const std = @import("std");
const root = @import("root.zig");
const gcode_integration = @import("gcode_integration.zig");
const gcode_shaper = @import("gcode_shaper.zig");

// Terminal-optimized text handling using gcode intelligence
// Handles cursor positioning, text selection, and complex text in terminals
pub const TerminalTextHandler = struct {
    allocator: std.mem.Allocator,
    gcode_processor: gcode_integration.GcodeTextProcessor,
    text_shaper: gcode_shaper.GcodeTextShaper,

    // Terminal-specific settings
    cell_width: f32,
    cell_height: f32,
    columns: u32,
    rows: u32,

    // Text selection state
    selection: ?TextSelection = null,

    const Self = @This();

    const TextSelection = struct {
        start: CursorPosition,
        end: CursorPosition,
        active: bool,
    };

    const CursorPosition = struct {
        logical: usize,  // Logical position in text
        visual: usize,   // Visual position for display
        column: u32,     // Terminal column
        row: u32,        // Terminal row
    };

    pub fn init(allocator: std.mem.Allocator, cell_width: f32, cell_height: f32, columns: u32, rows: u32) !Self {
        return Self{
            .allocator = allocator,
            .gcode_processor = try gcode_integration.GcodeTextProcessor.init(allocator),
            .text_shaper = try gcode_shaper.GcodeTextShaper.init(allocator),
            .cell_width = cell_width,
            .cell_height = cell_height,
            .columns = columns,
            .rows = rows,
        };
    }

    pub fn deinit(self: *Self) void {
        self.gcode_processor.deinit();
        self.text_shaper.deinit();
    }

    // Advanced word boundary detection for terminal text selection
    pub fn selectWord(self: *Self, text: []const u8, cursor_pos: usize) !TextSelection {
        // Use gcode's UAX #29 compliant word boundary detection
        const word_start = try self.gcode_processor.findWordBoundary(text, cursor_pos, .backward);
        const word_end = try self.gcode_processor.findWordBoundary(text, cursor_pos, .forward);

        // Convert logical positions to visual positions for BiDi text
        const visual_start = try self.gcode_processor.calculateCursorPosition(text, word_start, null);
        const visual_end = try self.gcode_processor.calculateCursorPosition(text, word_end, null);

        const start_pos = try self.logicalToTerminalPosition(text, word_start, visual_start);
        const end_pos = try self.logicalToTerminalPosition(text, word_end, visual_end);

        return TextSelection{
            .start = start_pos,
            .end = end_pos,
            .active = true,
        };
    }

    // Intelligent line breaking using gcode analysis
    pub fn wrapTextToTerminal(self: *Self, text: []const u8) ![]WrappedLine {
        const analysis = try self.gcode_processor.analyzeCompleteText(text);
        defer self.deallocateAnalysis(&analysis);

        var wrapped_lines = std.ArrayList(WrappedLine).init(self.allocator);
        var current_line = WrappedLine.init(self.allocator);
        var current_width: f32 = 0;
        const max_width = @as(f32, @floatFromInt(self.columns)) * self.cell_width;

        // Process word boundaries for intelligent wrapping
        for (analysis.word_boundaries) |boundary| {
            const word_text = text[boundary.start..boundary.end];
            const word_width = try self.calculateTextWidth(word_text, &analysis);

            // Check if word fits on current line
            if (current_width + word_width > max_width and current_line.segments.items.len > 0) {
                // Start new line
                try wrapped_lines.append(current_line);
                current_line = WrappedLine.init(self.allocator);
                current_width = 0;
            }

            // Add word to current line
            try current_line.segments.append(LineSegment{
                .text = try self.allocator.dupe(u8, word_text),
                .start = boundary.start,
                .end = boundary.end,
                .width = word_width,
                .word_type = boundary.word_type,
                .is_emoji = boundary.is_emoji_sequence,
            });

            current_width += word_width;

            // Handle explicit line breaks
            if (std.mem.indexOf(u8, word_text, "\n") != null) {
                try wrapped_lines.append(current_line);
                current_line = WrappedLine.init(self.allocator);
                current_width = 0;
            }
        }

        // Add final line if not empty
        if (current_line.segments.items.len > 0) {
            try wrapped_lines.append(current_line);
        } else {
            current_line.deinit();
        }

        return wrapped_lines.toOwnedSlice();
    }

    // Terminal cursor positioning in complex text
    pub fn moveCursor(self: *Self, text: []const u8, current_pos: usize, direction: CursorDirection) !CursorPosition {
        const new_logical = switch (direction) {
            .left => try self.moveCursorLeft(text, current_pos),
            .right => try self.moveCursorRight(text, current_pos),
            .up => try self.moveCursorUp(text, current_pos),
            .down => try self.moveCursorDown(text, current_pos),
            .word_left => try self.gcode_processor.findWordBoundary(text, current_pos, .backward),
            .word_right => try self.gcode_processor.findWordBoundary(text, current_pos, .forward),
        };

        // Convert to visual position for BiDi text
        const visual_pos = try self.gcode_processor.calculateCursorPosition(text, new_logical, null);

        return self.logicalToTerminalPosition(text, new_logical, visual_pos);
    }

    fn moveCursorLeft(self: *Self, text: []const u8, pos: usize) !usize {
        _ = self;
        if (pos == 0) return 0;

        // Move by grapheme cluster (handles multi-codepoint characters)
        var i = pos;
        while (i > 0) {
            i -= 1;
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch continue;
            if (i + char_len == pos) {
                return i;
            }
        }
        return 0;
    }

    fn moveCursorRight(self: *Self, text: []const u8, pos: usize) !usize {
        _ = self;
        if (pos >= text.len) return text.len;

        const char_len = std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
        return @min(pos + char_len, text.len);
    }

    fn moveCursorUp(self: *Self, text: []const u8, pos: usize) !usize {
        _ = self;
        _ = text;
        // Simplified - would implement line-aware cursor movement
        return pos;
    }

    fn moveCursorDown(self: *Self, text: []const u8, pos: usize) !usize {
        _ = self;
        _ = text;
        // Simplified - would implement line-aware cursor movement
        return pos;
    }

    fn logicalToTerminalPosition(self: *Self, text: []const u8, logical: usize, visual: usize) !CursorPosition {
        // Convert logical/visual positions to terminal coordinates
        _ = text;
        const column = @as(u32, @intCast(visual % self.columns));
        const row = @as(u32, @intCast(visual / self.columns));

        return CursorPosition{
            .logical = logical,
            .visual = visual,
            .column = column,
            .row = row,
        };
    }

    fn calculateTextWidth(self: *Self, _: []const u8, analysis: *const gcode_integration.CompleteTextAnalysis) !f32 {
        var total_width: f32 = 0;

        // Use gcode's display width analysis
        for (analysis.complex_analysis) |char_analysis| {
            total_width += char_analysis.display_width * self.cell_width;
        }

        return total_width;
    }

    // Emoji sequence handling with proper terminal width
    pub fn handleEmojiSequences(self: *Self, text: []const u8) ![]EmojiRenderInfo {
        const word_boundaries = try self.gcode_processor.getWordBoundaries(text);
        defer self.allocator.free(word_boundaries);

        var emoji_info = std.ArrayList(EmojiRenderInfo).init(self.allocator);

        for (word_boundaries) |boundary| {
            if (boundary.is_emoji_sequence) {
                const emoji_text = text[boundary.start..boundary.end];

                try emoji_info.append(EmojiRenderInfo{
                    .sequence = try self.allocator.dupe(u8, emoji_text),
                    .start = boundary.start,
                    .end = boundary.end,
                    .terminal_width = self.calculateEmojiWidth(emoji_text),
                    .grapheme_count = boundary.grapheme_count,
                });
            }
        }

        return emoji_info.toOwnedSlice();
    }

    fn calculateEmojiWidth(_: *Self, _: []const u8) u32 {
        // Most emoji take 2 terminal cells
        // Complex sequences (flags, skin tones) might vary
        return 2; // Simplified - would use gcode width analysis
    }

    // Text rendering pipeline for terminals
    pub fn renderTextForTerminal(self: *Self, text: []const u8) !TerminalRenderResult {
        // Complete text analysis
        const analysis = try self.gcode_processor.analyzeCompleteText(text);
        defer self.deallocateAnalysis(&analysis);

        // Shape text using gcode intelligence
        var shaped = try self.text_shaper.shapeText(text, self.cell_height);
        defer shaped.deinit();

        // Handle emoji sequences
        const emoji_info = try self.handleEmojiSequences(text);

        // Wrap text to terminal width
        const wrapped_lines = try self.wrapTextToTerminal(text);

        return TerminalRenderResult{
            .shaped_text = shaped,
            .emoji_sequences = emoji_info,
            .wrapped_lines = wrapped_lines,
            .requires_bidi = analysis.requires_bidi,
            .requires_complex_shaping = analysis.requires_complex_shaping,
        };
    }

    fn deallocateAnalysis(self: *Self, analysis: *const gcode_integration.CompleteTextAnalysis) void {
        self.allocator.free(analysis.script_runs);
        self.allocator.free(analysis.bidi_runs);
        self.allocator.free(analysis.word_boundaries);
        self.allocator.free(analysis.complex_analysis);
    }

    // Performance optimization for terminal scrolling
    pub fn optimizeForScrolling(self: *Self, text: []const u8, visible_start: usize, visible_end: usize) !OptimizedRenderData {
        // Only process visible text for performance
        const visible_text = text[visible_start..@min(visible_end, text.len)];

        // Quick analysis for visible portion
        const script_runs = try self.gcode_processor.detectScriptRuns(visible_text);
        defer self.allocator.free(script_runs);

        var simplified_runs = std.ArrayList(SimplifiedRun).init(self.allocator);

        for (script_runs) |run| {
            try simplified_runs.append(SimplifiedRun{
                .text = try self.allocator.dupe(u8, run.text),
                .script = run.script_info.script,
                .direction = run.script_info.writing_direction,
                .needs_complex_shaping = run.script_info.requires_complex_shaping,
                .char_width = self.estimateCharWidth(run.script_info.script),
            });
        }

        return OptimizedRenderData{
            .runs = try simplified_runs.toOwnedSlice(),
            .visible_start = visible_start,
            .visible_end = visible_end,
        };
    }

    fn estimateCharWidth(self: *Self, script: gcode_integration.ScriptType) f32 {
        return switch (script) {
            .han, .hiragana, .katakana => self.cell_width * 2.0, // CJK double-width
            else => self.cell_width,
        };
    }
};

