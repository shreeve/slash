<p align="center">
  <img src="docs/assets/slash-1280w.png" alt="Slash" width="500">
</p>

<div align="center">
  <strong>A Unix shell with structured commands, composable pipelines, and first-class jobs &mdash; one grammar, end to end.</strong>
</div>

---

## What is Slash?

Slash is a Unix shell written in Zig. It parses each line into a `Shape`,
lowers it into an immutable `Program`, and runs it as an inspectable
`Job`. One grammar drives parsing and editor-facing syntax work;
completion and formatting must use the same grammar rather than
separate tokenizers. `argv` is never flattened to a string. Pipelines
are structured. Job control is first-class. There is no `set -e`
magic, no implicit word-splitting, no hidden coercion.

Slash runs programs. It does not try to be a language.

## The rule that decides what gets built

> Does this improve `Command` clarity, `Pipeline` correctness, `Program`
> composability, or `Job` control? If not, do not build it.

Every feature is judged against this. It's why Slash isn't a data shell,
isn't an AI shell, isn't a programming language playground. It's why the
kernel stays small and the surface stays principled. (PLAN §14.)

## What it can do

```sh
# variables (scalar and list)
x = hello
xs = [a b c]

# command substitution
year = $(date +%Y)

# control flow with brace OR indent blocks (same semantics)
if test -d /tmp { echo found } else { echo missing }

if test -d /tmp
  echo found
else
  echo missing

# loops
for x in alpha beta gamma { echo $x }

while test -f /tmp/lock { sleep 1 }

# pattern dispatch — first arm wins, glob arms, no captures, no regex
match $1
  init                { repo-init       }
  status diff         { repo-$1         }
  push pull           { repo-sync $1    }
  *.md *.txt          { open-doc $1     }
  *                   { echo unknown; return 1 }

# user-defined commands — positional only, body sees $1..$N / $@ / $#
cmd ll { ls -lAh $@ }
cmd deploy
  git pull
  npm ci
  npm run build

# env-prefix on commands
NODE_ENV=production npm start

# pipelines, redirects, subshells, detached jobs
grep zig **/*.md | head -20 > hits.txt || echo no matches
(cd /tmp && /bin/ls) > listing
sleep 60 &
jobs; fg %1
```

## Builtins

`echo`, `true`, `false`, `pwd`, `cd`, `export`, `unset`, `test` (`[`),
`printf`, `exit`, `read`, `shift`, `type`, `command`, `source` (`.`),
`exec`, `return`, `break`, `continue`, `trap`, `jobs`, `fg`, `bg`,
`wait`, `kill`, `disown`, `str`, `history`.

## Interactive UX

Slash commits to fish-class interactive UX without becoming a
programming language. The line editor is
[zigline](https://github.com/shreeve/zigline). See [`PLAN.md`](./PLAN.md)
§12 for the in-scope/out-of-scope split.

What ships today:

- syntax highlighting as you type (BaseLexer-driven; one grammar)
- `str` abbreviations (literal-bytes-to-literal-bytes editor rewrites)
- persistent metadata-rich command history (per-cwd, frecency, dedup)
- smart prefix-aware Up/Down navigation
- pre-prompt status notices (`slash: exit N (SIGNAME)`)
- live job-state announcements (`[N] Stopped`, `[N] Continued`)

See [`ROADMAP.md`](./ROADMAP.md) for remaining release work.

```sh
# `str` — editor-only literal-text rewrites. Strict literal bytes →
# literal bytes; no variables, no command substitution, no templates.
# Triggers on Space at command position; the rewritten line is what
# slash parses and runs.

# Bare-args form (cooked argv joined by spaces):
str ll  ls -lAh
str gst git status
str ..  cd ..

# Brace form (raw bytes between matched braces — no escaping needed
# for pipes, ampersands, dollar signs, quotes, etc.):
str logs { tail -f /var/log/system.log | grep error }
str awk1 { awk '{print $1}' | sort | uniq -c }

ll<space>          # → `ls -lAh ` in the editor; Enter runs it
git ll<space>      # `ll` is at argument position; Space inserts a
                   # literal space, no expansion

# Erase: idempotent, silent on missing names.
str -e ll
```

## Design

The full design lives in [`PLAN.md`](./PLAN.md): types, semantic rules,
testing strategy, signal model, job model, and more.

The grammar engine is [nexus](https://github.com/shreeve/nexus).
`slash.grammar` and `src/slash.zig` are the language-specific inputs;
`src/parser.zig` is generated from them.

## Build

Requires **Zig 0.16.0**.

```sh
zig build                                # build ./bin/slash
zig build run -- --version               # show version
zig build test                           # run all tests
zig build run -- -c 'echo hello'         # run a one-liner
zig build run -- script.sh arg1 arg2     # run a script
```

## License

MIT
