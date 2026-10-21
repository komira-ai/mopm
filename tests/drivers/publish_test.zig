//! End-to-end tests of `mopm pack` and `mopm publish`: the Zig port of
//! tests/registry_e2e/publish.py (deleted with this port).
//!
//! Run by Buck2 (//:registry_publish): MOPM and MOPM_FAKE_REGISTRY are
//! the built programs. Each check prints `ok` or `FAIL`.
//!
//! What can go red, and why:
//! - a publish against mopm-fake-registry must end `published`, and then the
//!   version, the sparse index and the channel's repodata.json must list it,
//!   with the sha256 that `mopm pack` printed (so a packer that is not
//!   deterministic, or an upload that sends other bytes than it packed, fails);
//! - publishing the same version again must fail with the registry's
//!   `version_exists` message;
//! - the client-side refusals (a version that is not exactly MAJOR.MINOR.PATCH,
//!   a readme over 64 KiB, native libraries, a missing login) must happen
//!   before any request: they run against an address nothing listens on, so a
//!   client that went to the network would print "cannot reach" instead;
//! - the fake does not open archives, so a rejection is exercised against a
//!   small stand-in registry in this file that answers `rejected` with a code;
//!   it also records the PUT it receives, which must carry every header the
//!   registry named and no Authorization header;
//! - no token (the API token, the stand-in's token) appears in any output.

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

    fn run(m: Mopm, args: []const []const u8, token: ?[]const u8) !Out {
        const argv = try m.a.alloc([]const u8, args.len + 1);
        argv[0] = m.exe;
        @memcpy(argv[1..], args);
        var env = try h.cloneEnv(m.a, &m.env);
        if (token) |t| try env.put("MOPM_TOKEN", t);
        const r = try std.process.Child.run(.{ .allocator = m.a, .argv = argv, .env_map = &env, .max_output_bytes = 1 << 22 });
        return .{ .code = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        }, .stdout = r.stdout, .stderr = r.stderr };
    }
};

/// The pieces of `packed <path>\n  sha256 <hex>\n  size <n>\n  manifest_sha256 <hex>`.
const Packed = struct { path: []const u8, sha: []const u8, size: usize };

fn parsePacked(text: []const u8) ?Packed {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l0| {
        if (!std.mem.startsWith(u8, l0, "packed ")) continue;
        const l1 = lines.next() orelse return null;
        const l2 = lines.next() orelse return null;
        const l3 = lines.next() orelse return null;
        if (!std.mem.startsWith(u8, l1, "  sha256 ") or !std.mem.startsWith(u8, l2, "  size ")) return null;
        if (!std.mem.startsWith(u8, l3, "  manifest_sha256 ")) return null;
        const sha = l1["  sha256 ".len..];
        if (!isSha(sha) or !isSha(l3["  manifest_sha256 ".len..])) return null;
        const size = std.fmt.parseInt(usize, l2["  size ".len..], 10) catch return null;
        return .{ .path = l0["packed ".len..], .sha = sha, .size = size };
    }
    return null;
}

fn isSha(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |ch| {
        if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return false;
    }
    return true;
}

fn exists(path: []const u8) bool {
    return if (std.fs.cwd().access(path, .{})) true else |_| false;
}

fn tomlText(a: Allocator, name: []const u8, version: []const u8, extra: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "[package]\nname = \"{s}\"\nversion = \"{s}\"\n\n[toolchain]\nmojo = \"1.0.0\"\n\n{s}", .{ name, version, extra });
}

/// A file of `n` 'a' bytes.
fn writeBytes(a: Allocator, path: []const u8, n: usize) !void {
    const bytes = try a.alloc(u8, n);
    @memset(bytes, 'a');
    try h.writeFile(path, bytes);
}

// -------------------------------------------------------------- the stand-in

