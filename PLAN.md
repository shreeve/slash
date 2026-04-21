# Slash — Master Design & Implementation Plan

> **Slash parses commands into `Shapes`, lowers them into `Programs`, and runs them as `Jobs`.**

This document is the single source of truth for the Slash design.

---

## 0. TL;DR

Slash is a modern Unix shell written in Zig, built on a precise three-stage execution model:

```
Source  →  Shape  →  Program  →  Job
```

- `Shape` is the parsed structure — semantic nodes with source spans; trivia side-tabled.
- `Program` is the lowered executable semantics (immutable, no shell syntax left).
- `Job` is the runtime instance (process group, pids, state, result).

The grammar is driven by [nexus](https://github.com/shreeve/nexus). One grammar powers parsing, highlighting, completion, and formatting. `argv` is never flattened to a string. Pipelines are structured. Job control is first-class. There is no `set -e` magic, no implicit word-splitting, no hidden coercion.

Slash runs programs. It does not try to be a language.

---

## 1. Vision

Slash is **not**:

- another Bash clone
- a scripting language
- a data shell
- an AI shell

Slash **is**:

> A Unix shell with a precise, structured model of execution.

It optimizes for, in order:

1. Correctness
2. Composability
3. Observability
4. Clarity of execution

Everything else — syntax sugar, tooling, AI, UX polish — is downstream of those four.

---

## 2. Core Philosophy

### 2.1 Composition over computation

The shell runs programs. Complex logic belongs in real languages. Slash composes them.

### 2.2 Structure over strings

Traditional shells treat commands as strings and re-parse them at every layer. Slash treats them as structured objects end to end. This eliminates quoting bugs, word-splitting bugs, and argument-merging bugs by construction.

### 2.3 Explicit execution model

Every concept in Slash maps cleanly to one real thing:

- `Command` → one process
- `Pipeline` → connected processes
- `Program` → runnable structure
- `Job` → runtime instance

### 2.4 Grammar as source of truth

One grammar (`slash.grammar`, processed by `nexus`) drives:

- lexing
- parsing into `Shape`
- syntax highlighting
- completion context
- formatting
- error messages

No second parser. No ad-hoc regex tokenizers. No drift.

### 2.5 Surface may be rich; kernel must be small

Surface syntax may be expressive. **Lowering must shrink it into a small executable kernel.** This is the normalization contract that keeps `Program` testable and prevents syntax accidents from leaking into runtime.

---

## 3. Core Concepts

### 3.1 `Shape` — the parse layer

A `Shape` is the parsed structure. It is:

- purely structural
- span-bearing (every meaningful node carries a source `Span`)
- rich enough for highlighting, completion, and formatting — semantic nodes with editor-grade fidelity (per-node spans, per-word-part quoting preserved)
- **not executable**

It preserves pipelines, sequences, redirects, heredocs, quoting, and word fragments. It does not preserve redundant grouping (a parenthesized body becomes a `SubshellShape`, not a `ParensShape`), and it does not include job control, retries, timeouts, or any execution semantics.

Comments and pure whitespace live on a trivia side-table, not in the main tree, so traversal stays semantic.

### 3.2 `Word` — the semantic word unit

A `Word` is a lowered semantic word. Shell words are not strings — they are ordered lists of typed fragments: literal text, variable references, command substitutions, process substitutions, and glob patterns. Slash models this explicitly.

`Word` is what `Command.exe` and `Command.args` carry. Final `argv` is materialized at runtime during expansion. This is how we keep the "argv never flattened" invariant honestly.

### 3.3 `Command` — one process

```
Command { exe: Word, args: []Word, env, cwd, redirects, span }
```

One process invocation. `argv` is preserved as a list of `Word`s. Env bindings, cwd overrides, and redirects attach directly.

### 3.4 `Pipeline` — connected processes

```
Pipeline { stages: []*Program, pipefail: bool, span }
```

Ordered stages connected by pipes. Stages are runnable `Program` nodes (typically `Command` or `Subshell`). Pipelines are structured, not implicit text streams. **`pipefail` is on by default.**

### 3.5 `Sequence` — ordered programs with separators

```
Sequence { items: [{op_before: ?Op, program}] }   where Op ∈ {always, and_then, or_else}
```

Flat linear list with `;`, `&&`, `||` separators. Left-to-right, short-circuit for `&&` and `||`.

### 3.6 `Program` — the semantic layer

A `Program` is a runnable structure derived from a `Shape` through lowering. It contains:

- Structural forms: `Command`, `Pipeline`, `Sequence`, `Subshell`, `Parallel`, `Detached`
- Behavioral wrappers: `Retry`, `Timeout`, `Within`, `WithEnv`
- Control forms: `If`, `While`, `For`, `Define`

`Program` is **immutable** after lowering. No unparsed syntax, no grammar-dependent ambiguity, no pending heredoc resolution.

### 3.7 `Job` — the runtime layer

A `Job` is a running or completed `Program`. It holds the process group id, per-process state, aggregate state, aggregate result, timing, foreground/background flag, and a back-pointer to its `Program`. `Job` is **mutable** runtime state, owned by the job table.

### 3.8 `Redirect` — the I/O plumbing helper

Redirects attach to `Command`. Compound-command redirects (e.g. `(a; b) >out`, `while ...; done >log`) are normalized during lowering, typically by wrapping in a `Subshell` that carries the redirects. There is no free-floating redirect list on every node.

---

## 4. Architecture

### 4.1 Execution pipeline

```
source  →  Shape  →  Program  →  Job
         (parse)  (lower)     (run)
```

| Stage   | Layer         | Responsibility                                      | Lifetime     |
| ------- | ------------- | --------------------------------------------------- | ------------ |
| Source  | bytes         | Raw user input                                      | caller-owned |
| Shape   | syntactic     | Parsed structure, span-bearing                      | parse arena  |
| Program | semantic      | Lowered, immutable, executable                      | program arena|
| Job     | runtime       | Mutable runtime state, process group, result        | job arena    |

### 4.2 Module layout

```
slash/
├── slash.grammar          # nexus grammar, single source of truth
├── src/
│   ├── grammar/           # generated nexus tables + token kinds (do not edit)
│   ├── shape.zig          # parse(source) → Shape; Span, Source, trivia
│   ├── word.zig           # Word + expansion machinery
│   ├── program.zig        # Program types + lower(shape, ctx) → Program
│   ├── eval.zig           # run(program, session) → *Job; control forms
│   ├── exec.zig           # POSIX plumbing: fork/exec/pipe/dup/setpgid/tcsetpgrp
│   ├── job.zig            # Job, JobTable, lifecycle, reaping
│   ├── builtins.zig       # builtin registry + implementations
│   ├── session.zig        # REPL, readline, prompt, history, session state
│   ├── complete.zig       # completion engine (grammar + semantic context)
│   └── main.zig           # entry point, CLI flags
└── test/
```

### 4.3 Module contracts

Each module exposes a thin API (5–8 public functions max). Everything else is internal.

#### `slash.grammar` (mostly internal)
- **Owns**: nexus-generated tables, token kinds, parser entrypoints.
- **Exposes**: `TokenKind`, `lex(source, alloc) ![]Token`, `parseTokens(tokens, alloc) !ParseTree`.

#### `slash.shape`
- **Owns**: `Source`, `Span`, `Shape`, trivia, parse-to-shape transform.
- **Exposes**:
  - `parse(source: Source, alloc: Allocator, sink: ?diagnostics.Sink) !Parsed`
  - `format(shape, source, writer) !void`
  - `nodeAt(shape, offset) ?*const Shape`
  - `triviaAt(parsed, offset) []const Trivia`
  - `dump(shape, writer) !void`

#### `slash.word`
- **Owns**: semantic `Word`, expansion logic.
- **Exposes**:
  - `lowerWord(shape: WordShape, ctx) !Word`
  - `expandOne(word, session, alloc) ![]const u8`        (errors if result is not scalar)
  - `expandMany(words, session, alloc) ![][]const u8`    (preserves explicit lists)
  - `hasGlob(word) bool`

#### `slash.program`
- **Owns**: `Program`, `Command`, `Pipeline`, `Sequence`, `Redirect`, lowering passes.
- **Exposes**:
  - `lower(shape: *const Shape, ctx: *const LowerContext, sink: ?diagnostics.Sink) !*const Program`
  - `validate(program) !void`
  - `normalize(program, alloc) !*const Program`
  - `dump(program, writer) !void`
  - `span(program) Span`

#### `slash.eval`
- **Owns**: semantic execution, builtin dispatch, control-form evaluation, command resolution, expansion timing.
- **Exposes**:
  - `run(program: *const Program, session: *Session, sink: ?diagnostics.Sink) !*Job`
  - `wait(job, session) !Result`
  - `runForeground(program, session, sink) !Result`
  - `runDetached(program, session, sink) !*Job`
  - `resolveCommand(cmd, session) !ResolvedCommand`
  - `expandCommand(cmd, session, alloc) !ExpandedCommand`

#### `slash.exec`
- **Owns**: raw POSIX mechanics. No user-facing policy.
- **Exposes**:
  - `spawnProcess(req: SpawnRequest) !SpawnedProcess`
  - `makePipe() ![2]fd_t`
  - `applyRedirects(redirects) !void`
  - `setProcessGroup(pid, pgid) !void`
  - `giveTerminal(tty_fd, pgid) !void`
  - `waitOne(flags) !WaitEvent`
  - `signalGroup(pgid, sig) !void`

#### `slash.job`
- **Owns**: `Job`, `JobTable`, wait servicing, reaping, notifications. See §19 for the full wait/event model.
- **Exposes**:
  - `initTable(alloc) JobTable`
  - `create(table, program, foreground, detached) !*Job`
  - `addProcess(job, pid) !void`
  - `update(job, event) void`
  - `service(session: *Session, mode: WaitMode, target: ?*Job) !void`
  - `childEventPending(session: *const Session) bool`
  - `lookup(table, id) ?*Job`
  - `list(table) []const *Job`
- **Internal** (not part of the public contract): `reapReady(table)`, signal-handler flag plumbing.

#### `slash.builtins`
- **Owns**: builtin registry and implementations.
- **Exposes**:
  - `init(alloc) !BuiltinSet`
  - `lookup(set, name) ?Builtin`
  - `run(builtin, argv, session) !Result`
  - `names(set) []const []const u8`

#### `slash.session`
- **Owns**: shell session state, REPL, prompt, history, readline.
- **Exposes**:
  - `init(alloc, interactive) !Session`
  - `deinit(session) void`
  - `runSource(session, source) !Result`
  - `runProgram(session, program) !Result`
  - `repl(session) !void`
  - `notify(session) !void`

#### `slash.complete`
- **Owns**: completion engine.
- **Exposes**:
  - `complete(session, source, cursor, alloc) ![]Completion`
  - `contextAt(source, cursor, alloc) !CompletionContext`

---

## 5. Naming Rules (STRICT)

### Allowed top-level concepts

`Shape`, `Word`, `Command`, `Pipeline`, `Program`, `Sequence`, `Job`, `Redirect`.

Internal-but-named: `Span`, `Source`, `Signal`, `Result`, `Trivia`.

### Forbidden patterns

❌ `ExecPlan`, `InvocationSpec`, `ProcessNode`, `ASTNode`, `CmdPlan`, `IRNode`, `Stmt`, `Expr`, `Node`, `Opcode`, and any half-name.

### The rule

> Every public concept is a real, single English word, with semantic weight, that a Unix engineer already understands.

If a concept cannot be given such a name, it probably should not be a public concept.

---

## 6. Zig Type Model

These types are the authoritative reference for `slash.shape`, `slash.program`, and `slash.job`. They are writeable in Zig 0.16 as-is.

### 6.1 Shared

```zig
pub const Span = struct {
    start: u32,
    end: u32,
};

pub const Source = struct {
    name: []const u8,   // file path, "<repl>", "<arg>"
    text: []const u8,   // immutable UTF-8
};

pub const Trivia = struct {
    kind: enum { whitespace, comment },
    span: Span,
};

pub const Parsed = struct {
    source: Source,
    root: Shape,
    trivia: []const Trivia,
};
```

### 6.2 Shape

```zig
pub const Shape = union(enum) {
    word: WordShape,
    command: CommandShape,
    pipeline: PipelineShape,
    sequence: SequenceShape,
    subshell: SubshellShape,
    block: BlockShape,
    conditional: ConditionalShape,
    loop: LoopShape,
    definition: DefinitionShape,
    detached: DetachedShape,

    pub fn span(self: Shape) Span { /* dispatch */ }
};

pub const WordShape = struct {
    parts: []const WordPartShape,
    span: Span,
};

pub const WordPartShape = union(enum) {
    text: struct { bytes: []const u8, quoted: bool, span: Span },
    variable: struct { name: []const u8, quoted: bool, span: Span },
    command_subst: struct { body: *const Shape, quoted: bool, span: Span },
    process_subst_in: struct { body: *const Shape, span: Span },   // <(...)
    process_subst_out: struct { body: *const Shape, span: Span },  // >(...)
    glob: struct { pattern: []const u8, quoted: bool, span: Span },
};

pub const RedirectShape = struct {
    from_fd: ?u8, // null => default fd for op
    op: enum { read, write, append, clobber, read_write, dup_in, dup_out, heredoc, heredoc_tab },
    target: union(enum) {
        fd: u8,
        word: WordShape,
        heredoc: HeredocShape,
    },
    span: Span,
};

pub const HeredocShape = struct {
    delimiter: []const u8,
    quoted: bool,     // quoted delimiter disables interpolation
    trim_tabs: bool,  // <<-
    body_span: Span,
    span: Span,
};

pub const CommandShape = struct {
    exe: WordShape,
    args: []const WordShape,
    redirects: []const RedirectShape,
    span: Span,
};

pub const PipelineShape = struct {
    stages: []const Shape,
    pipefail: bool,
    span: Span,
};

pub const SequenceShape = struct {
    items: []const SequenceItemShape,
    span: Span,
};

pub const SequenceItemShape = struct {
    op_before: ?enum { always, and_then, or_else },
    program: Shape,
};

pub const SubshellShape = struct {
    body: *const Shape,
    redirects: []const RedirectShape,
    span: Span,
};

pub const BlockShape = struct {
    body: *const Shape,
    redirects: []const RedirectShape,
    span: Span,
};

pub const ConditionalShape = struct {
    kind: enum { @"if" },
    condition: *const Shape,
    then_body: *const Shape,
    else_body: ?*const Shape,
    redirects: []const RedirectShape,
    span: Span,
};

pub const LoopShape = struct {
    kind: enum { @"while", @"for" },
    condition: ?*const Shape,     // while
    binding: ?[]const u8,         // for
    items: []const WordShape,     // for
    body: *const Shape,
    redirects: []const RedirectShape,
    span: Span,
};

pub const DefinitionShape = struct {
    name: []const u8,
    body: *const Shape,
    span: Span,
};

pub const DetachedShape = struct {
    body: *const Shape,
    span: Span,
};
```

### 6.3 Word (semantic)

```zig
pub const Word = struct {
    parts: []const Part,
    span: Span,

    pub const Part = union(enum) {
        text: []const u8,                   // program-arena owned or interned
        variable: []const u8,
        command_subst: *const Program,
        process_subst_in: *const Program,
        process_subst_out: *const Program,
        glob: []const u8,
    };
};

pub const EnvBind = struct {
    name: []const u8,
    value: Word,
};
```

### 6.4 Redirect (semantic)

```zig
pub const Redirect = struct {
    from_fd: ?u8,
    target: Target,

    pub const Target = union(enum) {
        inherit,
        null,
        pipe,
        fd: u8,
        file: FileTarget,
        heredoc: Heredoc,
    };

    pub const FileTarget = struct {
        path: Word,
        mode: enum { read, write, append, clobber, read_write },
    };

    pub const Heredoc = struct {
        body: []const u8,   // cooked body in program arena
        expand: bool,       // false if quoted delimiter
        trim_tabs: bool,
    };
};
```

### 6.5 Program

```zig
pub const Command = struct {
    exe: Word,
    args: []const Word,
    env: []const EnvBind,
    cwd: ?Word,
    redirects: []const Redirect,
    span: Span,
};

pub const Pipeline = struct {
    stages: []const *const Program,
    pipefail: bool,
    span: Span,
};

pub const Sequence = struct {
    items: []const SequenceItem,
    span: Span,
};

pub const SequenceItem = struct {
    op_before: ?enum { always, and_then, or_else },
    program: *const Program,
};

pub const Program = union(enum) {
    command: Command,
    pipeline: Pipeline,
    sequence: Sequence,

    subshell: struct { body: *const Program, redirects: []const Redirect, span: Span },
    parallel: struct { items: []const *const Program, span: Span },
    detached: struct { body: *const Program, span: Span },

    retry:   struct { attempts: u32, body: *const Program, span: Span },
    timeout: struct { millis: u64, body: *const Program, span: Span },
    within:  struct { cwd: Word, body: *const Program, span: Span },
    with_env: struct { binds: []const EnvBind, body: *const Program, span: Span },

    @"if":    struct { condition: *const Program, then_body: *const Program, else_body: ?*const Program, redirects: []const Redirect, span: Span },
    @"while": struct { condition: *const Program, body: *const Program, redirects: []const Redirect, span: Span },
    @"for":   struct { binding: []const u8, items: []const Word, body: *const Program, redirects: []const Redirect, span: Span },

    define:  struct { name: []const u8, body: *const Program, span: Span },

    pub fn span(self: Program) Span { /* dispatch */ }
};
```

### 6.6 Job / Result / Signal

```zig
pub const Signal = enum(u8) {
    hup = 1, int = 2, quit = 3, ill = 4, trap = 5, abrt = 6, bus = 7, fpe = 8,
    kill = 9, usr1 = 10, segv = 11, usr2 = 12, pipe = 13, alrm = 14, term = 15,
    chld = 17, cont = 18, stop = 19, tstp = 20, ttin = 21, ttou = 22,
};

pub const Result = union(enum) {
    exited: u8,
    signaled: Signal,
};

pub const ProcessState = union(enum) {
    running,
    stopped: Signal,
    done: Result,
};

pub const Process = struct {
    pid: std.posix.pid_t,
    state: ProcessState,
};

pub const JobState = union(enum) {
    pending,
    running,
    stopped: Signal,
    done: Result,
};

pub const Job = struct {
    id: u32,
    pgid: std.posix.pid_t,
    processes: []Process,
    state: JobState,
    result: ?Result,
    started_at_ns: u64,
    ended_at_ns: ?u64,
    foreground: bool,
    detached: bool,
    command_text: ?[]const u8, // display only
    program: *const Program,
};
```

### 6.7 Lowering and running

```zig
pub const LowerContext = struct {
    alloc: Allocator,          // program arena allocator
    source: Source,
    features: Features,
};

pub const Features = struct {
    process_subst: bool = false,
    heredoc: bool = true,
    definitions: bool = false,
    conditionals: bool = false,
    loops: bool = false,
};

pub fn lower(shape: *const Shape, ctx: *const LowerContext) !*const Program;

pub const Session = struct {
    alloc: Allocator,
    vars: *VarStore,
    defs: *DefStore,
    jobs: *JobTable,
    builtins: *BuiltinSet,
    env: *EnvStore,
    cwd: []const u8,
    interactive: bool,
    controlling_tty_fd: ?std.posix.fd_t,
    default_pipefail: bool,
};

pub fn run(program: *const Program, session: *Session) !*Job;
```

### 6.8 Memory ownership

Three phase-owned arenas. `Program` is immutable; `Job` is mutable.

| Arena           | Owns                                                    | Lifetime                                 |
| --------------- | ------------------------------------------------------- | ---------------------------------------- |
| Parse arena     | `Shape` nodes, source-borrowed spans, trivia            | one parse/lower request                  |
| Program arena   | lowered `Program` tree, `Word` templates, interned strs | one run request, or lifetime of `cmd` def|
| Job arena       | pid arrays, expanded argv/env buffers, pipe arrays      | until job reaped and removed             |

String classes:

1. **Borrowed source slices** — `Shape` only; die with parse arena.
2. **Owned immutable strings** — `Program`; survive into session for `cmd` defs.
3. **Runtime buffers** — `Job`; final `argv`, `env`, after expansion.

User-defined `cmd` definitions are lowered into a dedicated session/definition arena. The parse arena cannot own anything retained by definitions. **A definition installed into `Session.defs` must be backed by session-owned or otherwise promoted immutable program storage; transient program arenas may not own retained definitions.**

---

## 7. Semantic Rules (commitments)

These are the rules Slash commits to. When in doubt, this list wins.

1. **Execution pipeline is fixed**: `source → Shape → Program → Job`. No execution directly from raw text.
2. **`Program` is immutable after lowering.** All runtime mutation lives in `Job`/`Session`.
3. **`argv` is never flattened to a shell string.** The final exec input is `exe: []const u8` plus `argv: []const []const u8`.
4. **`Command.exe` and `Command.args` are lowered `Word`s, not strings.** Runtime expansion materializes final argv.
5. **Expansion order per word** is: variable expansion → command substitution → process substitution → glob expansion → argv materialization. No further passes.
6. **There is no implicit whitespace word-splitting after expansion.** Expanded scalars stay one argument; expanded lists splice as multiple arguments.
7. **Variables are either scalar or list.** A scalar expands to one field; a list expands to N fields. No string re-splitting hack.
8. **Quoted variable expansion preserves field boundaries.** Quoting prevents globbing and preserves scalar/list elements as literal argv entries.
9. **Globbing applies only to unquoted literal/glob parts of a word.** If no match, the pattern is left literal (no silent deletion).
10. **PATH lookup happens only for external commands after `exe` is expanded.** Builtins and user-defined `cmd` resolve before PATH.
11. **`pipefail = on` is the default.** Pipeline result is the first non-zero/signaled stage, else zero. Phase 1 hardcodes the session default; no surface syntax toggles it yet.
12. **A `Sequence` evaluates left-to-right.** `;` always continues; `&&` continues only on zero exit; `||` continues only on non-zero or signaled result.
13. **A `Subshell` runs in a child shell process.** Changes to vars, cwd, defs, and shell state do not escape.
14. **A `Detached` program starts a background job immediately and returns success once launched.** Its eventual result lives in the job table, not in the caller's synchronous result. `Detached` applies to the whole lowered program node; when that node is a `Pipeline`, the entire pipeline becomes one background job with one process group and N pids. The `Job` is inserted into the job table *before* `run` returns success, so no spawned job is ever unreachable from the table.
15. **`if` exit status** is the selected branch's result, or zero if no branch runs.
16. **`while` exit status** is the last body result if the loop ran, else zero.
17. **`for` exit status** is the last body result if any iteration ran, else zero.
18. **There is no `set -e` or hidden abort-on-error mode.** Control flow is explicit via `&&`, `||`, `if`, and loop structure.
19. **Builtins that mutate shell state affect the shell only in shell context.** In a pipeline, subshell, or detached child, they affect only that child context. A shell-context builtin still executes as a `Job` for uniform reporting and sequencing, but may not spawn a child process: its `Job` has `processes.len = 0` and transitions directly to `.done(...)`. `Job` is not synonymous with "external process group". **Builtins never call `exec`.** A builtin's observable semantics (stdout, stderr, exit status, redirect handling, argv interpretation) must be identical regardless of execution context; only the *scope* of its state mutation differs between shell context and child context.
20. **Foreground jobs own the terminal; background jobs never do.** The shell regains terminal ownership after foreground exit or stop.
21. **Interactive shell ignores/handles job-control signals in the parent and restores defaults in children before exec.** Standard discipline; no signal surprises.
22. **All processes in a pipeline belong to one process group and one `Job`.** Job control operates on groups, not individual pids.
23. **Compound-command redirects are normalized during lowering.** They are represented either directly on `Program.subshell` when explicit in syntax (e.g. `(a ; b) >out`), or by lowering other redirected compound forms (e.g. `while ...; done >log`, `if ... fi 2>err`) through an equivalent synthesized `Subshell`. Parent shell fds are never mutated except for tightly-scoped builtin execution in shell context.
24. **Heredoc delimiter quoting controls interpolation.** Quoted delimiter ⇒ literal body. Unquoted delimiter ⇒ variable/command substitution allowed. `<<-` trims leading tabs only.
25. **Process substitution resources are job-owned.** Pipes and `/dev/fd/N` bindings are cleaned up on success, failure, stop, or interruption.
26. **`cmd` definitions are session-scoped unless created inside a subshell**, where they die with the subshell.
27. **AI may produce source or a `Program`, but Slash never auto-runs it.** The user sees the structured plan and confirms explicitly.
28. **Surface syntax may be rich; the Program kernel must stay small.** Every new surface form must lower to existing `Program` variants, or justify adding a new one. The `Program` kernel may expose semantic forms (e.g. `Retry`, `Timeout`, `Parallel`, `Within`, `WithEnv`) before any surface syntax exists for them; they are addressable from AI-produced plans and internal rewrites even without grammar support.
29. **Command substitution yields a scalar string by default**, with one trailing newline run removed and no whitespace splitting. `echo $(printf 'a\nb\n')` yields one argument `"a\nb"`, not two. If a list-valued capture is ever added, it is a distinct surface form — never overloaded onto `$(...)`.
30. **Expansion happens exactly once per word during evaluation. No re-expansion ever occurs.** A materialized argv element is never re-scanned for variables, command substitution, process substitution, or globs. This is what prevents Slash from becoming "a little bash inside a bash": the `Word → argv` boundary is a one-way gate.
31. **Lowering + normalization is the compiler pass of the shell.** After `program.lower` followed by `program.normalize`, a `Program` satisfies: no syntactic sugar remains; every redirect is attached to a concrete `Command` or `Subshell`; every compound form that bears a redirect has been made explicit (e.g. redirected `while` is wrapped in a `Subshell`); no ambiguous execution structure remains. `eval.run` is entitled to assume all of this; violating it is a bug in the lowerer, not a runtime condition.
32. **Jobs transition monotonically.** The `Job.state` graph is `pending → running → {stopped ↔ running}* → done`. Once a `Job` is `.done`, its `state` and `result` never change. Once a `Job` has been reaped and removed from the job table, it must not be mutated or referenced. There is no "zombie-after-reap" state and no partial reap.

---

## 8. End-to-End Example

Input:

```sh
grep -n zig **/*.md | head -20 > hits.txt || echo no matches
```

Assume `pipefail = on` and `**/*.md` parses as a word with a glob part.

### 8.1 Shape (abbreviated)

```
sequence span=0..58
  items = [
    { op_before = null,
      program = pipeline span=0..42 {
        pipefail = true,
        stages = [
          command span=0..19 {
            exe  = word("grep"),
            args = [ word("-n"), word("zig"), word(glob("**/*.md")) ],
            redirects = [],
          },
          command span=22..42 {
            exe  = word("head"),
            args = [ word("-20") ],
            redirects = [
              write from_fd=null target=word("hits.txt"),
            ],
          },
        ],
      },
    },
    { op_before = .or_else,
      program = command span=46..58 {
        exe  = word("echo"),
        args = [ word("no"), word("matches") ],
      },
    },
  ]
```

### 8.2 Program (after lowering)

```
sequence {
  items = [
    { op_before = null,
      program = &pipeline {
        pipefail = true,
        stages = [
          &command {
            exe = Word{text="grep"},
            args = [Word{text="-n"}, Word{text="zig"}, Word{glob="**/*.md"}],
            env  = [], cwd = null, redirects = [],
          },
          &command {
            exe = Word{text="head"},
            args = [Word{text="-20"}],
            env  = [], cwd = null,
            redirects = [
              Redirect{ from_fd = null,
                        target = .file{ .path = Word{text="hits.txt"},
                                        .mode = .write } },
            ],
          },
        ],
      },
    },
    { op_before = .or_else,
      program = &command {
        exe = Word{text="echo"},
        args = [Word{text="no"}, Word{text="matches"}],
        env = [], cwd = null, redirects = [],
      },
    },
  ],
}
```

### 8.3 Runtime (Job)

Before exec, `Word{glob="**/*.md"}` expands against cwd to a list of matching paths. No whitespace splitting. `grep`'s final argv becomes, e.g.:

```
["grep", "-n", "zig", "README.md", "docs/plan.md", ...]
```

On success:

```
Job{
  id = 7,
  pgid = 41231,
  processes = [
    { pid = 41231, state = .done(.exited(0)) }, // grep
    { pid = 41232, state = .done(.exited(0)) }, // head
  ],
  state = .done(.exited(0)),
  result = .exited(0),
  foreground = true,
  detached = false,
}
```

Sequence semantics: first item = 0, `|| echo ...` skipped, overall result = 0.

If `grep` finds nothing and exits 1 (with pipefail on), the pipeline result is 1, the `or_else` branch runs, `echo` exits 0, overall result = 0.

---

## 9. Phased Implementation Plan

Each phase ends with the headless harness passing a curated golden-test suite. No phase skips.

### Phase 1 — Headless core (prove the thesis)

**Goal**: `source → Shape → Program → Job`, end to end, no REPL.

Deliverables:

- `slash.shape.parse` producing `Shape` with spans and trivia.
- `slash.program.lower` producing immutable `Program`.
- `slash.eval.run` executing `Program` via `slash.exec` and `slash.job`.
- Surface covered (see §10):
  - simple commands, bare/quoted words
  - `|`, `||`, `&&`, `;`, `(...)`, trailing `&`
  - `<`, `>`, `>>`, numbered fds, `n>&m`
- `slash-run '<source>'` CLI harness for tests.
- Golden tests for parse, lower, and run.

Non-goals: no REPL, no prompt, no completion, no variables, no control forms, no heredocs, no process substitution, no `cmd` defs.

### Phase 2 — Correct process model and job control

Make it a real shell runtime.

- Process groups, `setpgid` done in both parent and child.
- Terminal handoff via `tcsetpgrp`; shell ignores `SIGTTOU`/`SIGTTIN`/`SIGTSTP`; children restore defaults before exec.
- Foreground/background transitions, `jobs`/`fg`/`bg`/`wait` builtins.
- Stopped/continued notifications at prompt boundaries.
- Robust reaping; one pipeline = one job = one pgid.
- PTY-based integration tests for Ctrl-C, Ctrl-Z, orphan pgroups, pipelines as single jobs.

### Phase 3 — Expansion and control semantics

Enough shell structure to be a complete interactive shell.

- Variables (scalar + list), env overlays, `WithEnv` wrappers.
- User-defined `cmd` (`Define`), session-scoped, subshell-isolated.
- `if`, `while`, `for`.
- Command substitution, process substitution with full cleanup.
- Heredocs with documented dedent and interpolation rules.
- Globbing as a filesystem step on unquoted literal/glob parts.
- Quoting matrix tests; heredoc interpolation tests; `cmd` scope/lifetime tests.

### Phase 4 — One-grammar UX

Exploit nexus across tooling.

- Syntax highlighting driven by the grammar + Shape spans.
- Completion driven by parse context + semantic hooks (first-word vs. variable vs. file).
- Formatter / pretty-printer over `Shape`.
- Structured diagnostics tied to `Span`.
- **Rule**: no second parser anywhere. No regex-based completion hacks.

### Phase 5 — Interactive session

Polished interactive shell.

- Line editor, prompt engine, history.
- Session state persistence, config loading.
- Key bindings.
- Interactive job notifications.

### Phase 6 — AI as Program producer

Keep AI narrow and safe.

- AI returns source or a `Program`.
- User sees the structured plan (commands, pipelines, redirects, cwd/env effects).
- No direct "run arbitrary AI string" path. Ever.

---

## 10. Phase 1 Grammar (minimum viable)

Phase 1 grammar is deliberately tiny. Everything else grows phase by phase.

### Lexical
- bare words
- single-quoted strings
- double-quoted strings
- escapes inside double quotes and unquoted words
- comments `#...`
- operators: `|`, `||`, `;`, `&&`, `&`, `(`, `)`, `<`, `>`, `>>`, `n>`, `n<`, `n>&m`, `n<&m`, `2>&1`-style dups

### Syntactic
1. Simple command: `WORD { WORD | REDIRECT }*`
2. Redirects: `< file`, `> file`, `>> file`, `n> file`, `n< file`, `n>&m`, `n<&m`
3. Pipeline: `command ('|' command)+`
4. Sequence: `program (';' | '&&' | '||') program ...`
5. Subshell: `'(' sequence ')'`
6. Detached: `program '&'`

### Explicitly excluded from Phase 1
heredocs, process substitution, variables, blocks `{ ... }` (`BlockShape` exists in the type model but `shape.parse` in Phase 1 will never produce one), `if`/`while`/`for`, `cmd` defs, env-prefix assignments, `retry`/`timeout`/`within`/`with_env`/`parallel` surface syntax.

### Lowering constraints for Phase 1
- Every pipeline stage lowers to `Program.command` or `Program.subshell`.
- Compound redirects on subshells allowed.
- `Detached` wraps a complete program node; when wrapping a `Pipeline` it yields one background job with one pgid and N pids.

### First commit after this PLAN
Build the headless `slash-run` path end to end — `Shape → Program → Job` — including the zero-child `Job` code path for shell-context builtins. This is the single place the architecture can still collapse into special-case mush; forcing it in commit one prevents that.

---

## 11. Hard Problems and Anti-Patterns

These are the traps every real shell falls into. Slash must solve them explicitly.

### Must-get-right

1. **Expansion timing.** Decide exactly when variables, command subst, process subst, globbing, and PATH lookup happen. They happen in that order, once, per §7.
2. **Compound-command redirects.** Don't fake them by mutating parent shell fds. Normalize via `Subshell` during lowering.
3. **Process substitution cleanup.** `/dev/fd/N` bindings and pipes are job-owned; cleaned up on every termination path.
4. **Terminal control.** Shell in its own pgrp; foreground job owns the tty; shell reclaims on exit/stop; `SIGTTOU`/`SIGTTIN` ignored in parent; `setpgid` called in both parent and child to close the fork race.
5. **Builtins in pipelines.** A stateful builtin (e.g. `cd`, `export`) runs in shell context only when it is a lone simple command in the foreground. In a pipeline, subshell, or detached context, it runs in a child and its state change dies there. This is documented, not accidental.
6. **User-defined `cmd` scope.** Session-scoped by default. Subshell definitions die with the subshell. Env overlays are dynamic for child execution, never shell-global unless an explicit builtin says so.

### Anti-patterns to avoid

- `set -e`-style invisible control flow.
- Untyped word splitting after expansion.
- Text-only parser model.
- Divergent grammars for parser and completion.
- Builtins mutating shell state from pipeline children unexpectedly.
- Implicit subshell creation surprises.
- Redirection side effects on the parent shell because fd restore was sloppy.
- Ambiguous exit-status rules for pipelines and lists.
- Turning the shell into a general-purpose language runtime.
- "Structured pipeline" marketing while still flattening `argv` internally.
- Multiple ASTs that drift because every feature wants "just one more".

---

## 12. Out of Scope

Slash runs programs. It does not try to be a language. These exclusions are intentional and load-bearing; features that look tempting but sit on the wrong side of this line do not belong in Slash.

### Not part of Slash

- Inline arithmetic as a first-class feature (e.g. `= 2 ** 10`, `x = 10 + 4`).
- `= expr` bare-print evaluation form.
- `??` as a general-expression default fallback. A narrow `${var ?? default}` form inside quoted strings is acceptable; general expression-level `??` is not.
- Expression-level comparisons and math operators — these are not shell operators.
- Pattern matching as a value-level language construct. If pattern dispatch appears, it dispatches to `Program`s only, not values.
- "Language-y" precedence and associativity in the grammar.

### In scope — as program control, not computation

- Variables (scalar and list).
- `if` / `unless` / `else`, `while`, `until`, `for`.
- `cmd` — user-defined commands, session-scoped, subshell-isolated (see §7 Rule 26).
- Heredocs with triple-delimiter form (`'''`, `"""`, ```` ``` ````) and defined dedent policy.
- Process substitution, subshells, background jobs, redirects, pipes, `and` / `or` / `xor` as contextual keywords.
- Grammar-driven parsing, argv-safe execution, one-grammar UX.
- Flat-file history, prompt escapes, directory MRU (e.g. a `j` builtin).

### Program-level helpers

- `run $list` is a `Command` whose `exe` and `args` come from a list-valued variable.
- `ok` is a wrapper that sets stdout and stderr to `Redirect.Target.null` and ignores non-zero exit.
- Both exist as `Program`-level mechanisms, not as parser-level special cases.

---

## 13. AI Integration

AI is optional and strictly bounded.

- AI takes a natural-language prompt.
- AI returns either (a) Slash source text, or (b) a serialized `Program`.
- Slash parses/lowers the source into a `Program`, or deserializes the `Program`.
- Slash shows the structured plan: each `Command`, `Pipeline`, `Redirect`, `Detached`, `WithEnv`, `Within`, etc.
- The user confirms or edits. Only then does it run.
- AI never executes. AI never touches `slash.exec`. AI never touches the `Job` table.

```
ai "deploy nginx to staging"
→ Program { Sequence [
    WithEnv { ENV=staging },
    Command { exe=ansible-playbook, args=[deploy.yml] },
    If { Command {exe=curl, args=[-f, https://staging/health]},
         then = Command { exe=echo, args=[ok] },
         else = Command { exe=echo, args=[rollback] } },
  ] }
→ [y/N/edit] ?
```

---

## 14. Guiding Principle

When designing any feature, ask:

- Does this improve **`Command`** clarity?
- Does this improve **`Pipeline`** correctness?
- Does this improve **`Program`** composability?
- Does this improve **`Job`** control?

If not:

> **Do not build it.**

---

## 15. Open Questions (deferred, not forgotten)

These are not decisions yet. They will be revisited at the phase where they matter.

- **Incremental parsing** for the editor. Not needed for Phase 1; may be required by Phase 4.
- **Structured command output** (optional JSON frame wrappers around certain commands). Interesting but easily slides into "data shell". Deferred until after Phase 6, if ever.
- **Job persistence** across shell restarts. Almost certainly not; document and move on.
- **Remote execution** as a first-class Program wrapper (`On { host, program }`). Tempting, high blast radius; deferred.
- **Typed Redirect targets** beyond file/fd/pipe (e.g. memory, socket). Likely yes for `pipe`/`null`; no for exotic targets until demand exists.

---

## 16. Diagnostics

Slash uses one diagnostic model end to end: parse, lower, eval, exec, and job all emit the same `Diagnostic` shape. Diagnostics are data, not formatted strings. Every layer may attach a stable code, a primary span, optional notes, and optional related locations. Parse may batch; lower does not; runtime records failures on the `Job` and may also emit a diagnostic for the user. A failed request returns diagnostics and no partial semantic product unless the phase explicitly allows safe recovery.

### 16.1 Types

```zig
const std = @import("std");

pub const Severity = enum {
    note,
    warning,
    @"error",
    fatal,
};

pub const Phase = enum {
    shape,   // lex + parse
    lower,
    eval,
    exec,
    job,
};

pub const Related = struct {
    message: []const u8,
    source: Source,
    span: Span,
};

pub const Diagnostic = struct {
    phase: Phase,
    severity: Severity,
    code: ?[]const u8,      // "SH0001", "LW0004", "EV0012", "EX0003", "JB0002"
    message: []const u8,
    source: Source,
    span: ?Span,
    notes: []const []const u8,
    related: []const Related,
};

pub const Sink = struct {
    ctx: *anyopaque,
    emitFn: *const fn (ctx: *anyopaque, diag: Diagnostic) anyerror!void,

    pub fn emit(self: Sink, diag: Diagnostic) !void {
        return self.emitFn(self.ctx, diag);
    }
};

pub const ListSink = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Diagnostic) = .{},

    pub fn sink(self: *ListSink) Sink {
        return .{
            .ctx = self,
            .emitFn = struct {
                fn call(ctx: *anyopaque, diag: Diagnostic) !void {
                    const s: *ListSink = @ptrCast(@alignCast(ctx));
                    try s.items.append(s.alloc, diag);
                }
            }.call,
        };
    }
};

pub const RenderStyle = enum {
    single_line,
    snippet,
};
```

### 16.2 Public API

```zig
pub fn make(
    phase: Phase,
    severity: Severity,
    code: ?[]const u8,
    message: []const u8,
    source: Source,
    span: ?Span,
) Diagnostic;

pub fn emit(sink: ?Sink, diag: Diagnostic) !void;

pub fn render(diag: Diagnostic, style: RenderStyle, writer: anytype) !void;

pub fn hasErrors(diags: []const Diagnostic) bool;
```

### 16.3 Error-code convention

- `SHxxxx` — lex/parse/shape
- `LWxxxx` — lower/program
- `EVxxxx` — eval/expansion/builtin resolution
- `EXxxxx` — fork/exec/redirect/process setup
- `JBxxxx` — job table/wait/job-control bookkeeping

Rules:

- Codes are optional but stable once published.
- Codes identify the semantic failure class, not the exact English wording.
- Tests may assert on code and span; they should not depend on prose beyond snapshot tests.
- Reserve broad ranges early; do not renumber.

Examples:

- `SH0001` unexpected token
- `SH0007` unterminated quote
- `LW0004` redirect not valid on this form
- `EV0001` command name expanded to zero or empty fields
- `EV0002` command name expanded to multiple fields
- `EX0003` exec failed: permission denied
- `JB0002` job lost terminal ownership unexpectedly

### 16.4 Error channels

- Every top-level request takes **one optional sink**.
- Parse may emit multiple diagnostics into the sink before returning.
- Lower emits at most one `error` diagnostic, then fails; warnings are allowed before the failure.
- Eval/exec/job may emit diagnostics into the sink **and** return a typed failure/result for the running `Job`.
- No callback chains, no per-module sink types, no global logger.
- **Diagnostic emission must not allocate unboundedly on error paths.** Parsers under fuzzing and lowerers under pathological input must respect a diagnostic budget (count and total message bytes) and stop emitting, or emit a single fatal "diagnostic budget exhausted" marker, rather than grow an `ArrayList` without bound. This aligns with parser crash-freedom (§17 layer 6) and prevents a malformed input from OOM-ing the shell.

Recommended signatures:

- `shape.parse(source, alloc, sink) !Parsed`
- `program.lower(shape, ctx, sink) !*const Program`
- `eval.run(program, session, sink) !*Job`

### 16.5 Phase policy

| Phase | Recovery | Partial product | Diagnostic policy | Caller outcome |
|---|---|---|---|---|
| Parse | Yes, if grammar recovery is safe and bounded | `Parsed` only if recovery produced a coherent tree | Batch multiple diagnostics | Return `Parsed` or fail |
| Lower | No | Never | Emit first hard error, then stop | Fail, no `Program` |
| Eval | N/A | `Job` exists if launch reached runtime | Emit runtime diagnostics as needed | `Job` carries failure/result |
| Exec | N/A | `Job` may be partial if some children spawned | Emit diagnostic, mark job failed, clean up | Shell keeps running |
| Job | N/A | `Job` always remains inspectable | Emit diagnostic only for bookkeeping/control failures | Shell keeps running |

### 16.6 Human formatting

Single-line form:

```text
error[EV0002]: command name expanded to multiple fields at script.sl:12:5
```

Snippet form:

```text
error[EV0002]: command name expanded to multiple fields
  --> script.sl:12:5
   |
12 | $cmd arg1 arg2
   | ^^^^ expands to 2 fields; command names must expand to exactly one non-empty field
   |
   = note: use an explicit list-aware dispatch form if multiple commands are intended
```

Rules:

- Always show severity, code if present, and source location.
- Multi-line format uses a single primary span and zero or more related spans.
- Notes are bullet-style `= note:` lines.
- Do not print stack traces or syscall noise in user diagnostics; that belongs in debug logs.

### 16.7 Test consumption

Tests consume diagnostics as machine-readable data:

- assert count
- assert `phase`, `severity`, `code`
- assert `span` byte offsets
- snapshot rendered output only where formatting itself is under test

Recommended artifacts:

- one `.diag` file containing rendered snippet output for humans
- one structured assertion in Zig for code/span stability

---

## 17. Testing Strategy

Slash testing is layered. Each layer exists for a different failure mode: parser shape drift, lowering drift, runtime regressions, terminal/job-control bugs, standards alignment, and parser crash resistance. Golden files are explicit, stable artifacts. Updating them is always opt-in and never happens during ordinary `zig build test`.

### 17.1 Tree layout

```text
tests/
  shape/
    basic/
      pipeline.shape
      sequence.shape
      redirects.shape
      subshell.shape
    shape_tests.zig

  program/
    basic/
      pipeline.program
      sequence.program
      redirects.program
      subshell.program
    program_tests.zig

  exec/
    headless/
      smoke.zig
      redirects.zig
      pipelines.zig
      detached.zig
      fixtures/
        hello.txt
    pty/
      job_control.zig
      signals.zig
      fg_bg.zig
      orphan_pgrp.zig
      pipelines_as_jobs.zig

  diff/
    bash_dash.zig
    cases/
      simple.txt
      pipelines.txt
      redirects.txt

  fuzz/
    parser_fuzz.zig
```

If per-module colocation is preferred, keep the same logical split under `src/*/tests`; the important part is preserving these six layers.

### 17.2 Invocation

Expose named build steps; do not hide everything behind one undifferentiated `test`.

```sh
zig build test-shape
zig build test-program
zig build test-headless
zig build test-pty
zig build test-diff
zig build test-fuzz
zig build test         # aggregate stable layers for the current phase
```

Aggregate per phase:

- Phase 1: `shape + program + headless + fuzz`
- Phase 2: add `pty`
- Phase 3+: add `diff`

### 17.3 Snapshot update protocol

Golden files update only when explicitly requested:

```sh
SLASH_UPDATE_GOLDENS=1 zig build test-shape
SLASH_UPDATE_GOLDENS=1 zig build test-program
```

Rules:

- No implicit snapshot rewrite on mismatch.
- Test failure prints the path to the actual rendered output and the golden path.
- Updating goldens must rewrite only the expected file for the failing case.
- CI never sets `SLASH_UPDATE_GOLDENS`.

### 17.4 Layer 1 — Parse snapshot tests

- **Purpose**: assert `source → Shape dump` stability.
- **Artifacts**: input inline in Zig test or adjacent `.sl`; expected dump in `.shape`.
- **Format**: deterministic tree dump, one node per line, stable field order, spans included or omitted by test mode but not mixed.
- **Invocation**: `zig build test-shape`.
- **Acceptance**: required from Phase 1 onward.

### 17.5 Layer 2 — Lower snapshot tests

- **Purpose**: assert `source → Program dump` stability; catch normalization mistakes and semantic drift.
- **Artifacts**: expected dump in `.program`.
- **Invocation**: `zig build test-program`.
- **Acceptance**: required from Phase 1 onward.

### 17.6 Layer 3 — Headless execution tests

- **Purpose**: assert observable behavior without tty concerns.
- **Harness**: run `source → Shape → Program → Job`; capture stdout, stderr, exit status; no prompt, no line editor, no terminal handoff.
- **Test shape**:

```zig
const Expect = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
};
```

- **Invocation**: `zig build test-headless`.
- **Acceptance**: required from Phase 1 onward.

### 17.7 Layer 4 — PTY integration tests

- **Purpose**: exercise real job control under a pseudo-terminal.
- **Coverage minimum**: Ctrl-C to foreground job; Ctrl-Z stop and `fg` resume; background launch does not steal terminal; pipelines are one job / one pgrp; stopped/continued notifications; orphan process group edge cases.
- **Invocation**: `zig build test-pty`.
- **Acceptance**: required from Phase 2 onward.

### 17.8 Layer 5 — Differential tests

- **Purpose**: compare Slash against `bash`/`dash` where semantics intentionally align.
- **Rules**: only include cases where Slash has explicitly chosen compatibility; exclude known semantic deltas (no whitespace splitting, pipefail default on, typed variables/lists, etc.); compare only observable behavior.
- **Invocation**: `zig build test-diff`.
- **Acceptance**: advisory in Phase 2, required for aligned surface areas in Phase 3+.

### 17.9 Layer 6 — Fuzzing

- **Purpose**: parser must be crash-free on arbitrary bytes — no panics, no UB, no infinite loops, no unbounded allocation explosion within configured limits.
- **Scope**: parser only in Phase 1–2; later may add lower fuzzing over valid `Shape`.
- **Invocation**: `zig build test-fuzz`.
- **Acceptance**: required from Phase 1 onward for parser crash-freedom.

### 17.10 Per-phase acceptance matrix

| Phase | Shape snapshots | Program snapshots | Headless exec | PTY | Differential | Fuzz |
|---|---|---|---|---|---|---|
| 1 | Required | Required | Required | N/A | N/A | Required |
| 2 | Required | Required | Required | Required | Advisory | Required |
| 3 | Required | Required | Required | Required | Required for aligned semantics | Required |
| 4 | Required | Required | Required | Required | Required | Required |
| 5 | Required | Required | Required | Required | Required | Required |
| 6 | Required | Required | Required | Required | Required | Required |

### 17.11 Rules

- Every bug fix that changes parse or lower output adds or updates a snapshot.
- Every runtime semantic bug gets a headless or PTY regression first, then the fix.
- PTY tests are not optional "later polish"; they are the only credible proof of job control.
- Differential tests are a guardrail, not a spec override. When Slash intentionally differs, Slash wins and the diff case does not exist.
- **Snapshot outputs must be deterministic across platforms.** Line endings are `\n` only; field order is fixed; hash-map iteration is replaced with sorted iteration in dump paths; absolute paths, timestamps, pids, and allocator addresses are either excluded from dumps or canonicalized. A snapshot that passes on macOS must pass byte-for-byte on Linux and vice versa.

---

## 18. Signal Model

Slash follows standard shell discipline: the parent shell stays alive and in control; foreground jobs receive terminal-generated signals; children restore default dispositions before `exec`. Signal policy is explicit and table-driven. Phase 1 does not require every signal-dependent interactive path, but the model is fixed from the start.

### 19.1 Disposition table

| Signal | Interactive shell | Non-interactive shell | Child before exec |
|---|---|---|---|
| `SIGINT`  | Ignore while idle/readline; forward effect comes from terminal to fg pgrp | Default shell behavior (typically terminate current script unless handled around waits) | Default |
| `SIGQUIT` | Ignore | Default | Default |
| `SIGTERM` | Catch or default-clean-exit; never permanently ignore | Default | Default |
| `SIGHUP`  | Catch for session teardown; propagate to running jobs on shell exit | Default | Default |
| `SIGTSTP` | Ignore | Default | Default |
| `SIGTTIN` | Ignore | Default | Default |
| `SIGTTOU` | Ignore | Default | Default |
| `SIGCHLD` | Minimal handler sets child-event flag only | Minimal handler sets child-event flag only | Default |
| `SIGPIPE` | Ignore in shell process | Ignore in shell process | Default |
| `SIGWINCH`| Catch/flag for prompt redraw and window-size refresh | Ignore or default; no prompt redraw needed | Default |

Notes on the table:

- "Ignore" means installed disposition `SIG_IGN`.
- "Catch" means a minimal async-signal-safe handler that sets a flag or writes to a self-pipe; Phase 1–2 only requires the flag path.
- Children must not inherit shell-specific ignores/catches across `exec`.

### 19.2 Rules

- The child restores default dispositions **after fork and before any exec or builtin-in-child body runs**. This includes `INT`, `QUIT`, `TSTP`, `TTIN`, `TTOU`, `PIPE`, `CHLD`, and `WINCH`.
- `SIGPIPE` is ignored in the shell and defaulted in children. Reason: the shell itself must not die because it writes to a closed pipe while printing or managing jobs; pipeline stages still get normal POSIX pipe semantics.
- `SIGWINCH` updates shell-side terminal geometry and prompt state; the shell does **not** manually forward it to the foreground job. The controlling terminal already delivers the relevant tty state to foreground applications, and duplicating delivery is a footgun.
- Builtins that run in shell context inherit shell dispositions; builtins that run in child context follow the child-before-exec column. Phase 1 should avoid builtins that fork for side effects.
- The `SIGCHLD` handler does no reaping and no allocation. It sets a `child_event_pending` flag consumed by the wait/event model (§19) at safe points.
- When the shell exits interactively due to `exit`, EOF, or fatal setup failure, it sends `SIGHUP` to running background jobs by policy, unless the implementation later supports a `disown` concept.

---

## 19. Wait / Event Model

Phase 1–2 use a portable wait model: a minimal `SIGCHLD` handler sets a flag, and the shell reaps children with `waitpid` at defined safe points. No `signalfd`, no `kqueue`, no background event thread. The abstraction boundary is small so Linux `signalfd` or BSD/macOS `kqueue` can replace the backend later without changing callers.

### 19.1 Decision

- **Foreground wait**: blocking `waitpid` loop on the foreground job's process group with `WUNTRACED`, handling `EINTR` and state transitions until the job is done or stopped.
- **Background reap / notifications**: `waitpid(-1, WNOHANG | WUNTRACED | WCONTINUED)` at safe points, only if `child_event_pending` is set or the caller explicitly polls.
- **No implicit wait on background jobs.** The shell never blocks on a background job except via an explicit `wait` builtin invocation (or its internal equivalent). Background jobs influence the shell only through reaping at safe points and through explicit user action.
- **Abstraction**: callers ask the job layer to poll or wait; they never call `waitpid` directly.

### 19.2 Abstraction surface

```zig
pub const WaitMode = enum {
    poll,       // non-blocking drain
    foreground, // blocking wait for one job/pgrp until done or stopped
};

pub fn service(session: *Session, mode: WaitMode, target: ?*Job) !void;

pub fn childEventPending(session: *const Session) bool;
```

Rules:

- `service(..., .poll, null)` drains pending child state changes without blocking.
- `service(..., .foreground, job)` blocks until `job.state` becomes `.done` or `.stopped`.
- A future `signalfd`/`kqueue` backend only changes the implementation behind `service`.

### 19.3 Safe points

A **safe point** is any place where Slash is not executing async-signal-unsafe code, is not holding mutable parser/lowerer internal invariants mid-update, and can reap children, update jobs, and emit notifications without corrupting user-visible state.

Concrete safe points:

- **Interactive**: before showing the prompt, after a foreground job returns/stops, after a builtin completes, and after readline yields control back to the shell.
- **Non-interactive**: before starting each top-level `Sequence` item, after each top-level item completes, and immediately after any spawn failure/partial launch cleanup.
- **Headless harness**: before run, after run, and between sequence items.

### 19.4 EINTR rule

- Any blocking `waitpid` loop retries on `EINTR`.
- If `waitpid` returns because an unrelated signal interrupted the call, the shell first services pending flags, updates job state, then resumes waiting unless the target foreground job is now done or stopped.
- `EINTR` is never surfaced as a user-visible error. It is transport noise, not shell semantics.

### 19.5 Stopped / continued notifications

- Interactive shell prints job notifications only at safe points, never from a signal handler and never by interleaving arbitrary output into readline state.
- A stop or continue event updates the `Job` immediately in the table; user-facing notification may be deferred until the next safe point.
- Foreground stop returns control to the shell, restores terminal ownership, and leaves the job in `.stopped`.
- Background continue notification is advisory; it does not steal focus or terminal control.

### 19.6 Readline hazards

Signals and child notifications during line editing can corrupt the line buffer if handled naively. Hazards:

- writing job messages in the middle of the current input line
- redrawing the prompt before terminal ownership is restored
- losing partially typed input after `SIGINT`
- stale terminal width after `SIGWINCH`
- racing reaped-job output with readline's own repaint logic

Rules:

- no direct diagnostic or job-status printing from signal handlers
- all notifications are deferred to safe points the line editor can tolerate
- prompt redraw occurs only after terminal ownership and tty modes are known-good

### 19.7 Non-interactive polling rule

Non-interactive mode has no prompt boundary, so polling is tied to evaluation boundaries:

- poll before spawning each top-level `Sequence` item
- poll after each top-level item completes
- poll after any detached/background launch
- do **not** poll in the middle of a foreground blocking wait except through the wait loop itself

This is enough to keep background job tables current during scripts without turning every command dispatch into an event framework.

---

## 20. Exit Status Model

Internally, Slash uses typed results. Externally, it speaks the conventional POSIX byte. Conversion happens only at process boundaries: shell process exit, `$?` exposure, and any compatibility surface that explicitly requires a numeric status. No internal code should traffic in raw `u8` statuses except at these edges.

### 20.1 Encoding rule

- `Result.exited(n)` encodes to `n & 0xFF`
- `Result.signaled(sig)` encodes to `128 + signal_number(sig)`
- Internal `Result` stays typed until conversion is required

```zig
pub fn toStatusByte(result: Result) u8 {
    return switch (result) {
        .exited => |n| n,
        .signaled => |sig| 128 + @intFromEnum(sig),
    };
}
```

### 20.2 Conventional special values

Slash follows the common shell convention by default:

- `126` — command found but not executable / permission denied
- `127` — command not found, command name expanded to zero fields, command name expanded to multiple fields, or command name expanded to empty
- `128` — invalid signal number for user-facing `kill`-style surfaces
- `130` — terminated by `SIGINT`
- `137` — terminated by `SIGKILL`
- `143` — terminated by `SIGTERM`

Builtin failures that are semantic/user errors rather than process-launch failures return `1` by convention unless a builtin specifies a better code.

### 20.3 Per-form status rules

- **Command**
  - external: child `Result`
  - builtin in shell context: `0` on success, `1` on ordinary failure, specific code if the builtin defines one
  - builtin/external launch failure: `126`/`127` as above
- **Pipeline**
  - with Slash default `pipefail = on`: first non-zero or signaled stage wins; otherwise `0`
  - if all stages succeed, result is `0`
- **Sequence**
  - result of the **last item that actually ran**
  - `&&` and `||` only control whether the next item runs; they do not overwrite the prior result except by causing another item to run after it
- **Subshell**
  - result of its body, encoded from the subshell child's final `Result`
- **Detached**
  - synchronous result is `0` if launch succeeded and the job entered the job table
  - non-zero only if launch/setup itself failed before the detached job was established
  - the detached job's eventual exit does not retroactively change the caller's status
- **If**
  - result of `then` branch if taken
  - else-branch result if else branch taken
  - `0` if condition is false and no else branch exists
- **While**
  - result of the last body iteration if any iteration ran
  - `0` if the condition fails before the first iteration
- **For**
  - result of the last body iteration if any iteration ran
  - `0` if the item list is empty
- **Define**
  - `0` on successful installation into session scope
  - non-zero if the definition cannot be installed (name invalid, memory/resource failure surfaced as shell error path, etc.)
- **Retry**
  - result of the first successful attempt, else the last failed attempt
- **Timeout**
  - result of the body if it completes in time
  - signaled result if the body is killed due to timeout policy
- **Within / WithEnv / Parallel**
  - `Within` and `WithEnv`: result of the body
  - `Parallel`: result policy must be explicit in its own section before surface syntax ships; until then it is not user-facing

### 20.4 Shell process exit

- `slash <file>` exits with the status of the last top-level statement that ran, unless an explicit `exit N` builtin overrides it.
- `slash -c 'source'` follows the same rule.
- Interactive REPL session returns the status of the last executed top-level statement when terminated normally, unless an explicit `exit N` overrides it.

---

## 21. Operational Clarifications

### 21.1 Script vs REPL mode

`slash <file>` runs the file non-interactively: no prompt, no line editor, and no interactive terminal handoff or job-control UX. `Session.args` exposes positional parameters, with `$0` bound to the script path and `$1..$N` to remaining arguments. `slash -c 'source'` is supported for scripts, tests, and editor/tool integrations; in that mode `$0` is `"slash"` unless explicitly overridden later. If the first line is a shebang (`#!...`), the lexer skips it before tokenization. The shell's exit status is the result of the last top-level statement that ran, unless an explicit `exit N` changes it.

### 21.2 `Command.exe` expansion edge cases

`Command.exe` must expand to exactly one non-empty field. Zero fields, an empty string result, or multiple fields are all hard evaluation errors: emit a diagnostic and fail the command with status `127`. Reserve `EV0001` for "command name expanded to zero or empty fields" and `EV0002` for "command name expanded to multiple fields." Slash does not silently pick the first field and does not re-split strings to guess intent.

### 21.3 Platform scope

Tier 1 platforms are Linux (`x86_64`, `aarch64`) and macOS (`aarch64`, `x86_64`); these are the targets that must pass the full test matrix as features land. Tier 2 is other POSIX systems such as FreeBSD on a best-effort basis, with portability bugs accepted but not allowed to distort the core design. Windows native is out of scope, and WSL1 oddities are not supported targets. Cross-compiling static Linux builds via `x86_64-linux-musl` is a first-class path; known `-gnu` toolchain issues do not justify design changes.

---

## 22. Final Identity

> Slash is a modern Unix shell built around a precise model of `Command`, `Pipeline`, `Program`, and `Job`. It parses your command into a `Shape`, lowers it into a `Program`, and runs it as a `Job`.

One grammar. Argv-safe. First-class job control. Structured pipelines. No language creep. Everything inspectable. AI-assisted, never AI-driven.

That's the shell.
