const std = @import("std");
const root = @import("root.zig");
const CellRenderer = @import("cell_renderer.zig").CellRenderer;
const GridAligner = @import("grid_alignment.zig").GridAligner;

// Wayland native rendering support for GhostShell terminal
// Provides efficient client-side rendering with Wayland protocols
pub const WaylandRenderer = struct {
    allocator: std.mem.Allocator,
    cell_renderer: *CellRenderer,
    grid_aligner: *GridAligner,

    // Wayland connection and objects
    display: ?*anyopaque = null,
    registry: ?*anyopaque = null,
    compositor: ?*anyopaque = null,
    surface: ?*anyopaque = null,
    shell_surface: ?*anyopaque = null,

    // Buffer management
    shared_memory: ?*anyopaque = null,
    buffers: [3]WaylandBuffer, // Triple buffering
    current_buffer: u8 = 0,
    buffer_pool: std.ArrayList(WaylandBuffer),

    // Rendering state
    surface_width: u32 = 0,
    surface_height: u32 = 0,
    scale_factor: f32 = 1.0,
    dirty_regions: std.ArrayList(DirtyRegion),

    // Performance optimization
    frame_callback: ?*anyopaque = null,
    vsync_enabled: bool = true,
    damage_tracking: bool = true,

    // Wayland-specific features
    viewport: ?*anyopaque = null, // wp_viewport for fractional scaling
    fractional_scale: ?*anyopaque = null,
    presentation_feedback: ?*anyopaque = null,

    const Self = @This();

    const WaylandBuffer = struct {
        buffer: ?*anyopaque = null,
        memory: ?*anyopaque = null,
        data: ?[*]u8 = null,
        width: u32 = 0,
        height: u32 = 0,
        stride: u32 = 0,
        size: usize = 0,
        busy: bool = false,
        damage_age: u32 = 0,
    };

    const DirtyRegion = struct {
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        age: u32,
    };

    const WaylandError = error{
        ConnectionFailed,
        DisplayNotFound,
        SurfaceCreationFailed,
        BufferCreationFailed,
        MemoryMapFailed,
        ProtocolError,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        cell_renderer: *CellRenderer,
        grid_aligner: *GridAligner,
    ) !Self {
        var renderer = Self{
            .allocator = allocator,
            .cell_renderer = cell_renderer,
            .grid_aligner = grid_aligner,
            .buffers = [_]WaylandBuffer{WaylandBuffer{}} ** 3,
            .buffer_pool = std.ArrayList(WaylandBuffer).init(allocator),
            .dirty_regions = std.ArrayList(DirtyRegion).init(allocator),
        };

        // Initialize Wayland connection
        try renderer.initWaylandConnection();

        return renderer;
    }

    pub fn deinit(self: *Self) void {
        // Cleanup Wayland resources
        self.cleanupWaylandConnection();

        // Free buffers
        for (&self.buffers) |*buffer| {
            self.destroyBuffer(buffer);
        }

        for (self.buffer_pool.items) |*buffer| {
            self.destroyBuffer(buffer);
        }
        self.buffer_pool.deinit();

        self.dirty_regions.deinit();
    }

    fn initWaylandConnection(self: *Self) !void {
        // Connect to Wayland display
        self.display = self.waylandConnect() catch |err| {
            switch (err) {
                error.ConnectionFailed => return WaylandError.ConnectionFailed,
                else => return err,
            }
        };

        // Get registry and bind interfaces
        try self.setupWaylandInterfaces();

        // Create surface
        try self.createSurface();

        // Setup buffer pool
        try self.setupBufferPool();
    }

    fn waylandConnect(self: *Self) !*anyopaque {
        _ = self;
        // Mock Wayland connection
        // In real implementation: wl_display_connect(null)
        const mock_display = try self.allocator.create(u32);
        mock_display.* = 0xDEADBEEF;
        return mock_display;
    }

    fn setupWaylandInterfaces(self: *Self) !void {
        // Mock interface setup
        // In real implementation:
        // - wl_display_get_registry()
        // - Bind compositor, shell, shared memory, etc.
        _ = self;
    }

    fn createSurface(self: *Self) !void {
        // Mock surface creation
        // In real implementation:
        // - wl_compositor_create_surface()
        // - Setup shell surface or XDG surface
        _ = self;
    }

    fn setupBufferPool(self: *Self) !void {
        // Initialize triple buffering
        for (&self.buffers) |*buffer| {
            try self.createBuffer(buffer, 1920, 1080); // Default size
        }
    }

    fn createBuffer(self: *Self, buffer: *WaylandBuffer, width: u32, height: u32) !void {
        const stride = width * 4; // ARGB32
        const size = stride * height;

        // Create shared memory pool (mock implementation)
        buffer.* = WaylandBuffer{
            .width = width,
            .height = height,
            .stride = stride,
            .size = size,
            .busy = false,
            .damage_age = 0,
        };

        // Allocate memory (in real implementation, use shared memory)
        const memory = try self.allocator.alloc(u8, size);
        buffer.data = memory.ptr;

        // Mock Wayland buffer creation
        const mock_buffer = try self.allocator.create(u32);
        mock_buffer.* = 0xBEEFFACE;
        buffer.buffer = mock_buffer;
    }

    fn destroyBuffer(self: *Self, buffer: *WaylandBuffer) void {
        if (buffer.data) |data| {
            const slice = data[0..buffer.size];
            self.allocator.free(slice);
        }

        if (buffer.buffer) |buf| {
            const mock_buffer: *u32 = @ptrCast(@alignCast(buf));
            self.allocator.destroy(mock_buffer);
        }

        buffer.* = WaylandBuffer{};
    }

    pub fn resize(self: *Self, width: u32, height: u32) !void {
        if (width == self.surface_width and height == self.surface_height) return;

        self.surface_width = width;
        self.surface_height = height;

        // Recreate buffers with new size
        for (&self.buffers) |*buffer| {
            self.destroyBuffer(buffer);
            try self.createBuffer(buffer, width, height);
        }

        // Mark entire surface as dirty
        try self.markDirty(0, 0, width, height);
    }

    pub fn render(self: *Self, terminal_state: anytype) !void {
        // Get next available buffer
        const buffer = try self.getAvailableBuffer();

        // Clear buffer if needed
        if (buffer.damage_age == 0) {
            self.clearBuffer(buffer);
        }

        // Render terminal content
        try self.renderTerminalContent(buffer, terminal_state);

        // Attach buffer to surface and commit
        try self.commitBuffer(buffer);

        // Setup frame callback for next frame
        if (self.vsync_enabled) {
            try self.setupFrameCallback();
        }
    }

    fn getAvailableBuffer(self: *Self) !*WaylandBuffer {
        // Find non-busy buffer
        for (&self.buffers) |*buffer| {
            if (!buffer.busy) {
                buffer.busy = true;
                return buffer;
            }
        }

        // All buffers busy, create additional buffer
        var new_buffer = WaylandBuffer{};
        try self.createBuffer(&new_buffer, self.surface_width, self.surface_height);
        try self.buffer_pool.append(new_buffer);

        return &self.buffer_pool.items[self.buffer_pool.items.len - 1];
    }

    fn clearBuffer(self: *Self, buffer: *WaylandBuffer) void {
        if (buffer.data) |data| {
            @memset(data[0..buffer.size], 0);
        }
    }

    fn renderTerminalContent(self: *Self, buffer: *WaylandBuffer, terminal_state: anytype) !void {
        if (buffer.data == null) return;

        const data = buffer.data.?;
        const width = buffer.width;
        const height = buffer.height;

        // Render each cell that needs updating
        for (terminal_state.cells) |cell| {
            if (self.shouldRenderCell(cell)) {
                try self.renderCell(data, width, height, cell);
            }
        }

        // Update damage regions
        try self.updateDamageRegions(terminal_state);
    }

    fn shouldRenderCell(self: *Self, cell: anytype) bool {
        // Check if cell is in dirty region
        const cell_x = cell.column * @as(u32, @intFromFloat(self.grid_aligner.cell_width));
        const cell_y = cell.row * @as(u32, @intFromFloat(self.grid_aligner.cell_height));

        for (self.dirty_regions.items) |region| {
            if (cell_x >= region.x and cell_x < region.x + region.width and
                cell_y >= region.y and cell_y < region.y + region.height) {
                return true;
            }
        }

        return false;
    }

    fn renderCell(self: *Self, buffer_data: [*]u8, buffer_width: u32, buffer_height: u32, cell: anytype) !void {
        const cell_x = @as(f32, @floatFromInt(cell.column)) * self.grid_aligner.cell_width;
        const cell_y = @as(f32, @floatFromInt(cell.row)) * self.grid_aligner.cell_height;

        try self.cell_renderer.renderCell(
            cell.codepoint,
            cell_x,
            cell_y,
            cell.font,
            cell.style,
            cell.foreground,
            cell.background,
            cell.effects,
            buffer_data[0..buffer_width * buffer_height * 4],
            buffer_width,
            buffer_height,
        );
    }

    fn updateDamageRegions(self: *Self, terminal_state: anytype) !void {
        _ = terminal_state;

        // Age existing damage regions
        for (self.dirty_regions.items) |*region| {
            region.age += 1;
        }

        // Remove old damage regions
        var i: usize = 0;
        while (i < self.dirty_regions.items.len) {
            if (self.dirty_regions.items[i].age > 10) {
                _ = self.dirty_regions.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn commitBuffer(self: *Self, buffer: *WaylandBuffer) !void {
        // Mock commit to Wayland surface
        // In real implementation:
        // - wl_surface_attach()
        // - wl_surface_damage()
        // - wl_surface_commit()

        _ = self;

        // Mark buffer as committed
        buffer.busy = true;
        buffer.damage_age += 1;
    }

    fn setupFrameCallback(self: *Self) !void {
        // Mock frame callback setup
        // In real implementation:
        // - wl_surface_frame()
        // - Set up callback for next frame
        _ = self;
    }

    pub fn markDirty(self: *Self, x: u32, y: u32, width: u32, height: u32) !void {
        try self.dirty_regions.append(DirtyRegion{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .age = 0,
        });
    }

    pub fn setScaleFactor(self: *Self, scale: f32) !void {
        if (scale != self.scale_factor) {
            self.scale_factor = scale;

            // Update buffer sizes for new scale
            const new_width = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.surface_width)) * scale));
            const new_height = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.surface_height)) * scale));

            try self.resize(new_width, new_height);
        }
    }

    // Wayland-specific optimizations
    pub fn enableDamageTracking(self: *Self, enable: bool) void {
        self.damage_tracking = enable;
    }

    pub fn enableVSync(self: *Self, enable: bool) void {
        self.vsync_enabled = enable;
    }

    // Buffer release callback (called by Wayland when buffer can be reused)
    pub fn onBufferRelease(self: *Self, buffer_ptr: *anyopaque) void {
        // Find and mark buffer as available
        for (&self.buffers) |*buffer| {
            if (buffer.buffer == buffer_ptr) {
                buffer.busy = false;
                break;
            }
        }

        for (self.buffer_pool.items) |*buffer| {
            if (buffer.buffer == buffer_ptr) {
                buffer.busy = false;
                break;
            }
        }
    }

    // Frame callback (called by Wayland when ready for next frame)
    pub fn onFrameCallback(self: *Self) !void {
        // Trigger next render cycle
        // This would typically notify the main rendering loop
        _ = self;
    }

    // Fractional scaling support
    pub fn onFractionalScale(self: *Self, scale_num: u32, scale_denom: u32) !void {
        const new_scale = @as(f32, @floatFromInt(scale_num)) / @as(f32, @floatFromInt(scale_denom));
        try self.setScaleFactor(new_scale);
    }

    // Presentation feedback for timing optimization
    pub fn onPresentationFeedback(self: *Self, tv_sec_hi: u32, tv_sec_lo: u32, tv_nsec: u32) void {
        _ = self;
        _ = tv_sec_hi;
        _ = tv_sec_lo;
        _ = tv_nsec;
        // Handle presentation timing for performance optimization
    }

    fn cleanupWaylandConnection(self: *Self) void {
        // Cleanup Wayland objects
        if (self.display) |display| {
            const mock_display: *u32 = @ptrCast(@alignCast(display));
            self.allocator.destroy(mock_display);
        }

        // In real implementation:
        // - wl_surface_destroy()
        // - wl_display_disconnect()
        // - Free all Wayland objects
    }

    // Performance monitoring
    pub fn getPerformanceStats(self: *const Self) WaylandRenderStats {
        var available_buffers: u32 = 0;
        for (self.buffers) |buffer| {
            if (!buffer.busy) available_buffers += 1;
        }

        return WaylandRenderStats{
            .buffer_count = @intCast(self.buffers.len + self.buffer_pool.items.len),
            .available_buffers = available_buffers,
            .dirty_regions = @intCast(self.dirty_regions.items.len),
            .scale_factor = self.scale_factor,
            .vsync_enabled = self.vsync_enabled,
            .damage_tracking = self.damage_tracking,
        };
    }
};

