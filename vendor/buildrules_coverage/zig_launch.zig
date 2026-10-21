// Vendored, unmodified, from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/zig/zig_launch.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
// Why Zig: build tools are Zig, and this one is built
// by the pinned zig directly (toolchain.bzl `zig_bootstrap_exe`), so the
// action that runs every zig_test needs no shell to exist.
//! zig_launch: the action runner of the `zig_test` rule (mojo/toolchain.bzl).
//!
//! usage: zig_launch test --busybox <busybox> --zig <zig_dir> --out <file>
//!            --stamp <text> [--data <manifest>] [--tools <manifest>]
//!            -- <zig arguments...>
//!        zig_launch run  --busybox <busybox> --exec <program> --out <file>
//!            --stamp <text> [--data <manifest>] [--tools <manifest>]
//!            -- <program arguments...>
//!
//! `run` is `test` with a program of the action's own in place of zig: the same scratch directory, the same environment (a coverage run
//! builds the test and runs it under kcov, rules/coverage/tools/zig_cover.zig), the same data and tools, the same stamp.
//!
//! It does what the busybox script of the rule did, without a shell:
//!
//!   1. A scratch directory `<scratch>/buildrules`: `$BUCK_SCRATCH_PATH/buildrules`
//!      (relative to the working directory when it is relative), or
//!      `.buildrules_action` in the working directory when buck2 names none.
//!   2. The busybox applets linked into `<scratch>/bin` (`busybox --install
//!      -s`), which is the whole `PATH` of the tests.
//!   3. The environment of the tests: what the action has, with `PATH`,
//!      `HOME`, `TMPDIR`, `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR`
//!      set inside the scratch directory. With `--data` or `--tools` (a driver
//!      test) also `XDG_CACHE_HOME` and `BUILDRULES_TEST_WORK`.
//!   4. A driver test's fixtures: each line of the `--data` manifest is
//!      `<destination>\t<source>`; a source directory is copied into
//!      `BUILDRULES_TEST_WORK/<destination>` (merged), a file to it. Every copied
//!      entry is then writable by its owner; executable bits are kept. Each
//!      line of the `--tools` manifest is `<NAME>\t<path>`: `NAME` is set to
//!      the path made absolute.
//!   5. `<zig_dir>/zig <zig arguments>` (`run`: `<program> <arguments>`), with the action's stdin, stdout and
//!      stderr. When it fails the launcher exits with its status (128 + N
//!      for signal N) and writes nothing.
//!   6. On success: the `--stamp` text is written to `--out` and the scratch
//!      directory removed.
//!
//! Exit status: zig's; 2 for a usage error or a failure of the launcher's own.

const std = @import("std");

pub const Plan = struct {
    busybox: []const u8,
    /// The directory holding `zig` (`test`); null for `run`.
    zig_dir: ?[]const u8,
    /// The program `run` runs; null for `test`.
    exec: ?[]const u8,
    out: []const u8,
    stamp: []const u8,
    data: ?[]const u8,
    tools: ?[]const u8,
    zig_args: []const []const u8,

    /// A driver test is one that was given a manifest, even an empty one.
    pub fn isDriver(self: Plan) bool {
        return self.data != null or self.tools != null;
    }
};

const usage = "usage: zig_launch test --busybox <busybox> --zig <zig_dir> --out <file> --stamp <text> [--data <manifest>] [--tools <manifest>] -- <zig arguments...>\n       zig_launch run --busybox <busybox> --exec <program> --out <file> --stamp <text> [--data <manifest>] [--tools <manifest>] -- <program arguments...>";

pub const ParseError = error{Usage};

