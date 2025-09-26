const std = @import("std");
const root = @import("root.zig");
const FontManager = @import("font_manager.zig").FontManager;

// Multi-threaded font loading and processing
// Optimized for modern multi-core systems

pub const FontLoader = struct {
    allocator: std.mem.Allocator,
    thread_pool: std.Thread.Pool,
    loading_queue: std.atomic.Queue(LoadRequest),
    completed_queue: std.atomic.Queue(LoadResult),
    worker_count: u32,
    is_running: std.atomic.Value(bool),

    const Self = @This();

    const LoadRequest = struct {
        id: u64,
        font_path: []const u8,
        priority: Priority,
        callback_context: ?*anyopaque = null,
    };

    const LoadResult = struct {
        id: u64,
        font: ?*root.Font,
        error_info: ?LoadError = null,
        callback_context: ?*anyopaque = null,
    };

    const LoadError = struct {
        error_type: root.FontError,
        message: []const u8,
    };

    const Priority = enum(u8) {
        low = 0,
        normal = 1,
        high = 2,
        critical = 3, // For UI responsiveness
    };

    pub fn init(allocator: std.mem.Allocator, worker_count: ?u32) !Self {
        const actual_worker_count = worker_count orelse @max(1, std.Thread.getCpuCount() catch 4);

        var loader = Self{
            .allocator = allocator,
            .thread_pool = undefined,
            .loading_queue = std.atomic.Queue(LoadRequest).init(),
            .completed_queue = std.atomic.Queue(LoadResult).init(),
            .worker_count = actual_worker_count,
            .is_running = std.atomic.Value(bool).init(true),
        };

        // Initialize thread pool
        loader.thread_pool = std.Thread.Pool.init(.{
            .allocator = allocator,
            .n_jobs = actual_worker_count,
        });

        return loader;
    }

    pub fn deinit(self: *Self) void {
        // Stop workers
        self.is_running.store(false, .monotonic);

        // Wait for all threads to complete
        self.thread_pool.deinit();

        // Clean up remaining items in queues
        while (self.loading_queue.get()) |node| {
            self.allocator.destroy(node);
        }

        while (self.completed_queue.get()) |node| {
            if (node.data.font) |font| {
                font.deinit();
                self.allocator.destroy(font);
            }
            self.allocator.destroy(node);
        }
    }

    pub fn loadFontAsync(self: *Self, font_path: []const u8, priority: Priority, context: ?*anyopaque) !u64 {
        const id = generateRequestId();

        const request = LoadRequest{
            .id = id,
            .font_path = try self.allocator.dupe(u8, font_path),
            .priority = priority,
            .callback_context = context,
        };

        const node = try self.allocator.create(std.atomic.Queue(LoadRequest).Node);
        node.* = std.atomic.Queue(LoadRequest).Node{ .data = request };

        self.loading_queue.put(node);

        // Spawn worker task
        try self.thread_pool.spawn(fontLoaderWorker, .{ self, node });

        return id;
    }

    pub fn getCompletedFont(self: *Self, id: u64) ?LoadResult {
        // Non-blocking check for completed fonts
        var current = self.completed_queue.get();
        var prev: ?*std.atomic.Queue(LoadResult).Node = null;

        while (current) |node| {
            if (node.data.id == id) {
                // Remove from queue
                if (prev) |p| {
                    p.next = node.next;
                } else {
                    // This was the first node
                }

                const result = node.data;
                self.allocator.destroy(node);
                return result;
            }
            prev = node;
            current = node.next;
        }

        return null;
    }

    pub fn pollCompletedFonts(self: *Self, results: *std.ArrayList(LoadResult)) !void {
        // Get all completed font loading results
        while (self.completed_queue.get()) |node| {
            try results.append(node.data);
            self.allocator.destroy(node);
        }
    }

    fn fontLoaderWorker(self: *Self, request_node: *std.atomic.Queue(LoadRequest).Node) void {
        defer self.allocator.destroy(request_node);

        const request = request_node.data;
        defer self.allocator.free(request.font_path);

        var result = LoadResult{
            .id = request.id,
            .font = null,
            .callback_context = request.callback_context,
        };

        // Perform font loading
        result.font = self.loadFontFromFile(request.font_path) catch |err| {
            result.error_info = LoadError{
                .error_type = switch (err) {
                    error.FileNotFound => root.FontError.FontNotFound,
                    error.InvalidFontData => root.FontError.InvalidFontData,
                    error.OutOfMemory => root.FontError.MemoryError,
                    else => root.FontError.InvalidFontData,
                },
                .message = @errorName(err),
            };
            null;
        };

        // Queue result
        const result_node = self.allocator.create(std.atomic.Queue(LoadResult).Node) catch {
            // Critical failure - can't even allocate result node
            if (result.font) |font| {
                font.deinit();
                self.allocator.destroy(font);
            }
            return;
        };

        result_node.* = std.atomic.Queue(LoadResult).Node{ .data = result };
        self.completed_queue.put(result_node);
    }

    fn loadFontFromFile(self: *Self, font_path: []const u8) !*root.Font {
        // Load font data from file (this is the heavy I/O operation)
        const font_data = try std.fs.cwd().readFileAlloc(
            self.allocator,
            font_path,
            50 * 1024 * 1024, // 50MB max
        );
        defer self.allocator.free(font_data);

        // Create and initialize font
        const font = try self.allocator.create(root.Font);
        errdefer self.allocator.destroy(font);

        font.* = try root.Font.init(self.allocator, font_data);
        return font;
    }

    fn generateRequestId() u64 {
        // Simple atomic counter for request IDs
        const static = struct {
            var counter = std.atomic.Value(u64).init(1);
        };
        return static.counter.fetchAdd(1, .monotonic);
    }
};

