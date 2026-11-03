//! Readmes sent as uploaded objects by `mopm publish --staged` (spec/staged-set.md), against the fake registry's own request
//! handler, in one process: no socket, no child process, no clock of the host.
//!
//! The client is the one of src/cli/group_publish.zig (module `cli_publish`): its form choice (`formOf`) and its `Publisher`, run
//! as the command runs them between the check of the plan and the end. The registry is the handler of registry/fake (module
//! `fake_fixture`, whose `Fx.call` builds an `api.Ctx` as the server does, `/_fake/upload/<id>` PUTs and `/_fake/` controls
//! included). `World.net` is the `Net` between them: it hands each request to the handler, records what the run sent, and keeps a
//! clock that only `sleep` moves.
//!
//! Not covered here: the command's own steps before and after (`command` is private to group_publish.zig): it reads the
//! registry's `config.json` with the real HTTP client (`registry_cmd.open`), its `--oidc` token comes from GitHub's job
//! variables and endpoint (`ACTIONS_ID_TOKEN_REQUEST_URL`), and its token from `$MOPM_TOKEN` or the login. None of that goes
//! through a `Net`, so it cannot run hermetically in one process. The order the command makes (`/health` read before any token
//! exchange) is src/cli/group_readmes_test.zig's and tests/drivers/oidc_publish_test.zig's.
//!
//! A set is a staged directory (plan.json, the package files, one `<name>.md` readme per member that has one).

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const gp = @import("cli_publish");
const fixture = @import("fake_fixture");

const Fx = fixture.Fx;
const StateT = std.meta.fieldInfo(gp.Publisher, .state).type;

/// A loopback address: the client sends an upload only to https or loopback http. No socket is ever opened to it.
const base = "http://127.0.0.1:1";
const api_url = base ++ "/api/v1";
const big_count = 100;
const big_readme_len = 65536;
const refusal_head = "the commit request of the 100 members to upload is ";
const objects_note = "the registry does not take readmes as objects";

const Seen = struct { method: std.http.Method, path: []const u8, token: ?[]const u8, body: []const u8 };

