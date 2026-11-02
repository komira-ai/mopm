//! A static archive in a Mojo package, from `mopm pack` to a linked test binary, against the real Mojo of the farm
//! (komira's pinned Mojo 1.0.0, no pixi): the spikes of the natives design (PR 1a), run for real.
//!
//! What it does:
//!   1. C sources become two archives with zig (`cc -c`, `zig ar`): libbase_sys.a defines `base_sys_value`,
//!      libprobe_sys.a defines `probe_sys_answer`, which calls it, so libprobe_sys.a needs libbase_sys.a.
//!   2. Two Mojo packages whose module is EMPTY (a `-sys` package: no Mojo code, only the archive) are built as
//!      library units by `mopm unit build` (the real `mojo precompile`, through tests/drivers/mojo_compile_shim.zig as
//!      the toolchain's `mojo_compile`), then `mopm pack`ed with `--native`, and served by the fake registry's
//!      static files (index records and repodata written here, as resolve_e2e_test.zig does).
//!   3. A consumer project depends on probe_sys. `mopm lock` fetches the two package files over HTTP and pins the sha256
//!      of each archive; this test computes the same hashes from the archives it built, so a lock that pins the hash of
//!      anything else is red. `mopm plan --unit-graph` lists the natives needer-first.
//!   4. `mopm unit test` builds and runs a test that calls `probe_sys_answer` through the archives, with
//!      `--natives` holding them: it must link, and print what only the C code can produce.
//!
//! Spike answers it checks (and the PR text reports):
//!   - an empty-module package builds (`mojo precompile`), packs, and its archive links through `--natives`;
//!   - the lock's hash is the archive's, fetched through the channel, not the package file's;
//!   - the archives reach the compiler in the graph's order (needer first), and a link of the same archives given
//!     in the other order is what lld does (see the "order" check).
//!
//! Controls that must be able to fail: no archive in --natives, another archive in --natives (mopm refuses, exit 4),
//! and a link with no archive at all (the compiler's link fails naming the symbol: the archive is load-bearing).
//!
//! Run by Buck2 (//:native_static); MOPM, MOPM_FAKE_REGISTRY and MOJO_COMPILE_SHIM are the built programs.

const std = @import("std");
const h = @import("harness.zig");
const mojo_env = @import("mojo_env.zig");
const Allocator = std.mem.Allocator;

const c_base = "int base_sys_value(void) { return 1000; }\n";
const c_probe = "int base_sys_value(void);\nint probe_sys_answer(void) { return base_sys_value() + 243; }\n";

const test_mojo =
    \\from std.ffi import external_call
    \\import probe_sys
    \\
    \\
    \\def main():
    \\    print("probe", Int(external_call["probe_sys_answer", Int32]()))
    \\
;

const probe_toml =
    \\[package]
    \\name = "probe_sys"
    \\version = "1.0.0"
    \\mojo = ["1.0.0"]
    \\
    \\[dependencies]
    \\base_sys = { path = "base", version = "1.0" }
    \\
    \\[native.probe_sys]
    \\kind = "static"
    \\srcs = ["native/probe_sys.c"]
    \\needs = ["libbase_sys.a"]
    \\
;

const base_toml =
    \\[package]
    \\name = "base_sys"
    \\version = "1.0.0"
    \\mojo = ["1.0.0"]
    \\
    \\[native.base_sys]
    \\kind = "static"
    \\srcs = ["native/base_sys.c"]
    \\
;

const app_toml =
    \\[package]
    \\name = "app"
    \\version = "1.0.0"
    \\mojo = ["1.0.0"]
    \\
    \\[dependencies]
    \\probe_sys = "1.0"
    \\
;

fn sha256Hex(a: Allocator, bytes: []const u8) ![]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(out, .lower));
}

