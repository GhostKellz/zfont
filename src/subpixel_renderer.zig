const std = @import("std");
const root = @import("root.zig");
const Glyph = @import("glyph.zig");

pub const SubpixelRenderer = struct {
    allocator: std.mem.Allocator,
    filter_weights: FilterWeights,
    gamma_lut: [256]u8,
    subpixel_order: SubpixelOrder,

    const Self = @This();

    const FilterWeights = struct {
        weights: [5]f32,

        pub fn init(filter_type: FilterType) FilterWeights {
            return switch (filter_type) {
                .none => FilterWeights{ .weights = [_]f32{ 0, 0, 1, 0, 0 } },
                .light => FilterWeights{ .weights = [_]f32{ 0.2, 0.4, 0.8, 0.4, 0.2 } },
                .normal => FilterWeights{ .weights = [_]f32{ 0.1, 0.3, 1.0, 0.3, 0.1 } },
                .strong => FilterWeights{ .weights = [_]f32{ 0.05, 0.25, 1.0, 0.25, 0.05 } },
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator, options: SubpixelOptions) Self {
        var renderer = Self{
            .allocator = allocator,
            .filter_weights = FilterWeights.init(options.filter_type),
            .gamma_lut = undefined,
            .subpixel_order = options.subpixel_order,
        };

        renderer.generateGammaLUT(options.gamma);
        return renderer;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    fn generateGammaLUT(self: *Self, gamma: f32) void {
        for (0..256) |i| {
            const normalized = @as(f32, @floatFromInt(i)) / 255.0;
            const corrected = std.math.pow(f32, normalized, 1.0 / gamma);
            self.gamma_lut[i] = @as(u8, @intFromFloat(@min(255.0, corrected * 255.0)));
        }
    }

    pub fn renderSubpixel(self: *Self, glyph: *Glyph.Glyph, options: SubpixelRenderOptions) !SubpixelBitmap {
        // Create high-resolution bitmap (3x horizontal resolution)
        const hr_width = glyph.width * 3;
        const hr_height = glyph.height;

        const hr_bitmap = try self.allocator.alloc(u8, hr_width * hr_height);
        defer self.allocator.free(hr_bitmap);
        @memset(hr_bitmap, 0);

        // Render at high resolution
        try self.renderHighResolution(glyph, hr_bitmap, hr_width, hr_height, options);

        // Apply subpixel filtering
        const filtered_bitmap = try self.allocator.alloc(u8, hr_width * hr_height);
        defer self.allocator.free(filtered_bitmap);

        try self.applySubpixelFilter(hr_bitmap, filtered_bitmap, hr_width, hr_height);

        // Convert to RGB format based on subpixel order
        const rgb_bitmap = try self.convertToRGB(filtered_bitmap, hr_width, hr_height);

        return SubpixelBitmap{
            .data = rgb_bitmap,
            .width = glyph.width,
            .height = glyph.height,
            .subpixel_order = self.subpixel_order,
        };
    }

    fn renderHighResolution(self: *Self, glyph: *Glyph.Glyph, bitmap: []u8, width: u32, height: u32, options: SubpixelRenderOptions) !void {
        _ = options;

        if (glyph.outline) |outline| {
            try self.rasterizeOutlineHR(outline, bitmap, width, height);
        } else if (glyph.bitmap) |glyph_bitmap| {
            // Scale up existing bitmap
            try self.scaleUpBitmap(glyph_bitmap, glyph.width, glyph.height, bitmap, width, height);
        } else {
            // Generate test pattern
            self.generateTestPatternHR(bitmap, width, height);
        }
    }

    fn rasterizeOutlineHR(self: *Self, outline: Glyph.GlyphOutline, bitmap: []u8, width: u32, height: u32) !void {
        // High-resolution rasterization with oversampling
        const oversample_x = 3; // 3x horizontal oversampling
        const oversample_y = 1; // No vertical oversampling for subpixel

        for (outline.contours) |contour| {
            if (contour.points.len < 2) continue;

            for (0..contour.points.len) |i| {
                const p1 = contour.points[i];
                const p2 = contour.points[(i + 1) % contour.points.len];

                try self.drawLineHR(bitmap, width, height, p1, p2, oversample_x, oversample_y);
            }
        }
    }

    fn drawLineHR(self: *Self, bitmap: []u8, width: u32, height: u32, p1: Glyph.Point, p2: Glyph.Point, oversample_x: u32, oversample_y: u32) !void {
        _ = self;
        _ = oversample_y;

        // Scale coordinates for high resolution
        const x1 = @as(i32, @intFromFloat(p1.x * @as(f32, @floatFromInt(oversample_x))));
        const y1 = @as(i32, @intFromFloat(p1.y));
        const x2 = @as(i32, @intFromFloat(p2.x * @as(f32, @floatFromInt(oversample_x))));
        const y2 = @as(i32, @intFromFloat(p2.y));

        // Bresenham's line algorithm with antialiasing
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
                bitmap[index] = @min(255, bitmap[index] + 64); // Accumulate coverage
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

    fn scaleUpBitmap(self: *Self, source: []const u8, src_width: u32, src_height: u32, dest: []u8, dest_width: u32, dest_height: u32) !void {
        _ = self;

        const scale_x = @as(f32, @floatFromInt(dest_width)) / @as(f32, @floatFromInt(src_width));
        const scale_y = @as(f32, @floatFromInt(dest_height)) / @as(f32, @floatFromInt(src_height));

        for (0..dest_height) |y| {
            for (0..dest_width) |x| {
                const src_x = @as(u32, @intFromFloat(@as(f32, @floatFromInt(x)) / scale_x));
                const src_y = @as(u32, @intFromFloat(@as(f32, @floatFromInt(y)) / scale_y));

                if (src_x < src_width and src_y < src_height) {
                    const src_index = src_y * src_width + src_x;
                    const dest_index = y * dest_width + x;
                    dest[dest_index] = source[src_index];
                }
            }
        }
    }

    fn generateTestPatternHR(self: *Self, bitmap: []u8, width: u32, height: u32) void {
        _ = self;

        // Generate a test pattern for subpixel rendering
        for (0..height) |y| {
            for (0..width) |x| {
                const index = y * width + x;

                // Create a gradient pattern
                const intensity = @as(u8, @intCast((x * 255) / width));
                bitmap[index] = intensity;
            }
        }
    }

    fn applySubpixelFilter(self: *Self, source: []const u8, dest: []u8, width: u32, height: u32) !void {
        for (0..height) |y| {
            for (0..width) |x| {
                var filtered_value: f32 = 0;

                // Apply horizontal filter
                for (0..5) |i| {
                    const offset_x = @as(i32, @intCast(x)) + @as(i32, @intCast(i)) - 2;
                    if (offset_x >= 0 and offset_x < width) {
                        const src_index = y * width + @as(u32, @intCast(offset_x));
                        filtered_value += @as(f32, @floatFromInt(source[src_index])) * self.filter_weights.weights[i];
                    }
                }

                const dest_index = y * width + x;
                dest[dest_index] = @as(u8, @intFromFloat(@max(0, @min(255, filtered_value))));
            }
        }
    }

    fn convertToRGB(self: *Self, filtered: []const u8, hr_width: u32, hr_height: u32) ![]u8 {
        const rgb_width = hr_width / 3;
        var rgb_bitmap = try self.allocator.alloc(u8, rgb_width * hr_height * 3);

        for (0..hr_height) |y| {
            for (0..rgb_width) |x| {
                const src_base = y * hr_width + x * 3;
                const dest_base = (y * rgb_width + x) * 3;

                // Extract subpixel values
                var r = filtered[src_base];
                var g = filtered[src_base + 1];
                var b = filtered[src_base + 2];

                // Apply gamma correction
                r = self.gamma_lut[r];
                g = self.gamma_lut[g];
                b = self.gamma_lut[b];

                // Store according to subpixel order
                switch (self.subpixel_order) {
                    .rgb => {
                        rgb_bitmap[dest_base] = r;
                        rgb_bitmap[dest_base + 1] = g;
                        rgb_bitmap[dest_base + 2] = b;
                    },
                    .bgr => {
                        rgb_bitmap[dest_base] = b;
                        rgb_bitmap[dest_base + 1] = g;
                        rgb_bitmap[dest_base + 2] = r;
                    },
                    .vrgb => {
                        // Vertical RGB - different handling needed
                        rgb_bitmap[dest_base] = r;
                        rgb_bitmap[dest_base + 1] = g;
                        rgb_bitmap[dest_base + 2] = b;
                    },
                    .vbgr => {
                        // Vertical BGR - different handling needed
                        rgb_bitmap[dest_base] = b;
                        rgb_bitmap[dest_base + 1] = g;
                        rgb_bitmap[dest_base + 2] = r;
                    },
                }
            }
        }

        return rgb_bitmap;
    }

    pub fn setGamma(self: *Self, gamma: f32) void {
        self.generateGammaLUT(gamma);
    }

    pub fn setFilterType(self: *Self, filter_type: FilterType) void {
        self.filter_weights = FilterWeights.init(filter_type);
    }

    pub fn setSubpixelOrder(self: *Self, order: SubpixelOrder) void {
        self.subpixel_order = order;
    }
};

pub const SubpixelBitmap = struct {
    data: []u8, // RGB data
    width: u32,
    height: u32,
    subpixel_order: SubpixelOrder,

    pub fn deinit(self: *SubpixelBitmap, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub const SubpixelOptions = struct {
    filter_type: FilterType = .normal,
    gamma: f32 = 1.8,
    subpixel_order: SubpixelOrder = .rgb,
};

pub const SubpixelRenderOptions = struct {
    quality: RenderQuality = .normal,
    enable_gamma: bool = true,
};

pub const FilterType = enum {
    none,
    light,
    normal,
    strong,
};

pub const SubpixelOrder = enum {
    rgb,   // Red-Green-Blue horizontal
    bgr,   // Blue-Green-Red horizontal
    vrgb,  // Red-Green-Blue vertical
    vbgr,  // Blue-Green-Red vertical
};

pub const RenderQuality = enum {
    fast,
    normal,
    high,
};

test "SubpixelRenderer basic operations" {
    const allocator = std.testing.allocator;

    const options = SubpixelOptions{
        .filter_type = .normal,
        .gamma = 1.8,
        .subpixel_order = .rgb,
    };

    var renderer = SubpixelRenderer.init(allocator, options);
    defer renderer.deinit();

    // Test gamma LUT generation
    try std.testing.expect(renderer.gamma_lut[0] == 0);
    try std.testing.expect(renderer.gamma_lut[255] == 255);

    // Test filter weights
    try std.testing.expect(renderer.filter_weights.weights[2] == 1.0); // Center weight
}

test "Filter weights initialization" {
    const none_filter = SubpixelRenderer.FilterWeights.init(.none);
    try std.testing.expect(none_filter.weights[2] == 1.0);
    try std.testing.expect(none_filter.weights[0] == 0.0);

    const light_filter = SubpixelRenderer.FilterWeights.init(.light);
    try std.testing.expect(light_filter.weights[2] == 0.8);
    try std.testing.expect(light_filter.weights[1] == 0.4);
}

test "Subpixel order handling" {
    const allocator = std.testing.allocator;

    var renderer = SubpixelRenderer.init(allocator, .{});
    defer renderer.deinit();

    try std.testing.expect(renderer.subpixel_order == .rgb);

    renderer.setSubpixelOrder(.bgr);
    try std.testing.expect(renderer.subpixel_order == .bgr);
}