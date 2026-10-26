//! //:group_e2e: tests/drivers/group_e2e.zig, the authenticated group-publish end-to-end check, run against a
//! registry that this file starts on a loopback port. The farm has no network, so the real beta and gamma are not
//! reachable from here; the registry below serves the contract's group routes (spec/api/openapi.yaml: createGroup,
//! getGroup, commitGroup, abortGroup, yankGroup), the version, the sparse index and the channel, from memory. It keeps
//! the rules the check is written to hold the real registry to: a member is readable only once its group has
//! committed, a group with one archive that is not a package ends rejected and shows none of its members, the storage
//! takes the headers the registry named and no bearer token, and the group yank moves every member.
//!
//! One test walks the whole check against a registry that does all of it right, with nothing stubbed on the client side
//! but pixi: the farm's Mojo 1.0.0 precompiles the three packages, the built CLI (MOPM) stages them, locks and installs the
//! staged set with --overlay (FAKE_PIXI stands in for pixi, which the farm lacks), the program of the app's README is built
//! with the farm's compiler and run, and `mopm publish --staged` sends the set to this registry. Each of the other tests breaks
//! one rule in the registry (or leaves a piece of the client out) and asserts that the check goes red on the line that names
//! it (or SKIPs, when that is the point). The packages the other tests need are precompiled once.

const std = @import("std");
const core = @import("mopm_core");
const h = @import("harness.zig");
const mojo_env = @import("mojo_env.zig");
const g = @import("group_e2e.zig");
const Allocator = std.mem.Allocator;

const test_token = "mopm_e2etokene2etokene2etokene2etoke";
const upload_header = "x-amz-meta-e2e";
/// The release of the first member that another run is made to have published (Mode.newer_release): a newer 1.x than any run's.
const rival_version = "1.99999999.1";
/// The release of the first member that Mode.rival_major makes another run have published: the next major.
const rival_major_version = "2.0.0";
/// The variable the stand-in compiler's programs read for the line they print (tests/drivers/fake_toolchain.zig).
const program_output_env = "FAKE_TOOLCHAIN_PROGRAM_OUTPUT";
/// An empty JSON list (an empty byte array would be written as a string).
const no_strings: []const []const u8 = &.{};

// ---- the registry ---------------------------------------------------------------------------------------------------

const Probe = enum { fresh, still_open, reopened };

/// What this registry does wrong. The default does everything right.
const Mode = struct {
    /// POST /groups is route_not_found (the stage's switch is off for this caller).
    groups_off: bool = false,
    /// POST /groups is a 404 with this error code instead (empty: not used). Only `route_not_found` means the switch is off.
    groups_404_code: []const u8 = "",
    /// A new group (not the probe) answers `reserving` this many times before it has reached every member.
    reserving_rounds: u32 = 0,
    /// The stage this registry says it is.
    stage: []const u8 = "beta",
    /// Members are readable while their group is still validating.
    leak_early: bool = false,
    /// After the commit only the first member is readable.
    half_commit: bool = false,
    /// Before the commit only the first member is readable.
    leak_first_early: bool = false,
    /// Validation takes this many milliseconds after the commit request, however often the group is read: a loaded registry.
    slow_validation_ms: u64 = 0,
    /// A good group is committed by the first read of the set's first member once its validation is done, and not by a read of the
    /// group: the commit lands between two reads of the members, as it does when a reader sweeps them one after the other.
    commit_in_sweep: bool = false,
    /// A file that is not a package is accepted.
    accept_bad: bool = false,
    /// A rejected group still shows its first member.
    reject_leaks_sibling: bool = false,
    /// The group stays `committed` and never becomes `visible`.
    stall: bool = false,
    /// The sparse index lists another sha256 for the first member.
    index_lies: bool = false,
    /// The group yank leaves the second member published.
    yank_partial: bool = false,
    /// Creating a group other than the probe is refused.
    create_refused: bool = false,
    /// The storage refuses every upload.
    storage_refuses: bool = false,
    /// The commit is refused.
    commit_refused: bool = false,
    /// The group yank is refused.
    yank_refused: bool = false,
    /// Once the set is published, the sparse index and the repodata give this member of the set (0 is the first) another size than
    /// the file uploaded, so the lock a reader makes differs from the one the staged set made.
    size_differs: ?usize = null,
    /// Another run's newer release (1.99999999.1) of the first member is already published when the set's group is created.
    newer_release: bool = false,
    /// Another run's release of the first member at the next MAJOR (2.0.0) is already published when the set's group is created, and
    /// the registry tells every dependency range of the set with no upper bound, so a reader's lock names that release.
    rival_major: bool = false,
    /// A member of the set is readable in the API from the moment the staged set has been installed, before it is published.
    shows_during_overlay: bool = false,
    /// The probe group's deadline is this many seconds after the call.
    deadline_secs: i64 = 12 * 3600,
    probe: Probe = .fresh,
};

const Dep = struct { name: []const u8, range: []const u8 };

const Member = struct {
    name: []const u8,
    version: []const u8,
    filename: []const u8,
    sha256: []const u8,
    size: u64,
    bytes: ?[]const u8 = null,
    manifest_sha256: []const u8 = "",
    deps: []const Dep = &.{},
    yanked: bool = false,
};

const Status = enum { open, validating, committed, visible, rejected, aborted };

const Grp = struct {
    id: []const u8,
    status: Status = .open,
    attempt: u64 = 1,
    members: []Member,
    created: i64,
    deadline: i64,
    polls: u32 = 0,
    /// When the commit request came (milliseconds of the clock of the process).
    committed_ms: i64 = 0,
    yank: ?[]const u8 = null,
    yank_polls: u32 = 0,
    failure_member: ?[]const u8 = null,
    reserving_left: u32 = 0,
};

fn statusName(s: Status) []const u8 {
    return @tagName(s);
}

