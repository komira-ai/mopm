//! The previous release (v0.0.104, d0b9020) and this code, each way, in one process: no socket, no child process.
//!
//! The previous release's command line and registry are its own code, byte for byte: the files that the live tree still holds
//! unchanged are read from there, the others are vendored under tests/compat/v0.0.104 (README.md there), and BUCK lays both out as
//! the release did. They are built as the modules `prev_cli` (the `Publisher` of src/cli/group_publish.zig at the tag, with the files it needs) and `prev_fake` (the
//! fake registry's handler, registry/fake at the tag). The current ones are `cli_publish` and `fake_fixture`. Every test first
//! checks that each of these files still hashes to its line of SHA256SUMS, so a run that passes ran the released bytes.
//!
//! What the two clients send is also written down: the bodies of the create and commit requests of one set, for each client, are
//! files under service/api/test/fixtures (released-client-v0.0.104/ and new-client/) that this test holds byte for byte to what the
//! clients send, and that the registry's TypeScript tests replay, so both registries are held to the same requests.
//!
//! The set: three packages at 1.0.0, `alpha` with a readme of quotes, backslashes and non-ASCII text, `beta` with an empty readme,
//! `gamma` with none.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const gp = @import("cli_publish");
const old = @import("prev_cli");
const fixture = @import("fake_fixture");
const prev = @import("prev_fake");
const inproc = @import("inproc_world.zig");

/// The current client and registry; the current client and the previous registry; the previous client and the current registry.
const NewNew = inproc.Wire(gp.Net, fixture.Fx, fixture.Reply);
const NewOld = inproc.Wire(gp.Net, prev.Fx, prev.Reply);
const OldNew = inproc.Wire(old.Net, fixture.Fx, fixture.Reply);

const NewClient = inproc.Client(gp);
const contains = inproc.contains;
const expectContains = inproc.expectContains;

const names: []const []const u8 = &.{ "alpha", "beta", "gamma" };
const readmes: []const ?[]const u8 = &.{ "# Alpha \"quoted\"\nline \u{e9} \u{65e5}\u{672c} \u{1f600} \\ end\n", "", null };
/// The previous fake registry refuses an empty readme (a text of 0 bytes is "empty or too long" to it, registry/fake/groups.zig at the
/// tag; the hosted registry took it), so the set it is given has none: `beta` has no readme and `gamma` a short one.
const readmes_nonempty: []const ?[]const u8 = &.{ readmes[0], null, "# gamma\nshort\n" };
const big_count = 100;
const big_readme_len = 65536;

const snapshot = "tests/compat/v0.0.104";
const goldens = "service/api/test/fixtures";

/// The repository root: BUILDRULES_TEST_WORK (the target's `data`) in the Buck2 build, else the current directory (the repository
/// root, `zig test` as lint.yml runs it).
fn rootDir() !std.fs.Dir {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.process.getEnvVarOwned(std.testing.allocator, "BUILDRULES_TEST_WORK") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return std.fs.cwd().openDir(".", .{}),
        else => return err,
    };
    defer std.testing.allocator.free(path);
    @memcpy(buf[0..path.len], path);
    return std.fs.cwd().openDir(buf[0..path.len], .{});
}

fn readRooted(a: Allocator, rel: []const u8) ![]u8 {
    var root = try rootDir();
    defer root.close();
    return root.readFileAlloc(a, rel, 1 << 24);
}

fn sha256Of(a: Allocator, bytes: []const u8) ![]const u8 {
    return inproc.sha256Hex(a, bytes);
}

