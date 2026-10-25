//! End-to-end tests of `mopm publish --oidc` (single package and `--staged`) against the fake registry and a stand-in
//! for the GitHub Actions identity-token endpoint.
//!
//! Run by Buck2 (//:oidc_publish): MOPM and MOPM_FAKE_REGISTRY are the built programs. Each check prints `ok` or `FAIL`.
//!
//! What can go red, and why:
//! - inside an Actions-shaped environment, a publish must reach `published` with the token the registry minted for the job's
//!   identity, not the MOPM_TOKEN that is set beside it: the version's provenance names the trusted repository, which only a
//!   token from the exchange gives; the stand-in must have been asked once, with the registry's audience (`beta.mopm.dev`
//!   for a beta registry) and the request token as a bearer token;
//! - the identity token, the request token and the exchanged token must be in nothing mopm prints, and no credentials file
//!   is written (the token lives in memory only);
//! - outside Actions, with only one of the two variables, the command must stop before any request: it is pointed at an
//!   address nothing listens on, so a client that went to the network would print "cannot reach", and the stand-in must
//!   have been asked nothing;
//! - a GitHub that refuses the identity request, and a registry that refuses the exchange (the package has no trusted
//!   publisher), must each end 1 with their own message and publish nothing;
//! - `--dry-run --oidc` reads no environment and sends nothing; `pack` does not know `--oidc`;
//! - a staged set is refused before any request when it is not for one member (the exchange mints a token for one package
//!   version), and for one member it asks GitHub once and sends the exchanged token to the registry, which answers as it does
//!   for any identity token (a group needs an API token): the run ends 1 with the registry's message.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

const dead = "http://127.0.0.1:1"; // nothing listens here

const request_secret = "actions-request-token-secret";
const repository = "komira-ai/demo";

// ----------------------------------------------------- the stand-in for GitHub

/// Answers `GET /idtoken?...&audience=<a>` with `{"value": <jwt>}` (a JWT-shaped token whose payload has a `repository`
/// claim, the one thing the fake registry reads), or 403 while `refuse` is set; keeps what it was asked.
const Github = struct {
    server: std.net.Server,
    mutex: std.Thread.Mutex = .{},
    refuse: bool = false,
    calls: usize = 0,
    audience: []const u8 = "",
    bearer: []const u8 = "",
    accept: []const u8 = "",
    jwt: []const u8 = "",

    fn base(self: *Github, a: Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}/idtoken?api-version=2.0", .{self.server.listen_address.getPort()});
    }

    fn serve(self: *Github) void {
        while (true) {
            const conn = self.server.accept() catch return;
            self.connection(conn);
        }
    }

    fn connection(self: *Github, conn: std.net.Server.Connection) void {
        defer conn.stream.close();
        var buf: [16 * 1024]u8 = undefined;
        var http = std.http.Server.init(conn, &buf);
        while (http.state == .ready) {
            var req = http.receiveHead() catch return;
            self.answer(&req) catch return;
        }
    }

    fn answer(self: *Github, req: *std.http.Server.Request) !void {
        const keep = std.heap.page_allocator;
        const target = req.head.target;
        var bearer: []const u8 = "";
        var accept: []const u8 = "";
        var it = req.iterateHeaders();
        while (it.next()) |hd| {
            if (std.ascii.eqlIgnoreCase(hd.name, "authorization")) bearer = try keep.dupe(u8, hd.value);
            if (std.ascii.eqlIgnoreCase(hd.name, "accept")) accept = try keep.dupe(u8, hd.value);
        }
        var audience: []const u8 = "";
        if (std.mem.indexOf(u8, target, "audience=")) |at| {
            const rest = target[at + "audience=".len ..];
            audience = try keep.dupe(u8, rest[0 .. std.mem.indexOfScalar(u8, rest, '&') orelse rest.len]);
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!std.mem.startsWith(u8, target, "/idtoken?")) return req.respond("{}", .{ .status = .not_found, .keep_alive = false });
        self.calls += 1;
        self.audience = audience;
        self.bearer = bearer;
        self.accept = accept;
        if (self.refuse) return req.respond("{\"message\":\"no\"}", .{ .status = .forbidden, .keep_alive = false });
        const enc = std.base64.url_safe_no_pad.Encoder;
        const payload = try std.fmt.allocPrint(keep, "{{\"repository\":\"{s}\",\"aud\":\"{s}\"}}", .{ repository, audience });
        const head_part = try keep.alloc(u8, enc.calcSize(15));
        _ = enc.encode(head_part, "{\"alg\":\"RS256\"}");
        const payload_part = try keep.alloc(u8, enc.calcSize(payload.len));
        _ = enc.encode(payload_part, payload);
        self.jwt = try std.fmt.allocPrint(keep, "{s}.{s}.c2ln", .{ head_part, payload_part });
        const body = try std.fmt.allocPrint(keep, "{{\"count\":1,\"value\":\"{s}\"}}", .{self.jwt});
        try req.respond(body, .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }}, .keep_alive = false });
    }
};