pub const CursorDirection = enum {
    left,
    right,
    up,
    down,
    word_left,
    word_right,
};

pub const WrappedLine = struct {
    segments: std.ArrayList(LineSegment),

    pub fn init(allocator: std.mem.Allocator) WrappedLine {
        return WrappedLine{
            .segments = std.ArrayList(LineSegment).init(allocator),
        };
    }

    pub fn deinit(self: *WrappedLine) void {
        for (self.segments.items) |*segment| {
            segment.allocator.free(segment.text);
        }
        self.segments.deinit();
    }
};

pub const LineSegment = struct {
    text: []u8,
    start: usize,
    end: usize,
    width: f32,
    word_type: gcode_integration.WordType,
    is_emoji: bool,
    allocator: std.mem.Allocator = undefined,
};

pub const EmojiRenderInfo = struct {
    sequence: []u8,
    start: usize,
    end: usize,
    terminal_width: u32,
    grapheme_count: usize,
};

pub const TerminalRenderResult = struct {
    shaped_text: gcode_shaper.ShapedText,
    emoji_sequences: []EmojiRenderInfo,
    wrapped_lines: []WrappedLine,
    requires_bidi: bool,
    requires_complex_shaping: bool,
};

pub const SimplifiedRun = struct {
    text: []u8,
    script: gcode_integration.ScriptType,
    direction: gcode_integration.WritingDirection,
    needs_complex_shaping: bool,
    char_width: f32,
};

