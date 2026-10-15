//! tests/resolve_e2e/run.py in Zig, for the build farm, which has no Python.
//! run.py stays for ci.yml until farm.yml has matched it, and is superseded by
//! this file.
//!
//! End-to-end tests of `mopm lock`, `mopm update` and `mopm tree` against
//! mopm-fake-registry. The fake registry is started on a free port; the index
//! records and the channel's repodata.json files below are then written into
//! its data directory, which it serves at /index/... and /channel/... as the
//! hosted registry does (spec/index.md, spec/channel.md). Each check prints
//! `ok` or `FAIL`.
//!
//! The index is built so that a resolver that picks a wrong version writes a
//! lock that differs from tests/resolve_e2e/expected.lock. Each trap below is
//! a version a faulty resolver would pick:
//!
//!     http_client 0.5.0   ignores the requirement "0.4"
//!     http_client 0.4.1   ignores the compiler (built for mojo 1.1.0)
//!     http_core   2.0.0   ignores http_client's range ">=1.2,<2"
//!     http_core   1.4.0   satisfies http_client but not tls's "~1.2" (the diamond)
//!     http_core   1.2.6   is yanked
//!     http_core   1.2.4   is older: the resolver must take the newest that fits
//!     tls         1.2.0   is taken down
//!     crypto      2.1.0b1 is not MAJOR.MINOR.PATCH: ignored, with a warning
//!     legacy      1.2.3.4 has four parts: ignored ("1" must give 1.1.0, not it)
//!     legacy      2.0.0-rc1 is a pre-release: ignored (">=2.0.0-rc1" matches nothing)
//!     legacy      1.0     is 1.0.0 ("=1.0.0" picks it)
//!
//! The repodata `depends` disagree with the index records' `deps[].range` on
//! purpose (every range there is ">=99"): the resolver reads only
//! `deps[].range`, the cargo requirement from the publisher's mopm.toml, so the
//! lock must not change.
//!
//! The lock's channel is the fake's loopback http URL with a path
//! (`http://127.0.0.1:<port>/channel/`), which mopm writes and reads; a lock
//! naming a plain-http channel on any other host is refused. The lock written
//! is compared byte for byte with expected.lock and also validated against
//! spec/lock.schema.json plus the rules of spec/lock.md, with the validator of
//! the contract driver (contract_test.zig). So that the schema check is shown
//! to be able to fail, the same lock with its channel moved to plain http on a
//! non-loopback host, or to loopback http without a port, must be refused.
//!
//! Run by Buck2 (//:resolve_e2e) from the repository root; MOPM and
//! MOPM_FAKE_REGISTRY are the built programs.
//!
//! NOT YET MIRRORED: the add / remove checks of the open pull request that
//! adds `mopm add` and `mopm remove` to run.py (add_before.toml,
//! add_after.toml, remove_after.toml in this directory, and run.py's
//! `add_remove`). When that lands, port `add_remove` here: read the three
//! files from tests/resolve_e2e, run the same steps with `run`, and compare
//! with `lockOf` / `same` below; the BUCK target globs tests/resolve_e2e/*, so
//! the files need no BUCK edit.