/// Every line of `dir`'s `sums` ("<sha256>  <path relative to dir>") names a file that hashes to it, and every file under
/// `dir/<vendored>/fake` and `dir/<vendored>/cli` has a line: the code the modules are built from is the released code, unedited.
/// A path outside `vendored` is a file of the live tree that the release had byte for byte; if it changes, the first problem
/// names it, and that is the moment to vendor the released copy. Null when all of this holds; otherwise the first problem.
fn snapshotProblem(a: Allocator, dir: std.fs.Dir, sums: []const u8, vendored: []const u8) !?[]const u8 {
    const text = dir.readFileAlloc(a, sums, 1 << 20) catch |e| return try std.fmt.allocPrint(a, "{s}: {s}", .{ sums, @errorName(e) });
    var lines = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (line.len <= 66 or !std.mem.eql(u8, line[64..66], "  ")) return try std.fmt.allocPrint(a, "not a SHA256SUMS line: {s}", .{line});
        const rel = line[66..];
        const bytes = dir.readFileAlloc(a, rel, 1 << 24) catch |e| return try std.fmt.allocPrint(a, "{s}: {s}", .{ rel, @errorName(e) });
        if (!std.mem.eql(u8, line[0..64], try sha256Of(a, bytes))) return try std.fmt.allocPrint(a, "{s} does not hash to its line", .{rel});
        try lines.append(rel);
    }
    for ([_][]const u8{ "fake", "cli" }) |sub| {
        const sub_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ vendored, sub });
        var sub_dir = dir.openDir(sub_path, .{ .iterate = true }) catch |e| return try std.fmt.allocPrint(a, "{s}/: {s}", .{ sub_path, @errorName(e) });
        defer sub_dir.close();
        var walk = sub_dir.iterate();
        while (try walk.next()) |entry| {
            const rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ sub_path, entry.name });
            var listed = false;
            for (lines.items) |l| listed = listed or std.mem.eql(u8, l, rel);
            if (!listed) return try std.fmt.allocPrint(a, "not in SHA256SUMS: {s}", .{rel});
        }
    }
    return null;
}

/// The files of the previous release pass `snapshotProblem`; the test fails with the problem otherwise.
fn verifySnapshot(a: Allocator) !void {
    var root = try rootDir();
    defer root.close();
    const problem = try snapshotProblem(a, root, snapshot ++ "/SHA256SUMS", snapshot);
    try std.testing.expectEqual(@as(?[]const u8, null), problem);
}

