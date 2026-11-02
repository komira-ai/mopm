//! One test process under supervision: the platform half of `mopm test`
//! (Linux and macOS; nothing here is used on another OS).
//!
//! `run` starts `argv` in a process group of its own (the test process is
//! the group leader, so the group id is its pid), with stdin from /dev/null
//! and stdout and stderr each to a file. Then, every `poll_ns`, it reaps the
//! process if it ended, and otherwise samples it:
//!
//!   * CPU time (user + system) of the test process: Linux
//!     /proc/<pid>/stat, macOS proc_pid_rusage;
//!   * resident size: Linux /proc/<pid>/status VmRSS, macOS
//!     proc_pid_rusage's physical footprint (what the macOS memory limiter
//!     itself counts).
//!
//! Past the deadline it kills the whole group with SIGKILL and records the
//! liveness: `hung` when the test process used less than 5% of one CPU over
//! the last `window` before the deadline (window = min(1 s, deadline / 2)),
//! `slow` when it was still computing, `unknown` when no CPU sample could be
//! read. Past the memory cap (a sample above it) it kills the group too and
//! records `oom`. The cap is a sampled limit, not an rlimit: a spike shorter
//! than one poll can pass it, and only the test process itself is measured,
//! not processes it starts. (RLIMIT_AS would also refuse address space the
//! Mojo runtime reserves but never touches; macOS does not enforce RLIMIT_AS
//! or RLIMIT_RSS at all.)
//!
//! After the test process ends for any reason, the group is killed again,
//! so a process the test started and left behind does not outlive the test,
//! and then `run` checks for up to two seconds that the group is empty;
//! `leftover` says it was not. `Limits.kill_group = false` is a test-only
//! switch (the supervisor self-test): it signals only the test process and
//! skips the final kill, so a process the test started survives, and
//! `leftover` must report it.

const std = @import("std");
const builtin = @import("builtin");
const child_env = @import("child_env.zig");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const is_darwin = builtin.os.tag.isDarwin();

pub const Limits = struct {
    deadline_ns: u64,
    /// Kill when the sampled resident size passes this many bytes; null:
    /// no cap.
    memory_bytes: ?u64 = null,
    /// Test-only: false signals only the test process (never its group) and
    /// skips the final group kill. See the file comment.
    kill_group: bool = true,
    poll_ns: u64 = 20 * std.time.ns_per_ms,
    /// Test-only: the deadline counts from the first poll that finds this
    /// file, not from the start of the process. A test that signals "I am
    /// ready" this way (the memory fixture, once it has touched its memory
    /// and before it sleeps) gets a deadline that does not race its setup.
    /// Until the file exists nothing times out. Null: from the start.
    ready_file: ?[]const u8 = null,
    /// Test seams; null is the real thing (a monotonic timer started at the
    /// fork, a real sleep, /proc or proc_pid_rusage).
    clock: ?Clock = null,
    sampler: ?Sampler = null,
};

/// What a sleep inside `run` is for.
pub const Wait = union(enum) {
    /// Between two looks at the test process.
    poll,
    /// Between two looks at whether process group `drain` is empty.
    drain: posix.pid_t,
};

/// The time `run` reads and spends. `now_fn` is nanoseconds since `run`
/// started; `sleep_fn` waits about that long. A test passes a manual clock
/// whose sleep advances its time, so a deadline is crossed by counting polls.
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    now_fn: *const fn (ctx: ?*anyopaque) u64,
    sleep_fn: *const fn (ctx: ?*anyopaque, ns: u64, wait: Wait) void,

    fn now(c: Clock) u64 {
        return c.now_fn(c.ctx);
    }

    fn sleep(c: Clock, ns: u64, wait: Wait) void {
        c.sleep_fn(c.ctx, ns, wait);
    }
};

/// Where CPU time and resident size of the test process come from.
pub const Sampler = struct {
    ctx: ?*anyopaque = null,
    sample_fn: *const fn (ctx: ?*anyopaque, pid: posix.pid_t) Sample,
};

fn timerNow(ctx: ?*anyopaque) u64 {
    const t: *std.time.Timer = @ptrCast(@alignCast(ctx.?));
    return t.read();
}

fn realSleep(_: ?*anyopaque, ns: u64, _: Wait) void {
    std.time.sleep(ns);
}

pub const Liveness = enum { hung, slow, unknown };

pub const Term = union(enum) {
    exited: u8,
    signaled: u32,
};

pub const Result = struct {
    term: Term,
    wall_ns: u64,
    /// User + system CPU of the test process, from wait4.
    cpu_ns: u64,
    /// The largest sampled resident size, if any sample could be read.
    peak_rss: ?u64,
    /// Set when the deadline passed and mopm killed the group.
    timeout: ?Liveness = null,
    /// Set when the memory cap was passed and mopm killed the group.
    oom: bool = false,
    /// The process group still had a process two seconds after the test
    /// process ended (and mopm's final kill, unless kill_group is false).
    leftover: bool = false,
    pgid: posix.pid_t,
};

pub const Spawn = struct {
    argv: []const []const u8,
    /// The environment of the test; null: mopm's own.
    env: ?*const std.process.EnvMap = null,
    stdout_path: []const u8,
    stderr_path: []const u8,
};

// ---------------------------------------------------------------- platform

