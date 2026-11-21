//! End-to-end test of one package version carrying one build per Mojo compiler, against the fake registry: `mopm stage` and
//! `mopm publish --staged` publish a version, then add a build for another compiler to it; `mopm lock` and the resolver of
//! mopm_core read it back, one file per Mojo.
//!
//! Run by Buck2 (//:multi_build): MOPM and MOPM_FAKE_REGISTRY are the built programs, and the working directory is the
//! repository root, where the fixture tests/e2e/multibuild is. Outside Buck2, after `zig build`:
//!
//!     MOPM=$PWD/zig-out/bin/mopm MOPM_FAKE_REGISTRY=$PWD/zig-out/bin/mopm-fake-registry \
//!         zig test --dep mopm_core -Mroot=tests/drivers/multi_build_test.zig -Mmopm_core=src/core/mopm_core.zig
//!
//! The fixture holds one workspace member, example/mbd (mopm.toml, a readme and a library directory), and a stand-in
//! `.mojoc` of it per compiler (1.0.0, 1.1.0, 1.2.0) in the layout `mopm stage --artifacts` reads. Each check prints `ok`
//! or `FAIL`.
//!
//! What can go red, and why:
//! - a first stage and publish with Mojo 1.0.0 must give a version whose index line lists one build, mojo1.0.0_0;
//! - the same sources staged for Mojo 1.1.0 must be an upload of that build's files alone, and publishing it must add the
//!   build: the index line then lists mojo1.0.0_0 and mojo1.1.0_0, its top-level build, requires_mojo and files stay the
//!   primary (lowest compiler) build's, and each file is served with the sha256 the index gives;
//! - a project on Mojo 1.0.0 must lock the 1.0.0 file of that version. mopm pins only the Mojo 1.0.0 toolchain, so `mopm lock`
//!   refuses a project on 1.1.0 before it resolves; the resolver and the lock builder of mopm_core, run on the index and the
//!   repodata the fake serves, must give a project on 1.1.0 the 1.1.0 file of the same version;
//! - sources that differ (a changed library file) are refused by `mopm stage` as built from other sources, and the same
//!   build published anyway is refused by the registry (version_exists), leaving the index line as it was; a changed file
//!   under a published build is refused as a file that is never replaced;
//! - a version published for Mojo 1.1.0 only is skipped by a project on 1.0.0 that asks for any version of the package, and
//!   named by the exact pin it gives the error that lists what exists;
//! - an index line written before `builds` existed (one build, no `builds` key) resolves for Mojo 1.0.0 as before.

const std = @import("std");
const h = @import("harness.zig");
const core = @import("mopm_core");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const fixture = "tests/e2e/multibuild";
const Sha256 = std.crypto.hash.sha2.Sha256;

const Out = struct { code: u8, stdout: []u8, stderr: []u8 };

const Mopm = struct {
    a: Allocator,
    exe: []const u8,
    /// This process's environment without MOPM_TOKEN.
    env: std.process.EnvMap,
    everything: *std.ArrayList(u8),

    fn run(m: Mopm, args: []const []const u8, cwd: ?[]const u8, token: ?[]const u8) !Out {
        const argv = try m.a.alloc([]const u8, args.len + 1);
        argv[0] = m.exe;
        @memcpy(argv[1..], args);
        var env = try h.cloneEnv(m.a, &m.env);
        if (token) |t| try env.put("MOPM_TOKEN", t);
        const r = try std.process.Child.run(.{ .allocator = m.a, .argv = argv, .cwd = cwd, .env_map = &env, .max_output_bytes = 1 << 22 });
        try m.everything.appendSlice(r.stdout);
        try m.everything.appendSlice(r.stderr);
        return .{ .code = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        }, .stdout = r.stdout, .stderr = r.stderr };
    }
};

/// What the lock holds for one package at one Mojo version.
const Artifact = struct { version: []const u8, build: []const u8, sha256: []const u8, url: []const u8 };

