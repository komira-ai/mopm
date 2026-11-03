//! Tests of the readme forms of `mopm publish --staged` (group_readmes.zig and its parts in group_publish.zig), by behaviour,
//! against the scripted registry of group_publish_test.zig. `drive` does what the command does between the check of the plan
//! and the run: it reads the form from /health and runs the publisher with it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const gp = @import("group_publish.zig");
const gt = @import("group_publish_test.zig");
const plan_mod = @import("group_plan.zig");
const readmes = @import("group_readmes.zig");
const Script = gt.Script;
const Console = gp.Console;
const Result = gp.Result;

pub const api = "http://127.0.0.1:1/api/v1";
pub const health_objects = "{\"status\":\"ok\",\"features\":[\"group_readme_objects\"]}";
pub const health_plain = "{\"status\":\"ok\"}";
pub const text_a = "# a readme\n";

/// Members m0.. with the readmes `texts` (null: none), each with one file of 7 bytes.
pub fn stageSet(a: Allocator, tmp: *std.testing.TmpDir, texts: []const ?[]const u8) !plan_mod.Plan {
    var members = std.ArrayList(u8).init(a);
    try tmp.dir.makePath("noarch");
    const sha = try core.install.sha256Hex(a, "m-bytes");
    for (texts, 0..) |t, i| {
        if (i != 0) try members.append(',');
        const filename = try std.fmt.allocPrint(a, "mojo-m{d}-1.0.0-x.conda", .{i});
        try tmp.dir.writeFile(try std.fmt.allocPrint(a, "noarch/{s}", .{filename}), "m-bytes");
        var key: []const u8 = "";
        if (t) |text| {
            try tmp.dir.writeFile(try std.fmt.allocPrint(a, "R{d}.md", .{i}), text);
            key = try std.fmt.allocPrint(a, "\"readme\":\"R{d}.md\",", .{i});
        }
        try members.writer().print(
            "{{\"name\":\"m{d}\",\"version\":\"1.0.0\",\"action\":\"upload\",\"manifest_sha256\":\"{s}\",{s}\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":7}}]}}",
            .{ i, gt.sha_x, key, filename, sha },
        );
    }
    const text = try std.fmt.allocPrint(a, "{{\"version\":1,\"members\":[{s}]}}", .{members.items});
    try tmp.dir.writeFile(plan_mod.plan_name, text);
    const parsed = try plan_mod.parsePlan(a, text);
    try std.testing.expectEqualStrings("a plan", if (parsed == .ok) "a plan" else parsed.bad);
    return parsed.ok;
}

/// How a create answer shows the readmes.
pub const Ref = enum { none, pending, held };

/// The answer of a create of the members `texts`: the files of the first `held_files` are held, and the readmes are `ref`.
/// URLs end `/put/f<i><variant>` and `/put/r<i><variant>`.
pub fn answerOf(a: Allocator, texts: []const ?[]const u8, held_files: usize, ref: Ref, variant: []const u8) ![]const u8 {
    return answerPartial(a, texts, held_files, 0, ref, variant);
}

/// `answerOf`, with the readmes of the first `held_readmes` members held when `ref` is `.pending`.
pub fn answerPartial(a: Allocator, texts: []const ?[]const u8, held_files: usize, held_readmes: usize, ref: Ref, variant: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.print("{{\"group_id\":\"{s}\",\"status\":\"open\",\"attempt\":1,\"members\":[", .{gt.gid});
    for (texts, 0..) |t, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"name\":\"m{d}\",\"version\":\"1.0.0\",\"action\":\"new\",", .{i});
        if (t) |text| if (ref != .none and text.len > 0) {
            const held_r = ref == .held or i < held_readmes;
            try w.print("\"readme\":{{\"sha256\":\"{s}\",\"size\":{d},\"upload_id\":\"upl_r{d}\",\"uploaded\":{s}", .{ try core.install.sha256Hex(a, text), text.len, i, if (held_r) "true" else "false" });
            if (!held_r) try w.print(",\"put_url\":\"http://127.0.0.1:1/put/r{d}{s}\",\"put_headers\":{{\"content-length\":\"{d}\",\"x-amz-checksum-sha256\":\"rrr=\"}},\"expires_at\":\"2026-11-03T00:00:00Z\"", .{ i, variant, text.len });
            try w.writeAll("},");
        };
        const held = i < held_files;
        try w.print("\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"mojo-m{d}-1.0.0-x.conda\",\"upload_id\":\"u{d}\",\"uploaded\":{s}", .{ i, i, if (held) "true" else "false" });
        if (!held) try w.print(",\"put_url\":\"http://127.0.0.1:1/put/f{d}{s}\",\"put_headers\":{{\"content-length\":\"7\",\"x-amz-checksum-sha256\":\"fff=\"}}", .{ i, variant });
        try w.writeAll("}]}");
    }
    try w.writeAll("]}");
    return out.items;
}

pub const Driven = struct { p: gp.Publisher, result: ?Result };

/// The command between the plan and the run: the form from /health (`null` result when that stops the run), then the run.
pub fn drive(a: Allocator, tmp: *std.testing.TmpDir, script: *Script, console: *Console, state: ?plan_mod.State) !Driven {
    const planned = try gp.checkedPlan(a, tmp.dir, "staged", false);
    try std.testing.expectEqualStrings("a checked plan", if (planned == .ok) "a checked plan" else planned.bad);
    const checked = planned.ok;
    return driveChecked(a, tmp, checked, script, console, state);
}

