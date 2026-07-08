# Changelog

All notable changes to ZFont will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.8] - 2026-07-08

### Added
- Real TrueType/OpenType table parsing in `font_parser.zig` for `head`, `maxp`,
  `hhea`, `hmtx`, `cmap`, `name`, `OS/2`, `loca`, and `glyf`, replacing the
  previous placeholder stubs. Includes bounds-checked big-endian readers,
  cmap formats 0/4/6/12 with best-subtable selection, name-table family/style
  extraction (UTF-16BE + Latin-1), real hmtx advance widths with font-unit→pixel
  scaling, OS/2-backed `x_height`/`cap_height` and Unicode-range script coverage,
  and simple-glyph outline/bbox parsing
- `shaping.zig`: an honest shaping result model (`ShapedGlyph`, `ShapingResult`)
  carrying glyph id, codepoint, cluster, x/y advance, x/y offset, direction,
  script, and source byte range. `shape()` resolves glyph ids from the real cmap
  and advances from real hmtx; uncovered codepoints are emitted as `.notdef`
- `font_set.zig`: a deterministic, non-owning `FontSet` doing real cmap coverage
  analysis via `Font.hasGlyph`. `coveringFont`/`coveringIndex` pick the first
  registered font that contains a glyph; `resolveRuns` splits text into
  `FontRun`s by covering font for explicit, no-discovery fallback chains
- `test_font.zig`: a deterministic in-memory TrueType generator (with
  `buildLetter` for disjoint-coverage fixtures) so parser, shaping, and fallback
  tests are fixture-backed with no binary blobs or licensing concerns

### Changed
- Test count grew to 34 (from 17); new tests are fixture-backed and cover
  metadata, cmap hits/misses, metrics, advances, outline geometry, malformed
  input rejection, shaping results, and coverage-based fallback

### Notes
- Still honestly deferred: composite `glyf` assembly, CFF/CFF2 outlines,
  Arabic/Indic contextual shaping, BiDi visual reordering, system font
  discovery, and GPU texture handles (tracked in `tasks/todo.md`)

## [0.1.7] - 2026-06-05

### Changed
- Updated for Zig 0.17.0-dev compatibility (std library reorganization)
- Migrated all source files from managed `std.ArrayList(T).init(allocator)` to the
  unmanaged `.empty` pattern with allocator-passed methods (`.append(a, x)`,
  `.deinit(a)`, `.toOwnedSlice(a)`, `.appendSlice(a, s)`, etc.)
- Rewrote `threading.zig` after removal of `std.Thread.Pool`, `std.Thread.Mutex`,
  and `std.atomic.Queue`; `FontLoader` now uses `std.Thread.spawn` with a
  mutex-guarded queue
- Migrated std reorganizations:
  - `std.fs.cwd`/`Dir`/`File` → `std.Io.Dir`/`File` with a global single-threaded io
  - `std.posix.getenv`/`std.process.getEnvVarOwned` → global `Threaded` environ
  - `std.mem.toLower` → `std.ascii.lowerString`
  - `std.mem.split` → `splitScalar`/`splitSequence`
  - `std.mem.page_size` → `std.heap.page_size_min`
- Re-integrated gcode against its flat v0.1.5 API (`gcode.BiDi`, `gcode.Script`,
  `gcode.getScript`, `gcode.ComplexScriptAnalyzer`, etc.) replacing the old
  submodule-style `gcode.bidi.*`/`gcode.script.*` paths

### Fixed
- ~15 latent logic bugs surfaced by a forced full-analysis compile pass
  (emoji renderer f32/usize coercions, `EmojiInfo`/`TableRecord` visibility,
  hinting optional-return mismatch, const-assignment in font fallback,
  gcode integration `[]const u32` vs `[]const u8` mismatches)

### Removed
- 8 dead orphan modules that never compiled and were referenced by nothing:
  `cell_renderer.zig`, `font_features.zig`, `grid_alignment.zig`,
  `kde_integration.zig`, `p10k_segments.zig`, `powerline_symbols.zig`,
  `variable_fonts.zig`, `wayland_renderer.zig`

## [0.1.6] - 2026-06-05

### Changed
- Zig 0.17.0-dev compatibility fixes and dependency update

## [0.1.5] - 2025-04-22

### Changed
- Updated for Zig 0.17.0-dev.56 compatibility
- Replaced deprecated `std.time.nanoTimestamp()` with `std.os.linux.clock_gettime()` in:
  - `terminal_optimization.zig`
  - `font_fallback.zig`
  - `p10k_segments.zig`
- Updated gcode dependency to v0.1.3
- Renamed docs/ files to lowercase convention

### Added
- SECURITY.md with vulnerability reporting guidelines and hardening recommendations

## [0.1.4] - 2025-03-15

### Changed
- Updated for Zig 0.16.0-dev.2960 compatibility
- Switched gcode dependency to tagged release URL

## [0.1.3] - 2025-02-20

### Fixed
- `@abs` unsigned type negation for Zig 0.16 compatibility

## [0.1.2] - 2025-02-10

### Fixed
- `font_parser.zig` - 10 readInt API fixes for Zig 0.16
- `variable_fonts.zig` - 18 readInt API fixes
- `variable_fonts.zig` - Memory leak fix (free instance.coordinates in deinit)
- `variable_fonts.zig` - For loop syntax fix (index capture)
- `variable_fonts.zig` - var to const for unmutated variables

## [0.1.1] - 2025-01-25

### Changed
- Updated for Zig 0.16.0-dev.2193 compatibility

## [0.1.0] - 2025-01-15

### Added
- Initial release
- Full Unicode compliance via gcode integration
- Pure Zig implementation (no C dependencies)
- TrueType/OpenType font parsing and rendering
- Advanced text shaping with OpenType feature support
- Complex script support (Arabic, Devanagari, Thai, Hebrew, Myanmar, Khmer)
- Bidirectional text rendering (BiDi UAX#9)
- GPU-accelerated glyph caching
- Multi-threaded font loading
- Memory-mapped font file support
- ZWJ emoji sequence rendering
- Skin tone modifier and regional flag support
- Terminal-specific optimizations
- PowerLevel10k support
- Intelligent font fallback chains
- Dynamic configuration with hot-reloading