const Cx = struct {
    a: Allocator,
    rep: *h.Report,
    m: Mopm,
    fake: h.Fake,
    fake_dir: []const u8,
    work: []const u8,
    conf: []const u8,
    token: []const u8,

    fn ok(cx: Cx, name: []const u8, good: bool, detail: []const u8) void {
        cx.rep.check(name, good, detail);
    }

    fn path(cx: Cx, parts: []const []const u8) ![]u8 {
        return h.join(cx.a, parts);
    }

    fn text(cx: Cx, r: Out) ![]const u8 {
        return std.fmt.allocPrint(cx.a, "exit {d}: {s}{s}", .{ r.code, r.stdout, r.stderr });
    }

    fn exists(cx: Cx, parts: []const []const u8) bool {
        const p = h.join(cx.a, parts) catch return false;
        return if (std.fs.cwd().access(p, .{})) true else |_| false;
    }

    fn sha256Of(cx: Cx, bytes: []const u8) ![]const u8 {
        var d: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(bytes, &d, .{});
        return cx.a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
    }

    /// The conda file name of example/mbd at `version` for Mojo `mojo`.
    fn condaName(cx: Cx, version: []const u8, mojo: []const u8) ![]const u8 {
        return std.fmt.allocPrint(cx.a, "mojo-example.mbd-{s}-mojo{s}_0.conda", .{ version, mojo });
    }

    /// `mopm stage` of the workspace `ws` (below the work directory) with the artifacts of `mojo` in `art`, into `out`.
    fn stage(cx: Cx, ws: []const u8, mojo: []const u8, art: []const u8, out: []const u8) !Out {
        return cx.m.run(&.{
            "stage",       "--workspace-root",              try cx.path(&.{ cx.work, ws }),
            "--artifacts", try cx.path(&.{ cx.work, art }), "--compiler",
            mojo,          "--out",                         try cx.path(&.{ cx.work, out }),
            "--registry",  cx.fake.base,
        }, null, null);
    }

    fn publishStaged(cx: Cx, set: []const u8) !Out {
        return cx.m.run(&.{ "publish", "--staged", try cx.path(&.{ cx.work, set }), "--registry", cx.fake.base, "--config-dir", cx.conf, "--wait", "60" }, null, cx.token);
    }

    fn plan(cx: Cx, set: []const u8) !Value {
        return h.parseJson(cx.a, try h.readFile(cx.a, try cx.path(&.{ cx.work, set, "plan.json" })));
    }

    /// The first member of a staged set's plan: its action, and the file names it uploads.
    fn member(cx: Cx, set: []const u8) !Value {
        return (try cx.plan(set)).object.get("members").?.array.items[0];
    }

    fn action(m: Value) []const u8 {
        return h.jsonString(m, "action") orelse "(none)";
    }

    /// The file names of a plan member, joined with commas.
    fn memberFiles(cx: Cx, m: Value) ![]const u8 {
        var list = std.ArrayList([]const u8).init(cx.a);
        const files = (m.object.get("files") orelse return "").array.items;
        for (files) |f| try list.append(h.jsonString(f, "filename") orelse (h.jsonString(f, "file") orelse (h.jsonString(f, "path") orelse "?")));
        return std.mem.join(cx.a, ",", list.items);
    }

    /// The index line of example/mbd at `version`, as the registry serves it.
    fn line(cx: Cx, name: []const u8, version: []const u8) !?Value {
        const r = try h.request(cx.a, "GET", cx.fake.base, try std.fmt.allocPrint(cx.a, "/index/v2/ex/am/example/{s}", .{name}), null, null);
        if (r.status != 200) return null;
        var lines = std.mem.splitScalar(u8, r.body, '\n');
        while (lines.next()) |l| {
            if (l.len == 0) continue;
            const v = try h.parseJson(cx.a, l);
            if (std.mem.eql(u8, h.jsonString(v, "version") orelse "", version)) return v;
        }
        return null;
    }

    /// The builds of an index line, `mojo1.0.0_0,mojo1.1.0_0`, in the order the line lists them.
    fn builds(cx: Cx, rec: Value) ![]const u8 {
        var list = std.ArrayList([]const u8).init(cx.a);
        const bs = (rec.object.get("builds") orelse return "(no builds key)").array.items;
        for (bs) |b| try list.append(h.jsonString(b, "build") orelse "?");
        return std.mem.join(cx.a, ",", list.items);
    }

    /// The first file of the build `build` of an index line.
    fn buildFile(rec: Value, build: []const u8) ?Value {
        const bs = (rec.object.get("builds") orelse return null).array.items;
        for (bs) |b| {
            if (std.mem.eql(u8, h.jsonString(b, "build") orelse "", build)) return b.object.get("files").?.array.items[0];
        }
        return null;
    }

    /// The sha256 of the bytes the channel serves for `filename` of example/mbd (noarch), or "" when it serves none.
    fn servedSha(cx: Cx, filename: []const u8) ![]const u8 {
        const r = try h.request(cx.a, "GET", cx.fake.base, try std.fmt.allocPrint(cx.a, "/channel/example/noarch/{s}", .{filename}), null, null);
        return if (r.status == 200) try cx.sha256Of(r.body) else "";
    }

    /// The sha256 of a file of a staged set.
    fn stagedSha(cx: Cx, set: []const u8, filename: []const u8) ![]const u8 {
        return cx.sha256Of(h.readFile(cx.a, try cx.path(&.{ cx.work, set, "noarch", filename })) catch return "(no such file)");
    }

    /// A project on `mojo` that depends on `name` at `requirement`, in the directory `dir` below the work directory.
    fn project(cx: Cx, dir: []const u8, mojo: []const u8, name: []const u8, requirement: []const u8) ![]const u8 {
        const d = try cx.path(&.{ cx.work, dir });
        try h.writeFile(try cx.path(&.{ d, "mopm.toml" }), try std.fmt.allocPrint(cx.a, "[package]\nname = \"example/app\"\nversion = \"0.1.0\"\nmojo = [\"{s}\"]\n\n[dependencies]\n\"{s}\" = \"{s}\"\n", .{ mojo, name, requirement }));
        try h.writeFile(try cx.path(&.{ d, "src", "app", "__init__.mojo" }), "def run():\n    pass\n");
        return d;
    }

    fn lock(cx: Cx, dir: []const u8) !Out {
        return cx.m.run(&.{ "lock", "--registry", cx.fake.base }, dir, null);
    }

    /// What the lock written in `dir` holds for `name` at `mojo`, or null.
    fn lockEntry(cx: Cx, dir: []const u8, name: []const u8, mojo: []const u8) !?Artifact {
        const bytes = h.readFile(cx.a, try cx.path(&.{ dir, "mopm.lock" })) catch return null;
        const doc = try h.parseJson(cx.a, bytes);
        for (doc.object.get("packages").?.array.items) |p| {
            if (!std.mem.eql(u8, h.jsonString(p, "name") orelse "", name)) continue;
            const art = (p.object.get("artifacts") orelse return null).object.get(mojo) orelse return null;
            return .{ .version = h.jsonString(p, "version") orelse "", .build = h.jsonString(art, "build") orelse "", .sha256 = h.jsonString(art, "sha256") orelse "", .url = h.jsonString(art, "url") orelse "" };
        }
        return null;
    }
};

