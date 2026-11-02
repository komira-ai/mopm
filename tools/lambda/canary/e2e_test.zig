//! End to end: runs the built canary Lambda `bootstrap` against a fake Lambda runtime API
//! on loopback, sends it one API Gateway v2 (payload format 2.0) event and holds the
//! response it posts back, byte for byte.
//!
//! What it proves: the binary starts as a custom runtime, long-polls
//! /2018-06-01/runtime/invocation/next, decodes the event, runs the handler, and
//! posts the API Gateway response (status, headers, body) to
//! /2018-06-01/runtime/invocation/<id>/response. What it catches: a change of the
//! handler's output, of the response encoding, of the runtime protocol the crates
//! speak, or a binary that does not start (missing symbol, wrong glibc).
//!
//! The build gives it the executable in $BOOTSTRAP. No network but loopback.

const std = @import("std");

const event =
    \\{"version":"2.0","routeKey":"GET /hello","rawPath":"/hello","rawQueryString":"name=komira",
    \\"headers":{"host":"api.example","accept":"*/*"},"queryStringParameters":{"name":"komira"},
    \\"requestContext":{"accountId":"example","apiId":"api","domainName":"api.example","domainPrefix":"api",
    \\"http":{"method":"GET","path":"/hello","protocol":"HTTP/1.1","sourceIp":"0.0.0.0","userAgent":"test"},
    \\"requestId":"id","routeKey":"GET /hello","stage":"$default","time":"01/Jan/2026:00:00:00 +0000","timeEpoch":1767225600000},
    \\"isBase64Encoded":false}
;

/// What the function must answer: the handler's JSON in the body of an API Gateway v2 response.
const expected_response =
    \\{"statusCode":200,"headers":{"content-type":"application/json"},"multiValueHeaders":{},"body":"{\"hello\":\"komira\",\"path\":\"/hello\"}","isBase64Encoded":false,"cookies":[]}
;

const response_path = "/2018-06-01/runtime/invocation/req-1/response";

const State = struct {
    mu: std.Thread.Mutex = .{},
    gpa: std.mem.Allocator,
    nexts: u32 = 0,
    posted_path: ?[]u8 = null,
    posted_body: ?[]u8 = null,
    other: ?[]u8 = null,
    /// Set (progress event) when the runtime API saw the response post, or any call it did not expect.
    finished: std.Thread.ResetEvent = .{},
    /// Set (progress event) when the bootstrap's stdout reached EOF: the process is gone or going.
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
                    "Lambda-Runtime-Invoked-Function-Arn: arn:aws:lambda:us-east-1:" ++ "0" ** 12 ++ ":function:canary\r\n" ++
                    "Lambda-Runtime-Trace-Id: Root=1-00000000-000000000000000000000000\r\n" ++
                    "Content-Length: {d}\r\n\r\n{s}",
                .{ event.len, event },
            );
            try stream.writeAll(out.items);
        } else if (std.mem.eql(u8, method, "POST")) {
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
        } else {
            state.mu.lock();
            state.other = try std.fmt.allocPrint(state.gpa, "{s} {s}", .{ method, path });
            state.mu.unlock();
            state.finished.set();
            try stream.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
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

test "bootstrap answers one API Gateway v2 event" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const exe = try std.process.getEnvVarOwned(a, "BOOTSTRAP");

    var state = State{ .gpa = a };
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();
    const port = server.listen_address.getPort();
    const accept = try std.Thread.spawn(.{}, acceptLoop, .{ &state, &server });
    accept.detach();

    var env = std.process.EnvMap.init(a);
    try env.put("AWS_LAMBDA_RUNTIME_API", try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{port}));
    try env.put("AWS_LAMBDA_FUNCTION_NAME", "canary");
    try env.put("AWS_LAMBDA_FUNCTION_VERSION", "$LATEST");
    try env.put("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "128");
    try env.put("AWS_LAMBDA_LOG_GROUP_NAME", "/aws/lambda/canary");
    try env.put("AWS_LAMBDA_LOG_STREAM_NAME", "stream");
    try env.put("AWS_REGION", "us-east-1");

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
        std.debug.print("unexpected runtime API call: {s}\n", .{o});
        return error.UnexpectedRuntimeCall;
    }
    const body = state.posted_body orelse {
        std.debug.print("bootstrap posted no response (exited: {})\n", .{state.exited});
        return error.NoResponse;
    };
    try std.testing.expectEqualStrings(response_path, state.posted_path.?);
    try std.testing.expectEqualStrings(expected_response, body);
}
