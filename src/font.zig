const std = @import("std");
const root = @import("root.zig");
const FontParser = @import("font_parser.zig").FontParser;
const Glyph = @import("glyph.zig").Glyph;

pub const Font = struct {
    allocator: std.mem.Allocator,
    parser: FontParser,
    family_name: []u8,
    style_name: []u8,
    format: root.FontFormat,
    units_per_em: u16,
    metrics: root.Metrics,
    glyph_cache: std.AutoHashMap(u32, Glyph),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, font_data: []const u8) !Self {
        var parser = try FontParser.init(allocator, font_data);

        const family_name = try parser.getFamilyName(allocator);
        const style_name = try parser.getStyleName(allocator);
        const format = try parser.getFormat();
        const units_per_em = try parser.getUnitsPerEm();
        const metrics = try parser.getMetrics();

        return Self{
            .allocator = allocator,
            .parser = parser,
            .family_name = family_name,
            .style_name = style_name,
            .format = format,
            .units_per_em = units_per_em,
            .metrics = metrics,
            .glyph_cache = std.AutoHashMap(u32, Glyph).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.family_name);
        self.allocator.free(self.style_name);
        self.parser.deinit();

        // Clear glyph cache
        var iterator = self.glyph_cache.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.glyph_cache.deinit();
    }

    pub fn getGlyph(self: *Self, codepoint: u32, size: f32) !Glyph {
        const cache_key = (@as(u64, codepoint) << 32) | @as(u32, @bitCast(size));

        if (self.glyph_cache.get(@truncate(cache_key))) |glyph| {
            return glyph;
        }

        // Load glyph from font
        const glyph_index = try self.parser.getGlyphIndex(codepoint);
        if (glyph_index == 0) {
            return root.FontError.GlyphNotFound;
        }

        const glyph = try self.parser.loadGlyph(self.allocator, glyph_index, size);
        try self.glyph_cache.put(@truncate(cache_key), glyph);

        return glyph;
    }

    pub fn hasGlyph(self: *Self, codepoint: u32) bool {
        const glyph_index = self.parser.getGlyphIndex(codepoint) catch return false;
        return glyph_index != 0;
    }

    pub fn getKerning(self: *Self, left_glyph: u32, right_glyph: u32, size: f32) f32 {
        return self.parser.getKerning(left_glyph, right_glyph, size) catch 0.0;
    }

    pub fn getAdvanceWidth(self: *Self, codepoint: u32, size: f32) !f32 {
        const glyph_index = try self.parser.getGlyphIndex(codepoint);
        if (glyph_index == 0) {
            return root.FontError.GlyphNotFound;
        }

        return try self.parser.getAdvanceWidth(glyph_index, size);
    }

    pub fn getLineHeight(self: *Self, size: f32) f32 {
        const scale = size / @as(f32, @floatFromInt(self.units_per_em));
        return self.metrics.line_height * scale;
    }

    pub fn getAscent(self: *Self, size: f32) f32 {
        const scale = size / @as(f32, @floatFromInt(self.units_per_em));
        return self.metrics.ascent * scale;
    }

    pub fn getDescent(self: *Self, size: f32) f32 {
        const scale = size / @as(f32, @floatFromInt(self.units_per_em));
        return self.metrics.descent * scale;
    }

    pub fn measureText(self: *Self, text: []const u8, size: f32) !TextMeasurement {
        var width: f32 = 0;
        const height = self.getLineHeight(size);
        const ascent = self.getAscent(size);
        const descent = self.getDescent(size);

        var utf8_view = std.unicode.Utf8View.init(text) catch {
            return root.FontError.InvalidFontData;
        };
        var iterator = utf8_view.iterator();

        var prev_codepoint: ?u32 = null;

        while (iterator.nextCodepoint()) |codepoint| {
            // Add kerning if we have a previous character
            if (prev_codepoint) |prev| {
                width += self.getKerning(prev, codepoint, size);
            }

            // Add character advance width
            width += self.getAdvanceWidth(codepoint, size) catch 0;
            prev_codepoint = codepoint;
        }

        return TextMeasurement{
            .width = width,
            .height = height,
            .ascent = ascent,
            .descent = descent,
        };
    }

    pub fn supportsScript(self: *Self, script: Script) bool {
        return self.parser.supportsScript(script) catch false;
    }

    pub fn getFamilyName(self: *Self) []const u8 {
        return self.family_name;
    }

    pub fn getStyleName(self: *Self) []const u8 {
        return self.style_name;
    }

    pub fn getFormat(self: *Self) root.FontFormat {
        return self.format;
    }
};

pub const TextMeasurement = struct {
    width: f32,
    height: f32,
    ascent: f32,
    descent: f32,
};

pub const Script = enum {
    latin,
    cyrillic,
    greek,
    arabic,
    hebrew,
    devanagari,
    chinese,
    japanese,
    korean,
    emoji,
    symbols,
    unknown,
};

test "Font basic operations" {
    // This test will be expanded once we have a working parser
    const allocator = std.testing.allocator;

    // Mock font data for testing
    const mock_data = [_]u8{ 0x00, 0x01, 0x00, 0x00 }; // Minimal TTF header

    // For now, just test that the structure compiles
    _ = allocator;
    _ = mock_data;

    try std.testing.expect(true);
}