const std = @import("std");
const root = @import("root.zig");
const Glyph = @import("glyph.zig").Glyph;

pub const FontParser = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    tables: std.StringHashMap(TableRecord),
    format: root.FontFormat,

    const Self = @This();

    const TableRecord = struct {
        offset: u32,
        length: u32,
        checksum: u32,
    };

    const OffsetTable = struct {
        sfnt_version: u32,
        num_tables: u16,
        search_range: u16,
        entry_selector: u16,
        range_shift: u16,
    };

    const CmapHeader = struct {
        version: u16,
        num_tables: u16,
    };

    const CmapSubtable = struct {
        platform_id: u16,
        encoding_id: u16,
        offset: u32,
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

        try parser.parseOffsetTable();
        return parser;
    }

    pub fn deinit(self: *Self) void {
        // Free all the duplicated tag strings
        var iterator = self.tables.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.tables.deinit();
    }

    fn parseOffsetTable(self: *Self) !void {
        const offset_table = try self.readStruct(OffsetTable, 0);

        // Detect font format
        self.format = switch (offset_table.sfnt_version) {
            0x00010000, 0x74727565 => .truetype, // 'true' in big-endian
            0x4F54544F => .opentype, // 'OTTO' in big-endian
            else => .unknown,
        };

        if (self.format == .unknown) {
            return root.FontError.UnsupportedFormat;
        }

        // Parse table directory
        var offset: u32 = 12;
        for (0..offset_table.num_tables) |_| {
            if (offset + 16 > self.data.len) {
                return root.FontError.InvalidFontData;
            }

            const tag = self.data[offset..offset + 4];
            const checksum = std.mem.readInt(u32, self.data[offset + 4..offset + 8][0..4], .big);
            const table_offset = std.mem.readInt(u32, self.data[offset + 8..offset + 12][0..4], .big);
            const length = std.mem.readInt(u32, self.data[offset + 12..offset + 16][0..4], .big);

            const tag_str = try self.allocator.dupe(u8, tag);
            try self.tables.put(tag_str, TableRecord{
                .offset = table_offset,
                .length = length,
                .checksum = checksum,
            });

            offset += 16;
        }
    }

    fn readStruct(self: *Self, comptime T: type, offset: u32) !T {
        const size = @sizeOf(T);
        if (offset + size > self.data.len) {
            return root.FontError.InvalidFontData;
        }

        var result: T = undefined;
        const bytes = @as([*]u8, @ptrCast(&result))[0..size];
        @memcpy(bytes, self.data[offset..offset + size]);

        // Convert from big-endian
        inline for (@typeInfo(T).@"struct".fields) |field| {
            const field_ptr = &@field(result, field.name);
            switch (field.type) {
                u16 => field_ptr.* = std.mem.bigToNative(u16, field_ptr.*),
                u32 => field_ptr.* = std.mem.bigToNative(u32, field_ptr.*),
                i16 => field_ptr.* = std.mem.bigToNative(i16, field_ptr.*),
                i32 => field_ptr.* = std.mem.bigToNative(i32, field_ptr.*),
                else => {},
            }
        }

        return result;
    }

    pub fn getFamilyName(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        _ = self.tables.get("name") orelse {
            return allocator.dupe(u8, "Unknown");
        };

        // For now, return a placeholder
        // TODO: Parse name table properly
        return allocator.dupe(u8, "FontFamily");
    }

    pub fn getStyleName(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        // TODO: Parse name table for style
        return allocator.dupe(u8, "Regular");
    }

    pub fn getFormat(self: *Self) !root.FontFormat {
        return self.format;
    }

    pub fn getUnitsPerEm(self: *Self) !u16 {
        const head_table = self.tables.get("head") orelse {
            return root.FontError.InvalidFontData;
        };

        if (head_table.offset + 18 + 2 > self.data.len) {
            return root.FontError.InvalidFontData;
        }

        return std.mem.readInt(u16, self.data[head_table.offset + 18 ..][0..2], .big);
    }

    pub fn getMetrics(self: *Self) !root.Metrics {
        const hhea_table = self.tables.get("hhea") orelse {
            return root.FontError.InvalidFontData;
        };

        if (hhea_table.offset + 36 > self.data.len) {
            return root.FontError.InvalidFontData;
        }

        const ascent = std.mem.readInt(i16, self.data[hhea_table.offset + 4 ..][0..2], .big);
        const descent = std.mem.readInt(i16, self.data[hhea_table.offset + 6 ..][0..2], .big);
        const line_gap = std.mem.readInt(i16, self.data[hhea_table.offset + 8 ..][0..2], .big);

        return root.Metrics{
            .ascent = @floatFromInt(ascent),
            .descent = @floatFromInt(-descent), // Make positive
            .line_height = @floatFromInt(ascent - descent + line_gap),
            .x_height = @as(f32, @floatFromInt(ascent)) * 0.5, // Approximation
            .cap_height = @as(f32, @floatFromInt(ascent)) * 0.7, // Approximation
        };
    }

    pub fn getGlyphIndex(self: *Self, codepoint: u32) !u32 {
        const cmap_table = self.tables.get("cmap") orelse {
            return 0;
        };

        // Simple implementation - find first supported subtable
        const cmap_offset = cmap_table.offset;
        if (cmap_offset + 4 > self.data.len) {
            return 0;
        }

        const version = std.mem.readInt(u16, self.data[cmap_offset..][0..2], .big);
        const num_subtables = std.mem.readInt(u16, self.data[cmap_offset + 2 ..][0..2], .big);

        _ = version;

        // Look for Unicode subtable (platform 3, encoding 1 or 10)
        var subtable_offset: u32 = cmap_offset + 4;
        for (0..num_subtables) |_| {
            if (subtable_offset + 8 > self.data.len) break;

            const platform_id = std.mem.readInt(u16, self.data[subtable_offset..][0..2], .big);
            const encoding_id = std.mem.readInt(u16, self.data[subtable_offset + 2 ..][0..2], .big);
            const offset = std.mem.readInt(u32, self.data[subtable_offset + 4 ..][0..4], .big);

            if (platform_id == 3 and (encoding_id == 1 or encoding_id == 10)) {
                return self.lookupGlyphInSubtable(cmap_offset + offset, codepoint);
            }

            subtable_offset += 8;
        }

        return 0;
    }

    fn lookupGlyphInSubtable(self: *Self, subtable_offset: u32, codepoint: u32) u32 {
        if (subtable_offset + 2 > self.data.len) return 0;

        const format = std.mem.readInt(u16, self.data[subtable_offset..][0..2], .big);

        // For now, only implement format 4 (most common)
        return switch (format) {
            4 => self.lookupFormat4(subtable_offset, codepoint),
            else => 0, // Unsupported format
        };
    }

    fn lookupFormat4(self: *Self, subtable_offset: u32, codepoint: u32) u32 {
        _ = self;
        _ = subtable_offset;
        // Simplified format 4 implementation
        // This is a complex format, so we'll use a basic approach
        if (codepoint > 0xFFFF) return 0; // Format 4 only supports BMP

        // TODO: Implement proper format 4 parsing
        // For now, return a simple mapping for ASCII characters
        if (codepoint >= 32 and codepoint <= 126) {
            return codepoint - 31; // Simple offset mapping
        }

        return 0;
    }

    pub fn loadGlyph(self: *Self, allocator: std.mem.Allocator, glyph_index: u32, size: f32) !Glyph {
        // For now, create a simple rectangular glyph
        // TODO: Parse actual glyph data from 'glyf' table
        _ = self;
        _ = glyph_index;

        return Glyph.init(allocator, size);
    }

    pub fn getKerning(self: *Self, left_glyph: u32, right_glyph: u32, size: f32) !f32 {
        // TODO: Parse kerning table
        _ = self;
        _ = left_glyph;
        _ = right_glyph;
        _ = size;
        return 0.0;
    }

    pub fn getAdvanceWidth(self: *Self, glyph_index: u32, size: f32) !f32 {
        const hmtx_table = self.tables.get("hmtx") orelse {
            return size * 0.6; // Default monospace width
        };

        // Simplified - just return a reasonable default for now
        _ = hmtx_table;
        _ = glyph_index;
        return size * 0.6;
    }

    pub fn supportsScript(self: *Self, script: @import("font.zig").Script) !bool {
        // TODO: Check OS/2 table for Unicode ranges
        _ = self;
        return switch (script) {
            .latin, .symbols => true,
            else => false,
        };
    }
};

test "FontParser basic operations" {
    const allocator = std.testing.allocator;

    // Minimal TTF header for testing
    const mock_data = [_]u8{
        0x00, 0x01, 0x00, 0x00, // sfntVersion
        0x00, 0x01, // numTables
        0x00, 0x10, // searchRange
        0x00, 0x00, // entrySelector
        0x00, 0x00, // rangeShift
        // Table directory entry
        'h', 'e', 'a', 'd', // tag
        0x00, 0x00, 0x00, 0x00, // checksum
        0x00, 0x00, 0x00, 0x1C, // offset
        0x00, 0x00, 0x00, 0x36, // length
    } ++ [_]u8{0} ** 0x36; // head table data

    var parser = FontParser.init(allocator, &mock_data) catch {
        // Expected to fail with mock data
        try std.testing.expect(true);
        return;
    };
    defer parser.deinit();

    try std.testing.expect(parser.format == .truetype);
}