//! Slash Bytecode Constants
//!
//! Minimal module providing constants required by the generated parser.
//! Slash does not use bytecode compilation — the runtime walks
//! s-expressions directly. This exists solely to satisfy the
//! parser generator's imports.

pub const MAX_ARGS: usize = 32;