/// A fake registry with an account that owns the names it is given, the `Net` to it, and what the runs sent.
const World = struct {
    a: Allocator,
    fx: Fx = undefined,
    token: []const u8 = "big-secret",
    seen: std.ArrayList(Seen),
    clock: i64 = 1000,
    /// The next commit is applied by the registry and its answer is lost (the connection resets).
    lose_commit_answer: bool = false,

    fn open(a: Allocator, w: *World, names: []const []const u8) !void {
        w.* = .{ .a = a, .seen = std.ArrayList(Seen).init(a) };
        try w.fx.setup();
        w.fx.state.base_url = base;
        const life = w.fx.life.allocator();
        const s = &w.fx.state;
        const owned = try life.alloc([]const u8, names.len);
        for (names, owned) |n, *o| {
            o.* = try life.dupe(u8, n);
            const p = try s.addPackage(.{ .name = o.*, .created_at = s.now(), .updated_at = s.now(), .claim_expires_at = s.now() + 86400 });
            try p.owners.append(life, w.fx.alice);
        }
        _ = try s.addToken(.{ .id = "t9", .secret = w.token, .kind = .api, .user = w.fx.alice, .scopes = &.{ .publish, .yank }, .packages = owned, .created_at = s.now(), .expires_at = s.now() + 86400 });
    }

    fn close(w: *World) void {
        w.fx.deinit();
    }

    fn net(w: *World) gp.Net {
        return .{ .ptr = w, .vtable = &.{ .request = request, .sleep = sleep, .now = now } };
    }

    fn request(ptr: *anyopaque, _: Allocator, method: std.http.Method, url: []const u8, options: core.http.Options) anyerror!core.http.Answer {
        const w: *World = @ptrCast(@alignCast(ptr));
        if (!std.mem.startsWith(u8, url, base)) return error.ConnectionRefused;
        const path = url[base.len..];
        if (std.mem.indexOfScalar(u8, path, '?') != null) return error.UnexpectedQuery;
        const body = options.body orelse "";
        try w.seen.append(.{ .method = method, .path = try w.a.dupe(u8, path), .token = if (options.token) |t| try w.a.dupe(u8, t) else null, .body = try w.a.dupe(u8, body) });
        const reply = try w.fx.call(method, path, body, options.token);
        if (w.lose_commit_answer and method == .POST and std.mem.endsWith(u8, path, "/commit")) {
            w.lose_commit_answer = false;
            return error.ConnectionResetByPeer;
        }
        return .{ .status = reply.status, .body = reply.body };
    }

    fn sleep(ptr: *anyopaque, secs: u64) void {
        const w: *World = @ptrCast(@alignCast(ptr));
        w.clock += @intCast(secs);
    }

    fn now(ptr: *anyopaque) i64 {
        const w: *World = @ptrCast(@alignCast(ptr));
        return w.clock;
    }

    fn objects(w: *World, on: bool) !void {
        _ = try w.fx.call(.POST, "/_fake/readme_objects", if (on) "{\"enabled\":true}" else "{\"enabled\":false}", null);
    }

    fn get(w: *World, path: []const u8) !fixture.Reply {
        return w.fx.call(.GET, path, "", null);
    }

    /// The `readme` of a published version as getVersion serves it: null when the version has no such key.
    fn versionReadme(w: *World, name: []const u8, version: []const u8) !?[]const u8 {
        const r = try w.get(try std.fmt.allocPrint(w.a, "/api/v1/packages/{s}/{s}", .{ name, version }));
        try std.testing.expectEqual(@as(u16, 200), r.status);
        return stringKey(r.value, "readme");
    }

    fn packageReadme(w: *World, name: []const u8) !?[]const u8 {
        const r = try w.get(try std.fmt.allocPrint(w.a, "/api/v1/packages/{s}", .{name}));
        try std.testing.expectEqual(@as(u16, 200), r.status);
        return stringKey(r.value, "readme");
    }

    /// How many of the members `<prefix>0..` of `count` are published at `version`.
    fn published(w: *World, prefix: []const u8, members: usize, version: []const u8) !usize {
        var n: usize = 0;
        for (0..members) |i| {
            const r = try w.get(try std.fmt.allocPrint(w.a, "/api/v1/packages/{s}{d}/{s}", .{ prefix, i, version }));
            if (r.status == 200 and std.mem.eql(u8, stringKey(r.value, "state") orelse "", "published")) n += 1;
        }
        return n;
    }

    fn groupStatus(w: *World, id: []const u8) ![]const u8 {
        const r = try w.fx.call(.GET, try std.fmt.allocPrint(w.a, "/api/v1/groups/{s}", .{id}), "", w.token);
        return stringKey(r.value, "status") orelse "(none)";
    }

    fn seenCount(w: *World, method: std.http.Method, from: usize, suffix: []const u8) usize {
        var n: usize = 0;
        for (w.seen.items[from..]) |s| {
            if (s.method == method and std.mem.endsWith(u8, s.path, suffix)) n += 1;
        }
        return n;
    }

    fn lastCommit(w: *World) ?Seen {
        var i = w.seen.items.len;
        while (i > 0) {
            i -= 1;
            const s = w.seen.items[i];
            if (s.method == .POST and std.mem.endsWith(u8, s.path, "/commit")) return s;
        }
        return null;
    }
};