extern "c" fn setpgid(pid: c_int, pgid: c_int) c_int;
extern "c" fn getpid() c_int; // macOS only (Linux: std.os.linux.getpid), for the sample test
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *anyopaque) c_int;

/// <libproc.h> struct rusage_info_v0.
const RusageInfoV0 = extern struct {
    uuid: [16]u8,
    user_time: u64,
    system_time: u64,
    pkg_idle_wkups: u64,
    interrupt_wkups: u64,
    pageins: u64,
    wired_size: u64,
    resident_size: u64,
    phys_footprint: u64,
    proc_start_abstime: u64,
    proc_exit_abstime: u64,
};

/// In the forked child only: become the leader of a new process group.
fn ownGroup() void {
    if (is_darwin) {
        _ = setpgid(0, 0);
    } else {
        _ = std.os.linux.syscall2(.setpgid, 0, 0);
    }
}

/// In the parent: the same, from outside (whichever side runs first wins;
/// the other may fail harmlessly).
fn putInOwnGroup(pid: posix.pid_t) void {
    if (is_darwin) {
        _ = setpgid(pid, pid);
    } else {
        _ = std.os.linux.syscall2(.setpgid, @as(usize, @bitCast(@as(isize, pid))), @as(usize, @bitCast(@as(isize, pid))));
    }
}

fn childExit(code: u8) noreturn {
    if (is_darwin) std.c._exit(code);
    posix.exit(code);
}

pub const Sample = struct {
    cpu_ns: ?u64 = null,
    rss: ?u64 = null,
};

var timebase: ?std.c.mach_timebase_info_data = null;

/// CPU time and resident size of a live process, as far as they can be read.
pub fn sample(pid: posix.pid_t) Sample {
    if (is_darwin) {
        var info: RusageInfoV0 = undefined;
        if (proc_pid_rusage(pid, 0, &info) != 0) return .{};
        if (timebase == null) {
            var tb: std.c.mach_timebase_info_data = undefined;
            _ = std.c.mach_timebase_info(&tb);
            timebase = tb;
        }
        const tb = timebase.?;
        // ri_user_time and ri_system_time are Mach absolute time units.
        const ticks = info.user_time + info.system_time;
        const ns = if (tb.denom == 0) ticks else ticks / tb.denom * tb.numer + (ticks % tb.denom) * tb.numer / tb.denom;
        return .{ .cpu_ns = ns, .rss = info.phys_footprint };
    }
    var s: Sample = .{};
    var buf: [1024]u8 = undefined;
    var path_buf: [64]u8 = undefined;
    const stat_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return s;
    if (readSmall(stat_path, &buf)) |text| s.cpu_ns = parseProcStatCpu(text);
    var status_buf: [4096]u8 = undefined;
    const status_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return s;
    if (readSmall(status_path, &status_buf)) |text| s.rss = parseVmRss(text);
    return s;
}

fn readSmall(path: []const u8, buf: []u8) ?[]const u8 {
    const f = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer f.close();
    const n = f.readAll(buf) catch return null;
    return buf[0..n];
}

/// utime + stime of a /proc/<pid>/stat line, in nanoseconds (clock ticks of
/// 1/100 s, the USER_HZ every Linux architecture mopm runs on uses).
pub fn parseProcStatCpu(text: []const u8) ?u64 {
    // The command name (field 2) is in parentheses and may hold spaces.
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var it = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    var i: usize = 0;
    var utime: ?u64 = null;
    while (it.next()) |tok| : (i += 1) {
        // Fields after ')': state(3) ppid pgrp session tty_nr tpgid flags
        // minflt cminflt majflt cmajflt utime(14) stime(15).
        if (i == 11) utime = std.fmt.parseInt(u64, tok, 10) catch return null;
        if (i == 12) {
            const stime = std.fmt.parseInt(u64, tok, 10) catch return null;
            return (utime.? + stime) * (std.time.ns_per_s / 100);
        }
    }
    return null;
}

/// The VmRSS line of /proc/<pid>/status, in bytes.
pub fn parseVmRss(text: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l, "VmRSS:")) continue;
        var it = std.mem.tokenizeAny(u8, l["VmRSS:".len..], " \t");
        const n = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
        const unit = it.next() orelse return null;
        if (!std.mem.eql(u8, unit, "kB")) return null;
        return n * 1024;
    }
    return null;
}

/// Total physical memory, or null.
pub fn totalMemory() ?u64 {
    if (is_darwin) {
        var v: u64 = 0;
        var len: usize = @sizeOf(u64);
        posix.sysctlbynameZ("hw.memsize", &v, &len, null, 0) catch return null;
        return v;
    }
    return std.process.totalSystemMemory() catch null;
}

fn timevalNs(tv: anytype) u64 {
    const s: u64 = @intCast(@max(tv.tv_sec, 0));
    const us: u64 = @intCast(@max(tv.tv_usec, 0));
    return s * std.time.ns_per_s + us * std.time.ns_per_us;
}

fn signal(pid: posix.pid_t, sig: u8) void {
    posix.kill(pid, sig) catch {};
}

/// Whether process group `pgid` has any process.
fn groupAlive(pgid: posix.pid_t) bool {
    posix.kill(-pgid, 0) catch |e| return e != error.ProcessNotFound;
    return true;
}