const Stub = struct {
    mode: Mode,
    server: std.net.Server,
    base: []const u8,
    arena: std.heap.ArenaAllocator,
    groups: std.ArrayList(Grp),
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// What the registry saw, read after `stop`.
    requests: usize = 0,
    group_creates: usize = 0,
    storage_puts: usize = 0,
    storage_auth_seen: bool = false,
    storage_header_missing: bool = false,
    /// `shows_during_overlay`: set by the run once the staged set is installed.
    squatting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rival_seeded: bool = false,

    fn start(mode: Mode) !*Stub {
        const s = try std.heap.page_allocator.create(Stub);
        const address = try std.net.Address.parseIp("127.0.0.1", 0);
        s.* = .{
            .mode = mode,
            .server = try address.listen(.{ .reuse_address = true }),
            .base = "",
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .groups = undefined,
        };
        s.groups = std.ArrayList(Grp).init(s.arena.allocator());
        s.base = try std.fmt.allocPrint(s.arena.allocator(), "http://127.0.0.1:{d}", .{s.server.listen_address.getPort()});
        s.thread = try std.Thread.spawn(.{}, loop, .{s});
        return s;
    }

    fn stop(s: *Stub) void {
        s.stopping.store(true, .release);
        if (std.net.tcpConnectToAddress(s.server.listen_address)) |c| c.close() else |_| {}
        if (s.thread) |t| t.join();
        s.server.deinit();
    }

    fn loop(s: *Stub) void {
        while (true) {
            const conn = s.server.accept() catch return;
            if (s.stopping.load(.acquire)) {
                conn.stream.close();
                return;
            }
            s.serve(conn);
        }
    }

    fn serve(s: *Stub, conn: std.net.Server.Connection) void {
        defer conn.stream.close();
        var buf: [64 * 1024]u8 = undefined;
        var srv = std.http.Server.init(conn, &buf);
        while (srv.state == .ready) {
            var request = srv.receiveHead() catch return;
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            s.answer(arena.allocator(), &request) catch return;
        }
    }

    // ---- routing ----

    fn answer(s: *Stub, a: Allocator, request: *std.http.Server.Request) !void {
        s.requests += 1;
        var authorization: ?[]const u8 = null;
        var has_upload_header = false;
        var it = request.iterateHeaders();
        while (it.next()) |hd| {
            if (std.ascii.eqlIgnoreCase(hd.name, "authorization")) authorization = try a.dupe(u8, hd.value);
            if (std.ascii.eqlIgnoreCase(hd.name, upload_header)) has_upload_header = true;
        }
        const target = try a.dupe(u8, request.head.target);
        const method = request.head.method;
        const has_body = request.head.content_length != null or request.head.transfer_encoding == .chunked;
        const body = if (has_body) try (try request.reader()).readAllAlloc(a, 64 << 20) else "";
        const r = try s.route(a, method, target, body, authorization, has_upload_header);
        var headers = [_]std.http.Header{.{ .name = "content-type", .value = r.content_type }};
        try request.respond(r.body, .{ .status = r.status, .extra_headers = &headers, .keep_alive = false });
    }

    const Reply = struct { status: std.http.Status, body: []const u8, content_type: []const u8 = "application/json" };

    fn json(a: Allocator, status: std.http.Status, value: anytype) !Reply {
        return .{ .status = status, .body = try std.json.stringifyAlloc(a, value, .{ .emit_null_optional_fields = false }) };
    }

    fn fail(a: Allocator, status: std.http.Status, code: []const u8, message: []const u8) !Reply {
        return json(a, status, .{ .@"error" = .{ .code = code, .message = message, .hint = "" } });
    }

    fn route(s: *Stub, a: Allocator, method: std.http.Method, target: []const u8, body: []const u8, authorization: ?[]const u8, has_upload_header: bool) !Reply {
        const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
        const api = "/api/v1";
        if (std.mem.startsWith(u8, path, "/upload/")) return s.upload(a, method, path["/upload/".len..], body, authorization, has_upload_header);
        if (std.mem.eql(u8, path, "/index/config.json")) return s.config(a);
        if (std.mem.startsWith(u8, path, "/index/")) return s.indexFile(a, path["/index/".len..]);
        if (std.mem.startsWith(u8, path, "/channel/")) return s.channel(a, path["/channel/".len..]);
        if (!std.mem.startsWith(u8, path, api)) return fail(a, .not_found, "route_not_found", "no such route");
        const rest = path[api.len..];
        if (std.mem.eql(u8, rest, "/health") and method == .GET) {
            return json(a, .ok, .{ .status = "ok", .stage = s.mode.stage, .api_version = "v1", .read_only = false });
        }
        if (std.mem.startsWith(u8, rest, "/packages/") and method == .GET) return s.version(a, rest["/packages/".len..]);
        if (std.mem.eql(u8, rest, "/groups") and method == .POST) return s.create(a, body, authorization);
        if (std.mem.startsWith(u8, rest, "/groups/")) {
            if (!s.authorized(authorization)) return fail(a, .unauthorized, "token_invalid", "the token is not valid");
            var parts = std.mem.splitScalar(u8, rest["/groups/".len..], '/');
            const id = parts.next() orelse "";
            const sub = parts.next();
            const gi = s.find(id) orelse return fail(a, .not_found, "group_not_found", "there is no such group");
            if (sub == null and method == .GET) return s.show(a, gi);
            if (sub == null and method == .DELETE) return s.abort(a, gi);
            if (sub != null and std.mem.eql(u8, sub.?, "commit") and method == .POST) return s.commit(a, gi, body);
            if (sub != null and std.mem.eql(u8, sub.?, "yank") and method == .PUT) return s.yank(a, gi, body);
        }
        return fail(a, .not_found, "route_not_found", "no such route");
    }

    fn authorized(s: *Stub, authorization: ?[]const u8) bool {
        _ = s;
        const v = authorization orelse return false;
        return std.mem.eql(u8, v, "Bearer " ++ test_token);
    }

    fn find(s: *Stub, id: []const u8) ?usize {
        for (s.groups.items, 0..) |gr, i| {
            if (std.mem.eql(u8, gr.id, id)) return i;
        }
        return null;
    }

    // ---- groups ----

    const FileIn = struct { subdir: []const u8, filename: []const u8, sha256: []const u8, size: u64 };
    const MemberIn = struct { name: []const u8, version: []const u8, files: []const FileIn };
    const CreateIn = struct { members: []const MemberIn };

    fn create(s: *Stub, a: Allocator, body: []const u8, authorization: ?[]const u8) !Reply {
        if (!s.authorized(authorization)) return fail(a, .unauthorized, "token_invalid", "the token is not valid");
        if (s.mode.groups_off) return fail(a, .not_found, "route_not_found", "no such route");
        if (s.mode.groups_404_code.len > 0) return fail(a, .not_found, s.mode.groups_404_code, "not found");
        s.group_creates += 1;
        const sa = s.arena.allocator();
        const input = std.json.parseFromSliceLeaky(CreateIn, sa, body, .{ .ignore_unknown_fields = true }) catch return fail(a, .bad_request, "invalid_request", "not a group");
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (input.members) |m| {
            hasher.update(m.name);
            hasher.update("@");
            hasher.update(m.version);
            hasher.update(";");
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        const id = try std.fmt.allocPrint(sa, "grp_{s}", .{hex[0..32]});
        const probe = std.mem.eql(u8, input.members[0].version, g.probe_version);
        if (s.mode.create_refused and !probe) return fail(a, .conflict, "group_conflict", "the group cannot be created");
        if ((s.mode.newer_release or s.mode.rival_major) and !probe and !s.rival_seeded) try s.seedRival();
        var existing = s.find(id);
        var status: std.http.Status = .created;
        if (existing) |i| {
            if (s.groups.items[i].status == .open) status = .ok;
        } else {
            const now = std.time.timestamp();
            const members = try sa.alloc(Member, input.members.len);
            for (input.members, members) |m, *out| {
                out.* = .{ .name = try sa.dupe(u8, m.name), .version = try sa.dupe(u8, m.version), .filename = try sa.dupe(u8, m.files[0].filename), .sha256 = try sa.dupe(u8, m.files[0].sha256), .size = m.files[0].size };
            }
            var attempt: u64 = 1;
            if (probe) {
                switch (s.mode.probe) {
                    .fresh => {},
                    .still_open => status = .ok,
                    .reopened => attempt = 2,
                }
            }
            try s.groups.append(.{ .id = id, .attempt = attempt, .members = members, .created = now, .deadline = now + s.mode.deadline_secs, .reserving_left = if (probe) 0 else s.mode.reserving_rounds });
            existing = s.groups.items.len - 1;
        }
        const gr = &s.groups.items[existing.?];
        const Reserving = struct { done: u64, total: u64 };
        const still_reserving = gr.reserving_left > 0;
        if (still_reserving) gr.reserving_left -= 1;
        const Up = struct { subdir: []const u8, filename: []const u8, upload_id: []const u8, uploaded: bool, put_url: ?[]const u8 = null, put_headers: ?struct { @"x-amz-meta-e2e": []const u8 } = null };
        const Ans = struct { name: []const u8, version: []const u8, action: []const u8, files: []const Up };
        const answers = try a.alloc(Ans, gr.members.len);
        for (gr.members, answers, 0..) |m, *out, i| {
            const files = try a.alloc(Up, 1);
            const have = m.bytes != null;
            files[0] = .{
                .subdir = g.subdir,
                .filename = m.filename,
                .upload_id = try std.fmt.allocPrint(a, "up_{s}_{d}", .{ gr.id, i }),
                .uploaded = have,
                .put_url = if (have) null else try std.fmt.allocPrint(a, "{s}/upload/{s}/{d}", .{ s.base, gr.id, i }),
                .put_headers = if (have) null else .{ .@"x-amz-meta-e2e" = "1" },
            };
            out.* = .{ .name = m.name, .version = m.version, .action = "new", .files = files };
        }
        return json(a, status, .{
            .group_id = gr.id,
            .status = statusName(gr.status),
            .attempt = gr.attempt,
            .deadline_at = try rfc3339(a, gr.deadline),
            .reserving = if (still_reserving) Reserving{ .done = gr.reserving_left, .total = gr.reserving_left + 1 } else null,
            .members = answers,
        });
    }

    /// Another run's release of the first member, in a group of its own that is already visible: a newer 1.x than the set's.
    fn seedRival(s: *Stub) !void {
        const sa = s.arena.allocator();
        s.rival_seeded = true;
        const bytes = "PK stand-in package of another run\n";
        const found = try sa.alloc(Member, 1);
        const rival = if (s.mode.rival_major) rival_major_version else rival_version;
        found[0] = .{
            .name = g.pkg_core,
            .version = rival,
            .filename = try std.fmt.allocPrint(sa, "mojo-{s}-{s}-mojo1.0.0_0.conda", .{ g.pkg_core, rival }),
            .sha256 = try sa.dupe(u8, &g.sha256Hex(bytes)),
            .size = bytes.len,
            .bytes = bytes,
            .manifest_sha256 = "1" ** 64,
        };
        const now = std.time.timestamp();
        try s.groups.append(.{ .id = "grp_" ++ "0" ** 32, .status = .visible, .members = found, .created = now, .deadline = now + 3600 });
    }

    /// The size the readers of the index and the repodata are told for member `i` of a group.
    fn shownSize(s: *Stub, m: Member, i: usize) u64 {
        const at = s.mode.size_differs orelse return m.size;
        return if (at == i and !std.mem.eql(u8, m.version, rival_version) and !std.mem.eql(u8, m.version, rival_major_version)) m.size + 1 else m.size;
    }

    fn upload(s: *Stub, a: Allocator, method: std.http.Method, rest: []const u8, body: []const u8, authorization: ?[]const u8, has_upload_header: bool) !Reply {
        if (method != .PUT) return fail(a, .method_not_allowed, "route_not_found", "PUT only");
        s.storage_puts += 1;
        if (s.mode.storage_refuses) return fail(a, .forbidden, "signature_mismatch", "the storage refuses the upload");
        if (authorization != null) s.storage_auth_seen = true;
        if (!has_upload_header) {
            s.storage_header_missing = true;
            return fail(a, .forbidden, "signature_mismatch", "the signed headers are missing");
        }
        var parts = std.mem.splitScalar(u8, rest, '/');
        const id = parts.next() orelse "";
        const idx = std.fmt.parseInt(usize, parts.next() orelse "x", 10) catch return fail(a, .not_found, "route_not_found", "no such upload");
        const gi = s.find(id) orelse return fail(a, .not_found, "route_not_found", "no such upload");
        const m = &s.groups.items[gi].members[idx];
        if (body.len != m.size or !std.mem.eql(u8, &g.sha256Hex(body), m.sha256)) return fail(a, .bad_request, "invalid_request", "the bytes are not the declared file");
        m.bytes = try s.arena.allocator().dupe(u8, body);
        return .{ .status = .ok, .body = "" };
    }

    const CommitMemberIn = struct { name: []const u8, manifest_sha256: []const u8 };
    const CommitIn = struct { members: []const CommitMemberIn };

    fn commit(s: *Stub, a: Allocator, gi: usize, body: []const u8) !Reply {
        const gr = &s.groups.items[gi];
        const sa = s.arena.allocator();
        if (s.mode.commit_refused) return fail(a, .conflict, "group_commit_refused", "the group cannot be committed");
        if (gr.status != .open) return fail(a, .conflict, "group_commit_refused", "the group is not open");
        const input = std.json.parseFromSliceLeaky(CommitIn, sa, body, .{ .ignore_unknown_fields = true }) catch return fail(a, .bad_request, "invalid_request", "not a commit");
        if (input.members.len != gr.members.len) return fail(a, .conflict, "group_commit_refused", "every member is listed exactly once");
        for (gr.members) |*m| {
            if (m.bytes == null) return fail(a, .conflict, "group_commit_refused", "a file is not uploaded");
            for (input.members) |im| {
                if (std.mem.eql(u8, im.name, m.name)) m.manifest_sha256 = try sa.dupe(u8, im.manifest_sha256);
            }
        }
        gr.status = .validating;
        gr.polls = 0;
        gr.committed_ms = std.time.milliTimestamp();
        return json(a, .accepted, .{ .group_id = gr.id, .status = "validating", .attempt = gr.attempt, .status_url = try std.fmt.allocPrint(a, "/api/v1/groups/{s}", .{gr.id}) });
    }

    fn isPackage(m: Member) bool {
        return if (m.bytes) |b| b.len > 2 and std.mem.eql(u8, b[0..2], "PK") else false;
    }

    /// The dependencies a package declares: the `deps` array of the `<name>.mopm.json` in its (stored) archive.
    fn depsOf(sa: Allocator, m: Member) []const Dep {
        const b = m.bytes orelse return &.{};
        const at = std.mem.indexOf(u8, b, "{\"deps\":[") orelse return &.{};
        const end = std.mem.indexOfPos(u8, b, at, "],\"name\"") orelse return &.{};
        const text = std.fmt.allocPrint(sa, "{s}]}}", .{b[at..end]}) catch return &.{};
        const Doc = struct { deps: []const Dep };
        const doc = std.json.parseFromSliceLeaky(Doc, sa, text, .{ .ignore_unknown_fields = true }) catch return &.{};
        return doc.deps;
    }

    /// Whether the API, the index and the channel show member `i` of `gr`.
    fn shows(s: *Stub, gr: Grp, i: usize) bool {
        return switch (gr.status) {
            .committed, .visible => !(s.mode.half_commit and i > 0),
            .validating => s.mode.leak_early or (s.mode.leak_first_early and i == 0),
            .rejected => s.mode.reject_leaks_sibling and i == 0,
            else => false,
        };
    }

    /// Whether the slow validation of the mode has taken its time.
    fn validationDone(s: *Stub, gr: *const Grp) bool {
        return std.time.milliTimestamp() - gr.committed_ms >= @as(i64, @intCast(s.mode.slow_validation_ms));
    }

    /// The group is committed: its members read as published, with the dependencies their archives declare.
    fn activate(s: *Stub, gr: *Grp) void {
        const sa = s.arena.allocator();
        for (gr.members) |*m| {
            m.deps = depsOf(sa, m.*);
            if (s.mode.rival_major) {
                const open: []Dep = sa.dupe(Dep, m.deps) catch continue;
                for (open) |*d| d.range = ">=0.0.0";
                m.deps = open;
            }
        }
        gr.status = .committed;
        gr.polls = 0;
    }

    fn progress(s: *Stub, gr: *Grp) void {
        if (gr.status == .validating) {
            // Validation takes several reads of the group: a reader sees it before its commit on both sides of a read of its members.
            gr.polls += 1;
            if (gr.polls >= 5 and validationDone(s, gr)) {
                var bad: ?[]const u8 = null;
                for (gr.members) |m| {
                    if (!isPackage(m) and bad == null) bad = m.name;
                }
                if (bad != null and !s.mode.accept_bad) {
                    gr.status = .rejected;
                    gr.failure_member = bad;
                } else if (!s.mode.commit_in_sweep) {
                    activate(s, gr);
                }
            }
        } else if (gr.status == .committed) {
            gr.polls += 1;
            if (gr.polls >= 2 and !s.mode.stall) gr.status = .visible;
        }
        if (gr.yank) |y| {
            gr.yank_polls += 1;
            if (gr.yank_polls >= 1) {
                if (std.mem.eql(u8, y, "yanking")) {
                    gr.yank = "yanked";
                    for (gr.members, 0..) |*m, i| m.yanked = !(s.mode.yank_partial and i == 1);
                } else if (std.mem.eql(u8, y, "unyanking")) {
                    gr.yank = "restored";
                    for (gr.members) |*m| m.yanked = false;
                }
            }
        }
    }

    fn show(s: *Stub, a: Allocator, gi: usize) !Reply {
        const gr = &s.groups.items[gi];
        s.progress(gr);
        const Mem = struct { name: []const u8, version: []const u8, state: []const u8 };
        const mem = try a.alloc(Mem, gr.members.len);
        for (gr.members, mem, 0..) |m, *out, i| {
            const state: []const u8 = if (s.shows(gr.*, i)) (if (m.yanked) "yanked" else "published") else if (m.bytes != null) "staged" else "reserved";
            out.* = .{ .name = m.name, .version = m.version, .state = state };
        }
        const Fail = struct { code: []const u8, message: []const u8, member: ?[]const u8 };
        const Yank = struct { state: []const u8, reason: []const u8, requested_at: []const u8, yanked_members: u64 };
        var yanked: u64 = 0;
        for (gr.members) |m| {
            if (m.yanked) yanked += 1;
        }
        return json(a, .ok, .{
            .group_id = gr.id,
            .status = statusName(gr.status),
            .attempt = gr.attempt,
            .created_at = try rfc3339(a, gr.created),
            .deadline_at = try rfc3339(a, gr.deadline),
            .committed_at = if (gr.status == .committed or gr.status == .visible) try rfc3339(a, gr.created) else null,
            .failure = if (gr.status == .rejected) Fail{ .code = "archive_invalid", .message = "the archive is not a package", .member = gr.failure_member } else null,
            .member_count = gr.members.len,
            .yank = if (gr.yank) |y| Yank{ .state = y, .reason = "e2e", .requested_at = try rfc3339(a, gr.created), .yanked_members = yanked } else null,
            .members = mem,
        });
    }

    fn abort(s: *Stub, a: Allocator, gi: usize) !Reply {
        const gr = &s.groups.items[gi];
        if (gr.status == .aborted) return s.show(a, gi);
        if (gr.status != .open) return fail(a, .conflict, "group_not_open", "only an open group can be aborted");
        gr.status = .aborted;
        return s.show(a, gi);
    }

    const YankIn = struct { yanked: bool, reason: ?[]const u8 = null };

    fn yank(s: *Stub, a: Allocator, gi: usize, body: []const u8) !Reply {
        const gr = &s.groups.items[gi];
        const input = std.json.parseFromSliceLeaky(YankIn, a, body, .{ .ignore_unknown_fields = true }) catch return fail(a, .bad_request, "invalid_request", "not a yank");
        if (s.mode.yank_refused) return fail(a, .conflict, "group_not_settled", "the group is not visible");
        if (gr.status != .visible) return fail(a, .conflict, "group_not_settled", "the group is not visible");
        gr.yank = if (input.yanked) "yanking" else "unyanking";
        gr.yank_polls = 0;
        const reply = try s.show(a, gi);
        return .{ .status = .accepted, .body = reply.body };
    }

    // ---- what a reader sees ----

    fn version(s: *Stub, a: Allocator, rest: []const u8) !Reply {
        var parts = std.mem.splitScalar(u8, rest, '/');
        const name = parts.next() orelse "";
        const ver = parts.next() orelse "";
        // `commit_in_sweep`: this read finds the group still validating, and the commit lands right after it.
        var committing: ?*Grp = null;
        defer if (committing) |gr| s.activate(gr);
        if (s.mode.commit_in_sweep and std.mem.eql(u8, name, g.pkg_core)) {
            for (s.groups.items) |*gr| {
                if (gr.status == .validating and gr.polls >= 5 and validationDone(s, gr) and std.mem.eql(u8, gr.members[0].version, ver)) committing = gr;
            }
        }
        if (s.squatting.load(.acquire) and std.mem.eql(u8, name, g.pkg_mid)) {
            return json(a, .ok, .{ .name = name, .version = ver, .state = "published" });
        }
        for (s.groups.items) |gr| {
            for (gr.members, 0..) |m, i| {
                if (!s.shows(gr, i) or !std.mem.eql(u8, m.name, name) or !std.mem.eql(u8, m.version, ver)) continue;
                const Dr = struct { name: []const u8, range: []const u8 };
                const Fr = struct { subdir: []const u8, filename: []const u8, sha256: []const u8, size: u64, url: []const u8 };
                const deps = try a.alloc(Dr, m.deps.len);
                for (m.deps, deps) |d, *out| out.* = .{ .name = d.name, .range = d.range };
                const files = [_]Fr{.{ .subdir = g.subdir, .filename = m.filename, .sha256 = m.sha256, .size = m.size, .url = try s.fileUrl(a, m) }};
                return json(a, .ok, .{
                    .name = m.name,
                    .version = m.version,
                    .state = if (m.yanked) "yanked" else "published",
                    .yank_reason = if (m.yanked) @as(?[]const u8, "e2e") else null,
                    .published_at = try rfc3339(a, gr.created),
                    .requires_mojo = "==1.0.0",
                    .deps = deps,
                    .native = no_strings,
                    .files = files,
                    .manifest_sha256 = m.manifest_sha256,
                    .provenance = .{ .kind = "none" },
                });
            }
        }
        return fail(a, .not_found, "version_not_found", "there is no such version");
    }

    fn fileUrl(s: *Stub, a: Allocator, m: Member) ![]u8 {
        return std.fmt.allocPrint(a, "{s}/channel/{s}/{s}", .{ s.base, g.subdir, m.filename });
    }

    fn config(s: *Stub, a: Allocator) !Reply {
        return json(a, .ok, .{
            .api_url = try std.fmt.allocPrint(a, "{s}/api/v1", .{s.base}),
            .channel_url = try std.fmt.allocPrint(a, "{s}/channel/", .{s.base}),
            .index_version = 1,
            .min_cli_version = "0.0.1",
            .read_only = false,
            .stage = s.mode.stage,
        });
    }

    fn indexFile(s: *Stub, a: Allocator, rest: []const u8) !Reply {
        if (std.mem.eql(u8, rest, "takedowns.json")) return json(a, .ok, .{ .index_version = 1, .takedowns = no_strings });
        var parts = std.mem.splitScalar(u8, rest, '/');
        _ = parts.next();
        _ = parts.next();
        const name = parts.next() orelse "";
        var out = std.ArrayList(u8).init(a);
        for (s.groups.items) |gr| {
            for (gr.members, 0..) |m, i| {
                if (!s.shows(gr, i) or !std.mem.eql(u8, m.name, name)) continue;
                const Dr = struct { name: []const u8, range: []const u8 };
                const Fr = struct { filename: []const u8, sha256: []const u8, size: u64, subdir: []const u8, url: []const u8 };
                const deps = try a.alloc(Dr, m.deps.len);
                for (m.deps, deps) |d, *dout| dout.* = .{ .name = d.name, .range = d.range };
                const lie = s.mode.index_lies and i == 0;
                const sha = if (lie) try a.dupe(u8, "0" ** 64) else m.sha256;
                const files = [_]Fr{.{ .filename = m.filename, .sha256 = sha, .size = s.shownSize(m, i), .subdir = g.subdir, .url = try s.fileUrl(a, m) }};
                try std.json.stringify(.{
                    .build = "mojo1.0.0_0",
                    .deps = deps,
                    .files = files,
                    .manifest_sha256 = m.manifest_sha256,
                    .name = m.name,
                    .native = no_strings,
                    .provenance = .{ .kind = "none" },
                    .published_at = try rfc3339(a, gr.created),
                    .requires_mojo = "==1.0.0",
                    .state = if (m.yanked) "yanked" else "published",
                    .v = 1,
                    .version = m.version,
                    .yank_reason = if (m.yanked) @as(?[]const u8, "e2e") else null,
                }, .{ .emit_null_optional_fields = false }, out.writer());
                try out.append('\n');
            }
        }
        if (out.items.len == 0) return fail(a, .not_found, "package_not_found", "there is no such package");
        return .{ .status = .ok, .body = out.items, .content_type = "application/x-ndjson" };
    }

    fn channel(s: *Stub, a: Allocator, rest: []const u8) !Reply {
        const sub = g.subdir ++ "/";
        if (!std.mem.startsWith(u8, rest, sub)) return fail(a, .not_found, "route_not_found", "no such subdir");
        const file = rest[sub.len..];
        if (std.mem.eql(u8, file, "repodata.json")) {
            var out = std.ArrayList(u8).init(a);
            const w = out.writer();
            try w.print("{{\"info\":{{\"subdir\":\"{s}\"}},\"packages\":{{}},\"packages.conda\":{{", .{g.subdir});
            var first = true;
            for (s.groups.items) |gr| {
                for (gr.members, 0..) |m, i| {
                    if (!s.shows(gr, i) or m.yanked) continue;
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.print("\"{s}\":", .{m.filename});
                    try std.json.stringify(.{ .build = "mojo1.0.0_0", .build_number = 0, .depends = no_strings, .name = try std.fmt.allocPrint(a, "mojo-{s}", .{m.name}), .sha256 = m.sha256, .size = s.shownSize(m, i), .subdir = g.subdir, .version = m.version }, .{}, w);
                }
            }
            try w.writeAll("},\"removed\":[]}\n");
            return .{ .status = .ok, .body = out.items };
        }
        for (s.groups.items) |gr| {
            for (gr.members, 0..) |m, i| {
                if (s.shows(gr, i) and std.mem.eql(u8, m.filename, file)) return .{ .status = .ok, .body = m.bytes orelse "", .content_type = "application/octet-stream" };
            }
        }
        return fail(a, .not_found, "route_not_found", "no such file");
    }
};

fn rfc3339(a: Allocator, secs: i64) ![]const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

// ---- running the check ----------------------------------------------------------------------------------------------

var work_counter: usize = 0;
/// What every run shares: the Mojo environment, the built CLI, the stand-in pixi, and the three packages precompiled once (the walk
/// that precompiles them itself is the first test). Lives for the whole process.
///
/// Two tiers run this file. The beta tier (//:group_e2e_mojo) has the farm's Mojo 1.0.0 (MOJO_TOOLCHAIN): the compiler builds the
/// packages and the README program for real. The unit tier (//:group_e2e) has none: a stand-in `mojo` (tests/drivers/fake_toolchain.zig)
/// writes stand-in packages and a program that prints the README's line, and everything else is the same walk with the same
/// registry, CLI and checks.
const Tools = struct {
    real: ?mojo_env.Mojo,
    /// A writable directory that lives as long as the process.
    work: []const u8,
    /// The Mojo environment: bin/mojo and what it needs.
    prefix: []const u8,
    /// The stand-in compiler, when there is no real one.
    fake: []const u8,
    /// The environment of the toolchain children.
    env: *const std.process.EnvMap,
    mopm: []const u8,
    pixi: []const u8,
    prebuilt: []const u8,
};

var tools_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var tools_cache: ?Tools = null;
var tools_tmp: ?std.testing.TmpDir = null;

fn tools() !*const Tools {
    if (tools_cache) |*t| return t;
    const a = tools_arena.allocator();
    const real = std.process.hasEnvVar(a, "MOJO_TOOLCHAIN") catch false;
    var t: Tools = undefined;
    var work: []const u8 = undefined;
    if (real) {
        const m = try mojo_env.Mojo.init(a);
        work = m.work;
        t.real = m;
        t.env = &t.real.?.base;
        t.fake = "";
        t.prefix = try h.join(a, &.{ work, "env" });
        try m.prefix(t.prefix, true);
        t.mopm = try h.toolPathAbs(a, "MOPM");
        t.pixi = try h.toolPathAbs(a, "FAKE_PIXI");
    } else {
        tools_tmp = std.testing.tmpDir(.{});
        work = try h.tmpPath(a, &tools_tmp.?);
        const env = try a.create(std.process.EnvMap);
        env.* = try std.process.getEnvMap(a);
        t.real = null;
        t.env = env;
        t.fake = try h.toolPath(a, "FAKE_TOOLCHAIN");
        t.prefix = try h.join(a, &.{ work, "env" });
        try layFake(t.fake, t.prefix);
        t.mopm = try h.toolPath(a, "MOPM");
        t.pixi = try h.toolPath(a, "FAKE_PIXI");
    }
    const ws = try h.join(a, &.{ work, "prebuilt_ws" });
    const art = try h.join(a, &.{ work, "prebuilt_art" });
    try g.writeWorkspace(a, ws, "0.0.1", &g.members);
    if (try g.precompileAll(a, t.prefix, t.env, ws, art)) |why| {
        std.debug.print("precompiling the packages failed: {s}\n", .{why});
        return error.PrecompileFailed;
    }
    t.prebuilt = art;
    t.work = work;
    tools_cache = t;
    // The environment points into the cached copy, not into this frame.
    if (tools_cache.?.real != null) tools_cache.?.env = &tools_cache.?.real.?.base;
    return &tools_cache.?;
}

/// `<prefix>/bin/mojo` is the stand-in compiler.
fn layFake(fake: []const u8, prefix: []const u8) !void {
    const a = tools_arena.allocator();
    const cwd = std.fs.cwd();
    try cwd.makePath(try h.join(a, &.{ prefix, "bin" }));
    try cwd.makePath(try h.join(a, &.{ prefix, "share", "max" }));
    const dest = try h.join(a, &.{ prefix, "bin", "mojo" });
    cwd.deleteFile(dest) catch {};
    try cwd.copyFile(fake, cwd, dest, .{});
    const f = try cwd.openFile(dest, .{});
    defer f.close();
    try f.chmod(0o755);
}

/// The stand-in pixi installs packages and nothing else; the Mojo toolchain goes into the environment it made, as a pixi
/// environment holds it beside the packages.
fn layToolchain(a: Allocator, env: []const u8) anyerror!void {
    _ = a;
    const t = try tools();
    if (t.real) |m| {
        try m.prefix(env, true);
    } else {
        try layFake(t.fake, env);
    }
}

/// The registry of the run that has `shows_during_overlay`: the stand-in laid after the sync tells it the set is installed.
var squat_target: ?*Stub = null;

fn layAndSquat(a: Allocator, env: []const u8) anyerror!void {
    try layToolchain(a, env);
    if (squat_target) |s| s.squatting.store(true, .release);
}

/// One run of the check against a registry with `mode`. The result and the registry, stopped, for what it saw.
const Ran = struct { result: g.Result, stub: *Stub };

/// What a few tests change about a run: a file for the job summary, a registry that is already gone, a piece of the client that is
/// left out, and the packages precompiled by the run itself.
const Extras = struct {
    summary: ?[]const u8 = null,
    registry_down: bool = false,
    no_mopm: bool = false,
    no_pixi: bool = false,
    /// No Mojo environment is given and no packages: with a pixi and its manifest the run makes the environment, else it has none.
    no_toolchain: bool = false,
    /// The manifest the run's pixi creates the Mojo environment from.
    pixi_manifest: ?[]const u8 = null,
    /// Precompile the packages in the run (the farm's compiler), instead of using the ones built once.
    precompile: bool = false,
    /// The line the README's program prints (the stand-in compiler's programs only; the real compiler builds what the README says).
    program_says: ?[]const u8 = null,
    /// How long a read of the registry's state is repeated before it is red (`Opts.wait_ms`).
    wait_ms: u64 = 8000,
};

fn runCheck(a: Allocator, mode: Mode, token: []const u8, stage: []const u8) !Ran {
    return runCheckWith(a, mode, token, stage, .{});
}

fn runCheckWith(a: Allocator, mode: Mode, token: []const u8, stage: []const u8, extras: Extras) !Ran {
    const t = try tools();
    const stub = try Stub.start(mode);
    errdefer if (!extras.registry_down) stub.stop();
    if (extras.registry_down) stub.stop();
    work_counter += 1;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try h.tmpPath(a, &tmp);
    var rep = h.Report{};
    // This run's own environment, with the line its programs print when the test names one; the shared one is not touched.
    var parent_env: *const std.process.EnvMap = t.env;
    if (extras.program_says) |line| {
        const own = try a.create(std.process.EnvMap);
        own.* = std.process.EnvMap.init(a);
        var it = t.env.iterator();
        while (it.next()) |e| try own.put(e.key_ptr.*, e.value_ptr.*);
        try own.put(program_output_env, line);
        parent_env = own;
    }
    squat_target = if (mode.shows_during_overlay) stub else null;
    const after_sync: *const fn (Allocator, []const u8) anyerror!void = if (mode.shows_during_overlay) layAndSquat else layToolchain;
    const result = try g.run(a, &rep, .{
        .base = stub.base,
        .stage = stage,
        .token = token,
        .mopm = if (extras.no_mopm) null else t.mopm,
        .work = work,
        .run_id = 4242000 + work_counter,
        .attempt = 1,
        .summary = extras.summary,
        // The reads of the index and the channel give up after a short time: the stand-in answers at once, and a check that is red on
        // purpose (a member that never appears) waits that long for it. The wait of `mopm publish` for its group is a backstop that a
        // loaded machine does not reach, and is short only for the registry that never settles.
        .wait_ms = extras.wait_ms,
        .publish_wait_ms = if (mode.stall) 3000 else 120_000,
        .poll_ms = 10,
        .retry_ms = 10,
        .parent_env = parent_env,
        .pixi = if (extras.no_pixi) null else t.pixi,
        .pixi_manifest = extras.pixi_manifest,
        .mojo_env = if (extras.no_toolchain) null else t.prefix,
        .prebuilt = if (extras.precompile or extras.no_toolchain) null else t.prebuilt,
        .after_sync = after_sync,
    });
    squat_target = null;
    if (!extras.registry_down) stub.stop();
    return .{ .result = result, .stub = stub };
}

fn hasNote(r: g.Result, prefix: []const u8, name: []const u8) bool {
    for (r.notes) |n| {
        if (std.mem.startsWith(u8, n, prefix) and std.mem.indexOf(u8, n, name) != null) return true;
    }
    return false;
}

fn failed(r: g.Result, name: []const u8) bool {
    return hasNote(r, "- FAIL", name);
}

fn passed(r: g.Result, name: []const u8) bool {
    return hasNote(r, "- ok", name);
}

fn expectRedOn(mode: Mode, name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const ran = try runCheck(a, mode, test_token, "beta");
    if (ran.result.skipped or ran.result.failures == 0 or !failed(ran.result, name)) {
        std.debug.print("expected a red line naming `{s}`; the run said: {s} ({d} failures)\n", .{ name, ran.result.line, ran.result.failures });
        for (ran.result.notes) |n| std.debug.print("{s}", .{n});
        return error.TestUnexpectedResult;
    }
}

test "a registry that does it all right passes every check, and the token goes only to the registry" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    // The secret holds a token for each stage; this stage's is the one used. The run precompiles the packages itself.
    const ran = try runCheckWith(a, .{}, "gamma=mopm_nottherightonenottherightonenotri\nbeta=" ++ test_token ++ "\n", "beta", .{ .precompile = true });
    for (ran.result.notes) |n| std.debug.print("{s}", .{n});
    try std.testing.expect(!ran.result.skipped);
    try std.testing.expectEqual(@as(usize, 0), ran.result.failures);
    try std.testing.expect(std.mem.startsWith(u8, ran.result.line, "group-e2e: PASS beta: "));
    // The real user path, each step on a line of its own: the farm's compiler builds the packages, `mopm stage` packs them, the
    // staged set installs through --overlay while the registry has none of it, the program of the README builds against it
    // and prints what the README says, and one `publish --staged` makes the group.
    try std.testing.expect(passed(ran.result, "packages: mojo precompile builds the three packages"));
    try std.testing.expect(passed(ran.result, "chain: mopm stage packs the workspace, with no token, and every member is an upload"));
    try std.testing.expect(passed(ran.result, "overlay: zz_e2e_app is locked at the uploaded file"));
    try std.testing.expect(passed(ran.result, "chain: mopm sync --overlay installs the whole set from the staged set"));
    try std.testing.expect(passed(ran.result, "chain: the README's program builds against the installed set"));
    try std.testing.expect(passed(ran.result, "chain: the README's program runs and prints what the README says"));
    try std.testing.expect(passed(ran.result, "chain: after all that the registry still shows none of the set"));
    try std.testing.expect(passed(ran.result, "chain: mopm publish --staged publishes the set"));
    try std.testing.expect(passed(ran.result, "chain: the token is not in what publish printed"));
    try std.testing.expect(passed(ran.result, "chain: no member is readable before the commit"));
    try std.testing.expect(passed(ran.result, "chain: the members appear all at once, never some of them"));
    try std.testing.expect(passed(ran.result, "chain: report.json says every member was published, with the planned file"));
    try std.testing.expect(passed(ran.result, "lock: the lock the staged set made is, byte for byte, the lock the registry gives once the set is published"));
    try std.testing.expect(passed(ran.result, "chain: the group becomes visible"));
    try std.testing.expect(passed(ran.result, "chain: once committed, all three members are readable at once"));
    try std.testing.expect(passed(ran.result, "lock: zz_e2e_core is locked at the uploaded file"));
    try std.testing.expect(passed(ran.result, "lock: the top package's entry names the middle one as its dependency"));
    try std.testing.expect(passed(ran.result, "rejected: the group ends rejected"));
    try std.testing.expect(passed(ran.result, "rejected: zz_e2e_core is not readable in the API"));
    try std.testing.expect(passed(ran.result, "yank: the group reaches yanked"));
    try std.testing.expect(passed(ran.result, "unyank: the group reaches restored"));
    // Three files of the chain and the two of the rejected group were uploaded, and the storage was given the
    // headers the registry named and no bearer token.
    try std.testing.expectEqual(@as(usize, 5), ran.stub.storage_puts);
    try std.testing.expect(!ran.stub.storage_auth_seen);
    try std.testing.expect(!ran.stub.storage_header_missing);
    // The groups of the run: the expiry probe, the chain and the rejected group.
    try std.testing.expectEqual(@as(usize, 3), ran.stub.group_creates);
}

