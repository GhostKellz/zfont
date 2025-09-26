const std = @import("std");
const root = @import("root.zig");

// Vivid color support for modern Linux terminals
// Provides enhanced color rendering with true color (24-bit) support
pub const VividColorRenderer = struct {
    allocator: std.mem.Allocator,
    color_space: ColorSpace,
    gamma_correction: f32,

    const Self = @This();

    pub const ColorSpace = enum {
        srgb,
        display_p3,
        rec2020,
        adobe_rgb,
    };

    pub const Color = struct {
        r: f32,
        g: f32,
        b: f32,
        a: f32 = 1.0,

        pub fn fromRGB(r: u8, g: u8, b: u8) Color {
            return Color{
                .r = @as(f32, @floatFromInt(r)) / 255.0,
                .g = @as(f32, @floatFromInt(g)) / 255.0,
                .b = @as(f32, @floatFromInt(b)) / 255.0,
            };
        }

        pub fn fromHex(hex: u32) Color {
            return Color{
                .r = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
                .g = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
                .b = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0,
            };
        }

        pub fn toRGB(self: Color) struct { r: u8, g: u8, b: u8 } {
            return .{
                .r = @intFromFloat(@round(std.math.clamp(self.r, 0.0, 1.0) * 255.0)),
                .g = @intFromFloat(@round(std.math.clamp(self.g, 0.0, 1.0) * 255.0)),
                .b = @intFromFloat(@round(std.math.clamp(self.b, 0.0, 1.0) * 255.0)),
            };
        }

        pub fn lerp(self: Color, other: Color, t: f32) Color {
            return Color{
                .r = self.r + (other.r - self.r) * t,
                .g = self.g + (other.g - self.g) * t,
                .b = self.b + (other.b - self.b) * t,
                .a = self.a + (other.a - self.a) * t,
            };
        }
    };

    // Terminal color capabilities detection
    pub const TerminalCapabilities = struct {
        true_color: bool = false,      // 24-bit RGB
        color_256: bool = false,       // 256 color palette
        color_16: bool = false,        // 16 basic colors
        color_8: bool = false,         // 8 basic colors
        italic: bool = false,
        bold: bool = false,
        underline: bool = false,
        strikethrough: bool = false,

        pub fn detect() TerminalCapabilities {
            var caps = TerminalCapabilities{};

            // Check environment variables
            if (std.posix.getenv("COLORTERM")) |colorterm| {
                if (std.mem.eql(u8, colorterm, "truecolor") or
                    std.mem.eql(u8, colorterm, "24bit")) {
                    caps.true_color = true;
                }
            }

            if (std.posix.getenv("TERM")) |term| {
                if (std.mem.indexOf(u8, term, "256") != null) {
                    caps.color_256 = true;
                } else if (std.mem.indexOf(u8, term, "color") != null) {
                    caps.color_16 = true;
                } else {
                    caps.color_8 = true;
                }

                // Most modern terminals support these
                if (std.mem.indexOf(u8, term, "xterm") != null or
                    std.mem.indexOf(u8, term, "screen") != null or
                    std.mem.indexOf(u8, term, "tmux") != null) {
                    caps.italic = true;
                    caps.bold = true;
                    caps.underline = true;
                }
            }

            return caps;
        }
    };

    // Vivid color themes for terminals
    pub const VividTheme = struct {
        background: Color,
        foreground: Color,
        cursor: Color,
        selection: Color,

        // Normal colors
        black: Color,
        red: Color,
        green: Color,
        yellow: Color,
        blue: Color,
        magenta: Color,
        cyan: Color,
        white: Color,

        // Bright colors
        bright_black: Color,
        bright_red: Color,
        bright_green: Color,
        bright_yellow: Color,
        bright_blue: Color,
        bright_magenta: Color,
        bright_cyan: Color,
        bright_white: Color,

        pub fn vibrantDark() VividTheme {
            return VividTheme{
                .background = Color.fromHex(0x1a1a1a),
                .foreground = Color.fromHex(0xe0e0e0),
                .cursor = Color.fromHex(0x00ff00),
                .selection = Color.fromHex(0x444444),

                .black = Color.fromHex(0x2e3436),
                .red = Color.fromHex(0xff6b6b),
                .green = Color.fromHex(0x4ecdc4),
                .yellow = Color.fromHex(0xffe066),
                .blue = Color.fromHex(0x74b9ff),
                .magenta = Color.fromHex(0xa29bfe),
                .cyan = Color.fromHex(0x81ecec),
                .white = Color.fromHex(0xeeeeee),

                .bright_black = Color.fromHex(0x555753),
                .bright_red = Color.fromHex(0xff7675),
                .bright_green = Color.fromHex(0x55efc4),
                .bright_yellow = Color.fromHex(0xfdcb6e),
                .bright_blue = Color.fromHex(0x6c5ce7),
                .bright_magenta = Color.fromHex(0xfd79a8),
                .bright_cyan = Color.fromHex(0x00cec9),
                .bright_white = Color.fromHex(0xffffff),
            };
        }

        pub fn solarizedDark() VividTheme {
            return VividTheme{
                .background = Color.fromHex(0x002b36),
                .foreground = Color.fromHex(0x839496),
                .cursor = Color.fromHex(0x93a1a1),
                .selection = Color.fromHex(0x073642),

                .black = Color.fromHex(0x073642),
                .red = Color.fromHex(0xdc322f),
                .green = Color.fromHex(0x859900),
                .yellow = Color.fromHex(0xb58900),
                .blue = Color.fromHex(0x268bd2),
                .magenta = Color.fromHex(0xd33682),
                .cyan = Color.fromHex(0x2aa198),
                .white = Color.fromHex(0xeee8d5),

                .bright_black = Color.fromHex(0x586e75),
                .bright_red = Color.fromHex(0xcb4b16),
                .bright_green = Color.fromHex(0x586e75),
                .bright_yellow = Color.fromHex(0x657b83),
                .bright_blue = Color.fromHex(0x839496),
                .bright_magenta = Color.fromHex(0x6c71c4),
                .bright_cyan = Color.fromHex(0x93a1a1),
                .bright_white = Color.fromHex(0xfdf6e3),
            };
        }

        pub fn catppuccin() VividTheme {
            return VividTheme{
                .background = Color.fromHex(0x1e1e2e),
                .foreground = Color.fromHex(0xcdd6f4),
                .cursor = Color.fromHex(0xf5e0dc),
                .selection = Color.fromHex(0x414559),

                .black = Color.fromHex(0x45475a),
                .red = Color.fromHex(0xf38ba8),
                .green = Color.fromHex(0xa6e3a1),
                .yellow = Color.fromHex(0xf9e2af),
                .blue = Color.fromHex(0x89b4fa),
                .magenta = Color.fromHex(0xf5c2e7),
                .cyan = Color.fromHex(0x94e2d5),
                .white = Color.fromHex(0xbac2de),

                .bright_black = Color.fromHex(0x585b70),
                .bright_red = Color.fromHex(0xf38ba8),
                .bright_green = Color.fromHex(0xa6e3a1),
                .bright_yellow = Color.fromHex(0xf9e2af),
                .bright_blue = Color.fromHex(0x89b4fa),
                .bright_magenta = Color.fromHex(0xf5c2e7),
                .bright_cyan = Color.fromHex(0x94e2d5),
                .bright_white = Color.fromHex(0xa6adc8),
            };
        }

        pub fn tokyoNight() VividTheme {
            return VividTheme{
                .background = Color.fromHex(0x0c0f17),
                .foreground = Color.fromHex(0xcbe3e7),
                .cursor = Color.fromHex(0x8aff80),
                .selection = Color.fromHex(0x23476a),

                .black = Color.fromHex(0x0c0f17),
                .red = Color.fromHex(0xff5c57),
                .green = Color.fromHex(0x8aff80),
                .yellow = Color.fromHex(0xf3f99d),
                .blue = Color.fromHex(0x57c7ff),
                .magenta = Color.fromHex(0xff6ac1),
                .cyan = Color.fromHex(0x9aedfe),
                .white = Color.fromHex(0xf1f1f0),

                .bright_black = Color.fromHex(0x686868),
                .bright_red = Color.fromHex(0xff5c57),
                .bright_green = Color.fromHex(0x8aff80),
                .bright_yellow = Color.fromHex(0xf3f99d),
                .bright_blue = Color.fromHex(0x57c7ff),
                .bright_magenta = Color.fromHex(0xff6ac1),
                .bright_cyan = Color.fromHex(0x9aedfe),
                .bright_white = Color.fromHex(0xffffff),
            };
        }

        pub fn tokyoNightStorm() VividTheme {
            return VividTheme{
                .background = Color.fromHex(0x24283b),
                .foreground = Color.fromHex(0xa9b1d6),
                .cursor = Color.fromHex(0xc0caf5),
                .selection = Color.fromHex(0x364a82),

                .black = Color.fromHex(0x32344a),
                .red = Color.fromHex(0xf7768e),
                .green = Color.fromHex(0x9ece6a),
                .yellow = Color.fromHex(0xe0af68),
                .blue = Color.fromHex(0x7aa2f7),
                .magenta = Color.fromHex(0xad8ee6),
                .cyan = Color.fromHex(0x449dab),
                .white = Color.fromHex(0x9699a8),

                .bright_black = Color.fromHex(0x444b6a),
                .bright_red = Color.fromHex(0xff7a93),
                .bright_green = Color.fromHex(0xb9f27c),
                .bright_yellow = Color.fromHex(0xff9e64),
                .bright_blue = Color.fromHex(0x7da6ff),
                .bright_magenta = Color.fromHex(0xbb9af7),
                .bright_cyan = Color.fromHex(0x0db9d7),
                .bright_white = Color.fromHex(0xacb0d0),
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator, color_space: ColorSpace, gamma: f32) Self {
        return Self{
            .allocator = allocator,
            .color_space = color_space,
            .gamma_correction = gamma,
        };
    }

    // Convert colors between different color spaces
    pub fn convertColor(self: *const Self, color: Color, target_space: ColorSpace) Color {
        if (self.color_space == target_space) return color;

        return switch (self.color_space) {
            .srgb => switch (target_space) {
                .display_p3 => self.srgbToDisplayP3(color),
                .rec2020 => self.srgbToRec2020(color),
                .adobe_rgb => self.srgbToAdobeRGB(color),
                else => color,
            },
            .display_p3 => switch (target_space) {
                .srgb => self.displayP3ToSrgb(color),
                else => color, // Simplified
            },
            else => color, // Simplified for other spaces
        };
    }

    fn srgbToDisplayP3(self: *const Self, color: Color) Color {
        _ = self;
        // Simplified color space conversion matrix
        // In practice, this would use proper ICC profiles
        const r = color.r * 0.8225 + color.g * 0.1774 + color.b * 0.0001;
        const g = color.r * 0.0331 + color.g * 0.9669 + color.b * 0.0000;
        const b = color.r * 0.0170 + color.g * 0.0724 + color.b * 0.9106;

        return Color{ .r = r, .g = g, .b = b, .a = color.a };
    }

    fn displayP3ToSrgb(self: *const Self, color: Color) Color {
        _ = self;
        // Inverse transformation (simplified)
        const r = color.r * 1.2247 + color.g * -0.2247 + color.b * 0.0000;
        const g = color.r * -0.0420 + color.g * 1.0420 + color.b * 0.0000;
        const b = color.r * -0.0196 + color.g * -0.0786 + color.b * 1.0982;

        return Color{ .r = r, .g = g, .b = b, .a = color.a };
    }

    fn srgbToRec2020(self: *const Self, color: Color) Color {
        _ = self;
        // Simplified Rec.2020 conversion
        return color; // Placeholder
    }

    fn srgbToAdobeRGB(self: *const Self, color: Color) Color {
        _ = self;
        // Simplified Adobe RGB conversion
        return color; // Placeholder
    }

    // Apply gamma correction
    pub fn applyGamma(self: *const Self, color: Color) Color {
        const gamma_inv = 1.0 / self.gamma_correction;
        return Color{
            .r = std.math.pow(f32, color.r, gamma_inv),
            .g = std.math.pow(f32, color.g, gamma_inv),
            .b = std.math.pow(f32, color.b, gamma_inv),
            .a = color.a,
        };
    }

    // Generate terminal escape codes for true color
    pub fn generateTrueColorEscape(self: *const Self, color: Color, background: bool) ![]u8 {
        const rgb = color.toRGB();

        return if (background)
            try std.fmt.allocPrint(self.allocator, "\x1b[48;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b })
        else
            try std.fmt.allocPrint(self.allocator, "\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b });
    }

    // Generate 256-color palette escape codes
    pub fn generate256ColorEscape(self: *const Self, color: Color, background: bool) ![]u8 {
        const color_idx = self.colorTo256Palette(color);

        return if (background)
            try std.fmt.allocPrint(self.allocator, "\x1b[48;5;{d}m", .{color_idx})
        else
            try std.fmt.allocPrint(self.allocator, "\x1b[38;5;{d}m", .{color_idx});
    }

    fn colorTo256Palette(self: *const Self, color: Color) u8 {
        _ = self;
        const rgb = color.toRGB();

        // Convert RGB to 256-color palette index
        if (rgb.r == rgb.g and rgb.g == rgb.b) {
            // Grayscale
            if (rgb.r < 8) return 16;
            if (rgb.r > 248) return 231;
            return @intCast(232 + (rgb.r - 8) / 10);
        }

        // Color cube (6x6x6)
        const r6 = rgb.r * 5 / 255;
        const g6 = rgb.g * 5 / 255;
        const b6 = rgb.b * 5 / 255;

        return @intCast(16 + 36 * r6 + 6 * g6 + b6);
    }

    // Enhanced text rendering with vivid colors
    pub fn renderText(self: *Self, text: []const u8, fg_color: Color, bg_color: ?Color, style: TextStyle) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);

        // Apply gamma correction
        const gamma_fg = self.applyGamma(fg_color);
        const gamma_bg = if (bg_color) |bg| self.applyGamma(bg) else null;

        // Detect terminal capabilities
        const caps = TerminalCapabilities.detect();

        // Generate appropriate escape codes
        if (caps.true_color) {
            const fg_escape = try self.generateTrueColorEscape(gamma_fg, false);
            defer self.allocator.free(fg_escape);
            try result.appendSlice(fg_escape);

            if (gamma_bg) |bg| {
                const bg_escape = try self.generateTrueColorEscape(bg, true);
                defer self.allocator.free(bg_escape);
                try result.appendSlice(bg_escape);
            }
        } else if (caps.color_256) {
            const fg_escape = try self.generate256ColorEscape(gamma_fg, false);
            defer self.allocator.free(fg_escape);
            try result.appendSlice(fg_escape);

            if (gamma_bg) |bg| {
                const bg_escape = try self.generate256ColorEscape(bg, true);
                defer self.allocator.free(bg_escape);
                try result.appendSlice(bg_escape);
            }
        }

        // Apply text styling
        if (style.bold and caps.bold) try result.appendSlice("\x1b[1m");
        if (style.italic and caps.italic) try result.appendSlice("\x1b[3m");
        if (style.underline and caps.underline) try result.appendSlice("\x1b[4m");
        if (style.strikethrough and caps.strikethrough) try result.appendSlice("\x1b[9m");

        // Add the actual text
        try result.appendSlice(text);

        // Reset formatting
        try result.appendSlice("\x1b[0m");

        return result.toOwnedSlice();
    }

    pub const TextStyle = struct {
        bold: bool = false,
        italic: bool = false,
        underline: bool = false,
        strikethrough: bool = false,
    };
};

// Smooth color transitions for animations
pub const ColorAnimator = struct {
    allocator: std.mem.Allocator,
    current_time: f32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .current_time = 0.0,
        };
    }

    pub fn update(self: *Self, delta_time: f32) void {
        self.current_time += delta_time;
    }

    pub fn animateColor(self: *const Self, from: VividColorRenderer.Color, to: VividColorRenderer.Color, duration: f32, easing: EasingFunction) VividColorRenderer.Color {
        const t = std.math.clamp(self.current_time / duration, 0.0, 1.0);
        const eased_t = switch (easing) {
            .linear => t,
            .ease_in => t * t,
            .ease_out => 1.0 - (1.0 - t) * (1.0 - t),
            .ease_in_out => if (t < 0.5) 2.0 * t * t else 1.0 - 2.0 * (1.0 - t) * (1.0 - t),
        };

        return from.lerp(to, eased_t);
    }

    pub const EasingFunction = enum {
        linear,
        ease_in,
        ease_out,
        ease_in_out,
    };
};

test "VividColorRenderer basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    _ = VividColorRenderer.init(allocator, .srgb, 2.2);

    const red = VividColorRenderer.Color.fromRGB(255, 0, 0);
    const rgb = red.toRGB();

    try testing.expect(rgb.r == 255);
    try testing.expect(rgb.g == 0);
    try testing.expect(rgb.b == 0);
}

test "Terminal capabilities detection" {
    const caps = VividColorRenderer.TerminalCapabilities.detect();
    // Just ensure it runs without crashing
    _ = caps;
}