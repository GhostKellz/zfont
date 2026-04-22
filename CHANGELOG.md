# Changelog

All notable changes to ZFont will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
