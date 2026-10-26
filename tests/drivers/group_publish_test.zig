//! End-to-end tests of `mopm publish --staged` and `mopm yank --group` against the fake registry (spec/staged-set.md).
//!
//! Run by Buck2 (//:group_publish): MOPM, MOPM_FAKE_REGISTRY and MOPM_ENV_PROBE are the built programs. Each check prints
//! `ok` or `FAIL`. Every scenario is a staged set of three packages, a, b and c (b needs a, c needs b: the plan lists them in
//! that order), published to the fake registry through one group.
//!
//! What can go red, and why:
//! - a chain published through one group must end with all three versions served, in the index and in the report, and
//!   nothing before that; one member the registry rejects must leave none of them published, and its number free;
//! - a group past its deadline when the commit arrives is refused, and a rerun opens it again and finishes;
//! - a rerun after a failed PUT must ask for the same group (the id in state.json) and send only the files the registry
//!   does not hold; a registry with no group publish (404) must get nothing uploaded; a 429 must stop the run where it is;
//! - the token must be in no program mopm starts (one stand-in plays mojo, the test binary and pixi, and records its
//!   environment: `mopm run`, the compile and the `--skip-all` listing of `mopm test`, and the installer of `mopm sync`),
//!   and in nothing mopm prints;
//! - a yank of the group yanks its members, and an unyank restores those and not the one yanked by hand before.

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

const Member = struct {
    name: []const u8,
    version: []const u8,
    bytes: []const u8,
    action: []const u8 = "upload",
    reason: []const u8 = "",
};

