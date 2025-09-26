const std = @import("std");
const zfont = @import("zfont");

/// Example: CJK text processing with proper width handling
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== CJK Text Processing Example ===", .{});

    // Initialize CJK width processor
    var cjk_processor = try zfont.CJKWidthProcessor.init(allocator);
    defer cjk_processor.deinit();

    // Test various CJK texts
    const cjk_texts = [_]struct {
        text: []const u8,
        language: []const u8,
        description: []const u8,
    }{
        .{ .text = "こんにちは世界", .language = "Japanese", .description = "Hello World (Hiragana + Han)" },
        .{ .text = "안녕하세요 세계", .language = "Korean", .description = "Hello World (Hangul)" },
        .{ .text = "你好世界", .language = "Chinese", .description = "Hello World (Simplified Chinese)" },
        .{ .text = "カタカナテスト", .language = "Japanese", .description = "Katakana Test" },
        .{ .text = "ｶﾀｶﾅﾃｽﾄ", .language = "Japanese", .description = "Halfwidth Katakana" },
        .{ .text = "Mixed: 日本語123", .language = "Mixed", .description = "Japanese + ASCII numbers" },
        .{ .text = "全角：ＡＢＣＤ", .language = "Japanese", .description = "Fullwidth Latin" },
        .{ .text = "中文測試文本", .language = "Chinese", .description = "Chinese test text" },
    };

    for (cjk_texts, 0..) |example, i| {
        std.log.info("\n--- Example {} ({s}) ---", .{ i + 1, example.language });
        std.log.info("Text: {s}", .{example.text});
        std.log.info("Description: {s}", .{example.description});

        // Process the CJK text
        var result = try cjk_processor.processCJKText(example.text);
        defer result.deinit();

        std.log.info("Analysis results:", .{});
        std.log.info("  Total display width: {d:.1}", .{result.total_display_width});
        std.log.info("  Terminal cells needed: {}", .{result.total_terminal_cells});
        std.log.info("  Mixed width characters: {}", .{result.mixed_width});
        std.log.info("  CJK characters found: {}", .{result.cjk_characters.items.len});

        // Show individual character analysis
        std.log.info("Character breakdown:");
        for (result.cjk_characters.items) |char_data| {
            const width_type = if (char_data.info.is_fullwidth) "fullwidth" else if (char_data.info.is_halfwidth) "halfwidth" else "normal";

            std.log.info("    U+{X:0>4} ({s}) - {s}, width: {d:.1}, cells: {}", .{
                char_data.codepoint,
                @tagName(char_data.info.script_type),
                width_type,
                char_data.visual_width,
                char_data.terminal_width,
            });
        }
    }

    // Demonstrate terminal layout optimization
    std.log.info("\n=== Terminal Layout Optimization ===", .{});

    const long_cjk_text = "これは長い日本語のテキストです。ターミナルの幅に合わせて適切に折り返されます。中国語も含まれています：你好世界！";

    const terminal_widths = [_]u32{ 40, 60, 80 };

    for (terminal_widths) |width| {
        std.log.info("\nTerminal width: {} columns", .{width});

        var layout = try cjk_processor.optimizeForTerminal(long_cjk_text, width);
        defer layout.deinit();

        std.log.info("Lines needed: {}", .{layout.lines.items.len});

        for (layout.lines.items, 0..) |line, line_num| {
            var line_width: u32 = 0;
            for (line) |char_data| {
                line_width += char_data.terminal_width;
            }
            std.log.info("  Line {}: {} characters, {} terminal cells", .{
                line_num + 1,
                line.len,
                line_width,
            });
        }
    }

    // Performance testing
    std.log.info("\n=== Performance Testing ===", .{});

    const performance_text = "性能测试文本：これは非常に長いテキストです。" ** 10;

    const start_time = std.time.milliTimestamp();
    var perf_result = try cjk_processor.processCJKText(performance_text);
    defer perf_result.deinit();
    const end_time = std.time.milliTimestamp();

    std.log.info("Processed {} characters in {}ms", .{
        performance_text.len,
        end_time - start_time,
    });
    std.log.info("Found {} CJK characters", .{perf_result.cjk_characters.items.len});

    std.log.info("\n=== CJK Text Processing Complete ===", .{});
}