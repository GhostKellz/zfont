# Terminal Integration

ZFont's most practical current use is terminal-oriented text handling that builds
on gcode for Unicode semantics.

## Current Pattern

```zig
var handler = try zfont.TerminalTextHandler.init(
    allocator,
    12.0,
    16.0,
    80,
    24,
);
defer handler.deinit();
```

Use terminal helpers for experiments around cursor positioning, wrapping, and
mixed-script text. Keep behavior covered by app-level tests because ZFont is not
yet a complete terminal text engine.

## Width Policy

Terminal width must be consistent across your stack. gcode should be the source
of truth for grapheme segmentation, display width, emoji sequences, and ambiguous
width policy. ZFont should consume those semantics rather than redefining them.

## Recommended Validation

Test terminal integration with:

- plain ASCII
- CJK wide characters
- emoji ZWJ sequences
- combining marks
- Arabic/Hebrew mixed with Latin text
- private-use Nerd Font symbols
- cursor movement across grapheme clusters
- selection and deletion by grapheme/display width

## Known Gaps

- line selection in `terminal_text_handler.zig` is still planned
- full BiDi layout is not guaranteed
- full font fallback and color emoji rendering are not complete
- performance claims need current benchmark output and runner metadata
