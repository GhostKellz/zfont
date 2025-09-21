const std = @import("std");
const root = @import("root.zig");

pub const Glyph = struct {
    allocator: std.mem.Allocator,
    codepoint: u32,
    index: u32,
    advance_width: f32,
    advance_height: f32,
    bearing_x: f32,
    bearing_y: f32,
    width: u32,
    height: u32,
    bitmap: ?[]u8,
    outline: ?GlyphOutline,
    size: f32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, size: f32) !Self {
        return Self{
            .allocator = allocator,
            .codepoint = 0,
            .index = 0,
            .advance_width = size * 0.6,
            .advance_height = size,
            .bearing_x = 0,
            .bearing_y = size * 0.8,
            .width = @as(u32, @intFromFloat(size * 0.6)),
            .height = @as(u32, @intFromFloat(size)),
            .bitmap = null,
            .outline = null,
            .size = size,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.bitmap) |bitmap| {
            allocator.free(bitmap);
        }
        if (self.outline) |*outline| {
            outline.deinit(allocator);
        }
    }

    pub fn renderBitmap(self: *Self, options: RenderOptions) !void {
        if (self.bitmap != null) return; // Already rendered

        const bitmap_size = self.width * self.height;
        self.bitmap = try self.allocator.alloc(u8, bitmap_size);

        if (self.outline) |outline| {
            try self.rasterizeOutline(outline, options);
        } else {
            // Create a simple rectangular bitmap for testing
            @memset(self.bitmap.?, 0);
            self.createTestGlyph();
        }
    }

    fn createTestGlyph(self: *Self) void {
        const bitmap = self.bitmap orelse return;

        // Create a simple rectangular character for testing
        const border = 2;
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const index = y * self.width + x;
                if (x < border or x >= self.width - border or
                    y < border or y >= self.height - border) {
                    bitmap[index] = 255; // Border
                } else {
                    bitmap[index] = 0; // Interior
                }
            }
        }
    }

    fn rasterizeOutline(self: *Self, outline: GlyphOutline, options: RenderOptions) !void {
        // Simplified rasterization
        const bitmap = self.bitmap orelse return;
        @memset(bitmap, 0);

        // For each contour, draw simple lines
        for (outline.contours) |contour| {
            for (0..contour.points.len) |i| {
                const point = contour.points[i];
                const x = @as(u32, @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(self.width - 1)), point.x))));
                const y = @as(u32, @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(self.height - 1)), point.y))));

                if (x < self.width and y < self.height) {
                    bitmap[y * self.width + x] = if (options.anti_aliasing) 128 else 255;
                }
            }
        }
    }

    pub fn getBitmap(self: *Self) ?[]const u8 {
        return self.bitmap;
    }

    pub fn getMetrics(self: *Self) GlyphMetrics {
        return GlyphMetrics{
            .width = self.width,
            .height = self.height,
            .advance_width = self.advance_width,
            .advance_height = self.advance_height,
            .bearing_x = self.bearing_x,
            .bearing_y = self.bearing_y,
        };
    }

    pub fn scale(self: *Self, scale_factor: f32) void {
        self.advance_width *= scale_factor;
        self.advance_height *= scale_factor;
        self.bearing_x *= scale_factor;
        self.bearing_y *= scale_factor;
        self.width = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.width)) * scale_factor));
        self.height = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.height)) * scale_factor));

        // Invalidate bitmap - will need re-rendering
        if (self.bitmap) |bitmap| {
            self.allocator.free(bitmap);
            self.bitmap = null;
        }
    }

    pub fn transform(self: *Self, matrix: TransformMatrix) void {
        if (self.outline) |*outline| {
            outline.transform(matrix);
        }

        // Transform metrics
        const transformed_advance = matrix.transformPoint(.{ .x = self.advance_width, .y = 0 });
        self.advance_width = transformed_advance.x;

        // Invalidate bitmap
        if (self.bitmap) |bitmap| {
            self.allocator.free(bitmap);
            self.bitmap = null;
        }
    }
};

pub const GlyphMetrics = struct {
    width: u32,
    height: u32,
    advance_width: f32,
    advance_height: f32,
    bearing_x: f32,
    bearing_y: f32,
};

pub const GlyphOutline = struct {
    contours: []Contour,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GlyphOutline, allocator: std.mem.Allocator) void {
        for (self.contours) |*contour| {
            contour.deinit(allocator);
        }
        allocator.free(self.contours);
    }

    pub fn transform(self: *GlyphOutline, matrix: TransformMatrix) void {
        for (self.contours) |*contour| {
            for (contour.points) |*point| {
                const transformed = matrix.transformPoint(point.*);
                point.* = transformed;
            }
        }
    }
};

pub const Contour = struct {
    points: []Point,
    is_closed: bool,

    pub fn deinit(self: *Contour, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
    }
};

pub const Point = struct {
    x: f32,
    y: f32,
    on_curve: bool = true,
};

pub const RenderOptions = struct {
    anti_aliasing: bool = true,
    hinting: bool = true,
    subpixel: bool = false,
    gamma_correction: f32 = 1.8,
};

pub const TransformMatrix = struct {
    a: f32 = 1.0,
    b: f32 = 0.0,
    c: f32 = 0.0,
    d: f32 = 1.0,
    e: f32 = 0.0,
    f: f32 = 0.0,

    pub fn transformPoint(self: TransformMatrix, point: Point) Point {
        return Point{
            .x = self.a * point.x + self.c * point.y + self.e,
            .y = self.b * point.x + self.d * point.y + self.f,
            .on_curve = point.on_curve,
        };
    }

    pub fn scale(scale_x: f32, scale_y: f32) TransformMatrix {
        return TransformMatrix{
            .a = scale_x,
            .d = scale_y,
        };
    }

    pub fn rotate(angle_radians: f32) TransformMatrix {
        const cos_a = std.math.cos(angle_radians);
        const sin_a = std.math.sin(angle_radians);
        return TransformMatrix{
            .a = cos_a,
            .b = sin_a,
            .c = -sin_a,
            .d = cos_a,
        };
    }

    pub fn translate(dx: f32, dy: f32) TransformMatrix {
        return TransformMatrix{
            .e = dx,
            .f = dy,
        };
    }
};

test "Glyph creation and rendering" {
    const allocator = std.testing.allocator;

    var glyph = try Glyph.init(allocator, 16.0);
    defer glyph.deinit(allocator);

    try std.testing.expect(glyph.size == 16.0);
    try std.testing.expect(glyph.bitmap == null);

    try glyph.renderBitmap(.{});
    try std.testing.expect(glyph.bitmap != null);

    const metrics = glyph.getMetrics();
    try std.testing.expect(metrics.width > 0);
    try std.testing.expect(metrics.height > 0);
}

test "Glyph transformation" {
    const allocator = std.testing.allocator;

    var glyph = try Glyph.init(allocator, 16.0);
    defer glyph.deinit(allocator);

    const original_width = glyph.advance_width;
    glyph.scale(2.0);
    try std.testing.expect(glyph.advance_width == original_width * 2.0);
}