// ---------------------------------------------------------------- run

/// Ring of recent CPU samples, enough to look back one window.
const Ring = struct {
    t: [128]u64 = undefined,
    cpu: [128]u64 = undefined,
    len: usize = 0,
    head: usize = 0,

    fn push(r: *Ring, t: u64, cpu: u64) void {
        r.t[r.head] = t;
        r.cpu[r.head] = cpu;
        r.head = (r.head + 1) % r.t.len;
        if (r.len < r.t.len) r.len += 1;
    }

    /// The oldest sample taken at or after `since`, else the oldest kept.
    fn from(r: *const Ring, since: u64) ?struct { t: u64, cpu: u64 } {
        if (r.len == 0) return null;
        var k: usize = 0;
        var best: ?usize = null;
        while (k < r.len) : (k += 1) {
            const idx = (r.head + r.t.len - r.len + k) % r.t.len;
            if (best == null) best = idx;
            if (r.t[idx] >= since) {
                best = idx;
                break;
            }
        }
        return .{ .t = r.t[best.?], .cpu = r.cpu[best.?] };
    }
};

/// Liveness from the CPU used between the window's first sample and now.
pub fn liveness(cpu_then: ?u64, cpu_now: ?u64, elapsed_ns: u64) Liveness {
    const a = cpu_then orelse return .unknown;
    const b = cpu_now orelse return .unknown;
    if (elapsed_ns == 0) return .unknown;
    const used = if (b > a) b - a else 0;
    // Less than 5% of one CPU over the window: not computing.
    return if (used * 20 < elapsed_ns) .hung else .slow;
}

pub fn run(arena: Allocator, s: Spawn, limits: Limits) !Result {
    // Everything the child needs is allocated before fork.
    const argv_z = try arena.allocSentinel(?[*:0]const u8, s.argv.len, null);
    for (s.argv, 0..) |a, i| argv_z[i] = (try arena.dupeZ(u8, a)).ptr;
    var own_env: std.process.EnvMap = undefined;
    const env_map: *const std.process.EnvMap = if (s.env) |e| e else blk: {
        own_env = try std.process.getEnvMap(arena);
        break :blk &own_env;
    };
    // The registry token is never handed to a test (child_env.zig), whether the environment is this process's or a caller's.
    var passed: usize = 0;
    {
        var count_it = env_map.iterator();
        while (count_it.next()) |kv| {
            if (!child_env.isScrubbed(kv.key_ptr.*)) passed += 1;
        }
    }
    const envp = try arena.allocSentinel(?[*:0]const u8, passed, null);
    {
        var it = env_map.iterator();
        var i: usize = 0;
        while (it.next()) |kv| {
            if (child_env.isScrubbed(kv.key_ptr.*)) continue;
            envp[i] = (try std.fmt.allocPrintZ(arena, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.* })).ptr;
            i += 1;
        }
    }
    const out = try std.fs.cwd().createFile(s.stdout_path, .{ .truncate = true });
    defer out.close();
    const err = try std.fs.cwd().createFile(s.stderr_path, .{ .truncate = true });
    defer err.close();
    const devnull = try std.fs.openFileAbsolute("/dev/null", .{});
    defer devnull.close();

    const window = @min(std.time.ns_per_s, limits.deadline_ns / 2);
    var timer = try std.time.Timer.start();
    const clock: Clock = limits.clock orelse .{ .ctx = &timer, .now_fn = timerNow, .sleep_fn = realSleep };
    const pid = try posix.fork();
    if (pid == 0) {
        ownGroup();
        posix.dup2(devnull.handle, 0) catch childExit(127);
        posix.dup2(out.handle, 1) catch childExit(127);
        posix.dup2(err.handle, 2) catch childExit(127);
        const e = posix.execveZ(argv_z[0].?, argv_z.ptr, envp.ptr);
        const msg = switch (e) {
            error.FileNotFound => "mopm test: the test binary does not exist\n",
            else => "mopm test: cannot execute the test binary\n",
        };
        _ = posix.write(2, msg) catch {};
        childExit(127);
    }
    putInOwnGroup(pid);

    var result = Result{ .term = .{ .exited = 0 }, .wall_ns = 0, .cpu_ns = 0, .peak_rss = null, .pgid = pid };
    var ring = Ring{};
    var killed = false;
    var ru: posix.rusage = undefined;
    var status: u32 = 0;
    // The time the deadline counts from: the start, or the first poll that finds the ready file.
    var origin: ?u64 = if (limits.ready_file == null) 0 else null;
    while (true) {
        const w = posix.wait4(pid, posix.W.NOHANG, &ru);
        if (w.pid == pid) {
            status = w.status;
            break;
        }
        const now = clock.now();
        if (!killed) {
            if (origin == null) {
                if (std.fs.cwd().access(limits.ready_file.?, .{})) |_| origin = now else |_| {}
            }
            const smp = if (limits.sampler) |sm| sm.sample_fn(sm.ctx, pid) else sample(pid);
            if (smp.rss) |r| result.peak_rss = @max(result.peak_rss orelse 0, r);
            if (smp.cpu_ns) |c| ring.push(now, c);
            if (limits.memory_bytes) |cap| {
                if (smp.rss) |r| {
                    if (r > cap) {
                        result.oom = true;
                        killed = true;
                    }
                }
            }
            if (!killed and origin != null and now - origin.? >= limits.deadline_ns) {
                const since = if (now > window) now - window else 0;
                const then = ring.from(since);
                result.timeout = if (then) |th| liveness(th.cpu, smp.cpu_ns, now - th.t) else .unknown;
                killed = true;
            }
            if (killed) signal(if (limits.kill_group) -pid else pid, posix.SIG.KILL);
        }
        clock.sleep(limits.poll_ns, .poll);
    }
    result.wall_ns = clock.now();
    result.cpu_ns = timevalNs(ru.utime) + timevalNs(ru.stime);
    if (posix.W.IFSIGNALED(status)) {
        result.term = .{ .signaled = posix.W.TERMSIG(status) };
    } else {
        result.term = .{ .exited = posix.W.EXITSTATUS(status) };
    }

    if (limits.kill_group) signal(-pid, posix.SIG.KILL);
    // A killed member is gone once its new parent reaps it; give that time.
    var waited: u64 = 0;
    while (groupAlive(pid) and waited < 2 * std.time.ns_per_s) : (waited += 20 * std.time.ns_per_ms) {
        clock.sleep(20 * std.time.ns_per_ms, .{ .drain = pid });
    }
    result.leftover = groupAlive(pid);
    return result;
}