// Batch font operations for improved efficiency
pub const BatchFontLoader = struct {
    allocator: std.mem.Allocator,
    base_loader: FontLoader,
    batch_requests: std.ArrayList(BatchRequest),
    batch_size: u32,

    const Self = @This();

    const BatchRequest = struct {
        paths: []const []const u8,
        priority: FontLoader.Priority,
        batch_id: u64,
    };

    pub fn init(allocator: std.mem.Allocator, batch_size: u32) !Self {
        return Self{
            .allocator = allocator,
            .base_loader = try FontLoader.init(allocator, null),
            .batch_requests = std.ArrayList(BatchRequest).init(allocator),
            .batch_size = batch_size,
        };
    }

    pub fn deinit(self: *Self) void {
        self.base_loader.deinit();
        self.batch_requests.deinit();
    }

    pub fn loadFontBatch(self: *Self, font_paths: []const []const u8, priority: FontLoader.Priority) !u64 {
        const batch_id = FontLoader.generateRequestId();

        // Split into smaller batches if needed
        var start: usize = 0;
        while (start < font_paths.len) {
            const end = @min(start + self.batch_size, font_paths.len);
            const batch_paths = font_paths[start..end];

            for (batch_paths) |path| {
                _ = try self.base_loader.loadFontAsync(path, priority, null);
            }

            start = end;
        }

        const request = BatchRequest{
            .paths = try self.allocator.dupe([]const u8, font_paths),
            .priority = priority,
            .batch_id = batch_id,
        };
        try self.batch_requests.append(request);

        return batch_id;
    }

    pub fn getBatchProgress(self: *Self, batch_id: u64) ?BatchProgress {
        // Find the batch request
        for (self.batch_requests.items) |request| {
            if (request.batch_id == batch_id) {
                var completed: u32 = 0;
                var failed: u32 = 0;

                // Count completed/failed fonts (simplified)
                var results = std.ArrayList(FontLoader.LoadResult).init(self.allocator);
                defer results.deinit();

                self.base_loader.pollCompletedFonts(&results) catch return null;

                for (results.items) |result| {
                    if (result.font != null) {
                        completed += 1;
                    } else {
                        failed += 1;
                    }
                }

                return BatchProgress{
                    .total = @intCast(request.paths.len),
                    .completed = completed,
                    .failed = failed,
                    .percentage = @as(f32, @floatFromInt(completed + failed)) / @as(f32, @floatFromInt(request.paths.len)) * 100.0,
                };
            }
        }

        return null;
    }
};

pub const BatchProgress = struct {
    total: u32,
    completed: u32,
    failed: u32,
    percentage: f32,
};

