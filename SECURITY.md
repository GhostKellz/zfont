# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Security Considerations

ZFont is a font parsing and rendering library. Font files are complex binary formats that have historically been vectors for security vulnerabilities. ZFont is designed with the following security principles:

### Memory Safety

- Written in Zig with bounds-checking enabled by default
- No unsafe pointer arithmetic outside of controlled parsing contexts
- All array and slice accesses are bounds-checked
- Integer overflow is detected in debug builds

### Input Validation

- Font file headers are validated before parsing
- Table offsets and sizes are validated against file boundaries
- Malformed font data results in explicit errors rather than undefined behavior
- Glyph data bounds are checked during rendering

### Attack Surface

When using ZFont, be aware of the following:

1. **Untrusted Font Files**: ZFont parses TrueType/OpenType font files which are complex binary formats. While we validate inputs, maliciously crafted fonts could potentially trigger parsing bugs.

2. **Memory Usage**: Complex fonts with many glyphs can consume significant memory. Consider limiting font file sizes in untrusted contexts.

3. **Rendering Performance**: Fonts with complex outlines could cause excessive CPU usage. Consider timeouts for rendering operations in security-sensitive contexts.

## Reporting a Vulnerability

If you discover a security vulnerability in ZFont, please report it responsibly:

1. **Do not** open a public GitHub issue for security vulnerabilities
2. Email the maintainers directly with:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact assessment
   - Any suggested fixes (optional)

3. Allow reasonable time for a fix before public disclosure

## Hardening Recommendations

When using ZFont in security-sensitive contexts:

- Validate font file sources before loading
- Consider sandboxing font parsing operations
- Limit maximum font file sizes
- Use release builds with appropriate optimization for production
- Keep ZFont updated to the latest version
