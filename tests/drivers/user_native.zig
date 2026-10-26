//! The native step of the user-level beta walk (tests/drivers/user_beta.zig): a released mopm must not regress packages
//! that ship C code. A package with its own static library is built, published into the fake registry the walk started,
//! and then used the way a customer uses it, and the program that comes out prints a value only the C code computes.
//!
//! The fixture is the member `shimlib` of tests/e2e/natws (the one tests/drivers/native_workspace_test.zig uses): its
//! manifest declares `[native.shim]` (C sources, a header, `cflags`, `cflags_by_os`), and `shim_answer()` is
//! 6 * 7 + (0 on Linux, 1 on macOS) = 42 or 43. What the step does, and what each line proves:
//!
//!   1  the C sources are compiled with the zig the walk's job installed (`zig cc -c`) and archived (`zig ar`) into
//!      libshim.a for this platform, and the member is precompiled with the Mojo environment of the walk;
//!   2  `mopm stage` packs the member from those artifacts (the archive is read from `shimlib.native/libshim.a`), and
//!      `mopm publish --staged` publishes the set through one group into the fake registry, which then serves the version;
//!   3  as a user: `mopm new --bin`, `mopm add shimlib` from that registry, `mopm sync` (the installed environment
//!      holds lib/libshim.a, byte for byte the archive that was built), `mopm build` with no file (the manifest's
//!      targets), and the built program, run, prints `native 42` (Linux) or `native 43` (macOS).
//!
//! The value is checked, not the time it took. A static link only: the fake registry has no system libraries, so a
//! `mode = "load"` dependency is not part of this step.
//!
//! linux-arm64 is not run until Linux arm64 build hardware exists: `linux_arm64_native_enabled` below is the one switch,
//! and with it off the walk prints `waiting_message` on that leg and counts the step as skipped, never as passed.

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

/// Whether this step runs on linux aarch64. Off: the native tests of that platform are disabled until Linux arm64 farm
/// hardware is racked (they are never faked and never moved to a hosted runner). Re-enabling is this one line.
pub const linux_arm64_native_enabled = false;

/// What the walk prints, exactly, in place of the step on a platform whose switch is off.
pub const waiting_message = "skipped: waiting on linux-arm64 hardware";

pub const Decision = enum { run, skip_waiting_on_arm64 };

/// Whether the step runs on `os` and `arch`, with the switch at `arm64_enabled`.
pub fn decide(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch, arm64_enabled: bool) Decision {
    if (os == .linux and arch == .aarch64 and !arm64_enabled) return .skip_waiting_on_arm64;
    return .run;
}

/// The decision for the machine this driver runs on.
pub fn decision() Decision {
    return decide(builtin.os.tag, builtin.cpu.arch, linux_arm64_native_enabled);
}

/// The step is skipped: counted as a skip (never as a pass) and announced with `waiting_message`.
pub fn reportSkip(skipped: *usize, w: anytype) !void {
    skipped.* += 1;
    try w.print("{s}\n", .{waiting_message});
}

/// The line the built program prints on `os`: what the C code computes (42 on Linux, 43 on macOS).
pub fn expectedLine(os: std.Target.Os.Tag) []const u8 {
    return if (os == .macos) "native 43\n" else "native 42\n";
}

/// Whether `stdout` is exactly what the built program prints on `os`.
pub fn outputOk(stdout: []const u8, os: std.Target.Os.Tag) bool {
    return std.mem.eql(u8, stdout, expectedLine(os));
}

/// Whether the installed archive is present and is, byte for byte, the archive that was built.
pub fn archiveOk(installed: []const u8, built: []const u8) bool {
    return installed.len != 0 and std.mem.eql(u8, installed, built);
}

const program_source =
    \\from shimlib import shim_answer
    \\
    \\
    \\def main():
    \\    print("native", shim_answer())
    \\
;