// ---------------------------------------------------------------- the program

const Out = struct { code: u8, stdout: []u8, stderr: []u8 };

/// What the environment of a run says about being in Actions.
const Ci = enum { none, both, url_only, token_only };

const Mopm = struct {
    a: Allocator,
    exe: []const u8,
    /// This process's environment without MOPM_TOKEN and the Actions variables.
    env: std.process.EnvMap,
    everything: *std.ArrayList(u8),
    github_url: []const u8,

    fn run(m: Mopm, args: []const []const u8, ci: Ci, token: ?[]const u8) !Out {
        const argv = try m.a.alloc([]const u8, args.len + 1);
        argv[0] = m.exe;
        @memcpy(argv[1..], args);
        var env = try h.cloneEnv(m.a, &m.env);
        if (token) |t| try env.put("MOPM_TOKEN", t);
        if (ci == .both or ci == .url_only) try env.put("ACTIONS_ID_TOKEN_REQUEST_URL", m.github_url);
        if (ci == .both or ci == .token_only) try env.put("ACTIONS_ID_TOKEN_REQUEST_TOKEN", request_secret);
        const r = try std.process.Child.run(.{ .allocator = m.a, .argv = argv, .env_map = &env, .max_output_bytes = 1 << 22 });
        try m.everything.appendSlice(r.stdout);
        try m.everything.appendSlice(r.stderr);
        return .{ .code = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        }, .stdout = r.stdout, .stderr = r.stderr };
    }
};

fn tomlText(a: Allocator, name: []const u8, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "[package]\nname = \"{s}\"\nversion = \"{s}\"\n\n[toolchain]\nmojo = \"1.0.0\"\n", .{ name, version });
}

fn sha256Hex(a: Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

/// Writes a staged directory of `uploads` (name, version) pairs, one file each under `noarch/`.
fn stage(a: Allocator, dir: []const u8, members: []const [2][]const u8) !void {
    var plan = std.ArrayList(u8).init(a);
    try plan.appendSlice("{\"version\":1,\"members\":[");
    for (members, 0..) |m, i| {
        if (i != 0) try plan.append(',');
        const filename = try std.fmt.allocPrint(a, "mojo-{s}-{s}-mojo1.0.0_0.conda", .{ m[0], m[1] });
        const bytes = try std.fmt.allocPrint(a, "the bytes of {s}", .{m[0]});
        try h.writeFile(try h.join(a, &.{ dir, "noarch", filename }), bytes);
        try plan.writer().print(
            "{{\"name\":\"{s}\",\"version\":\"{s}\",\"action\":\"upload\",\"manifest_sha256\":\"{s}\",\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}]}}",
            .{ m[0], m[1], try sha256Hex(a, m[0]), filename, try sha256Hex(a, bytes), bytes.len },
        );
    }
    try plan.appendSlice("]}");
    try h.writeFile(try h.join(a, &.{ dir, "plan.json" }), plan.items);
}

fn served(a: Allocator, fake: h.Fake, name: []const u8, version: []const u8) !?h.Response {
    const r = try h.request(a, "GET", fake.base, try std.fmt.allocPrint(a, "/api/v1/packages/{s}/{s}", .{ name, version }), null, null);
    return if (r.status == 200) r else null;
}

fn exists(path: []const u8) bool {
    return if (std.fs.cwd().access(path, .{})) true else |_| false;
}

fn describe(a: Allocator, r: Out) []const u8 {
    return std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }) catch "";
}

// ------------------------------------------------------------------- the test

