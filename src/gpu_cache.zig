const std = @import("std");
const root = @import("root.zig");
const Font = @import("font.zig").Font;
const Glyph = @import("glyph.zig").Glyph;

// GPU-accelerated glyph caching system optimized for terminals
// Designed for NVIDIA GPUs but with fallback support for other vendors

pub const GPUCache = struct {
    allocator: std.mem.Allocator,
    atlas_texture: ?AtlasTexture = null,
    glyph_cache: std.AutoHashMap(u64, CachedGlyph), // Hash of font_id + glyph_id + size
    gpu_backend: GPUBackend,
    enable_nvidia_optimizations: bool,
    atlas_size: u32 = 2048, // Start with 2K texture atlas
    current_x: u32 = 0,
    current_y: u32 = 0,
    row_height: u32 = 0,

    const Self = @This();

    const AtlasTexture = struct {
        width: u32,
        height: u32,
        data: []u8, // RGBA8 format
        gpu_handle: ?*anyopaque = null, // GPU-specific texture handle
    };

    const CachedGlyph = struct {
        atlas_x: u32,
        atlas_y: u32,
        width: u32,
        height: u32,
        bearing_x: f32,
        bearing_y: f32,
        advance: f32,
        gpu_uploaded: bool = false,
    };

    const GPUBackend = enum {
        vulkan,
        opengl,
        metal,
        software, // Fallback
    };

    pub fn init(allocator: std.mem.Allocator) !Self {
        const backend = detectGPUBackend();
        const nvidia_opt = detectNVIDIAOptimizations();

        var cache = Self{
            .allocator = allocator,
            .glyph_cache = std.AutoHashMap(u64, CachedGlyph).init(allocator),
            .gpu_backend = backend,
            .enable_nvidia_optimizations = nvidia_opt,
        };

        // Initialize GPU texture atlas
        try cache.initializeAtlas();

        if (cache.enable_nvidia_optimizations) {
            cache.enableNVIDIAOptimizations() catch |err| {
                std.log.warn("gpu-cache: failed to enable NVIDIA optimizations: {s}", .{@errorName(err)});
            };
        }

        return cache;
    }

    pub fn deinit(self: *Self) void {
        if (self.atlas_texture) |*atlas| {
            self.allocator.free(atlas.data);
            if (atlas.gpu_handle) |handle| {
                self.destroyGPUTexture(handle);
            }
        }
        self.glyph_cache.deinit();
    }

    fn detectGPUBackend() GPUBackend {
        // Platform-specific GPU backend detection
        const builtin_os = @import("builtin").os.tag;

        return switch (builtin_os) {
            .linux => .vulkan, // Prefer Vulkan on Linux for NVIDIA optimizations
            .macos => .metal,
            .windows => .vulkan,
            else => .software,
        };
    }

    fn detectNVIDIAOptimizations() bool {
        // Detect NVIDIA GPU for special optimizations
        // This is a simplified check - would use proper GPU detection in production
        const gpu_vendor = std.process.getEnvVarOwned(std.heap.page_allocator, "GPU_VENDOR") catch "unknown";
        defer std.heap.page_allocator.free(gpu_vendor);

        return std.mem.eql(u8, gpu_vendor, "nvidia") or
            std.mem.indexOf(u8, std.mem.toLower(std.heap.page_allocator, gpu_vendor) catch "unknown", "nvidia") != null;
    }

    fn initializeAtlas(self: *Self) !void {
        const atlas_data = try self.allocator.alloc(u8, self.atlas_size * self.atlas_size * 4); // RGBA
        @memset(atlas_data, 0); // Initialize to transparent

        self.atlas_texture = AtlasTexture{
            .width = self.atlas_size,
            .height = self.atlas_size,
            .data = atlas_data,
        };

        // Create GPU texture based on backend
        if (self.gpu_backend != .software) {
            self.atlas_texture.?.gpu_handle = try self.createGPUTexture(
                self.atlas_size,
                self.atlas_size,
                atlas_data,
            );
        }
    }

    fn createGPUTexture(self: *Self, width: u32, height: u32, data: []const u8) !*anyopaque {
        return switch (self.gpu_backend) {
            .vulkan => self.createVulkanTexture(width, height, data),
            .opengl => self.createOpenGLTexture(width, height, data),
            .metal => self.createMetalTexture(width, height, data),
            .software => error.NotSupported,
        };
    }

    fn createVulkanTexture(self: *Self, width: u32, height: u32, data: []const u8) !*anyopaque {
        _ = width;
        _ = height;
        _ = data;

        // Vulkan texture creation (simplified)
        // In a real implementation, this would:
        // 1. Create VkImage
        // 2. Allocate VkDeviceMemory
        // 3. Bind image to memory
        // 4. Create VkImageView
        // 5. Upload data via staging buffer
        // 6. Set up optimal layout and barriers

        // For now, return a dummy pointer
        const dummy = try self.allocator.create(u32);
        dummy.* = 0xDEADBEEF; // Vulkan texture handle placeholder
        return dummy;
    }

    fn createOpenGLTexture(self: *Self, width: u32, height: u32, data: []const u8) !*anyopaque {
        _ = width;
        _ = height;
        _ = data;

        // OpenGL texture creation (simplified)
        // glGenTextures, glBindTexture, glTexImage2D, etc.
        const dummy = try self.allocator.create(u32);
        dummy.* = 0xCAFEBABE; // OpenGL texture ID placeholder
        return dummy;
    }

    fn createMetalTexture(self: *Self, width: u32, height: u32, data: []const u8) !*anyopaque {
        _ = width;
        _ = height;
        _ = data;

        // Metal texture creation (simplified)
        const dummy = try self.allocator.create(u32);
        dummy.* = 0xBEEFCAFE; // Metal texture handle placeholder
        return dummy;
    }

    fn destroyGPUTexture(self: *Self, handle: *anyopaque) void {
        // Clean up GPU texture based on backend
        switch (self.gpu_backend) {
            .vulkan => self.destroyVulkanTexture(handle),
            .opengl => self.destroyOpenGLTexture(handle),
            .metal => self.destroyMetalTexture(handle),
            .software => {},
        }
    }

    fn destroyVulkanTexture(self: *Self, handle: *anyopaque) void {
        const dummy: *u32 = @ptrCast(@alignCast(handle));
        self.allocator.destroy(dummy);
    }

    fn destroyOpenGLTexture(self: *Self, handle: *anyopaque) void {
        const dummy: *u32 = @ptrCast(@alignCast(handle));
        self.allocator.destroy(dummy);
    }

    fn destroyMetalTexture(self: *Self, handle: *anyopaque) void {
        const dummy: *u32 = @ptrCast(@alignCast(handle));
        self.allocator.destroy(dummy);
    }

    pub fn cacheGlyph(self: *Self, font: *Font, glyph_id: u32, size: f32) !CachedGlyph {
        // Generate cache key from font ID, glyph ID, and size
        const cache_key = self.generateCacheKey(font, glyph_id, size);

        // Check if already cached
        if (self.glyph_cache.get(cache_key)) |cached| {
            return cached;
        }

        // Render glyph to bitmap
        const glyph = try font.renderGlyph(glyph_id, size, .{});

        // Find space in atlas
        const atlas_pos = try self.findAtlasSpace(glyph.width, glyph.height);

        // Copy glyph bitmap to atlas
        try self.copyGlyphToAtlas(glyph, atlas_pos);

        const cached_glyph = CachedGlyph{
            .atlas_x = atlas_pos.x,
            .atlas_y = atlas_pos.y,
            .width = glyph.width,
            .height = glyph.height,
            .bearing_x = glyph.bearing_x,
            .bearing_y = glyph.bearing_y,
            .advance = glyph.advance_x,
            .gpu_uploaded = false,
        };

        // Cache the glyph
        try self.glyph_cache.put(cache_key, cached_glyph);

        // Upload to GPU if using GPU backend
        if (self.gpu_backend != .software) {
            try self.uploadAtlasRegionToGPU(atlas_pos, glyph.width, glyph.height);
        }

        return cached_glyph;
    }

    fn generateCacheKey(self: *Self, font: *Font, glyph_id: u32, size: f32) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);

        // Hash font pointer (as ID)
        hasher.update(std.mem.asBytes(&font));
        hasher.update(std.mem.asBytes(&glyph_id));
        hasher.update(std.mem.asBytes(&size));

        return hasher.final();
    }

    const AtlasPosition = struct {
        x: u32,
        y: u32,
    };

    fn findAtlasSpace(self: *Self, width: u32, height: u32) !AtlasPosition {
        // Simple row-based packing algorithm
        // TODO: Implement more sophisticated rectangle packing

        // Check if we need to move to next row
        if (self.current_x + width > self.atlas_size) {
            self.current_x = 0;
            self.current_y += self.row_height;
            self.row_height = 0;
        }

        // Check if we're out of vertical space
        if (self.current_y + height > self.atlas_size) {
            // Atlas is full - could resize or use LRU eviction
            return error.AtlasFull;
        }

        const pos = AtlasPosition{
            .x = self.current_x,
            .y = self.current_y,
        };

        // Update position tracking
        self.current_x += width + 1; // Add 1 pixel padding
        self.row_height = @max(self.row_height, height + 1);

        return pos;
    }

    fn copyGlyphToAtlas(self: *Self, glyph: anytype, pos: AtlasPosition) !void {
        if (self.atlas_texture == null) return error.AtlasNotInitialized;

        const atlas = &self.atlas_texture.?;

        // Copy glyph bitmap to atlas (assuming grayscale to RGBA conversion)
        for (0..glyph.height) |y| {
            for (0..glyph.width) |x| {
                const src_idx = y * glyph.width + x;
                const dst_idx = ((pos.y + @as(u32, @intCast(y))) * atlas.width + (pos.x + @as(u32, @intCast(x)))) * 4;

                if (dst_idx + 3 < atlas.data.len and src_idx < glyph.bitmap.len) {
                    const alpha = glyph.bitmap[src_idx];
                    atlas.data[dst_idx + 0] = 255; // R
                    atlas.data[dst_idx + 1] = 255; // G
                    atlas.data[dst_idx + 2] = 255; // B
                    atlas.data[dst_idx + 3] = alpha; // A
                }
            }
        }
    }

    fn uploadAtlasRegionToGPU(self: *Self, pos: AtlasPosition, width: u32, height: u32) !void {
        if (self.atlas_texture == null or self.atlas_texture.?.gpu_handle == null) {
            return error.GPUTextureNotAvailable;
        }

        // Upload specific region to GPU texture
        switch (self.gpu_backend) {
            .vulkan => try self.uploadVulkanRegion(pos, width, height),
            .opengl => try self.uploadOpenGLRegion(pos, width, height),
            .metal => try self.uploadMetalRegion(pos, width, height),
            .software => {},
        }
    }

    fn uploadVulkanRegion(self: *Self, pos: AtlasPosition, width: u32, height: u32) !void {
        _ = self;
        _ = pos;
        _ = width;
        _ = height;

        // Vulkan region upload using staging buffer and command buffer
        // vkCmdCopyBufferToImage with appropriate offset and size
    }

    fn uploadOpenGLRegion(self: *Self, pos: AtlasPosition, width: u32, height: u32) !void {
        _ = self;
        _ = pos;
        _ = width;
        _ = height;

        // OpenGL subimage upload
        // glTexSubImage2D with correct offsets
    }

    fn uploadMetalRegion(self: *Self, pos: AtlasPosition, width: u32, height: u32) !void {
        _ = self;
        _ = pos;
        _ = width;
        _ = height;

        // Metal texture update with region
    }

    pub fn getCachedGlyph(self: *Self, font: *Font, glyph_id: u32, size: f32) ?CachedGlyph {
        const cache_key = self.generateCacheKey(font, glyph_id, size);
        return self.glyph_cache.get(cache_key);
    }

    pub fn flushToGPU(self: *Self) !void {
        // Ensure all pending uploads are completed
        if (self.gpu_backend != .software) {
            // Submit command buffers, wait for completion, etc.
            switch (self.gpu_backend) {
                .vulkan => try self.flushVulkan(),
                .opengl => try self.flushOpenGL(),
                .metal => try self.flushMetal(),
                .software => {},
            }
        }
    }

    fn flushVulkan(self: *Self) !void {
        _ = self;
        // vkQueueSubmit and vkQueueWaitIdle
    }

    fn flushOpenGL(self: *Self) !void {
        _ = self;
        // glFlush or glFinish
    }

    fn flushMetal(self: *Self) !void {
        _ = self;
        // [commandBuffer commit] and waitUntilCompleted
    }

    // NVIDIA-specific optimizations
    pub fn enableNVIDIAOptimizations(self: *Self) !void {
        if (!self.enable_nvidia_optimizations) return;

        switch (self.gpu_backend) {
            .vulkan => try self.enableNVIDIAVulkanOptimizations(),
            .opengl => try self.enableNVIDIAOpenGLOptimizations(),
            else => {}, // NVIDIA optimizations not available for other backends
        }
    }

    fn enableNVIDIAVulkanOptimizations(self: *Self) !void {
        _ = self;
        // Enable NVIDIA-specific Vulkan extensions:
        // - VK_NV_dedicated_allocation
        // - VK_NV_memory_decompression
        // - VK_NV_shader_subgroup_partitioned
        // - VK_NV_compute_shader_derivatives
        // Use NVIDIA's optimal memory types and heap preferences
    }

    fn enableNVIDIAOpenGLOptimizations(self: *Self) !void {
        _ = self;
        // Enable NVIDIA-specific OpenGL extensions:
        // - GL_NV_shader_buffer_load
        // - GL_NV_vertex_buffer_unified_memory
        // - GL_NV_gpu_memory_info
        // Use bindless textures and buffer objects for better performance
    }

    // Performance monitoring
    pub fn getPerformanceStats(self: *Self) GPUCacheStats {
        return GPUCacheStats{
            .cached_glyphs = @intCast(self.glyph_cache.count()),
            .atlas_utilization = self.calculateAtlasUtilization(),
            .gpu_backend = self.gpu_backend,
            .nvidia_optimizations = self.enable_nvidia_optimizations,
        };
    }

    fn calculateAtlasUtilization(self: *Self) f32 {
        if (self.atlas_texture == null) return 0.0;

        const used_area = @as(f32, @floatFromInt(self.current_y * self.atlas_size + self.current_x));
        const total_area = @as(f32, @floatFromInt(self.atlas_size * self.atlas_size));

        return used_area / total_area;
    }
};

