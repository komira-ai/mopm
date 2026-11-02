//! End-to-end tests of readmes sent as uploaded objects by `mopm publish --staged`, against the fake registry (spec/staged-set.md).
//!
//! Run by Buck2 (//:group_readmes): MOPM and MOPM_FAKE_REGISTRY are the built programs. Each check prints `ok` or `FAIL`. A set is a
//! staged directory (plan.json, the package files, one `<name>.md` readme per member). The fake takes readmes as objects unless
//! the control `/_fake/readme_objects` turned it off, which makes it a registry from before the capability.
//!
//! What can go red, and why:
//! - a set of 100 members whose readmes (64 KiB each) total over what a commit request may carry inline must publish, every
//!   member serving its whole readme; the same set must be refused inline by a registry without the capability, so it could not have
//!   gone inline;
//! - against a registry without the capability a small set must publish inline with its readmes served, and a large one must be
//!   refused with the commit-size message after the two requests the registry answers (its API root and GET /health);
//! - a group staged with its readmes uploaded as objects and resumed after the capability went away must publish inline when the
//!   set fits, and be refused (group open, nothing published, state.json kept) when it does not; resumed again with the capability
//!   back it must publish;
//! - the same set published as objects and inline must give the same readme fields, the same index records (but for each registry's own address in the file urls and published_at) and the same channel files.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

const Out = struct { code: u8, stdout: []u8, stderr: []u8 };

const big_count = 100;
const big_readme_len = 65536;

fn sha256Hex(a: Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

/// The readme of `name`: `len` bytes of text, a title line first and a different line of body for each name.
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

fn nameOf(a: Allocator, prefix: []const u8, i: usize) ![]u8 {
    return std.fmt.allocPrint(a, "{s}{d}", .{ prefix, i });
}

fn filenameOf(a: Allocator, name: []const u8, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "mojo-{s}-{s}-mojo1.0.0_0.conda", .{ name, version });
}

/// Writes the staged directory of `count` members `<prefix>0..` at `version`, each with one file and a readme of `readme_len` bytes.
fn stageSet(a: Allocator, dir: []const u8, prefix: []const u8, count: usize, version: []const u8, readme_len: usize) !void {
    var plan = std.ArrayList(u8).init(a);
    try plan.appendSlice("{\"version\":1,\"members\":[");
    for (0..count) |i| {
        const name = try nameOf(a, prefix, i);
        const bytes = try std.fmt.allocPrint(a, "the bytes of {s} {s}", .{ name, version });
        const filename = try filenameOf(a, name, version);
        try h.writeFile(try h.join(a, &.{ dir, "noarch", filename }), bytes);
        try h.writeFile(try h.join(a, &.{ dir, try std.fmt.allocPrint(a, "{s}.md", .{name}) }), try readmeOf(a, name, readme_len));
        if (i != 0) try plan.append(',');
        try plan.writer().print(
            "{{\"name\":\"{s}\",\"version\":\"{s}\",\"action\":\"upload\",\"manifest_sha256\":\"{s}\",\"readme\":\"{s}.md\",\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}]}}",
            .{ name, version, try sha256Hex(a, name), name, filename, try sha256Hex(a, bytes), bytes.len },
        );
    }
    try plan.appendSlice("]}");
    try h.writeFile(try h.join(a, &.{ dir, "plan.json" }), plan.items);
}

/// A fake registry with an account that owns the names it is given, and a token that may publish them.
const Reg = struct {
    fake: h.Fake,
    dir: []const u8,
    token: []const u8,

    fn open(a: Allocator, rep: *h.Report, exe: []const u8, dir: []const u8, handle: []const u8, groups: []const Names) !Reg {
        var fake = try h.Fake.start(a, exe, dir);
        errdefer fake.close();
        const session = h.jsonString(try fake.control(a, "/session", try std.fmt.allocPrint(a, "{{\"handle\":\"{s}\"}}", .{handle})), "token") orelse "";
        var quoted = std.ArrayList(u8).init(a);
        var claimed: usize = 0;
        var failed = false;
        for (groups) |g| {
            for (0..g.count) |i| {
                const name = try nameOf(a, g.prefix, i);
                const r = try h.request(a, "POST", fake.base, try std.fmt.allocPrint(a, "/api/v1/packages/{s}/claim", .{name}), "{}", session);
                if (r.status != 201) failed = true;
                try quoted.writer().print("{s}\"{s}\"", .{ if (claimed == 0) "" else ",", name });
                claimed += 1;
            }
        }
        rep.check(try std.fmt.allocPrint(a, "{s} owns {d} names", .{ handle, claimed }), !failed, "a claim was refused");
        const made = try h.request(a, "POST", fake.base, "/api/v1/me/tokens", try std.fmt.allocPrint(a, "{{\"name\":\"rdm\",\"scopes\":[\"publish\"],\"packages\":[{s}],\"expires_in_days\":7}}", .{quoted.items}), session);
        const token = if (made.status == 201) (h.jsonString(try h.parseJson(a, made.body), "token") orelse "") else "";
        rep.check(try std.fmt.allocPrint(a, "a token that may publish the names of {s} is made", .{handle}), token.len > 0, made.body);
        return .{ .fake = fake, .dir = dir, .token = token };
    }
};

