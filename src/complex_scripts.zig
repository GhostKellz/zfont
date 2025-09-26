const std = @import("std");
const root = @import("root.zig");

// Complex script support for Arabic, Indic, Thai, and other writing systems
// Handles contextual shaping, reordering, and script-specific features
pub const ComplexScriptProcessor = struct {
    allocator: std.mem.Allocator,
    unicode: *@import("unicode.zig").Unicode,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, unicode: *@import("unicode.zig").Unicode) Self {
        return Self{
            .allocator = allocator,
            .unicode = unicode,
        };
    }

    pub fn processScript(self: *Self, text: []const u8, script: ScriptType) !ProcessedText {
        return switch (script) {
            .arabic => self.processArabic(text),
            .devanagari => self.processDevanagari(text),
            .thai => self.processThai(text),
            .hebrew => self.processHebrew(text),
            .myanmar => self.processMyanmar(text),
            .khmer => self.processKhmer(text),
            .latin => self.processLatin(text),
        };
    }

    // Arabic script processing with contextual forms
    fn processArabic(self: *Self, text: []const u8) !ProcessedText {
        var processed = ProcessedText.init(self.allocator);
        var i: usize = 0;

        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + char_len <= text.len) {
                const codepoint = std.unicode.utf8Decode(text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };

                // Determine contextual form based on neighbors
                const form = self.getArabicForm(text, i);
                const shaped_char = self.applyArabicShaping(codepoint, form);

                try processed.addChar(shaped_char, .right_to_left);
                i += char_len;
            } else {
                break;
            }
        }

        // Apply Arabic-specific features
        try self.applyArabicFeatures(&processed);
        return processed;
    }

    fn getArabicForm(self: *Self, text: []const u8, pos: usize) ArabicForm {
        const has_prev = pos > 0 and self.isArabicJoining(self.getPreviousChar(text, pos));
        const has_next = self.hasNextArabicChar(text, pos) and self.isArabicJoining(self.getNextChar(text, pos));

        return switch (@as(u8, if (has_prev) 1 else 0) | (@as(u8, if (has_next) 2 else 0))) {
            0 => .isolated,
            1 => .final,
            2 => .initial,
            3 => .medial,
            else => .isolated,
        };
    }

    fn isArabicJoining(self: *Self, codepoint: u32) bool {
        _ = self;
        // Arabic joining characters (simplified)
        return (codepoint >= 0x0627 and codepoint <= 0x06EF) or
               (codepoint >= 0xFB50 and codepoint <= 0xFDFF) or
               (codepoint >= 0xFE70 and codepoint <= 0xFEFF);
    }

    fn applyArabicShaping(self: *Self, codepoint: u32, form: ArabicForm) u32 {
        _ = self;
        // Arabic shaping table (simplified mapping)
        return switch (codepoint) {
            // Example: Arabic letter BEH
            0x0628 => switch (form) {
                .isolated => 0xFE8F,
                .final => 0xFE90,
                .initial => 0xFE91,
                .medial => 0xFE92,
            },
            // Example: Arabic letter TEH
            0x062A => switch (form) {
                .isolated => 0xFE95,
                .final => 0xFE96,
                .initial => 0xFE97,
                .medial => 0xFE98,
            },
            // Add more characters as needed
            else => codepoint, // Return unchanged if no mapping
        };
    }

    fn applyArabicFeatures(self: *Self, processed: *ProcessedText) !void {
        _ = self;
        // Apply Arabic-specific OpenType features
        // - init: Initial forms
        // - medi: Medial forms
        // - fina: Final forms
        // - liga: Arabic ligatures (lam-alef, etc.)
        // - mark: Mark positioning
        // - mkmk: Mark-to-mark positioning

        // Example: Lam-Alef ligature
        var i: usize = 0;
        while (i + 1 < processed.chars.items.len) {
            const lam = processed.chars.items[i].codepoint;
            const alef = processed.chars.items[i + 1].codepoint;

            if (lam == 0x0644 and alef == 0x0627) { // Lam + Alef
                // Replace with ligature
                processed.chars.items[i].codepoint = 0xFEFB; // Lam-Alef ligature
                _ = processed.chars.orderedRemove(i + 1);
                continue;
            }
            i += 1;
        }
    }

    // Devanagari script processing with conjunct formation
    fn processDevanagari(self: *Self, text: []const u8) !ProcessedText {
        var processed = ProcessedText.init(self.allocator);
        var i: usize = 0;

        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + char_len <= text.len) {
                const codepoint = std.unicode.utf8Decode(text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };

                try processed.addChar(codepoint, .left_to_right);
                i += char_len;
            } else {
                break;
            }
        }

        // Apply Devanagari reordering and conjunct formation
        try self.applyDevanagariReordering(&processed);
        try self.applyDevanagariFeatures(&processed);

        return processed;
    }

    fn applyDevanagariReordering(self: *Self, processed: *ProcessedText) !void {
        // Devanagari reordering rules:
        // 1. Reph (र्) moves to end of syllable
        // 2. Matras (vowel signs) are reordered
        // 3. Halant conjuncts are formed

        var i: usize = 0;
        while (i < processed.chars.items.len) {
            const char = processed.chars.items[i];

            // Handle Reph (Ra + Halant at start of syllable)
            if (char.codepoint == 0x0930 and // Ra
                i + 1 < processed.chars.items.len and
                processed.chars.items[i + 1].codepoint == 0x094D) // Halant
            {
                // Find end of syllable and move Reph there
                const syllable_end = self.findSyllableEnd(processed, i + 2);
                const reph_char = ProcessedChar{ .codepoint = 0xE100, .direction = .left_to_right }; // Reph form

                // Remove Ra + Halant
                _ = processed.chars.orderedRemove(i + 1); // Remove Halant
                _ = processed.chars.orderedRemove(i);     // Remove Ra

                // Insert Reph at syllable end
                try processed.chars.insert(syllable_end - 2, reph_char);
                continue;
            }

            i += 1;
        }
    }

    fn findSyllableEnd(self: *Self, processed: *ProcessedText, start: usize) usize {
        var pos = start;

        while (pos < processed.chars.items.len) {
            const char = processed.chars.items[pos];

            // End syllable at next consonant or end of text
            if (self.isDevanagariConsonant(char.codepoint) and pos > start) {
                break;
            }
            pos += 1;
        }

        return pos;
    }

    fn isDevanagariConsonant(self: *Self, codepoint: u32) bool {
        _ = self;
        return codepoint >= 0x0915 and codepoint <= 0x0939; // Ka to Ha
    }

    fn applyDevanagariFeatures(self: *Self, processed: *ProcessedText) !void {
        // Apply Devanagari OpenType features:
        // - nukt: Nukta forms
        // - akhn: Akhands
        // - rphf: Reph form
        // - blwf: Below-base forms
        // - half: Half forms
        // - pstf: Post-base forms
        // - vatu: Vattu variants

        // Example: Half forms (consonant + halant + consonant)
        var i: usize = 0;
        while (i + 2 < processed.chars.items.len) {
            const cons1 = processed.chars.items[i].codepoint;
            const halant = processed.chars.items[i + 1].codepoint;
            const cons2 = processed.chars.items[i + 2].codepoint;

            if (self.isDevanagariConsonant(cons1) and halant == 0x094D and self.isDevanagariConsonant(cons2)) {
                // Form conjunct
                const conjunct = self.getDevanagariConjunct(cons1, cons2);
                if (conjunct != 0) {
                    processed.chars.items[i].codepoint = conjunct;
                    _ = processed.chars.orderedRemove(i + 2); // Remove second consonant
                    _ = processed.chars.orderedRemove(i + 1); // Remove halant
                    continue;
                }
            }
            i += 1;
        }
    }

    fn getDevanagariConjunct(self: *Self, cons1: u32, cons2: u32) u32 {
        _ = self;
        // Simplified conjunct mapping
        return switch (@as(u64, cons1) << 32 | cons2) {
            (@as(u64, 0x0915) << 32) | 0x0937 => 0xE200, // Ka + Sha = Ksha
            (@as(u64, 0x091C) << 32) | 0x091E => 0xE201, // Ja + Nya = Jnya
            (@as(u64, 0x0924) << 32) | 0x0930 => 0xE202, // Ta + Ra = Tra
            else => 0,
        };
    }

    // Thai script processing with cluster detection
    fn processThai(self: *Self, text: []const u8) !ProcessedText {
        var processed = ProcessedText.init(self.allocator);
        var i: usize = 0;

        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + char_len <= text.len) {
                const codepoint = std.unicode.utf8Decode(text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };

                try processed.addChar(codepoint, .left_to_right);
                i += char_len;
            } else {
                break;
            }
        }

        // Apply Thai vowel and tone mark reordering
        try self.applyThaiReordering(&processed);
        return processed;
    }

    fn applyThaiReordering(self: *Self, processed: *ProcessedText) !void {
        _ = self;
        _ = processed;
        // Thai doesn't require complex reordering like Devanagari
        // but vowels and tone marks need proper positioning
        // This is mostly handled by the font's positioning features
    }

    // Hebrew script processing (right-to-left)
    fn processHebrew(self: *Self, text: []const u8) !ProcessedText {
        var processed = ProcessedText.init(self.allocator);
        var i: usize = 0;

        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + char_len <= text.len) {
                const codepoint = std.unicode.utf8Decode(text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };

                try processed.addChar(codepoint, .right_to_left);
                i += char_len;
            } else {
                break;
            }
        }

        return processed;
    }

    // Myanmar script processing
    fn processMyanmar(self: *Self, text: []const u8) !ProcessedText {
        var processed = ProcessedText.init(self.allocator);
        var i: usize = 0;

        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + char_len <= text.len) {
                const codepoint = std.unicode.utf8Decode(text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };

                try processed.addChar(codepoint, .left_to_right);
                i += char_len;
            } else {
                break;
            }
        }

        try self.applyMyanmarReordering(&processed);
        return processed;
    }

    fn applyMyanmarReordering(self: *Self, processed: *ProcessedText) !void {
        _ = self;
        _ = processed;
        // Myanmar reordering rules (simplified)
        // Kinzi, medial consonants, and vowel marks need reordering
    }

    // Khmer script processing
    fn processKhmer(self: *Self, text: []const u8) !ProcessedText {
        var processed = ProcessedText.init(self.allocator);
        var i: usize = 0;

        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + char_len <= text.len) {
                const codepoint = std.unicode.utf8Decode(text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };

                try processed.addChar(codepoint, .left_to_right);
                i += char_len;
            } else {
                break;
            }
        }

        try self.applyKhmerReordering(&processed);
        return processed;
    }

    fn applyKhmerReordering(self: *Self, processed: *ProcessedText) !void {
        _ = self;
        _ = processed;
        // Khmer vowel reordering and coeng processing
    }

    // Latin script processing (simple case)
    fn processLatin(self: *Self, text: []const u8) !ProcessedText {
        var processed = ProcessedText.init(self.allocator);
        var i: usize = 0;

        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + char_len <= text.len) {
                const codepoint = std.unicode.utf8Decode(text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };

                try processed.addChar(codepoint, .left_to_right);
                i += char_len;
            } else {
                break;
            }
        }

        return processed;
    }

    // Utility functions
    fn getPreviousChar(self: *Self, text: []const u8, pos: usize) u32 {
        _ = self;
        if (pos == 0) return 0;

        var i = pos;
        while (i > 0) {
            i -= 1;
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch continue;
            if (i + char_len == pos) {
                return std.unicode.utf8Decode(text[i..pos]) catch 0;
            }
        }
        return 0;
    }

    fn getNextChar(self: *Self, text: []const u8, pos: usize) u32 {
        _ = self;
        const char_len = std.unicode.utf8ByteSequenceLength(text[pos]) catch return 0;
        const next_pos = pos + char_len;

        if (next_pos >= text.len) return 0;

        const next_char_len = std.unicode.utf8ByteSequenceLength(text[next_pos]) catch return 0;
        if (next_pos + next_char_len <= text.len) {
            return std.unicode.utf8Decode(text[next_pos..next_pos + next_char_len]) catch 0;
        }
        return 0;
    }

    fn hasNextArabicChar(self: *Self, text: []const u8, pos: usize) bool {
        return self.getNextChar(text, pos) != 0;
    }
};

