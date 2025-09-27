const std = @import("std");
const root = @import("root.zig");
const gcode = @import("gcode");

// Advanced OpenType font feature control for terminal applications
// Supports ligatures, contextual alternates, and other typographic features
pub const FontFeatureManager = struct {
    allocator: std.mem.Allocator,

    // Feature configurations per font
    font_features: std.AutoHashMap(*root.Font, FontFeatureSet),

    // Global feature settings
    global_features: GlobalFeatureSettings,

    // Feature cache for performance
    feature_cache: std.AutoHashMap(FeatureCacheKey, CachedFeatureResult),

    // Programming language specific features
    language_features: std.StringHashMap(ProgrammingLanguageFeatures),

    const Self = @This();

    const FontFeatureSet = struct {
        // Ligature controls
        liga: FeatureState = .auto, // Standard ligatures
        dlig: FeatureState = .disabled, // Discretionary ligatures
        hlig: FeatureState = .disabled, // Historical ligatures
        clig: FeatureState = .auto, // Contextual ligatures

        // Contextual features
        calt: FeatureState = .auto, // Contextual alternates
        cswh: FeatureState = .disabled, // Contextual swashes
        rclt: FeatureState = .auto, // Required contextual alternates

        // Number formatting
        lnum: FeatureState = .disabled, // Lining numbers
        onum: FeatureState = .disabled, // Oldstyle numbers
        pnum: FeatureState = .disabled, // Proportional numbers
        tnum: FeatureState = .auto, // Tabular numbers (preferred for terminals)

        // Character variants
        zero: FeatureState = .auto, // Slashed zero
        ss01: FeatureState = .disabled, // Stylistic set 1
        ss02: FeatureState = .disabled, // Stylistic set 2
        ss03: FeatureState = .disabled, // Stylistic set 3
        ss04: FeatureState = .disabled, // Stylistic set 4
        ss05: FeatureState = .disabled, // Stylistic set 5
        ss06: FeatureState = .disabled, // Stylistic set 6
        ss07: FeatureState = .disabled, // Stylistic set 7
        ss08: FeatureState = .disabled, // Stylistic set 8
        ss09: FeatureState = .disabled, // Stylistic set 9
        ss10: FeatureState = .disabled, // Stylistic set 10

        // Language-specific features
        locl: FeatureState = .auto, // Localized forms

        // Terminal-specific optimizations
        terminal_optimized: bool = true,
        force_monospace: bool = true,
        disable_ambiguous_features: bool = true,
    };

    const FeatureState = enum {
        disabled, // Feature explicitly disabled
        auto, // Feature enabled based on context
        enabled, // Feature explicitly enabled
        context_dependent, // Feature depends on programming language context
    };

    const GlobalFeatureSettings = struct {
        // Programming language detection
        enable_language_detection: bool = true,
        language_detection_method: LanguageDetectionMethod = .file_extension,

        // Performance settings
        cache_feature_results: bool = true,
        max_cache_size: usize = 1000,

        // Fallback behavior
        fallback_on_missing_features: bool = true,
        strict_feature_matching: bool = false,

        // Terminal compatibility
        disable_complex_features: bool = false,
        limit_ligature_length: ?usize = 4, // Maximum characters in a ligature

        const LanguageDetectionMethod = enum {
            file_extension,
            shebang,
            content_analysis,
            manual,
        };
    };

    const FeatureCacheKey = struct {
        font_ptr: *root.Font,
        text_hash: u64,
        language: ProgrammingLanguage,
        features_hash: u64,

        pub fn hash(self: FeatureCacheKey) u64 {
            var hasher = std.hash.Wyhash.init(0xFEA7C0DE);
            hasher.update(std.mem.asBytes(&self.font_ptr));
            hasher.update(std.mem.asBytes(&self.text_hash));
            hasher.update(std.mem.asBytes(&self.language));
            hasher.update(std.mem.asBytes(&self.features_hash));
            return hasher.final();
        }

        pub fn eql(a: FeatureCacheKey, b: FeatureCacheKey) bool {
            return a.font_ptr == b.font_ptr and
                   a.text_hash == b.text_hash and
                   a.language == b.language and
                   a.features_hash == b.features_hash;
        }
    };

    const CachedFeatureResult = struct {
        shaped_text: []ShapedGlyph,
        feature_list: []OpenTypeFeature,
        timestamp: i64,
    };

    const ShapedGlyph = struct {
        glyph_id: u32,
        cluster: u32,
        advance_x: f32,
        advance_y: f32,
        offset_x: f32,
        offset_y: f32,
        flags: GlyphFlags,
    };

    const GlyphFlags = packed struct {
        is_ligature: bool = false,
        is_mark: bool = false,
        is_base: bool = false,
        is_contextual: bool = false,
        _padding: u4 = 0,
    };

    const OpenTypeFeature = struct {
        tag: [4]u8,
        value: u32,
        start: u32,
        end: u32,
    };

    const ProgrammingLanguage = enum {
        unknown,
        c,
        cpp,
        rust,
        zig,
        go,
        javascript,
        typescript,
        python,
        java,
        kotlin,
        swift,
        haskell,
        ocaml,
        fsharp,
        scala,
        clojure,
        lisp,
        scheme,
        erlang,
        elixir,
        ruby,
        php,
        perl,
        lua,
        shell,
        sql,
        html,
        css,
        xml,
        json,
        yaml,
        toml,
        markdown,
    };

    const ProgrammingLanguageFeatures = struct {
        // Language-specific ligature preferences
        arrow_ligatures: bool = true, // ->, =>, <=, etc.
        comparison_ligatures: bool = true, // ==, !=, >=, <=, etc.
        logical_ligatures: bool = true, // &&, ||, !!, etc.
        assignment_ligatures: bool = true, // :=, +=, -=, etc.
        comment_ligatures: bool = true, // //, /*, */, etc.
        bracket_ligatures: bool = false, // <<, >>, etc.
        pipe_ligatures: bool = true, // |>, <|, etc.

        // Stylistic preferences
        prefer_slashed_zero: bool = true,
        prefer_dotted_zero: bool = false,
        cursive_italics: bool = false,

        // Language-specific symbols
        lambda_symbol: bool = false,
        mathematical_symbols: bool = false,
        custom_operators: []const []const u8 = &[_][]const u8{},
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        var manager = Self{
            .allocator = allocator,
            .font_features = std.AutoHashMap(*root.Font, FontFeatureSet).init(allocator),
            .global_features = GlobalFeatureSettings{},
            .feature_cache = std.AutoHashMap(FeatureCacheKey, CachedFeatureResult).init(allocator),
            .language_features = std.StringHashMap(ProgrammingLanguageFeatures).init(allocator),
        };

        manager.initializeLanguageFeatures() catch {};
        return manager;
    }

    pub fn deinit(self: *Self) void {
        // Cleanup feature cache
        var cache_iter = self.feature_cache.iterator();
        while (cache_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.shaped_text);
            self.allocator.free(entry.value_ptr.feature_list);
        }
        self.feature_cache.deinit();

        // Cleanup language features
        var lang_iter = self.language_features.iterator();
        while (lang_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.custom_operators) |op| {
                self.allocator.free(op);
            }
            self.allocator.free(entry.value_ptr.custom_operators);
        }
        self.language_features.deinit();

        self.font_features.deinit();
    }

    fn initializeLanguageFeatures(self: *Self) !void {
        // Initialize programming language specific features

        // Rust
        try self.addLanguageFeatures("rust", ProgrammingLanguageFeatures{
            .arrow_ligatures = true,
            .comparison_ligatures = true,
            .logical_ligatures = true,
            .assignment_ligatures = true,
            .pipe_ligatures = true,
            .prefer_slashed_zero = true,
            .custom_operators = try self.allocator.dupe([]const u8, &[_][]const u8{ "->", "=>", "|>", "<|", "::", ".." }),
        });

        // Zig
        try self.addLanguageFeatures("zig", ProgrammingLanguageFeatures{
            .arrow_ligatures = true,
            .comparison_ligatures = true,
            .logical_ligatures = true,
            .assignment_ligatures = true,
            .prefer_slashed_zero = true,
            .custom_operators = try self.allocator.dupe([]const u8, &[_][]const u8{ "=>", "==", "!=", ">=", "<=", "++", "--" }),
        });

        // JavaScript/TypeScript
        try self.addLanguageFeatures("javascript", ProgrammingLanguageFeatures{
            .arrow_ligatures = true,
            .comparison_ligatures = true,
            .logical_ligatures = true,
            .assignment_ligatures = true,
            .prefer_slashed_zero = false,
            .custom_operators = try self.allocator.dupe([]const u8, &[_][]const u8{ "=>", "===", "!==", "&&", "||", "??" }),
        });

        // Haskell
        try self.addLanguageFeatures("haskell", ProgrammingLanguageFeatures{
            .arrow_ligatures = true,
            .comparison_ligatures = true,
            .logical_ligatures = true,
            .pipe_ligatures = true,
            .lambda_symbol = true,
            .mathematical_symbols = true,
            .custom_operators = try self.allocator.dupe([]const u8, &[_][]const u8{ "->", "<-", "=>", ">>", "<<", ">>=", "=<<" }),
        });

        // Python
        try self.addLanguageFeatures("python", ProgrammingLanguageFeatures{
            .arrow_ligatures = true,
            .comparison_ligatures = true,
            .logical_ligatures = false, // Python uses 'and', 'or'
            .assignment_ligatures = true,
            .lambda_symbol = true,
            .custom_operators = try self.allocator.dupe([]const u8, &[_][]const u8{ "->", "==", "!=", ">=", "<=", "//" }),
        });
    }

    fn addLanguageFeatures(self: *Self, language: []const u8, features: ProgrammingLanguageFeatures) !void {
        const lang_key = try self.allocator.dupe(u8, language);
        try self.language_features.put(lang_key, features);
    }

    pub fn setFontFeatures(self: *Self, font: *root.Font, features: FontFeatureSet) !void {
        try self.font_features.put(font, features);
    }

    pub fn getFontFeatures(self: *Self, font: *root.Font) FontFeatureSet {
        return self.font_features.get(font) orelse FontFeatureSet{};
    }

    pub fn enableFeature(self: *Self, font: *root.Font, feature_tag: []const u8) !void {
        var features = self.getFontFeatures(font);
        try self.setFeatureByTag(&features, feature_tag, .enabled);
        try self.setFontFeatures(font, features);
    }

    pub fn disableFeature(self: *Self, font: *root.Font, feature_tag: []const u8) !void {
        var features = self.getFontFeatures(font);
        try self.setFeatureByTag(&features, feature_tag, .disabled);
        try self.setFontFeatures(font, features);
    }

    fn setFeatureByTag(self: *Self, features: *FontFeatureSet, tag: []const u8, state: FeatureState) !void {
        _ = self;

        if (std.mem.eql(u8, tag, "liga")) features.liga = state
        else if (std.mem.eql(u8, tag, "dlig")) features.dlig = state
        else if (std.mem.eql(u8, tag, "hlig")) features.hlig = state
        else if (std.mem.eql(u8, tag, "clig")) features.clig = state
        else if (std.mem.eql(u8, tag, "calt")) features.calt = state
        else if (std.mem.eql(u8, tag, "cswh")) features.cswh = state
        else if (std.mem.eql(u8, tag, "rclt")) features.rclt = state
        else if (std.mem.eql(u8, tag, "lnum")) features.lnum = state
        else if (std.mem.eql(u8, tag, "onum")) features.onum = state
        else if (std.mem.eql(u8, tag, "pnum")) features.pnum = state
        else if (std.mem.eql(u8, tag, "tnum")) features.tnum = state
        else if (std.mem.eql(u8, tag, "zero")) features.zero = state
        else if (std.mem.eql(u8, tag, "ss01")) features.ss01 = state
        else if (std.mem.eql(u8, tag, "ss02")) features.ss02 = state
        else if (std.mem.eql(u8, tag, "ss03")) features.ss03 = state
        else if (std.mem.eql(u8, tag, "ss04")) features.ss04 = state
        else if (std.mem.eql(u8, tag, "ss05")) features.ss05 = state
        else if (std.mem.eql(u8, tag, "ss06")) features.ss06 = state
        else if (std.mem.eql(u8, tag, "ss07")) features.ss07 = state
        else if (std.mem.eql(u8, tag, "ss08")) features.ss08 = state
        else if (std.mem.eql(u8, tag, "ss09")) features.ss09 = state
        else if (std.mem.eql(u8, tag, "ss10")) features.ss10 = state
        else if (std.mem.eql(u8, tag, "locl")) features.locl = state
        else return error.UnknownFeatureTag;
    }

    pub fn shapeText(
        self: *Self,
        font: *root.Font,
        text: []const u8,
        language: ProgrammingLanguage,
    ) ![]ShapedGlyph {
        // Check cache first
        const cache_key = self.createCacheKey(font, text, language);
        if (self.feature_cache.get(cache_key)) |cached| {
            return try self.allocator.dupe(ShapedGlyph, cached.shaped_text);
        }

        // Get font features
        const font_features = self.getFontFeatures(font);

        // Get language-specific features
        const lang_features = self.getLanguageFeatures(language);

        // Create OpenType feature list
        const ot_features = try self.buildOpenTypeFeatureList(font_features, lang_features, text);
        defer self.allocator.free(ot_features);

        // Perform text shaping
        const shaped_glyphs = try self.performTextShaping(font, text, ot_features);

        // Cache the result
        try self.cacheShapingResult(cache_key, shaped_glyphs, ot_features);

        return shaped_glyphs;
    }

    fn createCacheKey(self: *Self, font: *root.Font, text: []const u8, language: ProgrammingLanguage) FeatureCacheKey {
        var text_hasher = std.hash.Wyhash.init(0);
        text_hasher.update(text);

        const font_features = self.getFontFeatures(font);
        var features_hasher = std.hash.Wyhash.init(0);
        features_hasher.update(std.mem.asBytes(&font_features));

        return FeatureCacheKey{
            .font_ptr = font,
            .text_hash = text_hasher.final(),
            .language = language,
            .features_hash = features_hasher.final(),
        };
    }

    fn getLanguageFeatures(self: *Self, language: ProgrammingLanguage) ProgrammingLanguageFeatures {
        const lang_name = switch (language) {
            .rust => "rust",
            .zig => "zig",
            .javascript, .typescript => "javascript",
            .haskell => "haskell",
            .python => "python",
            else => return ProgrammingLanguageFeatures{},
        };

        return self.language_features.get(lang_name) orelse ProgrammingLanguageFeatures{};
    }

    fn buildOpenTypeFeatureList(
        self: *Self,
        font_features: FontFeatureSet,
        lang_features: ProgrammingLanguageFeatures,
        text: []const u8,
    ) ![]OpenTypeFeature {
        var features = std.ArrayList(OpenTypeFeature).init(self.allocator);

        // Add enabled font features
        try self.addFeatureIfEnabled(&features, "liga", font_features.liga, text);
        try self.addFeatureIfEnabled(&features, "dlig", font_features.dlig, text);
        try self.addFeatureIfEnabled(&features, "calt", font_features.calt, text);
        try self.addFeatureIfEnabled(&features, "clig", font_features.clig, text);
        try self.addFeatureIfEnabled(&features, "tnum", font_features.tnum, text);
        try self.addFeatureIfEnabled(&features, "zero", font_features.zero, text);

        // Add language-specific features
        if (lang_features.prefer_slashed_zero and font_features.zero == .auto) {
            try features.append(OpenTypeFeature{
                .tag = [_]u8{ 'z', 'e', 'r', 'o' },
                .value = 1,
                .start = 0,
                .end = @intCast(text.len),
            });
        }

        return features.toOwnedSlice();
    }

    fn addFeatureIfEnabled(
        self: *Self,
        features: *std.ArrayList(OpenTypeFeature),
        tag: []const u8,
        state: FeatureState,
        text: []const u8,
    ) !void {
        _ = self;

        const should_enable = switch (state) {
            .disabled => false,
            .enabled => true,
            .auto => self.shouldAutoEnableFeature(tag, text),
            .context_dependent => self.shouldEnableContextual(tag, text),
        };

        if (should_enable) {
            try features.append(OpenTypeFeature{
                .tag = [_]u8{ tag[0], tag[1], tag[2], tag[3] },
                .value = 1,
                .start = 0,
                .end = @intCast(text.len),
            });
        }
    }

    fn shouldAutoEnableFeature(self: *Self, tag: []const u8, text: []const u8) bool {
        _ = self;

        if (std.mem.eql(u8, tag, "liga")) {
            // Enable ligatures if common programming ligatures are found
            return std.mem.indexOf(u8, text, "->") != null or
                   std.mem.indexOf(u8, text, "=>") != null or
                   std.mem.indexOf(u8, text, "==") != null or
                   std.mem.indexOf(u8, text, "!=") != null or
                   std.mem.indexOf(u8, text, "<=") != null or
                   std.mem.indexOf(u8, text, ">=") != null;
        }

        if (std.mem.eql(u8, tag, "calt")) {
            // Enable contextual alternates for better character fitting
            return true;
        }

        if (std.mem.eql(u8, tag, "tnum")) {
            // Enable tabular numbers for better alignment
            return self.containsNumbers(text);
        }

        if (std.mem.eql(u8, tag, "zero")) {
            // Enable slashed zero if zeros are present
            return std.mem.indexOf(u8, text, "0") != null;
        }

        return false;
    }

    fn shouldEnableContextual(self: *Self, tag: []const u8, text: []const u8) bool {
        _ = self;
        _ = tag;
        _ = text;
        // Context-dependent features would analyze surrounding text
        return false;
    }

    fn containsNumbers(self: *Self, text: []const u8) bool {
        _ = self;
        for (text) |char| {
            if (char >= '0' and char <= '9') return true;
        }
        return false;
    }

    fn performTextShaping(
        self: *Self,
        font: *root.Font,
        text: []const u8,
        features: []const OpenTypeFeature,
    ) ![]ShapedGlyph {
        _ = font;
        _ = features;

        // Mock text shaping implementation
        // In real implementation, this would use HarfBuzz or similar
        var glyphs = std.ArrayList(ShapedGlyph).init(self.allocator);

        var i: usize = 0;
        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const codepoint = std.unicode.utf8Decode(text[i..i + char_len]) catch text[i];

            // Check for ligature opportunities
            const ligature_info = self.checkLigature(text, i);
            if (ligature_info.length > 1) {
                // Create ligature glyph
                try glyphs.append(ShapedGlyph{
                    .glyph_id = ligature_info.glyph_id,
                    .cluster = @intCast(i),
                    .advance_x = 12.0 * @as(f32, @floatFromInt(ligature_info.length)), // Mock advance
                    .advance_y = 0.0,
                    .offset_x = 0.0,
                    .offset_y = 0.0,
                    .flags = .{ .is_ligature = true },
                });

                i += ligature_info.length;
            } else {
                // Regular glyph
                try glyphs.append(ShapedGlyph{
                    .glyph_id = codepoint,
                    .cluster = @intCast(i),
                    .advance_x = 12.0, // Mock advance
                    .advance_y = 0.0,
                    .offset_x = 0.0,
                    .offset_y = 0.0,
                    .flags = .{},
                });

                i += char_len;
            }
        }

        return glyphs.toOwnedSlice();
    }

    const LigatureInfo = struct {
        length: usize,
        glyph_id: u32,
    };

    fn checkLigature(self: *Self, text: []const u8, pos: usize) LigatureInfo {
        _ = self;

        // Simple ligature detection
        if (pos + 1 < text.len) {
            if (text[pos] == '-' and text[pos + 1] == '>') {
                return LigatureInfo{ .length = 2, .glyph_id = 0xE001 }; // Mock ligature glyph
            }
            if (text[pos] == '=' and text[pos + 1] == '>') {
                return LigatureInfo{ .length = 2, .glyph_id = 0xE002 };
            }
            if (text[pos] == '=' and text[pos + 1] == '=') {
                return LigatureInfo{ .length = 2, .glyph_id = 0xE003 };
            }
            if (text[pos] == '!' and text[pos + 1] == '=') {
                return LigatureInfo{ .length = 2, .glyph_id = 0xE004 };
            }
        }

        return LigatureInfo{ .length = 1, .glyph_id = text[pos] };
    }

    fn cacheShapingResult(
        self: *Self,
        key: FeatureCacheKey,
        glyphs: []const ShapedGlyph,
        features: []const OpenTypeFeature,
    ) !void {
        // Clean cache if needed
        if (self.feature_cache.count() >= self.global_features.max_cache_size) {
            try self.cleanCache();
        }

        const result = CachedFeatureResult{
            .shaped_text = try self.allocator.dupe(ShapedGlyph, glyphs),
            .feature_list = try self.allocator.dupe(OpenTypeFeature, features),
            .timestamp = std.time.milliTimestamp(),
        };

        try self.feature_cache.put(key, result);
    }

    fn cleanCache(self: *Self) !void {
        const now = std.time.milliTimestamp();
        const max_age = 60000; // 1 minute

        var keys_to_remove = std.ArrayList(FeatureCacheKey).init(self.allocator);
        defer keys_to_remove.deinit();

        var iter = self.feature_cache.iterator();
        while (iter.next()) |entry| {
            if (now - entry.value_ptr.timestamp > max_age) {
                try keys_to_remove.append(entry.key_ptr.*);
            }
        }

        for (keys_to_remove.items) |key| {
            if (self.feature_cache.fetchRemove(key)) |kv| {
                self.allocator.free(kv.value.shaped_text);
                self.allocator.free(kv.value.feature_list);
            }
        }
    }

    // Language detection methods
    pub fn detectLanguageFromFilename(self: *Self, filename: []const u8) ProgrammingLanguage {
        _ = self;

        if (std.mem.endsWith(u8, filename, ".rs")) return .rust;
        if (std.mem.endsWith(u8, filename, ".zig")) return .zig;
        if (std.mem.endsWith(u8, filename, ".js")) return .javascript;
        if (std.mem.endsWith(u8, filename, ".ts")) return .typescript;
        if (std.mem.endsWith(u8, filename, ".py")) return .python;
        if (std.mem.endsWith(u8, filename, ".c")) return .c;
        if (std.mem.endsWith(u8, filename, ".cpp") or std.mem.endsWith(u8, filename, ".cxx")) return .cpp;
        if (std.mem.endsWith(u8, filename, ".go")) return .go;
        if (std.mem.endsWith(u8, filename, ".java")) return .java;
        if (std.mem.endsWith(u8, filename, ".hs")) return .haskell;
        if (std.mem.endsWith(u8, filename, ".swift")) return .swift;

        return .unknown;
    }

    pub fn detectLanguageFromShebang(self: *Self, text: []const u8) ProgrammingLanguage {
        _ = self;

        if (!std.mem.startsWith(u8, text, "#!")) return .unknown;

        const first_line_end = std.mem.indexOf(u8, text, "\n") orelse text.len;
        const shebang = text[0..first_line_end];

        if (std.mem.indexOf(u8, shebang, "python") != null) return .python;
        if (std.mem.indexOf(u8, shebang, "node") != null) return .javascript;
        if (std.mem.indexOf(u8, shebang, "ruby") != null) return .ruby;
        if (std.mem.indexOf(u8, shebang, "bash") != null or std.mem.indexOf(u8, shebang, "sh") != null) return .shell;
        if (std.mem.indexOf(u8, shebang, "perl") != null) return .perl;

        return .unknown;
    }

    // Configuration methods
    pub fn configureForTerminal(self: *Self, font: *root.Font) !void {
        var features = FontFeatureSet{
            .liga = .auto,
            .calt = .auto,
            .tnum = .enabled, // Always use tabular numbers in terminals
            .zero = .auto,
            .terminal_optimized = true,
            .force_monospace = true,
            .disable_ambiguous_features = true,
        };

        try self.setFontFeatures(font, features);
    }

    pub fn configureForProgrammingLanguage(self: *Self, font: *root.Font, language: ProgrammingLanguage) !void {
        var features = self.getFontFeatures(font);

        const lang_features = self.getLanguageFeatures(language);

        // Adjust based on language preferences
        if (lang_features.arrow_ligatures) {
            features.liga = .auto;
            features.calt = .auto;
        }

        if (lang_features.prefer_slashed_zero) {
            features.zero = .enabled;
        }

        if (lang_features.mathematical_symbols) {
            features.ss01 = .auto; // Might contain math symbols
        }

        try self.setFontFeatures(font, features);
    }

    // Performance monitoring
    pub fn getFeatureStats(self: *const Self) FeatureStats {
        return FeatureStats{
            .cached_results = @intCast(self.feature_cache.count()),
            .configured_fonts = @intCast(self.font_features.count()),
            .supported_languages = @intCast(self.language_features.count()),
            .cache_hit_rate = self.calculateCacheHitRate(),
        };
    }

    fn calculateCacheHitRate(self: *const Self) f32 {
        // This would track actual hit/miss ratios in a real implementation
        _ = self;
        return 0.85; // Mock hit rate
    }
};