/// "SIGSEGV" and the like, or null for a number this table does not name.
pub fn signalName(sig: u32) ?[]const u8 {
    const names = .{ "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE", "KILL", "USR1", "SEGV", "USR2", "PIPE", "ALRM", "TERM", "SYS", "XCPU", "XFSZ" };
    inline for (names) |n| {
        if (sig == @field(posix.SIG, n)) return "SIG" ++ n;
    }
    return null;
}

/// Kill whatever is left of a group (the self-test's cleanup).
pub fn killGroup(pgid: posix.pid_t) void {
    signal(-pgid, posix.SIG.KILL);
}

// ---------------------------------------------------------------- tests
//
// These run real processes (/bin/sh) on the CI hosts, so they prove the
// supervisor on Linux and macOS without Mojo: each would fail if the part it
// names were broken.

fn tmpPaths(a: Allocator, tmp: *std.testing.TmpDir) ![2][]const u8 {
    const dir = try tmp.dir.realpathAlloc(a, ".");
    return .{ try std.fs.path.join(a, &.{ dir, "out" }), try std.fs.path.join(a, &.{ dir, "err" }) };
}

const child_modes = [_]struct { script: []const u8, args: []const []const u8 }{
    .{ .script = "echo to-out; echo to-err >&2; exit 3", .args = &.{"out_err_exit3"} },
    .{ .script = "kill -SEGV $$", .args = &.{"segv"} },
    .{ .script = "kill -ABRT $$", .args = &.{"abrt"} },
    // A script that names "$1" is handed the path of a marker file, which it
    // creates once it is set up (see `Manual`).
    .{ .script = "touch \"$1\"; exec sleep 60", .args = &.{ "sleep", "60" } },
    .{ .script = "exec sleep 30", .args = &.{ "sleep", "30" } },
    .{ .script = "i=0; while [ $i -lt 200000 ]; do i=$((i+1)); done", .args = &.{"compute"} },
    .{ .script = "sleep 60 & touch \"$1\"; wait", .args = &.{"bg_sleep_wait"} },
    .{ .script = "sleep 60 & exit 0", .args = &.{"bg_sleep_exit0"} },
    .{ .script = "exit 0", .args = &.{"exit0"} },
    .{ .script = "exec 9>&-; read x <&8; exit 0", .args = &.{"wait_pipe"} },
};