// ------------------------------------------------- mopm_core's resolver on what the fake serves

/// The sparse index of the fake registry, read over HTTP as `mopm lock` reads it.
const HttpIndex = struct {
    config: core.registry.Config,

    pub fn fetch(self: HttpIndex, arena: Allocator, name: []const u8, diag: *core.resolve.Diagnostic) core.resolve.Error!?[]const u8 {
        const url = try core.registry.indexUrl(arena, self.config, name);
        const answer = core.http.request(arena, .GET, url, .{}) catch |e| {
            return core.resolve.fail(arena, diag, .unreachable_index, "cannot read {s}: {s}", .{ url, @errorName(e) });
        };
        if (answer.status == 404) return null;
        if (!answer.ok()) return core.resolve.fail(arena, diag, .unreachable_index, "{s} answered HTTP {d}", .{ url, answer.status });
        return answer.body;
    }
};

/// The repodata of the fake registry's channel, read over HTTP. No package file is asked for: no package here has natives.
const HttpChannel = struct {
    root: []const u8,

    pub fn fetch(self: HttpChannel, arena: Allocator, namespace: []const u8, subdir: []const u8, diag: *core.resolve.Diagnostic) core.resolve.Error![]const u8 {
        const url = try std.fmt.allocPrint(arena, "{s}{s}/{s}/repodata.json", .{ self.root, namespace, subdir });
        const answer = core.http.request(arena, .GET, url, .{}) catch |e| {
            return core.resolve.fail(arena, diag, .bad_channel, "cannot read {s}: {s}", .{ url, @errorName(e) });
        };
        if (!answer.ok()) return core.resolve.fail(arena, diag, .bad_channel, "{s} answered HTTP {d}", .{ url, answer.status });
        return answer.body;
    }

    pub fn fetchConda(_: HttpChannel, arena: Allocator, _: []const u8, _: []const u8, filename: []const u8, diag: *core.resolve.Diagnostic) core.resolve.Error![]const u8 {
        return core.resolve.fail(arena, diag, .bad_channel, "unexpected request for the package file {s}", .{filename});
    }
};

const Resolved = union(enum) { ok: core.lock.Lock, failed: []const u8 };

