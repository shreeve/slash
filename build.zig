//! Slash Build Configuration

const std = @import("std");

const version = "0.1.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // =========================================================================
    // Main executable
    // =========================================================================

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "slash",
        .root_module = main_mod,
    });

    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = ".." } },
        .dest_sub_path = "bin/slash",
    });
    b.getInstallStep().dependOn(&install_exe.step);

    // Run command
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
    });
    test_mod.addOptions("build_options", options);

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
