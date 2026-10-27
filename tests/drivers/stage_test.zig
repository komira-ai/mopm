//! End-to-end tests of `mopm stage` against the fake registry, and of `mopm publish --staged` on what it writes.
//!
//! Run by Buck2 (//:stage): MOPM and MOPM_FAKE_REGISTRY are the built programs. Each check prints `ok` or `FAIL`. The
//! workspace is three packages, written in an order and with names that sort the other way from their dependencies:
//! stg_z is the base, stg_m needs it, stg_a needs stg_m.
//!
//! What can go red, and why:
//! - `mopm stage` must order the set by dependency (z, m, a), write a plan that `publish --staged --dry-run` reads without
//!   a token, and need no token itself (it runs with none in its environment); the set it writes must publish through the
//!   fake registry, and staging it again must skip all three;
//! - the registry's answer must decide each member: the same version with other bytes, a yanked version and a burned one
//!   (a takedown) each make the stage end 1 and the plan refuse that member (so `publish --staged` refuses the whole set
//!   before any request), and a burned one must say to bump the version;
//! - a cycle must end 1 and leave no staged directory; two stages of one workspace must give the same bytes;
//! - no token (the API token, the login's) is printed.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

const dead = "http://127.0.0.1:1"; // nothing listens here

const Out = struct { code: u8, stdout: []u8, stderr: []u8 };

const Mopm = struct {
    a: Allocator,
    exe: []const u8,
    /// This process's environment without MOPM_TOKEN.
    env: std.process.EnvMap,
    everything: *std.ArrayList(u8),

    fn run(m: Mopm, args: []const []const u8, token: ?[]const u8) !Out {
        const argv = try m.a.alloc([]const u8, args.len + 1);
        argv[0] = m.exe;
        @memcpy(argv[1..], args);
        var env = try h.cloneEnv(m.a, &m.env);
        if (token) |t| try env.put("MOPM_TOKEN", t);
        const r = try std.process.Child.run(.{ .allocator = m.a, .argv = argv, .env_map = &env, .max_output_bytes = 1 << 22 });
        try m.everything.appendSlice(r.stdout);
        try m.everything.appendSlice(r.stderr);
        return .{ .code = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        }, .stdout = r.stdout, .stderr = r.stderr };
    }
};

const names = [_][]const u8{ "stg_z", "stg_m", "stg_a" };

const World = struct {
    a: Allocator,
    rep: *h.Report,
    m: Mopm,
    fake: h.Fake,
    work: []const u8,
    conf: []const u8,
    token: []const u8,

    fn path(w: World, parts: []const []const u8) ![]const u8 {
        return h.join(w.a, parts);
    }

    /// A member of the workspace `ws` at `version`, with its `[dependencies]` lines, and the artifact `art` holds for it.
    fn member(w: World, ws: []const u8, art: []const u8, name: []const u8, version: []const u8, deps: []const u8, mojoc: []const u8) !void {
        const manifest = try std.fmt.allocPrint(w.a, "[package]\nname = \"{s}\"\nversion = \"{s}\"\nmojo = [\"1.0.0\"]\n\n[dependencies]\n{s}", .{ name, version, deps });
        try h.writeFile(try w.path(&.{ w.work, ws, "src", name, "mopm.toml" }), manifest);
        try h.writeFile(try w.path(&.{ w.work, ws, "src", name, "README.md" }), try std.fmt.allocPrint(w.a, "# {s}\n", .{name}));
        try h.writeFile(try w.path(&.{ w.work, art, "noarch", try std.fmt.allocPrint(w.a, "{s}.mojoc", .{name}) }), mojoc);
    }

    fn chain(w: World, ws: []const u8, art: []const u8, version: []const u8, z_mojoc: []const u8) !void {
        try w.member(ws, art, "stg_z", version, "", z_mojoc);
        try w.member(ws, art, "stg_m", version, "stg_z = { path = \"../stg_z\", version = \"1\" }\n", "the mojoc of m");
        try w.member(ws, art, "stg_a", version, "stg_m = { path = \"../stg_m\", version = \"^1.0\" }\n", "the mojoc of a");
    }

    fn stage(w: World, ws: []const u8, art: []const u8, out: []const u8, extra: []const []const u8) !Out {
        const base = [_][]const u8{
            "stage",            "--workspace-root", try w.path(&.{ w.work, ws }),
            "--artifacts",      try w.path(&.{ w.work, art }),
            "--compiler",       "1.0.0",
            "--out",            try w.path(&.{ w.work, out }),
            "--registry",       w.fake.base,
        };
        const argv = try std.mem.concat(w.a, []const u8, &.{ &base, extra });
        // No token: staging reads none.
        return w.m.run(argv, null);
    }

    fn stateOf(w: World, name: []const u8, version: []const u8) ![]const u8 {
        const r = try h.request(w.a, "GET", w.fake.base, try std.fmt.allocPrint(w.a, "/api/v1/packages/{s}/{s}", .{ name, version }), null, null);
        if (r.status != 200) return "absent";
        return h.jsonString(try h.parseJson(w.a, r.body), "state") orelse "unknown";
    }

    fn plan(w: World, out: []const u8) !std.json.Value {
        return h.parseJson(w.a, try h.readFile(w.a, try w.path(&.{ w.work, out, "plan.json" })));
    }

    fn action(plan_: std.json.Value, name: []const u8) []const u8 {
        for (plan_.object.get("members").?.array.items) |m| {
            if (std.mem.eql(u8, h.jsonString(m, "name") orelse "", name)) return h.jsonString(m, "action") orelse "";
        }
        return "(none)";
    }

    fn order(w: World, plan_: std.json.Value) ![]const u8 {
        var list = std.ArrayList([]const u8).init(w.a);
        for (plan_.object.get("members").?.array.items) |m| try list.append(h.jsonString(m, "name") orelse "");
        return std.mem.join(w.a, ",", list.items);
    }

    fn text(w: World, r: Out) ![]const u8 {
        return std.fmt.allocPrint(w.a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr });
    }

    fn exists(w: World, parts: []const []const u8) bool {
        const p = h.join(w.a, parts) catch return false;
        return if (std.fs.cwd().access(p, .{})) true else |_| false;
    }
};