fn sha256Hex(a: Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

fn filenameOf(a: Allocator, m: Member) ![]u8 {
    return std.fmt.allocPrint(a, "mojo-{s}-{s}-mojo1.0.0_0.conda", .{ m.name, m.version });
}

/// Writes a staged directory: the files below `noarch/` and a plan.json that lists the members in the order given.
fn stage(a: Allocator, dir: []const u8, members: []const Member) !void {
    var plan = std.ArrayList(u8).init(a);
    try plan.appendSlice("{\"version\":1,\"members\":[");
    for (members, 0..) |m, i| {
        if (i != 0) try plan.append(',');
        if (!std.mem.eql(u8, m.action, "upload")) {
            try plan.writer().print("{{\"name\":\"{s}\",\"version\":\"{s}\",\"action\":\"{s}\",\"reason\":\"{s}\"}}", .{ m.name, m.version, m.action, m.reason });
            continue;
        }
        const filename = try filenameOf(a, m);
        try h.writeFile(try h.join(a, &.{ dir, "noarch", filename }), m.bytes);
        try plan.writer().print(
            "{{\"name\":\"{s}\",\"version\":\"{s}\",\"action\":\"upload\",\"manifest_sha256\":\"{s}\",\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}]}}",
            .{ m.name, m.version, try sha256Hex(a, m.name), filename, try sha256Hex(a, m.bytes), m.bytes.len },
        );
    }
    try plan.appendSlice("]}");
    try h.writeFile(try h.join(a, &.{ dir, "plan.json" }), plan.items);
}

const names = [_][]const u8{ "grp_a", "grp_b", "grp_c" };

/// The three members of a scenario at `version`; `b_bytes` lets one scenario make b's file a rejected one.
fn chain(version: []const u8, b_bytes: []const u8) [3]Member {
    return .{
        .{ .name = names[0], .version = version, .bytes = "the bytes of a" },
        .{ .name = names[1], .version = version, .bytes = b_bytes },
        .{ .name = names[2], .version = version, .bytes = "the bytes of c" },
    };
}

const World = struct {
    a: Allocator,
    rep: *h.Report,
    m: Mopm,
    fake: h.Fake,
    fake_dir: []const u8,
    work: []const u8,
    conf: []const u8,
    token: []const u8,

    fn api(w: World, method: []const u8, path: []const u8, body: ?[]const u8) !h.Response {
        return h.request(w.a, method, w.fake.base, path, body, w.token);
    }

    /// The state of `name` `version` as the registry serves it, or "absent".
    fn stateOf(w: World, name: []const u8, version: []const u8) ![]const u8 {
        const r = try h.request(w.a, "GET", w.fake.base, try std.fmt.allocPrint(w.a, "/api/v1/packages/{s}/{s}", .{ name, version }), null, null);
        if (r.status != 200) return "absent";
        return h.jsonString(try h.parseJson(w.a, r.body), "state") orelse "unknown";
    }

    fn visible(w: World, version: []const u8) !usize {
        var n: usize = 0;
        for (names) |name| {
            if (!std.mem.eql(u8, try w.stateOf(name, version), "absent")) n += 1;
        }
        return n;
    }

    fn allIn(w: World, version: []const u8, state: []const u8) !bool {
        for (names) |name| {
            if (!std.mem.eql(u8, try w.stateOf(name, version), state)) return false;
        }
        return true;
    }

    fn publish(w: World, staged: []const u8, extra: []const []const u8) !Out {
        const base = [_][]const u8{ "publish", "--staged", staged, "--registry", w.fake.base, "--config-dir", w.conf, "--wait", "60" };
        const argv = try std.mem.concat(w.a, []const u8, &.{ &base, extra });
        return w.m.run(argv, w.token);
    }

    fn json(w: World, path: []const u8) !std.json.Value {
        return h.parseJson(w.a, try h.readFile(w.a, path));
    }

    fn stateJson(w: World, staged: []const u8) !std.json.Value {
        return w.json(try h.join(w.a, &.{ staged, "state.json" }));
    }

    fn reportJson(w: World, staged: []const u8) !std.json.Value {
        return w.json(try h.join(w.a, &.{ staged, "report.json" }));
    }

    fn groupId(w: World, staged: []const u8) ![]const u8 {
        return h.jsonString(try w.stateJson(staged), "group_id") orelse "";
    }

    fn uploads(w: World) !usize {
        return (try h.findFilesAll(w.a, try h.join(w.a, &.{ w.fake_dir, "uploads" }))).len;
    }

    fn dir(w: World, name: []const u8) ![]const u8 {
        return h.join(w.a, &.{ w.work, name });
    }

    fn memberOutcome(report: std.json.Value, name: []const u8) []const u8 {
        for (report.object.get("members").?.array.items) |m| {
            if (std.mem.eql(u8, h.jsonString(m, "name") orelse "", name)) return h.jsonString(m, "outcome") orelse "";
        }
        return "(none)";
    }
};

// ----------------------------------------------------------------- scenarios

fn publishAChain(w: World) !void {
    const a = w.a;
    const staged = try w.dir("chain");
    const members = chain("1.0.0", "the bytes of b");
    try stage(a, staged, &members);
    w.rep.check("before the run none of the three versions is served", (try w.visible("1.0.0")) == 0, "something is visible");
    const r = try w.publish(staged, &.{});
    w.rep.check("a three-package chain is published through one group and the run ends 0", r.code == 0 and h.contains(r.stdout, "published group grp_") and
        h.contains(r.stdout, "grp_a 1.0.0 grp_b 1.0.0 grp_c 1.0.0"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    w.rep.check("then all three versions are published", try w.allIn("1.0.0", "published"), "not all published");
    const idx = try h.request(a, "GET", w.fake.base, "/index/gr/p_/grp_b", null, null);
    w.rep.check("the sparse index lists a member with the sha256 of the file in the plan", idx.status == 200 and h.contains(idx.body, "\"version\":\"1.0.0\"") and
        h.contains(idx.body, try sha256Hex(a, "the bytes of b")), idx.body);
    const ch = try h.request(a, "GET", w.fake.base, "/channel/noarch/mojo-grp_c-1.0.0-mojo1.0.0_0.conda", null, null);
    w.rep.check("the channel serves a member's file, byte for byte", ch.status == 200 and std.mem.eql(u8, ch.body, "the bytes of c"), "wrong bytes");

    const report = try w.reportJson(staged);
    const id = try w.groupId(staged);
    w.rep.check("report.json names the run, the group, and each member as published", h.jsonString(report, "outcome") != null and
        std.mem.eql(u8, h.jsonString(report, "outcome").?, "published") and std.mem.eql(u8, h.jsonString(report, "group_id") orelse "", id) and
        std.mem.startsWith(u8, id, "grp_") and (h.jsonString(report, "run_id") orelse "").len == 16 and
        std.mem.eql(u8, World.memberOutcome(report, "grp_a"), "published") and std.mem.eql(u8, World.memberOutcome(report, "grp_c"), "published"), "the report is not as expected");
    const state = try w.stateJson(staged);
    w.rep.check("state.json names the group and says it was committed", state.object.get("committed").?.bool and state.object.get("uploaded").?.array.items.len == 3, "the state is not as expected");

    const again = try w.publish(staged, &.{});
    w.rep.check("a rerun of a published set asks for the same group and ends 0", again.code == 0 and h.contains(again.stdout, "resuming group") and
        std.mem.eql(u8, try w.groupId(staged), id), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ again.code, again.stdout, again.stderr }));
}

fn aRejectedMember(w: World) !void {
    const a = w.a;
    const staged = try w.dir("rejected");
    const members = chain("1.1.0", "REJECT:path_not_allowed from the test");
    try stage(a, staged, &members);
    const r = try w.publish(staged, &.{});
    w.rep.check("a group with a rejected member ends 1 and names the member and the code", r.code == 1 and h.contains(r.stderr, "is rejected: path_not_allowed") and
        h.contains(r.stderr, "(member grp_b)") and h.contains(r.stderr, "none of its members is published"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    w.rep.check("and none of the three versions is served", (try w.visible("1.1.0")) == 0, "a member is visible");
    const report = try w.reportJson(staged);
    w.rep.check("report.json names the rejected member and says the others were not published", std.mem.eql(u8, h.jsonString(report, "outcome") orelse "", "failed") and
        std.mem.eql(u8, World.memberOutcome(report, "grp_b"), "rejected") and std.mem.eql(u8, World.memberOutcome(report, "grp_a"), "not_published") and
        std.mem.eql(u8, World.memberOutcome(report, "grp_c"), "not_published"), "the report is not as expected");

    // The numbers are free again: the same versions, with a b that is accepted, are another group and go through.
    const fixed = try w.dir("rejected_fixed");
    const good = chain("1.1.0", "the bytes of b, fixed");
    try stage(a, fixed, &good);
    const ok = try w.publish(fixed, &.{});
    w.rep.check("after a rejection the same versions can be published again", ok.code == 0 and try w.allIn("1.1.0", "published"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ ok.code, ok.stdout, ok.stderr }));
}

fn anExpiredGroup(w: World) !void {
    const a = w.a;
    const staged = try w.dir("expired");
    const members = chain("1.2.0", "the bytes of b");
    try stage(a, staged, &members);
    _ = try w.fake.control(a, "/commit_clock", "{\"advance_seconds\":46800}");
    const r = try w.publish(staged, &.{});
    w.rep.check("a group past its deadline when the commit arrives is refused at the commit", r.code == 1 and h.contains(r.stderr, "The group cannot be committed") and
        h.contains(r.stderr, "expired at"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    w.rep.check("and nothing is published", (try w.visible("1.2.0")) == 0, "a member is visible");
    const state = try w.stateJson(staged);
    w.rep.check("state.json keeps the group and says it was not committed", !state.object.get("committed").?.bool and (try w.groupId(staged)).len > 0, "the state is not as expected");
    const again = try w.publish(staged, &.{});
    w.rep.check("a rerun opens the group again, finds the files stored, and publishes", again.code == 0 and h.contains(again.stdout, "(attempt 2)") and
        h.contains(again.stdout, "3 file(s) were already in the registry's storage") and try w.allIn("1.2.0", "published"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ again.code, again.stdout, again.stderr }));
}

fn aFailedPutThenARerun(w: World) !void {
    const a = w.a;
    const staged = try w.dir("failed_put");
    const members = chain("1.3.0", "the bytes of b");
    try stage(a, staged, &members);
    _ = try w.fake.control(a, "/put_fault", "{\"after\":1}");
    // --retries 0: this scenario is about the resume, so the failed PUT must end the run (the next scenario retries it).
    const r = try w.publish(staged, &.{ "--retries", "0" });
    const id = try w.groupId(staged);
    w.rep.check("a failed PUT ends the run 1, says which file, and says to run the same command again", r.code == 1 and h.contains(r.stderr, "uploading mojo-grp_b-1.3.0-mojo1.0.0_0.conda failed") and
        h.contains(r.stderr, "run the same command again to resume group grp_") and h.contains(r.stderr, id), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    w.rep.check("nothing is published, and the state names the group with one file stored", (try w.visible("1.3.0")) == 0 and id.len > 0 and
        (try w.stateJson(staged)).object.get("uploaded").?.array.items.len == 1, "the state is not as expected");
    const again = try w.publish(staged, &.{});
    const report = try w.reportJson(staged);
    w.rep.check("the rerun resumes the SAME group, sends only what is missing, and publishes", again.code == 0 and std.mem.eql(u8, h.jsonString(report, "group_id") orelse "", id) and
        std.mem.eql(u8, try w.groupId(staged), id) and h.contains(again.stdout, "1 file(s) were already in the registry's storage") and try w.allIn("1.3.0", "published"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ again.code, again.stdout, again.stderr }));
}

fn transientFailuresAreRetried(w: World) !void {
    const a = w.a;
    // A storage that fails one PUT with a 503: the run repeats it and publishes, in one run, with no rerun.
    const put = try w.dir("retried_put");
    const m1 = chain("1.6.0", "the bytes of b");
    try stage(a, put, &m1);
    _ = try w.fake.control(a, "/put_fault", "{\"after\":1}");
    const r1 = try w.publish(put, &.{});
    w.rep.check("a PUT answered 503 once is repeated, and the one run publishes the chain", r1.code == 0 and try w.allIn("1.6.0", "published") and
        h.contains(r1.stdout, "uploaded mojo-grp_b-1.6.0") and !h.contains(r1.stderr, "failed"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r1.code, r1.stdout, r1.stderr }));

    // The poll for the group's state fails once with 503: asked again, and the run still ends 0.
    const poll = try w.dir("retried_poll");
    const m2 = chain("1.6.1", "the bytes of b");
    try stage(a, poll, &m2);
    _ = try w.fake.control(a, "/fault", "{\"operation\":\"getGroup\",\"code\":\"unavailable\"}");
    const r2 = try w.publish(poll, &.{});
    w.rep.check("a poll answered 503 once is asked again, and the run publishes", r2.code == 0 and try w.allIn("1.6.1", "published"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r2.code, r2.stdout, r2.stderr }));

    // A 4xx is final: the same single fault, a 403, is not asked again, so the run ends 1 and the group is not published by it.
    const refused = try w.dir("final_poll");
    const m3 = chain("1.6.2", "the bytes of b");
    try stage(a, refused, &m3);
    _ = try w.fake.control(a, "/fault", "{\"operation\":\"getGroup\",\"code\":\"not_owner\"}");
    const r3 = try w.publish(refused, &.{});
    w.rep.check("a poll answered 403 is not asked again: the run ends 1 and says what the registry said", r3.code == 1 and h.contains(r3.stderr, "You are not an owner"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r3.code, r3.stdout, r3.stderr }));
}