test "no token: the run skips, says which secret is missing, and sends nothing" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const ran = try runCheck(a, .{}, "", "beta");
    try std.testing.expect(ran.result.skipped);
    try std.testing.expectEqual(g.SkipReason.no_secret, ran.result.skip_reason);
    try std.testing.expectEqualStrings("group-e2e: SKIP beta: the repository secret MOPM_E2E_GROUP_TOKEN is not set", ran.result.line);
    try std.testing.expectEqual(@as(usize, 0), ran.stub.requests);
}

test "a secret that holds a token for another stage only: the run skips and sends nothing" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const ran = try runCheck(a, .{ .stage = "gamma" }, "beta=" ++ test_token, "gamma");
    try std.testing.expect(ran.result.skipped);
    try std.testing.expectEqual(g.SkipReason.no_stage_token, ran.result.skip_reason);
    try std.testing.expectEqualStrings("group-e2e: SKIP gamma: the repository secret MOPM_E2E_GROUP_TOKEN holds no token for gamma", ran.result.line);
    try std.testing.expectEqual(@as(usize, 0), ran.stub.requests);
    // Only separators: the same as no secret.
    const blank = try runCheck(a, .{}, " \n,\n", "beta");
    try std.testing.expectEqualStrings("group-e2e: SKIP beta: the repository secret MOPM_E2E_GROUP_TOKEN is not set", blank.result.line);
}