const Names = struct { prefix: []const u8, count: usize };

const World = struct {
    a: Allocator,
    rep: *h.Report,
    exe: []const u8,
    env: std.process.EnvMap,
    reg: Reg,
    work: []const u8,
    conf: []const u8,

    fn run(w: World, args: []const []const u8) !Out {
        const argv = try w.a.alloc([]const u8, args.len + 1);
        argv[0] = w.exe;
        @memcpy(argv[1..], args);
        var env = try h.cloneEnv(w.a, &w.env);
        try env.put("MOPM_TOKEN", w.reg.token);
        const r = try std.process.Child.run(.{ .allocator = w.a, .argv = argv, .env_map = &env, .max_output_bytes = 1 << 24 });
        return .{ .code = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        }, .stdout = r.stdout, .stderr = r.stderr };
    }

    fn publish(w: World, staged: []const u8, extra: []const []const u8) !Out {
        const base = [_][]const u8{ "publish", "--staged", staged, "--registry", w.reg.fake.base, "--config-dir", w.conf, "--wait", "120" };
        return w.run(try std.mem.concat(w.a, []const u8, &.{ &base, extra }));
    }

    fn text(w: World, r: Out) ![]const u8 {
        return std.fmt.allocPrint(w.a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr });
    }

    fn dir(w: World, name: []const u8) ![]const u8 {
        return h.join(w.a, &.{ w.work, name });
    }

    fn objects(w: World, on: bool) !void {
        _ = try w.reg.fake.control(w.a, "/readme_objects", if (on) "{\"enabled\":true}" else "{\"enabled\":false}");
    }

    /// The requests the registry has answered, its controls not counted.
    fn served(w: World) !i64 {
        return (try w.reg.fake.control(w.a, "/requests", "{}")).object.get("requests").?.integer;
    }

    fn get(w: World, path: []const u8) !h.Response {
        return h.request(w.a, "GET", w.reg.fake.base, path, null, null);
    }

    fn uploads(w: World) !usize {
        return (try h.findFilesAll(w.a, try h.join(w.a, &.{ w.reg.dir, "uploads" }))).len;
    }

    fn stateJson(w: World, staged: []const u8) !std.json.Value {
        return h.parseJson(w.a, try h.readFile(w.a, try h.join(w.a, &.{ staged, "state.json" })));
    }

    fn groupId(w: World, staged: []const u8) ![]const u8 {
        return h.jsonString(try w.stateJson(staged), "group_id") orelse "";
    }

    fn groupStatus(w: World, id: []const u8) ![]const u8 {
        const r = try h.request(w.a, "GET", w.reg.fake.base, try std.fmt.allocPrint(w.a, "/api/v1/groups/{s}", .{id}), null, w.reg.token);
        return h.jsonString(try h.parseJson(w.a, r.body), "status") orelse "(none)";
    }

    /// The `readme` of a version as getVersion serves it, or null.
    fn versionReadme(w: World, name: []const u8, version: []const u8) !?[]const u8 {
        const r = try w.get(try std.fmt.allocPrint(w.a, "/api/v1/packages/{s}/{s}", .{ name, version }));
        if (r.status != 200) return null;
        return h.jsonString(try h.parseJson(w.a, r.body), "readme");
    }

    /// The count of members `<prefix>0..` of `count` whose getVersion readme is the one the set was staged with.
    fn servedWhole(w: World, prefix: []const u8, count: usize, version: []const u8, readme_len: usize) !usize {
        var n: usize = 0;
        for (0..count) |i| {
            const name = try nameOf(w.a, prefix, i);
            const got = (try w.versionReadme(name, version)) orelse continue;
            if (std.mem.eql(u8, got, try readmeOf(w.a, name, readme_len))) n += 1;
        }
        return n;
    }

    fn published(w: World, prefix: []const u8, count: usize, version: []const u8) !usize {
        var n: usize = 0;
        for (0..count) |i| {
            const r = try w.get(try std.fmt.allocPrint(w.a, "/api/v1/packages/{s}/{s}", .{ try nameOf(w.a, prefix, i), version }));
            if (r.status == 200 and std.mem.eql(u8, h.jsonString(try h.parseJson(w.a, r.body), "state") orelse "", "published")) n += 1;
        }
        return n;
    }
};

