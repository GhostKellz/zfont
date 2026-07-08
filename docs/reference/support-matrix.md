# Support Matrix

| Surface | Status | Notes |
|---|---|---|
| Zig package/module | Experimental | Builds as a Zig package with gcode dependency. |
| Font manager lifecycle | Partial | Basic lifecycle exists; platform discovery and coverage matching need work. |
| Font metadata parsing | Partial | Name, cmap, metrics, and glyph parsing need fixture-backed completion. |
| Terminal text helpers | Partial | Useful for experiments; validate cursor/selection behavior per app. |
| gcode integration | Supported dependency path | gcode owns Unicode semantics; ZFont should avoid duplicating width/segmentation rules. |
| Arabic/Indic shaping | Experimental | Processors exist, but full shaping behavior is not production-proven. |
| BiDi layout | Experimental | Do not assume full UAX #9 correctness yet. |
| Emoji rendering | Experimental | Placeholder fallback shapes exist; color glyph rendering is not complete. |
| GPU cache/rendering | Experimental | Fake handles/placeholders must not be treated as real graphics resources. |
| FontConfig replacement | Planned | Native discovery and fallback policy are future work. |
| FreeType replacement | Planned | Real glyph outline parsing/rasterization must land first. |
| Pango/HarfBuzz replacement | Planned | Requires real shaping and fixture coverage. |

## Promotion Criteria

A surface should move toward stable only when it has:

- implementation without placeholder success paths
- redistributable fixture fonts or generated fixtures
- positive and negative tests
- documented ownership and error behavior
- downstream validation with Phantom or another real consumer
