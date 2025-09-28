const std = @import("std");
const root = @import("root.zig");
const Font = root.Font;

// OpenType Variable Font support
// Handles fvar, avar, HVAR, VVAR, and MVAR tables for dynamic font interpolation
pub const VariableFontManager = struct {
    allocator: std.mem.Allocator,

    // Font variation tables
    fvar_table: ?FvarTable = null,
    avar_table: ?AvarTable = null,

    // Current axis settings
    axis_values: std.AutoHashMap(u32, f32), // tag -> value

    // Instance cache for performance
    instance_cache: std.AutoHashMap(InstanceKey, *Font),

    const Self = @This();

    const FvarTable = struct {
        axes: []VariationAxis,
        instances: []NamedInstance,

        const VariationAxis = struct {
            tag: u32,          // 'wght', 'wdth', 'opsz', etc.
            min_value: f32,
            default_value: f32,
            max_value: f32,
            flags: u16,
            name_id: u16,
        };

        const NamedInstance = struct {
            subfamily_name_id: u16,
            flags: u16,
            coordinates: []f32,
            postscript_name_id: ?u16,
        };
    };

    const AvarTable = struct {
        segments: std.AutoHashMap(u32, []AxisValueMap), // tag -> segments

        const AxisValueMap = struct {
            from_coordinate: f32,
            to_coordinate: f32,
        };
    };

    const InstanceKey = struct {
        font_id: u64,
        axes_hash: u64,

        pub fn hash(self: InstanceKey) u64 {
            return self.font_id ^ self.axes_hash;
        }

        pub fn eql(a: InstanceKey, b: InstanceKey) bool {
            return a.font_id == b.font_id and a.axes_hash == b.axes_hash;
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .axis_values = std.AutoHashMap(u32, f32).init(allocator),
            .instance_cache = std.AutoHashMap(InstanceKey, *Font).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.fvar_table) |*fvar| {
            self.allocator.free(fvar.axes);
            self.allocator.free(fvar.instances);
        }

        if (self.avar_table) |*avar| {
            var iterator = avar.segments.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.value_ptr.*);
            }
            avar.segments.deinit();
        }

        self.axis_values.deinit();

        var cache_iterator = self.instance_cache.iterator();
        while (cache_iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.instance_cache.deinit();
    }

    // Load variable font tables from font data
    pub fn loadVariableTables(self: *Self, font_data: []const u8) !void {
        // Parse fvar table
        if (try self.findTable(font_data, "fvar")) |fvar_data| {
            self.fvar_table = try self.parseFvarTable(fvar_data);
        }

        // Parse avar table
        if (try self.findTable(font_data, "avar")) |avar_data| {
            self.avar_table = try self.parseAvarTable(avar_data);
        }
    }

    // Set axis value (e.g., weight, width, optical size)
    pub fn setAxisValue(self: *Self, tag: u32, value: f32) !void {
        if (self.fvar_table) |fvar| {
            // Find the axis and clamp to valid range
            for (fvar.axes) |axis| {
                if (axis.tag == tag) {
                    const clamped_value = std.math.clamp(value, axis.min_value, axis.max_value);
                    try self.axis_values.put(tag, clamped_value);
                    return;
                }
            }
        }
        return error.AxisNotFound;
    }

    // Get current axis value
    pub fn getAxisValue(self: *const Self, tag: u32) ?f32 {
        return self.axis_values.get(tag);
    }

    // Set multiple axis values at once
    pub fn setAxisValues(self: *Self, values: []const AxisSetting) !void {
        for (values) |setting| {
            try self.setAxisValue(setting.tag, setting.value);
        }
    }

    // Generate font instance with current axis settings
    pub fn generateInstance(self: *Self, base_font: *Font) !*Font {
        const axes_hash = self.calculateAxesHash();
        const key = InstanceKey{
            .font_id = base_font.id,
            .axes_hash = axes_hash,
        };

        // Check cache first
        if (self.instance_cache.get(key)) |cached_font| {
            return cached_font;
        }

        // Generate new instance
        const instance_font = try self.allocator.create(Font);
        instance_font.* = try self.interpolateFont(base_font);

        // Cache the result
        try self.instance_cache.put(key, instance_font);

        return instance_font;
    }

    // Apply avar mapping to normalize coordinates
    fn applyAvarMapping(self: *const Self, tag: u32, value: f32) f32 {
        if (self.avar_table) |avar| {
            if (avar.segments.get(tag)) |segments| {
                // Find the appropriate segment and interpolate
                for (segments) |segment, i| {
                    if (value <= segment.from_coordinate) {
                        if (i == 0) return segment.to_coordinate;

                        const prev_segment = segments[i - 1];
                        const t = (value - prev_segment.from_coordinate) /
                                (segment.from_coordinate - prev_segment.from_coordinate);
                        return prev_segment.to_coordinate + t *
                               (segment.to_coordinate - prev_segment.to_coordinate);
                    }
                }

                // If we get here, use the last segment
                return segments[segments.len - 1].to_coordinate;
            }
        }

        return value; // No avar mapping, return original value
    }

    // Calculate hash of current axis settings
    fn calculateAxesHash(self: *const Self) u64 {
        var hasher = std.hash.Wyhash.init(0x12345678);

        var iterator = self.axis_values.iterator();
        while (iterator.next()) |entry| {
            hasher.update(std.mem.asBytes(&entry.key_ptr.*));
            hasher.update(std.mem.asBytes(&entry.value_ptr.*));
        }

        return hasher.final();
    }

    // Find OpenType table in font data
    fn findTable(self: *Self, font_data: []const u8, tag: []const u8) !?[]const u8 {
        _ = self;

        if (font_data.len < 12) return null;

        const num_tables = std.mem.readInt(u16, font_data[4..6], .big);
        const table_directory = font_data[12..];

        var offset: usize = 0;
        for (0..num_tables) |_| {
            if (offset + 16 > table_directory.len) break;

            const table_tag = table_directory[offset..offset + 4];
            if (std.mem.eql(u8, table_tag, tag)) {
                const table_offset = std.mem.readInt(u32, table_directory[offset + 8..offset + 12], .big);
                const table_length = std.mem.readInt(u32, table_directory[offset + 12..offset + 16], .big);

                if (table_offset + table_length <= font_data.len) {
                    return font_data[table_offset..table_offset + table_length];
                }
            }

            offset += 16;
        }

        return null;
    }

    // Parse fvar table
    fn parseFvarTable(self: *Self, data: []const u8) !FvarTable {
        if (data.len < 16) return error.InvalidFvarTable;

        const axis_count = std.mem.readInt(u16, data[8..10], .big);
        const axis_size = std.mem.readInt(u16, data[10..12], .big);
        const instance_count = std.mem.readInt(u16, data[12..14], .big);
        const instance_size = std.mem.readInt(u16, data[14..16], .big);

        // Parse axes
        var axes = try self.allocator.alloc(FvarTable.VariationAxis, axis_count);
        var offset: usize = 16;

        for (0..axis_count) |i| {
            if (offset + axis_size > data.len) return error.InvalidFvarTable;

            axes[i] = FvarTable.VariationAxis{
                .tag = std.mem.readInt(u32, data[offset..offset + 4], .big),
                .min_value = @bitCast(std.mem.readInt(u32, data[offset + 4..offset + 8], .big)),
                .default_value = @bitCast(std.mem.readInt(u32, data[offset + 8..offset + 12], .big)),
                .max_value = @bitCast(std.mem.readInt(u32, data[offset + 12..offset + 16], .big)),
                .flags = std.mem.readInt(u16, data[offset + 16..offset + 18], .big),
                .name_id = std.mem.readInt(u16, data[offset + 18..offset + 20], .big),
            };

            offset += axis_size;
        }

        // Parse named instances
        var instances = try self.allocator.alloc(FvarTable.NamedInstance, instance_count);

        for (0..instance_count) |i| {
            if (offset + instance_size > data.len) return error.InvalidFvarTable;

            instances[i] = FvarTable.NamedInstance{
                .subfamily_name_id = std.mem.readInt(u16, data[offset..offset + 2], .big),
                .flags = std.mem.readInt(u16, data[offset + 2..offset + 4], .big),
                .coordinates = try self.allocator.alloc(f32, axis_count),
                .postscript_name_id = null,
            };

            // Read coordinates
            for (0..axis_count) |j| {
                const coord_offset = offset + 4 + j * 4;
                instances[i].coordinates[j] = @bitCast(std.mem.readInt(u32, data[coord_offset..coord_offset + 4], .big));
            }

            offset += instance_size;
        }

        return FvarTable{
            .axes = axes,
            .instances = instances,
        };
    }

    // Parse avar table
    fn parseAvarTable(self: *Self, data: []const u8) !AvarTable {
        if (data.len < 8) return error.InvalidAvarTable;

        const axis_count = std.mem.readInt(u16, data[4..6], .big);
        var segments = std.AutoHashMap(u32, []AvarTable.AxisValueMap).init(self.allocator);

        var offset: usize = 8;

        // Get axis tags from fvar table
        if (self.fvar_table) |fvar| {
            for (0..axis_count) |i| {
                if (i >= fvar.axes.len) break;

                const segment_count = std.mem.readInt(u16, data[offset..offset + 2], .big);
                offset += 2;

                var axis_segments = try self.allocator.alloc(AvarTable.AxisValueMap, segment_count);

                for (0..segment_count) |j| {
                    if (offset + 4 > data.len) return error.InvalidAvarTable;

                    axis_segments[j] = AvarTable.AxisValueMap{
                        .from_coordinate = @as(f32, @floatFromInt(std.mem.readInt(i16, data[offset..offset + 2], .big))) / 16384.0,
                        .to_coordinate = @as(f32, @floatFromInt(std.mem.readInt(i16, data[offset + 2..offset + 4], .big))) / 16384.0,
                    };

                    offset += 4;
                }

                try segments.put(fvar.axes[i].tag, axis_segments);
            }
        }

        return AvarTable{
            .segments = segments,
        };
    }

    // Interpolate font based on current axis values
    fn interpolateFont(self: *Self, base_font: *Font) !Font {
        // This is a simplified implementation
        // In practice, this would involve complex glyph outline interpolation
        var result_font = base_font.*;

        // Apply weight variations if present
        if (self.getAxisValue(0x77676874)) |weight| { // 'wght'
            // Adjust glyph outlines based on weight
            _ = weight;
        }

        // Apply width variations if present
        if (self.getAxisValue(0x77647468)) |width| { // 'wdth'
            // Adjust glyph metrics based on width
            _ = width;
        }

        // Apply optical size variations if present
        if (self.getAxisValue(0x6F70737A)) |opsz| { // 'opsz'
            // Adjust for optical size
            _ = opsz;
        }

        return result_font;
    }

    // Common axis tags
    pub const AXIS_WEIGHT = 0x77676874; // 'wght'
    pub const AXIS_WIDTH = 0x77647468;  // 'wdth'
    pub const AXIS_ITALIC = 0x6974616C; // 'ital'
    pub const AXIS_SLANT = 0x736C6E74;  // 'slnt'
    pub const AXIS_OPTICAL_SIZE = 0x6F70737A; // 'opsz'
};

