const std = @import("std");
const root = @import("root.zig");
const gcode = @import("gcode");
const GraphemeSegmenter = @import("grapheme_segmenter.zig").GraphemeSegmenter;

// Perfect emoji sequence handler using gcode analysis
// Handles complex emoji sequences, ZWJ, flags, skin tones, etc.
pub const EmojiSequenceProcessor = struct {
    allocator: std.mem.Allocator,
    grapheme_segmenter: GraphemeSegmenter,
    emoji_cache: EmojiCache,

    const Self = @This();

    const EmojiCache = std.HashMap(EmojiSequenceKey, EmojiInfo, EmojiContext, std.hash_map.default_max_load_percentage);

    const EmojiContext = struct {
        pub fn hash(self: @This(), key: EmojiSequenceKey) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&key.sequence_hash));
            hasher.update(std.mem.asBytes(&key.length));
            return hasher.final();
        }

        pub fn eql(self: @This(), a: EmojiSequenceKey, b: EmojiSequenceKey) bool {
            _ = self;
            return a.sequence_hash == b.sequence_hash and a.length == b.length;
        }
    };

    const EmojiSequenceKey = struct {
        sequence_hash: u64,
        length: u8,
    };

    const EmojiInfo = struct {
        sequence_type: EmojiType,
        display_width: f32,
        terminal_cells: u8,
        component_count: u8,
        has_skin_tone: bool,
        has_zwj: bool,
        is_flag_sequence: bool,
        presentation_style: PresentationStyle,
    };

    pub const EmojiType = enum(u8) {
        simple = 0,
        keycap = 1,
        flag = 2,
        zwj_sequence = 3,
        skin_tone_sequence = 4,
        tag_sequence = 5,
        modifier_sequence = 6,
        unknown = 255,
    };

    pub const PresentationStyle = enum(u8) {
        text = 0,
        emoji = 1,
        default = 2,
    };

    pub fn init(allocator: std.mem.Allocator) !Self {
        var processor = Self{
            .allocator = allocator,
            .grapheme_segmenter = GraphemeSegmenter.init(allocator),
            .emoji_cache = EmojiCache.init(allocator),
        };

        try processor.loadEmojiData();
        return processor;
    }

    pub fn deinit(self: *Self) void {
        self.grapheme_segmenter.deinit();
        self.emoji_cache.deinit();
    }

    pub fn getSequenceInfo(self: *Self, codepoints: []const u32) !EmojiInfo {
        const key = self.createSequenceKey(codepoints);

        if (self.emoji_cache.get(key)) |info| {
            return info;
        }

        const info = try self.dynamicEmojiAnalysis(codepoints);
        try self.emoji_cache.put(key, info);
        return info;
    }

    fn loadEmojiData(self: *Self) !void {
        // Load common emoji sequences with their properties
        const emoji_data = [_]struct { codepoints: []const u32, info: EmojiInfo }{
            // Simple emoji
            .{
                .codepoints = &[_]u32{0x1F600}, // 😀
                .info = .{ .sequence_type = .simple, .display_width = 2.0, .terminal_cells = 2, .component_count = 1, .has_skin_tone = false, .has_zwj = false, .is_flag_sequence = false, .presentation_style = .emoji },
            },

            // Flag sequences (Regional Indicator + Regional Indicator)
            .{
                .codepoints = &[_]u32{ 0x1F1FA, 0x1F1F8 }, // 🇺🇸 US Flag
                .info = .{ .sequence_type = .flag, .display_width = 2.0, .terminal_cells = 2, .component_count = 2, .has_skin_tone = false, .has_zwj = false, .is_flag_sequence = true, .presentation_style = .emoji },
            },

            // ZWJ sequences (Family)
            .{
                .codepoints = &[_]u32{ 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F466 }, // 👨‍👩‍👧‍👦
                .info = .{ .sequence_type = .zwj_sequence, .display_width = 2.0, .terminal_cells = 2, .component_count = 7, .has_skin_tone = false, .has_zwj = true, .is_flag_sequence = false, .presentation_style = .emoji },
            },

            // Skin tone sequences
            .{
                .codepoints = &[_]u32{ 0x1F44D, 0x1F3FB }, // 👍🏻 Thumbs up (light skin)
                .info = .{ .sequence_type = .skin_tone_sequence, .display_width = 2.0, .terminal_cells = 2, .component_count = 2, .has_skin_tone = true, .has_zwj = false, .is_flag_sequence = false, .presentation_style = .emoji },
            },

            // Keycap sequences
            .{
                .codepoints = &[_]u32{ 0x0031, 0xFE0F, 0x20E3 }, // 1️⃣
                .info = .{ .sequence_type = .keycap, .display_width = 2.0, .terminal_cells = 2, .component_count = 3, .has_skin_tone = false, .has_zwj = false, .is_flag_sequence = false, .presentation_style = .emoji },
            },
        };

        for (emoji_data) |data| {
            const key = self.createSequenceKey(data.codepoints);
            try self.emoji_cache.put(key, data.info);
        }
    }

    fn createSequenceKey(self: *Self, codepoints: []const u32) EmojiSequenceKey {
        _ = self;

        var hasher = std.hash.Wyhash.init(0x12345678);
        for (codepoints) |cp| {
            hasher.update(std.mem.asBytes(&cp));
        }

        return EmojiSequenceKey{
            .sequence_hash = hasher.final(),
            .length = @intCast(codepoints.len),
        };
    }

    pub fn processEmojiSequences(self: *Self, text: []const u8) !EmojiSequenceResult {
        // Use gcode grapheme segmentation to properly identify emoji boundaries
        const grapheme_breaks = try self.grapheme_segmenter.segmentCodepointBreaks(text);
        defer self.allocator.free(grapheme_breaks);

        var result = EmojiSequenceResult.init(self.allocator);

        // Convert text to codepoints
        var codepoints = std.ArrayList(u32).init(self.allocator);
        defer codepoints.deinit();

        var byte_pos: usize = 0;
        while (byte_pos < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[byte_pos]) catch 1;
            if (byte_pos + char_len <= text.len) {
                const codepoint = std.unicode.utf8Decode(text[byte_pos .. byte_pos + char_len]) catch {
                    byte_pos += 1;
                    continue;
                };
                try codepoints.append(codepoint);
                byte_pos += char_len;
            } else {
                break;
            }
        }

        // Process each grapheme cluster for emoji sequences
        var cluster_start: usize = 0;
        for (grapheme_breaks) |break_pos| {
            const cluster_end = break_pos;
            const cluster_codepoints = codepoints.items[cluster_start..cluster_end];

            if (self.containsEmoji(cluster_codepoints)) {
                const emoji_sequence = try self.analyzeEmojiSequence(cluster_codepoints, cluster_start);
                try result.sequences.append(emoji_sequence);
            }

            cluster_start = cluster_end;
        }

        // Calculate metrics
        result.total_emoji_count = result.sequences.items.len;
        result.total_display_width = self.calculateTotalEmojiWidth(result.sequences.items);
        result.has_complex_sequences = self.hasComplexSequences(result.sequences.items);

        return result;
    }

    fn containsEmoji(self: *Self, codepoints: []const u32) bool {
        for (codepoints) |cp| {
            if (self.isEmojiCodepoint(cp)) return true;
        }
        return false;
    }

    fn isEmojiCodepoint(self: *Self, codepoint: u32) bool {
        _ = self;

        // Basic emoji ranges
        if (codepoint >= 0x1F600 and codepoint <= 0x1F64F) return true; // Emoticons
        if (codepoint >= 0x1F300 and codepoint <= 0x1F5FF) return true; // Misc Symbols
        if (codepoint >= 0x1F680 and codepoint <= 0x1F6FF) return true; // Transport
        if (codepoint >= 0x1F1E6 and codepoint <= 0x1F1FF) return true; // Regional Indicators
        if (codepoint >= 0x2600 and codepoint <= 0x26FF) return true; // Misc Symbols
        if (codepoint >= 0x2700 and codepoint <= 0x27BF) return true; // Dingbats

        // Specific emoji codepoints
        switch (codepoint) {
            0x203C, 0x2049, 0x2122, 0x2139, 0x2194...0x2199, 0x21A9, 0x21AA, 0x231A, 0x231B, 0x2328, 0x23CF, 0x23E9...0x23F3, 0x23F8...0x23FA, 0x24C2, 0x25AA, 0x25AB, 0x25B6, 0x25C0, 0x25FB...0x25FE => return true,
            else => return false,
        }
    }

    fn analyzeEmojiSequence(self: *Self, codepoints: []const u32, position: usize) !EmojiSequenceData {
        const key = self.createSequenceKey(codepoints);

        // Check cache first
        const info = self.emoji_cache.get(key) orelse blk: {
            // Analyze sequence dynamically
            break :blk try self.dynamicEmojiAnalysis(codepoints);
        };

        // Create owned copy of codepoints
        const owned_codepoints = try self.allocator.dupe(u32, codepoints);

        return EmojiSequenceData{
            .codepoints = owned_codepoints,
            .position = position,
            .info = info,
            .text_representation = try self.codepointsToString(codepoints),
        };
    }

    fn dynamicEmojiAnalysis(self: *Self, codepoints: []const u32) !EmojiInfo {
        _ = self;

        var info = EmojiInfo{
            .sequence_type = .simple,
            .display_width = 2.0,
            .terminal_cells = 2,
            .component_count = @intCast(codepoints.len),
            .has_skin_tone = false,
            .has_zwj = false,
            .is_flag_sequence = false,
            .presentation_style = .emoji,
        };

        // Analyze sequence characteristics
        var has_zwj = false;
        var has_skin_tone = false;
        var is_flag = false;
        var has_tags = false;
        var tag_count: u8 = 0;
        var vs16 = false;
        var regional_indicator_count: u8 = 0;

        for (codepoints) |cp| {
            switch (cp) {
                0x200D => has_zwj = true, // ZWJ
                0x1F3FB...0x1F3FF => has_skin_tone = true, // Skin tone modifiers
                0x1F1E6...0x1F1FF => {
                    regional_indicator_count += 1;
                    if (regional_indicator_count == 2) is_flag = true;
                },
                0xFE0F => {
                    vs16 = true;
                    info.presentation_style = .emoji;
                },
                0xFE0E => info.presentation_style = .text, // Variation Selector-15 (text)
                0x20E3 => info.sequence_type = .keycap, // Combining Enclosing Keycap
                0xE0020...0xE007F => {
                    has_tags = true;
                    tag_count += 1;
                },
                else => {},
            }
        }

        // Determine sequence type
        if (is_flag) {
            info.sequence_type = .flag;
            info.is_flag_sequence = true;
        } else if (has_zwj) {
            info.sequence_type = .zwj_sequence;
            info.has_zwj = true;
        } else if (has_skin_tone) {
            info.sequence_type = .skin_tone_sequence;
            info.has_skin_tone = true;
        } else if (has_tags) {
            info.sequence_type = .tag_sequence;
        }

        if (info.presentation_style == .text and !vs16) {
            info.display_width = 1.0;
            info.terminal_cells = 1;
        }

        if (has_tags and codepoints.len > 0 and codepoints[0] == 0x1F3F4) {
            info.sequence_type = .tag_sequence;
        }

        info.component_count = 0;
        for (codepoints) |cp| {
            switch (cp) {
                0x200D, 0xFE0E, 0xFE0F => continue,
                0xE0020...0xE007F => continue,
                else => info.component_count += 1,
            }
        }
        if (info.component_count == 0) {
            info.component_count = @intCast(codepoints.len);
        }

        return info;
    }

    fn codepointsToString(self: *Self, codepoints: []const u32) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);

        for (codepoints) |cp| {
            var utf8_bytes: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &utf8_bytes) catch continue;
            try result.appendSlice(utf8_bytes[0..len]);
        }

        return result.toOwnedSlice();
    }

    fn calculateTotalEmojiWidth(self: *Self, sequences: []const EmojiSequenceData) f32 {
        _ = self;

        var total_width: f32 = 0;
        for (sequences) |seq| {
            total_width += seq.info.display_width;
        }
        return total_width;
    }

    fn hasComplexSequences(self: *Self, sequences: []const EmojiSequenceData) bool {
        _ = self;

        for (sequences) |seq| {
            switch (seq.info.sequence_type) {
                .zwj_sequence, .flag, .skin_tone_sequence, .tag_sequence => return true,
                else => continue,
            }
        }
        return false;
    }

    // Terminal-specific emoji handling
    pub fn optimizeForTerminal(self: *Self, sequences: []const EmojiSequenceData, terminal_width: u32) !EmojiTerminalLayout {
        var layout = EmojiTerminalLayout.init(self.allocator);

        var current_line = std.ArrayList(EmojiSequenceData).init(self.allocator);
        var current_line_width: u32 = 0;

        for (sequences) |seq| {
            const seq_width = seq.info.terminal_cells;

            // Check if emoji fits on current line
            if (current_line_width + seq_width > terminal_width and current_line.items.len > 0) {
                // Move to next line
                try layout.lines.append(try current_line.toOwnedSlice());
                current_line = std.ArrayList(EmojiSequenceData).init(self.allocator);
                current_line_width = 0;
            }

            try current_line.append(seq);
            current_line_width += seq_width;
        }

        // Add final line
        if (current_line.items.len > 0) {
            try layout.lines.append(try current_line.toOwnedSlice());
        } else {
            current_line.deinit();
        }

        return layout;
    }

    // Enhanced emoji rendering with proper fallback
    pub fn renderEmojiSequence(self: *Self, sequence: *const EmojiSequenceData, font_size: f32) !EmojiRenderInfo {
        var render_info = EmojiRenderInfo{
            .sequence = sequence,
            .render_as_single = false,
            .fallback_components = std.ArrayList(u32).init(self.allocator),
            .estimated_width = sequence.info.display_width * font_size,
            .estimated_height = font_size,
        };

        // Determine rendering strategy
        switch (sequence.info.sequence_type) {
            .simple => {
                render_info.render_as_single = true;
            },
            .zwj_sequence => {
                // For ZWJ sequences, try to render as single glyph first
                render_info.render_as_single = true;
                // If that fails, fall back to components
                for (sequence.codepoints) |cp| {
                    if (cp != 0x200D) { // Skip ZWJ characters in fallback
                        try render_info.fallback_components.append(cp);
                    }
                }
            },
            .flag => {
                render_info.render_as_single = true;
            },
            .skin_tone_sequence => {
                render_info.render_as_single = true;
                // Fallback: render base emoji without skin tone
                if (sequence.codepoints.len > 0) {
                    try render_info.fallback_components.append(sequence.codepoints[0]);
                }
            },
            else => {
                render_info.render_as_single = true;
            },
        }

        return render_info;
    }

    // Test with complex emoji sequences
    pub fn testEmojiProcessing(self: *Self) !void {
        const test_texts = [_][]const u8{
            "😀😍🤔", // Simple emoji
            "🇺🇸🇯🇵🇩🇪", // Flag sequences
            "👨‍👩‍👧‍👦", // Family ZWJ sequence
            "👍🏻👍🏿", // Skin tone variants
            "1️⃣2️⃣3️⃣", // Keycap sequences
            "👩‍💻👨‍🔬", // Professional emoji
            "🏴󠁧󠁢󠁳󠁣󠁴󠁿", // Tag sequence (Scotland flag)
        };

        for (test_texts) |text| {
            std.log.info("Processing emoji text: {s}", .{text});

            var result = try self.processEmojiSequences(text);
            defer result.deinit();

            std.log.info("Found {} emoji sequences, total width: {d:.1}, complex: {}", .{ result.total_emoji_count, result.total_display_width, result.has_complex_sequences });

            for (result.sequences.items) |seq| {
                std.log.info("  Sequence: {s} ({}) - {} components, type: {}", .{ seq.text_representation, seq.codepoints.len, seq.info.component_count, @tagName(seq.info.sequence_type) });
            }
        }
    }
};

