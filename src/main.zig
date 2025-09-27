const std = @import("std");
const zfont = @import("zfont");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("ZFont - Modern Font Rendering Library\n", .{});
    std.debug.print("=====================================\n", .{});

    // Basic functionality test
    var font_manager = zfont.FontManager.init(allocator);
    defer font_manager.deinit();
    std.debug.print("✓ Font manager initialized\n", .{});

    var layout = zfont.TextLayout.init(allocator);
    defer layout.deinit();
    std.debug.print("✓ Text layout initialized\n", .{});

    var emoji_renderer = try zfont.EmojiRenderer.init(allocator);
    defer emoji_renderer.deinit();
    const is_emoji = emoji_renderer.isEmoji(0x1F600);
    std.debug.print("✓ Emoji support: {} detected as emoji\n", .{is_emoji});

    var programming_manager = zfont.ProgrammingFonts.ProgrammingFontManager.init(allocator);
    defer programming_manager.deinit();
    const has_ligature = programming_manager.ligature_map.contains("==");
    std.debug.print("✓ Programming fonts: '==' ligature {s}\n", .{if (has_ligature) "found" else "not found"});

    std.debug.print("✓ All systems functional!\n", .{});
}

test "ZFont basic functionality" {
    const allocator = std.testing.allocator;

    var font_manager = zfont.FontManager.init(allocator);
    defer font_manager.deinit();
    try std.testing.expect(font_manager.font_cache.count() == 0);

    var layout = zfont.TextLayout.init(allocator);
    defer layout.deinit();
    try std.testing.expect(layout.runs.items.len == 0);

    var emoji_renderer = try zfont.EmojiRenderer.init(allocator);
    defer emoji_renderer.deinit();
    try std.testing.expect(emoji_renderer.isEmoji(0x1F600));
    try std.testing.expect(!emoji_renderer.isEmoji('A'));
}
