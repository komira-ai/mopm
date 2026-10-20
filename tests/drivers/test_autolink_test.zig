//! The port of the former tests/e2e/run.sh in Zig, for the build farm (no shell, no pixi, no system
//! C compiler): `mopm build`, `mopm run` and `mopm repl` against the real
//! Mojo toolchain, with native libraries reached through mopm's autolink.
//! It replaces tests/e2e/run.sh (deleted); the check is //:autolink.
//!
//! What it does, as run.sh does:
//!   1. builds libgreet, libinner and libouter (libouter needs libinner and
//!      has no run path of its own, so libinner loads only if mopm names it)
//!      with the C compiler (komira's zig, as `zig cc`);
//!   2. precompiles the Mojo packages greet, inner and outer with the pinned
//!      Mojo 1.0.0 (komira//tools/build/toolchains:mojo_compiler);
//!   3. installs them into two prefixes laid out as spec/channel.md says:
//!      "pixi" (the compiler's own library directory is the prefix's `lib`)
//!      and "split" (a prefix whose import path is its own lib/mojo, and
//!      whose natives are NOT in the directory the compiler's run path
//!      covers), with outer's metadata declaring that libouter needs libinner;
//!   4. in each prefix, for prog.mojo and the outer-only prog_outer.mojo,
//!      checks that the binary `mopm build` made (run in an empty
//!      environment), `mopm run` and `mopm repl` print the lines only the
//!      native code can produce;
//!   5. in the split prefix, controls: stock `mojo run` and `mojo repl`
//!      given greet and outer but not inner must NOT print the values, so
//!      the transitive entry is load-bearing.

const std = @import("std");
const h = @import("harness.zig");
const mojo_env = @import("mojo_env.zig");
const Allocator = std.mem.Allocator;

const values = [_][]const u8{ "greet 4242", "base 1000", "chain 1234" };

