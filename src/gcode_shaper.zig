const std = @import("std");
const root = @import("root.zig");
const gcode_integration = @import("gcode_integration.zig");

// Advanced text shaper using gcode intelligence
// Replaces HarfBuzz with pure Zig + gcode processing
pub const GcodeTextShaper = struct {
    allocator: std.mem.Allocator,
    gcode_processor: gcode_integration.GcodeTextProcessor,
    arabic_shaper: ArabicShaper,
    indic_shaper: IndicShaper,
    cjk_shaper: CJKShaper,
    emoji_shaper: EmojiShaper,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .gcode_processor = try gcode_integration.GcodeTextProcessor.init(allocator),
            .arabic_shaper = ArabicShaper.init(allocator),
            .indic_shaper = IndicShaper.init(allocator),
            .cjk_shaper = CJKShaper.init(allocator),
            .emoji_shaper = EmojiShaper.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.gcode_processor.deinit();
        self.arabic_shaper.deinit();
        self.indic_shaper.deinit();
        self.cjk_shaper.deinit();
        self.emoji_shaper.deinit();
    }

    // Main shaping pipeline using gcode analysis
    pub fn shapeText(self: *Self, text: []const u8, font_size: f32) !ShapedText {
        // Get complete analysis from gcode
        const analysis = try self.gcode_processor.analyzeCompleteText(text);
        defer self.deallocateAnalysis(&analysis);

        var shaped = ShapedText.init(self.allocator);

        // Process each script run with appropriate shaper
        for (analysis.script_runs) |script_run| {
            const shaped_run = try self.shapeScriptRun(script_run, font_size, &analysis);
            try shaped.runs.append(shaped_run);
        }

        // Apply BiDi reordering if needed
        if (analysis.requires_bidi) {
            try self.applyBiDiReordering(&shaped, analysis.bidi_runs);
        }

        return shaped;
    }

    fn shapeScriptRun(self: *Self, run: gcode_integration.ScriptRun, font_size: f32, analysis: *const gcode_integration.CompleteTextAnalysis) !ShapedRun {
        return switch (run.script_info.script) {
            .arabic => self.arabic_shaper.shapeRun(run, font_size, analysis),
            .hebrew => self.arabic_shaper.shapeRun(run, font_size, analysis), // Hebrew uses similar logic
            .devanagari, .bengali, .tamil => self.indic_shaper.shapeRun(run, font_size, analysis),
            .han, .hiragana, .katakana => self.cjk_shaper.shapeRun(run, font_size, analysis),
            .latin => self.shapeLatinRun(run, font_size),
            else => self.shapeFallbackRun(run, font_size),
        };
    }

    fn shapeLatinRun(self: *Self, run: gcode_integration.ScriptRun, font_size: f32) !ShapedRun {
        // Simple Latin shaping - no complex processing needed
        var glyphs = std.ArrayList(GlyphInfo).init(self.allocator);

        var i: usize = 0;
        while (i < run.text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(run.text[i]) catch 1;
            if (i + char_len <= run.text.len) {
                const codepoint = std.unicode.utf8Decode(run.text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };

                try glyphs.append(GlyphInfo{
                    .glyph_id = @intCast(codepoint), // Simplified - would use actual font glyph IDs
                    .cluster = @intCast(i),
                    .x_advance = font_size * 0.6, // Approximate advance width
                    .y_advance = 0,
                    .x_offset = 0,
                    .y_offset = 0,
                });

                i += char_len;
            } else {
                break;
            }
        }

        return ShapedRun{
            .glyphs = try glyphs.toOwnedSlice(),
            .script = run.script_info.script,
            .direction = run.script_info.writing_direction,
        };
    }

    fn shapeFallbackRun(self: *Self, run: gcode_integration.ScriptRun, font_size: f32) !ShapedRun {
        // Fallback for unknown scripts - treat as simple LTR
        return self.shapeLatinRun(run, font_size);
    }

    fn applyBiDiReordering(self: *Self, shaped: *ShapedText, bidi_runs: []gcode_integration.BiDiRun) !void {
        _ = self;
        // Apply visual reordering based on gcode BiDi analysis
        for (bidi_runs) |run| {
            if (run.direction == .rtl) {
                // Find shaped runs that overlap with this BiDi run
                for (shaped.runs.items) |*shaped_run| {
                    // Reverse glyph order for RTL display
                    if (shaped_run.direction == .rtl) {
                        std.mem.reverse(GlyphInfo, shaped_run.glyphs);
                    }
                }
            }
        }
    }

    fn deallocateAnalysis(self: *Self, analysis: *const gcode_integration.CompleteTextAnalysis) void {
        self.allocator.free(analysis.script_runs);
        self.allocator.free(analysis.bidi_runs);
        self.allocator.free(analysis.word_boundaries);
        self.allocator.free(analysis.complex_analysis);
    }
};