fn noGroupPublish(w: World) !void {
    const a = w.a;
    const staged = try w.dir("no_groups");
    const members = chain("1.4.0", "the bytes of b");
    try stage(a, staged, &members);
    const before = try w.uploads();
    _ = try w.fake.control(a, "/groups", "{\"enabled\":false}");
    const r = try w.publish(staged, &.{});
    w.rep.check("a 404 from /groups is refused: no group publish, and the run ends 1", r.code == 1 and h.contains(r.stderr, "has no group publish") and
        h.contains(r.stderr, "nothing was uploaded"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    w.rep.check("and nothing was uploaded", (try w.uploads()) == before, "an upload reached the registry");
    w.rep.check("and nothing is published, and the report says so", (try w.visible("1.4.0")) == 0 and (try w.groupId(staged)).len == 0 and
        std.mem.eql(u8, h.jsonString(try w.reportJson(staged), "outcome") orelse "", "no_group_publish"), "the state or report is not as expected");
    _ = try w.fake.control(a, "/groups", "{\"enabled\":true}");
    const later = try w.publish(staged, &.{});
    w.rep.check("once the registry has group publish, the same staged set goes through", later.code == 0 and try w.allIn("1.4.0", "published"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ later.code, later.stdout, later.stderr }));
}

fn rateLimited(w: World) !void {
    const a = w.a;
    // A 429 on the create: nothing is uploaded.
    const first = try w.dir("limited_create");
    const m1 = chain("1.5.1", "the bytes of b");
    try stage(a, first, &m1);
    const before = try w.uploads();
    _ = try w.fake.control(a, "/fault", "{\"operation\":\"createGroup\",\"code\":\"rate_limited\"}");
    const r1 = try w.publish(first, &.{});
    w.rep.check("a 429 on the create stops the run, says when to retry, and uploads nothing", r1.code == 1 and h.contains(r1.stderr, "HTTP 429") and
        h.contains(r1.stderr, "retry after 30 seconds") and (try w.uploads()) == before, try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r1.code, r1.stdout, r1.stderr }));

    // A 429 on the commit: the group is open, with its files stored, and not published.
    const staged = try w.dir("limited_commit");
    const m2 = chain("1.5.0", "the bytes of b");
    try stage(a, staged, &m2);
    _ = try w.fake.control(a, "/fault", "{\"operation\":\"commitGroup\",\"code\":\"rate_limited\"}");
    const r2 = try w.publish(staged, &.{});
    const id = try w.groupId(staged);
    w.rep.check("a 429 on the commit stops the run there", r2.code == 1 and h.contains(r2.stderr, "HTTP 429") and h.contains(r2.stderr, "retry after 30 seconds") and
        h.contains(r2.stdout, "uploaded mojo-grp_c-1.5.0") and !h.contains(r2.stdout, "committed group"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r2.code, r2.stdout, r2.stderr }));
    const group = try w.api("GET", try std.fmt.allocPrint(a, "/api/v1/groups/{s}", .{id}), null);
    w.rep.check("the group is open, nothing is published, and the report says pending", group.status == 200 and
        std.mem.eql(u8, h.jsonString(try h.parseJson(a, group.body), "status") orelse "", "open") and (try w.visible("1.5.0")) == 0 and
        std.mem.eql(u8, h.jsonString(try w.reportJson(staged), "outcome") orelse "", "rate_limited") and
        std.mem.eql(u8, World.memberOutcome(try w.reportJson(staged), "grp_a"), "pending"), group.body);

    // A group that is not visible cannot be yanked.
    const yank = try w.m.run(&.{ "yank", "--group", id, "--registry", w.fake.base, "--config-dir", w.conf, "--reason", "too early" }, w.token);
    w.rep.check("a yank of a group that is not visible is refused with the registry's reason", yank.code == 1 and h.contains(yank.stderr, "cannot be yanked or unyanked now"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ yank.code, yank.stdout, yank.stderr }));

    const again = try w.publish(staged, &.{});
    w.rep.check("the rerun commits the same group and publishes", again.code == 0 and std.mem.eql(u8, try w.groupId(staged), id) and try w.allIn("1.5.0", "published"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ again.code, again.stdout, again.stderr }));
}

