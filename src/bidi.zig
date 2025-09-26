const std = @import("std");
const root = @import("root.zig");

// Bidirectional text algorithm (Unicode BiDi Algorithm UAX#9)
// Handles mixed LTR/RTL text rendering for proper international support
pub const BiDiProcessor = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    // BiDi character types
    pub const BiDiType = enum(u8) {
        L = 0,   // Left-to-Right
        R = 1,   // Right-to-Left
        AL = 2,  // Right-to-Left Arabic
        EN = 3,  // European Number
        ES = 4,  // European Number Separator
        ET = 5,  // European Number Terminator
        AN = 6,  // Arabic Number
        CS = 7,  // Common Number Separator
        NSM = 8, // Nonspacing Mark
        BN = 9,  // Boundary Neutral
        B = 10,  // Paragraph Separator
        S = 11,  // Segment Separator
        WS = 12, // Whitespace
        ON = 13, // Other Neutrals
        LRE = 14, // Left-to-Right Embedding
        LRO = 15, // Left-to-Right Override
        RLE = 16, // Right-to-Left Embedding
        RLO = 17, // Right-to-Left Override
        PDF = 18, // Pop Directional Format
        LRI = 19, // Left-to-Right Isolate
        RLI = 20, // Right-to-Left Isolate
        FSI = 21, // First Strong Isolate
        PDI = 22, // Pop Directional Isolate
    };

    pub const Direction = enum(u8) {
        ltr = 0,
        rtl = 1,
        neutral = 2,
    };

    pub const BiDiChar = struct {
        codepoint: u32,
        bidi_type: BiDiType,
        level: u8,
        original_index: u32,
    };

    pub const BiDiRun = struct {
        start: usize,
        length: usize,
        level: u8,
        direction: Direction,
    };

    pub const BiDiResult = struct {
        chars: std.ArrayList(BiDiChar),
        runs: std.ArrayList(BiDiRun),
        base_direction: Direction,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) BiDiResult {
            return BiDiResult{
                .chars = std.ArrayList(BiDiChar).init(allocator),
                .runs = std.ArrayList(BiDiRun).init(allocator),
                .base_direction = .ltr,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *BiDiResult) void {
            self.chars.deinit();
            self.runs.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn processText(self: *Self, text: []const u8, base_direction: ?Direction) !BiDiResult {
        var result = BiDiResult.init(self.allocator);

        // Step 1: Parse text and determine BiDi types
        try self.parseText(text, &result);

        // Step 2: Determine paragraph direction
        result.base_direction = base_direction orelse self.determineParagraphDirection(&result);

        // Step 3: Apply BiDi algorithm
        try self.applyBiDiAlgorithm(&result);

        // Step 4: Create runs
        try self.createRuns(&result);

        return result;
    }

    fn parseText(self: *Self, text: []const u8, result: *BiDiResult) !void {
        _ = self;
        var i: usize = 0;
        var original_index: u32 = 0;

        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + char_len <= text.len) {
                const codepoint = std.unicode.utf8Decode(text[i..i + char_len]) catch {
                    i += 1;
                    original_index += 1;
                    continue;
                };

                const bidi_type = getBiDiType(codepoint);
                try result.chars.append(BiDiChar{
                    .codepoint = codepoint,
                    .bidi_type = bidi_type,
                    .level = 0, // Will be set later
                    .original_index = original_index,
                });

                i += char_len;
                original_index += 1;
            } else {
                break;
            }
        }
    }

    fn determineParagraphDirection(self: *Self, result: *BiDiResult) Direction {
        _ = self;
        // P2-P3: Find first strong character
        for (result.chars.items) |char| {
            switch (char.bidi_type) {
                .L => return .ltr,
                .R, .AL => return .rtl,
                else => continue,
            }
        }
        return .ltr; // Default to LTR
    }

    fn applyBiDiAlgorithm(self: *Self, result: *BiDiResult) !void {
        // Simplified BiDi algorithm implementation
        const base_level: u8 = if (result.base_direction == .rtl) 1 else 0;

        // Initialize levels
        for (result.chars.items) |*char| {
            char.level = base_level;
        }

        // Apply rules (simplified)
        try self.applyStrongTypes(result, base_level);
        try self.applyWeakTypes(result);
        try self.applyNeutralTypes(result);
    }

    fn applyStrongTypes(self: *Self, result: *BiDiResult, base_level: u8) !void {
        _ = self;
        var current_level = base_level;

        for (result.chars.items) |*char| {
            switch (char.bidi_type) {
                .L => {
                    current_level = if (base_level % 2 == 0) base_level else base_level + 1;
                    char.level = current_level;
                },
                .R, .AL => {
                    current_level = if (base_level % 2 == 0) base_level + 1 else base_level;
                    char.level = current_level;
                },
                else => {
                    char.level = current_level;
                },
            }
        }
    }

    fn applyWeakTypes(self: *Self, result: *BiDiResult) !void {
        _ = self;
        // W1-W7: Resolve weak types
        for (result.chars.items) |*char| {
            switch (char.bidi_type) {
                .EN => {
                    // European numbers follow the embedding direction
                    // Simplified: just use current level
                },
                .AN => {
                    // Arabic numbers are always RTL
                    char.level = if (char.level % 2 == 0) char.level + 1 else char.level;
                },
                else => {},
            }
        }
    }

    fn applyNeutralTypes(self: *Self, result: *BiDiResult) !void {
        _ = self;
        // N1-N2: Resolve neutral types
        for (result.chars.items) |*char| {
            switch (char.bidi_type) {
                .WS, .ON, .S => {
                    // Simplified: neutral characters take the level of surrounding text
                    // In a full implementation, this would be more complex
                },
                else => {},
            }
        }
    }

    fn createRuns(self: *Self, result: *BiDiResult) !void {
        _ = self;
        if (result.chars.items.len == 0) return;

        var current_level = result.chars.items[0].level;
        var run_start: usize = 0;

        for (result.chars.items, 0..) |char, i| {
            if (char.level != current_level) {
                // End current run and start new one
                try result.runs.append(BiDiRun{
                    .start = run_start,
                    .length = i - run_start,
                    .level = current_level,
                    .direction = if (current_level % 2 == 0) .ltr else .rtl,
                });

                run_start = i;
                current_level = char.level;
            }
        }

        // Add final run
        try result.runs.append(BiDiRun{
            .start = run_start,
            .length = result.chars.items.len - run_start,
            .level = current_level,
            .direction = if (current_level % 2 == 0) .ltr else .rtl,
        });
    }

    // Reorder characters for display
    pub fn reorderForDisplay(self: *Self, result: *BiDiResult) ![]BiDiChar {
        var display_order = std.ArrayList(BiDiChar).init(self.allocator);

        // Sort runs by level (higher levels first for proper nesting)
        const runs = try self.allocator.dupe(BiDiRun, result.runs.items);
        defer self.allocator.free(runs);

        std.mem.sort(BiDiRun, runs, {}, runLevelCompare);

        // Process each run
        for (runs) |run| {
            const run_chars = result.chars.items[run.start..run.start + run.length];

            if (run.direction == .rtl) {
                // Reverse RTL runs
                var i = run_chars.len;
                while (i > 0) {
                    i -= 1;
                    try display_order.append(run_chars[i]);
                }
            } else {
                // LTR runs stay in order
                for (run_chars) |char| {
                    try display_order.append(char);
                }
            }
        }

        return display_order.toOwnedSlice();
    }

    fn runLevelCompare(context: void, a: BiDiRun, b: BiDiRun) bool {
        _ = context;
        return a.level > b.level;
    }
};