pub const Opts = struct {
    mopm: []const u8,
    /// A writable directory for this step (absolute).
    work: []const u8,
    /// The member's directory: tests/e2e/natws/shimlib (absolute).
    fixture: []const u8,
    /// The fake registry's base URL.
    registry: []const u8,
    /// A session token of an account on that registry (it claims the name and makes the publishing token).
    session: []const u8,
    /// The zig executable (`zig cc`, `zig ar`).
    zig: []const u8,
    /// A Mojo environment prefix (bin/mojo, share/max): precompiles the member.
    mojo_env: []const u8,
    /// pixi, as `mopm sync --pixi` takes it.
    pixi: []const u8,
    /// The environment of every child (no MOPM_TOKEN).
    env: *const std.process.EnvMap,
    /// `-target` for `zig cc`; null for the machine's own.
    cc_target: ?[]const u8 = null,
    /// A stand-in compiler to lay into the installed environment (the unit tier of this step has no real Mojo).
    stand_in_mojo: ?[]const u8 = null,
};

fn hostSubdir() ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => "osx-arm64",
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "linux-64",
            .aarch64 => "linux-aarch64",
            else => error.UnsupportedHost,
        },
        else => error.UnsupportedHost,
    };
}

/// A copy of the executable `src` as `dest`, runnable.
pub fn installCompiler(src: []const u8, dest: []const u8) !void {
    const cwd = std.fs.cwd();
    if (std.fs.path.dirname(dest)) |d| try cwd.makePath(d);
    try cwd.copyFile(src, cwd, dest, .{});
    const f = try cwd.openFile(dest, .{});
    defer f.close();
    try f.chmod(0o755);
}

const Walk = struct {
    a: Allocator,
    rep: *h.Report,
    o: Opts,

    /// Runs `argv` in `dir` with `env`; a nonzero exit is a failure of the walk and ends the step.
    fn must(w: *Walk, what: []const u8, argv: []const []const u8, dir: ?[]const u8, env: *const std.process.EnvMap) !h.Ran {
        h.stage = what;
        const r = try h.run(w.a, argv, env, .{ .cwd = dir });
        if (r.signaled or r.code != 0) {
            std.debug.print("FAIL {s}: exit {d}\n{s}\n", .{ what, r.code, r.text });
            w.rep.failures += 1;
            return error.Fatal;
        }
        std.debug.print("ok   {s}\n", .{what});
        return r;
    }

    fn mopm(w: *Walk, what: []const u8, dir: []const u8, args: []const []const u8, env: *const std.process.EnvMap) !h.Ran {
        const argv = try w.a.alloc([]const u8, args.len + 1);
        argv[0] = w.o.mopm;
        @memcpy(argv[1..], args);
        return w.must(what, argv, dir, env);
    }
};

/// The names of the `.c` files in `dir`, sorted.
fn cSources(a: Allocator, dir: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(a);
    var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    while (try it.next()) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".c")) try list.append(try a.dupe(u8, e.name));
    }
    h.sortStrings(list.items);
    return list.items;
}

/// Claims `package` for the account of `session` and makes an API token that may publish it.
fn publishToken(a: Allocator, rep: *h.Report, base: []const u8, session: []const u8, package: []const u8) ![]const u8 {
    var resp = try h.request(a, "POST", base, try h.fmt(a, "/api/v1/packages/{s}/claim", .{package}), "{}", session);
    rep.check("native: the account claims the package name", resp.status == 201, resp.body);
    resp = try h.request(a, "POST", base, "/api/v1/me/tokens", try h.fmt(a, "{{\"name\":\"user-beta-native\",\"scopes\":[\"publish\"],\"packages\":[\"{s}\"],\"expires_in_days\":1}}", .{package}), session);
    const token = if (resp.status == 201) (h.jsonString(try h.parseJson(a, resp.body), "token") orelse "") else "";
    rep.check("native: the account makes an API token that may publish it", token.len != 0, resp.body);
    return token;
}

