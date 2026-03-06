# Slash Internals

Technical reference for the Slash grammar, parser, executor, and runtime.
This document covers implementation details too low-level for the README
but essential for contributors working on the parser or executor.

---

## Grammar and Parser

Slash uses a Zig-based grammar engine that reads `slash.grammar` and generates
`src/parser.zig` — a high-performance SLR(1) parser that emits s-expressions.

```
slash.grammar  →  grammar.zig  →  src/parser.zig
```

The generated parser produces s-expressions that the executor (`exec.zig`)
walks and executes as shell commands.

---

## Lexer

The lexer converts source text into a stream of tokens. It handles
context-sensitive tokenization using state variables.

### State Variables

| Variable | Initial | Purpose |
|----------|---------|---------|
| `beg` | 1 | At beginning of line (1 = yes, 0 = no) |
| `heredoc` | 0 | Heredoc mode (0 = none, 1 = literal, 2 = interpolated, 3 = backtick) |
| `paren` | 0 | Parenthesis nesting depth |
| `brace` | 0 | Brace nesting depth |
| `math` | 0 | Math context (1 = after `=`; `/` is division, `^` is power) |

### Token Types

**Literals**

| Token | Example | Description |
|-------|---------|-------------|
| `ident` | `ls`, `foo_bar` | Bare word (command, argument, variable name) |
| `integer` | `0`, `42` | Integer literal |
| `real` | `3.14`, `.5` | Decimal literal |
| `string_sq` | `'hello'` | Single-quoted string (literal, no interpolation) |
| `string_dq` | `"hello $name"` | Double-quoted string (interpolated) |
| `regex` | `/pattern/i`, `~\|pattern\|i` | Regex literal with optional flags (any delimiter after `~`) |
| `glob` | `*.zig` | Glob pattern |

**Variable References**

| Token | Example | Description |
|-------|---------|-------------|
| `variable` | `$name`, `$1`, `$?`, `$$`, `$!`, `$#`, `$*`, `$0` | Variable reference |
| `var_braced` | `${name}`, `${1 ?? "default"}` | Braced variable with optional default |

**Heredoc Markers**

| Token | Symbol | Description |
|-------|--------|-------------|
| `heredoc_sq` | `'''` | Literal heredoc delimiter (start/end) |
| `heredoc_dq` | `"""` | Interpolated heredoc delimiter (start/end) |
| `heredoc_bt` | `` ```lang `` | Syntax-highlighted heredoc start (with language tag) |
| `heredoc_end` | `` ``` `` | Backtick heredoc end |
| `heredoc_body` | | Content line within a heredoc |
| `herestring` | `<<<` | Herestring operator |

**Pipeline and Redirection Operators**

| Token | Symbol | Description |
|-------|--------|-------------|
| `pipe` | `\|` | Pipe stdout |
| `pipe_err` | `\|&` | Pipe stdout and stderr |
| `redir_out` | `>` | Redirect stdout to file (truncate) |
| `redir_append` | `>>` | Redirect stdout to file (append) |
| `redir_in` | `<` | Redirect stdin from file |
| `redir_err` | `2>` | Redirect stderr to file |
| `redir_err_app` | `2>>` | Redirect stderr to file (append) |
| `redir_both` | `&>` | Redirect stdout and stderr to file |
| `redir_fd` | `N>`, `N<` | Numbered file descriptor redirection |
| `redir_dup` | `2>&1` | File descriptor duplication |
| `proc_sub_in` | `<(` | Process substitution (input) |
| `proc_sub_out` | `>(` | Process substitution (output) |

**Boolean and Control Operators**

| Token | Symbol | Description |
|-------|--------|-------------|
| `and_sym` | `&&` | Logical AND (also word `and`) |
| `or_sym` | `\|\|` | Logical OR (also word `or`) |
| `not_sym` | `!` | Logical NOT (also word `not`) |
| `bg` | `&` | Background job (at end of command) |
| `semi` | `;` | Sequential command separator |

**Comparison Operators**

