const std = @import("std");
const root = @import("root.zig");
const gcode_integration = @import("gcode_integration.zig");
const gcode = @import("gcode");

// Advanced script processing using real gcode v0.1.5 APIs.
//
// gcode operates on Unicode codepoints (`[]const u32`) while this module's
// public surface accepts UTF-8 (`[]const u8`). Each entry point decodes the
// incoming text into a codepoint array and, where byte slices of the original
// text are emitted, keeps a parallel byte-offset table so codepoint indices
// returned by gcode can be mapped back to byte ranges.
pub const AdvancedScriptProcessor = struct {
    allocator: std.mem.Allocator,
    bidi_engine: gcode.BiDi,
    script_detector: gcode.ScriptDetector,
    complex_analyzer: gcode.ComplexScriptAnalyzer,

    const Self = @This();

    /// Decoded view of a UTF-8 string: the codepoints plus a byte-offset table.
    /// `offsets` has `cps.len + 1` entries; `offsets[i]` is the byte offset of
    /// codepoint `i` and `offsets[len]` is the total byte length, so any
    /// codepoint range `[a, b)` maps to the byte slice `text[offsets[a]..offsets[b]]`.
    const Decoded = struct {
        cps: []u32,
        offsets: []usize,
        allocator: std.mem.Allocator,

        fn deinit(self: *Decoded) void {
            self.allocator.free(self.cps);
            self.allocator.free(self.offsets);
        }
    };

    fn decode(allocator: std.mem.Allocator, text: []const u8) !Decoded {
        var cps = std.ArrayList(u32).empty;
        errdefer cps.deinit(allocator);
        var offsets = std.ArrayList(usize).empty;
        errdefer offsets.deinit(allocator);

        var idx: usize = 0;
        while (idx < text.len) {
            const len = std.unicode.utf8ByteSequenceLength(text[idx]) catch 1;
            const end = @min(idx + len, text.len);
            const cp = std.unicode.utf8Decode(text[idx..end]) catch text[idx];
            try offsets.append(allocator, idx);
            try cps.append(allocator, cp);
            idx = end;
        }
        try offsets.append(allocator, text.len);

        return Decoded{
            .cps = try cps.toOwnedSlice(allocator),
            .offsets = try offsets.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .bidi_engine = gcode.BiDi.init(allocator),
            .script_detector = gcode.ScriptDetector.init(allocator),
            .complex_analyzer = gcode.ComplexScriptAnalyzer.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    // Real BiDi processing using gcode's algorithm.
    pub fn processBiDiText(self: *Self, text: []const u8, base_direction: ?BiDiDirection) !BiDiResult {
        const direction = base_direction orelse .auto;

        var decoded = try decode(self.allocator, text);
        defer decoded.deinit();

        // gcode v0.1.5 has no explicit "auto"; resolve it via getBaseDirection.
        const gcode_dir: gcode.Direction = switch (direction) {
            .auto => self.bidi_engine.getBaseDirection(decoded.cps),
            .ltr => .LTR,
            .rtl => .RTL,
        };

        const runs = try self.bidi_engine.processText(decoded.cps, gcode_dir);
        defer self.allocator.free(runs);

        var result = BiDiResult.init(self.allocator);
        errdefer result.deinit();

        for (runs, 0..) |run, visual_index| {
            const byte_start = decoded.offsets[run.start];
            const byte_end = decoded.offsets[run.end()];
            try result.runs.append(self.allocator, BiDiRun{
                .text = text[byte_start..byte_end],
                .start = run.start,
                .length = run.length,
                .level = run.level,
                .direction = if (run.isRTL()) .rtl else .ltr,
                // gcode.Run carries no visual_order; runs are returned in visual
                // order, so the sequential index serves the same purpose.
                .visual_order = visual_index,
            });
        }

        return result;
    }

    // Real script detection using gcode.
    pub fn detectScriptRuns(self: *Self, text: []const u8) ![]ScriptRun {
        var decoded = try decode(self.allocator, text);
        defer decoded.deinit();

        const runs = try self.script_detector.detectRuns(decoded.cps);
        defer self.allocator.free(runs);

        var result = std.ArrayList(ScriptRun).empty;
        errdefer result.deinit(self.allocator);

        for (runs) |run| {
            const category = gcode.ComplexScriptCategory.fromScript(run.script);
            const script_info = ScriptInfo{
                .script = convertGcodeScript(run.script),
                // gcode.ScriptRun exposes no confidence metric; detection is
                // deterministic, so report full confidence.
                .confidence = 1.0,
                .requires_complex_shaping = category != .simple,
                .requires_bidi = run.script.isRTL(),
                .writing_direction = if (run.script.isRTL()) .rtl else .ltr,
                // gcode does not surface per-run ligature sets; callers that
                // need ligatures resolve them from font tables.
                .common_ligatures = &[_]u32{},
            };

            const byte_start = decoded.offsets[run.start];
            const byte_end = decoded.offsets[run.end()];
            try result.append(self.allocator, ScriptRun{
                .text = text[byte_start..byte_end],
                .start = run.start,
                .length = run.length,
                .script_info = script_info,
            });
        }

        return result.toOwnedSlice(self.allocator);
    }

    // Real complex script analysis using gcode.
    pub fn analyzeComplexScripts(self: *Self, text: []const u8) ![]ComplexScriptAnalysis {
        var decoded = try decode(self.allocator, text);
        defer decoded.deinit();

        const analyses = try self.complex_analyzer.analyzeText(decoded.cps);
        defer self.allocator.free(analyses);

        var result = std.ArrayList(ComplexScriptAnalysis).empty;
        errdefer result.deinit(self.allocator);

        for (analyses, 0..) |analysis, i| {
            const cp = decoded.cps[i];
            const props = gcode.getProperties(@intCast(cp));
            const complex_analysis = ComplexScriptAnalysis{
                // gcode.ComplexScriptAnalysis has no codepoint field; recover it
                // from the input array index.
                .codepoint = cp,
                .script_category = convertScriptCategory(analysis.category),
                .joining_type = if (analysis.joining_type) |jt| convertJoiningType(jt) else .none,
                .arabic_form = if (analysis.arabic_form) |form| convertArabicForm(form) else null,
                .indic_category = if (analysis.indic_category) |cat| convertIndicCategory(cat) else null,
                .display_width = analysis.getDisplayWidth(),
                .combining_class = props.combining_class,
                .is_mark = analysis.is_mark,
                .is_cluster_start = analysis.is_cluster_start,
                .can_break_line = analysis.can_break_line,
            };

            try result.append(self.allocator, complex_analysis);
        }

        return result.toOwnedSlice(self.allocator);
    }

    // Real word boundary detection using gcode (UAX #29).
    //
    // gcode.wordIterator yields plain byte slices without word-type metadata, so
    // byte offsets are tracked manually and the classification is derived from
    // each segment's content.
    pub fn getWordBoundaries(self: *Self, text: []const u8) ![]WordBoundary {
        var boundaries = std.ArrayList(WordBoundary).empty;
        errdefer {
            for (boundaries.items) |*b| self.allocator.free(b.script_runs);
            boundaries.deinit(self.allocator);
        }

        var iter = gcode.wordIterator(text);
        var pos: usize = 0;
        while (iter.next()) |word| {
            const start = pos;
            const end = pos + word.len;
            pos = end;

            const boundary_info = WordBoundary{
                .start = start,
                .end = end,
                .word_type = convertWordType(word),
                .is_emoji_sequence = false,
                .grapheme_count = countGraphemes(word),
                // Word segments returned by gcode are themselves break
                // opportunities at their boundaries.
                .break_opportunity = .allowed,
                .script_runs = try self.getWordScriptRuns(word),
            };

            try boundaries.append(self.allocator, boundary_info);
        }

        return boundaries.toOwnedSlice(self.allocator);
    }

    fn countGraphemes(segment: []const u8) usize {
        var count: usize = 0;
        var it = gcode.graphemeIterator(segment);
        while (it.next()) |_| count += 1;
        return count;
    }

    fn getWordScriptRuns(self: *Self, word: []const u8) ![]u8 {
        var decoded = try decode(self.allocator, word);
        defer decoded.deinit();

        const runs = try self.script_detector.detectRuns(decoded.cps);
        defer self.allocator.free(runs);

        // Simplified - return dominant (first) script name.
        if (runs.len > 0) {
            const script_name = @tagName(runs[0].script);
            return try self.allocator.dupe(u8, script_name);
        }

        return try self.allocator.dupe(u8, "Unknown");
    }

    // Enhanced Arabic contextual analysis.
    pub fn processArabicText(self: *Self, text: []const u8) !ArabicProcessingResult {
        const analyses = try self.analyzeComplexScripts(text);
        defer self.allocator.free(analyses);

        var result = ArabicProcessingResult.init(self.allocator);
        errdefer result.deinit();

        var i: usize = 0;
        for (analyses) |analysis| {
            if (analysis.script_category == .joining) {
                const contextual_form = try self.determineArabicForm(analyses, i);

                try result.contextual_forms.append(self.allocator, ArabicContextualForm{
                    .base_codepoint = analysis.codepoint,
                    .contextual_codepoint = self.getArabicVariant(analysis.codepoint, contextual_form),
                    .form = contextual_form,
                    .position = i,
                    .joins_left = self.joinsLeft(analysis.joining_type),
                    .joins_right = self.joinsRight(analysis.joining_type),
                });

                // Check for ligatures.
                if (i + 1 < analyses.len) {
                    if (self.canFormLigature(analysis.codepoint, analyses[i + 1].codepoint)) |ligature| {
                        try result.ligatures.append(self.allocator, ArabicLigature{
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
        // Arabic contextual forms mapping.
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
            // Add more Arabic characters as needed.
            else => base,
        };
    }

    fn canFormLigature(self: *Self, cp1: u32, cp2: u32) ?u32 {
        _ = self;
        // Common Arabic ligatures.
        return switch ((@as(u64, cp1) << 32) | cp2) {
            (0x0644 << 32) | 0x0627 => 0xFEFB, // LAM + ALEF
            (0x0644 << 32) | 0x0622 => 0xFEF7, // LAM + ALEF WITH MADDA ABOVE
            (0x0644 << 32) | 0x0623 => 0xFEF9, // LAM + ALEF WITH HAMZA ABOVE
            (0x0644 << 32) | 0x0625 => 0xFEF5, // LAM + ALEF WITH HAMZA BELOW
            else => null,
        };
    }

    // Enhanced Indic processing with syllable formation.
    pub fn processIndicText(self: *Self, text: []const u8) !IndicProcessingResult {
        const analyses = try self.analyzeComplexScripts(text);
        defer self.allocator.free(analyses);

        var result = IndicProcessingResult.init(self.allocator);
        errdefer result.deinit();

        // Group into syllables.
        var syllable_start: usize = 0;
        var i: usize = 0;

        while (i < analyses.len) {
            // Find syllable boundary.
            if (self.isIndicSyllableBoundary(analyses, i)) {
                const syllable = try self.processIndicSyllable(analyses[syllable_start..i]);
                try result.syllables.append(self.allocator, syllable);
                syllable_start = i;
            }
            i += 1;
        }

        // Process final syllable.
        if (syllable_start < analyses.len) {
            const syllable = try self.processIndicSyllable(analyses[syllable_start..]);
            try result.syllables.append(self.allocator, syllable);
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
        errdefer result.deinit();

        // Classify syllable components.
        for (syllable, 0..) |analysis, i| {
            const component = IndicSyllableComponent{
                .codepoint = analysis.codepoint,
                .category = analysis.indic_category orelse .combining_mark,
                .position = i,
                .reorder_class = self.getIndicReorderClass(analysis.indic_category orelse .combining_mark),
            };

            try result.components.append(self.allocator, component);
        }

        // Apply Indic reordering rules.
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
        // Sort by reorder class.
        std.mem.sort(IndicSyllableComponent, syllable.components.items, {}, indicReorderCompare);
    }

    fn indicReorderCompare(context: void, a: IndicSyllableComponent, b: IndicSyllableComponent) bool {
        _ = context;
        return a.reorder_class < b.reorder_class;
    }
};

// Enhanced data structures with gcode integration.

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
            .runs = std.ArrayList(BiDiRun).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BiDiResult) void {
        self.runs.deinit(self.allocator);
    }
};

pub const BiDiRun = struct {
    text: []const u8,
    start: usize,
    length: usize,
    level: u8,
    direction: WritingDirection,
    // Sequential position in visual order; gcode returns runs already ordered.
    visual_order: usize,
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
    // gcode's analysis exposes these flags directly; the previous
    // grapheme/word/line-break class bytes have no source in v0.1.5 and were
    // replaced with the real shaping-relevant flags.
    is_mark: bool,
    is_cluster_start: bool,
    can_break_line: bool,
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
            .contextual_forms = std.ArrayList(ArabicContextualForm).empty,
            .ligatures = std.ArrayList(ArabicLigature).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ArabicProcessingResult) void {
        self.contextual_forms.deinit(self.allocator);
        self.ligatures.deinit(self.allocator);
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
            .syllables = std.ArrayList(IndicSyllable).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IndicProcessingResult) void {
        for (self.syllables.items) |*syllable| {
            syllable.deinit();
        }
        self.syllables.deinit(self.allocator);
    }
};

pub const IndicSyllable = struct {
    components: std.ArrayList(IndicSyllableComponent),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) IndicSyllable {
        return IndicSyllable{
            .components = std.ArrayList(IndicSyllableComponent).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IndicSyllable) void {
        self.components.deinit(self.allocator);
    }
};

pub const IndicSyllableComponent = struct {
    codepoint: u32,
    category: IndicCategory,
    position: usize,
    reorder_class: u8,
};

// Enums and type definitions.

pub const ScriptType = enum { latin, arabic, hebrew, devanagari, bengali, tamil, thai, myanmar, khmer, han, hiragana, katakana, hangul, unknown };

pub const WritingDirection = enum { ltr, rtl, ttb };

pub const ScriptCategory = enum { simple, joining, indic, cjk, combining };

pub const JoiningType = enum { none, join_causing, dual_joining, left_joining, right_joining, transparent };

pub const ArabicForm = enum { isolated, initial, medial, final };

pub const IndicCategory = enum { consonant, vowel_independent, vowel_dependent, nukta, virama, combining_mark };

pub const WordType = enum { alphabetic, numeric, punctuation, whitespace, emoji, other };

pub const LineBreakClass = enum { mandatory, allowed, prohibited };

// Conversion functions from gcode types.
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

fn convertScriptCategory(category: gcode.ComplexScriptCategory) ScriptCategory {
    return switch (category) {
        .simple => .simple,
        .joining => .joining,
        .indic => .indic,
        .cjk => .cjk,
        // gcode exposes more categories than zfont; fold the remainder onto the
        // closest zfont concept.
        .southeast_asian => .indic,
        .other_complex => .combining,
    };
}

fn convertJoiningType(joining_type: gcode.ArabicJoiningType) JoiningType {
    return switch (joining_type) {
        .U => .none,
        .C => .join_causing,
        .D => .dual_joining,
        .L => .left_joining,
        .R => .right_joining,
        .T => .transparent,
    };
}

fn convertArabicForm(form: gcode.ArabicForm) ArabicForm {
    return switch (form) {
        .isolated => .isolated,
        .initial => .initial,
        .medial => .medial,
        .final => .final,
    };
}

fn convertIndicCategory(category: gcode.IndicCategory) IndicCategory {
    return switch (category) {
        .consonant,
        .consonant_dead,
        .consonant_with_stacker,
        .consonant_prefixed,
        .consonant_preceding_repha,
        .consonant_succeeding_repha,
        => .consonant,
        .vowel_independent => .vowel_independent,
        .vowel_dependent => .vowel_dependent,
        .nukta => .nukta,
        .virama, .invisible_stacker => .virama,
        else => .combining_mark,
    };
}

// gcode's WordIterator yields plain byte segments without a word-type tag, so
// derive a coarse classification from the segment's leading codepoint.
fn convertWordType(segment: []const u8) WordType {
    if (segment.len == 0) return .other;
    const seq_len = std.unicode.utf8ByteSequenceLength(segment[0]) catch 1;
    const end = @min(seq_len, segment.len);
    const cp = std.unicode.utf8Decode(segment[0..end]) catch return .other;
    if (cp < 0x80) {
        const byte: u8 = @intCast(cp);
        if (std.ascii.isAlphabetic(byte)) return .alphabetic;
        if (std.ascii.isDigit(byte)) return .numeric;
        if (std.ascii.isWhitespace(byte)) return .whitespace;
        return .punctuation;
    }
    return .alphabetic;
}

test "AdvancedScriptProcessor Arabic processing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = AdvancedScriptProcessor.init(allocator) catch return;
    defer processor.deinit();

    const arabic_text = "بسم الله"; // "In the name of Allah"
    var result = processor.processArabicText(arabic_text) catch return;
    defer result.deinit();

    // Should detect contextual forms.
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

    // Should form syllables.
    try testing.expect(result.syllables.items.len > 0);
}