fn theTokenIsInNoChildEnvironment(w: World, probe: []const u8) !void {
    const a = w.a;
    // A prefix whose `mojo` is a program that prints the variables it got.
    const prefix = try w.dir("prefix");
    try std.fs.cwd().makePath(try h.join(a, &.{ prefix, "lib", "mojo" }));
    try std.fs.cwd().makePath(try h.join(a, &.{ prefix, "bin" }));
    try std.fs.cwd().copyFile(probe, std.fs.cwd(), try h.join(a, &.{ prefix, "bin", "mojo" }), .{});
    try h.writeFile(try h.join(a, &.{ w.work, "prog.mojo" }), "def main(): pass\n");
    var env = try h.cloneEnv(a, &w.m.env);
    try env.put("MOPM_TOKEN", w.token);
    try env.put("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "actions_request_secret");
    try env.put("ACTIONS_ID_TOKEN_REQUEST_URL", "https://pipelines.example/idtoken?api-version=2.0");
    try env.put("MOPM_PROBE_MARK", "kept");
    const argv = [_][]const u8{ w.m.exe, "run", "--prefix", prefix, try h.join(a, &.{ w.work, "prog.mojo" }) };
    const r = try h.run(a, &argv, &env, .{});
    w.rep.check("a program mopm starts has no MOPM_TOKEN in its environment, and the rest of the environment as it was", h.contains(r.text, "MOPM_TOKEN=<unset>") and
        h.contains(r.text, "MOPM_PROBE_MARK=kept") and !h.contains(r.text, w.token), r.text);
    w.rep.check("nor the identity-token request token and URL that 'publish --oidc' asks GitHub with", h.contains(r.text, "ACTIONS_ID_TOKEN_REQUEST_TOKEN=<unset>") and
        h.contains(r.text, "ACTIONS_ID_TOKEN_REQUEST_URL=<unset>") and !h.contains(r.text, "actions_request_secret") and !h.contains(r.text, "pipelines.example"), r.text);
}

/// The lines the stand-in program appended to `path`, or "" when there are none.
fn probeLines(w: World, path: []const u8) []const u8 {
    return std.fs.cwd().readFileAlloc(w.a, path, 1 << 16) catch "";
}

/// Whether the stand-in reported, as `role`, an environment with no MOPM_TOKEN and the other variable as it was.
fn probeSawNoToken(lines: []const u8, role: []const u8, a: Allocator) !bool {
    return h.contains(lines, try std.fmt.allocPrint(a, "{s}: MOPM_TOKEN=<unset> MOPM_PROBE_MARK=kept\n", .{role}));
}

/// The compiler `mopm test` runs, the test binary it lists with `--skip-all`, and the installer `mopm sync` runs each get an
/// environment without the token (`mopm run` is checked above). One stand-in plays all three: `mojo build` leaves a copy of it
/// as the test binary, so a single `mopm test` starts two programs, and each appends a line saying what it was given.
fn theTokenIsInNoTestOrInstallerEnvironment(w: World, probe: []const u8) !void {
    const a = w.a;
    const prefix = try w.dir("prefix_test");
    try std.fs.cwd().makePath(try h.join(a, &.{ prefix, "lib", "mojo" }));
    try std.fs.cwd().makePath(try h.join(a, &.{ prefix, "bin" }));
    try std.fs.cwd().copyFile(probe, std.fs.cwd(), try h.join(a, &.{ prefix, "bin", "mojo" }), .{});

    // `mopm test`: the compile line and the `--skip-all` listing.
    const proj = try w.dir("proj_test");
    try std.fs.cwd().makePath(try h.join(a, &.{ proj, "tests" }));
    try h.writeFile(try h.join(a, &.{ proj, "tests", "test_probe.mojo" }), "def test_probe() raises:\n    pass\n");
    const out_test = try h.join(a, &.{ w.work, "probe_test.txt" });
    var env = try h.cloneEnv(a, &w.m.env);
    try env.put("MOPM_TOKEN", w.token);
    try env.put("MOPM_PROBE_MARK", "kept");
    try env.put("MOPM_PROBE_OUT", out_test);
    const t = try h.run(a, &.{ w.m.exe, "test", "--prefix", prefix, "tests/test_probe.mojo" }, &env, .{ .cwd = proj });
    const seen = probeLines(w, out_test);
    w.rep.check("mopm test starts the compiler and the test binary, and neither has MOPM_TOKEN in its environment", (try probeSawNoToken(seen, "build", a)) and
        (try probeSawNoToken(seen, "--skip-all", a)) and !h.contains(seen, w.token) and !h.contains(t.text, w.token), try std.fmt.allocPrint(a, "{s}\n{s}", .{ seen, t.text }));

    // `mopm sync`: the installer. A project with no dependency is locked with no registry.
    const sync_dir = try w.dir("proj_sync");
    try std.fs.cwd().makePath(sync_dir);
    try h.writeFile(try h.join(a, &.{ sync_dir, "mopm.toml" }), "[package]\nname = \"probe_sync\"\nversion = \"0.1.0\"\n\n[toolchain]\nmojo = \"1.0.0\"\n");
    const out_sync = try h.join(a, &.{ w.work, "probe_sync.txt" });
    try env.put("MOPM_PROBE_OUT", out_sync);
    const s = try h.run(a, &.{ w.m.exe, "sync", "--pixi", probe }, &env, .{ .cwd = sync_dir });
    const installed = probeLines(w, out_sync);
    w.rep.check("mopm sync starts the installer, and it has no MOPM_TOKEN in its environment", (try probeSawNoToken(installed, "install", a)) and
        !h.contains(installed, w.token) and !h.contains(s.text, w.token), try std.fmt.allocPrint(a, "{s}\n{s}", .{ installed, s.text }));
}

fn yankAndUnyank(w: World) !void {
    const a = w.a;
    const staged = try w.dir("chain");
    const id = try w.groupId(staged);
    // One member is yanked by hand first.
    const by_hand = try w.api("PUT", "/api/v1/packages/grp_b/1.0.0/yank", "{\"yanked\":true,\"reason\":\"by hand\"}");
    w.rep.check("a member is yanked by hand", by_hand.status == 200, by_hand.body);
    const y = try w.m.run(&.{ "yank", "--group", id, "--registry", w.fake.base, "--config-dir", w.conf, "--reason", "broken build", "--wait", "60" }, w.token);
    w.rep.check("mopm yank --group yanks the group's versions and waits for the registry", y.code == 0 and h.contains(y.stdout, "is yanked (2 versions)"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ y.code, y.stdout, y.stderr }));
    w.rep.check("all three are yanked, and the group says so", try w.allIn("1.0.0", "yanked") and
        std.mem.eql(u8, h.jsonString((try h.parseJson(a, (try w.api("GET", try std.fmt.allocPrint(a, "/api/v1/groups/{s}", .{id}), null)).body)).object.get("yank").?, "state") orelse "", "yanked"), "not all yanked");
    const repeat = try w.m.run(&.{ "yank", "--group", id, "--registry", w.fake.base, "--config-dir", w.conf, "--reason", "broken build" }, w.token);
    w.rep.check("a yank of a group already yanked is done at once", repeat.code == 0 and h.contains(repeat.stdout, "is already yanked"), repeat.stdout);
    const u = try w.m.run(&.{ "yank", "--group", id, "--registry", w.fake.base, "--config-dir", w.conf, "--unyank", "--wait", "60" }, w.token);
    w.rep.check("mopm yank --group --unyank restores the group's versions", u.code == 0 and h.contains(u.stdout, "is restored (2 versions it had yanked)"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ u.code, u.stdout, u.stderr }));
    w.rep.check("the two the group yanked are published again, and the one yanked by hand stays yanked", std.mem.eql(u8, try w.stateOf("grp_a", "1.0.0"), "published") and
        std.mem.eql(u8, try w.stateOf("grp_c", "1.0.0"), "published") and std.mem.eql(u8, try w.stateOf("grp_b", "1.0.0"), "yanked"), "the states are not as expected");
    const none = try w.m.run(&.{ "yank", "--group", "grp_00000000000000000000000000000000", "--registry", w.fake.base, "--config-dir", w.conf, "--unyank" }, w.token);
    w.rep.check("a group that does not exist is the registry's error", none.code == 1 and h.contains(none.stderr, "There is no such group"), none.stderr);
    const bare = try w.m.run(&.{ "yank", "--group", id, "--registry", dead, "--config-dir", w.conf }, w.token);
    w.rep.check("a yank with no reason is refused before any request", bare.code == 2 and h.contains(bare.stderr, "needs --reason") and !h.contains(bare.stderr, "cannot reach"), bare.stderr);
    const unplaced = try w.m.run(&.{ "yank", "--group", id, "--reason", "x" }, w.token);
    w.rep.check("a yank with no --registry is refused: there is no default", unplaced.code == 2 and h.contains(unplaced.stderr, "--registry is required"), unplaced.stderr);
}