test "the token of a stage: one token for any stage, or an entry for each" {
    try std.testing.expectEqualStrings("mopm_a", g.tokenFor("mopm_a", "beta"));
    try std.testing.expectEqualStrings("mopm_a", g.tokenFor("  mopm_a\r\n", "gamma"));
    try std.testing.expectEqualStrings("mopm_b", g.tokenFor("beta=mopm_b\ngamma=mopm_g\n", "beta"));
    try std.testing.expectEqualStrings("mopm_g", g.tokenFor("beta=mopm_b\r\ngamma=mopm_g\r\n", "gamma"));
    try std.testing.expectEqualStrings("mopm_g", g.tokenFor("beta=mopm_b, gamma=mopm_g", "gamma"));
    try std.testing.expectEqualStrings("", g.tokenFor("beta=mopm_b", "gamma"));
    try std.testing.expectEqualStrings("", g.tokenFor("", "beta"));
    // A stage name is matched whole, and an entry with no name is not one.
    try std.testing.expectEqualStrings("", g.tokenFor("beta2=mopm_b\n=mopm_x", "beta"));
    try std.testing.expectEqualStrings("mopm_b", g.tokenFor("junk\nbeta=mopm_b", "beta"));
}

test "the stage's groups switch is off: the run skips after one create and publishes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const ran = try runCheck(a, .{ .groups_off = true }, test_token, "beta");
    try std.testing.expect(ran.result.skipped);
    try std.testing.expectEqual(g.SkipReason.groups_off, ran.result.skip_reason);
    try std.testing.expect(std.mem.startsWith(u8, ran.result.line, "group-e2e: SKIP beta: group publishing is not enabled for the e2e actor on this stage"));
    try std.testing.expectEqual(@as(usize, 0), ran.stub.group_creates);
    try std.testing.expectEqual(@as(usize, 0), ran.stub.storage_puts);
    // The health read and the one create that was refused.
    try std.testing.expectEqual(@as(usize, 2), ran.stub.requests);
}

