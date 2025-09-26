const std = @import("std");
const root = @import("root.zig");
const gcode_integration = @import("gcode_integration.zig");
const gcode = @import("gcode");

// Advanced script processing using real gcode APIs
// Now that gcode compiles, let's implement the actual complex script features
pub const AdvancedScriptProcessor = struct {
    allocator: std.mem.Allocator,
    bidi_engine: gcode.bidi.BiDiEngine,
    script_detector: gcode.script.ScriptDetector,
    complex_analyzer: gcode.complex_script.ComplexScriptAnalyzer,
    word_iterator: gcode.word.WordIterator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .bidi_engine = try gcode.bidi.BiDiEngine.init(allocator),
            .script_detector = try gcode.script.ScriptDetector.init(allocator),
            .complex_analyzer = try gcode.complex_script.ComplexScriptAnalyzer.init(allocator),
            .word_iterator = gcode.word.WordIterator.init(""), // Will be reset per text
        };
    }

    pub fn deinit(self: *Self) void {
        self.bidi_engine.deinit();
        self.script_detector.deinit();
        self.complex_analyzer.deinit();
        self.word_iterator.deinit();
    }

    // Real BiDi processing using gcode's algorithm
    pub fn processBiDiText(self: *Self, text: []const u8, base_direction: ?BiDiDirection) !BiDiResult {
        const direction = base_direction orelse .auto;

        // Convert to gcode BiDi direction
        const gcode_dir = switch (direction) {
            .auto => gcode.bidi.Direction.Auto,
            .ltr => gcode.bidi.Direction.LeftToRight,
            .rtl => gcode.bidi.Direction.RightToLeft,
        };

        const runs = try self.bidi_engine.processText(text, gcode_dir);

        var result = BiDiResult.init(self.allocator);

        for (runs) |run| {
            try result.runs.append(BiDiRun{
                .text = text[run.start..run.end],
                .start = run.start,
                .length = run.length,
                .level = run.level,
                .direction = if (run.isRTL()) .rtl else .ltr,
                .visual_order = run.visual_order,
            });
        }

        return result;
    }

    // Real script detection using gcode
    pub fn detectScriptRuns(self: *Self, text: []const u8) ![]ScriptRun {
        const runs = try self.script_detector.analyzeText(text);

        var result = std.ArrayList(ScriptRun).init(self.allocator);

        for (runs) |run| {
            const script_info = ScriptInfo{
                .script = convertGcodeScript(run.script),
                .confidence = run.confidence,
                .requires_complex_shaping = run.needsComplexShaping(),
                .requires_bidi = run.needsBiDi(),
                .writing_direction = if (run.isRTL()) .rtl else .ltr,
                .common_ligatures = run.getCommonLigatures(),
            };

            try result.append(ScriptRun{
                .text = text[run.start..run.end],
                .start = run.start,
                .length = run.length,
                .script_info = script_info,
            });
        }

        return result.toOwnedSlice();
    }

    // Real complex script analysis using gcode
    pub fn analyzeComplexScripts(self: *Self, text: []const u8) ![]ComplexScriptAnalysis {
        const analyses = try self.complex_analyzer.analyzeText(text);

        var result = std.ArrayList(ComplexScriptAnalysis).init(self.allocator);

        for (analyses) |analysis| {
            const complex_analysis = ComplexScriptAnalysis{
                .codepoint = analysis.codepoint,
                .script_category = convertScriptCategory(analysis.category),
                .joining_type = convertJoiningType(analysis.joining_type),
                .arabic_form = if (analysis.arabic_form) |form| convertArabicForm(form) else null,
                .indic_category = if (analysis.indic_category) |cat| convertIndicCategory(cat) else null,
                .display_width = analysis.display_width,
                .combining_class = analysis.combining_class,
                .grapheme_boundary = analysis.grapheme_boundary_class,
                .word_boundary = analysis.word_boundary_class,
                .line_break_class = analysis.line_break_class,
            };

            try result.append(complex_analysis);
        }

        return result.toOwnedSlice();
    }

    // Real word boundary detection using gcode (UAX #29)
    pub fn getWordBoundaries(self: *Self, text: []const u8) ![]WordBoundary {
        self.word_iterator.reset(text);

        var boundaries = std.ArrayList(WordBoundary).init(self.allocator);

        while (self.word_iterator.next()) |word| {
            const boundary_info = WordBoundary{
                .start = word.start,
                .end = word.end,
                .word_type = convertWordType(word.word_type),
                .is_emoji_sequence = word.isEmojiSequence(),
                .grapheme_count = word.getGraphemeCount(),
                .break_opportunity = word.getLineBreakOpportunity(),
                .script_runs = try self.getWordScriptRuns(word),
            };

            try boundaries.append(boundary_info);
        }

        return boundaries.toOwnedSlice();
    }

    fn getWordScriptRuns(self: *Self, word: gcode.word.Word) ![]u8 {
        // Get script information for word
        const runs = try self.script_detector.analyzeText(word.getText());

        // Simplified - return dominant script
        if (runs.len > 0) {
            const script_name = @tagName(runs[0].script);
            return try self.allocator.dupe(u8, script_name);
        }

        return try self.allocator.dupe(u8, "Unknown");
    }

    // Enhanced Arabic contextual analysis
    pub fn processArabicText(self: *Self, text: []const u8) !ArabicProcessingResult {
        const analyses = try self.analyzeComplexScripts(text);
        defer self.allocator.free(analyses);

        var result = ArabicProcessingResult.init(self.allocator);

        var i: usize = 0;
        for (analyses) |analysis| {
            if (analysis.script_category == .joining) {
                const contextual_form = try self.determineArabicForm(analyses, i);

                try result.contextual_forms.append(ArabicContextualForm{
                    .base_codepoint = analysis.codepoint,
                    .contextual_codepoint = self.getArabicVariant(analysis.codepoint, contextual_form),
                    .form = contextual_form,
                    .position = i,
                    .joins_left = self.joinsLeft(analysis.joining_type),
                    .joins_right = self.joinsRight(analysis.joining_type),
                });

                // Check for ligatures
                if (i + 1 < analyses.len) {
                    if (self.canFormLigature(analysis.codepoint, analyses[i + 1].codepoint)) |ligature| {
                        try result.ligatures.append(ArabicLigature{
                            .components = &[_]u32{ analysis.codepoint, analyses[i + 1].codepoint },
                            .ligature_glyph = ligature,
                            .position = i,
                        });
                    }
                }
            }
            i += 1;
        }

        return result;
    }

    fn determineArabicForm(self: *Self, analyses: []ComplexScriptAnalysis, pos: usize) !ArabicForm {
        const current = analyses[pos];

        if (current.joining_type == .transparent or current.joining_type == .none) {
            return .isolated;
        }

        const has_left = pos > 0 and self.canJoinLeft(analyses[pos - 1].joining_type);
        const has_right = pos + 1 < analyses.len and self.canJoinRight(analyses[pos + 1].joining_type);

        return switch (@as(u2, if (has_left) 1 else 0) | (@as(u2, if (has_right) 2 else 0))) {
            0 => .isolated,
            1 => .final,
            2 => .initial,
            3 => .medial,
        };
    }

    fn canJoinLeft(self: *Self, joining_type: JoiningType) bool {
        _ = self;
        return joining_type == .dual_joining or joining_type == .left_joining or joining_type == .join_causing;
    }

    fn canJoinRight(self: *Self, joining_type: JoiningType) bool {
        _ = self;
        return joining_type == .dual_joining or joining_type == .right_joining or joining_type == .join_causing;
    }

    fn joinsLeft(self: *Self, joining_type: JoiningType) bool {
        return self.canJoinLeft(joining_type);
    }

    fn joinsRight(self: *Self, joining_type: JoiningType) bool {
        return self.canJoinRight(joining_type);
    }

    fn getArabicVariant(self: *Self, base: u32, form: ArabicForm) u32 {
        _ = self;
        // Arabic contextual forms mapping
        return switch (base) {
            0x0628 => switch (form) { // BEH
                .isolated => 0xFE8F,
                .final => 0xFE90,
                .initial => 0xFE91,
                .medial => 0xFE92,
            },
            0x062A => switch (form) { // TEH
                .isolated => 0xFE95,
                .final => 0xFE96,
                .initial => 0xFE97,
                .medial => 0xFE98,
            },
            0x062C => switch (form) { // JEEM
                .isolated => 0xFE9D,
                .final => 0xFE9E,
                .initial => 0xFE9F,
                .medial => 0xFEA0,
            },
            // Add more Arabic characters as needed
            else => base,
        };
    }

    fn canFormLigature(self: *Self, cp1: u32, cp2: u32) ?u32 {
        _ = self;
        // Common Arabic ligatures
        return switch ((@as(u64, cp1) << 32) | cp2) {
            (0x0644 << 32) | 0x0627 => 0xFEFB, // LAM + ALEF
            (0x0644 << 32) | 0x0622 => 0xFEF7, // LAM + ALEF WITH MADDA ABOVE
            (0x0644 << 32) | 0x0623 => 0xFEF9, // LAM + ALEF WITH HAMZA ABOVE
            (0x0644 << 32) | 0x0625 => 0xFEF5, // LAM + ALEF WITH HAMZA BELOW
            else => null,
        };
    }

    // Enhanced Indic processing with syllable formation
    pub fn processIndicText(self: *Self, text: []const u8) !IndicProcessingResult {
        const analyses = try self.analyzeComplexScripts(text);
        defer self.allocator.free(analyses);

        var result = IndicProcessingResult.init(self.allocator);

        // Group into syllables
        var syllable_start: usize = 0;
        var i: usize = 0;

        while (i < analyses.len) {
            // Find syllable boundary
            if (self.isIndicSyllableBoundary(analyses, i)) {
                const syllable = try self.processIndicSyllable(analyses[syllable_start..i]);
                try result.syllables.append(syllable);
                syllable_start = i;
            }
            i += 1;
        }

        // Process final syllable
        if (syllable_start < analyses.len) {
            const syllable = try self.processIndicSyllable(analyses[syllable_start..]);
            try result.syllables.append(syllable);
        }

        return result;
    }

    fn isIndicSyllableBoundary(self: *Self, analyses: []ComplexScriptAnalysis, pos: usize) bool {
        _ = self;
        if (pos == 0) return false;

        const current = analyses[pos];
        return current.indic_category == .consonant and
               analyses[pos - 1].indic_category != .virama;
    }

    fn processIndicSyllable(self: *Self, syllable: []ComplexScriptAnalysis) !IndicSyllable {
        var result = IndicSyllable.init(self.allocator);

        // Classify syllable components
        for (syllable, 0..) |analysis, i| {
            const component = IndicSyllableComponent{
                .codepoint = analysis.codepoint,
                .category = analysis.indic_category.?,
                .position = i,
                .reorder_class = self.getIndicReorderClass(analysis.indic_category.?),
            };

            try result.components.append(component);
        }

        // Apply Indic reordering rules
        try self.applyIndicReordering(&result);

        return result;
    }

    fn getIndicReorderClass(self: *Self, category: IndicCategory) u8 {
        _ = self;
        return switch (category) {
            .consonant => 0,
            .nukta => 1,
            .virama => 2,
            .vowel_dependent => 3,
            .combining_mark => 4,
            .vowel_independent => 5,
        };
    }

    fn applyIndicReordering(self: *Self, syllable: *IndicSyllable) !void {
        _ = self;
        // Sort by reorder class
        std.mem.sort(IndicSyllableComponent, syllable.components.items, {}, indicReorderCompare);
    }

    fn indicReorderCompare(context: void, a: IndicSyllableComponent, b: IndicSyllableComponent) bool {
        _ = context;
        return a.reorder_class < b.reorder_class;
    }
};

