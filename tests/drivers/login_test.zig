//! End-to-end tests of mopm's registry commands against mopm-fake-registry:
//! the Zig port of tests/registry_e2e/run.py (deleted with this port).
//!
//! Run by Buck2 (//:registry_login): MOPM and MOPM_FAKE_REGISTRY are
//! the built programs. Each check prints `ok` or `FAIL`. The refusals are
//! checked as well as the successes, so each check can go red: a registry URL
//! that is not https or loopback http, a config.json that names one, a login
//! that is denied, a token that has expired.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

/// A registry whose config.json names a plain-http, non-loopback API; every
/// GET gets it. Served from a thread that lives until the process ends.
const BadConfig = struct {
    server: std.net.Server,

    fn serve(self: *BadConfig) void {
        while (true) {
            const conn = self.server.accept() catch return;
            defer conn.stream.close();
            var buf: [8192]u8 = undefined;
            var http = std.http.Server.init(conn, &buf);
            var req = http.receiveHead() catch continue;
            const body =
                \\{"index_version":1,"stage":"beta","api_url":"http://registry.example/api/v1","channel_url":"https://conda.example/","min_cli_version":"0.0.1"}
            ;
            req.respond(body, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }}, .keep_alive = false }) catch {};
        }
    }
};

const Mopm = struct {
    a: Allocator,
    exe: []const u8,
    env: std.process.EnvMap,

    fn run(m: Mopm, args: []const []const u8) !Out {
        const argv = try m.a.alloc([]const u8, args.len + 1);
        argv[0] = m.exe;
        @memcpy(argv[1..], args);
        const r = try std.process.Child.run(.{ .allocator = m.a, .argv = argv, .env_map = &m.env, .max_output_bytes = 1 << 22 });
        return .{ .code = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        }, .stdout = r.stdout, .stderr = r.stderr };
    }
};

const Out = struct { code: u8, stdout: []u8, stderr: []u8 };

/// The code after "enter the code " in `line`, or null.
fn codeIn(line: []const u8) ?[]const u8 {
    const marker = "enter the code ";
    const at = std.mem.indexOf(u8, line, marker) orelse return null;
    const rest = line[at + marker.len ..];
    const end = std.mem.indexOfAny(u8, rest, " \r\n") orelse rest.len;
    return rest[0..end];
}

/// Starts `mopm login <flags>`, reads its first line and returns the child
/// and that line.
fn startLogin(a: Allocator, m: Mopm, flags: []const []const u8) !struct { child: std.process.Child, first: []u8 } {
    const argv = try a.alloc([]const u8, flags.len + 2);
    argv[0] = m.exe;
    argv[1] = "login";
    @memcpy(argv[2..], flags);
    var child = std.process.Child.init(argv, a);
    child.env_map = &m.env;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const first = try h.readLine(a, child.stdout.?);
    return .{ .child = child, .first = first };
}

/// The rest of the child's output; its exit status.
fn finishLogin(a: Allocator, child: *std.process.Child) !struct { code: u8, stdout: []u8, stderr: []u8 } {
    const out = try child.stdout.?.reader().readAllAlloc(a, 1 << 20);
    const err = try child.stderr.?.reader().readAllAlloc(a, 1 << 20);
    const term = try child.wait();
    return .{ .code = switch (term) {
        .Exited => |c| c,
        else => 255,
    }, .stdout = out, .stderr = err };
}

