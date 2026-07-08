//! Deterministic in-memory TrueType font builder for tests.
//!
//! Rather than shipping a binary `.ttf` fixture (with the licensing and
//! reviewability problems that brings), tests generate a tiny but *valid*
//! glyf-based font at runtime with known metrics. This keeps parser tests
//! fixture-backed and fully reproducible.
//!
//! The generated font contains:
//!   - `head`, `maxp`, `hhea`, `hmtx`, `cmap` (format 4), `name`, `OS/2`,
//!     `loca`, `glyf`
//!   - glyph 0: `.notdef` (empty)
//!   - glyph 1: `'A'` (0x41) — a single triangular contour
//!   - glyph 2: `' '` (0x20) — empty (space)
//!
//! Known values used by tests:
//!   unitsPerEm = 1000, ascent = 800, descent = -200, lineGap = 100
//!   advance widths: notdef = 500, A = 600, space = 250
//!   OS/2 sxHeight = 500, sCapHeight = 700
//!   family = "ZFontTest", subfamily = "Regular"

const std = @import("std");

pub const units_per_em: u16 = 1000;
pub const ascent: i16 = 800;
pub const descent: i16 = -200;
pub const line_gap: i16 = 100;
pub const advance_notdef: u16 = 500;
pub const advance_a: u16 = 600;
pub const advance_space: u16 = 250;
pub const x_height: i16 = 500;
pub const cap_height: i16 = 700;
pub const family_name = "ZFontTest";
pub const style_name = "Regular";
pub const num_glyphs: u16 = 3;

fn appendU16(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
    try buf.append(a, @intCast(v >> 8));
    try buf.append(a, @intCast(v & 0xFF));
}

fn appendI16(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: i16) !void {
    try appendU16(buf, a, @bitCast(v));
}

fn appendU32(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
    try buf.append(a, @intCast((v >> 24) & 0xFF));
    try buf.append(a, @intCast((v >> 16) & 0xFF));
    try buf.append(a, @intCast((v >> 8) & 0xFF));
    try buf.append(a, @intCast(v & 0xFF));
}

fn appendUtf16Be(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| try appendU16(buf, a, c); // ASCII → UTF-16BE
}

const Table = struct { tag: [4]u8, data: []u8 };

/// Build the font mapping `'A'` (0x41). Caller owns the returned slice.
pub fn build(allocator: std.mem.Allocator) ![]u8 {
    return buildLetter(allocator, 'A');
}

