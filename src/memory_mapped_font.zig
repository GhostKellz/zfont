const std = @import("std");
const root = @import("root.zig");

// Memory-mapped font file support for zero-copy font loading
// Provides significant performance improvements for large font files
pub const MemoryMappedFont = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    data: []align(std.mem.page_size) const u8,
    size: u64,
    path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, font_path: []const u8) !Self {
        const file = try std.fs.cwd().openFile(font_path, .{});
        errdefer file.close();

        const stat = try file.stat();
        const size = stat.size;

        // Memory-map the entire font file
        const mapped_data = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );

        return Self{
            .allocator = allocator,
            .file = file,
            .data = @alignCast(mapped_data),
            .size = size,
            .path = try allocator.dupe(u8, font_path),
        };
    }

    pub fn deinit(self: *Self) void {
        std.posix.munmap(self.data);
        self.file.close();
        self.allocator.free(self.path);
    }

    pub fn getData(self: *const Self) []const u8 {
        return self.data;
    }

    pub fn getSize(self: *const Self) u64 {
        return self.size;
    }

    pub fn createParser(self: *const Self, allocator: std.mem.Allocator) !@import("font_parser.zig").FontParser {
        return @import("font_parser.zig").FontParser.init(allocator, self.data);
    }

    // Prefault pages to reduce initial access latency
    pub fn prefault(self: *const Self) void {
        const page_size = std.mem.page_size;
        const pages = (self.size + page_size - 1) / page_size;

        var i: usize = 0;
        while (i < pages) : (i += 1) {
            const offset = i * page_size;
            if (offset < self.size) {
                // Touch each page to fault it in
                _ = self.data[offset];
            }
        }
    }

    // Advise kernel about memory access patterns
    pub fn adviseSequential(self: *const Self) void {
        _ = std.posix.madvise(self.data.ptr, self.size, std.posix.MADV.SEQUENTIAL) catch {};
    }

    pub fn adviseRandom(self: *const Self) void {
        _ = std.posix.madvise(self.data.ptr, self.size, std.posix.MADV.RANDOM) catch {};
    }

    pub fn adviseWillNeed(self: *const Self) void {
        _ = std.posix.madvise(self.data.ptr, self.size, std.posix.MADV.WILLNEED) catch {};
    }
};

// Font cache with memory-mapped files
pub const MemoryMappedFontCache = struct {
    allocator: std.mem.Allocator,
    fonts: std.StringHashMap(*MemoryMappedFont),
    max_fonts: u32,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_fonts: u32) Self {
        return Self{
            .allocator = allocator,
            .fonts = std.StringHashMap(*MemoryMappedFont).init(allocator),
            .max_fonts = max_fonts,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iterator = self.fonts.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.fonts.deinit();
    }

    pub fn getFont(self: *Self, font_path: []const u8) !*MemoryMappedFont {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.fonts.get(font_path)) |font| {
            return font;
        }

        // Check if we need to evict old fonts
        if (self.fonts.count() >= self.max_fonts) {
            try self.evictOldest();
        }

        // Load new font
        const font = try self.allocator.create(MemoryMappedFont);
        errdefer self.allocator.destroy(font);

        font.* = try MemoryMappedFont.init(self.allocator, font_path);

        // Optimize for typical font access patterns
        font.adviseWillNeed();

        const key = try self.allocator.dupe(u8, font_path);
        try self.fonts.put(key, font);

        return font;
    }

    fn evictOldest(self: *Self) !void {
        // Simple eviction: remove first font found
        var iterator = self.fonts.iterator();
        if (iterator.next()) |entry| {
            const font = entry.value_ptr.*;
            font.deinit();
            self.allocator.destroy(font);

            const key = entry.key_ptr.*;
            _ = self.fonts.remove(key);
            self.allocator.free(key);
        }
    }

    pub fn preloadFonts(self: *Self, font_paths: []const []const u8) !void {
        for (font_paths) |path| {
            const font = try self.getFont(path);
            font.prefault();
        }
    }
};

// Shared font data for system fonts
pub const SharedFontData = struct {
    allocator: std.mem.Allocator,
    shared_memory: ?[]align(std.mem.page_size) u8,
    fonts: std.ArrayList(SharedFont),

    const Self = @This();

    const SharedFont = struct {
        name: []const u8,
        offset: u64,
        size: u64,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .shared_memory = null,
            .fonts = std.ArrayList(SharedFont).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.shared_memory) |memory| {
            std.posix.munmap(memory);
        }

        for (self.fonts.items) |font| {
            self.allocator.free(font.name);
        }
        self.fonts.deinit();
    }

    // Create shared memory segment for common system fonts
    pub fn createSharedSegment(self: *Self, size: u64) !void {
        const mapped = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED, .ANONYMOUS = true },
            -1,
            0,
        );

        self.shared_memory = @alignCast(mapped);
    }

    pub fn addFont(self: *Self, name: []const u8, data: []const u8) !void {
        const shared_mem = self.shared_memory orelse return root.FontError.MemoryError;

        // Find space in shared memory
        var offset: u64 = 0;
        for (self.fonts.items) |font| {
            offset = @max(offset, font.offset + font.size);
        }

        if (offset + data.len > shared_mem.len) {
            return root.FontError.MemoryError;
        }

        // Copy font data to shared memory
        @memcpy(shared_mem[offset..offset + data.len], data);

        try self.fonts.append(SharedFont{
            .name = try self.allocator.dupe(u8, name),
            .offset = offset,
            .size = data.len,
        });
    }

    pub fn getFontData(self: *const Self, name: []const u8) ?[]const u8 {
        const shared_mem = self.shared_memory orelse return null;

        for (self.fonts.items) |font| {
            if (std.mem.eql(u8, font.name, name)) {
                return shared_mem[font.offset..font.offset + font.size];
            }
        }
        return null;
    }
};

test "MemoryMappedFontCache operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = MemoryMappedFontCache.init(allocator, 5);
    defer cache.deinit();

    try testing.expect(cache.fonts.count() == 0);
    try testing.expect(cache.max_fonts == 5);
}

test "SharedFontData operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var shared_data = SharedFontData.init(allocator);
    defer shared_data.deinit();

    try testing.expect(shared_data.fonts.items.len == 0);
}