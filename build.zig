//! Slash — Build Configuration
//!
//! Usage:
//!   zig build                    Build bin/slash
//!   zig build run -- <args>      Build and run with arguments
//!   zig build test               Run tests

const std = @import("std");

const version = "1.2.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // =========================================================================
    // Dependencies
    // =========================================================================

    // zigline — the line editor library. Imported in slash's repl.zig
    // for raw-mode line editing, history, completion, and syntax-
    // highlighting hooks. Path dep until zigline reaches v1.0; see
    // build.zig.zon.
    const zigline_dep = b.dependency("zigline", .{
        .target = target,
        .optimize = optimize,
    });
    const zigline_mod = zigline_dep.module("zigline");

    // =========================================================================
    // Main executable
    // =========================================================================

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addOptions("build_options", options);
    main_mod.addImport("zigline", zigline_mod);

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

    // Unit tests + headless integration tests share one test binary,
    // rooted at `test_root.zig` at the project root. Zig 0.16
    // constrains `@import("path")` to files within the module's
    // directory tree (rooted at `root_source_file`'s parent), so
    // a project-root root is the simplest way to let
    // `tests/headless_tests.zig` reach back into `src/*` via
    // `../src/foo.zig` paths.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", options);
    test_mod.addImport("zigline", zigline_mod);

    // Tests need libc for std.c symbols (fork/waitpid/pipe/dup2/...).
    // Zig 0.16 removed the corresponding wrappers from std.posix, so the
    // runtime modules link against libc directly.
    test_mod.linkSystemLibrary("c", .{});

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    // The main executable also needs libc.
    main_mod.linkSystemLibrary("c", .{});

    // Named aliases for the layered test suites (PLAN §17.2). All run
    // through the same test binary in v0 since modules cross-reference
    // each other via @import; we keep separate step names so future work
    // can split them.
    const test_shape_step = b.step("test-shape", "Run Shape golden snapshot tests");
    test_shape_step.dependOn(&run_tests.step);

    const test_program_step = b.step("test-program", "Run Program golden snapshot tests");
    test_program_step.dependOn(&run_tests.step);

    const test_headless_step = b.step("test-headless", "Run headless integration tests");
    test_headless_step.dependOn(&run_tests.step);

    // PTY-driven REPL tests live in their own test binary so they can
    // be skipped on platforms without /dev/ptmx. They run the just-built
    // slash binary as a subprocess attached to a pseudo-terminal, drive
    // keystrokes through the master end, and assert on the rendered
    // output. After the zigline cutover, slash's PTY suite focuses on
    // shell-specific behavior (multi-line continuation, prompt content,
    // exit-status propagation, slash-flavored highlighter output) —
    // line-editor mechanics are covered in zigline's own PTY tests.
    const pty_mod = b.createModule(.{
        .root_source_file = b.path("tests/pty_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    pty_mod.linkSystemLibrary("c", .{});
    const pty_tests = b.addTest(.{ .root_module = pty_mod });
    const run_pty_tests = b.addRunArtifact(pty_tests);
    run_pty_tests.step.dependOn(&install_exe.step);

    const test_pty_step = b.step("test-pty", "Run PTY-driven REPL tests");
    test_pty_step.dependOn(&run_pty_tests.step);

    test_step.dependOn(&run_pty_tests.step);
}