pub fn driveChecked(a: Allocator, tmp: *std.testing.TmpDir, checked: gp.Checked, script: *Script, console: *Console, state: ?plan_mod.State) !Driven {
    return driveWith(a, tmp, checked, script, console, state, false);
}

/// `driveChecked` for a run with or without `--no-commit`. State that names a group is the group an earlier run made.
pub fn driveWith(a: Allocator, tmp: *std.testing.TmpDir, checked: gp.Checked, script: *Script, console: *Console, state: ?plan_mod.State, no_commit: bool) !Driven {
    const resumed: ?plan_mod.State = if (state) |s| (if (s.group_id.len > 0) s else null) else null;
    const form = (try gp.formOf(a, script.net(), api, checked, resumed, console)) orelse return .{ .p = undefined, .result = null };
    var p = gt.publisherWith(a, tmp, checked.plan, form.choice.commit_body, script, console);
    p.entries = checked.entries;
    p.objects = form.choice.objects;
    p.refusal = form.refusal;
    p.no_commit = no_commit;
    if (state) |s| p.state = s;
    const result = p.run();
    return .{ .p = p, .result = result };
}

/// The checked plan of a set whose inline commit request is too large, with the commit's refusal in `over`.
pub fn driveOver(a: Allocator, tmp: *std.testing.TmpDir, script: *Script, console: *Console, state: ?plan_mod.State) !Driven {
    const checked = (try gp.checkedPlan(a, tmp.dir, "staged", false)).ok;
    try std.testing.expect(checked.over != null);
    return driveChecked(a, tmp, checked, script, console, state);
}

pub fn step(method: std.http.Method, suffix: []const u8, status: u16, body: []const u8) Script.Step {
    return .{ .method = method, .suffix = suffix, .status = status, .body = body };
}

pub const visible = gt.group_status.of("visible");
pub const validating = gt.group_status.of("validating");

pub fn expectHealthFirst(script: *const Script) !void {
    const first = script.seen.items[0];
    try std.testing.expectEqual(std.http.Method.GET, first.method);
    try std.testing.expectEqualStrings(api ++ "/health", first.url);
    try std.testing.expect(first.token == null);
}

/// How many `needle` the text holds.
pub fn countOf(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

test "objects mode: the create declares the readme by digest and size, the readme is PUT with the given headers and no token, and the commit names it" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const texts = [_]?[]const u8{ text_a, null, null };
    _ = try stageSet(a, &tmp, &texts);
    const sha = try core.install.sha256Hex(a, text_a);
    var script = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 0, .pending, "")),
        step(.PUT, "/put/f0", 200, ""),
        step(.PUT, "/put/r0", 200, ""),
        step(.PUT, "/put/f1", 200, ""),
        step(.PUT, "/put/f2", 200, ""),
        step(.POST, "/commit", 202, validating),
        step(.GET, gt.gid, 200, visible),
    });
    var console = Console.init(a, null);
    const d = try drive(a, &tmp, &script, &console, null);
    try std.testing.expectEqual(Result.published, d.result.?);
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqual(@as(usize, 8), script.seen.items.len);
    try expectHealthFirst(&script);

    // The create declares the readme of m0 and only that one.
    const create = script.seen.items[1].body.?;
    try gt.expectContains(create, try std.fmt.allocPrint(a, "\"readme\":{{\"sha256\":\"{s}\",\"size\":11}}", .{sha}));
    try std.testing.expectEqual(@as(usize, 1), countOf(create, "\"readme\""));
    try std.testing.expect(!gt.contains(create, "readme\":\"#"));

    // The readme follows its member's file and precedes the next member's; it is sent as read, with exactly the headers.
    const put = script.seen.items[3];
    try std.testing.expectEqual(std.http.Method.PUT, put.method);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/put/r0", put.url);
    try std.testing.expectEqualStrings(text_a, put.body.?);
    try std.testing.expect(put.token == null and !put.content_type_set);
    try std.testing.expectEqual(@as(usize, 1), put.headers.len);
    try std.testing.expectEqualStrings("x-amz-checksum-sha256", put.headers[0].name);
    try std.testing.expectEqualStrings("rrr=", put.headers[0].value);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/put/f1", script.seen.items[4].url);

    // The commit carries refs and no text.
    const expected = try std.fmt.allocPrint(a, "{{\"members\":[{{\"name\":\"m0\",\"manifest_sha256\":\"{s}\",\"readme\":{{\"sha256\":\"{s}\",\"size\":11}}}},{{\"name\":\"m1\",\"manifest_sha256\":\"{s}\"}},{{\"name\":\"m2\",\"manifest_sha256\":\"{s}\"}}]}}", .{ gt.sha_x, sha, gt.sha_x, gt.sha_x });
    try std.testing.expectEqualStrings(expected, script.seen.items[6].body.?);
    try std.testing.expect(!gt.contains(script.seen.items[6].body.?, "# a readme"));

    // state.json lists files only; the plan has not been touched.
    const state = (try plan_mod.loadState(a, tmp.dir)).ok;
    try std.testing.expectEqual(@as(usize, 3), state.uploaded.len);
    try std.testing.expect(state.committed);
}

