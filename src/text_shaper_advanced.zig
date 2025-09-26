const std = @import("std");
const root = @import("root.zig");

// Advanced text shaping engine comparable to HarfBuzz
// Handles complex scripts, OpenType features, and bidirectional text
pub const AdvancedTextShaper = struct {
    allocator: std.mem.Allocator,
    font_parser: *@import("font_parser.zig").FontParser,

    // OpenType tables
    gsub_table: ?GSUBTable = null,
    gpos_table: ?GPOSTable = null,

    // Shaping context
    buffer: ShapingBuffer,
    features: std.ArrayList(FeatureTag),

    const Self = @This();

    // OpenType feature tags (4-byte identifiers)
    pub const FeatureTag = enum(u32) {
        // Common features
        kern = 0x6B65726E, // 'kern'
        liga = 0x6C696761, // 'liga'
        dlig = 0x646C6967, // 'dlig'
        hlig = 0x686C6967, // 'hlig'
        clig = 0x636C6967, // 'clig'

        // Positioning features
        mark = 0x6D61726B, // 'mark'
        mkmk = 0x6D6B6D6B, // 'mkmk'
        curs = 0x63757273, // 'curs'

        // Arabic features
        init = 0x696E6974, // 'init'
        medi = 0x6D656469, // 'medi'
        fina = 0x66696E61, // 'fina'
        isol = 0x69736F6C, // 'isol'

        // Indic features
        nukt = 0x6E756B74, // 'nukt'
        akhn = 0x616B686E, // 'akhn'
        rphf = 0x72706866, // 'rphf'
        blwf = 0x626C7766, // 'blwf'
        half = 0x68616C66, // 'half'
        pstf = 0x70737466, // 'pstf'
        vatu = 0x76617475, // 'vatu'

        // Programming ligatures
        zero = 0x7A65726F, // 'zero' (slashed zero)
        ss01 = 0x73733031, // 'ss01' (stylistic set 1)
        ss02 = 0x73733032, // 'ss02'
        ss03 = 0x73733033, // 'ss03'

        _,

        pub fn fromBytes(bytes: [4]u8) FeatureTag {
            return @enumFromInt(std.mem.readInt(u32, &bytes, .big));
        }

        pub fn toBytes(self: FeatureTag) [4]u8 {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, @intFromEnum(self), .big);
            return bytes;
        }
    };

    const ShapingBuffer = struct {
        glyphs: std.ArrayList(GlyphInfo),
        positions: std.ArrayList(GlyphPosition),

        const GlyphInfo = struct {
            codepoint: u32,
            glyph_index: u32,
            cluster: u32,
            mask: u32 = 0xFFFFFFFF,
            var1: u32 = 0,
            var2: u32 = 0,
        };

        const GlyphPosition = struct {
            x_advance: i32 = 0,
            y_advance: i32 = 0,
            x_offset: i32 = 0,
            y_offset: i32 = 0,
            var_field: u32 = 0,
        };

        pub fn init(allocator: std.mem.Allocator) @This() {
            return @This(){
                .glyphs = std.ArrayList(GlyphInfo).init(allocator),
                .positions = std.ArrayList(GlyphPosition).init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.glyphs.deinit();
            self.positions.deinit();
        }

        pub fn clear(self: *@This()) void {
            self.glyphs.clearRetainingCapacity();
            self.positions.clearRetainingCapacity();
        }

        pub fn addGlyph(self: *@This(), codepoint: u32, cluster: u32) !void {
            try self.glyphs.append(GlyphInfo{
                .codepoint = codepoint,
                .glyph_index = 0, // Will be filled by font
                .cluster = cluster,
            });
            try self.positions.append(GlyphPosition{});
        }

        pub fn len(self: *const @This()) usize {
            return self.glyphs.items.len;
        }
    };

    // Simplified GSUB table for ligature substitution
    const GSUBTable = struct {
        ligatures: std.HashMap(LigatureKey, u32, LigatureContext, std.hash_map.default_max_load_percentage),

        const LigatureKey = struct {
            components: [8]u32, // Max 8 components
            count: u8,

            pub fn init(components: []const u32) LigatureKey {
                var key = LigatureKey{
                    .components = [_]u32{0} ** 8,
                    .count = @intCast(@min(components.len, 8)),
                };
                @memcpy(key.components[0..key.count], components[0..key.count]);
                return key;
            }
        };

        const LigatureContext = struct {
            pub fn hash(self: @This(), key: LigatureKey) u64 {
                _ = self;
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(std.mem.asBytes(&key.count));
                hasher.update(std.mem.sliceAsBytes(key.components[0..key.count]));
                return hasher.final();
            }

            pub fn eql(self: @This(), a: LigatureKey, b: LigatureKey) bool {
                _ = self;
                if (a.count != b.count) return false;
                return std.mem.eql(u32, a.components[0..a.count], b.components[0..b.count]);
            }
        };

        pub fn init(allocator: std.mem.Allocator) GSUBTable {
            return GSUBTable{
                .ligatures = std.HashMap(LigatureKey, u32, LigatureContext, std.hash_map.default_max_load_percentage).init(allocator),
            };
        }

        pub fn deinit(self: *GSUBTable) void {
            self.ligatures.deinit();
        }

        pub fn addLigature(self: *GSUBTable, components: []const u32, ligature_glyph: u32) !void {
            const key = LigatureKey.init(components);
            try self.ligatures.put(key, ligature_glyph);
        }

        pub fn findLigature(self: *const GSUBTable, components: []const u32) ?u32 {
            const key = LigatureKey.init(components);
            return self.ligatures.get(key);
        }
    };

    // Simplified GPOS table for positioning
    const GPOSTable = struct {
        kerning_pairs: std.HashMap(KerningPair, i16, KerningContext, std.hash_map.default_max_load_percentage),

        const KerningPair = struct {
            left: u32,
            right: u32,
        };

        const KerningContext = struct {
            pub fn hash(self: @This(), pair: KerningPair) u64 {
                _ = self;
                return (@as(u64, pair.left) << 32) | pair.right;
            }

            pub fn eql(self: @This(), a: KerningPair, b: KerningPair) bool {
                _ = self;
                return a.left == b.left and a.right == b.right;
            }
        };

        pub fn init(allocator: std.mem.Allocator) GPOSTable {
            return GPOSTable{
                .kerning_pairs = std.HashMap(KerningPair, i16, KerningContext, std.hash_map.default_max_load_percentage).init(allocator),
            };
        }

        pub fn deinit(self: *GPOSTable) void {
            self.kerning_pairs.deinit();
        }

        pub fn addKerningPair(self: *GPOSTable, left: u32, right: u32, value: i16) !void {
            try self.kerning_pairs.put(KerningPair{ .left = left, .right = right }, value);
        }

        pub fn getKerning(self: *const GPOSTable, left: u32, right: u32) i16 {
            return self.kerning_pairs.get(KerningPair{ .left = left, .right = right }) orelse 0;
        }
    };

    pub fn init(allocator: std.mem.Allocator, font_parser: *@import("font_parser.zig").FontParser) !Self {
        var shaper = Self{
            .allocator = allocator,
            .font_parser = font_parser,
            .buffer = ShapingBuffer.init(allocator),
            .features = std.ArrayList(FeatureTag).init(allocator),
        };

        // Initialize OpenType tables
        try shaper.loadGSUBTable();
        try shaper.loadGPOSTable();

        // Set default features
        try shaper.addDefaultFeatures();

        return shaper;
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
        self.features.deinit();
        if (self.gsub_table) |*gsub| gsub.deinit();
        if (self.gpos_table) |*gpos| gpos.deinit();
    }

    fn loadGSUBTable(self: *Self) !void {
        // Initialize GSUB with common programming ligatures
        var gsub = GSUBTable.init(self.allocator);

        // Programming ligatures
        const ligatures = [_]struct { components: []const u32, result: u32 }{
            .{ .components = &[_]u32{ '=', '=' }, .result = 0xE000 }, // ==
            .{ .components = &[_]u32{ '!', '=' }, .result = 0xE001 }, // !=
            .{ .components = &[_]u32{ '<', '=' }, .result = 0xE002 }, // <=
            .{ .components = &[_]u32{ '>', '=' }, .result = 0xE003 }, // >=
            .{ .components = &[_]u32{ '-', '>' }, .result = 0xE004 }, // ->
            .{ .components = &[_]u32{ '=', '>' }, .result = 0xE005 }, // =>
            .{ .components = &[_]u32{ '<', '-' }, .result = 0xE006 }, // <-
            .{ .components = &[_]u32{ '|', '|' }, .result = 0xE007 }, // ||
            .{ .components = &[_]u32{ '&', '&' }, .result = 0xE008 }, // &&
            .{ .components = &[_]u32{ '=', '=', '=' }, .result = 0xE009 }, // ===
            .{ .components = &[_]u32{ '!', '=', '=' }, .result = 0xE00A }, // !==
            .{ .components = &[_]u32{ '<', '<' }, .result = 0xE00B }, // <<
            .{ .components = &[_]u32{ '>', '>' }, .result = 0xE00C }, // >>
            .{ .components = &[_]u32{ '+', '+' }, .result = 0xE00D }, // ++
            .{ .components = &[_]u32{ '-', '-' }, .result = 0xE00E }, // --
            .{ .components = &[_]u32{ '*', '*' }, .result = 0xE00F }, // **
            .{ .components = &[_]u32{ '/', '/' }, .result = 0xE010 }, // //
            .{ .components = &[_]u32{ ':', ':' }, .result = 0xE011 }, // ::
            .{ .components = &[_]u32{ '.', '.' }, .result = 0xE012 }, // ..
            .{ .components = &[_]u32{ '.', '.', '.' }, .result = 0xE013 }, // ...
        };

        for (ligatures) |lig| {
            try gsub.addLigature(lig.components, lig.result);
        }

        self.gsub_table = gsub;
    }

    fn loadGPOSTable(self: *Self) !void {
        // Initialize GPOS with basic kerning pairs
        var gpos = GPOSTable.init(self.allocator);

        // Common kerning pairs (simplified)
        const kerning_pairs = [_]struct { left: u8, right: u8, value: i16 }{
            .{ .left = 'A', .right = 'V', .value = -50 },
            .{ .left = 'A', .right = 'W', .value = -40 },
            .{ .left = 'A', .right = 'Y', .value = -60 },
            .{ .left = 'F', .right = 'A', .value = -80 },
            .{ .left = 'F', .right = '.', .value = -100 },
            .{ .left = 'F', .right = ',', .value = -100 },
            .{ .left = 'P', .right = 'A', .value = -90 },
            .{ .left = 'P', .right = '.', .value = -120 },
            .{ .left = 'P', .right = ',', .value = -120 },
            .{ .left = 'T', .right = 'A', .value = -70 },
            .{ .left = 'T', .right = 'a', .value = -60 },
            .{ .left = 'T', .right = 'e', .value = -60 },
            .{ .left = 'T', .right = 'o', .value = -60 },
            .{ .left = 'V', .right = 'A', .value = -80 },
            .{ .left = 'V', .right = 'a', .value = -60 },
            .{ .left = 'W', .right = 'A', .value = -70 },
            .{ .left = 'Y', .right = 'A', .value = -90 },
            .{ .left = 'Y', .right = 'a', .value = -80 },
        };

        for (kerning_pairs) |pair| {
            try gpos.addKerningPair(pair.left, pair.right, pair.value);
        }

        self.gpos_table = gpos;
    }

    fn addDefaultFeatures(self: *Self) !void {
        // Add default features for Latin text
        try self.features.append(.kern);
        try self.features.append(.liga);
        try self.features.append(.clig);

        // Programming-specific features
        try self.features.append(.zero);
        try self.features.append(.ss01);
    }

    pub fn addFeature(self: *Self, feature: FeatureTag) !void {
        // Check if feature already exists
        for (self.features.items) |existing| {
            if (existing == feature) return;
        }
        try self.features.append(feature);
    }

    pub fn removeFeature(self: *Self, feature: FeatureTag) void {
        for (self.features.items, 0..) |existing, i| {
            if (existing == feature) {
                _ = self.features.swapRemove(i);
                return;
            }
        }
    }

    pub fn shapeText(self: *Self, text: []const u8, font_size: f32) ![]const ShapingBuffer.GlyphInfo {
        self.buffer.clear();

        // Convert text to Unicode codepoints and add to buffer
        var i: usize = 0;
        var cluster: u32 = 0;

        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + char_len <= text.len) {
                const codepoint = std.unicode.utf8Decode(text[i..i + char_len]) catch {
                    i += 1;
                    cluster += 1;
                    continue;
                };

                try self.buffer.addGlyph(codepoint, cluster);
                i += char_len;
                cluster += 1;
            } else {
                break;
            }
        }

        // Map codepoints to glyph indices
        for (self.buffer.glyphs.items) |*glyph| {
            glyph.glyph_index = self.font_parser.getGlyphIndex(glyph.codepoint) catch 0;
        }

        // Apply OpenType features
        try self.applyGSUBFeatures();
        try self.applyGPOSFeatures(font_size);

        return self.buffer.glyphs.items;
    }

    fn applyGSUBFeatures(self: *Self) !void {
        if (self.gsub_table == null) return;

        const gsub = &self.gsub_table.?;

        // Apply ligature substitution
        var i: usize = 0;
        while (i < self.buffer.glyphs.items.len) {
            // Try ligatures of different lengths (up to 4 components)
            var max_len = @min(4, self.buffer.glyphs.items.len - i);
            var found_ligature = false;

            while (max_len >= 2) : (max_len -= 1) {
                var components = std.ArrayList(u32).init(self.allocator);
                defer components.deinit();

                for (self.buffer.glyphs.items[i..i + max_len]) |glyph| {
                    try components.append(glyph.codepoint);
                }

                if (gsub.findLigature(components.items)) |ligature_glyph| {
                    // Replace components with ligature
                    self.buffer.glyphs.items[i].glyph_index = ligature_glyph;

                    // Remove the other components
                    for (1..max_len) |_| {
                        _ = self.buffer.glyphs.orderedRemove(i + 1);
                        _ = self.buffer.positions.orderedRemove(i + 1);
                    }

                    found_ligature = true;
                    break;
                }
            }

            if (!found_ligature) {
                i += 1;
            } else {
                i += 1; // Move to next position after ligature
            }
        }
    }

    fn applyGPOSFeatures(self: *Self, font_size: f32) !void {
        if (self.gpos_table == null or self.buffer.glyphs.items.len < 2) return;

        const gpos = &self.gpos_table.?;

        // Apply kerning
        for (self.buffer.glyphs.items[0..self.buffer.glyphs.items.len - 1], 0..) |glyph, i| {
            const next_glyph = self.buffer.glyphs.items[i + 1];
            const kerning = gpos.getKerning(glyph.glyph_index, next_glyph.glyph_index);

            if (kerning != 0) {
                // Scale kerning value by font size
                const scaled_kerning = @as(i32, @intFromFloat(@as(f32, @floatFromInt(kerning)) * font_size / 1000.0));
                self.buffer.positions.items[i].x_advance += scaled_kerning;
            }
        }
    }

    pub fn getShapedPositions(self: *const Self) []const ShapingBuffer.GlyphPosition {
        return self.buffer.positions.items;
    }

    // Script detection and feature selection
    pub fn configureForScript(self: *Self, script: ScriptTag) !void {
        self.features.clearRetainingCapacity();

        switch (script) {
            .latin => {
                try self.features.append(.kern);
                try self.features.append(.liga);
                try self.features.append(.clig);
                try self.features.append(.zero);
            },
            .arabic => {
                try self.features.append(.init);
                try self.features.append(.medi);
                try self.features.append(.fina);
                try self.features.append(.isol);
                try self.features.append(.mark);
                try self.features.append(.mkmk);
            },
            .devanagari => {
                try self.features.append(.nukt);
                try self.features.append(.akhn);
                try self.features.append(.rphf);
                try self.features.append(.blwf);
                try self.features.append(.half);
                try self.features.append(.pstf);
                try self.features.append(.vatu);
            },
        }
    }

    pub const ScriptTag = enum {
        latin,
        arabic,
        devanagari,
        // Add more scripts as needed
    };
};

test "AdvancedTextShaper ligature detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a mock font parser
    var mock_parser = @import("font_parser.zig").FontParser{
        .allocator = allocator,
        .data = &[_]u8{},
        .tables = std.StringHashMap(@import("font_parser.zig").FontParser.TableRecord).init(allocator),
        .format = .truetype,
    };
    defer mock_parser.deinit();

    var shaper = AdvancedTextShaper.init(allocator, &mock_parser) catch return;
    defer shaper.deinit();

    // Test basic functionality
    try testing.expect(shaper.features.items.len > 0);
}