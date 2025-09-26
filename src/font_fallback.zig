const std = @import("std");
const root = @import("root.zig");

// Font fallback chain system for comprehensive character coverage
// Automatically selects appropriate fonts for different scripts and symbols
pub const FontFallbackChain = struct {
    allocator: std.mem.Allocator,
    primary_font: *root.FontManager,
    fallback_fonts: std.ArrayList(FallbackFont),
    script_preferences: std.HashMap(ScriptRange, []const FallbackFont, ScriptContext, std.hash_map.default_max_load_percentage),
    glyph_cache: std.HashMap(u32, CachedGlyph, GlyphContext, std.hash_map.default_max_load_percentage),

    const Self = @This();

    const FallbackFont = struct {
        font_manager: *root.FontManager,
        font_path: []const u8,
        priority: u8,
        scripts: []const ScriptRange,
        coverage: CharacterCoverage,

        pub fn init(allocator: std.mem.Allocator, path: []const u8, priority: u8) FallbackFont {
            return FallbackFont{
                .font_manager = undefined, // Will be set when loaded
                .font_path = path,
                .priority = priority,
                .scripts = &[_]ScriptRange{},
                .coverage = CharacterCoverage.init(allocator),
            };
        }

        pub fn deinit(self: *FallbackFont, allocator: std.mem.Allocator) void {
            self.coverage.deinit();
            allocator.free(self.font_path);
            for (self.scripts) |*script| {
                _ = script;
            }
        }
    };

    const ScriptRange = struct {
        start: u32,
        end: u32,
        script_name: []const u8,

        pub fn contains(self: ScriptRange, codepoint: u32) bool {
            return codepoint >= self.start and codepoint <= self.end;
        }
    };

    const CharacterCoverage = struct {
        unicode_blocks: std.ArrayList(UnicodeBlock),

        const UnicodeBlock = struct {
            start: u32,
            end: u32,
            coverage_bitmap: []u8, // Bit array for covered characters
        };

        pub fn init(allocator: std.mem.Allocator) CharacterCoverage {
            return CharacterCoverage{
                .unicode_blocks = std.ArrayList(UnicodeBlock).init(allocator),
            };
        }

        pub fn deinit(self: *CharacterCoverage) void {
            for (self.unicode_blocks.items) |*block| {
                self.unicode_blocks.allocator.free(block.coverage_bitmap);
            }
            self.unicode_blocks.deinit();
        }

        pub fn hasGlyph(self: *const CharacterCoverage, codepoint: u32) bool {
            for (self.unicode_blocks.items) |block| {
                if (codepoint >= block.start and codepoint <= block.end) {
                    const index = codepoint - block.start;
                    const byte_index = index / 8;
                    const bit_index: u3 = @intCast(index % 8);

                    if (byte_index < block.coverage_bitmap.len) {
                        return (block.coverage_bitmap[byte_index] & (@as(u8, 1) << bit_index)) != 0;
                    }
                }
            }
            return false;
        }
    };

    const CachedGlyph = struct {
        font_index: usize, // Index in fallback chain
        glyph_id: u32,
        last_used: i64,
    };

    const ScriptContext = struct {
        pub fn hash(self: @This(), range: ScriptRange) u64 {
            _ = self;
            return (@as(u64, range.start) << 32) | range.end;
        }

        pub fn eql(self: @This(), a: ScriptRange, b: ScriptRange) bool {
            _ = self;
            return a.start == b.start and a.end == b.end;
        }
    };

    const GlyphContext = struct {
        pub fn hash(self: @This(), codepoint: u32) u64 {
            _ = self;
            return codepoint;
        }

        pub fn eql(self: @This(), a: u32, b: u32) bool {
            _ = self;
            return a == b;
        }
    };

    pub fn init(allocator: std.mem.Allocator, primary_font: *root.FontManager) Self {
        return Self{
            .allocator = allocator,
            .primary_font = primary_font,
            .fallback_fonts = std.ArrayList(FallbackFont).init(allocator),
            .script_preferences = std.HashMap(ScriptRange, []const FallbackFont, ScriptContext, std.hash_map.default_max_load_percentage).init(allocator),
            .glyph_cache = std.HashMap(u32, CachedGlyph, GlyphContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.fallback_fonts.items) |*font| {
            font.deinit(self.allocator);
        }
        self.fallback_fonts.deinit();
        self.script_preferences.deinit();
        self.glyph_cache.deinit();
    }

    // Add system-wide fallback fonts
    pub fn loadSystemFallbacks(self: *Self) !void {
        const system_fonts = getSystemFallbackFonts();

        for (system_fonts) |font_info| {
            var fallback = FallbackFont.init(self.allocator, font_info.path, font_info.priority);
            fallback.scripts = font_info.scripts;

            // TODO: Load actual font and analyze coverage
            // For now, we'll use predefined coverage based on font type

            try self.fallback_fonts.append(fallback);
        }

        // Sort by priority (higher priority first)
        std.mem.sort(FallbackFont, self.fallback_fonts.items, {}, fallbackPriorityCompare);
    }

    fn fallbackPriorityCompare(context: void, a: FallbackFont, b: FallbackFont) bool {
        _ = context;
        return a.priority > b.priority;
    }

    // Find best font for a specific codepoint
    pub fn findFontForCodepoint(self: *Self, codepoint: u32) !*root.FontManager {
        // Check cache first
        if (self.glyph_cache.get(codepoint)) |cached| {
            cached.last_used = std.time.nanoTimestamp();
            if (cached.font_index == 0) {
                return self.primary_font;
            } else {
                return self.fallback_fonts.items[cached.font_index - 1].font_manager;
            }
        }

        // Try primary font first
        if (try self.primary_font.hasGlyph(codepoint)) {
            try self.glyph_cache.put(codepoint, CachedGlyph{
                .font_index = 0,
                .glyph_id = 0, // Will be filled when actually rendering
                .last_used = std.time.nanoTimestamp(),
            });
            return self.primary_font;
        }

        // Try fallback fonts in priority order
        for (self.fallback_fonts.items, 0..) |*font, i| {
            if (font.coverage.hasGlyph(codepoint)) {
                try self.glyph_cache.put(codepoint, CachedGlyph{
                    .font_index = i + 1,
                    .glyph_id = 0,
                    .last_used = std.time.nanoTimestamp(),
                });
                return font.font_manager;
            }
        }

        // If no fallback found, return primary font (will render .notdef)
        return self.primary_font;
    }

    // Find best font for text containing multiple scripts
    pub fn findFontsForText(self: *Self, text: []const u8, allocator: std.mem.Allocator) ![]FontRun {
        var runs = std.ArrayList(FontRun).init(allocator);
        var current_font: ?*root.FontManager = null;
        var run_start: usize = 0;
        var i: usize = 0;

        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + char_len <= text.len) {
                const codepoint = std.unicode.utf8Decode(text[i..i + char_len]) catch {
                    i += 1;
                    continue;
                };

                const best_font = try self.findFontForCodepoint(codepoint);

                if (current_font != best_font) {
                    // End current run if it exists
                    if (current_font != null) {
                        try runs.append(FontRun{
                            .font = current_font.?,
                            .start = run_start,
                            .length = i - run_start,
                        });
                    }

                    // Start new run
                    current_font = best_font;
                    run_start = i;
                }

                i += char_len;
            } else {
                break;
            }
        }

        // Add final run
        if (current_font != null and run_start < text.len) {
            try runs.append(FontRun{
                .font = current_font.?,
                .start = run_start,
                .length = text.len - run_start,
            });
        }

        return runs.toOwnedSlice();
    }

    pub const FontRun = struct {
        font: *root.FontManager,
        start: usize,
        length: usize,
    };

    // Preload common fallback characters
    pub fn preloadCommonFallbacks(self: *Self) !void {
        const common_fallback_chars = [_]u32{
            // Common symbols
            0x2022, // Bullet
            0x2013, // En dash
            0x2014, // Em dash
            0x201C, // Left double quotation mark
            0x201D, // Right double quotation mark
            0x2018, // Left single quotation mark
            0x2019, // Right single quotation mark

            // Mathematical symbols
            0x2260, // Not equal to
            0x2264, // Less than or equal to
            0x2265, // Greater than or equal to
            0x221E, // Infinity
            0x2192, // Right arrow
            0x2190, // Left arrow

            // Currency symbols
            0x20AC, // Euro sign
            0x00A3, // Pound sign
            0x00A5, // Yen sign

            // Diacritical marks
            0x00E9, // é
            0x00F1, // ñ
            0x00FC, // ü
            0x00E7, // ç
        };

        for (common_fallback_chars) |codepoint| {
            _ = try self.findFontForCodepoint(codepoint);
        }
    }

    // Clean old entries from glyph cache
    pub fn cleanupCache(self: *Self, max_age_ns: i64) void {
        const current_time = std.time.nanoTimestamp();
        var keys_to_remove = std.ArrayList(u32).init(self.allocator);
        defer keys_to_remove.deinit();

        var iter = self.glyph_cache.iterator();
        while (iter.next()) |entry| {
            if (current_time - entry.value_ptr.last_used > max_age_ns) {
                keys_to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (keys_to_remove.items) |key| {
            _ = self.glyph_cache.remove(key);
        }
    }
};

// System-specific font information
const SystemFontInfo = struct {
    path: []const u8,
    priority: u8,
    scripts: []const FontFallbackChain.ScriptRange,
};

fn getSystemFallbackFonts() []const SystemFontInfo {
    const builtin_os = @import("builtin").os.tag;

    return switch (builtin_os) {
        .linux => &linux_fallbacks,
        .macos => &macos_fallbacks,
        .windows => &windows_fallbacks,
        else => &generic_fallbacks,
    };
}

const latin_range = FontFallbackChain.ScriptRange{
    .start = 0x0000,
    .end = 0x017F,
    .script_name = "Latin",
};

const cyrillic_range = FontFallbackChain.ScriptRange{
    .start = 0x0400,
    .end = 0x04FF,
    .script_name = "Cyrillic",
};

const greek_range = FontFallbackChain.ScriptRange{
    .start = 0x0370,
    .end = 0x03FF,
    .script_name = "Greek",
};

const arabic_range = FontFallbackChain.ScriptRange{
    .start = 0x0600,
    .end = 0x06FF,
    .script_name = "Arabic",
};

const devanagari_range = FontFallbackChain.ScriptRange{
    .start = 0x0900,
    .end = 0x097F,
    .script_name = "Devanagari",
};

const cjk_range = FontFallbackChain.ScriptRange{
    .start = 0x4E00,
    .end = 0x9FFF,
    .script_name = "CJK Unified Ideographs",
};

const emoji_range = FontFallbackChain.ScriptRange{
    .start = 0x1F600,
    .end = 0x1F64F,
    .script_name = "Emoticons",
};

const linux_fallbacks = [_]SystemFontInfo{
    // High priority: Common system fonts
    .{
        .path = "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        .priority = 90,
        .scripts = &[_]FontFallbackChain.ScriptRange{ latin_range, cyrillic_range, greek_range },
    },
    .{
        .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        .priority = 85,
        .scripts = &[_]FontFallbackChain.ScriptRange{ latin_range, cyrillic_range, greek_range },
    },

    // Medium priority: Script-specific fonts
    .{
        .path = "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        .priority = 70,
        .scripts = &[_]FontFallbackChain.ScriptRange{arabic_range},
    },
    .{
        .path = "/usr/share/fonts/truetype/lohit-devanagari/Lohit-Devanagari.ttf",
        .priority = 70,
        .scripts = &[_]FontFallbackChain.ScriptRange{devanagari_range},
    },

    // Lower priority: Comprehensive coverage
    .{
        .path = "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
        .priority = 60,
        .scripts = &[_]FontFallbackChain.ScriptRange{cjk_range},
    },
    .{
        .path = "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
        .priority = 50,
        .scripts = &[_]FontFallbackChain.ScriptRange{emoji_range},
    },

    // Fallback of last resort
    .{
        .path = "/usr/share/fonts/truetype/unifont/unifont.ttf",
        .priority = 10,
        .scripts = &[_]FontFallbackChain.ScriptRange{}, // Covers everything
    },
};

const macos_fallbacks = [_]SystemFontInfo{
    .{
        .path = "/System/Library/Fonts/Helvetica.ttc",
        .priority = 90,
        .scripts = &[_]FontFallbackChain.ScriptRange{latin_range},
    },
    .{
        .path = "/System/Library/Fonts/Apple Color Emoji.ttc",
        .priority = 50,
        .scripts = &[_]FontFallbackChain.ScriptRange{emoji_range},
    },
};

const windows_fallbacks = [_]SystemFontInfo{
    .{
        .path = "C:\\Windows\\Fonts\\arial.ttf",
        .priority = 90,
        .scripts = &[_]FontFallbackChain.ScriptRange{latin_range},
    },
    .{
        .path = "C:\\Windows\\Fonts\\seguiemj.ttf",
        .priority = 50,
        .scripts = &[_]FontFallbackChain.ScriptRange{emoji_range},
    },
};

const generic_fallbacks = [_]SystemFontInfo{
    .{
        .path = "/usr/share/fonts/TTF/DejaVuSans.ttf",
        .priority = 80,
        .scripts = &[_]FontFallbackChain.ScriptRange{latin_range},
    },
};

// Smart fallback manager that learns from usage patterns
pub const SmartFallbackManager = struct {
    allocator: std.mem.Allocator,
    fallback_chain: FontFallbackChain,
    usage_stats: std.HashMap(u32, UsageStats, FontFallbackChain.GlyphContext, std.hash_map.default_max_load_percentage),

    const UsageStats = struct {
        count: u32,
        last_font_used: usize,
        success_rate: f32,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, primary_font: *root.FontManager) Self {
        return Self{
            .allocator = allocator,
            .fallback_chain = FontFallbackChain.init(allocator, primary_font),
            .usage_stats = std.HashMap(u32, UsageStats, FontFallbackChain.GlyphContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.fallback_chain.deinit();
        self.usage_stats.deinit();
    }

    pub fn recordUsage(self: *Self, codepoint: u32, font_index: usize, success: bool) !void {
        const result = try self.usage_stats.getOrPut(codepoint);

        if (!result.found_existing) {
            result.value_ptr.* = UsageStats{
                .count = 0,
                .last_font_used = font_index,
                .success_rate = 0.0,
            };
        }

        const stats = result.value_ptr;
        stats.count += 1;
        stats.last_font_used = font_index;

        // Update success rate using exponential moving average
        const alpha = 0.1;
        const current_success: f32 = if (success) 1.0 else 0.0;
        stats.success_rate = alpha * current_success + (1.0 - alpha) * stats.success_rate;
    }

    pub fn getRecommendedFont(self: *Self, codepoint: u32) !*root.FontManager {
        if (self.usage_stats.get(codepoint)) |stats| {
            // If we have good success rate with a particular font, use it
            if (stats.success_rate > 0.8) {
                if (stats.last_font_used == 0) {
                    return self.fallback_chain.primary_font;
                } else if (stats.last_font_used - 1 < self.fallback_chain.fallback_fonts.items.len) {
                    return self.fallback_chain.fallback_fonts.items[stats.last_font_used - 1].font_manager;
                }
            }
        }

        // Fall back to normal lookup
        return self.fallback_chain.findFontForCodepoint(codepoint);
    }

    pub fn optimizeFallbackOrder(self: *Self) void {
        // Reorder fallback fonts based on usage statistics
        // Fonts with higher success rates should be tried first
        // This is a simplified implementation
        _ = self;
    }
};

test "FontFallbackChain basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create mock font manager for testing
    var primary_font = root.FontManager.init(allocator);
    defer primary_font.deinit();

    var fallback_chain = FontFallbackChain.init(allocator, &primary_font);
    defer fallback_chain.deinit();

    try fallback_chain.loadSystemFallbacks();
    try testing.expect(fallback_chain.fallback_fonts.items.len > 0);
}

test "SmartFallbackManager learning" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var primary_font = root.FontManager.init(allocator);
    defer primary_font.deinit();

    var smart_manager = SmartFallbackManager.init(allocator, &primary_font);
    defer smart_manager.deinit();

    // Record some usage
    try smart_manager.recordUsage(0x2022, 1, true); // Bullet point, successful
    try smart_manager.recordUsage(0x2022, 1, true);
    try smart_manager.recordUsage(0x2022, 1, true);

    // Verify stats were recorded
    const stats = smart_manager.usage_stats.get(0x2022);
    try testing.expect(stats != null);
    try testing.expect(stats.?.count == 3);
}