/// Resolves `name` at `requirement` for Mojo `mojo` on the fake registry's served index and repodata, and builds the lock.
fn resolveFor(cx: Cx, mojo: []const u8, name: []const u8, requirement: []const u8) !Resolved {
    const channel_root = try std.fmt.allocPrint(cx.a, "{s}/channel/", .{cx.fake.base});
    const config = core.registry.Config{ .base = cx.fake.base, .stage = "", .api_url = "", .channel_url = channel_root, .min_cli_version = "", .read_only = false };
    var diag: core.resolve.Diagnostic = .{};
    const res = core.resolve.resolve(cx.a, HttpIndex{ .config = config }, .{
        .mojo = mojo,
        .roots = &.{.{ .name = name, .requirement = requirement }},
        .mojoc_message = true,
    }, &diag) catch |e| switch (e) {
        error.ResolveFailed => return .{ .failed = diag.message },
        error.OutOfMemory => return e,
    };
    const l = core.install_plan.buildLock(cx.a, res, channel_root, HttpChannel{ .root = channel_root }, null, &diag) catch |e| switch (e) {
        error.ResolveFailed => return .{ .failed = diag.message },
        error.OutOfMemory => return e,
    };
    return .{ .ok = l };
}

fn firstPackage(r: Resolved) ?core.lock.Package {
    return switch (r) {
        .ok => |l| if (l.packages.len == 1) l.packages[0] else null,
        .failed => null,
    };
}

// ------------------------------------------------------------------------------------ the scenario

const v1 = "1.0.0";
const staged_notice = "1 to upload, 0 skipped, 0 refused";

/// 1. A version published with a 1.0.0 build.
fn firstBuild(cx: Cx) !void {
    const r = try cx.stage("fx/workspace", "1.0.0", "fx/artifacts/1.0.0", "set_a");
    const m = try cx.member("set_a");
    cx.ok("stage --compiler 1.0.0 of a new version is an upload of the 1.0.0 file", r.code == 0 and h.contains(r.stdout, staged_notice) and
        std.mem.eql(u8, Cx.action(m), "upload") and std.mem.eql(u8, try cx.memberFiles(m), try cx.condaName(v1, "1.0.0")), try cx.text(r));
    const p = try cx.publishStaged("set_a");
    cx.ok("publish --staged publishes the version", p.code == 0, try cx.text(p));
    const rec = (try cx.line("mbd", v1)) orelse return cx.ok("the index has a line for the version", false, "no line");
    cx.ok("the index line lists one build, mojo1.0.0_0, and its top-level build is the same", std.mem.eql(u8, try cx.builds(rec), "mojo1.0.0_0") and
        std.mem.eql(u8, h.jsonString(rec, "build") orelse "", "mojo1.0.0_0") and std.mem.eql(u8, h.jsonString(rec, "requires_mojo") orelse "", "==1.0.0"), try cx.builds(rec));
}

