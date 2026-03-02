//! Slash Build Configuration

const std = @import("std");

const version = "0.1.0";

const onig_cflags = &[_][]const u8{
    "-std=gnu99",
    "-DNDEBUG",
    "-DHAVE_CONFIG_H",
    "-DONIG_EXTERN=extern",
    "-fno-sanitize=undefined",
};

// Oniguruma C sources (compiled individually).
// Note: unicode_fold_data.c, unicode_property_data*.c, unicode_wb_data.c,
// unicode_egcb_data.c are #included by unicode.c and must NOT be listed here.
const onig_sources = &[_][]const u8{
    // Core
    "onig_init.c",
    "regcomp.c",
    "regenc.c",
    "regerror.c",
    "regexec.c",
    "regext.c",
    "regparse.c",
    "regsyntax.c",
    "regtrav.c",
    "regversion.c",
    "st.c",
    // Unicode (includes data files internally)
    "unicode.c",
    "unicode_fold1_key.c",
    "unicode_fold2_key.c",
    "unicode_fold3_key.c",
    "unicode_unfold_key.c",
    // Encodings
    "ascii.c",
    "utf8.c",
    "utf16_be.c",
    "utf16_le.c",
    "utf32_be.c",
    "utf32_le.c",
    "big5.c",
    "cp1251.c",
    "euc_jp.c",
    "euc_jp_prop.c",
    "euc_kr.c",
    "euc_tw.c",
    "gb18030.c",
    "iso8859_1.c",
    "iso8859_2.c",
    "iso8859_3.c",
    "iso8859_4.c",
    "iso8859_5.c",
    "iso8859_6.c",
    "iso8859_7.c",
    "iso8859_8.c",
    "iso8859_9.c",
    "iso8859_10.c",
    "iso8859_11.c",
    "iso8859_13.c",
    "iso8859_14.c",
    "iso8859_15.c",
    "iso8859_16.c",
    "koi8.c",
    "koi8_r.c",
    "sjis.c",
    "sjis_prop.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // =========================================================================
    // Main executable (with Oniguruma)
    // =========================================================================

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    main_mod.addOptions("build_options", options);
    main_mod.addIncludePath(b.path("onig"));
    main_mod.addCSourceFiles(.{
        .root = b.path("onig"),
        .files = onig_sources,
        .flags = onig_cflags,
    });

    const exe = b.addExecutable(.{
        .name = "slash",
        .root_module = main_mod,
    });

    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = ".." } },
        .dest_sub_path = "bin/slash",
    });
    b.getInstallStep().dependOn(&install_exe.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run slash");
    run_step.dependOn(&run_cmd.step);

    // =========================================================================
    // Tests
    // =========================================================================

    const test_step = b.step("test", "Run tests");

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addOptions("build_options", options);
    test_mod.addIncludePath(b.path("onig"));
    test_mod.addCSourceFiles(.{
        .root = b.path("onig"),
        .files = onig_sources,
        .flags = onig_cflags,
    });

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    // =========================================================================
    // Grammar — Parser Generator Tool
    // =========================================================================

    const grammar_mod = b.createModule(.{
        .root_source_file = b.path("src/grammar.zig"),
        .target = target,
        .optimize = optimize,
    });

    const grammar_exe = b.addExecutable(.{
        .name = "grammar",
        .root_module = grammar_mod,
    });

    const install_grammar = b.addInstallArtifact(grammar_exe, .{
        .dest_dir = .{ .override = .{ .custom = ".." } },
        .dest_sub_path = "bin/grammar",
    });

    const grammar_step = b.step("grammar", "Build grammar tool");
    grammar_step.dependOn(&install_grammar.step);
}
