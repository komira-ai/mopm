//! End to end: runs the built `web-login` Lambda `bootstrap` against a fake Lambda runtime API, a fake DynamoDB and a fake
//! Secrets Manager, all one server on loopback, sends it one API Gateway v2 (payload format 2.0) event, a top-level
//! navigation to `GET /api/v2/auth/web/start?return_to=/tutorial/hello`, and holds the response it posts back.
//!
//! What it proves: the binary starts as a custom runtime with only `AWS_LAMBDA_FUNCTION_NAME` of its own configuration;
//! reads the stage's settings (DynamoDB GetItem of `stage_settings` in `mopm-e2e-config`) and the secrets
//! `mopm/e2e/edge-origin` and `mopm/e2e/github-oauth` (Secrets Manager) through the AWS SDK; builds its HTTPS client from
//! the system's roots (`SSL_CERT_FILE`, a test CA written here: the farm has none); takes the event through the edge check;
//! stores the login transaction (PutItem into `mopm-e2e-web_logins`); and posts a 302 to GitHub's authorize URL with the
//! login cookie. What it catches: a binary that does not start (a missing symbol, the wrong glibc, no roots), a change of
//! the runtime protocol or of the SDK's wire, a start that reads a variable it should not need, and a changed answer.
//!
//! The build gives it the executable in $BOOTSTRAP. No network but loopback; no timer: it waits for the response post (or for
//! the bootstrap to end).

const std = @import("std");

const event =
    \\{"version":"2.0","routeKey":"GET /api/v2/auth/web/start","rawPath":"/api/v2/auth/web/start","rawQueryString":"return_to=%2Ftutorial%2Fhello",
    \\"headers":{"host":"api.mopm.test","x-mopm-edge":"e2e-edge-origin-value","sec-fetch-mode":"navigate","sec-fetch-dest":"document","sec-fetch-site":"none"},
    \\"requestContext":{"accountId":"example","apiId":"api","domainName":"api.mopm.test","domainPrefix":"api",
    \\"http":{"method":"GET","path":"/api/v2/auth/web/start","protocol":"HTTP/1.1","sourceIp":"192.0.2.1","userAgent":"test"},
    \\"requestId":"req-1","routeKey":"GET /api/v2/auth/web/start","stage":"$default","time":"01/Jan/2026:00:00:00 +0000","timeEpoch":1767225600000},
    \\"isBase64Encoded":false}
;

/// The item `stage_settings` of `mopm-e2e-config`, as DynamoDB's GetItem answers it.
const settings_answer =
    \\{"Item":{"key":{"S":"stage_settings"},"redirect_uri":{"S":"https://mopm.test/api/v2/auth/web/callback"},
    \\"site_origin":{"S":"https://mopm.test"},"require_two_factor":{"BOOL":true},"e2b_template_id":{"S":"tpl-e2e"},
    \\"e2b_domain":{"S":"e2b.test"},"sandbox_timeout_seconds":{"N":"1800"}}}
;

const edge_answer =
    \\{"Name":"mopm/e2e/edge-origin","SecretString":"e2e-edge-origin-value"}
;

const oauth_answer =
    \\{"Name":"mopm/e2e/github-oauth","SecretString":"{\"client_id\":\"Ov23liE2eClient00\",\"client_secret\":\"e2e-client-secret-value\"}"}
;

/// What the function must send GitHub's authorize page, as far as it is fixed (the state and the challenge are random).
const location_prefix = "https://github.com/login/oauth/authorize?client_id=Ov23liE2eClient00&redirect_uri=https%3A%2F%2Fmopm.test%2Fapi%2Fv2%2Fauth%2Fweb%2Fcallback&scope=read%3Auser&state=";
const cookie_prefix = "\"cookies\":[\"__Host-mopm_login=";
const cookie_suffix = "; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=600\"]";