test "objects mode: 110 members with 60 KiB readmes, over 6 MiB in all, publish with a commit request under 64 KiB" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const count = 110;
    const big = try a.alloc(u8, 60 * 1024);
    @memset(big, 'a');
    var texts: [count]?[]const u8 = undefined;
    for (&texts) |*t| t.* = big;
    _ = try stageSet(a, &tmp, &texts);
    try std.testing.expect(count * big.len > 6 * 1024 * 1024);
    // Sent inline, the set is refused.
    try std.testing.expect((try gp.checkedPlan(a, tmp.dir, "staged", false)).ok.over != null);

    var steps = std.ArrayList(Script.Step).init(a);
    try steps.append(step(.GET, "/health", 200, health_objects));
    try steps.append(step(.POST, "/groups", 201, try answerOf(a, &texts, count, .pending, "")));
    for (0..count) |i| try steps.append(step(.PUT, try std.fmt.allocPrint(a, "/put/r{d}", .{i}), 200, ""));
    try steps.append(step(.POST, "/commit", 202, validating));
    try steps.append(step(.GET, gt.gid, 200, visible));
    var script = gt.newScript(a, steps.items);
    var console = Console.init(a, null);
    const d = try drive(a, &tmp, &script, &console, null);
    try std.testing.expectEqual(Result.published, d.result.?);
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqual(@as(usize, count), script.count(.PUT));
    var uploaded: usize = 0;
    for (script.seen.items) |x| {
        if (x.method == .PUT) uploaded += x.body.?.len;
    }
    try std.testing.expectEqual(count * big.len, uploaded);
    const commit = script.seen.items[2 + count].body.?;
    try std.testing.expect(commit.len < 64 * 1024);
    try std.testing.expectEqual(@as(usize, count), countOf(commit, "\"readme\":{\"sha256\":\""));
    try std.testing.expect(!gt.contains(commit, "aaaa"));
}

test "without the capability the readme goes inline: no /health feature, a 404, an unreadable answer or no list of names" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const healths = [_]struct { status: u16, body: []const u8 }{
        .{ .status = 200, .body = health_plain },
        .{ .status = 200, .body = "{\"features\":[\"another_feature\"]}" },
        .{ .status = 404, .body = gt.err_404 },
        .{ .status = 200, .body = "<html>not json</html>" },
        .{ .status = 200, .body = "{\"features\":\"group_readme_objects\"}" },
    };
    const texts = [_]?[]const u8{ text_a, null, null };
    for (healths) |h| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        _ = try stageSet(a, &tmp, &texts);
        var script = gt.newScript(a, &.{
            step(.GET, "/health", h.status, h.body),
            step(.POST, "/groups", 201, try answerOf(a, &texts, 0, .none, "")),
            step(.PUT, "/put/f0", 200, ""),
            step(.PUT, "/put/f1", 200, ""),
            step(.PUT, "/put/f2", 200, ""),
            step(.POST, "/commit", 202, validating),
            step(.GET, gt.gid, 200, visible),
        });
        var console = Console.init(a, null);
        const d = try drive(a, &tmp, &script, &console, null);
        try std.testing.expectEqual(Result.published, d.result.?);
        try std.testing.expect(script.mismatch == null);
        try expectHealthFirst(&script);
        try std.testing.expect(!gt.contains(script.seen.items[1].body.?, "\"readme\""));
        const expected = try std.fmt.allocPrint(a, "{{\"members\":[{{\"name\":\"m0\",\"manifest_sha256\":\"{s}\",\"readme\":\"# a readme\\n\"}},{{\"name\":\"m1\",\"manifest_sha256\":\"{s}\"}},{{\"name\":\"m2\",\"manifest_sha256\":\"{s}\"}}]}}", .{ gt.sha_x, gt.sha_x, gt.sha_x });
        try std.testing.expectEqualStrings(expected, script.seen.items[5].body.?);
    }
}

test "without the capability the commit size limit still applies: an oversized set is refused with only /health sent" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const at = try gt.heavyAtLimit(a, gt.limit_members);
    for ([_]struct { status: u16, body: []const u8 }{ .{ .status = 200, .body = health_plain }, .{ .status = 404, .body = gt.err_404 } }) |h| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        _ = try gt.stageReadmes(a, &tmp, gt.limit_members, .{ .units = at.units, .pad = at.pad, .extra = at.extra + 1 }, "");
        var script = gt.newScript(a, &.{step(.GET, "/health", h.status, h.body)});
        var console = Console.init(a, null);
        const d = try driveOver(a, &tmp, &script, &console, null);
        try std.testing.expect(d.result == null);
        try std.testing.expectEqual(@as(usize, 1), script.seen.items.len);
        try expectHealthFirst(&script);
        try gt.expectContains(console.err.items, "which can take 6225921 bytes in the event the registry's function is invoked with; mopm keeps that to at most 6225920");
        try gt.expectContains(console.err.items, "Shorten them or publish fewer packages in one group; this run created and uploaded nothing\n");
        try gt.expectContains(console.err.items, "the registry does not take readmes as objects (its /health lists no group_readme_objects)");
    }
}

