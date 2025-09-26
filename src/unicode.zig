const std = @import("std");
const gcode = @import("gcode");

// gcode integration for high-performance Unicode property lookups
// This provides O(1) Unicode property lookups using gcode's optimized lookup tables

pub const Unicode = struct {
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

        pub fn detectFromCodepoint(codepoint: u21) ScriptProperty {
            // Basic script detection based on Unicode ranges
            return switch (codepoint) {
                // Basic Latin
                0x0000...0x007F => .Latin,
                // Latin-1 Supplement and Extended
                0x0080...0x024F => .Latin,
                // Greek
                0x0370...0x03FF => .Greek,
                // Cyrillic
                0x0400...0x04FF, 0x0500...0x052F => .Cyrillic,
                // Armenian
                0x0530...0x058F => .Armenian,
                // Hebrew
                0x0590...0x05FF => .Hebrew,
                // Arabic
                0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF => .Arabic,
                // Devanagari
                0x0900...0x097F => .Devanagari,
                // Bengali
                0x0980...0x09FF => .Bengali,
                // Gurmukhi
                0x0A00...0x0A7F => .Gurmukhi,
                // Gujarati
                0x0A80...0x0AFF => .Gujarati,
                // Oriya
                0x0B00...0x0B7F => .Oriya,
                // Tamil
                0x0B80...0x0BFF => .Tamil,
                // Telugu
                0x0C00...0x0C7F => .Telugu,
                // Kannada
                0x0C80...0x0CFF => .Kannada,
                // Malayalam
                0x0D00...0x0D7F => .Malayalam,
                // Thai
                0x0E00...0x0E7F => .Thai,
                // Lao
                0x0E80...0x0EFF => .Lao,
                // Tibetan
                0x0F00...0x0FFF => .Tibetan,
                // Myanmar
                0x1000...0x109F => .Myanmar,
                // Georgian
                0x10A0...0x10FF, 0x2D00...0x2D2F => .Georgian,
                // Hangul
                0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF => .Hangul,
                // Hiragana
                0x3040...0x309F => .Hiragana,
                // Katakana
                0x30A0...0x30FF, 0x31F0...0x31FF => .Katakana,
                // Han (CJK)
                0x2E80...0x2EFF, 0x2F00...0x2FDF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                0xF900...0xFAFF, 0x20000...0x2A6DF, 0x2A700...0x2B73F, 0x2B740...0x2B81F,
                0x2B820...0x2CEAF, 0x2CEB0...0x2EBEF, 0x30000...0x3134F => .Han,
                // Common (punctuation, symbols, etc.)
                0x2000...0x206F, 0x2070...0x209F, 0x20A0...0x20CF, 0x2100...0x214F,
                0x2150...0x218F, 0x2190...0x21FF, 0x2200...0x22FF, 0x2300...0x23FF,
                0x2400...0x243F, 0x2440...0x245F, 0x2460...0x24FF, 0x2500...0x257F,
                0x2580...0x259F, 0x25A0...0x25FF, 0x2600...0x26FF, 0x2700...0x27BF => .Common,
                else => .Unknown,
            };
        }
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

    // High-performance Unicode property lookup using gcode
    pub fn getProperties(codepoint: u32) Properties {
        const gcode_props = gcode.getProperties(@intCast(codepoint));

        return Properties{
            .width = CharacterWidth.fromGcodeWidth(gcode_props.width),
            .grapheme_break = gcode_props.grapheme_boundary_class,
            .emoji = EmojiProperty.fromGraphemeClass(gcode_props.grapheme_boundary_class),
            .script = ScriptProperty.detectFromCodepoint(@intCast(codepoint)),
            .is_control = isControl(codepoint),
            .is_whitespace = isWhitespace(codepoint),
            .is_combining = gcode_props.combining_class > 0,
        };
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
        return ScriptProperty.detectFromCodepoint(@intCast(codepoint));
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
    pub fn stringWidth(utf8_string: []const u8) usize {
        return gcode.stringWidth(utf8_string);
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

    // Test grapheme iteration
    var iter = Unicode.graphemeIterator("hello");
    try testing.expect(iter.next() != null);
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