/// 2. The same sources staged for Mojo 1.1.0: an add of that build's files.
fn addedBuild(cx: Cx) !void {
    const r = try cx.stage("fx/workspace", "1.1.0", "fx/artifacts/1.1.0", "set_b");
    const m = try cx.member("set_b");
    const file_1_1 = try cx.condaName(v1, "1.1.0");
    cx.ok("stage --compiler 1.1.0 of the published sources is an upload of the 1.1.0 file only", r.code == 0 and h.contains(r.stdout, staged_notice) and
        std.mem.eql(u8, Cx.action(m), "upload") and std.mem.eql(u8, try cx.memberFiles(m), file_1_1) and
        cx.exists(&.{ cx.work, "set_b", "noarch", file_1_1 }) and !cx.exists(&.{ cx.work, "set_b", "noarch", try cx.condaName(v1, "1.0.0") }), try cx.text(r));
    const p = try cx.publishStaged("set_b");
    cx.ok("publish --staged adds the build to the published version", p.code == 0, try cx.text(p));

    const rec = (try cx.line("mbd", v1)) orelse return cx.ok("the index has a line for the version", false, "no line");
    cx.ok("the index line now lists mojo1.0.0_0 and mojo1.1.0_0", std.mem.eql(u8, try cx.builds(rec), "mojo1.0.0_0,mojo1.1.0_0"), try cx.builds(rec));
    cx.ok("its top-level build and requires_mojo are still the lowest compiler's", std.mem.eql(u8, h.jsonString(rec, "build") orelse "", "mojo1.0.0_0") and
        std.mem.eql(u8, h.jsonString(rec, "requires_mojo") orelse "", "==1.0.0"), h.jsonString(rec, "build") orelse "");
    const top = rec.object.get("files").?.array.items;
    cx.ok("and its top-level files are the 1.0.0 build's one file", top.len == 1 and
        std.mem.eql(u8, h.jsonString(top[0], "filename") orelse "", try cx.condaName(v1, "1.0.0")), "top-level files differ");

    for ([_][]const u8{ "1.0.0", "1.1.0" }) |mojo| {
        const f = Cx.buildFile(rec, try std.fmt.allocPrint(cx.a, "mojo{s}_0", .{mojo})) orelse {
            cx.ok(try std.fmt.allocPrint(cx.a, "the index has a file for the {s} build", .{mojo}), false, "none");
            continue;
        };
        const name = h.jsonString(f, "filename") orelse "";
        const want = try cx.stagedSha(if (std.mem.eql(u8, mojo, "1.0.0")) "set_a" else "set_b", name);
        const served = try cx.servedSha(name);
        cx.ok(try std.fmt.allocPrint(cx.a, "the {s} file is served, and its bytes have the sha256 the index lists and the one staged", .{mojo}), std.mem.eql(u8, name, try cx.condaName(v1, mojo)) and
            std.mem.eql(u8, h.jsonString(f, "sha256") orelse "", want) and std.mem.eql(u8, served, want), served);
    }
    const again = try cx.stage("fx/workspace", "1.1.0", "fx/artifacts/1.1.0", "set_b_again");
    cx.ok("staging the 1.1.0 build again is a skip: the registry has it", again.code == 0 and h.contains(again.stdout, "0 to upload, 1 skipped, 0 refused") and
        std.mem.eql(u8, Cx.action(try cx.member("set_b_again")), "skip"), try cx.text(again));
}

/// 3. A project on each Mojo: the file of its own build, from one version.
fn eachMojoItsFile(cx: Cx) !void {
    const sha_1_0 = try cx.stagedSha("set_a", try cx.condaName(v1, "1.0.0"));
    const sha_1_1 = try cx.stagedSha("set_b", try cx.condaName(v1, "1.1.0"));
    cx.ok("the two builds are different bytes", !std.mem.eql(u8, sha_1_0, sha_1_1), sha_1_0);

    const p10 = try cx.project("proj_10", "1.0.0", "example/mbd", "1");
    const r10 = try cx.lock(p10);
    const e10 = try cx.lockEntry(p10, "example/mbd", "1.0.0");
    cx.ok("a project on Mojo 1.0.0 locks the version with its 1.0.0 file", r10.code == 0 and e10 != null and std.mem.eql(u8, e10.?.version, v1) and
        std.mem.eql(u8, e10.?.build, "mojo1.0.0_0") and std.mem.eql(u8, e10.?.sha256, sha_1_0) and h.contains(e10.?.url, "mojo-example.mbd-1.0.0-mojo1.0.0_0.conda"), try cx.text(r10));

    // mopm pins the Mojo 1.0.0 toolchain only: a project on 1.1.0 is refused before anything is resolved.
    const p11 = try cx.project("proj_11", "1.1.0", "example/mbd", "1");
    const r11 = try cx.lock(p11);
    cx.ok("mopm lock refuses a project on Mojo 1.1.0 for want of a pinned toolchain, and writes no lock", r11.code == 1 and
        h.contains(r11.stderr, "mopm has no pinned toolchain for mojo 1.1.0") and !cx.exists(&.{ p11, "mopm.lock" }), try cx.text(r11));

    // The resolver and the lock builder of mopm_core, on the index and the repodata the fake serves.
    const lib = try resolveFor(cx, "1.1.0", "example/mbd", "1");
    const pkg = firstPackage(lib);
    cx.ok("the resolver, run for Mojo 1.1.0 on the served index, picks the same version with its 1.1.0 file", pkg != null and std.mem.eql(u8, pkg.?.version, v1) and
        std.mem.eql(u8, pkg.?.build, "mojo1.1.0_0") and std.mem.eql(u8, pkg.?.sha256, sha_1_1) and std.mem.eql(u8, pkg.?.mojo, "1.1.0") and
        std.mem.endsWith(u8, pkg.?.url, "mojo-example.mbd-1.0.0-mojo1.1.0_0.conda"), switch (lib) {
        .ok => "resolved, but not as expected",
        .failed => |m| m,
    });
    const lib10 = try resolveFor(cx, "1.0.0", "example/mbd", "1");
    const pkg10 = firstPackage(lib10);
    cx.ok("and for Mojo 1.0.0 it picks the same version with the 1.0.0 file", pkg10 != null and std.mem.eql(u8, pkg10.?.version, v1) and
        std.mem.eql(u8, pkg10.?.build, "mojo1.0.0_0") and std.mem.eql(u8, pkg10.?.sha256, sha_1_0), "the 1.0.0 file was not picked");
    const lib12 = try resolveFor(cx, "1.2.0", "example/mbd", "1");
    cx.ok("and for Mojo 1.2.0 it fails, listing the builds that exist", switch (lib12) {
        .ok => false,
        .failed => |m| std.mem.eql(u8, m, "example/mbd 1.0.0 has no .mojoc for Mojo 1.2.0 (published for: 1.0.0, 1.1.0). Build with mojo 1.0.0, ask the publisher for a 1.2.0 build, or pin a version that has one."),
    }, switch (lib12) {
        .ok => "resolved",
        .failed => |m| m,
    });
}