test "a /health that cannot be read stops the run with nothing else sent" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try stageSet(a, &tmp, &.{ text_a, null });
    var script = gt.newScript(a, &.{.{ .method = .GET, .suffix = "/health", .status = 0, .err = error.ConnectionRefused }});
    var console = Console.init(a, null);
    const d = try drive(a, &tmp, &script, &console, null);
    try std.testing.expect(d.result == null);
    try gt.expectContains(console.err.items, "mopm: GET /health: ConnectionRefused; nothing more was sent\n");
    for (script.seen.items) |x| {
        try std.testing.expectEqual(std.http.Method.GET, x.method);
        try std.testing.expectEqualStrings(api ++ "/health", x.url);
    }
}

test "a set with no readme with text makes no /health request" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const texts = [_]?[]const u8{ null, "", null };
    _ = try stageSet(a, &tmp, &texts);
    var script = gt.newScript(a, &.{
        step(.POST, "/groups", 201, try answerOf(a, &texts, 0, .pending, "")),
        step(.PUT, "/put/f0", 200, ""),
        step(.PUT, "/put/f1", 200, ""),
        step(.PUT, "/put/f2", 200, ""),
        step(.POST, "/commit", 202, validating),
        step(.GET, gt.gid, 200, visible),
    });
    var console = Console.init(a, null);
    const d = try drive(a, &tmp, &script, &console, null);
    try std.testing.expectEqual(Result.published, d.result.?);
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqual(std.http.Method.POST, script.seen.items[0].method);
    // The empty readme stays inline.
    const expected = try std.fmt.allocPrint(a, "{{\"members\":[{{\"name\":\"m0\",\"manifest_sha256\":\"{s}\"}},{{\"name\":\"m1\",\"manifest_sha256\":\"{s}\",\"readme\":\"\"}},{{\"name\":\"m2\",\"manifest_sha256\":\"{s}\"}}]}}", .{ gt.sha_x, gt.sha_x, gt.sha_x });
    try std.testing.expectEqualStrings(expected, script.seen.items[4].body.?);
}

test "objects mode: an empty readme stays inline as \"\" and is not declared or uploaded" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const texts = [_]?[]const u8{ text_a, "", null };
    _ = try stageSet(a, &tmp, &texts);
    var script = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 0, .pending, "")),
        step(.PUT, "/put/f0", 200, ""),
        step(.PUT, "/put/r0", 200, ""),
        step(.PUT, "/put/f1", 200, ""),
        step(.PUT, "/put/f2", 200, ""),
        step(.POST, "/commit", 202, validating),
        step(.GET, gt.gid, 200, visible),
    });
    var console = Console.init(a, null);
    const d = try drive(a, &tmp, &script, &console, null);
    try std.testing.expectEqual(Result.published, d.result.?);
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqual(@as(usize, 1), countOf(script.seen.items[1].body.?, "\"readme\""));
    const commit = script.seen.items[6].body.?;
    try gt.expectContains(commit, "{\"name\":\"m1\",\"manifest_sha256\":\"" ++ gt.sha_x ++ "\",\"readme\":\"\"}");
    try std.testing.expectEqual(@as(usize, 1), countOf(commit, "\"sha256\":\""));
}

test "a create answer that lacks the readme upload re-plans to the inline form when it fits" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const texts = [_]?[]const u8{ text_a, null, null };
    _ = try stageSet(a, &tmp, &texts);
    var script = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 0, .none, "")),
        step(.PUT, "/put/f0", 200, ""),
        step(.PUT, "/put/f1", 200, ""),
        step(.PUT, "/put/f2", 200, ""),
        step(.POST, "/commit", 202, validating),
        step(.GET, gt.gid, 200, visible),
    });
    var console = Console.init(a, null);
    const d = try drive(a, &tmp, &script, &console, null);
    try std.testing.expectEqual(Result.published, d.result.?);
    try std.testing.expect(script.mismatch == null);
    // The create asked for the object, the answer had none; the readme goes in the commit as text.
    try gt.expectContains(script.seen.items[1].body.?, "\"readme\":{\"sha256\":\"");
    try gt.expectContains(script.seen.items[5].body.?, "\"readme\":\"# a readme\\n\"}");
    try gt.expectContains(console.out.items, "the registry no longer takes readmes as objects (its answer has no readme upload for m0); sending them inline\n");
    try std.testing.expect(!d.p.objects);
}

test "objects mode: a create answered \"reserving\" first is repeated, and the final answer's readme upload is used: the readme is PUT and the commit carries the ref, not the text" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const texts = [_]?[]const u8{ text_a, null, null };
    _ = try stageSet(a, &tmp, &texts);
    const sha = try core.install.sha256Hex(a, text_a);
    const partial = "{\"group_id\":\"" ++ gt.gid ++ "\",\"status\":\"open\",\"attempt\":1,\"reserving\":{\"done\":1,\"total\":3},\"members\":[]}";
    var script = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        step(.POST, "/groups", 201, partial),
        step(.POST, "/groups", 200, try answerOf(a, &texts, 0, .pending, "")),
        step(.PUT, "/put/f0", 200, ""),
        step(.PUT, "/put/r0", 200, ""),
        step(.PUT, "/put/f1", 200, ""),
        step(.PUT, "/put/f2", 200, ""),
        step(.POST, "/commit", 202, validating),
        step(.GET, gt.gid, 200, visible),
    });
    var console = Console.init(a, null);
    const d = try drive(a, &tmp, &script, &console, null);
    try std.testing.expectEqual(Result.published, d.result.?);
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqual(@as(usize, 9), script.seen.items.len);
    try std.testing.expect(d.p.objects);
    try std.testing.expect(!gt.contains(console.out.items, "sending them inline"));
    // Both creates declare the readme by digest; the readme is PUT as read.
    for ([_]usize{ 1, 2 }) |i| try gt.expectContains(script.seen.items[i].body.?, try std.fmt.allocPrint(a, "\"readme\":{{\"sha256\":\"{s}\",\"size\":11}}", .{sha}));
    try std.testing.expectEqualStrings("http://127.0.0.1:1/put/r0", script.seen.items[4].url);
    try std.testing.expectEqualStrings(text_a, script.seen.items[4].body.?);
    const commit = script.seen.items[7].body.?;
    try gt.expectContains(commit, try std.fmt.allocPrint(a, "\"readme\":{{\"sha256\":\"{s}\",\"size\":11}}", .{sha}));
    try std.testing.expect(!gt.contains(commit, "# a readme"));
}

