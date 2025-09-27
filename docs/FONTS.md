# Font Catalog & Licensing Guide

This guide catalogues the fonts that ZFont can automatically discover or that we recommend for developer-facing applications. It also highlights licensing constraints so you can decide which families can ship with your product and which must remain end-user installs.

---

## 📦 Recommended Open Fonts

These families work well for terminals, editors, and dashboards and are available under permissive licenses. They can be bundled with your application as long as you follow each license's attribution requirements.

| Family | Style Notes | License |
|--------|-------------|---------|
| Fira Code | Ligature-heavy monospace, clear at small sizes | SIL Open Font License 1.1 |
| JetBrains Mono | Friendly developer Sans/Mono, wide glyph variants | Apache License 2.0 |
| Cascadia Code / Mono | Microsoft terminal font with Powerline + ligatures | SIL Open Font License 1.1 |
| Source Code Pro | Neutral monospace companion to Source Sans | SIL Open Font License 1.1 |
| Hack | Tightly hinted monospace, low-DPI friendly | MIT-like / Hack Open Font License |
| Iosevka (all variants) | Highly configurable monospace/semi-monospace family | SIL Open Font License 1.1 |
| Victor Mono | Expressive italics and ligatures for UI or code | SIL Open Font License 1.1 |
| Meslo LG / MesloLGS NF | PowerLevel10k reference font, Nerd Font patched editions | MIT License |
| IBM Plex Mono | Corporate-friendly monospace with multiple weights | SIL Open Font License 1.1 |
| Terminus (TTF / OTB) | Retro bitmap aesthetic with sharp hinting | SIL Open Font License 1.1 |
| PxPlus IBM VGA8 / Proggy | Pixel fonts for CRT nostalgia | MIT-like (Proggy) / GPL-friendly variants |
| Sarasa Gothic / Sarasa Mono | Latin + CJK composite built on Iosevka | SIL Open Font License 1.1 |
| Noto Sans Mono CJK (SC/TC/JP/KR) | Googles comprehensive CJK monospace | SIL Open Font License 1.1 |
| Monaspace (Neon/Argon/Xenon/Radon/Krypton) | Variable monospace family from GitHub | SIL Open Font License 1.1 |
| Recursive Mono (Casual/Linear) | Variable monospace with casual/linear axes | SIL Open Font License 1.1 |
| Roboto / Roboto Slab | Google Sans family for UI body text | Apache License 2.0 |
| Ubuntu | Canonicals default UI typeface | Ubuntu Font Licence 1.0 |
| Cabin | Humanist sans inspired by Gill Sans | SIL Open Font License 1.1 |
| Libre Caslon Text / Display | OFL-licensed Caslon revival for UI headers | SIL Open Font License 1.1 |
| Caslon (commercial variants) | Serif fallback, check vendor EULA | Varies (see vendor) |
| DejaVu Sans / Serif / Mono | Comprehensive Unicode coverage | Bitstream Vera License / Public Domain additions |
| Droid Sans / Serif | Clean Android UI families | Apache License 2.0 |
| Gentium Book Basic / Gentium Plus | Classic serif with rich diacritics | SIL Open Font License 1.1 |
| Linux Libertine | Book-weight serif with extensive glyph set | SIL Open Font License 1.1 |
| IM FELL (DW Pica, English, etc.) | Digitized historical serif set | SIL Open Font License 1.1 |
| Open Baskerville | Modernized Baskerville revival | SIL Open Font License 1.1 |
| EB Garamond | Claude Garamond revival with optical sizes | SIL Open Font License 1.1 |
| Ghostscript / URW Core35 (Nimbus Sans/Mono/Roman, URW Bookman, URW Gothic, URW Palladio, URW Chancery L, Century Schoolbook L) | Drop-in replacements for classic PostScript families | GNU GPL w/ font exception |

> ℹ️ *Redistribution tip*: SIL Open Font License (OFL) allows bundling and subsetting. Keep the license text with the font, and rename only via the OFL reserved font name rules.

---

## 💼 Commercial & Seat-Licensed Favorites

The following families are beloved by developers but cannot be redistributed without purchasing licenses. Document how users can point ZFont at their locally installed fonts and avoid shipping the binaries.

| Family | Vendor | License Notes | Integration Guidance |
|--------|--------|---------------|----------------------|
| Operator Mono | Hoefler&Co. (Monotype) | Per-seat commercial license; no redistribution | Detect via `dynamic_config` font overrides or user font directories |
| Cartograph CF | Connary Fagen | Commercial license per user/site | Allow user-specified font paths; do not bundle |
| PragmataPro | Fabrizio Schiavi | Commercial license; no sharing | Provide override instructions; prefix fallback with `PragmataPro` when detected |
| Dank Mono | Phil PlF | Commercial license; single-user | Document manual install plus `dynamic_config` override |
| Input Mono | DJR / Font Bureau | Free for personal use, but redistribution prohibited | Point to user install, respect license for subsets |
| MonoLisa | MonoLisa | Team/Personal commercial license | Provide fallback instructions and style toggles |

### Working with commercial fonts

1. **Do not bundle** the font files. Instead, expose configuration hooks:
   ```zig
   const config = dynamic_config.getConfig();
   try font_manager.registerPreferredFonts(&[_][]const u8{
       config.primary_font.?,
       "Operator Mono",
       "PragmataPro",
   });
   ```
2. **Surface detection feedback** in logs or UI so users know whether ZFont picked up their licensed font.
3. **Document fallback behavior**—if a commercial font is missing, ZFont should gracefully fall back to one of the OFL families listed above.

---

## 🎛️ Nerd Font Strategy

Nerd Font builds (e.g., `MesloLGS NF`, `FiraCode Nerd Font`, `JetBrainsMono NF`) merge developer glyphs with extended icon sets. ZFonts programming font manager now probes for these aliases automatically:

- `programming_fonts.zig` enumerates patched variants alongside the base families.
- `powerlevel10k.zig` prioritizes MesloLGS Nerd Font for prompt symbols and falls back to other Nerd Fonts when available.

To ensure consistent icon coverage:

1. Ship configuration defaults pointing to `MesloLGS NF` or the users preferred Nerd Font.
2. Keep an emoji/color fallback (e.g., `Noto Color Emoji`) in your fallback chain.

---

## � Ligature Support

Many of the fonts above ship with programming ligatures. ZFont exposes two layers for controlling them:

1. **Runtime configuration** – Set `enable-ligatures = true` (default) in your `dynamic_config` file to enable OpenType ligatures globally. Hot reload keeps UI components in sync.
2. **Per-call control** – Pass `LigatureOptions{ .enable_ligatures = true }` to `ProgrammingFontManager.processLigatures` when you need fine-grained control inside editors or renderers.

For fonts that only provide partial ligature coverage, toggle `LigatureOptions.font_specific_only = true` so ZFont only substitutes ligatures present in the active font.

---

## �📄 Keeping Licenses Nearby

Whenever you bundle a font, include a copy of its license in your distribution (e.g., under `licenses/fonts/`). For end-user installed fonts, point to the vendors license page in your documentation instead of mirroring the EULA.

> ✅ *Best practice*: Track third-party assets in `docs/FONTS.md` (this file) and mirror the summary in your release notes so compliance reviews stay simple.