test "a snapshot with an edited, an unlisted or a missing file is refused, naming it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const body = "pub const x = 1;\n";
    const sums = try std.fmt.allocPrint(a, "{s}  v/fake/x.zig\n{s}  live/y.zig\n", .{ try sha256Of(a, body), try sha256Of(a, body) });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("v/fake");
    try tmp.dir.makePath("v/cli");
    try tmp.dir.makePath("live");
    try tmp.dir.writeFile("SHA256SUMS", sums);
    try tmp.dir.writeFile("v/fake/x.zig", body);
    try tmp.dir.writeFile("live/y.zig", body);
    try std.testing.expectEqual(@as(?[]const u8, null), try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v"));
    try tmp.dir.writeFile("v/fake/x.zig", "pub const x = 2;\n");
    try std.testing.expectEqualStrings("v/fake/x.zig does not hash to its line", (try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v")).?);
    try tmp.dir.writeFile("v/fake/x.zig", body);
    try tmp.dir.writeFile("live/y.zig", "pub const y = 2;\n");
    try std.testing.expectEqualStrings("live/y.zig does not hash to its line", (try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v")).?);
    try tmp.dir.writeFile("live/y.zig", body);
    try tmp.dir.writeFile("v/cli/extra.zig", body);
    try std.testing.expectEqualStrings("not in SHA256SUMS: v/cli/extra.zig", (try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v")).?);
    try tmp.dir.deleteFile("v/cli/extra.zig");
    try tmp.dir.deleteFile("v/fake/x.zig");
    try std.testing.expectEqualStrings("v/fake/x.zig: FileNotFound", (try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v")).?);
}

fn golden(a: Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return readRooted(a, try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ goldens, dir, name }));
}

/// The first create request and the last commit request a run sent.
fn createOf(seen: []const inproc.Seen) ?inproc.Seen {
    for (seen) |s| {
        if (s.method == .POST and std.mem.eql(u8, s.path, "/api/v1/groups")) return s;
    }
    return null;
}

fn commitOf(seen: []const inproc.Seen) ?inproc.Seen {
    var i = seen.len;
    while (i > 0) {
        i -= 1;
        const s = seen[i];
        if (s.method == .POST and std.mem.endsWith(u8, s.path, "/commit")) return s;
    }
    return null;
}

/// What a run of the previous client did.
const OldRan = struct { result: ?old.Result, err: []const u8, from: usize };

/// The previous release's command between the check of the plan and the end (its `command` of src/cli/group_publish.zig): the
/// plan is checked, then the `Publisher` runs. A plan refused by the check ends the run with a null result before any request.
fn runOld(w: *OldNew, dir: std.fs.Dir) !OldRan {
    const a = w.a;
    const from = w.seen.items.len;
    const planned = try old.checkedPlan(a, dir, "staged", false);
    const console = try a.create(old.Console);
    console.* = old.Console.init(a, null);
    const checked = switch (planned) {
        .ok => |c| c,
        .bad => |why| return .{ .result = null, .err = why, .from = from },
    };
    var p = old.Publisher{
        .arena = a,
        .net = w.net(),
        .console = console,
        .dir = dir,
        .plan = checked.plan,
        .commit_body = checked.commit_body.?,
        .api_url = inproc.api_url,
        .token = w.token,
        .wait_secs = 120,
        .state = .{ .registry = inproc.api_url, .plan_sha256 = checked.plan.sha256 },
    };
    const result = p.run();
    return .{ .result = result, .err = console.err.items, .from = from };
}

/// Every member of the set is published at 1.0.0.
fn expectPublished(w: anytype) !void {
    for (names) |name| {
        const r = try w.get(try std.fmt.allocPrint(w.a, "/api/v1/packages/{s}/1.0.0", .{name}));
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expectEqualStrings("published", inproc.stringKey(r.value, "state") orelse "(none)");
    }
}

test "the vendored snapshot of the previous release hashes to its SHA256SUMS" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try verifySnapshot(arena_state.allocator());
}

test "the previous client publishes to this registry what the current client publishes there as objects, and sends the bodies written in the fixtures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try verifySnapshot(a);

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try inproc.stageNamed(a, dir.dir, names, "1.0.0", readmes);

    // The previous client, inline as it always sent them, to this registry.
    var from_old: OldNew = undefined;
    try OldNew.open(a, &from_old, names);
    defer from_old.close();
    const r_old = try runOld(&from_old, dir.dir);
    try std.testing.expectEqual(@as(?old.Result, .published), r_old.result);
    try expectPublished(&from_old);
    try std.testing.expectEqualStrings(readmes[0].?, (try from_old.versionReadme("alpha", "1.0.0")).?);
    try std.testing.expectEqualStrings("", (try from_old.versionReadme("beta", "1.0.0")).?);
    try std.testing.expect((try from_old.versionReadme("gamma", "1.0.0")) == null);
    try std.testing.expectEqualStrings(readmes[0].?, (try from_old.packageReadme("alpha")).?);

    // The current client, readmes as objects, to another instance of this registry (it lists the capability).
    var dir2 = std.testing.tmpDir(.{});
    defer dir2.cleanup();
    try inproc.stageNamed(a, dir2.dir, names, "1.0.0", readmes);
    var from_new: NewNew = undefined;
    try NewNew.open(a, &from_new, names);
    defer from_new.close();
    const r_new = try NewClient.run(&from_new, dir2.dir, false);
    try std.testing.expectEqual(@as(?gp.Result, .published), r_new.result);
    try expectPublished(&from_new);
    // The objects form: the alpha readme travels as an object, the empty one inline.
    try expectContains(commitOf(from_new.seen.items).?.body, "\"readme\":{\"sha256\":\"");
    try expectContains(commitOf(from_new.seen.items).?.body, "\"readme\":\"\"");

    // The two registries serve the same facts for every member. The clocks of the two instances are their own, so the index record's
    // `published_at` is blanked (servedFacts); nothing else is normalised.
    for (names) |name| {
        const x = try inproc.servedFacts(&from_old, name, "1.0.0");
        const y = try inproc.servedFacts(&from_new, name, "1.0.0");
        for (x, y) |fx, fy| try std.testing.expectEqualStrings(fx, fy);
    }

    // The requests of each client are the ones the fixtures hold (which the TypeScript registry replays).
    try std.testing.expectEqualStrings(try golden(a, "released-client-v0.0.104", "create.json"), createOf(from_old.seen.items).?.body);
    try std.testing.expectEqualStrings(try golden(a, "released-client-v0.0.104", "commit.json"), commitOf(from_old.seen.items).?.body);
    try std.testing.expectEqualStrings(try golden(a, "new-client", "create.json"), createOf(from_new.seen.items).?.body);
    try std.testing.expectEqualStrings(try golden(a, "new-client", "commit.json"), commitOf(from_new.seen.items).?.body);
}

test "the previous client refuses an oversized set before any request, as it always did, whatever this registry takes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try verifySnapshot(a);

    var w: OldNew = undefined;
    try OldNew.open(a, &w, try inproc.namesOf(a, "rdb", big_count));
    defer w.close();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try inproc.stageSet(a, dir.dir, "rdb", "1.0.0", try inproc.bigTexts(a, "rdb", big_count, big_readme_len));

    const r = try runOld(&w, dir.dir);
    try std.testing.expectEqual(@as(?old.Result, null), r.result);
    try expectContains(r.err, "the commit request of the 100 members to upload is ");
    try expectContains(r.err, "Shorten them or publish fewer packages in one group");
    try expectContains(r.err, "nothing was sent");
    try std.testing.expectEqual(@as(usize, 0), w.seen.items.len);
}

test "the current client publishes a small set inline to the previous registry, which sees no readme object and no readme declaration" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try verifySnapshot(a);

    var w: NewOld = undefined;
    try NewOld.open(a, &w, names);
    defer w.close();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try inproc.stageNamed(a, dir.dir, names, "1.0.0", readmes_nonempty);

    const r = try NewClient.run(&w, dir.dir, false);
    try std.testing.expectEqual(@as(?gp.Result, .published), r.result);
    try expectPublished(&w);

    // The previous registry's /health lists no features: the first request is that read, and what follows is the inline form.
    try std.testing.expectEqualStrings("/api/v1/health", w.seen.items[r.from].path);
    const health = try w.get("/api/v1/health");
    try std.testing.expect(!contains(health.body, "features"));
    const create = createOf(w.seen.items).?;
    try std.testing.expect(!contains(create.body, "\"readme\""));
    const commit = commitOf(w.seen.items).?;
    try expectContains(commit.body, "\"readme\":\"# Alpha");
    try expectContains(commit.body, "\"readme\":\"# gamma");
    try std.testing.expect(!contains(commit.body, "\"readme\":{"));
    // Every upload it received is a package file: three PUTs, none the size of a readme.
    var puts: usize = 0;
    for (w.seen.items[r.from..]) |s| {
        if (s.method != .PUT) continue;
        puts += 1;
        try std.testing.expect(contains(s.body, "the bytes of "));
    }
    try std.testing.expectEqual(names.len, puts);
    // The bytes it sent are the bytes the current client sends inline for this set to the current registry with objects switched off.
    var dir2 = std.testing.tmpDir(.{});
    defer dir2.cleanup();
    try inproc.stageNamed(a, dir2.dir, names, "1.0.0", readmes_nonempty);
    var same: NewNew = undefined;
    try NewNew.open(a, &same, names);
    defer same.close();
    _ = try same.fx.call(.POST, "/_fake/readme_objects", "{\"enabled\":false}", null);
    const r2 = try NewClient.run(&same, dir2.dir, false);
    try std.testing.expectEqual(@as(?gp.Result, .published), r2.result);
    try std.testing.expectEqualStrings(createOf(same.seen.items).?.body, create.body);
    try std.testing.expectEqualStrings(commitOf(same.seen.items).?.body, commit.body);
}

test "the current client refuses an oversized set after the read of /health alone when the previous registry is the one it publishes to" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try verifySnapshot(a);

    var w: NewOld = undefined;
    try NewOld.open(a, &w, try inproc.namesOf(a, "rdb", big_count));
    defer w.close();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try inproc.stageSet(a, dir.dir, "rdb", "1.0.0", try inproc.bigTexts(a, "rdb", big_count, big_readme_len));

    const r = try NewClient.run(&w, dir.dir, false);
    try std.testing.expectEqual(@as(?gp.Result, null), r.result);
    try expectContains(r.err, "the commit request of the 100 members to upload is ");
    try expectContains(r.err, "the registry does not take readmes as objects");
    // Only the read of /health: no create, no upload, no commit, no state.json.
    try std.testing.expectEqual(@as(usize, 1), w.seen.items.len - r.from);
    try std.testing.expectEqualStrings("/api/v1/health", w.seen.items[r.from].path);
    try std.testing.expect(!inproc.fileExists(dir.dir, "state.json"));
}