test "a create answer that lacks the readme upload of a set too large inline is refused before any PUT, with state.json unchanged" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const at = try gt.heavyAtLimit(a, gt.limit_members);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const over = try gt.stageReadmes(a, &tmp, gt.limit_members, .{ .units = at.units, .pad = at.pad, .extra = at.extra + 1 }, "");
    const state = plan_mod.State{ .registry = api, .plan_sha256 = over.sha256, .group_id = gt.gid, .attempt = 1, .staged = true, .uploaded = &.{"m0/noarch/mojo-m0-1.0.0-x.conda"} };
    try plan_mod.saveState(a, tmp.dir, state);
    const before = try tmp.dir.readFileAlloc(a, plan_mod.state_name, 1 << 20);
    var script = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        step(.GET, gt.gid, 200, gt.group_status.of("open")),
        step(.POST, "/groups", 201, try gt.allHeld(a, gt.limit_members)),
    });
    var console = Console.init(a, null);
    const d = try driveOver(a, &tmp, &script, &console, state);
    try std.testing.expectEqual(Result.failed, d.result.?);
    try std.testing.expectEqual(@as(usize, 3), script.seen.items.len);
    try std.testing.expectEqual(@as(usize, 0), script.count(.PUT));
    try gt.expectContains(console.err.items, "the registry no longer takes readmes as objects (its answer has no readme upload for m0), and sent inline they are too large: the commit request of the 90 members to upload is ");
    try gt.expectContains(console.err.items, "; nothing was uploaded\n");
    try std.testing.expectEqualStrings(before, try tmp.dir.readFileAlloc(a, plan_mod.state_name, 1 << 20));
}

test "a staged group resumed after the capability disappeared is committed inline when that fits" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const texts = [_]?[]const u8{ text_a, null, null };
    const plan = try stageSet(a, &tmp, &texts);
    const state = plan_mod.State{ .registry = api, .plan_sha256 = plan.sha256, .group_id = gt.gid, .attempt = 1, .staged = true, .uploaded = &.{ "m0/noarch/mojo-m0-1.0.0-x.conda", "m1/noarch/mojo-m1-1.0.0-x.conda", "m2/noarch/mojo-m2-1.0.0-x.conda" } };
    var script = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_plain),
        step(.GET, gt.gid, 200, gt.group_status.of("open")),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 3, .none, "")),
        step(.POST, "/commit", 202, validating),
        step(.GET, gt.gid, 200, visible),
    });
    var console = Console.init(a, null);
    const d = try drive(a, &tmp, &script, &console, state);
    try std.testing.expectEqual(Result.published, d.result.?);
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqual(@as(usize, 0), script.count(.PUT));
    try gt.expectContains(script.seen.items[3].body.?, "\"readme\":\"# a readme\\n\"");
    try std.testing.expect((try plan_mod.loadState(a, tmp.dir)).ok.committed);
}

test "an invalid_request about the readme of an objects-mode commit is shown with a note, other refusals without, and the group is left open" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const texts = [_]?[]const u8{ text_a, null };
    const refusal = "{\"error\":{\"code\":\"invalid_request\",\"message\":\"'readme' of 'm0' must be a string\",\"hint\":\"\"}}";
    const other = "{\"error\":{\"code\":\"group_commit_refused\",\"message\":\"another request was committed\",\"hint\":\"\"}}";
    const not_readme = "{\"error\":{\"code\":\"invalid_request\",\"message\":\"'description' of 'm0' is empty or too long\",\"hint\":\"\"}}";
    const Case = struct { health: []const u8, ref: Ref, status: u16, body: []const u8, note: bool };
    for ([_]Case{
        .{ .health = health_objects, .ref = .held, .status = 400, .body = refusal, .note = true },
        .{ .health = health_objects, .ref = .held, .status = 409, .body = other, .note = false },
        .{ .health = health_objects, .ref = .held, .status = 400, .body = not_readme, .note = false },
        .{ .health = health_plain, .ref = .none, .status = 400, .body = refusal, .note = false },
    }) |c| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        _ = try stageSet(a, &tmp, &texts);
        var script = gt.newScript(a, &.{
            step(.GET, "/health", 200, c.health),
            step(.POST, "/groups", 201, try answerOf(a, &texts, 2, c.ref, "")),
            step(.POST, "/commit", c.status, c.body),
        });
        var console = Console.init(a, null);
        const d = try drive(a, &tmp, &script, &console, null);
        try std.testing.expectEqual(Result.failed, d.result.?);
        try std.testing.expectEqual(@as(usize, 3), script.seen.items.len);
        try std.testing.expect(!(try plan_mod.loadState(a, tmp.dir)).ok.committed);
        const note = "the registry did not take the readmes as objects (it may have been rolled back since /health was read); group " ++ gt.gid ++ " is still open: run the same command again, which sends them inline if /health no longer lists group_readme_objects\n";
        try std.testing.expectEqual(c.note, gt.contains(console.err.items, note));
        if (c.body.ptr == refusal.ptr) try gt.expectContains(console.err.items, "'readme' of 'm0' must be a string");
        if (c.body.ptr == not_readme.ptr) try gt.expectContains(console.err.items, "'description' of 'm0' is empty or too long");
    }
}