| Token | Symbol | Description |
|-------|--------|-------------|
| `eq` | `==` | Equal |
| `ne` | `!=` | Not equal |
| `lt` | `<` | Less than |
| `gt` | `>` | Greater than |
| `le` | `<=` | Less than or equal |
| `ge` | `>=` | Greater than or equal |
| `match` | `=~` | Regex match |
| `nomatch` | `!~` | Regex non-match |

**Arithmetic Operators**

| Token | Symbol | Description |
|-------|--------|-------------|
| `plus` | `+` | Addition |
| `minus` | `-` | Subtraction / unary minus |
| `star` | `*` | Multiplication |
| `slash` | `/` | Division |
| `percent` | `%` | Modulo |
| `power` | `**`, `^` | Exponentiation (`^` is power, not XOR) |

**Assignment and Default**

| Token | Symbol | Description |
|-------|--------|-------------|
| `assign` | `=` | Assignment |
| `default_op` | `??` | Default value (if unset or empty) |

**Punctuation**

| Token | Symbol | Description |
|-------|--------|-------------|
| `lparen` | `(` | Open parenthesis |
| `rparen` | `)` | Close parenthesis |
| `lbrace` | `{` | Open brace |
| `rbrace` | `}` | Close brace |
| `comma` | `,` | Comma (parameter lists) |
| `backslash` | `\` | Line continuation |
| `dollar` | `$` | Dollar sign (expansion context) |

**Structure**

| Token | Symbol | Description |
|-------|--------|-------------|
| `indent` | | Indentation increase (script mode) |
| `outdent` | | Indentation decrease (script mode) |
| `newline` | | Line terminator |
| `comment` | `# ...` | Comment (to end of line) |
| `eof` | | End of input |

### Lexer Rules

Rules are matched in order. Longer patterns are listed first to prevent
partial matches.

**Comments.** `#` starts a comment that runs to end of line.

**Newlines and line continuation.** `\` before a newline is a line continuation
— the lexer skips both and continues on the next line. CRLF is treated as a
single newline. All newlines set `beg = 1`.

**Strings.** Single-quoted strings (`'...'`) are literal — no interpolation,
no escapes except `''` for an embedded single quote. Double-quoted strings
(`"..."`) support variable interpolation (`$name`) and standard escape
sequences (`\n`, `\t`, `\\`, `\"`, etc.).

**Heredoc delimiters.** `'''` opens/closes a literal heredoc. `"""` opens/closes
an interpolated heredoc. `` ```lang `` opens a syntax-highlighted heredoc
(the language tag is captured in the token text). `` ``` `` closes it. Heredoc
body collection and margin stripping are handled by the wrapper lexer
(`src/lexer.zig`), which collects body lines and strips indentation before
the parser sees them. The executor then concatenates and interpolates the
already-tokenized body.

**Numbers.** Reals are matched before integers (longer match first).

**Regex literals.** Two forms: `/pattern/flags` after `=~`/`!~` operators, and
`~<delim>pattern<delim>flags` anywhere (standalone). The `~` prefix with any
non-alphanumeric, non-slash delimiter (e.g., `~|pattern|i`) avoids ambiguity
with paths (`~/foo`) and division (`22/7`). Flags: `[gimsux]`.

**Variable references.** `$name` for named variables, `$0`-`$9` for positional,
`$?`, `$$`, `$!`, `$#`, `$*` for specials. `${...}` for braced forms including
`${name ?? default}`.

**Operators.** Multi-character operators are matched before single-character
to prevent partial matches. Order: `|&` before `|`, `&&` before `&`,
`>>` before `>`, `**` before `*`, etc.

**Identifiers.** Bare words matching `[a-zA-Z_][a-zA-Z0-9_-]*` or path-like
patterns `[a-zA-Z_./~][a-zA-Z0-9_./-]*`. Keywords are recognized by the
parser via `@as` directives, not the lexer.

### Indentation Handling

In script mode (`.slash` files), the lexer tracks indentation levels and
emits `indent`/`outdent` tokens. In interactive mode with braces, it emits
`lbrace`/`rbrace` instead. The grammar accepts both forms uniformly via the
`block` rule.

