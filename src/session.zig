//! Session — long-lived shell state.

const std = @import("std");
const job = @import("job.zig");
const builtins = @import("builtins.zig");
const runtime = @import("runtime.zig");
const vars = @import("vars.zig");
const program_mod = @import("program.zig");
const history_mod = @import("history.zig");
const keybinding = @import("keybinding.zig");
const keyboards = @import("keyboards.zig");

pub const Allocator = std.mem.Allocator;

// libc bindings — Zig 0.16's `std.c` doesn't expose `getpgrp`/`getpgid`,
// but they're standard POSIX. Declare directly.
extern "c" fn getpgrp() std.c.pid_t;

pub const ProcSubEntry = struct {
    /// Fd open in the parent process pointing at the pipe end the
    /// exec'd child inherits via `/dev/fd/N`. Always strip
    /// `FD_CLOEXEC` before recording so the inherit works.
    parent_fd: i32,
    /// Pid of the forked side child running the `<(prog)` /
    /// `>(prog)` body. Reaped at the next `drainProcSubs` cadence.
    pid: i32,
    /// True once `drainProcSubs` has closed `parent_fd`. A retry
    /// pass on an unreaped survivor must NOT re-close (would
    /// double-close, possibly the wrong fd if it was recycled).
    closed: bool = false,
};

/// Tabulated signals supported by `trap`. The values are sequential
/// (0..N) because the trap table indexes by `@intFromEnum`; the mapping
/// to POSIX signal numbers lives in `builtins.sigToCSig`.
pub const TrapSignal = enum(u8) {
    EXIT, // pseudo-signal: runs at shell exit
    HUP,
    INT,
    QUIT,
    TERM,
    USR1,
    USR2,
};

pub const TrapDispo = union(enum) {
    default,
    ignore,
    run: TrapEntry,

    pub const TrapEntry = struct {
        arena: std.heap.ArenaAllocator,
        program: *const program_mod.Program,
    };
};

/// Per-session signal trap registry. Each slot holds either the default
/// disposition, an "ignore" marker, or a session-scoped Program parsed
/// from the registered source string. Real signals (everything except
/// EXIT) also have a `pending` flag set by the async-signal-safe handler;
/// the eval layer drains the flag at safe points and runs the trap.
pub const TrapTable = struct {
    alloc: Allocator,
    /// Indexed by the TrapSignal enum value (offset zero is EXIT).
    dispo: [num_slots]TrapDispo,
    /// Set by the signal handler; read at safe points.
    pending: [num_slots]bool,

    pub const num_slots: usize = @typeInfo(TrapSignal).@"enum".fields.len;

    pub fn init(alloc: Allocator) TrapTable {
        var t: TrapTable = .{
            .alloc = alloc,
            .dispo = undefined,
            .pending = [_]bool{false} ** num_slots,
        };
        for (&t.dispo) |*slot| slot.* = .default;
        return t;
    }

    pub fn deinit(self: *TrapTable) void {
        for (&self.dispo) |*slot| switch (slot.*) {
            .run => |*entry| entry.arena.deinit(),
            else => {},
        };
    }

    pub fn parseSignal(name: []const u8) ?TrapSignal {
        if (std.mem.eql(u8, name, "EXIT")) return .EXIT;
        if (std.mem.eql(u8, name, "HUP")) return .HUP;
        if (std.mem.eql(u8, name, "INT")) return .INT;
        if (std.mem.eql(u8, name, "QUIT")) return .QUIT;
        if (std.mem.eql(u8, name, "TERM")) return .TERM;
        if (std.mem.eql(u8, name, "USR1")) return .USR1;
        if (std.mem.eql(u8, name, "USR2")) return .USR2;
        return null;
    }

    pub fn setIgnore(self: *TrapTable, sig: TrapSignal) void {
        self.clearSlot(sig);
        self.dispo[@intFromEnum(sig)] = .ignore;
    }

    pub fn setDefault(self: *TrapTable, sig: TrapSignal) void {
        self.clearSlot(sig);
        self.dispo[@intFromEnum(sig)] = .default;
    }

    pub fn setRun(
        self: *TrapTable,
        sig: TrapSignal,
        arena: std.heap.ArenaAllocator,
        program: *const program_mod.Program,
    ) void {
        self.clearSlot(sig);
        self.dispo[@intFromEnum(sig)] = .{ .run = .{ .arena = arena, .program = program } };
    }

    pub fn lookup(self: *const TrapTable, sig: TrapSignal) TrapDispo {
        return self.dispo[@intFromEnum(sig)];
    }

    pub fn markPending(self: *TrapTable, sig: TrapSignal) void {
        self.pending[@intFromEnum(sig)] = true;
    }

    pub fn takePending(self: *TrapTable, sig: TrapSignal) bool {
        const idx = @intFromEnum(sig);
        const was = self.pending[idx];
        self.pending[idx] = false;
        return was;
    }

    fn clearSlot(self: *TrapTable, sig: TrapSignal) void {
        const idx = @intFromEnum(sig);
        switch (self.dispo[idx]) {
            .run => |*entry| entry.arena.deinit(),
            else => {},
        }
    }
};

