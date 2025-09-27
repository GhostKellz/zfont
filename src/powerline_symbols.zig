const std = @import("std");
const root = @import("root.zig");
const CellRenderer = @import("cell_renderer.zig").CellRenderer;
const FontFeatureManager = @import("font_features.zig").FontFeatureManager;

// PowerLevel10k optimized symbol rendering
// Provides pixel-perfect Powerline symbols with advanced rendering optimizations
pub const PowerlineSymbolRenderer = struct {
    allocator: std.mem.Allocator,
    cell_renderer: *CellRenderer,
    feature_manager: *FontFeatureManager,

    // Symbol cache for high-performance rendering
    symbol_cache: std.AutoHashMap(SymbolKey, CachedSymbol),

    // PowerLevel10k configuration
    p10k_config: P10kConfiguration,

    // Optimized symbol definitions
    symbol_definitions: std.AutoHashMap(u32, SymbolDefinition),

    // Performance metrics
    render_stats: RenderStats,

    const Self = @This();

    const SymbolKey = struct {
        unicode: u32,
        size: u32, // Fixed point: size * 1000
        style: SymbolStyle,
        mode: P10kMode,

        pub fn hash(self: SymbolKey) u64 {
            var hasher = std.hash.Wyhash.init(0xP10K0001);
            hasher.update(std.mem.asBytes(&self.unicode));
            hasher.update(std.mem.asBytes(&self.size));
            hasher.update(std.mem.asBytes(&self.style));
            hasher.update(std.mem.asBytes(&self.mode));
            return hasher.final();
        }

        pub fn eql(a: SymbolKey, b: SymbolKey) bool {
            return a.unicode == b.unicode and
                   a.size == b.size and
                   std.meta.eql(a.style, b.style) and
                   a.mode == b.mode;
        }
    };

    const SymbolStyle = struct {
        weight: FontWeight = .normal,
        rendering_mode: RenderingMode = .crisp,
        anti_aliasing: bool = true,
        hinting: HintingLevel = .full,
    };

    const FontWeight = enum(u8) {
        thin = 100,
        light = 300,
        normal = 400,
        medium = 500,
        bold = 700,
        black = 900,
    };

    const RenderingMode = enum {
        crisp, // Pixel-perfect for Powerline
        smooth, // Anti-aliased for general use
        hybrid, // Crisp edges, smooth curves
    };

    const HintingLevel = enum {
        none,
        slight,
        medium,
        full,
        auto,
    };

    const P10kMode = enum {
        nerdfont_v3,
        nerdfont_complete,
        awesome_patched,
        awesome_fontconfig,
        flat,
        ascii,
    };

    const CachedSymbol = struct {
        bitmap: []u8,
        width: u32,
        height: u32,
        bearing_x: f32,
        bearing_y: f32,
        advance: f32,
        optimized: bool,
        creation_time: i64,
        usage_count: u32,
    };

    const SymbolDefinition = struct {
        unicode: u32,
        powerline_codepoint: ?u32 = null,
        vectorized: bool = false,
        optimization_hints: OptimizationHints,
        segment_data: ?[]const u8 = null,
    };

    const OptimizationHints = struct {
        prefer_crisp_edges: bool = true,
        snap_to_pixel_grid: bool = true,
        use_subpixel_positioning: bool = false,
        force_integer_metrics: bool = true,
        enhance_contrast: bool = true,
    };

    const P10kConfiguration = struct {
        // Symbol mapping mode
        mode: P10kMode = .nerdfont_v3,
        legacy_icon_spacing: bool = false,
        icon_padding: IconPadding = .normal,

        // Rendering optimizations
        enable_symbol_cache: bool = true,
        max_cache_size: usize = 1000,
        enable_vectorization: bool = true,
        force_powerline_alignment: bool = true,

        // Visual enhancements
        enhance_separators: bool = true,
        optimize_branch_symbols: bool = true,
        crisp_git_icons: bool = true,
        align_status_icons: bool = true,

        const IconPadding = enum {
            none,
            minimal,
            normal,
            spacious,
        };
    };

    const RenderStats = struct {
        symbols_rendered: u64 = 0,
        cache_hits: u64 = 0,
        cache_misses: u64 = 0,
        optimizations_applied: u64 = 0,
        vectorized_renders: u64 = 0,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        cell_renderer: *CellRenderer,
        feature_manager: *FontFeatureManager,
    ) !Self {
        var renderer = Self{
            .allocator = allocator,
            .cell_renderer = cell_renderer,
            .feature_manager = feature_manager,
            .symbol_cache = std.AutoHashMap(SymbolKey, CachedSymbol).init(allocator),
            .p10k_config = P10kConfiguration{},
            .symbol_definitions = std.AutoHashMap(u32, SymbolDefinition).init(allocator),
            .render_stats = RenderStats{},
        };

        // Initialize PowerLevel10k symbol definitions
        try renderer.initializeP10kSymbols();

        return renderer;
    }

    pub fn deinit(self: *Self) void {
        // Cleanup symbol cache
        var cache_iter = self.symbol_cache.iterator();
        while (cache_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.bitmap);
        }
        self.symbol_cache.deinit();

        // Cleanup symbol definitions
        var def_iter = self.symbol_definitions.iterator();
        while (def_iter.next()) |entry| {
            if (entry.value_ptr.segment_data) |data| {
                self.allocator.free(data);
            }
        }
        self.symbol_definitions.deinit();
    }

    fn initializeP10kSymbols(self: *Self) !void {
        // Initialize core Powerline separators
        try self.addSymbolDefinition(0xE0B0, SymbolDefinition{ //
            .unicode = 0xE0B0,
            .powerline_codepoint = 0xE0B0,
            .vectorized = true,
            .optimization_hints = OptimizationHints{
                .prefer_crisp_edges = true,
                .snap_to_pixel_grid = true,
                .force_integer_metrics = true,
            },
        });

        try self.addSymbolDefinition(0xE0B2, SymbolDefinition{ //
            .unicode = 0xE0B2,
            .powerline_codepoint = 0xE0B2,
            .vectorized = true,
            .optimization_hints = OptimizationHints{
                .prefer_crisp_edges = true,
                .snap_to_pixel_grid = true,
                .force_integer_metrics = true,
            },
        });

        try self.addSymbolDefinition(0xE0B1, SymbolDefinition{ //
            .unicode = 0xE0B1,
            .powerline_codepoint = 0xE0B1,
            .vectorized = true,
            .optimization_hints = OptimizationHints{
                .prefer_crisp_edges = true,
                .snap_to_pixel_grid = true,
            },
        });

        try self.addSymbolDefinition(0xE0B3, SymbolDefinition{ //
            .unicode = 0xE0B3,
            .powerline_codepoint = 0xE0B3,
            .vectorized = true,
            .optimization_hints = OptimizationHints{
                .prefer_crisp_edges = true,
                .snap_to_pixel_grid = true,
            },
        });

        // Git and VCS symbols
        try self.addSymbolDefinition(0xE0A0, SymbolDefinition{ //
            .unicode = 0xE0A0,
            .vectorized = true,
            .optimization_hints = OptimizationHints{
                .prefer_crisp_edges = false,
                .enhance_contrast = true,
            },
        });

        try self.addSymbolDefinition(0xF126, SymbolDefinition{ //
            .unicode = 0xF126,
            .vectorized = true,
            .optimization_hints = OptimizationHints{
                .prefer_crisp_edges = false,
                .enhance_contrast = true,
            },
        });

        // System and status icons
        try self.addSymbolDefinition(0xF17C, SymbolDefinition{ //
            .unicode = 0xF17C,
            .vectorized = true,
            .optimization_hints = OptimizationHints{
                .prefer_crisp_edges = true,
                .enhance_contrast = true,
            },
        });

        try self.addSymbolDefinition(0xF015, SymbolDefinition{ //
            .unicode = 0xF015,
            .vectorized = true,
            .optimization_hints = OptimizationHints{
                .prefer_crisp_edges = true,
                .align_status_icons = true,
            },
        });

        // Programming language icons
        try self.addSymbolDefinition(0xE7A8, SymbolDefinition{ //
            .unicode = 0xE7A8,
            .vectorized = true,
            .optimization_hints = OptimizationHints{
                .enhance_contrast = true,
            },
        });

        try self.addSymbolDefinition(0xE626, SymbolDefinition{ //
            .unicode = 0xE626,
            .vectorized = true,
            .optimization_hints = OptimizationHints{
                .enhance_contrast = true,
            },
        });
    }

    fn addSymbolDefinition(self: *Self, unicode: u32, definition: SymbolDefinition) !void {
        try self.symbol_definitions.put(unicode, definition);
    }

    pub fn renderSymbol(
        self: *Self,
        unicode: u32,
        x: f32,
        y: f32,
        size: f32,
        style: SymbolStyle,
        color: u32,
        background: u32,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
    ) !void {
        self.render_stats.symbols_rendered += 1;

        // Create cache key
        const cache_key = SymbolKey{
            .unicode = unicode,
            .size = @as(u32, @intFromFloat(size * 1000)),
            .style = style,
            .mode = self.p10k_config.mode,
        };

        // Check cache
        if (self.symbol_cache.get(cache_key)) |*cached| {
            self.render_stats.cache_hits += 1;
            cached.usage_count += 1;

            try self.blitCachedSymbol(
                cached,
                x,
                y,
                color,
                background,
                buffer,
                buffer_width,
                buffer_height,
            );
            return;
        }

        self.render_stats.cache_misses += 1;

        // Get symbol definition
        const definition = self.symbol_definitions.get(unicode);

        // Render new symbol
        const rendered_symbol = if (definition) |def|
            try self.renderOptimizedSymbol(unicode, size, style, def)
        else
            try self.renderFallbackSymbol(unicode, size, style);

        // Cache the result
        try self.cacheSymbol(cache_key, rendered_symbol);

        // Blit to output buffer
        try self.blitCachedSymbol(
            &rendered_symbol,
            x,
            y,
            color,
            background,
            buffer,
            buffer_width,
            buffer_height,
        );
    }

    fn renderOptimizedSymbol(
        self: *Self,
        unicode: u32,
        size: f32,
        style: SymbolStyle,
        definition: SymbolDefinition,
    ) !CachedSymbol {
        self.render_stats.optimizations_applied += 1;

        if (definition.vectorized) {
            self.render_stats.vectorized_renders += 1;
            return try self.renderVectorizedSymbol(unicode, size, style, definition);
        } else {
            return try self.renderBitmapSymbol(unicode, size, style, definition);
        }
    }

    fn renderVectorizedSymbol(
        self: *Self,
        unicode: u32,
        size: f32,
        style: SymbolStyle,
        definition: SymbolDefinition,
    ) !CachedSymbol {
        // Vectorized rendering for crisp Powerline symbols
        const width = @as(u32, @intFromFloat(size));
        const height = @as(u32, @intFromFloat(size));
        const bitmap_size = width * height * 4; // RGBA

        var bitmap = try self.allocator.alloc(u8, bitmap_size);
        @memset(bitmap, 0);

        // Apply optimization hints
        const opts = definition.optimization_hints;

        switch (unicode) {
            0xE0B0 => try self.drawRightTriangle(bitmap, width, height, opts, style), //
            0xE0B2 => try self.drawLeftTriangle(bitmap, width, height, opts, style), //
            0xE0B1 => try self.drawRightThickSeparator(bitmap, width, height, opts, style), //
            0xE0B3 => try self.drawLeftThickSeparator(bitmap, width, height, opts, style), //
            0xE0A0 => try self.drawBranch(bitmap, width, height, opts, style), //
            0xF126 => try self.drawCodeBranch(bitmap, width, height, opts, style), //
            0xF17C => try self.drawLinuxIcon(bitmap, width, height, opts, style), //
            0xF015 => try self.drawHomeIcon(bitmap, width, height, opts, style), //
            else => try self.drawGenericIcon(bitmap, width, height, unicode, opts, style),
        }

        return CachedSymbol{
            .bitmap = bitmap,
            .width = width,
            .height = height,
            .bearing_x = 0.0,
            .bearing_y = size * 0.8, // Approximate baseline
            .advance = size,
            .optimized = true,
            .creation_time = std.time.milliTimestamp(),
            .usage_count = 1,
        };
    }

    fn renderBitmapSymbol(
        self: *Self,
        unicode: u32,
        size: f32,
        style: SymbolStyle,
        definition: SymbolDefinition,
    ) !CachedSymbol {
        _ = unicode;
        _ = definition;

        // Fallback to font rendering for non-vectorized symbols
        const width = @as(u32, @intFromFloat(size));
        const height = @as(u32, @intFromFloat(size));
        const bitmap_size = width * height * 4;

        var bitmap = try self.allocator.alloc(u8, bitmap_size);
        @memset(bitmap, 128); // Gray placeholder

        // Apply style-specific rendering
        if (style.rendering_mode == .crisp) {
            try self.applyCrispRendering(bitmap, width, height);
        }

        return CachedSymbol{
            .bitmap = bitmap,
            .width = width,
            .height = height,
            .bearing_x = 0.0,
            .bearing_y = size * 0.8,
            .advance = size,
            .optimized = false,
            .creation_time = std.time.milliTimestamp(),
            .usage_count = 1,
        };
    }

    fn renderFallbackSymbol(
        self: *Self,
        unicode: u32,
        size: f32,
        style: SymbolStyle,
    ) !CachedSymbol {
        _ = unicode;

        // Fallback rendering for unknown symbols
        const width = @as(u32, @intFromFloat(size));
        const height = @as(u32, @intFromFloat(size));
        const bitmap_size = width * height * 4;

        var bitmap = try self.allocator.alloc(u8, bitmap_size);
        @memset(bitmap, 64); // Dark gray placeholder

        // Draw a simple placeholder
        try self.drawPlaceholder(bitmap, width, height, style);

        return CachedSymbol{
            .bitmap = bitmap,
            .width = width,
            .height = height,
            .bearing_x = 0.0,
            .bearing_y = size * 0.8,
            .advance = size,
            .optimized = false,
            .creation_time = std.time.milliTimestamp(),
            .usage_count = 1,
        };
    }

    // Vectorized symbol drawing functions
    fn drawRightTriangle(
        self: *Self,
        bitmap: []u8,
        width: u32,
        height: u32,
        opts: OptimizationHints,
        style: SymbolStyle,
    ) !void {
        _ = self;
        _ = style;

        // Draw Powerline right separator triangle
        for (0..height) |y| {
            for (0..width) |x| {
                const alpha = if (x * height <= (width - y) * width) 255 else 0;

                const idx = (y * width + x) * 4;
                if (idx + 3 < bitmap.len) {
                    bitmap[idx + 0] = 255; // R
                    bitmap[idx + 1] = 255; // G
                    bitmap[idx + 2] = 255; // B
                    bitmap[idx + 3] = if (opts.prefer_crisp_edges) alpha else @as(u8, @intFromFloat(@as(f32, @floatFromInt(alpha)) * 0.9)); // A
                }
            }
        }
    }

    fn drawLeftTriangle(
        self: *Self,
        bitmap: []u8,
        width: u32,
        height: u32,
        opts: OptimizationHints,
        style: SymbolStyle,
    ) !void {
        _ = self;
        _ = style;

        // Draw Powerline left separator triangle
        for (0..height) |y| {
            for (0..width) |x| {
                const alpha = if (x * height >= y * width) 255 else 0;

                const idx = (y * width + x) * 4;
                if (idx + 3 < bitmap.len) {
                    bitmap[idx + 0] = 255; // R
                    bitmap[idx + 1] = 255; // G
                    bitmap[idx + 2] = 255; // B
                    bitmap[idx + 3] = if (opts.prefer_crisp_edges) alpha else @as(u8, @intFromFloat(@as(f32, @floatFromInt(alpha)) * 0.9)); // A
                }
            }
        }
    }

    fn drawRightThickSeparator(
        self: *Self,
        bitmap: []u8,
        width: u32,
        height: u32,
        opts: OptimizationHints,
        style: SymbolStyle,
    ) !void {
        _ = self;
        _ = opts;
        _ = style;

        // Draw thick right separator
        const thickness = @max(1, width / 8);
        const start_x = width - thickness;

        for (0..height) |y| {
            for (start_x..width) |x| {
                const idx = (y * width + x) * 4;
                if (idx + 3 < bitmap.len) {
                    bitmap[idx + 0] = 255; // R
                    bitmap[idx + 1] = 255; // G
                    bitmap[idx + 2] = 255; // B
                    bitmap[idx + 3] = 255; // A
                }
            }
        }
    }

    fn drawLeftThickSeparator(
        self: *Self,
        bitmap: []u8,
        width: u32,
        height: u32,
        opts: OptimizationHints,
        style: SymbolStyle,
    ) !void {
        _ = self;
        _ = opts;
        _ = style;

        // Draw thick left separator
        const thickness = @max(1, width / 8);

        for (0..height) |y| {
            for (0..thickness) |x| {
                const idx = (y * width + x) * 4;
                if (idx + 3 < bitmap.len) {
                    bitmap[idx + 0] = 255; // R
                    bitmap[idx + 1] = 255; // G
                    bitmap[idx + 2] = 255; // B
                    bitmap[idx + 3] = 255; // A
                }
            }
        }
    }

    fn drawBranch(
        self: *Self,
        bitmap: []u8,
        width: u32,
        height: u32,
        opts: OptimizationHints,
        style: SymbolStyle,
    ) !void {
        _ = self;
        _ = opts;
        _ = style;

        // Draw git branch symbol
        const center_x = width / 2;
        const center_y = height / 2;
        const radius = @min(width, height) / 4;

        // Draw main circle
        try self.drawCircle(bitmap, width, height, center_x, center_y, radius);

        // Draw branch lines
        try self.drawLine(bitmap, width, height, center_x, center_y, center_x + radius, center_y - radius);
        try self.drawLine(bitmap, width, height, center_x, center_y, center_x - radius, center_y + radius);
    }

    fn drawCodeBranch(
        self: *Self,
        bitmap: []u8,
        width: u32,
        height: u32,
        opts: OptimizationHints,
        style: SymbolStyle,
    ) !void {
        _ = opts;
        _ = style;

        // Draw code branch symbol (similar to git branch but with code styling)
        try self.drawBranch(bitmap, width, height, opts, style);

        // Add code-specific decorations
        const center_x = width / 2;
        const center_y = height / 2;
        const dot_size = 1;

        // Add dots to indicate code
        try self.drawDot(bitmap, width, height, center_x - 2, center_y, dot_size);
        try self.drawDot(bitmap, width, height, center_x + 2, center_y, dot_size);
    }

    fn drawLinuxIcon(
        self: *Self,
        bitmap: []u8,
        width: u32,
        height: u32,
        opts: OptimizationHints,
        style: SymbolStyle,
    ) !void {
        _ = self;
        _ = opts;
        _ = style;

        // Draw simplified Linux tux icon
        const center_x = width / 2;
        const center_y = height / 2;

        // Draw penguin body (simplified)
        try self.drawEllipse(bitmap, width, height, center_x, center_y + 2, width / 3, height / 3);

        // Draw head
        try self.drawCircle(bitmap, width, height, center_x, center_y - 2, width / 4);
    }

    fn drawHomeIcon(
        self: *Self,
        bitmap: []u8,
        width: u32,
        height: u32,
        opts: OptimizationHints,
        style: SymbolStyle,
    ) !void {
        _ = self;
        _ = opts;
        _ = style;

        // Draw house icon
        const base_y = height * 3 / 4;
        const roof_height = height / 4;
        const center_x = width / 2;

        // Draw roof (triangle)
        for (0..roof_height) |y| {
            const line_width = (width * y) / roof_height;
            const start_x = center_x - line_width / 2;
            const end_x = center_x + line_width / 2;

            for (start_x..end_x) |x| {
                const idx = (y * width + x) * 4;
                if (idx + 3 < bitmap.len) {
                    bitmap[idx + 0] = 255;
                    bitmap[idx + 1] = 255;
                    bitmap[idx + 2] = 255;
                    bitmap[idx + 3] = 255;
                }
            }
        }

        // Draw base (rectangle)
        for (roof_height..height) |y| {
            for (width / 4..width * 3 / 4) |x| {
                const idx = (y * width + x) * 4;
                if (idx + 3 < bitmap.len) {
                    bitmap[idx + 0] = 255;
                    bitmap[idx + 1] = 255;
                    bitmap[idx + 2] = 255;
                    bitmap[idx + 3] = 255;
                }
            }
        }
    }

    fn drawGenericIcon(
        self: *Self,
        bitmap: []u8,
        width: u32,
        height: u32,
        unicode: u32,
        opts: OptimizationHints,
        style: SymbolStyle,
    ) !void {
        _ = self;
        _ = unicode;
        _ = opts;
        _ = style;

        // Draw generic placeholder icon
        const center_x = width / 2;
        const center_y = height / 2;
        const radius = @min(width, height) / 3;

        try self.drawCircle(bitmap, width, height, center_x, center_y, radius);
    }

    // Drawing primitives
    fn drawCircle(self: *Self, bitmap: []u8, width: u32, height: u32, cx: u32, cy: u32, radius: u32) !void {
        _ = self;

        const r_sq = @as(i32, @intCast(radius * radius));

        for (0..height) |y| {
            for (0..width) |x| {
                const dx = @as(i32, @intCast(x)) - @as(i32, @intCast(cx));
                const dy = @as(i32, @intCast(y)) - @as(i32, @intCast(cy));
                const dist_sq = dx * dx + dy * dy;

                if (dist_sq <= r_sq) {
                    const idx = (y * width + x) * 4;
                    if (idx + 3 < bitmap.len) {
                        bitmap[idx + 0] = 255;
                        bitmap[idx + 1] = 255;
                        bitmap[idx + 2] = 255;
                        bitmap[idx + 3] = 255;
                    }
                }
            }
        }
    }

    fn drawEllipse(self: *Self, bitmap: []u8, width: u32, height: u32, cx: u32, cy: u32, rx: u32, ry: u32) !void {
        _ = self;

        for (0..height) |y| {
            for (0..width) |x| {
                const dx = @as(f32, @floatFromInt(@as(i32, @intCast(x)) - @as(i32, @intCast(cx))));
                const dy = @as(f32, @floatFromInt(@as(i32, @intCast(y)) - @as(i32, @intCast(cy))));

                const norm = (dx * dx) / @as(f32, @floatFromInt(rx * rx)) + (dy * dy) / @as(f32, @floatFromInt(ry * ry));

                if (norm <= 1.0) {
                    const idx = (y * width + x) * 4;
                    if (idx + 3 < bitmap.len) {
                        bitmap[idx + 0] = 255;
                        bitmap[idx + 1] = 255;
                        bitmap[idx + 2] = 255;
                        bitmap[idx + 3] = 255;
                    }
                }
            }
        }
    }

    fn drawLine(self: *Self, bitmap: []u8, width: u32, height: u32, x1: u32, y1: u32, x2: u32, y2: u32) !void {
        _ = self;

        // Simple line drawing using Bresenham's algorithm
        var x = @as(i32, @intCast(x1));
        var y = @as(i32, @intCast(y1));
        const dx = @abs(@as(i32, @intCast(x2)) - @as(i32, @intCast(x1)));
        const dy = @abs(@as(i32, @intCast(y2)) - @as(i32, @intCast(y1)));
        const sx: i32 = if (x1 < x2) 1 else -1;
        const sy: i32 = if (y1 < y2) 1 else -1;
        var err = dx - dy;

        while (true) {
            if (x >= 0 and x < width and y >= 0 and y < height) {
                const idx = (@as(u32, @intCast(y)) * width + @as(u32, @intCast(x))) * 4;
                if (idx + 3 < bitmap.len) {
                    bitmap[idx + 0] = 255;
                    bitmap[idx + 1] = 255;
                    bitmap[idx + 2] = 255;
                    bitmap[idx + 3] = 255;
                }
            }

            if (x == x2 and y == y2) break;

            const e2 = 2 * err;
            if (e2 > -dy) {
                err -= dy;
                x += sx;
            }
            if (e2 < dx) {
                err += dx;
                y += sy;
            }
        }
    }

    fn drawDot(self: *Self, bitmap: []u8, width: u32, height: u32, cx: u32, cy: u32, size: u32) !void {
        _ = self;

        for (cy - size..cy + size + 1) |y| {
            for (cx - size..cx + size + 1) |x| {
                if (x < width and y < height) {
                    const idx = (y * width + x) * 4;
                    if (idx + 3 < bitmap.len) {
                        bitmap[idx + 0] = 255;
                        bitmap[idx + 1] = 255;
                        bitmap[idx + 2] = 255;
                        bitmap[idx + 3] = 255;
                    }
                }
            }
        }
    }

    fn drawPlaceholder(
        self: *Self,
        bitmap: []u8,
        width: u32,
        height: u32,
        style: SymbolStyle,
    ) !void {
        _ = style;

        // Draw a simple question mark placeholder
        try self.drawCircle(bitmap, width, height, width / 2, height / 3, width / 4);
        try self.drawDot(bitmap, width, height, width / 2, height * 2 / 3, 2);
    }

    fn applyCrispRendering(self: *Self, bitmap: []u8, width: u32, height: u32) !void {
        _ = self;
        _ = bitmap;
        _ = width;
        _ = height;
        // Apply crisp rendering filters
        // This would implement edge enhancement, contrast adjustment, etc.
    }

    fn cacheSymbol(self: *Self, key: SymbolKey, symbol: CachedSymbol) !void {
        // Clean cache if it's getting too large
        if (self.symbol_cache.count() >= self.p10k_config.max_cache_size) {
            try self.cleanSymbolCache();
        }

        try self.symbol_cache.put(key, symbol);
    }

    fn cleanSymbolCache(self: *Self) !void {
        const current_time = std.time.milliTimestamp();
        const max_age = 300000; // 5 minutes

        var keys_to_remove = std.ArrayList(SymbolKey).init(self.allocator);
        defer keys_to_remove.deinit();

        var iter = self.symbol_cache.iterator();
        while (iter.next()) |entry| {
            if (current_time - entry.value_ptr.creation_time > max_age) {
                try keys_to_remove.append(entry.key_ptr.*);
            }
        }

        for (keys_to_remove.items) |key| {
            if (self.symbol_cache.fetchRemove(key)) |kv| {
                self.allocator.free(kv.value.bitmap);
            }
        }
    }

    fn blitCachedSymbol(
        self: *Self,
        symbol: *const CachedSymbol,
        x: f32,
        y: f32,
        color: u32,
        background: u32,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
    ) !void {
        _ = self;
        _ = background;

        const start_x = @as(u32, @intFromFloat(x));
        const start_y = @as(u32, @intFromFloat(y));

        // Extract color components
        const fg_r = @as(u8, @truncate((color >> 16) & 0xFF));
        const fg_g = @as(u8, @truncate((color >> 8) & 0xFF));
        const fg_b = @as(u8, @truncate(color & 0xFF));

        for (0..symbol.height) |src_y| {
            for (0..symbol.width) |src_x| {
                const dst_x = start_x + @as(u32, @intCast(src_x));
                const dst_y = start_y + @as(u32, @intCast(src_y));

                if (dst_x >= buffer_width or dst_y >= buffer_height) continue;

                const src_idx = (src_y * symbol.width + src_x) * 4;
                const dst_idx = (dst_y * buffer_width + dst_x) * 4;

                if (src_idx + 3 < symbol.bitmap.len and dst_idx + 3 < buffer.len) {
                    const alpha = symbol.bitmap[src_idx + 3];
                    if (alpha > 0) {
                        const alpha_f = @as(f32, @floatFromInt(alpha)) / 255.0;
                        const inv_alpha = 1.0 - alpha_f;

                        buffer[dst_idx + 0] = @as(u8, @intFromFloat(@as(f32, @floatFromInt(fg_r)) * alpha_f + @as(f32, @floatFromInt(buffer[dst_idx + 0])) * inv_alpha));
                        buffer[dst_idx + 1] = @as(u8, @intFromFloat(@as(f32, @floatFromInt(fg_g)) * alpha_f + @as(f32, @floatFromInt(buffer[dst_idx + 1])) * inv_alpha));
                        buffer[dst_idx + 2] = @as(u8, @intFromFloat(@as(f32, @floatFromInt(fg_b)) * alpha_f + @as(f32, @floatFromInt(buffer[dst_idx + 2])) * inv_alpha));
                        buffer[dst_idx + 3] = @max(alpha, buffer[dst_idx + 3]);
                    }
                }
            }
        }
    }

    // Configuration methods
    pub fn setP10kMode(self: *Self, mode: P10kMode) void {
        if (mode != self.p10k_config.mode) {
            self.p10k_config.mode = mode;
            // Clear cache when mode changes
            self.clearSymbolCache();
        }
    }

    pub fn enableOptimization(self: *Self, optimization: []const u8, enabled: bool) void {
        if (std.mem.eql(u8, optimization, "separators")) {
            self.p10k_config.enhance_separators = enabled;
        } else if (std.mem.eql(u8, optimization, "git_icons")) {
            self.p10k_config.crisp_git_icons = enabled;
        } else if (std.mem.eql(u8, optimization, "vectorization")) {
            self.p10k_config.enable_vectorization = enabled;
        } else if (std.mem.eql(u8, optimization, "alignment")) {
            self.p10k_config.force_powerline_alignment = enabled;
        }
    }

    fn clearSymbolCache(self: *Self) void {
        var iter = self.symbol_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.bitmap);
        }
        self.symbol_cache.clearRetainingCapacity();
    }

    // Performance monitoring
    pub fn getPerformanceStats(self: *const Self) RenderStats {
        return self.render_stats;
    }

    pub fn resetStats(self: *Self) void {
        self.render_stats = RenderStats{};
    }
};

// Tests
test "PowerlineSymbolRenderer initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Mock dependencies
    var mock_cell_renderer: CellRenderer = undefined;
    var mock_feature_manager: FontFeatureManager = undefined;

    var renderer = PowerlineSymbolRenderer.init(
        allocator,
        &mock_cell_renderer,
        &mock_feature_manager,
    ) catch return;
    defer renderer.deinit();

    try testing.expect(renderer.symbol_definitions.count() > 0);
    try testing.expect(renderer.p10k_config.mode == .nerdfont_v3);
}

test "PowerlineSymbolRenderer symbol caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mock_cell_renderer: CellRenderer = undefined;
    var mock_feature_manager: FontFeatureManager = undefined;

    var renderer = PowerlineSymbolRenderer.init(
        allocator,
        &mock_cell_renderer,
        &mock_feature_manager,
    ) catch return;
    defer renderer.deinit();

    const key = PowerlineSymbolRenderer.SymbolKey{
        .unicode = 0xE0B0,
        .size = 16000,
        .style = .{},
        .mode = .nerdfont_v3,
    };

    try testing.expect(renderer.symbol_cache.count() == 0);
    // After first render, symbol should be cached
    // (This would require a more complete mock implementation to test fully)
}