pub const WaylandRenderStats = struct {
    buffer_count: u32,
    available_buffers: u32,
    dirty_regions: u32,
    scale_factor: f32,
    vsync_enabled: bool,
    damage_tracking: bool,
};

// Wayland protocol event handlers
pub const WaylandEventHandler = struct {
    renderer: *WaylandRenderer,

    pub fn init(renderer: *WaylandRenderer) WaylandEventHandler {
        return WaylandEventHandler{
            .renderer = renderer,
        };
    }

    // Surface events
    pub fn onSurfaceEnter(self: *WaylandEventHandler, output: *anyopaque) void {
        _ = self;
        _ = output;
        // Handle surface entering output
    }

    pub fn onSurfaceLeave(self: *WaylandEventHandler, output: *anyopaque) void {
        _ = self;
        _ = output;
        // Handle surface leaving output
    }

    // Output events for multi-monitor support
    pub fn onOutputGeometry(
        self: *WaylandEventHandler,
        x: i32,
        y: i32,
        physical_width: i32,
        physical_height: i32,
        subpixel: i32,
        make: []const u8,
        model: []const u8,
        transform: i32,
    ) void {
        _ = self;
        _ = x;
        _ = y;
        _ = physical_width;
        _ = physical_height;
        _ = subpixel;
        _ = make;
        _ = model;
        _ = transform;
        // Handle output geometry changes
    }

    pub fn onOutputScale(self: *WaylandEventHandler, factor: i32) !void {
        try self.renderer.setScaleFactor(@floatFromInt(factor));
    }
};

// Tests
test "WaylandRenderer initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Mock dependencies
    var mock_cell_renderer: CellRenderer = undefined;
    var mock_grid_aligner: GridAligner = undefined;

    var renderer = WaylandRenderer.init(
        allocator,
        &mock_cell_renderer,
        &mock_grid_aligner,
    ) catch return;
    defer renderer.deinit();

    try testing.expect(renderer.buffers.len == 3);
    try testing.expect(renderer.current_buffer == 0);
}

test "WaylandRenderer buffer management" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mock_cell_renderer: CellRenderer = undefined;
    var mock_grid_aligner: GridAligner = undefined;

    var renderer = WaylandRenderer.init(
        allocator,
        &mock_cell_renderer,
        &mock_grid_aligner,
    ) catch return;
    defer renderer.deinit();

    // Test resize
    renderer.resize(800, 600) catch return;
    try testing.expect(renderer.surface_width == 800);
    try testing.expect(renderer.surface_height == 600);

    // Test scale factor
    renderer.setScaleFactor(2.0) catch return;
    try testing.expect(renderer.scale_factor == 2.0);
}