const refusal_head = "the commit request of the 100 members to upload is ";
const objects_note = "the registry does not take readmes as objects";

// ----------------------------------------------------------------- scenarios

/// 100 members of 64 KiB readmes: the set publishes with the capability, and a registry without it refuses the same set.
fn aLargeSetPublishesAsObjects(w: World) !void {
    const a = w.a;
    const staged = try w.dir("large");
    try stageSet(a, staged, "rdb", big_count, "1.0.0", big_readme_len);
    const copy = try w.dir("large_inline");
    try stageSet(a, copy, "rdb", big_count, "1.0.0", big_readme_len);

    try w.objects(false);
    const before = try w.served();
    const refused = try w.publish(copy, &.{});
    w.rep.check("the 100-member set of 64 KiB readmes is refused inline by a registry without the capability", refused.code == 1 and h.contains(refused.stderr, refusal_head) and
        h.contains(refused.stderr, objects_note), try w.text(refused));
    w.rep.check("and nothing of it was created: the only requests are the API root and GET /health", (try w.served()) - before == 2 and
        (try w.published("rdb", big_count, "1.0.0")) == 0, "requests were sent or a member is served");
    try w.objects(true);

    const uploads_before = try w.uploads();
    const r = try w.publish(staged, &.{});
    w.rep.check("with the capability the same set publishes as readme objects and the run ends 0", r.code == 0 and h.contains(r.stdout, "published group grp_"), try w.text(r));
    w.rep.check("all 100 members are published", (try w.published("rdb", big_count, "1.0.0")) == big_count, "not all published");
    w.rep.check("every member's getVersion serves its whole 64 KiB readme", (try w.servedWhole("rdb", big_count, "1.0.0", big_readme_len)) == big_count, "a readme differs");
    const latest = try w.get("/api/v1/packages/rdb7");
    const latest_readme = h.jsonString(try h.parseJson(a, latest.body), "readme") orelse "";
    w.rep.check("and getPackage serves the readme of the latest version", std.mem.eql(u8, latest_readme, try readmeOf(a, "rdb7", big_readme_len)), "the package readme differs");
    w.rep.check("the readmes travelled as uploaded objects: the registry holds one stored object per file and per readme", (try w.uploads()) - uploads_before == 2 * big_count, try std.fmt.allocPrint(a, "{d} objects stored", .{(try w.uploads()) - uploads_before}));
}

/// Against a registry without the capability: a small set goes inline, a large one is refused after GET /health.
fn withoutTheCapability(w: World) !void {
    const a = w.a;
    try w.objects(false);
    defer w.objects(true) catch {};

    const small = try w.dir("small_off");
    try stageSet(a, small, "rds", 3, "1.0.0", 2000);
    const r = try w.publish(small, &.{});
    w.rep.check("a small set publishes inline against a registry without the capability and the run ends 0", r.code == 0 and h.contains(r.stdout, "published group grp_"), try w.text(r));
    w.rep.check("and its three readmes are served whole", (try w.servedWhole("rds", 3, "1.0.0", 2000)) == 3, "a readme differs");

    const large = try w.dir("large_off");
    try stageSet(a, large, "rdb", big_count, "2.0.0", big_readme_len);
    const before = try w.served();
    const uploads = try w.uploads();
    const refused = try w.publish(large, &.{});
    w.rep.check("a large set is refused with the commit-size message and says the registry does not take readmes as objects", refused.code == 1 and h.contains(refused.stderr, refusal_head) and
        h.contains(refused.stderr, "Shorten them or publish fewer packages in one group") and h.contains(refused.stderr, objects_note), try w.text(refused));
    w.rep.check("after the API root and GET /health, no group, no upload, no state.json", (try w.served()) - before == 2 and (try w.uploads()) == uploads and
        (try w.published("rdb", big_count, "2.0.0")) == 0 and !exists(try h.join(a, &.{ large, "state.json" })), "something was sent or written");
}

