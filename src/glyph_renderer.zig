const std = @import("std");
const root = @import("root.zig");
const Glyph = @import("glyph.zig").Glyph;
const Font = @import("font.zig").Font;

pub const GlyphRenderer = struct {
    allocator: std.mem.Allocator,
    render_cache: std.HashMap(RenderKey, RenderedGlyph, RenderKeyContext, 80),

    const Self = @This();

    const RenderKey = struct {
        glyph_index: u32,
        size: u32, // Size in pixels * 100 for precision
        options_hash: u64,
    };

    const RenderKeyContext = struct {
        pub fn hash(self: @This(), key: RenderKey) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&key.glyph_index));
            hasher.update(std.mem.asBytes(&key.size));
            hasher.update(std.mem.asBytes(&key.options_hash));
            return hasher.final();
        }

        pub fn eql(self: @This(), a: RenderKey, b: RenderKey) bool {
            _ = self;
            return a.glyph_index == b.glyph_index and
                a.size == b.size and
                a.options_hash == b.options_hash;
        }
    };

    const RenderedGlyph = struct {
        bitmap: []u8,
        width: u32,
        height: u32,
        bearing_x: i32,
        bearing_y: i32,
        advance_x: i32,
        advance_y: i32,

        pub fn deinit(self: *RenderedGlyph, allocator: std.mem.Allocator) void {
            allocator.free(self.bitmap);
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .render_cache = std.HashMap(RenderKey, RenderedGlyph, RenderKeyContext, 80).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.render_cache.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.render_cache.deinit();
    }

    pub fn renderGlyph(self: *Self, font: *Font, codepoint: u32, options: root.RenderOptions) !RenderedGlyph {
        const options_hash = self.hashRenderOptions(options);
        const render_key = RenderKey{
            .glyph_index = codepoint, // Simplified
            .size = @as(u32, @intFromFloat(options.size * 100)),
            .options_hash = options_hash,
        };

        if (self.render_cache.get(render_key)) |cached| {
            return cached;
        }

        const glyph = try font.getGlyph(codepoint, options.size);
        const rendered = try self.renderGlyphInternal(glyph, options);

        try self.render_cache.put(render_key, rendered);
        return rendered;
    }

    fn renderGlyphInternal(self: *Self, glyph: Glyph, options: root.RenderOptions) !RenderedGlyph {
        const width = glyph.width;
        const height = glyph.height;
        const bitmap_size = width * height;

        var bitmap = try self.allocator.alloc(u8, bitmap_size);
        @memset(bitmap, 0);

        if (glyph.outline) |outline| {
            try self.rasterizeOutline(outline, bitmap, width, height, options);
        } else if (glyph.bitmap) |glyph_bitmap| {
            @memcpy(bitmap, glyph_bitmap);
        } else {
            // Generate a simple test glyph
            self.generateTestGlyph(bitmap, width, height);
        }

        // Apply post-processing
        if (options.enable_hinting) {
            self.applyHinting(bitmap, width, height);
        }

        if (options.enable_subpixel) {
            bitmap = try self.applySubpixelRendering(bitmap, width, height);
        }

        return RenderedGlyph{
            .bitmap = bitmap,
            .width = width,
            .height = height,
            .bearing_x = @as(i32, @intFromFloat(glyph.bearing_x)),
            .bearing_y = @as(i32, @intFromFloat(glyph.bearing_y)),
            .advance_x = @as(i32, @intFromFloat(glyph.advance_width)),
            .advance_y = @as(i32, @intFromFloat(glyph.advance_height)),
        };
    }

    fn rasterizeOutline(self: *Self, outline: @import("glyph.zig").GlyphOutline, bitmap: []u8, width: u32, height: u32, options: root.RenderOptions) !void {
        // Simplified scanline rasterization
        for (outline.contours) |contour| {
            if (contour.points.len < 2) continue;

            // Draw simple lines between points
            for (0..contour.points.len) |i| {
                const p1 = contour.points[i];
                const p2 = contour.points[(i + 1) % contour.points.len];

                self.drawLine(bitmap, width, height, p1, p2, options);
            }
        }
    }

    fn drawLine(self: *Self, bitmap: []u8, width: u32, height: u32, p1: @import("glyph.zig").Point, p2: @import("glyph.zig").Point, options: root.RenderOptions) void {
        _ = self;

        const x1 = @as(i32, @intFromFloat(p1.x));
        const y1 = @as(i32, @intFromFloat(p1.y));
        const x2 = @as(i32, @intFromFloat(p2.x));
        const y2 = @as(i32, @intFromFloat(p2.y));

        // Bresenham's line algorithm
        const dx: i32 = @intCast(@abs(x2 - x1));
        const dy: i32 = @intCast(@abs(y2 - y1));
        const sx: i32 = if (x1 < x2) 1 else -1;
        const sy: i32 = if (y1 < y2) 1 else -1;
        var err = dx - dy;

        var x = x1;
        var y = y1;

        while (true) {
            if (x >= 0 and x < width and y >= 0 and y < height) {
                const index = @as(u32, @intCast(y)) * width + @as(u32, @intCast(x));
                bitmap[index] = if (options.enable_subpixel) 128 else 255;
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

    fn generateTestGlyph(self: *Self, bitmap: []u8, width: u32, height: u32) void {
        _ = self;

        // Create a simple rectangular character
        const border = @min(width / 8, height / 8);

        for (0..height) |y| {
            for (0..width) |x| {
                const index = y * width + x;
                if (x < border or x >= width - border or
                    y < border or y >= height - border)
                {
                    bitmap[index] = 255;
                } else if (x < border * 2 or x >= width - border * 2 or
                    y < border * 2 or y >= height - border * 2)
                {
                    bitmap[index] = 128;
                } else {
                    bitmap[index] = 0;
                }
            }
        }
    }

    fn applyHinting(self: *Self, bitmap: []u8, width: u32, height: u32) void {
        _ = self;

        // Simple grid fitting - snap pixels to grid
        for (0..height) |y| {
            for (0..width) |x| {
                const index = y * width + x;
                const value = bitmap[index];

                // Simple threshold
                bitmap[index] = if (value > 128) 255 else 0;
            }
        }
    }

    fn applySubpixelRendering(self: *Self, bitmap: []u8, width: u32, height: u32) ![]u8 {
        // Convert to RGB subpixel format (3x width)
        const new_width = width * 3;
        var new_bitmap = try self.allocator.alloc(u8, new_width * height);
        @memset(new_bitmap, 0);

        for (0..height) |y| {
            for (0..width) |x| {
                const src_index = y * width + x;
                const dst_index = y * new_width + x * 3;
                const value = bitmap[src_index];

                // Simple RGB distribution
                new_bitmap[dst_index] = value; // R
                new_bitmap[dst_index + 1] = value; // G
                new_bitmap[dst_index + 2] = value; // B
            }
        }

        self.allocator.free(bitmap);
        return new_bitmap;
    }

    fn hashRenderOptions(self: *Self, options: root.RenderOptions) u64 {
        _ = self;

        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&options.dpi));
        hasher.update(std.mem.asBytes(&options.enable_hinting));
        hasher.update(std.mem.asBytes(&options.enable_subpixel));
        hasher.update(std.mem.asBytes(&options.gamma));
        hasher.update(std.mem.asBytes(&options.weight));
        hasher.update(std.mem.asBytes(&options.style));
        return hasher.final();
    }

    pub fn clearCache(self: *Self) void {
        var iterator = self.render_cache.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.render_cache.clearAndFree();
    }

    pub fn getCacheSize(self: *Self) u32 {
        return @as(u32, @intCast(self.render_cache.count()));
    }
};

pub const RenderTarget = struct {
    buffer: []u8,
    width: u32,
    height: u32,
    stride: u32,
    format: PixelFormat,

    pub const PixelFormat = enum {
        grayscale,
        rgb,
        rgba,
        bgr,
        bgra,
    };

    pub fn blitGlyph(self: *RenderTarget, glyph: GlyphRenderer.RenderedGlyph, x: i32, y: i32) void {
        const dst_width = @as(i32, @intCast(self.width));
        const dst_height = @as(i32, @intCast(self.height));
        const src_width = @as(i32, @intCast(glyph.width));
        const src_height = @as(i32, @intCast(glyph.height));

        const start_x = @max(0, x);
        const start_y = @max(0, y);
        const end_x = @min(dst_width, x + src_width);
        const end_y = @min(dst_height, y + src_height);

        for (@as(u32, @intCast(start_y))..@as(u32, @intCast(end_y))) |dst_y| {
            for (@as(u32, @intCast(start_x))..@as(u32, @intCast(end_x))) |dst_x| {
                const src_x = @as(i32, @intCast(dst_x)) - x;
                const src_y = @as(i32, @intCast(dst_y)) - y;

                if (src_x >= 0 and src_x < src_width and src_y >= 0 and src_y < src_height) {
                    const src_index = @as(u32, @intCast(src_y)) * glyph.width + @as(u32, @intCast(src_x));
                    const dst_index = dst_y * self.stride + dst_x;

                    if (dst_index < self.buffer.len) {
                        self.buffer[dst_index] = glyph.bitmap[src_index];
                    }
                }
            }
        }
    }
};

test "GlyphRenderer basic operations" {
    const allocator = std.testing.allocator;

    var renderer = GlyphRenderer.init(allocator);
    defer renderer.deinit();

    try std.testing.expect(renderer.getCacheSize() == 0);

    // Test cache operations
    renderer.clearCache();
    try std.testing.expect(renderer.getCacheSize() == 0);
}

test "RenderTarget blit operations" {
    const allocator = std.testing.allocator;

    const width = 32;
    const height = 32;
    const buffer = try allocator.alloc(u8, width * height);
    defer allocator.free(buffer);
    @memset(buffer, 0);

    var target = RenderTarget{
        .buffer = buffer,
        .width = width,
        .height = height,
        .stride = width,
        .format = .grayscale,
    };

    // Create a simple test glyph
    const glyph_size = 8;
    const glyph_bitmap = try allocator.alloc(u8, glyph_size * glyph_size);
    defer allocator.free(glyph_bitmap);
    @memset(glyph_bitmap, 255);

    const test_glyph = GlyphRenderer.RenderedGlyph{
        .bitmap = glyph_bitmap,
        .width = glyph_size,
        .height = glyph_size,
        .bearing_x = 0,
        .bearing_y = 0,
        .advance_x = glyph_size,
        .advance_y = 0,
    };

    target.blitGlyph(test_glyph, 4, 4);

    // Verify that some pixels were set
    var found_pixel = false;
    for (buffer) |pixel| {
        if (pixel != 0) {
            found_pixel = true;
            break;
        }
    }
    try std.testing.expect(found_pixel);
}
