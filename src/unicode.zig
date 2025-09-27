const std = @import("std");
const gcode = @import("gcode");

// gcode integration for high-performance Unicode property lookups
// This provides O(1) Unicode property lookups using gcode's optimized lookup tables

pub const Unicode = struct {
    const TableType = @TypeOf(gcode.table);

    pub const PropertyCache = struct {
        table: *const TableType,
        cached_stage1: u32,
        cached_stage2: [*]const u16,

        pub fn init() PropertyCache {
            return PropertyCache{
                .table = &gcode.table,
                .cached_stage1 = std.math.maxInt(u32),
                .cached_stage2 = undefined,
            };
        }

        pub inline fn lookupRaw(self: *PropertyCache, codepoint: u32) gcode.Properties {
            const cp: u21 = @intCast(codepoint);
            const stage1_idx = cp >> 8;
            if (stage1_idx != self.cached_stage1) {
                self.cached_stage1 = stage1_idx;
                const stage2_index = self.table.stage1[stage1_idx];
                self.cached_stage2 = self.table.stage2.ptr + stage2_index * 256;
            }

            const stage3_index = self.cached_stage2[cp & 0xFF];
            return self.table.stage3[stage3_index];
        }

        pub inline fn get(self: *PropertyCache, codepoint: u32) Properties {
            return buildProperties(codepoint, self.lookupRaw(codepoint));
        }
    };
    // Re-export gcode types with our naming conventions for compatibility
    pub const CharacterWidth = enum(u8) {
        zero = 0,
        narrow = 1,
        wide = 2,
        ambiguous = 3, // Treated as narrow in most contexts

        pub fn fromGcodeWidth(width: u2) CharacterWidth {
            return switch (width) {
                0 => .zero,
                1 => .narrow,
                2 => .wide,
                else => .narrow, // Fallback
            };
        }
    };

    pub const GraphemeBreakProperty = gcode.GraphemeBoundaryClass;

    pub const EmojiProperty = enum {
        None,
        Emoji,
        Emoji_Presentation,
        Emoji_Modifier,
        Emoji_Modifier_Base,
        Emoji_Component,
        Extended_Pictographic,

        pub fn fromGraphemeClass(class: gcode.GraphemeBoundaryClass) EmojiProperty {
            return switch (class) {
                .extended_pictographic => .Extended_Pictographic,
                .extended_pictographic_base => .Emoji_Modifier_Base,
                .emoji_modifier => .Emoji_Modifier,
                else => .None,
            };
        }
    };

    pub const ScriptProperty = enum {
        Unknown,
        Common,
        Latin,
        Greek,
        Cyrillic,
        Armenian,
        Hebrew,
        Arabic,
        Syriac,
        Thaana,
        Devanagari,
        Bengali,
        Gurmukhi,
        Gujarati,
        Oriya,
        Tamil,
        Telugu,
        Kannada,
        Malayalam,
        Sinhala,
        Thai,
        Lao,
        Tibetan,
        Myanmar,
        Georgian,
        Hangul,
        Ethiopic,
        Cherokee,
        Canadian_Aboriginal,
        Ogham,
        Runic,
        Khmer,
        Mongolian,
        Hiragana,
        Katakana,
        Bopomofo,
        Han,
        Yi,
        Old_Italic,
        Gothic,
        Deseret,
        Inherited,
        Tagalog,
        Hanunoo,
        Buhid,
        Tagbanwa,
        Limbu,
        Tai_Le,
        Linear_B,
        Ugaritic,
        Shavian,
        Osmanya,
        Cypriot,
        Braille,
        Buginese,
        Coptic,
        New_Tai_Lue,
        Glagolitic,
        Tifinagh,
        Syloti_Nagri,
        Old_Persian,
        Kharoshthi,
        Balinese,
        Cuneiform,
        Phoenician,
        Phags_Pa,
        Nko,
    };

    pub const Properties = struct {
        width: CharacterWidth,
        grapheme_break: GraphemeBreakProperty,
        emoji: EmojiProperty,
        script: ScriptProperty,
        is_control: bool,
        is_whitespace: bool,
        is_combining: bool,
    };

    pub const EastAsianWidthMode = enum {
        standard, // Ambiguous characters treated as narrow (default)
        wide, // Ambiguous characters treated as wide for CJK contexts
    };

    // High-performance Unicode property lookup using gcode
    pub inline fn getProperties(codepoint: u32) Properties {
        const gcode_props = gcode.getProperties(@intCast(codepoint));
        return buildProperties(codepoint, gcode_props);
    }

    pub fn getCharacterWidth(codepoint: u32) CharacterWidth {
        const width = gcode.getWidth(@intCast(codepoint));
        return CharacterWidth.fromGcodeWidth(width);
    }

    pub fn isZeroWidth(codepoint: u32) bool {
        return gcode.isZeroWidth(@intCast(codepoint));
    }

    pub fn isWideCharacter(codepoint: u32) bool {
        return gcode.isWide(@intCast(codepoint));
    }

    pub fn isAmbiguousWidth(codepoint: u32) bool {
        const props = gcode.getProperties(@intCast(codepoint));
        return props.ambiguous_width;
    }

    pub fn getGraphemeBreakProperty(codepoint: u32) GraphemeBreakProperty {
        return gcode.getProperties(@intCast(codepoint)).grapheme_boundary_class;
    }

    pub fn getEmojiProperty(codepoint: u32) EmojiProperty {
        // Enhanced emoji detection based on Unicode ranges and properties
        const props = gcode.getProperties(@intCast(codepoint));

        // First check gcode's detection
        const gcode_emoji = EmojiProperty.fromGraphemeClass(props.grapheme_boundary_class);
        if (gcode_emoji != .None) {
            return gcode_emoji;
        }

        // Fallback to manual range detection for cases gcode might miss
        if (codepoint >= 0x1F600 and codepoint <= 0x1F64F) return .Emoji_Presentation; // Emoticons
        if (codepoint >= 0x1F300 and codepoint <= 0x1F5FF) return .Emoji_Presentation; // Misc Symbols and Pictographs
        if (codepoint >= 0x1F680 and codepoint <= 0x1F6FF) return .Emoji_Presentation; // Transport and Map
        if (codepoint >= 0x1F700 and codepoint <= 0x1F77F) return .Emoji_Presentation; // Alchemical
        if (codepoint >= 0x1F780 and codepoint <= 0x1F7FF) return .Emoji_Presentation; // Geometric Shapes Extended
        if (codepoint >= 0x1F800 and codepoint <= 0x1F8FF) return .Emoji_Presentation; // Supplemental Arrows-C
        if (codepoint >= 0x1F900 and codepoint <= 0x1F9FF) return .Emoji_Presentation; // Supplemental Symbols
        if (codepoint >= 0x1FA00 and codepoint <= 0x1FA6F) return .Emoji_Presentation; // Chess Symbols
        if (codepoint >= 0x1FA70 and codepoint <= 0x1FAFF) return .Emoji_Presentation; // Extended-A

        // Skin tone modifiers
        if (codepoint >= 0x1F3FB and codepoint <= 0x1F3FF) return .Emoji_Modifier;

        // Regular emoji in other ranges
        if (codepoint >= 0x2600 and codepoint <= 0x26FF) return .Emoji; // Miscellaneous Symbols
        if (codepoint >= 0x2700 and codepoint <= 0x27BF) return .Emoji; // Dingbats

        return .None;
    }

    pub fn getScriptProperty(codepoint: u32) ScriptProperty {
        return convertScript(gcode.getScript(@intCast(codepoint)));
    }

    pub fn isControl(codepoint: u32) bool {
        return gcode.isControlCharacter(@intCast(codepoint));
    }

    pub fn isWhitespace(codepoint: u32) bool {
        return switch (codepoint) {
            0x0009, // Tab
            0x000A, // Line Feed
            0x000B, // Vertical Tab
            0x000C, // Form Feed
            0x000D, // Carriage Return
            0x0020, // Space
            0x0085, // Next Line
            0x00A0, // Non-breaking Space
            0x1680, // Ogham Space Mark
            0x2000...0x200A, // Various spaces
            0x2028, // Line Separator
            0x2029, // Paragraph Separator
            0x202F, // Narrow No-break Space
            0x205F, // Medium Mathematical Space
            0x3000, // Ideographic Space
            => true,
            else => false,
        };
    }

    pub fn isCombining(codepoint: u32) bool {
        const props = gcode.getProperties(@intCast(codepoint));
        return props.combining_class > 0;
    }

    // Grapheme cluster boundary detection using gcode
    pub const GraphemeBreakState = gcode.GraphemeBreakState;

    pub fn isGraphemeBoundary(prev_cp: u32, curr_cp: u32, state: *GraphemeBreakState) bool {
        return gcode.graphemeBreak(@intCast(prev_cp), @intCast(curr_cp), state);
    }

    // String processing utilities using gcode
    pub fn getDisplayWidth(codepoint: u32, mode: EastAsianWidthMode) u8 {
        const props = gcode.getProperties(@intCast(codepoint));

        if (props.width == 0) return 0;

        if (mode == .wide and props.ambiguous_width) {
            return 2;
        }

        const width_value: u8 = @intCast(props.width);
        return width_value;
    }

    pub fn stringWidthWithMode(utf8_string: []const u8, mode: EastAsianWidthMode) usize {
        var iter = gcode.codePointIterator(utf8_string);
        var width: usize = 0;

        while (iter.next()) |cp| {
            width += @as(usize, getDisplayWidth(cp.code, mode));
        }

        return width;
    }

    pub fn stringWidth(utf8_string: []const u8) usize {
        return stringWidthWithMode(utf8_string, .standard);
    }

    pub fn graphemeIterator(utf8_string: []const u8) gcode.GraphemeIterator {
        return gcode.graphemeIterator(utf8_string);
    }

    pub fn codePointIterator(utf8_string: []const u8) gcode.CodePointIterator {
        return gcode.codePointIterator(utf8_string);
    }

    // Cursor movement helpers
    pub fn findPreviousGrapheme(text: []const u8, pos: usize) usize {
        return gcode.findPreviousGrapheme(text, pos);
    }

    pub fn findNextGrapheme(text: []const u8, pos: usize) usize {
        return gcode.findNextGrapheme(text, pos);
    }
    inline fn buildProperties(codepoint: u32, gcode_props: gcode.Properties) Properties {
        return Properties{
            .width = CharacterWidth.fromGcodeWidth(gcode_props.width),
            .grapheme_break = gcode_props.grapheme_boundary_class,
            .emoji = EmojiProperty.fromGraphemeClass(gcode_props.grapheme_boundary_class),
            .script = convertScript(gcode.getScript(@intCast(codepoint))),
            .is_control = isControl(codepoint),
            .is_whitespace = isWhitespace(codepoint),
            .is_combining = gcode_props.combining_class > 0,
        };
    }
    fn convertScript(script: gcode.Script) ScriptProperty {
        return switch (script) {
            .Common => .Common,
            .Inherited => .Inherited,
            .Latin => .Latin,
            .Greek => .Greek,
            .Cyrillic => .Cyrillic,
            .Armenian => .Armenian,
            .Hebrew => .Hebrew,
            .Arabic => .Arabic,
            .Syriac => .Syriac,
            .Thaana => .Thaana,
            .Devanagari => .Devanagari,
            .Bengali => .Bengali,
            .Gurmukhi => .Gurmukhi,
            .Gujarati => .Gujarati,
            .Oriya => .Oriya,
            .Tamil => .Tamil,
            .Telugu => .Telugu,
            .Kannada => .Kannada,
            .Malayalam => .Malayalam,
            .Sinhala => .Sinhala,
            .Thai => .Thai,
            .Lao => .Lao,
            .Tibetan => .Tibetan,
            .Myanmar => .Myanmar,
            .Georgian => .Georgian,
            .Hangul => .Hangul,
            .Ethiopic => .Ethiopic,
            .Cherokee => .Cherokee,
            .Canadian_Aboriginal => .Canadian_Aboriginal,
            .Ogham => .Ogham,
            .Runic => .Runic,
            .Khmer => .Khmer,
            .Mongolian => .Mongolian,
            .Hiragana => .Hiragana,
            .Katakana => .Katakana,
            .Bopomofo => .Bopomofo,
            .Han => .Han,
            .Yi => .Yi,
            .Old_Italic => .Old_Italic,
            .Gothic => .Gothic,
            .Deseret => .Deseret,
            .Tagalog => .Tagalog,
            .Hanunoo => .Hanunoo,
            .Buhid => .Buhid,
            .Tagbanwa => .Tagbanwa,
            .Limbu => .Limbu,
            .Tai_Le => .Tai_Le,
            .Linear_B => .Linear_B,
            .Ugaritic => .Ugaritic,
            .Shavian => .Shavian,
            .Osmanya => .Osmanya,
            .Cypriot => .Cypriot,
            .Braille => .Braille,
            .Buginese => .Buginese,
            .Coptic => .Coptic,
            .New_Tai_Lue => .New_Tai_Lue,
            .Glagolitic => .Glagolitic,
            .Tifinagh => .Tifinagh,
            .Syloti_Nagri => .Syloti_Nagri,
            .Old_Persian => .Old_Persian,
            .Kharoshthi => .Kharoshthi,
            .Balinese => .Balinese,
            .Cuneiform => .Cuneiform,
            .Phoenician => .Phoenician,
            .Phags_Pa => .Phags_Pa,
            .Nko => .Nko,
            else => .Unknown,
        };
    }
};