test "a 404 whose error code is not route_not_found is a failure, not a skip" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const ran = try runCheck(a, .{ .groups_404_code = "group_not_found" }, test_token, "beta");
    try std.testing.expect(!ran.result.skipped);
    try std.testing.expect(failed(ran.result, "the switch: the e2e actor may create groups"));
    try std.testing.expect(std.mem.startsWith(u8, ran.result.line, "group-e2e: FAIL beta: "));
    try std.testing.expectEqual(@as(usize, 0), ran.stub.storage_puts);
}

/// A run with a token and with groups on, minus a piece of the client, is a failure that names the piece, never a skip: the
/// registry has already said groups are on, so nothing is left that may quietly do nothing.
fn expectFailsNotSkips(extras: Extras, name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const ran = try runCheckWith(a, .{}, test_token, "beta", extras);
    if (ran.result.skipped or ran.result.skip_reason != .none or ran.result.failures == 0 or !failed(ran.result, name)) {
        std.debug.print("expected a failure naming `{s}`, not a skip; the run said: {s}\n", .{ name, ran.result.line });
        for (ran.result.notes) |n| std.debug.print("{s}", .{n});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(std.mem.startsWith(u8, ran.result.line, "group-e2e: FAIL beta: "));
}

test "with a token and groups on, a piece of the client that is missing is a failure, not a skip" {
    // The CLI, pixi, and the Mojo environment (none given, no pixi to make one; a pixi with no manifest).
    try expectFailsNotSkips(.{ .no_mopm = true }, "chain: --mopm names the CLI");
    try expectFailsNotSkips(.{ .no_pixi = true }, "chain: --pixi names pixi, which mopm sync installs through");
    try expectFailsNotSkips(.{ .no_toolchain = true, .no_pixi = true }, "toolchain: --pixi (or --mojo-env) names the Mojo environment");
    try expectFailsNotSkips(.{ .no_toolchain = true }, "toolchain: --pixi-manifest names the Mojo environment pixi creates");
    // The same, for the rejected case, which needs the packages too: nothing there is skipped either.
    try expectFailsNotSkips(.{ .no_mopm = true }, "rejected: --mopm names the CLI");
}

test "pixi makes the Mojo environment: the run uses what it made, and a manifest it cannot make one from, or one with no compiler, fails" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const t = try tools();
    const ok_manifest = try h.join(a, &.{ t.work, "pixi_env_ok.toml" });
    try h.writeFile(ok_manifest, "[workspace]\nname = \"empty\"\nchannels = [\"file:///nonexistent\"]\nplatforms = [\"linux-64\"]\n");
    // The stand-in pixi installs no compiler, so the environment it makes has none: the build of the packages fails, on its line.
    try expectFailsNotSkips(.{ .no_toolchain = true, .pixi_manifest = ok_manifest }, "packages: mojo precompile builds the three packages");
    // A manifest the stand-in refuses: pixi fails, on its line.
    const bad_manifest = try h.join(a, &.{ t.work, "pixi_env_bad.toml" });
    try h.writeFile(bad_manifest, "[workspace]\nname = \"broken\"\n");
    try expectFailsNotSkips(.{ .no_toolchain = true, .pixi_manifest = bad_manifest }, "toolchain: pixi creates the Mojo environment");
}

