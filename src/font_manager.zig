const std = @import("std");
const root = @import("root.zig");
const Font = @import("font.zig").Font;
const FontParser = @import("font_parser.zig").FontParser;

pub const FontManager = struct {
    allocator: std.mem.Allocator,
    font_cache: std.StringHashMap(*Font),
    system_font_paths: std.ArrayList([]const u8),
    fallback_fonts: std.ArrayList(*Font),
    system_fonts_scanned: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .font_cache = std.StringHashMap(*Font){},
            .system_font_paths = std.ArrayList([]const u8){},
            .fallback_fonts = std.ArrayList(*Font){},
            .system_fonts_scanned = false,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free cached fonts
        var iterator = self.font_cache.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.font_cache.deinit();

        // Free system font paths
        for (self.system_font_paths.items) |path| {
            self.allocator.free(path);
        }
        self.system_font_paths.deinit();

        // Free fallback fonts
        for (self.fallback_fonts.items) |font| {
            font.deinit();
            self.allocator.destroy(font);
        }
        self.fallback_fonts.deinit();
    }

    pub fn scanSystemFonts(self: *Self) !void {
        if (self.system_fonts_scanned) return;

        const system_paths = getSystemFontPaths();

        for (system_paths) |path| {
            try self.scanFontDirectory(path);
        }

        self.system_fonts_scanned = true;
    }

    fn scanFontDirectory(self: *Self, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return, // Directory doesn't exist, skip
            else => return err,
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file) {
                if (isFontFile(entry.name)) {
                    const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });
                    try self.system_font_paths.append(full_path);
                }
            }
        }
    }

    fn isFontFile(filename: []const u8) bool {
        const extensions = [_][]const u8{ ".ttf", ".otf", ".woff", ".woff2" };

        for (extensions) |ext| {
            if (std.mem.endsWith(u8, filename, ext)) {
                return true;
            }
        }
        return false;
    }

    pub fn loadFont(self: *Self, font_path: []const u8) !*Font {
        // Check cache first
        if (self.font_cache.get(font_path)) |font| {
            return font;
        }

        // Load font from file
        const font_data = try std.fs.cwd().readFileAlloc(self.allocator, font_path, 50 * 1024 * 1024); // 50MB max
        defer self.allocator.free(font_data);

        const font = try self.allocator.create(Font);
        font.* = try Font.init(self.allocator, font_data);

        // Cache the font
        const cached_path = try self.allocator.dupe(u8, font_path);
        try self.font_cache.put(cached_path, font);

        return font;
    }

    pub fn findFont(self: *Self, family_name: []const u8, options: root.RenderOptions) !?*Font {
        try self.scanSystemFonts();

        // Search through system fonts for matching family name
        for (self.system_font_paths.items) |path| {
            if (std.mem.indexOf(u8, path, family_name)) |_| {
                // Simple heuristic: if path contains family name, try to load it
                const font = self.loadFont(path) catch continue;

                // TODO: Check if font matches weight and style requirements
                if (fontMatchesStyle(font, options)) {
                    return font;
                }
            }
        }

        return null;
    }

    fn fontMatchesStyle(font: *Font, options: root.RenderOptions) bool {
        // Simplified matching - would need proper font metadata parsing
        _ = font;
        _ = options;
        return true;
    }

    pub fn getFallbackFont(self: *Self) !?*Font {
        if (self.fallback_fonts.items.len == 0) {
            try self.loadDefaultFallbacks();
        }

        if (self.fallback_fonts.items.len > 0) {
            return self.fallback_fonts.items[0];
        }

        return null;
    }

    pub fn registerPreferredFonts(self: *Self, families: []const []const u8) !void {
        for (families) |family| {
            const font = try self.findFont(family, .{ .size = 12.0 }) orelse continue;
            if (!self.hasFallbackFont(font)) {
                try self.fallback_fonts.append(font);
            }
        }
    }

    fn hasFallbackFont(self: *Self, font: *Font) bool {
        for (self.fallback_fonts.items) |existing| {
            if (existing == font) return true;
        }
        return false;
    }

    fn loadDefaultFallbacks(self: *Self) !void {
        const fallback_names = [_][]const u8{
            "DejaVu Sans Mono",
            "Liberation Mono",
            "Consolas",
            "Monaco",
            "Menlo",
            "Source Code Pro",
            "Roboto",
            "Roboto Slab",
            "Robot",
            "Ubuntu",
            "Cabin",
            "Adobe Caslon Pro",
            "Caslon",
            "DejaVu Sans",
            "DejaVu Serif",
            "Droid Sans",
            "Droid Serif",
            "Gentium Book Basic",
            "Gentium Plus",
            "Gentium",
            "Linux Libertine",
            "IM FELL DW Pica",
            "IM FELL English",
            "Open Baskerville",
            "EB Garamond",
            "Nimbus Mono PS",
            "Nimbus Sans",
            "Nimbus Sans L",
            "Nimbus Roman",
            "Nimbus Roman No9 L",
            "URW Bookman",
            "URW Gothic",
            "URW Palladio",
            "URW Chancery L",
            "Century Schoolbook L",
        };

        for (fallback_names) |name| {
            if (try self.findFont(name, .{ .size = 12.0 })) |font| {
                try self.fallback_fonts.append(font);
            }
        }
    }

    fn getSystemFontPaths() []const []const u8 {
        const builtin_os = @import("builtin").os.tag;
        return switch (builtin_os) {
            .linux => &[_][]const u8{
                "/usr/share/fonts",
                "/usr/local/share/fonts",
                "/home/.local/share/fonts",
                "/home/.fonts",
            },
            .macos => &[_][]const u8{
                "/System/Library/Fonts",
                "/Library/Fonts",
                "/Users/Shared/Fonts",
                "/home/Library/Fonts",
            },
            .windows => &[_][]const u8{
                "C:\\Windows\\Fonts",
                "C:\\Windows\\System32\\Fonts",
            },
            else => &[_][]const u8{
                "/usr/share/fonts",
                "/usr/local/share/fonts",
            },
        };
    }
};

test "FontManager initialization" {
    const allocator = std.testing.allocator;

    var manager = FontManager.init(allocator);
    defer manager.deinit();

    try std.testing.expect(manager.font_cache.count() == 0);
    try std.testing.expect(manager.system_font_paths.items.len == 0);
}

test "Font file detection" {
    try std.testing.expect(FontManager.isFontFile("test.ttf"));
    try std.testing.expect(FontManager.isFontFile("test.otf"));
    try std.testing.expect(FontManager.isFontFile("test.woff"));
    try std.testing.expect(!FontManager.isFontFile("test.txt"));
    try std.testing.expect(!FontManager.isFontFile("font"));
}
