const std = @import("std");
const root = @import("root.zig");
const gcode = @import("gcode");
const Unicode = @import("unicode.zig").Unicode;

// Terminal grid alignment system for pixel-perfect text rendering
// Ensures consistent character spacing and baseline alignment
pub const GridAligner = struct {
    allocator: std.mem.Allocator,

    // Grid parameters
    cell_width: f32,
    cell_height: f32,
    baseline_y: f32,
    pixel_ratio: f32,

    // Alignment settings
    settings: AlignmentSettings,

    // Font-specific adjustments
    font_adjustments: std.AutoHashMap(*root.Font, FontAdjustment),

    // Performance monitoring
    alignment_cache: std.AutoHashMap(AlignmentKey, AlignmentResult),

    const Self = @This();

    const AlignmentSettings = struct {
        // Horizontal alignment
        force_monospace: bool = true,
        center_narrow_chars: bool = true,
        snap_to_pixel: bool = true,
        subpixel_positioning: bool = false,

        // Vertical alignment
        align_baselines: bool = true,
        normalize_line_height: bool = true,
        center_vertically: bool = false,

        // Character-specific adjustments
        adjust_cjk_spacing: bool = true,
        adjust_combining_marks: bool = true,
        adjust_emoji_size: bool = true,

        // Grid fitting
        hint_to_grid: bool = true,
        force_integer_advance: bool = true,
        compensate_stem_width: bool = true,
    };

    const FontAdjustment = struct {
        horizontal_scale: f32 = 1.0,
        vertical_scale: f32 = 1.0,
        baseline_offset: f32 = 0.0,
        advance_adjustment: f32 = 0.0,
        bearing_x_offset: f32 = 0.0,
        bearing_y_offset: f32 = 0.0,
    };

    const AlignmentKey = struct {
        font_ptr: *root.Font,
        codepoint: u32,
        size: u32, // Fixed point: size * 1000
        grid_width: u32, // Fixed point: width * 1000
        grid_height: u32, // Fixed point: height * 1000

        pub fn hash(self: AlignmentKey) u64 {
            var hasher = std.hash.Wyhash.init(0xABCDEF);
            hasher.update(std.mem.asBytes(&self.font_ptr));
            hasher.update(std.mem.asBytes(&self.codepoint));
            hasher.update(std.mem.asBytes(&self.size));
            hasher.update(std.mem.asBytes(&self.grid_width));
            hasher.update(std.mem.asBytes(&self.grid_height));
            return hasher.final();
        }

        pub fn eql(a: AlignmentKey, b: AlignmentKey) bool {
            return a.font_ptr == b.font_ptr and
                   a.codepoint == b.codepoint and
                   a.size == b.size and
                   a.grid_width == b.grid_width and
                   a.grid_height == b.grid_height;
        }
    };

    const AlignmentResult = struct {
        render_x: f32,
        render_y: f32,
        render_width: f32,
        render_height: f32,
        advance_x: f32,
        advance_y: f32,
        baseline_offset: f32,
        scale_factor: f32,
        needs_subpixel: bool,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        cell_width: f32,
        cell_height: f32,
        baseline_y: f32,
        pixel_ratio: f32,
    ) Self {
        return Self{
            .allocator = allocator,
            .cell_width = cell_width,
            .cell_height = cell_height,
            .baseline_y = baseline_y,
            .pixel_ratio = pixel_ratio,
            .settings = AlignmentSettings{},
            .font_adjustments = std.AutoHashMap(*root.Font, FontAdjustment).init(allocator),
            .alignment_cache = std.AutoHashMap(AlignmentKey, AlignmentResult).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.font_adjustments.deinit();
        self.alignment_cache.deinit();
    }

    pub fn alignGlyph(
        self: *Self,
        font: *root.Font,
        codepoint: u32,
        glyph_metrics: anytype,
        cell_x: f32,
        cell_y: f32,
    ) !AlignmentResult {
        // Create cache key
        const cache_key = AlignmentKey{
            .font_ptr = font,
            .codepoint = codepoint,
            .size = @as(u32, @intFromFloat(self.cell_height * 1000)),
            .grid_width = @as(u32, @intFromFloat(self.cell_width * 1000)),
            .grid_height = @as(u32, @intFromFloat(self.cell_height * 1000)),
        };

        // Check cache
        if (self.alignment_cache.get(cache_key)) |cached| {
            return AlignmentResult{
                .render_x = cached.render_x + cell_x,
                .render_y = cached.render_y + cell_y,
                .render_width = cached.render_width,
                .render_height = cached.render_height,
                .advance_x = cached.advance_x,
                .advance_y = cached.advance_y,
                .baseline_offset = cached.baseline_offset,
                .scale_factor = cached.scale_factor,
                .needs_subpixel = cached.needs_subpixel,
            };
        }

        // Calculate alignment
        const result = try self.calculateAlignment(font, codepoint, glyph_metrics);

        // Cache the result (without absolute position)
        try self.alignment_cache.put(cache_key, AlignmentResult{
            .render_x = result.render_x - cell_x,
            .render_y = result.render_y - cell_y,
            .render_width = result.render_width,
            .render_height = result.render_height,
            .advance_x = result.advance_x,
            .advance_y = result.advance_y,
            .baseline_offset = result.baseline_offset,
            .scale_factor = result.scale_factor,
            .needs_subpixel = result.needs_subpixel,
        });

        return result;
    }

    fn calculateAlignment(
        self: *Self,
        font: *root.Font,
        codepoint: u32,
        glyph_metrics: anytype,
    ) !AlignmentResult {
        // Get font-specific adjustments
        const font_adj = self.font_adjustments.get(font) orelse FontAdjustment{};

        // Character classification for specialized handling
        const char_class = self.classifyCharacter(codepoint);

        // Base glyph metrics
        var width = @as(f32, @floatFromInt(glyph_metrics.width));
        var height = @as(f32, @floatFromInt(glyph_metrics.height));
        var bearing_x = glyph_metrics.bearing_x + font_adj.bearing_x_offset;
        var bearing_y = glyph_metrics.bearing_y + font_adj.bearing_y_offset;
        var advance_x = glyph_metrics.advance_x + font_adj.advance_adjustment;

        // Apply character-specific adjustments
        switch (char_class) {
            .cjk_fullwidth => {
                if (self.settings.adjust_cjk_spacing) {
                    advance_x = self.cell_width * 2.0; // CJK characters are double-width
                    if (self.settings.center_narrow_chars and width < self.cell_width * 2.0) {
                        bearing_x = (self.cell_width * 2.0 - width) / 2.0;
                    }
                }
            },
            .cjk_halfwidth => {
                if (self.settings.adjust_cjk_spacing) {
                    advance_x = self.cell_width;
                    if (self.settings.center_narrow_chars and width < self.cell_width) {
                        bearing_x = (self.cell_width - width) / 2.0;
                    }
                }
            },
            .emoji => {
                if (self.settings.adjust_emoji_size) {
                    // Emoji should fill the cell height while maintaining aspect ratio
                    const scale = @min(self.cell_width / width, self.cell_height / height);
                    width *= scale;
                    height *= scale;
                    bearing_x = (self.cell_width - width) / 2.0;
                    bearing_y = self.baseline_y - height * 0.8; // Adjust for emoji baseline
                    advance_x = self.cell_width;
                }
            },
            .combining_mark => {
                if (self.settings.adjust_combining_marks) {
                    // Combining marks should not advance the cursor
                    advance_x = 0.0;
                    // Center over previous character
                    bearing_x = -self.cell_width / 2.0 + (self.cell_width - width) / 2.0;
                }
            },
            .ascii, .latin_extended => {
                // Standard Latin character handling
                if (self.settings.force_monospace) {
                    advance_x = self.cell_width;
                }
                if (self.settings.center_narrow_chars and width < self.cell_width * 0.8) {
                    bearing_x = (self.cell_width - width) / 2.0;
                }
            },
            .zero_width => {
                // Zero-width characters
                advance_x = 0.0;
                width = 0.0;
                height = 0.0;
            },
        }

        // Apply grid fitting
        if (self.settings.hint_to_grid) {
            bearing_x = self.snapToGrid(bearing_x);
            bearing_y = self.snapToGrid(bearing_y);

            if (self.settings.force_integer_advance) {
                advance_x = @round(advance_x);
            }
        }

        // Apply baseline alignment
        var final_y = bearing_y;
        if (self.settings.align_baselines) {
            final_y = self.baseline_y - bearing_y + font_adj.baseline_offset;
        }

        // Apply scaling adjustments
        width *= font_adj.horizontal_scale;
        height *= font_adj.vertical_scale;

        // Subpixel positioning decision
        const needs_subpixel = self.settings.subpixel_positioning and
                              !self.settings.snap_to_pixel and
                              self.pixel_ratio > 1.0;

        // Final position snapping
        var final_x = bearing_x;
        if (self.settings.snap_to_pixel and !needs_subpixel) {
            final_x = @round(final_x * self.pixel_ratio) / self.pixel_ratio;
            final_y = @round(final_y * self.pixel_ratio) / self.pixel_ratio;
        }

        return AlignmentResult{
            .render_x = final_x,
            .render_y = final_y,
            .render_width = width,
            .render_height = height,
            .advance_x = advance_x,
            .advance_y = 0.0, // Terminals don't typically use vertical advance
            .baseline_offset = final_y - bearing_y,
            .scale_factor = 1.0, // Could be used for additional scaling
            .needs_subpixel = needs_subpixel,
        };
    }

    fn classifyCharacter(self: *Self, codepoint: u32) CharacterClass {
        _ = self;

        // ASCII range
        if (codepoint < 0x80) {
            return .ascii;
        }

        // Extended Latin
        if (codepoint < 0x250) {
            return .latin_extended;
        }

        // Combining marks
        if (codepoint >= 0x300 and codepoint <= 0x36F) {
            return .combining_mark;
        }

        // CJK ranges
        if ((codepoint >= 0x4E00 and codepoint <= 0x9FFF) or // CJK Unified Ideographs
            (codepoint >= 0x3400 and codepoint <= 0x4DBF) or // CJK Extension A
            (codepoint >= 0x20000 and codepoint <= 0x2A6DF)) { // CJK Extension B

            // Check if character has fullwidth property
            const width = Unicode.getDisplayWidth(codepoint, .standard);
            return if (width == 2) .cjk_fullwidth else .cjk_halfwidth;
        }

        // Emoji ranges
        if ((codepoint >= 0x1F600 and codepoint <= 0x1F64F) or // Emoticons
            (codepoint >= 0x1F300 and codepoint <= 0x1F5FF) or // Misc Symbols
            (codepoint >= 0x1F680 and codepoint <= 0x1F6FF) or // Transport
            (codepoint >= 0x1F1E6 and codepoint <= 0x1F1FF)) { // Regional indicators
            return .emoji;
        }

        // Zero-width characters
        if (codepoint == 0x200B or // Zero Width Space
            codepoint == 0x200C or // Zero Width Non-Joiner
            codepoint == 0x200D or // Zero Width Joiner
            codepoint == 0xFEFF) { // Zero Width No-Break Space
            return .zero_width;
        }

        // Default to ASCII treatment
        return .ascii;
    }

    fn snapToGrid(self: *Self, value: f32) f32 {
        return @round(value * self.pixel_ratio) / self.pixel_ratio;
    }

    // Configuration methods
    pub fn setSettings(self: *Self, settings: AlignmentSettings) void {
        self.settings = settings;
        // Clear cache when settings change
        self.alignment_cache.clearRetainingCapacity();
    }

    pub fn setFontAdjustment(self: *Self, font: *root.Font, adjustment: FontAdjustment) !void {
        try self.font_adjustments.put(font, adjustment);
        // Clear relevant cache entries
        self.clearFontCache(font);
    }

    pub fn setCellDimensions(self: *Self, width: f32, height: f32, baseline_y: f32) void {
        if (width != self.cell_width or height != self.cell_height or baseline_y != self.baseline_y) {
            self.cell_width = width;
            self.cell_height = height;
            self.baseline_y = baseline_y;
            // Clear cache when dimensions change
            self.alignment_cache.clearRetainingCapacity();
        }
    }

    fn clearFontCache(self: *Self, font: *root.Font) void {
        var keys_to_remove = std.ArrayList(AlignmentKey).init(self.allocator);
        defer keys_to_remove.deinit();

        var iterator = self.alignment_cache.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.font_ptr == font) {
                keys_to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (keys_to_remove.items) |key| {
            _ = self.alignment_cache.remove(key);
        }
    }

    // Batch alignment for performance
    pub fn alignGlyphBatch(
        self: *Self,
        requests: []const AlignmentRequest,
        results: []AlignmentResult,
    ) !void {
        if (requests.len != results.len) return error.InvalidBatchSize;

        for (requests, results) |request, *result| {
            result.* = try self.alignGlyph(
                request.font,
                request.codepoint,
                request.glyph_metrics,
                request.cell_x,
                request.cell_y,
            );
        }
    }

    // Advanced grid fitting for high-DPI displays
    pub fn optimizeForDPI(self: *Self, dpi: f32) void {
        self.pixel_ratio = dpi / 96.0; // 96 DPI is standard

        // Adjust settings based on DPI
        if (self.pixel_ratio >= 2.0) {
            // High DPI - enable subpixel positioning
            self.settings.subpixel_positioning = true;
            self.settings.snap_to_pixel = false;
        } else {
            // Standard DPI - prefer pixel alignment
            self.settings.subpixel_positioning = false;
            self.settings.snap_to_pixel = true;
        }

        // Clear cache to apply new DPI settings
        self.alignment_cache.clearRetainingCapacity();
    }

    // Performance monitoring
    pub fn getStats(self: *const Self) AlignmentStats {
        return AlignmentStats{
            .cached_alignments = @intCast(self.alignment_cache.count()),
            .font_adjustments = @intCast(self.font_adjustments.count()),
            .memory_usage = self.estimateMemoryUsage(),
        };
    }

    fn estimateMemoryUsage(self: *const Self) usize {
        const alignment_size = @sizeOf(AlignmentKey) + @sizeOf(AlignmentResult);
        const font_adj_size = @sizeOf(*root.Font) + @sizeOf(FontAdjustment);

        return self.alignment_cache.count() * alignment_size +
               self.font_adjustments.count() * font_adj_size;
    }
};

const CharacterClass = enum {
    ascii,
    latin_extended,
    cjk_fullwidth,
    cjk_halfwidth,
    emoji,
    combining_mark,
    zero_width,
};

pub const AlignmentRequest = struct {
    font: *root.Font,
    codepoint: u32,
    glyph_metrics: anytype,
    cell_x: f32,
    cell_y: f32,
};

pub const AlignmentStats = struct {
    cached_alignments: u32,
    font_adjustments: u32,
    memory_usage: usize,
};

// Terminal-specific grid utilities
pub const TerminalGrid = struct {
    columns: u32,
    rows: u32,
    cell_width: f32,
    cell_height: f32,
    margin_left: f32,
    margin_top: f32,

    pub fn init(columns: u32, rows: u32, cell_width: f32, cell_height: f32) TerminalGrid {
        return TerminalGrid{
            .columns = columns,
            .rows = rows,
            .cell_width = cell_width,
            .cell_height = cell_height,
            .margin_left = 0.0,
            .margin_top = 0.0,
        };
    }

    pub fn getCellPosition(self: *const TerminalGrid, col: u32, row: u32) struct { x: f32, y: f32 } {
        return .{
            .x = self.margin_left + @as(f32, @floatFromInt(col)) * self.cell_width,
            .y = self.margin_top + @as(f32, @floatFromInt(row)) * self.cell_height,
        };
    }

    pub fn getGridPosition(self: *const TerminalGrid, x: f32, y: f32) struct { col: u32, row: u32 } {
        const col_f = (x - self.margin_left) / self.cell_width;
        const row_f = (y - self.margin_top) / self.cell_height;

        return .{
            .col = @as(u32, @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(self.columns - 1)), col_f)))),
            .row = @as(u32, @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(self.rows - 1)), row_f)))),
        };
    }

    pub fn isValidPosition(self: *const TerminalGrid, col: u32, row: u32) bool {
        return col < self.columns and row < self.rows;
    }

    pub fn getTotalWidth(self: *const TerminalGrid) f32 {
        return self.margin_left * 2 + @as(f32, @floatFromInt(self.columns)) * self.cell_width;
    }

    pub fn getTotalHeight(self: *const TerminalGrid) f32 {
        return self.margin_top * 2 + @as(f32, @floatFromInt(self.rows)) * self.cell_height;
    }
};

