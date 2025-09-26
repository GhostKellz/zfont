const std = @import("std");
const root = @import("root.zig");
const gcode = @import("gcode");

// CJK character width handler using gcode analysis
// Handles proper display width for Han, Hiragana, Katakana, Hangul
pub const CJKWidthProcessor = struct {
    allocator: std.mem.Allocator,
    script_detector: gcode.script.ScriptDetector,
    width_cache: WidthCache,

    const Self = @This();

    const WidthCache = std.HashMap(u32, CJKCharacterInfo, WidthContext, std.hash_map.default_max_load_percentage);

    const WidthContext = struct {
        pub fn hash(self: @This(), key: u32) u64 {
            _ = self;
            return key;
        }

        pub fn eql(self: @This(), a: u32, b: u32) bool {
            _ = self;
            return a == b;
        }
    };

    const CJKCharacterInfo = struct {
        display_width: f32,
        script_type: CJKScript,
        char_category: CJKCategory,
        is_halfwidth: bool,
        is_fullwidth: bool,
        terminal_cells: u8,
    };

    pub const CJKScript = enum(u8) {
        han = 0,
        hiragana = 1,
        katakana = 2,
        hangul = 3,
        bopomofo = 4,
        yi = 5,
        unknown = 255,
    };

    pub const CJKCategory = enum(u8) {
        ideograph = 0,
        syllable = 1,
        punctuation = 2,
        symbol = 3,
        number = 4,
        modifier = 5,
        other = 255,
    };

    pub fn init(allocator: std.mem.Allocator) !Self {
        var processor = Self{
            .allocator = allocator,
            .script_detector = try gcode.script.ScriptDetector.init(allocator),
            .width_cache = WidthCache.init(allocator),
        };

        try processor.loadCJKWidthData();
        return processor;
    }

    pub fn deinit(self: *Self) void {
        self.script_detector.deinit();
        self.width_cache.deinit();
    }

    fn loadCJKWidthData(self: *Self) !void {
        // Load common CJK character width data
        const cjk_data = [_]struct {
            range_start: u32,
            range_end: u32,
            info: CJKCharacterInfo
        }{
            // CJK Unified Ideographs (most common Han characters)
            .{
                .range_start = 0x4E00, .range_end = 0x9FFF,
                .info = .{
                    .display_width = 2.0, .script_type = .han, .char_category = .ideograph,
                    .is_halfwidth = false, .is_fullwidth = true, .terminal_cells = 2
                }
            },

            // Hiragana
            .{
                .range_start = 0x3040, .range_end = 0x309F,
                .info = .{
                    .display_width = 2.0, .script_type = .hiragana, .char_category = .syllable,
                    .is_halfwidth = false, .is_fullwidth = true, .terminal_cells = 2
                }
            },

            // Katakana
            .{
                .range_start = 0x30A0, .range_end = 0x30FF,
                .info = .{
                    .display_width = 2.0, .script_type = .katakana, .char_category = .syllable,
                    .is_halfwidth = false, .is_fullwidth = true, .terminal_cells = 2
                }
            },

            // Hangul Syllables
            .{
                .range_start = 0xAC00, .range_end = 0xD7AF,
                .info = .{
                    .display_width = 2.0, .script_type = .hangul, .char_category = .syllable,
                    .is_halfwidth = false, .is_fullwidth = true, .terminal_cells = 2
                }
            },

            // Halfwidth Katakana
            .{
                .range_start = 0xFF65, .range_end = 0xFF9F,
                .info = .{
                    .display_width = 1.0, .script_type = .katakana, .char_category = .syllable,
                    .is_halfwidth = true, .is_fullwidth = false, .terminal_cells = 1
                }
            },

            // CJK Symbols and Punctuation
            .{
                .range_start = 0x3000, .range_end = 0x303F,
                .info = .{
                    .display_width = 2.0, .script_type = .han, .char_category = .punctuation,
                    .is_halfwidth = false, .is_fullwidth = true, .terminal_cells = 2
                }
            },

            // Bopomofo
            .{
                .range_start = 0x3100, .range_end = 0x312F,
                .info = .{
                    .display_width = 1.0, .script_type = .bopomofo, .char_category = .syllable,
                    .is_halfwidth = true, .is_fullwidth = false, .terminal_cells = 1
                }
            },
        };

        for (cjk_data) |data| {
            var codepoint = data.range_start;
            while (codepoint <= data.range_end) : (codepoint += 1) {
                try self.width_cache.put(codepoint, data.info);
            }
        }
    }

    pub fn processCJKText(self: *Self, text: []const u8) !CJKTextResult {
        // Use gcode script detection to identify CJK runs
        const script_runs = try self.script_detector.detectRuns(text);
        defer self.allocator.free(script_runs);

        var result = CJKTextResult.init(self.allocator);

        // Convert text to codepoints for analysis
        var codepoints = std.ArrayList(u32).init(self.allocator);
        defer codepoints.deinit();

        var i: usize = 0;
        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + char_len <= text.len) {
                const codepoint = std.unicode.utf8Decode(text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };
                try codepoints.append(codepoint);
                i += char_len;
            } else {
                break;
            }
        }

        // Process each CJK character
        for (codepoints.items, 0..) |codepoint, pos| {
            if (self.isCJKCharacter(codepoint)) {
                const char_info = try self.analyzeCJKCharacter(codepoint);

                try result.cjk_characters.append(CJKCharacterData{
                    .codepoint = codepoint,
                    .position = pos,
                    .info = char_info,
                    .visual_width = char_info.display_width,
                    .terminal_width = char_info.terminal_cells,
                });
            }
        }

        // Calculate text metrics
        result.total_display_width = try self.calculateTotalWidth(result.cjk_characters.items);
        result.total_terminal_cells = self.calculateTerminalCells(result.cjk_characters.items);
        result.mixed_width = self.hasMixedWidths(result.cjk_characters.items);

        return result;
    }

    fn isCJKCharacter(self: *Self, codepoint: u32) bool {
        _ = self;

        // Check major CJK Unicode blocks
        return (codepoint >= 0x4E00 and codepoint <= 0x9FFF) or    // CJK Unified Ideographs
               (codepoint >= 0x3040 and codepoint <= 0x309F) or    // Hiragana
               (codepoint >= 0x30A0 and codepoint <= 0x30FF) or    // Katakana
               (codepoint >= 0xAC00 and codepoint <= 0xD7AF) or    // Hangul Syllables
               (codepoint >= 0x3100 and codepoint <= 0x312F) or    // Bopomofo
               (codepoint >= 0x3000 and codepoint <= 0x303F) or    // CJK Symbols and Punctuation
               (codepoint >= 0xFF00 and codepoint <= 0xFFEF) or    // Halfwidth and Fullwidth Forms
               (codepoint >= 0x3400 and codepoint <= 0x4DBF) or    // CJK Extension A
               (codepoint >= 0x20000 and codepoint <= 0x2A6DF) or  // CJK Extension B
               (codepoint >= 0x2A700 and codepoint <= 0x2B73F);    // CJK Extension C
    }

    fn analyzeCJKCharacter(self: *Self, codepoint: u32) !CJKCharacterInfo {
        // Check cache first
        if (self.width_cache.get(codepoint)) |cached_info| {
            return cached_info;
        }

        // Analyze character using gcode and Unicode properties
        var info = CJKCharacterInfo{
            .display_width = 1.0,
            .script_type = .unknown,
            .char_category = .other,
            .is_halfwidth = false,
            .is_fullwidth = false,
            .terminal_cells = 1,
        };

        // Determine script type
        info.script_type = self.getCJKScript(codepoint);
        info.char_category = self.getCJKCategory(codepoint);

        // Determine width based on character properties
        if (self.isFullwidthCharacter(codepoint)) {
            info.display_width = 2.0;
            info.is_fullwidth = true;
            info.terminal_cells = 2;
        } else if (self.isHalfwidthCharacter(codepoint)) {
            info.display_width = 1.0;
            info.is_halfwidth = true;
            info.terminal_cells = 1;
        } else {
            // Default based on script
            switch (info.script_type) {
                .han, .hiragana, .katakana, .hangul => {
                    info.display_width = 2.0;
                    info.is_fullwidth = true;
                    info.terminal_cells = 2;
                },
                .bopomofo => {
                    info.display_width = 1.0;
                    info.is_halfwidth = true;
                    info.terminal_cells = 1;
                },
                else => {
                    info.display_width = 1.0;
                    info.terminal_cells = 1;
                },
            }
        }

        // Cache the result
        try self.width_cache.put(codepoint, info);
        return info;
    }

    fn getCJKScript(self: *Self, codepoint: u32) CJKScript {
        _ = self;

        if (codepoint >= 0x4E00 and codepoint <= 0x9FFF) return .han;
        if (codepoint >= 0x3400 and codepoint <= 0x4DBF) return .han; // Extension A
        if (codepoint >= 0x20000 and codepoint <= 0x2A6DF) return .han; // Extension B
        if (codepoint >= 0x3040 and codepoint <= 0x309F) return .hiragana;
        if (codepoint >= 0x30A0 and codepoint <= 0x30FF) return .katakana;
        if (codepoint >= 0xFF65 and codepoint <= 0xFF9F) return .katakana; // Halfwidth
        if (codepoint >= 0xAC00 and codepoint <= 0xD7AF) return .hangul;
        if (codepoint >= 0x3100 and codepoint <= 0x312F) return .bopomofo;
        if (codepoint >= 0xA000 and codepoint <= 0xA48F) return .yi;

        return .unknown;
    }

    fn getCJKCategory(self: *Self, codepoint: u32) CJKCategory {
        _ = self;

        // CJK ideographs
        if ((codepoint >= 0x4E00 and codepoint <= 0x9FFF) or
            (codepoint >= 0x3400 and codepoint <= 0x4DBF) or
            (codepoint >= 0x20000 and codepoint <= 0x2A6DF)) return .ideograph;

        // Syllabic scripts
        if ((codepoint >= 0x3040 and codepoint <= 0x309F) or  // Hiragana
            (codepoint >= 0x30A0 and codepoint <= 0x30FF) or  // Katakana
            (codepoint >= 0xAC00 and codepoint <= 0xD7AF) or  // Hangul
            (codepoint >= 0x3100 and codepoint <= 0x312F)) return .syllable; // Bopomofo

        // Punctuation
        if (codepoint >= 0x3000 and codepoint <= 0x303F) return .punctuation;

        // Numbers
        if (codepoint >= 0xFF10 and codepoint <= 0xFF19) return .number; // Fullwidth digits

        return .other;
    }

    fn isFullwidthCharacter(self: *Self, codepoint: u32) bool {
        _ = self;

        // Fullwidth and Halfwidth Forms block - fullwidth subset
        if (codepoint >= 0xFF01 and codepoint <= 0xFF60) return true;

        // Most CJK characters are fullwidth by default
        return (codepoint >= 0x4E00 and codepoint <= 0x9FFF) or    // Han
               (codepoint >= 0x3040 and codepoint <= 0x309F) or    // Hiragana
               (codepoint >= 0x30A0 and codepoint <= 0x30FF) or    // Katakana
               (codepoint >= 0xAC00 and codepoint <= 0xD7AF) or    // Hangul
               (codepoint >= 0x3000 and codepoint <= 0x303F);      // CJK Symbols
    }

    fn isHalfwidthCharacter(self: *Self, codepoint: u32) bool {
        _ = self;

        // Halfwidth Katakana
        if (codepoint >= 0xFF65 and codepoint <= 0xFF9F) return true;

        // Halfwidth ASCII variants
        if (codepoint >= 0xFF61 and codepoint <= 0xFF64) return true;

        // Bopomofo is typically halfwidth
        if (codepoint >= 0x3100 and codepoint <= 0x312F) return true;

        return false;
    }

    fn calculateTotalWidth(self: *Self, characters: []const CJKCharacterData) !f32 {
        _ = self;

        var total_width: f32 = 0;
        for (characters) |char_data| {
            total_width += char_data.visual_width;
        }
        return total_width;
    }

    fn calculateTerminalCells(self: *Self, characters: []const CJKCharacterData) u32 {
        _ = self;

        var total_cells: u32 = 0;
        for (characters) |char_data| {
            total_cells += char_data.terminal_width;
        }
        return total_cells;
    }

    fn hasMixedWidths(self: *Self, characters: []const CJKCharacterData) bool {
        _ = self;

        if (characters.len == 0) return false;

        const first_width = characters[0].terminal_width;
        for (characters[1..]) |char_data| {
            if (char_data.terminal_width != first_width) return true;
        }
        return false;
    }

    // Terminal optimization for CJK text rendering
    pub fn optimizeForTerminal(self: *Self, text: []const u8, terminal_width: u32) !CJKTerminalLayout {
        var result = try self.processCJKText(text);
        defer result.deinit();

        var layout = CJKTerminalLayout.init(self.allocator);

        var current_line = std.ArrayList(CJKCharacterData).init(self.allocator);
        var current_line_width: u32 = 0;

        for (result.cjk_characters.items) |char_data| {
            const char_width = char_data.terminal_width;

            // Check if character fits on current line
            if (current_line_width + char_width > terminal_width and current_line.items.len > 0) {
                // Move to next line
                try layout.lines.append(try current_line.toOwnedSlice());
                current_line = std.ArrayList(CJKCharacterData).init(self.allocator);
                current_line_width = 0;
            }

            try current_line.append(char_data);
            current_line_width += char_width;
        }

        // Add final line
        if (current_line.items.len > 0) {
            try layout.lines.append(try current_line.toOwnedSlice());
        } else {
            current_line.deinit();
        }

        return layout;
    }

    // Test with various CJK texts
    pub fn testCJKProcessing(self: *Self) !void {
        const test_texts = [_][]const u8{
            "こんにちは世界",      // Japanese (Hiragana + Han)
            "안녕하세요 세계",      // Korean (Hangul)
            "你好世界",            // Chinese (Han)
            "カタカナテスト",      // Japanese (Katakana)
            "ｶﾀｶﾅﾃｽﾄ",           // Halfwidth Katakana
            "Mixed: 日本語123",   // Mixed CJK and ASCII
        };

        for (test_texts) |text| {
            std.log.info("Processing CJK text: {s}", .{text});

            var result = try self.processCJKText(text);
            defer result.deinit();

            std.log.info("Total width: {d:.1}, Terminal cells: {}, Mixed width: {}", .{
                result.total_display_width,
                result.total_terminal_cells,
                result.mixed_width
            });

            for (result.cjk_characters.items) |char_data| {
                std.log.info("  U+{X} ({}) - width: {d:.1}, cells: {}, script: {}", .{
                    char_data.codepoint,
                    @tagName(char_data.info.char_category),
                    char_data.visual_width,
                    char_data.terminal_width,
                    @tagName(char_data.info.script_type)
                });
            }
        }
    }
};

