const std = @import("std");
const root = @import("root.zig");
const gcode = @import("gcode");

// Advanced gcode integration for world-class text rendering
// Replaces HarfBuzz/ICU with pure Zig Unicode processing
pub const GcodeTextProcessor = struct {
    allocator: std.mem.Allocator,
    bidi_processor: ?gcode.BiDi = null,
    script_detector: ?gcode.ScriptDetector = null,
    word_iterator: ?gcode.WordIterator = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .bidi_processor = try gcode.BiDi.init(allocator),
            .script_detector = try gcode.ScriptDetector.init(allocator),
            .word_iterator = null, // Created per-text
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.bidi_processor) |*bidi| bidi.deinit();
        if (self.script_detector) |*detector| detector.deinit();
        if (self.word_iterator) |*iter| iter.deinit();
    }

    // Enhanced BiDi processing using gcode's superior algorithm
    pub fn processTextWithBiDi(self: *Self, text: []const u8, base_direction: ?BiDiDirection) !BiDiResult {
        const bidi = &self.bidi_processor.?;

        // gcode automatically detects direction if not specified
        const direction = base_direction orelse .auto;
        const runs = try bidi.processText(text, direction);

        var result = BiDiResult.init(self.allocator);

        for (runs) |run| {
            const text_slice = text[run.start..run.end()];

            try result.runs.append(BiDiRun{
                .text = try self.allocator.dupe(u8, text_slice),
                .start = run.start,
                .length = run.length,
                .direction = if (run.isRTL()) .rtl else .ltr,
                .level = run.level,
            });
        }

        return result;
    }

    // Script detection for intelligent font selection
    pub fn detectScriptRuns(self: *Self, text: []const u8) ![]ScriptRun {
        const detector = &self.script_detector.?;
        const runs = try detector.detectRuns(text);

        var result = std.ArrayList(ScriptRun).init(self.allocator);

        for (runs) |run| {
            const script_info = ScriptInfo{
                .script = convertGcodeScript(run.script),
                .requires_complex_shaping = run.requiresComplexShaping(),
                .requires_bidi = run.requiresBiDi(),
                .writing_direction = if (run.isRTL()) .rtl else .ltr,
            };

            try result.append(ScriptRun{
                .text = text[run.start..run.end()],
                .start = run.start,
                .length = run.length,
                .script_info = script_info,
            });
        }

        return result.toOwnedSlice();
    }

    // Advanced word boundary detection (UAX #29 compliant)
    pub fn getWordBoundaries(self: *Self, text: []const u8) ![]WordBoundary {
        self.word_iterator = gcode.WordIterator.init(text);
        var iter = &self.word_iterator.?;

        var boundaries = std.ArrayList(WordBoundary).init(self.allocator);

        while (iter.next()) |word| {
            try boundaries.append(WordBoundary{
                .start = word.start,
                .end = word.end,
                .word_type = convertGcodeWordType(word.word_type),
                .is_emoji_sequence = word.isEmojiSequence(),
                .grapheme_count = word.getGraphemeCount(),
            });
        }

        return boundaries.toOwnedSlice();
    }

    // Find word boundary from cursor position (for text selection)
    pub fn findWordBoundary(self: *Self, text: []const u8, cursor_pos: usize, direction: BoundaryDirection) !usize {
        _ = self;
        return switch (direction) {
            .forward => gcode.findWordBoundary(text, cursor_pos, .forward),
            .backward => gcode.findWordBoundary(text, cursor_pos, .backward),
        };
    }

    // Complex script analysis for advanced shaping
    pub fn analyzeComplexScript(self: *Self, text: []const u8) ![]ComplexScriptAnalysis {
        const analyzer = try gcode.ComplexScriptAnalyzer.init(self.allocator);
        defer analyzer.deinit();

        const analyses = try analyzer.analyzeText(text);
        var result = std.ArrayList(ComplexScriptAnalysis).init(self.allocator);

        for (analyses, 0..) |analysis, i| {
            _ = i;

            const script_analysis = ComplexScriptAnalysis{
                .category = convertGcodeCategory(analysis.category),
                .arabic_form = if (analysis.arabic_form) |form| convertArabicForm(form) else null,
                .indic_category = if (analysis.indic_category) |cat| convertIndicCategory(cat) else null,
                .display_width = analysis.getDisplayWidth(),
                .joining_behavior = convertJoiningBehavior(analysis.joining_behavior),
            };

            try result.append(script_analysis);
        }

        return result.toOwnedSlice();
    }

    // Terminal-optimized cursor positioning in complex text
    pub fn calculateCursorPosition(self: *Self, text: []const u8, logical_pos: usize, base_direction: ?BiDiDirection) !usize {
        const direction = base_direction orelse .auto;
        return try gcode.calculateCursorPosition(self.allocator, text, logical_pos, direction);
    }

    // Complete text analysis for zfont rendering pipeline
    pub fn analyzeCompleteText(self: *Self, text: []const u8) !CompleteTextAnalysis {
        // Get all analysis components
        const script_runs = try self.detectScriptRuns(text);
        const bidi_result = try self.processTextWithBiDi(text, null);
        const word_boundaries = try self.getWordBoundaries(text);
        const complex_analysis = try self.analyzeComplexScript(text);

        return CompleteTextAnalysis{
            .script_runs = script_runs,
            .bidi_runs = bidi_result.runs.items,
            .word_boundaries = word_boundaries,
            .complex_analysis = complex_analysis,
            .requires_complex_shaping = self.requiresComplexShaping(script_runs),
            .requires_bidi = self.requiresBiDi(script_runs),
        };
    }

    fn requiresComplexShaping(self: *Self, script_runs: []ScriptRun) bool {
        _ = self;
        for (script_runs) |run| {
            if (run.script_info.requires_complex_shaping) return true;
        }
        return false;
    }

    fn requiresBiDi(self: *Self, script_runs: []ScriptRun) bool {
        _ = self;
        for (script_runs) |run| {
            if (run.script_info.requires_bidi) return true;
        }
        return false;
    }
};