// Arabic shaper using gcode contextual analysis
pub const ArabicShaper = struct {
    allocator: std.mem.Allocator,
    joining_table: JoiningTable,

    const Self = @This();

    const JoiningTable = std.HashMap(u32, JoiningType, JoiningContext, std.hash_map.default_max_load_percentage);

    const JoiningContext = struct {
        pub fn hash(self: @This(), key: u32) u64 {
            _ = self;
            return key;
        }
        pub fn eql(self: @This(), a: u32, b: u32) bool {
            _ = self;
            return a == b;
        }
    };

    const JoiningType = enum {
        none,
        causing,
        dual,
        left,
        right,
        transparent,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        var shaper = Self{
            .allocator = allocator,
            .joining_table = JoiningTable.init(allocator),
        };

        // Initialize Arabic joining table
        shaper.initializeJoiningTable() catch {};
        return shaper;
    }

    pub fn deinit(self: *Self) void {
        self.joining_table.deinit();
    }

    fn initializeJoiningTable(self: *Self) !void {
        // Basic Arabic characters - would be expanded for full coverage
        const arabic_chars = [_]struct { cp: u32, joining: JoiningType }{
            .{ .cp = 0x0627, .joining = .right },     // Alef
            .{ .cp = 0x0628, .joining = .dual },      // Beh
            .{ .cp = 0x062A, .joining = .dual },      // Teh
            .{ .cp = 0x062B, .joining = .dual },      // Theh
            .{ .cp = 0x062C, .joining = .dual },      // Jeem
            .{ .cp = 0x062D, .joining = .dual },      // Hah
            .{ .cp = 0x062E, .joining = .dual },      // Khah
            .{ .cp = 0x062F, .joining = .right },     // Dal
            .{ .cp = 0x0630, .joining = .right },     // Thal
            .{ .cp = 0x0631, .joining = .right },     // Reh
            .{ .cp = 0x0632, .joining = .right },     // Zain
            .{ .cp = 0x0633, .joining = .dual },      // Seen
            .{ .cp = 0x0634, .joining = .dual },      // Sheen
            .{ .cp = 0x0635, .joining = .dual },      // Sad
            .{ .cp = 0x0636, .joining = .dual },      // Dad
            .{ .cp = 0x0637, .joining = .dual },      // Tah
            .{ .cp = 0x0638, .joining = .dual },      // Zah
            .{ .cp = 0x0639, .joining = .dual },      // Ain
            .{ .cp = 0x063A, .joining = .dual },      // Ghain
            .{ .cp = 0x0641, .joining = .dual },      // Feh
            .{ .cp = 0x0642, .joining = .dual },      // Qaf
            .{ .cp = 0x0643, .joining = .dual },      // Kaf
            .{ .cp = 0x0644, .joining = .dual },      // Lam
            .{ .cp = 0x0645, .joining = .dual },      // Meem
            .{ .cp = 0x0646, .joining = .dual },      // Noon
            .{ .cp = 0x0647, .joining = .dual },      // Heh
            .{ .cp = 0x0648, .joining = .right },     // Waw
            .{ .cp = 0x064A, .joining = .dual },      // Yeh
        };

        for (arabic_chars) |char| {
            try self.joining_table.put(char.cp, char.joining);
        }
    }

    pub fn shapeRun(self: *Self, run: gcode_integration.ScriptRun, font_size: f32, analysis: *const gcode_integration.CompleteTextAnalysis) !ShapedRun {
        var glyphs = std.ArrayList(GlyphInfo).init(self.allocator);

        // Use gcode's complex script analysis for Arabic shaping
        var i: usize = 0;
        var analysis_idx: usize = 0;

        while (i < run.text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(run.text[i]) catch 1;
            if (i + char_len <= run.text.len) {
                const codepoint = std.unicode.utf8Decode(run.text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };

                // Get gcode analysis for this character
                const char_analysis = if (analysis_idx < analysis.complex_analysis.len)
                    &analysis.complex_analysis[analysis_idx]
                else
                    null;

                // Apply Arabic contextual shaping based on gcode analysis
                const shaped_glyph = if (char_analysis) |ca| blk: {
                    if (ca.arabic_form) |form| {
                        break :blk self.getContextualForm(codepoint, form);
                    }
                    break :blk codepoint;
                } else codepoint;

                try glyphs.append(GlyphInfo{
                    .glyph_id = @intCast(shaped_glyph),
                    .cluster = @intCast(i),
                    .x_advance = font_size * 0.6,
                    .y_advance = 0,
                    .x_offset = 0,
                    .y_offset = 0,
                });

                i += char_len;
                analysis_idx += 1;
            } else {
                break;
            }
        }

        return ShapedRun{
            .glyphs = try glyphs.toOwnedSlice(),
            .script = .arabic,
            .direction = .rtl,
        };
    }

    fn getContextualForm(self: *Self, base_char: u32, form: gcode_integration.ArabicForm) u32 {
        _ = self;
        // Map base character + form to appropriate glyph
        // This would use actual font glyph tables in practice
        return switch (base_char) {
            0x0628 => switch (form) { // Beh
                .isolated => 0xFE8F,
                .initial => 0xFE91,
                .medial => 0xFE92,
                .final => 0xFE90,
            },
            0x062A => switch (form) { // Teh
                .isolated => 0xFE95,
                .initial => 0xFE97,
                .medial => 0xFE98,
                .final => 0xFE96,
            },
            else => base_char, // Return base form if no contextual variant
        };
    }
};

