const std = @import("std");
const root = @import("root.zig");
const glyph_mod = @import("glyph.zig");
const Glyph = glyph_mod.Glyph;
const Script = @import("font.zig").Script;

/// Pure-Zig TrueType/OpenType (sfnt) table parser.
///
/// Implemented (stable target): table directory, `head`, `maxp`, `hhea`,
/// `hmtx`, `cmap` (formats 4 and 12), `name`, `OS/2`, and `loca`+`glyf`
/// simple-glyph outlines/bounding boxes.
///
/// Documented limitations:
///   - Composite (`glyf` numberOfContours < 0) glyphs expose their bounding
///     box and metrics but no outline yet.
///   - CFF/CFF2 (`OTTO` outlines) are not parsed; only glyf-based fonts have
///     outlines. Metadata still parses for CFF fonts.
///   - Kerning (`kern`/GPOS) is not yet applied.
pub const FontParser = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    tables: std.StringHashMap(TableRecord),
    format: root.FontFormat,

    // Header fields cached at init so lookups do not re-parse each call.
    units_per_em: u16 = 1000,
    num_glyphs: u16 = 0,
    num_h_metrics: u16 = 0,
    index_to_loc_format: i16 = 0,

    const Self = @This();

    pub const TableRecord = struct {
        offset: u32,
        length: u32,
        checksum: u32,
    };

    pub fn init(allocator: std.mem.Allocator, font_data: []const u8) !Self {
        if (font_data.len < 12) {
            return root.FontError.InvalidFontData;
        }

        var parser = Self{
            .allocator = allocator,
            .data = font_data,
            .tables = std.StringHashMap(TableRecord).init(allocator),
            .format = .unknown,
        };
        errdefer parser.deinit();

        try parser.parseOffsetTable();
        try parser.parseHeaderFields();
        return parser;
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.tables.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.tables.deinit();
    }

    // --- Bounds-checked big-endian readers -------------------------------

    fn readU16(self: *Self, offset: usize) !u16 {
        if (offset + 2 > self.data.len) return root.FontError.InvalidFontData;
        return std.mem.readInt(u16, self.data[offset..][0..2], .big);
    }

    fn readI16(self: *Self, offset: usize) !i16 {
        if (offset + 2 > self.data.len) return root.FontError.InvalidFontData;
        return std.mem.readInt(i16, self.data[offset..][0..2], .big);
    }

    fn readU32(self: *Self, offset: usize) !u32 {
        if (offset + 4 > self.data.len) return root.FontError.InvalidFontData;
        return std.mem.readInt(u32, self.data[offset..][0..4], .big);
    }

    // --- Table directory --------------------------------------------------

    fn parseOffsetTable(self: *Self) !void {
        const sfnt_version = try self.readU32(0);
        const num_tables = try self.readU16(4);

        self.format = switch (sfnt_version) {
            0x00010000, 0x74727565 => .truetype, // 1.0 or 'true'
            0x4F54544F => .opentype, // 'OTTO'
            else => .unknown,
        };

        if (self.format == .unknown) {
            return root.FontError.UnsupportedFormat;
        }

        var offset: usize = 12;
        for (0..num_tables) |_| {
            if (offset + 16 > self.data.len) {
                return root.FontError.InvalidFontData;
            }

            const tag = self.data[offset .. offset + 4];
            const checksum = try self.readU32(offset + 4);
            const table_offset = try self.readU32(offset + 8);
            const length = try self.readU32(offset + 12);

            // Reject offsets/lengths that fall outside the file.
            if (table_offset > self.data.len or
                @as(u64, table_offset) + length > self.data.len)
            {
                return root.FontError.InvalidFontData;
            }

            const tag_str = try self.allocator.dupe(u8, tag);
            errdefer self.allocator.free(tag_str);
            const gop = try self.tables.getOrPut(tag_str);
            if (gop.found_existing) {
                // Duplicate table tag: keep the first, drop the copy.
                self.allocator.free(tag_str);
            } else {
                gop.value_ptr.* = .{
                    .offset = table_offset,
                    .length = length,
                    .checksum = checksum,
                };
            }

            offset += 16;
        }
    }

    fn parseHeaderFields(self: *Self) !void {
        if (self.tables.get("head")) |head| {
            self.units_per_em = try self.readU16(head.offset + 18);
            self.index_to_loc_format = try self.readI16(head.offset + 50);
        }
        if (self.units_per_em == 0) return root.FontError.InvalidFontData;

        if (self.tables.get("maxp")) |maxp| {
            self.num_glyphs = try self.readU16(maxp.offset + 4);
        }
        if (self.tables.get("hhea")) |hhea| {
            self.num_h_metrics = try self.readU16(hhea.offset + 34);
        }
    }

    pub fn getFormat(self: *Self) !root.FontFormat {
        return self.format;
    }

    pub fn getUnitsPerEm(self: *Self) !u16 {
        return self.units_per_em;
    }

    // --- name table -------------------------------------------------------

    /// Family name (name ID 1). Caller owns the returned slice.
    pub fn getFamilyName(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        return self.getNameString(allocator, 1) catch
            allocator.dupe(u8, "Unknown");
    }

    /// Subfamily/style name (name ID 2). Caller owns the returned slice.
    pub fn getStyleName(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        return self.getNameString(allocator, 2) catch
            allocator.dupe(u8, "Regular");
    }

    /// Read a name record by name ID, preferring a Windows/Unicode
    /// (UTF-16BE) record and falling back to a Macintosh (Latin-1) record.
    fn getNameString(self: *Self, allocator: std.mem.Allocator, name_id: u16) ![]u8 {
        const name = self.tables.get("name") orelse
            return root.FontError.FontNotFound;

        const base = name.offset;
        const count = try self.readU16(base + 2);
        const string_offset = try self.readU16(base + 4);
        const storage = base + string_offset;

        var best_platform: ?u16 = null;
        var best_off: usize = 0;
        var best_len: usize = 0;

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const rec = base + 6 + i * 12;
            const platform_id = try self.readU16(rec + 0);
            const encoding_id = try self.readU16(rec + 2);
            const rec_name_id = try self.readU16(rec + 6);
            const length = try self.readU16(rec + 8);
            const offset = try self.readU16(rec + 10);
            if (rec_name_id != name_id) continue;

            // Prefer Windows Unicode BMP (3,1); accept Unicode platform (0,*)
            // and Macintosh Roman (1,0) as fallbacks.
            const rank: u16 = if (platform_id == 3 and encoding_id == 1)
                3
            else if (platform_id == 0)
                2
            else if (platform_id == 1 and encoding_id == 0)
                1
            else
                0;
            if (rank == 0) continue;

            if (best_platform == null or rank > best_platform.?) {
                best_platform = rank;
                best_off = storage + offset;
                best_len = length;
            }
        }

        const platform = best_platform orelse return root.FontError.FontNotFound;
        if (best_off + best_len > self.data.len) return root.FontError.InvalidFontData;
        const raw = self.data[best_off .. best_off + best_len];

        // rank 3 and 2 are UTF-16BE encodings; rank 1 is single-byte Latin-1.
        if (platform >= 2) {
            return decodeUtf16Be(allocator, raw);
        }
        return decodeLatin1(allocator, raw);
    }

    fn decodeUtf16Be(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i + 1 < raw.len) : (i += 2) {
            const unit = (@as(u16, raw[i]) << 8) | raw[i + 1];
            var buf: [4]u8 = undefined;
            // Surrogate-aware decoding would need pairing; BMP names cover our
            // use, so lone/invalid units are replaced rather than erroring.
            const cp: u21 = if (unit >= 0xD800 and unit <= 0xDFFF) 0xFFFD else unit;
            const n = std.unicode.utf8Encode(cp, &buf) catch continue;
            try out.appendSlice(allocator, buf[0..n]);
        }
        return out.toOwnedSlice(allocator);
    }

    fn decodeLatin1(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (raw) |b| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@as(u21, b), &buf) catch continue;
            try out.appendSlice(allocator, buf[0..n]);
        }
        return out.toOwnedSlice(allocator);
    }

    // --- Metrics (head / hhea / OS/2) ------------------------------------

    pub fn getMetrics(self: *Self) !root.Metrics {
        const hhea = self.tables.get("hhea") orelse
            return root.FontError.InvalidFontData;

        const ascent = try self.readI16(hhea.offset + 4);
        const descent = try self.readI16(hhea.offset + 6);
        const line_gap = try self.readI16(hhea.offset + 8);

        // Prefer real OS/2 sxHeight/sCapHeight (version >= 2); otherwise
        // approximate from the ascender.
        var x_height: f32 = @as(f32, @floatFromInt(ascent)) * 0.5;
        var cap_height: f32 = @as(f32, @floatFromInt(ascent)) * 0.7;
        if (self.tables.get("OS/2")) |os2| {
            const version = try self.readU16(os2.offset + 0);
            if (version >= 2 and os2.offset + 90 <= self.data.len) {
                x_height = @floatFromInt(try self.readI16(os2.offset + 86));
                cap_height = @floatFromInt(try self.readI16(os2.offset + 88));
            }
        }

        return root.Metrics{
            .ascent = @floatFromInt(ascent),
            .descent = @floatFromInt(-descent), // stored as positive
            .line_height = @floatFromInt(ascent - descent + line_gap),
            .x_height = x_height,
            .cap_height = cap_height,
        };
    }

    // --- cmap -------------------------------------------------------------

    pub fn getGlyphIndex(self: *Self, codepoint: u32) !u32 {
        const cmap = self.tables.get("cmap") orelse return 0;
        const base = cmap.offset;
        const num_subtables = try self.readU16(base + 2);

        // Pick the best Unicode subtable. Prefer (3,10)/(0,4+) format-12 for
        // full-repertoire coverage, then (3,1)/(0,3) BMP.
        var best_off: u32 = 0;
        var best_rank: u8 = 0;
        var i: usize = 0;
        while (i < num_subtables) : (i += 1) {
            const rec = base + 4 + i * 8;
            const platform_id = try self.readU16(rec + 0);
            const encoding_id = try self.readU16(rec + 2);
            const sub_off = try self.readU32(rec + 4);

            const rank: u8 = if (platform_id == 3 and encoding_id == 10)
                4
            else if (platform_id == 0 and encoding_id >= 4)
                3
            else if (platform_id == 3 and encoding_id == 1)
                2
            else if (platform_id == 0)
                1
            else
                0;
            if (rank > best_rank) {
                best_rank = rank;
                best_off = base + sub_off;
            }
        }
        if (best_rank == 0) return 0;

        return self.lookupInSubtable(best_off, codepoint);
    }

    fn lookupInSubtable(self: *Self, subtable_offset: u32, codepoint: u32) !u32 {
        const format = try self.readU16(subtable_offset);
        return switch (format) {
            4 => self.lookupFormat4(subtable_offset, codepoint),
            12 => self.lookupFormat12(subtable_offset, codepoint),
            6 => self.lookupFormat6(subtable_offset, codepoint),
            0 => self.lookupFormat0(subtable_offset, codepoint),
            else => 0,
        };
    }

    fn lookupFormat0(self: *Self, off: u32, codepoint: u32) !u32 {
        if (codepoint > 255) return 0;
        const idx = off + 6 + codepoint; // byte glyph index array
        if (idx >= self.data.len) return 0;
        return self.data[idx];
    }

    fn lookupFormat6(self: *Self, off: u32, codepoint: u32) !u32 {
        const first = try self.readU16(off + 6);
        const count = try self.readU16(off + 8);
        if (codepoint < first or codepoint >= first + count) return 0;
        const idx = off + 10 + (codepoint - first) * 2;
        return @as(u32, try self.readU16(idx));
    }

    fn lookupFormat4(self: *Self, off: u32, codepoint: u32) !u32 {
        if (codepoint > 0xFFFF) return 0; // BMP only
        const c: u16 = @intCast(codepoint);

        const seg_count_x2 = try self.readU16(off + 6);
        const seg_count = seg_count_x2 / 2;
        if (seg_count == 0) return 0;

        const end_codes = off + 14;
        const start_codes = end_codes + seg_count_x2 + 2; // +2 reservedPad
        const id_deltas = start_codes + seg_count_x2;
        const id_range_offsets = id_deltas + seg_count_x2;

        // Find the first segment whose endCode >= c.
        var seg: usize = 0;
        while (seg < seg_count) : (seg += 1) {
            const end_code = try self.readU16(end_codes + seg * 2);
            if (c <= end_code) break;
        }
        if (seg == seg_count) return 0;

        const start_code = try self.readU16(start_codes + seg * 2);
        if (c < start_code) return 0;

        const id_delta = try self.readI16(id_deltas + seg * 2);
        const range_offset_pos = id_range_offsets + seg * 2;
        const id_range_offset = try self.readU16(range_offset_pos);

        if (id_range_offset == 0) {
            const g: u16 = @truncate(@as(u32, c) +% @as(u32, @bitCast(@as(i32, id_delta))));
            return g;
        }

        // Indirect glyph id array lookup.
        const glyph_addr = range_offset_pos + id_range_offset + (c - start_code) * 2;
        const raw = try self.readU16(glyph_addr);
        if (raw == 0) return 0;
        const g: u16 = @truncate(@as(u32, raw) +% @as(u32, @bitCast(@as(i32, id_delta))));
        return g;
    }

    fn lookupFormat12(self: *Self, off: u32, codepoint: u32) !u32 {
        const n_groups = try self.readU32(off + 12);
        var i: usize = 0;
        while (i < n_groups) : (i += 1) {
            const g = off + 16 + i * 12;
            const start_char = try self.readU32(g + 0);
            const end_char = try self.readU32(g + 4);
            const start_glyph = try self.readU32(g + 8);
            if (codepoint >= start_char and codepoint <= end_char) {
                return start_glyph + (codepoint - start_char);
            }
        }
        return 0;
    }

    // --- hmtx -------------------------------------------------------------

    /// Advance width in font units for a glyph index.
    pub fn getAdvanceWidthUnits(self: *Self, glyph_index: u32) !u16 {
        const hmtx = self.tables.get("hmtx") orelse return root.FontError.InvalidFontData;
        if (self.num_h_metrics == 0) return root.FontError.InvalidFontData;
        // Glyphs beyond numberOfHMetrics reuse the last advance width.
        const idx = @min(glyph_index, self.num_h_metrics - 1);
        return self.readU16(hmtx.offset + idx * 4);
    }

    /// Advance width in pixels at the requested pixel size.
    pub fn getAdvanceWidth(self: *Self, glyph_index: u32, size: f32) !f32 {
        const units = self.getAdvanceWidthUnits(glyph_index) catch {
            return size * 0.6; // fallback for fonts without hmtx
        };
        const scale = size / @as(f32, @floatFromInt(self.units_per_em));
        return @as(f32, @floatFromInt(units)) * scale;
    }

    pub fn getKerning(self: *Self, left_glyph: u32, right_glyph: u32, size: f32) !f32 {
        // Legacy `kern` / GPOS pair positioning not yet applied.
        _ = self;
        _ = left_glyph;
        _ = right_glyph;
        _ = size;
        return 0.0;
    }

    // --- loca / glyf ------------------------------------------------------

    /// Byte range [start, end) of a glyph in the `glyf` table, or null when
    /// the glyph is empty (e.g. a space).
    fn glyphRange(self: *Self, glyph_index: u32) !?struct { start: u32, end: u32 } {
        const loca = self.tables.get("loca") orelse return null;
        if (glyph_index >= self.num_glyphs) return null;

        var start: u32 = undefined;
        var end: u32 = undefined;
        if (self.index_to_loc_format == 0) {
            // Short format: offsets stored as value/2.
            start = @as(u32, try self.readU16(loca.offset + glyph_index * 2)) * 2;
            end = @as(u32, try self.readU16(loca.offset + (glyph_index + 1) * 2)) * 2;
        } else {
            start = try self.readU32(loca.offset + glyph_index * 4);
            end = try self.readU32(loca.offset + (glyph_index + 1) * 4);
        }
        if (end <= start) return null; // empty glyph
        return .{ .start = start, .end = end };
    }

    pub fn loadGlyph(self: *Self, allocator: std.mem.Allocator, glyph_index: u32, size: f32) !Glyph {
        var g = try Glyph.init(allocator, size);
        g.index = glyph_index;

        const scale = size / @as(f32, @floatFromInt(self.units_per_em));
        g.advance_width = self.getAdvanceWidth(glyph_index, size) catch g.advance_width;

        const glyf = self.tables.get("glyf");
        const range = self.glyphRange(glyph_index) catch null;
        if (glyf == null or range == null) {
            // No outline (empty glyph, CFF font, or missing glyf).
            return g;
        }

        const goff = glyf.?.offset + range.?.start;
        const number_of_contours = try self.readI16(goff + 0);
        const x_min = try self.readI16(goff + 2);
        const y_min = try self.readI16(goff + 4);
        const x_max = try self.readI16(goff + 6);
        const y_max = try self.readI16(goff + 8);

        // Bounding-box-derived metrics (valid for simple and composite).
        g.bearing_x = @as(f32, @floatFromInt(x_min)) * scale;
        g.bearing_y = @as(f32, @floatFromInt(y_max)) * scale;
        g.width = @intFromFloat(@max(0, @as(f32, @floatFromInt(x_max - x_min)) * scale));
        g.height = @intFromFloat(@max(0, @as(f32, @floatFromInt(y_max - y_min)) * scale));

        if (number_of_contours < 0) {
            // Composite glyph: metrics only for now (documented limitation).
            return g;
        }

        g.outline = try self.parseSimpleGlyph(allocator, goff, @intCast(number_of_contours), scale);
        return g;
    }

    fn parseSimpleGlyph(
        self: *Self,
        allocator: std.mem.Allocator,
        goff: u32,
        num_contours: u16,
        scale: f32,
    ) !glyph_mod.GlyphOutline {
        // endPtsOfContours[num_contours]
        var pos = goff + 10;
        var end_pts = try allocator.alloc(u16, num_contours);
        defer allocator.free(end_pts);
        for (0..num_contours) |i| {
            end_pts[i] = try self.readU16(pos);
            pos += 2;
        }
        const num_points: usize = if (num_contours == 0) 0 else @as(usize, end_pts[num_contours - 1]) + 1;

        // Skip instructions.
        const instruction_length = try self.readU16(pos);
        pos += 2 + instruction_length;

        // Flags (with repeat compression).
        const Flags = struct {
            const ON_CURVE: u8 = 0x01;
            const X_SHORT: u8 = 0x02;
            const Y_SHORT: u8 = 0x04;
            const REPEAT: u8 = 0x08;
            const X_SAME_POS: u8 = 0x10;
            const Y_SAME_POS: u8 = 0x20;
        };

        var flags = try allocator.alloc(u8, num_points);
        defer allocator.free(flags);
        var fi: usize = 0;
        while (fi < num_points) {
            if (pos >= self.data.len) return root.FontError.InvalidFontData;
            const flag = self.data[pos];
            pos += 1;
            flags[fi] = flag;
            fi += 1;
            if (flag & Flags.REPEAT != 0) {
                if (pos >= self.data.len) return root.FontError.InvalidFontData;
                var repeat = self.data[pos];
                pos += 1;
                while (repeat > 0 and fi < num_points) : (repeat -= 1) {
                    flags[fi] = flag;
                    fi += 1;
                }
            }
        }

        // X coordinates (delta encoded).
        var xs = try allocator.alloc(i32, num_points);
        defer allocator.free(xs);
        var x: i32 = 0;
        for (0..num_points) |i| {
            const flag = flags[i];
            if (flag & Flags.X_SHORT != 0) {
                if (pos >= self.data.len) return root.FontError.InvalidFontData;
                const dx: i32 = self.data[pos];
                pos += 1;
                x += if (flag & Flags.X_SAME_POS != 0) dx else -dx;
            } else if (flag & Flags.X_SAME_POS == 0) {
                x += try self.readI16(pos);
                pos += 2;
            }
            xs[i] = x;
        }

        // Y coordinates (delta encoded).
        var ys = try allocator.alloc(i32, num_points);
        defer allocator.free(ys);
        var y: i32 = 0;
        for (0..num_points) |i| {
            const flag = flags[i];
            if (flag & Flags.Y_SHORT != 0) {
                if (pos >= self.data.len) return root.FontError.InvalidFontData;
                const dy: i32 = self.data[pos];
                pos += 1;
                y += if (flag & Flags.Y_SAME_POS != 0) dy else -dy;
            } else if (flag & Flags.Y_SAME_POS == 0) {
                y += try self.readI16(pos);
                pos += 2;
            }
            ys[i] = y;
        }

        // Split points into contours.
        var contours = try allocator.alloc(glyph_mod.Contour, num_contours);
        errdefer allocator.free(contours);
        var start: usize = 0;
        var built: usize = 0;
        errdefer for (0..built) |i| contours[i].deinit(allocator);
        for (0..num_contours) |ci| {
            const end: usize = @as(usize, end_pts[ci]) + 1;
            const count = end - start;
            var pts = try allocator.alloc(glyph_mod.Point, count);
            for (0..count) |pi| {
                const idx = start + pi;
                pts[pi] = .{
                    .x = @as(f32, @floatFromInt(xs[idx])) * scale,
                    .y = @as(f32, @floatFromInt(ys[idx])) * scale,
                    .on_curve = flags[idx] & Flags.ON_CURVE != 0,
                };
            }
            contours[ci] = .{ .points = pts, .is_closed = true };
            built += 1;
            start = end;
        }

        return glyph_mod.GlyphOutline{ .contours = contours, .allocator = allocator };
    }

    // --- Script coverage --------------------------------------------------

    pub fn supportsScript(self: *Self, script: Script) !bool {
        // Prefer explicit OS/2 Unicode range bits; fall back to probing cmap
        // with a representative codepoint (ground-truth coverage).
        if (self.tables.get("OS/2")) |os2| {
            if (scriptUnicodeRangeBit(script)) |bit| {
                const word_index = bit / 32;
                const bit_index: u5 = @intCast(bit % 32);
                const range = try self.readU32(os2.offset + 42 + word_index * 4);
                if (range & (@as(u32, 1) << bit_index) != 0) return true;
                // Bit unset: fall through to cmap probe (some fonts omit bits).
            }
        }
        if (scriptRepresentativeCodepoint(script)) |cp| {
            return (self.getGlyphIndex(cp) catch 0) != 0;
        }
        return false;
    }

    fn scriptUnicodeRangeBit(script: Script) ?u32 {
        return switch (script) {
            .latin => 0, // Basic Latin
            .greek => 7,
            .cyrillic => 9,
            .hebrew => 11,
            .arabic => 13,
            .devanagari => 15,
            .chinese => 59, // CJK Unified Ideographs
            .japanese => 49, // Hiragana
            .korean => 56, // Hangul Syllables
            .symbols => 31, // General Punctuation-ish / symbols
            .emoji => 57, // Enclosed CJK-ish; emoji has no single bit
            .unknown => null,
        };
    }

    fn scriptRepresentativeCodepoint(script: Script) ?u32 {
        return switch (script) {
            .latin => 'A',
            .greek => 0x0391,
            .cyrillic => 0x0410,
            .hebrew => 0x05D0,
            .arabic => 0x0627,
            .devanagari => 0x0905,
            .chinese => 0x4E00,
            .japanese => 0x3042,
            .korean => 0xAC00,
            .symbols => 0x2022,
            .emoji => 0x1F600,
            .unknown => null,
        };
    }
};

test "FontParser rejects short data" {
    const allocator = std.testing.allocator;
    const too_short = [_]u8{ 0x00, 0x01, 0x00 };
    try std.testing.expectError(root.FontError.InvalidFontData, FontParser.init(allocator, &too_short));
}

test "FontParser rejects unknown sfnt version" {
    const allocator = std.testing.allocator;
    const bogus = [_]u8{ 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB };
    try std.testing.expectError(root.FontError.UnsupportedFormat, FontParser.init(allocator, &bogus));
}

// Pull the fixture-backed parser tests into the test build only.
test {
    _ = @import("test_font.zig");
}