const Ctx = struct {
    a: Allocator,
    rep: *h.Report,
    m: mojo_env.Mojo,
    mopm: []const u8,
    /// Environment of the mopm commands: nothing of the farm's, no token.
    env: std.process.EnvMap,

    fn mopmRun(c: *Ctx, dir: []const u8, args: []const []const u8) !h.Ran {
        const argv = try c.a.alloc([]const u8, args.len + 1);
        argv[0] = c.mopm;
        @memcpy(argv[1..], args);
        return h.run(c.a, argv, &c.env, .{ .cwd = dir });
    }

    fn must(c: *Ctx, what: []const u8, r: h.Ran) !void {
        if (r.signaled or r.code != 0) {
            std.debug.print("FAIL {s}: exit {d}\n{s}\n", .{ what, r.code, r.text });
            c.rep.failures += 1;
            return error.Fatal;
        }
        std.debug.print("ok   {s}\n", .{what});
    }

    /// `ar` over `objs` into `out`: zig's on the farm, the system's on a runner.
    fn archive(c: *Ctx, out: []const u8, objs: []const []const u8) !h.Ran {
        var e = try c.m.freshEnv();
        var argv = std.ArrayList([]const u8).init(c.a);
        if (c.m.base.get("MOPM_ZIG")) |zig| {
            try argv.appendSlice(&.{ zig, "ar", "rcs", out });
        } else {
            try argv.appendSlice(&.{ "ar", "rcs", out });
        }
        try argv.appendSlice(objs);
        return h.run(c.a, argv.items, &e, .{});
    }

    /// A C file compiled into `libname.a` in `dir`.
    fn cArchive(c: *Ctx, dir: []const u8, name: []const u8, source: []const u8) ![]const u8 {
        const src = try h.join(c.a, &.{ dir, try h.fmt(c.a, "{s}.c", .{name}) });
        const obj = try h.join(c.a, &.{ dir, try h.fmt(c.a, "{s}.o", .{name}) });
        const lib = try h.join(c.a, &.{ dir, try h.fmt(c.a, "lib{s}.a", .{name}) });
        try h.writeFile(src, source);
        try c.must(try h.fmt(c.a, "cc -c {s}", .{name}), try c.m.cc(&.{ "-c", "-O1", "-fPIC", "-o", obj, src }));
        try c.must(try h.fmt(c.a, "ar lib{s}.a", .{name}), try c.archive(lib, &.{obj}));
        return lib;
    }
};

/// The value after `key ` on the first line of `text` that has it.
fn valueOf(a: Allocator, text: []const u8, key: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " ");
        if (std.mem.startsWith(u8, t, key) and t.len > key.len and t[key.len] == ' ') return a.dupe(u8, t[key.len + 1 ..]);
    }
    return "";
}

/// What a package of the registry is, as `mopm pack` made it.
const Pack = struct { name: []const u8, soname: []const u8, deps: []const u8, file: []const u8, bytes: []const u8, sha256: []const u8, manifest_sha256: []const u8 };

fn writeRegistryFiles(a: Allocator, root: []const u8, base: []const u8, packs: []const Pack) !void {
    var entries = std.ArrayList(u8).init(a);
    for (packs) |p| {
        const rec = try h.fmt(a,
            "{{\"v\":1,\"name\":\"{s}\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"state\":\"published\",\"published_at\":\"2026-10-13T12:00:00Z\"," ++
                "\"requires_mojo\":\"==1.0.0\",\"deps\":[{s}],\"native\":[{{\"id\":\"{s}\",\"soname\":\"{s}\"}}]," ++
                "\"files\":[{{\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d},\"subdir\":\"linux-64\",\"url\":\"{s}/channel/linux-64/{s}\"}}]," ++
                "\"manifest_sha256\":\"{s}\"}}\n",
            .{ p.name, p.deps, p.name, p.soname, p.file, p.sha256, p.bytes.len, base, p.file, p.manifest_sha256 },
        );
        var padded: [4]u8 = "____".*;
        for (p.name[0..@min(p.name.len, 4)], 0..) |b, i| padded[i] = b;
        try h.writeFile(try h.fmt(a, "{s}/index/{s}/{s}/{s}", .{ root, padded[0..2], padded[2..4], p.name }), rec);
        try h.writeFile(try h.fmt(a, "{s}/channel/linux-64/{s}", .{ root, p.file }), p.bytes);
        if (entries.items.len > 0) try entries.append(',');
        try entries.writer().print(
            "\"{s}\":{{\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"depends\":[\"mojo-compiler ==1.0.0\"],\"name\":\"mojo-{s}\",\"sha256\":\"{s}\",\"size\":{d},\"subdir\":\"linux-64\",\"version\":\"1.0.0\"}}",
            .{ p.file, p.name, p.sha256, p.bytes.len },
        );
    }
    try h.writeFile(try h.fmt(a, "{s}/channel/linux-64/repodata.json", .{root}), try h.fmt(a, "{{\"info\":{{\"subdir\":\"linux-64\"}},\"packages\":{{}},\"packages.conda\":{{{s}}},\"removed\":[]}}\n", .{entries.items}));
}

