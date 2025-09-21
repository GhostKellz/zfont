const std = @import("std");
const root = @import("root.zig");
const Font = @import("font.zig").Font;
const Glyph = @import("glyph.zig").Glyph;

pub const TextLayout = struct {
    allocator: std.mem.Allocator,
    runs: std.ArrayList(TextRun),
    lines: std.ArrayList(Line),
    total_width: f32,
    total_height: f32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .runs = std.ArrayList(TextRun){},
            .lines = std.ArrayList(Line){},
            .total_width = 0,
            .total_height = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.runs.items) |*run| {
            run.deinit(self.allocator);
        }
        self.runs.deinit(self.allocator);

        for (self.lines.items) |*line| {
            line.deinit(self.allocator);
        }
        self.lines.deinit(self.allocator);
    }

    pub fn layoutText(self: *Self, text: []const u8, font: *Font, options: LayoutOptions) !void {
        // Clear previous layout
        self.clearLayout();

        // Create text runs based on script detection
        try self.createTextRuns(text, font, options);

        // Shape each run
        for (self.runs.items) |*run| {
            try self.shapeRun(run, options);
        }

        // Perform line breaking and positioning
        try self.performLineBreaking(options);

        // Calculate final dimensions
        self.calculateDimensions();
    }

    fn clearLayout(self: *Self) void {
        for (self.runs.items) |*run| {
            run.deinit(self.allocator);
        }
        self.runs.clearAndFree();

        for (self.lines.items) |*line| {
            line.deinit(self.allocator);
        }
        self.lines.clearAndFree();

        self.total_width = 0;
        self.total_height = 0;
    }

    fn createTextRuns(self: *Self, text: []const u8, font: *Font, options: LayoutOptions) !void {
        var utf8_view = std.unicode.Utf8View.init(text) catch {
            return root.FontError.InvalidFontData;
        };
        var iterator = utf8_view.iterator();

        var current_run: ?*TextRun = null;
        var current_script = @import("font.zig").Script.unknown;

        while (iterator.nextCodepoint()) |codepoint| {
            const script = detectScript(codepoint);

            // Start new run if script changes
            if (current_run == null or script != current_script) {
                const run = TextRun{
                    .font = font,
                    .script = script,
                    .direction = detectDirection(script),
                    .size = options.size,
                    .codepoints = std.ArrayList(u32).init(self.allocator),
                    .glyphs = std.ArrayList(ShapedGlyph).init(self.allocator),
                };

                try self.runs.append(run);
                current_run = &self.runs.items[self.runs.items.len - 1];
                current_script = script;
            }

            try current_run.?.codepoints.append(codepoint);
        }
    }

    fn shapeRun(self: *Self, run: *TextRun, options: LayoutOptions) !void {
        var x_offset: f32 = 0;

        for (run.codepoints.items, 0..) |codepoint, i| {
            const glyph = try run.font.getGlyph(codepoint, run.size);

            // Apply kerning with previous glyph
            if (i > 0) {
                const prev_codepoint = run.codepoints.items[i - 1];
                x_offset += run.font.getKerning(prev_codepoint, codepoint, run.size);
            }

            const shaped_glyph = ShapedGlyph{
                .glyph_index = codepoint, // Simplified
                .codepoint = codepoint,
                .x_offset = x_offset,
                .y_offset = 0,
                .x_advance = glyph.advance_width,
                .y_advance = glyph.advance_height,
                .cluster = @as(u32, @intCast(i)),
            };

            try run.glyphs.append(shaped_glyph);
            x_offset += shaped_glyph.x_advance;
        }

        // Apply RTL reversal if needed
        if (run.direction == .rtl) {
            std.mem.reverse(ShapedGlyph, run.glyphs.items);
        }

        // Apply advanced shaping for complex scripts
        if (options.enable_complex_shaping) {
            try self.applyComplexShaping(run);
        }
    }

    fn applyComplexShaping(self: *Self, run: *TextRun) !void {
        // Simplified complex shaping
        // In a full implementation, this would handle:
        // - Ligature substitution
        // - Mark positioning
        // - Contextual alternates
        // - etc.

        switch (run.script) {
            .arabic => try self.applyArabicShaping(run),
            .devanagari => try self.applyIndicShaping(run),
            else => {}, // No complex shaping needed
        }
    }

    fn applyArabicShaping(self: *Self, run: *TextRun) !void {
        // Simplified Arabic shaping
        _ = self;
        _ = run;
        // TODO: Implement Arabic contextual forms
    }

    fn applyIndicShaping(self: *Self, run: *TextRun) !void {
        // Simplified Indic shaping
        _ = self;
        _ = run;
        // TODO: Implement Indic reordering and positioning
    }

    fn performLineBreaking(self: *Self, options: LayoutOptions) !void {
        var current_line = Line.init();
        var line_width: f32 = 0;

        for (self.runs.items) |*run| {
            for (run.glyphs.items) |*glyph| {
                const glyph_width = glyph.x_advance;

                // Check if we need to break the line
                if (options.max_width > 0 and line_width + glyph_width > options.max_width) {
                    if (current_line.glyphs.items.len > 0) {
                        try self.lines.append(current_line);
                        current_line = Line.init();
                        line_width = 0;
                    }
                }

                glyph.x_offset = line_width;
                try current_line.glyphs.append(glyph.*);
                line_width += glyph_width;
            }
        }

        // Add the last line
        if (current_line.glyphs.items.len > 0) {
            try self.lines.append(current_line);
        }

        // Position lines vertically
        var y_offset: f32 = 0;
        for (self.lines.items) |*line| {
            line.y_offset = y_offset;
            y_offset += options.line_height;
        }
    }

    fn calculateDimensions(self: *Self) void {
        self.total_width = 0;
        self.total_height = 0;

        for (self.lines.items) |*line| {
            var line_width: f32 = 0;
            for (line.glyphs.items) |glyph| {
                line_width = @max(line_width, glyph.x_offset + glyph.x_advance);
            }
            self.total_width = @max(self.total_width, line_width);
        }

        if (self.lines.items.len > 0) {
            const last_line = &self.lines.items[self.lines.items.len - 1];
            self.total_height = last_line.y_offset + 20; // Approximate line height
        }
    }

    pub fn getGlyphPositions(self: *Self) []GlyphPosition {
        var positions = std.ArrayList(GlyphPosition).init(self.allocator);

        for (self.lines.items) |line| {
            for (line.glyphs.items) |glyph| {
                positions.append(GlyphPosition{
                    .glyph_index = glyph.glyph_index,
                    .x = glyph.x_offset,
                    .y = line.y_offset + glyph.y_offset,
                }) catch continue;
            }
        }

        return positions.toOwnedSlice() catch &[_]GlyphPosition{};
    }

    pub fn getDimensions(self: *Self) TextDimensions {
        return TextDimensions{
            .width = self.total_width,
            .height = self.total_height,
        };
    }

    pub fn getLineCount(self: *Self) u32 {
        return @as(u32, @intCast(self.lines.items.len));
    }
};

