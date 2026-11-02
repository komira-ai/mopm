//! The client of the fake registry and the recipes of the replay
//! (`build`): how to put a fresh fake in the state a case describes and which
//! request to send. The list of recipes is replay_table.zig; the assertions
//! about the live answer are replay_checks.zig. Used by replay_test.zig.

const std = @import("std");
const h = @import("harness.zig");
const c = @import("contract.zig");
const tbl = @import("replay_table.zig");
const gc = @import("replay_group_conflicts.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const Step = tbl.Step;
const Entry = tbl.Entry;

// ------------------------------------------------------------ the client

pub const Rsp = struct { status: u16, headers: Value, body: ?Value };

const BUILD = "mojo1.0.0_0";
const YANK_BODY = "{\"yanked\":true,\"reason\":\"crashes on empty body\"}";
pub const YANK_REASON = "crashes on empty body";
const TOKEN_BODY = "{\"name\":\"ci\",\"scopes\":[\"publish\",\"yank\"],\"packages\":[\"http_client\",\"http_core\"],\"expires_in_days\":90}";
const TOKEN_BODY_ALL = "{\"name\":\"ci\",\"scopes\":[\"publish\",\"yank\"],\"packages\":\"all_current\",\"expires_in_days\":90}";

pub const F = struct {
    a: Allocator,
    base: []const u8,
    handles: usize = 0,
    names: usize = 0,
    ids: std.StringHashMap(i64),

    pub fn init(a: Allocator, base: []const u8) F {
        return .{ .a = a, .base = base, .ids = std.StringHashMap(i64).init(a) };
    }

    pub fn fmt(self: *F, comptime f: []const u8, args: anytype) ![]u8 {
        return std.fmt.allocPrint(self.a, f, args);
    }

    pub fn json(self: *F, comptime f: []const u8, args: anytype) !Value {
        return c.parseJson(self.a, try self.fmt(f, args));
    }

    pub fn emptyObject(self: *F) Value {
        return .{ .object = std.json.ObjectMap.init(self.a) };
    }

    /// One request; the body is JSON. `path` carries any query string.
    pub fn req(self: *F, method: []const u8, path: []const u8, body: ?[]const u8, token: ?[]const u8) !Rsp {
        const r = try h.requestFull(self.a, method, self.base, path, body, token, "application/json", &.{});
        return .{
            .status = r.status,
            .headers = try parseHeaders(self.a, r.head),
            .body = if (r.body.len == 0) null else try c.parseJson(self.a, r.body),
        };
    }

    pub fn control(self: *F, path: []const u8, body: []const u8) !Value {
        const r = try self.req("POST", try self.fmt("/_fake{s}", .{path}), body, null);
        if (r.status != 200) {
            std.debug.print("control {s} failed: {d}\n", .{ path, r.status });
            return error.ControlFailed;
        }
        return r.body orelse .null;
    }

    /// A new GitHub account; its handle.
    pub fn user(self: *F) ![]const u8 {
        self.handles += 1;
        const handle = try self.fmt("user-{d}", .{self.handles});
        const out = try self.control("/users", try self.fmt("{{\"handle\":\"{s}\"}}", .{handle}));
        try self.ids.put(handle, c.getInt(out, "github_id") orelse return error.NoGithubId);
        return handle;
    }

    /// A session token for `handle` (a new account if null).
    pub fn session(self: *F, handle: ?[]const u8, fresh: bool) ![]const u8 {
        const who = handle orelse try self.user();
        const out = try self.control("/session", try self.fmt("{{\"handle\":\"{s}\",\"fresh\":{s}}}", .{ who, if (fresh) "true" else "false" }));
        return c.getStr(out, "token") orelse error.NoSessionToken;
    }

    /// Creates an API token with `session`; the createToken answer.
    pub fn apiToken(self: *F, session_token: []const u8, scopes: []const u8, packages: []const u8, days: i64) !Value {
        const body = try self.fmt("{{\"name\":\"ci\",\"scopes\":{s},\"packages\":{s},\"expires_in_days\":{d}}}", .{ scopes, packages, days });
        const r = try self.req("POST", "/api/v1/me/tokens", body, session_token);
        if (r.status != 201) {
            std.debug.print("could not create a token: {d}\n", .{r.status});
            return error.TokenNotCreated;
        }
        return r.body orelse .null;
    }

    pub fn name(self: *F, prefix: []const u8) ![]const u8 {
        self.names += 1;
        return self.fmt("{s}{d}", .{ prefix, self.names });
    }

    pub fn claim(self: *F, session_token: []const u8, pkg: []const u8) !void {
        const r = try self.req("POST", try self.fmt("/api/v1/packages/{s}/claim", .{pkg}), null, session_token);
        if (r.status != 201) {
            std.debug.print("could not claim {s}: {d}\n", .{ pkg, r.status });
            return error.ClaimFailed;
        }
    }

    /// Invites `handle` to own `pkg`; the invitation id.
    pub fn invite(self: *F, session_token: []const u8, pkg: []const u8, handle: []const u8) ![]const u8 {
        const r = try self.req("PUT", try self.fmt("/api/v1/packages/{s}/owners", .{pkg}), try self.fmt("{{\"handle\":\"{s}\"}}", .{handle}), session_token);
        if (r.status != 202) {
            std.debug.print("could not invite {s}: {d}\n", .{ handle, r.status });
            return error.InviteFailed;
        }
        return c.getStr(r.body orelse .null, "id") orelse error.NoInvitationId;
    }

    pub fn deviceStart(self: *F) !Value {
        const r = try self.req("POST", "/api/v1/auth/device", "{\"client\":\"mopm 0.0.1\"}", null);
        return r.body orelse .null;
    }

    /// A package claimed by a new account.
    pub fn claimed(self: *F) !Claimed {
        const handle = try self.user();
        const s = try self.session(handle, true);
        const pkg = try self.name("pkg");
        try self.claim(s, pkg);
        return .{ .handle = handle, .session = s, .name = pkg };
    }

    pub fn fetch(self: *F, path: []const u8) ![]u8 {
        const r = try h.requestFull(self.a, "GET", self.base, path, null, null, "application/json", &.{});
        if (r.status != 200) {
            std.debug.print("GET {s}: {d}\n", .{ path, r.status });
            return error.FetchFailed;
        }
        return r.body;
    }

    pub fn statusOf(self: *F, path: []const u8) !u16 {
        const r = try h.requestFull(self.a, "GET", self.base, path, null, null, "application/json", &.{});
        return r.status;
    }
};

pub const Claimed = struct { handle: []const u8, session: []const u8, name: []const u8 };

fn parseHeaders(a: Allocator, head: []const u8) !Value {
    var out = std.json.ObjectMap.init(a);
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // the status line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = try std.ascii.allocLowerString(a, line[0..colon]);
        try out.put(key, .{ .string = std.mem.trim(u8, line[colon + 1 ..], " ") });
    }
    return .{ .object = out };
}

