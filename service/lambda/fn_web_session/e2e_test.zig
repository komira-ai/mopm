//! End to end: runs the built web-session Lambda `bootstrap` against one loopback server that plays the
//! Lambda runtime API, DynamoDB and Secrets Manager, sends it one `GET /api/v2/auth/web/session` event
//! with the session cookie and the edge header, and holds the response it posts back, byte for byte.
//!
//! What it proves: the binary starts as a custom runtime, reads its stage's stage_settings item and its
//! edge secret once, answers the event from the tokens and users tables, writes the row's last_used_at
//! (UpdateItem on the tokens table), and posts the API Gateway response. What it catches: a change of
//! the response, of the calls the function makes (service, operation, table, order), or a binary that
//! does not start (missing symbol, wrong glibc).
//!
//! The build gives it the executable in $BOOTSTRAP. The function gets an explicit environment and
//! nothing inherited. No network but loopback.

const std = @import("std");

const edge = "edge-value-of-t";

const event =
    \\{"version":"2.0","routeKey":"GET /api/v2/auth/web/session","rawPath":"/api/v2/auth/web/session","rawQueryString":"",
    \\"cookies":["__Host-mopm_session=mopm_aeaqcaibaeaqcaibaeaqcaibaeaqcaibaeaqcaib"],
    \\"headers":{"host":"api.beta.mopm.dev","x-mopm-edge":"edge-value-of-t"},
    \\"requestContext":{"accountId":"fake","apiId":"api","domainName":"api.beta.mopm.dev",
    \\"http":{"method":"GET","path":"/api/v2/auth/web/session","protocol":"HTTP/1.1","sourceIp":"192.0.2.1","userAgent":"test"},
    \\"requestId":"gw-1","routeKey":"GET /api/v2/auth/web/session","stage":"$default","timeEpoch":1795003600000},
    \\"isBase64Encoded":false}
;

/// What the function must answer, as the API Gateway v2 response it posts. The session row expires in 2100, so the
/// answer does not depend on the real clock.
const expected_response =
    \\{"statusCode":200,"headers":{"x-mopm-request-id":"gw-1","cache-control":"no-store","content-type":"application/json"},"multiValueHeaders":{},"body":"{\"csrf\":\"xuAO3YCRSWXChUFi-Ro24qR01ucbsCFFPVBoM1_kkYs\",\"expires_at\":\"2100-01-01T00:00:00.000Z\",\"login\":\"alice\"}","isBase64Encoded":false,"cookies":[]}
;

/// The stage_settings item as the API stack writes it (service/lambda/web/tests/fixtures/stage_settings_item.json).
const settings_item =
    \\{"key":{"S":"stage_settings"},"redirect_uri":{"S":"https://beta.mopm.dev/api/v2/auth/web/callback"},
    \\"site_origin":{"S":"https://beta.mopm.dev"},"require_2fa":{"BOOL":false},"e2b_template_id":{"S":"tpl-abc_1"},
    \\"e2b_domain":{"S":"e2b.example"},"sandbox_timeout_s":{"N":"600"}}
;

/// The session row of the cookie above (the token's SHA-256 is the key).
const token_item =
    \\{"all_current":{"BOOL":false},"created_at":{"S":"2026-11-18T11:06:40.000Z"},"expires_at":{"N":"4102444800"},
    \\"expires_at_iso":{"S":"2100-01-01T00:00:00.000Z"},"fresh_until":{"S":"2026-11-18T11:06:40.000Z"},"github_id":{"S":"42"},
    \\"github_id_num":{"N":"42"},"id":{"S":"tok-1"},"kind":{"S":"session"},"name":{"S":"web login"},"packages":{"L":[]},
    \\"prefix":{"S":"mopm_aeaqca"},"scopes":{"L":[]},
    \\"token_hash":{"S":"400481e7d23917f69b2e9754916d3cd6ae51706a03e824651a92a1aa45f11d0d"}}
;

const user_item =
    \\{"created_at":{"S":"2026-11-18T11:06:40.000Z"},"github_id":{"S":"42"},"github_id_num":{"N":"42"},"handle":{"S":"alice"},
    \\"last_login_at":{"S":"2026-11-18T11:06:40.000Z"},"two_factor":{"BOOL":true}}
;