/// Build a font mapping `space` (0x20) and a single BMP `letter` codepoint
/// (which must be > 0x20 so the cmap segments stay sorted). Used by
/// coverage/fallback tests that need fonts with disjoint glyph coverage.
/// Caller owns the returned slice.
pub fn buildLetter(allocator: std.mem.Allocator, letter: u16) ![]u8 {
    std.debug.assert(letter > 0x20 and letter < 0xFFFF);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // --- glyf + loca ---------------------------------------------------
    // Glyph 1 = 'A': one contour, triangle (3 on-curve points).
    var glyf: std.ArrayList(u8) = .empty;
    // notdef (glyph 0): empty -> zero length.
    const loca_notdef_end: u32 = @intCast(glyf.items.len);
    // glyph 1 'A'
    try appendI16(&glyf, a, 1); // numberOfContours
    try appendI16(&glyf, a, 100); // xMin
    try appendI16(&glyf, a, 0); // yMin
    try appendI16(&glyf, a, 500); // xMax
    try appendI16(&glyf, a, 700); // yMax
    try appendU16(&glyf, a, 2); // endPtsOfContours[0] = 2 (3 points)
    try appendU16(&glyf, a, 0); // instructionLength
    // 3 points, all on-curve, using i16 (not short) deltas.
    // flags: ON_CURVE only (0x01) for each.
    try glyf.append(a, 0x01);
    try glyf.append(a, 0x01);
    try glyf.append(a, 0x01);
    // x deltas (i16): 100, 300, -400  -> x = 100, 400, 0
    try appendI16(&glyf, a, 100);
    try appendI16(&glyf, a, 300);
    try appendI16(&glyf, a, -400);
    // y deltas (i16): 0, 700, -700    -> y = 0, 700, 0
    try appendI16(&glyf, a, 0);
    try appendI16(&glyf, a, 700);
    try appendI16(&glyf, a, -700);
    // Short loca stores offset/2, so glyf offsets must be even; pad if needed.
    while (glyf.items.len % 2 != 0) try glyf.append(a, 0);
    const loca_a_end: u32 = @intCast(glyf.items.len);
    // glyph 2 space: empty (same end offset).
    const loca_space_end: u32 = loca_a_end;

    var loca: std.ArrayList(u8) = .empty;
    try appendU16(&loca, a, @intCast(loca_notdef_end / 2)); // glyph 0 start = 0
    try appendU16(&loca, a, @intCast(loca_notdef_end / 2)); // glyph 1 start
    try appendU16(&loca, a, @intCast(loca_a_end / 2)); // glyph 2 start
    try appendU16(&loca, a, @intCast(loca_space_end / 2)); // end

    // --- head ----------------------------------------------------------
    var head: std.ArrayList(u8) = .empty;
    try appendU32(&head, a, 0x00010000); // version
    try appendU32(&head, a, 0x00010000); // fontRevision
    try appendU32(&head, a, 0); // checkSumAdjustment
    try appendU32(&head, a, 0x5F0F3CF5); // magicNumber
    try appendU16(&head, a, 0); // flags
    try appendU16(&head, a, units_per_em); // unitsPerEm  (offset 18)
    try appendU32(&head, a, 0); // created (hi)
    try appendU32(&head, a, 0); // created (lo)
    try appendU32(&head, a, 0); // modified (hi)
    try appendU32(&head, a, 0); // modified (lo)
    try appendI16(&head, a, 0); // xMin
    try appendI16(&head, a, 0); // yMin
    try appendI16(&head, a, 500); // xMax
    try appendI16(&head, a, 700); // yMax
    try appendU16(&head, a, 0); // macStyle
    try appendU16(&head, a, 8); // lowestRecPPEM
    try appendI16(&head, a, 2); // fontDirectionHint
    try appendI16(&head, a, 0); // indexToLocFormat (0 = short) (offset 50)
    try appendI16(&head, a, 0); // glyphDataFormat

    // --- maxp ----------------------------------------------------------
    var maxp: std.ArrayList(u8) = .empty;
    try appendU32(&maxp, a, 0x00010000); // version 1.0
    try appendU16(&maxp, a, num_glyphs); // numGlyphs (offset 4)
    // Remaining v1.0 fields left zero (parser does not read them).
    for (0..13) |_| try appendU16(&maxp, a, 0);

    // --- hhea ----------------------------------------------------------
    var hhea: std.ArrayList(u8) = .empty;
    try appendU32(&hhea, a, 0x00010000); // version
    try appendI16(&hhea, a, ascent); // ascender (offset 4)
    try appendI16(&hhea, a, descent); // descender (offset 6)
    try appendI16(&hhea, a, line_gap); // lineGap (offset 8)
    try appendU16(&hhea, a, 600); // advanceWidthMax
    try appendI16(&hhea, a, 0); // minLeftSideBearing
    try appendI16(&hhea, a, 0); // minRightSideBearing
    try appendI16(&hhea, a, 500); // xMaxExtent
    try appendI16(&hhea, a, 1); // caretSlopeRise
    try appendI16(&hhea, a, 0); // caretSlopeRun
    try appendI16(&hhea, a, 0); // caretOffset
    try appendI16(&hhea, a, 0); // reserved
    try appendI16(&hhea, a, 0); // reserved
    try appendI16(&hhea, a, 0); // reserved
    try appendI16(&hhea, a, 0); // reserved
    try appendI16(&hhea, a, 0); // metricDataFormat
    try appendU16(&hhea, a, num_glyphs); // numberOfHMetrics (offset 34)

    // --- hmtx ----------------------------------------------------------
    var hmtx: std.ArrayList(u8) = .empty;
    try appendU16(&hmtx, a, advance_notdef); // glyph 0 advance
    try appendI16(&hmtx, a, 0); // lsb
    try appendU16(&hmtx, a, advance_a); // glyph 1 advance
    try appendI16(&hmtx, a, 100); // lsb
    try appendU16(&hmtx, a, advance_space); // glyph 2 advance
    try appendI16(&hmtx, a, 0); // lsb

    // --- cmap (format 4) ----------------------------------------------
    // Two coded segments: [0x20,0x20]->space(2), [0x41,0x41]->A(1), plus the
    // mandatory terminating [0xFFFF,0xFFFF] segment. We use idDelta so that
    // codepoint + delta = glyph id (mod 0x10000), idRangeOffset = 0.
    var sub: std.ArrayList(u8) = .empty;
    const seg_count: u16 = 3;
    try appendU16(&sub, a, 4); // format
    try appendU16(&sub, a, 0); // length (patched below)
    try appendU16(&sub, a, 0); // language
    try appendU16(&sub, a, seg_count * 2); // segCountX2
    // searchRange/entrySelector/rangeShift (not used by parser)
    try appendU16(&sub, a, 4); // searchRange = 2*2^floor(log2(seg))
    try appendU16(&sub, a, 1); // entrySelector
    try appendU16(&sub, a, seg_count * 2 - 4); // rangeShift
    // endCode[]
    try appendU16(&sub, a, 0x20);
    try appendU16(&sub, a, letter);
    try appendU16(&sub, a, 0xFFFF);
    try appendU16(&sub, a, 0); // reservedPad
    // startCode[]
    try appendU16(&sub, a, 0x20);
    try appendU16(&sub, a, letter);
    try appendU16(&sub, a, 0xFFFF);
    // idDelta[]: space(0x20)->2 => delta = 2-0x20; letter->1 => delta = 1-letter
    try appendI16(&sub, a, @intCast(2 - 0x20));
    try appendI16(&sub, a, @intCast(1 - @as(i32, letter)));
    try appendI16(&sub, a, 1); // terminator delta
    // idRangeOffset[]
    try appendU16(&sub, a, 0);
    try appendU16(&sub, a, 0);
    try appendU16(&sub, a, 0);
    // Patch subtable length.
    const sub_len: u16 = @intCast(sub.items.len);
    sub.items[2] = @intCast(sub_len >> 8);
    sub.items[3] = @intCast(sub_len & 0xFF);

    var cmap: std.ArrayList(u8) = .empty;
    try appendU16(&cmap, a, 0); // version
    try appendU16(&cmap, a, 1); // numTables
    try appendU16(&cmap, a, 3); // platformID = Windows
    try appendU16(&cmap, a, 1); // encodingID = Unicode BMP
    try appendU32(&cmap, a, 12); // offset to subtable (4 + 8)
    try cmap.appendSlice(a, sub.items);

    // --- name ----------------------------------------------------------
    // Two records: family (id 1) and subfamily (id 2), Windows UTF-16BE.
    var strings: std.ArrayList(u8) = .empty;
    const fam_off: u16 = @intCast(strings.items.len);
    try appendUtf16Be(&strings, a, family_name);
    const fam_len: u16 = @intCast(strings.items.len - fam_off);
    const sty_off: u16 = @intCast(strings.items.len);
    try appendUtf16Be(&strings, a, style_name);
    const sty_len: u16 = @intCast(strings.items.len - sty_off);

    var name: std.ArrayList(u8) = .empty;
    const record_count: u16 = 2;
    const name_header_len: u16 = 6 + record_count * 12;
    try appendU16(&name, a, 0); // format
    try appendU16(&name, a, record_count); // count
    try appendU16(&name, a, name_header_len); // stringOffset
    // record: family
    try appendU16(&name, a, 3); // platformID
    try appendU16(&name, a, 1); // encodingID
    try appendU16(&name, a, 0x0409); // languageID (en-US)
    try appendU16(&name, a, 1); // nameID = family
    try appendU16(&name, a, fam_len);
    try appendU16(&name, a, fam_off);
    // record: subfamily
    try appendU16(&name, a, 3);
    try appendU16(&name, a, 1);
    try appendU16(&name, a, 0x0409);
    try appendU16(&name, a, 2); // nameID = subfamily
    try appendU16(&name, a, sty_len);
    try appendU16(&name, a, sty_off);
    try name.appendSlice(a, strings.items);

    // --- OS/2 (version 4) ---------------------------------------------
    var os2: std.ArrayList(u8) = .empty;
    try appendU16(&os2, a, 4); // version
    try appendI16(&os2, a, 500); // xAvgCharWidth
    try appendU16(&os2, a, 400); // usWeightClass
    try appendU16(&os2, a, 5); // usWidthClass
    try appendU16(&os2, a, 0); // fsType
    // subscript/superscript/strikeout: 10 x i16 = 20 bytes
    for (0..10) |_| try appendI16(&os2, a, 0);
    try os2.append(a, 0); // sFamilyClass hi
    try os2.append(a, 0); // sFamilyClass lo
    for (0..10) |_| try os2.append(a, 0); // panose[10]
    // ulUnicodeRange1..4 (offset 42). Bit 0 = Basic Latin.
    try appendU32(&os2, a, 0x00000001); // range1: bit0 latin
    try appendU32(&os2, a, 0); // range2
    try appendU32(&os2, a, 0); // range3
    try appendU32(&os2, a, 0); // range4
    try appendU32(&os2, a, 0x54455354); // achVendID "TEST"
    try appendU16(&os2, a, 0x0040); // fsSelection (REGULAR)
    try appendU16(&os2, a, 0x20); // usFirstCharIndex
    try appendU16(&os2, a, 0x41); // usLastCharIndex
    try appendI16(&os2, a, ascent); // sTypoAscender
    try appendI16(&os2, a, descent); // sTypoDescender
    try appendI16(&os2, a, line_gap); // sTypoLineGap
    try appendU16(&os2, a, 800); // usWinAscent
    try appendU16(&os2, a, 200); // usWinDescent
    try appendU32(&os2, a, 0); // ulCodePageRange1
    try appendU32(&os2, a, 0); // ulCodePageRange2
    try appendI16(&os2, a, x_height); // sxHeight (offset 86)
    try appendI16(&os2, a, cap_height); // sCapHeight (offset 88)
    try appendU16(&os2, a, 0); // usDefaultChar
    try appendU16(&os2, a, 0x20); // usBreakChar
    try appendU16(&os2, a, 0); // usMaxContext

    // --- assemble sfnt -------------------------------------------------
    // Tables must be listed in the directory sorted by tag.
    const tables = [_]Table{
        .{ .tag = "OS/2".*, .data = os2.items },
        .{ .tag = "cmap".*, .data = cmap.items },
        .{ .tag = "glyf".*, .data = glyf.items },
        .{ .tag = "head".*, .data = head.items },
        .{ .tag = "hhea".*, .data = hhea.items },
        .{ .tag = "hmtx".*, .data = hmtx.items },
        .{ .tag = "loca".*, .data = loca.items },
        .{ .tag = "maxp".*, .data = maxp.items },
        .{ .tag = "name".*, .data = name.items },
    };

    const num_tables: u16 = tables.len;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Offset table.
    try appendU32(&out, allocator, 0x00010000); // sfnt version (TrueType)
    try appendU16(&out, allocator, num_tables);
    try appendU16(&out, allocator, 0); // searchRange (unused by parser)
    try appendU16(&out, allocator, 0); // entrySelector
    try appendU16(&out, allocator, 0); // rangeShift

    // Compute data offsets: after directory, each table 4-byte aligned.
    var data_offset: u32 = 12 + @as(u32, num_tables) * 16;
    var offsets: [tables.len]u32 = undefined;
    for (tables, 0..) |t, i| {
        offsets[i] = data_offset;
        data_offset += @intCast(t.data.len);
        data_offset = std.mem.alignForward(u32, data_offset, 4);
    }

    // Directory entries.
    for (tables, 0..) |t, i| {
        try out.appendSlice(allocator, &t.tag);
        try appendU32(&out, allocator, 0); // checksum (parser ignores)
        try appendU32(&out, allocator, offsets[i]);
        try appendU32(&out, allocator, @intCast(t.data.len));
    }

    // Table data, padded to 4 bytes.
    for (tables) |t| {
        try out.appendSlice(allocator, t.data);
        while (out.items.len % 4 != 0) try out.append(allocator, 0);
    }

    return out.toOwnedSlice(allocator);
}