fn sha256Hex(a: Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

fn b64(a: Allocator, raw: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try a.alloc(u8, enc.calcSize(raw.len));
    _ = enc.encode(out, raw);
    return out;
}

/// A CI identity token as the fake reads it: three base64url parts, the
/// middle one carrying the repository claim.
fn jwt(f: *F, repository: []const u8) ![]u8 {
    const claims = try f.fmt("{{\"repository\":\"{s}\",\"workflow_ref\":\"{s}/.github/workflows/release.yml\"}}", .{ repository, repository });
    return f.fmt("{s}.{s}.{s}", .{ try b64(f.a, "{\"alg\":\"RS256\"}"), try b64(f.a, claims), try b64(f.a, "signature") });
}

// -------------------------------------------------------------- publishing

pub const Release = struct {
    f: *F,
    owner: []const u8,
    session: []const u8,
    name: []const u8,
    token: []const u8,

    pub fn init(f: *F) !Release {
        const cl = try f.claimed();
        const pkgs = try f.fmt("[\"{s}\"]", .{cl.name});
        const tok = try f.apiToken(cl.session, "[\"publish\",\"yank\"]", pkgs, 30);
        return .{ .f = f, .owner = cl.handle, .session = cl.session, .name = cl.name, .token = c.getStr(tok, "token") orelse return error.NoToken };
    }

    pub fn filename(r: Release, version: []const u8) ![]u8 {
        return r.f.fmt("mojo-{s}-{s}-{s}.conda", .{ r.name, version, BUILD });
    }

    pub fn beginBody(r: Release, version: []const u8, data: []const u8, subdir: []const u8, file: ?[]const u8, size: ?usize) ![]u8 {
        return r.f.fmt("{{\"subdir\":\"{s}\",\"filename\":\"{s}\",\"size\":{d},\"sha256\":\"{s}\"}}", .{
            subdir,
            file orelse try r.filename(version),
            size orelse data.len,
            try sha256Hex(r.f.a, data),
        });
    }

    /// Begins an upload and, unless `put` is false, PUTs the bytes; the upload id.
    pub fn upload(r: Release, version: []const u8, data: []const u8, put: bool, subdir: []const u8, file: ?[]const u8) ![]const u8 {
        const files_path = try r.f.fmt("/api/v1/packages/{s}/{s}/files", .{ r.name, version });
        const rsp = try r.f.req("POST", files_path, try r.beginBody(version, data, subdir, file, null), r.token);
        if (rsp.status != 200) {
            std.debug.print("beginUpload answered {d}\n", .{rsp.status});
            return error.BeginFailed;
        }
        const out = rsp.body orelse return error.BeginFailed;
        if (put) {
            const url = c.getStr(out, "put_url") orelse return error.NoPutUrl;
            const scheme = "http://";
            if (!std.mem.startsWith(u8, url, scheme)) return error.PutUrlNotHttp;
            const slash = std.mem.indexOfScalarPos(u8, url, scheme.len, '/') orelse url.len;
            var headers = std.ArrayList(h.Header).init(r.f.a);
            if (c.get(out, "put_headers")) |ph| {
                if (ph == .object) {
                    var it = ph.object.iterator();
                    while (it.next()) |e| {
                        if (e.value_ptr.* == .string) try headers.append(.{ .name = e.key_ptr.*, .value = e.value_ptr.*.string });
                    }
                }
            }
            const put_rsp = try h.requestFull(r.f.a, "PUT", url[0..slash], url[slash..], data, null, "application/x-www-form-urlencoded", headers.items);
            if (put_rsp.status != 200) {
                std.debug.print("the PUT answered {d}\n", .{put_rsp.status});
                return error.PutFailed;
            }
        }
        return c.getStr(out, "upload_id") orelse error.NoUploadId;
    }

    pub fn commitBody(r: Release, ids: []const []const u8) ![]u8 {
        var list = std.ArrayList(u8).init(r.f.a);
        for (ids, 0..) |id, i| {
            if (i != 0) try list.append(',');
            try list.writer().print("\"{s}\"", .{id});
        }
        return r.f.fmt("{{\"upload_ids\":[{s}],\"manifest_sha256\":\"{s}\"}}", .{ list.items, try sha256Hex(r.f.a, "manifest") });
    }

    pub fn commit(r: Release, version: []const u8, ids: []const []const u8) ![]const u8 {
        const publish_path = try r.f.fmt("/api/v1/packages/{s}/{s}/publish", .{ r.name, version });
        const rsp = try r.f.req("POST", publish_path, try r.commitBody(ids), r.token);
        if (rsp.status != 202) {
            std.debug.print("commitPublish answered {d}\n", .{rsp.status});
            return error.CommitFailed;
        }
        return c.getStr(rsp.body orelse .null, "publish_id") orelse error.NoPublishId;
    }

    pub fn poll(r: Release, publish_id: []const u8, times: usize) !Value {
        var out: Value = .null;
        var i: usize = 0;
        while (i < times) : (i += 1) {
            const rsp = try r.f.req("GET", try r.f.fmt("/api/v1/publishes/{s}", .{publish_id}), null, r.token);
            if (rsp.status != 200) return error.PollFailed;
            out = rsp.body orelse .null;
        }
        return out;
    }

    pub fn publish(r: Release, version: []const u8, data: []const u8) !void {
        const up = try r.upload(version, data, true, "linux-64", null);
        const pid = try r.commit(version, &.{up});
        const out = try r.poll(pid, 4);
        if (!std.mem.eql(u8, c.getStr(out, "status") orelse "", "published")) {
            std.debug.print("{s} {s} did not publish\n", .{ r.name, version });
            return error.NotPublished;
        }
    }

    pub fn path(r: Release, version: []const u8) !Value {
        return r.f.json("{{\"name\":\"{s}\",\"version\":\"{s}\"}}", .{ r.name, version });
    }

    pub fn yankPath(r: Release, version: []const u8) ![]u8 {
        return r.f.fmt("/api/v1/packages/{s}/{s}/yank", .{ r.name, version });
    }
};

// ------------------------------------------------------------------ groups

/// One account that owns `names.len` packages and a token that may publish and yank them: the caller of a group.
pub const Grp = struct {
    f: *F,
    session: []const u8,
    token: []const u8,
    names: []const []const u8,
    /// The first member's bytes: a marker the fake reads as a rejection, or its ordinary bytes.
    reject: ?[]const u8 = null,

    pub fn init(f: *F, count: usize) !Grp {
        const handle = try f.user();
        const session = try f.session(handle, true);
        var names = std.ArrayList([]const u8).init(f.a);
        var quoted = std.ArrayList(u8).init(f.a);
        for (0..count) |i| {
            const pkg = try f.name("grp");
            try f.claim(session, pkg);
            try names.append(pkg);
            if (i != 0) try quoted.append(',');
            try quoted.writer().print("\"{s}\"", .{pkg});
        }
        const tok = try f.apiToken(session, "[\"publish\",\"yank\"]", try f.fmt("[{s}]", .{quoted.items}), 30);
        return .{ .f = f, .session = session, .token = c.getStr(tok, "token") orelse return error.NoToken, .names = names.items };
    }

    pub fn data(g: Grp, i: usize) ![]const u8 {
        if (i == 0) {
            if (g.reject) |r| return r;
        }
        return g.f.fmt("conda bytes of {s}", .{g.names[i]});
    }

    /// The create request for `version` of every member.
    pub fn body(g: Grp, version: []const u8) ![]u8 {
        var out = std.ArrayList(u8).init(g.f.a);
        try out.appendSlice("{\"members\":[");
        for (g.names, 0..) |n, i| {
            if (i != 0) try out.append(',');
            const bytes = try g.data(i);
            try out.writer().print(
                "{{\"name\":\"{s}\",\"version\":\"{s}\",\"files\":[{{\"subdir\":\"linux-64\",\"filename\":\"mojo-{s}-{s}-{s}.conda\",\"sha256\":\"{s}\",\"size\":{d}}}]}}",
                .{ n, version, n, version, BUILD, try sha256Hex(g.f.a, bytes), bytes.len },
            );
        }
        try out.appendSlice("]}");
        return out.items;
    }

    pub fn commitBody(g: Grp) ![]u8 {
        var out = std.ArrayList(u8).init(g.f.a);
        try out.appendSlice("{\"members\":[");
        for (g.names, 0..) |n, i| {
            if (i != 0) try out.append(',');
            try out.writer().print("{{\"name\":\"{s}\",\"manifest_sha256\":\"{s}\"}}", .{ n, try sha256Hex(g.f.a, "manifest") });
        }
        try out.appendSlice("]}");
        return out.items;
    }

    /// Creates the group; its id. `uploaded`: the bytes are PUT as well.
    pub fn create(g: Grp, version: []const u8, uploaded: bool) ![]const u8 {
        const rsp = try g.f.req("POST", "/api/v1/groups", try g.body(version), g.token);
        if (rsp.status != 201 and rsp.status != 200) {
            std.debug.print("createGroup answered {d}\n", .{rsp.status});
            return error.CreateFailed;
        }
        const out = rsp.body orelse return error.CreateFailed;
        if (uploaded) {
            for (c.getArr(out, "members")) |m| {
                const i = try gc.memberIndex(g.names, m);
                for (c.getArr(m, "files")) |file| try g.put(file, try g.data(i));
            }
        }
        return c.getStr(out, "group_id") orelse error.NoGroupId;
    }

    fn put(g: Grp, file: Value, bytes: []const u8) !void {
        const url = c.getStr(file, "put_url") orelse return;
        const scheme = "http://";
        if (!std.mem.startsWith(u8, url, scheme)) return error.PutUrlNotHttp;
        const slash = std.mem.indexOfScalarPos(u8, url, scheme.len, '/') orelse url.len;
        var headers = std.ArrayList(h.Header).init(g.f.a);
        if (c.get(file, "put_headers")) |ph| {
            if (ph == .object) {
                var it = ph.object.iterator();
                while (it.next()) |e| {
                    if (e.value_ptr.* == .string) try headers.append(.{ .name = e.key_ptr.*, .value = e.value_ptr.*.string });
                }
            }
        }
        const r = try h.requestFull(g.f.a, "PUT", url[0..slash], url[slash..], bytes, null, "application/x-www-form-urlencoded", headers.items);
        if (r.status != 200) return error.PutFailed;
    }

    pub fn commit(g: Grp, id: []const u8) !u16 {
        return (try g.f.req("POST", try g.f.fmt("/api/v1/groups/{s}/commit", .{id}), try g.commitBody(), g.token)).status;
    }

    /// `times` reads of the group; the last answer. Each moves the group one stage.
    pub fn poll(g: Grp, id: []const u8, times: usize) !Value {
        var out: Value = .null;
        for (0..times) |_| {
            const rsp = try g.f.req("GET", try g.f.fmt("/api/v1/groups/{s}", .{id}), null, g.token);
            if (rsp.status != 200) return error.PollFailed;
            out = rsp.body orelse .null;
        }
        return out;
    }

    /// A group created, uploaded, committed and polled until it is visible.
    pub fn visible(g: Grp, version: []const u8) ![]const u8 {
        const id = try g.create(version, true);
        if (try g.commit(id) != 202) return error.CommitFailed;
        _ = try g.poll(id, 3);
        return id;
    }

    pub fn path(g: Grp, id: []const u8) !Value {
        return g.f.json("{{\"group_id\":\"{s}\"}}", .{id});
    }

    pub fn yankPath(g: Grp, id: []const u8) ![]u8 {
        return g.f.fmt("/api/v1/groups/{s}/yank", .{id});
    }
};

fn groupStep(g: Grp, op: []const u8, id: []const u8) !Step {
    var s = step(op);
    s.path = try g.path(id);
    s.token = g.token;
    s.auth = "publishToken";
    return s;
}

fn groupRecipe(f: *F, e: Entry) !Step {
    switch (e.kind) {
        .group_create => {
            const g = try Grp.init(f, 3);
            var s = step("createGroup");
            s.body = try g.body("0.4.0");
            s.token = g.token;
            s.auth = "publishToken";
            s.check = .status_is;
            if (std.mem.eql(u8, e.arg, "new")) {
                s.args[0] = "open";
            } else if (std.mem.eql(u8, e.arg, "again")) {
                _ = try g.create("0.4.0", false);
                s.args[0] = "open";
            } else {
                _ = try g.visible("0.4.0");
                s.args[0] = "visible";
            }
            return s;
        },
        .group_get => {
            var g = try Grp.init(f, 3);
            var shown: []const u8 = "open";
            if (std.mem.eql(u8, e.arg, "rejected")) g.reject = "REJECT:archive_invalid from the replay";
            const id = try g.create("0.4.0", !std.mem.eql(u8, e.arg, "open"));
            var s = try groupStep(g, "getGroup", id);
            if (!std.mem.eql(u8, e.arg, "open")) {
                if (try g.commit(id) != 202) return error.CommitFailed;
                if (std.mem.eql(u8, e.arg, "committed")) {
                    _ = try g.poll(id, 1);
                    shown = "committed";
                } else {
                    _ = try g.poll(id, 2);
                    shown = "rejected";
                    s.check = .group_failure;
                    s.args[1] = "archive_invalid";
                }
            }
            s.args[0] = shown;
            if (s.check == .none) s.check = .status_is;
            return s;
        },
        .group_abort => {
            const g = try Grp.init(f, 2);
            const id = try g.create("0.4.0", false);
            var s = try groupStep(g, "abortGroup", id);
            s.check = .status_is;
            s.args[0] = "aborted";
            return s;
        },
        .group_commit => {
            const g = try Grp.init(f, 3);
            const id = try g.create("0.4.0", true);
            var s = try groupStep(g, "commitGroup", id);
            s.body = try g.commitBody();
            s.check = .status_is;
            if (std.mem.eql(u8, e.arg, "again")) {
                if (try g.commit(id) != 202) return error.CommitFailed;
                _ = try g.poll(id, 1);
                s.args[0] = "committed";
            } else {
                s.args[0] = "validating";
            }
            return s;
        },
        .group_yank => {
            const g = try Grp.init(f, 3);
            const id = try g.visible("0.4.0");
            var s = try groupStep(g, "yankGroup", id);
            s.auth = "yankToken";
            s.check = .group_yank_state;
            if (std.mem.eql(u8, e.arg, "yank")) {
                s.body = YANK_BODY;
                s.args[0] = "yanking";
            } else {
                // Yanked, then unyanked, and polled until the unyank has ended: nothing left to restore.
                _ = try f.req("PUT", try g.yankPath(id), YANK_BODY, g.token);
                _ = try g.poll(id, 2);
                _ = try f.req("PUT", try g.yankPath(id), "{\"yanked\":false}", g.token);
                _ = try g.poll(id, 2);
                s.body = "{\"yanked\":false}";
                s.args[0] = "restored";
            }
            return s;
        },
        .group_error => {
            if (std.mem.eql(u8, e.arg, "not_found")) {
                const g = try Grp.init(f, 1);
                return groupStep(g, "getGroup", "grp_00000000000000000000000000000000");
            }
            if (std.mem.eql(u8, e.arg, "conflict")) return gc.openCap(f);
            if (std.mem.eql(u8, e.arg, "overlap_refused")) return gc.overlapRefused(f);
            const g = try Grp.init(f, 2);
            const id = try g.create("0.4.0", true);
            if (std.mem.eql(u8, e.arg, "not_open")) {
                if (try g.commit(id) != 202) return error.CommitFailed;
                return groupStep(g, "abortGroup", id);
            }
            if (std.mem.eql(u8, e.arg, "commit_refused")) {
                _ = try f.req("DELETE", try f.fmt("/api/v1/groups/{s}", .{id}), null, g.token);
                var s = try groupStep(g, "commitGroup", id);
                s.body = try g.commitBody();
                return s;
            }
            // not_settled: a group that has not committed cannot be yanked.
            var s = try groupStep(g, "yankGroup", id);
            s.auth = "yankToken";
            s.body = YANK_BODY;
            return s;
        },
        else => unreachable,
    }
}

// ----------------------------------------------------------------- recipes

pub fn step(op: []const u8) Step {
    return .{ .op = op };
}

fn pathName(f: *F, pkg: []const u8) !Value {
    return f.json("{{\"name\":\"{s}\"}}", .{pkg});
}

fn claimStep(f: *F, pkg: []const u8, body: ?[]const u8) !Step {
    var s = step("claimPackage");
    s.path = try pathName(f, pkg);
    s.body = body;
    s.token = try f.session(null, true);
    s.auth = "userToken";
    return s;
}

fn status(f: *F, polls_before: usize, data: []const u8, file: ?[]const u8, want: ?[]const u8) !Step {
    const r = try Release.init(f);
    const up = try r.upload("0.4.0", data, true, "linux-64", file);
    const pid = try r.commit("0.4.0", &.{up});
    if (polls_before != 0) _ = try r.poll(pid, polls_before);
    var s = step("getPublishStatus");
    s.path = try f.json("{{\"publish_id\":\"{s}\"}}", .{pid});
    s.token = r.token;
    s.auth = "publishToken";
    if (want) |w| {
        s.check = .status_is;
        s.args[0] = w;
    }
    return s;
}

pub fn build(f: *F, e: Entry) !Step {
    switch (e.kind) {
        .health => return step("getHealth"),
        .health_read_only => {
            _ = try f.control("/mode", "{\"read_only\":true}");
            var s = step("getHealth");
            s.check = .read_only;
            s.after = .read_only_off;
            return s;
        },
        .device_start => {
            var s = step("startDeviceLogin");
            s.body = "{\"client\":\"mopm 0.0.1\"}";
            return s;
        },
        .poll => {
            const start = try f.deviceStart();
            const code = c.getStr(start, "user_code") orelse "";
            if (std.mem.eql(u8, e.arg, "approve") or std.mem.eql(u8, e.arg, "deny")) {
                const who = try f.user();
                _ = try f.control("/device", try f.fmt("{{\"user_code\":\"{s}\",\"decision\":\"{s}\",\"handle\":\"{s}\"}}", .{ code, e.arg, who }));
            }
            if (std.mem.eql(u8, e.arg, "expire")) _ = try f.control("/clock", "{\"advance_seconds\":601}");
            var s = step("pollDeviceLogin");
            s.body = try f.fmt("{{\"device_code\":\"{s}\"}}", .{c.getStr(start, "device_code") orelse ""});
            return s;
        },
        .device_unknown => {
            var s = step("pollDeviceLogin");
            s.body = "{\"device_code\":\"0000000000000000000000000000000000000000\"}";
            return s;
        },
        .me_no_token => return step("getMe"),
        .me_unknown_token => {
            var s = step("getMe");
            s.token = "mopm_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
            s.auth = "userToken";
            return s;
        },
        .me_expired => {
            const tok = try f.apiToken(try f.session(null, true), "[\"publish\"]", "[\"http_client\"]", 1);
            _ = try f.control("/clock", "{\"advance_seconds\":172800}");
            var s = step("getMe");
            s.token = c.getStr(tok, "token");
            s.auth = "userToken";
            return s;
        },
        .me_revoked => {
            const sess = try f.session(null, true);
            const created = try f.apiToken(sess, "[\"publish\"]", "[\"http_client\"]", 30);
            const r = try f.req("DELETE", try f.fmt("/api/v1/me/tokens/{s}", .{c.getStr(created, "id") orelse ""}), null, sess);
            if (r.status != 204) return error.RevokeFailed;
            var s = step("getMe");
            s.token = c.getStr(created, "token");
            s.auth = "userToken";
            return s;
        },
        .me => {
            var s = step("getMe");
            s.token = try f.session(null, true);
            s.auth = "userToken";
            return s;
        },
        .token_stale, .token_named, .token_all => {
            var s = step("createToken");
            s.body = if (e.kind == .token_all) TOKEN_BODY_ALL else TOKEN_BODY;
            s.token = try f.session(null, e.kind != .token_stale);
            s.auth = "freshSession";
            s.check = switch (e.kind) {
                .token_named => .packages_named,
                .token_all => .packages_all_current,
                else => .none,
            };
            return s;
        },
        .tokens_list => {
            const sess = try f.session(null, true);
            _ = try f.apiToken(sess, "[\"publish\"]", "[\"http_client\"]", 30);
            var s = step("listTokens");
            s.token = sess;
            s.auth = "freshSession";
            s.check = .tokens_listed;
            return s;
        },
        .token_revoke_unknown => {
            var s = step("revokeToken");
            s.path = try f.json("{{\"token_id\":\"tok-unknown\"}}", .{});
            s.token = try f.session(null, true);
            s.auth = "freshSession";
            return s;
        },
        .token_revoke => {
            const sess = try f.session(null, true);
            const created = try f.apiToken(sess, "[\"publish\"]", "[\"http_client\"]", 30);
            var s = step("revokeToken");
            s.path = try f.json("{{\"token_id\":\"{s}\"}}", .{c.getStr(created, "id") orelse ""});
            s.token = sess;
            s.auth = "freshSession";
            s.check = .token_gone;
            s.args[0] = sess;
            return s;
        },
        .oidc, .oidc_untrusted => {
            const owner = try f.session(null, true);
            const pkg = try f.name("pkg");
            try f.claim(owner, pkg);
            const trusted = e.kind == .oidc;
            const repo = try f.fmt("octo/{s}", .{pkg});
            if (trusted) _ = try f.control("/trusted", try f.fmt("{{\"name\":\"{s}\",\"repository\":\"{s}\"}}", .{ pkg, repo }));
            var s = step("exchangeOidcToken");
            s.body = try f.fmt("{{\"jwt\":\"{s}\",\"name\":\"{s}\",\"version\":\"0.4.0\"}}", .{ try jwt(f, repo), pkg });
            if (trusted) {
                s.check = .name_is;
                s.args[0] = pkg;
            }
            return s;
        },
        .oidc_packages => {
            const pkg: []const u8 = "ci_listed";
            const repo = try f.fmt("octo/{s}", .{pkg});
            _ = try f.control("/ci_publisher", try f.fmt("{{\"repository\":\"{s}\"}}", .{repo}));
            var s = step("exchangeOidcToken");
            s.body = try f.fmt("{{\"jwt\":\"{s}\",\"packages\":[{{\"name\":\"{s}\",\"version\":\"0.4.0\"}}]}}", .{ try jwt(f, repo), pkg });
            s.check = .first_package_is;
            s.args[0] = pkg;
            return s;
        },
        .oidc_invalid => {
            var s = step("exchangeOidcToken");
            s.body = "{\"jwt\":\"not-a-jwt\",\"name\":\"http_client\",\"version\":\"0.4.0\"}";
            return s;
        },
        .search_invalid => {
            var s = step("searchPackages");
            s.query = try f.json("{{\"cursor\":\"garbage\"}}", .{});
            return s;
        },
        .fault_search => {
            _ = try f.control("/fault", try f.fmt("{{\"operation\":\"searchPackages\",\"code\":\"{s}\"}}", .{e.arg}));
            var s = step("searchPackages");
            if (std.mem.eql(u8, e.arg, "rate_limited")) s.query = try f.json("{{\"q\":\"http\"}}", .{});
            return s;
        },
        .route_missing => {
            var s = step("getHealth");
            s.raw_path = "/api/v1/no_such_operation";
            return s;
        },
        .search_prefix => {
            const sess = try f.session(null, true);
            const prefix = try f.name("srch");
            for ([_][]const u8{ "b", "a" }) |suffix| try f.claim(sess, try f.fmt("{s}{s}", .{ prefix, suffix }));
            var s = step("searchPackages");
            s.query = try f.json("{{\"q\":\"{s}\",\"sort\":\"name\",\"limit\":20}}", .{prefix});
            s.check = .search_prefix;
            s.args[0] = prefix;
            return s;
        },
        .search_last_page => {
            const sess = try f.session(null, true);
            const prefix = try f.name("page");
            for ([_][]const u8{ "a", "b" }) |suffix| try f.claim(sess, try f.fmt("{s}{s}", .{ prefix, suffix }));
            const first = try f.req("GET", try f.fmt("/api/v1/packages?q={s}&limit=1", .{prefix}), null, null);
            const cursor = c.getStr(first.body orelse .null, "next_cursor") orelse return error.NoCursor;
            var s = step("searchPackages");
            s.query = try f.json("{{\"q\":\"{s}\",\"limit\":1,\"cursor\":\"{s}\"}}", .{ prefix, cursor });
            s.check = .search_last_page;
            s.args[0] = prefix;
            return s;
        },
        .pkg_invalid_name => {
            var s = step("getPackage");
            s.path = try pathName(f, "Http-Client");
            s.malformed = true;
            return s;
        },
        .pkg_missing => {
            var s = step("getPackage");
            s.path = try pathName(f, try f.name("nosuch"));
            return s;
        },
        .pkg_fault => {
            const cl = try f.claimed();
            _ = try f.control("/fault", "{\"operation\":\"getPackage\",\"code\":\"internal_error\"}");
            var s = step("getPackage");
            s.path = try pathName(f, cl.name);
            return s;
        },
        .pkg_info => {
            const cl = try f.claimed();
            var s = step("getPackage");
            s.path = try pathName(f, cl.name);
            if (e.arg.len != 0) {
                s.check = .package_info;
                s.args[0] = cl.handle;
            }
            return s;
        },
        .claim_reserved => return claimStep(f, "mopm", null),
        .claim_taken => return claimStep(f, (try f.claimed()).name, null),
        .claim_similar, .claim_similar_ok => {
            const cl = try f.claimed();
            const body: ?[]const u8 = if (e.kind == .claim_similar_ok) "{\"confirm_similar\":true}" else null;
            return claimStep(f, try f.fmt("{s}s", .{cl.name}), body);
        },
        .claim_plain => return claimStep(f, try f.name("pkg"), null),
        .versions, .owners => {
            var s = step(if (e.kind == .versions) "listVersions" else "listOwners");
            s.path = try pathName(f, (try f.claimed()).name);
            return s;
        },
        .invite_not_owner => {
            const cl = try f.claimed();
            var s = step("inviteOwner");
            s.path = try pathName(f, cl.name);
            s.body = try f.fmt("{{\"handle\":\"{s}\"}}", .{try f.user()});
            s.token = try f.session(null, true);
            s.auth = "freshSession";
            return s;
        },
        .invite => {
            const cl = try f.claimed();
            const handle: []const u8 = if (std.mem.eql(u8, e.arg, "ghost")) "ghost-nobody" else if (std.mem.eql(u8, e.arg, "owner")) cl.handle else try f.user();
            var s = step("inviteOwner");
            s.path = try pathName(f, cl.name);
            s.body = try f.fmt("{{\"handle\":\"{s}\"}}", .{handle});
            s.token = cl.session;
            s.auth = "freshSession";
            return s;
        },
        .remove_unknown => {
            const cl = try f.claimed();
            var s = step("removeOwner");
            s.path = try f.json("{{\"name\":\"{s}\",\"github_id\":1}}", .{cl.name});
            s.token = cl.session;
            s.auth = "freshSession";
            return s;
        },
        .remove_last => {
            const cl = try f.claimed();
            var s = step("removeOwner");
            s.path = try f.json("{{\"name\":\"{s}\",\"github_id\":{d}}}", .{ cl.name, f.ids.get(cl.handle).? });
            s.token = cl.session;
            s.auth = "freshSession";
            return s;
        },
        .remove => {
            const cl = try f.claimed();
            const invitee = try f.user();
            const inv = try f.invite(cl.session, cl.name, invitee);
            const r = try f.req("POST", try f.fmt("/api/v1/me/invitations/{s}/accept", .{inv}), null, try f.session(invitee, true));
            if (r.status != 200) return error.AcceptFailed;
            var s = step("removeOwner");
            s.path = try f.json("{{\"name\":\"{s}\",\"github_id\":{d}}}", .{ cl.name, f.ids.get(invitee).? });
            s.token = cl.session;
            s.auth = "freshSession";
            s.check = .one_owner_left;
            s.args[0] = cl.name;
            return s;
        },
        .invitations => {
            const cl = try f.claimed();
            const invitee = try f.user();
            _ = try f.invite(cl.session, cl.name, invitee);
            var s = step("listInvitations");
            s.token = try f.session(invitee, true);
            s.auth = "userToken";
            s.check = .invitations_names;
            s.args[0] = cl.name;
            return s;
        },
        .accept_unknown => {
            var s = step("acceptInvitation");
            s.path = try f.json("{{\"invitation_id\":\"inv-none\"}}", .{});
            s.token = try f.session(null, true);
            s.auth = "userToken";
            return s;
        },
        .accept => {
            const cl = try f.claimed();
            const invitee = try f.user();
            const inv = try f.invite(cl.session, cl.name, invitee);
            const expire = std.mem.eql(u8, e.arg, "expire");
            if (expire) _ = try f.control("/clock", "{\"advance_seconds\":691200}");
            var s = step("acceptInvitation");
            s.path = try f.json("{{\"invitation_id\":\"{s}\"}}", .{inv});
            s.token = try f.session(invitee, true);
            s.auth = "userToken";
            if (!expire) {
                s.check = .accepted_owner;
                s.args[0] = invitee;
            }
            return s;
        },
        .begin, .begin_too_big, .begin_read_only, .begin_limit, .begin_version => {
            const r = try Release.init(f);
            const version: []const u8 = if (e.kind == .begin_version) e.arg else "0.4.0";
            var s = step("beginUpload");
            s.token = r.token;
            s.auth = "publishToken";
            s.path = try r.path(version);
            switch (e.kind) {
                .begin_limit => {
                    // The package already holds 11 bytes and may hold 15: a file of 5 more does not fit.
                    _ = try f.control("/limits", "{\"project_bytes\":15}");
                    try r.publish("0.3.0", "conda bytes");
                    s.body = try r.beginBody("0.4.0", "12345", "linux-64", null, null);
                    s.after = .project_limit_restore;
                },
                .begin_too_big => {
                    s.body = try r.beginBody("0.4.0", "conda bytes", "linux-64", null, 60000000);
                    s.malformed = true;
                },
                .begin_read_only => {
                    s.body = try r.beginBody("0.4.0", "conda bytes", "linux-64", null, null);
                    _ = try f.control("/mode", "{\"read_only\":true}");
                    s.after = .read_only_off;
                },
                .begin_version => {
                    s.body = try r.beginBody(version, "conda bytes", "linux-64", null, null);
                    s.malformed = true;
                },
                else => s.body = try r.beginBody("0.4.0", "conda bytes", "linux-64", null, null),
            }
            return s;
        },
        .commit_version => {
            const r = try Release.init(f);
            var s = step("commitPublish");
            s.path = try r.path(e.arg);
            s.body = try r.commitBody(&.{"upl-none"});
            s.token = r.token;
            s.auth = "publishToken";
            s.malformed = true;
            return s;
        },
        .commit => {
            const r = try Release.init(f);
            var version: []const u8 = "0.4.0";
            var body: []const u8 = undefined;
            if (std.mem.eql(u8, e.arg, "exists")) {
                // 1.0.0 is published; the same version again is refused.
                try r.publish("1.0.0", "conda bytes");
                version = "1.0.0";
                body = try r.commitBody(&.{try r.upload("1.0.0", "conda bytes", true, "linux-64", null)});
            } else if (std.mem.eql(u8, e.arg, "used")) {
                // The version is still pending, and a different set reuses an upload.
                const first = try r.upload("0.4.0", "conda bytes", true, "linux-64", null);
                const second = try r.upload("0.4.0", "conda bytes", true, "osx-arm64", null);
                _ = try r.commit("0.4.0", &.{first});
                body = try r.commitBody(&.{ first, second });
            } else if (std.mem.eql(u8, e.arg, "not uploaded")) {
                body = try r.commitBody(&.{try r.upload("0.4.0", "conda bytes", false, "linux-64", null)});
            } else {
                const plain = try r.commitBody(&.{try r.upload("0.4.0", "conda bytes", true, "linux-64", null)});
                body = plain;
                if (std.mem.eql(u8, e.arg, "display")) {
                    body = try f.fmt("{s},\"description\":\"HTTP/1.1 client\",\"license\":\"MIT OR Apache-2.0\",\"keywords\":[\"http\",\"client\"]," ++
                        "\"repository\":\"https://github.com/example/http_client\",\"homepage\":\"https://example.com/http_client\"}}", .{plain[0 .. plain.len - 1]});
                }
            }
            var s = step("commitPublish");
            s.path = try r.path(version);
            s.body = body;
            s.token = r.token;
            s.auth = "publishToken";
            return s;
        },
        .publish_missing => {
            var s = step("getPublishStatus");
            s.path = try f.json("{{\"publish_id\":\"pub-none\"}}", .{});
            s.token = (try Release.init(f)).token;
            s.auth = "publishToken";
            return s;
        },
        .status => {
            const colon = std.mem.indexOfScalar(u8, e.arg, ':').?;
            const polls = try std.fmt.parseInt(usize, e.arg[0..colon], 10);
            return status(f, polls, "conda bytes", null, e.arg[colon + 1 ..]);
        },
        .rejected => {
            var s = if (std.mem.eql(u8, e.arg, "filename_mismatch"))
                try status(f, 2, "conda bytes", "mojo-other-9.9.9-" ++ BUILD ++ ".conda", null)
            else
                try status(f, 2, try f.fmt("REJECT:{s} from the replay", .{e.arg}), null, null);
            s.check = .rejected_with;
            s.args[0] = e.arg;
            return s;
        },
        .yank => {
            const r = try Release.init(f);
            try r.publish("0.4.0", "conda bytes");
            var s = step("setYanked");
            s.path = try r.path("0.4.0");
            s.body = YANK_BODY;
            s.token = r.token;
            s.auth = "yankToken";
            if (std.mem.eql(u8, e.arg, "scope_missing")) {
                const other = try Release.init(f);
                const pkgs = try f.fmt("[\"{s}\"]", .{other.name});
                const tok = try f.apiToken(other.session, "[\"yank\"]", pkgs, 30);
                s.body = "{\"yanked\":false}";
                s.token = c.getStr(tok, "token");
            } else if (std.mem.eql(u8, e.arg, "tombstoned")) {
                // A tombstoned version never changes state.
                _ = try f.control("/tombstone", try f.fmt("{{\"name\":\"{s}\",\"version\":\"0.4.0\",\"reason_code\":\"malware\"}}", .{r.name}));
            } else if (std.mem.eql(u8, e.arg, "unyank")) {
                _ = try f.req("PUT", try r.yankPath("0.4.0"), YANK_BODY, r.token);
                s.body = "{\"yanked\":false}";
                s.check = .unyank_state;
            } else if (std.mem.eql(u8, e.arg, "publish token")) {
                const pkgs = try f.fmt("[\"{s}\"]", .{r.name});
                const tok = try f.apiToken(r.session, "[\"publish\"]", pkgs, 30);
                s.token = c.getStr(tok, "token");
                s.auth = "publishToken";
                s.check = .state_yanked;
            } else {
                s.check = .yank_state_yanked;
            }
            return s;
        },
        .version_invalid => {
            var s = step("getVersion");
            s.path = try f.json("{{\"name\":\"{s}\",\"version\":\"1.0.0+local\"}}", .{(try f.claimed()).name});
            s.malformed = true;
            return s;
        },
        .version_missing => {
            var s = step("getVersion");
            s.path = try f.json("{{\"name\":\"{s}\",\"version\":\"9.9.9\"}}", .{(try f.claimed()).name});
            return s;
        },
        .group_create, .group_get, .group_abort, .group_commit, .group_yank, .group_error, .group_facts => return groupRecipe(f, e),
        .detail => {
            const r = try Release.init(f);
            try r.publish("0.4.0", "conda bytes");
            var s = step("getVersion");
            s.path = try r.path("0.4.0");
            if (std.mem.eql(u8, e.arg, "yanked")) {
                _ = try f.req("PUT", try r.yankPath("0.4.0"), YANK_BODY, r.token);
                s.check = .detail_yanked;
            } else if (std.mem.eql(u8, e.arg, "tombstoned")) {
                _ = try f.control("/tombstone", try f.fmt("{{\"name\":\"{s}\",\"version\":\"0.4.0\",\"reason_code\":\"malware\"}}", .{r.name}));
                s.check = .detail_tombstoned;
            } else {
                s.check = .detail_published;
            }
            return s;
        },
    }
}