fn stringKey(v: std.json.Value, key: []const u8) ?[]const u8 {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const x = o.get(key) orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

/// What a run did: how it ended (null when it stopped before any publisher was made) and what it said.
const Ran = struct { result: ?gp.Result, out: []const u8, err: []const u8, from: usize, group_id: []const u8 };

/// The command between the check of the plan and the end, as group_publish.zig's `command` makes it: the form of the readmes
/// from `/health` (a group the staged directory's state.json names is resumed), then the publisher.
fn run(w: *World, dir: std.fs.Dir, no_commit: bool) !Ran {
    const a = w.a;
    const from = w.seen.items.len;
    const planned = try gp.checkedPlan(a, dir, "staged", false);
    try std.testing.expectEqualStrings("a checked plan", if (planned == .ok) "a checked plan" else planned.bad);
    const checked = planned.ok;
    const old: ?StateT = if (dir.readFileAlloc(a, "state.json", 1 << 24)) |text|
        try std.json.parseFromSliceLeaky(StateT, a, text, .{ .ignore_unknown_fields = true })
    else |_|
        null;
    const resumed: ?StateT = if (old) |s| (if (s.group_id.len > 0) s else null) else null;
    const console = try a.create(gp.Console);
    console.* = gp.Console.init(a, null);
    const form = (try gp.formOf(a, w.net(), api_url, checked, resumed, console)) orelse
        return .{ .result = null, .out = console.out.items, .err = console.err.items, .from = from, .group_id = "" };
    var p = gp.Publisher{
        .arena = a,
        .net = w.net(),
        .console = console,
        .dir = dir,
        .plan = checked.plan,
        .commit_body = form.choice.commit_body,
        .entries = checked.entries,
        .objects = form.choice.objects,
        .refusal = form.refusal,
        .api_url = api_url,
        .token = w.token,
        .wait_secs = 120,
        .no_commit = no_commit,
        .state = old orelse .{ .registry = api_url, .plan_sha256 = checked.plan.sha256 },
    };
    const result = p.run();
    return .{ .result = result, .out = console.out.items, .err = console.err.items, .from = from, .group_id = p.state.group_id };
}

fn sha256Hex(a: Allocator, bytes: []const u8) ![]const u8 {
    return core.install.sha256Hex(a, bytes);
}

fn nameOf(a: Allocator, prefix: []const u8, i: usize) ![]u8 {
    return std.fmt.allocPrint(a, "{s}{d}", .{ prefix, i });
}

fn filenameOf(a: Allocator, name: []const u8, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "mojo-{s}-{s}-mojo1.0.0_0.conda", .{ name, version });
}

/// `len` bytes of text: a title line, then a line of body repeated.
fn readmeOf(a: Allocator, name: []const u8, len: usize) ![]u8 {
    const out = try a.alloc(u8, len);
    const line = try std.fmt.allocPrint(a, "# {s}\n", .{name});
    var at: usize = 0;
    var title = true;
    while (at < len) {
        const piece = if (title) line else "the readme of this package says what it is for\n";
        title = false;
        const n = @min(piece.len, len - at);
        @memcpy(out[at .. at + n], piece[0..n]);
        at += n;
    }
    return out;
}

/// The names `<prefix>0..` of `count`.
fn namesOf(a: Allocator, prefix: []const u8, count: usize) ![]const []const u8 {
    const out = try a.alloc([]const u8, count);
    for (out, 0..) |*o, i| o.* = try nameOf(a, prefix, i);
    return out;
}

/// Writes the staged directory of members `<prefix>0..`, each with one file and the readme `texts[i]` (null: none, "": empty).
fn stageSet(a: Allocator, dir: std.fs.Dir, prefix: []const u8, version: []const u8, texts: []const ?[]const u8) !void {
    var plan = std.ArrayList(u8).init(a);
    try plan.appendSlice("{\"version\":1,\"members\":[");
    try dir.makePath("noarch");
    for (texts, 0..) |text, i| {
        const name = try nameOf(a, prefix, i);
        const bytes = try std.fmt.allocPrint(a, "the bytes of {s} {s}", .{ name, version });
        const filename = try filenameOf(a, name, version);
        try dir.writeFile(try std.fmt.allocPrint(a, "noarch/{s}", .{filename}), bytes);
        var key: []const u8 = "";
        if (text) |t| {
            try dir.writeFile(try std.fmt.allocPrint(a, "{s}.md", .{name}), t);
            key = try std.fmt.allocPrint(a, "\"readme\":\"{s}.md\",", .{name});
        }
        if (i != 0) try plan.append(',');
        try plan.writer().print(
            "{{\"name\":\"{s}\",\"version\":\"{s}\",\"action\":\"upload\",\"manifest_sha256\":\"{s}\",{s}\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}]}}",
            .{ name, version, try sha256Hex(a, name), key, filename, try sha256Hex(a, bytes), bytes.len },
        );
    }
    try plan.appendSlice("]}");
    try dir.writeFile("plan.json", plan.items);
}