pub const FeatureStats = struct {
    cached_results: u32,
    configured_fonts: u32,
    supported_languages: u32,
    cache_hit_rate: f32,
};

// Tests
test "FontFeatureManager initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = FontFeatureManager.init(allocator);
    defer manager.deinit();

    try testing.expect(manager.language_features.count() > 0);
    try testing.expect(manager.global_features.enable_language_detection == true);
}

test "FontFeatureManager feature control" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = FontFeatureManager.init(allocator);
    defer manager.deinit();

    // Mock font
    var mock_font: u32 = 0x12345678;
    const font_ptr: *root.Font = @ptrCast(&mock_font);

    // Test feature enabling
    manager.enableFeature(font_ptr, "liga") catch return;
    const features = manager.getFontFeatures(font_ptr);
    try testing.expect(features.liga == .enabled);
}

test "FontFeatureManager language detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = FontFeatureManager.init(allocator);
    defer manager.deinit();

    try testing.expect(manager.detectLanguageFromFilename("test.rs") == .rust);
    try testing.expect(manager.detectLanguageFromFilename("test.zig") == .zig);
    try testing.expect(manager.detectLanguageFromFilename("test.py") == .python);

    const python_shebang = "#!/usr/bin/env python3\nprint('hello')";
    try testing.expect(manager.detectLanguageFromShebang(python_shebang) == .python);
}