test "a group that is still reserving its members is created again until it has reached them all" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const ran = try runCheck(a, .{ .reserving_rounds = 2 }, test_token, "beta");
    for (ran.result.notes) |n| std.debug.print("{s}", .{n});
    try std.testing.expect(!ran.result.skipped);
    try std.testing.expectEqual(@as(usize, 0), ran.result.failures);
    // The probe once; the chain and the rejected group three times each (two answers of `reserving`, then the full one), asked
    // again by `mopm publish --staged` itself.
    try std.testing.expectEqual(@as(usize, 7), ran.stub.group_creates);
    // The calls after the first did not make a second group.
    try std.testing.expect(passed(ran.result, "chain: mopm publish --staged publishes the set"));
    try std.testing.expectEqual(@as(usize, 3), ran.stub.groups.items.len);
    try std.testing.expectEqual(@as(usize, 5), ran.stub.storage_puts);
}

test "prod is never exercised" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const ran = try runCheck(a, .{ .stage = "prod" }, test_token, "prod");
    try std.testing.expect(ran.result.skipped);
    try std.testing.expectEqualStrings("group-e2e: SKIP prod: this check never runs on prod", ran.result.line);
    try std.testing.expectEqual(@as(usize, 0), ran.stub.requests);
}

test "a token the registry refuses is a failure, not a skip" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const ran = try runCheck(a, .{}, "mopm_not_the_token_not_the_token_nope", "beta");
    try std.testing.expect(!ran.result.skipped);
    try std.testing.expect(failed(ran.result, "the switch: the e2e actor may create groups"));
    try std.testing.expect(std.mem.startsWith(u8, ran.result.line, "group-e2e: FAIL beta: "));
    try std.testing.expectEqual(@as(usize, 0), ran.stub.storage_puts);
}

test "a registry of another stage is a failure" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const ran = try runCheck(a, .{ .stage = "gamma" }, test_token, "beta");
    try std.testing.expect(failed(ran.result, "health: the stage answers as the stage under test"));
    try std.testing.expectEqual(@as(usize, 0), ran.stub.group_creates);
}

test "the expiry probe: a group left open by an earlier run is reported as still open, or as ended and opened again" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const open = try runCheck(a, .{ .probe = .still_open }, test_token, "beta");
    try std.testing.expectEqual(@as(usize, 0), open.result.failures);
    try std.testing.expect(passed(open.result, "expiry: the probe group is still open from an earlier run"));
    const again = try runCheck(a, .{ .probe = .reopened }, test_token, "beta");
    try std.testing.expectEqual(@as(usize, 0), again.result.failures);
    try std.testing.expect(passed(again.result, "expiry: a probe group left open by an earlier run ended at its deadline and was opened again"));
    const fresh = try runCheck(a, .{}, test_token, "beta");
    try std.testing.expect(passed(fresh.result, "expiry: the probe group is open; the first run after its deadline will find it ended"));
}

test "a deadline that is days away, or already past, is a failure" {
    try expectRedOn(.{ .deadline_secs = 72 * 3600 }, "the probe group's deadline is between 30 minutes and 19 hours away");
    try expectRedOn(.{ .deadline_secs = -60 }, "the probe group's deadline is between 30 minutes and 19 hours away");
}

test "a member that is readable before its group commits is a failure" {
    try expectRedOn(.{ .leak_early = true }, "chain: no member is readable before the commit");
}

test "a commit that shows only some members is a failure" {
    try expectRedOn(.{ .half_commit = true }, "chain: once committed, all three members are readable at once");
}

test "a commit that lands between two reads of the members is one commit, not some of the members readable at once" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    // The first member is read while the group validates (and is not there), and the commit lands right after that read: the rest
    // of the same sweep finds the other two. A registry that commits at once does exactly this to a reader whose requests
    // come one after the other. The run must not call that a partial exposure; it is green.
    const ran = try runCheck(a, .{ .commit_in_sweep = true }, test_token, "beta");
    for (ran.result.notes) |n| {
        if (std.mem.startsWith(u8, n, "- FAIL")) std.debug.print("{s}", .{n});
    }
    try std.testing.expect(!ran.result.skipped);
    try std.testing.expectEqual(@as(usize, 0), ran.result.failures);
    try std.testing.expect(passed(ran.result, "chain: the members appear all at once, never some of them"));
    try std.testing.expect(passed(ran.result, "chain: no member is readable before the commit"));
    try std.testing.expect(passed(ran.result, "chain: once committed, all three members are readable at once"));
}

test "some of the members readable at once before the commit is still a failure" {
    // Only the first member is readable while the group validates, in every sweep: nothing is committed meanwhile.
    try expectRedOn(.{ .leak_first_early = true }, "chain: the members appear all at once, never some of them");
}

test "a registry that validates slowly is waited for, however briefly the reads of its state are repeated" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    // Validation takes 2.5 seconds after the commit, of the chain and of the rejected group, and the reads of the index and the
    // channel are repeated for one second only. `mopm publish` waits for its group by its own wait, not by that one.
    const ran = try runCheckWith(a, .{ .slow_validation_ms = 2500 }, test_token, "beta", .{ .wait_ms = 1000 });
    for (ran.result.notes) |n| {
        if (std.mem.startsWith(u8, n, "- FAIL")) std.debug.print("{s}", .{n});
    }
    try std.testing.expect(!ran.result.skipped);
    try std.testing.expectEqual(@as(usize, 0), ran.result.failures);
    try std.testing.expect(passed(ran.result, "chain: mopm publish --staged publishes the set"));
    try std.testing.expect(passed(ran.result, "chain: the group becomes visible"));
    try std.testing.expect(passed(ran.result, "rejected: the group ends rejected"));
}

test "a group that never becomes visible is a failure that names the status" {
    try expectRedOn(.{ .stall = true }, "chain: the group becomes visible");
}

test "a file that is not a package, accepted, is a failure" {
    try expectRedOn(.{ .accept_bad = true }, "rejected: the group ends rejected");
}

test "a rejected group that still shows its good member is a failure in the API, the index and the channel" {
    try expectRedOn(.{ .reject_leaks_sibling = true }, "rejected: zz_e2e_core is not readable in the API");
    try expectRedOn(.{ .reject_leaks_sibling = true }, "rejected: zz_e2e_core is not in the sparse index");
    try expectRedOn(.{ .reject_leaks_sibling = true }, "rejected: the good sibling is not in the channel's repodata");
}