const Ctx = struct {
    a: Allocator,
    rep: *h.Report,
    m: mojo_env.Mojo,
    mopm: []const u8,
    /// tests/e2e as staged in the work directory.
    here: []const u8,
    natives: []const u8,
    pkgs: []const u8,
    out: []const u8,
    /// Whether the toolchain can run `mojo repl` (it needs lldb, which komira's
    /// pinned compiler closure does not hold).
    have_repl: bool,

    fn skipRepl(c: *Ctx, label: []const u8) void {
        _ = c;
        std.debug.print("SKIP {s}: the pinned toolchain has no bin/mojo-lldb, and `mojo repl` answers \"unable to resolve the lldb path\"\n", .{label});
    }

    fn die(c: *Ctx, what: []const u8, r: h.Ran) error{Fatal} {
        std.debug.print("FAIL {s}: exit {d}{s}\n{s}\n", .{ what, r.code, if (r.signaled) " (signal)" else "", r.text });
        c.rep.failures += 1;
        return error.Fatal;
    }

    fn mustRun(c: *Ctx, what: []const u8, r: h.Ran) !void {
        if (r.signaled or r.code != 0) return c.die(what, r);
    }

    fn shlib(c: *Ctx, name: []const u8, extra: []const []const u8) !void {
        const src = try h.fmt(c.a, "{s}/native/{s}.c", .{ c.here, name });
        const out = try h.fmt(c.a, "{s}/{s}", .{ c.natives, try mojo_env.libName(c.a, name) });
        var argv = std.ArrayList([]const u8).init(c.a);
        try argv.appendSlice(try mojo_env.shlibFlags(c.a, name));
        try argv.appendSlice(&.{ "-o", out, src });
        try argv.appendSlice(extra);
        try c.mustRun(try h.fmt(c.a, "cc lib{s}", .{name}), try c.m.cc(argv.items));
    }

    /// lib/mojo/<name>.mopm.json content.
    fn meta(c: *Ctx, name: []const u8, deps: []const u8, needs: []const u8) ![]u8 {
        return h.fmt(c.a,
            \\{{"schema": 1, "name": "{s}", "version": "1.0.0", "deps": {s},
            \\ "native": [{{"id": "{s}", "soname": "lib{s}.{s}", "file": "../lib{s}.{s}", "needs": {s}}}]}}
            \\
        , .{ name, deps, name, name, mojo_env.ext, name, mojo_env.ext, needs });
    }

    /// The three packages, as spec/channel.md lays them out.
    fn install(c: *Ctx, prefix: []const u8) !void {
        const cwd = std.fs.cwd();
        for ([_][]const u8{ "greet", "inner", "outer" }) |p| {
            try cwd.copyFile(try h.fmt(c.a, "{s}/lib{s}.{s}", .{ c.natives, p, mojo_env.ext }), cwd, try h.fmt(c.a, "{s}/lib/lib{s}.{s}", .{ prefix, p, mojo_env.ext }), .{});
            try cwd.copyFile(try h.fmt(c.a, "{s}/{s}.mojoc", .{ c.pkgs, p }), cwd, try h.fmt(c.a, "{s}/lib/mojo/{s}.mojoc", .{ prefix, p }), .{});
        }
        try h.writeFile(try h.fmt(c.a, "{s}/lib/mojo/greet.mopm.json", .{prefix}), try c.meta("greet", "[]", "[]"));
        try h.writeFile(try h.fmt(c.a, "{s}/lib/mojo/inner.mopm.json", .{prefix}), try c.meta("inner", "[]", "[]"));
        try h.writeFile(try h.fmt(c.a, "{s}/lib/mojo/outer.mopm.json", .{prefix}), try c.meta("outer", "[{\"name\": \"inner\"}]", try h.fmt(c.a, "[\"libinner.{s}\"]", .{mojo_env.ext})));
    }

    fn wantFor(prog: []const u8) []const []const u8 {
        return if (std.mem.eql(u8, prog, "prog")) &values else values[2..];
    }

    /// Exit 0 and every line the program must print (`expect` of run.sh).
    fn expect(c: *Ctx, label: []const u8, r: h.Ran, prog: []const u8) void {
        var ok = !r.signaled and r.code == 0;
        var detail = std.ArrayList(u8).init(c.a);
        if (!ok) detail.writer().print("exit {d}, want 0; ", .{r.code}) catch {};
        for (wantFor(prog)) |w| {
            if (!h.contains(r.text, w)) {
                ok = false;
                detail.writer().print("no '{s}' in the output; ", .{w}) catch {};
            }
        }
        if (!ok) detail.writer().print("output:\n{s}", .{r.text}) catch {};
        c.rep.check(label, ok, detail.items);
    }

    /// None of the values in the output, and (when `must_fail`) a non-zero exit.
    fn refuse(c: *Ctx, label: []const u8, r: h.Ran, must_fail: bool) void {
        var ok = true;
        if (must_fail and !r.signaled and r.code == 0) ok = false;
        for (values) |v| if (h.contains(r.text, v)) {
            ok = false;
        };
        c.rep.check(label, ok, "the control printed a value or exited 0; output:\n");
        if (!ok) std.debug.print("{s}\n", .{r.text});
    }

    fn mopmRun(c: *Ctx, prefix: []const u8, args: []const []const u8, stdin: ?[]const u8) !h.Ran {
        var env = try c.m.freshEnv();
        const argv = try c.a.alloc([]const u8, args.len + 3);
        argv[0] = c.mopm;
        @memcpy(argv[1 .. args.len + 1], args);
        argv[args.len + 1] = "--prefix";
        argv[args.len + 2] = prefix;
        return h.run(c.a, argv, &env, .{ .stdin_path = stdin });
    }

    fn layout(c: *Ctx, name: []const u8, prefix: []const u8, prog: []const u8, repl_stdin: []const u8) !void {
        const dir = try h.fmt(c.a, "{s}/{s}/{s}", .{ c.out, name, prog });
        try std.fs.cwd().makePath(dir);
        const src = try h.fmt(c.a, "{s}/{s}.mojo", .{ c.here, prog });
        const bin = try h.fmt(c.a, "{s}/prog", .{dir});
        const stdin = try h.fmt(c.a, "{s}/{s}", .{ c.here, repl_stdin });

        const b = try c.mopmRun(prefix, &.{ "build", src, "-o", bin }, null);
        if (b.signaled or b.code != 0) {
            c.rep.check(try h.fmt(c.a, "{s}, {s}: mopm build", .{ name, prog }), false, b.text);
        } else {
            var empty = std.process.EnvMap.init(c.a);
            const r = try h.run(c.a, &.{bin}, &empty, .{});
            c.expect(try h.fmt(c.a, "{s}, {s}: mopm build, then the binary in an empty environment", .{ name, prog }), r, prog);
        }
        const r = try c.mopmRun(prefix, &.{ "run", src }, null);
        c.expect(try h.fmt(c.a, "{s}, {s}: mopm run", .{ name, prog }), r, prog);
        if (!c.have_repl) {
            c.skipRepl(try h.fmt(c.a, "{s}, {s}: mopm repl", .{ name, prog }));
            return;
        }
        const rr = try c.mopmRun(prefix, &.{"repl"}, stdin);
        c.expect(try h.fmt(c.a, "{s}, {s}: mopm repl, stdin with a blank line between expressions", .{ name, prog }), rr, prog);
    }
};

