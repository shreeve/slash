# Pitch

## One-Sentence Pitch

Slash is a small, fast, grammar-driven shell for people who want the Unix shell
to do shell things extremely well, without legacy weirdness, plugin tax, or
turning the shell into a programming language.

## The Problem

Most developers do not actually love their shell. They tolerate it.

`zsh` is powerful, but much of what people like about using it does not come
from `zsh` itself. It comes from a pile of extras: prompt themes, completion
systems, syntax highlighting, history tools, fuzzy jumping, keybinding helpers,
and personal dotfile frameworks. The result is familiar, but also fragile:

- too much setup for a good everyday experience
- too much historical syntax and too many edge cases
- too much behavior learned by folklore instead of design
- too much shell language baggage for tasks that should be simple

That is the gap Slash exists to close.

## Why Slash Should Exist

Slash is not trying to out-ecosystem `zsh`, out-script-compatibility `bash`, or
out-language Nushell. It exists for a narrower and more important reason:

**the interactive Unix shell should feel complete without needing to be
assembled.**

The promise is simple:

- install it
- start using it
- get a polished shell immediately
- define commands, key bindings, and settings simply
- stay focused on running programs, composing pipelines, and moving on

That is a real product, not just a language experiment.

## The Core Thesis

The best reason to use Slash is not that it does more than `zsh`.

The best reason is that it should require less.

Less configuration.
Less syntax trivia.
Less plugin machinery.
Less shell folklore.
Less time fighting your environment.

The value is not "more features." The value is "nothing extra needed."

## What Slash Offers

Slash should be compelling because it combines five things that are usually
scattered across shell defaults, plugins, and dotfiles:

### 1. A shell, not a platform

Slash is intentionally a shell. It runs commands, connects programs with pipes,
handles redirects, manages jobs, navigates directories, and gets out of the
way. When you need real programming, call Python, Zig, Ruby, awk, jq, or
whatever else fits the job.

That constraint is a strength. It keeps the shell understandable.

### 2. A cleaner mental model

Shells should not feel like a museum of historical accidents. Slash is built
around a formal grammar and one coherent execution model, so the language can be
explained instead of merely memorized.

The goal is not novelty. The goal is confidence.

### 3. A complete default experience

Prompt, history, navigation, completion, highlighting, key bindings, and shell
configuration should feel built in, not bolted on.

A user should not need to build a mini-distribution in their dotfiles just to
get a decent shell.

### 4. Small, fast, lightweight behavior

The shell should start quickly, stay out of the way, and do the obvious thing
without drama. Slash should feel closer to a sharp Unix tool than a framework.

This matters. A shell is something people touch all day.

### 5. Simple extension where it matters

Most users do not need a plugin system. They need a frictionless way to define:

- `cmd`s for common tasks
- key bindings for repeated flows
- `set`-style configuration for shell behavior

That is enough power for most real shell customization without dragging in a
full package ecosystem.

## What `zsh` Is Failing On

`zsh` is not failing in the sense that it is bad software. It is failing in the
sense that it is an evolved artifact rather than a deliberate modern design.

Its weaknesses are structural:

- a great experience usually depends on additional tools and configuration
- the language carries decades of quoting, expansion, and parsing baggage
- shell quality is often proportional to how much dotfile engineering the user
  has done
- many workflows feel "possible" rather than "clean"

For power users, this is manageable. For everyone else, it is unnecessary drag.

## The Compelling Pain Point

If Slash solves one problem dramatically better than existing shells, it should
be this:

**the modern shell experience is too customized, too fragile, and too weird for
how central it is to daily work.**

People want:

- a shell that feels polished on day one
- a shell they can reason about
- a shell that does not need a plugin stack
- a shell that stays focused on shell work

If Slash delivers that, it has a real reason to exist.

## What We Should Do

If we add anything, it should sharpen the core promise rather than widen scope.

The highest-value work is:

- make the default interactive experience excellent
- make `cmd`, `key`, and `set` feel discoverable and effortless
- make parsing and execution behavior unsurprising and consistent
- make job control, completion, history, navigation, and prompt behavior rock
  solid
- make startup and interactivity feel fast and lightweight
- make docs and examples show that common shell tasks are clearer in Slash than
  in `zsh`

In other words: polish, harden, simplify.

## What We Should Not Add

The easiest way to ruin this pitch is to chase breadth.

We should be very skeptical of:

- a plugin marketplace
- a giant extension API
- turning the shell into a general-purpose language runtime
- adding features whose main purpose is to mimic other shells
- complexity that weakens the "small, fast, complete by default" story

The product gets stronger when the answer to "what else do I need?" is
"probably nothing."

## The Positioning

Slash is for people who want:

- the Unix shell model
- a clean and coherent language
- a polished interactive experience by default
- lightweight customization without framework overhead
- a shell that disappears when they are trying to work

It is not for people who primarily want maximum compatibility with existing
Bash or `zsh` scripts. That is fine. Those tools already exist.

## The Line To Remember

Slash should be the shell you install when you want a shell, not a shell plus a
project.
