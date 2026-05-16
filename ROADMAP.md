# Slash — Roadmap

This file lists every concrete unit of work that stands between Slash
today and the next release. As items ship, **delete them from this
file** in the same commit. The ROADMAP shrinks until empty; that's how
the next release ships.

The roadmap is empty. Every interactive-UX item the previous release
target depended on has shipped. See `HANDOFF.md` for the running list
of what landed and `VALIDATION.md` for the empirical record.

> **The test that decides whether anything joins this list:**
> Does this improve `Command` clarity, `Pipeline` correctness, `Program`
> composability, or `Job` control? If not, do not build it. (PLAN §14)

---

## Done means done

When this file is empty, the next Slash release ships:
- A real Unix shell, not a toy
- Usable as the daily driver for new shell work
- Pleasant to live in interactively (fish-class UX)
- Mechanically correct in the places shells historically lie
- Inspectable end-to-end, from source byte to job exit

We don't need to support old bash scripts. We need to be the better
choice for new ones. That's the bar.
