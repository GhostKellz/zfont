const std = @import("std");
const root = @import("root.zig");
const Font = @import("font.zig").Font;
const FontManager = @import("font_manager.zig").FontManager;
const Glyph = @import("glyph.zig").Glyph;
const Unicode = @import("unicode.zig").Unicode;

pub const EmojiRenderer = struct {
    allocator: std.mem.Allocator,
    emoji_fonts: std.ArrayList(*Font),
    color_cache: std.AutoHashMap(u32, ColorGlyph),
    fallback_chain: std.ArrayList(*Font),
    sequence_cache: std.AutoHashMap(u64, ColorGlyph), // For emoji sequences
    grapheme_state: Unicode.GraphemeBreakState,

    const Self = @This();

    const ColorGlyph = struct {
        layers: []ColorLayer,
        metrics: EmojiMetrics,

        pub fn deinit(self: *ColorGlyph, allocator: std.mem.Allocator) void {
            for (self.layers) |*layer| {
                layer.deinit(allocator);
            }
            allocator.free(self.layers);
        }
    };

    const ColorLayer = struct {
        bitmap: []u8,
        width: u32,
        height: u32,
        color: Color,
        blend_mode: BlendMode,

        pub fn deinit(self: *ColorLayer, allocator: std.mem.Allocator) void {
            allocator.free(self.bitmap);
        }
    };

    const Color = struct {
        r: u8,
        g: u8,
        b: u8,
        a: u8,
    };

    const BlendMode = enum {
        normal,
        multiply,
        screen,
        overlay,
    };

    const EmojiMetrics = struct {
        width: f32,
        height: f32,
        bearing_x: f32,
        bearing_y: f32,
        advance: f32,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .emoji_fonts = std.ArrayList(*Font){},
            .color_cache = std.AutoHashMap(u32, ColorGlyph).init(allocator),
            .fallback_chain = std.ArrayList(*Font){},
            .sequence_cache = std.AutoHashMap(u64, ColorGlyph).init(allocator),
            .grapheme_state = Unicode.GraphemeBreakState{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.emoji_fonts.deinit(self.allocator);

        var cache_iterator = self.color_cache.iterator();
        while (cache_iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.color_cache.deinit();

        var seq_iterator = self.sequence_cache.iterator();
        while (seq_iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.sequence_cache.deinit();

        self.fallback_chain.deinit(self.allocator);
    }

    pub fn loadEmojiFonts(self: *Self, font_manager: *FontManager) !void {
        const emoji_font_names = [_][]const u8{
            "Noto Color Emoji",
            "Apple Color Emoji",
            "Segoe UI Emoji",
            "Twemoji",
            "EmojiOne",
        };

        for (emoji_font_names) |font_name| {
            if (try font_manager.findFont(font_name, .{ .size = 24.0 })) |font| {
                try self.emoji_fonts.append(self.allocator, font);
            }
        }

        // Set up fallback chain
        for (self.emoji_fonts.items) |font| {
            try self.fallback_chain.append(self.allocator, font);
        }
    }

    pub fn renderEmoji(self: *Self, codepoint: u32, size: f32, options: EmojiRenderOptions) !?ColorGlyph {
        if (!self.isEmoji(codepoint)) {
            return null;
        }

        // Check cache first
        if (self.color_cache.get(codepoint)) |cached| {
            return self.scaleColorGlyph(cached, size);
        }

        // Try to render with emoji fonts
        for (self.emoji_fonts.items) |font| {
            if (try self.renderEmojiWithFont(font, codepoint, size, options)) |glyph| {
                try self.color_cache.put(codepoint, glyph);
                return glyph;
            }
        }

        // Handle emoji sequences
        if (self.isEmojiSequence(codepoint)) {
            return try self.renderEmojiSequence(codepoint, size, options);
        }

        // Fallback to monochrome rendering
        return try self.renderMonochromeEmoji(codepoint, size);
    }

    fn renderEmojiWithFont(self: *Self, font: *Font, codepoint: u32, size: f32, options: EmojiRenderOptions) !?ColorGlyph {
        const glyph_index = font.parser.getGlyphIndex(codepoint) catch return null;
        if (glyph_index == 0) return null;

        // Check if font has color tables (COLR/CPAL, CBDT/CBLC, or SBIX)
        if (try self.hasColorTable(font, "COLR")) {
            return try self.renderCOLRGlyph(font, glyph_index, size, options);
        }

        if (try self.hasColorTable(font, "CBDT")) {
            return try self.renderCBDTGlyph(font, glyph_index, size, options);
        }

        if (try self.hasColorTable(font, "SBIX")) {
            return try self.renderSBIXGlyph(font, glyph_index, size, options);
        }

        return null;
    }

    fn hasColorTable(self: *Self, font: *Font, table_name: []const u8) !bool {
        _ = self;
        return font.parser.tables.contains(table_name);
    }

    fn renderCOLRGlyph(self: *Self, font: *Font, glyph_index: u32, size: f32, options: EmojiRenderOptions) !ColorGlyph {
        // COLR/CPAL color font rendering
        _ = font;
        _ = glyph_index;
        _ = options;

        // Simplified implementation - create a single color layer
        const width = @as(u32, @intFromFloat(size));
        const height = @as(u32, @intFromFloat(size));
        const bitmap_size = width * height * 4; // RGBA

        const bitmap = try self.allocator.alloc(u8, bitmap_size);

        // Generate a simple colored emoji placeholder
        self.generateColoredEmoji(bitmap, width, height);

        const layer = ColorLayer{
            .bitmap = bitmap,
            .width = width,
            .height = height,
            .color = Color{ .r = 255, .g = 200, .b = 0, .a = 255 },
            .blend_mode = .normal,
        };

        var layers = try self.allocator.alloc(ColorLayer, 1);
        layers[0] = layer;

        return ColorGlyph{
            .layers = layers,
            .metrics = EmojiMetrics{
                .width = @floatFromInt(width),
                .height = @floatFromInt(height),
                .bearing_x = 0,
                .bearing_y = @floatFromInt(height),
                .advance = @floatFromInt(width),
            },
        };
    }

    fn renderCBDTGlyph(self: *Self, font: *Font, glyph_index: u32, size: f32, options: EmojiRenderOptions) !ColorGlyph {
        // CBDT/CBLC bitmap color font rendering
        return self.renderCOLRGlyph(font, glyph_index, size, options);
    }

    fn renderSBIXGlyph(self: *Self, font: *Font, glyph_index: u32, size: f32, options: EmojiRenderOptions) !ColorGlyph {
        // SBIX (Apple) color font rendering
        return self.renderCOLRGlyph(font, glyph_index, size, options);
    }

    fn generateColoredEmoji(self: *Self, bitmap: []u8, width: u32, height: u32) void {
        _ = self;

        // Generate a simple circular emoji placeholder
        const center_x = @as(f32, @floatFromInt(width)) / 2.0;
        const center_y = @as(f32, @floatFromInt(height)) / 2.0;
        const radius = @min(center_x, center_y) * 0.8;

        for (0..height) |y| {
            for (0..width) |x| {
                const dx = @as(f32, @floatFromInt(x)) - center_x;
                const dy = @as(f32, @floatFromInt(y)) - center_y;
                const distance = std.math.sqrt(dx * dx + dy * dy);

                const pixel_index = (y * width + x) * 4;

                if (distance <= radius) {
                    // Inside circle - yellow emoji face
                    bitmap[pixel_index] = 255;     // R
                    bitmap[pixel_index + 1] = 220; // G
                    bitmap[pixel_index + 2] = 0;   // B
                    bitmap[pixel_index + 3] = 255; // A

                    // Add simple eyes and mouth
                    const eye1_x = center_x - radius * 0.3;
                    const eye1_y = center_y - radius * 0.2;
                    const eye2_x = center_x + radius * 0.3;
                    const eye2_y = center_y - radius * 0.2;

                    const eye1_dist = std.math.sqrt((@as(f32, @floatFromInt(x)) - eye1_x) * (@as(f32, @floatFromInt(x)) - eye1_x) +
                                                   (@as(f32, @floatFromInt(y)) - eye1_y) * (@as(f32, @floatFromInt(y)) - eye1_y));
                    const eye2_dist = std.math.sqrt((@as(f32, @floatFromInt(x)) - eye2_x) * (@as(f32, @floatFromInt(x)) - eye2_x) +
                                                   (@as(f32, @floatFromInt(y)) - eye2_y) * (@as(f32, @floatFromInt(y)) - eye2_y));

                    if (eye1_dist <= radius * 0.1 or eye2_dist <= radius * 0.1) {
                        // Eyes - black
                        bitmap[pixel_index] = 0;
                        bitmap[pixel_index + 1] = 0;
                        bitmap[pixel_index + 2] = 0;
                    }

                    // Simple smile
                    if (y > center_y + radius * 0.1 and y < center_y + radius * 0.4) {
                        const smile_dx = @as(f32, @floatFromInt(x)) - center_x;
                        const smile_curve = center_y + radius * 0.2 + (smile_dx * smile_dx) / (radius * 0.8);
                        if (@abs(@as(f32, @floatFromInt(y)) - smile_curve) < 2.0 and @abs(smile_dx) < radius * 0.4) {
                            bitmap[pixel_index] = 0;
                            bitmap[pixel_index + 1] = 0;
                            bitmap[pixel_index + 2] = 0;
                        }
                    }
                } else {
                    // Outside circle - transparent
                    bitmap[pixel_index] = 0;
                    bitmap[pixel_index + 1] = 0;
                    bitmap[pixel_index + 2] = 0;
                    bitmap[pixel_index + 3] = 0;
                }
            }
        }
    }

    fn renderEmojiSequenceOld(self: *Self, codepoint: u32, size: f32, options: EmojiRenderOptions) !ColorGlyph {
        // Handle emoji sequences like skin tone modifiers, ZWJ sequences, etc.
        _ = codepoint;

        // Simplified - just render as regular emoji
        return self.renderCOLRGlyph(undefined, 0, size, options);
    }

    fn renderMonochromeEmoji(self: *Self, codepoint: u32, size: f32) !ColorGlyph {
        // Fallback to monochrome text rendering
        _ = codepoint;

        const width = @as(u32, @intFromFloat(size));
        const height = @as(u32, @intFromFloat(size));
        const bitmap_size = width * height;

        const bitmap = try self.allocator.alloc(u8, bitmap_size);
        @memset(bitmap, 128); // Gray placeholder

        const layer = ColorLayer{
            .bitmap = bitmap,
            .width = width,
            .height = height,
            .color = Color{ .r = 128, .g = 128, .b = 128, .a = 255 },
            .blend_mode = .normal,
        };

        var layers = try self.allocator.alloc(ColorLayer, 1);
        layers[0] = layer;

        return ColorGlyph{
            .layers = layers,
            .metrics = EmojiMetrics{
                .width = @floatFromInt(width),
                .height = @floatFromInt(height),
                .bearing_x = 0,
                .bearing_y = @floatFromInt(height),
                .advance = @floatFromInt(width),
            },
        };
    }

    fn scaleColorGlyph(self: *Self, glyph: ColorGlyph, size: f32) ColorGlyph {
        // For now, return the original glyph
        // In a full implementation, this would scale the bitmap
        _ = self;
        _ = size;
        return glyph;
    }

    pub fn isEmoji(self: *Self, codepoint: u32) bool {
        _ = self;

        // Use gcode's emoji detection through Unicode module
        const emoji_prop = Unicode.getEmojiProperty(codepoint);
        if (emoji_prop != .None) {
            return true;
        }

        // Additional fallback check for common emoji ranges
        return switch (codepoint) {
            0x1F600...0x1F64F, // Emoticons
            0x1F300...0x1F5FF, // Miscellaneous Symbols and Pictographs
            0x1F680...0x1F6FF, // Transport and Map Symbols
            0x1F700...0x1F77F, // Alchemical Symbols
            0x1F900...0x1F9FF, // Supplemental Symbols and Pictographs
            0x1FA00...0x1FA6F, // Chess Symbols
            0x1FA70...0x1FAFF, // Symbols and Pictographs Extended-A
            0x2600...0x26FF,   // Miscellaneous Symbols
            0x2700...0x27BF,   // Dingbats
            => true,
            else => false,
        };
    }

    pub fn renderEmojiSequence(self: *Self, sequence: []const u32, size: f32, options: EmojiRenderOptions) !?ColorGlyph {
        // Handle complex emoji sequences like ZWJ sequences, skin tones, flags

        if (sequence.len == 0) return null;
        if (sequence.len == 1) return self.renderEmoji(sequence[0], size, options);

        // Create a hash for the sequence
        var hasher = std.hash.Wyhash.init(0);
        for (sequence) |cp| {
            hasher.update(std.mem.asBytes(&cp));
        }
        const sequence_hash = hasher.final();

        // Check cache first
        if (self.sequence_cache.get(sequence_hash)) |cached| {
            return self.scaleColorGlyph(cached, size);
        }

        // Handle different types of emoji sequences
        if (self.isZWJSequence(sequence)) {
            return self.renderZWJSequence(sequence, size, options);
        }

        if (self.isFlagSequence(sequence)) {
            return self.renderFlagSequence(sequence, size, options);
        }

        if (self.isSkinToneSequence(sequence)) {
            return self.renderSkinToneSequence(sequence, size, options);
        }

        // Fallback: render first emoji in sequence
        return self.renderEmoji(sequence[0], size, options);
    }

    fn isZWJSequence(self: *Self, sequence: []const u32) bool {
        _ = self;
        // Check if sequence contains Zero Width Joiner (U+200D)
        for (sequence) |cp| {
            if (cp == 0x200D) return true;
        }
        return false;
    }

    fn isFlagSequence(self: *Self, sequence: []const u32) bool {
        _ = self;
        // Regional Indicator sequences (country flags)
        if (sequence.len == 2) {
            return sequence[0] >= 0x1F1E6 and sequence[0] <= 0x1F1FF and
                   sequence[1] >= 0x1F1E6 and sequence[1] <= 0x1F1FF;
        }
        return false;
    }

    fn isSkinToneSequence(self: *Self, sequence: []const u32) bool {
        _ = self;
        // Check for emoji modifier base + skin tone modifier
        if (sequence.len >= 2) {
            const base_props = Unicode.getEmojiProperty(sequence[0]);
            const modifier_props = Unicode.getEmojiProperty(sequence[1]);
            return base_props == .Emoji_Modifier_Base and modifier_props == .Emoji_Modifier;
        }
        return false;
    }

    fn renderZWJSequence(self: *Self, sequence: []const u32, size: f32, options: EmojiRenderOptions) !ColorGlyph {
        // ZWJ sequences like 👨‍👩‍👧‍👦 (family), 🏳️‍🌈 (rainbow flag)

        // For now, try to render as a single glyph if available
        // Fall back to combining individual parts

        for (self.emoji_fonts.items) |font| {
            // Try to find a precomposed glyph for the entire sequence
            if (try self.renderSequenceWithFont(font, sequence, size, options)) |glyph| {
                return glyph;
            }
        }

        // Fallback: render the base emoji (first non-ZWJ, non-variation selector)
        for (sequence) |cp| {
            if (cp != 0x200D and cp != 0xFE0E and cp != 0xFE0F) {
                const props = Unicode.getEmojiProperty(cp);
                if (props != .None) {
                    return self.renderEmoji(cp, size, options) orelse continue;
                }
            }
        }

        // Ultimate fallback
        return self.renderMonochromeEmoji(sequence[0], size);
    }

    fn renderFlagSequence(self: *Self, sequence: []const u32, size: f32, options: EmojiRenderOptions) !ColorGlyph {
        // Regional Indicator pairs for country flags
        if (sequence.len != 2) {
            return self.renderMonochromeEmoji(sequence[0], size);
        }

        // Convert to flag emoji codepoint if font supports it
        for (self.emoji_fonts.items) |font| {
            if (try self.renderSequenceWithFont(font, sequence, size, options)) |glyph| {
                return glyph;
            }
        }

        // Fallback: render as separate regional indicators
        return self.renderEmoji(sequence[0], size, options) orelse
               self.renderMonochromeEmoji(sequence[0], size);
    }

    fn renderSkinToneSequence(self: *Self, sequence: []const u32, size: f32, options: EmojiRenderOptions) !ColorGlyph {
        // Emoji modifier base + skin tone modifier
        const base_cp = sequence[0];
        const modifier_cp = sequence[1];

        // Try to render the modified emoji
        for (self.emoji_fonts.items) |font| {
            if (try self.renderModifiedEmojiWithFont(font, base_cp, modifier_cp, size, options)) |glyph| {
                return glyph;
            }
        }

        // Fallback: render base emoji without modifier
        return self.renderEmoji(base_cp, size, options) orelse
               self.renderMonochromeEmoji(base_cp, size);
    }

    fn renderSequenceWithFont(self: *Self, font: *Font, sequence: []const u32, size: f32, options: EmojiRenderOptions) !?ColorGlyph {
        // Try to find a single glyph that represents the entire sequence
        _ = self;
        _ = font;
        _ = sequence;
        _ = size;
        _ = options;

        // This would require advanced OpenType GSUB table processing
        // For now, return null to indicate fallback needed
        return null;
    }

    fn renderModifiedEmojiWithFont(self: *Self, font: *Font, base: u32, modifier: u32, size: f32, options: EmojiRenderOptions) !?ColorGlyph {
        // Look for precomposed glyph or use font's modification tables
        _ = self;
        _ = font;
        _ = base;
        _ = modifier;
        _ = size;
        _ = options;

        // This would require COLR table processing with layered rendering
        // For now, return null to indicate fallback needed
        return null;
    }

    fn isEmojiSequence(self: *Self, codepoint: u32) bool {
        // Check if this is part of an emoji sequence
        _ = self;
        return codepoint >= 0x1F1E6 and codepoint <= 0x1F1FF; // Regional indicators
    }

    pub fn supportsSkinTones(self: *Self, codepoint: u32) bool {
        _ = self;
        // Emoji that support skin tone modifiers
        const skin_tone_emojis = [_]u32{
            0x1F44D, // 👍 thumbs up
            0x1F44E, // 👎 thumbs down
            0x1F44F, // 👏 clapping hands
            0x1F64F, // 🙏 folded hands
            // Add more as needed
        };

        for (skin_tone_emojis) |emoji| {
            if (codepoint == emoji) return true;
        }

        return false;
    }

    pub fn applySkinTone(self: *Self, base_emoji: u32, skin_tone: SkinTone) u32 {
        if (!self.supportsSkinTones(base_emoji)) {
            return base_emoji;
        }

        // Apply skin tone modifier
        // This is a simplified implementation
        return base_emoji + (@intFromEnum(skin_tone) - 1);
    }
};

pub const EmojiRenderOptions = struct {
    prefer_color: bool = true,
    skin_tone: SkinTone = .default,
    text_presentation: bool = false,
};

pub const SkinTone = enum(u8) {
    default = 0,
    light = 1,
    medium_light = 2,
    medium = 3,
    medium_dark = 4,
    dark = 5,
};

test "EmojiRenderer basic operations" {
    const allocator = std.testing.allocator;

    var renderer = EmojiRenderer.init(allocator);
    defer renderer.deinit();

    // Test emoji detection
    try std.testing.expect(renderer.isEmoji(0x1F600)); // 😀
    try std.testing.expect(renderer.isEmoji(0x1F44D)); // 👍
    try std.testing.expect(!renderer.isEmoji('A'));

    // Test skin tone support
    try std.testing.expect(renderer.supportsSkinTones(0x1F44D)); // 👍
    try std.testing.expect(!renderer.supportsSkinTones(0x1F600)); // 😀
}

test "Unicode emoji detection via Unicode module" {
    const testing = std.testing;

    // Test emoji detection using Unicode module
    try testing.expect(Unicode.getEmojiProperty(0x1F600) != .None); // 😀
    try testing.expect(Unicode.getEmojiProperty(0x2600) != .None);  // ☀
    try testing.expect(Unicode.getEmojiProperty('A') == .None);

    // Test emoji sequence detection
    const allocator = std.testing.allocator;
    var renderer = EmojiRenderer.init(allocator);
    defer renderer.deinit();

    // Regional indicator sequence (flag)
    const flag_sequence = [_]u32{ 0x1F1FA, 0x1F1F8 }; // US flag
    try testing.expect(renderer.isFlagSequence(&flag_sequence));

    // Skin tone sequence
    const skin_sequence = [_]u32{ 0x1F44D, 0x1F3FB }; // 👍🏻
    try testing.expect(renderer.isSkinToneSequence(&skin_sequence));

    // ZWJ sequence
    const zwj_sequence = [_]u32{ 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467 }; // 👨‍👩‍👧
    try testing.expect(renderer.isZWJSequence(&zwj_sequence));
}