/// The clock of these tests: time is a number that moves only when `run`
/// sleeps, by exactly the time it asked to sleep. So a deadline is crossed
/// after a counted number of polls, whatever the machine is doing, and what
/// `run` slept for is read back from here, never measured.
///
/// The one thing real time still decides is when a child is ready, and that is
/// not waited for with a timer: a script that names "$1" creates the marker
/// file at that path when it is set up, and the first sleep does not return
/// before the marker exists. A child that is killed before it is set up would
/// make the tests below pass for the wrong reason (nothing to kill).
const Manual = struct {
    now: u64 = 0,
    marker: ?[]const u8 = null,
    /// A process group is expected to outlive the group kill: the drain sleeps
    /// do not wait for it to go.
    survivors: bool = false,
    polls: u64 = 0,
    drains: u64 = 0,
    drain_ns: u64 = 0,
    gave_up: bool = false,
    /// At this time the poll sleep creates `gate_path` (the ready file of a test).
    gate_at: ?u64 = null,
    gate_path: []const u8 = "",
    /// At this time the poll sleep closes `release_fd`, the write end a waiting
    /// child's read ends on; from then on the time stands still until the
    /// child is reaped.
    release_at: ?u64 = null,
    release_fd: posix.fd_t = -1,
    frozen: bool = false,
    frozen_spins: u64 = 0,

    /// Spins to wait for an event; a lost event ends the wait instead of
    /// hanging the test, and then the test's own asserts fail.
    const patience = 1 << 24;

    fn clock(m: *Manual) Clock {
        return .{ .ctx = m, .now_fn = nowFn, .sleep_fn = sleepFn };
    }

    fn nowFn(ctx: ?*anyopaque) u64 {
        const m: *Manual = @ptrCast(@alignCast(ctx.?));
        return m.now;
    }

    fn markerExists(m: *const Manual) bool {
        const path = m.marker orelse return true;
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }

    fn sleepFn(ctx: ?*anyopaque, ns: u64, wait: Wait) void {
        const m: *Manual = @ptrCast(@alignCast(ctx.?));
        switch (wait) {
            .poll => {
                if (m.release_at) |t| {
                    if (m.now >= t and m.release_fd >= 0) {
                        posix.close(m.release_fd);
                        m.release_fd = -1;
                        m.frozen = true;
                    }
                }
                if (m.gate_at) |t| {
                    if (m.now >= t) {
                        m.gate_at = null;
                        const f = std.fs.cwd().createFile(m.gate_path, .{}) catch @panic("cannot create the ready file");
                        f.close();
                    }
                }
                if (m.frozen) {
                    // The child is ending; the time does not move until it is reaped.
                    m.frozen_spins += 1;
                    if (m.frozen_spins > patience) std.debug.panic("the released child never ended", .{});
                    std.Thread.yield() catch {};
                    return;
                }
                std.Thread.yield() catch {};
                var spins: usize = 0;
                while (!m.markerExists() and spins < patience) : (spins += 1) std.Thread.yield() catch {};
                if (!m.markerExists()) std.debug.panic("the child never created its marker file", .{});
                m.now += ns;
                m.polls += 1;
            },
            .drain => |pgid| {
                m.drains += 1;
                m.drain_ns += ns;
                if (m.survivors or m.gave_up) return;
                // A killed member is gone once its new parent has reaped it.
                var spins: usize = 0;
                while (groupAlive(pgid) and spins < patience) : (spins += 1) std.Thread.yield() catch {};
                if (groupAlive(pgid)) m.gave_up = true;
            },
        }
    }
};

/// CPU time of the test process as a function of the clock, so a verdict
/// depends on a chosen CPU history, not on what a real process happened to use.
const Scripted = struct {
    m: *const Manual,
    cpu_of: *const fn (now: u64) ?u64,
    rss: ?u64 = null,
    samples: u64 = 0,
    last_at: u64 = 0,

    fn sampler(s: *Scripted) Sampler {
        return .{ .ctx = s, .sample_fn = sampleFn };
    }

    fn sampleFn(ctx: ?*anyopaque, _: posix.pid_t) Sample {
        const s: *Scripted = @ptrCast(@alignCast(ctx.?));
        s.samples += 1;
        s.last_at = s.m.now;
        return .{ .cpu_ns = s.cpu_of(s.m.now), .rss = s.rss };
    }
};

fn sh(a: Allocator, tmp: *std.testing.TmpDir, script: []const u8, limits: Limits, m: *Manual) !Result {
    const p = try tmpPaths(a, tmp);
    var lim = limits;
    lim.clock = m.clock();
    const wants_marker = std.mem.indexOf(u8, script, "$1") != null;
    m.marker = null;
    if (wants_marker) {
        tmp.dir.deleteFile("ready") catch {};
        m.marker = try std.fs.path.join(a, &.{ std.fs.path.dirname(p[0]).?, "ready" });
    }
    // MOPM_TEST_CHILD names tests/drivers/proc_child.zig, built by Buck2 for a
    // host with no /bin/sh (the farm's image): each script below is one of its
    // modes. Without it (zig build test) the script runs under /bin/sh.
    if (std.posix.getenv("MOPM_TEST_CHILD")) |child_z| {
        const child: []const u8 = child_z;
        for (child_modes) |cm| {
            if (std.mem.eql(u8, cm.script, script)) {
                const tail: []const []const u8 = if (m.marker) |mk| &.{mk} else &.{};
                const argv = try std.mem.concat(a, []const u8, &.{ &[_][]const u8{child}, cm.args, tail });
                return run(a, .{ .argv = argv, .stdout_path = p[0], .stderr_path = p[1] }, lim);
            }
        }
        std.debug.panic("no proc_child mode for the script: {s}", .{script});
    }
    const argv: []const []const u8 = if (m.marker) |mk| &.{ "/bin/sh", "-c", script, "sh", mk } else &.{ "/bin/sh", "-c", script };
    return run(a, .{ .argv = argv, .stdout_path = p[0], .stderr_path = p[1] }, lim);
}

const second = std.time.ns_per_s;
/// A deadline no manual clock reaches: for a test whose child ends by itself.
const never = std.math.maxInt(u64) / 2;

test "exit status, output to the files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var m = Manual{};
    const r = try sh(a, &tmp, "echo to-out; echo to-err >&2; exit 3", .{ .deadline_ns = never }, &m);
    try std.testing.expectEqual(Term{ .exited = 3 }, r.term);
    try std.testing.expectEqual(@as(?Liveness, null), r.timeout);
    try std.testing.expect(!r.oom and !r.leftover);
    const p = try tmpPaths(a, &tmp);
    try std.testing.expectEqualStrings("to-out\n", try std.fs.cwd().readFileAlloc(a, p[0], 1024));
    try std.testing.expectEqualStrings("to-err\n", try std.fs.cwd().readFileAlloc(a, p[1], 1024));
}

