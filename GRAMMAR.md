# Slash Grammar Reference

This document describes the formal grammar for the Slash shell. The grammar
is defined in `slash.grammar` and processed by `src/grammar.zig` to generate
`src/parser.zig` — a high-performance LALR(1) parser that emits s-expressions.

```
slash.grammar  →  grammar.zig  →  src/parser.zig
```

The generated parser produces s-expressions that the executor (`exec.zig`)
walks and executes as shell commands.

---

## 1. Lexer

The lexer converts source text into a stream of tokens. It handles
context-sensitive tokenization using state variables.

### 1.1 State Variables

| Variable | Initial | Purpose |
|----------|---------|---------|
| `beg` | 1 | At beginning of line (1 = yes, 0 = no) |
| `heredoc` | 0 | Heredoc mode (0 = none, 1 = literal, 2 = interpolated, 3 = backtick) |
| `paren` | 0 | Parenthesis nesting depth |
| `brace` | 0 | Brace nesting depth |

### 1.2 Token Types

**Literals**

| Token | Example | Description |
|-------|---------|-------------|
| `ident` | `ls`, `foo_bar` | Bare word (command, argument, variable name) |
| `integer` | `0`, `42`, `1000` | Integer literal |
| `real` | `3.14`, `.5` | Decimal literal |
| `string_sq` | `'hello'` | Single-quoted string (literal, no interpolation) |
| `string_dq` | `"hello $name"` | Double-quoted string (interpolated) |
| `regex` | `/pattern/i` | Regex literal with optional flags |
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
| `power` | `**` | Exponentiation |

**Assignment and Default**

| Token | Symbol | Description |
|-------|--------|-------------|
| `assign` | `=` | Assignment |
| `default_op` | `??` | Default value (if unset or empty) |

**Punctuation**

| Token | Symbol | Description |
|-------|--------|-------------|
| `lparen` | `(` | Open parenthesis (increments `paren`) |
| `rparen` | `)` | Close parenthesis (decrements `paren`) |
| `lbrace` | `{` | Open brace (increments `brace`) |
| `rbrace` | `}` | Close brace (decrements `brace`) |
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
| `err` | | Lexer error (unrecognized character) |

### 1.3 Lexer Rules

Rules are matched in order. Longer patterns are listed first to prevent
partial matches.

**Comments.** `#` starts a comment that runs to end of line. SIMD-accelerated
scan to newline. Allowed everywhere including the interactive prompt.

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
body collection and margin stripping are handled by the executor, not the
lexer.

**Herestrings.** `<<<` feeds a single string as stdin to a command.

**Numbers.** Reals are matched before integers (longer match first).
`[0-9]*.[0-9]+` matches reals, `[0-9]+` matches integers.

**Regex literals.** `/pattern/flags` where flags are from `[gimsux]`.
Disambiguation from division requires context: regex is valid after
operators, keywords, and at expression start — never after a value token.
This is handled in generated code.

**Variable references.** `$name` for named variables, `$0`-`$9` for
positional, `$?`, `$$`, `$!`, `$#`, `$*` for specials. `${...}` for braced
forms including `${name ?? default}`.

**Operators.** Multi-character operators are matched before single-character
to prevent partial matches. Order: `|&` before `|`, `&&` before `&`,
`>>` before `>`, `**` before `*`, etc.

**Identifiers.** Bare words matching `[a-zA-Z_][a-zA-Z0-9_-]*` or path-like
patterns `[a-zA-Z_./~][a-zA-Z0-9_./-]*`. Keywords are recognized by the
parser via `@as` directives, not the lexer.

### 1.4 Indentation Handling

In script mode (`.slash` files), the lexer tracks indentation levels and
emits `indent`/`outdent` tokens. In interactive mode with braces, it emits
`lbrace`/`rbrace` instead. The grammar accepts both forms uniformly via the
`block` rule.

### 1.5 Regex Disambiguation

The `/` character is ambiguous: it could be division or the start of a regex.
The lexer uses the preceding token to decide:

- After `ident`, `integer`, `real`, `string_*`, `rparen`, `variable` → division
- After everything else (`=~`, `!~`, `==`, `(`, `and`, etc.) → regex

---

## 2. Parser

The parser is LALR(1), generated from grammar rules that produce
s-expressions. Each rule defines a non-terminal with one or more alternatives,
each with an optional s-expression output transform.

### 2.1 Keywords

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

### 2.2 Operator Word Aliases

Symbol and word forms are interchangeable:

| Word | Symbol |
|------|--------|
| `and` | `&&` |
| `or` | `\|\|` |
| `not` | `!` |
| `xor` | (word form only) |

### 2.3 Parser Aliases

Zero-cost aliases expanded at compile time:

| Alias | Expansion |
|-------|-----------|
| `name` | `IDENT` |
| `word` | `IDENT \| STRING_SQ \| STRING_DQ \| INTEGER \| REAL \| VARIABLE \| VAR_BRACED` |
| `cmd_name` | `IDENT \| STRING_SQ \| STRING_DQ` |

---

## 3. Grammar Rules

### 3.1 Program Structure

```
program  = line*
line     = stmt NEWLINE | NEWLINE | COMMENT NEWLINE
```

A program is a sequence of lines. Empty lines and comment-only lines
produce no output (nil).

### 3.2 Statements

```
stmt = cmd_def | key_def | set_stmt | assignment
     | if_stmt | unless_stmt | for_stmt | while_stmt | until_stmt | try_stmt
     | pipeline
```

Definitions (`cmd`, `key`, `set`) and assignments are checked before
general pipelines.

### 3.3 Pipelines and Command Lists

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

### 3.4 Commands

