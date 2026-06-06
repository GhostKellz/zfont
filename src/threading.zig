const std = @import("std");
const root = @import("root.zig");
const FontManager = @import("font_manager.zig").FontManager;

// Multi-threaded font loading and processing
// Optimized for modern multi-core systems

// Minimal blocking-lock helper built on the spinlock `std.atomic.Mutex`,
// which only exposes `tryLock`/`unlock`. We emulate a blocking acquire by
// spinning and yielding the thread until the lock is taken.
fn lockMutex(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) {
        std.Thread.yield() catch {};
    }
}

fn unlockMutex(m: *std.atomic.Mutex) void {
    m.unlock();
}

pub const FontLoader = struct {
    allocator: std.mem.Allocator,

    // Worker pool: a fixed set of threads pulling jobs from a shared,
    // mutex-guarded queue until `is_running` is cleared.
    workers: std.ArrayList(std.Thread),
    worker_count: u32,
    workers_started: bool,

    // Pending load requests. Guarded by `queue_mutex`.
    loading_queue: std.ArrayList(LoadRequest),
    queue_mutex: std.atomic.Mutex,

    // Completed results. Guarded by `completed_mutex`.
    completed_queue: std.ArrayList(LoadResult),
    completed_mutex: std.atomic.Mutex,

    // Cleared on deinit to signal workers to stop.
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
        const actual_worker_count = worker_count orelse @as(u32, @intCast(@max(1, std.Thread.getCpuCount() catch 4)));

        // Workers are spawned lazily on the first enqueue: `init` returns the
        // struct by value, so spawning here would hand workers a pointer to a
        // soon-to-be-moved stack value. Deferring until `loadFontAsync` lets us
        // pass the caller's stable `self` pointer instead.
        return Self{
            .allocator = allocator,
            .workers = std.ArrayList(std.Thread).empty,
            .worker_count = actual_worker_count,
            .workers_started = false,
            .loading_queue = std.ArrayList(LoadRequest).empty,
            .queue_mutex = .unlocked,
            .completed_queue = std.ArrayList(LoadResult).empty,
            .completed_mutex = .unlocked,
            .is_running = std.atomic.Value(bool).init(true),
        };
    }

    // Spawn the fixed pool of worker threads, each pulling jobs from the shared
    // queue until shutdown is signalled. Idempotent and guarded by the queue
    // mutex held by the caller.
    fn ensureWorkers(self: *Self) !void {
        if (self.workers_started) return;
        self.workers_started = true;

        try self.workers.ensureTotalCapacity(self.allocator, self.worker_count);
        var spawned: u32 = 0;
        while (spawned < self.worker_count) : (spawned += 1) {
            const thread = std.Thread.spawn(.{}, workerMain, .{self}) catch break;
            self.workers.appendAssumeCapacity(thread);
        }
    }

    pub fn deinit(self: *Self) void {
        self.stopAndJoin();

        // Drain any remaining pending requests, freeing their owned paths.
        for (self.loading_queue.items) |request| {
            self.allocator.free(request.font_path);
        }
        self.loading_queue.deinit(self.allocator);

        // Drain any remaining completed results, freeing owned fonts.
        for (self.completed_queue.items) |result| {
            if (result.font) |font| {
                font.deinit();
                self.allocator.destroy(font);
            }
        }
        self.completed_queue.deinit(self.allocator);
    }

    // Signal shutdown and join every spawned worker before any shared state
    // is freed. Safe to call multiple times.
    fn stopAndJoin(self: *Self) void {
        self.is_running.store(false, .monotonic);
        for (self.workers.items) |thread| {
            thread.join();
        }
        self.workers.deinit(self.allocator);
        self.workers = std.ArrayList(std.Thread).empty;
    }

    pub fn loadFontAsync(self: *Self, font_path: []const u8, priority: Priority, context: ?*anyopaque) !u64 {
        const id = generateRequestId();

        const request = LoadRequest{
            .id = id,
            .font_path = try self.allocator.dupe(u8, font_path),
            .priority = priority,
            .callback_context = context,
        };

        // Enqueue for the worker pool to pick up, spawning the pool on first use.
        lockMutex(&self.queue_mutex);
        defer unlockMutex(&self.queue_mutex);

        self.ensureWorkers() catch |err| {
            self.allocator.free(request.font_path);
            return err;
        };

        self.loading_queue.append(self.allocator, request) catch |err| {
            self.allocator.free(request.font_path);
            return err;
        };

        return id;
    }

    pub fn getCompletedFont(self: *Self, id: u64) ?LoadResult {
        // Non-blocking check for a specific completed font.
        lockMutex(&self.completed_mutex);
        defer unlockMutex(&self.completed_mutex);

        for (self.completed_queue.items, 0..) |result, index| {
            if (result.id == id) {
                return self.completed_queue.orderedRemove(index);
            }
        }

        return null;
    }

    pub fn pollCompletedFonts(self: *Self, results: *std.ArrayList(LoadResult)) !void {
        // Drain all currently completed font loading results.
        lockMutex(&self.completed_mutex);
        defer unlockMutex(&self.completed_mutex);

        try results.appendSlice(self.allocator, self.completed_queue.items);
        self.completed_queue.clearRetainingCapacity();
    }

    // Worker thread main loop: pull jobs from the shared queue, run the load,
    // and push results back until shutdown is signalled and the queue drains.
    fn workerMain(self: *Self) void {
        while (true) {
            const maybe_request = self.dequeueRequest();
            if (maybe_request) |request| {
                self.processRequest(request);
                continue;
            }

            // No work right now. Exit once shutdown was requested, otherwise
            // back off briefly to avoid busy-spinning.
            if (!self.is_running.load(.monotonic)) return;
            std.Thread.yield() catch {};
        }
    }

    fn dequeueRequest(self: *Self) ?LoadRequest {
        lockMutex(&self.queue_mutex);
        defer unlockMutex(&self.queue_mutex);

        if (self.loading_queue.items.len > 0) {
            return self.loading_queue.orderedRemove(0);
        }
        return null;
    }

    fn processRequest(self: *Self, request: LoadRequest) void {
        defer self.allocator.free(request.font_path);

        var result = LoadResult{
            .id = request.id,
            .font = null,
            .callback_context = request.callback_context,
        };

        // Perform font loading (heavy I/O + parsing).
        result.font = self.loadFontFromFile(request.font_path) catch |err| blk: {
            result.error_info = LoadError{
                .error_type = switch (err) {
                    error.FileNotFound => root.FontError.FontNotFound,
                    error.InvalidFontData => root.FontError.InvalidFontData,
                    error.OutOfMemory => root.FontError.MemoryError,
                    else => root.FontError.InvalidFontData,
                },
                .message = @errorName(err),
            };
            break :blk null;
        };

        // Publish the result for consumers.
        lockMutex(&self.completed_mutex);
        defer unlockMutex(&self.completed_mutex);
        self.completed_queue.append(self.allocator, result) catch {
            // Critical failure: cannot store the result, so drop the font to
            // avoid leaking it.
            if (result.font) |font| {
                font.deinit();
                self.allocator.destroy(font);
            }
        };
    }

    fn loadFontFromFile(self: *Self, font_path: []const u8) !*root.Font {
        const io = std.Io.Threaded.global_single_threaded.io();

        // Load font data from file (this is the heavy I/O operation).
        const font_data = try std.Io.Dir.cwd().readFileAlloc(
            io,
            font_path,
            self.allocator,
            std.Io.Limit.limited(50 * 1024 * 1024), // 50MB max
        );
        defer self.allocator.free(font_data);

        // Create and initialize font.
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
            .batch_requests = std.ArrayList(BatchRequest).empty,
            .batch_size = batch_size,
        };
    }

    pub fn deinit(self: *Self) void {
        self.base_loader.deinit();
        for (self.batch_requests.items) |request| {
            self.allocator.free(request.paths);
        }
        self.batch_requests.deinit(self.allocator);
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
        try self.batch_requests.append(self.allocator, request);

        return batch_id;
    }

    pub fn getBatchProgress(self: *Self, batch_id: u64) ?BatchProgress {
        // Find the batch request
        for (self.batch_requests.items) |request| {
            if (request.batch_id == batch_id) {
                var completed: u32 = 0;
                var failed: u32 = 0;

                // Count completed/failed fonts (simplified)
                var results = std.ArrayList(FontLoader.LoadResult).empty;
                defer results.deinit(self.allocator);

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
    mutex: std.atomic.Mutex,

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
            .discovered_fonts = std.ArrayList(DiscoveredFont).empty,
            .discovery_threads = std.ArrayList(std.Thread).empty,
            .mutex = .unlocked,
        };
    }

    pub fn deinit(self: *Self) void {
        // Wait for all discovery threads to complete
        for (self.discovery_threads.items) |thread| {
            thread.join();
        }
        self.discovery_threads.deinit(self.allocator);

        // Free discovered font paths
        for (self.discovered_fonts.items) |font| {
            self.allocator.free(font.path);
            if (font.family_name) |name| self.allocator.free(name);
            if (font.style_name) |name| self.allocator.free(name);
        }
        self.discovered_fonts.deinit(self.allocator);
    }

    pub fn discoverSystemFonts(self: *Self) !void {
        const system_font_dirs = getSystemFontDirectories();

        // Spawn discovery thread for each directory
        for (system_font_dirs) |dir| {
            const thread = try std.Thread.spawn(.{}, Self.discoveryWorker, .{ self, dir });
            try self.discovery_threads.append(self.allocator, thread);
        }
    }

    fn discoveryWorker(self: *Self, directory: []const u8) void {
        self.scanDirectory(directory) catch |err| {
            std.log.warn("Font discovery error in {s}: {}", .{ directory, err });
        };
    }

    fn scanDirectory(self: *Self, dir_path: []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();

        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(io);

        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind == .file and isFontFile(entry.name)) {
                const full_path = try std.fs.path.join(
                    self.allocator,
                    &[_][]const u8{ dir_path, entry.name },
                );

                var discovered = DiscoveredFont{
                    .path = full_path,
                };

                // Get file metadata
                const stat = dir.statFile(io, entry.name, .{}) catch continue;
                discovered.file_size = stat.size;
                discovered.last_modified = @intCast(stat.mtime.toNanoseconds());

                // Quick font analysis (without full parsing)
                self.analyzeFont(&discovered) catch {};

                // Thread-safe addition to results
                lockMutex(&self.mutex);
                defer unlockMutex(&self.mutex);
                self.discovered_fonts.append(self.allocator, discovered) catch {};
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
            std.mem.indexOf(u8, filename, "Console") != null)
        {
            discovered.is_monospace = true;
        }

        if (std.mem.indexOf(u8, filename, "Fira") != null or
            std.mem.indexOf(u8, filename, "Cascadia") != null or
            std.mem.indexOf(u8, filename, "JetBrains") != null or
            std.mem.indexOf(u8, filename, "Iosevka") != null or
            std.mem.indexOf(u8, filename, "Victor") != null or
            std.mem.indexOf(u8, filename, "Monaspace") != null or
            std.mem.indexOf(u8, filename, "Recursive") != null or
            std.mem.indexOf(u8, filename, "Plex") != null)
        {
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
            if (std.ascii.endsWithIgnoreCase(filename, ext)) {
                return true;
            }
        }
        return false;
    }

    pub fn getDiscoveredFonts(self: *Self) []const DiscoveredFont {
        lockMutex(&self.mutex);
        defer unlockMutex(&self.mutex);
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
