const std = @import("std");
const root = @import("root.zig");
const Font = @import("font.zig").Font;
const FontManager = @import("font_manager.zig").FontManager;
const Glyph = @import("glyph.zig").Glyph;
const Unicode = @import("unicode.zig").Unicode;
const EmojiSequenceProcessor = @import("emoji_sequences.zig").EmojiSequenceProcessor;
const EmojiInfo = EmojiSequenceProcessor.EmojiInfo;
const EmojiType = EmojiSequenceProcessor.EmojiType;
const PresentationStyle = EmojiSequenceProcessor.PresentationStyle;

pub const EmojiRenderer = struct {
    allocator: std.mem.Allocator,
    emoji_fonts: std.ArrayList(*Font),
    color_cache: std.AutoHashMap(u32, ColorGlyph),
    fallback_chain: std.ArrayList(*Font),
    sequence_cache: std.AutoHashMap(u64, ColorGlyph), // For emoji sequences
    grapheme_state: Unicode.GraphemeBreakState,
    sequence_processor: EmojiSequenceProcessor,

    // Unicode 15.1 emoji support
    unicode_version: UnicodeVersion,
    supported_categories: std.AutoHashMap(u32, EmojiCategory),

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

    const UnicodeVersion = struct {
        major: u8,
        minor: u8,
        patch: u8,

        pub const UNICODE_15_1 = UnicodeVersion{ .major = 15, .minor = 1, .patch = 0 };
    };

    const EmojiCategory = enum {
        smileys_and_emotion,
        people_and_body,
        animals_and_nature,
        food_and_drink,
        travel_and_places,
        activities,
        objects,
        symbols,
        flags,
        // Unicode 15.1 new categories
        new_in_15_1,
    };

    pub fn init(allocator: std.mem.Allocator) !Self {
        var renderer = Self{
            .allocator = allocator,
            .emoji_fonts = undefined,
            .color_cache = std.AutoHashMap(u32, ColorGlyph).init(allocator),
            .fallback_chain = undefined,
            .sequence_cache = std.AutoHashMap(u64, ColorGlyph).init(allocator),
            .grapheme_state = Unicode.GraphemeBreakState{},
            .sequence_processor = undefined,
            .unicode_version = UnicodeVersion.UNICODE_15_1,
            .supported_categories = std.AutoHashMap(u32, EmojiCategory).init(allocator),
        };

        renderer.emoji_fonts = std.ArrayList(*Font){};
        renderer.fallback_chain = std.ArrayList(*Font){};
        renderer.sequence_processor = try EmojiSequenceProcessor.init(allocator);
        return renderer;
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
        self.sequence_processor.deinit();
        self.supported_categories.deinit();
    }

    fn appendUniqueFont(list: *std.ArrayList(*Font), font: *Font) !void {
        for (list.items) |existing| {
            if (existing == font) return;
        }
        try list.append(font);
    }

    pub fn loadEmojiFonts(self: *Self, font_manager: *FontManager) !void {
        try font_manager.scanSystemFonts();

        self.emoji_fonts.clearRetainingCapacity();
        self.fallback_chain.clearRetainingCapacity();

        const emoji_font_names = [_][]const u8{
            "Noto Color Emoji",
            "Noto Emoji",
            "Apple Color Emoji",
            "Segoe UI Emoji",
            "Segoe UI Symbol",
            "Twemoji",
            "EmojiOne",
            "JoyPixels",
        };

        for (emoji_font_names) |font_name| {
            if (try font_manager.findFont(font_name, .{ .size = 24.0 })) |font| {
                try appendUniqueFont(&self.emoji_fonts, font);
            }
        }

        if (self.emoji_fonts.items.len == 0) {
            if (try font_manager.getFallbackFont()) |fallback| {
                try appendUniqueFont(&self.emoji_fonts, fallback);
            }
        }

        for (self.emoji_fonts.items) |font| {
            try appendUniqueFont(&self.fallback_chain, font);
        }

        if (try font_manager.getFallbackFont()) |fallback| {
            try appendUniqueFont(&self.fallback_chain, fallback);
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
                    bitmap[pixel_index] = 255; // R
                    bitmap[pixel_index + 1] = 220; // G
                    bitmap[pixel_index + 2] = 0; // B
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
        const bitmap_size = width * height * 4;

        const bitmap = try self.allocator.alloc(u8, bitmap_size);
        var i: usize = 0;
        while (i < bitmap_size) : (i += 4) {
            bitmap[i] = 160;
            bitmap[i + 1] = 160;
            bitmap[i + 2] = 160;
            bitmap[i + 3] = 255;
        }

        const layer = ColorLayer{
            .bitmap = bitmap,
            .width = width,
            .height = height,
            .color = Color{ .r = 160, .g = 160, .b = 160, .a = 255 },
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
            0x2600...0x26FF, // Miscellaneous Symbols
            0x2700...0x27BF, // Dingbats
            => true,
            else => false,
        };
    }

    pub fn renderEmojiSequence(self: *Self, sequence: []const u32, size: f32, options: EmojiRenderOptions) !?ColorGlyph {
        if (sequence.len == 0) return null;
        if (sequence.len == 1) return self.renderEmoji(sequence[0], size, options);

        const sequence_hash = self.computeSequenceHash(sequence);

        if (self.sequence_cache.get(sequence_hash)) |cached| {
            return self.scaleColorGlyph(cached, size);
        }

        if (self.shouldForceTextPresentation(sequence, options)) {
            const text_glyph = try self.renderSequenceAsText(sequence, size);
            try self.sequence_cache.put(sequence_hash, text_glyph);
            return self.scaleColorGlyph(text_glyph, size);
        }

        const info = try self.sequence_processor.getSequenceInfo(sequence);

        if (try self.tryRenderSequenceWithFonts(sequence, size, options)) |precomposed| {
            try self.sequence_cache.put(sequence_hash, precomposed);
            return self.scaleColorGlyph(precomposed, size);
        }

        const glyph = switch (info.sequence_type) {
            .zwj_sequence => try self.renderZWJSequence(sequence, size, options),
            .flag => try self.renderFlagSequence(sequence, size, options),
            .skin_tone_sequence => try self.renderSkinToneSequence(sequence, size, options),
            .keycap => try self.renderKeycapSequence(sequence, size, options),
            .tag_sequence => try self.renderTagSequence(sequence, size, options),
            else => try self.renderGenericSequence(sequence, size, options),
        };

        try self.sequence_cache.put(sequence_hash, glyph);
        return self.scaleColorGlyph(glyph, size);
    }

    fn computeSequenceHash(self: *Self, sequence: []const u32) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0x9BABCDEF);
        for (sequence) |cp| {
            hasher.update(std.mem.asBytes(&cp));
        }
        return hasher.final();
    }

    fn shouldForceTextPresentation(self: *Self, sequence: []const u32, options: EmojiRenderOptions) bool {
        _ = self;
        if (options.text_presentation) return true;

        var has_text_vs = false;
        var has_emoji_vs = false;

        for (sequence) |cp| {
            switch (cp) {
                0xFE0E => has_text_vs = true,
                0xFE0F => has_emoji_vs = true,
                else => {},
            }
        }

        return has_text_vs and !has_emoji_vs;
    }

    pub fn analyzeSequence(self: *Self, sequence: []const u32) !EmojiInfo {
        return try self.sequence_processor.getSequenceInfo(sequence);
    }

    pub fn isEmojiSequence(self: *Self, sequence: []const u32) bool {
        if (sequence.len <= 1) return false;
        const info = self.sequence_processor.getSequenceInfo(sequence) catch return false;
        return info.sequence_type != .simple or info.component_count > 1;
    }

    pub fn isFlagSequence(self: *Self, sequence: []const u32) bool {
        const info = self.sequence_processor.getSequenceInfo(sequence) catch return false;
        return info.sequence_type == .flag;
    }

    pub fn isZWJSequence(self: *Self, sequence: []const u32) bool {
        const info = self.sequence_processor.getSequenceInfo(sequence) catch return false;
        return info.sequence_type == .zwj_sequence or info.has_zwj;
    }

    pub fn isSkinToneSequence(self: *Self, sequence: []const u32) bool {
        const info = self.sequence_processor.getSequenceInfo(sequence) catch return false;
        return info.sequence_type == .skin_tone_sequence or info.has_skin_tone;
    }

    pub fn sequencePresentationStyle(self: *Self, sequence: []const u32) PresentationStyle {
        const info = self.sequence_processor.getSequenceInfo(sequence) catch {
            return .default;
        };
        return info.presentation_style;
    }

    fn normalizeSequence(self: *Self, sequence: []const u32, buffer: []u32, include_controls: bool) []const u32 {
        _ = self;
        var count: usize = 0;
        for (sequence) |cp| {
            switch (cp) {
                0x200D, 0xFE0E, 0xFE0F => {
                    if (include_controls) {
                        buffer[count] = cp;
                        count += 1;
                    }
                    continue;
                },
                0xE0020...0xE007F => {
                    if (include_controls) {
                        buffer[count] = cp;
                        count += 1;
                    }
                    continue;
                },
                else => {
                    buffer[count] = cp;
                    count += 1;
                },
            }
        }
        return buffer[0..count];
    }

    fn isSequenceControl(codepoint: u32) bool {
        return switch (codepoint) {
            0x200D, // Zero Width Joiner
            0xFE0E, // VS15 (text)
            0xFE0F, // VS16 (emoji)
            0xE0020...0xE007F,
            => true, // Tags
            else => false,
        };
    }

    fn tryRenderSequenceWithFonts(self: *Self, sequence: []const u32, size: f32, options: EmojiRenderOptions) !?ColorGlyph {
        for (self.emoji_fonts.items) |font| {
            if (try self.renderSequenceWithFont(font, sequence, size, options)) |glyph| {
                return glyph;
            }
        }
        return null;
    }

    fn renderSequenceWithFont(self: *Self, font: *Font, sequence: []const u32, size: f32, options: EmojiRenderOptions) !?ColorGlyph {
        if (sequence.len == 0) return null;

        var glyphs = std.ArrayList(ColorGlyph).init(self.allocator);
        defer {
            for (glyphs.items) |*g| g.deinit(self.allocator);
            glyphs.deinit();
        }

        var has_component = false;
        var buffer: [64]u32 = undefined;
        const normalized = self.normalizeSequence(sequence, &buffer, true);

        for (normalized) |cp| {
            if (isSequenceControl(cp)) continue;

            var component_options = options;
            component_options.prefer_color = true;
            component_options.text_presentation = false;

            var component = try self.renderEmojiWithFont(font, cp, size, component_options) orelse {
                return null;
            };
            errdefer component.deinit(self.allocator);
            try glyphs.append(component);
            has_component = true;
        }

        if (!has_component) {
            return null;
        }

        const composed = try self.composeColorGlyphs(glyphs.items);
        return composed;
    }

    fn renderZWJSequence(self: *Self, sequence: []const u32, size: f32, options: EmojiRenderOptions) !ColorGlyph {
        var buffer: [32]u32 = undefined;
        const components = self.normalizeSequence(sequence, &buffer, false);
        if (components.len == 0) {
            return self.renderMonochromeEmoji(sequence[0], size);
        }
        return try self.composeComponentGlyphs(components, size, options, false);
    }

    fn renderFlagSequence(self: *Self, sequence: []const u32, size: f32, options: EmojiRenderOptions) !ColorGlyph {
        if (sequence.len < 2) {
            return self.renderMonochromeEmoji(sequence[0], size);
        }

        var buffer: [32]u32 = undefined;
        const components = self.normalizeSequence(sequence, &buffer, false);
        if (components.len == 0) {
            return self.renderMonochromeEmoji(sequence[0], size);
        }
        return try self.composeComponentGlyphs(components, size, options, false);
    }

    fn renderSkinToneSequence(self: *Self, sequence: []const u32, size: f32, options: EmojiRenderOptions) !ColorGlyph {
        var buffer: [32]u32 = undefined;
        const components = self.normalizeSequence(sequence, &buffer, false);
        if (components.len == 0) {
            return self.renderMonochromeEmoji(sequence[0], size);
        }

        if (try self.tryRenderSequenceWithFonts(sequence, size, options)) |glyph| {
            return glyph;
        }

        const tone = if (options.skin_tone != .default)
            options.skin_tone
        else
            self.detectSkinToneModifier(sequence) orelse .default;

        const base_cp = components[0];
        const base_color = (try self.renderEmoji(base_cp, size, options)) orelse try self.renderMonochromeEmoji(base_cp, size);
        var tinted = try self.cloneColorGlyph(base_color);
        try self.tintGlyphForSkinTone(&tinted, tone);

        if (components.len == 1) {
            return tinted;
        }

        var glyphs = std.ArrayList(ColorGlyph).init(self.allocator);
        defer {
            for (glyphs.items) |*g| g.deinit(self.allocator);
            glyphs.deinit();
        }

        try glyphs.append(tinted);

        for (components[1..]) |cp| {
            const sub = try self.renderComponentGlyph(cp, size, options, false);
            try glyphs.append(sub);
        }

        const composed = try self.composeColorGlyphs(glyphs.items);
        return composed;
    }

    fn detectSkinToneModifier(self: *Self, sequence: []const u32) ?SkinTone {
        for (sequence) |cp| {
            if (self.skinToneFromModifier(cp)) |tone| {
                return tone;
            }
        }
        return null;
    }

    fn renderKeycapSequence(self: *Self, sequence: []const u32, size: f32, options: EmojiRenderOptions) !ColorGlyph {
        var buffer: [32]u32 = undefined;
        const components = self.normalizeSequence(sequence, &buffer, false);
        if (components.len == 0) {
            return self.renderMonochromeEmoji(sequence[0], size);
        }
        return try self.composeComponentGlyphs(components, size, options, false);
    }

    fn renderTagSequence(self: *Self, sequence: []const u32, size: f32, options: EmojiRenderOptions) !ColorGlyph {
        var buffer: [32]u32 = undefined;
        const components = self.normalizeSequence(sequence, &buffer, false);
        if (components.len == 0) {
            return self.renderMonochromeEmoji(sequence[0], size);
        }
        return try self.composeComponentGlyphs(components, size, options, false);
    }

    fn renderGenericSequence(self: *Self, sequence: []const u32, size: f32, options: EmojiRenderOptions) !ColorGlyph {
        var buffer: [32]u32 = undefined;
        const components = self.normalizeSequence(sequence, &buffer, false);
        if (components.len == 0) {
            return self.renderMonochromeEmoji(sequence[0], size);
        }
        return try self.composeComponentGlyphs(components, size, options, false);
    }

    fn renderSequenceAsText(self: *Self, sequence: []const u32, size: f32) !ColorGlyph {
        var buffer: [32]u32 = undefined;
        const components = self.normalizeSequence(sequence, &buffer, false);
        if (components.len == 0) {
            return self.renderMonochromeEmoji(sequence[0], size);
        }
        const mono_options = EmojiRenderOptions{
            .prefer_color = false,
            .skin_tone = .default,
            .text_presentation = true,
        };
        return try self.composeComponentGlyphs(components, size, mono_options, true);
    }

    fn composeComponentGlyphs(self: *Self, components: []const u32, size: f32, options: EmojiRenderOptions, force_monochrome: bool) !ColorGlyph {
        if (components.len == 1) {
            return try self.renderComponentGlyph(components[0], size, options, force_monochrome);
        }

        var glyphs = std.ArrayList(ColorGlyph).init(self.allocator);
        defer {
            for (glyphs.items) |*g| g.deinit(self.allocator);
            glyphs.deinit();
        }

        for (components) |cp| {
            const glyph = try self.renderComponentGlyph(cp, size, options, force_monochrome);
            try glyphs.append(glyph);
        }

        const composed = try self.composeColorGlyphs(glyphs.items);
        return composed;
    }

    fn renderComponentGlyph(self: *Self, codepoint: u32, size: f32, options: EmojiRenderOptions, force_monochrome: bool) !ColorGlyph {
        if (force_monochrome) {
            return try self.renderMonochromeEmoji(codepoint, size);
        }

        if (try self.renderEmoji(codepoint, size, options)) |glyph| {
            return try self.cloneColorGlyph(glyph);
        }

        return try self.renderMonochromeEmoji(codepoint, size);
    }

    fn composeColorGlyphs(self: *Self, glyphs: []const ColorGlyph) !ColorGlyph {
        if (glyphs.len == 0) {
            return self.renderMonochromeEmoji(0x25A1, 16.0);
        }

        var flattened = std.ArrayList([]u8).init(self.allocator);
        var widths = std.ArrayList(u32).init(self.allocator);
        var heights = std.ArrayList(u32).init(self.allocator);
        defer {
            for (flattened.items) |buffer| {
                self.allocator.free(buffer);
            }
            flattened.deinit();
            widths.deinit();
            heights.deinit();
        }

        var total_width: u32 = 0;
        var max_height: u32 = 0;

        for (glyphs) |glyph| {
            var width: u32 = 0;
            var height: u32 = 0;
            const buffer = try self.flattenGlyph(&glyph, &width, &height);
            try flattened.append(buffer);
            try widths.append(width);
            try heights.append(height);

            total_width += width;
            if (height > max_height) max_height = height;
        }

        if (total_width == 0) total_width = 1;
        if (max_height == 0) max_height = 1;

        const canvas_len = total_width * max_height * 4;
        var canvas = try self.allocator.alloc(u8, canvas_len);
        @memset(canvas, 0);

        var offset_x: u32 = 0;
        for (flattened.items, 0..) |buffer, idx| {
            const width = widths.items[idx];
            const height = heights.items[idx];
            const baseline_offset = if (max_height > height) max_height - height else 0;

            var y: u32 = 0;
            while (y < height) : (y += 1) {
                var x: u32 = 0;
                while (x < width) : (x += 1) {
                    const src_index = (y * width + x) * 4;
                    const dest_x = offset_x + x;
                    const dest_y = baseline_offset + y;
                    if (dest_x >= total_width or dest_y >= max_height) continue;

                    const dest_index = (dest_y * total_width + dest_x) * 4;
                    self.blendPixel(canvas[dest_index .. dest_index + 4], buffer[src_index .. src_index + 4]);
                }
            }

            offset_x += width;
        }

        var layers = try self.allocator.alloc(ColorLayer, 1);
        layers[0] = ColorLayer{
            .bitmap = canvas,
            .width = total_width,
            .height = max_height,
            .color = Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
            .blend_mode = .normal,
        };

        return ColorGlyph{
            .layers = layers,
            .metrics = EmojiMetrics{
                .width = @floatFromInt(total_width),
                .height = @floatFromInt(max_height),
                .bearing_x = 0,
                .bearing_y = @floatFromInt(max_height),
                .advance = @floatFromInt(total_width),
            },
        };
    }

    fn flattenGlyph(self: *Self, glyph: *const ColorGlyph, out_width: *u32, out_height: *u32) ![]u8 {
        var width: u32 = 0;
        var height: u32 = 0;

        for (glyph.layers) |layer| {
            if (layer.width > width) width = layer.width;
            if (layer.height > height) height = layer.height;
        }

        if (width == 0) {
            const fallback_width = @as(u32, @intFromFloat(@round(glyph.metrics.width)));
            width = @max(@as(u32, 1), fallback_width);
        }
        if (height == 0) {
            const fallback_height = @as(u32, @intFromFloat(@round(glyph.metrics.height)));
            height = @max(@as(u32, 1), fallback_height);
        }

        const buffer_len = width * height * 4;
        var buffer = try self.allocator.alloc(u8, buffer_len);
        @memset(buffer, 0);

        for (glyph.layers) |layer| {
            if (layer.width == 0 or layer.height == 0) continue;
            if (layer.bitmap.len < layer.width * layer.height * 4) continue;

            const copy_width = @min(layer.width, width);
            const copy_height = @min(layer.height, height);
            const y_offset = if (height > layer.height) height - layer.height else 0;

            var y: u32 = 0;
            while (y < copy_height) : (y += 1) {
                var x: u32 = 0;
                while (x < copy_width) : (x += 1) {
                    const src_index = (y * layer.width + x) * 4;
                    const dest_index = ((y_offset + y) * width + x) * 4;
                    self.blendPixel(buffer[dest_index .. dest_index + 4], layer.bitmap[src_index .. src_index + 4]);
                }
            }
        }

        out_width.* = width;
        out_height.* = height;
        return buffer;
    }

    fn blendPixel(self: *Self, dest: []u8, src: []const u8) void {
        _ = self;
        const src_a = @as(u32, src[3]);
        if (src_a == 0) return;

        const dst_a = @as(u32, dest[3]);
        const out_a = src_a + ((255 - src_a) * dst_a) / 255;
        const inv_src = 255 - src_a;

        dest[0] = @intCast((@as(u32, src[0]) * src_a + @as(u32, dest[0]) * inv_src) / 255);
        dest[1] = @intCast((@as(u32, src[1]) * src_a + @as(u32, dest[1]) * inv_src) / 255);
        dest[2] = @intCast((@as(u32, src[2]) * src_a + @as(u32, dest[2]) * inv_src) / 255);
        dest[3] = @intCast(out_a);
    }

    fn cloneColorGlyph(self: *Self, glyph: ColorGlyph) !ColorGlyph {
        var layers = try self.allocator.alloc(ColorLayer, glyph.layers.len);
        for (glyph.layers, 0..) |layer, idx| {
            const bitmap_copy = try self.allocator.dupe(u8, layer.bitmap);
            layers[idx] = ColorLayer{
                .bitmap = bitmap_copy,
                .width = layer.width,
                .height = layer.height,
                .color = layer.color,
                .blend_mode = layer.blend_mode,
            };
        }

        return ColorGlyph{
            .layers = layers,
            .metrics = glyph.metrics,
        };
    }

    fn tintGlyphForSkinTone(self: *Self, glyph: *ColorGlyph, tone: SkinTone) !void {
        if (tone == .default) return;

        const tint = self.getSkinToneColor(tone);

        for (glyph.layers) |*layer| {
            if (layer.bitmap.len == 0 or layer.width == 0 or layer.height == 0) continue;
            if (layer.bitmap.len < layer.width * layer.height * 4) continue;

            var idx: usize = 0;
            while (idx < layer.bitmap.len) : (idx += 4) {
                const alpha = layer.bitmap[idx + 3];
                if (alpha == 0) continue;

                const r = layer.bitmap[idx];
                const g = layer.bitmap[idx + 1];
                const b = layer.bitmap[idx + 2];
                const brightness = std.math.max(r, std.math.max(g, b));
                if (brightness < 40) continue;

                layer.bitmap[idx] = @intCast((@as(u32, r) * 60 + @as(u32, tint.r) * 195) / 255);
                layer.bitmap[idx + 1] = @intCast((@as(u32, g) * 60 + @as(u32, tint.g) * 195) / 255);
                layer.bitmap[idx + 2] = @intCast((@as(u32, b) * 60 + @as(u32, tint.b) * 195) / 255);
            }
        }
    }

    fn getSkinToneColor(self: *Self, tone: SkinTone) Color {
        _ = self;
        return switch (tone) {
            .light => Color{ .r = 255, .g = 224, .b = 189, .a = 255 },
            .medium_light => Color{ .r = 242, .g = 203, .b = 164, .a = 255 },
            .medium => Color{ .r = 224, .g = 172, .b = 105, .a = 255 },
            .medium_dark => Color{ .r = 198, .g = 134, .b = 66, .a = 255 },
            .dark => Color{ .r = 141, .g = 85, .b = 36, .a = 255 },
            .default => Color{ .r = 255, .g = 214, .b = 120, .a = 255 },
        };
    }

    fn skinToneFromModifier(self: *Self, modifier: u32) ?SkinTone {
        _ = self;
        return switch (modifier) {
            0x1F3FB => .light,
            0x1F3FC => .medium_light,
            0x1F3FD => .medium,
            0x1F3FE => .medium_dark,
            0x1F3FF => .dark,
            else => null,
        };
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

    try std.testing.expect(renderer.isEmoji(0x1F600)); // 😀
    try std.testing.expect(renderer.isEmoji(0x1F44D)); // 👍
    try std.testing.expect(!renderer.isEmoji('A'));

    try std.testing.expect(renderer.supportsSkinTones(0x1F44D));
    try std.testing.expect(!renderer.supportsSkinTones(0x1F600));
}

