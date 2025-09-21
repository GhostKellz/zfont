const std = @import("std");
const root = @import("root.zig");
const Font = @import("font.zig").Font;
const TextLayout = @import("text_layout.zig");

pub const TextShaper = struct {
    allocator: std.mem.Allocator,
    feature_cache: std.HashMap(FeatureKey, FeatureSet, FeatureKeyContext, 80),

    const Self = @This();

    const FeatureKey = struct {
        script: @import("font.zig").Script,
        language: Language,
    };

    const FeatureKeyContext = struct {
        pub fn hash(self: @This(), key: FeatureKey) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&key.script));
            hasher.update(std.mem.asBytes(&key.language));
            return hasher.final();
        }

        pub fn eql(self: @This(), a: FeatureKey, b: FeatureKey) bool {
            _ = self;
            return a.script == b.script and a.language == b.language;
        }
    };

    const FeatureSet = struct {
        features: []Feature,

        pub fn deinit(self: *FeatureSet, allocator: std.mem.Allocator) void {
            allocator.free(self.features);
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .feature_cache = std.HashMap(FeatureKey, FeatureSet, FeatureKeyContext, 80).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.feature_cache.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.feature_cache.deinit();
    }

    pub fn shapeText(self: *Self, text: []const u8, font: *Font, options: ShapingOptions) !ShapingResult {
        var result = ShapingResult.init(self.allocator);

        // Detect script and language
        const script = self.detectPrimaryScript(text);
        const language = options.language orelse self.detectLanguage(text, script);

        // Get appropriate features for this script/language combination
        const features = try self.getFeaturesForScript(script, language);

        // Perform basic character-to-glyph mapping
        try self.performBasicShaping(&result, text, font, options);

        // Apply OpenType features
        try self.applyFeatures(&result, font, features, options);

        // Apply script-specific processing
        try self.applyScriptProcessing(&result, script, font, options);

        return result;
    }

    fn detectPrimaryScript(self: *Self, text: []const u8) @import("font.zig").Script {
        _ = self;

        var script_counts = std.EnumMap(@import("font.zig").Script, u32).init(.{});

        var utf8_view = std.unicode.Utf8View.init(text) catch return .latin;
        var iterator = utf8_view.iterator();

        while (iterator.nextCodepoint()) |codepoint| {
            const script = @import("text_layout.zig").detectScript(codepoint);
            const current = script_counts.get(script) orelse 0;
            script_counts.put(script, current + 1);
        }

        // Find the most common script
        var max_count: u32 = 0;
        var primary_script = @import("font.zig").Script.latin;

        var script_iterator = script_counts.iterator();
        while (script_iterator.next()) |entry| {
            if (entry.value.* > max_count) {
                max_count = entry.value.*;
                primary_script = entry.key;
            }
        }

        return primary_script;
    }

    fn detectLanguage(self: *Self, text: []const u8, script: @import("font.zig").Script) Language {
        _ = self;
        _ = text;

        // Simplified language detection based on script
        return switch (script) {
            .latin => .english,
            .arabic => .arabic,
            .hebrew => .hebrew,
            .cyrillic => .russian,
            .chinese => .chinese_simplified,
            .japanese => .japanese,
            .korean => .korean,
            .devanagari => .hindi,
            else => .unknown,
        };
    }

    fn getFeaturesForScript(self: *Self, script: @import("font.zig").Script, language: Language) ![]Feature {
        const key = FeatureKey{ .script = script, .language = language };

        if (self.feature_cache.get(key)) |feature_set| {
            return feature_set.features;
        }

        const features = try self.createFeaturesForScript(script, language);
        const feature_set = FeatureSet{ .features = features };
        try self.feature_cache.put(key, feature_set);

        return features;
    }

    fn createFeaturesForScript(self: *Self, script: @import("font.zig").Script, language: Language) ![]Feature {
        var features = std.ArrayList(Feature).init(self.allocator);

        // Add common features
        try features.append(.{ .tag = "kern", .enabled = true }); // Kerning
        try features.append(.{ .tag = "liga", .enabled = true }); // Standard ligatures

        // Add script-specific features
        switch (script) {
            .latin => {
                try features.append(.{ .tag = "clig", .enabled = true }); // Contextual ligatures
                if (language == .english) {
                    try features.append(.{ .tag = "dlig", .enabled = false }); // Discretionary ligatures
                }
            },
            .arabic => {
                try features.append(.{ .tag = "init", .enabled = true }); // Initial forms
                try features.append(.{ .tag = "medi", .enabled = true }); // Medial forms
                try features.append(.{ .tag = "fina", .enabled = true }); // Final forms
                try features.append(.{ .tag = "rlig", .enabled = true }); // Required ligatures
            },
            .devanagari => {
                try features.append(.{ .tag = "nukt", .enabled = true }); // Nukta forms
                try features.append(.{ .tag = "akhn", .enabled = true }); // Akhands
                try features.append(.{ .tag = "rphf", .enabled = true }); // Reph forms
            },
            .chinese, .japanese, .korean => {
                try features.append(.{ .tag = "vert", .enabled = false }); // Vertical writing
                try features.append(.{ .tag = "vrt2", .enabled = false }); // Vertical alternates
            },
            else => {},
        }

        return features.toOwnedSlice();
    }

    fn performBasicShaping(self: *Self, result: *ShapingResult, text: []const u8, font: *Font, options: ShapingOptions) !void {
        _ = self;

        var utf8_view = std.unicode.Utf8View.init(text) catch return;
        var iterator = utf8_view.iterator();

        var cluster: u32 = 0;

        while (iterator.nextCodepoint()) |codepoint| {
            const glyph_index = font.parser.getGlyphIndex(codepoint) catch 0;

            if (glyph_index == 0 and options.fallback_font) |fallback| {
                const fallback_index = fallback.parser.getGlyphIndex(codepoint) catch 0;
                if (fallback_index != 0) {
                    const shaped_glyph = ShapedGlyph{
                        .glyph_index = fallback_index,
                        .codepoint = codepoint,
                        .cluster = cluster,
                        .x_advance = fallback.getAdvanceWidth(codepoint, options.size) catch 0,
                        .y_advance = 0,
                        .x_offset = 0,
                        .y_offset = 0,
                    };
                    try result.glyphs.append(shaped_glyph);
                    cluster += 1;
                    continue;
                }
            }

            if (glyph_index != 0) {
                const shaped_glyph = ShapedGlyph{
                    .glyph_index = glyph_index,
                    .codepoint = codepoint,
                    .cluster = cluster,
                    .x_advance = font.getAdvanceWidth(codepoint, options.size) catch 0,
                    .y_advance = 0,
                    .x_offset = 0,
                    .y_offset = 0,
                };
                try result.glyphs.append(shaped_glyph);
            }

            cluster += 1;
        }
    }

    fn applyFeatures(self: *Self, result: *ShapingResult, font: *Font, features: []Feature, options: ShapingOptions) !void {
        _ = font;
        _ = options;

        for (features) |feature| {
            if (!feature.enabled) continue;

            switch (feature.getType()) {
                .substitution => try self.applySubstitutionFeature(result, feature),
                .positioning => try self.applyPositioningFeature(result, feature),
            }
        }
    }

    fn applySubstitutionFeature(self: *Self, result: *ShapingResult, feature: Feature) !void {
        // Simplified feature application
        if (std.mem.eql(u8, feature.tag, "liga")) {
            try self.applyLigatures(result);
        }
    }

    fn applyPositioningFeature(self: *Self, result: *ShapingResult, feature: Feature) !void {
        if (std.mem.eql(u8, feature.tag, "kern")) {
            try self.applyKerning(result);
        }
    }

    fn applyLigatures(self: *Self, result: *ShapingResult) !void {
        _ = self;

        // Simple ligature substitution (fi -> ﬁ)
        var i: usize = 0;
        while (i < result.glyphs.items.len - 1) {
            const glyph1 = result.glyphs.items[i];
            const glyph2 = result.glyphs.items[i + 1];

            // Check for common ligatures
            if (glyph1.codepoint == 'f' and glyph2.codepoint == 'i') {
                // Replace with fi ligature (if available)
                result.glyphs.items[i].glyph_index = 0xFB01; // fi ligature
                result.glyphs.items[i].x_advance = glyph1.x_advance + glyph2.x_advance;
                _ = result.glyphs.orderedRemove(i + 1);
                continue;
            }

            i += 1;
        }
    }

    fn applyKerning(self: *Self, result: *ShapingResult) !void {
        _ = self;

        for (result.glyphs.items, 0..) |*glyph, i| {
            if (i == 0) continue;

            const prev_glyph = result.glyphs.items[i - 1];
            // Simplified kerning - would need actual kerning table
            if (prev_glyph.codepoint == 'T' and glyph.codepoint == 'o') {
                glyph.x_offset -= 2.0; // Adjust kerning
            }
        }
    }

    fn applyScriptProcessing(self: *Self, result: *ShapingResult, script: @import("font.zig").Script, font: *Font, options: ShapingOptions) !void {
        _ = font;
        _ = options;

        switch (script) {
            .arabic => try self.applyArabicProcessing(result),
            .devanagari => try self.applyDevanagariProcessing(result),
            else => {},
        }
    }

    fn applyArabicProcessing(self: *Self, result: *ShapingResult) !void {
        // Simplified Arabic contextual analysis
        for (result.glyphs.items, 0..) |*glyph, i| {
            const position = self.getArabicPosition(result.glyphs.items, i);

            // Apply contextual forms based on position
            switch (position) {
                .isolated => {}, // No change needed
                .initial => glyph.glyph_index = self.getInitialForm(glyph.glyph_index),
                .medial => glyph.glyph_index = self.getMedialForm(glyph.glyph_index),
                .final => glyph.glyph_index = self.getFinalForm(glyph.glyph_index),
            }
        }
    }

    fn applyDevanagariProcessing(self: *Self, result: *ShapingResult) !void {
        _ = self;
        _ = result;
        // TODO: Implement Devanagari reordering and conjunct formation
    }

    fn getArabicPosition(self: *Self, glyphs: []ShapedGlyph, index: usize) ArabicPosition {
        _ = self;

        // Simplified position detection
        const is_first = index == 0;
        const is_last = index == glyphs.len - 1;

        if (is_first and is_last) return .isolated;
        if (is_first) return .initial;
        if (is_last) return .final;
        return .medial;
    }

    fn getInitialForm(self: *Self, glyph_index: u32) u32 {
        _ = self;
        // Simplified - would use actual substitution tables
        return glyph_index;
    }

    fn getMedialForm(self: *Self, glyph_index: u32) u32 {
        _ = self;
        return glyph_index;
    }

    fn getFinalForm(self: *Self, glyph_index: u32) u32 {
        _ = self;
        return glyph_index;
    }
};