// Tests
test "GridAligner character classification" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var aligner = GridAligner.init(allocator, 12.0, 16.0, 12.0, 1.0);
    defer aligner.deinit();

    // Test ASCII
    try testing.expect(aligner.classifyCharacter('A') == .ascii);
    try testing.expect(aligner.classifyCharacter('1') == .ascii);

    // Test CJK
    try testing.expect(aligner.classifyCharacter(0x4E00) == .cjk_fullwidth); // CJK ideograph

    // Test emoji
    try testing.expect(aligner.classifyCharacter(0x1F600) == .emoji); // Grinning face

    // Test zero-width
    try testing.expect(aligner.classifyCharacter(0x200B) == .zero_width); // ZWSP
}

test "TerminalGrid position calculations" {
    const grid = TerminalGrid.init(80, 24, 12.0, 16.0);

    const pos = grid.getCellPosition(10, 5);
    try std.testing.expect(pos.x == 120.0);
    try std.testing.expect(pos.y == 80.0);

    const grid_pos = grid.getGridPosition(120.0, 80.0);
    try std.testing.expect(grid_pos.col == 10);
    try std.testing.expect(grid_pos.row == 5);

    try std.testing.expect(grid.isValidPosition(79, 23));
    try std.testing.expect(!grid.isValidPosition(80, 24));
}