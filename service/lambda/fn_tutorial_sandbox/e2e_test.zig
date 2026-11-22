//! End to end: runs the built tutorial-sandbox Lambda `bootstrap` against one loopback HTTP/1.1 server
//! that plays both the Lambda runtime API and the AWS endpoint (DynamoDB and Secrets Manager, JSON
//! protocol), sends it two API Gateway v2 (payload format 2.0) events and holds what it posts back and
//! what it prints, byte for byte.
//!
//! What it proves: the binary starts as a custom runtime; its cold start reads the stage settings item
//! from the `mopm-beta-config` table, the edge-origin secret and the e2b secret (absent here, which must
//! not stop it), in that order and nothing else; the AWS SDK clients it builds honour
//! `--aws-endpoint-url`; each event is decoded, refused by the gate (no session cookie, then an
//! Authorization header) before any DynamoDB tokens/users call or any E2B call; the API Gateway response
//! carries the status, the three headers and the exact error body; and exactly one JSON log line per
//! request reaches stdout. What it catches: a change to the cold-start reads or their order, to the
//! gate order, to the error envelope text or headers, to the log line shape, a secret-less start that
//! no longer starts, a binary that reads configuration from anywhere but the flag, or one that does not
//! start (missing symbol, wrong glibc).
//!
//! The build gives it the executable in $BOOTSTRAP. No network but loopback, port 0. No clock decides
//! the outcome: the test waits for a progress event (the second response, a failure, or the child's
//! stdout reaching end of file), then kills the child.

const std = @import("std");

const gpa = std.heap.page_allocator;

/// An API Gateway v2 event: a POST of the sandbox route with the given header members (JSON, no braces). Its
/// `requestContext.requestId` is the invocation's id, as API Gateway's id and Lambda's are both the request's here; the
/// function answers and logs API Gateway's.
fn eventFor(comptime id: []const u8, comptime headers: []const u8) []const u8 {
    return "{\"version\":\"2.0\",\"routeKey\":\"POST /api/v2/tutorial/sandbox\"," ++
        "\"rawPath\":\"/api/v2/tutorial/sandbox\",\"rawQueryString\":\"\"," ++
        "\"headers\":{" ++ headers ++ "}," ++
        "\"requestContext\":{\"accountId\":\"example\",\"apiId\":\"api\",\"domainName\":\"api.example\",\"domainPrefix\":\"api\"," ++
        "\"http\":{\"method\":\"POST\",\"path\":\"/api/v2/tutorial/sandbox\",\"protocol\":\"HTTP/1.1\",\"sourceIp\":\"0.0.0.0\",\"userAgent\":\"test\"}," ++
        "\"requestId\":\"" ++ id ++ "\",\"routeKey\":\"POST /api/v2/tutorial/sandbox\",\"stage\":\"$default\"," ++
        "\"time\":\"01/Dec/2026:00:00:00 +0000\",\"timeEpoch\":1796083200000}," ++
        "\"isBase64Encoded\":false}";
}

const Invocation = struct {
    id: []const u8,
    event: []const u8,
    status: i64,
    body: []const u8,
};

const invocations = [_]Invocation{
    .{
        .id = "req-e2e-1",
        .event = eventFor("req-e2e-1", "\"host\":\"api.example\",\"x-mopm-edge\":\"edge-e2e-value\""),
        .status = 401,
        .body =
        \\{"error":{"code":"session_required","message":"You are not signed in to the website.","hint":"Sign in with GitHub, then try again."}}
        ,
    },
    .{
        .id = "req-e2e-2",
        .event = eventFor("req-e2e-2", "\"host\":\"api.example\",\"x-mopm-edge\":\"edge-e2e-value\",\"authorization\":\"Bearer x\""),
        .status = 400,
        .body =
        \\{"error":{"code":"invalid_request","message":"The request is not valid: the website's routes take no Authorization header.","hint":"Check the request against the API documentation; update mopm if it is old."}}
        ,
    },
};

/// The AWS calls the cold start makes, in order, as the server labels them.
const expected_calls = [_][]const u8{
    "dynamodb GetItem mopm-beta-config stage_settings",
    "secretsmanager GetSecretValue mopm/beta/edge-origin",
    "secretsmanager GetSecretValue mopm/beta/e2b",
};