/// `count` readmes of `len` bytes, one per member of `prefix`.
fn bigTexts(a: Allocator, prefix: []const u8, count: usize, len: usize) ![]const ?[]const u8 {
    const out = try a.alloc(?[]const u8, count);
    for (out, 0..) |*o, i| o.* = try readmeOf(a, try nameOf(a, prefix, i), len);
    return out;
}

/// How many of the members `<prefix>0..` serve the readme they were staged with at `version`.
fn servedWhole(w: *World, prefix: []const u8, texts: []const ?[]const u8, version: []const u8) !usize {
    var n: usize = 0;
    for (texts, 0..) |t, i| {
        const got = (try w.versionReadme(try nameOf(w.a, prefix, i), version)) orelse continue;
        if (std.mem.eql(u8, got, t.?)) n += 1;
    }
    return n;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn expectContains(hay: []const u8, needle: []const u8) !void {
    try std.testing.expectEqualStrings(needle, if (contains(hay, needle)) needle else hay);
}

fn fileExists(dir: std.fs.Dir, path: []const u8) bool {
    dir.access(path, .{}) catch return false;
    return true;
}

fn expectHealthFirstWithoutToken(w: *World, from: usize) !void {
    const first = w.seen.items[from];
    try std.testing.expectEqual(std.http.Method.GET, first.method);
    try std.testing.expectEqualStrings("/api/v1/health", first.path);
    try std.testing.expect(first.token == null);
}

// ------------------------------------------------------------------- scenarios

test "100 members with 64 KiB readmes, over what a commit may carry inline, publish as objects: the commit stays small and every readme is served" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var w: World = undefined;
    try World.open(a, &w, try namesOf(a, "rdb", big_count));
    defer w.close();
    var staged = std.testing.tmpDir(.{});
    defer staged.cleanup();
    const texts = try bigTexts(a, "rdb", big_count, big_readme_len);
    try stageSet(a, staged.dir, "rdb", "1.0.0", texts);

    const r = try run(&w, staged.dir, false);
    try std.testing.expectEqual(@as(?gp.Result, .published), r.result);
    try expectHealthFirstWithoutToken(&w, r.from);
    try std.testing.expectEqual(@as(usize, big_count), try w.published("rdb", big_count, "1.0.0"));
    try std.testing.expectEqual(@as(usize, big_count), try servedWhole(&w, "rdb", texts, "1.0.0"));
    try std.testing.expectEqualStrings(texts[7].?, (try w.packageReadme("rdb7")).?);

    // The commit request the registry received names the readmes and carries none: the body is far under what 6.4 MB of text takes.
    const commit = w.lastCommit().?;
    try std.testing.expect(commit.token != null);
    try std.testing.expect(commit.body.len < 64 * 1024);
    try std.testing.expect(!contains(commit.body, "the readme of this package"));
    try expectContains(commit.body, try std.fmt.allocPrint(a, "\"readme\":{{\"sha256\":\"{s}\",\"size\":{d}}}", .{ try sha256Hex(a, texts[0].?), big_readme_len }));

    // Each readme was PUT to the registry's storage route as an object, a file and a readme per member, none with a token.
    var puts: usize = 0;
    var readme_puts: usize = 0;
    for (w.seen.items[r.from..]) |s| {
        if (s.method != .PUT) continue;
        puts += 1;
        try std.testing.expect(s.token == null);
        try std.testing.expect(std.mem.startsWith(u8, s.path, "/_fake/upload/"));
        if (s.body.len == big_readme_len) readme_puts += 1;
    }
    try std.testing.expectEqual(@as(usize, 2 * big_count), puts);
    try std.testing.expectEqual(@as(usize, big_count), readme_puts);
}

