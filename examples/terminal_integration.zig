const std = @import("std");
const zfont = @import("zfont");

/// Example: Complete terminal integration with complex text
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Terminal Integration Example ===", .{});

    // Initialize terminal text handler
    const cell_width = 12.0;
    const cell_height = 16.0;
    const terminal_cols = 80;
    const terminal_rows = 24;

    var terminal_handler = try zfont.TerminalTextHandler.init(
        allocator,
        cell_width,
        cell_height,
        terminal_cols,
        terminal_rows
    );
    defer terminal_handler.deinit();

    // Initialize cursor processor
    var cursor_processor = try zfont.TerminalCursorProcessor.init(allocator);
    defer cursor_processor.deinit();

    // Initialize performance optimizer
    const perf_settings = zfont.TerminalPerformanceOptimizer.OptimizationSettings{};
    var perf_optimizer = try zfont.TerminalPerformanceOptimizer.init(allocator, perf_settings);
    defer perf_optimizer.deinit();

    // Test complex multilingual text
    const complex_text =
        \\Welcome to زفونت (ZFont)!
        \\
        \\This terminal supports:
        \\• Arabic: مرحبا بالعالم 🌍
        \\• Hebrew: שלום עולם
        \\• Hindi: नमस्ते दुनिया
        \\• Chinese: 你好世界 🇨🇳
        \\• Japanese: こんにちは世界 🇯🇵
        \\• Korean: 안녕하세요 세계 🇰🇷
        \\• Emoji: 👨‍👩‍👧‍👦👍🏽🏳️‍🌈
        \\
        \\Mixed direction: Hello مرحبا שלום
        \\Numbers: ১২৩ (Bengali) ١٢٣ (Arabic)
        \\Programming: fn main() -> Result<(), Error>
    ;

    std.log.info("Processing complex multilingual text...\n");

    // 1. Text Analysis and Optimization
    std.log.info("=== Text Analysis ===", .{});

    var optimized = try perf_optimizer.optimizeTextForScrolling(
        complex_text, 0, complex_text.len, terminal_cols, cell_height
    );
    defer optimized.deinit();

    std.log.info("Optimization level: {s}", .{@tagName(optimized.optimization_level)});
    std.log.info("Total lines: {}", .{optimized.total_lines});

    for (optimized.line_segments, 0..) |segment, i| {
        std.log.info("Line {}: \"{s}\" ({})", .{
            i + 1,
            segment.text,
            @tagName(segment.complexity_level)
        });
        std.log.info("  Width: {d:.1}, BiDi: {}, Shaping: {}", .{
            segment.display_width,
            segment.needs_bidi,
            segment.needs_shaping
        });
    }

    // 2. Cursor Movement Demo
    std.log.info("\n=== Cursor Movement Demo ===", .{});

    const cursor_test_text = "Hello مرحبا World! 👨‍👩‍👧‍👦";

    var cursor_analysis = try cursor_processor.analyzeTextForCursor(cursor_test_text, terminal_cols);
    defer cursor_analysis.deinit();

    var cursor_pos = zfont.TerminalCursorProcessor.CursorPosition{
        .logical_index = 0,
        .visual_index = 0,
        .grapheme_index = 0,
        .line = 0,
        .column = 0,
        .is_rtl_context = false,
        .script_context = try cursor_processor.getScriptContext(0, &cursor_analysis),
    };

    std.log.info("Initial cursor: logical={}, visual={}, line={}, col={}", .{
        cursor_pos.logical_index,
        cursor_pos.visual_index,
        cursor_pos.line,
        cursor_pos.column
    });

    // Test various cursor movements
    const movements = [_]struct {
        move: zfont.TerminalCursorProcessor.CursorMovement,
        description: []const u8,
    }{
        .{ .move = .right, .description = "Move right" },
        .{ .move = .right, .description = "Move right again" },
        .{ .move = .word_right, .description = "Next word" },
        .{ .move = .grapheme_right, .description = "Next grapheme" },
        .{ .move = .left, .description = "Move left" },
        .{ .move = .word_left, .description = "Previous word" },
    };

    for (movements) |movement| {
        cursor_pos = try cursor_processor.moveCursor(
            cursor_pos, movement.move, &cursor_analysis, cursor_test_text
        );

        std.log.info("{s}: logical={}, visual={}, line={}, col={}, RTL={}", .{
            movement.description,
            cursor_pos.logical_index,
            cursor_pos.visual_index,
            cursor_pos.line,
            cursor_pos.column,
            cursor_pos.is_rtl_context,
        });
    }

    // 3. Text Selection Demo
    std.log.info("\n=== Text Selection Demo ===", .{});

    const selection_text = "Double-click on مرحبا to select Arabic word";

    // Simulate double-click at position of Arabic word
    const click_position = 15; // Approximate position of "مرحبا"

    var selection = try terminal_handler.selectWord(selection_text, click_position);

    std.log.info("Selected word at position {}:", .{click_position});
    std.log.info("  Start: logical={}, visual={}, line={}, col={}", .{
        selection.start.logical,
        selection.start.visual,
        selection.start.column,
        selection.start.row
    });
    std.log.info("  End: logical={}, visual={}, line={}, col={}", .{
        selection.end.logical,
        selection.end.visual,
        selection.end.column,
        selection.end.row
    });

    // 4. Emoji Handling in Terminal
    std.log.info("\n=== Emoji Terminal Handling ===", .{});

    const emoji_text = "Team: 👨‍💻👩‍🔬👨‍🍳 Flags: 🇺🇸🇯🇵🇩🇪 Family: 👨‍👩‍👧‍👦";

    var emoji_info = try terminal_handler.handleEmojiSequences(emoji_text);
    defer {
        for (emoji_info) |*info| {
            allocator.free(info.sequence);
        }
        allocator.free(emoji_info);
    }

    std.log.info("Found {} emoji sequences:", .{emoji_info.len});
    for (emoji_info) |info| {
        std.log.info("  Emoji: {s} (width: {} cells, {} graphemes)", .{
            info.sequence,
            info.terminal_width,
            info.grapheme_count
        });
    }

    // 5. Text Wrapping Demo
    std.log.info("\n=== Text Wrapping Demo ===", .{});

    const wrap_text = "This is a long line with mixed content: العربية中文हिंदी that needs to be wrapped properly across terminal width boundaries.";

    var wrapped = try terminal_handler.wrapTextToTerminal(wrap_text);
    defer {
        for (wrapped) |*line| {
            line.deinit();
        }
        allocator.free(wrapped);
    }

    std.log.info("Text wrapped into {} lines:", .{wrapped.len});
    for (wrapped, 0..) |line, i| {
        var line_text = std.ArrayList(u8).init(allocator);
        defer line_text.deinit();

        var total_width: f32 = 0;
        for (line.segments.items) |segment| {
            try line_text.appendSlice(segment.text);
            total_width += segment.width;
        }

        std.log.info("  Line {}: \"{s}\" (width: {d:.1})", .{
            i + 1,
            line_text.items,
            total_width
        });
    }

    // 6. Performance Metrics
    std.log.info("\n=== Performance Metrics ===", .{});

    const metrics = perf_optimizer.getPerformanceMetrics();
    std.log.info("Cache hit rate: {d:.1}%", .{metrics.cache_hit_rate * 100});
    std.log.info("Cache size: {}", .{metrics.cache_size});
    std.log.info("Memory usage: {} bytes", .{metrics.memory_usage});

    // 7. Complete Rendering Pipeline
    std.log.info("\n=== Complete Rendering Pipeline ===", .{});

    const render_text = "Final demo: مرحبا 🌍 Hello こんにちは";

    var render_result = try terminal_handler.renderTextForTerminal(render_text);

    std.log.info("Rendering complete:", .{});
    std.log.info("  Requires BiDi: {}", .{render_result.requires_bidi});
    std.log.info("  Requires complex shaping: {}", .{render_result.requires_complex_shaping});
    std.log.info("  Emoji sequences: {}", .{render_result.emoji_sequences.len});
    std.log.info("  Wrapped lines: {}", .{render_result.wrapped_lines.len});

    // 8. Memory Cleanup Demonstration
    std.log.info("\n=== Memory Management ===", .{});

    // All memory is automatically cleaned up through defer statements
    // demonstrating proper RAII patterns in Zig

    std.log.info("All resources cleaned up automatically via defer statements");

    std.log.info("\n=== Terminal Integration Complete ===", .{});
    std.log.info("ZFont successfully handles:");
    std.log.info("✓ Multilingual text (Arabic, Hebrew, Hindi, CJK)");
    std.log.info("✓ Complex emoji sequences");
    std.log.info("✓ BiDi text processing");
    std.log.info("✓ Smart cursor movement");
    std.log.info("✓ Intelligent text selection");
    std.log.info("✓ Performance optimization");
    std.log.info("✓ Memory-safe operations");
}