### Regex Syntax

Two regex literal forms:

**After `=~` / `!~`:** any non-alphanumeric character works as the delimiter.
The lexer knows it's regex context because the previous token was `match` or
`nomatch`. `/pattern/flags` is the conventional form, but `~|pattern|flags`
or any other delimiter also works.

```
if $file =~ /\.zig$/ { echo yes }
if $file =~ ~|\.zig$| { echo yes }
```

**Standalone `~<delim>`:** `~` followed by any non-alphanumeric, non-slash
delimiter signals a regex literal anywhere in a command. The executor expands
these against directory contents (regex glob). `~/` is excluded because it's
a home path; `~letter` is excluded because it's a username path.

```
ls ~|\.zig$|          # files matching regex
ls ~|test|i           # case-insensitive
```

The `~` prefix was chosen to avoid all ambiguity with paths and division.

---

## Keywords

Keywords are recognized from `ident` tokens via `@as` directives:

| Keyword | Token | Purpose |
|---------|-------|---------|
| `if` | `kw_if` | Conditional |
| `unless` | `kw_unless` | Negated conditional |
| `else` | `kw_else` | Else branch |
| `for` | `kw_for` | For loop |
| `in` | `kw_in` | For-in separator |
| `while` | `kw_while` | While loop |
| `until` | `kw_until` | Until loop |
| `try` | `kw_try` | Pattern matching |
| `and` | `kw_and` | Boolean AND (word form) |
| `or` | `kw_or` | Boolean OR (word form) |
| `not` | `kw_not` | Boolean NOT (word form) |
| `xor` | `kw_xor` | Boolean XOR (word form) |
| `cmd` | `kw_cmd` | User command definition |
| `key` | `kw_key` | Key binding definition |
| `set` | `kw_set` | Shell option |
| `test` | `kw_test` | File test |
| `source` | `kw_source` | Source a script |
| `exit` | `kw_exit` | Exit current context |
| `break` | `kw_break` | Break from loop |
| `continue` | `kw_continue` | Continue to next iteration |
| `shift` | `kw_shift` | Shift positional arguments |

Operator word aliases (`and`/`&&`, `or`/`||`, `not`/`!`) are interchangeable.
`xor` is word-form only — `^` is used for exponentiation, not XOR.

---

## Grammar Rules

### Program Structure

```
program  = line*
line     = stmt NEWLINE | NEWLINE | COMMENT NEWLINE
```

### Statements

```
stmt = cmd_def | key_def | set_stmt | assignment
     | if_stmt | unless_stmt | for_stmt | while_stmt | until_stmt | try_stmt
     | pipeline
```

### Pipelines and Command Lists

```
cmdlist  = pipeline && cmdlist    → (and L R)
         | pipeline || cmdlist    → (or L R)
         | pipeline ;  cmdlist    → (seq L R)
         | pipeline &  cmdlist    → (bg L R)
         | pipeline &             → (bg L)
         | pipeline

pipeline = command |& pipeline    → (pipe_err L R)
         | command |  pipeline    → (pipe L R)
         | command
```

### Commands

```
command     = ! command            → (not cmd)
            | ( cmdlist )          → (subshell cmds)
            | simple_cmd

simple_cmd  = cmd_word (argument | redirect)* [heredoc]
                                   → (cmd name args heredoc)
```

### Arguments and Redirections

```
argument          = word | proc_sub | subshell_capture
proc_sub          = <( pipeline )  → (procsub_in pipeline)
                  | >( pipeline )  → (procsub_out pipeline)
subshell_capture  = $( pipeline )  → (capture pipeline)

redirect = >   word    → (redir_out file)
         | >>  word    → (redir_append file)
         | <   word    → (redir_in file)
         | 2>  word    → (redir_err file)
         | 2>> word    → (redir_err_app file)
         | &>  word    → (redir_both file)
         | 2>&1        → (redir_dup)
         | <<< word    → (herestring value)
```

### Heredocs