test "Unicode emoji detection via Unicode module" {
    const testing = std.testing;

    try testing.expect(Unicode.getEmojiProperty(0x1F600) != .None);
    try testing.expect(Unicode.getEmojiProperty(0x2600) != .None);
    try testing.expect(Unicode.getEmojiProperty('A') == .None);

    const allocator = std.testing.allocator;
    var renderer = EmojiRenderer.init(allocator);
    defer renderer.deinit();

    const flag_sequence = [_]u32{ 0x1F1FA, 0x1F1F8 };
    try testing.expect(renderer.isEmojiSequence(&flag_sequence));
    try testing.expect(renderer.isFlagSequence(&flag_sequence));

    const skin_sequence = [_]u32{ 0x1F44D, 0x1F3FB };
    try testing.expect(renderer.isEmojiSequence(&skin_sequence));
    try testing.expect(renderer.isSkinToneSequence(&skin_sequence));

    const zwj_sequence = [_]u32{ 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467 };
    try testing.expect(renderer.isEmojiSequence(&zwj_sequence));
    try testing.expect(renderer.isZWJSequence(&zwj_sequence));
}

test "EmojiRenderer sequence rendering" {
    const allocator = std.testing.allocator;

    var renderer = try EmojiRenderer.init(allocator);
    defer renderer.deinit();

    const thumbs_up = [_]u32{ 0x1F44D, 0x1F3FD };
    const options = EmojiRenderOptions{ .prefer_color = true, .skin_tone = .default, .text_presentation = false };
    if (try renderer.renderEmojiSequence(&thumbs_up, 24.0, options)) |glyph| {
        defer glyph.deinit(renderer.allocator);
        try std.testing.expect(glyph.layers.len >= 1);
    }

    const family = [_]u32{ 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F466 };
    if (try renderer.renderEmojiSequence(&family, 24.0, options)) |glyph| {
        defer glyph.deinit(renderer.allocator);
        try std.testing.expect(glyph.metrics.width > 0);
    }
}
