//! The previous release (v0.0.108, the last before names moved into namespaces) and this code, each way, for every row of the
//! table in docs/design/namespaces.md, section 11: in one process, with no socket and no child process.
//!
//! The previous release is its own code, byte for byte: the readers of its core (manifest, lock, metadata, index config and
//! resolver, staged set, unit graph, CI token exchange) and its fake registry, vendored under tests/compat/v0.0.108 and built as
//! the module `prev_v0_0_108` (tests/compat/prev_v0_0_108.zig). Every test first checks that each vendored file still hashes to
//! its line of SHA256SUMS, so a run that passes ran the released bytes. The current code is `mopm_core` and the current fake
//! registry's handler with its fixture (`fake_fixture`, registry/fake/groups_test.zig).
//!
//! What each side is given is what the other side writes: the current registry's index and config files, the current
//! scaffold's mopm.toml, the current lock examples (tests/contract/examples/lock/valid, which the lock tests hold to the writer),
//! the current unit-graph writer's output and a current package's metadata (tests/fixtures/env); the previous registry's
//! config file, the previous release's lock examples (vendored) and the locks its writer renders.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const fixture = @import("fake_fixture");
const prev = @import("prev_v0_0_108");
const inproc = @import("inproc_world.zig");

const snapshot = "tests/compat/v0.0.108";
/// The registry's address in every config.json here: loopback http with a port, the only plain http either release accepts.
/// No socket is ever opened to it.
const base = "http://127.0.0.1:1";
/// The version this code calls itself when it reads a config.json; the refusals below come before any version check.
const this_version = "0.0.109";

/// The repository root: BUILDRULES_TEST_WORK (the target's `data`) in the Buck2 build, else the current directory (the repository
/// root, as `zig build test` runs).
fn rootDir() !std.fs.Dir {
    const path = std.process.getEnvVarOwned(std.testing.allocator, "BUILDRULES_TEST_WORK") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return std.fs.cwd().openDir(".", .{}),
        else => return err,
    };
    defer std.testing.allocator.free(path);
    return std.fs.cwd().openDir(path, .{});
}

fn readRooted(a: Allocator, rel: []const u8) ![]u8 {
    var root = try rootDir();
    defer root.close();
    return root.readFileAlloc(a, rel, 1 << 24);
}

/// A file's name and its text.
const Named = struct { name: []const u8, text: []const u8 };

/// The JSON files of the directory `rel` under the root, sorted by name.
fn jsonFiles(a: Allocator, rel: []const u8) ![]const Named {
    var root = try rootDir();
    defer root.close();
    var dir = try root.openDir(rel, .{ .iterate = true });
    defer dir.close();
    var out = std.ArrayList(Named).init(a);
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".json")) continue;
        try out.append(.{ .name = try a.dupe(u8, e.name), .text = try dir.readFileAlloc(a, e.name, 1 << 24) });
    }
    std.mem.sort(Named, out.items, {}, struct {
        fn less(_: void, x: Named, y: Named) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.less);
    return out.items;
}

/// Every line of `sums` ("<sha256>  <path>", the path relative to `dir`) names a file that hashes to it, and every file under
/// `<vendored>/<sub>` for each of `subs` (at any depth) has a line: what the module is built from is the released code, unedited.
/// Null when all of this holds; otherwise the first problem.
fn snapshotProblem(a: Allocator, dir: std.fs.Dir, sums: []const u8, vendored: []const u8, subs: []const []const u8) !?[]const u8 {
    const text = dir.readFileAlloc(a, sums, 1 << 20) catch |e| return try std.fmt.allocPrint(a, "{s}: {s}", .{ sums, @errorName(e) });
    var listed = std.StringHashMap(void).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (line.len <= 66 or !std.mem.eql(u8, line[64..66], "  ")) return try std.fmt.allocPrint(a, "not a SHA256SUMS line: {s}", .{line});
        const rel = line[66..];
        const bytes = dir.readFileAlloc(a, rel, 1 << 24) catch |e| return try std.fmt.allocPrint(a, "{s}: {s}", .{ rel, @errorName(e) });
        if (!std.mem.eql(u8, line[0..64], try inproc.sha256Hex(a, bytes))) return try std.fmt.allocPrint(a, "{s} does not hash to its line", .{rel});
        try listed.put(rel, {});
    }
    for (subs) |sub| {
        const sub_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ vendored, sub });
        var sub_dir = dir.openDir(sub_path, .{ .iterate = true }) catch |e| return try std.fmt.allocPrint(a, "{s}/: {s}", .{ sub_path, @errorName(e) });
        defer sub_dir.close();
        var walker = try sub_dir.walk(a);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            const rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ sub_path, entry.path });
            if (!listed.contains(rel)) return try std.fmt.allocPrint(a, "not in SHA256SUMS: {s}", .{rel});
        }
    }
    return null;
}

