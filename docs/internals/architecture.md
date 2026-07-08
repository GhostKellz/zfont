# Architecture

ZFont is organized as a pure-Zig font/text stack that delegates Unicode semantics
to gcode and keeps font parsing, layout, fallback, and rendering in this package.

## Module Shape

```mermaid
flowchart LR
    root["src/root.zig"] --> font["font / font_manager / font_parser"]
    root --> glyph["glyph / glyph_renderer / hinting"]
    root --> layout["text_layout / text_shaper"]
    root --> terminal["terminal_text_handler / cursor / performance"]
    root --> scripts["arabic / indic / bidi / emoji"]
    root --> gpu["gpu_cache"]

    terminal --> gcode["gcode"]
    scripts --> gcode
    layout --> font
    glyph --> font
```

## Text Flow

```mermaid
flowchart TD
    input["UTF-8 text"] --> segment["gcode segmentation / width"]
    segment --> script["script and direction analysis"]
    script --> shape["ZFont shaping layer"]
    shape --> glyphs["glyph ids / clusters / advances"]
    glyphs --> render["renderer or terminal consumer"]

    shape --> gaps["partial implementation today"]
```

## Font Flow

```mermaid
flowchart TD
    file["font bytes"] --> parser["FontParser"]
    parser --> tables["OpenType tables"]
    tables --> cmap["cmap coverage"]
    tables --> metrics["metrics"]
    tables --> outlines["glyph outlines"]
    cmap --> fallback["fallback chain"]
    metrics --> layout["text layout"]
    outlines --> raster["rasterization path"]

    tables --> partial["several tables still partial"]
```

## Boundaries

- gcode owns Unicode property tables, segmentation, normalization, and terminal width policy.
- ZFont should own font file parsing, glyph lookup, fallback, shaping results, and rendering/rasterization.
- GPU and full shaping should remain experimental until real backends and fixture tests exist.
