const std = @import("std");
const root = @import("root.zig");
const Font = @import("font.zig").Font;
const FontManager = @import("font_manager.zig").FontManager;
const TextShaper = @import("text_shaper.zig").TextShaper;

pub const ProgrammingFontManager = struct {
    allocator: std.mem.Allocator,
    ligature_map: std.StringHashMap(LigatureInfo),
    nerd_font_map: std.AutoHashMap(u32, NerdFontIcon),
    programming_fonts: std.ArrayList(*Font),

    const Self = @This();

    const LigatureInfo = struct {
        replacement_glyph: u32,
        sequence_length: u8,
        font_specific: bool,
    };

    const NerdFontIcon = struct {
        codepoint: u32,
        name: []const u8,
        category: IconCategory,
    };

    const IconCategory = enum {
        file_type,
        folder,
        git,
        device,
        ui,
        weather,
        logo,
        misc,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        var manager = Self{
            .allocator = allocator,
            .ligature_map = std.StringHashMap(LigatureInfo).init(allocator),
            .nerd_font_map = std.AutoHashMap(u32, NerdFontIcon).init(allocator),
            .programming_fonts = std.ArrayList(*Font){},
        };

        manager.initializeLigatures() catch {};
        manager.initializeNerdFontIcons() catch {};
        return manager;
    }

    pub fn deinit(self: *Self) void {
        self.ligature_map.deinit();
        self.nerd_font_map.deinit();
        self.programming_fonts.deinit(self.allocator);
    }

    fn initializeLigatures(self: *Self) !void {
        // Common programming ligatures
        const ligatures = [_]struct { sequence: []const u8, glyph: u32 }{
            .{ .sequence = "==", .glyph = 0xE000 },
            .{ .sequence = "!=", .glyph = 0xE001 },
            .{ .sequence = "<=", .glyph = 0xE002 },
            .{ .sequence = ">=", .glyph = 0xE003 },
            .{ .sequence = "->", .glyph = 0xE004 },
            .{ .sequence = "=>", .glyph = 0xE005 },
            .{ .sequence = "<-", .glyph = 0xE006 },
            .{ .sequence = "<<", .glyph = 0xE007 },
            .{ .sequence = ">>", .glyph = 0xE008 },
            .{ .sequence = "||", .glyph = 0xE009 },
            .{ .sequence = "&&", .glyph = 0xE00A },
            .{ .sequence = "++", .glyph = 0xE00B },
            .{ .sequence = "--", .glyph = 0xE00C },
            .{ .sequence = "::", .glyph = 0xE00D },
            .{ .sequence = "!!", .glyph = 0xE00E },
            .{ .sequence = "??", .glyph = 0xE00F },
            .{ .sequence = "***", .glyph = 0xE010 },
            .{ .sequence = "<!--", .glyph = 0xE011 },
            .{ .sequence = "-->", .glyph = 0xE012 },
            .{ .sequence = "<==", .glyph = 0xE013 },
            .{ .sequence = "==>", .glyph = 0xE014 },
            .{ .sequence = "<=>", .glyph = 0xE015 },
            .{ .sequence = "<->", .glyph = 0xE016 },
            .{ .sequence = "<==>", .glyph = 0xE017 },
            .{ .sequence = "<-->", .glyph = 0xE018 },
            .{ .sequence = "===", .glyph = 0xE019 },
            .{ .sequence = "!==", .glyph = 0xE01A },
        };

        for (ligatures) |lig| {
            try self.ligature_map.put(lig.sequence, LigatureInfo{
                .replacement_glyph = lig.glyph,
                .sequence_length = @as(u8, @intCast(lig.sequence.len)),
                .font_specific = false,
            });
        }
    }

    fn initializeNerdFontIcons(self: *Self) !void {
        // Common Nerd Font icons
        const icons = [_]struct { codepoint: u32, name: []const u8, category: IconCategory }{
            // File types
            .{ .codepoint = 0xF1C1, .name = "file-code", .category = .file_type },
            .{ .codepoint = 0xF1C2, .name = "file-text", .category = .file_type },
            .{ .codepoint = 0xF1C3, .name = "file-image", .category = .file_type },
            .{ .codepoint = 0xF1C4, .name = "file-video", .category = .file_type },
            .{ .codepoint = 0xF1C5, .name = "file-audio", .category = .file_type },

            // Folders
            .{ .codepoint = 0xF07B, .name = "folder", .category = .folder },
            .{ .codepoint = 0xF07C, .name = "folder-open", .category = .folder },

            // Git
            .{ .codepoint = 0xF1D3, .name = "git-branch", .category = .git },
            .{ .codepoint = 0xF1D2, .name = "git-commit", .category = .git },
            .{ .codepoint = 0xF1D1, .name = "git-merge", .category = .git },

            // Programming languages
            .{ .codepoint = 0xE74E, .name = "rust", .category = .logo },
            .{ .codepoint = 0xE781, .name = "python", .category = .logo },
            .{ .codepoint = 0xE74F, .name = "javascript", .category = .logo },
            .{ .codepoint = 0xE750, .name = "typescript", .category = .logo },
            .{ .codepoint = 0xE751, .name = "go", .category = .logo },
            .{ .codepoint = 0xE752, .name = "c", .category = .logo },
            .{ .codepoint = 0xE753, .name = "cpp", .category = .logo },
            .{ .codepoint = 0xE754, .name = "java", .category = .logo },

            // UI elements
            .{ .codepoint = 0xF068, .name = "minus", .category = .ui },
            .{ .codepoint = 0xF067, .name = "plus", .category = .ui },
            .{ .codepoint = 0xF00C, .name = "check", .category = .ui },
            .{ .codepoint = 0xF00D, .name = "times", .category = .ui },
        };

        for (icons) |icon| {
            try self.nerd_font_map.put(icon.codepoint, NerdFontIcon{
                .codepoint = icon.codepoint,
                .name = icon.name,
                .category = icon.category,
            });
        }
    }

    pub fn loadProgrammingFonts(self: *Self, font_manager: *FontManager) !void {
        const programming_font_names = [_][]const u8{
            "Fira Code",
            "JetBrains Mono",
            "Source Code Pro",
            "Cascadia Code",
            "Hack",
            "Inconsolata",
            "Victor Mono",
            "Ubuntu Mono",
            "Roboto Mono",
            "SF Mono",
            "Menlo",
            "Monaco",
            "Consolas",
            "DejaVu Sans Mono",
            "Liberation Mono",
        };

        for (programming_font_names) |font_name| {
            if (try font_manager.findFont(font_name, .{ .size = 12.0 })) |font| {
                try self.programming_fonts.append(font);
            }
        }
    }

    pub fn processLigatures(self: *Self, text: []const u8, font: *Font, options: LigatureOptions) !LigatureResult {
        var result = LigatureResult.init(self.allocator);

        var i: usize = 0;
        while (i < text.len) {
            var found_ligature = false;

            // Try to find the longest matching ligature
            var max_length: usize = 0;
            var best_ligature: ?LigatureInfo = null;

            var lig_iterator = self.ligature_map.iterator();
            while (lig_iterator.next()) |entry| {
                const sequence = entry.key_ptr.*;
                const lig_info = entry.value_ptr.*;

                if (i + sequence.len <= text.len and
                    std.mem.eql(u8, text[i..i + sequence.len], sequence) and
                    sequence.len > max_length) {

                    // Check if font supports this ligature
                    if (self.fontSupportsLigature(font, lig_info)) {
                        max_length = sequence.len;
                        best_ligature = lig_info;
                    }
                }
            }

            if (best_ligature) |lig_info| {
                if (options.enable_ligatures) {
                    try result.ligatures.append(LigatureMatch{
                        .position = i,
                        .length = max_length,
                        .replacement_glyph = lig_info.replacement_glyph,
                    });
                    found_ligature = true;
                    i += max_length;
                } else {
                    i += 1;
                }
            } else {
                i += 1;
            }

            if (!found_ligature) {
                // No ligature found, process as regular character
                const char = text[i - 1];
                try result.characters.append(char);
            }
        }

        return result;
    }

    fn fontSupportsLigature(self: *Self, font: *Font, ligature: LigatureInfo) bool {
        _ = self;

        // Check if font has the ligature glyph
        const glyph_index = font.parser.getGlyphIndex(ligature.replacement_glyph) catch return false;
        return glyph_index != 0;
    }

    pub fn getNerdFontIcon(self: *Self, name: []const u8) ?NerdFontIcon {
        var iterator = self.nerd_font_map.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.name, name)) {
                return entry.value_ptr.*;
            }
        }
        return null;
    }

    pub fn getNerdFontIconByCodepoint(self: *Self, codepoint: u32) ?NerdFontIcon {
        return self.nerd_font_map.get(codepoint);
    }

    pub fn getIconsInCategory(self: *Self, category: IconCategory) ![]NerdFontIcon {
        var icons = std.ArrayList(NerdFontIcon).init(self.allocator);

        var iterator = self.nerd_font_map.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.category == category) {
                try icons.append(entry.value_ptr.*);
            }
        }

        return icons.toOwnedSlice();
    }

    pub fn isMonospaceFont(self: *Self, font: *Font) bool {
        _ = self;

        // Check if font is monospace by comparing advance widths
        const char_a = font.getAdvanceWidth('A', 12.0) catch return false;
        const char_i = font.getAdvanceWidth('i', 12.0) catch return false;
        const char_w = font.getAdvanceWidth('W', 12.0) catch return false;

        const tolerance = 0.1;
        return @abs(char_a - char_i) < tolerance and @abs(char_a - char_w) < tolerance;
    }

    pub fn optimizeForTerminal(self: *Self, font: *Font, options: TerminalOptions) !TerminalOptimization {
        var optimization = TerminalOptimization{
            .line_height_adjustment = 0,
            .character_spacing = 0,
            .enable_hinting = true,
            .enable_subpixel = options.enable_subpixel,
        };

        // Adjust line height for better terminal display
        const line_height = font.getLineHeight(options.font_size);
        const optimal_height = options.font_size * 1.2; // 120% of font size
        optimization.line_height_adjustment = optimal_height - line_height;

        // Ensure character spacing is optimal for monospace
        if (self.isMonospaceFont(font)) {
            optimization.character_spacing = 0; // No adjustment needed
        } else {
            optimization.character_spacing = 1.0; // Add slight spacing
        }

        return optimization;
    }

    pub fn detectFontFeatures(self: *Self, font: *Font) FontFeatures {
        var features = FontFeatures{
            .has_ligatures = false,
            .has_nerd_font_icons = false,
            .is_monospace = false,
            .has_powerline_symbols = false,
            .programming_optimized = false,
        };

        features.is_monospace = self.isMonospaceFont(font);

        // Check for common ligature glyphs
        features.has_ligatures = self.checkForLigatures(font);

        // Check for Nerd Font icons
        features.has_nerd_font_icons = self.checkForNerdFontIcons(font);

        // Check for Powerline symbols
        features.has_powerline_symbols = self.checkForPowerlineSymbols(font);

        // Determine if it's programming optimized
        features.programming_optimized = features.is_monospace and
            (features.has_ligatures or features.has_nerd_font_icons);

        return features;
    }

    fn checkForLigatures(self: *Self, font: *Font) bool {
        // Check for a few common ligature glyphs
        const test_glyphs = [_]u32{ 0xE000, 0xE001, 0xE002 }; // ==, !=, <=

        for (test_glyphs) |glyph| {
            const glyph_index = font.parser.getGlyphIndex(glyph) catch continue;
            if (glyph_index != 0) {
                return true;
            }
        }

        _ = self;
        return false;
    }

    fn checkForNerdFontIcons(self: *Self, font: *Font) bool {
        // Check for Nerd Font private use area
        const nerd_font_ranges = [_]struct { start: u32, end: u32 }{
            .{ .start = 0xE000, .end = 0xF8FF }, // Private Use Area
            .{ .start = 0xF0000, .end = 0xFFFFF }, // Supplementary Private Use Area-A
        };

        for (nerd_font_ranges) |range| {
            // Sample a few codepoints in the range
            var test_point = range.start;
            while (test_point <= range.end and test_point < range.start + 100) : (test_point += 50) {
                const glyph_index = font.parser.getGlyphIndex(test_point) catch continue;
                if (glyph_index != 0) {
                    return true;
                }
            }
        }

        _ = self;
        return false;
    }

    fn checkForPowerlineSymbols(self: *Self, font: *Font) bool {
        // Check for Powerline symbols
        const powerline_glyphs = [_]u32{ 0xE0A0, 0xE0A1, 0xE0A2, 0xE0B0, 0xE0B1, 0xE0B2 };

        for (powerline_glyphs) |glyph| {
            const glyph_index = font.parser.getGlyphIndex(glyph) catch continue;
            if (glyph_index != 0) {
                return true;
            }
        }

        _ = self;
        return false;
    }
};

