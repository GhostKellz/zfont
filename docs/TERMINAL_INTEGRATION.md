# Terminal Integration Guide

## Overview

ZFont provides specialized terminal integration features designed for high-performance text rendering in terminal emulators, code editors, and command-line applications. This guide covers integration patterns, optimization strategies, and best practices.

## Core Integration Components

### 1. Terminal Text Handler

The `TerminalTextHandler` provides unified text processing for terminal applications:

```zig
const zfont = @import("zfont");

// Initialize for specific terminal dimensions
var terminal_handler = try zfont.TerminalTextHandler.init(
    allocator,
    cell_width,     // Character cell width in pixels
    cell_height,    // Character cell height in pixels
    columns,        // Terminal columns
    rows           // Terminal rows
);
defer terminal_handler.deinit();
```

### 2. Performance Optimizer

Intelligent caching and optimization for terminal scrolling:

```zig
const settings = zfont.TerminalPerformanceOptimizer.OptimizationSettings{
    .cache_size_limit = 1000,
    .cache_ttl_ms = 30000,
    .lazy_analysis_threshold = 1000,
    .viewport_buffer_lines = 5,
    .enable_incremental_updates = true,
    .enable_background_processing = true,
};

var optimizer = try zfont.TerminalPerformanceOptimizer.init(allocator, settings);
defer optimizer.deinit();
```

### 3. Cursor Processor

Complex text-aware cursor positioning:

```zig
var cursor_processor = try zfont.TerminalCursorProcessor.init(allocator);
defer cursor_processor.deinit();

// Analyze text for cursor operations
const analysis = try cursor_processor.analyzeTextForCursor(text, terminal_width);
defer analysis.deinit();
```

## Integration Patterns

### Pattern 1: Basic Terminal Emulator

```zig
const TerminalEmulator = struct {
    allocator: std.mem.Allocator,
    terminal_handler: zfont.TerminalTextHandler,
    cursor_processor: zfont.TerminalCursorProcessor,
    performance_optimizer: zfont.TerminalPerformanceOptimizer,

    // Terminal state
    buffer: [][]u8,
    cursor_pos: zfont.TerminalCursorProcessor.CursorPosition,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Self {
        return Self{
            .allocator = allocator,
            .terminal_handler = try zfont.TerminalTextHandler.init(
                allocator, 12.0, 16.0, width, height
            ),
            .cursor_processor = try zfont.TerminalCursorProcessor.init(allocator),
            .performance_optimizer = try zfont.TerminalPerformanceOptimizer.init(
                allocator, .{}
            ),
            .buffer = try createBuffer(allocator, width, height),
            .cursor_pos = undefined,
        };
    }

    pub fn deinit(self: *Self) void {
        self.terminal_handler.deinit();
        self.cursor_processor.deinit();
        self.performance_optimizer.deinit();
        freeBuffer(self.allocator, self.buffer);
    }

    pub fn processInput(self: *Self, input: []const u8) !void {
        // Process incoming text with full Unicode support
        const render_result = try self.terminal_handler.renderTextForTerminal(input);

        // Update terminal buffer
        try self.updateBuffer(render_result);

        // Handle cursor positioning
        if (render_result.requires_complex_shaping) {
            const analysis = try self.cursor_processor.analyzeTextForCursor(
                input, self.terminal_handler.columns
            );
            defer analysis.deinit();

            // Update cursor with complex text awareness
            self.cursor_pos = try self.cursor_processor.moveCursor(
                self.cursor_pos, .right, &analysis, input
            );
        }
    }

    pub fn handleCursorMovement(self: *Self, direction: CursorMovement) !void {
        const current_line = self.getCurrentLineText();

        const analysis = try self.cursor_processor.analyzeTextForCursor(
            current_line, self.terminal_handler.columns
        );
        defer analysis.deinit();

        self.cursor_pos = try self.cursor_processor.moveCursor(
            self.cursor_pos, direction, &analysis, current_line
        );
    }

    pub fn optimizeForScrolling(self: *Self, viewport_start: usize, viewport_end: usize) !void {
        const full_buffer = try self.getBufferAsText();
        defer self.allocator.free(full_buffer);

        const optimized = try self.performance_optimizer.optimizeTextForScrolling(
            full_buffer, viewport_start, viewport_end,
            self.terminal_handler.columns, 16.0
        );
        defer optimized.deinit();

        // Use optimized results for rendering
        try self.renderOptimized(optimized);
    }
};
```

