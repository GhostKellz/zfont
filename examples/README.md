# ZFont Examples

This directory contains comprehensive examples demonstrating ZFont's advanced Unicode processing capabilities.

## Examples Overview

### 1. Arabic Text Processing (`arabic_text.zig`)
Demonstrates Arabic contextual forms and BiDi text processing:
- Contextual forms (isolated, initial, medial, final)
- Arabic ligature detection (LAM+ALEF combinations)
- BiDi text reordering for mixed Arabic/English content
- Real Arabic text samples with analysis

**Run**: `zig build run-arabic`

### 2. CJK Text Handling (`cjk_text.zig`)
Shows proper handling of Chinese, Japanese, and Korean text:
- Fullwidth vs halfwidth character detection
- Terminal width calculation for proper display
- Script-specific processing (Han, Hiragana, Katakana, Hangul)
- Terminal layout optimization
- Performance testing with large CJK content

**Run**: `zig build run-cjk`

### 3. Emoji Sequence Processing (`emoji_sequences.zig`)
Complete emoji handling including complex sequences:
- Simple emoji detection
- ZWJ (Zero Width Joiner) sequences (family, profession emojis)
- Flag sequences using Regional Indicators
- Skin tone modifier handling
- Keycap sequences
- Tag sequences (subdivision flags)
- Terminal layout for emoji-rich content

**Run**: `zig build run-emoji`

### 4. Terminal Integration (`terminal_integration.zig`)
Comprehensive terminal application integration:
- Multi-language text processing pipeline
- Intelligent cursor positioning in complex text
- Text selection with script awareness
- Performance optimization strategies
- Memory management patterns
- Real-world terminal scenarios

**Run**: `zig build run-terminal`

## Building Examples

### Quick Start
```bash
# Run all examples
zig build run-all

# Run specific example
zig build run-arabic
zig build run-cjk
zig build run-emoji
zig build run-terminal
```

### Manual Build
```bash
# Build individual examples
zig build-exe arabic_text.zig -freference-trace --name arabic_example
zig build-exe cjk_text.zig -freference-trace --name cjk_example
zig build-exe emoji_sequences.zig -freference-trace --name emoji_example
zig build-exe terminal_integration.zig -freference-trace --name terminal_example

# Run examples
./arabic_example
./cjk_example
./emoji_example
./terminal_example
```

## Example Output

### Arabic Text Processing
```
=== Arabic Text Processing Example ===

--- Example 1 ---
Arabic text: بسم الله الرحمن الرحيم
Found 15 contextual forms and 2 ligatures
Contextual forms:
  U+0628 -> U+FE8F (isolated) joins_left:false joins_right:true
  U+0633 -> U+FEB3 (initial) joins_left:false joins_right:true
  ...
Ligatures:
  U+0644+U+0627 -> U+FEFB
```

### CJK Text Processing
```
=== CJK Text Processing Example ===

--- Example 1 (Japanese) ---
Text: こんにちは世界
Description: Hello World (Hiragana + Han)
Analysis results:
  Total display width: 14.0
  Terminal cells needed: 14
  Mixed width characters: false
  CJK characters found: 7
```

### Emoji Sequence Processing
```
=== Emoji Sequence Processing Example ===

--- Example 1 ---
Text: 😀😍🤔
Description: Simple emoji
Complexity: Basic
Analysis results:
  Total emoji sequences: 3
  Total display width: 6.0
  Has complex sequences: false
```

### Terminal Integration
```
=== Terminal Integration Example ===
Processing complex multilingual text...

=== Text Analysis ===
Optimization level: complex
Total lines: 12
Line 1: "Welcome to زفونت (ZFont)!" (moderate)
  Width: 25.0, BiDi: true, Shaping: true
```

## Test Data

The examples use real-world multilingual text including:

- **Arabic**: Bismillah, greetings, common phrases
- **Hebrew**: Traditional greetings
- **Hindi**: Devanagari script samples
- **Chinese**: Simplified and traditional characters
- **Japanese**: Hiragana, Katakana, and Kanji
- **Korean**: Hangul syllables
- **Emoji**: Various complexity levels including:
  - Simple emoji (😀🤔)
  - Flag sequences (🇺🇸🇯🇵)
  - ZWJ sequences (👨‍👩‍👧‍👦)
  - Skin tone variants (👍🏻👍🏿)
  - Professional emoji (👩‍💻👨‍🔬)

## Performance Testing

Each example includes performance testing sections demonstrating:

- Processing speed with various text complexities
- Memory usage patterns
- Caching effectiveness
- Optimization strategies

## Integration Patterns

The examples demonstrate common integration patterns:

1. **Basic Processing**: Simple text analysis
2. **Error Handling**: Proper error management with Zig
3. **Memory Management**: RAII patterns with defer
4. **Performance Optimization**: Caching and lazy evaluation
5. **Terminal Integration**: Real-world terminal scenarios

## Educational Value

These examples serve as:

- **Learning resources** for Unicode text processing
- **Integration guides** for terminal applications
- **Performance benchmarks** for comparison
- **Test cases** for validation
- **Documentation** of best practices

## Extending Examples

To create your own examples:

1. Copy an existing example as a template
2. Add your specific use case
3. Include proper error handling and cleanup
4. Add performance measurements
5. Document the expected behavior

## Troubleshooting

### Common Issues

1. **Missing dependencies**: Ensure gcode is properly fetched
2. **Compilation errors**: Check Zig version compatibility
3. **Runtime errors**: Verify text encoding (UTF-8)
4. **Performance issues**: Enable optimizations (-O ReleaseFast)

### Debug Build
```bash
# Build with debug info
zig build-exe arabic_text.zig -g

# Run with debug output
./arabic_text
```

### Release Build
```bash
# Build optimized version
zig build-exe arabic_text.zig -O ReleaseFast

# Performance testing
time ./arabic_text
```

## Contributing Examples

When contributing new examples:

1. **Focus on real-world use cases**
2. **Include comprehensive error handling**
3. **Add performance measurements**
4. **Document expected output**
5. **Test with various input data**
6. **Follow existing code style**

Examples should demonstrate not just how to use ZFont, but how to use it effectively in production applications.