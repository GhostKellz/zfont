//! Shaping result model.
//!
//! This module defines an honest, self-describing shaping result and a
//! `shape()` entry point that resolves glyphs, advances, script, direction,
//! and source ranges using a *real* parsed font (cmap + hmtx), not the
//! `font_size * 0.6` placeholders used by the experimental gcode shaper.
//!
//! Scope and limitations (kept honest deliberately):
//!   - Glyph ids and advances come from the font's real cmap/hmtx tables.
//!   - `cluster` is the source byte offset (HarfBuzz-style monotonic cluster).
//!   - Complex reordering (BiDi visual order, Arabic joining, Indic reorder)
//!     is NOT applied here. Each glyph carries its logical-order `direction`
//!     and `script` so a higher layer (gcode BiDi) can reorder if desired.
//!   - Codepoints with no glyph in the font are still emitted with
//!     `glyph_id == 0` (.notdef) and zero advance so callers can drive
//!     fallback (see font_set.zig).

const std = @import("std");
const root = @import("root.zig");
const Font = @import("font.zig").Font;
const Script = @import("font.zig").Script;
const detectScript = @import("text_layout.zig").detectScript;

pub const Direction = enum { ltr, rtl };

/// A single shaped glyph in logical (source) order.
pub const ShapedGlyph = struct {
    /// Glyph index from the font cmap (0 = .notdef / not covered).
    glyph_id: u32,
    /// Source Unicode scalar this glyph was shaped from.
    codepoint: u32,
    /// Cluster identifier: byte offset of the source codepoint.
    cluster: u32,
    /// Horizontal advance in pixels at the requested size (from hmtx).
    x_advance: f32,
    /// Vertical advance in pixels (0 for horizontal layout).
    y_advance: f32,
    /// Horizontal placement offset in pixels.
    x_offset: f32,
    /// Vertical placement offset in pixels.
    y_offset: f32,
    /// Logical writing direction for this glyph's script.
    direction: Direction,
    /// Detected script for this glyph.
    script: Script,
    /// Inclusive start byte offset in the source text.
    source_start: u32,
    /// Exclusive end byte offset in the source text.
    source_end: u32,

    /// True when the font has no glyph for this codepoint.
    pub fn isNotdef(self: ShapedGlyph) bool {
        return self.glyph_id == 0;
    }
};

/// Owned result of a `shape()` call.
pub const ShapingResult = struct {
    glyphs: []ShapedGlyph,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ShapingResult) void {
        self.allocator.free(self.glyphs);
    }

    /// Sum of horizontal advances (pixels).
    pub fn totalAdvance(self: ShapingResult) f32 {
        var total: f32 = 0;
        for (self.glyphs) |g| total += g.x_advance;
        return total;
    }

    /// Number of glyphs that the font could not cover (.notdef).
    pub fn notdefCount(self: ShapingResult) usize {
        var n: usize = 0;
        for (self.glyphs) |g| {
            if (g.isNotdef()) n += 1;
        }
        return n;
    }
};

fn scriptDirection(script: Script) Direction {
    return switch (script) {
        .arabic, .hebrew => .rtl,
        else => .ltr,
    };
}