/// A test CA (EC P-256), the only root the function trusts: the same certificate as service/lambda/aws/tests/fixtures/ca.pem.
const ca_pem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBkDCCATagAwIBAgIUZ7Iw9vJth7uNDy0gG5x69KiP3MowCgYIKoZIzj0EAwIw
    \\JTEjMCEGA1UEAwwabW9wbV9hd3MgdGVzdCBDQSAodHJ1c3RlZCkwIBcNMjYxMTIw
    \\MDYwNTU4WhgPMjEyNjEwMjcwNjA1NThaMCUxIzAhBgNVBAMMGm1vcG1fYXdzIHRl
    \\c3QgQ0EgKHRydXN0ZWQpMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEqM9flkpN
    \\U0quSYc/G7Z7PtCKIwUfFbXO1xgyaXZShpTCS5+Ic8Ry6qRqdLqHvNYEHLoCudg/
    \\t7X1W/eTnbrutqNCMEAwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYw
    \\HQYDVR0OBBYEFA97prBeIvXwLGGnIVDfS8TFROCyMAoGCCqGSM49BAMCA0gAMEUC
    \\IQD8D3pp5F9xK4izr7fFv4ZmOsR0zUhSVDAA0akzXvgVNQIgXIpUEmooeJJfbsdO
    \\GXE5niGCIBmGZK5eBQMaiK1MjuM=
    \\-----END CERTIFICATE-----
    \\
;

const response_path = "/2018-06-01/runtime/invocation/req-1/response";

const State = struct {
    mu: std.Thread.Mutex = .{},
    gpa: std.mem.Allocator,
    nexts: u32 = 0,
    posted_path: ?[]u8 = null,
    posted_body: ?[]u8 = null,
    put_body: ?[]u8 = null,
    other: ?[]u8 = null,
    /// Set (progress event) when the runtime API saw the response post, or any call it did not expect.
    finished: std.Thread.ResetEvent = .{},
    /// Set (progress event) when the bootstrap's stdout reached EOF: the process is gone or going.
    exited: bool = false,
    /// What the bootstrap wrote to stdout and stderr (its log lines and any start error), shown when the test fails.
    output: std.ArrayListUnmanaged(u8) = .{},
};

/// Drains the bootstrap's stdout until EOF, which is the process ending, then signals `finished` so the
/// test fails at once on a bootstrap that dies instead of waiting on a clock. Keeps what it read.
fn watchChild(state: *State, file: std.fs.File) void {
    drainInto(state, file);
    state.mu.lock();
    state.exited = true;
    state.mu.unlock();
    state.finished.set();
}

/// Drains the bootstrap's stderr into the kept output.
fn watchStderr(state: *State, file: std.fs.File) void {
    drainInto(state, file);
}