/// The calls the function must make, in order: the cold start (settings item, then secret), then the request.
const expected_calls = [_][]const u8{
    "DynamoDB_20120810.GetItem mopm-t-config",
    "secretsmanager.GetSecretValue mopm/t/edge-origin",
    "DynamoDB_20120810.GetItem mopm-t-tokens",
    "DynamoDB_20120810.GetItem mopm-t-users",
    "DynamoDB_20120810.UpdateItem mopm-t-tokens",
};

const response_path = "/2018-06-01/runtime/invocation/inv-1/response";

const State = struct {
    mu: std.Thread.Mutex = .{},
    gpa: std.mem.Allocator,
    nexts: u32 = 0,
    calls: std.ArrayList([]u8),
    posted_path: ?[]u8 = null,
    posted_body: ?[]u8 = null,
    other: ?[]u8 = null,
    /// Set (progress event) when the runtime API saw the response post, or any call it did not expect.
    finished: std.Thread.ResetEvent = .{},
    /// Set when the bootstrap's stdout reached EOF: the process is gone or going.
    exited: bool = false,
};

/// Drains the bootstrap's stdout until EOF, which is the process ending, then signals `finished` so the
/// test fails at once on a bootstrap that dies instead of waiting on a clock.
fn watchChild(state: *State, file: std.fs.File) void {
    var tmp: [1024]u8 = undefined;
    while (true) {
        const n = file.read(&tmp) catch break;
        if (n == 0) break;
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

/// The table (or secret) a JSON request body names: "TableName" or "SecretId".
fn targetName(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const v = obj.get("TableName") orelse obj.get("SecretId") orelse return gpa.dupe(u8, "?");
    return gpa.dupe(u8, v.string);
}

fn reply(stream: std.net.Stream, gpa: std.mem.Allocator, status: []const u8, content_type: []const u8, body: []const u8) !void {
    const out = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nx-amzn-RequestId: fake-request\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ status, content_type, body.len, body },
    );
    defer gpa.free(out);
    try stream.writeAll(out);
}

fn unexpected(state: *State, stream: std.net.Stream, what: []const u8) !void {
    state.mu.lock();
    state.other = try state.gpa.dupe(u8, what);
    state.mu.unlock();
    state.finished.set();
    try stream.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
}

