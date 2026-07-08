# ZFont Documentation

ZFont is an experimental Zig font and terminal text-processing library. The docs
are organized around the current implemented surface, clear experimental
boundaries, and the path toward a more complete pure-Zig font stack.

## Documentation Map

```mermaid
flowchart TD
    start["Start here<br/>docs/README.md"]

    start --> gs["Getting Started"]
    start --> ref["Reference"]
    start --> guides["Guides"]
    start --> internals["Internals"]
    start --> project["Project"]

    gs --> quick["quickstart.md"]
    gs --> install["installation.md"]

    ref --> api["api.md"]
    ref --> support["support-matrix.md"]

    guides --> terminal["terminal-integration.md"]
    guides --> fonts["fonts.md"]
    guides --> migration["migration.md"]

    internals --> arch["architecture.md"]

    project --> performance["performance.md"]
```

## Runtime Shape

```mermaid
flowchart LR
    app["Zig application"] --> zfont["zfont root module"]
    zfont --> font["font metadata / glyph APIs"]
    zfont --> text["text processors"]
    zfont --> terminal["terminal helpers"]
    zfont --> experimental["experimental shaping / GPU / emoji rendering"]

    text --> gcode["gcode Unicode semantics"]
    terminal --> gcode
    font --> parser["font_parser / font_manager"]
    experimental --> future["implementation and fixture work required"]
```

## Stability Flow

```mermaid
flowchart TD
    surface{"Which surface?"}
    surface --> current["Current usable APIs"]
    surface --> partial["Partial implementation"]
    surface --> experimental["Experimental / placeholder-heavy"]
    surface --> planned["Planned"]

    current --> use["Use with local tests"]
    partial --> verify["Validate against your fonts/text"]
    experimental --> avoid["Do not treat as stable"]
    planned --> roadmap["Track in tasks/todo.md"]
```

## Getting Started

- [Installation](getting-started/installation.md) - Add ZFont as a Zig dependency and run local verification.
- [Quickstart](getting-started/quickstart.md) - Minimal examples for font manager and terminal text helpers.

## Reference

- [API Reference](reference/api.md) - Current exported API grouped by maturity.
- [Support Matrix](reference/support-matrix.md) - Implemented, partial, experimental, and planned surfaces.

## Guides

- [Terminal Integration](guides/terminal-integration.md) - Terminal text measurement, cursor movement, and gcode-backed semantics.
- [Font Catalog and Licensing](guides/fonts.md) - Recommended fonts and redistribution notes.
- [Migration Notes](guides/migration.md) - How to evaluate ZFont alongside HarfBuzz, ICU, FreeType, and FontConfig.

## Internals

- [Architecture](internals/architecture.md) - Module graph, data flow, and experimental boundaries.

## Project

- [Performance Evidence](project/performance.md) - Current benchmark posture and how future results should be recorded.

## Quick Links

| Area | Path |
|------|------|
| Package metadata | [`../build.zig.zon`](../build.zig.zon) |
| Build script | [`../build.zig`](../build.zig) |
| Root module | [`../src/root.zig`](../src/root.zig) |
| gcode dependency | [`../build.zig.zon`](../build.zig.zon) |
| Task backlog | `../tasks/todo.md` (local ignored task notes) |

## Verification

```bash
zig build
zig build test
```

ZFont is experimental. Treat claims as valid only when backed by current source,
tests, fixture fonts, and benchmark output from your target environment.