pub const LigatureOptions = struct {
    enable_ligatures: bool = true,
    font_specific_only: bool = false,
};

pub const LigatureResult = struct {
    ligatures: std.ArrayList(LigatureMatch),
    characters: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LigatureResult {
        return LigatureResult{
            .ligatures = std.ArrayList(LigatureMatch){},
            .characters = std.ArrayList(u8){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LigatureResult) void {
        self.ligatures.deinit();
        self.characters.deinit();
    }
};

pub const LigatureMatch = struct {
    position: usize,
    length: usize,
    replacement_glyph: u32,
};

pub const TerminalOptions = struct {
    font_size: f32,
    enable_subpixel: bool = true,
    cell_width: ?f32 = null,
    cell_height: ?f32 = null,
};

pub const TerminalOptimization = struct {
    line_height_adjustment: f32,
    character_spacing: f32,
    enable_hinting: bool,
    enable_subpixel: bool,
};

pub const FontFeatures = struct {
    has_ligatures: bool,
    has_nerd_font_icons: bool,
    is_monospace: bool,
    has_powerline_symbols: bool,
    programming_optimized: bool,
};

test "ProgrammingFontManager basic operations" {
    const allocator = std.testing.allocator;

    var manager = ProgrammingFontManager.init(allocator);
    defer manager.deinit();

    // Test ligature lookup
    const lig_info = manager.ligature_map.get("==");
    try std.testing.expect(lig_info != null);
    try std.testing.expect(lig_info.?.replacement_glyph == 0xE000);

    // Test Nerd Font icon lookup
    const icon = manager.getNerdFontIcon("file-code");
    try std.testing.expect(icon != null);
    try std.testing.expect(icon.?.codepoint == 0xF1C1);
}

test "Ligature processing" {
    const allocator = std.testing.allocator;

    var manager = ProgrammingFontManager.init(allocator);
    defer manager.deinit();

    const options = LigatureOptions{ .enable_ligatures = true };

    // This would need a real font for proper testing
    // For now, just test the structure
    try std.testing.expect(options.enable_ligatures == true);
}