fn refusalsBeforeAnyRequest(w: World) !void {
    const a = w.a;
    const staged = try w.dir("refusals");
    const members = chain("2.0.0", "the bytes of b");
    try stage(a, staged, &members);
    var r = try w.m.run(&.{ "publish", "--staged", staged }, null);
    w.rep.check("--staged without --registry is a usage error", r.code == 2 and h.contains(r.stderr, "--registry is required with --staged"), r.stderr);
    r = try w.m.run(&.{ "publish", "--staged", staged, "--registry", dead, "--mojoc", "x.mojoc" }, null);
    w.rep.check("--staged with a package to pack is a usage error", r.code == 2 and h.contains(r.stderr, "--mojoc packs one package"), r.stderr);
    try std.fs.cwd().makePath(try w.dir("empty_dir"));
    r = try w.m.run(&.{ "publish", "--staged", try w.dir("empty_dir"), "--registry", dead }, null);
    w.rep.check("a directory with no plan.json is refused", r.code == 1 and h.contains(r.stderr, "plan.json"), r.stderr);
    r = try w.m.run(&.{ "publish", "--staged", staged, "--registry", dead, "--config-dir", w.conf }, null);
    w.rep.check("a registry nothing listens on is reported, not hung on", r.code == 1, try std.fmt.allocPrint(a, "{d}: {s}", .{ r.code, r.stderr }));

    // --dry-run reads no token, sends nothing and writes nothing.
    r = try w.m.run(&.{ "publish", "--staged", staged, "--registry", dead, "--config-dir", w.conf, "--dry-run" }, null);
    w.rep.check("--dry-run says what it would send, with no token and no registry", r.code == 0 and h.contains(r.stdout, "would create one group of 3 members (3 files)") and
        h.contains(r.stdout, "dry run: nothing was sent"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    w.rep.check("and writes neither a state nor a report", !exists(try h.join(a, &.{ staged, "state.json" })) and !exists(try h.join(a, &.{ staged, "report.json" })), "a record was written");
    r = try w.m.run(&.{ "publish", "--staged", staged, "--registry", "nowhere", "--dry-run" }, null);
    w.rep.check("--dry-run still refuses a registry that is not one", r.code == 1 and h.contains(r.stderr, "--registry nowhere"), r.stderr);

    // A file that changed since the plan, a plan that refuses a member, a plan with nothing to upload.
    try h.writeFile(try h.join(a, &.{ staged, "noarch", "mojo-grp_b-2.0.0-mojo1.0.0_0.conda" }), "THE BYTES OF B");
    r = try w.m.run(&.{ "publish", "--staged", staged, "--registry", dead, "--config-dir", w.conf }, "mopm_unused");
    w.rep.check("a file that is not the one in the plan is refused before any request", r.code == 1 and h.contains(r.stderr, "has the sha256") and h.contains(r.stderr, "nothing was sent") and
        !h.contains(r.stderr, "cannot reach"), r.stderr);
    const refusing = try w.dir("refusing");
    try stage(a, refusing, &.{
        .{ .name = names[0], .version = "2.0.0", .bytes = "x" },
        .{ .name = names[1], .version = "2.0.0", .bytes = "", .action = "refuse", .reason = "the version is yanked" },
    });
    r = try w.m.run(&.{ "publish", "--staged", refusing, "--registry", dead, "--config-dir", w.conf }, "mopm_unused");
    w.rep.check("a plan that refuses a member stops the whole run before any request", r.code == 1 and h.contains(r.stderr, "the plan refuses grp_b 2.0.0: the version is yanked") and
        !h.contains(r.stderr, "cannot reach"), r.stderr);
    const skipping = try w.dir("skipping");
    try stage(a, skipping, &.{.{ .name = names[0], .version = "2.0.0", .bytes = "", .action = "skip", .reason = "already published" }});
    r = try w.m.run(&.{ "publish", "--staged", skipping, "--registry", dead, "--config-dir", w.conf }, null);
    const report = try w.reportJson(skipping);
    w.rep.check("a plan with nothing to upload ends 0 and the report names the skipped member", r.code == 0 and h.contains(r.stdout, "nothing to publish") and
        std.mem.eql(u8, World.memberOutcome(report, "grp_a"), "skipped"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));

    // A state from another plan, a state from another registry, no login.
    const other = try w.dir("other_plan");
    const m2 = chain("2.1.0", "the bytes of b");
    try stage(a, other, &m2);
    try h.writeFile(try h.join(a, &.{ other, "state.json" }), try std.fmt.allocPrint(a, "{{\"registry\":\"{s}/api/v1\",\"plan_sha256\":\"{s}\"}}", .{ w.fake.base, "0" ** 64 }));
    r = try w.publish(other, &.{});
    w.rep.check("a state.json of another plan is refused, and nothing is sent", r.code == 1 and h.contains(r.stderr, "belongs to another plan") and (try w.visible("2.1.0")) == 0, r.stderr);
    try h.writeFile(try h.join(a, &.{ other, "state.json" }), "{\"registry\":\"http://elsewhere/api/v1\",\"plan_sha256\":\"x\"}");
    r = try w.publish(other, &.{});
    w.rep.check("a state.json of another registry is refused", r.code == 1 and h.contains(r.stderr, "belongs to the registry http://elsewhere/api/v1"), r.stderr);
    try h.writeFile(try h.join(a, &.{ other, "state.json" }), "not json");
    r = try w.publish(other, &.{});
    w.rep.check("a state.json that is not one is refused", r.code == 1 and h.contains(r.stderr, "not a state file"), r.stderr);
    try std.fs.cwd().deleteFile(try h.join(a, &.{ other, "state.json" }));
    r = try w.m.run(&.{ "publish", "--staged", other, "--registry", w.fake.base, "--config-dir", w.conf }, null);
    w.rep.check("with no token and no login the run says to log in, before sending anything", r.code == 1 and h.contains(r.stderr, "not logged in") and (try w.visible("2.1.0")) == 0, r.stderr);
}

fn groupStatus(w: World, id: []const u8) ![]const u8 {
    const r = try w.api("GET", try std.fmt.allocPrint(w.a, "/api/v1/groups/{s}", .{id}), null);
    return h.jsonString(try h.parseJson(w.a, r.body), "status") orelse "(none)";
}

/// `--no-commit` stops with the group open and nothing readable; the same directory, run again without it, commits that group.
fn stageThenCommit(w: World) !void {
    const a = w.a;
    const staged = try w.dir("staged_commit");
    const members = chain("3.0.0", "the bytes of b");
    try stage(a, staged, &members);
    const digest = try sha256Hex(a, try h.readFile(a, try h.join(a, &.{ staged, "plan.json" })));
    const r = try w.publish(staged, &.{"--no-commit"});
    const id = try w.groupId(staged);
    w.rep.check("--no-commit uploads the set and ends 0, saying the group and the plan digest", r.code == 0 and h.contains(r.stdout, "staged group grp_") and
        h.contains(r.stdout, "open, 3 file(s) held, not committed") and h.contains(r.stdout, digest) and !h.contains(r.stdout, "published group"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    w.rep.check("the registry holds the group open, and serves none of the three versions", std.mem.eql(u8, try groupStatus(w, id), "open") and (try w.visible("3.0.0")) == 0, "the group is not open or a member is visible");
    const ch = try h.request(a, "GET", w.fake.base, "/channel/noarch/mojo-grp_c-3.0.0-mojo1.0.0_0.conda", null, null);
    const idx = try h.request(a, "GET", w.fake.base, "/index/gr/p_/grp_b", null, null);
    w.rep.check("and neither the channel nor the index serves a staged file", ch.status != 200 and !h.contains(idx.body, "\"3.0.0\""), "a staged file is readable");
    const report = try w.reportJson(staged);
    w.rep.check("report.json says the run is staged, names the group, the digest and the open status", std.mem.eql(u8, h.jsonString(report, "outcome") orelse "", "staged") and
        std.mem.eql(u8, h.jsonString(report, "group_id") orelse "", id) and std.mem.eql(u8, h.jsonString(report, "plan_sha256") orelse "", digest) and
        std.mem.eql(u8, h.jsonString(report, "group_status") orelse "", "open") and std.mem.eql(u8, World.memberOutcome(report, "grp_a"), "staged"), "the report is not as expected");
    const state = try w.stateJson(staged);
    w.rep.check("state.json keeps the group, marks it staged and not committed, and lists the three files", state.object.get("staged").?.bool and !state.object.get("committed").?.bool and
        state.object.get("uploaded").?.array.items.len == 3, "the state is not as expected");

    const again = try w.publish(staged, &.{});
    w.rep.check("the same command without --no-commit resumes the SAME group, sends no file, commits, and waits", again.code == 0 and h.contains(again.stdout, "resuming group") and
        h.contains(again.stdout, "3 file(s) were already in the registry's storage") and !h.contains(again.stdout, "uploaded mojo-") and h.contains(again.stdout, "committed group") and
        std.mem.eql(u8, try w.groupId(staged), id) and try w.allIn("3.0.0", "published"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ again.code, again.stdout, again.stderr }));
    w.rep.check("then report.json says published and state.json says committed, no longer staged", std.mem.eql(u8, h.jsonString(try w.reportJson(staged), "outcome") orelse "", "published") and
        (try w.stateJson(staged)).object.get("committed").?.bool and !(try w.stateJson(staged)).object.get("staged").?.bool, "the records are not as expected");
}

/// `--abort` ends the staged group and frees the actor's place: five open groups fill the actor's places, a sixth is refused, an abort lets it in.
fn abortFreesThePlace(w: World) !void {
    const a = w.a;
    const versions = [_][]const u8{ "4.0.0", "4.1.0", "4.2.0", "4.3.0", "4.4.0" };
    var dirs: [5][]const u8 = undefined;
    var ids: [5][]const u8 = undefined;
    for (versions, 0..) |v, i| {
        dirs[i] = try w.dir(try std.fmt.allocPrint(a, "slot_{d}", .{i}));
        const members = chain(v, "the bytes of b");
        try stage(a, dirs[i], &members);
        const r = try w.publish(dirs[i], &.{"--no-commit"});
        ids[i] = try w.groupId(dirs[i]);
        w.rep.check(try std.fmt.allocPrint(a, "{s} is staged and open", .{v}), r.code == 0 and std.mem.eql(u8, try groupStatus(w, ids[i]), "open"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    }
    const sixth = try w.dir("slot_5");
    const m6 = chain("4.5.0", "the bytes of b");
    try stage(a, sixth, &m6);
    const full = try w.publish(sixth, &.{"--no-commit"});
    w.rep.check("with five groups open a sixth cannot be staged: the registry's refusal is shown", full.code == 1 and h.contains(full.stderr, "at most 5 may be open"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ full.code, full.stdout, full.stderr }));

    const gone = try w.publish(dirs[0], &.{"--abort"});
    w.rep.check("--abort ends the group state.json names, says so, and ends 0", gone.code == 0 and h.contains(gone.stdout, "aborted group grp_") and std.mem.eql(u8, try groupStatus(w, ids[0]), "aborted") and
        (try w.visible("4.0.0")) == 0, try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ gone.code, gone.stdout, gone.stderr }));
    const report = try w.reportJson(dirs[0]);
    w.rep.check("report.json says aborted and names the group; state.json names none", std.mem.eql(u8, h.jsonString(report, "outcome") orelse "", "aborted") and
        std.mem.eql(u8, h.jsonString(report, "group_id") orelse "", ids[0]) and (try w.groupId(dirs[0])).len == 0, "the records are not as expected");
    const twice = try w.publish(dirs[0], &.{"--abort"});
    w.rep.check("a second --abort has no group to end: it says so, sends nothing and ends 0", twice.code == 0 and h.contains(twice.stdout, "names no group: nothing to abort"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ twice.code, twice.stdout, twice.stderr }));

    const freed = try w.publish(sixth, &.{"--no-commit"});
    w.rep.check("the place is free: the sixth set is now staged", freed.code == 0 and h.contains(freed.stdout, "staged group grp_"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ freed.code, freed.stdout, freed.stderr }));

    // An abort of a group that already ended (here: aborted from another directory's copy of the state) is not a failure of the failure job.
    const copy = try w.dir("slot_1_copy");
    try std.fs.cwd().makePath(copy);
    try h.writeFile(try h.join(a, &.{ copy, "plan.json" }), try h.readFile(a, try h.join(a, &.{ dirs[1], "plan.json" })));
    try h.writeFile(try h.join(a, &.{ copy, "state.json" }), try h.readFile(a, try h.join(a, &.{ dirs[1], "state.json" })));
    const from_copy = try w.publish(copy, &.{"--abort"});
    w.rep.check("--abort reads plan.json and state.json only: a directory without the set's files ends the group", from_copy.code == 0 and std.mem.eql(u8, try groupStatus(w, ids[1]), "aborted"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ from_copy.code, from_copy.stdout, from_copy.stderr }));
    const ended = try w.publish(dirs[1], &.{"--abort"});
    w.rep.check("--abort of a group that is already aborted ends 0 again", ended.code == 0 and std.mem.eql(u8, try groupStatus(w, ids[1]), "aborted"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ ended.code, ended.stdout, ended.stderr }));

    // Leave no group open for the scenarios that follow (an actor holds at most five).
    for (dirs[2..]) |d| _ = try w.publish(d, &.{"--abort"});
    _ = try w.publish(sixth, &.{"--abort"});
}