fn drainInto(state: *State, file: std.fs.File) void {
    var tmp: [1024]u8 = undefined;
    while (true) {
        const n = file.read(&tmp) catch break;
        if (n == 0) break;
        state.mu.lock();
        state.output.appendSlice(state.gpa, tmp[0..n]) catch {};
        state.mu.unlock();
    }
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(l[0..colon], name)) return std.mem.trim(u8, l[colon + 1 ..], " ");
    }
    return null;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn reply(state: *State, stream: std.net.Stream, content_type: []const u8, body: []const u8) !void {
    var out = std.ArrayList(u8).init(state.gpa);
    defer out.deinit();
    try out.writer().print("HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ content_type, body.len, body });
    try stream.writeAll(out.items);
}

fn unexpected(state: *State, stream: std.net.Stream, what: []const u8) !void {
    state.mu.lock();
    state.other = try state.gpa.dupe(u8, what);
    state.mu.unlock();
    state.finished.set();
    try stream.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
}

fn serve(state: *State, stream: std.net.Stream) !void {
    var buf = std.ArrayList(u8).init(state.gpa);
    defer buf.deinit();
    while (true) {
        var head_end: usize = 0;
        while (true) {
            if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |i| {
                head_end = i + 4;
                break;
            }
            var tmp: [4096]u8 = undefined;
            const n = try stream.read(&tmp);
            if (n == 0) return;
            try buf.appendSlice(tmp[0..n]);
        }
        const head = try state.gpa.dupe(u8, buf.items[0..head_end]);
        defer state.gpa.free(head);
        const cl: usize = if (headerValue(head, "content-length")) |v| try std.fmt.parseInt(usize, v, 10) else 0;
        while (buf.items.len < head_end + cl) {
            var tmp: [4096]u8 = undefined;
            const n = try stream.read(&tmp);
            if (n == 0) return;
            try buf.appendSlice(tmp[0..n]);
        }
        const body = try state.gpa.dupe(u8, buf.items[head_end .. head_end + cl]);
        try buf.replaceRange(0, head_end + cl, &.{});

        var rl = std.mem.splitScalar(u8, head[0 .. std.mem.indexOf(u8, head, "\r\n").?], ' ');
        const method = rl.next().?;
        const path = rl.next().?;
        const target = headerValue(head, "x-amz-target") orelse "";

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/2018-06-01/runtime/invocation/next")) {
            state.mu.lock();
            state.nexts += 1;
            const first = state.nexts == 1;
            state.mu.unlock();
            state.gpa.free(body);
            if (!first) {
                // The runtime asks for the next event: there is none. Hold the request open by
                // blocking on the socket until the peer goes away (the test kills the bootstrap).
                var drain: [256]u8 = undefined;
                while ((stream.read(&drain) catch 0) != 0) {}
                return;
            }
            var out = std.ArrayList(u8).init(state.gpa);
            defer out.deinit();
            try out.writer().print(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
                    "Lambda-Runtime-Aws-Request-Id: req-1\r\n" ++
                    "Lambda-Runtime-Deadline-Ms: 32503680000000\r\n" ++
                    "Lambda-Runtime-Invoked-Function-Arn: arn:aws:lambda:us-east-1:" ++ "0" ** 12 ++ ":function:mopm-e2e-web-login\r\n" ++
                    "Lambda-Runtime-Trace-Id: Root=1-00000000-000000000000000000000000\r\n" ++
                    "Content-Length: {d}\r\n\r\n{s}",
                .{ event.len, event },
            );
            try stream.writeAll(out.items);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, response_path)) {
            state.mu.lock();
            state.posted_path = try state.gpa.dupe(u8, path);
            state.posted_body = body;
            state.mu.unlock();
            state.finished.set();
            try stream.writeAll("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n");
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/") and std.mem.eql(u8, target, "DynamoDB_20120810.GetItem")) {
            defer state.gpa.free(body);
            if (!contains(body, "\"TableName\":\"mopm-e2e-config\"") or !contains(body, "stage_settings")) {
                try unexpected(state, stream, try std.fmt.allocPrint(state.gpa, "GetItem: {s}", .{body}));
            } else {
                try reply(state, stream, "application/x-amz-json-1.0", settings_answer);
            }
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/") and std.mem.eql(u8, target, "DynamoDB_20120810.PutItem")) {
            state.mu.lock();
            state.put_body = body;
            state.mu.unlock();
            try reply(state, stream, "application/x-amz-json-1.0", "{}");
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/") and std.mem.eql(u8, target, "secretsmanager.GetSecretValue")) {
            defer state.gpa.free(body);
            if (contains(body, "mopm/e2e/edge-origin")) {
                try reply(state, stream, "application/x-amz-json-1.1", edge_answer);
            } else if (contains(body, "mopm/e2e/github-oauth")) {
                try reply(state, stream, "application/x-amz-json-1.1", oauth_answer);
            } else {
                try unexpected(state, stream, try std.fmt.allocPrint(state.gpa, "GetSecretValue: {s}", .{body}));
            }
        } else {
            state.gpa.free(body);
            try unexpected(state, stream, try std.fmt.allocPrint(state.gpa, "{s} {s} {s}", .{ method, path, target }));
        }
    }
}

fn connThread(state: *State, stream: std.net.Stream) void {
    defer stream.close();
    serve(state, stream) catch {};
}

fn acceptLoop(state: *State, server: *std.net.Server) void {
    while (true) {
        const c = server.accept() catch return;
        const t = std.Thread.spawn(.{}, connThread, .{ state, c.stream }) catch return;
        t.detach();
    }
}

