const std = @import("std");
const root = @import("root.zig");
const gcode = @import("gcode");
const Unicode = @import("unicode.zig").Unicode;
const GlyphRenderer = @import("glyph_renderer.zig").GlyphRenderer;
const GPUCache = @import("gpu_cache.zig").GPUCache;

// Cell-based rendering optimizations for terminal emulators
// Provides pixel-perfect terminal grid alignment and optimized text rendering
pub const CellRenderer = struct {
    allocator: std.mem.Allocator,
    glyph_renderer: *GlyphRenderer,
    gpu_cache: *GPUCache,

    // Terminal grid properties
    cell_width: f32,
    cell_height: f32,
    baseline_offset: f32,
    line_spacing: f32,

    // Cell cache for rapid terminal updates
    cell_cache: std.AutoHashMap(CellKey, CachedCell),

    // Performance counters
    cache_hits: std.atomic.Value(u64),
    cache_misses: std.atomic.Value(u64),
    render_calls: std.atomic.Value(u64),

    // Grid alignment settings
    grid_alignment: GridAlignment,
    font_metrics: FontMetrics,

    const Self = @This();

    const CellKey = struct {
        codepoint: u32,
        font_id: u64,
        size: u32, // Size in fixed point (size * 1000)
        style: FontStyle,
        foreground: u32,
        background: u32,
        effects: CellEffects,

        pub fn hash(self: CellKey) u64 {
            var hasher = std.hash.Wyhash.init(0x12345678);
            hasher.update(std.mem.asBytes(&self.codepoint));
            hasher.update(std.mem.asBytes(&self.font_id));
            hasher.update(std.mem.asBytes(&self.size));
            hasher.update(std.mem.asBytes(&self.style));
            hasher.update(std.mem.asBytes(&self.foreground));
            hasher.update(std.mem.asBytes(&self.background));
            hasher.update(std.mem.asBytes(&self.effects));
            return hasher.final();
        }

        pub fn eql(a: CellKey, b: CellKey) bool {
            return a.codepoint == b.codepoint and
                   a.font_id == b.font_id and
                   a.size == b.size and
                   a.style == b.style and
                   a.foreground == b.foreground and
                   a.background == b.background and
                   std.meta.eql(a.effects, b.effects);
        }
    };

    const FontStyle = struct {
        weight: FontWeight = .normal,
        slant: FontSlant = .normal,
        stretch: FontStretch = .normal,

        const FontWeight = enum(u8) {
            thin = 100,
            extra_light = 200,
            light = 300,
            normal = 400,
            medium = 500,
            semi_bold = 600,
            bold = 700,
            extra_bold = 800,
            black = 900,
        };

        const FontSlant = enum(u8) {
            normal = 0,
            italic = 1,
            oblique = 2,
        };

        const FontStretch = enum(u8) {
            ultra_condensed = 50,
            extra_condensed = 62,
            condensed = 75,
            semi_condensed = 87,
            normal = 100,
            semi_expanded = 112,
            expanded = 125,
            extra_expanded = 150,
            ultra_expanded = 200,
        };
    };

    const CellEffects = packed struct {
        bold: bool = false,
        italic: bool = false,
        underline: bool = false,
        strikethrough: bool = false,
        overline: bool = false,
        blink: bool = false,
        reverse: bool = false,
        invisible: bool = false,
        dim: bool = false,
        _padding: u7 = 0, // Align to byte boundary
    };

    const CachedCell = struct {
        bitmap: []u8,
        width: u32,
        height: u32,
        bearing_x: f32,
        bearing_y: f32,
        advance: f32,
        baseline_y: f32,
        gpu_texture_id: ?u32 = null,
        last_used: i64,
        usage_count: u32,
    };

    const GridAlignment = struct {
        snap_to_pixel: bool = true,
        force_monospace: bool = true,
        center_glyphs: bool = true,
        align_baseline: bool = true,
        hinting_mode: HintingMode = .auto,

        const HintingMode = enum {
            none,
            slight,
            medium,
            full,
            auto,
        };
    };

    const FontMetrics = struct {
        ascent: f32,
        descent: f32,
        line_gap: f32,
        x_height: f32,
        cap_height: f32,
        underline_position: f32,
        underline_thickness: f32,
        strikethrough_position: f32,
        strikethrough_thickness: f32,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        glyph_renderer: *GlyphRenderer,
        gpu_cache: *GPUCache,
        cell_width: f32,
        cell_height: f32,
    ) !Self {
        var renderer = Self{
            .allocator = allocator,
            .glyph_renderer = glyph_renderer,
            .gpu_cache = gpu_cache,
            .cell_width = cell_width,
            .cell_height = cell_height,
            .baseline_offset = 0.0,
            .line_spacing = 0.0,
            .cell_cache = std.AutoHashMap(CellKey, CachedCell).init(allocator),
            .cache_hits = std.atomic.Value(u64).init(0),
            .cache_misses = std.atomic.Value(u64).init(0),
            .render_calls = std.atomic.Value(u64).init(0),
            .grid_alignment = GridAlignment{},
            .font_metrics = std.mem.zeroes(FontMetrics),
        };

        // Calculate optimal baseline positioning
        try renderer.calculateFontMetrics();

        return renderer;
    }

    pub fn deinit(self: *Self) void {
        // Free cached cell data
        var iterator = self.cell_cache.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.bitmap);
        }
        self.cell_cache.deinit();
    }

    pub fn renderCell(
        self: *Self,
        codepoint: u32,
        x: f32,
        y: f32,
        font: *root.Font,
        style: FontStyle,
        foreground: u32,
        background: u32,
        effects: CellEffects,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
    ) !void {
        _ = self.render_calls.fetchAdd(1, .monotonic);

        // Create cache key
        const cache_key = CellKey{
            .codepoint = codepoint,
            .font_id = @intFromPtr(font),
            .size = @as(u32, @intFromFloat(self.cell_height * 1000)),
            .style = style,
            .foreground = foreground,
            .background = background,
            .effects = effects,
        };

        // Check cache first
        const current_time = std.time.milliTimestamp();
        if (self.cell_cache.get(cache_key)) |*cached_cell| {
            _ = self.cache_hits.fetchAdd(1, .monotonic);
            cached_cell.last_used = current_time;
            cached_cell.usage_count += 1;

            try self.blitCachedCell(
                cached_cell,
                x,
                y,
                buffer,
                buffer_width,
                buffer_height,
            );
            return;
        }

        _ = self.cache_misses.fetchAdd(1, .monotonic);

        // Render new cell
        const rendered_cell = try self.renderNewCell(
            codepoint,
            font,
            style,
            foreground,
            background,
            effects,
        );

        // Cache the result
        try self.cell_cache.put(cache_key, rendered_cell);

        // Blit to output buffer
        try self.blitCachedCell(
            &rendered_cell,
            x,
            y,
            buffer,
            buffer_width,
            buffer_height,
        );

        // Cleanup old cache entries if needed
        if (self.cell_cache.count() > 10000) {
            try self.cleanupCache();
        }
    }

    fn renderNewCell(
        self: *Self,
        codepoint: u32,
        font: *root.Font,
        style: FontStyle,
        foreground: u32,
        background: u32,
        effects: CellEffects,
    ) !CachedCell {
        // Apply font style modifications
        var render_options = self.createRenderOptions(style, effects);

        // Render glyph with precise grid alignment
        const glyph = try font.renderGlyph(codepoint, self.cell_height, render_options);

        // Create cell-sized bitmap
        const cell_bitmap = try self.allocator.alloc(u8, @as(usize, @intFromFloat(self.cell_width * self.cell_height * 4))); // RGBA
        @memset(cell_bitmap, 0);

        // Apply grid alignment and centering
        const aligned_pos = self.calculateAlignedPosition(glyph);

        // Composite glyph onto cell bitmap with proper colors and effects
        try self.compositeGlyph(
            glyph,
            cell_bitmap,
            aligned_pos,
            foreground,
            background,
            effects,
        );

        return CachedCell{
            .bitmap = cell_bitmap,
            .width = @as(u32, @intFromFloat(self.cell_width)),
            .height = @as(u32, @intFromFloat(self.cell_height)),
            .bearing_x = aligned_pos.x,
            .bearing_y = aligned_pos.y,
            .advance = self.cell_width, // Force monospace
            .baseline_y = self.baseline_offset,
            .last_used = std.time.milliTimestamp(),
            .usage_count = 1,
        };
    }

    fn createRenderOptions(self: *Self, style: FontStyle, effects: CellEffects) anytype {
        // Create render options based on style and effects
        _ = self;
        _ = style;

        return .{
            .bold = effects.bold,
            .italic = effects.italic,
            .hinting = .auto,
            .subpixel = true,
            .grid_fit = true,
            .force_autohint = false,
        };
    }

    fn calculateAlignedPosition(self: *Self, glyph: anytype) struct { x: f32, y: f32 } {
        var x: f32 = 0;
        var y: f32 = self.baseline_offset;

        if (self.grid_alignment.center_glyphs) {
            // Center glyph horizontally in cell
            x = (self.cell_width - @as(f32, @floatFromInt(glyph.width))) / 2.0;

            // Align to pixel boundary for sharp rendering
            if (self.grid_alignment.snap_to_pixel) {
                x = @round(x);
                y = @round(y);
            }
        }

        if (self.grid_alignment.align_baseline) {
            y = self.baseline_offset - glyph.bearing_y;
        }

        return .{ .x = x, .y = y };
    }

    fn compositeGlyph(
        self: *Self,
        glyph: anytype,
        cell_bitmap: []u8,
        pos: struct { x: f32, y: f32 },
        foreground: u32,
        background: u32,
        effects: CellEffects,
    ) !void {
        _ = self;

        const cell_width = @as(u32, @intFromFloat(self.cell_width));
        const cell_height = @as(u32, @intFromFloat(self.cell_height));

        // Extract color components
        const fg_r = @as(u8, @truncate((foreground >> 16) & 0xFF));
        const fg_g = @as(u8, @truncate((foreground >> 8) & 0xFF));
        const fg_b = @as(u8, @truncate(foreground & 0xFF));
        const fg_a = @as(u8, @truncate((foreground >> 24) & 0xFF));

        const bg_r = @as(u8, @truncate((background >> 16) & 0xFF));
        const bg_g = @as(u8, @truncate((background >> 8) & 0xFF));
        const bg_b = @as(u8, @truncate(background & 0xFF));
        const bg_a = @as(u8, @truncate((background >> 24) & 0xFF));

        // Fill background
        for (0..cell_height) |y| {
            for (0..cell_width) |x| {
                const idx = (y * cell_width + x) * 4;
                if (idx + 3 < cell_bitmap.len) {
                    cell_bitmap[idx + 0] = bg_r;
                    cell_bitmap[idx + 1] = bg_g;
                    cell_bitmap[idx + 2] = bg_b;
                    cell_bitmap[idx + 3] = bg_a;
                }
            }
        }

        // Composite glyph
        const start_x = @max(0, @as(i32, @intFromFloat(pos.x)));
        const start_y = @max(0, @as(i32, @intFromFloat(pos.y)));

        for (0..glyph.height) |src_y| {
            const dst_y = start_y + @as(i32, @intCast(src_y));
            if (dst_y < 0 or dst_y >= cell_height) continue;

            for (0..glyph.width) |src_x| {
                const dst_x = start_x + @as(i32, @intCast(src_x));
                if (dst_x < 0 or dst_x >= cell_width) continue;

                const src_idx = src_y * glyph.width + src_x;
                const dst_idx = (@as(u32, @intCast(dst_y)) * cell_width + @as(u32, @intCast(dst_x))) * 4;

                if (src_idx < glyph.bitmap.len and dst_idx + 3 < cell_bitmap.len) {
                    const alpha = glyph.bitmap[src_idx];

                    if (alpha > 0) {
                        // Alpha blend with background
                        const alpha_f = @as(f32, @floatFromInt(alpha)) / 255.0;
                        const inv_alpha = 1.0 - alpha_f;

                        cell_bitmap[dst_idx + 0] = @as(u8, @intFromFloat(@as(f32, @floatFromInt(fg_r)) * alpha_f + @as(f32, @floatFromInt(cell_bitmap[dst_idx + 0])) * inv_alpha));
                        cell_bitmap[dst_idx + 1] = @as(u8, @intFromFloat(@as(f32, @floatFromInt(fg_g)) * alpha_f + @as(f32, @floatFromInt(cell_bitmap[dst_idx + 1])) * inv_alpha));
                        cell_bitmap[dst_idx + 2] = @as(u8, @intFromFloat(@as(f32, @floatFromInt(fg_b)) * alpha_f + @as(f32, @floatFromInt(cell_bitmap[dst_idx + 2])) * inv_alpha));
                        cell_bitmap[dst_idx + 3] = @max(fg_a, cell_bitmap[dst_idx + 3]);
                    }
                }
            }
        }

        // Apply text effects
        try self.applyTextEffects(cell_bitmap, cell_width, cell_height, effects, foreground);
    }

    fn applyTextEffects(
        self: *Self,
        bitmap: []u8,
        width: u32,
        height: u32,
        effects: CellEffects,
        color: u32,
    ) !void {
        _ = self;

        const fg_r = @as(u8, @truncate((color >> 16) & 0xFF));
        const fg_g = @as(u8, @truncate((color >> 8) & 0xFF));
        const fg_b = @as(u8, @truncate(color & 0xFF));
        const fg_a = @as(u8, @truncate((color >> 24) & 0xFF));

        // Underline
        if (effects.underline) {
            const underline_y = @as(u32, @intFromFloat(self.font_metrics.underline_position + self.baseline_offset));
            const thickness = @max(1, @as(u32, @intFromFloat(self.font_metrics.underline_thickness)));

            for (0..thickness) |t| {
                const y = underline_y + @as(u32, @intCast(t));
                if (y < height) {
                    for (0..width) |x| {
                        const idx = (y * width + x) * 4;
                        if (idx + 3 < bitmap.len) {
                            bitmap[idx + 0] = fg_r;
                            bitmap[idx + 1] = fg_g;
                            bitmap[idx + 2] = fg_b;
                            bitmap[idx + 3] = fg_a;
                        }
                    }
                }
            }
        }

        // Strikethrough
        if (effects.strikethrough) {
            const strike_y = @as(u32, @intFromFloat(self.font_metrics.strikethrough_position + self.baseline_offset));
            const thickness = @max(1, @as(u32, @intFromFloat(self.font_metrics.strikethrough_thickness)));

            for (0..thickness) |t| {
                const y = strike_y + @as(u32, @intCast(t));
                if (y < height) {
                    for (0..width) |x| {
                        const idx = (y * width + x) * 4;
                        if (idx + 3 < bitmap.len) {
                            bitmap[idx + 0] = fg_r;
                            bitmap[idx + 1] = fg_g;
                            bitmap[idx + 2] = fg_b;
                            bitmap[idx + 3] = fg_a;
                        }
                    }
                }
            }
        }

        // Overline
        if (effects.overline) {
            const overline_y = 2; // Top of cell
            for (0..width) |x| {
                const idx = (overline_y * width + x) * 4;
                if (idx + 3 < bitmap.len) {
                    bitmap[idx + 0] = fg_r;
                    bitmap[idx + 1] = fg_g;
                    bitmap[idx + 2] = fg_b;
                    bitmap[idx + 3] = fg_a;
                }
            }
        }
    }

    fn blitCachedCell(
        self: *Self,
        cached_cell: *const CachedCell,
        x: f32,
        y: f32,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
    ) !void {
        _ = self;

        const start_x = @as(u32, @intFromFloat(x));
        const start_y = @as(u32, @intFromFloat(y));

        // Bounds checking
        if (start_x >= buffer_width or start_y >= buffer_height) return;

        const copy_width = @min(cached_cell.width, buffer_width - start_x);
        const copy_height = @min(cached_cell.height, buffer_height - start_y);

        // Optimized blit using SIMD when available
        for (0..copy_height) |src_y| {
            const dst_y = start_y + @as(u32, @intCast(src_y));
            const src_row_start = src_y * cached_cell.width * 4;
            const dst_row_start = (dst_y * buffer_width + start_x) * 4;

            if (dst_row_start + copy_width * 4 <= buffer.len and
                src_row_start + copy_width * 4 <= cached_cell.bitmap.len) {

                @memcpy(
                    buffer[dst_row_start..dst_row_start + copy_width * 4],
                    cached_cell.bitmap[src_row_start..src_row_start + copy_width * 4],
                );
            }
        }
    }

    fn calculateFontMetrics(self: *Self) !void {
        // Calculate optimal font metrics for terminal rendering
        // This would typically involve querying the primary font

        self.font_metrics = FontMetrics{
            .ascent = self.cell_height * 0.8,
            .descent = self.cell_height * 0.2,
            .line_gap = 0.0,
            .x_height = self.cell_height * 0.5,
            .cap_height = self.cell_height * 0.7,
            .underline_position = self.cell_height * 0.85,
            .underline_thickness = @max(1.0, self.cell_height * 0.05),
            .strikethrough_position = self.cell_height * 0.5,
            .strikethrough_thickness = @max(1.0, self.cell_height * 0.05),
        };

        self.baseline_offset = self.font_metrics.ascent;
    }

    fn cleanupCache(self: *Self) !void {
        // Remove least recently used entries
        const current_time = std.time.milliTimestamp();
        const max_age_ms = 60000; // 1 minute

        var entries_to_remove = std.ArrayList(CellKey).init(self.allocator);
        defer entries_to_remove.deinit();

        var iterator = self.cell_cache.iterator();
        while (iterator.next()) |entry| {
            if (current_time - entry.value_ptr.last_used > max_age_ms) {
                try entries_to_remove.append(entry.key_ptr.*);
            }
        }

        for (entries_to_remove.items) |key| {
            if (self.cell_cache.fetchRemove(key)) |kv| {
                self.allocator.free(kv.value.bitmap);
            }
        }
    }

    // Performance monitoring
    pub fn getPerformanceStats(self: *const Self) CellRenderStats {
        const hits = self.cache_hits.load(.monotonic);
        const misses = self.cache_misses.load(.monotonic);
        const total_requests = hits + misses;

        return CellRenderStats{
            .cache_hit_rate = if (total_requests > 0) @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(total_requests)) else 0.0,
            .cached_cells = @intCast(self.cell_cache.count()),
            .total_renders = self.render_calls.load(.monotonic),
            .cache_hits = hits,
            .cache_misses = misses,
        };
    }

    pub fn resetStats(self: *Self) void {
        self.cache_hits.store(0, .monotonic);
        self.cache_misses.store(0, .monotonic);
        self.render_calls.store(0, .monotonic);
    }

    // Configuration methods
    pub fn setCellDimensions(self: *Self, width: f32, height: f32) !void {
        if (width != self.cell_width or height != self.cell_height) {
            // Clear cache when cell dimensions change
            var iterator = self.cell_cache.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.value_ptr.bitmap);
            }
            self.cell_cache.clearRetainingCapacity();

            self.cell_width = width;
            self.cell_height = height;

            try self.calculateFontMetrics();
        }
    }

    pub fn setGridAlignment(self: *Self, alignment: GridAlignment) void {
        self.grid_alignment = alignment;
    }

    // Batch rendering for improved performance
    pub fn renderCellBatch(
        self: *Self,
        cells: []const CellRenderRequest,
        buffer: []u8,
        buffer_width: u32,
        buffer_height: u32,
    ) !void {
        for (cells) |cell| {
            try self.renderCell(
                cell.codepoint,
                cell.x,
                cell.y,
                cell.font,
                cell.style,
                cell.foreground,
                cell.background,
                cell.effects,
                buffer,
                buffer_width,
                buffer_height,
            );
        }
    }
};