test "a readme already in storage is not sent, and one the storage refuses with 403 is sent again to the fresh URL, once" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const texts = [_]?[]const u8{ text_a, null };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try stageSet(a, &tmp, &texts);

    // Held already.
    var held = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 0, .held, "")),
        step(.PUT, "/put/f0", 200, ""),
        step(.PUT, "/put/f1", 200, ""),
        step(.POST, "/commit", 202, validating),
        step(.GET, gt.gid, 200, visible),
    });
    var c1 = Console.init(a, null);
    const d1 = try drive(a, &tmp, &held, &c1, null);
    try std.testing.expectEqual(Result.published, d1.result.?);
    try std.testing.expect(held.mismatch == null);
    try gt.expectContains(c1.out.items, "1 readme(s) were already in the registry's storage\n");

    // 403, then the fresh URL works; the files after it use the fresh answer.
    var fresh = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 0, .pending, "")),
        step(.PUT, "/put/f0", 200, ""),
        step(.PUT, "/put/r0", 403, ""),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 1, .pending, "x")),
        step(.PUT, "/put/r0x", 200, ""),
        step(.PUT, "/put/f1x", 200, ""),
        step(.POST, "/commit", 202, validating),
        step(.GET, gt.gid, 200, visible),
    });
    var c2 = Console.init(a, null);
    const d2 = try drive(a, &tmp, &fresh, &c2, null);
    try std.testing.expectEqual(Result.published, d2.result.?);
    try std.testing.expect(fresh.mismatch == null);
    try std.testing.expectEqualStrings(text_a, fresh.seen.items[5].body.?);
    try std.testing.expect(fresh.seen.items[5].token == null);

    // 403, and the fresh answer says the readme is held: no second PUT.
    var then_held = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 0, .pending, "")),
        step(.PUT, "/put/f0", 200, ""),
        step(.PUT, "/put/r0", 403, ""),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 1, .held, "x")),
        step(.PUT, "/put/f1x", 200, ""),
        step(.POST, "/commit", 202, validating),
        step(.GET, gt.gid, 200, visible),
    });
    var c3 = Console.init(a, null);
    const d3 = try drive(a, &tmp, &then_held, &c3, null);
    try std.testing.expectEqual(Result.published, d3.result.?);
    try std.testing.expect(then_held.mismatch == null);
    try std.testing.expectEqual(@as(usize, 3), then_held.count(.PUT));

    // 403 twice: the run stops and says which upload failed.
    var twice = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 0, .pending, "")),
        step(.PUT, "/put/f0", 200, ""),
        step(.PUT, "/put/r0", 403, ""),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 1, .pending, "x")),
        step(.PUT, "/put/r0x", 403, ""),
    });
    var c4 = Console.init(a, null);
    const d4 = try drive(a, &tmp, &twice, &c4, null);
    try std.testing.expectEqual(Result.failed, d4.result.?);
    try gt.expectContains(c4.err.items, "uploading README.md failed: the storage answered HTTP 403; run the same command again to resume group " ++ gt.gid);
}

test "a readme the registry gave no upload for stops the run, and a long run asks for fresh URLs before the readme" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const texts = [_]?[]const u8{ text_a, null };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try stageSet(a, &tmp, &texts);

    // A refreshed answer without the readme.
    var lacking = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 0, .pending, "")),
        step(.PUT, "/put/f0", 200, ""),
        step(.PUT, "/put/r0", 403, ""),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 1, .none, "x")),
    });
    var c1 = Console.init(a, null);
    const d1 = try drive(a, &tmp, &lacking, &c1, null);
    try std.testing.expectEqual(Result.failed, d1.result.?);
    try gt.expectContains(c1.err.items, "the registry's answer has no readme upload for m0\n");

    // An answer whose readme has no URL.
    const no_url = try std.mem.replaceOwned(u8, a, try answerOf(a, &texts, 0, .pending, ""), "\"put_url\":\"http://127.0.0.1:1/put/r0\",", "");
    var bare = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        step(.POST, "/groups", 201, no_url),
        step(.PUT, "/put/f0", 200, ""),
    });
    var c2 = Console.init(a, null);
    const d2 = try drive(a, &tmp, &bare, &c2, null);
    try std.testing.expectEqual(Result.failed, d2.result.?);
    try gt.expectContains(c2.err.items, "the registry's answer for the readme of m0 is not an upload descriptor: it is not uploaded and has no put_url; nothing was uploaded\n");
    try std.testing.expectEqual(@as(usize, 0), bare.count(.PUT));

    // The file took long enough for the URLs to lapse: the readme waits for fresh ones.
    var slow = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 0, .pending, "")),
        .{ .method = .PUT, .suffix = "/put/f0", .status = 200, .advance_clock = 250 },
        step(.POST, "/groups", 201, try answerOf(a, &texts, 1, .pending, "x")),
        step(.PUT, "/put/r0x", 200, ""),
        step(.PUT, "/put/f1x", 200, ""),
        step(.POST, "/commit", 202, validating),
        step(.GET, gt.gid, 200, visible),
    });
    var c3 = Console.init(a, null);
    const d3 = try drive(a, &tmp, &slow, &c3, null);
    try std.testing.expectEqual(Result.published, d3.result.?);
    try std.testing.expect(slow.mismatch == null);

    // A refreshed answer without the member.
    const missing = try std.mem.replaceOwned(u8, a, try answerOf(a, &texts, 1, .pending, "x"), "\"name\":\"m0\"", "\"name\":\"zz\"");
    var none = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 0, .pending, "")),
        step(.PUT, "/put/f0", 200, ""),
        step(.PUT, "/put/r0", 403, ""),
        step(.POST, "/groups", 201, missing),
    });
    var c4 = Console.init(a, null);
    const d4 = try drive(a, &tmp, &none, &c4, null);
    try std.testing.expectEqual(Result.failed, d4.result.?);
    try gt.expectContains(c4.err.items, "the registry's answer has no reservation for m0 1.0.0\n");
}