### Pattern 2: Code Editor Integration

```zig
const CodeEditor = struct {
    allocator: std.mem.Allocator,
    text_handler: zfont.TerminalTextHandler,
    cursor_processor: zfont.TerminalCursorProcessor,

    // Editor-specific features
    syntax_highlighter: SyntaxHighlighter,
    selection_manager: SelectionManager,

    const Self = @This();

    pub fn handleTextSelection(self: *Self, start_pos: usize, end_pos: usize) !TextSelection {
        const text = self.getDocumentText();

        // Use ZFont for intelligent word selection
        if (self.isDoubleClick()) {
            return self.text_handler.selectWord(text, start_pos);
        }

        // Custom selection with script awareness
        const analysis = try self.cursor_processor.analyzeTextForCursor(
            text, self.getEditorWidth()
        );
        defer analysis.deinit();

        return TextSelection{
            .start = try self.logicalToVisualPosition(start_pos, &analysis),
            .end = try self.logicalToVisualPosition(end_pos, &analysis),
        };
    }

    pub fn handleFindReplace(self: *Self, query: []const u8, replacement: []const u8) !void {
        const text = self.getDocumentText();

        // Use gcode for proper word boundary detection
        var gcode_processor = try zfont.GcodeTextProcessor.init(self.allocator);
        defer gcode_processor.deinit();

        const word_boundaries = try gcode_processor.getWordBoundaries(text);
        defer self.allocator.free(word_boundaries);

        // Find matches respecting Unicode word boundaries
        for (word_boundaries) |boundary| {
            const word = text[boundary.start..boundary.end];
            if (std.mem.eql(u8, word, query)) {
                try self.replaceRange(boundary.start, boundary.end, replacement);
            }
        }
    }

    pub fn renderWithSyntaxHighlighting(self: *Self, line_num: usize) !RenderedLine {
        const line_text = self.getLineText(line_num);

        // First, apply syntax highlighting
        const highlighted = try self.syntax_highlighter.highlight(line_text);

        // Then process with ZFont for complex scripts
        const segments = try self.processComplexText(highlighted);

        return RenderedLine{
            .segments = segments,
            .requires_bidi = self.containsRTLText(line_text),
            .has_complex_scripts = self.hasComplexScripts(line_text),
        };
    }
};
```

### Pattern 3: High-Performance Terminal