```
heredoc = ''' body* '''           → (heredoc_literal lines...)
        | """ body* """           → (heredoc_interp lines...)
        | ```lang body* ```       → (heredoc_lang tag lines...)
```

The closing delimiter's indentation defines the left margin. All content
lines are dedented by that amount. Piping and stacking are supported.

### Variable Assignment

```
assignment = name = -       → (unset name)
           | name = expr    → (assign name value)
```

Bare `-` means unset. Quoted `"-"` is the literal string minus.

### Conditionals

```
if_stmt     = if condition block else_clause?     → (if cond body else)
unless_stmt = unless condition block              → (unless cond body)
else_clause = else if_stmt                        → chained
            | else block                          → (else body)

condition   = pipeline | comparison
comparison  = expr op expr     → (op L R)
            | comparison and/or comparison
            | not comparison
            | ( comparison )
```

### Loops

```
for_stmt   = for name in wordlist block    → (for var list body)
while_stmt = while condition block         → (while cond body)
until_stmt = until condition block         → (until cond body)
```

### Pattern Matching

```
try_stmt  = try expr try_block             → (try value arms)
try_arm   = "string" block                 → (arm pattern body)
          | /regex/ block                  → (arm pattern body)
          | word block                     → (arm pattern body)
          | else block                     → (arm_else body)
```

### Blocks

```
block = { stmt* }             → (block stmts...)
      | INDENT stmt* OUTDENT  → (block stmts...)
```

Both forms are semantically identical.

### User Commands

```
cmd name params? block    → (cmd_def name params body)
cmd name params? stmt     → (cmd_def name params body)
cmd name -                → (cmd_del name)
cmd name                  → (cmd_show name)
cmd                       → (cmd_list)

params = ( name, name, ... )
```

**Parsing rule:** `cmd name(params)` with `(` touching the name (pre=0) means
a parameter list. `cmd name (body)` with a space (pre>0) means subshell body.

### Key Bindings

```
key combo action      → (key combo action)
key combo "command"   → (key combo command)
key combo -           → (key_del combo)
key                   → (key_list)
```

Combo names use hyphens: `esc-l`, `esc-=`, `esc-1`. Quoted command
values are stored with quotes stripped so they re-parse as command lines.

### Shell Options

```
set name value    → (set name value)
set name -        → (set_reset name)
set name          → (set_show name)
set               → (set_list)
```

### Expressions

```
expr   = term ((+ | -) term)*
term   = factor ((* | / | %) factor)*
factor = base (** factor)?
base   = ( expr ) | - base | + base | atom
atom   = VARIABLE | VAR_BRACED | INTEGER | REAL | STRING | capture

expr  |= expr ?? expr    → (default value fallback)
```

Standard arithmetic precedence. `**` is right-associative.

### File Tests

```
test -flag path    → (test flag path)
```

Flags: `-e` (exists), `-f` (file), `-d` (directory), `-s` (non-empty),
`-r` (readable), `-w` (writable), `-x` (executable), `-L` (symlink).

---

## S-Expression Output

Every construct maps to a tagged list:

| Input | S-Expression |
|-------|-------------|
| `ls -la` | `(cmd ls -la)` |
| `ls \| wc` | `(pipe (cmd ls) (cmd wc))` |
| `x = 42` | `(assign x 42)` |
| `x = -` | `(unset x)` |
| `if $x == 1 { echo yes }` | `(if (eq $x 1) (block (cmd echo yes)))` |
| `for f in *.zig { echo $f }` | `(for f (*.zig) (block (cmd echo $f)))` |
| `try $a { "x" { echo x } }` | `(try $a (arm "x" (block (cmd echo x))))` |
| `cmd g git $*` | `(cmd_def g nil (cmd git $*))` |
| `cmd mkcd(dir) ...` | `(cmd_def mkcd (dir) ...)` |
| `cmd foo -` | `(cmd_del foo)` |
| `key esc-l "ls -la"` | `(key esc-l ls -la)` |
| `set prompt-git true` | `(set prompt-git true)` |
| `test -f $file` | `(test -f $file)` |
| `exit 1` | `(exit 1)` |
| `cat ''' ... '''` | `(cmd cat (heredoc_literal ...))` |
| `wc <<< "hello"` | `(cmd wc (herestring "hello"))` |
| `$x ?? 0` | `(default $x 0)` |
| `make && echo ok` | `(and (cmd make) (cmd echo ok))` |
| `sleep 10 &` | `(bg (cmd sleep 10))` |
| `(cd /tmp; ls)` | `(subshell (seq (cmd cd /tmp) (cmd ls)))` |