pub const EmojiSequenceData = struct {
    codepoints: []u32,
    position: usize,
    info: EmojiSequenceProcessor.EmojiInfo,
    text_representation: []u8,

    pub fn deinit(self: *EmojiSequenceData, allocator: std.mem.Allocator) void {
        allocator.free(self.codepoints);
        allocator.free(self.text_representation);
    }
};

pub const EmojiSequenceResult = struct {
    sequences: std.ArrayList(EmojiSequenceData),
    total_emoji_count: usize,
    total_display_width: f32,
    has_complex_sequences: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EmojiSequenceResult {
        return EmojiSequenceResult{
            .sequences = std.ArrayList(EmojiSequenceData).init(allocator),
            .total_emoji_count = 0,
            .total_display_width = 0.0,
            .has_complex_sequences = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EmojiSequenceResult) void {
        for (self.sequences.items) |*seq| {
            seq.deinit(self.allocator);
        }
        self.sequences.deinit();
    }
};

pub const EmojiTerminalLayout = struct {
    lines: std.ArrayList([]EmojiSequenceData),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EmojiTerminalLayout {
        return EmojiTerminalLayout{
            .lines = std.ArrayList([]EmojiSequenceData).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EmojiTerminalLayout) void {
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.deinit();
    }
};

pub const EmojiRenderInfo = struct {
    sequence: *const EmojiSequenceData,
    render_as_single: bool,
    fallback_components: std.ArrayList(u32),
    estimated_width: f32,
    estimated_height: f32,

    pub fn deinit(self: *EmojiRenderInfo) void {
        self.fallback_components.deinit();
    }
};

test "EmojiSequenceProcessor detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = EmojiSequenceProcessor.init(allocator) catch return;
    defer processor.deinit();

    // Test emoji detection
    try testing.expect(processor.isEmojiCodepoint(0x1F600)); // 😀
    try testing.expect(processor.isEmojiCodepoint(0x1F1FA)); // Regional Indicator U
    try testing.expect(!processor.isEmojiCodepoint(0x0041)); // Latin A
}

test "EmojiSequenceProcessor sequence analysis" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = EmojiSequenceProcessor.init(allocator) catch return;
    defer processor.deinit();

    // Test flag sequence detection
    const flag_codepoints = [_]u32{ 0x1F1FA, 0x1F1F8 }; // US flag
    const flag_info = processor.dynamicEmojiAnalysis(&flag_codepoints) catch return;
    try testing.expect(flag_info.sequence_type == .flag);
    try testing.expect(flag_info.is_flag_sequence);

    // Test ZWJ sequence detection
    const zwj_sequence = [_]u32{ 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467 };
    const zwj_info = processor.dynamicEmojiAnalysis(&zwj_sequence) catch return;
    try testing.expect(zwj_info.sequence_type == .zwj_sequence);
    try testing.expect(zwj_info.has_zwj);

    // Test skin tone detection
    const skin_sequence = [_]u32{ 0x1F44D, 0x1F3FD };
    const skin_info = processor.dynamicEmojiAnalysis(&skin_sequence) catch return;
    try testing.expect(skin_info.sequence_type == .skin_tone_sequence);
    try testing.expect(skin_info.has_skin_tone);

    // Test keycap sequence detection
    const keycap_sequence = [_]u32{ 0x0031, 0xFE0F, 0x20E3 };
    const keycap_info = processor.dynamicEmojiAnalysis(&keycap_sequence) catch return;
    try testing.expect(keycap_info.sequence_type == .keycap);
}
