//! Slash — Build Configuration
//!
//! Usage:
//!   zig build                    Build bin/slash
//!   zig build run -- <args>      Build and run with arguments
//!   zig build test               Run tests

const std = @import("std");

const version = "0.0.0";

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

    // Install to ./bin/slash at the repo root (matches .gitignore, matches nexus).
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

    const test_step = b.step("test", "Run all tests");

    // Unit tests rooted at src/main.zig (the top-level `test { ... }` block
    // explicitly imports every module so each module's test blocks run).
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", options);

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    // Golden snapshot tests live in src/goldens.zig and are auto-discovered
    // via main.zig's top-level `test { _ = @import("goldens.zig"); }` block.
    // `test-shape` and `test-program` are named aliases for the same run.
    const test_shape_step = b.step("test-shape", "Run Shape golden snapshot tests");
    test_shape_step.dependOn(&run_tests.step);

    const test_program_step = b.step("test-program", "Run Program golden snapshot tests");
    test_program_step.dependOn(&run_tests.step);
}
