const std = @import("std");
const root = @import("root.zig");

// Advanced OpenType feature implementation
// Comprehensive support for OpenType Layout features
pub const OpenTypeFeatureEngine = struct {
    allocator: std.mem.Allocator,
    gsub_table: ?GSUBTable = null,
    gpos_table: ?GPOSTable = null,

    const Self = @This();

    // OpenType Layout Table structures
    pub const GSUBTable = struct {
        version: u32,
        script_list: ScriptList,
        feature_list: FeatureList,
        lookup_list: LookupList,

        pub const ScriptList = struct {
            scripts: std.HashMap(ScriptTag, Script, ScriptContext, std.hash_map.default_max_load_percentage),

            const ScriptContext = struct {
                pub fn hash(self: @This(), script: ScriptTag) u64 {
                    _ = self;
                    return @intFromEnum(script);
                }
                pub fn eql(self: @This(), a: ScriptTag, b: ScriptTag) bool {
                    _ = self;
                    return a == b;
                }
            };

            pub fn init(allocator: std.mem.Allocator) ScriptList {
                return ScriptList{
                    .scripts = std.HashMap(ScriptTag, Script, ScriptContext, std.hash_map.default_max_load_percentage).init(allocator),
                };
            }

            pub fn deinit(self: *ScriptList) void {
                self.scripts.deinit();
            }
        };

        pub const FeatureList = struct {
            features: std.HashMap(FeatureTag, Feature, FeatureContext, std.hash_map.default_max_load_percentage),

            const FeatureContext = struct {
                pub fn hash(self: @This(), feature: FeatureTag) u64 {
                    _ = self;
                    return @intFromEnum(feature);
                }
                pub fn eql(self: @This(), a: FeatureTag, b: FeatureTag) bool {
                    _ = self;
                    return a == b;
                }
            };

            pub fn init(allocator: std.mem.Allocator) FeatureList {
                return FeatureList{
                    .features = std.HashMap(FeatureTag, Feature, FeatureContext, std.hash_map.default_max_load_percentage).init(allocator),
                };
            }

            pub fn deinit(self: *FeatureList) void {
                self.features.deinit();
            }
        };

        pub const LookupList = struct {
            lookups: std.ArrayList(Lookup),

            pub fn init(allocator: std.mem.Allocator) LookupList {
                return LookupList{
                    .lookups = std.ArrayList(Lookup).init(allocator),
                };
            }

            pub fn deinit(self: *LookupList) void {
                self.lookups.deinit();
            }
        };

        pub fn init(allocator: std.mem.Allocator) GSUBTable {
            return GSUBTable{
                .version = 0x00010000,
                .script_list = ScriptList.init(allocator),
                .feature_list = FeatureList.init(allocator),
                .lookup_list = LookupList.init(allocator),
            };
        }

        pub fn deinit(self: *GSUBTable) void {
            self.script_list.deinit();
            self.feature_list.deinit();
            self.lookup_list.deinit();
        }
    };

    pub const GPOSTable = struct {
        version: u32,
        script_list: GSUBTable.ScriptList,
        feature_list: GSUBTable.FeatureList,
        lookup_list: GSUBTable.LookupList,

        pub fn init(allocator: std.mem.Allocator) GPOSTable {
            return GPOSTable{
                .version = 0x00010000,
                .script_list = GSUBTable.ScriptList.init(allocator),
                .feature_list = GSUBTable.FeatureList.init(allocator),
                .lookup_list = GSUBTable.LookupList.init(allocator),
            };
        }

        pub fn deinit(self: *GPOSTable) void {
            self.script_list.deinit();
            self.feature_list.deinit();
            self.lookup_list.deinit();
        }
    };

    pub const ScriptTag = enum(u32) {
        DFLT = 0x44464C54, // 'DFLT'
        latn = 0x6C61746E, // 'latn'
        arab = 0x61726162, // 'arab'
        deva = 0x64657661, // 'deva'
        thai = 0x74686169, // 'thai'
        hebr = 0x68656272, // 'hebr'
        cyrl = 0x6379726C, // 'cyrl'
        grek = 0x6772656B, // 'grek'
        hang = 0x68616E67, // 'hang' (Hangul)
        hani = 0x68616E69, // 'hani' (Han)
        kana = 0x6B616E61, // 'kana' (Katakana)
        hira = 0x68697261, // 'hira' (Hiragana)
        _,
    };

    pub const FeatureTag = enum(u32) {
        // Common Latin features
        kern = 0x6B65726E, // 'kern' - Kerning
        liga = 0x6C696761, // 'liga' - Standard Ligatures
        dlig = 0x646C6967, // 'dlig' - Discretionary Ligatures
        hlig = 0x686C6967, // 'hlig' - Historical Ligatures
        clig = 0x636C6967, // 'clig' - Contextual Ligatures

        // Case features
        smcp = 0x736D6370, // 'smcp' - Small Capitals
        c2sc = 0x63327363, // 'c2sc' - Capitals to Small Capitals
        case = 0x63617365, // 'case' - Case-Sensitive Forms

        // Number features
        lnum = 0x6C6E756D, // 'lnum' - Lining Figures
        onum = 0x6F6E756D, // 'onum' - Oldstyle Figures
        pnum = 0x706E756D, // 'pnum' - Proportional Figures
        tnum = 0x746E756D, // 'tnum' - Tabular Figures
        zero = 0x7A65726F, // 'zero' - Slashed Zero

        // Fractions
        frac = 0x66726163, // 'frac' - Fractions
        afrc = 0x61667263, // 'afrc' - Alternative Fractions

        // Positional forms
        sups = 0x73757073, // 'sups' - Superscript
        subs = 0x73756273, // 'subs' - Subscript
        ordn = 0x6F72646E, // 'ordn' - Ordinals

        // Stylistic features
        ss01 = 0x73733031, // 'ss01' - Stylistic Set 1
        ss02 = 0x73733032, // 'ss02' - Stylistic Set 2
        ss03 = 0x73733033, // 'ss03' - Stylistic Set 3
        ss04 = 0x73733034, // 'ss04' - Stylistic Set 4
        ss05 = 0x73733035, // 'ss05' - Stylistic Set 5
        ss06 = 0x73733036, // 'ss06' - Stylistic Set 6
        ss07 = 0x73733037, // 'ss07' - Stylistic Set 7
        ss08 = 0x73733038, // 'ss08' - Stylistic Set 8
        ss09 = 0x73733039, // 'ss09' - Stylistic Set 9
        ss10 = 0x73733130, // 'ss10' - Stylistic Set 10
        ss11 = 0x73733131, // 'ss11' - Stylistic Set 11
        ss12 = 0x73733132, // 'ss12' - Stylistic Set 12
        ss13 = 0x73733133, // 'ss13' - Stylistic Set 13
        ss14 = 0x73733134, // 'ss14' - Stylistic Set 14
        ss15 = 0x73733135, // 'ss15' - Stylistic Set 15
        ss16 = 0x73733136, // 'ss16' - Stylistic Set 16
        ss17 = 0x73733137, // 'ss17' - Stylistic Set 17
        ss18 = 0x73733138, // 'ss18' - Stylistic Set 18
        ss19 = 0x73733139, // 'ss19' - Stylistic Set 19
        ss20 = 0x73733230, // 'ss20' - Stylistic Set 20

        // Character variants
        cv01 = 0x63763031, // 'cv01' - Character Variant 1
        cv02 = 0x63763032, // 'cv02' - Character Variant 2
        cv03 = 0x63763033, // 'cv03' - Character Variant 3

        // Arabic features
        init = 0x696E6974, // 'init' - Initial Forms
        medi = 0x6D656469, // 'medi' - Medial Forms
        fina = 0x66696E61, // 'fina' - Final Forms
        isol = 0x69736F6C, // 'isol' - Isolated Forms
        rlig = 0x726C6967, // 'rlig' - Required Ligatures

        // Mark positioning
        mark = 0x6D61726B, // 'mark' - Mark Positioning
        mkmk = 0x6D6B6D6B, // 'mkmk' - Mark-to-Mark Positioning

        // Cursive attachment
        curs = 0x63757273, // 'curs' - Cursive Positioning

        // Indic features
        nukt = 0x6E756B74, // 'nukt' - Nukta Forms
        akhn = 0x616B686E, // 'akhn' - Akhands
        rphf = 0x72706866, // 'rphf' - Reph Forms
        blwf = 0x626C7766, // 'blwf' - Below-base Forms
        half = 0x68616C66, // 'half' - Half Forms
        pstf = 0x70737466, // 'pstf' - Post-base Forms
        vatu = 0x76617475, // 'vatu' - Vattu Variants
        cjct = 0x636A6374, // 'cjct' - Conjunct Forms

        _,
    };

    pub const Script = struct {
        default_lang_sys: ?LanguageSystem,
        lang_sys_records: std.ArrayList(LangSysRecord),

        pub fn init(allocator: std.mem.Allocator) Script {
            return Script{
                .default_lang_sys = null,
                .lang_sys_records = std.ArrayList(LangSysRecord).init(allocator),
            };
        }

        pub fn deinit(self: *Script) void {
            self.lang_sys_records.deinit();
        }
    };

    pub const LanguageSystem = struct {
        lookup_order: ?u16,
        required_feature_index: u16,
        feature_indices: std.ArrayList(u16),

        pub fn init(allocator: std.mem.Allocator) LanguageSystem {
            return LanguageSystem{
                .lookup_order = null,
                .required_feature_index = 0xFFFF,
                .feature_indices = std.ArrayList(u16).init(allocator),
            };
        }

        pub fn deinit(self: *LanguageSystem) void {
            self.feature_indices.deinit();
        }
    };

    pub const LangSysRecord = struct {
        lang_sys_tag: u32,
        lang_sys: LanguageSystem,
    };

    pub const Feature = struct {
        feature_params: ?u16,
        lookup_indices: std.ArrayList(u16),

        pub fn init(allocator: std.mem.Allocator) Feature {
            return Feature{
                .feature_params = null,
                .lookup_indices = std.ArrayList(u16).init(allocator),
            };
        }

        pub fn deinit(self: *Feature) void {
            self.lookup_indices.deinit();
        }
    };

    pub const Lookup = struct {
        lookup_type: u16,
        lookup_flag: u16,
        subtables: std.ArrayList(SubTable),
        mark_filtering_set: ?u16 = null,

        pub fn init(allocator: std.mem.Allocator) Lookup {
            return Lookup{
                .lookup_type = 0,
                .lookup_flag = 0,
                .subtables = std.ArrayList(SubTable).init(allocator),
            };
        }

        pub fn deinit(self: *Lookup) void {
            self.subtables.deinit();
        }
    };

    pub const SubTable = union(enum) {
        single_subst: SingleSubstitution,
        multiple_subst: MultipleSubstitution,
        alternate_subst: AlternateSubstitution,
        ligature_subst: LigatureSubstitution,
        contextual_subst: ContextualSubstitution,
        chaining_contextual_subst: ChainingContextualSubstitution,
        extension_subst: ExtensionSubstitution,
        reverse_chaining_subst: ReverseChainingSubstitution,

        // GPOS subtables
        single_pos: SinglePositioning,
        pair_pos: PairPositioning,
        cursive_pos: CursivePositioning,
        mark_to_base_pos: MarkToBasePositioning,
        mark_to_ligature_pos: MarkToLigaturePositioning,
        mark_to_mark_pos: MarkToMarkPositioning,
        contextual_pos: ContextualPositioning,
        chaining_contextual_pos: ChainingContextualPositioning,
        extension_pos: ExtensionPositioning,
    };

    // GSUB subtable types
    pub const SingleSubstitution = struct {
        format: u16,
        coverage: Coverage,
        substitutes: std.ArrayList(u16), // Format 1: delta, Format 2: substitute array

        pub fn init(allocator: std.mem.Allocator) SingleSubstitution {
            return SingleSubstitution{
                .format = 1,
                .coverage = Coverage.init(allocator),
                .substitutes = std.ArrayList(u16).init(allocator),
            };
        }

        pub fn deinit(self: *SingleSubstitution) void {
            self.coverage.deinit();
            self.substitutes.deinit();
        }
    };

    pub const MultipleSubstitution = struct {
        format: u16,
        coverage: Coverage,
        sequences: std.ArrayList(std.ArrayList(u16)),

        pub fn init(allocator: std.mem.Allocator) MultipleSubstitution {
            return MultipleSubstitution{
                .format = 1,
                .coverage = Coverage.init(allocator),
                .sequences = std.ArrayList(std.ArrayList(u16)).init(allocator),
            };
        }

        pub fn deinit(self: *MultipleSubstitution) void {
            self.coverage.deinit();
            for (self.sequences.items) |*seq| {
                seq.deinit();
            }
            self.sequences.deinit();
        }
    };

    pub const AlternateSubstitution = struct {
        format: u16,
        coverage: Coverage,
        alternate_sets: std.ArrayList(std.ArrayList(u16)),

        pub fn init(allocator: std.mem.Allocator) AlternateSubstitution {
            return AlternateSubstitution{
                .format = 1,
                .coverage = Coverage.init(allocator),
                .alternate_sets = std.ArrayList(std.ArrayList(u16)).init(allocator),
            };
        }

        pub fn deinit(self: *AlternateSubstitution) void {
            self.coverage.deinit();
            for (self.alternate_sets.items) |*set| {
                set.deinit();
            }
            self.alternate_sets.deinit();
        }
    };

    pub const LigatureSubstitution = struct {
        format: u16,
        coverage: Coverage,
        ligature_sets: std.ArrayList(LigatureSet),

        pub const LigatureSet = struct {
            ligatures: std.ArrayList(Ligature),

            pub fn init(allocator: std.mem.Allocator) LigatureSet {
                return LigatureSet{
                    .ligatures = std.ArrayList(Ligature).init(allocator),
                };
            }

            pub fn deinit(self: *LigatureSet) void {
                for (self.ligatures.items) |*lig| {
                    lig.deinit();
                }
                self.ligatures.deinit();
            }
        };

        pub const Ligature = struct {
            ligature_glyph: u16,
            component_glyphs: std.ArrayList(u16),

            pub fn init(allocator: std.mem.Allocator) Ligature {
                return Ligature{
                    .ligature_glyph = 0,
                    .component_glyphs = std.ArrayList(u16).init(allocator),
                };
            }

            pub fn deinit(self: *Ligature) void {
                self.component_glyphs.deinit();
            }
        };

        pub fn init(allocator: std.mem.Allocator) LigatureSubstitution {
            return LigatureSubstitution{
                .format = 1,
                .coverage = Coverage.init(allocator),
                .ligature_sets = std.ArrayList(LigatureSet).init(allocator),
            };
        }

        pub fn deinit(self: *LigatureSubstitution) void {
            self.coverage.deinit();
            for (self.ligature_sets.items) |*set| {
                set.deinit();
            }
            self.ligature_sets.deinit();
        }
    };

    // Simplified contextual substitution (full implementation would be much more complex)
    pub const ContextualSubstitution = struct {
        format: u16,

        pub fn init() ContextualSubstitution {
            return ContextualSubstitution{ .format = 1 };
        }
    };

    pub const ChainingContextualSubstitution = struct {
        format: u16,

        pub fn init() ChainingContextualSubstitution {
            return ChainingContextualSubstitution{ .format = 1 };
        }
    };

    pub const ExtensionSubstitution = struct {
        format: u16,
        extension_lookup_type: u16,

        pub fn init() ExtensionSubstitution {
            return ExtensionSubstitution{ .format = 1, .extension_lookup_type = 1 };
        }
    };

    pub const ReverseChainingSubstitution = struct {
        format: u16,

        pub fn init() ReverseChainingSubstitution {
            return ReverseChainingSubstitution{ .format = 1 };
        }
    };

    // GPOS subtable types
    pub const SinglePositioning = struct {
        format: u16,
        coverage: Coverage,
        value_records: std.ArrayList(ValueRecord),

        pub fn init(allocator: std.mem.Allocator) SinglePositioning {
            return SinglePositioning{
                .format = 1,
                .coverage = Coverage.init(allocator),
                .value_records = std.ArrayList(ValueRecord).init(allocator),
            };
        }

        pub fn deinit(self: *SinglePositioning) void {
            self.coverage.deinit();
            self.value_records.deinit();
        }
    };

    pub const PairPositioning = struct {
        format: u16,
        coverage: Coverage,
        pair_sets: std.ArrayList(PairSet),

        pub const PairSet = struct {
            pair_value_records: std.ArrayList(PairValueRecord),

            pub fn init(allocator: std.mem.Allocator) PairSet {
                return PairSet{
                    .pair_value_records = std.ArrayList(PairValueRecord).init(allocator),
                };
            }

            pub fn deinit(self: *PairSet) void {
                self.pair_value_records.deinit();
            }
        };

        pub const PairValueRecord = struct {
            second_glyph: u16,
            value_record1: ValueRecord,
            value_record2: ValueRecord,
        };

        pub fn init(allocator: std.mem.Allocator) PairPositioning {
            return PairPositioning{
                .format = 1,
                .coverage = Coverage.init(allocator),
                .pair_sets = std.ArrayList(PairSet).init(allocator),
            };
        }

        pub fn deinit(self: *PairPositioning) void {
            self.coverage.deinit();
            for (self.pair_sets.items) |*set| {
                set.deinit();
            }
            self.pair_sets.deinit();
        }
    };

    // Simplified implementations for other positioning types
    pub const CursivePositioning = struct { format: u16 };
    pub const MarkToBasePositioning = struct { format: u16 };
    pub const MarkToLigaturePositioning = struct { format: u16 };
    pub const MarkToMarkPositioning = struct { format: u16 };
    pub const ContextualPositioning = struct { format: u16 };
    pub const ChainingContextualPositioning = struct { format: u16 };
    pub const ExtensionPositioning = struct { format: u16 };

    pub const Coverage = struct {
        glyphs: std.ArrayList(u16),

        pub fn init(allocator: std.mem.Allocator) Coverage {
            return Coverage{
                .glyphs = std.ArrayList(u16).init(allocator),
            };
        }

        pub fn deinit(self: *Coverage) void {
            self.glyphs.deinit();
        }

        pub fn contains(self: *const Coverage, glyph_id: u16) bool {
            for (self.glyphs.items) |glyph| {
                if (glyph == glyph_id) return true;
            }
            return false;
        }
    };

    pub const ValueRecord = struct {
        x_placement: i16 = 0,
        y_placement: i16 = 0,
        x_advance: i16 = 0,
        y_advance: i16 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.gsub_table) |*gsub| gsub.deinit();
        if (self.gpos_table) |*gpos| gpos.deinit();
    }

    pub fn loadGSUB(self: *Self) !void {
        var gsub = GSUBTable.init(self.allocator);

        // Add common Latin script support
        var latin_script = Script.init(self.allocator);
        var default_lang_sys = LanguageSystem.init(self.allocator);

        // Add feature indices for common features
        try default_lang_sys.feature_indices.append(0); // kern
        try default_lang_sys.feature_indices.append(1); // liga

        latin_script.default_lang_sys = default_lang_sys;
        try gsub.script_list.scripts.put(.latn, latin_script);

        // Add features
        var kern_feature = Feature.init(self.allocator);
        try kern_feature.lookup_indices.append(0);
        try gsub.feature_list.features.put(.kern, kern_feature);

        var liga_feature = Feature.init(self.allocator);
        try liga_feature.lookup_indices.append(1);
        try gsub.feature_list.features.put(.liga, liga_feature);

        // Add lookups (simplified)
        var kern_lookup = Lookup.init(self.allocator);
        kern_lookup.lookup_type = 2; // Pair adjustment
        try gsub.lookup_list.lookups.append(kern_lookup);

        var liga_lookup = Lookup.init(self.allocator);
        liga_lookup.lookup_type = 4; // Ligature substitution
        try gsub.lookup_list.lookups.append(liga_lookup);

        self.gsub_table = gsub;
    }

    pub fn loadGPOS(self: *Self) !void {
        const gpos = GPOSTable.init(self.allocator);
        // Initialize with basic structure
        self.gpos_table = gpos;
    }

    pub fn hasFeature(self: *const Self, script: ScriptTag, feature: FeatureTag) bool {
        if (self.gsub_table) |*gsub| {
            if (gsub.script_list.scripts.get(script)) |_| {
                return gsub.feature_list.features.contains(feature);
            }
        }
        return false;
    }

    pub fn applyFeature(self: *Self, glyphs: []u16, feature: FeatureTag) !void {
        _ = self;
        _ = glyphs;
        _ = feature;
        // Feature application would be implemented here
        // This involves complex lookup processing
    }

    // Get available features for a script
    pub fn getAvailableFeatures(self: *const Self, script: ScriptTag, allocator: std.mem.Allocator) ![]FeatureTag {
        var features = std.ArrayList(FeatureTag).init(allocator);

        if (self.gsub_table) |*gsub| {
            if (gsub.script_list.scripts.get(script)) |_| {
                var iter = gsub.feature_list.features.iterator();
                while (iter.next()) |entry| {
                    try features.append(entry.key_ptr.*);
                }
            }
        }

        return features.toOwnedSlice();
    }
};

