<p align="center">
  <img src="docs/assets/slash-1280w.png" alt="Slash" width="500">
</p>

<div align="center">
  <strong>A modern Unix shell with a precise model for commands, pipelines, and jobs.</strong>
</div>

---

## What is Slash?

Slash is a modern Unix shell written in Zig. It parses each line into a
`Shape`, lowers it into a `Program`, and runs it as a `Job` you can inspect
and control. One grammar drives parsing, highlighting, completion, and
formatting. `argv` is never flattened to a string. Pipelines are structured.
Job control is first-class. There is no `set -e` magic, no implicit
word-splitting, no hidden coercion.

Slash runs programs. It does not try to be a language.

## Design

The full design lives in [`PLAN.md`](./PLAN.md). It is the single source of
truth — types, semantic rules, testing strategy, signal model, and more.
Read it before contributing.

The grammar engine is [nexus](https://github.com/shreeve/nexus); `slash.grammar`
and `src/slash.zig` are the language-specific inputs, and `src/parser.zig` is
generated from them.

## Build

Requires **Zig 0.16.0**.

```sh
zig build                    # build ./bin/slash
zig build run -- --version   # run
zig build test               # run tests
```

## Status

Phase 1 of the implementation plan is in progress (see `PLAN.md` §9). The
binary currently prints its version. The parser, shape, program, and
evaluation layers are being built next, one commit at a time.

## License

MIT