const TextRun = struct {
    font: *Font,
    script: @import("font.zig").Script,
    direction: TextDirection,
    size: f32,
    codepoints: std.ArrayList(u32),
    glyphs: std.ArrayList(ShapedGlyph),

    pub fn deinit(self: *TextRun, allocator: std.mem.Allocator) void {
        self.codepoints.deinit(allocator);
        self.glyphs.deinit(allocator);
    }
};

const Line = struct {
    glyphs: std.ArrayList(ShapedGlyph),
    y_offset: f32,

    pub fn init() Line {
        return Line{
            .glyphs = std.ArrayList(ShapedGlyph){},
            .y_offset = 0,
        };
    }

    pub fn deinit(self: *Line, allocator: std.mem.Allocator) void {
        self.glyphs.deinit(allocator);
    }
};

const ShapedGlyph = struct {
    glyph_index: u32,
    codepoint: u32,
    x_offset: f32,
    y_offset: f32,
    x_advance: f32,
    y_advance: f32,
    cluster: u32,
};

pub const GlyphPosition = struct {
    glyph_index: u32,
    x: f32,
    y: f32,
};

pub const TextDimensions = struct {
    width: f32,
    height: f32,
};

pub const LayoutOptions = struct {
    size: f32,
    max_width: f32 = 0, // 0 = no wrapping
    line_height: f32 = 20,
    alignment: TextAlignment = .left,
    enable_complex_shaping: bool = true,
    enable_kerning: bool = true,
};

pub const TextAlignment = enum {
    left,
    center,
    right,
    justify,
};

pub const TextDirection = enum {
    ltr,
    rtl,
    ttb,
};

fn detectScript(codepoint: u32) @import("font.zig").Script {
    return switch (codepoint) {
        0x0000...0x007F => .latin, // Basic Latin
        0x0080...0x00FF => .latin, // Latin-1 Supplement
        0x0100...0x017F => .latin, // Latin Extended-A
        0x0180...0x024F => .latin, // Latin Extended-B
        0x0400...0x04FF => .cyrillic, // Cyrillic
        0x0370...0x03FF => .greek, // Greek
        0x0600...0x06FF => .arabic, // Arabic
        0x0590...0x05FF => .hebrew, // Hebrew
        0x0900...0x097F => .devanagari, // Devanagari
        0x4E00...0x9FFF => .chinese, // CJK Unified Ideographs
        0x3040...0x309F => .japanese, // Hiragana
        0x30A0...0x30FF => .japanese, // Katakana
        0xAC00...0xD7AF => .korean, // Hangul Syllables
        0x1F600...0x1F64F => .emoji, // Emoticons
        0x1F300...0x1F5FF => .emoji, // Misc Symbols and Pictographs
        else => .unknown,
    };
}

fn detectDirection(script: @import("font.zig").Script) TextDirection {
    return switch (script) {
        .arabic, .hebrew => .rtl,
        else => .ltr,
    };
}

test "TextLayout basic operations" {
    const allocator = std.testing.allocator;

    var layout = TextLayout.init(allocator);
    defer layout.deinit();

    try std.testing.expect(layout.runs.items.len == 0);
    try std.testing.expect(layout.lines.items.len == 0);

    const dimensions = layout.getDimensions();
    try std.testing.expect(dimensions.width == 0);
    try std.testing.expect(dimensions.height == 0);
}

test "Script detection" {
    try std.testing.expect(detectScript('A') == .latin);
    try std.testing.expect(detectScript('α') == .greek);
    try std.testing.expect(detectScript('ا') == .arabic);
    try std.testing.expect(detectScript('中') == .chinese);
    try std.testing.expect(detectScript('😀') == .emoji);
}

test "Direction detection" {
    try std.testing.expect(detectDirection(.latin) == .ltr);
    try std.testing.expect(detectDirection(.arabic) == .rtl);
    try std.testing.expect(detectDirection(.hebrew) == .rtl);
}