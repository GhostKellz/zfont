const std = @import("std");
const zfont = @import("zfont");

/// Example: Arabic text processing with contextual forms
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Arabic Text Processing Example ===", .{});

    // Initialize Arabic contextual processor
    var arabic_processor = try zfont.ArabicContextualProcessor.init(allocator);
    defer arabic_processor.deinit();

    // Test various Arabic texts
    const arabic_texts = [_][]const u8{
        "بسم الله الرحمن الرحيم",  // Bismillah
        "السلام عليكم ورحمة الله", // As-salamu alaykum
        "مرحبا بكم في العالم",     // Welcome to the world
        "الكتاب المقدس",          // The holy book
        "جامعة القاهرة",          // Cairo University
    };

    for (arabic_texts, 0..) |text, i| {
        std.log.info("\n--- Example {} ---", .{i + 1});
        std.log.info("Arabic text: {s}", .{text});

        // Process the Arabic text
        var result = try arabic_processor.processArabicText(text);
        defer result.deinit();

        std.log.info("Found {} contextual forms and {} ligatures", .{
            result.contextual_forms.items.len,
            result.ligatures.items.len,
        });

        // Display contextual forms
        std.log.info("Contextual forms:");
        for (result.contextual_forms.items) |form| {
            std.log.info("  U+{X:0>4} -> U+{X:0>4} ({s}) joins_left:{} joins_right:{}", .{
                form.base_codepoint,
                form.contextual_codepoint,
                @tagName(form.form),
                form.joins_left,
                form.joins_right,
            });
        }

        // Display ligatures
        if (result.ligatures.items.len > 0) {
            std.log.info("Ligatures:");
            for (result.ligatures.items) |ligature| {
                std.log.info("  U+{X:0>4}+U+{X:0>4} -> U+{X:0>4}", .{
                    ligature.components[0],
                    ligature.components[1],
                    ligature.ligature_glyph,
                });
            }
        }
    }

    // Demonstrate BiDi processing with mixed text
    std.log.info("\n=== BiDi Processing Example ===", .{});

    var bidi_processor = try zfont.GcodeTextProcessor.init(allocator);
    defer bidi_processor.deinit();

    const mixed_texts = [_][]const u8{
        "Hello مرحبا World",
        "Welcome to القاهرة city",
        "Email: user@البريد.com",
        "Price: 100 جنيه only",
    };

    for (mixed_texts, 0..) |text, i| {
        std.log.info("\nMixed text {}: {s}", .{ i + 1, text });

        var bidi_result = try bidi_processor.processTextWithBiDi(text, .auto);
        defer bidi_result.deinit();

        std.log.info("BiDi runs:");
        for (bidi_result.runs, 0..) |run, j| {
            std.log.info("  Run {}: '{s}' -> Direction: {s}, Level: {}", .{
                j + 1,
                run.text,
                @tagName(run.direction),
                run.level,
            });
        }
    }

    std.log.info("\n=== Arabic Text Processing Complete ===", .{});
}