/// The plan an argument vector (without the program name) states. On
/// `error.Usage`, `diag` says what is wrong.
pub fn parse(args: []const []const u8, diag: *[]const u8) ParseError!Plan {
    if (args.len < 1 or !(std.mem.eql(u8, args[0], "test") or std.mem.eql(u8, args[0], "run"))) {
        diag.* = "the subcommand is `test` or `run`";
        return error.Usage;
    }
    const is_run = std.mem.eql(u8, args[0], "run");
    var busybox: ?[]const u8 = null;
    var zig_dir: ?[]const u8 = null;
    var exec: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var stamp: ?[]const u8 = null;
    var data: ?[]const u8 = null;
    var tools: ?[]const u8 = null;
    var zig_args: ?[]const []const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            zig_args = args[i + 1 ..];
            break;
        }
        const slot: *?[]const u8 = if (std.mem.eql(u8, arg, "--busybox"))
            &busybox
        else if (!is_run and std.mem.eql(u8, arg, "--zig"))
            &zig_dir
        else if (is_run and std.mem.eql(u8, arg, "--exec"))
            &exec
        else if (std.mem.eql(u8, arg, "--out"))
            &out
        else if (std.mem.eql(u8, arg, "--stamp"))
            &stamp
        else if (std.mem.eql(u8, arg, "--data"))
            &data
        else if (std.mem.eql(u8, arg, "--tools"))
            &tools
        else {
            diag.* = "unknown argument";
            return error.Usage;
        };
        if (slot.* != null) {
            diag.* = "an option is given twice";
            return error.Usage;
        }
        i += 1;
        if (i >= args.len) {
            diag.* = "an option has no value";
            return error.Usage;
        }
        slot.* = args[i];
    }
    if (is_run) {
        if (busybox == null or exec == null or out == null or stamp == null) {
            diag.* = "--busybox, --exec, --out and --stamp are required";
            return error.Usage;
        }
    } else if (busybox == null or zig_dir == null or out == null or stamp == null) {
        diag.* = "--busybox, --zig, --out and --stamp are required";
        return error.Usage;
    }
    const rest = zig_args orelse {
        diag.* = if (is_run) "the program's arguments follow `--`" else "the zig arguments follow `--`";
        return error.Usage;
    };
    if (rest.len == 0 and !is_run) {
        diag.* = "no zig arguments after `--`";
        return error.Usage;
    }
    return .{ .busybox = busybox.?, .zig_dir = zig_dir, .exec = exec, .out = out.?, .stamp = stamp.?, .data = data, .tools = tools, .zig_args = rest };
}

/// The scratch directory of the action: where buck2 says (`buck_scratch`, its
/// BUCK_SCRATCH_PATH; relative to `cwd` when relative), else beside the
/// action's inputs.
pub fn scratchRoot(a: std.mem.Allocator, cwd: []const u8, buck_scratch: ?[]const u8) ![]u8 {
    const s = buck_scratch orelse "";
    if (s.len == 0) return std.fs.path.join(a, &.{ cwd, ".buildrules_action" });
    if (std.fs.path.isAbsolute(s)) return std.fs.path.join(a, &.{ s, "buildrules" });
    return std.fs.path.join(a, &.{ cwd, s, "buildrules" });
}

pub const Entry = struct { left: []const u8, right: []const u8 };

pub const ManifestError = error{BadLine};

/// The entries of a manifest: one `<left>\t<right>` per line; the last line
/// may end without a newline; empty lines are skipped. The right side is
/// everything after the first tab.
pub fn manifest(a: std.mem.Allocator, text: []const u8) (ManifestError || std.mem.Allocator.Error)![]Entry {
    var list = std.ArrayList(Entry).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.BadLine;
        if (tab == 0 or tab + 1 == line.len) return error.BadLine;
        try list.append(.{ .left = line[0..tab], .right = line[tab + 1 ..] });
    }
    return list.toOwnedSlice();
}

/// What the launcher exits with when a child ended as `term`: the child's own
/// status, 128 + N for signal N (a shell's), 1 for anything else.
pub fn exitCodeOf(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| @truncate(128 +% s),
        else => 1,
    };
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zig_launch: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

/// Copies the entries of `src` into `dst`, merging into directories that exist:
/// a symbolic link stays one (as `cp -R` does), a file's mode is kept.
pub fn copyTree(src: std.fs.Dir, dst: std.fs.Dir) !void {
    var it = src.iterate();
    while (try it.next()) |e| {
        switch (e.kind) {
            .directory => {
                dst.makeDir(e.name) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                var s = try src.openDir(e.name, .{ .iterate = true });
                defer s.close();
                var d = try dst.openDir(e.name, .{ .iterate = true });
                defer d.close();
                try copyTree(s, d);
            },
            .sym_link => {
                var buf: [4096]u8 = undefined;
                const target = try src.readLink(e.name, &buf);
                dst.deleteFile(e.name) catch {};
                try dst.symLink(target, e.name, .{});
            },
            .file => try src.copyFile(e.name, dst, e.name, .{}),
            else => return error.UnsupportedEntry,
        }
    }
}

/// Adds the owner's write bit to every file and directory under `dir` (links
/// are left alone), as `chmod -R u+w`.
pub fn makeWritable(dir: std.fs.Dir) !void {
    const self = std.fs.File{ .handle = dir.fd };
    const st = try self.stat();
    try self.chmod(st.mode | 0o200);
    var it = dir.iterate();
    while (try it.next()) |e| {
        switch (e.kind) {
            .directory => {
                var d = try dir.openDir(e.name, .{ .iterate = true });
                defer d.close();
                try makeWritable(d);
            },
            .file => {
                const f = try dir.openFile(e.name, .{});
                defer f.close();
                const fst = try f.stat();
                try f.chmod(fst.mode | 0o200);
            },
            else => {},
        }
    }
}