/// A group staged with readme objects, then the capability goes away and comes back.
fn aStagedGroupAcrossTheSwitch(w: World) !void {
    const a = w.a;
    try w.objects(true);

    // A set that fits inline: staged with objects, resumed inline.
    const fits = try w.dir("staged_fits");
    try stageSet(a, fits, "rdt", 3, "1.0.0", 3000);
    const s = try w.publish(fits, &.{"--no-commit"});
    const id = try w.groupId(fits);
    w.rep.check("a small set is staged with its readmes as objects: the group is open", s.code == 0 and h.contains(s.stdout, "staged group grp_") and
        std.mem.eql(u8, try w.groupStatus(id), "open"), try w.text(s));
    try w.objects(false);
    const resumed = try w.publish(fits, &.{});
    w.rep.check("resumed after the capability went away it publishes inline, in the same group", resumed.code == 0 and h.contains(resumed.stdout, "resuming group") and
        h.contains(resumed.stdout, "committed group") and std.mem.eql(u8, try w.groupId(fits), id) and (try w.published("rdt", 3, "1.0.0")) == 3, try w.text(resumed));
    w.rep.check("and the three readmes are served whole", (try w.servedWhole("rdt", 3, "1.0.0", 3000)) == 3, "a readme differs");

    // A set that does not fit inline.
    try w.objects(true);
    const over = try w.dir("staged_over");
    try stageSet(a, over, "rdb", big_count, "3.0.0", big_readme_len);
    const t = try w.publish(over, &.{"--no-commit"});
    const over_id = try w.groupId(over);
    w.rep.check("a large set is staged with its readmes as objects: the group is open", t.code == 0 and h.contains(t.stdout, "staged group grp_") and
        std.mem.eql(u8, try w.groupStatus(over_id), "open"), try w.text(t));
    const state_before = try h.readFile(a, try h.join(a, &.{ over, "state.json" }));
    try w.objects(false);
    const refused = try w.publish(over, &.{});
    w.rep.check("resumed after the capability went away it is refused with the commit-size message and the note about readme objects", refused.code == 1 and
        h.contains(refused.stderr, refusal_head) and h.contains(refused.stderr, objects_note) and !h.contains(refused.stdout, "committed group"), try w.text(refused));
    w.rep.check("and the group is still open, nothing is published, and state.json is as it was", std.mem.eql(u8, try w.groupStatus(over_id), "open") and
        (try w.published("rdb", big_count, "3.0.0")) == 0 and std.mem.eql(u8, try h.readFile(a, try h.join(a, &.{ over, "state.json" })), state_before), "the group, the versions or state.json changed");

    try w.objects(true);
    const again = try w.publish(over, &.{});
    w.rep.check("with the capability back, the resume publishes the same group", again.code == 0 and h.contains(again.stdout, "resuming group") and
        std.mem.eql(u8, try w.groupId(over), over_id) and (try w.published("rdb", big_count, "3.0.0")) == big_count, try w.text(again));
    w.rep.check("and every member serves its whole readme", (try w.servedWhole("rdb", big_count, "3.0.0", big_readme_len)) == big_count, "a readme differs");
}