test "--dry-run reads /health without a token and says which form it would send; an oversized inline set is refused" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const texts = [_]?[]const u8{ text_a, null, null };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stageSet(a, &tmp, &texts);
    const checked = (try gp.checkedPlan(a, tmp.dir, "staged", false)).ok;
    const uploads = try plan.uploads(a);
    const inline_len = checked.commit_body.?.len;
    const objects_len = (try plan_mod.objectsBody(a, checked.entries)).len;

    var objects = gt.newScript(a, &.{step(.GET, "/health", 200, health_objects)});
    var c1 = Console.init(a, null);
    try std.testing.expectEqual(@as(u8, 0), try readmes.dryRun(a, &c1, objects.net(), api, false, plan, uploads, checked.entries, checked.inlineCommit()));
    try expectHealthFirst(&objects);
    try std.testing.expectEqual(@as(usize, 1), objects.seen.items.len);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a,
        \\would create one group of 3 members (3 files), in this order:
        \\  m0 1.0.0 (1 files)
        \\  m1 1.0.0 (1 files)
        \\  m2 1.0.0 (1 files)
        \\would send the readmes as uploaded objects (the registry lists group_readme_objects); the commit request is {d} bytes
        \\would upload each file the registry does not hold, commit the group, and wait for it to be visible
        \\dry run: nothing was created or uploaded; the registry was only read (its config.json and GET /health)
        \\
    , .{objects_len}), c1.out.items);

    var plain = gt.newScript(a, &.{step(.GET, "/health", 200, health_plain)});
    var c2 = Console.init(a, null);
    try std.testing.expectEqual(@as(u8, 0), try readmes.dryRun(a, &c2, plain.net(), api, true, plan, uploads, checked.entries, checked.inlineCommit()));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a,
        \\would create one group of 3 members (3 files), in this order:
        \\  m0 1.0.0 (1 files)
        \\  m1 1.0.0 (1 files)
        \\  m2 1.0.0 (1 files)
        \\would send the readmes inline; the commit request is {d} bytes
        \\would upload each file the registry does not hold, and stop with the group open (--no-commit)
        \\dry run: nothing was created or uploaded; the registry was only read (its config.json and GET /health)
        \\
    , .{inline_len}), c2.out.items);

    var broken = gt.newScript(a, &.{.{ .method = .GET, .suffix = "/health", .status = 0, .err = error.ConnectionRefused }});
    var c3 = Console.init(a, null);
    try std.testing.expectEqual(@as(u8, 1), try readmes.dryRun(a, &c3, broken.net(), api, false, plan, uploads, checked.entries, checked.inlineCommit()));
    try gt.expectContains(c3.err.items, "GET /health: ConnectionRefused");

    // No readme with text: no request at all.
    var bare_tmp = std.testing.tmpDir(.{});
    defer bare_tmp.cleanup();
    const bare_plan = try stageSet(a, &bare_tmp, &.{ null, null });
    const bare = (try gp.checkedPlan(a, bare_tmp.dir, "staged", false)).ok;
    var quiet = gt.newScript(a, &.{step(.GET, "/health", 500, "")});
    var c4 = Console.init(a, null);
    try std.testing.expectEqual(@as(u8, 0), try readmes.dryRun(a, &c4, quiet.net(), api, false, bare_plan, try bare_plan.uploads(a), bare.entries, bare.inlineCommit()));
    try std.testing.expectEqual(@as(usize, 0), quiet.seen.items.len);
    try std.testing.expectEqualStrings(
        \\would create one group of 2 members (2 files), in this order:
        \\  m0 1.0.0 (1 files)
        \\  m1 1.0.0 (1 files)
        \\would upload each file the registry does not hold, commit the group, and wait for it to be visible
        \\dry run: nothing was sent
        \\
    , c4.out.items);

    // Too large inline: refused when /health lists nothing, accepted in the form of objects when it does.
    const at = try gt.heavyAtLimit(a, gt.limit_members);
    var over_tmp = std.testing.tmpDir(.{});
    defer over_tmp.cleanup();
    const over_plan = try gt.stageReadmes(a, &over_tmp, gt.limit_members, .{ .units = at.units, .pad = at.pad, .extra = at.extra + 1 }, "");
    const over = (try gp.checkedPlan(a, over_tmp.dir, "staged", false)).ok;
    const over_uploads = try over_plan.uploads(a);
    var refused = gt.newScript(a, &.{step(.GET, "/health", 200, health_plain)});
    var c5 = Console.init(a, null);
    try std.testing.expectEqual(@as(u8, 1), try readmes.dryRun(a, &c5, refused.net(), api, false, over_plan, over_uploads, over.entries, over.inlineCommit()));
    try gt.expectContains(c5.err.items, "Shorten them or publish fewer packages in one group; this run created and uploaded nothing\n");
    try gt.expectContains(c5.err.items, readmes.inline_note);
    var accepted = gt.newScript(a, &.{step(.GET, "/health", 200, health_objects)});
    var c6 = Console.init(a, null);
    try std.testing.expectEqual(@as(u8, 0), try readmes.dryRun(a, &c6, accepted.net(), api, false, over_plan, over_uploads, over.entries, over.inlineCommit()));
    try gt.expectContains(c6.out.items, "would send the readmes as uploaded objects");
}

