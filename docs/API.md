# ZFont API Documentation

## Overview

ZFont provides a comprehensive text rendering library with advanced Unicode support through gcode integration. This document covers all major APIs and their usage patterns.

## Core Components

### BiDi Text Processing

Handle bidirectional text (Arabic, Hebrew) with RTL/LTR support.

```zig
const zfont = @import("zfont");

// Initialize BiDi processor
var bidi_processor = try zfont.GcodeTextProcessor.init(allocator);
defer bidi_processor.deinit();

// Process mixed RTL/LTR text
const text = "Hello مرحبا World";
const result = try bidi_processor.processTextWithBiDi(text, .auto);
defer result.deinit();

// Access reordered runs
for (result.runs) |run| {
    std.log.info("Text: {s}, Direction: {}", .{run.text, run.direction});
}
```

### Arabic Contextual Forms

Process Arabic text with proper contextual shaping.

```zig
// Initialize Arabic processor
var arabic_processor = try zfont.ArabicContextualProcessor.init(allocator);
defer arabic_processor.deinit();

// Process Arabic text
const arabic_text = "بسم الله";
var result = try arabic_processor.processArabicText(arabic_text);
defer result.deinit();

// Access contextual forms
for (result.contextual_forms.items) |form| {
    std.log.info("U+{X} -> U+{X} ({})", .{
        form.base_codepoint,
        form.contextual_codepoint,
        @tagName(form.form)
    });
}
```

### Indic Script Processing

Handle complex Indic scripts (Devanagari, Bengali, Tamil).

```zig
// Initialize Indic processor
var indic_processor = try zfont.IndicSyllableProcessor.init(allocator);
defer indic_processor.deinit();

// Process Indic text
const devanagari_text = "नमस्ते";
var result = try indic_processor.processSyllables(devanagari_text);
defer result.deinit();

// Access syllable information
for (result.syllables.items) |syllable| {
    std.log.info("Syllable: {} characters, base: {?}", .{
        syllable.characters.len,
        syllable.base_character
    });
}
```

### CJK Character Width

Handle CJK character width for proper terminal display.

```zig
// Initialize CJK processor
var cjk_processor = try zfont.CJKWidthProcessor.init(allocator);
defer cjk_processor.deinit();

// Process CJK text
const japanese_text = "こんにちは世界";
var result = try cjk_processor.processCJKText(japanese_text);
defer result.deinit();

std.log.info("Total width: {d:.1}, Terminal cells: {}", .{
    result.total_display_width,
    result.total_terminal_cells
});
```

### Emoji Sequence Handling

Process complex emoji sequences including ZWJ, flags, and skin tones.

```zig
// Initialize emoji processor
var emoji_processor = try zfont.EmojiSequenceProcessor.init(allocator);
defer emoji_processor.deinit();

// Process emoji text
const emoji_text = "👨‍👩‍👧‍👦 Family";
var result = try emoji_processor.processEmojiSequences(emoji_text);
defer result.deinit();

for (result.sequences.items) |seq| {
    std.log.info("Emoji: {s} ({} components)", .{
        seq.text_representation,
        seq.info.component_count
    });
}
```

### Terminal Cursor Positioning

Intelligent cursor movement in complex text.

```zig
// Initialize cursor processor
var cursor_processor = try zfont.TerminalCursorProcessor.init(allocator);
defer cursor_processor.deinit();

// Analyze text for cursor operations
const text = "Mixed: العربية and English";
var analysis = try cursor_processor.analyzeTextForCursor(text, 80);
defer analysis.deinit();

// Create cursor position
var pos = zfont.TerminalCursorProcessor.CursorPosition{
    .logical_index = 0,
    .visual_index = 0,
    .grapheme_index = 0,
    .line = 0,
    .column = 0,
    .is_rtl_context = false,
    .script_context = try cursor_processor.getScriptContext(0, &analysis),
};

// Move cursor
pos = try cursor_processor.moveCursor(pos, .right, &analysis, text);
```

### Performance Optimization

Optimize text processing for terminal scrolling.

```zig
// Initialize performance optimizer
const settings = zfont.TerminalPerformanceOptimizer.OptimizationSettings{};
var optimizer = try zfont.TerminalPerformanceOptimizer.init(allocator, settings);
defer optimizer.deinit();

// Optimize text for viewport
const text = "Large text content...";
var result = try optimizer.optimizeTextForScrolling(
    text, 0, 1000, 80, 16.0
);
defer result.deinit();

std.log.info("Optimization level: {}, Lines: {}", .{
    @tagName(result.optimization_level),
    result.total_lines
});
```

## Advanced Usage Patterns

### Mixed Script Text

```zig
// Handle text with multiple scripts
const mixed_text = "English العربية 中文 हिंदी";

// Use the advanced script processor
var script_processor = try zfont.AdvancedScriptProcessor.init(allocator);
defer script_processor.deinit();

var result = try script_processor.processComplexText(mixed_text);
defer result.deinit();

// Process each script run appropriately
for (result.script_runs) |run| {
    switch (run.script_info.script) {
        .arabic => {
            // Use Arabic contextual processor
        },
        .devanagari => {
            // Use Indic syllable processor
        },
        .han => {
            // Use CJK width processor
        },
        else => {
            // Standard processing
        },
    }
}
```

### Terminal Integration

```zig
// Complete terminal text handler
var terminal_handler = try zfont.TerminalTextHandler.init(
    allocator, 12.0, 16.0, 80, 24
);
defer terminal_handler.deinit();

// Handle complex text selection
const selection = try terminal_handler.selectWord(text, cursor_position);

// Handle emoji sequences for terminal
const emoji_info = try terminal_handler.handleEmojiSequences(emoji_text);
defer {
    for (emoji_info) |*info| {
        allocator.free(info.sequence);
    }
    allocator.free(emoji_info);
}

// Render text for terminal display
const render_result = try terminal_handler.renderTextForTerminal(text);
```

## Error Handling

All zfont functions return error unions. Common errors include:

- `FontError.InvalidFontData` - Corrupted font file
- `FontError.FontNotFound` - Font file not found
- `FontError.UnsupportedFormat` - Unsupported font format
- `FontError.MemoryError` - Out of memory
- `FontError.GlyphNotFound` - Glyph not available in font
- `FontError.LayoutError` - Text layout failure
- `FontError.RenderingError` - Rendering failure

```zig
const result = arabic_processor.processArabicText(text) catch |err| switch (err) {
    FontError.MemoryError => {
        std.log.err("Out of memory processing Arabic text");
        return;
    },
    FontError.LayoutError => {
        std.log.err("Failed to layout Arabic text");
        return;
    },
    else => return err,
};
```

## Performance Considerations

1. **Caching**: Most processors include intelligent caching
2. **Viewport Processing**: Only process visible text when possible
3. **Complexity Analysis**: Automatic optimization based on text complexity
4. **Memory Management**: Proper cleanup of allocated resources

## Thread Safety

ZFont processors are not thread-safe by design. Each thread should have its own processor instances.

```zig
// Per-thread processors
var thread_local_arabic = try zfont.ArabicContextualProcessor.init(allocator);
defer thread_local_arabic.deinit();
```