// Tests
test "Unicode gcode integration" {
    const testing = std.testing;

    // Test basic width detection
    try testing.expect(Unicode.getCharacterWidth('A') == .narrow);
    try testing.expect(Unicode.getCharacterWidth('中') == .wide);
    try testing.expect(Unicode.getCharacterWidth(0x200B) == .zero); // ZWSP

    // Test properties
    const props = Unicode.getProperties('A');
    try testing.expect(props.width == .narrow);
    try testing.expect(!props.is_control);
    try testing.expect(!props.is_whitespace);
    try testing.expect(Unicode.getScriptProperty('A') == .Latin);
    try testing.expect(Unicode.getScriptProperty('中') == .Han);

    // Test control character
    const control_props = Unicode.getProperties(0x07); // Bell
    try testing.expect(control_props.is_control);
}

test "Unicode grapheme boundary detection with gcode" {
    const testing = std.testing;

    var state = Unicode.GraphemeBreakState{};

    // Simple case: A|B should have boundary
    try testing.expect(Unicode.isGraphemeBoundary('A', 'B', &state));

    // Don't break CR-LF
    state = Unicode.GraphemeBreakState{};
    try testing.expect(!Unicode.isGraphemeBoundary('\r', '\n', &state));
}

test "Unicode string processing" {
    const testing = std.testing;

    // Test string width calculation
    const width = Unicode.stringWidth("Hello 世界");
    try testing.expect(width > 5); // Should account for wide characters
    const ambiguous_standard = Unicode.stringWidthWithMode("·", .standard);
    try testing.expectEqual(@as(usize, 1), ambiguous_standard);
    const ambiguous_wide = Unicode.stringWidthWithMode("·", .wide);
    try testing.expectEqual(@as(usize, 2), ambiguous_wide);

    // Test grapheme iteration
    var iter = Unicode.graphemeIterator("hello");
    try testing.expect(iter.next() != null);
}