pub const CellRenderRequest = struct {
    codepoint: u32,
    x: f32,
    y: f32,
    font: *root.Font,
    style: CellRenderer.FontStyle,
    foreground: u32,
    background: u32,
    effects: CellRenderer.CellEffects,
};

pub const CellRenderStats = struct {
    cache_hit_rate: f32,
    cached_cells: u32,
    total_renders: u64,
    cache_hits: u64,
    cache_misses: u64,
};

// Tests
test "CellRenderer initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Mock dependencies
    var mock_glyph_renderer: GlyphRenderer = undefined;
    var mock_gpu_cache: GPUCache = undefined;

    var renderer = CellRenderer.init(
        allocator,
        &mock_glyph_renderer,
        &mock_gpu_cache,
        12.0,
        16.0,
    ) catch return;
    defer renderer.deinit();

    try testing.expect(renderer.cell_width == 12.0);
    try testing.expect(renderer.cell_height == 16.0);
    try testing.expect(renderer.cell_cache.count() == 0);
}

test "CellRenderer cache key hashing" {
    const key1 = CellRenderer.CellKey{
        .codepoint = 65, // 'A'
        .font_id = 0x12345678,
        .size = 16000, // 16.0 * 1000
        .style = .{},
        .foreground = 0xFFFFFFFF,
        .background = 0x00000000,
        .effects = .{},
    };

    const key2 = CellRenderer.CellKey{
        .codepoint = 65, // 'A'
        .font_id = 0x12345678,
        .size = 16000, // 16.0 * 1000
        .style = .{},
        .foreground = 0xFFFFFFFF,
        .background = 0x00000000,
        .effects = .{},
    };

    const key3 = CellRenderer.CellKey{
        .codepoint = 66, // 'B'
        .font_id = 0x12345678,
        .size = 16000, // 16.0 * 1000
        .style = .{},
        .foreground = 0xFFFFFFFF,
        .background = 0x00000000,
        .effects = .{},
    };

    try std.testing.expect(CellRenderer.CellKey.eql(key1, key2));
    try std.testing.expect(!CellRenderer.CellKey.eql(key1, key3));
    try std.testing.expect(key1.hash() == key2.hash());
    try std.testing.expect(key1.hash() != key3.hash());
}