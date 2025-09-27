const std = @import("std");
const root = @import("root.zig");
const Font = @import("font.zig").Font;
const Unicode = @import("unicode.zig").Unicode;

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
        var current_run: ?*TextRun = null;
        var current_script = @import("font.zig").Script.unknown;

        var iterator = Unicode.codePointIterator(text);
        while (iterator.next()) |cp| {
            const codepoint: u32 = cp.code;
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
        var last_visible_codepoint: ?u32 = null;
        var property_cache = Unicode.PropertyCache.init();
        var grapheme_state = Unicode.GraphemeBreakState{};
        var current_cluster: u32 = 0;

        for (run.codepoints.items, 0..) |codepoint, i| {
            if (i > 0) {
                const prev = run.codepoints.items[i - 1];
                if (Unicode.isGraphemeBoundary(prev, codepoint, &grapheme_state)) {
                    current_cluster = @intCast(i);
                }
            }

            const props = property_cache.get(codepoint);

            if (props.is_control) {
                continue;
            }

            if (options.enable_kerning) {
                if (last_visible_codepoint) |prev| {
                    if (props.width != .zero) {
                        x_offset += run.font.getKerning(prev, codepoint, run.size);
                    }
                }
            }

            const glyph = run.font.getGlyph(codepoint, run.size) catch |err| {
                if (err == root.FontError.GlyphNotFound and props.width == .zero) {
                    continue;
                }
                return err;
            };

            var x_advance = glyph.advance_width;
            if (props.width == .zero) {
                x_advance = 0;
            }

            const shaped_glyph = ShapedGlyph{
                .glyph_index = glyph.index,
                .codepoint = codepoint,
                .x_offset = x_offset,
                .y_offset = 0,
                .x_advance = x_advance,
                .y_advance = glyph.advance_height,
                .cluster = current_cluster,
            };

            try run.glyphs.append(shaped_glyph);

            if (props.width != .zero) {
                x_offset += x_advance;
                last_visible_codepoint = codepoint;
            }
        }

        if (run.direction == .rtl) {
            std.mem.reverse(ShapedGlyph, run.glyphs.items);
        }

        if (options.enable_complex_shaping) {
            try self.applyComplexShaping(run);
        }
    }

    fn applyComplexShaping(self: *Self, run: *TextRun) !void {
        switch (run.script) {
            .arabic => try self.applyArabicShaping(run),
            .devanagari => try self.applyIndicShaping(run),
            else => {},
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
    if (Unicode.getEmojiProperty(codepoint) != .None) {
        return .emoji;
    }

    const script_prop = Unicode.getScriptProperty(codepoint);

    return switch (script_prop) {
        .Latin => .latin,
        .Greek => .greek,
        .Cyrillic => .cyrillic,
        .Hebrew => .hebrew,
        .Arabic => .arabic,
        .Devanagari => .devanagari,
        .Han => .chinese,
        .Hiragana, .Katakana => .japanese,
        .Hangul => .korean,
        .Common, .Inherited => .symbols,
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