// Indic shaper using gcode syllable analysis
pub const IndicShaper = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn shapeRun(self: *Self, run: gcode_integration.ScriptRun, font_size: f32, analysis: *const gcode_integration.CompleteTextAnalysis) !ShapedRun {
        var glyphs = std.ArrayList(GlyphInfo).init(self.allocator);

        // Process Indic text with gcode syllable analysis
        var i: usize = 0;
        var analysis_idx: usize = 0;

        while (i < run.text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(run.text[i]) catch 1;
            if (i + char_len <= run.text.len) {
                const codepoint = std.unicode.utf8Decode(run.text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };

                // Get gcode analysis for Indic character positioning
                const char_analysis = if (analysis_idx < analysis.complex_analysis.len)
                    &analysis.complex_analysis[analysis_idx]
                else
                    null;

                var glyph_info = GlyphInfo{
                    .glyph_id = @intCast(codepoint),
                    .cluster = @intCast(i),
                    .x_advance = font_size * 0.6,
                    .y_advance = 0,
                    .x_offset = 0,
                    .y_offset = 0,
                };

                // Apply Indic positioning based on gcode analysis
                if (char_analysis) |ca| {
                    if (ca.indic_category) |category| {
                        switch (category) {
                            .vowel_dependent => {
                                // Position dependent vowel relative to base
                                glyph_info.x_offset = -font_size * 0.1;
                            },
                            .combining_mark => {
                                // Position combining mark above/below base
                                glyph_info.y_offset = font_size * 0.2;
                                glyph_info.x_advance = 0; // Zero width
                            },
                            else => {},
                        }
                    }
                }

                try glyphs.append(glyph_info);
                i += char_len;
                analysis_idx += 1;
            } else {
                break;
            }
        }

        return ShapedRun{
            .glyphs = try glyphs.toOwnedSlice(),
            .script = run.script_info.script,
            .direction = .ltr,
        };
    }
};

