const std = @import("std");

// Build script for ZFont examples
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add zfont dependency
    const zfont = b.dependency("zfont", .{
        .target = target,
        .optimize = optimize,
    });

    // Arabic text processing example
    const arabic_example = b.addExecutable(.{
        .name = "arabic_example",
        .root_source_file = b.path("arabic_text.zig"),
        .target = target,
        .optimize = optimize,
    });
    arabic_example.root_module.addImport("zfont", zfont.module("zfont"));
    b.installArtifact(arabic_example);

    // CJK text processing example
    const cjk_example = b.addExecutable(.{
        .name = "cjk_example",
        .root_source_file = b.path("cjk_text.zig"),
        .target = target,
        .optimize = optimize,
    });
    cjk_example.root_module.addImport("zfont", zfont.module("zfont"));
    b.installArtifact(cjk_example);

    // Emoji sequences example
    const emoji_example = b.addExecutable(.{
        .name = "emoji_example",
        .root_source_file = b.path("emoji_sequences.zig"),
        .target = target,
        .optimize = optimize,
    });
    emoji_example.root_module.addImport("zfont", zfont.module("zfont"));
    b.installArtifact(emoji_example);

    // Terminal integration example
    const terminal_example = b.addExecutable(.{
        .name = "terminal_example",
        .root_source_file = b.path("terminal_integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    terminal_example.root_module.addImport("zfont", zfont.module("zfont"));
    b.installArtifact(terminal_example);

    // Run commands
    const run_arabic = b.addRunArtifact(arabic_example);
    const run_cjk = b.addRunArtifact(cjk_example);
    const run_emoji = b.addRunArtifact(emoji_example);
    const run_terminal = b.addRunArtifact(terminal_example);

    // Build steps
    const run_arabic_step = b.step("run-arabic", "Run Arabic text processing example");
    run_arabic_step.dependOn(&run_arabic.step);

    const run_cjk_step = b.step("run-cjk", "Run CJK text processing example");
    run_cjk_step.dependOn(&run_cjk.step);

    const run_emoji_step = b.step("run-emoji", "Run emoji sequences example");
    run_emoji_step.dependOn(&run_emoji.step);

    const run_terminal_step = b.step("run-terminal", "Run terminal integration example");
    run_terminal_step.dependOn(&run_terminal.step);

    // Run all examples
    const run_all_step = b.step("run-all", "Run all examples");
    run_all_step.dependOn(&run_arabic.step);
    run_all_step.dependOn(&run_cjk.step);
    run_all_step.dependOn(&run_emoji.step);
    run_all_step.dependOn(&run_terminal.step);
}