test "autolink: mopm build, run and repl with native libraries (tests/e2e/run.sh)" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    try h.watchdog(1500);
    var rep = h.Report{};
    run(a, &rep) catch |e| switch (e) {
        error.Fatal => {},
        else => return e,
    };
    try rep.finish();
}

/// Whether a line that is not a comment mentions `inner`.
fn namesInner(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "#")) continue;
        if (h.contains(l, "inner")) return true;
    }
    return false;
}

fn run(a: Allocator, rep: *h.Report) !void {
    const m = try mojo_env.Mojo.init(a);
    var c = Ctx{
        .a = a,
        .rep = rep,
        .m = m,
        .mopm = try h.toolPathAbs(a, "MOPM"),
        .here = try h.join(a, &.{ m.work, "tests/e2e" }),
        .natives = try h.join(a, &.{ m.work, "out/natives" }),
        .pkgs = try h.join(a, &.{ m.work, "out/pkgs" }),
        .out = try h.join(a, &.{ m.work, "out" }),
        .have_repl = blk: {
            std.fs.cwd().access(try h.join(a, &.{ m.tc, "bin/mojo-lldb" }), .{}) catch break :blk false;
            break :blk true;
        },
    };
    const cwd = std.fs.cwd();
    try cwd.makePath(c.natives);
    try cwd.makePath(c.pkgs);

    // The Mojo environment: the pinned toolchain as a prefix with the
    // compiler's library directory as its lib ("pixi" layout).
    const pixi = try h.join(a, &.{ m.work, "out/pixi" });
    try m.prefix(pixi, true);
    const v = try m.run(pixi, &.{"--version"}, null);
    std.debug.print("== mojo: {s}", .{v.text});

    // 1. natives
    try c.shlib("greet", &.{});
    try c.shlib("inner", &.{});
    try c.shlib("outer", &.{ try h.fmt(a, "-L{s}", .{c.natives}), "-linner" });
    const outer = try mojo_env.dynamic(a, try h.fmt(a, "{s}/libouter.{s}", .{ c.natives, mojo_env.ext }));
    rep.check("fixture: libouter needs libinner and has no run path", outer.needs(try h.fmt(a, "libinner.{s}", .{mojo_env.ext})) and !outer.has_run_path, "libouter lacks libinner as a needed library (DT_NEEDED, macOS: @rpath/libinner.dylib), or has a run path");

    // 2. packages
    for ([_][]const u8{ "greet", "inner", "outer" }) |p| {
        const r = try m.run(pixi, &.{ "precompile", try h.fmt(a, "{s}/pkgs/{s}", .{ c.here, p }), "-o", try h.fmt(a, "{s}/{s}.mojoc", .{ c.pkgs, p }) }, null);
        try c.mustRun(try h.fmt(a, "mojo precompile {s}", .{p}), r);
    }

    // The outer-only program must not reach inner by itself.
    const outer_src = try h.readFile(a, try h.join(a, &.{ c.here, "prog_outer.mojo" }));
    const outer_repl = try h.readFile(a, try h.join(a, &.{ c.here, "repl_outer.stdin" }));
    rep.check("fixture: the outer-only program names inner nowhere", !namesInner(outer_src) and !namesInner(outer_repl), "prog_outer.mojo or repl_outer.stdin names inner outside a comment");

    // 3. the split prefix
    const split = try h.join(a, &.{ m.work, "out/split" });
    try m.prefix(split, false);
    try c.install(split);
    try std.fs.cwd().access(try h.fmt(a, "{s}/lib", .{m.tc}), .{});
    const leak = std.fs.cwd().access(try h.fmt(a, "{s}/lib/libinner.{s}", .{ m.tc, mojo_env.ext }), .{});
    rep.check("split: libinner is not in the toolchain's lib", leak == error.FileNotFound, "libinner is in the toolchain's lib");

    // Controls (split only): libinner named nowhere, so libouter cannot load.
    const lib = try h.fmt(a, "{s}/lib", .{split});
    const prog_src = try h.join(a, &.{ c.here, "prog.mojo" });
    const ctl1 = try m.run(split, &.{ "run", "-Xlinker", try h.fmt(a, "{s}/libgreet.{s}", .{ lib, mojo_env.ext }), "-Xlinker", try h.fmt(a, "{s}/libouter.{s}", .{ lib, mojo_env.ext }), prog_src }, null);
    c.refuse("control, split: mojo run without libinner fails", ctl1, true);
    rep.check("control, split: the mojo run failure names libinner", h.contains(ctl1.text, "libinner"), ctl1.text);
    const ctl3 = try m.run(split, &.{ "run", "-Xlinker", try h.fmt(a, "{s}/libouter.{s}", .{ lib, mojo_env.ext }), try h.join(a, &.{ c.here, "prog_outer.mojo" }) }, null);
    c.refuse("control, split: mojo run of the outer-only program without libinner fails", ctl3, true);
    rep.check("control, split: the outer-only mojo run failure names libinner", h.contains(ctl3.text, "libinner"), ctl3.text);
    if (!c.have_repl) {
        c.skipRepl("control, split: mojo repl without libinner preloaded prints nothing");
    } else {
        var e = try m.freshEnv();
        try e.put("MODULAR_HOME", try h.fmt(a, "{s}/share/max", .{split}));
        const pre = try h.fmt(a, "settings set target.env-vars {s}={s}/libgreet.{s}:{s}/libouter.{s}", .{ mojo_env.preload_var, lib, mojo_env.ext, lib, mojo_env.ext });
        const ctl2 = try h.run(a, &.{ try h.fmt(a, "{s}/bin/mojo", .{split}), "repl", "-O", pre }, &e, .{ .stdin_path = try h.join(a, &.{ c.here, "repl.stdin" }) });
        c.refuse("control, split: mojo repl without libinner preloaded prints nothing", ctl2, false);
    }

    // 4. mopm
    try c.layout("split", split, "prog", "repl.stdin");
    try c.layout("split", split, "prog_outer", "repl_outer.stdin");
    try c.install(pixi);
    try c.layout("pixi", pixi, "prog", "repl.stdin");
    try c.layout("pixi", pixi, "prog_outer", "repl_outer.stdin");
}