/// 4. A build from other sources, and 5. a replaced file.
fn refusedBuilds(cx: Cx) !void {
    // The same package with one library file changed: the digest of its sources, and so its metadata, differ.
    try h.copyTree(cx.a, try cx.path(&.{ cx.work, "fx", "workspace" }), try cx.path(&.{ cx.work, "fx", "workspace_other" }));
    try h.writeFile(try cx.path(&.{ cx.work, "fx", "workspace_other", "mbd", "src", "mbd", "__init__.mojo" }), "def greet() -> String:\n    return \"goodbye\"\n");
    const r = try cx.stage("fx/workspace_other", "1.2.0", "fx/artifacts/1.2.0", "set_c");
    cx.ok("stage refuses a build for Mojo 1.2.0 that comes from other sources, with the reason", r.code == 1 and
        h.contains(r.stderr, "example/mbd 1.0.0 is already published, and the build mojo1.2.0_0 was built from other sources than the published version") and
        std.mem.eql(u8, Cx.action(try cx.member("set_c")), "refuse"), try cx.text(r));
    const refused = try cx.m.run(&.{ "publish", "--staged", try cx.path(&.{ cx.work, "set_c" }), "--registry", "http://127.0.0.1:1", "--config-dir", cx.conf }, null, "mopm_unused");
    cx.ok("and publish --staged refuses that set before it sends a request", refused.code == 1 and h.contains(refused.stderr, "the plan refuses example/mbd 1.0.0") and
        !h.contains(refused.stderr, "cannot reach"), try cx.text(refused));

    // The registry's own refusal: the same other sources staged against an empty registry make an upload set, which the
    // registry that holds the version then refuses.
    var empty = try h.Fake.start(cx.a, try h.toolPath(cx.a, "MOPM_FAKE_REGISTRY"), try cx.path(&.{ cx.work, "fake_empty" }));
    defer empty.close();
    const other_session = h.jsonString(try empty.control(cx.a, "/session", "{\"handle\":\"example\"}"), "token") orelse "";
    const other_package = try h.request(cx.a, "PUT", empty.base, "/api/v2/packages/example/mbd", null, other_session);
    cx.ok("the other registry has the package, and no version of it", other_package.status == 201, other_package.body);
    const against_empty = try cx.m.run(&.{
        "stage",       "--workspace-root",                                     try cx.path(&.{ cx.work, "fx", "workspace_other" }),
        "--artifacts", try cx.path(&.{ cx.work, "fx", "artifacts", "1.2.0" }), "--compiler",
        "1.2.0",       "--out",                                                try cx.path(&.{ cx.work, "set_d" }),
        "--registry",  empty.base,
    }, null, null);
    if (against_empty.code != 0) return cx.ok("the same sources staged against a registry that has no such version are staged", false, try cx.text(against_empty));
    const dm = try cx.member("set_d");
    cx.ok("the same sources staged against a registry that has no such version are an upload of the 1.2.0 file", against_empty.code == 0 and
        std.mem.eql(u8, Cx.action(dm), "upload") and std.mem.eql(u8, try cx.memberFiles(dm), try cx.condaName(v1, "1.2.0")), try cx.text(against_empty));
    const forced = try cx.publishStaged("set_d");
    cx.ok("publishing that set to the registry that holds the version is refused by the registry: the version exists and versions are immutable", forced.code == 1 and h.contains(forced.stderr, "already exists") and h.contains(forced.stderr, "versions are immutable"), try cx.text(forced));
    const rec = (try cx.line("mbd", v1)) orelse return cx.ok("the index still has a line for the version", false, "no line");
    cx.ok("and the version still lists the same two builds", std.mem.eql(u8, try cx.builds(rec), "mojo1.0.0_0,mojo1.1.0_0"), try cx.builds(rec));
    cx.ok("with no file of the refused build served", (try cx.servedSha(try cx.condaName(v1, "1.2.0"))).len == 0, "the refused file is served");

    // A published file is never replaced: the 1.1.0 artifact changed, the same version.
    try h.writeFile(try cx.path(&.{ cx.work, "fx", "artifacts_changed", "1.1.0", "noarch", "example", "mbd.mojoc" }), "a different stand-in .mojoc, built by Mojo 1.1.0\n");
    const replaced = try cx.stage("fx/workspace", "1.1.0", "fx/artifacts_changed/1.1.0", "set_e");
    cx.ok("stage refuses a 1.1.0 file that differs from the published one: a published file is never replaced", replaced.code == 1 and
        h.contains(replaced.stderr, "a published file is never replaced") and std.mem.eql(u8, Cx.action(try cx.member("set_e")), "refuse"), try cx.text(replaced));
}