const expected_stdout =
    \\{"event":"tutorial_sandbox","outcome":"refused","reason":"session_required","request_id":"req-e2e-1"}
    \\{"event":"tutorial_sandbox","outcome":"refused","reason":"invalid_request","request_id":"req-e2e-2"}
    \\
;

const stage_settings_item =
    \\{"Item":{"key":{"S":"stage_settings"},"redirect_uri":{"S":"https://beta.mopm.dev/api/v2/auth/web/callback"},
    \\"site_origin":{"S":"https://beta.mopm.dev"},"require_2fa":{"BOOL":true},"e2b_template_id":{"S":"mopm-tutorial-beta"},
    \\"e2b_domain":{"S":"e2b.app"},"sandbox_timeout_s":{"N":"1800"}}}
;

const edge_origin_secret =
    \\{"Name":"mopm/beta/edge-origin","SecretString":"edge-e2e-value"}
;

const e2b_secret_missing =
    \\{"__type":"ResourceNotFoundException","message":"Secrets Manager can't find the specified secret."}
;

const State = struct {
    mu: std.Thread.Mutex = .{},
    /// Runtime API polls of /next seen so far.
    nexts: usize = 0,
    /// Labels of the AWS calls, in arrival order.
    calls: std.ArrayList([]u8) = std.ArrayList([]u8).init(gpa),
    /// The bodies posted to /invocation/<id>/response, in order.
    responses: std.ArrayList([]u8) = std.ArrayList([]u8).init(gpa),
    /// The first thing that went wrong (an unexpected call, an error post, a malformed request).
    failure: ?[]const u8 = null,
    /// Everything the child printed on stdout.
    stdout: std.ArrayList(u8) = std.ArrayList(u8).init(gpa),
    /// Set (progress event) on the second response, on the first failure, or when stdout reached EOF.
    finished: std.Thread.ResetEvent = .{},
    /// Set when the child's stdout reached EOF: the process is gone or going.
    exited: bool = false,
};

/// Records the first failure and wakes the test, so it fails at once instead of waiting on a clock.
fn fail(state: *State, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(gpa, fmt, args) catch "out of memory while recording a failure";
    state.mu.lock();
    if (state.failure == null) state.failure = msg;
    state.mu.unlock();
    state.finished.set();
}

