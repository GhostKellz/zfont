const std = @import("std");
const root = @import("root.zig");
const gcode = @import("gcode");
const Unicode = @import("unicode.zig").Unicode;

// Terminal scrolling performance optimizer using gcode intelligence
// Optimizes text processing for high-speed terminal operations
pub const TerminalPerformanceOptimizer = struct {
    allocator: std.mem.Allocator,
    script_detector: gcode.script.ScriptDetector,
    cache: RenderCache,
    settings: OptimizationSettings,
    east_asian_mode: Unicode.EastAsianWidthMode,

    const Self = @This();

    const RenderCache = std.HashMap(CacheKey, CachedRenderData, CacheContext, std.hash_map.default_max_load_percentage);

    const CacheContext = struct {
        pub fn hash(self: @This(), key: CacheKey) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&key.text_hash));
            hasher.update(std.mem.asBytes(&key.font_size));
            hasher.update(std.mem.asBytes(&key.terminal_width));
            return hasher.final();
        }

        pub fn eql(self: @This(), a: CacheKey, b: CacheKey) bool {
            _ = self;
            return a.text_hash == b.text_hash and
                a.font_size == b.font_size and
                a.terminal_width == b.terminal_width;
        }
    };

    const CacheKey = struct {
        text_hash: u64,
        font_size: u32,
        terminal_width: u32,
    };

    const CachedRenderData = struct {
        line_segments: []LineSegment,
        total_lines: u32,
        requires_complex_shaping: bool,
        has_bidi_content: bool,
        timestamp: i64,
    };

    pub const OptimizationSettings = struct {
        cache_size_limit: usize = 1000,
        cache_ttl_ms: i64 = 30000, // 30 seconds
        lazy_analysis_threshold: usize = 1000, // Characters
        viewport_buffer_lines: u32 = 5,
        enable_incremental_updates: bool = true,
        enable_background_processing: bool = true,
        east_asian_width_mode: Unicode.EastAsianWidthMode = .standard,
    };

    pub const LineSegment = struct {
        text: []const u8,
        start_byte: usize,
        end_byte: usize,
        display_width: f32,
        script_runs: []ScriptRun,
        complexity_level: ComplexityLevel,
        needs_bidi: bool,
        needs_shaping: bool,
    };

    pub const ScriptRun = struct {
        script: gcode.script.Script,
        start: usize,
        length: usize,
        direction: gcode.bidi.Direction,
        complexity: ComplexityLevel,
    };

    pub const ComplexityLevel = enum(u8) {
        simple = 0, // ASCII text
        moderate = 1, // CJK or extended Latin
        complex = 2, // Arabic, Indic with shaping
        very_complex = 3, // Mixed scripts with BiDi
    };

    pub fn init(allocator: std.mem.Allocator, settings: OptimizationSettings) !Self {
        return Self{
            .allocator = allocator,
            .script_detector = try gcode.script.ScriptDetector.init(allocator),
            .cache = RenderCache.init(allocator),
            .settings = settings,
            .east_asian_mode = settings.east_asian_width_mode,
        };
    }

    pub fn deinit(self: *Self) void {
        self.script_detector.deinit();
        self.clearCache();
        self.cache.deinit();
    }

    pub fn setEastAsianWidthMode(self: *Self, mode: Unicode.EastAsianWidthMode) void {
        self.east_asian_mode = mode;
    }

    fn clearCache(self: *Self) void {
        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            self.deallocateCachedData(entry.value_ptr);
        }
        self.cache.clearRetainingCapacity();
    }

    fn deallocateCachedData(self: *Self, data: *CachedRenderData) void {
        for (data.line_segments) |*segment| {
            self.allocator.free(segment.script_runs);
        }
        self.allocator.free(data.line_segments);
    }

    pub fn optimizeTextForScrolling(self: *Self, text: []const u8, viewport_start: usize, viewport_end: usize, terminal_width: u32, font_size: f32) !ScrollOptimizedResult {
        // Quick analysis to determine optimization strategy
        const complexity = self.analyzeTextComplexity(text);

        // Check cache first
        const cache_key = self.createCacheKey(text, @intFromFloat(font_size), terminal_width);
        if (self.cache.get(cache_key)) |cached| {
            if (self.isCacheValid(cached)) {
                return try self.extractViewportFromCache(cached, viewport_start, viewport_end);
            }
        }

        // Choose optimization strategy based on complexity
        const result = switch (complexity) {
            .simple => try self.optimizeSimpleText(text, viewport_start, viewport_end, terminal_width),
            .moderate => try self.optimizeModerateText(text, viewport_start, viewport_end, terminal_width),
            .complex, .very_complex => try self.optimizeComplexText(text, viewport_start, viewport_end, terminal_width),
        };

        // Cache the results if beneficial
        if (text.len > self.settings.lazy_analysis_threshold) {
            try self.cacheRenderData(cache_key, &result);
        }

        return result;
    }

    fn analyzeTextComplexity(self: *Self, text: []const u8) ComplexityLevel {
        var has_non_ascii = false;
        var has_rtl = false;
        var has_complex_scripts = false;
        var scripts_seen = std.ArrayList(gcode.script.Script).init(self.allocator);
        defer scripts_seen.deinit();

        var byte_pos: usize = 0;
        var char_count: usize = 0;

        // Sample up to 200 characters for performance
        while (byte_pos < text.len and char_count < 200) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[byte_pos]) catch 1;
            if (byte_pos + char_len > text.len) break;

            const codepoint = std.unicode.utf8Decode(text[byte_pos .. byte_pos + char_len]) catch {
                byte_pos += 1;
                continue;
            };

            // Check for non-ASCII
            if (codepoint > 127) has_non_ascii = true;

            // Check for RTL scripts
            if (self.isRTLScript(codepoint)) has_rtl = true;

            // Check for complex scripts
            if (self.isComplexScript(codepoint)) has_complex_scripts = true;

            byte_pos += char_len;
            char_count += 1;
        }

        // Determine complexity level
        if (!has_non_ascii) return .simple;
        if (has_complex_scripts or has_rtl) {
            return if (has_rtl and has_complex_scripts) .very_complex else .complex;
        }
        return .moderate;
    }

    fn isRTLScript(self: *Self, codepoint: u32) bool {
        _ = self;
        // Arabic, Hebrew
        return (codepoint >= 0x0590 and codepoint <= 0x05FF) or // Hebrew
            (codepoint >= 0x0600 and codepoint <= 0x06FF) or // Arabic
            (codepoint >= 0x0750 and codepoint <= 0x077F); // Arabic Supplement
    }

    fn isComplexScript(self: *Self, codepoint: u32) bool {
        _ = self;
        // Arabic, Devanagari, Bengali, Tamil, etc.
        return (codepoint >= 0x0600 and codepoint <= 0x06FF) or // Arabic
            (codepoint >= 0x0900 and codepoint <= 0x097F) or // Devanagari
            (codepoint >= 0x0980 and codepoint <= 0x09FF) or // Bengali
            (codepoint >= 0x0B80 and codepoint <= 0x0BFF); // Tamil
    }

    fn optimizeSimpleText(self: *Self, text: []const u8, viewport_start: usize, viewport_end: usize, terminal_width: u32) !ScrollOptimizedResult {
        // Fast path for ASCII text
        var result = ScrollOptimizedResult.init(self.allocator);

        // Simple line breaking - just split on newlines and terminal width
        const visible_text = text[viewport_start..@min(viewport_end, text.len)];

        var lines = std.ArrayList(LineSegment).init(self.allocator);
        var line_start: usize = 0;
        var current_width: u32 = 0;

        for (visible_text, 0..) |byte, i| {
            const char_width = @as(u32, Unicode.getDisplayWidth(@intCast(byte), self.east_asian_mode));
            if (byte == '\n' or (terminal_width > 0 and current_width + char_width > terminal_width and current_width > 0)) {
                // Complete line
                const line_text = visible_text[line_start..i];
                const segment = LineSegment{
                    .text = line_text,
                    .start_byte = viewport_start + line_start,
                    .end_byte = viewport_start + i,
                    .display_width = @floatFromInt(self.measureColumns(line_text)),
                    .script_runs = &[_]ScriptRun{},
                    .complexity_level = .simple,
                    .needs_bidi = false,
                    .needs_shaping = false,
                };
                try lines.append(segment);

                line_start = i + 1;
                current_width = 0;
            } else {
                current_width += char_width;
            }
        }

        // Handle final line
        if (line_start < visible_text.len) {
            const line_text = visible_text[line_start..];
            const segment = LineSegment{
                .text = line_text,
                .start_byte = viewport_start + line_start,
                .end_byte = viewport_start + visible_text.len,
                .display_width = @floatFromInt(self.measureColumns(line_text)),
                .script_runs = &[_]ScriptRun{},
                .complexity_level = .simple,
                .needs_bidi = false,
                .needs_shaping = false,
            };
            try lines.append(segment);
        }

        result.line_segments = try lines.toOwnedSlice();
        result.total_lines = @intCast(result.line_segments.len);
        result.optimization_level = .simple;

        return result;
    }

    fn optimizeModerateText(self: *Self, text: []const u8, viewport_start: usize, viewport_end: usize, terminal_width: u32) !ScrollOptimizedResult {
        // Optimized path for CJK and extended Latin
        var result = ScrollOptimizedResult.init(self.allocator);

        // Use script detection for better line breaking
        const visible_text = text[viewport_start..@min(viewport_end, text.len)];
        const script_runs = try self.script_detector.detectRuns(visible_text);
        defer self.allocator.free(script_runs);

        var lines = std.ArrayList(LineSegment).init(self.allocator);
        var current_line_start: usize = 0;
        var current_width: f32 = 0;

        for (script_runs) |run| {
            const run_width = self.estimateRunWidth(run);

            // Check if run fits on current line
            if (terminal_width > 0 and current_width + run_width > @as(f32, @floatFromInt(terminal_width)) and current_width > 0) {
                // Complete current line
                try self.completeLine(&lines, visible_text, current_line_start, run.start, viewport_start, script_runs, .moderate);
                current_line_start = run.start;
                current_width = 0;
            }

            current_width += run_width;
        }

        // Complete final line
        if (current_line_start < visible_text.len) {
            try self.completeLine(&lines, visible_text, current_line_start, visible_text.len, viewport_start, script_runs, .moderate);
        }

        result.line_segments = try lines.toOwnedSlice();
        result.total_lines = @intCast(result.line_segments.len);
        result.optimization_level = .moderate;

        return result;
    }

    fn optimizeComplexText(self: *Self, text: []const u8, viewport_start: usize, viewport_end: usize, terminal_width: u32) !ScrollOptimizedResult {
        // Full analysis for complex scripts
        var result = ScrollOptimizedResult.init(self.allocator);

        const visible_text = text[viewport_start..@min(viewport_end, text.len)];

        // Use gcode for comprehensive analysis
        const script_runs = try self.script_detector.detectRuns(visible_text);
        defer self.allocator.free(script_runs);

        // Perform BiDi analysis if needed
        var bidi_runs: []gcode.bidi.BiDiRun = &[_]gcode.bidi.BiDiRun{};
        var needs_bidi = false;

        for (script_runs) |run| {
            if (run.script_info.writing_direction == .rtl) {
                needs_bidi = true;
                break;
            }
        }

        if (needs_bidi) {
            const bidi_processor = try gcode.bidi.BiDi.init(self.allocator);
            defer bidi_processor.deinit();
            bidi_runs = try bidi_processor.processText(visible_text, .auto);
        }

        var lines = std.ArrayList(LineSegment).init(self.allocator);
        var current_line_start: usize = 0;
        var current_width: f32 = 0;

        for (script_runs) |run| {
            const run_width = self.estimateComplexRunWidth(run);

            if (terminal_width > 0 and current_width + run_width > @as(f32, @floatFromInt(terminal_width)) and current_width > 0) {
                try self.completeComplexLine(&lines, visible_text, current_line_start, run.start, viewport_start, script_runs, bidi_runs);
                current_line_start = run.start;
                current_width = 0;
            }

            current_width += run_width;
        }

        // Complete final line
        if (current_line_start < visible_text.len) {
            try self.completeComplexLine(&lines, visible_text, current_line_start, visible_text.len, viewport_start, script_runs, bidi_runs);
        }

        if (needs_bidi) {
            self.allocator.free(bidi_runs);
        }

        result.line_segments = try lines.toOwnedSlice();
        result.total_lines = @intCast(result.line_segments.len);
        result.optimization_level = if (needs_bidi) .very_complex else .complex;

        return result;
    }

    fn estimateRunWidth(self: *Self, run: gcode.script.ScriptRun) f32 {
        return @as(f32, @floatFromInt(self.measureColumns(run.text)));
    }

    fn estimateComplexRunWidth(self: *Self, run: gcode.script.ScriptRun) f32 {
        return @as(f32, @floatFromInt(self.measureColumns(run.text)));
    }

    fn measureColumns(self: *Self, text: []const u8) usize {
        if (text.len == 0) return 0;
        return Unicode.stringWidthWithMode(text, self.east_asian_mode);
    }

    fn completeLine(self: *Self, lines: *std.ArrayList(LineSegment), text: []const u8, start: usize, end: usize, offset: usize, _: []const gcode.script.ScriptRun, complexity: ComplexityLevel) !void {
        const line_text = text[start..end];
        const segment = LineSegment{
            .text = line_text,
            .start_byte = offset + start,
            .end_byte = offset + end,
            .display_width = @floatFromInt(self.measureColumns(line_text)),
            .script_runs = &[_]ScriptRun{},
            .complexity_level = complexity,
            .needs_bidi = false,
            .needs_shaping = complexity != .simple,
        };
        try lines.append(segment);
    }

    fn completeComplexLine(self: *Self, lines: *std.ArrayList(LineSegment), text: []const u8, start: usize, end: usize, offset: usize, _: []const gcode.script.ScriptRun, _: []const gcode.bidi.BiDiRun) !void {
        const line_text = text[start..end];
        const segment = LineSegment{
            .text = line_text,
            .start_byte = offset + start,
            .end_byte = offset + end,
            .display_width = @floatFromInt(self.measureColumns(line_text)),
            .script_runs = &[_]ScriptRun{},
            .complexity_level = .complex,
            .needs_bidi = true,
            .needs_shaping = true,
        };
        try lines.append(segment);
    }

    fn createCacheKey(self: *Self, text: []const u8, font_size: u32, terminal_width: u32) CacheKey {
        _ = self;

        var hasher = std.hash.Wyhash.init(0x12345678);
        hasher.update(text);

        return CacheKey{
            .text_hash = hasher.final(),
            .font_size = font_size,
            .terminal_width = terminal_width,
        };
    }

    fn isCacheValid(self: *Self, cached: CachedRenderData) bool {
        const now = std.time.milliTimestamp();
        return (now - cached.timestamp) < self.settings.cache_ttl_ms;
    }

    fn extractViewportFromCache(self: *Self, cached: CachedRenderData, viewport_start: usize, viewport_end: usize) !ScrollOptimizedResult {
        _ = viewport_start;
        _ = viewport_end;

        var result = ScrollOptimizedResult.init(self.allocator);

        // Extract relevant lines from cache (simplified)
        result.line_segments = try self.allocator.dupe(LineSegment, cached.line_segments);
        result.total_lines = cached.total_lines;
        result.optimization_level = if (cached.has_bidi_content) .very_complex else if (cached.requires_complex_shaping) .complex else .moderate;

        return result;
    }

    fn cacheRenderData(self: *Self, key: CacheKey, result: *const ScrollOptimizedResult) !void {
        // Clean old cache entries if needed
        if (self.cache.count() >= self.settings.cache_size_limit) {
            try self.cleanOldCacheEntries();
        }

        const cached_data = CachedRenderData{
            .line_segments = try self.allocator.dupe(LineSegment, result.line_segments),
            .total_lines = result.total_lines,
            .requires_complex_shaping = result.optimization_level != .simple,
            .has_bidi_content = result.optimization_level == .very_complex,
            .timestamp = std.time.milliTimestamp(),
        };

        try self.cache.put(key, cached_data);
    }

    fn cleanOldCacheEntries(self: *Self) !void {
        const now = std.time.milliTimestamp();
        var entries_to_remove = std.ArrayList(CacheKey).init(self.allocator);
        defer entries_to_remove.deinit();

        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            if ((now - entry.value_ptr.timestamp) > self.settings.cache_ttl_ms) {
                try entries_to_remove.append(entry.key_ptr.*);
            }
        }

        for (entries_to_remove.items) |key| {
            if (self.cache.fetchRemove(key)) |kv| {
                self.deallocateCachedData(&kv.value);
            }
        }
    }

    // Performance monitoring and metrics
    pub fn getPerformanceMetrics(self: *Self) PerformanceMetrics {
        return PerformanceMetrics{
            .cache_hit_rate = 0.0, // Would track in real implementation
            .cache_size = self.cache.count(),
            .memory_usage = self.estimateMemoryUsage(),
            .optimization_level_distribution = self.getOptimizationDistribution(),
        };
    }

    fn estimateMemoryUsage(self: *Self) usize {
        var total: usize = 0;
        var iterator = self.cache.iterator();

        while (iterator.next()) |entry| {
            total += entry.value_ptr.line_segments.len * @sizeOf(LineSegment);
        }

        return total;
    }

    fn getOptimizationDistribution(self: *Self) [4]usize {
        _ = self;
        return [4]usize{ 0, 0, 0, 0 }; // Would track in real implementation
    }

    // Test performance optimization
    pub fn testPerformanceOptimization(self: *Self) !void {
        const test_texts = [_][]const u8{
            "Simple ASCII text for testing performance optimization.",
            "Mixed text with 中文字符 and English for moderate complexity.",
            "Complex text: العربية मिश्रित النص with mixed scripts and BiDi.",
            "Very complex: 👨‍👩‍👧‍👦 Family emoji مع النص العربي and हिंदी text.",
        };

        for (test_texts, 0..) |text, i| {
            std.log.info("Testing performance optimization {}: {s}", .{ i + 1, text });

            const start = std.time.milliTimestamp();
            var result = try self.optimizeTextForScrolling(text, 0, text.len, 80, 16.0);
            defer result.deinit();
            const end = std.time.milliTimestamp();

            std.log.info("  Optimization level: {}, Lines: {}, Time: {}ms", .{ @tagName(result.optimization_level), result.total_lines, end - start });
        }
    }
};