Use `--sexp` (or `-s`) to dump the parsed s-expression for any input.

---

## Compilation Pipeline

```
source text → lexer → tokens → parser → s-expressions → executor → execution
```

1. **Lexer** tokenizes input with context-sensitive state
2. **Parser** builds s-expressions from the token stream (SLR(1))
3. **Executor** pattern-matches on s-expression heads and dispatches:
   - `cmd` → fork/exec or builtin dispatch
   - `pipe` → pipe creation, fork both sides
   - `if`/`for`/`while`/`try` → control flow
   - `assign`/`unset` → variable management
   - `cmd_def` → register user command
   - `redir_*` → file descriptor setup
   - `heredoc_*` → collect body, strip margin, feed stdin
   - `bg` → background job management
   - `subshell` → fork and execute in child

No AST node types, no visitor pattern. S-expressions are lists. The executor
is a recursive function that switches on the head tag.

---

## Job Control

Job control follows the POSIX model precisely.

### Process Groups and Sessions

Slash is the session leader. Every pipeline runs in its own process group.
`Ctrl+C` sends `SIGINT` to the entire pipeline group — all processes die,
Slash survives.

### Spawning a Foreground Job

```zig
const pid = try std.posix.fork();
if (pid == 0) {
    // Child
    try std.posix.setpgid(0, 0);
    try std.posix.tcsetpgrp(shell_tty, std.posix.getpid());
    resetSignalsToDefaults();
    try std.posix.execve(path, argv, envp);
} else {
    // Parent
    try std.posix.setpgid(pid, pid);      // race condition prevention
    waitForJob(pid);
    try std.posix.tcsetpgrp(shell_tty, shell_pgid);
}
```

Both parent and child call `setpgid`. The second call is a no-op. This closes
the race window where the parent might try to give the terminal to a process
not yet in the right group.

### Signal Handling

Slash sets these signals to `SIG_IGN` at startup in `main.zig`:

| Signal | Slash | Child |
|--------|-------|-------|
| `SIGINT` | Ignore | Default (terminate) |
| `SIGQUIT` | Ignore | Default |
| `SIGTSTP` | Ignore | Default (stop) |
| `SIGTTOU` | Ignore | Default |
| `SIGTTIN` | Ignore | Default |

There is no `SIGCHLD` handler — background job reaping is done by polling
with `waitpid(-1, WNOHANG)` in `reapAndReport()` at each prompt cycle.
`SIGPIPE` is not explicitly handled by the shell; children get the kernel
default.

Children must have all signals reset to defaults before `exec`.

### Terminal Ownership Transfer

```
Ctrl+Z pressed:
  1. SIGTSTP delivered to foreground pgid
  2. Processes stop
  3. waitpid returns with WIFSTOPPED
  4. Slash calls tcsetpgrp(tty, slash_pgid)  -- reclaim terminal
  5. Slash redraws prompt

fg command:
  1. Slash calls tcsetpgrp(tty, job_pgid)    -- give terminal to job
  2. Slash calls kill(job_pgid, SIGCONT)      -- resume job
  3. Slash calls waitpid(job_pgid)            -- wait for it
  4. On return, tcsetpgrp(tty, slash_pgid)    -- reclaim
```

### Job Table

Up to 64 jobs. Each job tracks its process group and up to 8 PIDs:

```zig
const Job = struct {
    id: u16,                    // [1], [2]
    pgid: posix.pid_t,
    state: JobState,            // running, stopped, done
    exit_code: u8,
    command: []const u8,        // original command string for display
    pids: [8]posix.pid_t,       // individual PIDs in the pipeline
    pid_count: u8,
};
```