fn stageAndPublishAChain(w: World) !void {
    try w.chain("ws", "art", "1.0.0", "the mojoc of z");
    const r = try w.stage("ws", "art", "set", &.{});
    w.rep.check("a chain is staged with no token, and the run ends 0", r.code == 0 and h.contains(r.stdout, "staged 3 members") and
        h.contains(r.stdout, "3 to upload, 0 skipped, 0 refused"), try w.text(r));
    const p = try w.plan("set");
    w.rep.check("the plan lists the base first and the top last, though the names sort the other way", std.mem.eql(u8, try w.order(p), "stg_z,stg_m,stg_a"), try w.order(p));
    w.rep.check("every member is an upload, with its package file and its readme in the set", std.mem.eql(u8, World.action(p, "stg_z"), "upload") and
        w.exists(&.{ w.work, "set", "noarch", "mojo-stg_z-1.0.0-mojo1.0.0_0.conda" }) and w.exists(&.{ w.work, "set", "stg_a", "README.md" }), "the set is not as expected");

    const dry = try w.m.run(&.{ "publish", "--staged", try w.path(&.{ w.work, "set" }), "--registry", dead, "--dry-run" }, null);
    w.rep.check("the staged plan is read by publish --staged --dry-run, which reads no token", dry.code == 0 and h.contains(dry.stdout, "would create one group of 3 members (3 files)") and
        h.contains(dry.stdout, "stg_z 1.0.0") and h.contains(dry.stdout, "dry run: nothing was sent"), try w.text(dry));

    const pub_ = try w.m.run(&.{ "publish", "--staged", try w.path(&.{ w.work, "set" }), "--registry", w.fake.base, "--config-dir", w.conf, "--wait", "60" }, w.token);
    var all = true;
    for (names) |n| all = all and std.mem.eql(u8, try w.stateOf(n, "1.0.0"), "published");
    w.rep.check("the staged set publishes through one group", pub_.code == 0 and all, try w.text(pub_));

    const again = try w.stage("ws", "art", "set_again", &.{});
    const p2 = try w.plan("set_again");
    w.rep.check("staging it again skips all three: same bytes, nothing to upload", again.code == 0 and h.contains(again.stdout, "0 to upload, 3 skipped, 0 refused") and
        std.mem.eql(u8, World.action(p2, "stg_a"), "skip") and !w.exists(&.{ w.work, "set_again", "noarch", "mojo-stg_a-1.0.0-mojo1.0.0_0.conda" }), try w.text(again));
    const idle = try w.m.run(&.{ "publish", "--staged", try w.path(&.{ w.work, "set_again" }), "--registry", w.fake.base, "--config-dir", w.conf }, w.token);
    w.rep.check("and publish --staged of that set has nothing to publish", idle.code == 0 and h.contains(idle.stdout, "nothing to publish"), try w.text(idle));
}