/// Collects the child's stdout until EOF (the process ending), then signals `finished`.
fn watchChild(state: *State, file: std.fs.File) void {
    var tmp: [1024]u8 = undefined;
    while (true) {
        const n = file.read(&tmp) catch break;
        if (n == 0) break;
        state.mu.lock();
        state.stdout.appendSlice(tmp[0..n]) catch {};
        state.mu.unlock();
    }
    state.mu.lock();
    state.exited = true;
    state.mu.unlock();
    state.finished.set();
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

/// Reads more bytes from the peer into `buf`; EndOfStream when it closed.
fn fill(buf: *std.ArrayList(u8), stream: std.net.Stream) !void {
    var tmp: [4096]u8 = undefined;
    const n = try stream.read(&tmp);
    if (n == 0) return error.EndOfStream;
    try buf.appendSlice(tmp[0..n]);
}

/// The index of the first `needle` at or after `from`, reading more as needed.
fn findFrom(buf: *std.ArrayList(u8), stream: std.net.Stream, from: usize, needle: []const u8) !usize {
    while (true) {
        if (std.mem.indexOfPos(u8, buf.items, from, needle)) |i| return i;
        try fill(buf, stream);
    }
}

const Request = struct {
    head: []u8,
    method: []const u8,
    path: []const u8,
    body: []u8,
};

/// Reads one request (Content-Length or chunked body) from the connection, removing its bytes from
/// `buf`. Null when the peer closed between requests.
fn readRequest(buf: *std.ArrayList(u8), stream: std.net.Stream) !?Request {
    const head_end = blk: {
        while (true) {
            if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |i| break :blk i + 4;
            fill(buf, stream) catch |e| {
                if (e == error.EndOfStream and buf.items.len == 0) return null;
                return e;
            };
        }
    };
    const head = try gpa.dupe(u8, buf.items[0..head_end]);
    var body = std.ArrayList(u8).init(gpa);
    var consumed: usize = undefined;

    if (headerValue(head, "expect")) |ex| {
        if (std.ascii.eqlIgnoreCase(ex, "100-continue")) try stream.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
    }

    const chunked = if (headerValue(head, "transfer-encoding")) |te| std.ascii.indexOfIgnoreCase(te, "chunked") != null else false;
    if (chunked) {
        var pos = head_end;
        while (true) {
            const line_end = try findFrom(buf, stream, pos, "\r\n");
            const size_line = buf.items[pos..line_end];
            const semi = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
            const size = try std.fmt.parseInt(usize, std.mem.trim(u8, size_line[0..semi], " "), 16);
            pos = line_end + 2;
            if (size == 0) {
                // Skip trailer lines up to the empty line that ends the message.
                while (true) {
                    const e = try findFrom(buf, stream, pos, "\r\n");
                    const empty = e == pos;
                    pos = e + 2;
                    if (empty) break;
                }
                break;
            }
            while (buf.items.len < pos + size + 2) try fill(buf, stream);
            try body.appendSlice(buf.items[pos .. pos + size]);
            pos += size + 2;
        }
        consumed = pos;
    } else {
        const cl: usize = if (headerValue(head, "content-length")) |v| try std.fmt.parseInt(usize, v, 10) else 0;
        while (buf.items.len < head_end + cl) try fill(buf, stream);
        try body.appendSlice(buf.items[head_end .. head_end + cl]);
        consumed = head_end + cl;
    }
    try buf.replaceRange(0, consumed, &.{});

    const line = head[0..std.mem.indexOf(u8, head, "\r\n").?];
    var rl = std.mem.splitScalar(u8, line, ' ');
    const method = rl.next() orelse return error.BadRequestLine;
    const path = rl.next() orelse return error.BadRequestLine;
    return Request{ .head = head, .method = method, .path = path, .body = body.items };
}

fn reply(stream: std.net.Stream, status: []const u8, content_type: ?[]const u8, extra: []const u8, body: []const u8) !void {
    var out = std.ArrayList(u8).init(gpa);
    defer out.deinit();
    const w = out.writer();
    try w.print("HTTP/1.1 {s}\r\n", .{status});
    if (content_type) |ct| try w.print("Content-Type: {s}\r\n", .{ct});
    try w.print("{s}Content-Length: {d}\r\n\r\n", .{ extra, body.len });
    try out.appendSlice(body);
    try stream.writeAll(out.items);
}

/// The string at `path` below `v` (objects only), or null.
fn jsonStr(v: std.json.Value, path: []const []const u8) ?[]const u8 {
    var cur = v;
    for (path) |k| {
        if (cur != .object) return null;
        cur = cur.object.get(k) orelse return null;
    }
    return if (cur == .string) cur.string else null;
}

fn record(state: *State, label: []const u8) !void {
    const copy = try gpa.dupe(u8, label);
    state.mu.lock();
    defer state.mu.unlock();
    try state.calls.append(copy);
}

/// One AWS JSON-protocol call: only the three the cold start is known to make are answered.
fn handleAws(state: *State, stream: std.net.Stream, target: []const u8, body: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch {
        fail(state, "AWS call {s} had a body that is not JSON: {s}", .{ target, body });
        return reply(stream, "500 Internal Server Error", "text/plain", "", "bad request");
    };
    const v = parsed.value;
    if (std.mem.eql(u8, target, "DynamoDB_20120810.GetItem")) {
        const table = jsonStr(v, &.{"TableName"}) orelse "";
        const key = jsonStr(v, &.{ "Key", "key", "S" }) orelse "";
        if (std.mem.eql(u8, table, "mopm-beta-config") and std.mem.eql(u8, key, "stage_settings")) {
            const label = try std.fmt.allocPrint(gpa, "dynamodb GetItem {s} {s}", .{ table, key });
            try record(state, label);
            return reply(stream, "200 OK", "application/x-amz-json-1.0", "", stage_settings_item);
        }
    } else if (std.mem.eql(u8, target, "secretsmanager.GetSecretValue")) {
        const id = jsonStr(v, &.{"SecretId"}) orelse "";
        const label = try std.fmt.allocPrint(gpa, "secretsmanager GetSecretValue {s}", .{id});
        if (std.mem.eql(u8, id, "mopm/beta/edge-origin")) {
            try record(state, label);
            return reply(stream, "200 OK", "application/x-amz-json-1.1", "", edge_origin_secret);
        }
        if (std.mem.eql(u8, id, "mopm/beta/e2b")) {
            try record(state, label);
            return reply(stream, "400 Bad Request", "application/x-amz-json-1.1", "", e2b_secret_missing);
        }
    }
    fail(state, "unexpected AWS call: target {s}, body {s}", .{ target, body });
    try reply(stream, "500 Internal Server Error", "text/plain", "", "unexpected");
}

fn handleRuntime(state: *State, stream: std.net.Stream, req: Request) !void {
    const prefix = "/2018-06-01/runtime/";
    const rest = req.path[prefix.len..];
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, rest, "invocation/next")) {
        state.mu.lock();
        const n = state.nexts;
        state.nexts += 1;
        state.mu.unlock();
        if (n >= invocations.len) {
            // No more events: hold the poll open until the peer goes away (the test kills the child).
            var drain: [256]u8 = undefined;
            while ((stream.read(&drain) catch 0) != 0) {}
            return error.EndOfStream;
        }
        const inv = invocations[n];
        var out = std.ArrayList(u8).init(gpa);
        defer out.deinit();
        try out.writer().print(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
                "Lambda-Runtime-Aws-Request-Id: {s}\r\n" ++
                "Lambda-Runtime-Deadline-Ms: 32503680000000\r\n" ++
                "Lambda-Runtime-Invoked-Function-Arn: arn:aws:lambda:us-east-1:" ++ "0" ** 12 ++ ":function:mopm-beta-tutorial-sandbox\r\n" ++
                "Lambda-Runtime-Trace-Id: Root=1-" ++ "0" ** 8 ++ "-" ++ "0" ** 24 ++ "\r\n" ++
                "Content-Length: {d}\r\n\r\n{s}",
            .{ inv.id, inv.event.len, inv.event },
        );
        return stream.writeAll(out.items);
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.startsWith(u8, rest, "invocation/") and std.mem.endsWith(u8, rest, "/response")) {
        const id = rest["invocation/".len .. rest.len - "/response".len];
        state.mu.lock();
        const idx = state.responses.items.len;
        state.mu.unlock();
        if (idx >= invocations.len or !std.mem.eql(u8, id, invocations[idx].id)) {
            fail(state, "response posted for unexpected invocation id {s} (already {d} responses)", .{ id, idx });
            return reply(stream, "404 Not Found", null, "", "");
        }
        const copy = try gpa.dupe(u8, req.body);
        state.mu.lock();
        try state.responses.append(copy);
        const done = state.responses.items.len == invocations.len;
        state.mu.unlock();
        try reply(stream, "202 Accepted", null, "", "");
        if (done) state.finished.set();
        return;
    }
    // /init/error, /invocation/<id>/error, or anything else the runtime API should not see.
    fail(state, "unexpected runtime API call: {s} {s}: {s}", .{ req.method, req.path, req.body });
    try reply(stream, "404 Not Found", null, "", "");
}