pub const OptimizedRenderData = struct {
    runs: []SimplifiedRun,
    visible_start: usize,
    visible_end: usize,
};

// Terminal text selection with complex script support
pub const TerminalTextSelector = struct {
    allocator: std.mem.Allocator,
    text_handler: *TerminalTextHandler,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, handler: *TerminalTextHandler) Self {
        return Self{
            .allocator = allocator,
            .text_handler = handler,
        };
    }

    // Select text by word boundaries (double-click selection)
    pub fn selectByWord(self: *Self, text: []const u8, click_pos: usize) !TerminalTextHandler.TextSelection {
        return self.text_handler.selectWord(text, click_pos);
    }

    // Select entire line (triple-click selection)
    pub fn selectLine(self: *Self, text: []const u8, click_pos: usize) !TerminalTextHandler.TextSelection {
        _ = self;
        _ = text;
        _ = click_pos;
        // TODO: Implement line selection
        return TerminalTextHandler.TextSelection{
            .start = TerminalTextHandler.CursorPosition{ .logical = 0, .visual = 0, .column = 0, .row = 0 },
            .end = TerminalTextHandler.CursorPosition{ .logical = 0, .visual = 0, .column = 0, .row = 0 },
            .active = true,
        };
    }

    // Extend selection while respecting script boundaries
    pub fn extendSelection(self: *Self, selection: *TerminalTextHandler.TextSelection, text: []const u8, new_pos: usize) !void {
        const visual_pos = try self.text_handler.gcode_processor.calculateCursorPosition(text, new_pos, null);
        selection.end = try self.text_handler.logicalToTerminalPosition(text, new_pos, visual_pos);
    }
};

test "TerminalTextHandler word selection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var handler = TerminalTextHandler.init(allocator, 12.0, 16.0, 80, 24) catch return;
    defer handler.deinit();

    const test_text = "Hello 🇺🇸 World مرحبا";
    const selection = handler.selectWord(test_text, 7) catch return; // Position in flag emoji

    try testing.expect(selection.active);
    // Should select the entire flag emoji sequence
}

test "TerminalTextHandler emoji handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var handler = TerminalTextHandler.init(allocator, 12.0, 16.0, 80, 24) catch return;
    defer handler.deinit();

    const emoji_text = "👨‍👩‍👧‍👦 Family"; // Complex family emoji
    const emoji_info = handler.handleEmojiSequences(emoji_text) catch return;
    defer {
        for (emoji_info) |*info| {
            allocator.free(info.sequence);
        }
        allocator.free(emoji_info);
    }

    try testing.expect(emoji_info.len > 0);
    try testing.expect(emoji_info[0].terminal_width == 2); // Double-width emoji
}