/// A registry that rejects every publish with path_not_allowed, and records
/// what it was sent. Served from a thread that lives until the process ends.
const Stub = struct {
    server: std.net.Server,
    mutex: std.Thread.Mutex = .{},
    polls: usize = 0,
    begin_size: i64 = -1,
    begin_auth: []const u8 = "",
    commit_body: []const u8 = "",
    put_seen: bool = false,
    put_checksum: []const u8 = "",
    put_has_authorization: bool = false,
    put_size: usize = 0,

    fn base(self: *Stub, a: Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{self.server.listen_address.getPort()});
    }

    fn serve(self: *Stub) void {
        while (true) {
            const conn = self.server.accept() catch return;
            self.connection(conn);
        }
    }

    fn connection(self: *Stub, conn: std.net.Server.Connection) void {
        defer conn.stream.close();
        var buf: [16 * 1024]u8 = undefined;
        var http = std.http.Server.init(conn, &buf);
        while (http.state == .ready) {
            var req = http.receiveHead() catch return;
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            self.answer(arena.allocator(), &req) catch return;
        }
    }

    fn reply(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
        try req.respond(body, .{
            .status = status,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            .keep_alive = false,
        });
    }

    fn answer(self: *Stub, a: Allocator, req: *std.http.Server.Request) !void {
        const target = try a.dupe(u8, req.head.target);
        const method = req.head.method;
        var auth: ?[]const u8 = null;
        var checksum: ?[]const u8 = null;
        var it = req.iterateHeaders();
        while (it.next()) |hd| {
            if (std.ascii.eqlIgnoreCase(hd.name, "authorization")) auth = try std.heap.page_allocator.dupe(u8, hd.value);
            if (std.ascii.eqlIgnoreCase(hd.name, "x-stub-checksum")) checksum = try std.heap.page_allocator.dupe(u8, hd.value);
        }
        const has_body = req.head.content_length != null or req.head.transfer_encoding == .chunked;
        const body = if (has_body) try (try req.reader()).readAllAlloc(a, 64 << 20) else "";
        const b = try self.base(a);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (method == .GET and std.mem.eql(u8, target, "/index/config.json")) {
            return reply(req, .ok, try std.fmt.allocPrint(a,
                \\{{"index_version":1,"stage":"stub","api_url":"{s}/api/v1","channel_url":"{s}/channel/","min_cli_version":"0.0.1"}}
            , .{ b, b }));
        }
        if (method == .GET and std.mem.eql(u8, target, "/api/v1/publishes/pub_1")) {
            self.polls += 1;
            if (self.polls < 2) {
                return reply(req, .ok,
                    \\{"publish_id":"pub_1","name":"stubpkg","version":"1.0.0","status":"validating"}
                );
            }
            return reply(req, .ok,
                \\{"publish_id":"pub_1","name":"stubpkg","version":"1.0.0","status":"rejected","rejection_code":"path_not_allowed","message":"bin/tool is not an allowed path"}
            );
        }
        if (method == .POST and std.mem.eql(u8, target, "/api/v1/packages/stubpkg/1.0.0/files")) {
            const v = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
            const size: i64 = if (v == .object) (if (v.object.get("size")) |s| (if (s == .integer) s.integer else -2) else -3) else -4;
            self.begin_size = size;
            self.begin_auth = if (auth) |x| x else "";
            return reply(req, .ok, try std.fmt.allocPrint(a,
                \\{{"upload_id":"upl_1","put_url":"{s}/put/upl_1","put_headers":{{"content-length":"{d}","x-stub-checksum":"abc=="}},"expires_at":"2099-01-01T00:00:00Z"}}
            , .{ b, size }));
        }
        if (method == .POST and std.mem.eql(u8, target, "/api/v1/packages/stubpkg/1.0.0/publish")) {
            self.commit_body = try std.heap.page_allocator.dupe(u8, body);
            return reply(req, .accepted,
                \\{"publish_id":"pub_1","status_url":"/api/v1/publishes/pub_1"}
            );
        }
        if (method == .PUT) {
            self.put_seen = true;
            self.put_checksum = if (checksum) |x| x else "";
            self.put_has_authorization = auth != null;
            self.put_size = body.len;
            return reply(req, .ok, "{}");
        }
        return reply(req, .not_found,
            \\{"error":{"code":"not_found","message":"no","hint":""}}
        );
    }
};

// ------------------------------------------------------------------- the test