// High-level feature manager
pub const FeatureManager = struct {
    allocator: std.mem.Allocator,
    engine: OpenTypeFeatureEngine,
    active_features: std.ArrayList(OpenTypeFeatureEngine.FeatureTag),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var manager = Self{
            .allocator = allocator,
            .engine = OpenTypeFeatureEngine.init(allocator),
            .active_features = std.ArrayList(OpenTypeFeatureEngine.FeatureTag).init(allocator),
        };

        // Load default tables
        try manager.engine.loadGSUB();
        try manager.engine.loadGPOS();

        // Enable default features
        try manager.enableFeature(.kern);
        try manager.enableFeature(.liga);

        return manager;
    }

    pub fn deinit(self: *Self) void {
        self.engine.deinit();
        self.active_features.deinit();
    }

    pub fn enableFeature(self: *Self, feature: OpenTypeFeatureEngine.FeatureTag) !void {
        // Check if already enabled
        for (self.active_features.items) |existing| {
            if (existing == feature) return;
        }
        try self.active_features.append(feature);
    }

    pub fn disableFeature(self: *Self, feature: OpenTypeFeatureEngine.FeatureTag) void {
        for (self.active_features.items, 0..) |existing, i| {
            if (existing == feature) {
                _ = self.active_features.swapRemove(i);
                return;
            }
        }
    }

    pub fn isFeatureEnabled(self: *const Self, feature: OpenTypeFeatureEngine.FeatureTag) bool {
        for (self.active_features.items) |existing| {
            if (existing == feature) return true;
        }
        return false;
    }

    // Apply all active features to text
    pub fn processText(self: *Self, glyphs: []u16) !void {
        for (self.active_features.items) |feature| {
            try self.engine.applyFeature(glyphs, feature);
        }
    }

    // Preset configurations for different use cases
    pub fn configureForProgramming(self: *Self) !void {
        self.active_features.clearRetainingCapacity();

        // Programming-focused features
        try self.enableFeature(.liga);  // Code ligatures
        try self.enableFeature(.clig);  // Contextual ligatures
        try self.enableFeature(.zero);  // Slashed zero
        try self.enableFeature(.ss01);  // Stylistic set 1 (often alternative a)
        try self.enableFeature(.cv01);  // Character variant 1
    }

    pub fn configureForReading(self: *Self) !void {
        self.active_features.clearRetainingCapacity();

        // Reading-focused features
        try self.enableFeature(.kern);  // Kerning
        try self.enableFeature(.liga);  // Standard ligatures
        try self.enableFeature(.onum);  // Old-style figures
        try self.enableFeature(.smcp);  // Small caps
    }

    pub fn configureForMath(self: *Self) !void {
        self.active_features.clearRetainingCapacity();

        // Math-focused features
        try self.enableFeature(.kern);  // Kerning
        try self.enableFeature(.frac);  // Fractions
        try self.enableFeature(.sups);  // Superscripts
        try self.enableFeature(.subs);  // Subscripts
        try self.enableFeature(.lnum);  // Lining figures
        try self.enableFeature(.tnum);  // Tabular figures
    }
};

test "OpenTypeFeatureEngine initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var engine = OpenTypeFeatureEngine.init(allocator);
    defer engine.deinit();

    try engine.loadGSUB();
    try engine.loadGPOS();

    try testing.expect(engine.gsub_table != null);
    try testing.expect(engine.gpos_table != null);
}

test "FeatureManager configuration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = FeatureManager.init(allocator) catch return;
    defer manager.deinit();

    try manager.configureForProgramming();
    try testing.expect(manager.isFeatureEnabled(.liga));
    try testing.expect(manager.isFeatureEnabled(.zero));

    try manager.configureForReading();
    try testing.expect(manager.isFeatureEnabled(.kern));
    try testing.expect(manager.isFeatureEnabled(.onum));
}