test "an index that lists another sha256 than the one uploaded is a failure" {
    try expectRedOn(.{ .index_lies = true }, "chain: the sparse index lists zz_e2e_core");
}

test "a group yank that leaves a member published is a failure" {
    try expectRedOn(.{ .yank_partial = true }, "yank: the sparse index lists zz_e2e_mid");
}

const lock_same = "lock: the lock the staged set made is, byte for byte, the lock the registry gives once the set is published";

test "a lock that the registry gives after the publish, and that differs from the one the staged set made, is a failure" {
    // The registry tells its readers another size for the first member than the file that was uploaded. The overlay's lock, made
    // from the staged files, has the true size; the lock `mopm add` makes from the index has the other. The same walk with a
    // registry that does it right passes this line (the first test).
    try expectRedOn(.{ .size_differs = 0 }, lock_same);
    // The same for a member that is not the first.
    try expectRedOn(.{ .size_differs = 2 }, lock_same);
}

test "a newer release of a set package that another run published meanwhile is the one difference the lock comparison allows" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const ran = try runCheck(a, .{ .newer_release = true }, test_token, "beta");
    for (ran.result.notes) |n| std.debug.print("{s}", .{n});
    try std.testing.expect(!ran.result.skipped);
    try std.testing.expectEqual(@as(usize, 0), ran.result.failures);
    // The registry's lock names the other run's file for the first member, so the two locks are not equal byte for byte; the
    // comparison says which entry differs and still holds the rest to the overlay's lock.
    try std.testing.expect(passed(ran.result, lock_same));
    try std.testing.expect(passed(ran.result, "lock: the locks differ only in a newer release of zz_e2e_core, which another run published meanwhile"));
    try std.testing.expect(passed(ran.result, "lock: zz_e2e_core is locked at the uploaded file"));
    // The tolerance covers that entry and nothing else: with the newer release there and another size told for the middle package's
    // own file, the lock still names a size no set file has, and the comparison is red.
    const both = try runCheck(a, .{ .newer_release = true, .size_differs = 1 }, test_token, "beta");
    try std.testing.expect(!both.result.skipped);
    try std.testing.expect(failed(both.result, lock_same));
    try std.testing.expect(!passed(both.result, "lock: the locks differ only in a newer release"));
}

test "a release of a set package at another major that another run published meanwhile is a failure of the lock comparison, naming that entry" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    // The registry's lock names the other run's 2.0.0 for the first member. Only a newer release of the SAME major is the other
    // run's file the comparison lets by; this one is neither the uploaded file nor that, so the entry fails and the locks differ.
    const ran = try runCheck(a, .{ .rival_major = true }, test_token, "beta");
    try std.testing.expect(!ran.result.skipped);
    try std.testing.expect(failed(ran.result, "lock: zz_e2e_core is locked at the uploaded file"));
    try std.testing.expect(failed(ran.result, lock_same));
    try std.testing.expect(!passed(ran.result, "lock: the locks differ only in a newer release"));
    try std.testing.expect(passed(ran.result, "lock: zz_e2e_mid is locked at the uploaded file"));
}

test "a README program that exits 0 and prints another line is a failure" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    // Only the stand-in compiler's programs can be told what to print; the real compiler builds what the README says, and the
    // walk of the first test holds that to the README in the beta tier.
    if ((try tools()).real != null) return;
    const ran = try runCheckWith(a, .{}, test_token, "beta", .{ .program_says = "zz_e2e total 4\n" });
    try std.testing.expect(!ran.result.skipped);
    try std.testing.expect(passed(ran.result, "chain: the README's program builds against the installed set"));
    try std.testing.expect(failed(ran.result, "chain: the README's program runs and prints what the README says"));
    try std.testing.expect(std.mem.startsWith(u8, ran.result.line, "group-e2e: FAIL beta: "));
    // A program that prints the README's line and more is not what the README says either.
    const more = try runCheckWith(a, .{}, test_token, "beta", .{ .program_says = "zz_e2e total 3\nzz_e2e total 3\n" });
    try std.testing.expect(failed(more.result, "chain: the README's program runs and prints what the README says"));
}

test "a member that the registry shows while the staged set is installed is a failure" {
    try expectRedOn(.{ .shows_during_overlay = true }, "chain: after all that the registry still shows none of the set");
}

test "a refused create, upload, commit or yank is a failure that names the step, and an open group is not left behind" {
    try expectRedOn(.{ .create_refused = true }, "chain: mopm publish --staged publishes the set");
    try expectRedOn(.{ .create_refused = true }, "rejected: the group ends rejected");
    try expectRedOn(.{ .storage_refuses = true }, "chain: mopm publish --staged publishes the set");
    try expectRedOn(.{ .yank_refused = true }, "yank: the group yank is accepted");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const ran = try runCheck(a, .{ .commit_refused = true }, test_token, "beta");
    try std.testing.expect(failed(ran.result, "chain: mopm publish --staged publishes the set"));
    try std.testing.expect(failed(ran.result, "rejected: the group ends rejected"));
    // The two groups that could not be committed were aborted, so they do not hold one of the actor's open slots until the
    // deadline; the expiry probe is meant to stay open.
    var aborted: usize = 0;
    for (ran.stub.groups.items) |gr| {
        if (gr.status == .aborted) aborted += 1;
        if (gr.status == .open) try std.testing.expectEqualStrings(g.probe_version, gr.members[0].version);
    }
    try std.testing.expectEqual(@as(usize, 2), aborted);
    const stuck = try runCheck(a, .{ .storage_refuses = true }, test_token, "beta");
    for (stuck.stub.groups.items) |gr| {
        if (gr.status == .open) try std.testing.expectEqualStrings(g.probe_version, gr.members[0].version);
    }
}

test "a registry that does not answer is a failed check, not a crash" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const ran = try runCheckWith(a, .{}, test_token, "beta", .{ .registry_down = true });
    try std.testing.expect(!ran.result.skipped);
    try std.testing.expect(failed(ran.result, "the walk ends without an error"));
    try std.testing.expect(std.mem.startsWith(u8, ran.result.line, "group-e2e: FAIL beta: "));
}

test "the job summary: one line for a skip, the line and every check for a run" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try h.tmpPath(a, &tmp);
    const skip_file = try h.join(a, &.{ dir, "skip.md" });
    _ = try runCheckWith(a, .{}, "", "beta", .{ .summary = skip_file });
    // A skip is loud in the summary: its own heading, the line with the reason, and what it means.
    const once = try h.readFile(a, skip_file);
    try std.testing.expect(std.mem.startsWith(u8, once, "### group end-to-end, beta: SKIPPED\n\ngroup-e2e: SKIP beta: the repository secret MOPM_E2E_GROUP_TOKEN is not set\n\n"));
    try std.testing.expect(std.mem.indexOf(u8, once, "Nothing was published and nothing was checked on this stage.") != null);
    try std.testing.expect(std.mem.indexOf(u8, once, "it will fail, not skip, once the secret holds a token for beta and the stage has groups on") != null);
    // The file is appended to, as $GITHUB_STEP_SUMMARY is: the steps of a job write to one file.
    _ = try runCheckWith(a, .{ .groups_off = true }, test_token, "beta", .{ .summary = skip_file });
    const twice = try h.readFile(a, skip_file);
    try std.testing.expect(std.mem.indexOf(u8, twice, "is not set\n\nNothing was published") != null);
    try std.testing.expect(std.mem.indexOf(u8, twice, "\ngroup-e2e: SKIP beta: group publishing is not enabled for the e2e actor on this stage (creating a group answered route_not_found)\n") != null);
    const run_file = try h.join(a, &.{ dir, "run.md" });
    const ran = try runCheckWith(a, .{ .half_commit = true }, test_token, "beta", .{ .summary = run_file });
    const text = try h.readFile(a, run_file);
    try std.testing.expect(std.mem.startsWith(u8, text, "### group end-to-end, beta\n\ngroup-e2e: FAIL beta: "));
    try std.testing.expect(std.mem.indexOf(u8, text, "\n- ok   health: the stage answers as the stage under test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\n- FAIL chain: once committed, all three members are readable at once: 1 of 3\n") != null);
    try std.testing.expect(ran.result.failures > 0);
}