test "mopm pack and publish against the fake registry, and a rejection against a stand-in" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var rep = h.Report{};
    try h.watchdog(90);
    const mopm_exe = try h.toolPath(a, "MOPM");
    const fake_exe = try h.toolPath(a, "MOPM_FAKE_REGISTRY");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try h.tmpPath(a, &tmp);

    var env = try h.environ(a);
    env.remove("MOPM_TOKEN");
    const m = Mopm{ .a = a, .exe = mopm_exe, .env = env };
    var everything = std.ArrayList(u8).init(a);

    h.stage = "starting the fake registry";
    var fake = try h.Fake.start(a, fake_exe, try h.join(a, &.{ work, "fake" }));
    defer fake.close();
    const api = try fake.api(a);

    const pkg = try h.join(a, &.{ work, "pkg" });
    const manifest = try h.join(a, &.{ pkg, "mopm.toml" });
    try h.writeFile(manifest, try tomlText(a, "pubdemo", "0.1.0", ""));
    try h.writeFile(try h.join(a, &.{ pkg, "README.md" }), "# pubdemo\n");
    const mojoc = try h.join(a, &.{ pkg, "pubdemo.mojoc" });
    try h.writeFile(mojoc, "not a real mojoc, only bytes\n");
    const conf = try h.join(a, &.{ work, "conf" });
    const conda_name = "mojo-pubdemo-0.1.0-mojo1.0.0_0.conda";

    // --- pack
    const dist = try h.join(a, &.{ work, "dist" });
    var r = try m.run(&.{ "pack", "--compiler", "1.0.0", "--mojoc", mojoc, "--manifest", manifest, "-o", dist }, null);
    try everything.appendSlice(r.stdout);
    try everything.appendSlice(r.stderr);
    const pk = parsePacked(r.stdout);
    rep.check("pack writes <dir>/noarch/<file>.conda and prints its sha256", r.code == 0 and pk != null and
        std.mem.endsWith(u8, pk.?.path, "/noarch/" ++ conda_name) and exists(pk.?.path), r.stdout);
    const packed_sha = if (pk) |p| p.sha else "";
    const r2 = try m.run(&.{ "pack", "--compiler", "1.0.0", "--mojoc", mojoc, "--manifest", manifest, "-o", try h.join(a, &.{ work, "dist2" }) }, null);
    const packed2 = parsePacked(r2.stdout);
    rep.check("packing twice gives the same bytes", packed2 != null and std.mem.eql(u8, packed2.?.sha, packed_sha), r2.stdout);
    const linux_mojoc = try std.fmt.allocPrint(a, "linux-64={s}", .{mojoc});
    const osx_mojoc = try std.fmt.allocPrint(a, "osx-arm64={s}", .{mojoc});
    const dist3 = try h.join(a, &.{ work, "dist3" });
    r = try m.run(&.{ "pack", "--compiler", "1.0.0", "--mojoc", linux_mojoc, "--mojoc", osx_mojoc, "--manifest", manifest, "-o", dist3 }, null);
    rep.check("pack writes one file per subdir", r.code == 0 and exists(try h.join(a, &.{ dist3, "linux-64", conda_name })) and
        exists(try h.join(a, &.{ dist3, "osx-arm64", conda_name })), r.stdout);
    r = try m.run(&.{ "pack", "--compiler", "1.0.0", "--mojoc", try std.fmt.allocPrint(a, "win-64={s}", .{mojoc}), "--manifest", manifest }, null);
    rep.check("pack refuses an unknown subdir", r.code == 2 and h.contains(r.stderr, "not a subdir"), r.stderr);

    // --- an account that owns the name, and a token that may publish it
    const session_json = try fake.control(a, "/session", "{\"handle\":\"pub-user\"}");
    const session = h.jsonString(session_json, "token") orelse "";
    var resp = try h.request(a, "POST", fake.base, "/api/v1/packages/pubdemo/claim", "{}", session);
    rep.check("the name is claimed", resp.status == 201, resp.body);
    resp = try h.request(a, "POST", fake.base, "/api/v1/me/tokens", "{\"name\":\"e2e\",\"scopes\":[\"publish\"],\"packages\":[\"pubdemo\"],\"expires_in_days\":1}", session);
    const api_token = if (resp.status == 201) (h.jsonString(try h.parseJson(a, resp.body), "token") orelse "") else "";
    rep.check("an API token with the publish scope is made", resp.status == 201 and api_token.len > 0, resp.body);
    const flags = [_][]const u8{ "--registry", fake.base, "--config-dir", conf };
    const pub_args = [_][]const u8{ "publish", "--compiler", "1.0.0", "--mojoc", mojoc, "--manifest", manifest };

    // --- client-side refusals, before any request
    const dry = try m.run(&(pub_args ++ [_][]const u8{ "--registry", dead, "--config-dir", conf, "--dry-run" }), null);
    try everything.appendSlice(dry.stdout);
    try everything.appendSlice(dry.stderr);
    rep.check("--dry-run packs and says what it would send, without a registry", dry.code == 0 and
        h.contains(dry.stdout, "would upload noarch/" ++ conda_name) and
        h.contains(dry.stdout, try std.fmt.allocPrint(a, "sha256 {s}", .{packed_sha})) and
        h.contains(dry.stdout, "would commit mojo-pubdemo 0.1.0") and
        h.contains(dry.stdout, "would send a readme of 10 bytes") and
        h.contains(dry.stdout, "dry run: nothing was sent"), dry.stdout);

    const rc_manifest = try h.join(a, &.{ work, "rc", "mopm.toml" });
    try h.writeFile(rc_manifest, try tomlText(a, "pubdemo", "0.2.0-rc.1", ""));
    r = try m.run(&.{ "publish", "--compiler", "1.0.0", "--mojoc", mojoc, "--manifest", rc_manifest, "--registry", dead, "--config-dir", conf }, null);
    rep.check("a pre-release version is refused before any request", r.code == 1 and h.contains(r.stderr, "must be exactly MAJOR.MINOR.PATCH") and !h.contains(r.stderr, "cannot reach"), r.stderr);
    const short_manifest = try h.join(a, &.{ work, "short", "mopm.toml" });
    try h.writeFile(short_manifest, try tomlText(a, "pubdemo", "1.0", ""));
    r = try m.run(&.{ "publish", "--compiler", "1.0.0", "--mojoc", mojoc, "--manifest", short_manifest, "--registry", dead, "--config-dir", conf }, null);
    rep.check("a version 1.0 is refused before any request", r.code == 1 and h.contains(r.stderr, "MAJOR.MINOR.PATCH") and !h.contains(r.stderr, "cannot reach"), r.stderr);

    const big = try h.join(a, &.{ work, "big", "README.md" });
    try writeBytes(a, big, 65537);
    r = try m.run(&(pub_args ++ [_][]const u8{ "--registry", dead, "--config-dir", conf, "--readme", big }), null);
    rep.check("a readme over 65536 bytes is refused before any request", r.code == 1 and h.contains(r.stderr, "at most 65536 bytes") and !h.contains(r.stderr, "cannot reach"), r.stderr);
    const exact = try h.join(a, &.{ work, "exact", "README.md" });
    try writeBytes(a, exact, 65536);
    r = try m.run(&(pub_args ++ [_][]const u8{ "--registry", dead, "--config-dir", conf, "--readme", exact, "--dry-run" }), null);
    rep.check("a readme of exactly 65536 bytes is accepted", r.code == 0 and h.contains(r.stdout, "would send a readme of 65536 bytes"), r.stdout);

    const native_manifest = try h.join(a, &.{ work, "native", "mopm.toml" });
    try h.writeFile(native_manifest, try tomlText(a, "pubdemo", "0.1.0", "[native.zlib]\nkind = \"shared\"\n"));
    r = try m.run(&.{ "publish", "--compiler", "1.0.0", "--mojoc", mojoc, "--manifest", native_manifest, "--registry", dead, "--config-dir", conf }, null);
    rep.check("native libraries are refused before any request", r.code == 1 and h.contains(r.stderr, "native libraries are not packed yet") and !h.contains(r.stderr, "cannot reach"), r.stderr);

    r = try m.run(&(pub_args ++ flags), null);
    rep.check("publishing without a login or MOPM_TOKEN says to log in", r.code == 1 and h.contains(r.stderr, "not logged in to beta; run 'mopm login' or set MOPM_TOKEN"), r.stderr);

    // --- a publish
    r = try m.run(&(pub_args ++ flags), api_token);
    try everything.appendSlice(r.stdout);
    try everything.appendSlice(r.stderr);
    rep.check("publish ends with 'published'", r.code == 0 and h.contains(r.stdout, "uploaded " ++ conda_name) and
        h.contains(r.stdout, "committed, publish ") and h.contains(r.stdout, "published mojo-pubdemo 0.1.0"), r.stdout);
    resp = try h.request(a, "GET", fake.base, "/api/v1/packages/pubdemo/0.1.0", null, null);
    rep.check("the version is served", resp.status == 200 and std.mem.eql(u8, h.jsonString(try h.parseJson(a, resp.body), "version") orelse "", "0.1.0"), resp.body);
    resp = try h.request(a, "GET", fake.base, "/index/pu/bd/pubdemo", null, null);
    rep.check("the sparse index lists the version and its sha256", resp.status == 200 and h.contains(resp.body, "\"version\":\"0.1.0\"") and h.contains(resp.body, packed_sha), resp.body);
    resp = try h.request(a, "GET", fake.base, "/channel/noarch/repodata.json", null, null);
    {
        var sha_ok = false;
        if (resp.status == 200) {
            const doc = try h.parseJson(a, resp.body);
            if (doc == .object) {
                if (doc.object.get("packages.conda")) |pc| {
                    if (pc == .object) {
                        if (pc.object.get(conda_name)) |entry| {
                            sha_ok = std.mem.eql(u8, h.jsonString(entry, "sha256") orelse "", packed_sha);
                        }
                    }
                }
            }
        }
        rep.check("the channel's repodata.json lists the file with the packed sha256", sha_ok, resp.body[0..@min(resp.body.len, 400)]);
    }
    resp = try h.request(a, "GET", fake.base, "/channel/noarch/" ++ conda_name, null, null);
    rep.check("the channel serves the file", resp.status == 200 and pk != null and resp.body.len == pk.?.size, "wrong status or size");

    r = try m.run(&(pub_args ++ flags), api_token);
    try everything.appendSlice(r.stdout);
    try everything.appendSlice(r.stderr);
    rep.check("publishing the same version again fails with version_exists", r.code == 1 and h.contains(r.stderr, "already exists") and h.contains(r.stderr, "versions are immutable"), r.stderr);

    // --- the login's session is not a publish token
    const conf2 = try h.join(a, &.{ work, "conf2" });
    try h.writeFile(try h.join(a, &.{ conf2, "credentials.json" }), try std.fmt.allocPrint(a, "{{\"{s}\":{{\"token\":\"{s}\",\"handle\":\"pub-user\"}}}}", .{ api, session }));
    const next_manifest = try h.join(a, &.{ work, "next", "mopm.toml" });
    try h.writeFile(next_manifest, try tomlText(a, "pubdemo", "0.1.1", ""));
    r = try m.run(&.{ "publish", "--compiler", "1.0.0", "--mojoc", mojoc, "--manifest", next_manifest, "--registry", fake.base, "--config-dir", conf2 }, null);
    try everything.appendSlice(r.stdout);
    try everything.appendSlice(r.stderr);
    rep.check("a stored session token is sent and the registry's refusal is printed", r.code == 1 and h.contains(r.stderr, "does not have the 'publish' scope for 'pubdemo'"), r.stderr);

    // --- a rejection, against the stand-in
    const stub = try a.create(Stub);
    stub.* = .{ .server = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true }) };
    const thread = try std.Thread.spawn(.{}, Stub.serve, .{stub});
    thread.detach();
    const stub_base = try stub.base(a);
    const stub_manifest = try h.join(a, &.{ work, "stub", "mopm.toml" });
    try h.writeFile(stub_manifest, try tomlText(a, "stubpkg", "1.0.0", ""));
    const stub_mojoc = try h.join(a, &.{ work, "stub", "stubpkg.mojoc" });
    try h.writeFile(stub_mojoc, "bytes");
    const stub_token = "mopm_stub_secret_token";
    r = try m.run(&.{ "publish", "--compiler", "1.0.0", "--mojoc", stub_mojoc, "--manifest", stub_manifest, "--registry", stub_base, "--config-dir", try h.join(a, &.{ work, "conf3" }) }, stub_token);
    try everything.appendSlice(r.stdout);
    try everything.appendSlice(r.stderr);
    rep.check("a rejected publish exits 1 and prints the code and message", r.code == 1 and
        h.contains(r.stderr, "rejected: path_not_allowed: bin/tool is not an allowed path") and !h.contains(r.stdout, "published"), r.stderr);
    stub.mutex.lock();
    defer stub.mutex.unlock();
    rep.check("the PUT carries the headers the registry named, as given", stub.put_seen and std.mem.eql(u8, stub.put_checksum, "abc=="), stub.put_checksum);
    rep.check("the PUT carries no Authorization header", stub.put_seen and !stub.put_has_authorization, "an Authorization header was sent");
    rep.check("the PUT sends the declared number of bytes", stub.put_seen and @as(i64, @intCast(stub.put_size)) == stub.begin_size, "wrong size");
    rep.check("begin-upload and commit carry the bearer token", std.mem.eql(u8, stub.begin_auth, "Bearer " ++ stub_token), stub.begin_auth);
    {
        const commit = h.parseJson(a, stub.commit_body) catch std.json.Value{ .null = {} };
        var ids_ok = false;
        var no_readme = false;
        var sha_ok = false;
        if (commit == .object) {
            if (commit.object.get("upload_ids")) |ids| {
                ids_ok = ids == .array and ids.array.items.len == 1 and ids.array.items[0] == .string and std.mem.eql(u8, ids.array.items[0].string, "upl_1");
            }
            sha_ok = isSha(h.jsonString(commit, "manifest_sha256") orelse "");
            no_readme = commit.object.get("readme") == null;
        }
        rep.check("commit declares the upload id and a manifest_sha256", ids_ok and sha_ok and no_readme, stub.commit_body);
    }

    const secrets = [_][]const u8{ session, api_token, stub_token };
    var leaked = false;
    for (secrets) |s| {
        if (s.len > 0 and h.contains(everything.items, s)) leaked = true;
    }
    rep.check("no token is ever printed", !leaked, "a token was printed");

    try rep.finish();
}