```zig
const HighPerformanceTerminal = struct {
    allocator: std.mem.Allocator,
    optimizer: zfont.TerminalPerformanceOptimizer,

    // Performance tracking
    frame_timer: std.time.Timer,
    render_cache: RenderCache,
    dirty_regions: std.ArrayList(Rect),

    const Self = @This();
    const TARGET_FPS = 60;
    const FRAME_TIME_MS = 1000 / TARGET_FPS;

    pub fn renderFrame(self: *Self) !void {
        self.frame_timer.reset();

        // Only process dirty regions for performance
        for (self.dirty_regions.items) |region| {
            try self.renderRegion(region);
        }

        const frame_time = self.frame_timer.read() / std.time.ns_per_ms;

        // Adjust optimization settings based on performance
        if (frame_time > FRAME_TIME_MS) {
            try self.increaseOptimization();
        } else if (frame_time < FRAME_TIME_MS / 2) {
            try self.decreaseOptimization();
        }

        self.dirty_regions.clearRetainingCapacity();
    }

    pub fn handleFastScrolling(self: *Self, direction: ScrollDirection, lines: u32) !void {
        const viewport_start = self.getViewportStart();
        const viewport_end = self.getViewportEnd();

        // Use performance optimizer for fast scrolling
        const optimized = try self.optimizer.optimizeTextForScrolling(
            self.getBufferText(),
            viewport_start,
            viewport_end,
            self.getTerminalWidth(),
            16.0
        );
        defer optimized.deinit();

        // Apply scroll-specific optimizations
        switch (optimized.optimization_level) {
            .simple => try self.fastScrollSimple(direction, lines),
            .moderate => try self.fastScrollModerate(direction, lines, &optimized),
            .complex, .very_complex => try self.fastScrollComplex(direction, lines, &optimized),
        }
    }

    fn increaseOptimization(self: *Self) !void {
        // Reduce cache size to improve performance
        const metrics = self.optimizer.getPerformanceMetrics();
        if (metrics.cache_size > 500) {
            try self.optimizer.cleanOldCacheEntries();
        }

        // Enable more aggressive optimizations
        try self.optimizer.enableBackgroundProcessing(false);
        try self.optimizer.setLazyAnalysisThreshold(500);
    }

    fn decreaseOptimization(self: *Self) !void {
        // Increase cache size for better quality
        try self.optimizer.enableBackgroundProcessing(true);
        try self.optimizer.setLazyAnalysisThreshold(2000);
    }
};
```

## Optimization Strategies

### 1. Viewport-Aware Processing

Only process visible text for performance:

```zig
pub fn renderViewport(self: *Self, start_line: usize, end_line: usize) !void {
    const viewport_text = self.getViewportText(start_line, end_line);

    // Process only visible content
    const optimized = try self.optimizer.optimizeTextForScrolling(
        viewport_text,
        0,
        viewport_text.len,
        self.terminal_width,
        self.font_size
    );
    defer optimized.deinit();

    // Render optimized content
    try self.renderOptimizedContent(optimized);
}
```

### 2. Incremental Updates

Update only changed regions:

```zig
pub fn updateText(self: *Self, start: usize, end: usize, new_text: []const u8) !void {
    // Mark region as dirty
    try self.dirty_regions.append(Rect{
        .start = start,
        .end = end,
    });

    // Invalidate cache for affected region
    self.optimizer.invalidateCache(start, end);

    // Update buffer
    self.replaceText(start, end, new_text);
}
```

### 3. Intelligent Caching

Cache based on text complexity:

```zig
pub fn processText(self: *Self, text: []const u8) !ProcessedText {
    const complexity = self.optimizer.analyzeTextComplexity(text);

    const cache_key = switch (complexity) {
        .simple => self.createSimpleKey(text),
        .moderate => self.createModerateKey(text),
        .complex, .very_complex => self.createComplexKey(text),
    };

    if (self.cache.get(cache_key)) |cached| {
        return cached;
    }

    const result = try self.processTextInternal(text, complexity);
    try self.cache.put(cache_key, result);

    return result;
}
```

## Best Practices

### 1. Memory Management

```zig
// Always use defer for cleanup
var terminal_handler = try zfont.TerminalTextHandler.init(allocator, 12.0, 16.0, 80, 24);
defer terminal_handler.deinit();

// Reuse allocations when possible
var buffer = std.ArrayList(u8).init(allocator);
defer buffer.deinit();

for (lines) |line| {
    buffer.clearRetainingCapacity(); // Reuse capacity
    try buffer.appendSlice(line);
    // Process buffer...
}
```

### 2. Error Handling

```zig
pub fn processTerminalInput(self: *Self, input: []const u8) !void {
    const result = self.terminal_handler.renderTextForTerminal(input) catch |err| switch (err) {
        FontError.MemoryError => {
            // Try to free some cache
            self.optimizer.cleanOldCacheEntries();
            return self.terminal_handler.renderTextForTerminal(input);
        },
        FontError.LayoutError => {
            // Fall back to simple rendering
            return self.renderSimpleText(input);
        },
        else => return err,
    };

    try self.updateDisplay(result);
}
```