test "native_static: an archive in an empty-module package, from mopm pack to a linked test (spikes of the natives design)" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    var rep = h.Report{};
    run(a, &rep) catch |e| switch (e) {
        error.Fatal => {},
        else => return e,
    };
    try rep.finish();
}

fn run(a: Allocator, rep: *h.Report) !void {
    const m = try mojo_env.Mojo.init(a);
    var env = try h.environ(a);
    env.remove("MOPM_TOKEN");
    var c = Ctx{ .a = a, .rep = rep, .m = m, .mopm = try h.toolPathAbs(a, "MOPM"), .env = env };
    const work = try h.join(a, &.{ m.work, "natives" });
    const cwd = std.fs.cwd();
    try cwd.makePath(work);

    // The compiler as prefix, as the autolink driver does.
    const pixi = try h.join(a, &.{ work, "pixi" });
    try m.prefix(pixi, true);

    // 1. The archives.
    const natives = try h.join(a, &.{ work, "natives" });
    const c_dir = try h.join(a, &.{ work, "c" });
    const base_ar = try c.cArchive(c_dir, "base_sys", c_base);
    const probe_ar = try c.cArchive(c_dir, "probe_sys", c_probe);
    try cwd.makePath(natives);
    try cwd.copyFile(base_ar, cwd, try h.join(a, &.{ natives, "libbase_sys.a" }), .{});
    try cwd.copyFile(probe_ar, cwd, try h.join(a, &.{ natives, "libprobe_sys.a" }), .{});
    const base_bytes = try h.readFile(a, base_ar);
    const probe_bytes = try h.readFile(a, probe_ar);
    rep.check("the archives are ar archives", std.mem.startsWith(u8, base_bytes, "!<arch>\n") and std.mem.startsWith(u8, probe_bytes, "!<arch>\n"), "zig ar made something else");

    // 2. The toolchain directory mopm unit runs: the shim as `mojo_compile`, its configuration, the closure hash, the runtime libraries.
    const tc = try h.join(a, &.{ work, "tc" });
    const log = try h.join(a, &.{ work, "mojo_compile.log" });
    try cwd.makePath(tc);
    try cwd.copyFile(try h.toolPathAbs(a, "MOJO_COMPILE_SHIM"), cwd, try h.join(a, &.{ tc, "mojo_compile" }), .{});
    {
        const f = try cwd.openFile(try h.join(a, &.{ tc, "mojo_compile" }), .{});
        defer f.close();
        try f.chmod(0o755);
    }
    {
        var conf = std.ArrayList(u8).init(a);
        try conf.writer().print("mojo={s}/bin/mojo\nlog={s}\nenv.MODULAR_HOME={s}/share/max\n", .{ pixi, log, pixi });
        var it = m.base.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "MODULAR_HOME")) continue;
            try conf.writer().print("env.{s}={s}\n", .{ e.key_ptr.*, e.value_ptr.* });
        }
        try h.writeFile(try h.join(a, &.{ tc, "mojo_compile.conf" }), conf.items);
    }
    try cwd.symLink(try h.join(a, &.{ m.tc, "lib" }), try h.join(a, &.{ tc, "lib" }), .{});

    // 3. The two packages whose module is empty, as a workspace: libraries built by `mopm unit build`.
    const ws = try h.join(a, &.{ work, "ws" });
    try h.writeFile(try h.join(a, &.{ ws, "mopm.toml" }), probe_toml);
    try h.writeFile(try h.join(a, &.{ ws, "src/probe_sys/__init__.mojo" }), "");
    // A unit graph builds a member's native from its C sources, so each member declares them (the archives the
    // test links are the ones built above; these sources only satisfy the manifests).
    try h.writeFile(try h.join(a, &.{ ws, "native/probe_sys.c" }), c_probe);
    try h.writeFile(try h.join(a, &.{ ws, "base/native/base_sys.c" }), c_base);
    try h.writeFile(try h.join(a, &.{ ws, "base/mopm.toml" }), base_toml);
    try h.writeFile(try h.join(a, &.{ ws, "base/src/base_sys/__init__.mojo" }), "");
    var r = try c.mopmRun(ws, &.{"lock"});
    try c.must("mopm lock of the workspace of the two empty-module packages (path dependency, offline)", r);
    const ws_graph = try h.join(a, &.{ work, "ws_graph.json" });
    r = try c.mopmRun(ws, &.{ "plan", "--unit-graph", "--locked", "--mojo", "1.0.0", "-o", ws_graph });
    try c.must("mopm plan --unit-graph of a workspace whose modules are empty (defaultLib accepts them)", r);
    const graph_doc = try h.parseJson(a, try h.readFile(a, ws_graph));
    const closure = blk: {
        const tcv = graph_doc.object.get("toolchain") orelse return error.BadGraph;
        break :blk h.jsonString(tcv, "closure_sha256") orelse return error.BadGraph;
    };
    try h.writeFile(try h.join(a, &.{ tc, "CLOSURE_SHA256" }), try h.fmt(a, "{s}\n", .{closure}));

    const deps = try h.join(a, &.{ work, "deps" });
    try cwd.makePath(deps);
    const lib_out = try h.join(a, &.{ work, "lib_out" });
    for ([_][]const u8{ "base_sys", "probe_sys" }) |name| {
        r = try c.mopmRun(ws, &.{ "unit", "build", "--unit", try h.fmt(a, "{s}@1.0.0#mojo1.0.0/lib", .{name}), "--graph", ws_graph, "--out", lib_out, "--toolchain", tc, "--src", ".", "--deps", deps, "--natives", natives, "--stage", try h.fmt(a, "{s}/stage_{s}", .{ work, name }) });
        try c.must(try h.fmt(a, "mopm unit build: the empty module {s} through the real `mojo precompile`", .{name}), r);
        const mojoc = try h.join(a, &.{ lib_out, try h.fmt(a, "{s}.mojoc", .{name}) });
        try cwd.copyFile(mojoc, cwd, try h.join(a, &.{ deps, try h.fmt(a, "{s}.mojoc", .{name}) }), .{});
        const bytes = try h.readFile(a, mojoc);
        rep.check(try h.fmt(a, "the {s}.mojoc of an empty module is not empty", .{name}), bytes.len > 0, "zero bytes");
    }

    // 4. mopm pack, with the archive of each package.
    const dist = try h.join(a, &.{ work, "dist" });
    var packs = std.ArrayList(Pack).init(a);
    const Spec = struct { name: []const u8, manifest: []const u8, soname: []const u8, lib: []const u8, deps: []const u8 };
    for ([_]Spec{
        .{ .name = "base_sys", .manifest = "base/mopm.toml", .soname = "libbase_sys.a", .lib = base_ar, .deps = "" },
        .{ .name = "probe_sys", .manifest = "mopm.toml", .soname = "libprobe_sys.a", .lib = probe_ar, .deps = "{\"name\":\"base_sys\",\"range\":\"1.0\"}" },
    }) |s| {
        r = try c.mopmRun(ws, &.{
            "pack",      "--compiler", "1.0.0",
            "--manifest", s.manifest,  "-o",
            dist,        "--mojoc",    try h.fmt(a, "linux-64={s}/{s}.mojoc", .{ deps, s.name }),
            "--native",  try h.fmt(a, "{s}=linux-64:{s}", .{ s.name, s.lib }),
        });
        try c.must(try h.fmt(a, "mopm pack {s} with its archive", .{s.name}), r);
        const file = try h.fmt(a, "mojo-{s}-1.0.0-mojo1.0.0_0.conda", .{s.name});
        const bytes = try h.readFile(a, try h.join(a, &.{ dist, "linux-64", file }));
        try packs.append(.{ .name = s.name, .soname = s.soname, .deps = s.deps, .file = file, .bytes = bytes, .sha256 = try sha256Hex(a, bytes), .manifest_sha256 = try valueOf(a, r.text, "manifest_sha256") });
    }

    // 5. A registry that serves them, and the consumer.
    var fake = try h.Fake.start(a, try h.toolPathAbs(a, "MOPM_FAKE_REGISTRY"), try h.join(a, &.{ work, "fake" }));
    defer fake.close();
    try writeRegistryFiles(a, try h.join(a, &.{ work, "fake" }), fake.base, packs.items);
    const app = try h.join(a, &.{ work, "app" });
    try h.writeFile(try h.join(a, &.{ app, "mopm.toml" }), app_toml);
    try h.writeFile(try h.join(a, &.{ app, "tests/test_probe.mojo" }), test_mojo);
    r = try c.mopmRun(app, &.{ "lock", "--registry", fake.base });
    try c.must("mopm lock of a project that depends on probe_sys: it fetches both package files and pins their archives", r);
    const lock_text = try h.readFile(a, try h.join(a, &.{ app, "mopm.lock" }));
    const probe_sha = try sha256Hex(a, probe_bytes);
    const base_sha = try sha256Hex(a, base_bytes);
    rep.check("the lock pins libprobe_sys.a: the sha256 of the archive, its kind and its need", h.contains(lock_text, try h.fmt(a,
        "\"soname\": \"libprobe_sys.a\",\n          \"sha256\": \"{s}\",\n          \"kind\": \"static\",\n          \"needs\": [\n            \"libbase_sys.a\"\n          ]",
        .{probe_sha},
    )), lock_text);
    rep.check("the lock pins libbase_sys.a: the sha256 of the archive and its kind", h.contains(lock_text, try h.fmt(a,
        "\"soname\": \"libbase_sys.a\",\n          \"sha256\": \"{s}\",\n          \"kind\": \"static\"",
        .{base_sha},
    )), lock_text);
    rep.check("the lock pins no hash of a package file as a native's", !h.contains(lock_text, try h.fmt(a, "\"sha256\": \"{s}\",\n          \"kind\"", .{packs.items[1].sha256})), lock_text);

    const graph_path = try h.join(a, &.{ work, "graph.json" });
    r = try c.mopmRun(app, &.{ "plan", "--unit-graph", "--locked", "-o", graph_path });
    try c.must("mopm plan --unit-graph of the consumer", r);
    const test_id = "app@1.0.0#mojo1.0.0/test:tests/test_probe.mojo";
    const graph = try h.parseJson(a, try h.readFile(a, graph_path));
    var order = std.ArrayList(u8).init(a);
    for ((graph.object.get("units") orelse return error.BadGraph).array.items) |u| {
        if (!std.mem.eql(u8, h.jsonString(u, "id") orelse "", test_id)) continue;
        for ((u.object.get("natives") orelse return error.BadGraph).array.items) |n| {
            if (order.items.len > 0) try order.append(' ');
            try order.appendSlice(h.jsonString(n, "soname") orelse "?");
        }
    }
    rep.check("the graph lists the natives of the test needer-first: libprobe_sys.a before libbase_sys.a", std.mem.eql(u8, order.items, "libprobe_sys.a libbase_sys.a"), order.items);

    // 6. The link, through mopm unit test, with the archives in --natives.
    const out = try h.join(a, &.{ work, "out" });
    const stage = try h.join(a, &.{ work, "stage_test" });
    const unit_args = [_][]const u8{ "--unit", test_id, "--graph", graph_path, "--out", out, "--toolchain", tc, "--src", ".", "--deps", deps, "--natives", natives, "--stage", stage };
    r = try c.mopmRun(app, &([_][]const u8{ "unit", "test" } ++ unit_args));
    rep.check("mopm unit test: the test links the archives through --natives, runs, and prints what only the C code gives", !r.signaled and r.code == 0 and h.contains(r.text, "probe 1243"), try h.fmt(a, "exit {d}:\n{s}", .{ r.code, r.text }));
    const logged = try h.readFile(a, log);
    const natives_real = try cwd.realpathAlloc(a, natives);
    rep.check("the compiler was given the archives in the graph's order, each as -Xlinker", h.contains(logged, try h.fmt(a, "-Xlinker {s}/libprobe_sys.a -Xlinker {s}/libbase_sys.a", .{ natives_real, natives_real })), logged);
    cwd.access(try h.join(a, &.{ out, "test_probe.pass" }), .{}) catch rep.check("the pass marker is written", false, "no test_probe.pass");

    // 7. Controls: each of these must be able to fail.
    // 7a. An archive that is not in --natives: mopm refuses before running anything.
    const bare = try h.join(a, &.{ work, "natives_bare" });
    try cwd.makePath(bare);
    try cwd.copyFile(base_ar, cwd, try h.join(a, &.{ bare, "libbase_sys.a" }), .{});
    r = try c.mopmRun(app, &([_][]const u8{ "unit", "build", "--unit", test_id, "--graph", graph_path, "--out", try h.join(a, &.{ work, "out_a" }), "--toolchain", tc, "--src", ".", "--deps", deps, "--natives", bare, "--stage", try h.join(a, &.{ work, "stage_a" }) }));
    rep.check("control: an archive missing from --natives is refused (4), naming it", !r.signaled and r.code == 4 and h.contains(r.text, "native library libprobe_sys.a (probe_sys) is not in"), try h.fmt(a, "exit {d}: {s}", .{ r.code, r.text }));
    // 7b. Another archive under the same name: the sha256 refuses it.
    const other = try h.join(a, &.{ work, "natives_other" });
    try cwd.makePath(other);
    try cwd.copyFile(base_ar, cwd, try h.join(a, &.{ other, "libbase_sys.a" }), .{});
    try cwd.copyFile(base_ar, cwd, try h.join(a, &.{ other, "libprobe_sys.a" }), .{});
    r = try c.mopmRun(app, &([_][]const u8{ "unit", "build", "--unit", test_id, "--graph", graph_path, "--out", try h.join(a, &.{ work, "out_b" }), "--toolchain", tc, "--src", ".", "--deps", deps, "--natives", other, "--stage", try h.join(a, &.{ work, "stage_b" }) }));
    rep.check("control: another archive under the name is refused (4) on its sha256", !r.signaled and r.code == 4 and h.contains(r.text, "native library libprobe_sys.a has sha256"), try h.fmt(a, "exit {d}: {s}", .{ r.code, r.text }));

    // 7c0. Stock zig refuses `-Xlinker <archive>` ("unsupported linker arg"): what `mopm unit build` passes needs the
    // `cc` shim of the wrapper, which hands the operand to zig as an input file (buildrules' cc_shim.zig; tests/drivers/zigcc.zig
    // does the same here). The farm only: a runner links through the system cc, which takes it as it is.
    if (c.m.base.get("MOPM_ZIG")) |zig| {
        const main_c = try h.join(a, &.{ work, "c/main.c" });
        try h.writeFile(main_c, "int main(void) { return 0; }\n");
        var e = try c.m.freshEnv();
        const raw = try h.run(a, &.{ zig, "cc", "-target", "x86_64-linux-gnu.2.34", "-o", try h.join(a, &.{ work, "c/raw_main" }), main_c, "-Xlinker", base_ar }, &e, .{});
        rep.check("stock zig cc refuses a bare -Xlinker operand (unsupported linker arg): the wrapper's cc shim must rewrite it", !raw.signaled and raw.code != 0 and h.contains(raw.text, "unsupported linker arg"), try h.fmt(a, "exit {d}: {s}", .{ raw.code, raw.text }));
    }

    // 7c. The compiler alone: the same program with no archive does not link, and the failure names the symbol; with the
    // archives in the order a needer-last list gives, it does link (what lld does with archive order).
    const inc_base = try h.join(a, &.{ work, "inc/base_sys" });
    const inc_probe = try h.join(a, &.{ work, "inc/probe_sys" });
    try cwd.makePath(inc_base);
    try cwd.makePath(inc_probe);
    try cwd.copyFile(try h.join(a, &.{ deps, "base_sys.mojoc" }), cwd, try h.join(a, &.{ inc_base, "base_sys.mojoc" }), .{});
    try cwd.copyFile(try h.join(a, &.{ deps, "probe_sys.mojoc" }), cwd, try h.join(a, &.{ inc_probe, "probe_sys.mojoc" }), .{});
    const src = try h.join(a, &.{ app, "tests/test_probe.mojo" });
    const i_base = try h.fmt(a, "-I{s}", .{inc_base});
    const i_probe = try h.fmt(a, "-I{s}", .{inc_probe});
    const none = try c.m.run(pixi, &.{ "build", i_base, i_probe, src, "-o", try h.join(a, &.{ work, "x_none" }) }, null);
    rep.check("control: without the archives the link fails, naming probe_sys_answer", !none.signaled and none.code != 0 and h.contains(none.text, "probe_sys_answer"), try h.fmt(a, "exit {d}: {s}", .{ none.code, none.text }));
    const needer_first = try c.m.run(pixi, &.{ "build", i_base, i_probe, src, "-o", try h.join(a, &.{ work, "x_first" }), "-Xlinker", probe_ar, "-Xlinker", base_ar }, null);
    rep.check("order: needer first (the order mopm gives) links", !needer_first.signaled and needer_first.code == 0, try h.fmt(a, "exit {d}: {s}", .{ needer_first.code, needer_first.text }));
    const provider_first = try c.m.run(pixi, &.{ "build", i_base, i_probe, src, "-o", try h.join(a, &.{ work, "x_second" }), "-Xlinker", base_ar, "-Xlinker", probe_ar }, null);
    // Recorded: whether the pinned linker (lld) cares about the order of archives. The check holds the observed answer.
    rep.check("order: provider first links too, so lld does not care about the order of archives", !provider_first.signaled and provider_first.code == 0, try h.fmt(a, "exit {d}: {s}", .{ provider_first.code, provider_first.text }));
}
