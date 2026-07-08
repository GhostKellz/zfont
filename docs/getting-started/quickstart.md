# Quickstart

This quickstart uses the current exported API without implying that the whole
font stack is production-complete.

## Font Manager

```zig
const std = @import("std");
const zfont = @import("zfont");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = zfont.FontManager.init(allocator);
    defer manager.deinit();

    _ = &manager;
}
```

## Terminal Text Helpers

```zig
const std = @import("std");
const zfont = @import("zfont");

pub fn inspectText(allocator: std.mem.Allocator, text: []const u8) !void {
    var cursor = try zfont.TerminalCursorProcessor.init(allocator);
    defer cursor.deinit();

    var analysis = try cursor.analyzeTextForCursor(text, 80);
    defer analysis.deinit();

    std.debug.print("requires complex shaping: {}\n", .{analysis.requires_complex_shaping});
}
```

Use these helpers as application-facing utilities. Validate behavior against your
own fonts and terminal width policy while the library remains pre-stable.
