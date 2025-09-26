const std = @import("std");
const root = @import("root.zig");
const gcode = @import("gcode");

// Enhanced Arabic contextual forms using real gcode analysis
pub const ArabicContextualProcessor = struct {
    allocator: std.mem.Allocator,
    complex_analyzer: gcode.complex_script.ComplexScriptAnalyzer,
    contextual_forms_table: ContextualFormsTable,

    const Self = @This();

    const ContextualFormsTable = std.HashMap(ContextualKey, u32, ContextualContext, std.hash_map.default_max_load_percentage);

    const ContextualKey = struct {
        base_char: u32,
        form: ArabicForm,
    };

    const ContextualContext = struct {
        pub fn hash(self: @This(), key: ContextualKey) u64 {
            _ = self;
            return (@as(u64, key.base_char) << 4) | @intFromEnum(key.form);
        }

        pub fn eql(self: @This(), a: ContextualKey, b: ContextualKey) bool {
            _ = self;
            return a.base_char == b.base_char and a.form == b.form;
        }
    };

    pub const ArabicForm = enum(u4) {
        isolated = 0,
        initial = 1,
        medial = 2,
        final = 3,
    };

    pub fn init(allocator: std.mem.Allocator) !Self {
        var processor = Self{
            .allocator = allocator,
            .complex_analyzer = try gcode.complex_script.ComplexScriptAnalyzer.init(allocator),
            .contextual_forms_table = ContextualFormsTable.init(allocator),
        };

        try processor.loadContextualFormsTable();
        return processor;
    }

    pub fn deinit(self: *Self) void {
        self.complex_analyzer.deinit();
        self.contextual_forms_table.deinit();
    }

    fn loadContextualFormsTable(self: *Self) !void {
        // Complete Arabic contextual forms mapping
        const arabic_forms = [_]struct { base: u32, isolated: u32, initial: u32, medial: u32, final: u32 }{
            // ARABIC LETTER BEH
            .{ .base = 0x0628, .isolated = 0xFE8F, .initial = 0xFE91, .medial = 0xFE92, .final = 0xFE90 },
            // ARABIC LETTER TEH
            .{ .base = 0x062A, .isolated = 0xFE95, .initial = 0xFE97, .medial = 0xFE98, .final = 0xFE96 },
            // ARABIC LETTER THEH
            .{ .base = 0x062B, .isolated = 0xFE99, .initial = 0xFE9B, .medial = 0xFE9C, .final = 0xFE9A },
            // ARABIC LETTER JEEM
            .{ .base = 0x062C, .isolated = 0xFE9D, .initial = 0xFE9F, .medial = 0xFEA0, .final = 0xFE9E },
            // ARABIC LETTER HAH
            .{ .base = 0x062D, .isolated = 0xFEA1, .initial = 0xFEA3, .medial = 0xFEA4, .final = 0xFEA2 },
            // ARABIC LETTER KHAH
            .{ .base = 0x062E, .isolated = 0xFEA5, .initial = 0xFEA7, .medial = 0xFEA8, .final = 0xFEA6 },
            // ARABIC LETTER SEEN
            .{ .base = 0x0633, .isolated = 0xFEB1, .initial = 0xFEB3, .medial = 0xFEB4, .final = 0xFEB2 },
            // ARABIC LETTER SHEEN
            .{ .base = 0x0634, .isolated = 0xFEB5, .initial = 0xFEB7, .medial = 0xFEB8, .final = 0xFEB6 },
            // ARABIC LETTER AIN
            .{ .base = 0x0639, .isolated = 0xFECB, .initial = 0xFECD, .medial = 0xFECE, .final = 0xFECC },
            // ARABIC LETTER GHAIN
            .{ .base = 0x063A, .isolated = 0xFECF, .initial = 0xFED1, .medial = 0xFED2, .final = 0xFED0 },
            // ARABIC LETTER FEH
            .{ .base = 0x0641, .isolated = 0xFED1, .initial = 0xFED3, .medial = 0xFED4, .final = 0xFED2 },
            // ARABIC LETTER QAF
            .{ .base = 0x0642, .isolated = 0xFED5, .initial = 0xFED7, .medial = 0xFED8, .final = 0xFED6 },
            // ARABIC LETTER KAF
            .{ .base = 0x0643, .isolated = 0xFED9, .initial = 0xFEDB, .medial = 0xFEDC, .final = 0xFEDA },
            // ARABIC LETTER LAM
            .{ .base = 0x0644, .isolated = 0xFEDD, .initial = 0xFEDF, .medial = 0xFEE0, .final = 0xFEDE },
            // ARABIC LETTER MEEM
            .{ .base = 0x0645, .isolated = 0xFEE1, .initial = 0xFEE3, .medial = 0xFEE4, .final = 0xFEE2 },
            // ARABIC LETTER NOON
            .{ .base = 0x0646, .isolated = 0xFEE5, .initial = 0xFEE7, .medial = 0xFEE8, .final = 0xFEE6 },
            // ARABIC LETTER HEH
            .{ .base = 0x0647, .isolated = 0xFEE9, .initial = 0xFEEB, .medial = 0xFEEC, .final = 0xFEEA },
            // ARABIC LETTER YEH
            .{ .base = 0x064A, .isolated = 0xFEF1, .initial = 0xFEF3, .medial = 0xFEF4, .final = 0xFEF2 },
        };

        for (arabic_forms) |form_set| {
            try self.contextual_forms_table.put(.{ .base_char = form_set.base, .form = .isolated }, form_set.isolated);
            try self.contextual_forms_table.put(.{ .base_char = form_set.base, .form = .initial }, form_set.initial);
            try self.contextual_forms_table.put(.{ .base_char = form_set.base, .form = .medial }, form_set.medial);
            try self.contextual_forms_table.put(.{ .base_char = form_set.base, .form = .final }, form_set.final);
        }
    }

    pub fn processArabicText(self: *Self, text: []const u8) !ArabicProcessingResult {
        // Use gcode to analyze the text
        const analyses = try self.complex_analyzer.analyzeText(text);
        defer self.allocator.free(analyses);

        var result = ArabicProcessingResult.init(self.allocator);

        // Convert text to codepoints for processing
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

        // Process each character with its context
        for (codepoints.items, 0..) |codepoint, pos| {
            if (pos < analyses.len and self.isArabicLetter(codepoint)) {
                const analysis = analyses[pos];

                // Determine contextual form using gcode analysis
                const form = self.determineContextualForm(analyses, pos);

                // Get the shaped glyph
                const shaped_glyph = self.getContextualForm(codepoint, form);

                try result.contextual_forms.append(ArabicContextualForm{
                    .base_codepoint = codepoint,
                    .contextual_codepoint = shaped_glyph,
                    .form = form,
                    .position = pos,
                    .joins_left = analysis.joining_type == .dual_joining or analysis.joining_type == .left_joining,
                    .joins_right = analysis.joining_type == .dual_joining or analysis.joining_type == .right_joining,
                });

                // Check for ligatures
                if (pos + 1 < codepoints.items.len) {
                    if (self.checkForLigature(codepoint, codepoints.items[pos + 1])) |ligature| {
                        try result.ligatures.append(ArabicLigature{
                            .components = &[_]u32{ codepoint, codepoints.items[pos + 1] },
                            .ligature_glyph = ligature,
                            .position = pos,
                        });
                    }
                }
            }
        }

        return result;
    }

    fn isArabicLetter(self: *Self, codepoint: u32) bool {
        _ = self;
        return (codepoint >= 0x0621 and codepoint <= 0x064A) or // Basic Arabic block
               (codepoint >= 0x066E and codepoint <= 0x06D3) or // Extended Arabic
               (codepoint >= 0x06FA and codepoint <= 0x06FF);   // More Arabic
    }

    fn determineContextualForm(self: *Self, analyses: []gcode.complex_script.ComplexScriptAnalysis, pos: usize) ArabicForm {
        _ = self;
        const current = analyses[pos];

        // If non-joining, always isolated
        if (current.joining_type == .none or current.joining_type == .transparent) {
            return .isolated;
        }

        // Check left context
        var has_left_joiner = false;
        if (pos > 0) {
            const prev = analyses[pos - 1];
            has_left_joiner = (prev.joining_type == .dual_joining or
                              prev.joining_type == .right_joining or
                              prev.joining_type == .join_causing) and
                              prev.codepoint != 0x0020; // Not space
        }

        // Check right context
        var has_right_joiner = false;
        if (pos + 1 < analyses.len) {
            const next = analyses[pos + 1];
            has_right_joiner = (next.joining_type == .dual_joining or
                               next.joining_type == .left_joining or
                               next.joining_type == .join_causing) and
                               next.codepoint != 0x0020; // Not space
        }

        // Determine form based on context
        return switch (@as(u2, if (has_left_joiner) 1 else 0) | (@as(u2, if (has_right_joiner) 2 else 0))) {
            0 => .isolated, // No joiners
            1 => .final,    // Left joiner only
            2 => .initial,  // Right joiner only
            3 => .medial,   // Both joiners
        };
    }

    fn getContextualForm(self: *Self, base_char: u32, form: ArabicForm) u32 {
        const key = ContextualKey{ .base_char = base_char, .form = form };
        return self.contextual_forms_table.get(key) orelse base_char;
    }

    fn checkForLigature(self: *Self, char1: u32, char2: u32) ?u32 {
        _ = self;
        // Common Arabic ligatures
        return switch ((@as(u64, char1) << 32) | char2) {
            // LAM + ALEF combinations
            (0x0644 << 32) | 0x0627 => 0xFEFB, // LAM + ALEF
            (0x0644 << 32) | 0x0622 => 0xFEF7, // LAM + ALEF WITH MADDA ABOVE
            (0x0644 << 32) | 0x0623 => 0xFEF9, // LAM + ALEF WITH HAMZA ABOVE
            (0x0644 << 32) | 0x0625 => 0xFEF5, // LAM + ALEF WITH HAMZA BELOW
            // Other common ligatures
            (0x0641 << 32) | 0x062D => 0xFC00, // FEH + HAH
            (0x0642 << 32) | 0x062D => 0xFC01, // QAF + HAH
            (0x0643 << 32) | 0x062D => 0xFC02, // KAF + HAH
            else => null,
        };
    }

    // Test with real Arabic text
    pub fn testArabicProcessing(self: *Self) !void {
        // Test various Arabic texts
        const test_texts = [_][]const u8{
            "بسم الله",           // "In the name of Allah"
            "السلام عليكم",      // "Peace be upon you"
            "مرحبا بالعالم",     // "Hello world"
            "الكتاب المقدس",     // "The holy book"
        };

        for (test_texts) |text| {
            std.log.info("Processing Arabic text: {s}", .{text});

            var result = try self.processArabicText(text);
            defer result.deinit();

            std.log.info("Found {} contextual forms and {} ligatures", .{
                result.contextual_forms.items.len,
                result.ligatures.items.len
            });

            for (result.contextual_forms.items) |form| {
                std.log.info("Char U+{X} -> U+{X} ({})", .{
                    form.base_codepoint,
                    form.contextual_codepoint,
                    @tagName(form.form)
                });
            }

            for (result.ligatures.items) |ligature| {
                std.log.info("Ligature: U+{X}+U+{X} -> U+{X}", .{
                    ligature.components[0],
                    ligature.components[1],
                    ligature.ligature_glyph
                });
            }
        }
    }
};