// High-performance font discovery using multiple threads
pub const FontDiscovery = struct {
    allocator: std.mem.Allocator,
    discovered_fonts: std.ArrayList(DiscoveredFont),
    discovery_threads: std.ArrayList(std.Thread),
    mutex: std.Thread.Mutex,

    const Self = @This();

    const DiscoveredFont = struct {
        path: []const u8,
        family_name: ?[]const u8 = null,
        style_name: ?[]const u8 = null,
        weight: root.FontWeight = .normal,
        is_monospace: bool = false,
        supports_ligatures: bool = false,
        file_size: u64 = 0,
        last_modified: i64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .discovered_fonts = std.ArrayList(DiscoveredFont).init(allocator),
            .discovery_threads = std.ArrayList(std.Thread).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        // Wait for all discovery threads to complete
        for (self.discovery_threads.items) |thread| {
            thread.join();
        }
        self.discovery_threads.deinit();

        // Free discovered font paths
        for (self.discovered_fonts.items) |font| {
            self.allocator.free(font.path);
            if (font.family_name) |name| self.allocator.free(name);
            if (font.style_name) |name| self.allocator.free(name);
        }
        self.discovered_fonts.deinit();
    }

    pub fn discoverSystemFonts(self: *Self) !void {
        const system_font_dirs = getSystemFontDirectories();

        // Spawn discovery thread for each directory
        for (system_font_dirs) |dir| {
            const thread = try std.Thread.spawn(.{}, Self.discoveryWorker, .{ self, dir });
            try self.discovery_threads.append(thread);
        }
    }

    fn discoveryWorker(self: *Self, directory: []const u8) void {
        self.scanDirectory(directory) catch |err| {
            std.log.warn("Font discovery error in {s}: {}", .{ directory, err });
        };
    }

    fn scanDirectory(self: *Self, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file and isFontFile(entry.name)) {
                const full_path = try std.fs.path.join(
                    self.allocator,
                    &[_][]const u8{ dir_path, entry.name },
                );

                var discovered = DiscoveredFont{
                    .path = full_path,
                };

                // Get file metadata
                const stat = dir.statFile(entry.name) catch continue;
                discovered.file_size = stat.size;
                discovered.last_modified = @intCast(stat.mtime);

                // Quick font analysis (without full parsing)
                self.analyzeFont(&discovered) catch {};

                // Thread-safe addition to results
                self.mutex.lock();
                defer self.mutex.unlock();
                self.discovered_fonts.append(discovered) catch {};
            } else if (entry.kind == .directory and !std.mem.eql(u8, entry.name, ".")) {
                // Recursive directory scanning
                const subdirectory = try std.fs.path.join(
                    self.allocator,
                    &[_][]const u8{ dir_path, entry.name },
                );
                defer self.allocator.free(subdirectory);

                self.scanDirectory(subdirectory) catch {};
            }
        }
    }

    fn analyzeFont(self: *Self, discovered: *DiscoveredFont) !void {
        // Quick font analysis without full parsing
        // This could use font headers to determine basic properties
        _ = self;

        // Heuristic-based analysis from filename
        const filename = std.fs.path.basename(discovered.path);

        if (std.mem.indexOf(u8, filename, "Mono") != null or
            std.mem.indexOf(u8, filename, "Code") != null or
            std.mem.indexOf(u8, filename, "Console") != null) {
            discovered.is_monospace = true;
        }

        if (std.mem.indexOf(u8, filename, "Fira") != null or
            std.mem.indexOf(u8, filename, "Cascadia") != null or
            std.mem.indexOf(u8, filename, "JetBrains") != null) {
            discovered.supports_ligatures = true;
        }

        // Could be enhanced with actual font header parsing
    }

    fn getSystemFontDirectories() []const []const u8 {
        const builtin_os = @import("builtin").os.tag;
        return switch (builtin_os) {
            .linux => &[_][]const u8{
                "/usr/share/fonts",
                "/usr/local/share/fonts",
                "/home/.local/share/fonts",
                "/home/.fonts",
            },
            .macos => &[_][]const u8{
                "/System/Library/Fonts",
                "/Library/Fonts",
                "/Users/Shared/Fonts",
                "/home/Library/Fonts",
            },
            .windows => &[_][]const u8{
                "C:\\Windows\\Fonts",
                "C:\\Windows\\System32\\Fonts",
            },
            else => &[_][]const u8{
                "/usr/share/fonts",
                "/usr/local/share/fonts",
            },
        };
    }

    fn isFontFile(filename: []const u8) bool {
        const extensions = [_][]const u8{ ".ttf", ".otf", ".woff", ".woff2", ".ttc" };

        for (extensions) |ext| {
            if (std.mem.endsWith(u8, std.mem.toLower(
                std.heap.page_allocator,
                filename,
            ) catch filename, ext)) {
                return true;
            }
        }
        return false;
    }

    pub fn getDiscoveredFonts(self: *Self) []const DiscoveredFont {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.discovered_fonts.items;
    }
};

// Tests
test "FontLoader initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loader = try FontLoader.init(allocator, 2);
    defer loader.deinit();

    try testing.expect(loader.worker_count == 2);
    try testing.expect(loader.is_running.load(.monotonic));
}

test "BatchFontLoader functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var batch_loader = try BatchFontLoader.init(allocator, 4);
    defer batch_loader.deinit();

    try testing.expect(batch_loader.batch_size == 4);
}

test "FontDiscovery initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var discovery = FontDiscovery.init(allocator);
    defer discovery.deinit();

    try testing.expect(discovery.discovered_fonts.items.len == 0);
}