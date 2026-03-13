<p align="center">
  <img src="docs/assets/slash-1280w.png" alt="Slash Logo" width="400">
</p>

## A modern shell built on Unix fundamentals

Slash is a clean, fast, modern shell written entirely in Zig. It uses a
grammar-driven SLR(1) parser that emits s-expressions — no hand-rolled
parsing, no AST, no intermediate representations. The parser is generated
from a formal grammar by a powerful Zig-based engine used in several commercial
projects.

Slash is **not** a programming language, it is a **shell**. It runs commands,
composes them with pipes and redirects, manages processes and jobs, navigates
the filesystem, and gets out of your way. When you need real computation, call
a real language. Slash executes it.

---

## Why Slash?

Every existing shell carries decades of accumulated compromise. Bash is a 1989
design patched for 37 years. Zsh is Bash with more footguns and a plugin
ecosystem that papers over them. Fish is friendly but timid. Nushell forgot it
was supposed to be a shell and became a data language. PowerShell is an
abomination.

Slash starts from scratch with clear principles:

- **Composition over computation** — the shell's job is to run programs and wire
  them together, not to be a programming language
- **Grammar-driven parsing** — one formal grammar is the single source of truth
  for lexing, parsing, syntax highlighting, and error messages
- **No configuration required** — rich prompt, history, directory jumping, syntax
  highlighting, and tab completion all work out of the box
- **Correct job control** — process groups, terminal ownership, signal handling,
  and pipeline wiring done right, not approximately
- **One syntax, two forms** — braces for one-liners at the prompt, indentation
  for scripts. Same semantics, same grammar, different delimiters

---

## Features

### Language

Slash has exactly the language features a shell needs — no more.

**Commands and pipelines:**

```
ls -la /tmp
git commit -m "initial commit"
ls -la | grep zig | sort
make |& grep error                    # pipe stderr too
```

**Boolean operators** (symbol and word forms are interchangeable):

```
make && echo done        # or: make and echo done
make || echo failed      # or: make or echo failed
! test -f foo            # or: not test -f foo
```

**Variables** — uppercase variables are automatically exported, no `export` keyword:

```
name = "steve"
count = 42
PATH = "$PATH:/usr/local/bin"
name = -      # unset (bare minus)
```

At the top level, assignments persist in the shell. Uppercase names are
exported to child processes; lowercase names stay shell-local.

**Inline math** — no `$(( ))` syntax, no calling `bc`:

```
x = 10 + 4    # x is 14
y = $x * 3    # y is 42
2 ** 10       # 1024 (also: 2^10)
1 + 2 * 8     # prints 17
```

**Conditionals** with `if` / `unless` / `else`:

```
if git diff --quiet { echo clean } else { echo dirty }
if $count == 0 { echo "nothing" }
if $file =~ /\.zig$/ { echo "zig source" }
if $name =~ ~|^test|i { echo "test file" }
if $x > 0 and $x < 100 { echo "in range" }
```

**Loops** with `for` / `while` / `until`:

```
for f in *.zig { echo $f }
while $count < 10 { count = $count + 1 }
```

**Pattern matching** with `try`:

```
try $action
    "start"  { npm run dev }
    "build"  { npm run build }
    /test/i  { npm run test }
    else     { echo "unknown action" }
```

**User commands** (`cmd`) — one concept replaces aliases, functions, and scripts:

```
cmd ll ls -la
cmd g git $*
cmd mkcd(dir) mkdir -p $dir && cd $dir

cmd serve(port)
    port = $port ?? 8080
    python3 -m http.server $port
```

Each `cmd` invocation gets a fresh local variable scope. Assignments inside a
`cmd` do not leak back into the shell, but uppercase variables are still
exported to child processes launched by that command.

**String lists** — build commands incrementally without flattening to a string:

```
args = [find . -type f]
args += [-iname "*.zig"]
run $args
```

Lists preserve argument boundaries. `run` expands a list-valued variable into
real argv entries — redirections and pipes work normally:

```
cmd f(name)
    match = $name
    args = [find .]
    args += [-not '(' -path '*/.*/*' -o -path '*/node_modules/*' ')']
    if $name != "." { args += [-iname "*$name*"] }
    if $name == "." { match = "" }
    if $match != "" { run $args 2> /dev/null | grep -i $match }
    if $match == "" { run $args 2> /dev/null }
```

**Default values** with `??`:

```
port = $1 ?? 8080
cmd o open ${* ?? "."}
```

In expression contexts, `??` currently falls back when the left side evaluates
to `0`. In braced-variable/string contexts, it behaves like a default for
unset/empty values.

**Redirections** — full Unix set:

```
command > out.txt                     # stdout to file
command >> out.txt                    # append
command 2> err.txt                    # stderr to file
command &> out.txt                    # stdout + stderr
command < input.txt                   # stdin from file
```

**Heredocs** with triple-character delimiters (no `<<EOF` tokens):

```
cat '''                               # literal (no interpolation)
    Hello $name
    '''

cat """                               # interpolated
    Hello $name
    """
```

The closing delimiter's indentation defines the left margin — content is
automatically dedented.

**Subshell capture and process substitution:**

```
branch = $(git branch --show-current)
diff <(sort a.txt) <(sort b.txt)
```

**Block syntax** — braces or indentation, everywhere, always:

```
# Brace form (prompt one-liners)
if $x == 1 { echo one } else { echo other }

# Indentation form (scripts)
if $x == 1
    echo one
else
    echo other
```

### Syntax Highlighting

Live highlighting as you type, powered by the generated lexer — the same
tokenizer used by the parser, not a separate pile of regexes. Keywords are
blue, strings green, variables cyan, numbers magenta, operators yellow, flags
light cyan, regex red, and comments gray. Errors get red underline.