test "a registry without the capability takes a small set inline and refuses a large one after the read of /health alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var w: World = undefined;
    const names = try std.mem.concat(a, []const u8, &.{ try namesOf(a, "rds", 3), try namesOf(a, "rdb", big_count) });
    try World.open(a, &w, names);
    defer w.close();
    try w.objects(false);

    var small_dir = std.testing.tmpDir(.{});
    defer small_dir.cleanup();
    const small = try bigTexts(a, "rds", 3, 2000);
    try stageSet(a, small_dir.dir, "rds", "1.0.0", small);
    const s = try run(&w, small_dir.dir, false);
    try std.testing.expectEqual(@as(?gp.Result, .published), s.result);
    try std.testing.expectEqual(@as(usize, 3), try servedWhole(&w, "rds", small, "1.0.0"));
    // Inline: the commit carries the text.
    try expectContains(w.lastCommit().?.body, "\"readme\":\"# rds0\\n");

    var large_dir = std.testing.tmpDir(.{});
    defer large_dir.cleanup();
    try stageSet(a, large_dir.dir, "rdb", "2.0.0", try bigTexts(a, "rdb", big_count, big_readme_len));
    const r = try run(&w, large_dir.dir, false);
    try std.testing.expectEqual(@as(?gp.Result, null), r.result);
    try expectContains(r.err, refusal_head);
    try expectContains(r.err, "Shorten them or publish fewer packages in one group");
    try expectContains(r.err, objects_note);
    // After the one read of GET /health: nothing else was sent, no state.json was written, nothing is published.
    try std.testing.expectEqual(@as(usize, 1), w.seen.items.len - r.from);
    try expectHealthFirstWithoutToken(&w, r.from);
    try std.testing.expect(!fileExists(large_dir.dir, "state.json"));
    try std.testing.expectEqual(@as(usize, 0), try w.published("rdb", big_count, "2.0.0"));
}

test "a group staged with readme objects is resumed inline when the set fits and refused while open when it does not, then published when objects are back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var w: World = undefined;
    const names = try std.mem.concat(a, []const u8, &.{ try namesOf(a, "rdt", 3), try namesOf(a, "rdb", big_count) });
    try World.open(a, &w, names);
    defer w.close();
    try w.objects(true);

    // A set that fits inline: staged with objects, resumed inline in the same group.
    var fits_dir = std.testing.tmpDir(.{});
    defer fits_dir.cleanup();
    const fits = try bigTexts(a, "rdt", 3, 3000);
    try stageSet(a, fits_dir.dir, "rdt", "1.0.0", fits);
    const staged = try run(&w, fits_dir.dir, true);
    try std.testing.expectEqual(@as(?gp.Result, .staged), staged.result);
    try std.testing.expectEqualStrings("open", try w.groupStatus(staged.group_id));
    try w.objects(false);
    const resumed = try run(&w, fits_dir.dir, false);
    try std.testing.expectEqual(@as(?gp.Result, .published), resumed.result);
    try std.testing.expectEqualStrings(staged.group_id, resumed.group_id);
    try std.testing.expectEqual(@as(usize, 3), try servedWhole(&w, "rdt", fits, "1.0.0"));

    // A set that does not fit inline: the resume is refused, the group stays open, and state.json is as it was.
    try w.objects(true);
    var over_dir = std.testing.tmpDir(.{});
    defer over_dir.cleanup();
    const over = try bigTexts(a, "rdb", big_count, big_readme_len);
    try stageSet(a, over_dir.dir, "rdb", "3.0.0", over);
    const staged_over = try run(&w, over_dir.dir, true);
    try std.testing.expectEqual(@as(?gp.Result, .staged), staged_over.result);
    const state_before = try over_dir.dir.readFileAlloc(a, "state.json", 1 << 20);
    try w.objects(false);
    const refused = try run(&w, over_dir.dir, false);
    try std.testing.expectEqual(@as(?gp.Result, .failed), refused.result);
    try expectContains(refused.err, refusal_head);
    try expectContains(refused.err, "nothing was uploaded or committed");
    try expectContains(refused.err, objects_note);
    try std.testing.expectEqual(@as(usize, 0), w.seenCount(.PUT, refused.from, ""));
    try std.testing.expectEqual(@as(usize, 0), w.seenCount(.POST, refused.from, "/commit"));
    try std.testing.expectEqualStrings("open", try w.groupStatus(staged_over.group_id));
    try std.testing.expectEqual(@as(usize, 0), try w.published("rdb", big_count, "3.0.0"));
    try std.testing.expectEqualStrings(state_before, try over_dir.dir.readFileAlloc(a, "state.json", 1 << 20));

    try w.objects(true);
    const again = try run(&w, over_dir.dir, false);
    try std.testing.expectEqual(@as(?gp.Result, .published), again.result);
    try std.testing.expectEqualStrings(staged_over.group_id, again.group_id);
    try std.testing.expectEqual(@as(usize, big_count), try servedWhole(&w, "rdb", over, "3.0.0"));
}