test "mopm login, whoami and logout against the fake registry" {
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
    const conf = try h.join(a, &.{ work, "conf" });

    h.stage = "starting the fake registry";
    var fake = try h.Fake.start(a, fake_exe, try h.join(a, &.{ work, "fake" }));
    defer fake.close();
    const m = Mopm{ .a = a, .exe = mopm_exe, .env = try h.environ(a) };
    const flags = [_][]const u8{ "--registry", fake.base, "--config-dir", conf };
    const api = try fake.api(a);
    const whoami_args = [_][]const u8{ "whoami", "--registry", fake.base, "--config-dir", conf };
    const logout_args = [_][]const u8{ "logout", "--registry", fake.base, "--config-dir", conf };

    var r = try m.run(&.{ "whoami", "--registry", "http://example.com", "--config-dir", conf });
    rep.check("a plain-http registry that is not loopback is refused", r.code == 1 and h.contains(r.stderr, "plain http only to 127.0.0.1"), r.stderr);
    r = try m.run(&.{ "whoami", "--registry", "staging", "--config-dir", conf });
    rep.check("an unknown registry name is refused", r.code == 1 and h.contains(r.stderr, "a registry is prod, gamma, beta, or a URL"), r.stderr);

    {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        const server = try addr.listen(.{ .reuse_address = true });
        const bad = try a.create(BadConfig);
        bad.* = .{ .server = server };
        const thread = try std.Thread.spawn(.{}, BadConfig.serve, .{bad});
        thread.detach();
        const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{server.listen_address.getPort()});
        r = try m.run(&.{ "whoami", "--registry", url, "--config-dir", conf });
        rep.check("a config.json that names a non-loopback http URL is refused", r.code == 1 and h.contains(r.stderr, "plain http only to a loopback host"), r.stderr);
    }

    r = try m.run(&whoami_args);
    rep.check("whoami before login says so", r.code == 1 and h.contains(r.stderr, "not logged in to beta; run 'mopm login'"), r.stderr);

    // Login, approved on the fake's approval page.
    var token: []const u8 = "";
    var path: []const u8 = "";
    {
        var login = try startLogin(a, m, &flags);
        const code = codeIn(login.first);
        rep.check("login prints a code to enter", code != null, login.first);
        if (code) |cd| {
            const body = try std.fmt.allocPrint(a, "{{\"user_code\":\"{s}\",\"decision\":\"approve\",\"handle\":\"e2e-user\"}}", .{cd});
            _ = try fake.control(a, "/device", body);
        }
        const rest = try finishLogin(a, &login.child);
        const out = try std.mem.concat(a, u8, &.{ login.first, "\n", rest.stdout });
        rep.check("an approved login succeeds", rest.code == 0 and h.contains(out, "Logged in to beta as e2e-user."), rest.stderr);
        path = try h.join(a, &.{ conf, "credentials.json" });
        const exists = if (std.fs.cwd().access(path, .{})) true else |_| false;
        rep.check("the token file exists", exists, path);
        if (exists) {
            const st = try std.fs.cwd().statFile(path);
            rep.check("the token file is mode 0600", st.mode & 0o777 == 0o600, "wrong mode");
            const creds = try h.parseJson(a, try h.readFile(a, path));
            const entry = creds.object.get(api).?;
            token = h.jsonString(entry, "token") orelse "";
            rep.check("the token is a token", std.mem.startsWith(u8, token, "mopm_"), token);
            rep.check("the token is never printed", !h.contains(out, token) and !h.contains(rest.stderr, token), "printed");
        }
    }

    r = try m.run(&whoami_args);
    rep.check("whoami names the account", r.code == 0 and hasWhoami(r.stdout), r.stdout);

    // A session lives 30 days: past that the registry refuses it, and mopm
    // prints the contract's message, hint and request id.
    _ = try fake.control(a, "/clock", "{\"advance_seconds\":2678400}");
    r = try m.run(&whoami_args);
    rep.check("an expired token is reported with hint and request id", r.code == 1 and h.contains(r.stderr, "The token expired at") and
        h.contains(r.stderr, "hint: Create a new token.") and h.contains(r.stderr, "request id: fake-"), r.stderr);

    r = try m.run(&logout_args);
    {
        const creds = try h.parseJson(a, try h.readFile(a, path));
        rep.check("logout removes the token", r.code == 0 and h.contains(r.stdout, "Logged out of beta.") and creds.object.get(api) == null, r.stdout);
    }
    r = try m.run(&logout_args);
    rep.check("a second logout says there is nothing to remove", r.code == 0 and h.contains(r.stdout, "Not logged in to beta."), r.stdout);

    // Login, denied.
    {
        var login = try startLogin(a, m, &flags);
        if (codeIn(login.first)) |cd| {
            const body = try std.fmt.allocPrint(a, "{{\"user_code\":\"{s}\",\"decision\":\"deny\"}}", .{cd});
            _ = try fake.control(a, "/device", body);
        }
        const rest = try finishLogin(a, &login.child);
        rep.check("a denied login fails and says so", rest.code == 1 and h.contains(rest.stderr, "the login was denied"), rest.stderr);
    }

    try rep.finish();
}

/// A line `e2e-user (GitHub id <digits>) on beta`.
fn hasWhoami(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const pre = "e2e-user (GitHub id ";
        const post = ") on beta";
        if (!std.mem.startsWith(u8, line, pre) or !std.mem.endsWith(u8, line, post)) continue;
        const digits = line[pre.len .. line.len - post.len];
        if (digits.len == 0) continue;
        var all_digits = true;
        for (digits) |ch| {
            if (ch < '0' or ch > '9') all_digits = false;
        }
        if (all_digits) return true;
    }
    return false;
}