/// A staged group left open past its deadline is ended by the registry; the resume says so, sends nothing, and keeps state.json.
fn aStagedGroupThatExpired(w: World) !void {
    const a = w.a;
    const staged = try w.dir("staged_expired");
    const members = chain("5.0.0", "the bytes of b");
    try stage(a, staged, &members);
    const r = try w.publish(staged, &.{"--no-commit"});
    const id = try w.groupId(staged);
    w.rep.check("a set is staged", r.code == 0 and id.len > 0, try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    _ = try w.fake.control(a, "/clock", "{\"advance_seconds\":46800}");
    const before = try w.uploads();
    const again = try w.publish(staged, &.{});
    w.rep.check("a resume after the group expired ends 1, names the group and its status, and says nothing was sent", again.code == 1 and h.contains(again.stderr, "staged by an earlier run, is expired") and
        h.contains(again.stderr, id) and h.contains(again.stderr, "nothing was sent") and h.contains(again.stderr, "stage the set again"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ again.code, again.stdout, again.stderr }));
    w.rep.check("the group was not opened again and nothing is served", std.mem.eql(u8, try groupStatus(w, id), "expired") and (try w.visible("5.0.0")) == 0 and (try w.uploads()) == before, "the registry was changed");
    w.rep.check("state.json still names the group", std.mem.eql(u8, try w.groupId(staged), id), "the state was changed");
    const gone = try w.publish(staged, &.{"--abort"});
    w.rep.check("--abort of the expired group ends 0 and says it is already ended", gone.code == 0 and h.contains(gone.stdout, "already expired: nothing is held"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ gone.code, gone.stdout, gone.stderr }));
}