/// getVersion and getPackage readmes, the sparse-index record (the clock of each fake blanked) and the channel file of member `i`.
fn servedFacts(w: *World, prefix: []const u8, i: usize, version: []const u8) ![4][]const u8 {
    const a = w.a;
    const name = try nameOf(a, prefix, i);
    const idx = try w.get(try std.fmt.allocPrint(a, "/index/{s}/{s}/{s}", .{ name[0..2], name[2..4], name }));
    try std.testing.expectEqual(@as(u16, 200), idx.status);
    const channel = try w.get(try std.fmt.allocPrint(a, "/channel/noarch/{s}", .{try filenameOf(a, name, version)}));
    try std.testing.expectEqual(@as(u16, 200), channel.status);
    return .{
        (try w.versionReadme(name, version)) orelse "(none)",
        (try w.packageReadme(name)) orelse "(none)",
        try withoutPublishedAt(a, idx.body),
        channel.body,
    };
}

fn withoutPublishedAt(a: Allocator, body: []const u8) ![]u8 {
    const key = "\"published_at\":\"";
    const at = std.mem.indexOf(u8, body, key) orelse return a.dupe(u8, body);
    const from = at + key.len;
    const to = std.mem.indexOfScalarPos(u8, body, from, '"') orelse return a.dupe(u8, body);
    return std.mem.concat(a, u8, &.{ body[0..from], body[to..] });
}

test "the same set published as objects and inline serves the same readmes, index records and channel files" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var with: World = undefined;
    var without: World = undefined;
    try World.open(a, &with, try namesOf(a, "rdm", 3));
    defer with.close();
    try World.open(a, &without, try namesOf(a, "rdm", 3));
    defer without.close();
    try with.objects(true);
    try without.objects(false);

    // A byte order mark, multi-byte text, a long line, and the quote and control characters of JSON.
    const texts = [_]?[]const u8{
        "\xEF\xBB\xBF# rdm0\nwith a byte order mark\n",
        "# rdm1 \xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80\n\"quoted\" \\ \t\x01 and </script>\n",
        "x" ** 5000,
    };
    var dir_a = std.testing.tmpDir(.{});
    defer dir_a.cleanup();
    var dir_b = std.testing.tmpDir(.{});
    defer dir_b.cleanup();
    try stageSet(a, dir_a.dir, "rdm", "1.0.0", &texts);
    try stageSet(a, dir_b.dir, "rdm", "1.0.0", &texts);
    const x = try run(&with, dir_a.dir, false);
    const y = try run(&without, dir_b.dir, false);
    try std.testing.expectEqual(@as(?gp.Result, .published), x.result);
    try std.testing.expectEqual(@as(?gp.Result, .published), y.result);
    // The two runs really did go different ways.
    try std.testing.expect(!contains(with.lastCommit().?.body, "with a byte order mark"));
    try expectContains(without.lastCommit().?.body, "with a byte order mark");

    for (texts, 0..) |t, i| {
        const fx = try servedFacts(&with, "rdm", i, "1.0.0");
        const fy = try servedFacts(&without, "rdm", i, "1.0.0");
        try std.testing.expectEqualStrings(t.?, fx[0]);
        try std.testing.expectEqualStrings(t.?, fx[1]);
        for (fx, fy) |ex, ey| try std.testing.expectEqualStrings(ex, ey);
    }
}

