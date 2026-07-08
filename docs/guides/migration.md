# Migration Notes

ZFont is not yet a drop-in replacement for HarfBuzz, ICU, FreeType, FontConfig,
or Pango. Use this guide to evaluate where it can already help and where it still
needs implementation.

## Safe Evaluation Areas

- gcode-backed terminal text experiments
- font metadata parsing experiments
- cursor/selection behavior prototypes
- programming font and Nerd Font fallback planning
- Phantom integration fixtures

## Do Not Treat As Complete Yet

- full glyph rasterization replacement for FreeType
- full system font discovery replacement for FontConfig
- full shaping replacement for HarfBuzz/Pango
- full BiDi replacement for ICU
- production GPU text rendering

## Evaluation Checklist

- [ ] Identify exact fonts and scripts your application needs.
- [ ] Add fixture tests for those fonts and strings.
- [ ] Compare output against your current stack.
- [ ] Measure performance on your target hardware.
- [ ] Keep fallback behavior explicit for unsupported fonts/scripts.

## Migration Strategy

1. Start with terminal width/cursor behavior where gcode-backed helpers are most useful.
2. Add font metadata parsing only for fixture fonts you control.
3. Keep HarfBuzz/FreeType/FontConfig in production until ZFont covers your required tables and scripts.
4. Promote ZFont usage incrementally as tests prove behavior.
