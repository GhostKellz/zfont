const std = @import("std");
const root = @import("root.zig");

// Dynamic configuration system for runtime font and theme changes
// Supports hot-reloading and live configuration updates
pub const DynamicConfig = struct {
    allocator: std.mem.Allocator,
    config_path: []const u8,
    current_config: Config,
    watchers: std.ArrayList(ConfigWatcher),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub const Config = struct {
        // Font configuration
        font_family: []const u8,
        font_size: f32,
        font_weight: root.FontWeight,
        font_style: root.FontStyle,

        // Theme configuration
        theme_name: []const u8,
        theme: @import("vivid_colors.zig").VividColorRenderer.VividTheme,

        // OpenType features
        enable_ligatures: bool,
        enable_kerning: bool,
        stylistic_set: ?u8,
        zero_style: ZeroStyle,

        // Terminal behavior
        cursor_blink: bool,
        cursor_shape: CursorShape,
        window_padding_x: u32,
        window_padding_y: u32,

        pub fn init(_: std.mem.Allocator) Config {
            return Config{
                .font_family = "CaskaydiaCove NFM SemiBold",
                .font_size = 15.0,
                .font_weight = .normal,
                .font_style = .normal,
                .theme_name = "tokyo-night",
                .theme = @import("vivid_colors.zig").VividColorRenderer.VividTheme.tokyoNight(),
                .enable_ligatures = true,
                .enable_kerning = true,
                .stylistic_set = null,
                .zero_style = .normal,
                .cursor_blink = true,
                .cursor_shape = .block,
                .window_padding_x = 2,
                .window_padding_y = 2,
            };
        }

        pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
            allocator.free(self.font_family);
            allocator.free(self.theme_name);
        }
    };

    pub const ZeroStyle = enum {
        normal,
        slashed,
        dotted,
    };

    pub const CursorShape = enum {
        block,
        underline,
        bar,
    };

    pub const ConfigWatcher = struct {
        callback: *const fn (config: *const Config) void,
        context: ?*anyopaque,
    };

    pub fn init(allocator: std.mem.Allocator, config_path: []const u8) !Self {
        var config = Self{
            .allocator = allocator,
            .config_path = try allocator.dupe(u8, config_path),
            .current_config = Config.init(allocator),
            .watchers = std.ArrayList(ConfigWatcher).init(allocator),
            .mutex = std.Thread.Mutex{},
        };

        // Try to load existing config
        config.loadConfig() catch |err| switch (err) {
            error.FileNotFound => {
                // Create default config file
                try config.saveConfig();
            },
            else => return err,
        };

        return config;
    }

    pub fn deinit(self: *Self) void {
        self.current_config.deinit(self.allocator);
        self.watchers.deinit();
        self.allocator.free(self.config_path);
    }

    pub fn loadConfig(self: *Self) !void {
        const file = try std.fs.cwd().openFile(self.config_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB max
        defer self.allocator.free(content);

        try self.parseConfig(content);
    }

    fn parseConfig(self: *Self, content: []const u8) !void {
        var lines = std.mem.split(u8, content, "\n");
        var new_config = Config.init(self.allocator);

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Skip comments and empty lines
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Parse key=value pairs
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1..], " \t");

                try self.setConfigValue(&new_config, key, value);
            }
        }

        // Update theme based on theme_name
        new_config.theme = self.getThemeByName(new_config.theme_name);

        self.mutex.lock();
        defer self.mutex.unlock();

        self.current_config.deinit(self.allocator);
        self.current_config = new_config;
    }

    fn setConfigValue(self: *Self, config: *Config, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, key, "font-family")) {
            self.allocator.free(config.font_family);
            config.font_family = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "font-size")) {
            config.font_size = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, key, "theme")) {
            self.allocator.free(config.theme_name);
            config.theme_name = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "enable-ligatures")) {
            config.enable_ligatures = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "enable-kerning")) {
            config.enable_kerning = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "zero-style")) {
            config.zero_style = if (std.mem.eql(u8, value, "slashed")) .slashed
                              else if (std.mem.eql(u8, value, "dotted")) .dotted
                              else .normal;
        } else if (std.mem.eql(u8, key, "cursor-blink")) {
            config.cursor_blink = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "cursor-shape")) {
            config.cursor_shape = if (std.mem.eql(u8, value, "underline")) .underline
                                 else if (std.mem.eql(u8, value, "bar")) .bar
                                 else .block;
        } else if (std.mem.eql(u8, key, "window-padding-x")) {
            config.window_padding_x = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "window-padding-y")) {
            config.window_padding_y = try std.fmt.parseInt(u32, value, 10);
        }
        // Add more config options as needed
    }

    fn getThemeByName(self: *Self, name: []const u8) @import("vivid_colors.zig").VividColorRenderer.VividTheme {
        _ = self;
        const VividTheme = @import("vivid_colors.zig").VividColorRenderer.VividTheme;

        if (std.mem.eql(u8, name, "tokyo-night")) return VividTheme.tokyoNight();
        if (std.mem.eql(u8, name, "tokyo-night-storm")) return VividTheme.tokyoNightStorm();
        if (std.mem.eql(u8, name, "solarized-dark")) return VividTheme.solarizedDark();
        if (std.mem.eql(u8, name, "catppuccin")) return VividTheme.catppuccin();
        if (std.mem.eql(u8, name, "vibrant-dark")) return VividTheme.vibrantDark();

        // Default to Tokyo Night
        return VividTheme.tokyoNight();
    }

    pub fn saveConfig(self: *Self) !void {
        const file = try std.fs.cwd().createFile(self.config_path, .{});
        defer file.close();

        var writer = file.writer();

        // Write header comment
        try writer.writeAll("# ZFont Dynamic Configuration\n");
        try writer.writeAll("# This file supports hot-reloading - changes take effect immediately\n");
        try writer.writeAll("# Use Ctrl+Shift+Comma to open configuration menu\n\n");

        self.mutex.lock();
        defer self.mutex.unlock();

        // Font settings
        try writer.print("font-family={s}\n", .{self.current_config.font_family});
        try writer.print("font-size={d}\n", .{self.current_config.font_size});

        // Theme settings
        try writer.print("theme={s}\n", .{self.current_config.theme_name});

        // Feature settings
        try writer.print("enable-ligatures={s}\n", .{if (self.current_config.enable_ligatures) "true" else "false"});
        try writer.print("enable-kerning={s}\n", .{if (self.current_config.enable_kerning) "true" else "false"});

        const zero_style_str = switch (self.current_config.zero_style) {
            .normal => "normal",
            .slashed => "slashed",
            .dotted => "dotted",
        };
        try writer.print("zero-style={s}\n", .{zero_style_str});

        // Cursor settings
        try writer.print("cursor-blink={s}\n", .{if (self.current_config.cursor_blink) "true" else "false"});

        const cursor_shape_str = switch (self.current_config.cursor_shape) {
            .block => "block",
            .underline => "underline",
            .bar => "bar",
        };
        try writer.print("cursor-shape={s}\n", .{cursor_shape_str});

        // Window settings
        try writer.print("window-padding-x={d}\n", .{self.current_config.window_padding_x});
        try writer.print("window-padding-y={d}\n", .{self.current_config.window_padding_y});

        // Available themes comment
        try writer.writeAll("\n# Available themes:\n");
        try writer.writeAll("# - tokyo-night\n");
        try writer.writeAll("# - tokyo-night-storm\n");
        try writer.writeAll("# - solarized-dark\n");
        try writer.writeAll("# - catppuccin\n");
        try writer.writeAll("# - vibrant-dark\n");
    }

    pub fn addWatcher(self: *Self, callback: *const fn (config: *const Config) void) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.watchers.append(ConfigWatcher{
            .callback = callback,
            .context = null,
        });
    }

    pub fn removeWatcher(self: *Self, callback: *const fn (config: *const Config) void) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.watchers.items, 0..) |watcher, i| {
            if (watcher.callback == callback) {
                _ = self.watchers.swapRemove(i);
                return;
            }
        }
    }

    fn notifyWatchers(self: *Self) void {
        for (self.watchers.items) |watcher| {
            watcher.callback(&self.current_config);
        }
    }

    // Hot reload configuration
    pub fn reloadConfig(self: *Self) !void {
        try self.loadConfig();
        self.notifyWatchers();
    }

    // Update specific config values at runtime
    pub fn setFontFamily(self: *Self, family: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.allocator.free(self.current_config.font_family);
        self.current_config.font_family = try self.allocator.dupe(u8, family);
        self.notifyWatchers();
    }

    pub fn setFontSize(self: *Self, size: f32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.current_config.font_size = size;
        self.notifyWatchers();
    }

    pub fn setTheme(self: *Self, theme_name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.allocator.free(self.current_config.theme_name);
        self.current_config.theme_name = try self.allocator.dupe(u8, theme_name);
        self.current_config.theme = self.getThemeByName(theme_name);
        self.notifyWatchers();
    }

    pub fn toggleLigatures(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.current_config.enable_ligatures = !self.current_config.enable_ligatures;
        self.notifyWatchers();
    }

    pub fn getConfig(self: *const Self) Config {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.current_config;
    }

    // Configuration menu system
    pub const ConfigMenu = struct {
        allocator: std.mem.Allocator,
        dynamic_config: *DynamicConfig,
        visible: bool,
        selected_item: usize,
        items: []const MenuItem,

        const MenuItem = struct {
            name: []const u8,
            action: MenuAction,
        };

        const MenuAction = union(enum) {
            font_family: void,
            font_size: void,
            theme_selection: void,
            toggle_ligatures: void,
            toggle_kerning: void,
            zero_style: void,
            save_config: void,
            reload_config: void,
        };

        pub fn init(allocator: std.mem.Allocator, config: *DynamicConfig) ConfigMenu {
            const menu_items = [_]MenuItem{
                .{ .name = "Font Family", .action = .font_family },
                .{ .name = "Font Size", .action = .font_size },
                .{ .name = "Theme", .action = .theme_selection },
                .{ .name = "Toggle Ligatures", .action = .toggle_ligatures },
                .{ .name = "Toggle Kerning", .action = .toggle_kerning },
                .{ .name = "Zero Style", .action = .zero_style },
                .{ .name = "Save Config", .action = .save_config },
                .{ .name = "Reload Config", .action = .reload_config },
            };

            return ConfigMenu{
                .allocator = allocator,
                .dynamic_config = config,
                .visible = false,
                .selected_item = 0,
                .items = &menu_items,
            };
        }

        pub fn toggle(self: *ConfigMenu) void {
            self.visible = !self.visible;
        }

        pub fn handleKeyPress(self: *ConfigMenu, key: u8) !void {
            if (!self.visible) return;

            switch (key) {
                'j', 's' => { // Down
                    self.selected_item = (self.selected_item + 1) % self.items.len;
                },
                'k', 'w' => { // Up
                    self.selected_item = if (self.selected_item == 0) self.items.len - 1 else self.selected_item - 1;
                },
                '\n', '\r' => { // Enter
                    try self.executeAction(self.items[self.selected_item].action);
                },
                27 => { // Escape
                    self.visible = false;
                },
                else => {},
            }
        }

        fn executeAction(self: *ConfigMenu, action: MenuAction) !void {
            switch (action) {
                .toggle_ligatures => self.dynamic_config.toggleLigatures(),
                .save_config => try self.dynamic_config.saveConfig(),
                .reload_config => try self.dynamic_config.reloadConfig(),
                .theme_selection => try self.showThemeMenu(),
                else => {
                    // Other actions would show input dialogs
                    std.log.info("Action not yet implemented: {}", .{action});
                },
            }
        }

        fn showThemeMenu(self: *ConfigMenu) !void {
            const themes = [_][]const u8{
                "tokyo-night",
                "tokyo-night-storm",
                "solarized-dark",
                "catppuccin",
                "vibrant-dark",
            };

            // For now, just cycle through themes
            const current_theme = self.dynamic_config.getConfig().theme_name;
            var next_index: usize = 0;

            for (themes, 0..) |theme, i| {
                if (std.mem.eql(u8, current_theme, theme)) {
                    next_index = (i + 1) % themes.len;
                    break;
                }
            }

            try self.dynamic_config.setTheme(themes[next_index]);
        }

        pub fn render(self: *const ConfigMenu, writer: anytype) !void {
            if (!self.visible) return;

            try writer.writeAll("\x1b[2J\x1b[H"); // Clear screen and go to top
            try writer.writeAll("┌─ ZFont Configuration ─┐\n");

            const config = self.dynamic_config.getConfig();

            for (self.items, 0..) |item, i| {
                const selected = if (i == self.selected_item) "► " else "  ";

                switch (item.action) {
                    .font_family => try writer.print("{s}{s}: {s}\n", .{ selected, item.name, config.font_family }),
                    .font_size => try writer.print("{s}{s}: {d:.1}\n", .{ selected, item.name, config.font_size }),
                    .theme_selection => try writer.print("{s}{s}: {s}\n", .{ selected, item.name, config.theme_name }),
                    .toggle_ligatures => try writer.print("{s}{s}: {s}\n", .{ selected, item.name, if (config.enable_ligatures) "ON" else "OFF" }),
                    .toggle_kerning => try writer.print("{s}{s}: {s}\n", .{ selected, item.name, if (config.enable_kerning) "ON" else "OFF" }),
                    .zero_style => try writer.print("{s}{s}: {s}\n", .{ selected, item.name, @tagName(config.zero_style) }),
                    else => try writer.print("{s}{s}\n", .{ selected, item.name }),
                }
            }

            try writer.writeAll("└────────────────────────┘\n");
            try writer.writeAll("Use j/k or w/s to navigate, Enter to select, Esc to close\n");
        }
    };
};

// File watcher for automatic config reloading
pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    last_modified: i128,
    callback: *const fn () void,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, file_path: []const u8, callback: *const fn () void) !Self {
        const stat = try std.fs.cwd().statFile(file_path);

        return Self{
            .allocator = allocator,
            .file_path = try allocator.dupe(u8, file_path),
            .last_modified = stat.mtime,
            .callback = callback,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.file_path);
    }

    pub fn checkForChanges(self: *Self) !bool {
        const stat = std.fs.cwd().statFile(self.file_path) catch return false;

        if (stat.mtime > self.last_modified) {
            self.last_modified = stat.mtime;
            self.callback();
            return true;
        }

        return false;
    }
};

test "DynamicConfig basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const test_config_path = "/tmp/test_zfont_config.conf";

    // Clean up any existing test file
    std.fs.cwd().deleteFile(test_config_path) catch {};

    var config = DynamicConfig.init(allocator, test_config_path) catch return;
    defer config.deinit();

    // Test theme setting
    try config.setTheme("tokyo-night-storm");
    const current = config.getConfig();
    try testing.expect(std.mem.eql(u8, current.theme_name, "tokyo-night-storm"));

    // Clean up
    std.fs.cwd().deleteFile(test_config_path) catch {};
}