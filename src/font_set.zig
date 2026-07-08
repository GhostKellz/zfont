//! Deterministic, coverage-backed font fallback.
//!
//! `FontSet` is an ordered list of fonts. Fallback selection uses each font's
//! *real* cmap coverage (`Font.hasGlyph`) rather than the never-populated
//! coverage placeholders in `font_fallback.zig`. For any codepoint, the first
//! font in registration order that actually contains a glyph is chosen. This
//! gives applications a predictable, no-magic fallback chain they can build
//! from explicit font files without any system font discovery.
//!
//! The set is non-owning: callers keep ownership of the `*Font`s and are
//! responsible for their lifetimes. `FontSet` only borrows pointers.

const std = @import("std");
const Font = @import("font.zig").Font;

/// A contiguous run of source bytes resolved to a single covering font.
pub const FontRun = struct {
    /// The font that covers this run, or null if no font in the set does.
    font: ?*Font,
    /// Index of `font` within the set (null when uncovered).
    font_index: ?usize,
    /// Inclusive start byte offset in the source text.
    start: u32,
    /// Exclusive end byte offset in the source text.
    end: u32,
};

pub const FontSet = struct {
    allocator: std.mem.Allocator,
    fonts: std.ArrayList(*Font),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator, .fonts = .empty };
    }

    /// Frees the set's internal storage. Does NOT deinit the borrowed fonts.
    pub fn deinit(self: *Self) void {
        self.fonts.deinit(self.allocator);
    }

    /// Append a font to the fallback chain. Earlier fonts have priority.
    pub fn addFont(self: *Self, font: *Font) !void {
        try self.fonts.append(self.allocator, font);
    }

    pub fn count(self: Self) usize {
        return self.fonts.items.len;
    }

    /// Index of the first font covering `codepoint`, or null if none do.
    pub fn coveringIndex(self: Self, codepoint: u32) ?usize {
        for (self.fonts.items, 0..) |font, i| {
            if (font.hasGlyph(codepoint)) return i;
        }
        return null;
    }

    /// First font covering `codepoint`, or null if none do.
    pub fn coveringFont(self: Self, codepoint: u32) ?*Font {
        if (self.coveringIndex(codepoint)) |i| return self.fonts.items[i];
        return null;
    }

    /// Split `text` into runs, each resolved to the first covering font.
    /// Consecutive codepoints resolving to the same font (or to no font) are
    /// merged into a single run. Caller owns the returned slice.
    pub fn resolveRuns(self: Self, allocator: std.mem.Allocator, text: []const u8) ![]FontRun {
        var runs: std.ArrayList(FontRun) = .empty;
        errdefer runs.deinit(allocator);

        var i: usize = 0;
        while (i < text.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                i += 1;
                continue;
            };
            if (i + seq_len > text.len) break;
            const codepoint = std.unicode.utf8Decode(text[i .. i + seq_len]) catch {
                i += 1;
                continue;
            };

            const idx = self.coveringIndex(codepoint);
            const start: u32 = @intCast(i);
            const end: u32 = @intCast(i + seq_len);

            // Extend the previous run if it resolved to the same font.
            if (runs.items.len > 0 and runs.items[runs.items.len - 1].font_index == idx) {
                runs.items[runs.items.len - 1].end = end;
            } else {
                try runs.append(allocator, .{
                    .font = if (idx) |n| self.fonts.items[n] else null,
                    .font_index = idx,
                    .start = start,
                    .end = end,
                });
            }

            i += seq_len;
        }

        return runs.toOwnedSlice(allocator);
    }
};

const test_font = @import("test_font.zig");

test "coveringFont picks first font that covers the codepoint" {
    const allocator = std.testing.allocator;

    // font_a covers 'A' (0x41); font_b covers 'B' (0x42). Both cover space.
    const data_a = try test_font.buildLetter(allocator, 'A');
    defer allocator.free(data_a);
    const data_b = try test_font.buildLetter(allocator, 'B');
    defer allocator.free(data_b);

    var font_a = try Font.init(allocator, data_a);
    defer font_a.deinit();
    var font_b = try Font.init(allocator, data_b);
    defer font_b.deinit();

    var set = FontSet.init(allocator);
    defer set.deinit();
    try set.addFont(&font_a);
    try set.addFont(&font_b);

    // 'A' only in font_a, 'B' only in font_b.
    try std.testing.expectEqual(@as(?usize, 0), set.coveringIndex('A'));
    try std.testing.expectEqual(@as(?usize, 1), set.coveringIndex('B'));
    // Space is in both -> first font wins (deterministic).
    try std.testing.expectEqual(@as(?usize, 0), set.coveringIndex(' '));
    // 'Z' in neither.
    try std.testing.expectEqual(@as(?usize, null), set.coveringIndex('Z'));
}

test "resolveRuns splits mixed coverage into font runs" {
    const allocator = std.testing.allocator;

    const data_a = try test_font.buildLetter(allocator, 'A');
    defer allocator.free(data_a);
    const data_b = try test_font.buildLetter(allocator, 'B');
    defer allocator.free(data_b);

    var font_a = try Font.init(allocator, data_a);
    defer font_a.deinit();
    var font_b = try Font.init(allocator, data_b);
    defer font_b.deinit();

    var set = FontSet.init(allocator);
    defer set.deinit();
    try set.addFont(&font_a);
    try set.addFont(&font_b);

    // "AABZ": AA -> font_a, B -> font_b, Z -> uncovered.
    const runs = try set.resolveRuns(allocator, "AABZ");
    defer allocator.free(runs);

    try std.testing.expectEqual(@as(usize, 3), runs.len);

    try std.testing.expectEqual(@as(?usize, 0), runs[0].font_index);
    try std.testing.expectEqual(@as(u32, 0), runs[0].start);
    try std.testing.expectEqual(@as(u32, 2), runs[0].end);

    try std.testing.expectEqual(@as(?usize, 1), runs[1].font_index);
    try std.testing.expectEqual(@as(u32, 2), runs[1].start);
    try std.testing.expectEqual(@as(u32, 3), runs[1].end);

    try std.testing.expectEqual(@as(?usize, null), runs[2].font_index);
    try std.testing.expect(runs[2].font == null);
    try std.testing.expectEqual(@as(u32, 3), runs[2].start);
    try std.testing.expectEqual(@as(u32, 4), runs[2].end);
}

test "empty set covers nothing" {
    const allocator = std.testing.allocator;
    var set = FontSet.init(allocator);
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 0), set.count());
    try std.testing.expectEqual(@as(?*Font, null), set.coveringFont('A'));

    const runs = try set.resolveRuns(allocator, "AB");
    defer allocator.free(runs);
    // Both uncovered and merged into a single null run.
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try std.testing.expectEqual(@as(?usize, null), runs[0].font_index);
    try std.testing.expectEqual(@as(u32, 0), runs[0].start);
    try std.testing.expectEqual(@as(u32, 2), runs[0].end);
}
