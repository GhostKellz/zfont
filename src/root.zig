//! ZFont - Modern font rendering library for terminals
//! Replaces FreeType, FontConfig, and Pango with pure Zig implementation
const std = @import("std");

pub const Font = @import("font.zig").Font;
pub const FontManager = @import("font_manager.zig").FontManager;
pub const Glyph = @import("glyph.zig").Glyph;
pub const GlyphRenderer = @import("glyph_renderer.zig").GlyphRenderer;
pub const TextLayout = @import("text_layout.zig").TextLayout;
pub const TextShaper = @import("text_shaper.zig").TextShaper;
pub const EmojiRenderer = @import("emoji_renderer.zig").EmojiRenderer;
pub const FontParser = @import("font_parser.zig").FontParser;
pub const Hinting = @import("hinting.zig");
pub const SubpixelRenderer = @import("subpixel_renderer.zig").SubpixelRenderer;
pub const ProgrammingFonts = @import("programming_fonts.zig");
pub const GPUCache = @import("gpu_cache.zig").GPUCache;
pub const Unicode = @import("unicode.zig").Unicode;
pub const PowerLevel10k = @import("powerlevel10k.zig").PowerLevel10k;
pub const MemoryMappedFont = @import("memory_mapped_font.zig").MemoryMappedFont;
pub const ThreadedFontLoader = @import("threading.zig").FontLoader;
pub const TerminalOptimizer = @import("terminal_optimization.zig").TerminalOptimizer;

pub const FontError = error{
    InvalidFontData,
    FontNotFound,
    UnsupportedFormat,
    MemoryError,
    GlyphNotFound,
    LayoutError,
    RenderingError,
};

pub const FontFormat = enum {
    truetype,
    opentype,
    woff,
    woff2,
    unknown,
};

pub const RenderOptions = struct {
    size: f32,
    dpi: u32 = 96,
    enable_hinting: bool = true,
    enable_subpixel: bool = true,
    gamma: f32 = 1.8,
    weight: FontWeight = .normal,
    style: FontStyle = .normal,
};

pub const FontWeight = enum {
    thin,
    extra_light,
    light,
    normal,
    medium,
    semi_bold,
    bold,
    extra_bold,
    black,
};

pub const FontStyle = enum {
    normal,
    italic,
    oblique,
};

pub const Metrics = struct {
    ascent: f32,
    descent: f32,
    line_height: f32,
    x_height: f32,
    cap_height: f32,
};

test "zfont basic functionality" {
    const allocator = std.testing.allocator;

    var font_manager = FontManager.init(allocator);
    defer font_manager.deinit();

    // Basic test - will expand once we implement the core functionality
    try std.testing.expect(true);
}