fn serve(state: *State, stream: std.net.Stream) !void {
    var buf = std.ArrayList(u8).init(gpa);
    defer buf.deinit();
    while (true) {
        const req = (try readRequest(&buf, stream)) orelse return;
        if (std.mem.startsWith(u8, req.path, "/2018-06-01/runtime/")) {
            try handleRuntime(state, stream, req);
        } else if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/")) {
            const target = headerValue(req.head, "x-amz-target") orelse {
                fail(state, "POST / without x-amz-target: {s}", .{req.body});
                return reply(stream, "400 Bad Request", null, "", "");
            };
            try handleAws(state, stream, target, req.body);
        } else {
            fail(state, "unexpected request: {s} {s}", .{ req.method, req.path });
            try reply(stream, "404 Not Found", null, "", "");
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

/// Checks one posted API Gateway response: status, exactly the three headers, the body string, no cookies.
fn checkResponse(inv: Invocation, posted: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, posted, .{}) catch |e| {
        std.debug.print("response for {s} is not JSON ({s}): {s}\n", .{ inv.id, @errorName(e), posted });
        return error.BadResponse;
    };
    const root = parsed.value;
    if (root != .object) return error.BadResponse;
    const status = root.object.get("statusCode") orelse return error.BadResponse;
    if (status != .integer) return error.BadResponse;
    try std.testing.expectEqual(inv.status, status.integer);

    const headers = root.object.get("headers") orelse return error.BadResponse;
    if (headers != .object) return error.BadResponse;
    try std.testing.expectEqual(@as(usize, 3), headers.object.count());
    try std.testing.expectEqualStrings(inv.id, jsonStr(headers, &.{"x-mopm-request-id"}) orelse "<absent>");
    try std.testing.expectEqualStrings("no-store", jsonStr(headers, &.{"cache-control"}) orelse "<absent>");
    try std.testing.expectEqualStrings("application/json", jsonStr(headers, &.{"content-type"}) orelse "<absent>");

    try std.testing.expectEqualStrings(inv.body, jsonStr(root, &.{"body"}) orelse "<absent>");

    // The cookies list, when present, is empty.
    if (root.object.get("cookies")) |c| {
        if (c != .array) return error.BadResponse;
        try std.testing.expectEqual(@as(usize, 0), c.array.items.len);
    }
}

test "the function refuses a request without a session and one with an Authorization header, after reading its settings" {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const a = arena_state.allocator();
    const exe = try std.process.getEnvVarOwned(a, "BOOTSTRAP");

    var state = State{};
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();
    const port = server.listen_address.getPort();
    const accept = try std.Thread.spawn(.{}, acceptLoop, .{ &state, &server });
    accept.detach();

    var env = std.process.EnvMap.init(a);
    try env.put("AWS_LAMBDA_RUNTIME_API", try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{port}));
    try env.put("AWS_LAMBDA_FUNCTION_NAME", "mopm-beta-tutorial-sandbox");
    try env.put("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "256");
    try env.put("AWS_LAMBDA_FUNCTION_VERSION", "$LATEST");
    try env.put("AWS_LAMBDA_LOG_STREAM_NAME", "e2e");
    try env.put("AWS_LAMBDA_LOG_GROUP_NAME", "e2e");
    try env.put("AWS_REGION", "us-east-1");
    try env.put("AWS_ACCESS_KEY_ID", "AKIDEXAMPLE");
    try env.put("AWS_SECRET_ACCESS_KEY", "e2e-secret-access-key");
    // The build's workers have no system root certificates, and the function builds its HTTPS client (E2B's) at cold
    // start from the system's roots. rustls-native-certs reads SSL_CERT_FILE in place of the system's: a test CA that
    // nothing here connects to. The function never calls E2B in this test.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile("roots.pem", @embedFile("tests/fixtures/e2e_root.pem"));
    try env.put("SSL_CERT_FILE", try tmp.dir.realpathAlloc(a, "roots.pem"));

    const endpoint = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{port});
    var child = std.process.Child.init(&.{ exe, "--aws-endpoint-url", endpoint }, a);
    child.env_map = &env;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    const watcher = try std.Thread.spawn(.{}, watchChild, .{ &state, child.stdout.? });

    // Wait for a progress event, not for a clock: the second response, a failure, or the child ending.
    // Kill with the pid still unreaped (child.wait reaps it after the join); the join returns once the
    // pipe reached EOF, so every line the child printed is in state.stdout.
    state.finished.wait();
    std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
    watcher.join();
    _ = child.wait() catch {};

    state.mu.lock();
    defer state.mu.unlock();
    if (state.failure) |f| {
        std.debug.print("{s}\nAWS calls so far: {d}; stdout so far:\n{s}\n", .{ f, state.calls.items.len, state.stdout.items });
        return error.UnexpectedCall;
    }
    if (state.responses.items.len < invocations.len) {
        std.debug.print(
            "function posted {d} of {d} responses (child exited: {}); AWS calls: {d}; stdout:\n{s}\n",
            .{ state.responses.items.len, invocations.len, state.exited, state.calls.items.len, state.stdout.items },
        );
        return error.MissingResponse;
    }

    // Cold start reads: exactly these, in this order (no tokens/users table call, nothing else).
    var calls_ok = state.calls.items.len == expected_calls.len;
    if (calls_ok) {
        for (expected_calls, state.calls.items) |want, got| {
            if (!std.mem.eql(u8, want, got)) calls_ok = false;
        }
    }
    if (!calls_ok) {
        std.debug.print("AWS calls differ from the expected cold-start reads; got {d}:\n", .{state.calls.items.len});
        for (state.calls.items) |c| std.debug.print("  {s}\n", .{c});
        return error.WrongAwsCalls;
    }

    for (invocations, state.responses.items) |inv, posted| try checkResponse(inv, posted);

    try std.testing.expectEqualStrings(expected_stdout, state.stdout.items);
}