### Directory Navigation

First-class, not a plugin:

```
cd projects/slash                     # go there, record it
..                                    # up one level (no cd needed)
...                                   # up two levels
cd -                                  # back to previous directory
j slash                               # list recent session dirs matching "slash"
/tmp                                  # auto-cd (just type the path)
```

Type `j` to list your most recent directories for this session (MRU, deduped).
Type a number (1-9) at the next prompt to jump. If you want a hotkey, bind one
with `key esc-= "j"`.

### Prompt

Rich out of the box. The default prompt shows time, user/host, and directory.
Git branch (via `.git/HEAD`), command duration, and exit codes are available
through prompt escapes. Fully configurable via format strings:

```
PROMPT="%bg(#43669d)%fg(#ecede8) %t %bg(#81a1c7)%fg(#43669d)%>%fg(#ecede8) %u@%h %r%fg(#81a1c7)%>%fg(#ecede8) %d>%r "
```

Supports `%t` (time), `%u` (user), `%h` (host), `%d` (directory), `%g` (git),
`%e` (exit code), `%D` (duration), `%$` (colored prompt char), `%fg`/`%bg`
(hex colors), `%>` (powerline arrow), and `%r` (reset).

### History

Command history is stored in `~/.slash/history` as tab-separated text, loaded
into memory on startup. Each entry records the command, working directory, exit
code, duration, and timestamp. `Ctrl+R` opens incremental search with live
filtering.

### Tab Completion

Context-aware: if the cursor is on the first word, complete against PATH,
builtins, and user commands. If it starts with `$`, complete against defined
variables. Otherwise, complete against files and directories. Common prefix
is computed when multiple matches exist.

### Job Control

Slash supports POSIX-style job control: foreground pipelines get their own
process groups, `Ctrl+C` targets the foreground job instead of the shell,
`Ctrl+Z` stops the foreground job, and `fg`, `bg`, and `jobs` are available.
Both parent and child call `setpgid` to close the fork race condition. Signal
defaults are restored before `exec` in children. Background reaping is
poll-based at prompt boundaries rather than using a `SIGCHLD` handler.

Job control uses numeric job ids (`fg 3`, `bg 2`). Bash/Zsh jobspec shorthand
like `%3` is intentionally not supported; Slash prints a hint to use `fg 3`.

### Key Bindings

Human-readable syntax with `key`:

```
key esc-=     "j"                     # list recent directories
key esc-1     ".."                    # up 1 directory
key esc-l     "ls -la"               # quick listing
key ctrl-r    "echo search"           # bindings execute shell commands
key ctrl-l    "clear"                 # clear screen
```

---

## Architecture

```
slash.grammar  →  grammar.zig  →  parser.zig  (lexer + SLR parser)
                                               (tags + keywords generated inline)
exec.zig                                       (s-expression executor: fork/exec/pipe)
main.zig                                       (CLI + REPL)
lexer.zig                                      (shell-specific lexer extensions)
readline.zig                                   (line editing, highlighting, completion)
prompt.zig                                     (prompt rendering, format escapes)
history.zig                                    (flat-file history)
regex.zig                                      (libc POSIX regex wrapper)
```

The compilation pipeline is:

```
source text  →  lexer  →  tokens  →  parser  →  s-expressions  →  executor
```

There is no AST. The parser outputs s-expressions directly (`["pipe", a, b]`,
`["if", cond, then, else]`). The executor pattern-matches on the head of each
list and dispatches. Simple, fast, debuggable. Use `--sexp` (or `-s`) to dump
the parsed s-expression for any input.

### Key Files

| File | Purpose |
|------|---------|
| `slash.grammar` | Lexer rules + parser rules — single source of truth |
| `src/grammar.zig` | Generic grammar tool, generates `parser.zig` from any `.grammar` file |
| `src/parser.zig` | **Generated — do not edit.** Regenerate with `./bin/grammar slash.grammar src/parser.zig` |
| `src/lexer.zig` | Shell-specific lexer extensions (heredocs, indentation, regex disambiguation) |
| `src/exec.zig` | Walks s-expressions, executes commands (struct: `Shell`) |
| `src/main.zig` | Entry point, CLI flags, REPL loop |
| `src/readline.zig` | Line editing, key bindings, syntax highlighting, tab completion |
| `src/prompt.zig` | Prompt rendering with format escapes, git branch, duration |
| `src/history.zig` | Flat-file history (`~/.slash/history`) |
| `src/regex.zig` | libc POSIX regex wrapper (ERE) for `=~`, `!~`, glob expansion |

---

## Build

Requires **Zig 0.15.2**.

```bash
zig build              # build bin/slash
zig build run          # build and run slash
zig build grammar      # build bin/grammar
```

### Regenerate Parser

When `slash.grammar` changes:

```bash
zig build grammar
./bin/grammar slash.grammar src/parser.zig
zig build
```

---

## What Slash Is Not

Slash is not a POSIX shell and does not aim for POSIX compliance. It will not
run Bash scripts — if you need Bash, call it. Slash is your interactive shell
and your scripting language for tasks that are genuinely shell tasks.

Slash is not a programming language. It has commands, not functions — no return
values, no local scope, no closures, no recursion, no data structures. It
composes with real languages, it does not replace them.

Slash is not configurable to the point of chaos. No plugin system, no theme
engine, no package manager for shell extensions. Good defaults and a simple
config file. That is enough.

---

## Status

Slash is under active development. The parser, executor, job control, readline,
syntax highlighting, tab completion, history, directory navigation, prompt, and
key bindings are all working. See [INTERNALS.md](INTERNALS.md) for technical
deep-dives into the grammar, parser, and execution model.

---

## License

MIT