### 3. Performance Monitoring

```zig
pub fn monitorPerformance(self: *Self) void {
    const metrics = self.optimizer.getPerformanceMetrics();

    std.log.info("Cache hit rate: {d:.1}%", .{metrics.cache_hit_rate * 100});
    std.log.info("Memory usage: {} MB", .{metrics.memory_usage / 1024 / 1024});

    if (metrics.cache_hit_rate < 0.8) {
        std.log.warn("Low cache hit rate, consider adjusting cache settings");
    }
}
```

## Integration Examples

### Terminal Emulator Integration

```zig
// Terminal emulator main loop
pub fn mainLoop(self: *TerminalEmulator) !void {
    while (self.running) {
        // Handle input
        if (try self.pollInput()) |input| {
            try self.processInput(input);
        }

        // Render frame
        try self.renderFrame();

        // Maintain 60fps
        try self.waitForNextFrame();
    }
}
```

### Code Editor Integration

```zig
// Code editor text change handler
pub fn onTextChanged(self: *CodeEditor, change: TextChange) !void {
    // Update document
    try self.document.applyChange(change);

    // Process with ZFont
    const line_text = self.document.getLine(change.line);
    var analysis = try self.cursor_processor.analyzeTextForCursor(
        line_text, self.editor_width
    );
    defer analysis.deinit();

    // Update cursor position
    if (analysis.requires_complex_shaping) {
        self.cursor_pos = try self.adjustCursorForComplexText(
            self.cursor_pos, &analysis
        );
    }

    // Invalidate rendering cache
    try self.invalidateLineCache(change.line);
}
```

### Performance-Critical Application

```zig
// High-performance rendering pipeline
pub fn renderHighPerformance(self: *HighPerfApp) !void {
    // Use multiple optimization strategies

    // 1. Viewport culling
    const visible_lines = self.getVisibleLines();

    // 2. Complexity-based processing
    for (visible_lines) |line_num| {
        const line_text = self.getLineText(line_num);
        const complexity = self.optimizer.analyzeTextComplexity(line_text);

        switch (complexity) {
            .simple => try self.renderSimpleText(line_text, line_num),
            .moderate => try self.renderModerateText(line_text, line_num),
            .complex, .very_complex => try self.renderComplexText(line_text, line_num),
        }
    }

    // 3. Background processing for non-visible content
    try self.scheduleBackgroundProcessing();
}
```

## Troubleshooting

### Common Issues

1. **Slow scrolling performance**
   - Enable viewport optimization
   - Increase cache size
   - Use background processing

2. **High memory usage**
   - Reduce cache TTL
   - Enable cache cleanup
   - Use lazy analysis

3. **Incorrect cursor positioning**
   - Ensure text analysis is current
   - Handle BiDi text properly
   - Use grapheme-aware movement

### Performance Tuning

```zig
// Adjust settings based on use case
const settings = zfont.TerminalPerformanceOptimizer.OptimizationSettings{
    // For fast scrolling
    .cache_size_limit = 2000,
    .cache_ttl_ms = 60000,
    .lazy_analysis_threshold = 500,

    // For memory-constrained environments
    .cache_size_limit = 100,
    .cache_ttl_ms = 5000,
    .lazy_analysis_threshold = 100,

    // For complex multilingual text
    .enable_background_processing = true,
    .viewport_buffer_lines = 10,
};
```

## Conclusion

ZFont's terminal integration provides:

- **60fps performance** for complex multilingual text
- **Intelligent optimization** based on content complexity
- **Memory-efficient** caching strategies
- **Unicode-compliant** cursor positioning
- **Script-aware** text selection
- **Zero-copy** architecture where possible

These integration patterns enable terminal applications to handle complex international text while maintaining optimal performance and user experience.