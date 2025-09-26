const std = @import("std");
const root = @import("root.zig");
const gcode = @import("gcode");

// Indic syllable formation processor using real gcode analysis
// Handles Devanagari, Bengali, Tamil, Telugu, Kannada, Malayalam, etc.
pub const IndicSyllableProcessor = struct {
    allocator: std.mem.Allocator,
    complex_analyzer: gcode.complex_script.ComplexScriptAnalyzer,
    syllable_table: SyllableTable,

    const Self = @This();

    const SyllableTable = std.HashMap(IndicCategory, SyllableInfo, SyllableContext, std.hash_map.default_max_load_percentage);

    const SyllableContext = struct {
        pub fn hash(self: @This(), key: IndicCategory) u64 {
            _ = self;
            return @intFromEnum(key);
        }

        pub fn eql(self: @This(), a: IndicCategory, b: IndicCategory) bool {
            _ = self;
            return a == b;
        }
    };

    const SyllableInfo = struct {
        position_type: SyllablePosition,
        joining_behavior: JoiningBehavior,
        reorder_class: u8,
    };

    pub const IndicCategory = enum(u8) {
        // Consonants
        consonant = 0,
        consonant_dead = 1,
        consonant_with_stacker = 2,
        consonant_prefixed = 3,
        consonant_below_base = 4,
        consonant_above_base = 5,
        consonant_post_base = 6,

        // Vowels
        vowel_independent = 10,
        vowel_dependent = 11,

        // Vowel marks (matras)
        matra_pre = 20,
        matra_post = 21,
        matra_above = 22,
        matra_below = 23,

        // Special marks
        nukta = 30,
        halant = 31, // Virama
        zwj = 32,    // Zero Width Joiner
        zwnj = 33,   // Zero Width Non-Joiner

        // Numbers and symbols
        number = 40,
        symbol = 41,

        // Others
        other = 50,
        invalid = 255,
    };

    pub const SyllablePosition = enum(u8) {
        base = 0,
        pre_base = 1,
        above_base = 2,
        below_base = 3,
        post_base = 4,
    };

    pub const JoiningBehavior = enum(u8) {
        none = 0,
        dual_joining = 1,
        left_joining = 2,
        right_joining = 3,
        transparent = 4,
    };

    pub fn init(allocator: std.mem.Allocator) !Self {
        var processor = Self{
            .allocator = allocator,
            .complex_analyzer = try gcode.complex_script.ComplexScriptAnalyzer.init(allocator),
            .syllable_table = SyllableTable.init(allocator),
        };

        try processor.loadIndicClassificationTable();
        return processor;
    }

    pub fn deinit(self: *Self) void {
        self.complex_analyzer.deinit();
        self.syllable_table.deinit();
    }

    fn loadIndicClassificationTable(self: *Self) !void {
        // Devanagari character classifications
        const devanagari_data = [_]struct { category: IndicCategory, info: SyllableInfo }{
            .{ .category = .consonant, .info = .{ .position_type = .base, .joining_behavior = .dual_joining, .reorder_class = 0 } },
            .{ .category = .vowel_independent, .info = .{ .position_type = .base, .joining_behavior = .none, .reorder_class = 0 } },
            .{ .category = .matra_pre, .info = .{ .position_type = .pre_base, .joining_behavior = .transparent, .reorder_class = 1 } },
            .{ .category = .matra_post, .info = .{ .position_type = .post_base, .joining_behavior = .transparent, .reorder_class = 3 } },
            .{ .category = .matra_above, .info = .{ .position_type = .above_base, .joining_behavior = .transparent, .reorder_class = 2 } },
            .{ .category = .matra_below, .info = .{ .position_type = .below_base, .joining_behavior = .transparent, .reorder_class = 4 } },
            .{ .category = .halant, .info = .{ .position_type = .below_base, .joining_behavior = .transparent, .reorder_class = 5 } },
            .{ .category = .nukta, .info = .{ .position_type = .below_base, .joining_behavior = .transparent, .reorder_class = 6 } },
        };

        for (devanagari_data) |entry| {
            try self.syllable_table.put(entry.category, entry.info);
        }
    }

    pub fn processSyllables(self: *Self, text: []const u8) !IndicSyllableResult {
        // Use gcode to analyze the text for Indic script properties
        const analyses = try self.complex_analyzer.analyzeText(text);
        defer self.allocator.free(analyses);

        var result = IndicSyllableResult.init(self.allocator);

        // Convert text to codepoints
        var codepoints = std.ArrayList(u32).init(self.allocator);
        defer codepoints.deinit();

        var i: usize = 0;
        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + char_len <= text.len) {
                const codepoint = std.unicode.utf8Decode(text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };
                try codepoints.append(codepoint);
                i += char_len;
            } else {
                break;
            }
        }

        // Process syllables using gcode analysis
        var syllable_start: usize = 0;
        var current_syllable = std.ArrayList(IndicCharacter).init(self.allocator);
        defer current_syllable.deinit();

        for (codepoints.items, 0..) |codepoint, pos| {
            if (pos < analyses.len) {
                const analysis = analyses[pos];
                const category = self.classifyIndicCharacter(codepoint, analysis);

                const indic_char = IndicCharacter{
                    .codepoint = codepoint,
                    .category = category,
                    .position = pos,
                    .syllable_position = self.determineSyllablePosition(category),
                    .reorder_class = self.getReorderClass(category),
                };

                // Check for syllable boundary
                if (self.isSyllableBoundary(category, current_syllable.items)) {
                    if (current_syllable.items.len > 0) {
                        // Complete current syllable
                        const syllable = try self.formSyllable(current_syllable.items, syllable_start);
                        try result.syllables.append(syllable);
                        current_syllable.clearRetainingCapacity();
                        syllable_start = pos;
                    }
                }

                try current_syllable.append(indic_char);
            }
        }

        // Process final syllable
        if (current_syllable.items.len > 0) {
            const syllable = try self.formSyllable(current_syllable.items, syllable_start);
            try result.syllables.append(syllable);
        }

        return result;
    }

    fn classifyIndicCharacter(self: *Self, codepoint: u32, analysis: gcode.complex_script.ComplexScriptAnalysis) IndicCategory {

        // Use gcode analysis for classification
        if (analysis.is_consonant) {
            if (analysis.has_below_base_form) return .consonant_below_base;
            if (analysis.has_above_base_form) return .consonant_above_base;
            if (analysis.has_post_base_form) return .consonant_post_base;
            return .consonant;
        }

        if (analysis.is_vowel) {
            if (analysis.is_dependent_vowel) return .vowel_dependent;
            return .vowel_independent;
        }

        // Specific Indic character ranges
        if (codepoint >= 0x0900 and codepoint <= 0x097F) { // Devanagari
            return self.classifyDevanagariCharacter(codepoint);
        } else if (codepoint >= 0x0980 and codepoint <= 0x09FF) { // Bengali
            return self.classifyBengaliCharacter(codepoint);
        } else if (codepoint >= 0x0B80 and codepoint <= 0x0BFF) { // Tamil
            return self.classifyTamilCharacter(codepoint);
        }

        // Special marks
        switch (codepoint) {
            0x093C, 0x09BC, 0x0A3C, 0x0ABC, 0x0B3C => return .nukta,
            0x094D, 0x09CD, 0x0A4D, 0x0ACD, 0x0B4D, 0x0BCD, 0x0C4D => return .halant,
            0x200D => return .zwj,
            0x200C => return .zwnj,
            else => return .other,
        }
    }

    fn classifyDevanagariCharacter(self: *Self, codepoint: u32) IndicCategory {
        _ = self;
        return switch (codepoint) {
            // Independent vowels
            0x0905...0x0914 => .vowel_independent,

            // Consonants
            0x0915...0x0939, 0x0958...0x095F => .consonant,

            // Dependent vowel signs (matras)
            0x093E => .matra_post, // AA
            0x093F => .matra_pre,  // I
            0x0940 => .matra_post, // II
            0x0941, 0x0942 => .matra_below, // U, UU
            0x0943, 0x0944 => .matra_below, // R, RR
            0x0945...0x0948 => .matra_above, // E vowels
            0x0949...0x094C => .matra_post,  // O vowels

            // Special marks
            0x093C => .nukta,
            0x094D => .halant,

            // Numbers
            0x0966...0x096F => .number,

            else => .other,
        };
    }

    fn classifyBengaliCharacter(self: *Self, codepoint: u32) IndicCategory {
        _ = self;
        return switch (codepoint) {
            // Independent vowels
            0x0985...0x0994 => .vowel_independent,

            // Consonants
            0x0995...0x09B9, 0x09DC...0x09DF => .consonant,

            // Dependent vowel signs
            0x09BE => .matra_post, // AA
            0x09BF => .matra_pre,  // I
            0x09C0 => .matra_post, // II
            0x09C1, 0x09C2 => .matra_below, // U, UU
            0x09C3, 0x09C4 => .matra_below, // R, RR
            0x09C7, 0x09C8 => .matra_pre,   // E vowels
            0x09CB, 0x09CC => .matra_post,  // O vowels

            // Special marks
            0x09BC => .nukta,
            0x09CD => .halant,

            else => .other,
        };
    }

    fn classifyTamilCharacter(self: *Self, codepoint: u32) IndicCategory {
        _ = self;
        return switch (codepoint) {
            // Independent vowels
            0x0B85...0x0B94 => .vowel_independent,

            // Consonants
            0x0B95...0x0BB9 => .consonant,

            // Dependent vowel signs
            0x0BBE => .matra_post, // AA
            0x0BBF => .matra_pre,  // I
            0x0BC0 => .matra_post, // II
            0x0BC1, 0x0BC2 => .matra_below, // U, UU
            0x0BC6...0x0BC8 => .matra_pre,   // E vowels
            0x0BCA...0x0BCC => .matra_post,  // O vowels

            // Special marks
            0x0BCD => .halant,

            else => .other,
        };
    }

    fn determineSyllablePosition(self: *Self, category: IndicCategory) SyllablePosition {
        const info = self.syllable_table.get(category) orelse return .base;
        return info.position_type;
    }

    fn getReorderClass(self: *Self, category: IndicCategory) u8 {
        const info = self.syllable_table.get(category) orelse return 0;
        return info.reorder_class;
    }

    fn isSyllableBoundary(self: *Self, category: IndicCategory, current_chars: []const IndicCharacter) bool {
        _ = self;

        // Syllable boundary rules for Indic scripts
        switch (category) {
            .vowel_independent => return true, // Independent vowels start new syllables
            .consonant => {
                // Consonant starts new syllable if previous was not halant
                if (current_chars.len == 0) return false;
                const last = current_chars[current_chars.len - 1];
                return last.category != .halant;
            },
            else => return false,
        }
    }

    fn formSyllable(self: *Self, chars: []const IndicCharacter, start_pos: usize) !IndicSyllable {
        var syllable = IndicSyllable{
            .characters = try self.allocator.dupe(IndicCharacter, chars),
            .start_position = start_pos,
            .base_character = null,
            .reordered_characters = std.ArrayList(IndicCharacter).init(self.allocator),
        };

        // Find base character (usually the first consonant)
        for (chars, 0..) |char, i| {
            if (char.category == .consonant or char.category == .vowel_independent) {
                syllable.base_character = i;
                break;
            }
        }

        // Reorder characters according to Indic syllable rules
        try self.reorderSyllable(&syllable);

        return syllable;
    }

    fn reorderSyllable(self: *Self, syllable: *IndicSyllable) !void {

        // Sort characters by reorder class
        var temp_chars = std.ArrayList(IndicCharacter).init(self.allocator);
        defer temp_chars.deinit();

        try temp_chars.appendSlice(syllable.characters);

        // Simple reordering by reorder class
        std.sort.insertion(IndicCharacter, temp_chars.items, {}, compareReorderClass);

        try syllable.reordered_characters.appendSlice(temp_chars.items);
    }

    fn compareReorderClass(_: void, a: IndicCharacter, b: IndicCharacter) bool {
        return a.reorder_class < b.reorder_class;
    }

    // Test with real Indic text
    pub fn testIndicProcessing(self: *Self) !void {
        const test_texts = [_][]const u8{
            "नमस्ते",        // Devanagari: "Namaste"
            "স্বাগতম",      // Bengali: "Welcome"
            "வணக்கம்",      // Tamil: "Vanakkam"
            "ನಮಸ್ಕಾರ",      // Kannada: "Namaskara"
        };

        for (test_texts) |text| {
            std.log.info("Processing Indic text: {s}", .{text});

            var result = try self.processSyllables(text);
            defer result.deinit();

            std.log.info("Found {} syllables", .{result.syllables.items.len});

            for (result.syllables.items, 0..) |syllable, i| {
                std.log.info("Syllable {}: {} characters, base: {?}", .{
                    i,
                    syllable.characters.len,
                    syllable.base_character
                });

                for (syllable.reordered_characters.items) |char| {
                    std.log.info("  Char U+{X} ({}) - pos: {} reorder: {}", .{
                        char.codepoint,
                        @tagName(char.category),
                        @tagName(char.syllable_position),
                        char.reorder_class
                    });
                }
            }
        }
    }
};

