# Installation

ZFont targets the Zig development version declared in `build.zig.zon` and depends
on `gcode` for Unicode semantics.

## Fetch

Use a release tag when one is available for the version you want to test:

```bash
zig fetch --save https://github.com/ghostkellz/zfont/archive/refs/tags/<tag>.tar.gz
```

For local development, use a path dependency from your application checkout.

## Build Integration

```zig
const zfont = b.dependency("zfont", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zfont", zfont.module("zfont"));
```

## Local Verification

```bash
zig build
zig build test
```

ZFont is experimental. Verify the exact APIs and text/font behavior your
application depends on before shipping it.