fn theRegistryDecides(w: World) !void {
    const a = w.a;
    // Other bytes under a published version.
    try w.chain("ws", "art_changed", "1.0.0", "the mojoc of z, changed");
    var r = try w.stage("ws", "art_changed", "set_changed", &.{});
    var p = try w.plan("set_changed");
    w.rep.check("a published version with other bytes is refused: the run ends 1, and the plan refuses only that member", r.code == 1 and
        h.contains(r.stderr, "stg_z 1.0.0 is already published with different bytes") and std.mem.eql(u8, World.action(p, "stg_z"), "refuse") and
        std.mem.eql(u8, World.action(p, "stg_m"), "skip"), try w.text(r));
    const pub_ = try w.m.run(&.{ "publish", "--staged", try w.path(&.{ w.work, "set_changed" }), "--registry", dead, "--config-dir", w.conf }, "mopm_unused");
    w.rep.check("and publish --staged refuses that set before it sends a request", pub_.code == 1 and h.contains(pub_.stderr, "the plan refuses stg_z 1.0.0") and
        !h.contains(pub_.stderr, "cannot reach"), try w.text(pub_));

    // A yanked version, even with the same bytes.
    const yank = try h.request(a, "PUT", w.fake.base, "/api/v1/packages/stg_m/1.0.0/yank", "{\"yanked\":true,\"reason\":\"broken build\"}", w.token);
    w.rep.check("a member is yanked", yank.status == 200, yank.body);
    r = try w.stage("ws", "art", "set_yanked", &.{});
    p = try w.plan("set_yanked");
    w.rep.check("a yanked version is refused with its reason", r.code == 1 and h.contains(r.stderr, "stg_m 1.0.0 is yanked: broken build") and
        std.mem.eql(u8, World.action(p, "stg_m"), "refuse"), try w.text(r));
    const restore = try h.request(a, "PUT", w.fake.base, "/api/v1/packages/stg_m/1.0.0/yank", "{\"yanked\":false}", w.token);
    w.rep.check("the member is restored", restore.status == 200, restore.body);

    // A burned version.
    _ = try w.fake.control(a, "/tombstone", "{\"name\":\"stg_a\",\"version\":\"1.0.0\",\"reason_code\":\"malware\"}");
    r = try w.stage("ws", "art", "set_burned", &.{});
    p = try w.plan("set_burned");
    w.rep.check("a burned version is refused, and the message says to bump the version", r.code == 1 and h.contains(r.stderr, "stg_a 1.0.0 was taken down") and
        h.contains(r.stderr, "bump the version") and std.mem.eql(u8, World.action(p, "stg_a"), "refuse"), try w.text(r));

    // Naming a package stages it and what it needs only: stg_m and stg_z are the same bytes, so both skip.
    r = try w.stage("ws", "art", "set_named", &.{"stg_m"});
    p = try w.plan("set_named");
    w.rep.check("naming stg_m stages stg_m and stg_z only, and both are skipped", r.code == 0 and std.mem.eql(u8, try w.order(p), "stg_z,stg_m") and
        std.mem.eql(u8, World.action(p, "stg_m"), "skip"), try w.text(r));
}