```
command     = ! command            → (not cmd)
            | ( cmdlist )          → (subshell cmds)
            | simple_cmd

simple_cmd  = cmd_word (argument | redirect)* [heredoc]
                                   → (cmd name args heredoc)
```

### 3.5 Arguments and Redirections

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

### 3.6 Heredocs

```
heredoc = ''' body* '''           → (heredoc_literal lines...)
        | """ body* """           → (heredoc_interp lines...)
        | ```lang body* ```       → (heredoc_lang tag lines...)
```

Heredoc bodies are collected line by line. The closing delimiter's
indentation defines the left margin. All content lines are dedented by
that amount. Piping and stacking are supported — the pipe can appear on
the opening line or after the closing delimiter. Multiple heredocs on one
command line match their bodies in order.

### 3.7 Variable Assignment

```
assignment = name = -       → (unset name)
           | name = expr    → (assign name value)
```

Bare `-` on the right side of `=` means unset (remove the variable).
Quoted `"-"` is the literal string minus.

### 3.8 Conditionals

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

Comparison operators: `==`, `!=`, `<`, `>`, `<=`, `>=`, `=~`, `!~`.
Boolean connectors: `and`, `or`, `not` (with parentheses for grouping).

### 3.9 Loops

```
for_stmt   = for name in wordlist block    → (for var list body)
while_stmt = while condition block         → (while cond body)
until_stmt = until condition block         → (until cond body)
```

`break` exits the innermost loop. `continue` skips to the next iteration.

### 3.10 Pattern Matching

```
try_stmt  = try expr try_block             → (try value arms)
try_arm   = "string" block                 → (arm pattern body)
          | /regex/ block                  → (arm pattern body)
          | word block                     → (arm pattern body)
          | else block                     → (arm_else body)
```

Matches the value against each arm in order. String matches are exact.
Regex matches use `/pattern/flags` syntax. `else` is the catch-all.

### 3.11 Blocks

```
block = { stmt* }             → (block stmts...)
      | INDENT stmt* OUTDENT  → (block stmts...)
```

Both forms are semantically identical. Braces for one-liners at the
prompt, indentation for scripts and multi-line work. The lexer handles
the difference; the grammar sees the same `block` rule either way.

### 3.12 User Commands

```
cmd name params? block    → (cmd_def name params body)
cmd name params? stmt     → (cmd_def name params body)
cmd name -                → (cmd_del name)
cmd name                  → (cmd_show name)
cmd                       → (cmd_list)

params = ( name, name, ... )
```

One-line and multi-line forms. Named parameters capture positional
arguments. `$*` refers to remaining arguments. If no positional variables
appear in a one-liner body, `$*` is implicitly appended.

The special name `???` defines the command-not-found hook.

### 3.13 Key Bindings

```
key combo action      → (key combo action)
key combo "command"   → (key combo command)
key combo -           → (key_del combo)
```

Bare word = readline action. Quoted string = execute as command.

### 3.14 Shell Options

```
set name value    → (set name value)
set name -        → (set_reset name)
set name          → (set_show name)
set               → (set_list)
```

### 3.15 Expressions

```
expr   = term ((+ | -) term)*
term   = factor ((* | / | %) factor)*
factor = base (** factor)?
base   = ( expr ) | - base | + base | atom
atom   = VARIABLE | VAR_BRACED | INTEGER | REAL | STRING | capture

expr  |= expr ?? expr    → (default value fallback)
```

Standard arithmetic precedence. `**` is right-associative. The `??`
operator provides a default value when the left side is unset or empty.

### 3.16 File Tests

```
test -flag path    → (test flag path)
```

Flags: `-e` (exists), `-f` (file), `-d` (directory), `-s` (non-empty),
`-r` (readable), `-w` (writable), `-x` (executable), `-L` (symlink).

### 3.17 Special Builtins

```
exit [N]       → (exit code)
break          → (break)
continue       → (continue)
shift          → (shift)
source file    → (source path)
```

`exit` is context-sensitive: exits the innermost context (command, script,
or shell) with an optional numeric exit code (default 0).

---

## 4. S-Expression Output

The parser produces s-expressions that the executor walks. Every construct
maps to a tagged list:

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
| `key esc-l "ls -la"` | `(key esc-l "ls -la")` |
| `set prompt-git true` | `(set prompt-git true)` |
| `test -f $file` | `(test -f $file)` |
| `exit 1` | `(exit 1)` |
| `cat ''' ... '''` | `(cmd cat (heredoc_literal ...))` |
| `wc <<< "hello"` | `(cmd wc (herestring "hello"))` |
| `$x ?? 0` | `(default $x 0)` |
| `make && echo ok` | `(and (cmd make) (cmd echo ok))` |
| `sleep 10 &` | `(bg (cmd sleep 10))` |
| `(cd /tmp; ls)` | `(subshell (seq (cmd cd /tmp) (cmd ls)))` |

The `--sexpr` flag dumps the parsed s-expression for any input, useful for
debugging and development.

---

## 5. Compilation Pipeline

```
source text → lexer → tokens → parser → s-expressions → executor → execution
```

1. **Lexer** tokenizes input with context-sensitive state
2. **Parser** builds s-expressions from the token stream (LALR(1))
3. **Evaluator** pattern-matches on s-expression heads and dispatches:
   - `cmd` → fork/exec or builtin dispatch
   - `pipe` → pipe creation, fork both sides
   - `if`/`for`/`while`/`try` → control flow
   - `assign`/`unset` → variable management
   - `cmd_def` → register user command
   - `redir_*` → file descriptor setup
   - `heredoc_*` → collect body, strip margin, feed stdin
   - `bg` → background job management
   - `subshell` → fork and execute in child

No AST node types, no visitor pattern. S-expressions are lists.
The executor is a recursive function that switches on the head tag.
