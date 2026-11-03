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
const inproc = @import("inproc_world.zig");

const Fx = fixture.Fx;

const api_url = inproc.api_url;
const Client = inproc.Client(gp);
const Ran = Client.Ran;
const run = Client.run;
const sha256Hex = inproc.sha256Hex;
const nameOf = inproc.nameOf;
const filenameOf = inproc.filenameOf;
const readmeOf = inproc.readmeOf;
const namesOf = inproc.namesOf;
const stageSet = inproc.stageSet;
const bigTexts = inproc.bigTexts;
const contains = inproc.contains;
const expectContains = inproc.expectContains;
const fileExists = inproc.fileExists;
const big_count = 100;
const big_readme_len = 65536;
const refusal_head = "the commit request of the 100 members to upload is ";
const objects_note = "the registry does not take readmes as objects";

/// A fake registry with an account that owns the names it is given, the `Net` to it, and what the runs sent.
const World = inproc.Wire(gp.Net, Fx, fixture.Reply);
const Seen = inproc.Seen;
const stringKey = inproc.stringKey;

/// The control that turns the registry's readme objects on or off (the fake's `/_fake/readme_objects`).
fn setObjects(w: *World, on: bool) !void {
    _ = try w.fx.call(.POST, "/_fake/readme_objects", if (on) "{\"enabled\":true}" else "{\"enabled\":false}", null);
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
    try setObjects(&w, false);

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
    try setObjects(&w, true);

    // A set that fits inline: staged with objects, resumed inline in the same group.
    var fits_dir = std.testing.tmpDir(.{});
    defer fits_dir.cleanup();
    const fits = try bigTexts(a, "rdt", 3, 3000);
    try stageSet(a, fits_dir.dir, "rdt", "1.0.0", fits);
    const staged = try run(&w, fits_dir.dir, true);
    try std.testing.expectEqual(@as(?gp.Result, .staged), staged.result);
    try std.testing.expectEqualStrings("open", try w.groupStatus(staged.group_id));
    try setObjects(&w, false);
    const resumed = try run(&w, fits_dir.dir, false);
    try std.testing.expectEqual(@as(?gp.Result, .published), resumed.result);
    try std.testing.expectEqualStrings(staged.group_id, resumed.group_id);
    try std.testing.expectEqual(@as(usize, 3), try servedWhole(&w, "rdt", fits, "1.0.0"));

    // A set that does not fit inline: the resume is refused, the group stays open, and state.json is as it was.
    try setObjects(&w, true);
    var over_dir = std.testing.tmpDir(.{});
    defer over_dir.cleanup();
    const over = try bigTexts(a, "rdb", big_count, big_readme_len);
    try stageSet(a, over_dir.dir, "rdb", "3.0.0", over);
    const staged_over = try run(&w, over_dir.dir, true);
    try std.testing.expectEqual(@as(?gp.Result, .staged), staged_over.result);
    const state_before = try over_dir.dir.readFileAlloc(a, "state.json", 1 << 20);
    try setObjects(&w, false);
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

    try setObjects(&w, true);
    const again = try run(&w, over_dir.dir, false);
    try std.testing.expectEqual(@as(?gp.Result, .published), again.result);
    try std.testing.expectEqualStrings(staged_over.group_id, again.group_id);
    try std.testing.expectEqual(@as(usize, big_count), try servedWhole(&w, "rdb", over, "3.0.0"));
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
    try setObjects(&with, true);
    try setObjects(&without, false);

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
        const fx = try inproc.servedFacts(&with, try nameOf(a, "rdm", i), "1.0.0");
        const fy = try inproc.servedFacts(&without, try nameOf(a, "rdm", i), "1.0.0");
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
        try setObjects(&w, objects);
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
    try setObjects(&w, true);

    // The registry applies the commit and the answer never arrives.
    w.lose_commit_answer = true;
    const first = try run(&w, dir.dir, false);
    try std.testing.expect(first.result != null and first.result.? != .published);
    try std.testing.expectEqual(@as(usize, 1), w.seenCount(.POST, first.from, "/commit"));
    const kept = try dir.dir.readFileAlloc(a, "state.json", 1 << 20);
    try expectContains(kept, first.group_id);

    // The registry no longer lists the capability: the set cannot go inline, but its commit was taken, so it is waited for.
    try setObjects(&w, false);
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