fn aCycleAndDeterminism(w: World) !void {
    const a = w.a;
    // A cycle: nothing staged.
    try w.member("cyc", "art_cyc", "stg_p", "0.1.0", "stg_q = { path = \"../stg_q\", version = \"0.1\" }\n", "p");
    try w.member("cyc", "art_cyc", "stg_q", "0.1.0", "stg_p = { path = \"../stg_p\", version = \"0.1\" }\n", "q");
    const cyc = try w.stage("cyc", "art_cyc", "set_cycle", &.{});
    w.rep.check("a cycle ends 1, names the packages, and stages nothing", cyc.code == 1 and h.contains(cyc.stderr, "stg_p, stg_q form a cycle") and
        !w.exists(&.{ w.work, "set_cycle" }), try w.text(cyc));

    // The same workspace twice: the same bytes, a plan with no loopback address in it, and packages with none either.
    try w.chain("ws2", "art2", "0.2.0", "the mojoc of z");
    try w.member("ws2", "art2", "stg_m", "0.2.0", "stg_z = { path = \"../stg_z\", version = \"0.2\" }\n", "the mojoc of m");
    try w.member("ws2", "art2", "stg_a", "0.2.0", "stg_m = { path = \"../stg_m\", version = \"0.2\" }\n", "the mojoc of a");
    const one = try w.stage("ws2", "art2", "set_one", &.{});
    const two = try w.stage("ws2", "art2", "set_two", &.{});
    var same = one.code == 0 and two.code == 0;
    const files = [_][]const u8{ "plan.json", "noarch/mojo-stg_z-0.2.0-mojo1.0.0_0.conda", "noarch/mojo-stg_m-0.2.0-mojo1.0.0_0.conda", "noarch/mojo-stg_a-0.2.0-mojo1.0.0_0.conda" };
    var local = false;
    for (files) |f| {
        const x = try h.readFile(a, try w.path(&.{ w.work, "set_one", f }));
        const y = try h.readFile(a, try w.path(&.{ w.work, "set_two", f }));
        same = same and std.mem.eql(u8, x, y);
        for ([_][]const u8{ "127.0.0.1", "localhost", "mopm.lock", "../stg_" }) |needle| local = local or h.contains(x, needle);
    }
    w.rep.check("staging one workspace twice gives the same bytes, plan and packages", same, try w.text(one));
    w.rep.check("and no loopback address, lock entry or path is in the plan or the packages", !local, "something local was packed");
    const m = try h.readFile(a, try w.path(&.{ w.work, "set_one", "noarch", "mojo-stg_m-0.2.0-mojo1.0.0_0.conda" }));
    w.rep.check("a dependency keeps its version requirement in the package", h.contains(m, "\"name\":\"stg_z\",\"range\":\">=0.2,<0.3\""), "the requirement is gone");
}

/// A member with a `[native.<id>]` static library: staged from the archive beside its `.mojoc`, and published as staged.
fn aNativeMember(w: World) !void {
    const archive = "!<arch>\nthe archive of stg_n\n";
    try h.writeFile(try w.path(&.{ w.work, "wsn", "src", "stg_n", "mopm.toml" }), "[package]\nname = \"stg_n\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n\n[native.stg_n]\nkind = \"static\"\nneeds = [\"libz.so.1\", \"libcore_sys.a\"]\nexclusive = \"libstg\"\n");
    try h.writeFile(try w.path(&.{ w.work, "wsn", "src", "stg_n", "README.md" }), "# stg_n\n");
    try h.writeFile(try w.path(&.{ w.work, "artn", "linux-64", "stg_n.mojoc" }), "the mojoc of n");
    var r = try w.stage("wsn", "artn", "set_n_missing", &.{});
    w.rep.check("a native member with no archive is refused, naming the member and the file it expected", r.code == 1 and h.contains(r.stderr, "stg_n: native library 'stg_n' has no archive for linux-64") and
        h.contains(r.stderr, "stg_n.native/libstg_n.a") and !w.exists(&.{ w.work, "set_n_missing" }), try w.text(r));
    try h.writeFile(try w.path(&.{ w.work, "artn", "linux-64", "stg_n.native", "libstg_n.a" }), archive);
    r = try w.stage("wsn", "artn", "set_n", &.{});
    w.rep.check("a native member is staged from its archive", r.code == 0 and h.contains(r.stdout, "1 to upload"), try w.text(r));
    const conda_file = try h.readFile(w.a, try w.path(&.{ w.work, "set_n", "linux-64", "mojo-stg_n-1.0.0-mojo1.0.0_0.conda" }));
    w.rep.check("and the package holds the archive and declares the static native", h.contains(conda_file, "lib/libstg_n.a") and h.contains(conda_file, "stg_n"), "the archive is not in the package");
    const mojoc_arg = try std.fmt.allocPrint(w.a, "linux-64={s}", .{try w.path(&.{ w.work, "artn", "linux-64", "stg_n.mojoc" })});
    const native_arg = try std.fmt.allocPrint(w.a, "stg_n=linux-64:{s}", .{try w.path(&.{ w.work, "artn", "linux-64", "stg_n.native", "libstg_n.a" })});
    const manifest_arg = try w.path(&.{ w.work, "wsn", "src", "stg_n", "mopm.toml" });
    const out_arg = try w.path(&.{ w.work, "packed_n" });
    const by_pack = try w.m.run(&.{ "pack", "--compiler", "1.0.0", "--mojoc", mojoc_arg, "--native", native_arg, "--manifest", manifest_arg, "-o", out_arg }, null);
    const packed_bytes = if (by_pack.code == 0) try h.readFile(w.a, try w.path(&.{ w.work, "packed_n", "linux-64", "mojo-stg_n-1.0.0-mojo1.0.0_0.conda" })) else "";
    w.rep.check("the staged package is byte for byte the one mopm pack makes from the same files", by_pack.code == 0 and std.mem.eql(u8, packed_bytes, conda_file), try w.text(by_pack));
    const pub_ = try w.m.run(&.{ "publish", "--staged", try w.path(&.{ w.work, "set_n" }), "--registry", w.fake.base, "--config-dir", w.conf, "--wait", "60" }, w.token);
    w.rep.check("publish --staged publishes the native member", pub_.code == 0 and std.mem.eql(u8, try w.stateOf("stg_n", "1.0.0"), "published"), try w.text(pub_));
}

