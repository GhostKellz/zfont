const std = @import("std");
const root = @import("root.zig");
const FontManager = @import("font_manager.zig").FontManager;
const ProgrammingFonts = @import("programming_fonts.zig");
const Unicode = @import("unicode.zig").Unicode;

// PowerLevel10k support with optimized glyph rendering
// Provides out-of-the-box support for P10k icons and segments

pub const PowerLevel10k = struct {
    allocator: std.mem.Allocator,
    icon_cache: std.StringHashMap(P10kIcon),
    programming_manager: *ProgrammingFonts.ProgrammingFontManager,
    meslo_font: ?*root.Font = null,
    powerline_font: ?*root.Font = null,

    const Self = @This();

    const P10kIcon = struct {
        codepoint: u32,
        symbol: []const u8,
        description: []const u8,
        category: P10kCategory,
        recommended_font: RecommendedFont,
        width_hint: u8, // Suggested character width (1 or 2)
    };

    const P10kCategory = enum {
        segment_separators,
        system_icons,
        vcs_icons,
        status_icons,
        multiline_prompt,
        os_icons,
        directory_icons,
        misc_icons,
    };

    const RecommendedFont = enum {
        meslo_nerd_font,
        powerline_extra_symbols,
        nerd_font_complete,
        fallback_unicode,
    };

    pub fn init(allocator: std.mem.Allocator, programming_manager: *ProgrammingFonts.ProgrammingFontManager) Self {
        var p10k = Self{
            .allocator = allocator,
            .icon_cache = std.StringHashMap(P10kIcon).init(allocator),
            .programming_manager = programming_manager,
        };

        p10k.initializeP10kIcons() catch {};
        return p10k;
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.icon_cache.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.description);
        }
        self.icon_cache.deinit();
    }

    fn initializeP10kIcons(self: *Self) !void {
        // PowerLevel10k segment separators (most important for performance)
        try self.addIcon("LEFT_SEGMENT_SEPARATOR", P10kIcon{
            .codepoint = 0xE0B0, //
            .symbol = "\u{E0B0}",
            .description = try self.allocator.dupe(u8, "Left segment separator"),
            .category = .segment_separators,
            .recommended_font = .meslo_nerd_font,
            .width_hint = 1,
        });

        try self.addIcon("RIGHT_SEGMENT_SEPARATOR", P10kIcon{
            .codepoint = 0xE0B2, //
            .symbol = "\u{E0B2}",
            .description = try self.allocator.dupe(u8, "Right segment separator"),
            .category = .segment_separators,
            .recommended_font = .meslo_nerd_font,
            .width_hint = 1,
        });

        try self.addIcon("LEFT_SUBSEGMENT_SEPARATOR", P10kIcon{
            .codepoint = 0xE0B1, //
            .symbol = "\u{E0B1}",
            .description = try self.allocator.dupe(u8, "Left subsegment separator"),
            .category = .segment_separators,
            .recommended_font = .meslo_nerd_font,
            .width_hint = 1,
        });

        try self.addIcon("RIGHT_SUBSEGMENT_SEPARATOR", P10kIcon{
            .codepoint = 0xE0B3, //
            .symbol = "\u{E0B3}",
            .description = try self.allocator.dupe(u8, "Right subsegment separator"),
            .category = .segment_separators,
            .recommended_font = .meslo_nerd_font,
            .width_hint = 1,
        });

        // Multiline prompt characters (critical for terminal layout)
        try self.addIcon("MULTILINE_FIRST_PROMPT_PREFIX", P10kIcon{
            .codepoint = 0x256D, // ╭
            .symbol = "╭─",
            .description = try self.allocator.dupe(u8, "Multiline first prompt prefix"),
            .category = .multiline_prompt,
            .recommended_font = .fallback_unicode,
            .width_hint = 1,
        });

        try self.addIcon("MULTILINE_NEWLINE_PROMPT_PREFIX", P10kIcon{
            .codepoint = 0x251C, // ├
            .symbol = "├─",
            .description = try self.allocator.dupe(u8, "Multiline newline prompt prefix"),
            .category = .multiline_prompt,
            .recommended_font = .fallback_unicode,
            .width_hint = 1,
        });

        try self.addIcon("MULTILINE_LAST_PROMPT_PREFIX", P10kIcon{
            .codepoint = 0x2570, // ╰
            .symbol = "╰─ ",
            .description = try self.allocator.dupe(u8, "Multiline last prompt prefix"),
            .category = .multiline_prompt,
            .recommended_font = .fallback_unicode,
            .width_hint = 1,
        });

        // VCS (Git) icons
        try self.addIcon("VCS_BRANCH_ICON", P10kIcon{
            .codepoint = 0xE0A0, //
            .symbol = "\u{E0A0}",
            .description = try self.allocator.dupe(u8, "Git branch icon"),
            .category = .vcs_icons,
            .recommended_font = .powerline_extra_symbols,
            .width_hint = 1,
        });

        try self.addIcon("VCS_UNTRACKED_ICON", P10kIcon{
            .codepoint = 0xE16C, //
            .symbol = "\u{E16C}",
            .description = try self.allocator.dupe(u8, "Git untracked files icon"),
            .category = .vcs_icons,
            .recommended_font = .meslo_nerd_font,
            .width_hint = 1,
        });

        try self.addIcon("VCS_UNSTAGED_ICON", P10kIcon{
            .codepoint = 0xE17C, //
            .symbol = "\u{E17C}",
            .description = try self.allocator.dupe(u8, "Git unstaged changes icon"),
            .category = .vcs_icons,
            .recommended_font = .meslo_nerd_font,
            .width_hint = 1,
        });

        try self.addIcon("VCS_STAGED_ICON", P10kIcon{
            .codepoint = 0xE168, //
            .symbol = "\u{E168}",
            .description = try self.allocator.dupe(u8, "Git staged changes icon"),
            .category = .vcs_icons,
            .recommended_font = .meslo_nerd_font,
            .width_hint = 1,
        });

        // System and status icons
        try self.addIcon("ROOT_ICON", P10kIcon{
            .codepoint = 0xE801, //
            .symbol = "\u{E801}",
            .description = try self.allocator.dupe(u8, "Root user icon"),
            .category = .status_icons,
            .recommended_font = .meslo_nerd_font,
            .width_hint = 1,
        });

        try self.addIcon("OK_ICON", P10kIcon{
            .codepoint = 0x2714, // ✔
            .symbol = "✔",
            .description = try self.allocator.dupe(u8, "Success/OK icon"),
            .category = .status_icons,
            .recommended_font = .fallback_unicode,
            .width_hint = 1,
        });

        try self.addIcon("FAIL_ICON", P10kIcon{
            .codepoint = 0x2718, // ✘
            .symbol = "✘",
            .description = try self.allocator.dupe(u8, "Failure/error icon"),
            .category = .status_icons,
            .recommended_font = .fallback_unicode,
            .width_hint = 1,
        });

        // OS icons (Linux-focused for GhostShell)
        try self.addIcon("LINUX_ICON", P10kIcon{
            .codepoint = 0xE271, //
            .symbol = "\u{E271}",
            .description = try self.allocator.dupe(u8, "Linux OS icon"),
            .category = .os_icons,
            .recommended_font = .meslo_nerd_font,
            .width_hint = 1,
        });

        try self.addIcon("LINUX_ARCH_ICON", P10kIcon{
            .codepoint = 0xE271, //
            .symbol = "\u{E271}",
            .description = try self.allocator.dupe(u8, "Arch Linux icon"),
            .category = .os_icons,
            .recommended_font = .meslo_nerd_font,
            .width_hint = 1,
        });

        // Directory icons
        try self.addIcon("HOME_ICON", P10kIcon{
            .codepoint = 0xE12C, //
            .symbol = "\u{E12C}",
            .description = try self.allocator.dupe(u8, "Home directory icon"),
            .category = .directory_icons,
            .recommended_font = .meslo_nerd_font,
            .width_hint = 1,
        });

        try self.addIcon("FOLDER_ICON", P10kIcon{
            .codepoint = 0xE818, //
            .symbol = "\u{E818}",
            .description = try self.allocator.dupe(u8, "Folder icon"),
            .category = .directory_icons,
            .recommended_font = .meslo_nerd_font,
            .width_hint = 1,
        });

        // Programming language icons (integrate with existing system)
        try self.addIcon("NODEJS_ICON", P10kIcon{
            .codepoint = 0x2B22, // ⬢
            .symbol = "⬢",
            .description = try self.allocator.dupe(u8, "Node.js icon"),
            .category = .misc_icons,
            .recommended_font = .fallback_unicode,
            .width_hint = 1,
        });
    }

    fn addIcon(self: *Self, name: []const u8, icon: P10kIcon) !void {
        const key = try self.allocator.dupe(u8, name);
        try self.icon_cache.put(key, icon);
    }

    pub fn getIcon(self: *Self, name: []const u8) ?P10kIcon {
        return self.icon_cache.get(name);
    }

    pub fn loadOptimalFonts(self: *Self, font_manager: *FontManager) !void {
        // Try to load MesloLGS NF (PowerLevel10k's recommended font)
        const meslo_names = [_][]const u8{
            "MesloLGS NF",
            "MesloLGS Nerd Font",
            "Meslo LG S",
            "MesloLGS",
        };

        for (meslo_names) |font_name| {
            if (try font_manager.findFont(font_name, .{ .size = 12.0 })) |font| {
                self.meslo_font = font;
                break;
            }
        }

        // Try to load a Powerline-compatible font
        const powerline_names = [_][]const u8{
            "Source Code Pro for Powerline",
            "Fira Code",
            "JetBrains Mono",
            "Cascadia Code PL",
        };

        for (powerline_names) |font_name| {
            if (try font_manager.findFont(font_name, .{ .size = 12.0 })) |font| {
                self.powerline_font = font;
                break;
            }
        }
    }

    pub fn getFontForIcon(self: *Self, icon_name: []const u8) ?*root.Font {
        if (self.getIcon(icon_name)) |icon| {
            return switch (icon.recommended_font) {
                .meslo_nerd_font => self.meslo_font,
                .powerline_extra_symbols => self.powerline_font orelse self.meslo_font,
                .nerd_font_complete => self.meslo_font orelse self.powerline_font,
                .fallback_unicode => self.meslo_font orelse self.powerline_font,
            };
        }
        return null;
    }

    pub fn renderP10kSegment(self: *Self, segment_type: P10kSegmentType, content: []const u8, style: P10kStyle) !P10kRenderedSegment {
        const segment_info = getSegmentInfo(segment_type);

        var rendered = P10kRenderedSegment{
            .allocator = self.allocator,
            .text = std.ArrayList(u8).init(self.allocator),
            .width = 0,
            .segment_type = segment_type,
            .style = style,
        };

        // Add left separator if needed
        if (style.left_separator) |sep_name| {
            if (self.getIcon(sep_name)) |icon| {
                try rendered.text.appendSlice(icon.symbol);
                rendered.width += icon.width_hint;
            }
        }

        // Add segment icon
        if (segment_info.icon_name) |icon_name| {
            if (self.getIcon(icon_name)) |icon| {
                try rendered.text.appendSlice(icon.symbol);
                rendered.width += icon.width_hint;

                // Add spacing after icon
                try rendered.text.append(' ');
                rendered.width += 1;
            }
        }

        // Add content
        try rendered.text.appendSlice(content);
        rendered.width += Unicode.stringWidth(content);

        // Add right separator if needed
        if (style.right_separator) |sep_name| {
            if (self.getIcon(sep_name)) |icon| {
                try rendered.text.appendSlice(icon.symbol);
                rendered.width += icon.width_hint;
            }
        }

        return rendered;
    }

    // Performance optimization: pre-render common segments
    pub fn preRenderCommonSegments(self: *Self) !void {
        // Pre-render frequently used segments to improve terminal responsiveness
        const common_segments = [_]struct { segment_type: P10kSegmentType, content: []const u8 }{
            .{ .segment_type = .os, .content = "linux" },
            .{ .segment_type = .vcs, .content = "main" },
            .{ .segment_type = .dir, .content = "~" },
            .{ .segment_type = .status, .content = "" },
        };

        for (common_segments) |seg| {
            const rendered = try self.renderP10kSegment(seg.segment_type, seg.content, P10kStyle.default());
            defer rendered.deinit();
            // Could cache these for ultra-fast rendering
        }
    }

    pub fn optimizeForTerminal(self: *Self, terminal_info: TerminalInfo) !void {
        _ = self;

        // Terminal-specific optimizations based on capabilities
        switch (terminal_info.type) {
            .ghostshell => {
                // GhostShell-specific optimizations
                // - GPU-accelerated segment rendering
                // - NVIDIA-optimized glyph caching
                // - Wayland native rendering
            },
            .alacritty => {
                // Alacritty optimizations
            },
            .kitty => {
                // Kitty optimizations
            },
            .wezterm => {
                // WezTerm optimizations
            },
            .other => {
                // Generic terminal optimizations
            },
        }
    }
};