test "generated font parses with correct metadata" {
    const FontParser = @import("font_parser.zig").FontParser;
    const allocator = std.testing.allocator;

    const data = try build(allocator);
    defer allocator.free(data);

    var parser = try FontParser.init(allocator, data);
    defer parser.deinit();

    try std.testing.expectEqual(units_per_em, try parser.getUnitsPerEm());
    try std.testing.expectEqual(@as(u16, num_glyphs), parser.num_glyphs);
    try std.testing.expectEqual(@as(u16, num_glyphs), parser.num_h_metrics);

    const family = try parser.getFamilyName(allocator);
    defer allocator.free(family);
    try std.testing.expectEqualStrings(family_name, family);

    const style = try parser.getStyleName(allocator);
    defer allocator.free(style);
    try std.testing.expectEqualStrings(style_name, style);
}

test "generated font cmap maps A and space" {
    const FontParser = @import("font_parser.zig").FontParser;
    const allocator = std.testing.allocator;
    const data = try build(allocator);
    defer allocator.free(data);
    var parser = try FontParser.init(allocator, data);
    defer parser.deinit();

    try std.testing.expectEqual(@as(u32, 1), try parser.getGlyphIndex('A'));
    try std.testing.expectEqual(@as(u32, 2), try parser.getGlyphIndex(' '));
    try std.testing.expectEqual(@as(u32, 0), try parser.getGlyphIndex('Z'));
    try std.testing.expectEqual(@as(u32, 0), try parser.getGlyphIndex(0x1F600));
}

