const std = @import("std");
const gcode = @import("gcode");

pub const GraphemeSegmenter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GraphemeSegmenter {
        return GraphemeSegmenter{ .allocator = allocator };
    }

    pub fn deinit(self: *GraphemeSegmenter) void {
        _ = self;
    }

    pub fn segmentText(self: *GraphemeSegmenter, text: []const u8) ![]usize {
        return self.segmentByteBreaks(text);
    }

    pub fn segmentByteBreaks(self: *GraphemeSegmenter, text: []const u8) ![]usize {
        var breaks = std.ArrayList(usize).empty;
        errdefer breaks.deinit(self.allocator);

        var iterator = gcode.graphemeIterator(text);
        var offset: usize = 0;

        while (iterator.next()) |cluster| {
            offset += cluster.len;
            try breaks.append(self.allocator, offset);
        }
        return breaks.toOwnedSlice(self.allocator);
    }

    pub fn segmentCodepointBreaks(self: *GraphemeSegmenter, text: []const u8) ![]usize {
        var breaks = std.ArrayList(usize).empty;
        errdefer breaks.deinit(self.allocator);

        var iterator = gcode.graphemeIterator(text);
        var cp_count: usize = 0;

        while (iterator.next()) |cluster| {
            cp_count += try std.unicode.utf8CountCodepoints(cluster);
            try breaks.append(self.allocator, cp_count);
        }

        return breaks.toOwnedSlice(self.allocator);
    }
};