const std = @import("std");
const h = @import("harness.zig");
const c = @import("contract.zig");
const js = @import("jsonschema.zig");
const regex = @import("regex.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const SIZE: u32 = 4096;

fn digest(a: Allocator, subdir: []const u8, file: []const u8) ![]u8 {
    var out: [32]u8 = undefined;
    const text = try std.fmt.allocPrint(a, "{s}/{s}", .{ subdir, file });
    std.crypto.hash.sha2.Sha256.hash(text, &out, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(out, .lower));
}

// ------------------------------------------------------------ the index

const Dep = struct { name: []const u8, range: []const u8 };
const Native = struct { id: []const u8, soname: []const u8 };
const Ver = struct {
    ver: []const u8,
    deps: []const Dep = &.{},
    state: []const u8 = "published",
    mojo: []const u8 = "1.0.0",
    subdirs: []const []const u8 = &.{"linux-64"},
    native: []const Native = &.{},
    yank_reason: ?[]const u8 = null,
    tombstoned: bool = false,
};
const Pkg = struct { name: []const u8, versions: []const Ver };

const client_deps = [_]Dep{ .{ .name = "http_core", .range = ">=1.2,<2" }, .{ .name = "crypto", .range = "2" } };
const tls_deps = [_]Dep{.{ .name = "http_core", .range = "~1.2" }};
const crypto_native = [_]Native{.{ .id = "crypto", .soname = "libcrypto_native.so.1" }};

const packages = [_]Pkg{
    .{ .name = "http_client", .versions = &.{
        .{ .ver = "0.3.0", .deps = &client_deps, .state = "yanked", .yank_reason = "crashes on empty body" },
        .{ .ver = "0.4.0", .deps = &client_deps },
        .{ .ver = "0.4.1", .deps = &client_deps, .mojo = "1.1.0" },
        .{ .ver = "0.5.0", .deps = &client_deps },
    } },
    .{ .name = "http_core", .versions = &.{
        .{ .ver = "1.2.4" },
        .{ .ver = "1.2.5" },
        .{ .ver = "1.2.6", .state = "yanked", .yank_reason = "breaks keep-alive" },
        .{ .ver = "1.4.0" },
        .{ .ver = "2.0.0" },
    } },
    .{ .name = "crypto", .versions = &.{
        .{ .ver = "2.0.1", .subdirs = &.{ "linux-64", "osx-arm64" }, .native = &crypto_native },
        .{ .ver = "2.1.0b1" },
    } },
    .{ .name = "tls", .versions = &.{
        .{ .ver = "1.0.0", .state = "tombstoned", .tombstoned = true },
        .{ .ver = "1.1.0", .deps = &tls_deps },
        .{ .ver = "1.2.0", .state = "tombstoned", .tombstoned = true },
    } },
    // The repodata disagrees with the index about this one's bytes.
    .{ .name = "badsum", .versions = &.{.{ .ver = "1.0.0" }} },
    // Only MAJOR.MINOR.PATCH is read; 1.0 is 1.0.0; the rest are ignored.
    .{ .name = "legacy", .versions = &.{
        .{ .ver = "1.0" },
        .{ .ver = "1.1.0" },
        .{ .ver = "1.2.3.4" },
        .{ .ver = "2.0.0-rc1" },
    } },
};

const all_subdirs = [_][]const u8{ "linux-64", "linux-aarch64", "osx-arm64", "noarch" };

const Tombstone = struct { date: []const u8, reason_code: []const u8 };
const File = struct { filename: []const u8, sha256: []const u8, size: u32, subdir: []const u8, url: ?[]const u8 = null };
const Record = struct {
    v: u8 = 1,
    name: []const u8,
    version: []const u8,
    build: []const u8,
    state: []const u8,
    published_at: []const u8 = "2026-10-13T12:00:00Z",
    requires_mojo: []const u8,
    deps: []const Dep,
    native: []const Native,
    files: []const File,
    manifest_sha256: []const u8,
    yank_reason: ?[]const u8 = null,
    tombstone: ?Tombstone = null,
};
const RepoEntry = struct {
    build: []const u8,
    build_number: u8 = 0,
    depends: []const []const u8,
    name: []const u8,
    sha256: []const u8,
    size: u32,
    subdir: []const u8,
    version: []const u8,
};

fn filenameOf(a: Allocator, pkg: []const u8, v: Ver) ![]u8 {
    return std.fmt.allocPrint(a, "mojo-{s}-{s}-mojo{s}_0.conda", .{ pkg, v.ver, v.mojo });
}

fn toJson(a: Allocator, value: anytype) ![]u8 {
    return std.json.stringifyAlloc(a, value, .{ .emit_null_optional_fields = false });
}

/// The index files and repodata of `packages` under the fake's data directory.
fn writeRegistry(a: Allocator, root: []const u8, base: []const u8) !void {
    var entries: [all_subdirs.len]std.ArrayList(u8) = undefined;
    var removed: [all_subdirs.len]std.ArrayList([]const u8) = undefined;
    for (&entries, &removed) |*e, *r| {
        e.* = std.ArrayList(u8).init(a);
        r.* = std.ArrayList([]const u8).init(a);
    }
    for (packages) |pkg| {
        var lines = std.ArrayList(u8).init(a);
        for (pkg.versions) |v| {
            const fname = try filenameOf(a, pkg.name, v);
            const build = try std.fmt.allocPrint(a, "mojo{s}_0", .{v.mojo});
            var files = std.ArrayList(File).init(a);
            for (v.subdirs) |sub| {
                const sha = try digest(a, sub, fname);
                try files.append(.{
                    .filename = fname,
                    .sha256 = sha,
                    .size = SIZE,
                    .subdir = sub,
                    .url = if (std.mem.eql(u8, v.state, "tombstoned")) null else try std.fmt.allocPrint(a, "{s}/channel/{s}/{s}", .{ base, sub, fname }),
                });
                const idx = for (all_subdirs, 0..) |s, i| {
                    if (std.mem.eql(u8, s, sub)) break i;
                } else return error.UnknownSubdir;
                if (std.mem.eql(u8, v.state, "published")) {
                    const tampered = std.mem.eql(u8, pkg.name, "badsum");
                    var depends = std.ArrayList([]const u8).init(a);
                    try depends.append(try std.fmt.allocPrint(a, "mojo-compiler =={s}", .{v.mojo}));
                    // Deliberately not the index's ranges: never read.
                    for (v.deps) |d| try depends.append(try std.fmt.allocPrint(a, "mojo-{s} >=99", .{d.name}));
                    try depends.append("mojo-zlib_never_read 1");
                    const entry = RepoEntry{
                        .build = build,
                        .depends = depends.items,
                        .name = try std.fmt.allocPrint(a, "mojo-{s}", .{pkg.name}),
                        .sha256 = if (tampered) try digest(a, sub, "tampered") else sha,
                        .size = SIZE,
                        .subdir = sub,
                        .version = v.ver,
                    };
                    if (entries[idx].items.len != 0) try entries[idx].append(',');
                    try entries[idx].writer().print("\"{s}\":{s}", .{ fname, try toJson(a, entry) });
                } else {
                    try removed[idx].append(fname);
                }
            }
            const rec = Record{
                .name = pkg.name,
                .version = v.ver,
                .build = build,
                .state = v.state,
                .requires_mojo = try std.fmt.allocPrint(a, "=={s}", .{v.mojo}),
                .deps = v.deps,
                .native = v.native,
                .files = files.items,
                .manifest_sha256 = try digest(a, "manifest", fname),
                .yank_reason = v.yank_reason,
                .tombstone = if (v.tombstoned) Tombstone{ .date = "2026-10-14", .reason_code = "malware" } else null,
            };
            try lines.writer().print("{s}\n", .{try toJson(a, rec)});
        }
        var padded: [4]u8 = "____".*;
        for (pkg.name[0..@min(pkg.name.len, 4)], 0..) |b, i| padded[i] = b;
        const path = try std.fmt.allocPrint(a, "{s}/index/{s}/{s}/{s}", .{ root, padded[0..2], padded[2..4], pkg.name });
        try h.writeFile(path, lines.items);
    }
    for (all_subdirs, 0..) |sub, i| {
        std.mem.sort([]const u8, removed[i].items, {}, c.lessStr);
        var doc = std.ArrayList(u8).init(a);
        try doc.writer().print("{{\"info\":{{\"subdir\":\"{s}\"}},\"packages\":{{}},\"packages.conda\":{{{s}}},\"removed\":[", .{ sub, entries[i].items });
        for (removed[i].items, 0..) |name, k| {
            if (k != 0) try doc.append(',');
            try doc.writer().print("\"{s}\"", .{name});
        }
        try doc.appendSlice("]}\n");
        try h.writeFile(try std.fmt.allocPrint(a, "{s}/channel/{s}/repodata.json", .{ root, sub }), doc.items);
    }
}

// --------------------------------------------------------------- running

const MANIFEST_HEAD =
    \\[package]
    \\name = "app"
    \\version = "0.1.0"
    \\
    \\[toolchain]
    \\mojo = "1.0.0"
    \\
    \\[dependencies]
    \\
;

const TREE =
    \\app 0.1.0
    \\├── http_client 0.4.0
    \\│   ├── crypto 2.0.1
    \\│   └── http_core 1.2.5
    \\└── tls 1.1.0
    \\    └── http_core 1.2.5
    \\
;

fn warning(a: Allocator, name: []const u8, ver: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "mopm lock: warning: the index lists {s} {s}, which is not a MAJOR.MINOR.PATCH version; it is ignored\n", .{ name, ver });
}