const vendored_dirs: []const []const u8 = &.{ "core", "fake", "lock" };

fn verifySnapshot(a: Allocator) !void {
    var root = try rootDir();
    defer root.close();
    try std.testing.expectEqual(@as(?[]const u8, null), try snapshotProblem(a, root, snapshot ++ "/SHA256SUMS", snapshot, vendored_dirs));
}

test "a snapshot with an edited, an unlisted (at any depth) or a missing file is refused, naming it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const body = "pub const x = 1;\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("v/core/toolchain");
    try tmp.dir.makePath("v/fake");
    try tmp.dir.writeFile("v/core/x.zig", body);
    try tmp.dir.writeFile("SHA256SUMS", try std.fmt.allocPrint(a, "{s}  v/core/x.zig\n", .{try inproc.sha256Hex(a, body)}));
    const subs: []const []const u8 = &.{ "core", "fake" };
    try std.testing.expectEqual(@as(?[]const u8, null), try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v", subs));
    try tmp.dir.writeFile("v/core/x.zig", "pub const x = 2;\n");
    try std.testing.expectEqualStrings("v/core/x.zig does not hash to its line", (try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v", subs)).?);
    try tmp.dir.writeFile("v/core/x.zig", body);
    try tmp.dir.writeFile("v/core/toolchain/extra.json", "{}");
    try std.testing.expectEqualStrings("not in SHA256SUMS: v/core/toolchain/extra.json", (try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v", subs)).?);
    try tmp.dir.deleteFile("v/core/toolchain/extra.json");
    try tmp.dir.deleteFile("v/core/x.zig");
    try std.testing.expectEqualStrings("v/core/x.zig: FileNotFound", (try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v", subs)).?);
    try tmp.dir.writeFile("SHA256SUMS", "abc  v/core/x.zig\n");
    try std.testing.expectEqualStrings("not a SHA256SUMS line: abc  v/core/x.zig", (try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v", subs)).?);
}

test "the vendored snapshot of the previous release hashes to its SHA256SUMS" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try verifySnapshot(arena_state.allocator());
}

// ---- The previous release reading the namespaced registry -------------------------------------------------------------------

/// The current fake registry at `base`, holding the flat packages `pkg_a`, `pkg_b`, `pkg_c` (the fixture's) and `kci_buffer`,
/// all of `alice`, with a token that publishes `pkg_a` and `kci_buffer`.
const Current = struct {
    fx: fixture.Fx = undefined,
    token: []const u8 = "kci-and-pkg-a-secret",

    fn open(c: *Current) !void {
        try c.fx.setup();
        const s = &c.fx.state;
        s.base_url = base;
        // Rewrites config.json for the loopback base (the control `/_fake/mode` rewrites every index file).
        _ = try c.fx.call(.POST, "/_fake/mode", "{\"read_only\":false}", null);
        const life = c.fx.life.allocator();
        const p = try s.addPackage(.{ .name = "kci_buffer", .created_at = s.now(), .updated_at = s.now(), .claim_expires_at = s.now() + 86400 });
        try p.owners.append(life, c.fx.alice);
        _ = try s.addToken(.{ .id = "t-kci", .secret = c.token, .kind = .api, .user = c.fx.alice, .scopes = &.{ .publish, .yank }, .packages = &.{ "kci_buffer", "pkg_a" }, .created_at = s.now(), .expires_at = s.now() + 86400 });
    }

    /// Publishes `names` (flat, at 1.0.0) as one group through `/api/v1`, as the previous client does, until it is visible.
    fn publishFlat(c: *Current, names: []const []const u8) !void {
        const created = try c.fx.call(.POST, "/api/v1/groups", try c.fx.request(names, "1.0.0", "x"), c.token);
        try std.testing.expectEqual(@as(u16, 201), created.status);
        try c.fx.upload(created, "x");
        const id = fixture.idOf(created);
        const commit = try std.fmt.allocPrint(c.fx.life.allocator(), "/api/v1/groups/{s}/commit", .{id});
        try std.testing.expectEqual(@as(u16, 202), (try c.fx.call(.POST, commit, try c.fx.commitBody(names), c.token)).status);
        var polls: usize = 0;
        while (!std.mem.eql(u8, try c.fx.status(id), "visible")) : (polls += 1) {
            if (polls == 5) return error.GroupNeverVisible;
        }
    }

    /// The config the previous release reads from this registry, as its `registry.load` makes it.
    fn prevConfig(c: *Current, a: Allocator) !prev.registry.Config {
        const r = try c.fx.call(.GET, "/index/config.json", "", null);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        switch (try prev.registry.parseConfig(a, r.body, prev.cli_version)) {
            .ok => |cfg| {
                var with_base = cfg;
                with_base.base = base;
                return with_base;
            },
            .bad => |why| {
                std.debug.print("the previous release refused this registry's config.json: {s}\n", .{why});
                return error.ConfigRefused;
            },
        }
    }
};

/// The previous release's index source: its own `registry.indexUrl`, answered by the current registry's file routes.
const PrevIndex = struct {
    fx: *fixture.Fx,
    config: prev.registry.Config,

    pub fn fetch(self: PrevIndex, arena: Allocator, name: []const u8, diag: *prev.resolve.Diagnostic) prev.resolve.Error!?[]const u8 {
        const url = try prev.registry.indexUrl(arena, self.config, name);
        const r = self.fx.call(.GET, url[base.len..], "", null) catch |e| return prev.resolve.fail(arena, diag, .unreachable_index, "cannot read {s}: {s}", .{ url, @errorName(e) });
        if (r.status == 404) return null;
        if (r.status != 200) return prev.resolve.fail(arena, diag, .unreachable_index, "{s} answered HTTP {d}", .{ url, r.status });
        return try arena.dupe(u8, r.body);
    }
};

/// What the previous release's resolver makes of `name` "1" against the current registry: the version, or the message.
fn prevResolves(a: Allocator, c: *Current, name: []const u8) ![]const u8 {
    const source = PrevIndex{ .fx = &c.fx, .config = try c.prevConfig(a) };
    var diag = prev.resolve.Diagnostic{};
    const roots = [_]prev.resolve.Root{.{ .name = name, .requirement = "1" }};
    const res = prev.resolve.resolve(a, source, .{ .mojo = "1.0.0", .roots = &roots }, &diag) catch |e| switch (e) {
        error.ResolveFailed => return diag.message,
        error.OutOfMemory => return e,
    };
    try std.testing.expectEqual(@as(usize, 1), res.packages.len);
    try std.testing.expectEqualStrings(name, res.packages[0].record.name);
    return res.packages[0].record.version;
}

test "the previous release resolves flat names from the namespaced registry; with the flat names gone, as after the deletion, only the kept kci_ ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try verifySnapshot(a);

    // Before the deletion: the registry serves index version 2 beside version 1, and the previous release reads version 1 as it
    // always did (it ignores `index_versions` and `api_v2_url`).
    var before = Current{};
    try before.open();
    defer before.fx.deinit();
    try before.publishFlat(&.{ "kci_buffer", "pkg_a" });
    const config = try before.fx.call(.GET, "/index/config.json", "", null);
    try inproc.expectContains(config.body, "\"index_versions\":[1,2]");
    try std.testing.expectEqualStrings("1.0.0", try prevResolves(a, &before, "pkg_a"));
    try std.testing.expectEqualStrings("1.0.0", try prevResolves(a, &before, "kci_buffer"));

    // After it: the flat names are gone but the kept kci_ packages. A name nobody published reads as one the index lacks.
    var after = Current{};
    try after.open();
    defer after.fx.deinit();
    try after.publishFlat(&.{"kci_buffer"});
    try std.testing.expectEqualStrings("pkg_a (required by mopm.toml) is not in the registry's index", try prevResolves(a, &after, "pkg_a"));
    try std.testing.expectEqualStrings("1.0.0", try prevResolves(a, &after, "kci_buffer"));
}

/// The previous release's `http` io for its CI token exchange, answered by the current registry's handler.
const PrevIo = struct {
    fx: *fixture.Fx,
    sent: usize = 0,

    pub fn once(io: *PrevIo, arena: Allocator, method: std.http.Method, url: []const u8, options: prev.http.Options) anyerror!prev.http.Answer {
        if (!std.mem.startsWith(u8, url, base)) return error.NotTheRegistry;
        io.sent += 1;
        const r = try io.fx.call(method, url[base.len..], options.body orelse "", options.token);
        return .{ .status = r.status, .body = try arena.dupe(u8, r.body) };
    }

    pub fn pause(_: *PrevIo, _: u64) void {}
};

/// A JWT-shaped CI identity token whose payload names `repository` (the fake reads no signature).
fn jwtOf(a: Allocator, repository: []const u8) ![]const u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const payload = try std.fmt.allocPrint(a, "{{\"repository\":\"{s}\"}}", .{repository});
    const part = try a.alloc(u8, enc.calcSize(payload.len));
    _ = enc.encode(part, payload);
    return std.fmt.allocPrint(a, "e30.{s}.c2ln", .{part});
}

test "the previous release cannot create a flat package once v1 stops creating: name_reserved with the hint to update mopm, and nothing is made" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try verifySnapshot(a);

    var c = Current{};
    try c.open();
    defer c.fx.deinit();
    try c.fx.state.ci_repos.append(c.fx.life.allocator(), "example/ci");
    const jwt = try jwtOf(a, "example/ci");
    const set = [_]prev.ci_oidc.Package{.{ .name = "brand_new", .version = "1.0.0" }};
    var io = PrevIo{ .fx = &c.fx };

    // The way the previous release creates a package: `mopm publish --staged --oidc` trades its CI identity for a token over
    // the set, and the registry makes each name nobody has. With v1 creation off, as the hosted registry has it now:
    const off = try c.fx.call(.POST, "/_fake/v1_creation", "{\"enabled\":false}", null);
    try std.testing.expectEqual(@as(u16, 200), off.status);
    switch (try prev.ci_oidc.exchangePackages(a, &io, .{}, base ++ "/api/v1", jwt, &set)) {
        .ok => return error.TokenMinted,
        .bad => |why| try std.testing.expectEqualStrings(
            "the registry refused the identity token for the 1 packages of the set: 'brand_new' is reserved.\n  hint: package names are in namespaces now; update mopm",
            why,
        ),
    }
    try std.testing.expectEqual(@as(usize, 1), io.sent);
    try std.testing.expect(c.fx.state.packageByName("brand_new") == null);

    // The same request, with v1 creation on (the registry before /api/v2), made the package: the refusal is the namespaces'.
    const on = try c.fx.call(.POST, "/_fake/v1_creation", "{\"enabled\":true}", null);
    try std.testing.expectEqual(@as(u16, 200), on.status);
    switch (try prev.ci_oidc.exchangePackages(a, &io, .{}, base ++ "/api/v1", jwt, &set)) {
        .ok => |token| try std.testing.expect(token.len > 0),
        .bad => |why| {
            std.debug.print("refused with v1 creation on: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    }
    try std.testing.expect(c.fx.state.packageByName("brand_new") != null);
}

// ---- The previous release reading what this release writes --------------------------------------------------------------------

test "the previous release refuses a namespaced mopm.toml with its name rule, naming the key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try verifySnapshot(a);

    // `mopm new example/alpha`'s manifest: this release reads it.
    const toml = (try core.scaffold.files(a, "example/alpha", .lib))[0];
    try std.testing.expectEqualStrings("mopm.toml", toml.path);
    var now_diag = core.manifest.Diagnostic{};
    const m = try core.manifest.parse(a, toml.contents, &now_diag);
    try std.testing.expectEqualStrings("example/alpha", m.package.full_name);
    try std.testing.expectEqualStrings("alpha", m.package.name);

    // The previous release stops at `[package] name`, line 2.
    var diag = prev.manifest.Diagnostic{};
    try std.testing.expectError(error.Invalid, prev.manifest.parse(a, toml.contents, &diag));
    try std.testing.expectEqualStrings("package name 'example/alpha' may contain only lowercase letters, digits and '_'", diag.message);
    try std.testing.expectEqual(@as(u32, 2), diag.pos.line);

    // A full name as a dependency key is refused the same way, at its key.
    const dep =
        \\[package]
        \\name = "alpha"
        \\version = "0.1.0"
        \\
        \\[toolchain]
        \\mojo = "1.0.0"
        \\
        \\[dependencies]
        \\"komira-ai/json" = "0.1"
        \\
    ;
    var dep_diag = prev.manifest.Diagnostic{};
    try std.testing.expectError(error.Invalid, prev.manifest.parse(a, dep, &dep_diag));
    try std.testing.expectEqualStrings("dependency name 'komira-ai/json' may contain only lowercase letters, digits and '_'", dep_diag.message);
    try std.testing.expectEqual(@as(u32, 9), dep_diag.pos.line);
}

test "the previous release refuses every lock of version 3 with its 'Update mopm.' message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try verifySnapshot(a);

    const examples = try jsonFiles(a, "tests/contract/examples/lock/valid");
    try std.testing.expect(examples.len > 0);
    for (examples) |e| {
        var why: []const u8 = "";
        const l = core.lock.parse(a, e.text, &why) catch |err| {
            std.debug.print("{s}: this release refuses its own example: {s}\n", .{ e.name, why });
            return err;
        };
        _ = l;
        var old_why: []const u8 = "";
        _ = prev.lock.parse(a, e.text, &old_why) catch |err| {
            try std.testing.expectEqual(error.Invalid, err);
            try std.testing.expectEqualStrings("lock_version is 3; this mopm reads 2. Update mopm.", old_why);
            continue;
        };
        std.debug.print("{s}: the previous release read a version 3 lock\n", .{e.name});
        return error.TestUnexpectedResult;
    }
}

test "the previous release refuses package metadata of schema 2 with its unsupported-schema error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try verifySnapshot(a);

    const text = try readRooted(a, "tests/fixtures/env/linux/dup/lib/mojo/pkg_a.mopm.json");
    const m = try core.metadata.parse(a, text);
    try std.testing.expectEqualStrings("example/pkg_a", m.name);
    try std.testing.expectError(error.UnsupportedSchema, prev.metadata.parse(a, text));
}

test "the previous release refuses a staged set of plan version 2, naming the file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try verifySnapshot(a);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try inproc.stageNamed(a, tmp.dir, &.{"example/alpha"}, "1.0.0", &.{null});
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    try std.testing.expectError(error.Refused, prev.overlay.load(a, dir, &why));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/plan.json: this mopm reads plan version 1", .{dir}), why);
}

test "the previous release reads a unit graph of format 6 only as far as its format number, which none of its formats is" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try verifySnapshot(a);

    const sha = "a" ** 64;
    const g = core.unit_graph.Graph{
        .package = "example/alpha@1.0.0",
        .mojo = "1.0.0",
        .toolchain = .{
            .mojo = "1.0.0",
            .subdir = "linux-64",
            .cc_target = "x86_64-linux-gnu",
            .closure_sha256 = sha,
            .zig = .{ .version = "0.12.0", .url = "https://example.invalid/zig.tar.xz", .sha256 = sha, .size = 1 },
            .components = &.{},
        },
        .units = &.{.{
            .id = "example/alpha@1.0.0#mojo1.0.0/lib",
            .package = "example/alpha",
            .import = "alpha",
            .version = "1.0.0",
            .kind = "lib",
            .root = ".",
        }},
    };
    const text = try core.unit_graph.render(a, g);
    const now = try core.unit_graph.parse(a, text);
    try std.testing.expectEqual(@as(u32, 6), now.unit_graph);
    try std.testing.expectEqual(core.unit_graph.format_version, now.unit_graph);

    // The previous release's graph reader takes the file (it ignores the unknown `import`) and would take the full name for a
    // package name; what stops `mopm unit` there is its format check (src/cli/unit_cmd.zig `formatProblem` at the tag), which
    // passes only the four formats below.
    const old = try prev.unit_graph.parse(a, text);
    try std.testing.expectEqual(@as(u32, 6), old.unit_graph);
    try std.testing.expectEqualStrings("example/alpha", old.units[0].package);
    const g0 = prev.unit_graph;
    for ([_]u32{ g0.format_version, g0.format_loads, g0.format_provided, g0.format_link }) |known| {
        try std.testing.expect(known != old.unit_graph);
    }
    try std.testing.expectEqual(@as(u32, 5), @max(@max(g0.format_version, g0.format_loads), @max(g0.format_provided, g0.format_link)));
}

// ---- This release reading what the previous release writes --------------------------------------------------------------------

test "this release refuses the previous fake registry: it serves no index version 2" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try verifySnapshot(a);

    var old: prev.Fx = undefined;
    try old.setup(base);
    defer old.deinit();
    const r = try old.call(.GET, "/index/config.json", "", null);
    try std.testing.expectEqual(@as(u16, 200), r.status);

    // The previous release itself reads it.
    switch (try prev.registry.parseConfig(a, r.body, prev.cli_version)) {
        .ok => {},
        .bad => |why| {
            std.debug.print("the previous release refused its own registry: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    }
    // This one does not, with the message of section 6 once `load` names the registry.
    switch (try core.registry.parseConfig(a, r.body, this_version)) {
        .ok => return error.TestUnexpectedResult,
        .bad => |why| try std.testing.expectEqualStrings(core.registry.no_version_2, why),
    }
    try std.testing.expectEqualStrings(
        "the registry at " ++ base ++ " serves no namespaced packages (index version 2); it is older than this mopm",
        try core.registry.noVersion2(a, base),
    );
}

test "this release takes every lock of version 1 or 2 the previous release reads for stale, with the message to run mopm lock" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try verifySnapshot(a);

    var locks = std.ArrayList(Named).init(a);
    // The previous release's lock examples (version 1, the `[toolchain] mojo` form)...
    for (try jsonFiles(a, snapshot ++ "/lock/valid")) |e| try locks.append(e);
    // ... and the version 2 form, as its writer renders it.
    const two = prev.lock.Lock{
        .mojo = "1.0.0",
        .channels = &.{"https://conda.mopm.dev/"},
        .packages = &.{},
        .mojos = &.{"1.0.0"},
        .closures = &.{.{ .mojo = "1.0.0", .subdir = "linux-64", .sha256 = "b" ** 64 }},
    };
    try locks.append(.{ .name = "rendered version 2", .text = try prev.lock.render(a, two) });

    var seen = [_]usize{ 0, 0, 0 };
    for (locks.items) |e| {
        var old_why: []const u8 = "";
        _ = prev.lock.parse(a, e.text, &old_why) catch |err| {
            std.debug.print("{s}: the previous release refuses its own lock: {s}\n", .{ e.name, old_why });
            return err;
        };
        const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, e.text, .{});
        const version = doc.object.get("lock_version").?.integer;
        try std.testing.expect(version == 1 or version == 2);
        seen[@intCast(version)] += 1;
        var why: []const u8 = "";
        try std.testing.expectError(error.Stale, core.lock.parse(a, e.text, &why));
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mopm.lock predates namespaces (lock_version {d}); run 'mopm lock'", .{version}), why);
        try std.testing.expectEqualStrings(try core.lock.staleMessage(a, version), why);
    }
    try std.testing.expect(seen[1] > 0);
    try std.testing.expectEqual(@as(usize, 1), seen[2]);
}

test "this release refuses a staged set of plan version 1, naming the file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try verifySnapshot(a);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try inproc.stageNamed(a, tmp.dir, &.{"alpha"}, "1.0.0", &.{null});
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    try std.testing.expectError(error.Refused, core.overlay.load(a, dir, &why));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/plan.json is version 1 (it predates namespaces); stage the set again", .{dir}), why);
}
