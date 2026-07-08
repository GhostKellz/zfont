# API Reference

ZFont exports a broad experimental surface from `src/root.zig`. This page groups
that surface by maturity so consumers can avoid treating placeholders as stable
font infrastructure.

## Current Usable Surface

- `FontManager` - font manager skeleton and lifecycle API.
- `FontParser` - parser entrypoint, with several OpenType tables still partial.
- `Font`, `Glyph`, `GlyphRenderer`, `TextLayout`, `TextShaper` - core font/text abstractions under active development.
- `TerminalTextHandler`, `TerminalCursorProcessor`, `TerminalPerformanceOptimizer` - terminal-oriented text helpers.
- `GcodeTextProcessor`, `GcodeFontManager`, `GcodeTextShaper` - integration points with gcode.

## Partial Or Experimental Surface

- `BiDiProcessor`, `ArabicContextualProcessor`, `IndicSyllableProcessor`, `AdvancedScriptProcessor` - useful processors, but not yet a complete UAX #9 or HarfBuzz-class shaping implementation.
- `EmojiRenderer`, `EmojiSequenceProcessor` - emoji detection and fallback work; color glyph rendering is not complete.
- `FontFallbackChain` - fallback API, but real font coverage analysis is still planned.
- `OpenTypeFeatureEngine`, `ProgrammingFonts`, `PowerLevel10k` - developer-font and feature helpers that need fixture-backed validation.

## Placeholder-Heavy Or Planned Surface

- `GPUCache` and GPU-related resource handles are not production rendering backends.
- Full TrueType/OpenType glyph parsing, real rasterization, and platform font discovery require more implementation and fixtures.
- Full FreeType, FontConfig, Pango, HarfBuzz, or ICU replacement claims are future goals, not current support guarantees.

## Error Vocabulary

```zig
pub const FontError = error{
    InvalidFontData,
    FontNotFound,
    UnsupportedFormat,
    MemoryError,
    GlyphNotFound,
    LayoutError,
    RenderingError,
};
```

Prefer explicit error handling and add application-level fallback paths for
unsupported fonts, missing glyphs, and layout failures.