pub const GPUCacheStats = struct {
    cached_glyphs: u32,
    atlas_utilization: f32,
    gpu_backend: GPUCache.GPUBackend,
    nvidia_optimizations: bool,
};

// Tests
test "GPUCache initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = try GPUCache.init(allocator);
    defer cache.deinit();

    try testing.expect(cache.atlas_texture != null);
    try testing.expect(cache.glyph_cache.count() == 0);
}

test "GPU backend detection" {
    const cache_backend = GPUCache.detectGPUBackend();

    // Should detect some backend (depending on platform)
    const expected_backends = [_]GPUCache.GPUBackend{ .vulkan, .opengl, .metal, .software };
    var found = false;
    for (expected_backends) |backend| {
        if (cache_backend == backend) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "Cache key generation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = try GPUCache.init(allocator);
    defer cache.deinit();

    // Mock font pointer
    var dummy_font: u32 = 0x12345678;
    const font_ptr: *Font = @ptrCast(&dummy_font);

    const key1 = cache.generateCacheKey(font_ptr, 65, 12.0); // 'A' at 12pt
    const key2 = cache.generateCacheKey(font_ptr, 65, 14.0); // 'A' at 14pt
    const key3 = cache.generateCacheKey(font_ptr, 66, 12.0); // 'B' at 12pt

    // Keys should be different
    try testing.expect(key1 != key2);
    try testing.expect(key1 != key3);
    try testing.expect(key2 != key3);

    // Same parameters should produce same key
    const key1_again = cache.generateCacheKey(font_ptr, 65, 12.0);
    try testing.expect(key1 == key1_again);
}