/// Store for user-defined `cmd` bodies. Both keys (definition names) and
/// values (lowered Programs) live in the entry's own arena so the
/// definition outlives the originating parse.
pub const DefStore = struct {
    alloc: Allocator,
    table: std.StringHashMapUnmanaged(*Entry) = .empty,

    pub const Entry = struct {
        arena: std.heap.ArenaAllocator,
        program: *const program_mod.Program,
    };

    pub fn init(alloc: Allocator) DefStore {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *DefStore) void {
        var it = self.table.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            e.value_ptr.*.arena.deinit();
            self.alloc.destroy(e.value_ptr.*);
        }
        self.table.deinit(self.alloc);
    }

    pub fn lookup(self: *const DefStore, name: []const u8) ?*const program_mod.Program {
        if (self.table.get(name)) |entry| return entry.program;
        return null;
    }

    /// Install a definition. The caller passes a freshly initialized
    /// arena and the lowered Program allocated from it. Ownership of
    /// the arena transfers to the store; on key replacement the old
    /// entry's arena is destroyed.
    pub fn install(
        self: *DefStore,
        name: []const u8,
        arena: std.heap.ArenaAllocator,
        program: *const program_mod.Program,
    ) !void {
        const key = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(key);

        const entry = try self.alloc.create(Entry);
        errdefer self.alloc.destroy(entry);
        entry.* = .{ .arena = arena, .program = program };

        const gop = try self.table.getOrPut(self.alloc, key);
        if (gop.found_existing) {
            self.alloc.free(key);
            gop.value_ptr.*.arena.deinit();
            self.alloc.destroy(gop.value_ptr.*);
        }
        gop.value_ptr.* = entry;
    }
};