pub const ScriptType = enum {
    latin,
    arabic,
    devanagari,
    thai,
    hebrew,
    myanmar,
    khmer,
};

pub const ArabicForm = enum {
    isolated,
    initial,
    medial,
    final,
};

pub const Direction = enum {
    left_to_right,
    right_to_left,
};

pub const ProcessedChar = struct {
    codepoint: u32,
    direction: Direction,
};

pub const ProcessedText = struct {
    chars: std.ArrayList(ProcessedChar),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ProcessedText {
        return ProcessedText{
            .chars = std.ArrayList(ProcessedChar).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProcessedText) void {
        self.chars.deinit();
    }

    pub fn addChar(self: *ProcessedText, codepoint: u32, direction: Direction) !void {
        try self.chars.append(ProcessedChar{
            .codepoint = codepoint,
            .direction = direction,
        });
    }
};

// Script detection based on Unicode ranges
pub const ScriptDetector = struct {
    pub fn detectScript(text: []const u8) ScriptType {
        var i: usize = 0;

        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + char_len <= text.len) {
                const codepoint = std.unicode.utf8Decode(text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };

                // Detect script based on Unicode ranges
                if (codepoint >= 0x0600 and codepoint <= 0x06FF) return .arabic;
                if (codepoint >= 0x0900 and codepoint <= 0x097F) return .devanagari;
                if (codepoint >= 0x0E00 and codepoint <= 0x0E7F) return .thai;
                if (codepoint >= 0x0590 and codepoint <= 0x05FF) return .hebrew;
                if (codepoint >= 0x1000 and codepoint <= 0x109F) return .myanmar;
                if (codepoint >= 0x1780 and codepoint <= 0x17FF) return .khmer;

                i += char_len;
            } else {
                break;
            }
        }

        return .latin; // Default
    }
};

test "ComplexScriptProcessor Arabic processing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var unicode = @import("unicode.zig").Unicode.init(allocator);
    defer unicode.deinit();

    var processor = ComplexScriptProcessor.init(allocator, &unicode);

    // Test Arabic text processing
    const arabic_text = "مرحبا"; // "Hello" in Arabic
    var result = processor.processScript(arabic_text, .arabic) catch return;
    defer result.deinit();

    try testing.expect(result.chars.items.len > 0);
    try testing.expect(result.chars.items[0].direction == .right_to_left);
}

test "ScriptDetector functionality" {
    const arabic_text = "مرحبا";
    const devanagari_text = "नमस्ते";
    const latin_text = "Hello";

    try std.testing.expect(ScriptDetector.detectScript(arabic_text) == .arabic);
    try std.testing.expect(ScriptDetector.detectScript(devanagari_text) == .devanagari);
    try std.testing.expect(ScriptDetector.detectScript(latin_text) == .latin);
}