---

## File Descriptor Handling

### Standard Redirections

```
cmd > file          # stdout → file (truncate)
cmd >> file         # stdout → file (append)
cmd < file          # stdin ← file
cmd 2> file         # stderr → file
cmd &> file         # stdout and stderr → file
cmd 2>&1            # stderr → stdout
```

### Pipeline FD Wiring

For `A | B | C`, two pipes are created:

```
pipe1: A_stdout → B_stdin
pipe2: B_stdout → C_stdin
```

After forking each process:
- A: close read end of pipe1, close both ends of pipe2, dup pipe1 write → stdout
- B: close write end of pipe1, close read end of pipe2, dup pipe1 read → stdin, dup pipe2 write → stdout
- C: close both ends of pipe1, close write end of pipe2, dup pipe2 read → stdin

All unused pipe ends are closed before exec. Failure to close them causes
`SIGPIPE` never to be delivered and pipelines to hang.

### Process Substitution

`diff <(sort a.txt) <(sort b.txt)` — implemented with pipes and `/dev/fd/N`.
Slash creates a pipe, forks a child to run the substituted command writing to
the write end, and passes the read end's path as an argument to the outer
command.

---

## Builtins

Commands implemented inside Slash (they affect shell state):

These are registered in `isBuiltin()` in `exec.zig`:

| Command | Description |
|---------|-------------|
| `cd` | Change directory (file-aware), record in frecency DB |
| `..` / `...` / `....` | Go up 1, 2, 3, ... directories (dynamic dot-counter) |
| `echo` | Print arguments |
| `true` / `false` | Exit 0 / Exit 1 |
| `type` | Show whether a name is a builtin, command, or external |
| `pwd` | Print working directory |
| `jobs` | List all jobs |
| `fg` / `bg` | Job control (foreground / background) |
| `history` | Search/display command history |
| `j` | Fuzzy jump to frecency-ranked directory match |
| `exit` | Exit current context (command, script, or shell) |
| `source` | Execute a script in current shell context |
| `set` | Set, show, reset, or list shell options |
| `cmd` | Define, show, delete, or list user commands |
| `key` | Define key bindings |
| `test` | File tests (`-f`, `-d`, `-e`, `-s`, `-r`, `-w`, `-x`, `-L`) |
| `shift` | Shift positional arguments |
| `break` / `continue` | Loop control flow |

`exec` is handled at the s-expression dispatch level (tag `.exec`), not
through `tryBuiltin()` — it replaces the shell process via `execvpeZ`.

---

## Executor/Expander Concerns

These features are handled post-parse by the executor — the grammar passes
raw tokens through, expansion happens at runtime:

| Feature | Where |
|---------|-------|
| Glob expansion (`*.zig`, `file[0-9]`) | Expander converts glob to regex, matches against directory entries |
| Regex glob expansion (`~\|pattern\|`) | Expander compiles Oniguruma regex, matches against directory entries |
| Brace expansion (`{a,b,c}`) | Expander checks `pre=0` on LBRACE to distinguish from block syntax |
| Variable interpolation in strings | Expander parses `$name` inside `string_dq` tokens |
| Tilde expansion (`~/foo`) | Expander handles `~` prefix in idents |
| Auto-cd (`/tmp` as command) | Executor fallback when command not found |

---

## Grammar Engine Implementation Notes

These features are specified in the grammar but require specific implementation
in `grammar.zig`:

| Feature | What's Needed |
|---------|---------------|
| Regex literals | After `=~`/`!~`: any delimiter works. Standalone: `~<delim>pattern<delim>flags` where delim is non-alnum, non-slash. Handled in `lexer.zig`. |
| Else after OUTDENT | Lexer must not emit NEWLINE between OUTDENT and ELSE |
| `cmd name(params)` vs `cmd name (body)` | Parser checks LPAREN's `pre` field — `pre=0` means params, `pre>0` means subshell |
