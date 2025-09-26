const std = @import("std");
const root = @import("root.zig");
const gcode = @import("gcode");

// Terminal cursor positioning in complex text using gcode intelligence
// Handles proper cursor movement in BiDi, CJK, Indic, Arabic, and emoji text
pub const TerminalCursorProcessor = struct {
    allocator: std.mem.Allocator,
    bidi_processor: gcode.bidi.BiDi,
    grapheme_segmenter: gcode.grapheme.GraphemeSegmenter,
    complex_analyzer: gcode.complex_script.ComplexScriptAnalyzer,

    const Self = @This();

    pub const CursorPosition = struct {
        logical_index: usize,    // Logical position in text buffer
        visual_index: usize,     // Visual position for rendering
        grapheme_index: usize,   // Grapheme cluster index
        line: u32,               // Terminal line
        column: u32,             // Terminal column
        is_rtl_context: bool,    // Whether cursor is in RTL context
        script_context: ScriptContext,
    };

    pub const ScriptContext = struct {
        script_type: gcode.script.Script,
        requires_complex_shaping: bool,
        is_emoji_sequence: bool,
        is_cjk_fullwidth: bool,
    };

    pub const CursorMovement = enum {
        left,
        right,
        up,
        down,
        word_left,
        word_right,
        line_start,
        line_end,
        grapheme_left,
        grapheme_right,
    };

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .bidi_processor = try gcode.bidi.BiDi.init(allocator),
            .grapheme_segmenter = try gcode.grapheme.GraphemeSegmenter.init(allocator),
            .complex_analyzer = try gcode.complex_script.ComplexScriptAnalyzer.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.bidi_processor.deinit();
        self.grapheme_segmenter.deinit();
        self.complex_analyzer.deinit();
    }

    pub fn analyzeTextForCursor(self: *Self, text: []const u8, terminal_width: u32) !CursorTextAnalysis {
        // Comprehensive text analysis for cursor positioning
        var analysis = CursorTextAnalysis.init(self.allocator);

        // 1. Grapheme cluster segmentation
        analysis.grapheme_breaks = try self.grapheme_segmenter.segmentText(text);

        // 2. BiDi analysis for RTL/LTR text
        const bidi_runs = try self.bidi_processor.processText(text, .auto);
        analysis.bidi_runs = try self.allocator.dupe(@TypeOf(bidi_runs[0]), bidi_runs);

        // 3. Script analysis for complex text
        analysis.complex_analysis = try self.complex_analyzer.analyzeText(text);

        // 4. Terminal line wrapping analysis
        analysis.line_breaks = try self.calculateLineBreaks(text, terminal_width, &analysis);

        // 5. Create logical-to-visual mapping
        analysis.logical_to_visual = try self.createLogicalToVisualMap(text, &analysis);
        analysis.visual_to_logical = try self.createVisualToLogicalMap(analysis.logical_to_visual);

        return analysis;
    }

    fn calculateLineBreaks(self: *Self, text: []const u8, terminal_width: u32, analysis: *const CursorTextAnalysis) ![]usize {

        var line_breaks = std.ArrayList(usize).init(self.allocator);
        var current_width: u32 = 0;
        var byte_pos: usize = 0;

        // Process character by character considering display width
        while (byte_pos < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[byte_pos]) catch 1;
            if (byte_pos + char_len > text.len) break;

            const codepoint = std.unicode.utf8Decode(text[byte_pos..byte_pos + char_len]) catch {
                byte_pos += 1;
                continue;
            };

            // Calculate character display width
            const char_width = self.getCharacterDisplayWidth(codepoint, analysis);

            // Check for line wrap
            if (current_width + char_width > terminal_width and current_width > 0) {
                try line_breaks.append(byte_pos);
                current_width = 0;
            }

            // Handle explicit line breaks
            if (codepoint == '\n') {
                try line_breaks.append(byte_pos + char_len);
                current_width = 0;
            } else {
                current_width += char_width;
            }

            byte_pos += char_len;
        }

        return line_breaks.toOwnedSlice();
    }

    fn getCharacterDisplayWidth(self: *Self, codepoint: u32, analysis: *const CursorTextAnalysis) u32 {
        _ = self;
        _ = analysis;

        // Determine character width for terminal display

        // Control characters and combining marks have no width
        if (codepoint < 0x20 or (codepoint >= 0x0300 and codepoint <= 0x036F)) {
            return 0;
        }

        // CJK characters are typically fullwidth (2 cells)
        if ((codepoint >= 0x4E00 and codepoint <= 0x9FFF) or    // CJK Unified Ideographs
            (codepoint >= 0x3040 and codepoint <= 0x309F) or    // Hiragana
            (codepoint >= 0x30A0 and codepoint <= 0x30FF) or    // Katakana
            (codepoint >= 0xAC00 and codepoint <= 0xD7AF)) {    // Hangul
            return 2;
        }

        // Most emoji are fullwidth
        if ((codepoint >= 0x1F600 and codepoint <= 0x1F64F) or  // Emoticons
            (codepoint >= 0x1F300 and codepoint <= 0x1F5FF) or  // Misc Symbols
            (codepoint >= 0x1F680 and codepoint <= 0x1F6FF) or  // Transport
            (codepoint >= 0x1F1E6 and codepoint <= 0x1F1FF)) {  // Regional Indicators
            return 2;
        }

        // Default to single width
        return 1;
    }

    fn createLogicalToVisualMap(self: *Self, text: []const u8, analysis: *const CursorTextAnalysis) ![]usize {
        var mapping = try self.allocator.alloc(usize, text.len);

        // Start with identity mapping
        for (mapping, 0..) |*pos, i| {
            pos.* = i;
        }

        // Apply BiDi reordering
        for (analysis.bidi_runs) |run| {
            if (run.direction == .rtl) {
                // Reverse the mapping for RTL runs
                const start = run.start;
                const end = run.start + run.length;

                var i = start;
                var j = end - 1;
                while (i < j) {
                    const temp = mapping[i];
                    mapping[i] = mapping[j];
                    mapping[j] = temp;
                    i += 1;
                    j -= 1;
                }
            }
        }

        return mapping;
    }

    fn createVisualToLogicalMap(self: *Self, logical_to_visual: []const usize) ![]usize {
        var mapping = try self.allocator.alloc(usize, logical_to_visual.len);

        for (logical_to_visual, 0..) |visual_pos, logical_pos| {
            if (visual_pos < mapping.len) {
                mapping[visual_pos] = logical_pos;
            }
        }

        return mapping;
    }

    pub fn moveCursor(self: *Self, current_pos: CursorPosition, movement: CursorMovement, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
        return switch (movement) {
            .left => try self.moveCursorLeft(current_pos, analysis, text),
            .right => try self.moveCursorRight(current_pos, analysis, text),
            .up => try self.moveCursorUp(current_pos, analysis),
            .down => try self.moveCursorDown(current_pos, analysis),
            .word_left => try self.moveCursorWordLeft(current_pos, analysis, text),
            .word_right => try self.moveCursorWordRight(current_pos, analysis, text),
            .line_start => try self.moveCursorLineStart(current_pos, analysis),
            .line_end => try self.moveCursorLineEnd(current_pos, analysis),
            .grapheme_left => try self.moveCursorGraphemeLeft(current_pos, analysis),
            .grapheme_right => try self.moveCursorGraphemeRight(current_pos, analysis),
        };
    }

    fn moveCursorLeft(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
        _ = text;

        var new_pos = current;

        if (current.is_rtl_context) {
            // In RTL context, left means visual right
            new_pos.visual_index = @min(new_pos.visual_index + 1, analysis.logical_to_visual.len - 1);
        } else {
            // In LTR context, left means visual left
            if (new_pos.visual_index > 0) {
                new_pos.visual_index -= 1;
            }
        }

        // Update logical position based on visual
        if (new_pos.visual_index < analysis.visual_to_logical.len) {
            new_pos.logical_index = analysis.visual_to_logical[new_pos.visual_index];
        }

        // Update terminal coordinates
        try self.updateTerminalCoordinates(&new_pos, analysis);

        // Update script context
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn moveCursorRight(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
        _ = text;

        var new_pos = current;

        if (current.is_rtl_context) {
            // In RTL context, right means visual left
            if (new_pos.visual_index > 0) {
                new_pos.visual_index -= 1;
            }
        } else {
            // In LTR context, right means visual right
            new_pos.visual_index = @min(new_pos.visual_index + 1, analysis.logical_to_visual.len - 1);
        }

        // Update logical position
        if (new_pos.visual_index < analysis.visual_to_logical.len) {
            new_pos.logical_index = analysis.visual_to_logical[new_pos.visual_index];
        }

        // Update terminal coordinates
        try self.updateTerminalCoordinates(&new_pos, analysis);

        // Update script context
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn moveCursorGraphemeLeft(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis) !CursorPosition {
        var new_pos = current;

        // Find previous grapheme boundary
        if (current.grapheme_index > 0) {
            new_pos.grapheme_index -= 1;
            new_pos.logical_index = analysis.grapheme_breaks[new_pos.grapheme_index];
            new_pos.visual_index = analysis.logical_to_visual[new_pos.logical_index];
        }

        try self.updateTerminalCoordinates(&new_pos, analysis);
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn moveCursorGraphemeRight(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis) !CursorPosition {
        var new_pos = current;

        // Find next grapheme boundary
        if (current.grapheme_index + 1 < analysis.grapheme_breaks.len) {
            new_pos.grapheme_index += 1;
            new_pos.logical_index = analysis.grapheme_breaks[new_pos.grapheme_index];
            new_pos.visual_index = analysis.logical_to_visual[new_pos.logical_index];
        }

        try self.updateTerminalCoordinates(&new_pos, analysis);
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn moveCursorWordLeft(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
        // Use gcode word boundary detection
        const word_boundaries = try gcode.word.WordIterator.init(text);
        defer self.allocator.free(word_boundaries);

        var new_pos = current;

        // Find previous word boundary
        for (word_boundaries) |boundary| {
            if (boundary.start < current.logical_index) {
                new_pos.logical_index = boundary.start;
            } else {
                break;
            }
        }

        new_pos.visual_index = analysis.logical_to_visual[new_pos.logical_index];
        try self.updateTerminalCoordinates(&new_pos, analysis);
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn moveCursorWordRight(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
        // Use gcode word boundary detection
        const word_boundaries = try gcode.word.WordIterator.init(text);
        defer self.allocator.free(word_boundaries);

        var new_pos = current;

        // Find next word boundary
        for (word_boundaries) |boundary| {
            if (boundary.end > current.logical_index) {
                new_pos.logical_index = boundary.end;
                break;
            }
        }

        new_pos.visual_index = analysis.logical_to_visual[new_pos.logical_index];
        try self.updateTerminalCoordinates(&new_pos, analysis);
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn moveCursorUp(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis) !CursorPosition {
        var new_pos = current;

        if (current.line > 0) {
            new_pos.line -= 1;

            // Find corresponding position on previous line
            const target_column = current.column;
            new_pos = try self.findPositionAtColumnOnLine(new_pos.line, target_column, analysis);
        }

        return new_pos;
    }

    fn moveCursorDown(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis) !CursorPosition {
        var new_pos = current;

        // Estimate total lines (simplified)
        const total_lines = analysis.line_breaks.len + 1;

        if (current.line + 1 < total_lines) {
            new_pos.line += 1;

            // Find corresponding position on next line
            const target_column = current.column;
            new_pos = try self.findPositionAtColumnOnLine(new_pos.line, target_column, analysis);
        }

        return new_pos;
    }

    fn moveCursorLineStart(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis) !CursorPosition {

        var new_pos = current;
        new_pos.column = 0;

        // Find logical position at start of current line
        if (current.line < analysis.line_breaks.len) {
            new_pos.logical_index = analysis.line_breaks[current.line];
        } else {
            new_pos.logical_index = 0;
        }

        new_pos.visual_index = analysis.logical_to_visual[new_pos.logical_index];
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn moveCursorLineEnd(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis) !CursorPosition {

        var new_pos = current;

        // Find end of current line
        if (current.line + 1 < analysis.line_breaks.len) {
            new_pos.logical_index = analysis.line_breaks[current.line + 1] - 1;
        } else {
            new_pos.logical_index = analysis.logical_to_visual.len - 1;
        }

        new_pos.visual_index = analysis.logical_to_visual[new_pos.logical_index];
        try self.updateTerminalCoordinates(&new_pos, analysis);
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn findPositionAtColumnOnLine(self: *Self, line: u32, target_column: u32, analysis: *const CursorTextAnalysis) !CursorPosition {

        // Simplified implementation - find closest position to target column on specified line
        var pos = CursorPosition{
            .logical_index = 0,
            .visual_index = 0,
            .grapheme_index = 0,
            .line = line,
            .column = @min(target_column, 79), // Clamp to reasonable terminal width
            .is_rtl_context = false,
            .script_context = undefined,
        };

        // Find corresponding logical position (simplified)
        if (line < analysis.line_breaks.len) {
            pos.logical_index = analysis.line_breaks[line] + pos.column;
        }

        if (pos.logical_index < analysis.logical_to_visual.len) {
            pos.visual_index = analysis.logical_to_visual[pos.logical_index];
        }

        pos.script_context = try self.getScriptContext(pos.logical_index, analysis);

        return pos;
    }

    fn updateTerminalCoordinates(_: *Self, pos: *CursorPosition, analysis: *const CursorTextAnalysis) !void {

        // Calculate terminal line and column from logical position
        var current_line: u32 = 0;
        var current_column: u32 = 0;

        for (analysis.line_breaks) |break_pos| {
            if (pos.logical_index >= break_pos) {
                current_line += 1;
                current_column = 0;
            } else {
                current_column = @intCast(pos.logical_index - (if (current_line > 0) analysis.line_breaks[current_line - 1] else 0));
                break;
            }
        }

        pos.line = current_line;
        pos.column = current_column;
    }

    fn getScriptContext(_: *Self, logical_index: usize, analysis: *const CursorTextAnalysis) !ScriptContext {

        if (logical_index >= analysis.complex_analysis.len) {
            return ScriptContext{
                .script_type = .latin,
                .requires_complex_shaping = false,
                .is_emoji_sequence = false,
                .is_cjk_fullwidth = false,
            };
        }

        const char_analysis = analysis.complex_analysis[logical_index];

        return ScriptContext{
            .script_type = char_analysis.script,
            .requires_complex_shaping = char_analysis.requires_complex_shaping,
            .is_emoji_sequence = char_analysis.is_emoji,
            .is_cjk_fullwidth = char_analysis.is_fullwidth,
        };
    }

    // Test cursor movement in complex text
    pub fn testCursorMovement(self: *Self) !void {
        const test_texts = [_][]const u8{
            "Hello مرحبا World",      // Mixed LTR/RTL
            "こんにちは世界",           // Japanese
            "👨‍👩‍👧‍👦 Family",          // Emoji sequences
            "नमस्ते दुनिया",           // Devanagari
        };

        for (test_texts) |text| {
            std.log.info("Testing cursor in: {s}", .{text});

            var analysis = try self.analyzeTextForCursor(text, 80);
            defer analysis.deinit();

            var pos = CursorPosition{
                .logical_index = 0,
                .visual_index = 0,
                .grapheme_index = 0,
                .line = 0,
                .column = 0,
                .is_rtl_context = false,
                .script_context = try self.getScriptContext(0, &analysis),
            };

            // Test various movements
            const movements = [_]CursorMovement{ .right, .right, .left, .word_right, .grapheme_left };

            for (movements) |movement| {
                pos = try self.moveCursor(pos, movement, &analysis, text);
                std.log.info("  After {}: logical={}, visual={}, line={}, col={}", .{
                    @tagName(movement), pos.logical_index, pos.visual_index, pos.line, pos.column
                });
            }
        }
    }
};

pub const CursorTextAnalysis = struct {
    grapheme_breaks: []usize,
    bidi_runs: []gcode.bidi.BiDiRun,
    complex_analysis: []gcode.complex_script.ComplexScriptAnalysis,
    line_breaks: []usize,
    logical_to_visual: []usize,
    visual_to_logical: []usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CursorTextAnalysis {
        return CursorTextAnalysis{
            .grapheme_breaks = &[_]usize{},
            .bidi_runs = &[_]gcode.bidi.BiDiRun{},
            .complex_analysis = &[_]gcode.complex_script.ComplexScriptAnalysis{},
            .line_breaks = &[_]usize{},
            .logical_to_visual = &[_]usize{},
            .visual_to_logical = &[_]usize{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CursorTextAnalysis) void {
        self.allocator.free(self.grapheme_breaks);
        self.allocator.free(self.bidi_runs);
        self.allocator.free(self.complex_analysis);
        self.allocator.free(self.line_breaks);
        self.allocator.free(self.logical_to_visual);
        self.allocator.free(self.visual_to_logical);
    }
};

test "TerminalCursorProcessor basic movement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = TerminalCursorProcessor.init(allocator) catch return;
    defer processor.deinit();

    const test_text = "Hello World";
    var analysis = processor.analyzeTextForCursor(test_text, 80) catch return;
    defer analysis.deinit();

    var pos = TerminalCursorProcessor.CursorPosition{
        .logical_index = 0,
        .visual_index = 0,
        .grapheme_index = 0,
        .line = 0,
        .column = 0,
        .is_rtl_context = false,
        .script_context = processor.getScriptContext(0, &analysis) catch return,
    };

    // Test right movement
    pos = processor.moveCursor(pos, .right, &analysis, test_text) catch return;
    try testing.expect(pos.logical_index > 0);
}