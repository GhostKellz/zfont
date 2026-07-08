# Font Catalog And Licensing

This guide lists useful font families for testing and integration. It is not a
claim that ZFont can fully parse, shape, or render every feature in every family.

## Open Fonts For Fixtures And Examples

| Family | Notes | License |
|---|---|---|
| Fira Code | Programming ligatures, common editor font | SIL Open Font License 1.1 |
| JetBrains Mono | Developer-focused monospace | Apache License 2.0 |
| Cascadia Code / Mono | Microsoft terminal font | SIL Open Font License 1.1 |
| Source Code Pro | Neutral monospace | SIL Open Font License 1.1 |
| Hack | Monospace with broad developer usage | MIT-like / Hack Open Font License |
| Iosevka | Configurable monospace family | SIL Open Font License 1.1 |
| DejaVu Sans / Serif / Mono | Broad Unicode coverage | Bitstream Vera License / public domain additions |
| Noto Sans Mono CJK | CJK monospace coverage | SIL Open Font License 1.1 |
| Noto Color Emoji | Emoji fallback candidate | SIL Open Font License 1.1 |

Keep license text with bundled fixture fonts. Prefer small redistributable test
fonts where possible.

## Commercial Fonts

Do not bundle commercial fonts unless their license explicitly allows it. Let
users point ZFont at locally installed fonts instead.

Examples: Operator Mono, Cartograph CF, PragmataPro, Dank Mono, Input Mono, and
MonoLisa.

## Nerd Fonts

Nerd Font patched families are useful for terminal/UI icon coverage. Treat them
as fallback candidates and test private-use codepoint behavior explicitly.