/// A member with `[targets] bins`: the sources of its programs are packed, `mopm pack` makes the same bytes, and the set
/// publishes.
fn aBinsMember(w: World) !void {
    const manifest_path = try w.path(&.{ w.work, "wsb", "src", "stg_b", "mopm.toml" });
    try h.writeFile(manifest_path, "[package]\nname = \"stg_b\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n\n[targets]\nbins = [{ name = \"ring_bench\", path = \"bench/ring.mojo\" }, { name = \"agg_bench\", path = \"bench/agg.mojo\" }]\n");
    try h.writeFile(try w.path(&.{ w.work, "wsb", "src", "stg_b", "README.md" }), "# stg_b\n");
    try h.writeFile(try w.path(&.{ w.work, "artb", "linux-64", "stg_b.mojoc" }), "the mojoc of b");
    var r = try w.stage("wsb", "artb", "set_b_missing", &.{});
    w.rep.check("a member whose program source is missing is refused, naming the member and the program", r.code == 1 and h.contains(r.stderr, "stg_b: [targets] bin 'ring_bench': cannot read") and
        !w.exists(&.{ w.work, "set_b_missing" }), try w.text(r));
    try h.writeFile(try w.path(&.{ w.work, "wsb", "src", "stg_b", "bench", "ring.mojo" }), "def main(): print(\"ring\")\n");
    try h.writeFile(try w.path(&.{ w.work, "wsb", "src", "stg_b", "bench", "agg.mojo" }), "def main(): print(\"agg\")\n");
    r = try w.stage("wsb", "artb", "set_b", &.{});
    w.rep.check("a member with programs is staged", r.code == 0 and h.contains(r.stdout, "1 to upload"), try w.text(r));
    const conda_file = try h.readFile(w.a, try w.path(&.{ w.work, "set_b", "linux-64", "mojo-stg_b-1.0.0-mojo1.0.0_0.conda" }));
    w.rep.check("and the package holds the source of each program, below lib/mojo/stg_b.bins", h.contains(conda_file, "lib/mojo/stg_b.bins/ring_bench.mojo") and
        h.contains(conda_file, "lib/mojo/stg_b.bins/agg_bench.mojo") and h.contains(conda_file, "def main(): print(\"ring\")"), "a program is not in the package");
    const mojoc_arg = try std.fmt.allocPrint(w.a, "linux-64={s}", .{try w.path(&.{ w.work, "artb", "linux-64", "stg_b.mojoc" })});
    const out_arg = try w.path(&.{ w.work, "packed_b" });
    const by_pack = try w.m.run(&.{ "pack", "--compiler", "1.0.0", "--mojoc", mojoc_arg, "--manifest", manifest_path, "-o", out_arg }, null);
    const packed_bytes = if (by_pack.code == 0) try h.readFile(w.a, try w.path(&.{ w.work, "packed_b", "linux-64", "mojo-stg_b-1.0.0-mojo1.0.0_0.conda" })) else "";
    w.rep.check("the staged package is byte for byte the one mopm pack makes from the same files", by_pack.code == 0 and std.mem.eql(u8, packed_bytes, conda_file), try w.text(by_pack));
    const pub_ = try w.m.run(&.{ "publish", "--staged", try w.path(&.{ w.work, "set_b" }), "--registry", w.fake.base, "--config-dir", w.conf, "--wait", "60" }, w.token);
    w.rep.check("publish --staged publishes the member with programs", pub_.code == 0 and std.mem.eql(u8, try w.stateOf("stg_b", "1.0.0"), "published"), try w.text(pub_));
}