/// 6. A version with no build for the project's Mojo.
fn noBuild(cx: Cx) !void {
    // example/mbd 1.1.0: the same package, a new version, built for Mojo 1.1.0 only.
    try h.copyTree(cx.a, try cx.path(&.{ cx.work, "fx", "workspace" }), try cx.path(&.{ cx.work, "fx", "workspace_w" }));
    const manifest_path = try cx.path(&.{ cx.work, "fx", "workspace_w", "mbd", "mopm.toml" });
    const bumped = try std.mem.replaceOwned(u8, cx.a, try h.readFile(cx.a, manifest_path), "version = \"1.0.0\"", "version = \"1.1.0\"");
    try h.writeFile(manifest_path, bumped);
    const staged = try cx.stage("fx/workspace_w", "1.1.0", "fx/artifacts/1.1.0", "set_f");
    const published = try cx.publishStaged("set_f");
    cx.ok("version 1.1.0 of the package is published with a 1.1.0 build only", staged.code == 0 and published.code == 0 and
        std.mem.eql(u8, Cx.action(try cx.member("set_f")), "upload"), try cx.text(if (staged.code != 0) staged else published));
    const rec = (try cx.line("mbd", "1.1.0")) orelse return cx.ok("the index has a line for 1.1.0", false, "no line");
    cx.ok("its index line lists the one build, mojo1.1.0_0", std.mem.eql(u8, try cx.builds(rec), "mojo1.1.0_0"), try cx.builds(rec));

    const pinned = try cx.project("proj_pinned", "1.0.0", "example/mbd", "=1.1.0");
    const r = try cx.lock(pinned);
    cx.ok("a project on Mojo 1.0.0 pinned to 1.1.0 is refused with the Mojo versions the version is published for", r.code == 1 and
        h.contains(r.stderr, "error: example/mbd 1.1.0 has no .mojoc for Mojo 1.0.0 (published for: 1.1.0). Build with mojo 1.1.0, ask the publisher for a 1.0.0 build, or pin a version that has one.\n") and
        !cx.exists(&.{ pinned, "mopm.lock" }), try cx.text(r));

    // The newest version that has a build for the project's Mojo is taken, not the newest version.
    const open = try cx.project("proj_open", "1.0.0", "example/mbd", "1");
    const ro = try cx.lock(open);
    const eo = try cx.lockEntry(open, "example/mbd", "1.0.0");
    cx.ok("a project on Mojo 1.0.0 that asks for any 1.x gets 1.0.0, the newest version with a 1.0.0 build", ro.code == 0 and eo != null and
        std.mem.eql(u8, eo.?.version, v1) and std.mem.eql(u8, eo.?.build, "mojo1.0.0_0"), try cx.text(ro));
    const lib = try resolveFor(cx, "1.1.0", "example/mbd", "1");
    const pkg = firstPackage(lib);
    cx.ok("and the resolver for Mojo 1.1.0 gets 1.1.0, the newest version, with its 1.1.0 file", pkg != null and std.mem.eql(u8, pkg.?.version, "1.1.0") and
        std.mem.eql(u8, pkg.?.build, "mojo1.1.0_0"), "the newest version was not picked");
}