test "generated font metrics and advances" {
    const FontParser = @import("font_parser.zig").FontParser;
    const allocator = std.testing.allocator;
    const data = try build(allocator);
    defer allocator.free(data);
    var parser = try FontParser.init(allocator, data);
    defer parser.deinit();

    const m = try parser.getMetrics();
    try std.testing.expectEqual(@as(f32, 800), m.ascent);
    try std.testing.expectEqual(@as(f32, 200), m.descent);
    try std.testing.expectEqual(@as(f32, 1100), m.line_height); // 800 - (-200) + 100
    try std.testing.expectEqual(@as(f32, @floatFromInt(x_height)), m.x_height);
    try std.testing.expectEqual(@as(f32, @floatFromInt(cap_height)), m.cap_height);

    // Advance widths in font units.
    try std.testing.expectEqual(advance_a, try parser.getAdvanceWidthUnits(1));
    try std.testing.expectEqual(advance_space, try parser.getAdvanceWidthUnits(2));

    // Pixel advance at size 1000 == unitsPerEm equals the font-unit value.
    const px = try parser.getAdvanceWidth(1, @floatFromInt(units_per_em));
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(advance_a)), px, 0.01);
}

test "generated font glyph outline" {
    const FontParser = @import("font_parser.zig").FontParser;
    const allocator = std.testing.allocator;
    const data = try build(allocator);
    defer allocator.free(data);
    var parser = try FontParser.init(allocator, data);
    defer parser.deinit();

    // Load 'A' at size == unitsPerEm so scale == 1.0.
    var glyph = try parser.loadGlyph(allocator, 1, @floatFromInt(units_per_em));
    defer glyph.deinit(allocator);

    try std.testing.expect(glyph.outline != null);
    const outline = glyph.outline.?;
    try std.testing.expectEqual(@as(usize, 1), outline.contours.len);
    try std.testing.expectEqual(@as(usize, 3), outline.contours[0].points.len);

    // Triangle points: (100,0), (400,700), (0,0) in font units.
    const p = outline.contours[0].points;
    try std.testing.expectApproxEqAbs(@as(f32, 100), p[0].x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), p[0].y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 400), p[1].x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 700), p[1].y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), p[2].x, 0.01);
}