pub const ScrollOptimizedResult = struct {
    line_segments: []TerminalPerformanceOptimizer.LineSegment,
    total_lines: u32,
    optimization_level: TerminalPerformanceOptimizer.ComplexityLevel,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ScrollOptimizedResult {
        return ScrollOptimizedResult{
            .line_segments = &[_]TerminalPerformanceOptimizer.LineSegment{},
            .total_lines = 0,
            .optimization_level = .simple,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ScrollOptimizedResult) void {
        for (self.line_segments) |*segment| {
            self.allocator.free(segment.script_runs);
        }
        self.allocator.free(self.line_segments);
    }
};

pub const PerformanceMetrics = struct {
    cache_hit_rate: f32,
    cache_size: usize,
    memory_usage: usize,
    optimization_level_distribution: [4]usize,
};

test "TerminalPerformanceOptimizer complexity analysis" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const settings = TerminalPerformanceOptimizer.OptimizationSettings{};
    var optimizer = TerminalPerformanceOptimizer.init(allocator, settings) catch return;
    defer optimizer.deinit();

    // Test complexity analysis
    const simple_text = "Hello World";
    const complexity = optimizer.analyzeTextComplexity(simple_text);
    try testing.expect(complexity == .simple);

    const complex_text = "مرحبا بالعالم";
    const complex_complexity = optimizer.analyzeTextComplexity(complex_text);
    try testing.expect(complex_complexity == .complex or complex_complexity == .very_complex);
}