test "the registry token is not in the environment a test process gets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try tmpPaths(a, &tmp);
    var env = std.process.EnvMap.init(a);
    try env.put("MOPM_TOKEN", "mopm_secret_token");
    try env.put("MOPM_TOKEN_NOT", "a different variable");
    try env.put("MOPM_KEEP", "kept");
    // `env` prints what the process got: proc_child's env_to_stdout where there is no /bin/sh, else the program itself.
    const argv: []const []const u8 = if (std.posix.getenv("MOPM_TEST_CHILD")) |child_z|
        try std.mem.concat(a, []const u8, &.{ &[_][]const u8{child_z}, &[_][]const u8{"env_to_stdout"} })
    else
        &.{ "/bin/sh", "-c", "env" };
    var m = Manual{};
    const r = try run(a, .{ .argv = argv, .stdout_path = p[0], .stderr_path = p[1], .env = &env }, .{ .deadline_ns = never, .clock = m.clock() });
    try std.testing.expectEqual(Term{ .exited = 0 }, r.term);
    const printed = try std.fs.cwd().readFileAlloc(a, p[0], 1 << 16);
    try std.testing.expect(std.mem.indexOf(u8, printed, "mopm_secret_token") == null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "MOPM_TOKEN=") == null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "MOPM_TOKEN_NOT=a different variable") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "MOPM_KEEP=kept") != null);
}

test "death by a signal is reported with that signal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var m = Manual{};
    const r = try sh(a, &tmp, "kill -SEGV $$", .{ .deadline_ns = never }, &m);
    try std.testing.expectEqual(Term{ .signaled = posix.SIG.SEGV }, r.term);
    try std.testing.expectEqualStrings("SIGSEGV", signalName(r.term.signaled).?);
    const b = try sh(a, &tmp, "kill -ABRT $$", .{ .deadline_ns = never }, &m);
    try std.testing.expectEqual(Term{ .signaled = posix.SIG.ABRT }, b.term);
    try std.testing.expectEqual(@as(?Liveness, null), b.timeout);
}

test "a sleeping process is killed at the deadline and reported hung, well before it would end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The real sampler, on a process that is set up and asleep; the clock is
    // manual, so "the deadline passes" is 100 polls of 20 ms, not two seconds.
    var m = Manual{};
    const r = try sh(a, &tmp, "touch \"$1\"; exec sleep 60", .{ .deadline_ns = 2 * second }, &m);
    // Killed by the supervisor (the process would sleep for a minute), and
    // not before the deadline: the clock had reached it.
    try std.testing.expectEqual(Term{ .signaled = posix.SIG.KILL }, r.term);
    try std.testing.expectEqual(@as(?Liveness, .hung), r.timeout);
    try std.testing.expect(r.wall_ns >= 2 * second);
    try std.testing.expect(m.polls >= 2 * second / (20 * std.time.ns_per_ms));
}

fn idle(_: u64) ?u64 {
    return 0;
}

test "the process is killed at the first poll at or past the deadline, and not before" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var m = Manual{};
    var sc = Scripted{ .m = &m, .cpu_of = idle };
    const r = try sh(a, &tmp, "touch \"$1\"; exec sleep 60", .{ .deadline_ns = 2 * second, .sampler = sc.sampler() }, &m);
    try std.testing.expectEqual(Term{ .signaled = posix.SIG.KILL }, r.term);
    // A sample is taken at every poll until the kill: at 0, 20 ms, ... and 2 s
    // and none after it. One more or fewer means a late or an early kill.
    try std.testing.expectEqual(@as(u64, 2 * second), sc.last_at);
    try std.testing.expectEqual(@as(u64, 2 * second / (20 * std.time.ns_per_ms) + 1), sc.samples);
    try std.testing.expectEqual(@as(?Liveness, .hung), r.timeout);
}

fn busy(now: u64) ?u64 {
    return now;
}

fn busy_then_idle(now: u64) ?u64 {
    return @min(now, second);
}

fn idle_then_busy(now: u64) ?u64 {
    return if (now > second) now - second else 0;
}

fn unreadable(_: u64) ?u64 {
    return null;
}

fn verdictOf(a: Allocator, tmp: *std.testing.TmpDir, cpu_of: *const fn (u64) ?u64) !?Liveness {
    var m = Manual{};
    var sc = Scripted{ .m = &m, .cpu_of = cpu_of };
    const r = try sh(a, tmp, "touch \"$1\"; exec sleep 60", .{ .deadline_ns = 2 * second, .sampler = sc.sampler() }, &m);
    try std.testing.expectEqual(Term{ .signaled = posix.SIG.KILL }, r.term);
    return r.timeout;
}

test "a computing process past the deadline is reported slow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The CPU history is scripted (a process that used all of one CPU), so
    // the verdict does not depend on what a real spinning process got from a
    // loaded machine. The process itself only has to be alive to be killed.
    try std.testing.expectEqual(@as(?Liveness, .slow), try verdictOf(a, &tmp, busy));
    // The window is the last second before the deadline (2 s / 2 is longer,
    // so 1 s): CPU used before it does not make a sleeper slow ...
    try std.testing.expectEqual(@as(?Liveness, .hung), try verdictOf(a, &tmp, busy_then_idle));
    // ... and CPU used only inside it does make the process slow.
    try std.testing.expectEqual(@as(?Liveness, .slow), try verdictOf(a, &tmp, idle_then_busy));
    // No readable CPU time: unknown, never a guess.
    try std.testing.expectEqual(@as(?Liveness, .unknown), try verdictOf(a, &tmp, unreadable));
}