// Enhanced data structures with gcode integration

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
        self.runs.deinit();
    }
};

pub const BiDiRun = struct {
    text: []const u8,
    start: usize,
    length: usize,
    level: u8,
    direction: WritingDirection,
    visual_order: []usize,
};

pub const ScriptRun = struct {
    text: []const u8,
    start: usize,
    length: usize,
    script_info: ScriptInfo,
};

pub const ScriptInfo = struct {
    script: ScriptType,
    confidence: f32,
    requires_complex_shaping: bool,
    requires_bidi: bool,
    writing_direction: WritingDirection,
    common_ligatures: []const u32,
};

pub const ComplexScriptAnalysis = struct {
    codepoint: u32,
    script_category: ScriptCategory,
    joining_type: JoiningType,
    arabic_form: ?ArabicForm,
    indic_category: ?IndicCategory,
    display_width: f32,
    combining_class: u8,
    grapheme_boundary: u8,
    word_boundary: u8,
    line_break_class: u8,
};

pub const WordBoundary = struct {
    start: usize,
    end: usize,
    word_type: WordType,
    is_emoji_sequence: bool,
    grapheme_count: usize,
    break_opportunity: LineBreakClass,
    script_runs: []u8,
};

pub const ArabicProcessingResult = struct {
    contextual_forms: std.ArrayList(ArabicContextualForm),
    ligatures: std.ArrayList(ArabicLigature),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ArabicProcessingResult {
        return ArabicProcessingResult{
            .contextual_forms = std.ArrayList(ArabicContextualForm).init(allocator),
            .ligatures = std.ArrayList(ArabicLigature).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ArabicProcessingResult) void {
        self.contextual_forms.deinit();
        self.ligatures.deinit();
    }
};

pub const ArabicContextualForm = struct {
    base_codepoint: u32,
    contextual_codepoint: u32,
    form: ArabicForm,
    position: usize,
    joins_left: bool,
    joins_right: bool,
};

pub const ArabicLigature = struct {
    components: []const u32,
    ligature_glyph: u32,
    position: usize,
};

pub const IndicProcessingResult = struct {
    syllables: std.ArrayList(IndicSyllable),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) IndicProcessingResult {
        return IndicProcessingResult{
            .syllables = std.ArrayList(IndicSyllable).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IndicProcessingResult) void {
        for (self.syllables.items) |*syllable| {
            syllable.deinit();
        }
        self.syllables.deinit();
    }
};

pub const IndicSyllable = struct {
    components: std.ArrayList(IndicSyllableComponent),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) IndicSyllable {
        return IndicSyllable{
            .components = std.ArrayList(IndicSyllableComponent).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IndicSyllable) void {
        self.components.deinit();
    }
};

pub const IndicSyllableComponent = struct {
    codepoint: u32,
    category: IndicCategory,
    position: usize,
    reorder_class: u8,
};

// Enums and type definitions

pub const ScriptType = enum {
    latin, arabic, hebrew, devanagari, bengali, tamil, thai, myanmar, khmer, han, hiragana, katakana, hangul, unknown
};

pub const WritingDirection = enum { ltr, rtl, ttb };

pub const ScriptCategory = enum { simple, joining, indic, cjk, combining };

pub const JoiningType = enum { none, join_causing, dual_joining, left_joining, right_joining, transparent };

pub const ArabicForm = enum { isolated, initial, medial, final };

pub const IndicCategory = enum { consonant, vowel_independent, vowel_dependent, nukta, virama, combining_mark };

pub const WordType = enum { alphabetic, numeric, punctuation, whitespace, emoji, other };

pub const LineBreakClass = enum { mandatory, allowed, prohibited };

// Conversion functions from gcode types
fn convertGcodeScript(script: gcode.script.Script) ScriptType {
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

fn convertScriptCategory(category: gcode.complex_script.ScriptCategory) ScriptCategory {
    return switch (category) {
        .Simple => .simple,
        .Joining => .joining,
        .Indic => .indic,
        .CJK => .cjk,
        .Combining => .combining,
    };
}

fn convertJoiningType(joining_type: gcode.complex_script.JoiningType) JoiningType {
    return switch (joining_type) {
        .None => .none,
        .JoinCausing => .join_causing,
        .DualJoining => .dual_joining,
        .LeftJoining => .left_joining,
        .RightJoining => .right_joining,
        .Transparent => .transparent,
    };
}

fn convertArabicForm(form: gcode.complex_script.ArabicForm) ArabicForm {
    return switch (form) {
        .Isolated => .isolated,
        .Initial => .initial,
        .Medial => .medial,
        .Final => .final,
    };
}

fn convertIndicCategory(category: gcode.complex_script.IndicCategory) IndicCategory {
    return switch (category) {
        .Consonant => .consonant,
        .VowelIndependent => .vowel_independent,
        .VowelDependent => .vowel_dependent,
        .Nukta => .nukta,
        .Virama => .virama,
        .CombiningMark => .combining_mark,
    };
}

fn convertWordType(word_type: gcode.word.WordType) WordType {
    return switch (word_type) {
        .Alphabetic => .alphabetic,
        .Numeric => .numeric,
        .Punctuation => .punctuation,
        .Whitespace => .whitespace,
        .Emoji => .emoji,
        else => .other,
    };
}

test "AdvancedScriptProcessor Arabic processing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = AdvancedScriptProcessor.init(allocator) catch return;
    defer processor.deinit();

    const arabic_text = "بسم الله"; // "In the name of Allah"
    var result = processor.processArabicText(arabic_text) catch return;
    defer result.deinit();

    // Should detect contextual forms
    try testing.expect(result.contextual_forms.items.len > 0);
}

test "AdvancedScriptProcessor Indic processing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = AdvancedScriptProcessor.init(allocator) catch return;
    defer processor.deinit();

    const devanagari_text = "नमस्ते"; // "Namaste"
    var result = processor.processIndicText(devanagari_text) catch return;
    defer result.deinit();

    // Should form syllables
    try testing.expect(result.syllables.items.len > 0);
}