/// The same set through two registries, one taking readme objects and one not: what each serves for it.
fn bothFormsAgree(w: World, exe: []const u8, other_dir: []const u8) !void {
    const a = w.a;
    const inline_reg = try Reg.open(a, w.rep, exe, other_dir, "rdm-inline", &.{.{ .prefix = "rdm", .count = 3 }});
    var inline_fake = inline_reg.fake;
    defer inline_fake.close();
    const other = World{ .a = a, .rep = w.rep, .exe = w.exe, .env = w.env, .reg = inline_reg, .work = w.work, .conf = try h.join(a, &.{ w.work, "conf_inline" }) };
    try other.objects(false);
    try w.objects(true);

    // Readmes with a byte order mark, multi-byte text, a long line and the quote and control characters of JSON.
    const readmes = [_][]const u8{ "\xEF\xBB\xBF# rdm0\nwith a byte order mark\n", "# rdm1 \xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80\n\"quoted\" \\ \t\x01 and </script>\n", "x" ** 5000 };
    const dirs = [_][]const u8{ try w.dir("same_objects"), try w.dir("same_inline") };
    for (dirs) |d| {
        try stageSet(a, d, "rdm", 3, "1.0.0", 10);
        for (readmes, 0..) |text, i| try h.writeFile(try h.join(a, &.{ d, try std.fmt.allocPrint(a, "rdm{d}.md", .{i}) }), text);
    }
    const objects_run = try w.publish(dirs[0], &.{});
    const inline_run = try other.publish(dirs[1], &.{});
    w.rep.check("the set publishes with readme objects", objects_run.code == 0 and h.contains(objects_run.stdout, "published group grp_"), try w.text(objects_run));
    w.rep.check("the set publishes inline against the registry without the capability", inline_run.code == 0 and h.contains(inline_run.stdout, "published group grp_"), try other.text(inline_run));

    var same_version = true;
    var same_package = true;
    var same_index = true;
    var same_channel = true;
    var served_whole = true;
    for (readmes, 0..) |text, i| {
        const name = try nameOf(a, "rdm", i);
        const path = try std.fmt.allocPrint(a, "/api/v1/packages/{s}/1.0.0", .{name});
        const x = try w.get(path);
        const y = try other.get(path);
        const xr = h.jsonString(try h.parseJson(a, x.body), "readme") orelse "";
        const yr = h.jsonString(try h.parseJson(a, y.body), "readme") orelse "";
        if (!std.mem.eql(u8, xr, yr)) same_version = false;
        if (!std.mem.eql(u8, xr, text)) served_whole = false;
        const pkg = try std.fmt.allocPrint(a, "/api/v1/packages/{s}", .{name});
        const px = h.jsonString(try h.parseJson(a, (try w.get(pkg)).body), "readme") orelse "";
        const py = h.jsonString(try h.parseJson(a, (try other.get(pkg)).body), "readme") orelse "";
        if (!std.mem.eql(u8, px, py) or !std.mem.eql(u8, px, text)) same_package = false;
        const idx = try std.fmt.allocPrint(a, "/index/rd/m{d}/{s}", .{ i, name });
        const ix = try w.get(idx);
        const iy = try other.get(idx);
        const nx = try withoutBaseAndTime(a, ix.body, w.reg.fake.base);
        const ny = try withoutBaseAndTime(a, iy.body, other.reg.fake.base);
        if (ix.status != 200 or iy.status != 200 or !std.mem.eql(u8, nx, ny)) same_index = false;
        const file = try std.fmt.allocPrint(a, "/channel/noarch/{s}", .{try filenameOf(a, name, "1.0.0")});
        const cx = try w.get(file);
        const cy = try other.get(file);
        if (cx.status != 200 or cx.status != cy.status or !std.mem.eql(u8, cx.body, cy.body)) same_channel = false;
    }
    w.rep.check("both registries serve the same readme field in getVersion for each of the three members", same_version, "a getVersion readme differs");
    w.rep.check("and it is the text that was staged, byte for byte (byte order mark, multi-byte text and control characters kept)", served_whole, "a readme differs from the staged one");
    w.rep.check("and the same readme in getPackage", same_package, "a getPackage readme differs");
    w.rep.check("and identical sparse-index records for each member, but for the registry's own address in the file urls and published_at", same_index, "an index record differs");
    w.rep.check("and byte-identical channel files", same_channel, "a channel file differs");
}

/// `body` with the registry's own address taken out of the file urls and the value of `published_at` (the clock of that registry) blanked.
fn withoutBaseAndTime(a: Allocator, body: []const u8, base: []const u8) ![]u8 {
    const replaced = try std.mem.replaceOwned(u8, a, body, base, "");
    const key = "\"published_at\":\"";
    const at = std.mem.indexOf(u8, replaced, key) orelse return replaced;
    const from = at + key.len;
    const to = std.mem.indexOfScalarPos(u8, replaced, from, '"') orelse return replaced;
    return std.mem.concat(a, u8, &.{ replaced[0..from], replaced[to..] });
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

// ------------------------------------------------------------------- the test

test "mopm publish --staged sends readmes as objects, and falls back to inline, against the fake registry" {
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

    h.stage = "starting the fake registry";
    const reg = try Reg.open(a, &report, fake_exe, try h.join(a, &.{ work, "fake" }), "readme-user", &.{
        .{ .prefix = "rdb", .count = big_count },
        .{ .prefix = "rds", .count = 3 },
        .{ .prefix = "rdt", .count = 3 },
        .{ .prefix = "rdm", .count = 3 },
    });
    var fake = reg.fake;
    defer fake.close();

    const w = World{ .a = a, .rep = &report, .exe = mopm_exe, .env = env, .reg = reg, .work = work, .conf = try h.join(a, &.{ work, "conf" }) };
    try aLargeSetPublishesAsObjects(w);
    try withoutTheCapability(w);
    try aStagedGroupAcrossTheSwitch(w);
    try bothFormsAgree(w, fake_exe, try h.join(a, &.{ work, "fake_inline" }));
    try report.finish();
}