fn readManifest(a: std.mem.Allocator, path: []const u8) []Entry {
    const text = std.fs.cwd().readFileAlloc(a, path, 1 << 24) catch |e| die("cannot read {s}: {s}", .{ path, @errorName(e) });
    return manifest(a, text) catch |e| die("{s}: {s}", .{ path, @errorName(e) });
}

/// Lays a driver test's data into `work`: see the module comment.
fn layData(entries: []const Entry, work_path: []const u8) !void {
    var work = try std.fs.cwd().openDir(work_path, .{ .iterate = true });
    defer work.close();
    for (entries) |e| {
        const st = std.fs.cwd().statFile(e.right) catch |err| die("data {s}: {s}", .{ e.right, @errorName(err) });
        if (st.kind == .directory) {
            try work.makePath(e.left);
            var s = try std.fs.cwd().openDir(e.right, .{ .iterate = true });
            defer s.close();
            var d = try work.openDir(e.left, .{ .iterate = true });
            defer d.close();
            try copyTree(s, d);
        } else {
            if (std.fs.path.dirname(e.left)) |parent| try work.makePath(parent);
            try std.fs.cwd().copyFile(e.right, work, e.left, .{});
        }
    }
    try makeWritable(work);
}

fn run(a: std.mem.Allocator, argv: []const []const u8, env: *const std.process.EnvMap) !std.process.Child.Term {
    var child = std.process.Child.init(argv, a);
    child.env_map = env;
    return child.spawnAndWait();
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    var diag: []const u8 = "";
    const plan = parse(argv[1..], &diag) catch {
        die("{s}\n{s}", .{ diag, usage });
    };

    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    const abs = struct {
        fn of(al: std.mem.Allocator, base: []const u8, p: []const u8) ![]u8 {
            return if (std.fs.path.isAbsolute(p)) al.dupe(u8, p) else std.fs.path.join(al, &.{ base, p });
        }
    }.of;
    const busybox = try abs(a, cwd, plan.busybox);
    // `test` runs zig, `run` the program of the action.
    const zig_exe = if (plan.exec) |e| try abs(a, cwd, e) else try std.fs.path.join(a, &.{ plan.zig_dir.?, "zig" });

    var env = try std.process.getEnvMap(a);
    const t = try scratchRoot(a, cwd, env.get("BUCK_SCRATCH_PATH"));
    const bin = try std.fs.path.join(a, &.{ t, "bin" });
    try std.fs.cwd().makePath(bin);
    const installed = run(a, &.{ busybox, "--install", "-s", bin }, &env) catch |e| die("cannot run {s}: {s}", .{ busybox, @errorName(e) });
    if (exitCodeOf(installed) != 0) die("{s} --install -s {s} failed", .{ busybox, bin });

    try env.put("PATH", bin);
    try env.put("ZIG_GLOBAL_CACHE_DIR", try std.fs.path.join(a, &.{ t, "zig-global" }));
    try env.put("ZIG_LOCAL_CACHE_DIR", try std.fs.path.join(a, &.{ t, "zig-local" }));
    try env.put("HOME", try std.fs.path.join(a, &.{ t, "home" }));
    const tmp = try std.fs.path.join(a, &.{ t, "tmp" });
    try env.put("TMPDIR", tmp);
    try std.fs.cwd().makePath(tmp);

    if (plan.isDriver()) {
        const cache = try std.fs.path.join(a, &.{ t, "cache" });
        const work = try std.fs.path.join(a, &.{ t, "work" });
        try env.put("XDG_CACHE_HOME", cache);
        try env.put("BUILDRULES_TEST_WORK", work);
        try std.fs.cwd().makePath(cache);
        try std.fs.cwd().makePath(work);
        if (plan.data) |m| try layData(readManifest(a, m), work);
        if (plan.tools) |m| {
            for (readManifest(a, m)) |e| try env.put(e.left, try abs(a, cwd, e.right));
        }
    }

    var zig_argv = std.ArrayList([]const u8).init(a);
    try zig_argv.append(zig_exe);
    try zig_argv.appendSlice(plan.zig_args);
    const term = run(a, zig_argv.items, &env) catch |e| die("cannot run {s}: {s}", .{ zig_exe, @errorName(e) });
    const code = exitCodeOf(term);
    if (code != 0) std.process.exit(code);

    const f = try std.fs.cwd().createFile(plan.out, .{});
    defer f.close();
    try f.writeAll(plan.stamp);
    std.fs.cwd().deleteTree(t) catch |e| die("cannot remove {s}: {s}", .{ t, @errorName(e) });
}