test "the window is half the deadline when that is under a second" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var m = Manual{};
    // Busy until 0.4 s, idle for the last 0.6 s of a 1 s deadline. The window
    // is 0.5 s: idle in it, so hung. Were it a full second it would take in
    // the busy start (40% of one CPU) and say slow.
    var sc = Scripted{ .m = &m, .cpu_of = busy_until_400ms };
    const r = try sh(a, &tmp, "touch \"$1\"; exec sleep 60", .{ .deadline_ns = 1 * second, .sampler = sc.sampler() }, &m);
    try std.testing.expectEqual(@as(?Liveness, .hung), r.timeout);
}

fn busy_until_400ms(now: u64) ?u64 {
    return @min(now, 400 * std.time.ns_per_ms);
}

test "the CPU time of a computing process is reported from its exit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var m = Manual{};
    // A fixed amount of work, so it ends by itself; the deadline is never reached.
    const r = try sh(a, &tmp, "i=0; while [ $i -lt 200000 ]; do i=$((i+1)); done", .{ .deadline_ns = never }, &m);
    try std.testing.expectEqual(Term{ .exited = 0 }, r.term);
    try std.testing.expectEqual(@as(?Liveness, null), r.timeout);
    try std.testing.expect(r.cpu_ns > 0);
}

test "sample: the CPU time and resident size of a live process are read, and CPU time advances with work" {
    const me: posix.pid_t = if (is_darwin) getpid() else std.os.linux.getpid();
    const first = sample(me);
    try std.testing.expect(first.rss.? > 0);
    const start = first.cpu_ns.?;
    // Work until the reading moves (the kernel counts in 10 ms ticks): an
    // event, not a duration. A reading that never moves ends the loop at the
    // count, and the assert fails.
    var rounds: usize = 0;
    var x: u64 = 0;
    while (sample(me).cpu_ns.? <= start and rounds < 1 << 14) : (rounds += 1) {
        var i: u64 = 0;
        while (i < 1 << 20) : (i += 1) {
            x +%= i;
            std.mem.doNotOptimizeAway(x);
        }
    }
    try std.testing.expect(sample(me).cpu_ns.? > start);
}

test "the deadline kills the whole group: a background child does not survive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The shell starts a sleep in its own group (no job control in sh -c)
    // and then waits; at the deadline both must die.
    // The script creates the marker after starting the sleep, and the clock
    // does not move before it exists: the group has two members when the
    // deadline passes.
    var m = Manual{};
    const r = try sh(a, &tmp, "sleep 60 & touch \"$1\"; wait", .{ .deadline_ns = 1 * second }, &m);
    try std.testing.expectEqual(@as(?Liveness, .hung), r.timeout);
    try std.testing.expect(!r.leftover);
    try std.testing.expect(!groupAlive(r.pgid));
}

test "a process left behind by a test that passed is killed with the group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var m = Manual{};
    const r = try sh(a, &tmp, "sleep 60 & exit 0", .{ .deadline_ns = never }, &m);
    try std.testing.expectEqual(Term{ .exited = 0 }, r.term);
    try std.testing.expect(!r.leftover);
    try std.testing.expect(!groupAlive(r.pgid));
}

test "self-test: without the group kill the leftover is detected (the check above can fail)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The sleeper survives by construction, so the drain sleeps do not wait
    // for it to go; what `run` slept for in them is read off the clock.
    var m = Manual{ .survivors = true };
    const r = try sh(a, &tmp, "sleep 60 & touch \"$1\"; wait", .{ .deadline_ns = 1 * second, .kill_group = false }, &m);
    defer killGroup(r.pgid);
    try std.testing.expectEqual(@as(?Liveness, .hung), r.timeout);
    try std.testing.expect(r.leftover);
    try std.testing.expect(groupAlive(r.pgid));
    // The wait for the group to empty is 100 sleeps of 20 ms: 2 s.
    try std.testing.expectEqual(@as(u64, 100), m.drains);
    try std.testing.expectEqual(@as(u64, 2 * second), m.drain_ns);
}

test "the memory cap kills a process whose resident size passes it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Any process is resident in more than 64 KiB: that cap is passed at
    // the first sample; a 1 GiB one is never passed by a shell.
    var m = Manual{};
    // The deadline is 20 s of manual time, so only the cap can have killed it
    // (timeout stays null); it is passed at the first sample, before any poll.
    const r = try sh(a, &tmp, "exec sleep 30", .{ .deadline_ns = 20 * second, .memory_bytes = 64 << 10 }, &m);
    try std.testing.expect(r.oom);
    try std.testing.expectEqual(Term{ .signaled = posix.SIG.KILL }, r.term);
    try std.testing.expectEqual(@as(?Liveness, null), r.timeout);
    try std.testing.expect(r.peak_rss.? > 64 << 10);
    var m2 = Manual{};
    const ok = try sh(a, &tmp, "exit 0", .{ .deadline_ns = never, .memory_bytes = 1 << 30 }, &m2);
    try std.testing.expect(!ok.oom);
    try std.testing.expectEqual(Term{ .exited = 0 }, ok.term);
}