// BiDi type lookup (simplified)
fn getBiDiType(codepoint: u32) BiDiProcessor.BiDiType {
    // ASCII Latin
    if ((codepoint >= 0x0041 and codepoint <= 0x005A) or // A-Z
        (codepoint >= 0x0061 and codepoint <= 0x007A))   // a-z
    {
        return .L;
    }

    // ASCII digits
    if (codepoint >= 0x0030 and codepoint <= 0x0039) {
        return .EN;
    }

    // Arabic
    if (codepoint >= 0x0600 and codepoint <= 0x06FF) {
        // Most Arabic characters are AL (Arabic Letter)
        if ((codepoint >= 0x0627 and codepoint <= 0x063A) or
            (codepoint >= 0x0641 and codepoint <= 0x064A))
        {
            return .AL;
        }
        // Arabic-Indic digits
        if (codepoint >= 0x0660 and codepoint <= 0x0669) {
            return .AN;
        }
        return .AL; // Default for Arabic block
    }

    // Hebrew
    if (codepoint >= 0x0590 and codepoint <= 0x05FF) {
        return .R;
    }

    // Whitespace
    if (codepoint == 0x0020 or codepoint == 0x0009 or codepoint == 0x000A or codepoint == 0x000D) {
        return .WS;
    }

    // Common punctuation
    if ((codepoint >= 0x0021 and codepoint <= 0x002F) or
        (codepoint >= 0x003A and codepoint <= 0x0040) or
        (codepoint >= 0x005B and codepoint <= 0x0060) or
        (codepoint >= 0x007B and codepoint <= 0x007E))
    {
        return .ON;
    }

    // Default to Left-to-Right for unknown characters
    return .L;
}

