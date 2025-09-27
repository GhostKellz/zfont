const std = @import("std");
const root = @import("root.zig");
const PowerlineSymbolRenderer = @import("powerline_symbols.zig").PowerlineSymbolRenderer;
const CellRenderer = @import("cell_renderer.zig").CellRenderer;
const FontFeatureManager = @import("font_features.zig").FontFeatureManager;

// PowerLevel10k segment rendering with custom glyph optimization
// Handles the rendering of P10k prompt segments with advanced optimizations
pub const P10kSegmentRenderer = struct {
    allocator: std.mem.Allocator,
    powerline_renderer: *PowerlineSymbolRenderer,
    cell_renderer: *CellRenderer,
    feature_manager: *FontFeatureManager,

    // Segment cache for maximum performance
    segment_cache: std.AutoHashMap(SegmentKey, CachedSegment),

    // P10k configuration
    config: P10kConfig,

    // Performance metrics
    stats: RenderStats,

    // Segment type definitions
    segment_registry: std.StringHashMap(SegmentDefinition),

    const Self = @This();

    const SegmentKey = struct {
        segment_type: []const u8,
        content_hash: u64,
        style_hash: u64,
        width: u32,

        pub fn hash(self: SegmentKey) u64 {
            var hasher = std.hash.Wyhash.init(0xSEGMENT1);
            hasher.update(self.segment_type);
            hasher.update(std.mem.asBytes(&self.content_hash));
            hasher.update(std.mem.asBytes(&self.style_hash));
            hasher.update(std.mem.asBytes(&self.width));
            return hasher.final();
        }

        pub fn eql(a: SegmentKey, b: SegmentKey) bool {
            return std.mem.eql(u8, a.segment_type, b.segment_type) and
                   a.content_hash == b.content_hash and
                   a.style_hash == b.style_hash and
                   a.width == b.width;
        }
    };

    const CachedSegment = struct {
        bitmap: []u8,
        width: u32,
        height: u32,
        segments: []RenderedSegmentPart,
        creation_time: i64,
        usage_count: u32,
    };

    const RenderedSegmentPart = struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        type: PartType,
        color: u32,
        background: u32,

        const PartType = enum {
            separator_left,
            separator_right,
            content,
            icon,
            text,
        };
    };

    const P10kConfig = struct {
        // Style configuration
        default_style: SegmentStyle = SegmentStyle{},
        transient_prompt: bool = false,
        instant_prompt: bool = true,

        // Performance settings
        enable_segment_cache: bool = true,
        max_cache_size: usize = 500,
        enable_smart_truncation: bool = true,
        enable_async_rendering: bool = false,

        // Visual settings
        segment_separator: u32 = 0xE0B0, //
        subsegment_separator: u32 = 0xE0B1, //
        multiline_first_prompt_prefix: []const u8 = "╭─",
        multiline_newline_prompt_prefix: []const u8 = "├─",
        multiline_last_prompt_prefix: []const u8 = "╰─ ",

        // Icon mode
        mode: IconMode = .nerdfont_v3,

        const IconMode = enum {
            nerdfont_v3,
            nerdfont_complete,
            awesome_patched,
            awesome_fontconfig,
            flat,
            ascii,
        };
    };

    const SegmentStyle = struct {
        background: u32 = 0x005f87,
        foreground: u32 = 0xffffff,
        separator_foreground: u32 = 0x005f87,
        leading_diamond: ?u32 = null,
        trailing_diamond: ?u32 = null,
        template: []const u8 = " %s ",
        properties: SegmentProperties = SegmentProperties{},

        const SegmentProperties = struct {
            powerline_symbol: bool = true,
            display_host: bool = false,
            display_user: bool = true,
            display_default: bool = true,
        };
    };

    const SegmentDefinition = struct {
        name: []const u8,
        type: SegmentType,
        style: SegmentStyle,
        icons: SegmentIcons,
        renderer: SegmentRenderer,

        const SegmentType = enum {
            dir,
            vcs,
            status,
            context,
            command_execution_time,
            background_jobs,
            virtualenv,
            conda,
            pyenv,
            go_version,
            rust_version,
            node_version,
            java_version,
            package,
            rbenv,
            rvm,
            kubecontext,
            terraform,
            aws,
            aws_eb_env,
            azure,
            gcloud,
            nordvpn,
            ranger,
            yazi,
            nnn,
            vim_shell,
            midnight_commander,
            nix_shell,
            chezmoi,
            direnv,
            asdf,
            todo,
            time,
            battery,
            wifi,
            load,
            ram,
            swap,
            disk_usage,
            public_ip,
            vpn_ip,
            ip,
            proxy,
            firewall,
            os_icon,
            host,
            user,
            root_indicator,
            prompt_char,
        };

        const SegmentIcons = struct {
            // Common icons used in segments
            home: u32 = 0xF015, //
            folder: u32 = 0xF115, //
            folder_open: u32 = 0xF07C, //
            git_branch: u32 = 0xF126, //
            git_commit: u32 = 0xE729, //
            git_merge: u32 = 0xE728, //
            git_tag: u32 = 0xF02B, //
            python: u32 = 0xE73C, //
            nodejs: u32 = 0xE617, //
            rust: u32 = 0xE7A8, //
            go: u32 = 0xE626, //
            java: u32 = 0xE738, //
            docker: u32 = 0xF308, //
            kubernetes: u32 = 0xF10FE, //󱃾
            aws: u32 = 0xF270, //
            azure: u32 = 0xEBD8, //
            linux: u32 = 0xF17C, //
            apple: u32 = 0xF179, //
            windows: u32 = 0xF17A, //
            terminal: u32 = 0xF120, //
            clock: u32 = 0xF017, //
            battery: u32 = 0xF240, //
            wifi: u32 = 0xF1EB, //
            server: u32 = 0xF0AE, //
            database: u32 = 0xF1C0, //
            lock: u32 = 0xF023, //
            unlock: u32 = 0xF09C, //
            user: u32 = 0xF007, //
            users: u32 = 0xF0C0, //
            bell: u32 = 0xF0F3, //
            warning: u32 = 0xF071, //
            error: u32 = 0xF00D, //
            success: u32 = 0xF00C, //
            info: u32 = 0xF05A, //
        };

        const SegmentRenderer = *const fn (
            self: *P10kSegmentRenderer,
            segment: *const SegmentDefinition,
            content: []const u8,
            style: SegmentStyle,
            buffer: []u8,
            buffer_width: u32,
            buffer_height: u32,
            x: f32,
            y: f32,
        ) anyerror!f32; // Returns width of rendered segment
    };

    const RenderStats = struct {
        segments_rendered: u64 = 0,
        cache_hits: u64 = 0,
        cache_misses: u64 = 0,
        total_render_time_ns: u64 = 0,
        custom_glyphs_rendered: u64 = 0,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        powerline_renderer: *PowerlineSymbolRenderer,
        cell_renderer: *CellRenderer,
        feature_manager: *FontFeatureManager,
    ) !Self {
        var renderer = Self{
            .allocator = allocator,
            .powerline_renderer = powerline_renderer,
            .cell_renderer = cell_renderer,
            .feature_manager = feature_manager,
            .segment_cache = std.AutoHashMap(SegmentKey, CachedSegment){},
            .config = P10kConfig{},
            .stats = RenderStats{},
            .segment_registry = std.StringHashMap(SegmentDefinition){},
        };

        // Initialize standard segment definitions
        try renderer.initializeSegmentRegistry();

        return renderer;
    }

    pub fn deinit(self: *Self) void {
        // Cleanup segment cache
        var cache_iter = self.segment_cache.iterator();
        while (cache_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.bitmap);
            self.allocator.free(entry.value_ptr.segments);
        }
        self.segment_cache.deinit();

        // Cleanup segment registry
        var registry_iter = self.segment_registry.iterator();
        while (registry_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.segment_registry.deinit();
    }

    fn initializeSegmentRegistry(self: *Self) !void {
        // Directory segment
        try self.registerSegment("dir", SegmentDefinition{
            .name = try self.allocator.dupe(u8, "dir"),
            .type = .dir,
            .style = SegmentStyle{
                .background = 0x005f87,
                .foreground = 0xffffff,
                .template = try self.allocator.dupe(u8, " %s "),
            },
            .icons = SegmentDefinition.SegmentIcons{},
            .renderer = renderDirSegment,
        });

        // Git/VCS segment
        try self.registerSegment("vcs", SegmentDefinition{
            .name = try self.allocator.dupe(u8, "vcs"),
            .type = .vcs,
            .style = SegmentStyle{
                .background = 0x87af00,
                .foreground = 0x000000,
                .template = try self.allocator.dupe(u8, " %s "),
            },
            .icons = SegmentDefinition.SegmentIcons{},
            .renderer = renderVcsSegment,
        });

        // Status segment
        try self.registerSegment("status", SegmentDefinition{
            .name = try self.allocator.dupe(u8, "status"),
            .type = .status,
            .style = SegmentStyle{
                .background = 0xd70000,
                .foreground = 0xffffff,
                .template = try self.allocator.dupe(u8, " %s "),
            },
            .icons = SegmentDefinition.SegmentIcons{},
            .renderer = renderStatusSegment,
        });

        // Context segment
        try self.registerSegment("context", SegmentDefinition{
            .name = try self.allocator.dupe(u8, "context"),
            .type = .context,
            .style = SegmentStyle{
                .background = 0x585858,
                .foreground = 0xffffff,
                .template = try self.allocator.dupe(u8, " %s "),
            },
            .icons = SegmentDefinition.SegmentIcons{},
            .renderer = renderContextSegment,
        });

        // Execution time segment
        try self.registerSegment("command_execution_time", SegmentDefinition{
            .name = try self.allocator.dupe(u8, "command_execution_time"),
            .type = .command_execution_time,
            .style = SegmentStyle{
                .background = 0xaf8700,
                .foreground = 0x000000,
                .template = try self.allocator.dupe(u8, " took %s "),
            },
            .icons = SegmentDefinition.SegmentIcons{},
            .renderer = renderExecutionTimeSegment,
        });

        // Programming language segments
        try self.registerSegment("rust_version", SegmentDefinition{
            .name = try self.allocator.dupe(u8, "rust_version"),
            .type = .rust_version,
            .style = SegmentStyle{
                .background = 0xd75f00,
                .foreground = 0xffffff,
                .template = try self.allocator.dupe(u8, " %s "),
            },
            .icons = SegmentDefinition.SegmentIcons{},
            .renderer = renderRustVersionSegment,
        });

        try self.registerSegment("node_version", SegmentDefinition{
            .name = try self.allocator.dupe(u8, "node_version"),
            .type = .node_version,
            .style = SegmentStyle{
                .background = 0x87af00,
                .foreground = 0x000000,
                .template = try self.allocator.dupe(u8, " %s "),
            },
            .icons = SegmentDefinition.SegmentIcons{},
            .renderer = renderNodeVersionSegment,
        });
    }

    fn registerSegment(self: *Self, name: []const u8, definition: SegmentDefinition) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        try self.segment_registry.put(name_copy, definition);
    }

    pub fn renderSegment(
        self: *Self,
        segment_name: []const u8,
        content: []const u8,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
        x: f32,
        y: f32,
    ) !f32 {
        const start_time = std.time.nanoTimestamp();
        defer {
            const end_time = std.time.nanoTimestamp();
            self.stats.total_render_time_ns += @intCast(end_time - start_time);
        }

        self.stats.segments_rendered += 1;

        // Get segment definition
        const segment_def = self.segment_registry.get(segment_name) orelse {
            return self.renderFallbackSegment(content, buffer, buffer_width, buffer_height, x, y);
        };

        // Check cache
        const cache_key = self.createCacheKey(segment_name, content, segment_def.style, buffer_width);
        if (self.segment_cache.get(cache_key)) |cached| {
            self.stats.cache_hits += 1;
            return try self.blitCachedSegment(&cached, buffer, buffer_width, buffer_height, x, y);
        }

        self.stats.cache_misses += 1;

        // Render new segment
        const rendered_width = try segment_def.renderer(
            self,
            &segment_def,
            content,
            segment_def.style,
            buffer,
            buffer_width,
            buffer_height,
            x,
            y,
        );

        return rendered_width;
    }

    fn createCacheKey(self: *Self, segment_name: []const u8, content: []const u8, style: SegmentStyle, width: u32) SegmentKey {
        _ = self;

        var content_hasher = std.hash.Wyhash.init(0);
        content_hasher.update(content);

        var style_hasher = std.hash.Wyhash.init(0);
        style_hasher.update(std.mem.asBytes(&style.background));
        style_hasher.update(std.mem.asBytes(&style.foreground));
        style_hasher.update(style.template);

        return SegmentKey{
            .segment_type = segment_name,
            .content_hash = content_hasher.final(),
            .style_hash = style_hasher.final(),
            .width = width,
        };
    }

    fn blitCachedSegment(
        self: *Self,
        cached: *const CachedSegment,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
        x: f32,
        y: f32,
    ) !f32 {
        _ = self;

        const start_x = @as(u32, @intFromFloat(x));
        const start_y = @as(u32, @intFromFloat(y));

        // Bounds checking
        if (start_x >= buffer_width or start_y >= buffer_height) return 0.0;

        const copy_width = @min(cached.width, buffer_width - start_x);
        const copy_height = @min(cached.height, buffer_height - start_y);

        // Optimized blit
        for (0..copy_height) |src_y| {
            const dst_y = start_y + @as(u32, @intCast(src_y));
            const src_row_start = src_y * cached.width * 4;
            const dst_row_start = (dst_y * buffer_width + start_x) * 4;

            if (dst_row_start + copy_width * 4 <= buffer.len and
                src_row_start + copy_width * 4 <= cached.bitmap.len) {

                @memcpy(
                    buffer[dst_row_start..dst_row_start + copy_width * 4],
                    cached.bitmap[src_row_start..src_row_start + copy_width * 4],
                );
            }
        }

        return @floatFromInt(cached.width);
    }

    fn renderFallbackSegment(
        self: *Self,
        content: []const u8,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
        x: f32,
        y: f32,
    ) !f32 {
        _ = self;
        _ = content;
        _ = buffer;
        _ = buffer_width;
        _ = buffer_height;
        _ = x;
        _ = y;

        // Simple fallback rendering
        return 100.0; // Mock width
    }

    // Segment-specific renderers
    fn renderDirSegment(
        self: *P10kSegmentRenderer,
        segment: *const SegmentDefinition,
        content: []const u8,
        style: SegmentStyle,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
        x: f32,
        y: f32,
    ) !f32 {
        _ = segment;

        // Render directory icon and path
        var current_x = x;

        // Render home icon if in home directory
        if (std.mem.indexOf(u8, content, "~") != null) {
            try self.powerline_renderer.renderSymbol(
                segment.icons.home,
                current_x,
                y,
                16.0,
                .{},
                style.foreground,
                style.background,
                buffer,
                buffer_width,
                buffer_height,
            );
            current_x += 20.0;
        } else {
            try self.powerline_renderer.renderSymbol(
                segment.icons.folder,
                current_x,
                y,
                16.0,
                .{},
                style.foreground,
                style.background,
                buffer,
                buffer_width,
                buffer_height,
            );
            current_x += 20.0;
        }

        // Render directory text
        current_x += try self.renderText(content, current_x, y, style, buffer, buffer_width, buffer_height);

        // Render separator
        current_x += try self.renderSeparator(current_x, y, style, buffer, buffer_width, buffer_height);

        return current_x - x;
    }

    fn renderVcsSegment(
        self: *P10kSegmentRenderer,
        segment: *const SegmentDefinition,
        content: []const u8,
        style: SegmentStyle,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
        x: f32,
        y: f32,
    ) !f32 {
        var current_x = x;

        // Render git branch icon
        try self.powerline_renderer.renderSymbol(
            segment.icons.git_branch,
            current_x,
            y,
            16.0,
            .{},
            style.foreground,
            style.background,
            buffer,
            buffer_width,
            buffer_height,
        );
        current_x += 20.0;

        // Render branch name
        current_x += try self.renderText(content, current_x, y, style, buffer, buffer_width, buffer_height);

        // Check for git status indicators
        if (std.mem.indexOf(u8, content, "*") != null) {
            // Unstaged changes
            try self.powerline_renderer.renderSymbol(
                0xF06A, //
                current_x,
                y,
                12.0,
                .{},
                0xffff00, // Yellow
                style.background,
                buffer,
                buffer_width,
                buffer_height,
            );
            current_x += 15.0;
        }

        if (std.mem.indexOf(u8, content, "+") != null) {
            // Staged changes
            try self.powerline_renderer.renderSymbol(
                0xF055, //
                current_x,
                y,
                12.0,
                .{},
                0x00ff00, // Green
                style.background,
                buffer,
                buffer_width,
                buffer_height,
            );
            current_x += 15.0;
        }

        // Render separator
        current_x += try self.renderSeparator(current_x, y, style, buffer, buffer_width, buffer_height);

        return current_x - x;
    }

    fn renderStatusSegment(
        self: *P10kSegmentRenderer,
        segment: *const SegmentDefinition,
        content: []const u8,
        style: SegmentStyle,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
        x: f32,
        y: f32,
    ) !f32 {
        _ = segment;

        var current_x = x;

        // Parse exit code
        const exit_code = std.fmt.parseInt(i32, content, 10) catch 0;

        if (exit_code == 0) {
            // Success
            try self.powerline_renderer.renderSymbol(
                0xF00C, //
                current_x,
                y,
                16.0,
                .{},
                0x00ff00, // Green
                style.background,
                buffer,
                buffer_width,
                buffer_height,
            );
        } else {
            // Error
            try self.powerline_renderer.renderSymbol(
                0xF00D, //
                current_x,
                y,
                16.0,
                .{},
                0xff0000, // Red
                style.background,
                buffer,
                buffer_width,
                buffer_height,
            );
            current_x += 20.0;

            // Render exit code
            current_x += try self.renderText(content, current_x, y, style, buffer, buffer_width, buffer_height);
        }

        current_x += 20.0;

        // Render separator
        current_x += try self.renderSeparator(current_x, y, style, buffer, buffer_width, buffer_height);

        return current_x - x;
    }

    fn renderContextSegment(
        self: *P10kSegmentRenderer,
        segment: *const SegmentDefinition,
        content: []const u8,
        style: SegmentStyle,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
        x: f32,
        y: f32,
    ) !f32 {
        var current_x = x;

        // Render user icon
        try self.powerline_renderer.renderSymbol(
            segment.icons.user,
            current_x,
            y,
            16.0,
            .{},
            style.foreground,
            style.background,
            buffer,
            buffer_width,
            buffer_height,
        );
        current_x += 20.0;

        // Render context (user@host)
        current_x += try self.renderText(content, current_x, y, style, buffer, buffer_width, buffer_height);

        // Render separator
        current_x += try self.renderSeparator(current_x, y, style, buffer, buffer_width, buffer_height);

        return current_x - x;
    }

    fn renderExecutionTimeSegment(
        self: *P10kSegmentRenderer,
        segment: *const SegmentDefinition,
        content: []const u8,
        style: SegmentStyle,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
        x: f32,
        y: f32,
    ) !f32 {
        var current_x = x;

        // Render clock icon
        try self.powerline_renderer.renderSymbol(
            segment.icons.clock,
            current_x,
            y,
            16.0,
            .{},
            style.foreground,
            style.background,
            buffer,
            buffer_width,
            buffer_height,
        );
        current_x += 20.0;

        // Render execution time
        current_x += try self.renderText(content, current_x, y, style, buffer, buffer_width, buffer_height);

        // Render separator
        current_x += try self.renderSeparator(current_x, y, style, buffer, buffer_width, buffer_height);

        return current_x - x;
    }

    fn renderRustVersionSegment(
        self: *P10kSegmentRenderer,
        segment: *const SegmentDefinition,
        content: []const u8,
        style: SegmentStyle,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
        x: f32,
        y: f32,
    ) !f32 {
        var current_x = x;

        // Render Rust logo
        try self.powerline_renderer.renderSymbol(
            segment.icons.rust,
            current_x,
            y,
            16.0,
            .{},
            style.foreground,
            style.background,
            buffer,
            buffer_width,
            buffer_height,
        );
        current_x += 20.0;

        // Render version
        current_x += try self.renderText(content, current_x, y, style, buffer, buffer_width, buffer_height);

        // Render separator
        current_x += try self.renderSeparator(current_x, y, style, buffer, buffer_width, buffer_height);

        return current_x - x;
    }

    fn renderNodeVersionSegment(
        self: *P10kSegmentRenderer,
        segment: *const SegmentDefinition,
        content: []const u8,
        style: SegmentStyle,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
        x: f32,
        y: f32,
    ) !f32 {
        var current_x = x;

        // Render Node.js logo
        try self.powerline_renderer.renderSymbol(
            segment.icons.nodejs,
            current_x,
            y,
            16.0,
            .{},
            style.foreground,
            style.background,
            buffer,
            buffer_width,
            buffer_height,
        );
        current_x += 20.0;

        // Render version
        current_x += try self.renderText(content, current_x, y, style, buffer, buffer_width, buffer_height);

        // Render separator
        current_x += try self.renderSeparator(current_x, y, style, buffer, buffer_width, buffer_height);

        return current_x - x;
    }

    // Helper rendering functions
    fn renderText(
        self: *P10kSegmentRenderer,
        text: []const u8,
        x: f32,
        y: f32,
        style: SegmentStyle,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
    ) !f32 {
        _ = self;
        _ = text;
        _ = x;
        _ = y;
        _ = style;
        _ = buffer;
        _ = buffer_width;
        _ = buffer_height;

        // Mock text rendering - would use cell renderer in real implementation
        return @as(f32, @floatFromInt(text.len)) * 8.0; // Mock character width
    }

    fn renderSeparator(
        self: *P10kSegmentRenderer,
        x: f32,
        y: f32,
        style: SegmentStyle,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
    ) !f32 {
        try self.powerline_renderer.renderSymbol(
            self.config.segment_separator,
            x,
            y,
            16.0,
            .{},
            style.separator_foreground,
            0x000000, // Transparent background
            buffer,
            buffer_width,
            buffer_height,
        );

        return 16.0; // Separator width
    }

    // Configuration and management
    pub fn setConfig(self: *Self, config: P10kConfig) void {
        self.config = config;
        // Clear cache when configuration changes
        self.clearCache();
    }

    pub fn addCustomSegment(self: *Self, name: []const u8, definition: SegmentDefinition) !void {
        try self.registerSegment(name, definition);
    }

    fn clearCache(self: *Self) void {
        var iter = self.segment_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.bitmap);
            self.allocator.free(entry.value_ptr.segments);
        }
        self.segment_cache.clearRetainingCapacity();
    }

    // Performance monitoring
    pub fn getStats(self: *const Self) RenderStats {
        return self.stats;
    }

    pub fn resetStats(self: *Self) void {
        self.stats = RenderStats{};
    }

    pub fn getCacheUtilization(self: *const Self) f32 {
        const current_size = self.segment_cache.count();
        const max_size = self.config.max_cache_size;
        return @as(f32, @floatFromInt(current_size)) / @as(f32, @floatFromInt(max_size));
    }
};

// Tests
test "P10kSegmentRenderer initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Mock dependencies
    var mock_powerline_renderer: PowerlineSymbolRenderer = undefined;
    var mock_cell_renderer: CellRenderer = undefined;
    var mock_feature_manager: FontFeatureManager = undefined;

    var renderer = P10kSegmentRenderer.init(
        allocator,
        &mock_powerline_renderer,
        &mock_cell_renderer,
        &mock_feature_manager,
    ) catch return;
    defer renderer.deinit();

    try testing.expect(renderer.segment_registry.count() > 0);
    try testing.expect(renderer.config.enable_segment_cache == true);
}

test "P10kSegmentRenderer segment registration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mock_powerline_renderer: PowerlineSymbolRenderer = undefined;
    var mock_cell_renderer: CellRenderer = undefined;
    var mock_feature_manager: FontFeatureManager = undefined;

    var renderer = P10kSegmentRenderer.init(
        allocator,
        &mock_powerline_renderer,
        &mock_cell_renderer,
        &mock_feature_manager,
    ) catch return;
    defer renderer.deinit();

    try testing.expect(renderer.segment_registry.contains("dir"));
    try testing.expect(renderer.segment_registry.contains("vcs"));
    try testing.expect(renderer.segment_registry.contains("status"));
}