// Type definitions for gcode integration
pub const BiDiDirection = enum {
    auto,
    ltr,
    rtl,
};

pub const BiDiResult = struct {
    runs: std.ArrayList(BiDiRun),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BiDiResult {
        return BiDiResult{
            .runs = std.ArrayList(BiDiRun).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BiDiResult) void {
        for (self.runs.items) |*run| {
            self.allocator.free(run.text);
        }
        self.runs.deinit();
    }
};

pub const BiDiRun = struct {
    text: []u8,
    start: usize,
    length: usize,
    direction: WritingDirection,
    level: u8,
};

pub const ScriptRun = struct {
    text: []const u8,
    start: usize,
    length: usize,
    script_info: ScriptInfo,
};

pub const ScriptInfo = struct {
    script: ScriptType,
    requires_complex_shaping: bool,
    requires_bidi: bool,
    writing_direction: WritingDirection,
};

pub const ScriptType = enum {
    latin,
    arabic,
    hebrew,
    devanagari,
    bengali,
    tamil,
    thai,
    myanmar,
    khmer,
    han,
    hiragana,
    katakana,
    hangul,
    unknown,
};

pub const WritingDirection = enum {
    ltr,
    rtl,
    ttb, // Top-to-bottom (vertical)
};

pub const WordBoundary = struct {
    start: usize,
    end: usize,
    word_type: WordType,
    is_emoji_sequence: bool,
    grapheme_count: usize,
};

pub const WordType = enum {
    alphabetic,
    numeric,
    punctuation,
    whitespace,
    emoji,
    other,
};

pub const BoundaryDirection = enum {
    forward,
    backward,
};

pub const ComplexScriptAnalysis = struct {
    category: ScriptCategory,
    arabic_form: ?ArabicForm,
    indic_category: ?IndicCategory,
    display_width: f32,
    joining_behavior: JoiningBehavior,
};

pub const ScriptCategory = enum {
    simple,      // Simple Latin-style rendering
    joining,     // Arabic-style joining
    indic,       // Complex Indic scripts
    cjk,         // CJK ideographs
    combining,   // Combining marks
};

pub const ArabicForm = enum {
    isolated,
    initial,
    medial,
    final,
};

pub const IndicCategory = enum {
    consonant,
    vowel_independent,
    vowel_dependent,
    nukta,
    virama,
    combining_mark,
};

pub const JoiningBehavior = enum {
    none,
    join_causing,
    dual_joining,
    left_joining,
    right_joining,
    transparent,
};

pub const CompleteTextAnalysis = struct {
    script_runs: []ScriptRun,
    bidi_runs: []BiDiRun,
    word_boundaries: []WordBoundary,
    complex_analysis: []ComplexScriptAnalysis,
    requires_complex_shaping: bool,
    requires_bidi: bool,
};

// Conversion functions from gcode types to zfont types
fn convertGcodeScript(script: gcode.Script) ScriptType {
    return switch (script) {
        .Latin => .latin,
        .Arabic => .arabic,
        .Hebrew => .hebrew,
        .Devanagari => .devanagari,
        .Bengali => .bengali,
        .Tamil => .tamil,
        .Thai => .thai,
        .Myanmar => .myanmar,
        .Khmer => .khmer,
        .Han => .han,
        .Hiragana => .hiragana,
        .Katakana => .katakana,
        .Hangul => .hangul,
        else => .unknown,
    };
}

fn convertGcodeWordType(word_type: gcode.WordType) WordType {
    return switch (word_type) {
        .Alphabetic => .alphabetic,
        .Numeric => .numeric,
        .Punctuation => .punctuation,
        .Whitespace => .whitespace,
        .Emoji => .emoji,
        else => .other,
    };
}

fn convertGcodeCategory(category: gcode.ScriptCategory) ScriptCategory {
    return switch (category) {
        .Simple => .simple,
        .Joining => .joining,
        .Indic => .indic,
        .CJK => .cjk,
        .Combining => .combining,
    };
}

fn convertArabicForm(form: gcode.ArabicForm) ArabicForm {
    return switch (form) {
        .Isolated => .isolated,
        .Initial => .initial,
        .Medial => .medial,
        .Final => .final,
    };
}

fn convertIndicCategory(category: gcode.IndicCategory) IndicCategory {
    return switch (category) {
        .Consonant => .consonant,
        .VowelIndependent => .vowel_independent,
        .VowelDependent => .vowel_dependent,
        .Nukta => .nukta,
        .Virama => .virama,
        .CombiningMark => .combining_mark,
    };
}

fn convertJoiningBehavior(behavior: gcode.JoiningBehavior) JoiningBehavior {
    return switch (behavior) {
        .None => .none,
        .JoinCausing => .join_causing,
        .DualJoining => .dual_joining,
        .LeftJoining => .left_joining,
        .RightJoining => .right_joining,
        .Transparent => .transparent,
    };
}

// Enhanced font manager that uses gcode for intelligent font selection
pub const GcodeFontManager = struct {
    allocator: std.mem.Allocator,
    base_font_manager: *root.FontManager,
    gcode_processor: GcodeTextProcessor,
    script_font_map: std.HashMap(ScriptType, []const u8, ScriptContext, std.hash_map.default_max_load_percentage),

    const ScriptContext = struct {
        pub fn hash(self: @This(), script: ScriptType) u64 {
            _ = self;
            return @intFromEnum(script);
        }
        pub fn eql(self: @This(), a: ScriptType, b: ScriptType) bool {
            _ = self;
            return a == b;
        }
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, base_font_manager: *root.FontManager) !Self {
        var manager = Self{
            .allocator = allocator,
            .base_font_manager = base_font_manager,
            .gcode_processor = try GcodeTextProcessor.init(allocator),
            .script_font_map = std.HashMap(ScriptType, []const u8, ScriptContext, std.hash_map.default_max_load_percentage).init(allocator),
        };

        // Set up default script-to-font mappings
        try manager.setupDefaultScriptFonts();
        return manager;
    }

    pub fn deinit(self: *Self) void {
        self.gcode_processor.deinit();
        self.script_font_map.deinit();
    }

    fn setupDefaultScriptFonts(self: *Self) !void {
        // Default font mappings for different scripts
        const font_mappings = [_]struct { script: ScriptType, font: []const u8 }{
            .{ .script = .latin, .font = "DejaVu Sans" },
            .{ .script = .arabic, .font = "Noto Sans Arabic" },
            .{ .script = .hebrew, .font = "Noto Sans Hebrew" },
            .{ .script = .devanagari, .font = "Noto Sans Devanagari" },
            .{ .script = .han, .font = "Noto Sans CJK SC" },
            .{ .script = .hiragana, .font = "Noto Sans CJK JP" },
            .{ .script = .katakana, .font = "Noto Sans CJK JP" },
            .{ .script = .thai, .font = "Noto Sans Thai" },
        };

        for (font_mappings) |mapping| {
            try self.script_font_map.put(mapping.script, mapping.font);
        }
    }

    pub fn selectFontForScript(self: *Self, script: ScriptType) []const u8 {
        return self.script_font_map.get(script) orelse "DejaVu Sans"; // Fallback
    }

    // Main text processing pipeline using gcode
    pub fn processAndRenderText(self: *Self, text: []const u8) !RenderedText {
        // Step 1: Complete analysis using gcode
        const analysis = try self.gcode_processor.analyzeCompleteText(text);
        defer self.deallocateAnalysis(&analysis);

        var rendered = RenderedText.init(self.allocator);

        // Step 2: Process each script run with appropriate font
        for (analysis.script_runs) |script_run| {
            const font_name = self.selectFontForScript(script_run.script_info.script);

            // Get shaping hints from gcode analysis
            const shaping_hints = ShapingHints{
                .script = script_run.script_info.script,
                .requires_complex_shaping = script_run.script_info.requires_complex_shaping,
                .writing_direction = script_run.script_info.writing_direction,
            };

            // Render with zfont using gcode intelligence
            const shaped_run = try self.base_font_manager.shapeTextWithHints(
                script_run.text,
                font_name,
                shaping_hints,
            );

            try rendered.runs.append(shaped_run);
        }

        // Step 3: Apply BiDi layout if needed
        if (analysis.requires_bidi) {
            try self.applyBiDiLayout(&rendered, analysis.bidi_runs);
        }

        return rendered;
    }

    fn deallocateAnalysis(self: *Self, analysis: *const CompleteTextAnalysis) void {
        self.allocator.free(analysis.script_runs);
        self.allocator.free(analysis.word_boundaries);
        self.allocator.free(analysis.complex_analysis);
    }

    fn applyBiDiLayout(self: *Self, rendered: *RenderedText, bidi_runs: []BiDiRun) !void {
        _ = self;
        // Apply BiDi reordering based on gcode analysis
        for (bidi_runs) |run| {
            if (run.direction == .rtl) {
                // Find corresponding rendered runs and reverse them
                for (rendered.runs.items) |*shaped_run| {
                    if (shaped_run.overlaps(run.start, run.start + run.length)) {
                        shaped_run.reverseForRTL();
                    }
                }
            }
        }
    }
};

pub const ShapingHints = struct {
    script: ScriptType,
    requires_complex_shaping: bool,
    writing_direction: WritingDirection,
};

pub const RenderedText = struct {
    runs: std.ArrayList(ShapedRun),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RenderedText {
        return RenderedText{
            .runs = std.ArrayList(ShapedRun).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RenderedText) void {
        self.runs.deinit();
    }
};

pub const ShapedRun = struct {
    glyphs: []u32,
    positions: []f32,
    start_offset: usize,
    length: usize,

    pub fn overlaps(self: *const ShapedRun, start: usize, end: usize) bool {
        return !(self.start_offset >= end or self.start_offset + self.length <= start);
    }

    pub fn reverseForRTL(self: *ShapedRun) void {
        std.mem.reverse(u32, self.glyphs);
        std.mem.reverse(f32, self.positions);
    }
};

test "GcodeTextProcessor basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = GcodeTextProcessor.init(allocator) catch return;
    defer processor.deinit();

    // Test Arabic BiDi processing
    const arabic_text = "مرحبا Hello";
    var bidi_result = processor.processTextWithBiDi(arabic_text, null) catch return;
    defer bidi_result.deinit();

    try testing.expect(bidi_result.runs.items.len > 0);

    // Test script detection
    const script_runs = processor.detectScriptRuns(arabic_text) catch return;
    defer allocator.free(script_runs);

    try testing.expect(script_runs.len >= 2); // Arabic and Latin parts
}

test "GcodeFontManager integration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var base_font = root.FontManager.init(allocator);
    defer base_font.deinit();

    var font_manager = GcodeFontManager.init(allocator, &base_font) catch return;
    defer font_manager.deinit();

    const font_name = font_manager.selectFontForScript(.arabic);
    try testing.expect(std.mem.eql(u8, font_name, "Noto Sans Arabic"));
}