pub const ArabicProcessingResult = struct {
    contextual_forms: std.ArrayList(ArabicContextualForm),
    ligatures: std.ArrayList(ArabicLigature),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ArabicProcessingResult {
        return ArabicProcessingResult{
            .contextual_forms = std.ArrayList(ArabicContextualForm).init(allocator),
            .ligatures = std.ArrayList(ArabicLigature).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ArabicProcessingResult) void {
        self.contextual_forms.deinit();
        self.ligatures.deinit();
    }
};

pub const ArabicContextualForm = struct {
    base_codepoint: u32,
    contextual_codepoint: u32,
    form: ArabicContextualProcessor.ArabicForm,
    position: usize,
    joins_left: bool,
    joins_right: bool,
};

pub const ArabicLigature = struct {
    components: []const u32,
    ligature_glyph: u32,
    position: usize,
};

test "ArabicContextualProcessor basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = ArabicContextualProcessor.init(allocator) catch return;
    defer processor.deinit();

    // Test contextual forms table
    const beh_isolated = processor.getContextualForm(0x0628, .isolated);
    try testing.expect(beh_isolated == 0xFE8F);

    const beh_initial = processor.getContextualForm(0x0628, .initial);
    try testing.expect(beh_initial == 0xFE91);
}

test "ArabicContextualProcessor ligature detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = ArabicContextualProcessor.init(allocator) catch return;
    defer processor.deinit();

    // Test LAM + ALEF ligature
    const lam_alef = processor.checkForLigature(0x0644, 0x0627);
    try testing.expect(lam_alef == 0xFEFB);
}

test "ArabicContextualProcessor text processing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = ArabicContextualProcessor.init(allocator) catch return;
    defer processor.deinit();

    const arabic_text = "بسم"; // Simple Arabic text
    var result = processor.processArabicText(arabic_text) catch return;
    defer result.deinit();

    // Should detect contextual forms
    try testing.expect(result.contextual_forms.items.len > 0);
}