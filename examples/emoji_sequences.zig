const std = @import("std");
const zfont = @import("zfont");

/// Example: Complex emoji sequence processing
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Emoji Sequence Processing Example ===", .{});

    // Initialize emoji sequence processor
    var emoji_processor = try zfont.EmojiSequenceProcessor.init(allocator);
    defer emoji_processor.deinit();

    // Test various emoji sequences
    const emoji_examples = [_]struct {
        text: []const u8,
        description: []const u8,
        complexity: []const u8,
    }{
        .{ .text = "😀😍🤔", .description = "Simple emoji", .complexity = "Basic" },
        .{ .text = "🇺🇸🇯🇵🇩🇪🇫🇷", .description = "Country flags", .complexity = "Regional Indicators" },
        .{ .text = "👨‍👩‍👧‍👦", .description = "Family emoji", .complexity = "ZWJ Sequence" },
        .{ .text = "👍🏻👍🏿", .description = "Skin tone variants", .complexity = "Skin Tone Modifiers" },
        .{ .text = "1️⃣2️⃣3️⃣", .description = "Keycap sequences", .complexity = "Keycap Combining" },
        .{ .text = "👩‍💻👨‍🔬👩‍⚕️", .description = "Professional emoji", .complexity = "ZWJ Professions" },
        .{ .text = "🏴󠁧󠁢󠁳󠁣󠁴󠁿", .description = "Scotland flag", .complexity = "Tag Sequence" },
        .{ .text = "🧑‍🤝‍🧑", .description = "People holding hands", .complexity = "ZWJ + Skin Tone" },
        .{ .text = "👨🏽‍❤️‍👨🏻", .description = "Couple with different skin tones", .complexity = "Complex ZWJ + Skin" },
        .{ .text = "🏳️‍🌈🏳️‍⚧️", .description = "Pride flags", .complexity = "Flag Variations" },
    };

    for (emoji_examples, 0..) |example, i| {
        std.log.info("\n--- Example {} ---", .{i + 1});
        std.log.info("Text: {s}", .{example.text});
        std.log.info("Description: {s}", .{example.description});
        std.log.info("Complexity: {s}", .{example.complexity});

        // Process the emoji text
        var result = try emoji_processor.processEmojiSequences(example.text);
        defer result.deinit();

        std.log.info("Analysis results:", .{});
        std.log.info("  Total emoji sequences: {}", .{result.total_emoji_count});
        std.log.info("  Total display width: {d:.1}", .{result.total_display_width});
        std.log.info("  Has complex sequences: {}", .{result.has_complex_sequences});

        // Show individual sequence analysis
        for (result.sequences.items, 0..) |seq, seq_num| {
            std.log.info("  Sequence {}: {s}", .{ seq_num + 1, seq.text_representation });
            std.log.info("    Codepoints: {} (", .{seq.codepoints.len});
            for (seq.codepoints, 0..) |cp, cp_idx| {
                if (cp_idx > 0) std.log.info(", ", .{});
                std.log.info("U+{X:0>4}", .{cp});
            }
            std.log.info(")", .{});
            std.log.info("    Type: {s}", .{@tagName(seq.info.sequence_type)});
            std.log.info("    Components: {}", .{seq.info.component_count});
            std.log.info("    Display width: {d:.1}", .{seq.info.display_width});
            std.log.info("    Terminal cells: {}", .{seq.info.terminal_cells});
            std.log.info("    Has skin tone: {}", .{seq.info.has_skin_tone});
            std.log.info("    Has ZWJ: {}", .{seq.info.has_zwj});
            std.log.info("    Is flag: {}", .{seq.info.is_flag_sequence});
        }
    }

    // Demonstrate terminal layout for emoji
    std.log.info("\n=== Terminal Layout for Emoji ===", .{});

    const emoji_paragraph = "Welcome! 👋🏻 Our team includes: 👩‍💻👨‍🔬👩‍⚕️👨‍🍳 We support all countries: 🇺🇸🇯🇵🇩🇪🇫🇷🇨🇳🇮🇳🇧🇷 Family time: 👨‍👩‍👧‍👦👵🏻👶🏽 Have a great day! 😊🌟";

    var emoji_result = try emoji_processor.processEmojiSequences(emoji_paragraph);
    defer emoji_result.deinit();

    const terminal_widths = [_]u32{ 40, 60, 80 };

    for (terminal_widths) |width| {
        std.log.info("\nTerminal width: {} columns", .{width});

        var layout = try emoji_processor.optimizeForTerminal(emoji_result.sequences.items, width);
        defer layout.deinit();

        std.log.info("Lines needed: {}", .{layout.lines.items.len});

        for (layout.lines.items, 0..) |line, line_num| {
            var line_width: u32 = 0;
            var line_content = std.ArrayList(u8).init(allocator);
            defer line_content.deinit();

            for (line) |seq| {
                line_width += seq.info.terminal_cells;
                try line_content.appendSlice(seq.text_representation);
            }

            std.log.info("  Line {}: {s} (width: {})", .{
                line_num + 1,
                line_content.items,
                line_width,
            });
        }
    }

    // Demonstrate emoji rendering strategies
    std.log.info("\n=== Emoji Rendering Strategies ===", .{});

    const complex_emoji = "👨🏽‍❤️‍👨🏻"; // Complex couple emoji

    var complex_result = try emoji_processor.processEmojiSequences(complex_emoji);
    defer complex_result.deinit();

    if (complex_result.sequences.items.len > 0) {
        const seq = &complex_result.sequences.items[0];

        var render_info = try emoji_processor.renderEmojiSequence(seq, 16.0);
        defer render_info.deinit();

        std.log.info("Complex emoji: {s}", .{seq.text_representation});
        std.log.info("  Render as single: {}", .{render_info.render_as_single});
        std.log.info("  Estimated size: {d:.1}x{d:.1}", .{
            render_info.estimated_width,
            render_info.estimated_height,
        });

        if (render_info.fallback_components.items.len > 0) {
            std.log.info("  Fallback components:", .{});
            for (render_info.fallback_components.items) |cp| {
                std.log.info("    U+{X:0>4}", .{cp});
            }
        }
    }

    // Performance testing
    std.log.info("\n=== Performance Testing ===", .{});

    const performance_emoji = "😀👍🇺🇸👨‍👩‍👧‍👦🏳️‍🌈" ** 50;

    const start_time = std.time.milliTimestamp();
    var perf_result = try emoji_processor.processEmojiSequences(performance_emoji);
    defer perf_result.deinit();
    const end_time = std.time.milliTimestamp();

    std.log.info("Processed {} bytes of emoji in {}ms", .{
        performance_emoji.len,
        end_time - start_time,
    });
    std.log.info("Found {} emoji sequences", .{perf_result.total_emoji_count});

    std.log.info("\n=== Emoji Sequence Processing Complete ===", .{});
}