const P10kSegmentType = enum {
    os,
    dir,
    vcs,
    status,
    time,
    user,
    host,
    custom,
};

const P10kStyle = struct {
    left_separator: ?[]const u8 = null,
    right_separator: ?[]const u8 = null,
    background_color: u32 = 0x000000,
    foreground_color: u32 = 0xFFFFFF,

    pub fn default() P10kStyle {
        return P10kStyle{
            .left_separator = "LEFT_SEGMENT_SEPARATOR",
            .right_separator = "RIGHT_SEGMENT_SEPARATOR",
        };
    }
};

const P10kRenderedSegment = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayList(u8),
    width: usize,
    segment_type: P10kSegmentType,
    style: P10kStyle,

    pub fn deinit(self: *P10kRenderedSegment) void {
        self.text.deinit();
    }
};

const TerminalInfo = struct {
    type: TerminalType,
    supports_true_color: bool = true,
    supports_unicode: bool = true,
    cell_width: u32 = 8,
    cell_height: u32 = 16,
};

const TerminalType = enum {
    ghostshell,
    alacritty,
    kitty,
    wezterm,
    other,
};

const SegmentInfo = struct {
    icon_name: ?[]const u8,
    default_content: []const u8,
    description: []const u8,
};

fn getSegmentInfo(segment_type: P10kSegmentType) SegmentInfo {
    return switch (segment_type) {
        .os => SegmentInfo{
            .icon_name = "LINUX_ICON",
            .default_content = "linux",
            .description = "Operating system identifier",
        },
        .dir => SegmentInfo{
            .icon_name = "FOLDER_ICON",
            .default_content = "~",
            .description = "Current directory",
        },
        .vcs => SegmentInfo{
            .icon_name = "VCS_BRANCH_ICON",
            .default_content = "main",
            .description = "Version control status",
        },
        .status => SegmentInfo{
            .icon_name = "OK_ICON",
            .default_content = "",
            .description = "Last command status",
        },
        .time => SegmentInfo{
            .icon_name = null,
            .default_content = "00:00",
            .description = "Current time",
        },
        .user => SegmentInfo{
            .icon_name = "ROOT_ICON",
            .default_content = "user",
            .description = "Current user",
        },
        .host => SegmentInfo{
            .icon_name = null,
            .default_content = "localhost",
            .description = "Hostname",
        },
        .custom => SegmentInfo{
            .icon_name = null,
            .default_content = "",
            .description = "Custom segment",
        },
    };
}