test "Unicode property cache fast path" {
    const testing = std.testing;

    var cache = Unicode.PropertyCache.init();

    const codepoints = [_]u32{ 'A', 0x200B, 0x1F600, 0x0627 };

    for (codepoints) |cp| {
        const from_cache = cache.get(cp);
        const direct = Unicode.getProperties(cp);

        try testing.expectEqual(from_cache.width, direct.width);
        try testing.expect(from_cache.grapheme_break == direct.grapheme_break);
        try testing.expect(from_cache.emoji == direct.emoji);
    }
}

test "Emoji property detection" {
    const testing = std.testing;

    // Test emoji detection
    try testing.expect(Unicode.getEmojiProperty(0x1F600) != .None); // 😀
    try testing.expect(Unicode.getEmojiProperty('A') == .None);

    // Test emoji modifier base
    try testing.expect(Unicode.getEmojiProperty(0x1F44D) == .Emoji_Modifier_Base); // 👍

    // Test skin tone modifier
    try testing.expect(Unicode.getEmojiProperty(0x1F3FB) == .Emoji_Modifier);
}

test "Script detection" {
    const testing = std.testing;

    try testing.expect(Unicode.getScriptProperty('A') == .Latin);
    try testing.expect(Unicode.getScriptProperty('中') == .Han);
    try testing.expect(Unicode.getScriptProperty('あ') == .Hiragana);
    try testing.expect(Unicode.getScriptProperty('한') == .Hangul);
}
