# Slash — Roadmap to Complete

This file lists every concrete unit of work that stands between Slash today
and Slash 1.0. As items ship, **delete them from this file**. When the
file is empty, Slash 1.0 ships.

Items are flat bullets — no numbering, ship in whichever order makes
sense. As items ship, **delete the bullet** in the same commit; the
ROADMAP shrinks until empty.

> **The test that decides whether anything joins this list:**
> Does this improve `Command` clarity, `Pipeline` correctness, `Program`
> composability, or `Job` control? If not, do not build it. (PLAN §14)

---

## Done means done

When this file is empty, Slash 1.0 ships:
- A real Unix shell, not a toy
- Usable as the daily driver for new shell work
- Pleasant to live in interactively
- Mechanically correct in the places shells historically lie
- Inspectable end-to-end, from source byte to job exit

We don't need to support old bash scripts. We need to be the better
choice for new ones. That's the bar.