test "empty glyph (space) has no outline" {
    const FontParser = @import("font_parser.zig").FontParser;
    const allocator = std.testing.allocator;
    const data = try build(allocator);
    defer allocator.free(data);
    var parser = try FontParser.init(allocator, data);
    defer parser.deinit();

    var glyph = try parser.loadGlyph(allocator, 2, 16.0);
    defer glyph.deinit(allocator);
    try std.testing.expect(glyph.outline == null);
}

test "supportsScript uses OS/2 and cmap" {
    const FontParser = @import("font_parser.zig").FontParser;
    const Script = @import("font.zig").Script;
    const allocator = std.testing.allocator;
    const data = try build(allocator);
    defer allocator.free(data);
    var parser = try FontParser.init(allocator, data);
    defer parser.deinit();

    try std.testing.expect(try parser.supportsScript(Script.latin));
    try std.testing.expect(!(try parser.supportsScript(Script.arabic)));
}

test "truncated font data is rejected" {
    const FontParser = @import("font_parser.zig").FontParser;
    const allocator = std.testing.allocator;
    const data = try build(allocator);
    defer allocator.free(data);

    // Chop the file in half so table offsets point past the end.
    const truncated = data[0 .. data.len / 2];
    try std.testing.expectError(
        @import("root.zig").FontError.InvalidFontData,
        FontParser.init(allocator, truncated),
    );
}