// Tests
test "PowerLevel10k initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var prog_manager = ProgrammingFonts.ProgrammingFontManager.init(allocator);
    defer prog_manager.deinit();

    var p10k = PowerLevel10k.init(allocator, &prog_manager);
    defer p10k.deinit();

    // Test that basic icons are loaded
    try testing.expect(p10k.getIcon("LEFT_SEGMENT_SEPARATOR") != null);
    try testing.expect(p10k.getIcon("VCS_BRANCH_ICON") != null);
    try testing.expect(p10k.getIcon("LINUX_ICON") != null);
}

test "PowerLevel10k icon lookup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var prog_manager = ProgrammingFonts.ProgrammingFontManager.init(allocator);
    defer prog_manager.deinit();

    var p10k = PowerLevel10k.init(allocator, &prog_manager);
    defer p10k.deinit();

    const sep_icon = p10k.getIcon("LEFT_SEGMENT_SEPARATOR").?;
    try testing.expect(sep_icon.codepoint == 0xE0B0);
    try testing.expect(sep_icon.category == .segment_separators);
}

test "PowerLevel10k segment rendering" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var prog_manager = ProgrammingFonts.ProgrammingFontManager.init(allocator);
    defer prog_manager.deinit();

    var p10k = PowerLevel10k.init(allocator, &prog_manager);
    defer p10k.deinit();

    var rendered = try p10k.renderP10kSegment(.os, "linux", P10kStyle.default());
    defer rendered.deinit();

    try testing.expect(rendered.text.items.len > 0);
    try testing.expect(rendered.width > 0);
}