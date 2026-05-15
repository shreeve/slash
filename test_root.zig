//! Test-only root. Zig 0.16's module system constrains `@import("path")`
//! to files within the module's directory tree, rooted at the
//! `root_source_file`'s parent. To let one test binary cover both the
//! in-tree module unit tests (under `src/`) and the cross-module
//! integration tests (under `tests/`), this root file lives at the
//! project root so the module path includes both subdirectories.
//!
//! Build wiring: `build.zig` uses this file as the `root_source_file`
//! for the main `test` step. PTY tests stay in their own binary
//! (`tests/pty_tests.zig`) because they spawn the just-built
//! `bin/slash` and don't share compilation with the in-process suite.

test {
    _ = @import("src/main.zig");
    _ = @import("tests/headless_tests.zig");
}