/// 7. An index line from before `builds`: one build, no `builds` key, in a namespace of its own.
fn oldShape(cx: Cx) !void {
    const file = "mojo-oldrec.lines-0.1.0-mojo1.0.0_0.conda";
    const sha = try cx.sha256Of("the bytes of an old-shape package file");
    const size = "37";
    const record = try std.fmt.allocPrint(cx.a,
        \\{{"build":"mojo1.0.0_0","deps":[],"files":[{{"filename":"{s}","sha256":"{s}","size":{s},"subdir":"noarch","url":"{s}/channel/oldrec/noarch/{s}"}}],"manifest_sha256":"{s}","name":"oldrec/lines","native":[],"provenance":{{"kind":"none"}},"published_at":"2026-11-20T12:00:00Z","requires_mojo":"==1.0.0","state":"published","v":2,"version":"0.1.0"}}
        \\
    , .{ file, sha, size, cx.fake.base, file, sha });
    try h.writeFile(try cx.path(&.{ cx.fake_dir, "index", "v2", "ol", "dr", "oldrec", "lines" }), record);
    const repodata = try std.fmt.allocPrint(cx.a,
        \\{{"info":{{"subdir":"noarch"}},"packages":{{}},"packages.conda":{{"{s}":{{"build":"mojo1.0.0_0","depends":["mojo-compiler ==1.0.0"],"name":"mojo-oldrec.lines","sha256":"{s}","size":{s},"subdir":"noarch","version":"0.1.0"}}}},"removed":[]}}
        \\
    , .{ file, sha, size });
    try h.writeFile(try cx.path(&.{ cx.fake_dir, "channel", "oldrec", "noarch", "repodata.json" }), repodata);

    const p = try cx.project("proj_old", "1.0.0", "oldrec/lines", "0.1");
    const r = try cx.lock(p);
    const e = try cx.lockEntry(p, "oldrec/lines", "1.0.0");
    cx.ok("a project on Mojo 1.0.0 locks an index line that has no builds key, as before", r.code == 0 and e != null and std.mem.eql(u8, e.?.version, "0.1.0") and
        std.mem.eql(u8, e.?.build, "mojo1.0.0_0") and std.mem.eql(u8, e.?.sha256, sha), try cx.text(r));
    const lib = try resolveFor(cx, "1.1.0", "oldrec/lines", "0.1");
    cx.ok("for Mojo 1.1.0 that line is one build, and the error names its Mojo", switch (lib) {
        .ok => false,
        .failed => |m| std.mem.eql(u8, m, "oldrec/lines 0.1.0 has no .mojoc for Mojo 1.1.0 (published for: 1.0.0). Build with mojo 1.0.0, ask the publisher for a 1.1.0 build, or pin a version that has one."),
    }, switch (lib) {
        .ok => "resolved",
        .failed => |m| m,
    });
}

test "one package version, one build per Mojo compiler, against the fake registry" {
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
    const fake_dir = try h.join(a, &.{ work, "fake" });
    var fake = try h.Fake.start(a, fake_exe, fake_dir);
    defer fake.close();

    const session = h.jsonString(try fake.control(a, "/session", "{\"handle\":\"example\"}"), "token") orelse "";
    const created = try h.request(a, "PUT", fake.base, "/api/v2/packages/example/mbd", null, session);
    report.check("example/mbd is created", created.status == 201, created.body);
    const made = try h.request(a, "POST", fake.base, "/api/v2/me/tokens", "{\"name\":\"e2e\",\"scopes\":[\"publish\",\"yank\"],\"packages\":[\"example/mbd\"],\"expires_in_days\":1}", session);
    const token = if (made.status == 201) (h.jsonString(try h.parseJson(a, made.body), "token") orelse "") else "";
    report.check("an API token that may publish example/mbd is made", token.len > 0, made.body);

    try h.copyTree(a, fixture, try h.join(a, &.{ work, "fx" }));
    const cx = Cx{ .a = a, .rep = &report, .m = m, .fake = fake, .fake_dir = fake_dir, .work = work, .conf = try h.join(a, &.{ work, "conf" }), .token = token };

    h.stage = "a first build";
    try firstBuild(cx);
    h.stage = "a build added";
    try addedBuild(cx);
    h.stage = "each Mojo its file";
    try eachMojoItsFile(cx);
    h.stage = "builds refused";
    try refusedBuilds(cx);
    h.stage = "no build for the Mojo";
    try noBuild(cx);
    h.stage = "an old-shape record";
    try oldShape(cx);

    var leaked = false;
    for ([_][]const u8{ token, session }) |s| {
        if (s.len > 0 and h.contains(everything.items, s)) leaked = true;
    }
    report.check("no token is ever printed", !leaked, "a token was printed");
    try report.finish();
}
