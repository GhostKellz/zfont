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
            .bidi_processor = gcode.BiDi.init(allocator),
            .script_detector = gcode.ScriptDetector.init(allocator),
            .word_iterator = null, // Created per-text
        };
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    // Enhanced BiDi processing using gcode's superior algorithm
    pub fn processTextWithBiDi(self: *Self, text: []const u8, base_direction: ?BiDiDirection) !BiDiResult {
        const bidi = &self.bidi_processor.?;

        // Decode UTF-8 into codepoints; gcode processText expects []const u32.
        var codepoints: std.ArrayList(u32) = .empty;
        defer codepoints.deinit(self.allocator);
        {
            var byte_index: usize = 0;
            while (byte_index < text.len) {
                const char_len = std.unicode.utf8ByteSequenceLength(text[byte_index]) catch 1;
                if (byte_index + char_len > text.len) break;
                const cp = std.unicode.utf8Decode(text[byte_index .. byte_index + char_len]) catch {
                    byte_index += 1;
                    continue;
                };
                try codepoints.append(self.allocator, cp);
                byte_index += char_len;
            }
        }

        // Map the zfont direction request onto gcode's Direction; gcode has no
        // explicit "auto", so derive the base direction from the text instead.
        const direction: gcode.Direction = switch (base_direction orelse .auto) {
            .ltr => .LTR,
            .rtl => .RTL,
            .auto => bidi.getBaseDirection(codepoints.items),
        };
        const runs = try bidi.processText(codepoints.items, direction);
        defer self.allocator.free(runs);

        var result = BiDiResult.init(self.allocator);

        for (runs) |run| {
            const text_slice = text[run.start..run.end()];

            try result.runs.append(self.allocator, BiDiRun{
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

        // Decode UTF-8 into codepoints; gcode detectRuns expects []const u32.
        var codepoints: std.ArrayList(u32) = .empty;
        defer codepoints.deinit(self.allocator);
        {
            var byte_index: usize = 0;
            while (byte_index < text.len) {
                const char_len = std.unicode.utf8ByteSequenceLength(text[byte_index]) catch 1;
                if (byte_index + char_len > text.len) break;
                const cp = std.unicode.utf8Decode(text[byte_index .. byte_index + char_len]) catch {
                    byte_index += 1;
                    continue;
                };
                try codepoints.append(self.allocator, cp);
                byte_index += char_len;
            }
        }

        const runs = try detector.detectRuns(codepoints.items);
        defer self.allocator.free(runs);

        var result: std.ArrayList(ScriptRun) = .empty;

        for (runs) |run| {
            const script_info = ScriptInfo{
                .script = convertGcodeScript(run.script),
                .requires_complex_shaping = run.script.requiresComplexShaping(),
                .requires_bidi = run.script.isRTL(),
                .writing_direction = if (run.script.isRTL()) .rtl else .ltr,
            };

            try result.append(self.allocator, ScriptRun{
                .text = text[run.start..run.end()],
                .start = run.start,
                .length = run.length,
                .script_info = script_info,
            });
        }

        return result.toOwnedSlice(self.allocator);
    }

    // Advanced word boundary detection (UAX #29 compliant)
    pub fn getWordBoundaries(self: *Self, text: []const u8) ![]WordBoundary {
        self.word_iterator = gcode.WordIterator.init(text);
        var iter = &self.word_iterator.?;

        var boundaries: std.ArrayList(WordBoundary) = .empty;

        // gcode's WordIterator yields word *segments* ([]const u8); track the
        // running byte offset to recover [start, end) boundaries. The richer
        // per-word metadata (type/emoji/grapheme-count) is not provided by the
        // flat gcode API, so derive a coarse word type and sensible defaults.
        var offset: usize = 0;
        while (iter.next()) |segment| {
            const start = offset;
            const end = offset + segment.len;
            offset = end;

            try boundaries.append(self.allocator, WordBoundary{
                .start = start,
                .end = end,
                .word_type = classifyWordSegment(segment),
                .is_emoji_sequence = segmentIsEmoji(segment),
                .grapheme_count = countGraphemes(segment),
            });
        }

        return boundaries.toOwnedSlice(self.allocator);
    }

    // Find word boundary from cursor position (for text selection).
    // gcode exposes no findWordBoundary; reconstruct boundaries from the
    // segment offsets produced by gcode.wordIterator.
    pub fn findWordBoundary(self: *Self, text: []const u8, cursor_pos: usize, direction: BoundaryDirection) !usize {
        _ = self;
        var iter = gcode.wordIterator(text);
        var offset: usize = 0;

        return switch (direction) {
            .forward => blk: {
                // First segment end strictly after the cursor.
                while (iter.next()) |segment| {
                    const end = offset + segment.len;
                    if (end > cursor_pos) break :blk end;
                    offset = end;
                }
                break :blk text.len;
            },
            .backward => blk: {
                // Last segment start at or before the cursor.
                var boundary: usize = 0;
                while (iter.next()) |segment| {
                    if (offset >= cursor_pos) break;
                    boundary = offset;
                    offset += segment.len;
                }
                break :blk boundary;
            },
        };
    }

    // Complex script analysis for advanced shaping
    pub fn analyzeComplexScript(self: *Self, text: []const u8) ![]ComplexScriptAnalysis {
        const analyzer = gcode.ComplexScriptAnalyzer.init(self.allocator);

        // Decode UTF-8 into codepoints; gcode analyzeText expects []const u32.
        var codepoints: std.ArrayList(u32) = .empty;
        defer codepoints.deinit(self.allocator);
        {
            var byte_index: usize = 0;
            while (byte_index < text.len) {
                const char_len = std.unicode.utf8ByteSequenceLength(text[byte_index]) catch 1;
                if (byte_index + char_len > text.len) break;
                const cp = std.unicode.utf8Decode(text[byte_index .. byte_index + char_len]) catch {
                    byte_index += 1;
                    continue;
                };
                try codepoints.append(self.allocator, cp);
                byte_index += char_len;
            }
        }

        const analyses = try analyzer.analyzeText(codepoints.items);
        defer self.allocator.free(analyses);
        var result: std.ArrayList(ComplexScriptAnalysis) = .empty;

        for (analyses, 0..) |analysis, i| {
            _ = i;

            const script_analysis = ComplexScriptAnalysis{
                .category = convertGcodeCategory(analysis.category),
                .arabic_form = if (analysis.arabic_form) |form| convertArabicForm(form) else null,
                .indic_category = if (analysis.indic_category) |cat| convertIndicCategory(cat) else null,
                .display_width = analysis.getDisplayWidth(),
                .joining_behavior = if (analysis.joining_type) |jt| convertJoiningBehavior(jt) else .none,
            };

            try result.append(self.allocator, script_analysis);
        }

        return result.toOwnedSlice(self.allocator);
    }

    // Terminal-optimized cursor positioning in complex text
    pub fn calculateCursorPosition(self: *Self, text: []const u8, logical_pos: usize, base_direction: ?BiDiDirection) !usize {
        // Decode UTF-8 into codepoints; gcode calculateCursorPosition expects []const u32.
        var codepoints: std.ArrayList(u32) = .empty;
        defer codepoints.deinit(self.allocator);
        {
            var byte_index: usize = 0;
            while (byte_index < text.len) {
                const char_len = std.unicode.utf8ByteSequenceLength(text[byte_index]) catch 1;
                if (byte_index + char_len > text.len) break;
                const cp = std.unicode.utf8Decode(text[byte_index .. byte_index + char_len]) catch {
                    byte_index += 1;
                    continue;
                };
                try codepoints.append(self.allocator, cp);
                byte_index += char_len;
            }
        }

        const direction: gcode.Direction = switch (base_direction orelse .auto) {
            .ltr => .LTR,
            .rtl => .RTL,
            .auto => self.bidi_processor.?.getBaseDirection(codepoints.items),
        };
        return try gcode.calculateCursorPosition(self.allocator, codepoints.items, logical_pos, direction);
    }

    // Complete text analysis for zfont rendering pipeline
    pub fn analyzeCompleteText(self: *Self, text: []const u8) !CompleteTextAnalysis {
        // Get all analysis components
        const script_runs = try self.detectScriptRuns(text);
        var bidi_result = try self.processTextWithBiDi(text, null);
        const word_boundaries = try self.getWordBoundaries(text);
        const complex_analysis = try self.analyzeComplexScript(text);

        // Take ownership of the BiDi runs: `runs.items` aliases the ArrayList's
        // backing buffer (len-sliced, not capacity-sliced), so freeing it later
        // would corrupt the allocator. toOwnedSlice yields a real allocation
        // that deallocateAnalysis can free exactly once. The duped per-run
        // `text` allocations are then owned by CompleteTextAnalysis as well.
        const bidi_runs = try bidi_result.runs.toOwnedSlice(self.allocator);

        return CompleteTextAnalysis{
            .script_runs = script_runs,
            .bidi_runs = bidi_runs,
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
            .runs = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BiDiResult) void {
        for (self.runs.items) |*run| {
            self.allocator.free(run.text);
        }
        self.runs.deinit(self.allocator);
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
    simple, // Simple Latin-style rendering
    joining, // Arabic-style joining
    indic, // Complex Indic scripts
    cjk, // CJK ideographs
    combining, // Combining marks
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

// gcode's WordIterator yields plain byte segments without a word-type tag, so
// derive a coarse classification from the segment's leading codepoint.
fn classifyWordSegment(segment: []const u8) WordType {
    if (segment.len == 0) return .other;
    const cp = std.unicode.utf8Decode(segment[0 .. std.unicode.utf8ByteSequenceLength(segment[0]) catch 1]) catch return .other;
    if (cp < 0x80) {
        const byte: u8 = @intCast(cp);
        if (std.ascii.isAlphabetic(byte)) return .alphabetic;
        if (std.ascii.isDigit(byte)) return .numeric;
        if (std.ascii.isWhitespace(byte)) return .whitespace;
        return .punctuation;
    }
    return .alphabetic;
}

/// True if the segment contains any Extended_Pictographic code point, i.e. it is
/// (part of) an emoji sequence rather than ordinary text.
fn segmentIsEmoji(segment: []const u8) bool {
    var iter = gcode.codePointIterator(segment);
    while (iter.next()) |cp| {
        if (gcode.getProperties(@intCast(cp.code)).grapheme_boundary_class.isExtendedPictographic()) {
            return true;
        }
    }
    return false;
}

/// Count user-perceived grapheme clusters in a UTF-8 segment.
fn countGraphemes(segment: []const u8) usize {
    var iter = gcode.graphemeIterator(segment);
    var count: usize = 0;
    while (iter.next()) |_| count += 1;
    return count;
}

fn convertGcodeCategory(category: gcode.ComplexScriptCategory) ScriptCategory {
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

fn convertJoiningBehavior(behavior: gcode.ArabicJoiningType) JoiningBehavior {
    return switch (behavior) {
        .U => .none,
        .C => .join_causing,
        .D => .dual_joining,
        .L => .left_joining,
        .R => .right_joining,
        .T => .transparent,
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

    // Map a script run's bytes onto glyphs with monospace advances. The hints
    // steer ordering (RTL runs are emitted in visual order) but the per-glyph
    // mapping is a 1:1 codepoint placeholder until a full shaper is wired in.
    fn shapeRun(self: *Self, text: []const u8, font_name: []const u8, hints: ShapingHints) !ShapedRun {
        _ = font_name;

        var glyphs = std.ArrayList(u32).empty;
        errdefer glyphs.deinit(self.allocator);
        var positions = std.ArrayList(f32).empty;
        errdefer positions.deinit(self.allocator);

        var advance: f32 = 0;
        var view = (try std.unicode.Utf8View.init(text)).iterator();
        while (view.nextCodepoint()) |cp| {
            try glyphs.append(self.allocator, cp);
            try positions.append(self.allocator, advance);
            advance += 1.0;
        }

        var run = ShapedRun{
            .glyphs = try glyphs.toOwnedSlice(self.allocator),
            .positions = try positions.toOwnedSlice(self.allocator),
            .start_offset = 0,
            .length = text.len,
        };

        if (hints.writing_direction == .rtl) run.reverseForRTL();
        return run;
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
            const shaped_run = try self.shapeRun(
                script_run.text,
                font_name,
                shaping_hints,
            );

            try rendered.runs.append(self.allocator, shaped_run);
        }

        // Step 3: Apply BiDi layout if needed
        if (analysis.requires_bidi) {
            try self.applyBiDiLayout(&rendered, analysis.bidi_runs);
        }

        return rendered;
    }

    fn deallocateAnalysis(self: *Self, analysis: *const CompleteTextAnalysis) void {
        self.allocator.free(analysis.script_runs);
        // Each BiDiRun owns a duped `text`; free those before the slice itself.
        for (analysis.bidi_runs) |run| self.allocator.free(run.text);
        self.allocator.free(analysis.bidi_runs);
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
            .runs = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RenderedText) void {
        for (self.runs.items) |run| {
            self.allocator.free(run.glyphs);
            self.allocator.free(run.positions);
        }
        self.runs.deinit(self.allocator);
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