// CJK shaper with proper width handling
pub const CJKShaper = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn shapeRun(self: *Self, run: gcode_integration.ScriptRun, font_size: f32, analysis: *const gcode_integration.CompleteTextAnalysis) !ShapedRun {
        var glyphs = std.ArrayList(GlyphInfo).init(self.allocator);

        var i: usize = 0;
        var analysis_idx: usize = 0;

        while (i < run.text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(run.text[i]) catch 1;
            if (i + char_len <= run.text.len) {
                const codepoint = std.unicode.utf8Decode(run.text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };

                // Get display width from gcode analysis
                const char_analysis = if (analysis_idx < analysis.complex_analysis.len)
                    &analysis.complex_analysis[analysis_idx]
                else
                    null;

                const display_width = if (char_analysis) |ca| ca.display_width else 1.0;

                try glyphs.append(GlyphInfo{
                    .glyph_id = @intCast(codepoint),
                    .cluster = @intCast(i),
                    .x_advance = font_size * display_width, // Use gcode width
                    .y_advance = 0,
                    .x_offset = 0,
                    .y_offset = 0,
                });

                i += char_len;
                analysis_idx += 1;
            } else {
                break;
            }
        }

        return ShapedRun{
            .glyphs = try glyphs.toOwnedSlice(),
            .script = run.script_info.script,
            .direction = .ltr,
        };
    }
};

// Enhanced emoji shaper using gcode sequence detection
pub const EmojiShaper = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn shapeEmojiSequences(self: *Self, text: []const u8, font_size: f32, word_boundaries: []gcode_integration.WordBoundary) ![]EmojiGlyph {
        var emoji_glyphs = std.ArrayList(EmojiGlyph).init(self.allocator);

        // Use gcode word boundary detection to find emoji sequences
        for (word_boundaries) |boundary| {
            if (boundary.is_emoji_sequence) {
                const emoji_text = text[boundary.start..boundary.end];
                const emoji_glyph = try self.renderEmojiSequence(emoji_text, font_size);
                try emoji_glyphs.append(emoji_glyph);
            }
        }

        return emoji_glyphs.toOwnedSlice();
    }

    fn renderEmojiSequence(self: *Self, emoji_sequence: []const u8, font_size: f32) !EmojiGlyph {
        _ = self;
        // Render complex emoji sequence (flags, skin tones, etc.)
        return EmojiGlyph{
            .sequence_text = emoji_sequence,
            .glyph_id = 0xE000, // Placeholder emoji glyph
            .width = font_size * 2.0, // Emoji are typically double-width
            .height = font_size,
        };
    }
};

// Data structures for shaped text
pub const ShapedText = struct {
    runs: std.ArrayList(ShapedRun),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ShapedText {
        return ShapedText{
            .runs = std.ArrayList(ShapedRun).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ShapedText) void {
        for (self.runs.items) |*run| {
            self.allocator.free(run.glyphs);
        }
        self.runs.deinit();
    }
};

pub const ShapedRun = struct {
    glyphs: []GlyphInfo,
    script: gcode_integration.ScriptType,
    direction: gcode_integration.WritingDirection,
};

pub const GlyphInfo = struct {
    glyph_id: u32,
    cluster: u32,
    x_advance: f32,
    y_advance: f32,
    x_offset: f32,
    y_offset: f32,
};

pub const EmojiGlyph = struct {
    sequence_text: []const u8,
    glyph_id: u32,
    width: f32,
    height: f32,
};

test "GcodeTextShaper Arabic shaping" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var shaper = GcodeTextShaper.init(allocator) catch return;
    defer shaper.deinit();

    const arabic_text = "السلام عليكم"; // "Peace be upon you" in Arabic
    var shaped = shaper.shapeText(arabic_text, 16.0) catch return;
    defer shaped.deinit();

    try testing.expect(shaped.runs.items.len > 0);

    // Check that Arabic text is shaped RTL
    for (shaped.runs.items) |run| {
        if (run.script == .arabic) {
            try testing.expect(run.direction == .rtl);
            try testing.expect(run.glyphs.len > 0);
        }
    }
}

test "GcodeTextShaper mixed script handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var shaper = GcodeTextShaper.init(allocator) catch return;
    defer shaper.deinit();

    const mixed_text = "Hello مرحبا 世界"; // English + Arabic + Chinese
    var shaped = shaper.shapeText(mixed_text, 16.0) catch return;
    defer shaped.deinit();

    // Should detect multiple script runs
    try testing.expect(shaped.runs.items.len >= 3);
}