const Out = struct { code: u8, stdout: []u8, stderr: []u8 };

const Cx = struct {
    a: Allocator,
    rep: *h.Report,
    mopm: []const u8,
    work: []const u8,
    registry: []const u8,
    lock_schema: Value,

    /// A project directory holding a mopm.toml with `deps` under [dependencies].
    fn project(cx: *Cx, name: []const u8, deps: []const u8) ![]u8 {
        const d = try h.join(cx.a, &.{ cx.work, name });
        try h.writeFile(try h.join(cx.a, &.{ d, "mopm.toml" }), try std.fmt.allocPrint(cx.a, "{s}{s}\n", .{ MANIFEST_HEAD, deps }));
        return d;
    }

    /// A path dependency's own mopm.toml.
    fn package(cx: *Cx, dir: []const u8, name: []const u8, ver: []const u8, deps: []const u8) !void {
        try h.writeFile(try h.join(cx.a, &.{ dir, "mopm.toml" }), try std.fmt.allocPrint(cx.a, "[package]\nname = \"{s}\"\nversion = \"{s}\"\n\n[dependencies]\n{s}\n", .{ name, ver, deps }));
    }

    /// `mopm <args>` in `dir`; stdout and stderr apart.
    fn run(cx: *Cx, dir: []const u8, args: []const []const u8) !Out {
        const argv = try cx.a.alloc([]const u8, args.len + 1);
        argv[0] = cx.mopm;
        @memcpy(argv[1..], args);
        const r = try std.process.Child.run(.{ .allocator = cx.a, .argv = argv, .cwd = dir, .max_output_bytes = 1 << 22 });
        return .{ .code = switch (r.term) {
            .Exited => |code| code,
            else => 255,
        }, .stdout = r.stdout, .stderr = r.stderr };
    }

    /// `mopm <args> --registry <fake>`.
    fn runReg(cx: *Cx, dir: []const u8, args: []const []const u8) !Out {
        const all = try std.mem.concat(cx.a, []const u8, &.{ args, &.{ "--registry", cx.registry } });
        return cx.run(dir, all);
    }

    fn lockOf(cx: *Cx, dir: []const u8) !?[]u8 {
        return h.readFile(cx.a, try h.join(cx.a, &.{ dir, "mopm.lock" })) catch null;
    }

    fn writeLock(cx: *Cx, dir: []const u8, text: []const u8) !void {
        try h.writeFile(try h.join(cx.a, &.{ dir, "mopm.lock" }), text);
    }

    fn fmt(cx: *Cx, comptime f: []const u8, args: anytype) ![]u8 {
        return std.fmt.allocPrint(cx.a, f, args);
    }

    fn ok(cx: *Cx, name: []const u8, good: bool, detail: []const u8) void {
        cx.rep.check(name, good, detail);
    }

    /// What tests/contract/validate.py finds wrong with a lock: schema, then rules.
    fn contractProblems(cx: *Cx, text: []const u8) !c.Problems {
        var out = c.Problems.init(cx.a);
        const doc = c.parseJson(cx.a, text) catch {
            try out.append("not JSON");
            return out;
        };
        for ((try c.schemaErrors(cx.a, cx.lock_schema, cx.lock_schema, doc)).items) |e| try out.append(e);
        if (out.items.len == 0) {
            for ((try c.lockProblems(cx.a, doc)).items) |e| try out.append(e);
        }
        return out;
    }

    /// The packages of a lock as name -> entry.
    fn entries(cx: *Cx, text: ?[]const u8) !std.StringArrayHashMap(Value) {
        var out = std.StringArrayHashMap(Value).init(cx.a);
        const t = text orelse return out;
        const doc = try c.parseJson(cx.a, t);
        for (c.getArr(doc, "packages")) |p| try out.put(c.getStr(p, "name") orelse "", p);
        return out;
    }
};

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "mopm lock, update and tree resolve against the fake registry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var rep = h.Report{};
    try h.watchdog(280);
    const mopm_exe = try h.toolPath(a, "MOPM");
    const fake_exe = try h.toolPath(a, "MOPM_FAKE_REGISTRY");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try h.tmpPath(a, &tmp);

    h.stage = "starting the fake registry";
    var fake = try h.Fake.start(a, fake_exe, try h.join(a, &.{ work, "fake" }));
    defer fake.close();
    try writeRegistry(a, try h.join(a, &.{ work, "fake" }), fake.base);
    const channel = try std.fmt.allocPrint(a, "{s}/channel/", .{fake.base});
    const expected = try std.mem.replaceOwned(u8, a, try h.readFile(a, "tests/resolve_e2e/expected.lock"), "@CHANNEL@", channel);

    var cx = Cx{ .a = a, .rep = &rep, .mopm = mopm_exe, .work = work, .registry = fake.base, .lock_schema = try c.loadJson(a, "spec/lock.schema.json") };

    h.stage = "app";
    const app = try cx.project("app", "http_client = \"0.4\"\ntls = \"1\"");

    var r = try cx.run(app, &.{"tree"});
    cx.ok("tree without a lock says to lock", r.code == 1 and has(r.stderr, "no mopm.lock; run 'mopm lock'"), r.stderr);

    r = try cx.runReg(app, &.{"lock"});
    cx.ok("lock succeeds", r.code == 0, try cx.fmt("{s}{s}", .{ r.stdout, r.stderr }));
    cx.ok("lock warns once about crypto 2.1.0b1 and about nothing else", std.mem.eql(u8, r.stderr, try warning(a, "crypto", "2.1.0b1")), r.stderr);
    {
        const re = try regex.Regex.compile(a, "^http://127\\.0\\.0\\.1:[0-9]+/channel/$");
        cx.ok("the channel is loopback http with a path", re.search(channel), channel);
    }
    const got = try cx.lockOf(app);
    cx.rep.same("the lock picks exactly the expected versions and bytes", expected, got orelse "(no lock written)\n");
    {
        const found = if (got) |g| try cx.contractProblems(g) else blk: {
            var none = c.Problems.init(a);
            try none.append("no lock written");
            break :blk none;
        };
        cx.ok("the lock written passes spec/lock.schema.json and the lock rules", found.items.len == 0, try std.mem.join(a, "; ", found.items));
        for ([_][]const u8{ "http://example.com/channel/", "http://127.0.0.1/channel/" }) |bad| {
            const broken = try std.mem.replaceOwned(u8, a, got orelse "", channel, bad);
            const refused = try cx.contractProblems(broken);
            cx.ok(try cx.fmt("the schema check refuses the same lock with channel {s}", .{bad}), refused.items.len != 0 and got != null, "accepted");
        }
    }
    cx.ok("lock reports what it added", std.mem.eql(u8, r.stdout, "adding crypto 2.0.1\nadding http_client 0.4.0\nadding http_core 1.2.5\nadding tls 1.1.0\nlocked 4 packages for mojo 1.0.0\n"), r.stdout);

    r = try cx.run(app, &.{"tree"});
    cx.ok("tree draws the locked graph", r.code == 0 and std.mem.eql(u8, r.stdout, TREE), try cx.fmt("{s}{s}", .{ r.stdout, r.stderr }));

    r = try cx.runReg(app, &.{"lock"});
    {
        const again = try cx.lockOf(app);
        cx.ok("locking again changes nothing", r.code == 0 and std.mem.eql(u8, r.stdout, "locked 4 packages for mojo 1.0.0\n") and again != null and std.mem.eql(u8, again.?, expected), try cx.fmt("{s}{s}", .{ r.stdout, r.stderr }));
    }

    // A lock that pins an older http_core keeps it; update moves it.
    {
        const old_fn = "mojo-http_core-1.2.4-mojo1.0.0_0.conda";
        const new_fn = "mojo-http_core-1.2.5-mojo1.0.0_0.conda";
        var pinned = try std.mem.replaceOwned(u8, a, expected, new_fn, old_fn);
        pinned = try std.mem.replaceOwned(u8, a, pinned, "\"version\": \"1.2.5\"", "\"version\": \"1.2.4\"");
        pinned = try std.mem.replaceOwned(u8, a, pinned, try digest(a, "linux-64", new_fn), try digest(a, "linux-64", old_fn));
        try cx.writeLock(app, pinned);
        r = try cx.runReg(app, &.{"lock"});
        var now = try cx.lockOf(app);
        cx.ok("lock keeps a pinned version that still fits", r.code == 0 and now != null and std.mem.eql(u8, now.?, pinned), try cx.fmt("{s}{s}", .{ r.stdout, r.stderr }));
        r = try cx.runReg(app, &.{ "update", "http_core" });
        now = try cx.lockOf(app);
        cx.ok("update moves the named package to the newest that fits", r.code == 0 and now != null and std.mem.eql(u8, now.?, expected) and has(r.stdout, "updating http_core 1.2.4 -> 1.2.5\n"), try cx.fmt("{s}{s}", .{ r.stdout, r.stderr }));
        r = try cx.runReg(app, &.{ "update", "nosuch" });
        cx.ok("update refuses a package the lock does not hold", r.code == 1 and has(r.stderr, "nosuch is not in mopm.lock"), r.stderr);
    }

    for ([_][]const u8{ "http://example.com/channel/", "http://127.0.0.2:80/channel/" }) |host| {
        try cx.writeLock(app, try std.mem.replaceOwned(u8, a, expected, channel, host));
        const want = try cx.fmt("channel {s} is refused: a channel ends with '/' and is https, or plain http only to 127.0.0.1, [::1] or localhost with a port", .{host});
        r = try cx.run(app, &.{"tree"});
        cx.ok(try cx.fmt("tree refuses a lock whose channel is {s}", .{host}), r.code == 1 and has(r.stderr, want), r.stderr);
        r = try cx.runReg(app, &.{"lock"});
        cx.ok(try cx.fmt("lock refuses a lock whose channel is {s}", .{host}), r.code == 1 and has(r.stderr, want), r.stderr);
    }

    // Versions: 1.0 is 1.0.0; 1.2.3.4 and 2.0.0-rc1 are ignored, with a warning each.
    {
        const legacy_warnings = try cx.fmt("{s}{s}", .{ try warning(a, "legacy", "1.2.3.4"), try warning(a, "legacy", "2.0.0-rc1") });
        const Case = struct { name: []const u8, req: []const u8, want: []const u8 };
        var last_dir: []const u8 = "";
        var last_text: ?[]u8 = null;
        for ([_]Case{
            .{ .name = "caret", .req = "1", .want = "1.1.0" },
            .{ .name = "exact", .req = "=1.0.0", .want = "1.0" },
            .{ .name = "below", .req = "<1.1", .want = "1.0" },
        }) |case| {
            const d = try cx.project(try cx.fmt("legacy_{s}", .{case.name}), try cx.fmt("legacy = \"{s}\"", .{case.req}));
            r = try cx.runReg(d, &.{"lock"});
            const text = try cx.lockOf(d);
            const files = try cx.entries(text);
            const fname = try cx.fmt("mojo-legacy-{s}-mojo1.0.0_0.conda", .{case.want});
            const want_url = try cx.fmt("{s}linux-64/{s}", .{ channel, fname });
            var picked_ok = files.count() == 1;
            if (files.get("legacy")) |p| {
                picked_ok = picked_ok and std.mem.eql(u8, c.getStr(p, "version") orelse "", case.want) and std.mem.eql(u8, c.getStr(p, "url") orelse "", want_url);
            } else picked_ok = false;
            cx.ok(try cx.fmt("legacy {s} picks {s} and warns about each ignored version", .{ case.req, case.want }), r.code == 0 and std.mem.eql(u8, r.stderr, legacy_warnings) and picked_ok, try cx.fmt("exit {d}, stderr {s}", .{ r.code, r.stderr }));
            last_dir = d;
            last_text = text;
        }
        // Locking with the lock in place reads it back (the version 1.0 too).
        r = try cx.runReg(last_dir, &.{"lock"});
        const after = try cx.lockOf(last_dir);
        cx.ok("a lock holding legacy 1.0 is read back and kept", r.code == 0 and after != null and last_text != null and std.mem.eql(u8, after.?, last_text.?), try cx.fmt("{s}{s}", .{ r.stdout, r.stderr }));
    }

    // Path dependencies: locked as source = path, at the version their own
    // mopm.toml gives, with no file; their own requirements resolve.
    {
        const withpath = try cx.project("withpath", "local = { path = \"local\" }");
        const local_dir = try h.join(a, &.{ withpath, "local" });
        const util_dir = try h.join(a, &.{ withpath, "util" });
        try cx.package(local_dir, "local", "0.3.0", "tls = \"1\"\nutil = { path = \"../util\" }");
        try cx.package(util_dir, "util", "0.0.7", "");
        r = try cx.runReg(withpath, &.{"lock"});
        var text = try cx.lockOf(withpath);
        const entries = try cx.entries(text);
        const want_local = try c.parseJson(a, "{\"name\":\"local\",\"version\":\"0.3.0\",\"source\":\"path\",\"path\":\"local\",\"deps\":[\"tls\",\"util\"]}");
        const want_util = try c.parseJson(a, "{\"name\":\"util\",\"version\":\"0.0.7\",\"source\":\"path\",\"path\":\"util\"}");
        cx.ok("a path dependency is locked with source path, its version and path, and no file", r.code == 0 and
            (if (entries.get("local")) |v| js.eql(v, want_local) else false) and (if (entries.get("util")) |v| js.eql(v, want_util) else false), try cx.fmt("exit {d} {s}", .{ r.code, r.stderr }));
        {
            const tls_v = if (entries.get("tls")) |v| c.getStr(v, "version") orelse "" else "";
            const core_v = if (entries.get("http_core")) |v| c.getStr(v, "version") orelse "" else "";
            var names = std.ArrayList([]const u8).init(a);
            for (entries.keys()) |k| try names.append(k);
            std.mem.sort([]const u8, names.items, {}, c.lessStr);
            const joined = try std.mem.join(a, ",", names.items);
            cx.ok("a path dependency's own requirements are resolved from the registry", std.mem.eql(u8, tls_v, "1.1.0") and std.mem.eql(u8, core_v, "1.2.5") and std.mem.eql(u8, joined, "http_core,local,tls,util"), joined);
        }
        cx.ok("lock reports the path dependencies", std.mem.eql(u8, r.stdout, "adding http_core 1.2.5\nadding local 0.3.0\nadding tls 1.1.0\nadding util 0.0.7\nlocked 4 packages for mojo 1.0.0\n"), r.stdout);
        r = try cx.run(withpath, &.{"tree"});
        cx.ok("tree draws path dependencies with their paths", r.code == 0 and std.mem.eql(u8, r.stdout, "app 0.1.0\n└── local 0.3.0 (local)\n    ├── tls 1.1.0\n    │   └── http_core 1.2.5\n    └── util 0.0.7 (util)\n"), try cx.fmt("{s}{s}", .{ r.stdout, r.stderr }));
        try cx.package(local_dir, "local", "0.3.1", "tls = \"1\"\nutil = { path = \"../util\" }");
        r = try cx.runReg(withpath, &.{"lock"});
        text = try cx.lockOf(withpath);
        cx.ok("a path dependency's new version is locked", r.code == 0 and has(r.stdout, "updating local 0.3.0 -> 0.3.1\n") and has(text orelse "", "\"version\": \"0.3.1\""), try cx.fmt("{s}{s}", .{ r.stdout, r.stderr }));
        try cx.package(util_dir, "notutil", "0.0.7", "");
        r = try cx.runReg(withpath, &.{"lock"});
        cx.ok("a path dependency whose mopm.toml names another package is refused", r.code == 1 and has(r.stderr, "util/mopm.toml names the package notutil, but local/mopm.toml calls it util"), r.stderr);
        const nodir = try cx.project("nopath", "gone = { path = \"gone\" }");
        r = try cx.runReg(nodir, &.{"lock"});
        cx.ok("a path dependency without a mopm.toml is refused", r.code == 1 and has(r.stderr, "no gone/mopm.toml") and (try cx.lockOf(nodir)) == null, r.stderr);
    }

    try cx.writeLock(app, try std.mem.replaceOwned(u8, a, expected, "\"lock_version\": 1", "\"lock_version\": 2"));
    r = try cx.runReg(app, &.{"lock"});
    cx.ok("a lock from a newer mopm is refused", r.code == 1 and has(r.stderr, "Update mopm."), r.stderr);

    const Refusal = struct { name: []const u8, deps: []const u8, wants: []const []const u8 };
    const bad_sum = try cx.fmt("the index says sha256 {s}", .{try digest(a, "linux-64", "mojo-badsum-1.0.0-mojo1.0.0_0.conda")});
    const tampered = try cx.fmt("repodata.json says sha256 {s}", .{try digest(a, "linux-64", "tampered")});
    const refusals = [_]Refusal{
        .{ .name = "missing", .deps = "nosuch = \"1\"", .wants = &.{"nosuch (required by mopm.toml) is not in the registry's index"} },
        .{ .name = "yanked", .deps = "http_client = \"=0.3.0\"", .wants = &.{"0.3.0 was yanked: crashes on empty body"} },
        .{ .name = "taken_down", .deps = "tls = \"=1.2.0\"", .wants = &.{"1.2.0 was taken down (malware)"} },
        .{ .name = "compiler", .deps = "http_client = \"=0.4.1\"", .wants = &.{ "is built for mojo 1.0.0", "0.4.1 (mojo 1.1.0)" } },
        .{ .name = "conflict", .deps = "http_client = \"0.4\"\nhttp_core = \"2\"", .wants = &.{ "no version of http_core satisfies every requirement on it", ">=1.2,<2 (from http_client 0.4.0)", "2 (from mopm.toml)" } },
        .{ .name = "no_match", .deps = "http_core = \"3\"", .wants = &.{"no version of http_core matches 3 (from mopm.toml)"} },
        .{ .name = "pre_release", .deps = "legacy = \">=2.0.0-rc1\"", .wants = &.{ "no version of legacy matches >=2.0.0-rc1 (from mopm.toml)", "2.0.0-rc1 (ignored: not MAJOR.MINOR.PATCH)", "mopm lock: warning: the index lists legacy 2.0.0-rc1, which is not a MAJOR.MINOR.PATCH version; it is ignored\n" } },
        .{ .name = "four_parts", .deps = "legacy = \"=1.2.3\"", .wants = &.{ "no version of legacy matches =1.2.3 (from mopm.toml)", "1.2.3.4 (ignored: not MAJOR.MINOR.PATCH)", "mopm lock: warning: the index lists legacy 1.2.3.4, which is not a MAJOR.MINOR.PATCH version; it is ignored\n" } },
        .{ .name = "badsum", .deps = "badsum = \"1\"", .wants = &.{ bad_sum, tampered } },
    };
    for (refusals) |refusal| {
        const d = try cx.project(try cx.fmt("refuse_{s}", .{refusal.name}), refusal.deps);
        r = try cx.runReg(d, &.{"lock"});
        var lacks: []const u8 = "";
        for (refusal.wants) |w| {
            if (!has(r.stderr, w)) lacks = w;
        }
        cx.ok(try cx.fmt("refused: {s}", .{refusal.name}), r.code == 1 and lacks.len == 0 and (try cx.lockOf(d)) == null, try cx.fmt("exit {d}, lacks '{s}': {s}", .{ r.code, lacks, r.stderr }));
    }

    try rep.finish();
}