/// Editor-only literal-text rewrites (PLAN §12). Keys are LHS names
/// typed at the prompt; values are RHS bytes inserted verbatim before
/// parsing. The shell itself never expands `str` entries — the REPL's
/// keystroke handler does, and only at the keystroke moment.
///
/// Empty values are a real, distinct stored state — they cause the
/// candidate to be deleted from the buffer when triggered. Distinct
/// from "name is unset," which inserts a literal space (no-op).
///
/// Both LHS and RHS are owned by `alloc`. The set of legal LHS bytes
/// is enforced at the call site (the `str` builtin, and the `str_def`
/// keyword form's lexer wrapper); this table is a passive store that
/// takes whatever passes that gate.
pub const StrTable = struct {
    alloc: Allocator,
    table: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(alloc: Allocator) StrTable {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *StrTable) void {
        var it = self.table.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.table.deinit(self.alloc);
    }

    /// Install a `str`. Replaces any existing entry under the same
    /// name. Both `name` and `value` are dup'd; the caller owns the
    /// input slices. An empty `value` is allowed (and meaningful —
    /// see the type comment).
    pub fn set(self: *StrTable, name: []const u8, value: []const u8) !void {
        const key = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(key);
        const val = try self.alloc.dupe(u8, value);
        errdefer self.alloc.free(val);

        const gop = try self.table.getOrPut(self.alloc, key);
        if (gop.found_existing) {
            self.alloc.free(key);
            self.alloc.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = val;
    }

    /// Remove a `str`. Returns true iff something was removed. Callers
    /// that want idempotent erase semantics ignore the return value.
    pub fn unset(self: *StrTable, name: []const u8) bool {
        const kv = self.table.fetchRemove(name) orelse return false;
        self.alloc.free(kv.key);
        self.alloc.free(kv.value);
        return true;
    }

    pub fn lookup(self: *const StrTable, name: []const u8) ?[]const u8 {
        return self.table.get(name);
    }

    pub fn count(self: *const StrTable) usize {
        return self.table.count();
    }

    /// Allocate and return name pointers in lexicographic order,
    /// borrowed from the table (caller must not free entries; caller
    /// frees the slice itself with the supplied allocator). Used for
    /// deterministic listing in the `str` builtin and tests.
    pub fn sortedNames(self: *const StrTable, alloc: Allocator) ![][]const u8 {
        const n = self.table.count();
        var names = try alloc.alloc([]const u8, n);
        errdefer alloc.free(names);
        var it = self.table.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) names[i] = k.*;
        std.mem.sort([]const u8, names, {}, lessByName);
        return names;
    }

    fn lessByName(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
};

pub const Session = struct {
    alloc: Allocator,
    jobs: job.JobTable,
    builtins: builtins.BuiltinSet,
    vars: vars.VarStore,
    defs: DefStore,
    strs: StrTable,
    traps: TrapTable,
    /// Optional persistent history index. Owned by the session;
    /// `null` in non-interactive entry points (`-c`, scripts).
    /// Captures every accepted line with cwd / timestamp / exit
    /// status / duration, persists as JSONL under XDG. The substrate
    /// for the `history` builtin and (eventually) smart Up/Down
    /// navigation + autosuggestions.
    history: ?history_mod.HistoryIndex = null,
    /// Inherited environment as a raw `execve`-ready pointer. Threaded
    /// from `std.c.environ` in `main`; not owned by Session.
    envp: [*:null]const ?[*:0]const u8,
    interactive: bool,
    default_pipefail: bool,
    /// Set by builtin `exit`. The `runForeground` caller (typically `main`)
    /// observes this after evaluation completes and may terminate the shell
    /// with the requested result.
    exit_request: ?runtime.Result,
    /// Last command's exit status (for `$?`).
    last_status: u8,
    /// Typed result of the last top-level command. `null` until the
    /// first command runs. Carries the same information as
    /// `last_status` plus the exited/signaled distinction, which the
    /// status-byte form can't preserve (a process that runs `exit 130`
    /// is byte-equivalent to one killed by SIGINT, but only the typed
    /// form lets us label it correctly in the pre-prompt notice).
    last_result: ?runtime.Result = null,
    /// True iff `last_status` was set by a command that hasn't yet
    /// surfaced in a pre-prompt notice. The notice helper checks
    /// this once per prompt and clears the flag, so the
    /// `slash: exit N` line appears immediately after a failure but
    /// not on every subsequent prompt while `$?` remains non-zero.
    status_pending: bool = false,
    /// PID of the most recently launched background job (for `$!`).
    /// `null` until at least one bg job has started in the session.
    last_bg_pid: ?std.c.pid_t = null,
    /// Set by the SIGCHLD handler; consumed at safe points by
    /// `eval.drainChildEvents`. PLAN §19: the handler is minimal and
    /// async-signal-safe — it sets this flag and pokes zigline's
    /// signal pipe to wake any blocked editor read. The actual
    /// reaping happens later, in shell context.
    child_event_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// File descriptor referring to the controlling tty when slash is
    /// interactive and stderr is a terminal. `null` in non-interactive
    /// or piped contexts. Used for `tcsetpgrp` handoff around foreground
    /// jobs (PLAN §18 / §11 must-get-right "terminal control"). Owned
    /// by the session: `dup`d at init, `close`d at deinit.
    controlling_tty_fd: ?std.c.fd_t = null,
    /// Process group id of the shell process. Captured at init via
    /// `getpgrp()`; restored as the controlling-tty's foreground pgrp
    /// after every foreground job completes or stops.
    shell_pgid: std.c.pid_t = 0,
    /// Snapshot of the shell's terminal modes (line discipline, echo
    /// settings, etc.) taken at interactive bootstrap. Restored onto
    /// the controlling tty after every foreground job stops or exits
    /// so programs that scribbled on termios (vim, less, stty raw,
    /// Python REPL) don't leave Slash in a broken terminal state.
    /// `null` in non-interactive shapes.
    shell_termios: ?std.posix.termios = null,
    /// Process-substitution side children whose pipe ends the parent
    /// is holding open until the foreground command exits. Each
    /// entry's fd is closed and its child reaped at the next safe
    /// point (typically right after the foreground job completes, or
    /// in `Session.deinit` for any stragglers).
    proc_subs: std.ArrayListUnmanaged(ProcSubEntry) = .empty,
    /// User-configurable key bindings (the `key` builtin). The
    /// keymap adapter in `repl.zig` consults this table before
    /// falling through to zigline's default emacs lookup, so user
    /// bindings always win on conflict. Initialized to a real
    /// `Table` in `Session.init`; `undefined` here only because
    /// the struct's literal initializer can't call `init`.
    keybindings: keybinding.Table = undefined,
    /// Slot for a literal-text binding's payload while the editor
    /// dispatches it. The keymap lookup runs first (knows the
    /// `KeyEvent`), stashes the literal bytes here, and returns
    /// `Action{ .custom = dispatch_user_literal }`; the custom-
    /// action hook (which has no `KeyEvent` parameter) reads back
    /// from this slot and emits the actual insert + accept. Slice
    /// is borrowed from the binding's `BindingTarget.literal`;
    /// never freed via this pointer.
    user_literal_pending: ?[]const u8 = null,
    /// Active keyboard layout for the macOS-Option-key reverse-
    /// resolution path in `slashKeymapLookup`. When a multi-byte
    /// compose char arrives (e.g. `¬` from Option+L without
    /// "Use Option as Meta"), the lookup consults this layout's
    /// `composeToOptionLetter` to derive the Alt-letter chord
    /// the user actually meant. Default: US-QWERTY; future
    /// non-US layouts plug in via `$SLASH_KEYBOARD`.
    keyboard_layout: *const keyboards.Layout = &keyboards.us_qwerty,
    /// PATH lookup memoization. Keys and values are owned by `alloc`.
    /// `path_cache_signature` is a dup'd snapshot of `$PATH` at the time
    /// the cache was last validated; on mismatch the cache is dropped
    /// before any lookup.
    path_cache: std.StringHashMapUnmanaged([]const u8) = .empty,
    path_cache_signature: ?[]const u8 = null,

    pub fn init(
        alloc: Allocator,
        envp: [*:null]const ?[*:0]const u8,
        interactive: bool,
    ) !Session {
        // Capture the shell's pgid up-front. The interactive bootstrap
        // (see `repl.bootstrapInteractive`) may install a different pgid
        // and update `shell_pgid` accordingly; non-interactive entry
        // points just keep whatever the launcher gave us.
        const shell_pgid = getpgrp();

        return .{
            .alloc = alloc,
            .jobs = job.JobTable.init(alloc),
            .builtins = try builtins.init(alloc),
            .vars = vars.VarStore.init(alloc),
            .defs = DefStore.init(alloc),
            .strs = StrTable.init(alloc),
            .keybindings = keybinding.Table.init(alloc),
            .traps = TrapTable.init(alloc),
            .envp = envp,
            .interactive = interactive,
            .default_pipefail = true,
            .exit_request = null,
            .last_status = 0,
            .last_bg_pid = null,
            .controlling_tty_fd = null,
            .shell_pgid = shell_pgid,
        };
    }

    pub fn deinit(self: *Session) void {
        // Use the escalating-reap path here. A typical shell exit
        // path has already flushed proc_subs via per-command
        // `drainProcSubs` calls; this catches the rare case where
        // a side child outlived its parent command (slow flusher,
        // misbehaved reader). SIGTERM + blocking wait beats
        // shipping zombies up to init.
        self.drainProcSubsAtExit();
        self.proc_subs.deinit(self.alloc);
        self.keybindings.deinit();
        self.jobs.deinit();
        self.builtins.deinit(self.alloc);
        self.vars.deinit();
        self.defs.deinit();
        self.strs.deinit();
        self.traps.deinit();
        if (self.history) |*h| h.deinit();
        self.clearPathCache();
        self.path_cache.deinit(self.alloc);
        if (self.path_cache_signature) |sig| self.alloc.free(sig);
        if (self.controlling_tty_fd) |fd| _ = std.c.close(fd);
    }

    /// Close every pending proc-sub fd and reap the side children.
    /// Closing the parent's end is what lets a `>(...)` reader see
    /// EOF, so this is called right after the foreground job for a
    /// command finishes (PLAN §7 Rule 25).
    ///
    /// Two-pass reap. Most side children are dead by the time we get
    /// here — the parent-side close above either:
    ///
    ///   - delivers SIGPIPE to a `<(prog)` writer that's still
    ///     trying to push bytes (default action: terminate), or
    ///   - delivers EOF to a `>(prog)` reader that then exits its
    ///     read loop naturally.
    ///
    /// `WNOHANG` catches the common path. The retry list survives
    /// the call: any child still alive (e.g. a `>(slow-flush)` that
    /// hasn't finished its post-EOF cleanup yet) gets re-attempted
    /// at the next `drainProcSubs` (called once per foreground
    /// command + once at session teardown). Without this, an
    /// unreaped child becomes a zombie that lives until the slash
    /// process itself exits — a slow fd/PID leak in long sessions
    /// that lean on `<(...)` / `>(...)` heavily.
    ///
    /// At session teardown the leftover list gets a SIGTERM nudge
    /// and a blocking wait via `drainProcSubsAtExit` so we don't
    /// ship zombies up to init.
    pub fn drainProcSubs(self: *Session) void {
        // In-place compaction. No allocation in the reaper path:
        // an OOM here would silently drop tracking and re-introduce
        // the zombie leak the audit just fixed.
        var write_idx: usize = 0;
        for (self.proc_subs.items) |entry_in| {
            var entry = entry_in;
            if (!entry.closed) {
                _ = std.c.close(entry.parent_fd);
                entry.closed = true;
            }
            var status: c_int = 0;
            const rc = std.c.waitpid(entry.pid, &status, std.c.W.NOHANG);
            if (rc == entry.pid) {
                // Reaped cleanly — drop.
                continue;
            }
            if (rc == 0) {
                // Still alive — retain for the next reap pass.
                self.proc_subs.items[write_idx] = entry;
                write_idx += 1;
                continue;
            }
            // rc < 0 (and notionally also rc > 0 with a different pid,
            // which POSIX says can't happen for a non-`-1` first arg).
            // Inspect errno:
            //   - EINTR: signal interrupted us; retain and retry next pass.
            //   - ECHILD: child already gone (someone else reaped it, or
            //     it never existed) — DROP. Critically: we must NOT
            //     keep this entry around because a later `SIGTERM`/
            //     `SIGKILL` pass would signal a recycled PID and could
            //     murder an unrelated process.
            //   - other: treat as fatal-to-this-entry; drop.
            const err = std.c.errno(rc);
            if (err == .INTR) {
                self.proc_subs.items[write_idx] = entry;
                write_idx += 1;
            }
            // ECHILD or anything else: fall through to drop.
        }
        self.proc_subs.shrinkRetainingCapacity(write_idx);
    }

    /// Final reap pass at session teardown. Four-phase escalation:
    ///
    ///   1. `drainProcSubs` (WNOHANG) catches the typical case.
    ///   2. Poll-grace window (100ms) — well-behaved post-EOF
    ///      children flush + exit naturally inside this window
    ///      (e.g. `>(wc -c)` reading EOF, writing its byte count,
    ///      exiting).
    ///   3. SIGTERM survivors, then a SECOND poll-grace (100ms)
    ///      for the polite-shutdown path to complete.
    ///   4. SIGKILL anyone STILL alive, then blocking `waitpid`
    ///      with EINTR retry. SIGKILL is unmaskable so the wait
    ///      can't wedge indefinitely.
    ///
    /// Bounded total: ~200ms grace + the kernel's SIGKILL delivery
    /// + blocking wait for an unmaskable death. Slash never hangs
    /// forever on session teardown, no matter what a hostile or
    /// buggy side child does. Data loss for SIGKILL'd processes is
    /// the price; the alternative is wedging the shell on exit.
    pub fn drainProcSubsAtExit(self: *Session) void {
        self.drainProcSubs();
        if (self.proc_subs.items.len == 0) return;

        // Phase 2: short polling grace window. Each pass reaps
        // anything that has exited since the previous one.
        graceReap(self, 100, 5);
        if (self.proc_subs.items.len == 0) return;

        // Phase 3: polite termination.
        for (self.proc_subs.items) |entry| {
            _ = std.c.kill(entry.pid, std.c.SIG.TERM);
        }
        graceReap(self, 100, 5);
        if (self.proc_subs.items.len == 0) return;

        // Phase 4: SIGKILL + EINTR-safe blocking wait. SIGKILL is
        // unblockable, so each `waitpid` reaps within a kernel
        // tick. The EINTR retry guards against SIGCHLD (delivered
        // when the kill takes effect) interrupting the wait.
        for (self.proc_subs.items) |entry| {
            _ = std.c.kill(entry.pid, std.c.SIG.KILL);
        }
        for (self.proc_subs.items) |entry| {
            while (true) {
                var status: c_int = 0;
                const rc = std.c.waitpid(entry.pid, &status, 0);
                if (rc == entry.pid) break;
                if (rc < 0) {
                    const err = std.c.errno(rc);
                    if (err == .INTR) continue;
                    break; // ECHILD or unexpected — give up on this one
                }
                break;
            }
        }
        self.proc_subs.shrinkRetainingCapacity(0);
    }

    fn graceReap(self: *Session, total_ms: u32, step_ms: u32) void {
        var elapsed: u32 = 0;
        while (elapsed < total_ms and self.proc_subs.items.len > 0) {
            var pfd: std.c.pollfd = .{ .fd = -1, .events = 0, .revents = 0 };
            _ = std.c.poll(@ptrCast(&pfd), 0, @intCast(step_ms));
            elapsed += step_ms;
            self.drainProcSubs();
        }
    }

    /// Free every cached entry but leave the table allocated.
    pub fn clearPathCache(self: *Session) void {
        var it = self.path_cache.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.path_cache.clearRetainingCapacity();
    }

    /// Drop the cache if `$PATH` has changed since the last validation.
    /// Returns the live `$PATH` slice (or `null` if PATH is unset). The
    /// returned slice is borrowed from the C runtime and is only valid
    /// until the next env mutation.
    pub fn refreshPathSignature(self: *Session) ?[]const u8 {
        const env = std.c.getenv("PATH") orelse {
            if (self.path_cache_signature != null) {
                self.alloc.free(self.path_cache_signature.?);
                self.path_cache_signature = null;
                self.clearPathCache();
            }
            return null;
        };
        const live = std.mem.span(env);
        if (self.path_cache_signature) |sig| {
            if (std.mem.eql(u8, sig, live)) return live;
            self.alloc.free(sig);
            self.path_cache_signature = null;
            self.clearPathCache();
        }
        const dup = self.alloc.dupe(u8, live) catch return live;
        self.path_cache_signature = dup;
        return live;
    }

    /// Read a variable as a single string (joining lists with space).
    /// Returns null if undefined.
    pub fn varString(self: *const Session, name: []const u8, alloc: Allocator) !?[]u8 {
        if (self.vars.get(name)) |v| {
            return switch (v.value) {
                .scalar => |s| try alloc.dupe(u8, s),
                .list => |xs| try std.mem.join(alloc, " ", xs),
            };
        }
        return null;
    }
};
