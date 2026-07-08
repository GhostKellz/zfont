<div align="center">
  <img src="assets/icons/zfont.png" alt="ZFont Logo" width="200"/>

  # ZFont

  <img src="https://img.shields.io/badge/Zig-0.17.0--dev-F7A41D?style=for-the-badge&logo=zig&logoColor=white" alt="Zig">
  <img src="https://img.shields.io/badge/Built_with-Zig-F7A41D?style=for-the-badge&logo=zig&logoColor=white" alt="Built with Zig">
  <img src="https://img.shields.io/badge/Nerd_Fonts-Supported-00D4FF?style=for-the-badge&logo=nerdfonts&logoColor=white" alt="Nerd Fonts">
  <img src="https://img.shields.io/badge/Fira_Code-Supported-4B32C3?style=for-the-badge&logo=firacode&logoColor=white" alt="Fira Code">
  <img src="https://img.shields.io/badge/Unicode-Full_Support-5B2C87?style=for-the-badge&logo=unicode&logoColor=white" alt="Unicode">

## DISCLAIMER

⚠️ **EXPERIMENTAL LIBRARY - FOR LAB/PERSONAL USE** ⚠️

This is an experimental library under active development. It is
intended for research, learning, and personal projects. The API is subject
to change!

  **Modern Font Rendering Library for Zig**

  *Pure Zig implementation with advanced Unicode processing via gcode integration*
</div>

## 🚀 Features

### Current Focus
- **gcode integration**: Terminal-oriented Unicode semantics, display width, grapheme-aware helpers, and text-processing experiments.
- **Font metadata and layout experiments**: Font manager, parser, glyph, layout, shaping, and terminal helper APIs are present but still evolving.
- **Terminal workflows**: Cursor movement, CJK width handling, emoji sequence handling, and terminal text helpers are active development areas.
- **Pure Zig direction**: The project is exploring font parsing/layout/rendering without C dependencies, but it is not yet a complete FreeType/HarfBuzz/Pango replacement.

### Experimental Areas
- **BiDi and complex shaping**: Arabic, Indic, mixed-script, and BiDi processors exist, but full UAX #9 and HarfBuzz-class shaping are not yet guaranteed.
- **TrueType/OpenType parsing**: Several table parsers and glyph paths still need fixture-backed completion.
- **Emoji and color glyph rendering**: Fallback rendering exists, but full color glyph table support is not complete.
- **GPU/cache/rendering paths**: GPU-related resource handles and rendering paths are research surfaces until real backend lifecycle tests exist.

## 🎯 Project Goals

ZFont aims to grow toward a pure-Zig font and text stack. These are goals, not current production guarantees:

- **FreeType-style work** → font loading, glyph metrics, outlines, and rasterization
- **FontConfig-style work** → native font discovery, fallback, and coverage matching
- **Pango/HarfBuzz-style work** → text layout, shaping, feature application, and script-aware glyph runs

## 🛠️ Building

```bash
# Build the library and executable
zig build

# Run the demo application
zig build run

# Run tests
zig build test
```

## 📚 Usage

```zig
const std = @import("std");
const zfont = @import("zfont");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize font manager
    var font_manager = zfont.FontManager.init(allocator);
    defer font_manager.deinit();

    // Set up text layout
    var layout = zfont.TextLayout.init(allocator);
    defer layout.deinit();

    // Emoji rendering
    var emoji_renderer = zfont.EmojiRenderer.init(allocator);
    defer emoji_renderer.deinit();

    const is_emoji = emoji_renderer.isEmoji(0x1F600); // 😀
    std.debug.print("Is emoji: {}\n", .{is_emoji});
}
```

## 🔧 Architecture

- **Font Manager**: font loading and caching API under active development
- **Font Parser**: OpenType/TrueType table parsing, currently partial
- **Glyph Renderer**: glyph rendering and hinting experiments
- **Text Layout / Shaping**: script-aware layout work, not yet full HarfBuzz parity
- **Emoji Renderer**: emoji detection and fallback experiments
- **Terminal Helpers**: gcode-backed terminal text handling and cursor movement

## 🎨 Programming Font Support

ZFont tracks common programming fonts and Nerd Font aliases for fallback and integration experiments:

- **Fira Code**: Complete ligature support
- **JetBrains Mono**: Developer-optimized rendering
- **Cascadia Code**: Microsoft's programming font
- **Source Code Pro**: Adobe's monospace font

## 🌟 Nerd Font Integration

Nerd Font support is an active integration target for developer icons and terminal UI symbols:

- File type icons
- Git status indicators
- Programming language symbols
- System and tool icons

## 🤝 Related Projects

- [gcode](https://github.com/ghostkellz/gcode) - Unicode library for terminal semantics

## 📄 Development Status

ZFont is experimental and in active development. Current focus areas:

- Core font rendering engine
- Text layout and shaping
- Emoji fallback systems
- Programming font optimizations
- Performance benchmarking

## 📚 Documentation

- [Documentation Index](docs/README.md) - Clean docs map and stability boundaries
- [Quickstart](docs/getting-started/quickstart.md) - Minimal current API examples
- [API Reference](docs/reference/api.md) - Exported API grouped by maturity
- [Support Matrix](docs/reference/support-matrix.md) - Implemented, partial, experimental, and planned areas
- [Architecture](docs/internals/architecture.md) - Module graph and data flows
- [Performance Evidence](docs/project/performance.md) - Current benchmark policy

---

<div align="center">
  <sub>Built with ⚡ in Zig</sub>
</div>