/// One AWS JSON call: records "<target> <table or secret>" and answers it, or fails the test for a call not expected.
fn awsCall(state: *State, stream: std.net.Stream, target: []const u8, body: []const u8) !void {
    const name = try targetName(state.gpa, body);
    const call = try std.fmt.allocPrint(state.gpa, "{s} {s}", .{ target, name });
    state.mu.lock();
    try state.calls.append(call);
    state.mu.unlock();
    const dynamo = "application/x-amz-json-1.0";
    if (std.mem.eql(u8, target, "secretsmanager.GetSecretValue") and std.mem.eql(u8, name, "mopm/t/edge-origin")) {
        return reply(stream, state.gpa, "200 OK", "application/x-amz-json-1.1", "{\"Name\":\"mopm/t/edge-origin\",\"SecretString\":\"" ++ edge ++ "\"}");
    } else if (std.mem.eql(u8, target, "DynamoDB_20120810.GetItem")) {
        if (std.mem.eql(u8, name, "mopm-t-config")) return reply(stream, state.gpa, "200 OK", dynamo, "{\"Item\":" ++ settings_item ++ "}");
        if (std.mem.eql(u8, name, "mopm-t-tokens")) return reply(stream, state.gpa, "200 OK", dynamo, "{\"Item\":" ++ token_item ++ "}");
        if (std.mem.eql(u8, name, "mopm-t-users")) return reply(stream, state.gpa, "200 OK", dynamo, "{\"Item\":" ++ user_item ++ "}");
    } else if (std.mem.eql(u8, target, "DynamoDB_20120810.UpdateItem") and std.mem.eql(u8, name, "mopm-t-tokens")) {
        return reply(stream, state.gpa, "200 OK", dynamo, "{}");
    }
    try unexpected(state, stream, call);
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

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/2018-06-01/runtime/invocation/next")) {
            state.mu.lock();
            state.nexts += 1;
            const first = state.nexts == 1;
            state.mu.unlock();
            state.gpa.free(body);
            if (!first) {
                // There is no further event: hold the poll open until the peer goes away (the test kills the bootstrap).
                var drain: [256]u8 = undefined;
                while ((stream.read(&drain) catch 0) != 0) {}
                return;
            }
            var out = std.ArrayList(u8).init(state.gpa);
            defer out.deinit();
            try out.writer().print(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
                    "Lambda-Runtime-Aws-Request-Id: inv-1\r\n" ++
                    "Lambda-Runtime-Deadline-Ms: 32503680000000\r\n" ++
                    "Lambda-Runtime-Invoked-Function-Arn: arn:aws:lambda:us-east-1:" ++ "0" ** 12 ++ ":function:mopm-t-web-session\r\n" ++
                    "Lambda-Runtime-Trace-Id: Root=1-00000000-000000000000000000000000\r\n" ++
                    "Content-Length: {d}\r\n\r\n{s}",
                .{ event.len, event },
            );
            try stream.writeAll(out.items);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.startsWith(u8, path, "/2018-06-01/")) {
            state.mu.lock();
            if (std.mem.eql(u8, path, response_path)) {
                state.posted_path = try state.gpa.dupe(u8, path);
                state.posted_body = body;
            } else {
                state.other = try std.fmt.allocPrint(state.gpa, "{s} {s}: {s}", .{ method, path, body });
            }
            state.mu.unlock();
            state.finished.set();
            try stream.writeAll("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n");
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/") and headerValue(head, "x-amz-target") != null) {
            try awsCall(state, stream, headerValue(head, "x-amz-target").?, body);
        } else {
            const what = try std.fmt.allocPrint(state.gpa, "{s} {s}", .{ method, path });
            try unexpected(state, stream, what);
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

test "bootstrap answers a session event from the tables and the secret it is granted" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const exe = try std.process.getEnvVarOwned(a, "BOOTSTRAP");

    var state = State{ .gpa = a, .calls = std.ArrayList([]u8).init(a) };
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();
    const port = server.listen_address.getPort();
    const accept = try std.Thread.spawn(.{}, acceptLoop, .{ &state, &server });
    accept.detach();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(a, ".");

    const host = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{port});
    var env = std.process.EnvMap.init(a);
    try env.put("AWS_LAMBDA_RUNTIME_API", host);
    try env.put("AWS_LAMBDA_FUNCTION_NAME", "mopm-t-web-session");
    try env.put("AWS_LAMBDA_FUNCTION_VERSION", "$LATEST");
    try env.put("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "128");
    try env.put("AWS_LAMBDA_LOG_GROUP_NAME", "/aws/lambda/mopm-t-web-session");
    try env.put("AWS_LAMBDA_LOG_STREAM_NAME", "stream");
    try env.put("AWS_REGION", "us-east-1");
    try env.put("AWS_ACCESS_KEY_ID", "AKIDFAKE");
    try env.put("AWS_SECRET_ACCESS_KEY", "fakesecret");
    try env.put("AWS_ENDPOINT_URL", try std.fmt.allocPrint(a, "http://{s}", .{host}));
    try env.put("AWS_EC2_METADATA_DISABLED", "true");
    try env.put("HOME", home);
    try env.put("AWS_CONFIG_FILE", try std.fs.path.join(a, &.{ home, "no-config" }));
    try env.put("AWS_SHARED_CREDENTIALS_FILE", try std.fs.path.join(a, &.{ home, "no-credentials" }));

    var child = std.process.Child.init(&.{exe}, a);
    child.env_map = &env;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    const watcher = try std.Thread.spawn(.{}, watchChild, .{ &state, child.stdout.? });

    // Wait for a progress event, not for a clock: the response post, an unexpected call, or the
    // bootstrap ending. Kill with the pid still unreaped (child.wait reaps it after the join).
    state.finished.wait();
    std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
    watcher.join();
    _ = child.wait() catch {};

    state.mu.lock();
    defer state.mu.unlock();
    if (state.other) |o| {
        std.debug.print("unexpected call: {s}\n", .{o});
        return error.UnexpectedCall;
    }
    const body = state.posted_body orelse {
        std.debug.print("bootstrap posted no response (exited: {})\n", .{state.exited});
        return error.NoResponse;
    };
    try std.testing.expectEqualStrings(response_path, state.posted_path.?);
    try std.testing.expectEqualStrings(expected_response, body);

    try std.testing.expectEqual(expected_calls.len, state.calls.items.len);
    for (expected_calls, state.calls.items) |want, got| try std.testing.expectEqualStrings(want, got);
}