/// The step. A failure is recorded in `rep` and ends the step; the walk goes on.
pub fn run(a: Allocator, rep: *h.Report, o: Opts) !void {
    var w = Walk{ .a = a, .rep = rep, .o = o };
    walk(&w) catch |e| switch (e) {
        error.Fatal => {},
        else => return e,
    };
}

fn walk(w: *Walk) !void {
    const a = w.a;
    const o = w.o;
    const rep = w.rep;
    const cwd = std.fs.cwd();
    const subdir = try hostSubdir();
    const is_macos = builtin.os.tag == .macos;
    const root = try h.join(a, &.{ o.work, "native" });
    const member = try h.join(a, &.{ root, "ws", "shimlib" });
    try h.copyTree(a, o.fixture, member);

    const manifest = try h.readFile(a, try h.join(a, &.{ member, "mopm.toml" }));
    rep.check("native: the member's manifest declares the static native this step builds, with the flags it compiles with", h.contains(manifest, "[native.shim]") and
        h.contains(manifest, "kind = \"static\"") and h.contains(manifest, "-DSHIM_SCALE=6") and h.contains(manifest, "-DSHIM_OS_ADD=0") and h.contains(manifest, "-DSHIM_OS_ADD=1"), manifest);

    // 1. The archive, as a build system makes it, and the member's precompiled package.
    const native_dir = try h.join(a, &.{ member, "native" });
    const objdir = try h.join(a, &.{ root, "obj" });
    try cwd.makePath(objdir);
    var objs = std.ArrayList([]const u8).init(a);
    for (try cSources(a, native_dir)) |name| {
        const obj = try h.join(a, &.{ objdir, try h.fmt(a, "{s}.o", .{std.fs.path.stem(name)}) });
        var argv = std.ArrayList([]const u8).init(a);
        try argv.appendSlice(&.{ o.zig, "cc" });
        if (o.cc_target) |t| try argv.appendSlice(&.{ "-target", t });
        try argv.appendSlice(&.{ "-c", "-fPIC", "-O1", "-DSHIM_SCALE=6", if (is_macos) "-DSHIM_OS_ADD=1" else "-DSHIM_OS_ADD=0" });
        try argv.append(try h.fmt(a, "-I{s}", .{native_dir}));
        try argv.appendSlice(&.{ "-o", obj, try h.join(a, &.{ native_dir, name }) });
        _ = try w.must(try h.fmt(a, "native: zig cc compiles {s} with the flags of the manifest", .{name}), argv.items, null, o.env);
        try objs.append(obj);
    }
    const art = try h.join(a, &.{ root, "artifacts" });
    const archive = try h.join(a, &.{ art, subdir, "shimlib.native", "libshim.a" });
    try cwd.makePath(try h.join(a, &.{ art, subdir, "shimlib.native" }));
    var ar = std.ArrayList([]const u8).init(a);
    try ar.appendSlice(&.{ o.zig, "ar", "rcs", archive });
    try ar.appendSlice(objs.items);
    _ = try w.must("native: zig ar archives the objects into libshim.a", ar.items, null, o.env);
    const archive_bytes = try h.readFile(a, archive);
    rep.check("native: libshim.a is an ar archive that holds the C functions", std.mem.startsWith(u8, archive_bytes, "!<arch>\n") and h.contains(archive_bytes, "shim_answer") and h.contains(archive_bytes, "shim_scale"), "the archive is not an ar archive with both symbols");

    var mojo_env = try h.cloneEnv(a, o.env);
    try mojo_env.put("MODULAR_HOME", try h.fmt(a, "{s}/share/max", .{o.mojo_env}));
    const mojoc = try h.join(a, &.{ art, subdir, "shimlib.mojoc" });
    _ = try w.must("native: mojo precompile of the member", &.{ try h.join(a, &.{ o.mojo_env, "bin", "mojo" }), "precompile", "src/shimlib", "-o", mojoc }, member, &mojo_env);

    // 2. Staged, then published through one group.
    const staged = try h.join(a, &.{ root, "staged" });
    _ = try w.mopm("native: mopm stage packs the member with its archive", root, &.{
        "stage", "--workspace-root", try h.join(a, &.{ root, "ws" }), "--artifacts", art, "--compiler", "1.0.0", "--out", staged, "--registry", o.registry, "shimlib",
    }, o.env);
    const plan = try h.parseJson(a, try h.readFile(a, try h.join(a, &.{ staged, "plan.json" })));
    const members = if (plan == .object) (plan.object.get("members") orelse std.json.Value{ .null = {} }) else std.json.Value{ .null = {} };
    const first = if (members == .array and members.array.items.len == 1) members.array.items[0] else std.json.Value{ .null = {} };
    rep.check("native: the staged plan uploads exactly shimlib", std.mem.eql(u8, h.jsonString(first, "name") orelse "", "shimlib") and std.mem.eql(u8, h.jsonString(first, "action") orelse "", "upload"), "plan.json does not list shimlib as an upload");

    const token = try publishToken(a, rep, o.registry, o.session, "shimlib");
    var pub_env = try h.cloneEnv(a, o.env);
    try pub_env.put("MOPM_TOKEN", token);
    _ = try w.mopm("native: mopm publish --staged publishes the set through one group", root, &.{
        "publish", "--staged", staged, "--registry", o.registry, "--config-dir", try h.join(a, &.{ root, "conf" }), "--wait", "60",
    }, &pub_env);
    const served = try h.request(a, "GET", o.registry, "/api/v1/packages/shimlib/1.0.0", null, null);
    rep.check("native: the registry serves shimlib 1.0.0", served.status == 200, served.body);

    // 3. As a user: a new package that adds it, syncs, builds with no file, and runs.
    const user = try h.join(a, &.{ root, "user" });
    try cwd.makePath(user);
    const app = try h.join(a, &.{ user, "nat_app" });
    _ = try w.mopm("native: mopm new --bin", user, &.{ "new", "nat_app", "--bin" }, o.env);
    _ = try w.mopm("native: mopm add shimlib from the registry", app, &.{ "add", "shimlib", "--registry", o.registry }, o.env);
    const lock = try h.readFile(a, try h.join(a, &.{ app, "mopm.lock" }));
    rep.check("native: the lock names shimlib", h.contains(lock, "shimlib"), lock);
    _ = try w.mopm("native: mopm sync installs it", app, &.{ "sync", "--pixi", o.pixi, "--registry", o.registry }, o.env);
    const env_dir = try h.join(a, &.{ app, ".mopm", ".pixi", "envs", "default" });
    const installed = h.readFile(a, try h.join(a, &.{ env_dir, "lib", "libshim.a" })) catch "";
    rep.check("native: the installed environment holds lib/libshim.a, byte for byte the archive that was built", archiveOk(installed, archive_bytes), "lib/libshim.a is missing or differs");
    if (o.stand_in_mojo) |stand_in| try installCompiler(stand_in, try h.join(a, &.{ env_dir, "bin", "mojo" }));

    try h.writeFile(try h.join(a, &.{ app, "src", "main.mojo" }), program_source);
    _ = try w.mopm("native: mopm build with no file builds the manifest's targets", app, &.{ "build", "--prefix", env_dir }, o.env);
    const bin = try h.join(a, &.{ app, "target", "build", "nat_app" });
    const built = if (cwd.access(bin, .{})) true else |_| false;
    rep.check("native: the program is where the build puts it", built, bin);
    if (!built) return;
    const ran = try h.run(a, &.{bin}, o.env, .{ .capture = .stdout });
    rep.check("native: the built program prints the value the C code computes", !ran.signaled and ran.code == 0 and outputOk(ran.text, builtin.os.tag), ran.text);
}