fn usageErrors(w: World) !void {
    var r = try w.m.run(&.{ "stage", "--workspace-root", "x", "--artifacts", "y", "--compiler", "1.0.0", "--out", "z" }, null);
    w.rep.check("stage without --registry is a usage error: there is no default", r.code == 2 and h.contains(r.stderr, "--registry is required"), r.stderr);
    r = try w.m.run(&.{ "stage", "--frob" }, null);
    w.rep.check("an option stage does not know is a usage error", r.code == 2 and h.contains(r.stderr, "unexpected argument '--frob'"), r.stderr);
    r = try w.m.run(&.{ "stage", "--workspace-root", "x", "--artifacts", "y", "--compiler", "1.0.0", "--out", "z", "--registry", "nowhere" }, null);
    w.rep.check("a registry that is not one is reported before any work", r.code == 1 and h.contains(r.stderr, "--registry nowhere"), r.stderr);
    r = try w.m.run(&.{ "stage", "--workspace-root", "x", "--artifacts", "y", "--compiler", "1.0.0", "--out", "z", "--registry", dead }, null);
    w.rep.check("a registry nothing listens on is reported, not hung on", r.code == 1 and h.contains(r.stderr, "cannot reach"), r.stderr);
}

test "mopm stage against the fake registry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report = h.Report{};
    const mopm_exe = try h.toolPath(a, "MOPM");
    const fake_exe = try h.toolPath(a, "MOPM_FAKE_REGISTRY");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try h.tmpPath(a, &tmp);

    var env = try h.environ(a);
    env.remove("MOPM_TOKEN");
    var everything = std.ArrayList(u8).init(a);
    const m = Mopm{ .a = a, .exe = mopm_exe, .env = env, .everything = &everything };

    h.stage = "starting the fake registry";
    var fake = try h.Fake.start(a, fake_exe, try h.join(a, &.{ work, "fake" }));
    defer fake.close();

    const session = h.jsonString(try fake.control(a, "/session", "{\"handle\":\"stage-user\"}"), "token") orelse "";
    for (names) |n| {
        const r = try h.request(a, "POST", fake.base, try std.fmt.allocPrint(a, "/api/v1/packages/{s}/claim", .{n}), "{}", session);
        report.check(try std.fmt.allocPrint(a, "{s} is claimed", .{n}), r.status == 201, r.body);
    }
    const claim_n = try h.request(a, "POST", fake.base, "/api/v1/packages/stg_n/claim", "{}", session);
    report.check("stg_n is claimed", claim_n.status == 201, claim_n.body);
    const claim_b = try h.request(a, "POST", fake.base, "/api/v1/packages/stg_b/claim", "{}", session);
    report.check("stg_b is claimed", claim_b.status == 201, claim_b.body);
    const made = try h.request(a, "POST", fake.base, "/api/v1/me/tokens", "{\"name\":\"e2e\",\"scopes\":[\"publish\",\"yank\"],\"packages\":[\"stg_z\",\"stg_m\",\"stg_a\",\"stg_n\",\"stg_b\"],\"expires_in_days\":1}", session);
    const token = if (made.status == 201) (h.jsonString(try h.parseJson(a, made.body), "token") orelse "") else "";
    report.check("an API token that may publish and yank the three is made", token.len > 0, made.body);

    const w = World{ .a = a, .rep = &report, .m = m, .fake = fake, .work = work, .conf = try h.join(a, &.{ work, "conf" }), .token = token };
    try stageAndPublishAChain(w);
    try theRegistryDecides(w);
    try aCycleAndDeterminism(w);
    try aNativeMember(w);
    try aBinsMember(w);
    try usageErrors(w);

    var leaked = false;
    for ([_][]const u8{ token, session }) |s| {
        if (s.len > 0 and h.contains(everything.items, s)) leaked = true;
    }
    report.check("no token is ever printed", !leaked, "a token was printed");
    try report.finish();
}
