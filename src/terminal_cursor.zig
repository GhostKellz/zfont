const std = @import("std");
const root = @import("root.zig");
const gcode = @import("gcode");
const Unicode = @import("unicode.zig").Unicode;
const GraphemeSegmenter = @import("grapheme_segmenter.zig").GraphemeSegmenter;

// Terminal cursor positioning in complex text using gcode intelligence
// Handles proper cursor movement in BiDi, CJK, Indic, Arabic, and emoji text
pub const TerminalCursorProcessor = struct {
    allocator: std.mem.Allocator,
    bidi_processor: gcode.BiDi,
    grapheme_segmenter: GraphemeSegmenter,
    complex_analyzer: gcode.ComplexScriptAnalyzer,
    east_asian_mode: Unicode.EastAsianWidthMode,

    const Self = @This();

    pub const CursorPosition = struct {
        logical_index: usize, // Logical position in text buffer
        visual_index: usize, // Visual position for rendering
        grapheme_index: usize, // Grapheme cluster index
        line: u32, // Terminal line
        column: u32, // Terminal column
        is_rtl_context: bool, // Whether cursor is in RTL context
        script_context: ScriptContext,
    };

    pub const ScriptContext = struct {
        script_type: gcode.Script,
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
            .bidi_processor = gcode.BiDi.init(allocator),
            .grapheme_segmenter = GraphemeSegmenter.init(allocator),
            .complex_analyzer = gcode.ComplexScriptAnalyzer.init(allocator),
            .east_asian_mode = .standard,
        };
    }

    pub fn deinit(self: *Self) void {
        self.grapheme_segmenter.deinit();
    }

    pub fn setEastAsianWidthMode(self: *Self, mode: Unicode.EastAsianWidthMode) void {
        self.east_asian_mode = mode;
    }

    pub fn analyzeTextForCursor(self: *Self, text: []const u8, terminal_width: u32) !CursorTextAnalysis {
        // Comprehensive text analysis for cursor positioning
        var analysis = CursorTextAnalysis.init(self.allocator);

        // 1. Grapheme cluster segmentation
        analysis.grapheme_breaks = try self.grapheme_segmenter.segmentText(text);

        // Decode UTF-8 into codepoints; gcode processText/analyzeText expect []const u32.
        var codepoints = std.ArrayList(u32).empty;
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

        // 2. BiDi analysis for RTL/LTR text
        const base_dir = self.bidi_processor.getBaseDirection(codepoints.items);
        const bidi_runs = try self.bidi_processor.processText(codepoints.items, base_dir);
        defer self.allocator.free(bidi_runs);
        analysis.bidi_runs = try self.allocator.dupe(@TypeOf(bidi_runs[0]), bidi_runs);

        // 3. Script analysis for complex text
        analysis.complex_analysis = try self.complex_analyzer.analyzeText(codepoints.items);
        // Retain the codepoints parallel to the analysis for property recovery.
        analysis.analysis_codepoints = try self.allocator.dupe(u32, codepoints.items);

        // 4. Terminal line wrapping analysis
        analysis.line_breaks = try self.calculateLineBreaks(text, terminal_width);

        // 5. Create logical-to-visual mapping
        analysis.logical_to_visual = try self.createLogicalToVisualMap(text, &analysis);
        analysis.visual_to_logical = try self.createVisualToLogicalMap(analysis.logical_to_visual);

        return analysis;
    }

    fn calculateLineBreaks(self: *Self, text: []const u8, terminal_width: u32) ![]usize {
        var line_starts = std.ArrayList(usize).empty;
        try line_starts.append(self.allocator, 0);

        var current_width: u32 = 0;
        var iterator = Unicode.codePointIterator(text);

        while (iterator.next()) |cp| {
            const codepoint = cp.code;
            const char_width: u32 = @as(u32, Unicode.getDisplayWidth(codepoint, self.east_asian_mode));

            if (codepoint == '\n') {
                const next_start = cp.offset + cp.len;
                try line_starts.append(self.allocator, next_start);
                current_width = 0;
                continue;
            }

            if (terminal_width > 0 and current_width + char_width > terminal_width and current_width > 0) {
                try line_starts.append(self.allocator, cp.offset);
                current_width = char_width;
            } else {
                current_width += char_width;
            }
        }

        if (line_starts.items[line_starts.items.len - 1] != text.len) {
            try line_starts.append(self.allocator, text.len);
        }

        return line_starts.toOwnedSlice(self.allocator);
    }

    fn createLogicalToVisualMap(self: *Self, text: []const u8, analysis: *const CursorTextAnalysis) ![]usize {
        var mapping = try self.allocator.alloc(usize, text.len);

        // Start with identity mapping
        for (mapping, 0..) |*pos, i| {
            pos.* = i;
        }

        // Apply BiDi reordering
        for (analysis.bidi_runs) |run| {
            if (run.direction == .RTL) {
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
            .up => try self.moveCursorUp(current_pos, analysis, text),
            .down => try self.moveCursorDown(current_pos, analysis, text),
            .word_left => try self.moveCursorWordLeft(current_pos, analysis, text),
            .word_right => try self.moveCursorWordRight(current_pos, analysis, text),
            .line_start => try self.moveCursorLineStart(current_pos, analysis, text),
            .line_end => try self.moveCursorLineEnd(current_pos, analysis, text),
            .grapheme_left => try self.moveCursorGraphemeLeft(current_pos, analysis, text),
            .grapheme_right => try self.moveCursorGraphemeRight(current_pos, analysis, text),
        };
    }

    fn moveCursorLeft(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
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

        try self.updateTerminalCoordinates(&new_pos, analysis, text);
        new_pos.visual_index = self.resolveVisualIndex(analysis, new_pos.logical_index);
        new_pos.grapheme_index = self.resolveGraphemeIndex(analysis, new_pos.logical_index);
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn moveCursorRight(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
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

        try self.updateTerminalCoordinates(&new_pos, analysis, text);
        new_pos.visual_index = self.resolveVisualIndex(analysis, new_pos.logical_index);
        new_pos.grapheme_index = self.resolveGraphemeIndex(analysis, new_pos.logical_index);
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn moveCursorGraphemeLeft(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
        var new_pos = current;

        // Find previous grapheme boundary
        if (current.grapheme_index > 0) {
            new_pos.grapheme_index -= 1;
            new_pos.logical_index = analysis.grapheme_breaks[new_pos.grapheme_index];
        }

        try self.updateTerminalCoordinates(&new_pos, analysis, text);
        new_pos.visual_index = self.resolveVisualIndex(analysis, new_pos.logical_index);
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn moveCursorGraphemeRight(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
        var new_pos = current;

        // Find next grapheme boundary
        if (current.grapheme_index + 1 < analysis.grapheme_breaks.len) {
            new_pos.grapheme_index += 1;
            new_pos.logical_index = analysis.grapheme_breaks[new_pos.grapheme_index];
        }

        try self.updateTerminalCoordinates(&new_pos, analysis, text);
        new_pos.visual_index = self.resolveVisualIndex(analysis, new_pos.logical_index);
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn moveCursorWordLeft(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
        // Use gcode word boundary detection. WordIterator yields word segments;
        // track the running byte offset to recover boundary start positions.
        var iter = gcode.wordIterator(text);
        var new_pos = current;
        var offset: usize = 0;

        // Find the last word-start strictly before the current logical index.
        while (iter.next()) |segment| {
            if (offset < current.logical_index) {
                new_pos.logical_index = offset;
            } else {
                break;
            }
            offset += segment.len;
        }

        try self.updateTerminalCoordinates(&new_pos, analysis, text);
        new_pos.visual_index = self.resolveVisualIndex(analysis, new_pos.logical_index);
        new_pos.grapheme_index = self.resolveGraphemeIndex(analysis, new_pos.logical_index);
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn moveCursorWordRight(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
        // Use gcode word boundary detection. WordIterator yields word segments;
        // track the running byte offset to recover boundary end positions.
        var iter = gcode.wordIterator(text);
        var new_pos = current;
        var offset: usize = 0;

        // Find the first word-end strictly after the current logical index.
        while (iter.next()) |segment| {
            const end = offset + segment.len;
            if (end > current.logical_index) {
                new_pos.logical_index = end;
                break;
            }
            offset = end;
        }

        try self.updateTerminalCoordinates(&new_pos, analysis, text);
        new_pos.visual_index = self.resolveVisualIndex(analysis, new_pos.logical_index);
        new_pos.grapheme_index = self.resolveGraphemeIndex(analysis, new_pos.logical_index);
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn moveCursorUp(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
        var new_pos = current;

        if (current.line > 0) {
            new_pos.line -= 1;

            // Find corresponding position on previous line
            const target_column = current.column;
            new_pos = try self.findPositionAtColumnOnLine(new_pos.line, target_column, analysis, text);
        }

        return new_pos;
    }

    fn moveCursorDown(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
        var new_pos = current;

        // Estimate total lines (simplified)
        const total_lines = analysis.line_breaks.len + 1;

        if (current.line + 1 < total_lines) {
            new_pos.line += 1;

            // Find corresponding position on next line
            const target_column = current.column;
            new_pos = try self.findPositionAtColumnOnLine(new_pos.line, target_column, analysis, text);
        }

        return new_pos;
    }

    fn moveCursorLineStart(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
        var new_pos = current;
        const line_count = self.lineCount(analysis);
        const target_line: usize = if (line_count == 0) 0 else @min(@as(usize, current.line), line_count - 1);

        const bounds = self.getLineBounds(analysis, text, target_line);
        new_pos.logical_index = bounds.start;
        new_pos.line = @intCast(target_line);
        new_pos.column = 0;
        new_pos.visual_index = self.resolveVisualIndex(analysis, new_pos.logical_index);
        new_pos.grapheme_index = self.resolveGraphemeIndex(analysis, new_pos.logical_index);
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn moveCursorLineEnd(self: *Self, current: CursorPosition, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
        var new_pos = current;
        const line_count = self.lineCount(analysis);
        const target_line: usize = if (line_count == 0) 0 else @min(@as(usize, current.line), line_count - 1);

        const bounds = self.getLineBounds(analysis, text, target_line);
        var line_end = bounds.end;
        if (line_end > bounds.start and text[line_end - 1] == '\n') {
            line_end -= 1;
        }

        new_pos.logical_index = line_end;
        new_pos.line = @intCast(target_line);
        try self.updateTerminalCoordinates(&new_pos, analysis, text);
        new_pos.visual_index = self.resolveVisualIndex(analysis, new_pos.logical_index);
        new_pos.grapheme_index = self.resolveGraphemeIndex(analysis, new_pos.logical_index);
        new_pos.script_context = try self.getScriptContext(new_pos.logical_index, analysis);

        return new_pos;
    }

    fn findPositionAtColumnOnLine(self: *Self, line: u32, target_column: u32, analysis: *const CursorTextAnalysis, text: []const u8) !CursorPosition {
        const line_count = self.lineCount(analysis);
        const target_line: usize = if (line_count == 0) 0 else @min(@as(usize, line), line_count - 1);
        const bounds = self.getLineBounds(analysis, text, target_line);

        var iterator = Unicode.codePointIterator(text[bounds.start..bounds.end]);
        var logical_offset: usize = 0;
        var column_width: u32 = 0;

        while (iterator.next()) |cp| {
            const width = @as(u32, Unicode.getDisplayWidth(cp.code, self.east_asian_mode));
            if (column_width + width > target_column) break;
            column_width += width;
            logical_offset = cp.offset + cp.len;
        }

        const logical_index = bounds.start + logical_offset;

        return CursorPosition{
            .logical_index = logical_index,
            .visual_index = self.resolveVisualIndex(analysis, logical_index),
            .grapheme_index = self.resolveGraphemeIndex(analysis, logical_index),
            .line = @intCast(target_line),
            .column = column_width,
            .is_rtl_context = false,
            .script_context = try self.getScriptContext(logical_index, analysis),
        };
    }

    fn updateTerminalCoordinates(self: *Self, pos: *CursorPosition, analysis: *const CursorTextAnalysis, text: []const u8) !void {
        if (analysis.line_breaks.len == 0) {
            pos.line = 0;
            pos.column = 0;
            return;
        }

        var line_index: usize = 0;
        while (line_index + 1 < analysis.line_breaks.len and pos.logical_index >= analysis.line_breaks[line_index + 1]) {
            line_index += 1;
        }

        const bounds = self.getLineBounds(analysis, text, line_index);
        const slice_end = @min(pos.logical_index, bounds.end);
        const column = self.measureRangeWidth(text, bounds.start, slice_end);

        pos.line = @intCast(line_index);
        pos.column = column;
    }

    fn resolveVisualIndex(_: *Self, analysis: *const CursorTextAnalysis, logical_index: usize) usize {
        if (analysis.logical_to_visual.len == 0) return 0;
        const clamped = @min(logical_index, analysis.logical_to_visual.len - 1);
        return analysis.logical_to_visual[clamped];
    }

    fn resolveGraphemeIndex(_: *Self, analysis: *const CursorTextAnalysis, logical_index: usize) usize {
        if (analysis.grapheme_breaks.len == 0) return 0;
        var i: usize = 0;
        while (i < analysis.grapheme_breaks.len and analysis.grapheme_breaks[i] <= logical_index) : (i += 1) {}
        return if (i == 0) 0 else i - 1;
    }

    fn lineCount(_: *Self, analysis: *const CursorTextAnalysis) usize {
        return if (analysis.line_breaks.len == 0) 0 else analysis.line_breaks.len - 1;
    }

    fn getLineBounds(_: *Self, analysis: *const CursorTextAnalysis, text: []const u8, line: usize) struct { start: usize, end: usize } {
        if (analysis.line_breaks.len == 0) {
            return .{ .start = 0, .end = text.len };
        }

        const start = analysis.line_breaks[line];
        const end = if (line + 1 < analysis.line_breaks.len) analysis.line_breaks[line + 1] else text.len;
        return .{ .start = start, .end = end };
    }

    fn measureRangeWidth(self: *Self, text: []const u8, start: usize, end: usize) u32 {
        if (start >= end) return 0;
        var iterator = Unicode.codePointIterator(text[start..end]);
        var width: u32 = 0;
        while (iterator.next()) |cp| {
            width += @as(u32, Unicode.getDisplayWidth(cp.code, self.east_asian_mode));
        }
        return width;
    }

    fn getScriptContext(_: *Self, logical_index: usize, analysis: *const CursorTextAnalysis) !ScriptContext {
        if (logical_index >= analysis.complex_analysis.len) {
            return ScriptContext{
                .script_type = .Latin,
                .requires_complex_shaping = false,
                .is_emoji_sequence = false,
                .is_cjk_fullwidth = false,
            };
        }

        const char_analysis = analysis.complex_analysis[logical_index];

        // gcode's ComplexScriptAnalysis exposes width via cjk_width and shaping via
        // needsComplexShaping(). It does not carry the source codepoint or an emoji
        // flag, so emoji detection is derived from the per-codepoint grapheme
        // property below using the stored codepoint mirror.
        const is_fullwidth = if (char_analysis.cjk_width) |w| w == .wide else false;
        const is_emoji = if (logical_index < analysis.analysis_codepoints.len)
            gcode.getProperties(@intCast(analysis.analysis_codepoints[logical_index])).grapheme_boundary_class.isExtendedPictographic()
        else
            false;

        return ScriptContext{
            .script_type = char_analysis.script,
            .requires_complex_shaping = char_analysis.needsComplexShaping(),
            .is_emoji_sequence = is_emoji,
            .is_cjk_fullwidth = is_fullwidth,
        };
    }

    // Test cursor movement in complex text
    pub fn testCursorMovement(self: *Self) !void {
        const test_texts = [_][]const u8{
            "Hello مرحبا World", // Mixed LTR/RTL
            "こんにちは世界", // Japanese
            "👨‍👩‍👧‍👦 Family", // Emoji sequences
            "नमस्ते दुनिया", // Devanagari
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
                std.log.info("  After {s}: logical={}, visual={}, line={}, col={}", .{ @tagName(movement), pos.logical_index, pos.visual_index, pos.line, pos.column });
            }
        }
    }
};

pub const CursorTextAnalysis = struct {
    grapheme_breaks: []usize,
    bidi_runs: []gcode.Run,
    complex_analysis: []gcode.ComplexScriptAnalysis,
    // Codepoints parallel to complex_analysis (same index space). gcode's
    // ComplexScriptAnalysis omits the source codepoint, so we retain it here to
    // recover per-character properties (e.g. emoji classification).
    analysis_codepoints: []u32,
    line_breaks: []usize,
    logical_to_visual: []usize,
    visual_to_logical: []usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CursorTextAnalysis {
        return CursorTextAnalysis{
            .grapheme_breaks = &[_]usize{},
            .bidi_runs = &[_]gcode.Run{},
            .complex_analysis = &[_]gcode.ComplexScriptAnalysis{},
            .analysis_codepoints = &[_]u32{},
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
        self.allocator.free(self.analysis_codepoints);
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