/// Shape `text` with `font` at `size` pixels into a `ShapingResult`.
///
/// Glyph ids and advances are read from the font's real tables. Invalid UTF-8
/// bytes are skipped one byte at a time. The result is in logical order;
/// callers wanting visual order apply BiDi/reordering afterwards.
pub fn shape(
    allocator: std.mem.Allocator,
    font: *Font,
    text: []const u8,
    size: f32,
) !ShapingResult {
    var glyphs: std.ArrayList(ShapedGlyph) = .empty;
    errdefer glyphs.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + seq_len > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[i .. i + seq_len]) catch {
            i += 1;
            continue;
        };

        const script = detectScript(codepoint);
        const glyph_id = font.parser.getGlyphIndex(codepoint) catch 0;
        const advance: f32 = if (glyph_id != 0)
            (font.parser.getAdvanceWidth(glyph_id, size) catch 0)
        else
            0;

        try glyphs.append(allocator, .{
            .glyph_id = glyph_id,
            .codepoint = codepoint,
            .cluster = @intCast(i),
            .x_advance = advance,
            .y_advance = 0,
            .x_offset = 0,
            .y_offset = 0,
            .direction = scriptDirection(script),
            .script = script,
            .source_start = @intCast(i),
            .source_end = @intCast(i + seq_len),
        });

        i += seq_len;
    }

    return .{
        .glyphs = try glyphs.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

const test_font = @import("test_font.zig");

test "shape resolves real glyph ids and advances" {
    const allocator = std.testing.allocator;
    const data = try test_font.build(allocator);
    defer allocator.free(data);

    var font = try Font.init(allocator, data);
    defer font.deinit();

    // "A A": letter, space, letter.
    var result = try shape(allocator, &font, "A A", @floatFromInt(test_font.units_per_em));
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.glyphs.len);

    // Glyph ids come from the real cmap: A->1, space->2, A->1.
    try std.testing.expectEqual(@as(u32, 1), result.glyphs[0].glyph_id);
    try std.testing.expectEqual(@as(u32, 2), result.glyphs[1].glyph_id);
    try std.testing.expectEqual(@as(u32, 1), result.glyphs[2].glyph_id);

    // Advances come from real hmtx (size == unitsPerEm => font units == pixels).
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(test_font.advance_a)),
        result.glyphs[0].x_advance,
        0.01,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(test_font.advance_space)),
        result.glyphs[1].x_advance,
        0.01,
    );
}

test "shape records clusters, script, direction, and source ranges" {
    const allocator = std.testing.allocator;
    const data = try test_font.build(allocator);
    defer allocator.free(data);

    var font = try Font.init(allocator, data);
    defer font.deinit();

    var result = try shape(allocator, &font, "A A", 16.0);
    defer result.deinit();

    // Clusters == byte offsets, monotonic.
    try std.testing.expectEqual(@as(u32, 0), result.glyphs[0].cluster);
    try std.testing.expectEqual(@as(u32, 1), result.glyphs[1].cluster);
    try std.testing.expectEqual(@as(u32, 2), result.glyphs[2].cluster);

    // Source ranges cover each single-byte codepoint.
    try std.testing.expectEqual(@as(u32, 0), result.glyphs[0].source_start);
    try std.testing.expectEqual(@as(u32, 1), result.glyphs[0].source_end);
    try std.testing.expectEqual(@as(u32, 2), result.glyphs[2].source_start);
    try std.testing.expectEqual(@as(u32, 3), result.glyphs[2].source_end);

    // Latin is LTR.
    try std.testing.expectEqual(Script.latin, result.glyphs[0].script);
    try std.testing.expectEqual(Direction.ltr, result.glyphs[0].direction);
}

test "shape emits notdef for uncovered codepoints" {
    const allocator = std.testing.allocator;
    const data = try test_font.build(allocator);
    defer allocator.free(data);

    var font = try Font.init(allocator, data);
    defer font.deinit();

    // 'Z' is not in the fixture cmap; emitted as .notdef with zero advance.
    var result = try shape(allocator, &font, "AZ", @floatFromInt(test_font.units_per_em));
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.glyphs.len);
    try std.testing.expect(!result.glyphs[0].isNotdef());
    try std.testing.expect(result.glyphs[1].isNotdef());
    try std.testing.expectEqual(@as(f32, 0), result.glyphs[1].x_advance);
    try std.testing.expectEqual(@as(usize, 1), result.notdefCount());
}

test "shape handles multi-byte utf8 source ranges" {
    const allocator = std.testing.allocator;
    const data = try test_font.build(allocator);
    defer allocator.free(data);

    var font = try Font.init(allocator, data);
    defer font.deinit();

    // "Aα" : 'A' (1 byte) + Greek alpha (2 bytes, uncovered here).
    var result = try shape(allocator, &font, "A\u{03B1}", 16.0);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.glyphs.len);
    try std.testing.expectEqual(@as(u32, 1), result.glyphs[1].source_start);
    try std.testing.expectEqual(@as(u32, 3), result.glyphs[1].source_end);
    try std.testing.expectEqual(Script.greek, result.glyphs[1].script);
}