test "liveness: under 5% of one CPU over the window is hung" {
    try std.testing.expectEqual(Liveness.hung, liveness(100, 100, second));
    try std.testing.expectEqual(Liveness.hung, liveness(0, second / 25, second));
    try std.testing.expectEqual(Liveness.slow, liveness(0, second / 10, second));
    try std.testing.expectEqual(Liveness.unknown, liveness(null, 5, second));
    try std.testing.expectEqual(Liveness.unknown, liveness(5, null, second));
}

test "/proc parsing" {
    try std.testing.expectEqual(@as(?u64, 70 * std.time.ns_per_s / 100), parseProcStatCpu("42 (a b) c) S 1 42 42 0 -1 4194560 100 0 0 0 30 40 0 0 20 0 1 0"));
    try std.testing.expectEqual(@as(?u64, null), parseProcStatCpu("42 (x) S 1"));
    try std.testing.expectEqual(@as(?u64, 2048 * 1024), parseVmRss("Name:\tx\nVmPeak:\t 9 kB\nVmRSS:\t    2048 kB\n"));
    try std.testing.expectEqual(@as(?u64, null), parseVmRss("Name:\tx\n"));
}

test "signal names" {
    try std.testing.expectEqualStrings("SIGABRT", signalName(posix.SIG.ABRT).?);
    try std.testing.expectEqualStrings("SIGILL", signalName(posix.SIG.ILL).?);
    try std.testing.expectEqualStrings("SIGBUS", signalName(posix.SIG.BUS).?);
    try std.testing.expectEqual(@as(?[]const u8, null), signalName(200));
}

// ------------------------------------------------- tests of the ready file
//
// `Limits.ready_file` moves the start of the deadline. The tests use `Manual`
// (above): the file appears, and the child is let go, at a chosen manual time.

/// The pipe a `wait_pipe` child (descriptors 8 and 9, see proc_child) ends on
/// when the write end closes. Closed by `Manual` at `release_at`.
fn releasePipe() !posix.fd_t {
    const p = try posix.pipe();
    try posix.dup2(p[0], 8);
    try posix.dup2(p[1], 9);
    posix.close(p[0]);
    posix.close(p[1]);
    return 9;
}

test "ready file: the deadline counts from the poll that finds it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const go = try std.fs.path.join(a, &.{ dir, "go" });
    // The file appears at 10 s, five deadlines after the start; the sleep that
    // creates it advances to 10.02 s, where the poll finds it. The deadline of
    // 2 s then ends at 12.02 s, and the last sample is that poll's.
    const poll = (Limits{ .deadline_ns = 0 }).poll_ns;
    var m = Manual{ .gate_at = 10 * second, .gate_path = go };
    var sc = Scripted{ .m = &m, .cpu_of = idle };
    const r = try sh(a, &tmp, "touch \"$1\"; exec sleep 60", .{ .deadline_ns = 2 * second, .ready_file = go, .sampler = sc.sampler() }, &m);
    try std.testing.expectEqual(Term{ .signaled = posix.SIG.KILL }, r.term);
    try std.testing.expectEqual(@as(?Liveness, .hung), r.timeout);
    try std.testing.expectEqual(12 * second + poll, sc.last_at);
}

test "ready file: without it nothing times out, however long the clock runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const never_there = try std.fs.path.join(a, &.{ dir, "never" });
    // The clock runs to 100 s, fifty deadlines; there the child is let go and
    // ends by itself. `run` has not killed it.
    var m = Manual{ .release_at = 100 * second, .release_fd = try releasePipe() };
    defer posix.close(8);
    defer if (m.release_fd >= 0) posix.close(m.release_fd);
    var sc = Scripted{ .m = &m, .cpu_of = busy };
    const r = try sh(a, &tmp, "exec 9>&-; read x <&8; exit 0", .{ .deadline_ns = 2 * second, .ready_file = never_there, .sampler = sc.sampler() }, &m);
    try std.testing.expectEqual(Term{ .exited = 0 }, r.term);
    try std.testing.expectEqual(@as(?Liveness, null), r.timeout);
    try std.testing.expect(!r.oom);
    try std.testing.expectEqual(100 * second, sc.last_at);
}

test "a test that computes past half the deadline and ends in time is not a timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Let go at 4 s of a 6 s deadline: polled (and sampled as computing) past
    // half of it, never killed.
    var m = Manual{ .release_at = 4 * second, .release_fd = try releasePipe() };
    defer posix.close(8);
    defer if (m.release_fd >= 0) posix.close(m.release_fd);
    var sc = Scripted{ .m = &m, .cpu_of = busy };
    const r = try sh(a, &tmp, "exec 9>&-; read x <&8; exit 0", .{ .deadline_ns = 6 * second, .sampler = sc.sampler() }, &m);
    try std.testing.expectEqual(Term{ .exited = 0 }, r.term);
    try std.testing.expectEqual(@as(?Liveness, null), r.timeout);
    try std.testing.expect(!r.oom);
    try std.testing.expectEqual(4 * second, sc.last_at);
    try std.testing.expectEqual(4 * second, r.wall_ns);
}