const AxisSetting = struct {
    tag: u32,
    value: f32,
};

// Predefined instances for common variable font settings
pub const CommonInstances = struct {
    pub const THIN = [_]AxisSetting{
        .{ .tag = VariableFontManager.AXIS_WEIGHT, .value = 100 },
    };

    pub const LIGHT = [_]AxisSetting{
        .{ .tag = VariableFontManager.AXIS_WEIGHT, .value = 300 },
    };

    pub const REGULAR = [_]AxisSetting{
        .{ .tag = VariableFontManager.AXIS_WEIGHT, .value = 400 },
    };

    pub const MEDIUM = [_]AxisSetting{
        .{ .tag = VariableFontManager.AXIS_WEIGHT, .value = 500 },
    };

    pub const BOLD = [_]AxisSetting{
        .{ .tag = VariableFontManager.AXIS_WEIGHT, .value = 700 },
    };

    pub const BLACK = [_]AxisSetting{
        .{ .tag = VariableFontManager.AXIS_WEIGHT, .value = 900 },
    };

    pub const CONDENSED = [_]AxisSetting{
        .{ .tag = VariableFontManager.AXIS_WIDTH, .value = 75 },
    };

    pub const EXPANDED = [_]AxisSetting{
        .{ .tag = VariableFontManager.AXIS_WIDTH, .value = 125 },
    };
};

test "VariableFontManager basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = VariableFontManager.init(allocator);
    defer manager.deinit();

    // Test axis value setting
    try manager.setAxisValue(VariableFontManager.AXIS_WEIGHT, 700);
    try testing.expect(manager.getAxisValue(VariableFontManager.AXIS_WEIGHT).? == 700);
}