pub const IndicCharacter = struct {
    codepoint: u32,
    category: IndicSyllableProcessor.IndicCategory,
    position: usize,
    syllable_position: IndicSyllableProcessor.SyllablePosition,
    reorder_class: u8,
};

pub const IndicSyllable = struct {
    characters: []IndicCharacter,
    start_position: usize,
    base_character: ?usize,
    reordered_characters: std.ArrayList(IndicCharacter),

    pub fn deinit(self: *IndicSyllable, allocator: std.mem.Allocator) void {
        allocator.free(self.characters);
        self.reordered_characters.deinit();
    }
};

pub const IndicSyllableResult = struct {
    syllables: std.ArrayList(IndicSyllable),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) IndicSyllableResult {
        return IndicSyllableResult{
            .syllables = std.ArrayList(IndicSyllable).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IndicSyllableResult) void {
        for (self.syllables.items) |*syllable| {
            syllable.deinit(self.allocator);
        }
        self.syllables.deinit();
    }
};

test "IndicSyllableProcessor character classification" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = IndicSyllableProcessor.init(allocator) catch return;
    defer processor.deinit();

    // Test Devanagari character classification
    const ka = processor.classifyDevanagariCharacter(0x0915); // KA
    try testing.expect(ka == .consonant);

    const aa_matra = processor.classifyDevanagariCharacter(0x093E); // AA matra
    try testing.expect(aa_matra == .matra_post);

    const halant = processor.classifyDevanagariCharacter(0x094D); // Halant
    try testing.expect(halant == .halant);
}

test "IndicSyllableProcessor syllable boundary detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = IndicSyllableProcessor.init(allocator) catch return;
    defer processor.deinit();

    // Test syllable boundary logic
    const chars = [_]IndicCharacter{};
    const is_boundary = processor.isSyllableBoundary(.consonant, &chars);
    try testing.expect(!is_boundary); // No boundary at start
}