test "an empty, an absent and a non-empty readme in one set are served as the empty string, no key, and the text, in both forms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const texts = [_]?[]const u8{ "", null, "# text\nthe body\n" };
    for ([_]bool{ true, false }) |objects| {
        var w: World = undefined;
        try World.open(a, &w, try namesOf(a, "rde", 3));
        defer w.close();
        try w.objects(objects);
        var dir = std.testing.tmpDir(.{});
        defer dir.cleanup();
        try stageSet(a, dir.dir, "rde", "1.0.0", &texts);
        const r = try run(&w, dir.dir, false);
        try std.testing.expectEqual(@as(?gp.Result, .published), r.result);

        try std.testing.expectEqualStrings("", (try w.versionReadme("rde0", "1.0.0")).?);
        try std.testing.expect((try w.versionReadme("rde1", "1.0.0")) == null);
        try std.testing.expectEqualStrings(texts[2].?, (try w.versionReadme("rde2", "1.0.0")).?);
        try std.testing.expectEqualStrings("", (try w.packageReadme("rde0")).?);
        try std.testing.expect((try w.packageReadme("rde1")) == null);
        try std.testing.expectEqualStrings(texts[2].?, (try w.packageReadme("rde2")).?);
        // With objects only the non-empty readme travels as an object; the empty one is in the commit as the empty string.
        const commit = w.lastCommit().?.body;
        try expectContains(commit, "\"readme\":\"\"");
        try std.testing.expectEqual(contains(commit, "\"readme\":{\"sha256\""), objects);
    }
}

test "a large group whose commit answer is lost is waited for to visible by a rerun after the registry stopped taking readme objects" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var w: World = undefined;
    try World.open(a, &w, try namesOf(a, "rdb", big_count));
    defer w.close();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const texts = try bigTexts(a, "rdb", big_count, big_readme_len);
    try stageSet(a, dir.dir, "rdb", "1.0.0", texts);
    try w.objects(true);

    // The registry applies the commit and the answer never arrives.
    w.lose_commit_answer = true;
    const first = try run(&w, dir.dir, false);
    try std.testing.expect(first.result != null and first.result.? != .published);
    try std.testing.expectEqual(@as(usize, 1), w.seenCount(.POST, first.from, "/commit"));
    const kept = try dir.dir.readFileAlloc(a, "state.json", 1 << 20);
    try expectContains(kept, first.group_id);

    // The registry no longer lists the capability: the set cannot go inline, but its commit was taken, so it is waited for.
    try w.objects(false);
    const rerun = try run(&w, dir.dir, false);
    try std.testing.expectEqual(@as(?gp.Result, .published), rerun.result);
    try std.testing.expectEqualStrings(first.group_id, rerun.group_id);
    // The rerun cannot know the commit went through (its answer was lost), so it reads /health first and defers the refusal an
    // oversized inline commit would earn; the create then finds the group past open, and there is nothing to refuse.
    try expectHealthFirstWithoutToken(&w, rerun.from);
    try std.testing.expectEqualStrings("/api/v1/groups", w.seen.items[rerun.from + 1].path);
    try std.testing.expectEqual(@as(usize, 0), w.seenCount(.PUT, rerun.from, ""));
    try std.testing.expectEqual(@as(usize, 0), w.seenCount(.POST, rerun.from, "/commit"));
    try std.testing.expectEqualStrings("visible", try w.groupStatus(first.group_id));
    try std.testing.expectEqual(@as(usize, big_count), try servedWhole(&w, "rdb", texts, "1.0.0"));
}