test "mopm publish --oidc against the fake registry and a stand-in for GitHub" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var rep = h.Report{};
    try h.watchdog(120);
    const mopm_exe = try h.toolPath(a, "MOPM");
    const fake_exe = try h.toolPath(a, "MOPM_FAKE_REGISTRY");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try h.tmpPath(a, &tmp);

    h.stage = "starting the stand-in for GitHub";
    const gh = try a.create(Github);
    gh.* = .{ .server = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true }) };
    const thread = try std.Thread.spawn(.{}, Github.serve, .{gh});
    thread.detach();

    var env = try h.environ(a);
    env.remove("MOPM_TOKEN");
    env.remove("ACTIONS_ID_TOKEN_REQUEST_URL");
    env.remove("ACTIONS_ID_TOKEN_REQUEST_TOKEN");
    var everything = std.ArrayList(u8).init(a);
    const m = Mopm{ .a = a, .exe = mopm_exe, .env = env, .everything = &everything, .github_url = try gh.base(a) };

    h.stage = "starting the fake registry";
    var fake = try h.Fake.start(a, fake_exe, try h.join(a, &.{ work, "fake" }));
    defer fake.close();

    // An account that owns two names; only one has a trusted publisher, the repository the stand-in's tokens name.
    const session = h.jsonString(try fake.control(a, "/session", "{\"handle\":\"ci-owner\"}"), "token") orelse "";
    for ([_][]const u8{ "oidcdemo", "untrusted" }) |n| {
        const r = try h.request(a, "POST", fake.base, try std.fmt.allocPrint(a, "/api/v1/packages/{s}/claim", .{n}), "{}", session);
        rep.check(try std.fmt.allocPrint(a, "{s} is claimed", .{n}), r.status == 201, r.body);
    }
    _ = try fake.control(a, "/trusted", "{\"name\":\"oidcdemo\",\"repository\":\"" ++ repository ++ "\"}");

    const conf = try h.join(a, &.{ work, "conf" });
    const mojoc = try h.join(a, &.{ work, "pkg", "demo.mojoc" });
    try h.writeFile(mojoc, "not a real mojoc, only bytes\n");
    const trusted_toml = try h.join(a, &.{ work, "pkg", "mopm.toml" });
    try h.writeFile(trusted_toml, try tomlText(a, "oidcdemo", "0.1.0"));
    const untrusted_toml = try h.join(a, &.{ work, "untrusted", "mopm.toml" });
    try h.writeFile(untrusted_toml, try tomlText(a, "untrusted", "0.1.0"));
    const publish = [_][]const u8{ "publish", "--compiler", "1.0.0", "--mojoc", mojoc, "--config-dir", conf, "--oidc" };
    const to_fake = [_][]const u8{ "--registry", fake.base };
    const to_dead = [_][]const u8{ "--registry", dead };
    const with_trusted = [_][]const u8{ "--manifest", trusted_toml };
    const with_untrusted = [_][]const u8{ "--manifest", untrusted_toml };

    // --- outside Actions: stopped before any request
    for ([_]Ci{ .none, .url_only, .token_only }) |ci| {
        const r = try m.run(&(publish ++ with_trusted ++ to_dead), ci, null);
        rep.check(try std.fmt.allocPrint(a, "--oidc with {s} stops before any request and says what the job needs", .{@tagName(ci)}), r.code == 1 and
            h.contains(r.stderr, "GitHub Actions job") and h.contains(r.stderr, "id-token: write") and h.contains(r.stderr, "mopm login") and
            !h.contains(r.stderr, "cannot reach") and r.stdout.len == 0, describe(a, r));
    }
    rep.check("and GitHub was asked nothing", gh.calls == 0, "the stand-in was called");

    // --- --dry-run reads no environment and sends nothing
    var r = try m.run(&(publish ++ with_trusted ++ to_dead ++ [_][]const u8{"--dry-run"}), .none, null);
    rep.check("--dry-run --oidc outside Actions packs and sends nothing", r.code == 0 and h.contains(r.stdout, "dry run: nothing was sent") and gh.calls == 0, describe(a, r));
    r = try m.run(&.{ "pack", "--compiler", "1.0.0", "--mojoc", mojoc, "--manifest", trusted_toml, "--oidc" }, .both, null);
    rep.check("pack does not know --oidc", r.code == 2 and h.contains(r.stderr, "unexpected argument '--oidc'"), describe(a, r));

    // --- GitHub refuses the identity request
    gh.mutex.lock();
    gh.refuse = true;
    gh.mutex.unlock();
    r = try m.run(&(publish ++ with_trusted ++ to_fake), .both, null);
    rep.check("a GitHub that refuses the identity request ends 1, says so, and publishes nothing", r.code == 1 and
        h.contains(r.stderr, "GitHub refused the identity token request (HTTP 403)") and h.contains(r.stderr, "id-token: write") and
        gh.calls == 1 and (try served(a, fake, "oidcdemo", "0.1.0")) == null, describe(a, r));
    gh.mutex.lock();
    gh.refuse = false;
    gh.calls = 0;
    gh.mutex.unlock();

    // --- the registry refuses the exchange: the package has no trusted publisher
    r = try m.run(&(publish ++ with_untrusted ++ to_fake), .both, null);
    rep.check("a refused exchange ends 1 with the registry's message, and publishes nothing", r.code == 1 and
        h.contains(r.stderr, "refused the identity token for untrusted 0.1.0") and h.contains(r.stderr, "No trusted publisher of 'untrusted' matches this CI identity") and
        gh.calls == 1 and (try served(a, fake, "untrusted", "0.1.0")) == null, describe(a, r));
    gh.calls = 0;

    // --- a publish: the token is the job's, whatever MOPM_TOKEN says
    r = try m.run(&(publish ++ with_trusted ++ to_fake), .both, "bogus-token-that-must-not-be-used");
    rep.check("--oidc publishes with the exchanged token, not with MOPM_TOKEN", r.code == 0 and h.contains(r.stdout, "published mojo-oidcdemo 0.1.0"), describe(a, r));
    const version = try served(a, fake, "oidcdemo", "0.1.0");
    rep.check("the version is served, and its provenance names the trusted repository (only the exchange gives that)", version != null and
        h.contains(version.?.body, "\"kind\":\"oidc\"") and h.contains(version.?.body, "\"repository\":\"" ++ repository ++ "\""), if (version) |v| v.body else "not served");
    gh.mutex.lock();
    const asked_once = gh.calls == 1;
    const audience_ok = std.mem.eql(u8, gh.audience, "beta.mopm.dev");
    const bearer_ok = std.mem.eql(u8, gh.bearer, "Bearer " ++ request_secret);
    const accept_ok = h.contains(gh.accept, "application/json");
    const jwt = gh.jwt;
    gh.mutex.unlock();
    rep.check("GitHub was asked once, for the audience of a beta registry, with the request token as the bearer", asked_once and audience_ok and bearer_ok and accept_ok, "the request was not as expected");
    rep.check("the token is in memory only: no credentials file was written", !exists(conf), "the config directory exists");

    // --- the same version again is the registry's refusal, and a fresh identity token was asked for
    r = try m.run(&(publish ++ with_trusted ++ to_fake), .both, null);
    rep.check("a second run exchanges a new identity token and gets the registry's own answer for a version it holds", r.code == 1 and h.contains(r.stderr, "'oidcdemo' 0.1.0 already exists") and gh.calls == 2 and
        !h.contains(r.stderr, "GitHub"), describe(a, r));

    // --- --staged
    const one = try h.join(a, &.{ work, "staged_one" });
    try stage(a, one, &.{.{ "oidcdemo", "0.2.0" }});
    const three = try h.join(a, &.{ work, "staged_three" });
    try stage(a, three, &.{ .{ "oidcdemo", "0.3.0" }, .{ "untrusted", "0.3.0" }, .{ "other", "0.3.0" } });
    const staged_base = [_][]const u8{ "publish", "--staged", one, "--config-dir", conf, "--oidc", "--wait", "30" };
    gh.calls = 0;

    r = try m.run(&(staged_base ++ to_dead), .none, null);
    rep.check("--staged --oidc outside Actions stops before any request", r.code == 1 and h.contains(r.stderr, "GitHub Actions job") and
        !h.contains(r.stderr, "cannot reach") and gh.calls == 0 and !exists(try h.join(a, &.{ one, "state.json" })), describe(a, r));

    r = try m.run(&.{ "publish", "--staged", one, "--registry", dead, "--oidc", "--dry-run" }, .none, null);
    rep.check("--staged --oidc --dry-run reads no environment and sends nothing", r.code == 0 and h.contains(r.stdout, "dry run: nothing was sent"), describe(a, r));

    r = try m.run(&.{ "publish", "--staged", three, "--config-dir", conf, "--oidc", "--registry", fake.base }, .both, null);
    rep.check("a set of three members is refused before GitHub or the registry is asked", r.code == 1 and h.contains(r.stderr, "mints a token for one package version") and
        h.contains(r.stderr, "uploads 3 members") and gh.calls == 0 and !exists(try h.join(a, &.{ three, "state.json" })), describe(a, r));

    r = try m.run(&(staged_base ++ to_fake), .both, null);
    gh.mutex.lock();
    const staged_audience = gh.audience;
    const staged_calls = gh.calls;
    gh.mutex.unlock();
    rep.check("a set of one member asks GitHub once and sends the exchanged token, which the registry answers as for any identity token", r.code == 1 and
        staged_calls == 1 and std.mem.eql(u8, staged_audience, "beta.mopm.dev") and
        h.contains(r.stderr, "does not have the 'publish' scope for 'oidcdemo'") and !h.contains(r.stderr, "GitHub") and
        (try served(a, fake, "oidcdemo", "0.2.0")) == null, describe(a, r));
    rep.check("and no credentials file was written by either command", !exists(conf), "the config directory exists");

    // --- nothing secret was printed
    gh.mutex.lock();
    const last_jwt = gh.jwt;
    gh.mutex.unlock();
    var leaked = false;
    for ([_][]const u8{ request_secret, jwt, last_jwt, "bogus-token-that-must-not-be-used" }) |s| {
        if (s.len > 0 and h.contains(everything.items, s)) leaked = true;
    }
    rep.check("neither the request token, nor an identity token, nor MOPM_TOKEN is ever printed", !leaked, "a token was printed");
    try rep.finish();
}