test "the commit body in objects form: refs for readmes with text, \"\" kept, no key without a readme; and the digest is read with the readme" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const sha = try core.install.sha256Hex(a, "é\n");
    const entries = [_]plan_mod.CommitEntry{
        .{ .name = "q\"", .manifest_sha256 = gt.sha_x, .readme = "é\n", .readme_sha256 = sha },
        .{ .name = "e", .manifest_sha256 = gt.sha_x, .readme = "" },
        .{ .name = "n", .manifest_sha256 = gt.sha_x, .readme = null },
    };
    const expected = try std.fmt.allocPrint(a, "{{\"members\":[{{\"name\":\"q\\\"\",\"manifest_sha256\":\"{s}\",\"readme\":{{\"sha256\":\"{s}\",\"size\":3}}}},{{\"name\":\"e\",\"manifest_sha256\":\"{s}\",\"readme\":\"\"}},{{\"name\":\"n\",\"manifest_sha256\":\"{s}\"}}]}}", .{ gt.sha_x, sha, gt.sha_x, gt.sha_x });
    try std.testing.expectEqualStrings(expected, try plan_mod.objectsBody(a, &entries));
    // The inline form of the same entries is unchanged.
    try gt.expectContains(try plan_mod.commitBody(a, &entries), "\"readme\":\"é\\n\"}");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stageSet(a, &tmp, &.{ "é\n", "", null });
    const read = (try plan_mod.readEntries(a, tmp.dir, plan)).ok;
    try std.testing.expectEqualStrings(sha, read[0].readme_sha256);
    try std.testing.expectEqualStrings("", read[1].readme_sha256);
    try std.testing.expectEqualStrings("", read[2].readme_sha256);
    try std.testing.expect(read[2].readme == null);
}

test "which members have a readme to send, and how a create answer's readme stands against the declaration" {
    const sha = "d" ** 64;
    const entries = [_]plan_mod.CommitEntry{
        .{ .name = "a", .manifest_sha256 = gt.sha_x, .readme = "text", .readme_sha256 = sha },
        .{ .name = "b", .manifest_sha256 = gt.sha_x, .readme = "" },
        .{ .name = "c", .manifest_sha256 = gt.sha_x, .readme = null },
    };
    try std.testing.expect(readmes.hasReadme(&entries));
    try std.testing.expect(!readmes.hasReadme(entries[1..]));
    try std.testing.expect(readmes.entryWithReadme(&entries, "a") != null);
    for ([_][]const u8{ "b", "c", "zz" }) |n| try std.testing.expect(readmes.entryWithReadme(&entries, n) == null);

    const e = entries[0];
    const url = "http://127.0.0.1:1/put/r";
    try std.testing.expectEqual(readmes.Verdict.absent, readmes.judge(e, null));
    try std.testing.expectEqual(readmes.Verdict.differs, readmes.judge(e, .{ .sha256 = "e" ** 64, .size = 4, .put_url = url }));
    try std.testing.expectEqual(readmes.Verdict.differs, readmes.judge(e, .{ .sha256 = sha, .size = 5, .put_url = url }));
    try std.testing.expectEqual(readmes.Verdict.differs, readmes.judge(e, .{ .sha256 = sha, .put_url = url }));
    try std.testing.expectEqual(readmes.Verdict.confirmed, readmes.judge(e, .{ .sha256 = sha, .size = 4, .put_url = url }));
    try std.testing.expectEqual(readmes.Verdict.confirmed, readmes.judge(e, .{ .sha256 = sha, .size = 4, .uploaded = true }));
    try std.testing.expectEqual(readmes.Verdict.confirmed, readmes.judge(e, .{ .sha256 = sha, .size = 4, .put_url = url, .put_headers = .{ .object = std.json.ObjectMap.init(std.testing.allocator) } }));
    try std.testing.expectEqualStrings("it is not uploaded and has no put_url", readmes.judge(e, .{ .sha256 = sha, .size = 4 }).malformed);
    try std.testing.expectEqualStrings("its put_headers is not an object", readmes.judge(e, .{ .sha256 = sha, .size = 4, .put_url = url, .put_headers = .{ .string = "x" } }).malformed);
}