test "the command line: every flag, and the ways it is wrong" {
    const ok = g.parseArgs(&.{ "--stage", "gamma", "--mopm", "/m", "--work", "/w", "--run-id", "123", "--attempt", "2", "--summary", "/s", "--wait-seconds", "30", "--registry", "http://127.0.0.1:9", "--pixi", "/p", "--pixi-manifest", "/p.toml", "--mojo-env", "/env" }).?;
    try std.testing.expectEqualStrings("/p", ok.pixi.?);
    try std.testing.expectEqualStrings("/p.toml", ok.pixi_manifest.?);
    try std.testing.expectEqualStrings("/env", ok.mojo_env.?);
    try std.testing.expectEqualStrings("gamma", ok.stage);
    try std.testing.expectEqualStrings("/m", ok.mopm.?);
    try std.testing.expectEqualStrings("/w", ok.work);
    try std.testing.expectEqual(@as(u64, 123), ok.run_id);
    try std.testing.expectEqual(@as(u64, 2), ok.attempt);
    try std.testing.expectEqualStrings("/s", ok.summary.?);
    try std.testing.expectEqual(@as(u64, 30), ok.wait_seconds);
    try std.testing.expectEqualStrings("http://127.0.0.1:9", ok.registry_spec.?);
    const least = g.parseArgs(&.{ "--stage", "beta", "--work", "/w", "--run-id", "1", "--attempt", "1" }).?;
    try std.testing.expectEqual(@as(?[]const u8, null), least.mopm);
    try std.testing.expectEqual(@as(u64, 600), least.wait_seconds);
    // Each of these is refused: a missing required flag, a flag with no value, an unknown flag, a number that is not one.
    try std.testing.expect(g.parseArgs(&.{ "--work", "/w", "--run-id", "1", "--attempt", "1" }) == null);
    try std.testing.expect(g.parseArgs(&.{ "--stage", "beta", "--run-id", "1", "--attempt", "1" }) == null);
    try std.testing.expect(g.parseArgs(&.{ "--stage", "beta", "--work", "/w", "--attempt", "1" }) == null);
    try std.testing.expect(g.parseArgs(&.{ "--stage", "beta", "--work", "/w", "--run-id", "1" }) == null);
    try std.testing.expect(g.parseArgs(&.{ "--stage", "beta", "--work", "/w", "--run-id", "1", "--attempt" }) == null);
    try std.testing.expect(g.parseArgs(&.{ "--stage", "beta", "--work", "/w", "--run-id", "1", "--attempt", "1", "--token", "x" }) == null);
    try std.testing.expect(g.parseArgs(&.{ "--stage", "beta", "--work", "/w", "--run-id", "x", "--attempt", "1" }) == null);
    try std.testing.expect(g.parseArgs(&.{ "--stage", "beta", "--work", "/w", "--run-id", "1", "--attempt", "-1" }) == null);
    try std.testing.expect(g.parseArgs(&.{ "--stage", "beta", "--work", "/w", "--run-id", "1", "--attempt", "1", "--wait-seconds", "soon" }) == null);
}

// ---- the pure parts of the check ------------------------------------------------------------------------------------

test "a version is the case, the run and the attempt, and no two cases or runs share one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("1.12345678901.2", try g.versionOf(a, .chain, 12345678901, 2));
    try std.testing.expectEqualStrings("2.12345678901.2", try g.versionOf(a, .rejected, 12345678901, 2));
    const x = try g.versionOf(a, .chain, 100, 1);
    const y = try g.versionOf(a, .chain, 100, 2);
    const z = try g.versionOf(a, .chain, 101, 1);
    try std.testing.expect(!std.mem.eql(u8, x, y) and !std.mem.eql(u8, x, z) and !std.mem.eql(u8, y, z));
    // The registry's version grammar: three numbers, no leading zero.
    for ([_][]const u8{ x, y, z, g.probe_version }) |v| try std.testing.expect(core.conda.exactVersion(v));
}

test "a dependency asks for that version or a newer one of the same major" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(">=1.77.1,<2", try g.rangeFrom(arena.allocator(), "1.77.1"));
}

test "a timestamp is read to the second, across a leap year and a month end" {
    try std.testing.expectEqual(@as(?i64, 0), g.epochOf("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, 951782400), g.epochOf("2000-02-29T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, 1792672496), g.epochOf("2026-10-22T12:34:56Z"));
    try std.testing.expectEqual(@as(?i64, 1792672496), g.epochOf("2026-10-22T12:34:56.789Z"));
    try std.testing.expectEqual(@as(?i64, null), g.epochOf("2026-10-22 12:34:56Z"));
    try std.testing.expectEqual(@as(?i64, null), g.epochOf("2026-13-22T12:34:56Z"));
    try std.testing.expectEqual(@as(?i64, null), g.epochOf("2026-10-22T12:34:56+01:00"));
    try std.testing.expectEqual(@as(?i64, null), g.epochOf(""));
}

test "a child gets the path and a home, and not the token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parent = std.process.EnvMap.init(a);
    try parent.put("PATH", "/bin");
    try parent.put(g.token_env, "mopm_secretsecretsecretsecretsecretse");
    try parent.put("AWS_SESSION_TOKEN", "x");
    var env = try g.childEnv(a, &parent, "/work/home");
    try std.testing.expectEqualStrings("/bin", env.get("PATH").?);
    try std.testing.expectEqualStrings("/work/home", env.get("HOME").?);
    try std.testing.expectEqual(@as(?[]const u8, null), env.get(g.token_env));
    try std.testing.expectEqual(@as(?[]const u8, null), env.get("AWS_SESSION_TOKEN"));
    try std.testing.expectEqual(@as(u32, 2), env.count());
}

test "the index path of a package is derived from its name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("index/zz/_e/zz_e2e_core", try g.indexPath(a, g.pkg_core));
    try std.testing.expectEqualStrings("index/tl/s_/tls", try g.indexPath(a, "tls"));
    try std.testing.expectEqualStrings("index/ab/__/ab", try g.indexPath(a, "ab"));
}

test "the range the check expects of a dependency is the one mopm writes for the requirement of the manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // memberToml asks for ^VERSION; the index and the registry's API show what `mopm pack` made of it.
    var why: []const u8 = "";
    for ([_][]const u8{ "1.5.1", "1.4242001.1", "1.77.1" }) |v| {
        const req = try std.fmt.allocPrint(a, "^{s}", .{v});
        try std.testing.expectEqualStrings(try g.rangeFrom(a, v), try core.conda.condaRange(a, req, &why));
    }
}

test "the workspace: each member depends on the one below it, by path and by version, and the app's README holds the program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("[package]\nname = \"zz_e2e_core\"\nversion = \"1.5.1\"\nmojo = [\"1.0.0\"]\n\n[dependencies]\n", try g.memberToml(a, g.pkg_core, "1.5.1"));
    try std.testing.expectEqualStrings("[package]\nname = \"zz_e2e_mid\"\nversion = \"1.5.1\"\nmojo = [\"1.0.0\"]\n\n[dependencies]\nzz_e2e_core = { path = \"../zz_e2e_core\", version = \"^1.5.1\" }\n", try g.memberToml(a, g.pkg_mid, "1.5.1"));
    try std.testing.expectEqualStrings(g.pkg_mid, g.depOf(g.pkg_app).?);
    try std.testing.expect(g.depOf(g.pkg_core) == null);
    // The sources chain: the app imports the middle package, which imports the core.
    try std.testing.expect(std.mem.indexOf(u8, g.sourceOf(g.pkg_app), "from zz_e2e_mid import") != null);
    try std.testing.expect(std.mem.indexOf(u8, g.sourceOf(g.pkg_mid), "from zz_e2e_core import") != null);
    // The README program is the first mojo block of the app's README, and a README without one has none.
    const readme = try g.readmeOf(a, g.pkg_app);
    const program = g.readmeProgram(readme).?;
    try std.testing.expect(std.mem.startsWith(u8, program, "from zz_e2e_app import total\n"));
    try std.testing.expect(std.mem.indexOf(u8, program, "```") == null);
    try std.testing.expect(g.readmeProgram(try g.readmeOf(a, g.pkg_core)) == null);
    try std.testing.expect(g.readmeProgram("```mojo\nno closing fence") == null);
    // The writer puts every file of every member in place.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try h.tmpPath(a, &tmp);
    try g.writeWorkspace(a, ws, "1.5.1", g.members[0..2]);
    try std.testing.expectEqualStrings(g.sourceOf(g.pkg_mid), try h.readFile(a, try h.join(a, &.{ ws, g.pkg_mid, "src", g.pkg_mid, "__init__.mojo" })));
    try std.testing.expectEqualStrings(try g.memberToml(a, g.pkg_core, "1.5.1"), try h.readFile(a, try h.join(a, &.{ ws, g.pkg_core, "mopm.toml" })));
    try std.testing.expectError(error.FileNotFound, h.readFile(a, try h.join(a, &.{ ws, g.pkg_app, "mopm.toml" })));
}

test "a toolchain child gets the runner's environment, less the token and the credentials the runner holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parent = std.process.EnvMap.init(a);
    try parent.put("PATH", "/bin");
    try parent.put("HOME", "/home/runner");
    try parent.put("LD_LIBRARY_PATH", "/tc/lib");
    try parent.put("MOPM_ZIG", "/zig");
    try parent.put(g.token_env, "mopm_secretsecretsecretsecretsecretse");
    try parent.put("MOPM_TOKEN", "mopm_secretsecretsecretsecretsecretse");
    try parent.put("GITHUB_TOKEN", "x");
    try parent.put("AWS_SESSION_TOKEN", "x");
    try parent.put("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "x");
    var env = try g.toolEnv(a, &parent);
    try std.testing.expectEqualStrings("/bin", env.get("PATH").?);
    try std.testing.expectEqualStrings("/home/runner", env.get("HOME").?);
    try std.testing.expectEqualStrings("/tc/lib", env.get("LD_LIBRARY_PATH").?);
    try std.testing.expectEqualStrings("/zig", env.get("MOPM_ZIG").?);
    try std.testing.expectEqual(@as(u32, 4), env.count());
}

test "a path the check is given is made absolute, because its children start in other directories; a bare name is left to the PATH" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/abs/mopm", try g.absolute(a, "/abs/mopm"));
    try std.testing.expectEqualStrings("pixi", try g.absolute(a, "pixi"));
    const rel = try g.absolute(a, "./zig-out/bin/mopm");
    try std.testing.expect(std.fs.path.isAbsolute(rel));
    try std.testing.expect(std.mem.endsWith(u8, rel, "/zig-out/bin/mopm"));
    try std.testing.expect(std.mem.indexOf(u8, rel, "/./") == null);
}

test "the summary of a skip says it was a skip, why, and when it stops being one" {
    const a = std.testing.allocator;
    const s = try g.skipSummary(a, "gamma", "group-e2e: SKIP gamma: why");
    defer a.free(s);
    try std.testing.expectEqualStrings("### group end-to-end, gamma: SKIPPED\n\ngroup-e2e: SKIP gamma: why\n\nNothing was published and nothing was checked on this stage. The job is green because it did nothing; it will fail, not skip, once the secret holds a token for gamma and the stage has groups on.\n\n", s);
}