// BiDi text layout for rendering
pub const BiDiLayout = struct {
    allocator: std.mem.Allocator,
    processor: BiDiProcessor,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .processor = BiDiProcessor.init(allocator),
        };
    }

    pub fn layoutText(self: *Self, text: []const u8, base_direction: ?BiDiProcessor.Direction) !LayoutResult {
        var bidi_result = try self.processor.processText(text, base_direction);
        defer bidi_result.deinit();

        var layout = LayoutResult.init(self.allocator);

        // Convert BiDi runs to layout runs
        for (bidi_result.runs.items) |run| {
            const run_chars = bidi_result.chars.items[run.start..run.start + run.length];

            var layout_run = LayoutRun{
                .direction = run.direction,
                .chars = std.ArrayList(u32).init(self.allocator),
            };

            if (run.direction == .rtl) {
                // Reverse RTL text
                var i = run_chars.len;
                while (i > 0) {
                    i -= 1;
                    try layout_run.chars.append(run_chars[i].codepoint);
                }
            } else {
                // LTR text stays in order
                for (run_chars) |char| {
                    try layout_run.chars.append(char.codepoint);
                }
            }

            try layout.runs.append(layout_run);
        }

        return layout;
    }

    pub const LayoutResult = struct {
        runs: std.ArrayList(LayoutRun),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) LayoutResult {
            return LayoutResult{
                .runs = std.ArrayList(LayoutRun).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *LayoutResult) void {
            for (self.runs.items) |*run| {
                run.chars.deinit();
            }
            self.runs.deinit();
        }
    };

    pub const LayoutRun = struct {
        direction: BiDiProcessor.Direction,
        chars: std.ArrayList(u32),
    };
};

test "BiDi basic LTR text" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = BiDiProcessor.init(allocator);
    var result = try processor.processText("Hello World", null);
    defer result.deinit();

    try testing.expect(result.base_direction == .ltr);
    try testing.expect(result.chars.items.len == 11);
    try testing.expect(result.runs.items.len == 1);
    try testing.expect(result.runs.items[0].direction == .ltr);
}

test "BiDi mixed LTR/RTL text" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = BiDiProcessor.init(allocator);
    // "Hello مرحبا World" (mixed English and Arabic)
    var result = try processor.processText("Hello مرحبا World", null);
    defer result.deinit();

    try testing.expect(result.chars.items.len > 0);
    try testing.expect(result.runs.items.len >= 1);
}

test "BiDiLayout functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var layout = BiDiLayout.init(allocator);
    var result = try layout.layoutText("Hello World", .ltr);
    defer result.deinit();

    try testing.expect(result.runs.items.len >= 1);
}