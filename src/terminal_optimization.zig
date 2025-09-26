const std = @import("std");
const root = @import("root.zig");

// Terminal-specific optimizations for maximum performance
// Tailored for GhostShell and other high-performance terminals
pub const TerminalOptimizer = struct {
    allocator: std.mem.Allocator,

    // Character frequency analysis for caching priorities
    ascii_frequency: [128]u32,
    unicode_frequency: std.AutoHashMap(u32, u32),

    // Terminal characteristics
    cell_width: u32,
    cell_height: u32,
    columns: u32,
    rows: u32,

    // Performance counters
    cache_hits: std.atomic.Value(u64),
    cache_misses: std.atomic.Value(u64),
    render_time: std.atomic.Value(u64), // nanoseconds

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, columns: u32, rows: u32, cell_width: u32, cell_height: u32) Self {
        return Self{
            .allocator = allocator,
            .ascii_frequency = [_]u32{0} ** 128,
            .unicode_frequency = std.AutoHashMap(u32, u32).init(allocator),
            .cell_width = cell_width,
            .cell_height = cell_height,
            .columns = columns,
            .rows = rows,
            .cache_hits = std.atomic.Value(u64).init(0),
            .cache_misses = std.atomic.Value(u64).init(0),
            .render_time = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        self.unicode_frequency.deinit();
    }

    // Track character usage for intelligent caching
    pub fn recordCharacterUsage(self: *Self, codepoint: u32) void {
        if (codepoint < 128) {
            self.ascii_frequency[codepoint] += 1;
        } else {
            const result = self.unicode_frequency.getOrPut(codepoint) catch return;
            if (result.found_existing) {
                result.value_ptr.* += 1;
            } else {
                result.value_ptr.* = 1;
            }
        }
    }

    // Get character priority for cache eviction decisions
    pub fn getCharacterPriority(self: *const Self, codepoint: u32) u32 {
        if (codepoint < 128) {
            return self.ascii_frequency[codepoint];
        } else {
            return self.unicode_frequency.get(codepoint) orelse 0;
        }
    }

    // Optimize glyph atlas based on terminal characteristics
    pub fn optimizeGlyphAtlas(self: *const Self, atlas_size: *u32) void {
        const total_cells = self.columns * self.rows;

        // Calculate optimal atlas size based on screen real estate
        const estimated_glyphs = @min(total_cells * 2, 4096); // Conservative estimate
        const glyph_area = self.cell_width * self.cell_height;
        const required_area = estimated_glyphs * glyph_area;

        // Find next power of 2 that fits required area
        var size: u32 = 256;
        while (size * size < required_area and size < 4096) {
            size *= 2;
        }

        atlas_size.* = size;
    }

    // Fast ASCII rendering path
    pub fn renderASCII(self: *Self, chars: []const u8, x: u32, y: u32, buffer: []u8) !void {
        const start_time = std.time.nanoTimestamp();
        defer {
            const end_time = std.time.nanoTimestamp();
            _ = self.render_time.fetchAdd(@intCast(end_time - start_time), .monotonic);
        }

        // Optimized ASCII rendering with SIMD when available
        for (chars, 0..) |char, i| {
            if (char < 128) {
                self.recordCharacterUsage(char);
                try self.renderASCIIChar(char, x + @as(u32, @intCast(i)) * self.cell_width, y, buffer);
            }
        }
    }

    fn renderASCIIChar(self: *const Self, char: u8, x: u32, y: u32, buffer: []u8) !void {
        // Simple ASCII character rendering
        _ = self;
        _ = char;
        _ = x;
        _ = y;
        _ = buffer;
        // TODO: Implement optimized ASCII glyph rendering
    }

    // Performance monitoring
    pub fn recordCacheHit(self: *Self) void {
        _ = self.cache_hits.fetchAdd(1, .monotonic);
    }

    pub fn recordCacheMiss(self: *Self) void {
        _ = self.cache_misses.fetchAdd(1, .monotonic);
    }

    pub fn getCacheHitRatio(self: *const Self) f32 {
        const hits = self.cache_hits.load(.monotonic);
        const misses = self.cache_misses.load(.monotonic);
        const total = hits + misses;

        if (total == 0) return 0.0;
        return @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(total));
    }

    pub fn getAverageRenderTime(self: *const Self) u64 {
        const total_time = self.render_time.load(.monotonic);
        const total_renders = self.cache_hits.load(.monotonic) + self.cache_misses.load(.monotonic);

        if (total_renders == 0) return 0;
        return total_time / total_renders;
    }

    // Reset performance counters
    pub fn resetCounters(self: *Self) void {
        self.cache_hits.store(0, .monotonic);
        self.cache_misses.store(0, .monotonic);
        self.render_time.store(0, .monotonic);
    }
};

