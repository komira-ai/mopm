//! The `Net` between a client and a fake registry's request handler, in one process: no socket, no child process, no clock of the
//! host. Shared by the in-process tests of the current client (group_readmes_inproc_test.zig) and of the previous release's client
//! and registry (compat_v0_0_104_test.zig), which are different types of the same shape; `Wire` is generic over both.
//!
//! `Wire(NetT, FxT, ReplyT)` is a world of one registry: `FxT` is its fixture (`setup`, `deinit`, `call`, `state`, `alice`, `life`),
//! `NetT` the client's `Net` type (a `ptr`, and a `vtable` of `request`, `sleep` and `now`), `ReplyT` what `FxT.call` answers. The
//! `Net` hands each request to the handler, records what the run sent, and keeps a clock that only `sleep` moves.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");

/// A loopback address: the client sends an upload only to https or loopback http. No socket is ever opened to it.
pub const base = "http://127.0.0.1:1";
pub const api_url = base ++ "/api/v1";

pub const Seen = struct { method: std.http.Method, path: []const u8, token: ?[]const u8, body: []const u8 };

pub fn Wire(comptime NetT: type, comptime FxT: type, comptime ReplyT: type) type {
    return struct {
        const World = @This();

        a: Allocator,
        fx: FxT = undefined,
        token: []const u8 = "big-secret",
        seen: std.ArrayList(Seen),
        clock: i64 = 1000,
        /// The next commit is applied by the registry and its answer is lost (the connection resets).
        lose_commit_answer: bool = false,

        pub fn open(a: Allocator, w: *World, names: []const []const u8) !void {
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

        pub fn close(w: *World) void {
            w.fx.deinit();
        }

        pub fn net(w: *World) NetT {
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

        pub fn get(w: *World, path: []const u8) !ReplyT {
            return w.fx.call(.GET, path, "", null);
        }

        /// The `readme` of a published version as getVersion serves it: null when the version has no such key.
        pub fn versionReadme(w: *World, name: []const u8, version: []const u8) !?[]const u8 {
            const r = try w.get(try std.fmt.allocPrint(w.a, "/api/v1/packages/{s}/{s}", .{ name, version }));
            try std.testing.expectEqual(@as(u16, 200), r.status);
            return stringKey(r.value, "readme");
        }

        pub fn packageReadme(w: *World, name: []const u8) !?[]const u8 {
            const r = try w.get(try std.fmt.allocPrint(w.a, "/api/v1/packages/{s}", .{name}));
            try std.testing.expectEqual(@as(u16, 200), r.status);
            return stringKey(r.value, "readme");
        }

        /// How many of the members `<prefix>0..` of `count` are published at `version`.
        pub fn published(w: *World, prefix: []const u8, members: usize, version: []const u8) !usize {
            var n: usize = 0;
            for (0..members) |i| {
                const r = try w.get(try std.fmt.allocPrint(w.a, "/api/v1/packages/{s}{d}/{s}", .{ prefix, i, version }));
                if (r.status == 200 and std.mem.eql(u8, stringKey(r.value, "state") orelse "", "published")) n += 1;
            }
            return n;
        }

        pub fn groupStatus(w: *World, id: []const u8) ![]const u8 {
            const r = try w.fx.call(.GET, try std.fmt.allocPrint(w.a, "/api/v1/groups/{s}", .{id}), "", w.token);
            return stringKey(r.value, "status") orelse "(none)";
        }

        pub fn seenCount(w: *World, method: std.http.Method, from: usize, suffix: []const u8) usize {
            var n: usize = 0;
            for (w.seen.items[from..]) |s| {
                if (s.method == method and std.mem.endsWith(u8, s.path, suffix)) n += 1;
            }
            return n;
        }

        pub fn lastCommit(w: *World) ?Seen {
            var i = w.seen.items.len;
            while (i > 0) {
                i -= 1;
                const s = w.seen.items[i];
                if (s.method == .POST and std.mem.endsWith(u8, s.path, "/commit")) return s;
            }
            return null;
        }
    };
}

pub fn stringKey(v: std.json.Value, key: []const u8) ?[]const u8 {
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

// ------------------------------------------------------------------ staged sets and their names

pub fn sha256Hex(a: Allocator, bytes: []const u8) ![]const u8 {
    return core.install.sha256Hex(a, bytes);
}

pub fn nameOf(a: Allocator, prefix: []const u8, i: usize) ![]u8 {
    return std.fmt.allocPrint(a, "{s}{d}", .{ prefix, i });
}

pub fn filenameOf(a: Allocator, name: []const u8, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "mojo-{s}-{s}-mojo1.0.0_0.conda", .{ name, version });
}

/// `len` bytes of text: a title line, then a line of body repeated.
pub fn readmeOf(a: Allocator, name: []const u8, len: usize) ![]u8 {
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
pub fn namesOf(a: Allocator, prefix: []const u8, count: usize) ![]const []const u8 {
    const out = try a.alloc([]const u8, count);
    for (out, 0..) |*o, i| o.* = try nameOf(a, prefix, i);
    return out;
}

/// Writes the staged directory of members `<prefix>0..`, each with one file and the readme `texts[i]` (null: none, "": empty).
pub fn stageSet(a: Allocator, dir: std.fs.Dir, prefix: []const u8, version: []const u8, texts: []const ?[]const u8) !void {
    return stageNamed(a, dir, try namesOf(a, prefix, texts.len), version, texts);
}

/// `stageSet` for members of the given names.
pub fn stageNamed(a: Allocator, dir: std.fs.Dir, names: []const []const u8, version: []const u8, texts: []const ?[]const u8) !void {
    var plan = std.ArrayList(u8).init(a);
    try plan.appendSlice("{\"version\":1,\"members\":[");
    try dir.makePath("noarch");
    for (texts, names, 0..) |text, name, i| {
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
pub fn bigTexts(a: Allocator, prefix: []const u8, count: usize, len: usize) ![]const ?[]const u8 {
    const out = try a.alloc(?[]const u8, count);
    for (out, 0..) |*o, i| o.* = try readmeOf(a, try nameOf(a, prefix, i), len);
    return out;
}

pub fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

pub fn expectContains(hay: []const u8, needle: []const u8) !void {
    try std.testing.expectEqualStrings(needle, if (contains(hay, needle)) needle else hay);
}

pub fn fileExists(dir: std.fs.Dir, path: []const u8) bool {
    dir.access(path, .{}) catch return false;
    return true;
}

pub fn withoutPublishedAt(a: Allocator, body: []const u8) ![]u8 {
    const key = "\"published_at\":\"";
    const at = std.mem.indexOf(u8, body, key) orelse return a.dupe(u8, body);
    const from = at + key.len;
    const to = std.mem.indexOfScalarPos(u8, body, from, '"') orelse return a.dupe(u8, body);
    return std.mem.concat(a, u8, &.{ body[0..from], body[to..] });
}

/// The current client (src/cli/group_publish.zig, imported as `gp`) between the check of the plan and the end.
pub fn Client(comptime gp: type) type {
    const StateT = std.meta.fieldInfo(gp.Publisher, .state).type;
    return struct {
        /// What a run did: how it ended (null when it stopped before any publisher was made) and what it said.
        pub const Ran = struct { result: ?gp.Result, out: []const u8, err: []const u8, from: usize, group_id: []const u8 };

        /// The command between the check of the plan and the end, as group_publish.zig's `command` makes it: the form of the readmes
        /// from `/health` (a group the staged directory's state.json names is resumed), then the publisher.
        pub fn run(w: anytype, dir: std.fs.Dir, no_commit: bool) !Ran {
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
    };
}

/// getVersion and getPackage readmes, the sparse-index record (the clock of each fake blanked) and the channel file of member `name`.
pub fn servedFacts(w: anytype, name: []const u8, version: []const u8) ![4][]const u8 {
    const a = w.a;
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