/// A group that was committed cannot be staged again, aborted, or mistaken for a staged one.
fn refusalsOfStaging(w: World) !void {
    const a = w.a;
    const staged = try w.dir("staged_refused");
    const members = chain("6.0.0", "the bytes of b");
    try stage(a, staged, &members);
    var r = try w.m.run(&.{ "publish", "--staged", staged, "--registry", dead, "--abort", "--no-commit" }, null);
    w.rep.check("--abort with --no-commit is a usage error", r.code == 2 and h.contains(r.stderr, "--abort ends a group and --no-commit stages one"), r.stderr);
    r = try w.m.run(&.{ "publish", "--staged", staged, "--registry", dead, "--abort", "--dry-run" }, null);
    w.rep.check("--abort with --dry-run is a usage error", r.code == 2 and h.contains(r.stderr, "--abort cannot be a --dry-run"), r.stderr);
    r = try w.m.run(&.{ "publish", "--staged", staged, "--registry", dead, "--config-dir", w.conf, "--no-commit", "--dry-run" }, null);
    w.rep.check("--no-commit --dry-run says it would stop with the group open, and sends nothing", r.code == 0 and h.contains(r.stdout, "stop with the group open") and !exists(try h.join(a, &.{ staged, "state.json" })), r.stdout);
    r = try w.publish(staged, &.{"--abort"});
    w.rep.check("--abort in a directory that was never staged refuses, naming state.json, and sends nothing", r.code == 1 and h.contains(r.stderr, "has no state.json") and !exists(try h.join(a, &.{ staged, "report.json" })), r.stderr);

    // Published already: --no-commit refuses (it stages before a commit), and --abort refuses (a committed group is not aborted).
    const done = try w.publish(staged, &.{});
    w.rep.check("the set is published", done.code == 0 and try w.allIn("6.0.0", "published"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ done.code, done.stdout, done.stderr }));
    const id = try w.groupId(staged);
    r = try w.publish(staged, &.{"--no-commit"});
    w.rep.check("--no-commit on a published set is refused and publishes nothing new", r.code == 1 and h.contains(r.stderr, "not open: --no-commit stages a group before its commit"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    r = try w.publish(staged, &.{"--abort"});
    w.rep.check("--abort on a published group is refused, points at yank, and the set stays published", r.code == 1 and h.contains(r.stderr, "it was committed, so it cannot be aborted") and
        h.contains(r.stderr, "mopm yank --group") and try w.allIn("6.0.0", "published") and std.mem.eql(u8, try w.groupId(staged), id), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));

    // A state of another plan is refused by --abort as by every other run.
    const other = try w.dir("staged_other_plan");
    const m2 = chain("6.1.0", "the bytes of b");
    try stage(a, other, &m2);
    try h.writeFile(try h.join(a, &.{ other, "state.json" }), try std.fmt.allocPrint(a, "{{\"registry\":\"{s}/api/v1\",\"plan_sha256\":\"{s}\",\"group_id\":\"{s}\"}}", .{ w.fake.base, "0" ** 64, id }));
    r = try w.publish(other, &.{"--abort"});
    w.rep.check("--abort with a state.json of another plan is refused, and the group it names is untouched", r.code == 1 and h.contains(r.stderr, "belongs to another plan") and std.mem.eql(u8, try groupStatus(w, id), "visible"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
}

fn exists(path: []const u8) bool {
    return if (std.fs.cwd().access(path, .{})) true else |_| false;
}

// ------------------------------------------------------------------- the test

test "mopm publish --staged and mopm yank --group against the fake registry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report = h.Report{};
    try h.watchdog(180);
    const mopm_exe = try h.toolPath(a, "MOPM");
    const fake_exe = try h.toolPath(a, "MOPM_FAKE_REGISTRY");
    const probe = try h.toolPath(a, "MOPM_ENV_PROBE");
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

    // An account that owns the three names, and a token that may publish and yank them.
    const session = h.jsonString(try fake.control(a, "/session", "{\"handle\":\"group-user\"}"), "token") orelse "";
    for (names) |n| {
        const r = try h.request(a, "POST", fake.base, try std.fmt.allocPrint(a, "/api/v1/packages/{s}/claim", .{n}), "{}", session);
        report.check(try std.fmt.allocPrint(a, "{s} is claimed", .{n}), r.status == 201, r.body);
    }
    const made = try h.request(a, "POST", fake.base, "/api/v1/me/tokens", "{\"name\":\"e2e\",\"scopes\":[\"publish\",\"yank\"],\"packages\":[\"grp_a\",\"grp_b\",\"grp_c\"],\"expires_in_days\":7}", session);
    const token = if (made.status == 201) (h.jsonString(try h.parseJson(a, made.body), "token") orelse "") else "";
    report.check("an API token that may publish and yank the three is made", token.len > 0, made.body);

    const w = World{ .a = a, .rep = &report, .m = m, .fake = fake, .fake_dir = fake_dir, .work = work, .conf = try h.join(a, &.{ work, "conf" }), .token = token };
    try publishAChain(w);
    try aRejectedMember(w);
    try anExpiredGroup(w);
    try stageThenCommit(w);
    try abortFreesThePlace(w);
    try aStagedGroupThatExpired(w);
    try refusalsOfStaging(w);
    try aFailedPutThenARerun(w);
    try transientFailuresAreRetried(w);
    try noGroupPublish(w);
    try rateLimited(w);
    try theTokenIsInNoChildEnvironment(w, probe);
    try theTokenIsInNoTestOrInstallerEnvironment(w, probe);
    try yankAndUnyank(w);
    try refusalsBeforeAnyRequest(w);

    var leaked = false;
    for ([_][]const u8{ token, session }) |s| {
        if (s.len > 0 and h.contains(everything.items, s)) leaked = true;
    }
    report.check("no token is ever printed", !leaked, "a token was printed");
    try report.finish();
}