// Fast text measurement for terminal layout
pub const TerminalMeasurement = struct {
    const Self = @This();

    // Pre-computed ASCII character widths
    const ascii_widths = [_]f32{
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, // 0-15
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 16-31
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 32-47 (space, !"#$%&'()*+,-./)
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 48-63 (0-9:;<=>?)
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 64-79 (@A-O)
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 80-95 (P-Z[\]^_)
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 96-111 (`a-o)
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, // 112-127 (p-z{|}~DEL)
    };

    pub fn measureASCII(text: []const u8) f32 {
        var width: f32 = 0;
        for (text) |char| {
            if (char < 128) {
                width += ascii_widths[char];
            } else {
                width += 1; // Fallback for non-ASCII
            }
        }
        return width;
    }

    pub fn measureUnicode(allocator: std.mem.Allocator, text: []const u8) !f32 {
        _ = allocator;
        var width: f32 = 0;
        var i: usize = 0;

        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + char_len <= text.len) {
                const codepoint = std.unicode.utf8Decode(text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };

                // Use gcode Unicode properties for width
                const unicode_props = @import("unicode.zig").Unicode.getProperties(codepoint);
                width += unicode_props.width.toFloat();
                i += char_len;
            } else {
                i += 1;
            }
        }

        return width;
    }
};

// Terminal-specific font manager with optimizations
pub const TerminalFontManager = struct {
    base_manager: *root.FontManager,
    optimizer: TerminalOptimizer,
    ascii_cache: [128]?*root.Glyph,
    frequent_unicode_cache: std.AutoHashMap(u32, *root.Glyph),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, base_manager: *root.FontManager, columns: u32, rows: u32, cell_width: u32, cell_height: u32) !Self {
        return Self{
            .base_manager = base_manager,
            .optimizer = TerminalOptimizer.init(allocator, columns, rows, cell_width, cell_height),
            .ascii_cache = [_]?*root.Glyph{null} ** 128,
            .frequent_unicode_cache = std.AutoHashMap(u32, *root.Glyph).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.optimizer.deinit();
        self.frequent_unicode_cache.deinit();
    }

    pub fn getGlyph(self: *Self, codepoint: u32, size: f32) !*root.Glyph {
        // Fast path for ASCII characters
        if (codepoint < 128) {
            if (self.ascii_cache[codepoint]) |glyph| {
                self.optimizer.recordCacheHit();
                return glyph;
            } else {
                self.optimizer.recordCacheMiss();
                // Load glyph through base manager
                return self.base_manager.getGlyph(codepoint, size);
            }
        }

        // Check frequent Unicode cache
        if (self.frequent_unicode_cache.get(codepoint)) |glyph| {
            self.optimizer.recordCacheHit();
            return glyph;
        } else {
            self.optimizer.recordCacheMiss();
            return self.base_manager.getGlyph(codepoint, size);
        }
    }

    pub fn preloadCommonChars(self: *Self, size: f32) !void {
        // Preload common ASCII characters
        const common_ascii = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,;:!?()[]{}\"'-_+=<>/@#$%^&*~`|\\";

        for (common_ascii) |char| {
            if (char < 128 and self.ascii_cache[char] == null) {
                self.ascii_cache[char] = try self.base_manager.getGlyph(char, size);
            }
        }
    }

    pub fn getOptimizer(self: *Self) *TerminalOptimizer {
        return &self.optimizer;
    }
};

test "TerminalOptimizer functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var optimizer = TerminalOptimizer.init(allocator, 80, 24, 12, 16);
    defer optimizer.deinit();

    // Test character usage tracking
    optimizer.recordCharacterUsage('a');
    optimizer.recordCharacterUsage('a');
    optimizer.recordCharacterUsage('b');

    try testing.expect(optimizer.getCharacterPriority('a') == 2);
    try testing.expect(optimizer.getCharacterPriority('b') == 1);
    try testing.expect(optimizer.getCharacterPriority('c') == 0);
}

test "TerminalMeasurement ASCII" {
    const text = "Hello World";
    const width = TerminalMeasurement.measureASCII(text);
    try std.testing.expect(width == 11.0); // 11 characters
}