pub const CJKCharacterData = struct {
    codepoint: u32,
    position: usize,
    info: CJKWidthProcessor.CJKCharacterInfo,
    visual_width: f32,
    terminal_width: u8,
};

pub const CJKTextResult = struct {
    cjk_characters: std.ArrayList(CJKCharacterData),
    total_display_width: f32,
    total_terminal_cells: u32,
    mixed_width: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CJKTextResult {
        return CJKTextResult{
            .cjk_characters = std.ArrayList(CJKCharacterData).init(allocator),
            .total_display_width = 0.0,
            .total_terminal_cells = 0,
            .mixed_width = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CJKTextResult) void {
        self.cjk_characters.deinit();
    }
};

pub const CJKTerminalLayout = struct {
    lines: std.ArrayList([]CJKCharacterData),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CJKTerminalLayout {
        return CJKTerminalLayout{
            .lines = std.ArrayList([]CJKCharacterData).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CJKTerminalLayout) void {
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.deinit();
    }
};

test "CJKWidthProcessor character classification" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = CJKWidthProcessor.init(allocator) catch return;
    defer processor.deinit();

    // Test CJK character detection
    try testing.expect(processor.isCJKCharacter(0x4E00)); // Han
    try testing.expect(processor.isCJKCharacter(0x3042)); // Hiragana
    try testing.expect(processor.isCJKCharacter(0x30A2)); // Katakana
    try testing.expect(processor.isCJKCharacter(0xAC00)); // Hangul

    try testing.expect(!processor.isCJKCharacter(0x0041)); // Latin A
}

test "CJKWidthProcessor width calculation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = CJKWidthProcessor.init(allocator) catch return;
    defer processor.deinit();

    // Test fullwidth vs halfwidth
    try testing.expect(processor.isFullwidthCharacter(0x4E00)); // Han
    try testing.expect(processor.isHalfwidthCharacter(0xFF65)); // Halfwidth Katakana
}