pub const ShapingResult = struct {
    glyphs: std.ArrayList(ShapedGlyph),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ShapingResult {
        return ShapingResult{
            .glyphs = std.ArrayList(ShapedGlyph){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ShapingResult) void {
        self.glyphs.deinit();
    }
};

pub const ShapedGlyph = struct {
    glyph_index: u32,
    codepoint: u32,
    cluster: u32,
    x_advance: f32,
    y_advance: f32,
    x_offset: f32,
    y_offset: f32,
};

pub const ShapingOptions = struct {
    size: f32,
    language: ?Language = null,
    fallback_font: ?*Font = null,
    enable_ligatures: bool = true,
    enable_kerning: bool = true,
    direction: TextLayout.TextDirection = .ltr,
};

pub const Feature = struct {
    tag: []const u8,
    enabled: bool,

    pub fn getType(self: Feature) FeatureType {
        const substitution_features = [_][]const u8{ "liga", "clig", "dlig", "rlig", "init", "medi", "fina" };
        const positioning_features = [_][]const u8{ "kern", "mark", "mkmk" };

        for (substitution_features) |sub_feature| {
            if (std.mem.eql(u8, self.tag, sub_feature)) {
                return .substitution;
            }
        }

        for (positioning_features) |pos_feature| {
            if (std.mem.eql(u8, self.tag, pos_feature)) {
                return .positioning;
            }
        }

        return .substitution; // Default
    }
};

pub const FeatureType = enum {
    substitution,
    positioning,
};

pub const Language = enum {
    unknown,
    english,
    arabic,
    hebrew,
    russian,
    chinese_simplified,
    chinese_traditional,
    japanese,
    korean,
    hindi,
    spanish,
    french,
    german,
};

const ArabicPosition = enum {
    isolated,
    initial,
    medial,
    final,
};

test "TextShaper basic operations" {
    const allocator = std.testing.allocator;

    var shaper = TextShaper.init(allocator);
    defer shaper.deinit();

    // Test script detection
    const script = shaper.detectPrimaryScript("Hello World");
    try std.testing.expect(script == .latin);

    const arabic_script = shaper.detectPrimaryScript("مرحبا");
    try std.testing.expect(arabic_script == .unknown); // Since our detectScript is simplified
}

test "Feature creation" {
    const allocator = std.testing.allocator;

    var shaper = TextShaper.init(allocator);
    defer shaper.deinit();

    const features = try shaper.createFeaturesForScript(.latin, .english);
    defer allocator.free(features);

    try std.testing.expect(features.len > 0);

    // Check that kern feature is included
    var has_kern = false;
    for (features) |feature| {
        if (std.mem.eql(u8, feature.tag, "kern")) {
            has_kern = true;
            break;
        }
    }
    try std.testing.expect(has_kern);
}