test "bootstrap starts from settings and secrets, and answers one start event with the redirect to GitHub" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const exe = try std.process.getEnvVarOwned(a, "BOOTSTRAP");

    // The test CA is the function's only root certificate: SSL_CERT_FILE names it, and nothing else is read.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile("ca.pem", .{});
        defer f.close();
        try f.writeAll(ca_pem);
    }
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const ca_path = try std.fs.path.join(a, &.{ dir, "ca.pem" });
    const absent = try std.fs.path.join(a, &.{ dir, "absent" });

    // Connection threads allocate too, so the state's allocator is the thread-safe page allocator, not the arena.
    var state = State{ .gpa = std.heap.page_allocator };
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();
    const port = server.listen_address.getPort();
    const accept = try std.Thread.spawn(.{}, acceptLoop, .{ &state, &server });
    accept.detach();

    // The function's whole environment: its name, the runtime API, the SDK's endpoint, credentials and region, no config
    // file, no instance metadata, and the roots. Nothing is inherited.
    var env = std.process.EnvMap.init(a);
    try env.put("AWS_LAMBDA_RUNTIME_API", try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{port}));
    try env.put("AWS_LAMBDA_FUNCTION_NAME", "mopm-e2e-web-login");
    try env.put("AWS_LAMBDA_FUNCTION_VERSION", "$LATEST");
    try env.put("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "128");
    try env.put("AWS_LAMBDA_LOG_GROUP_NAME", "/aws/lambda/mopm-e2e-web-login");
    try env.put("AWS_LAMBDA_LOG_STREAM_NAME", "stream");
    try env.put("AWS_REGION", "us-east-1");
    try env.put("AWS_ENDPOINT_URL", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{port}));
    try env.put("AWS_ACCESS_KEY_ID", "AKIDE2ETEST");
    try env.put("AWS_SECRET_ACCESS_KEY", "e2e-test-secret-access-key");
    try env.put("AWS_CONFIG_FILE", absent);
    try env.put("AWS_SHARED_CREDENTIALS_FILE", absent);
    try env.put("AWS_EC2_METADATA_DISABLED", "true");
    try env.put("HOME", dir);
    try env.put("SSL_CERT_FILE", ca_path);

    var child = std.process.Child.init(&.{exe}, a);
    child.env_map = &env;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const watcher = try std.Thread.spawn(.{}, watchChild, .{ &state, child.stdout.? });
    const err_watcher = try std.Thread.spawn(.{}, watchStderr, .{ &state, child.stderr.? });

    // Wait for a progress event, not for a clock: the response post, an unexpected call, or the
    // bootstrap ending. Kill with the pid still unreaped (child.wait reaps it after the join).
    state.finished.wait();
    std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
    watcher.join();
    err_watcher.join();
    _ = child.wait() catch {};

    state.mu.lock();
    defer state.mu.unlock();
    if (state.other) |o| {
        std.debug.print("unexpected call: {s}\n", .{o});
        return error.UnexpectedCall;
    }
    const body = state.posted_body orelse {
        std.debug.print("bootstrap posted no response (exited: {}); its output:\n{s}\n", .{ state.exited, state.output.items });
        return error.NoResponse;
    };
    try std.testing.expectEqualStrings(response_path, state.posted_path.?);
    try std.testing.expect(contains(body, "\"statusCode\":302"));
    try std.testing.expect(contains(body, "\"location\":\"" ++ location_prefix));
    try std.testing.expect(contains(body, cookie_prefix));
    try std.testing.expect(contains(body, cookie_suffix));
    try std.testing.expect(!contains(body, "e2e-client-secret-value"));
    // The login transaction was stored in the stage's web_logins table, with the return_to the request named.
    const put = state.put_body orelse return error.NoLoginStored;
    try std.testing.expect(contains(put, "\"TableName\":\"mopm-e2e-web_logins\""));
    try std.testing.expect(contains(put, "/tutorial/hello"));
}
