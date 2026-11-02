//! A small HTTP client for the registry: one request per call, the answer's
//! status, body, `x-mopm-request-id` and `Retry-After`, and the contract's
//! error shape (`{"error": {"code", "message", "hint"}}`) made readable.
//!
//! A token goes only into the `Authorization` header; nothing here prints it.
//!
//! A request has a time limit. The connection must be made within `timeout_secs`
//! (`error.ConnectTimedOut`), and after that no read or write may wait longer than
//! `timeout_secs` for the server (`error.RequestTimedOut`); a transfer that keeps
//! making progress is never cut short. `retrying` repeats an idempotent request that
//! failed in a way a second try can cure, a bounded number of times, with jittered
//! waits; a caller names its own clock so a test does not sleep.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// The longest a connection may take to be made, and the longest a read or a write may wait for the server.
pub const default_timeout_secs: u32 = 30;
/// How many times an idempotent request is repeated after its first try.
pub const default_retries: u8 = 3;
/// The most retries a caller may ask for.
pub const max_retries: u8 = 10;
/// The longest a `Retry-After` is honoured; a longer one ends the retries (the caller reports it).
pub const max_retry_after_secs: u32 = 20;
/// The longest one wait between tries grows to, before jitter.
pub const max_backoff_secs: u64 = 30;

pub const Policy = struct {
    timeout_secs: u32 = default_timeout_secs,
    retries: u8 = default_retries,
};

pub const Answer = struct {
    status: u16,
    body: []const u8,
    /// `x-mopm-request-id`, or "" when the answer has none.
    request_id: []const u8 = "",
    retry_after: ?u32 = null,

    pub fn ok(a: Answer) bool {
        return a.status >= 200 and a.status < 300;
    }
};

pub const Options = struct {
    /// Sent as `Authorization: Bearer <token>`.
    token: ?[]const u8 = null,
    body: ?[]const u8 = null,
    /// null sends no `Content-Type` (an upload sends exactly the headers the
    /// registry names, and the PUT of a presigned URL signs them).
    content_type: ?[]const u8 = "application/json",
    /// Sent as given (the presigned upload's headers).
    extra_headers: []const std.http.Header = &.{},
    /// The most a body may hold; a longer one is `error.StreamTooLong`.
    max_body: usize = 64 << 20,
    /// Seconds to make the connection in, and the longest a read or write waits; 0 sets no limit.
    timeout_secs: u32 = default_timeout_secs,
};

/// One request. A server that does not answer in time is `error.RequestTimedOut`, a host that cannot be
/// reached in time `error.ConnectTimedOut`; any other failure is returned as it came.
pub fn request(arena: Allocator, method: std.http.Method, url: []const u8, options: Options) !Answer {
    return requestWith(arena, method, url, options, Net{});
}

/// The network and the clock `request` uses; a test passes its own `now` (milliseconds) and `once`.
const Net = struct {
    fn now(_: Net) i64 {
        return std.time.milliTimestamp();
    }
    fn once(_: Net, arena: Allocator, method: std.http.Method, url: []const u8, options: Options) anyerror!Answer {
        return requestOnce(arena, method, url, options);
    }
};

fn requestWith(arena: Allocator, method: std.http.Method, url: []const u8, options: Options, net: anytype) anyerror!Answer {
    const started = net.now();
    return net.once(arena, method, url, options) catch |e| {
        if (options.timeout_secs > 0 and isTimeout(e, net.now() - started, options.timeout_secs)) return error.RequestTimedOut;
        return e;
    };
}

/// Whether `e`, which ended a request after `elapsed_ms`, is the socket's time limit running out. A plain socket
/// reports it as `WouldBlock`; a TLS stream hides the cause behind a read or write failure, which counts only
/// when the whole limit has passed.
fn isTimeout(e: anyerror, elapsed_ms: i64, timeout_secs: u32) bool {
    const name = @errorName(e);
    if (std.mem.eql(u8, name, "WouldBlock")) return true;
    const hidden = [_][]const u8{ "UnexpectedReadFailure", "UnexpectedWriteFailure", "TlsFailure" };
    for (hidden) |h| {
        if (std.mem.eql(u8, name, h)) return elapsed_ms >= @as(i64, timeout_secs) * 1000 - 100;
    }
    return false;
}

fn requestOnce(arena: Allocator, method: std.http.Method, url: []const u8, options: Options) !Answer {
    if (options.timeout_secs > 0) try probeConnect(url, options.timeout_secs);
    var client = std.http.Client{ .allocator = arena };
    defer client.deinit();
    const uri = try std.Uri.parse(url);
    var header_buf: [16 * 1024]u8 = undefined;
    const authorization: ?[]const u8 = if (options.token) |t| try std.fmt.allocPrint(arena, "Bearer {s}", .{t}) else null;
    var req = try client.open(method, uri, .{
        .server_header_buffer = &header_buf,
        .keep_alive = false,
        .headers = .{
            .authorization = if (authorization) |a| .{ .override = a } else .default,
            .content_type = if (options.body == null) .default else if (options.content_type) |ct| .{ .override = ct } else .omit,
            .user_agent = .{ .override = "mopm" },
        },
        .extra_headers = options.extra_headers,
    });
    defer req.deinit();
    if (options.timeout_secs > 0) try setSocketTimeouts(req.connection.?.stream.handle, options.timeout_secs);
    if (options.body) |b| req.transfer_encoding = .{ .content_length = b.len };
    try req.send();
    if (options.body) |b| try req.writeAll(b);
    try req.finish();
    try req.wait();

    var answer = Answer{ .status = @intFromEnum(req.response.status), .body = "" };
    var it = req.response.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "x-mopm-request-id")) answer.request_id = try arena.dupe(u8, h.value);
        if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) answer.retry_after = std.fmt.parseInt(u32, h.value, 10) catch null;
    }
    answer.body = try req.reader().readAllAlloc(arena, options.max_body);
    return answer;
}

// ------------------------------------------------------------------ time limits

const Timeval = extern struct { sec: c_long, usec: if (builtin.os.tag == .linux) c_long else i32 };

/// Reads and writes on `handle` give up after `secs` of waiting (the socket's own limit, so the TLS layer and the
/// body reads are covered alike).
fn setSocketTimeouts(handle: std.posix.socket_t, secs: u32) !void {
    if (comptime builtin.os.tag == .windows) return;
    const tv = Timeval{ .sec = @intCast(secs), .usec = 0 };
    try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
    try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
}

const HostPort = struct { host: []const u8, port: u16 };

/// The host and port a URL names (`https` defaults to 443, anything else to 80), or null for a URL this cannot read.
fn hostPort(url: []const u8) ?HostPort {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const default_port: u16 = if (std.mem.eql(u8, url[0..scheme_end], "https")) 443 else 80;
    var rest = url[scheme_end + 3 ..];
    rest = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
    if (rest.len == 0) return null;
    if (rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
        const after = rest[close + 1 ..];
        if (after.len == 0) return .{ .host = rest[1..close], .port = default_port };
        if (after[0] != ':') return null;
        return .{ .host = rest[1..close], .port = std.fmt.parseInt(u16, after[1..], 10) catch return null };
    }
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        return .{ .host = rest[0..colon], .port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return null };
    }
    return .{ .host = rest, .port = default_port };
}

/// A connection made on a thread of its own, so the caller can stop waiting for it. Two owners, the caller and the
/// thread; the last to let go frees it, so a connect that finishes after the caller gave up touches nothing freed.
const Probe = struct {
    refs: std.atomic.Value(u8) = std.atomic.Value(u8).init(2),
    done: std.Thread.ResetEvent = .{},
    port: u16,
    host_len: u8,
    host_buf: [255]u8 = undefined,

    fn run(p: *Probe) void {
        defer p.release();
        // A failed connect is not this probe's to report: the request that follows makes its own and names the error.
        if (std.net.tcpConnectToHost(std.heap.page_allocator, p.host_buf[0..p.host_len], p.port)) |stream| stream.close() else |_| {}
        p.done.set();
    }

    fn release(p: *Probe) void {
        if (p.refs.fetchSub(1, .acq_rel) == 1) std.heap.page_allocator.destroy(p);
    }
};

/// Waits up to `secs` for a connection to the URL's host (name lookup included) to be made or to fail; a host that
/// does neither in time is `error.ConnectTimedOut`. The standard client's own connect has no limit, so the wait is
/// made first, on a connection of its own that is closed at once.
fn probeConnect(url: []const u8, secs: u32) error{ConnectTimedOut}!void {
    const hp = hostPort(url) orelse return;
    if (hp.host.len > 255) return;
    const p = std.heap.page_allocator.create(Probe) catch return;
    p.* = .{ .port = hp.port, .host_len = @intCast(hp.host.len) };
    @memcpy(p.host_buf[0..hp.host.len], hp.host);
    const t = std.Thread.spawn(.{}, Probe.run, .{p}) catch {
        std.heap.page_allocator.destroy(p);
        return;
    };
    t.detach();
    defer p.release();
    p.done.timedWait(@as(u64, secs) * std.time.ns_per_s) catch return error.ConnectTimedOut;
}

// -------------------------------------------------------------------- retries

/// Whether repeating a request of this method changes nothing the first try had not.
pub fn idempotent(method: std.http.Method) bool {
    return switch (method) {
        .GET, .HEAD, .PUT, .DELETE, .OPTIONS => true,
        else => false,
    };
}

/// Whether a second try may be answered differently: a server that failed (500, 502, 503 - which is also how storage
/// says SlowDown - and 504) or asked the client to slow down (429). Every other status is the answer, retried or not.
/// A `Retry-After` longer than `max_retry_after_secs` is not waited for here: the caller reports it.
pub fn retryableAnswer(a: Answer) bool {
    switch (a.status) {
        429, 500, 502, 503, 504 => {},
        else => return false,
    }
    return if (a.retry_after) |s| s <= max_retry_after_secs else true;
}

/// Whether a request that ended in `e` may succeed when repeated: the connection broke, was refused or reset, the
/// name server failed for now, or the time limit ran out. An error of the request itself (a bad URL, a body too long) is not.
pub fn retryableError(e: anyerror) bool {
    const name = @errorName(e);
    const transient = [_][]const u8{
        "RequestTimedOut",        "ConnectTimedOut",      "ConnectionRefused",     "ConnectionResetByPeer", "ConnectionTimedOut",
        "NetworkUnreachable",     "BrokenPipe",           "EndOfStream",           "TemporaryNameServerFailure", "UnexpectedConnectFailure",
        "UnexpectedReadFailure",  "UnexpectedWriteFailure", "TlsConnectionTruncated", "TlsAlert",
    };
    for (transient) |t| {
        if (std.mem.eql(u8, name, t)) return true;
    }
    return false;
}

/// Seconds to wait before retry number `attempt` (1 is the first): twice as long each time up to
/// `max_backoff_secs`, then a point in the upper half of that, picked by `random`, so clients that failed together
/// do not come back together. A `Retry-After` the server named is the least it waits.
pub fn backoffSecs(attempt: u8, retry_after: ?u32, random: u64) u64 {
    const shift: u6 = @intCast(@min(attempt, 6));
    const ceiling = @min(max_backoff_secs, @as(u64, 1) << shift);
    const low = (ceiling + 1) / 2;
    const jittered = low + random % (ceiling - low + 1);
    return if (retry_after) |s| @max(jittered, s) else jittered;
}

/// The request over the real network and the real clock.
pub const Real = struct {
    pub fn once(_: Real, arena: Allocator, method: std.http.Method, url: []const u8, options: Options) anyerror!Answer {
        return request(arena, method, url, options);
    }
    pub fn pause(_: Real, secs: u64) void {
        std.time.sleep(secs * std.time.ns_per_s);
    }
};

/// `io.once(arena, method, url, options)` repeated up to `policy.retries` times while it fails in a way
/// `retryableError`/`retryableAnswer` names and the method is idempotent, with `io.pause(secs)` between tries. After
/// the last try, or on an answer a second try would not change, the result is returned as it came, so a caller reports
/// the final failure as it would have reported the first. `policy.timeout_secs` is set on every try.
pub fn retrying(arena: Allocator, io: anytype, method: std.http.Method, url: []const u8, options: Options, policy: Policy) anyerror!Answer {
    var opts = options;
    opts.timeout_secs = policy.timeout_secs;
    const retries: u8 = if (idempotent(method)) @min(policy.retries, max_retries) else 0;
    var retry: u8 = 0;
    while (true) {
        const result: anyerror!Answer = io.once(arena, method, url, opts);
        if (retry >= retries) return result;
        const wait: u64 = if (result) |answer| blk: {
            if (!retryableAnswer(answer)) return answer;
            break :blk backoffSecs(retry + 1, answer.retry_after, std.crypto.random.int(u64));
        } else |e| blk: {
            if (!retryableError(e)) return e;
            break :blk backoffSecs(retry + 1, null, std.crypto.random.int(u64));
        };
        io.pause(wait);
        retry += 1;
    }
}

/// Why a `group_conflict` was refused (`error.reason`, spec/api/openapi.yaml `x-mopm-error-reasons`). A value this
/// client does not know reads as none, as the contract requires.
pub const Reason = enum {
    number_held,
    group_failed,
    open_cap,
    supersede_cap,
    takeover_blocked,
    number_taken,
    overlap_refused,
};

pub const ApiError = struct { code: []const u8, message: []const u8, hint: []const u8, reason: ?Reason = null };

/// The contract error in `a`'s body; an answer without one reads as its status.
pub fn apiError(arena: Allocator, a: Answer) Allocator.Error!ApiError {
    const generic = ApiError{
        .code = "",
        .message = try std.fmt.allocPrint(arena, "the registry answered HTTP {d}", .{a.status}),
        .hint = "",
    };
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, a.body, .{}) catch return generic;
    const top = switch (v) {
        .object => |o| o,
        else => return generic,
    };
    const err = switch (top.get("error") orelse return generic) {
        .object => |o| o,
        else => return generic,
    };
    return .{
        .code = stringOr(err, "code", ""),
        .message = stringOr(err, "message", generic.message),
        .hint = stringOr(err, "hint", ""),
        .reason = std.meta.stringToEnum(Reason, stringOr(err, "reason", "")),
    };
}

fn stringOr(o: std.json.ObjectMap, key: []const u8, default: []const u8) []const u8 {
    return switch (o.get(key) orelse return default) {
        .string => |s| s,
        else => default,
    };
}

/// The lines mopm prints for a failed request: the message, its hint, how
/// long to wait when the registry says, and the request id to report.
pub fn describe(arena: Allocator, a: Answer) Allocator.Error![]const u8 {
    const e = try apiError(arena, a);
    var out = std.ArrayList(u8).init(arena);
    const w = out.writer();
    try w.print("{s}\n", .{e.message});
    if (e.hint.len > 0) try w.print("  hint: {s}\n", .{e.hint});
    if (a.retry_after) |s| try w.print("  retry after: {d} seconds\n", .{s});
    if (a.request_id.len > 0) try w.print("  request id: {s}\n", .{a.request_id});
    return out.items;
}

test "a contract error reads as message, hint and request id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const answer = Answer{
        .status = 401,
        .body = "{\"error\":{\"code\":\"token_expired\",\"message\":\"The token expired at 2026-10-14T00:00:00Z.\",\"hint\":\"Create a new token.\"}}",
        .request_id = "req-1",
    };
    try std.testing.expectEqualStrings("token_expired", (try apiError(a, answer)).code);
    try std.testing.expectEqualStrings(
        "The token expired at 2026-10-14T00:00:00Z.\n  hint: Create a new token.\n  request id: req-1\n",
        try describe(a, answer),
    );
    const bare = Answer{ .status = 502, .body = "<html>bad gateway</html>" };
    try std.testing.expectEqualStrings("the registry answered HTTP 502\n", try describe(a, bare));
}

test "a group_conflict reason is read, an unknown one is none, and the printed lines do not change" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const head = "{\"error\":{\"code\":\"group_conflict\",\"message\":\"The group cannot be created: x.\",\"hint\":\"h\"";
    const known = Answer{ .status = 409, .body = head ++ ",\"reason\":\"overlap_refused\"}}" };
    try std.testing.expectEqual(Reason.overlap_refused, (try apiError(a, known)).reason.?);
    for ([_][]const u8{ "\"reason\":\"a_new_reason\"", "\"reason\":7", "\"reason\":null", "\"x\":1" }) |extra| {
        const other = Answer{ .status = 409, .body = try std.fmt.allocPrint(a, "{s},{s}}}}}", .{ head, extra }) };
        try std.testing.expectEqual(@as(?Reason, null), (try apiError(a, other)).reason);
        try std.testing.expectEqualStrings("group_conflict", (try apiError(a, other)).code);
    }
    const bare = Answer{ .status = 409, .body = head ++ "}}" };
    try std.testing.expectEqual(@as(?Reason, null), (try apiError(a, bare)).reason);
    try std.testing.expectEqualStrings(try describe(a, bare), try describe(a, known));
}

// ---------------------------------------------------------------------- tests

/// An `io` for `retrying` that answers from a list, in order (the last repeats), and counts what was asked of it.
const ScriptedIo = struct {
    results: []const anyerror!Answer,
    calls: usize = 0,
    pauses: usize = 0,
    slept: u64 = 0,
    last_timeout: u32 = 0,
    last_method: std.http.Method = .GET,

    fn once(io: *ScriptedIo, _: Allocator, method: std.http.Method, _: []const u8, options: Options) anyerror!Answer {
        io.last_timeout = options.timeout_secs;
        io.last_method = method;
        const result = io.results[@min(io.calls, io.results.len - 1)];
        io.calls += 1;
        return result;
    }

    fn pause(io: *ScriptedIo, secs: u64) void {
        io.pauses += 1;
        io.slept += secs;
    }
};

fn answerWith(status: u16, retry_after: ?u32) Answer {
    return .{ .status = status, .body = "", .retry_after = retry_after };
}

test "a 503 and then a 200 is one retry, and the 200 is what comes back" {
    var io = ScriptedIo{ .results = &.{ answerWith(503, null), answerWith(200, null) } };
    const got = try retrying(std.testing.allocator, &io, .PUT, "http://x/", .{}, .{});
    try std.testing.expectEqual(@as(u16, 200), got.status);
    try std.testing.expectEqual(@as(usize, 2), io.calls);
    try std.testing.expectEqual(@as(usize, 1), io.pauses);
    // The first wait is between 1 and 2 seconds (jittered, never zero).
    try std.testing.expect(io.slept >= 1 and io.slept <= 2);
}

test "an answer that a second try would not change is returned at once" {
    for ([_]u16{ 400, 401, 403, 404, 409, 410, 422, 501 }) |status| {
        var io = ScriptedIo{ .results = &.{ answerWith(status, null), answerWith(200, null) } };
        const got = try retrying(std.testing.allocator, &io, .PUT, "http://x/", .{}, .{});
        try std.testing.expectEqual(status, got.status);
        try std.testing.expectEqual(@as(usize, 1), io.calls);
        try std.testing.expectEqual(@as(usize, 0), io.pauses);
    }
}

test "retries are bounded: the failure comes back after the last one" {
    var io = ScriptedIo{ .results = &.{answerWith(503, null)} };
    const got = try retrying(std.testing.allocator, &io, .GET, "http://x/", .{}, .{ .retries = 3 });
    try std.testing.expectEqual(@as(u16, 503), got.status);
    try std.testing.expectEqual(@as(usize, 4), io.calls);
    try std.testing.expectEqual(@as(usize, 3), io.pauses);

    var none = ScriptedIo{ .results = &.{answerWith(503, null)} };
    _ = try retrying(std.testing.allocator, &none, .GET, "http://x/", .{}, .{ .retries = 0 });
    try std.testing.expectEqual(@as(usize, 1), none.calls);

    // A caller cannot ask for an unbounded run.
    var many = ScriptedIo{ .results = &.{error.ConnectionRefused} };
    try std.testing.expectError(error.ConnectionRefused, retrying(std.testing.allocator, &many, .GET, "http://x/", .{}, .{ .retries = 255 }));
    try std.testing.expectEqual(@as(usize, max_retries) + 1, many.calls);
}

test "a request that is not idempotent is never repeated" {
    var io = ScriptedIo{ .results = &.{ answerWith(503, null), answerWith(200, null) } };
    const got = try retrying(std.testing.allocator, &io, .POST, "http://x/", .{}, .{});
    try std.testing.expectEqual(@as(u16, 503), got.status);
    try std.testing.expectEqual(@as(usize, 1), io.calls);
    var broken = ScriptedIo{ .results = &.{ error.ConnectionResetByPeer, answerWith(200, null) } };
    try std.testing.expectError(error.ConnectionResetByPeer, retrying(std.testing.allocator, &broken, .POST, "http://x/", .{}, .{}));
    try std.testing.expectEqual(@as(usize, 1), broken.calls);
}

test "a broken connection, a refusal and a timeout are retried; an error of the request itself is not" {
    var io = ScriptedIo{ .results = &.{ error.ConnectionResetByPeer, error.RequestTimedOut, error.ConnectTimedOut, answerWith(200, null) } };
    const got = try retrying(std.testing.allocator, &io, .GET, "http://x/", .{}, .{ .retries = 3 });
    try std.testing.expectEqual(@as(u16, 200), got.status);
    try std.testing.expectEqual(@as(usize, 4), io.calls);

    var too_long = ScriptedIo{ .results = &.{ error.StreamTooLong, answerWith(200, null) } };
    try std.testing.expectError(error.StreamTooLong, retrying(std.testing.allocator, &too_long, .GET, "http://x/", .{}, .{}));
    try std.testing.expectEqual(@as(usize, 1), too_long.calls);

    var last = ScriptedIo{ .results = &.{error.RequestTimedOut} };
    try std.testing.expectError(error.RequestTimedOut, retrying(std.testing.allocator, &last, .GET, "http://x/", .{}, .{ .retries = 2 }));
    try std.testing.expectEqual(@as(usize, 3), last.calls);
}

test "a 429 waits the Retry-After the server named, when it is short, and stops when it is long" {
    var io = ScriptedIo{ .results = &.{ answerWith(429, 7), answerWith(200, null) } };
    const got = try retrying(std.testing.allocator, &io, .PUT, "http://x/", .{}, .{});
    try std.testing.expectEqual(@as(u16, 200), got.status);
    try std.testing.expect(io.slept >= 7);

    var long = ScriptedIo{ .results = &.{ answerWith(429, max_retry_after_secs + 1), answerWith(200, null) } };
    const stopped = try retrying(std.testing.allocator, &long, .PUT, "http://x/", .{}, .{});
    try std.testing.expectEqual(@as(u16, 429), stopped.status);
    try std.testing.expectEqual(@as(u32, max_retry_after_secs + 1), stopped.retry_after.?);
    try std.testing.expectEqual(@as(usize, 1), long.calls);

    var bare = ScriptedIo{ .results = &.{ answerWith(429, null), answerWith(200, null) } };
    try std.testing.expectEqual(@as(u16, 200), (try retrying(std.testing.allocator, &bare, .GET, "http://x/", .{}, .{})).status);
}

test "every try carries the policy's time limit" {
    var io = ScriptedIo{ .results = &.{ answerWith(502, null), answerWith(200, null) } };
    _ = try retrying(std.testing.allocator, &io, .GET, "http://x/", .{ .timeout_secs = 99 }, .{ .timeout_secs = 7 });
    try std.testing.expectEqual(@as(u32, 7), io.last_timeout);
}

test "the wait grows, stays under its ceiling, is jittered, and never undercuts a Retry-After" {
    var attempt: u8 = 1;
    while (attempt <= 12) : (attempt += 1) {
        const shift: u6 = @intCast(@min(attempt, 6));
        const ceiling = @min(max_backoff_secs, @as(u64, 1) << shift);
        const low = (ceiling + 1) / 2;
        var seen_low = false;
        var seen_high = false;
        var r: u64 = 0;
        while (r < 64) : (r += 1) {
            const w = backoffSecs(attempt, null, r);
            try std.testing.expect(w >= low and w <= ceiling and w >= 1);
            if (w == low) seen_low = true;
            if (w == ceiling) seen_high = true;
        }
        // Different random numbers reach both ends of the range.
        try std.testing.expect(seen_low and seen_high);
        try std.testing.expectEqual(@max(low, @as(u64, 19)), backoffSecs(attempt, 19, 0));
    }
    try std.testing.expect(backoffSecs(1, null, 0) < backoffSecs(5, null, 0));
    try std.testing.expectEqual(@as(u64, max_backoff_secs), backoffSecs(200, null, 15));
}

test "which answers and errors are worth a second try" {
    for ([_]u16{ 500, 502, 503, 504 }) |s| try std.testing.expect(retryableAnswer(answerWith(s, null)));
    for ([_]u16{ 200, 201, 204, 301, 400, 401, 403, 404, 409, 413, 422, 501, 505 }) |s| try std.testing.expect(!retryableAnswer(answerWith(s, null)));
    try std.testing.expect(retryableAnswer(answerWith(429, null)));
    try std.testing.expect(retryableAnswer(answerWith(503, max_retry_after_secs)));
    try std.testing.expect(!retryableAnswer(answerWith(503, max_retry_after_secs + 1)));
    try std.testing.expect(retryableError(error.ConnectionRefused));
    try std.testing.expect(retryableError(error.RequestTimedOut));
    try std.testing.expect(!retryableError(error.OutOfMemory));
    try std.testing.expect(!retryableError(error.InvalidFormat));
    try std.testing.expect(idempotent(.PUT) and idempotent(.GET) and !idempotent(.POST) and !idempotent(.PATCH));
}

test "a URL's host and port" {
    const cases = [_]struct { url: []const u8, host: []const u8, port: u16 }{
        .{ .url = "http://127.0.0.1:8080/api", .host = "127.0.0.1", .port = 8080 },
        .{ .url = "https://registry.example/x?y=1", .host = "registry.example", .port = 443 },
        .{ .url = "http://localhost", .host = "localhost", .port = 80 },
        .{ .url = "http://[::1]:9/a", .host = "::1", .port = 9 },
        .{ .url = "https://[::1]/a", .host = "::1", .port = 443 },
        .{ .url = "https://user@bucket.s3.example:444/k#f", .host = "bucket.s3.example", .port = 444 },
    };
    for (cases) |c| {
        const got = hostPort(c.url).?;
        try std.testing.expectEqualStrings(c.host, got.host);
        try std.testing.expectEqual(c.port, got.port);
    }
    try std.testing.expect(hostPort("no scheme") == null);
    try std.testing.expect(hostPort("http:///x") == null);
    try std.testing.expect(hostPort("http://h:notaport/") == null);
}

fn loopbackServer() !std.net.Server {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    return addr.listen(.{ .reuse_address = true });
}

/// A network whose clock is the test's: `once` moves the clock by `took_ms`, then fails with `err` or answers 200.
const FakeNet = struct {
    clock_ms: *i64,
    took_ms: i64,
    err: ?anyerror,

    fn now(n: FakeNet) i64 {
        return n.clock_ms.*;
    }
    fn once(n: FakeNet, _: Allocator, _: std.http.Method, _: []const u8, _: Options) anyerror!Answer {
        n.clock_ms.* += n.took_ms;
        if (n.err) |e| return e;
        return Answer{ .status = 200, .body = "ok" };
    }
};

fn runFake(clock_ms: *i64, took_ms: i64, err: ?anyerror, timeout_secs: u32) anyerror!Answer {
    return requestWith(std.testing.allocator, .GET, "http://x/", .{ .timeout_secs = timeout_secs }, FakeNet{ .clock_ms = clock_ms, .took_ms = took_ms, .err = err });
}

test "a server that stops answering is a RequestTimedOut once the limit has passed, not a hang" {
    var clock: i64 = 1_000_000;
    // A plain socket reports its expired limit as WouldBlock: that is a timeout whatever the clock says.
    try std.testing.expectError(error.RequestTimedOut, runFake(&clock, 0, error.WouldBlock, 1));
    // A TLS stream hides the cause behind a read/write failure: it is a timeout only when the whole limit (less 100 ms) passed.
    const hidden = [_]anyerror{ error.UnexpectedReadFailure, error.UnexpectedWriteFailure, error.TlsFailure };
    for (hidden) |e| {
        try std.testing.expectError(error.RequestTimedOut, runFake(&clock, 1000, e, 1));
        try std.testing.expectError(error.RequestTimedOut, runFake(&clock, 900, e, 1));
        try std.testing.expectError(e, runFake(&clock, 899, e, 1));
        try std.testing.expectError(error.RequestTimedOut, runFake(&clock, 29_900, e, 30));
        try std.testing.expectError(e, runFake(&clock, 29_899, e, 30));
    }
    // Any other failure is returned as it came, however long it took.
    try std.testing.expectError(error.ConnectionRefused, runFake(&clock, 60_000, error.ConnectionRefused, 1));
    // No limit asked for: nothing is reclassified.
    try std.testing.expectError(error.WouldBlock, runFake(&clock, 60_000, error.WouldBlock, 0));
}

test "the limit reaches the socket: reads and writes on it give up after the seconds asked" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try loopbackServer();
    defer server.deinit();
    const stream = try std.net.tcpConnectToAddress(server.listen_address);
    defer stream.close();
    try setSocketTimeouts(stream.handle, 7);
    inline for (.{ std.posix.SO.RCVTIMEO, std.posix.SO.SNDTIMEO }) |opt| {
        var tv: Timeval = undefined;
        var len: std.posix.socklen_t = @sizeOf(Timeval);
        const rc = std.os.linux.getsockopt(stream.handle, std.posix.SOL.SOCKET, opt, std.mem.asBytes(&tv).ptr, &len);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.E.init(rc));
        try std.testing.expectEqual(@as(c_long, 7), tv.sec);
        try std.testing.expectEqual(@as(@TypeOf(tv.usec), 0), tv.usec);
    }
}

/// A server that answers a request in four pieces, each written when the test allows it: slow as a whole, never idle.
const Trickle = struct {
    server: std.net.Server,
    gate: std.Thread.Semaphore = .{},
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Serves connections (the request's connect probe is the first) until told to stop; `stop` is followed by a connect to wake the accept.
    fn serve(t: *Trickle) void {
        while (!t.stop.load(.acquire)) {
            const conn = t.server.accept() catch return;
            t.handle(conn);
        }
    }

    fn handle(t: *Trickle, conn: std.net.Server.Connection) void {
        defer conn.stream.close();
        var buf: [4096]u8 = undefined;
        var len: usize = 0;
        while (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n") == null) {
            const n = conn.stream.read(buf[len..]) catch return;
            if (n == 0) return;
            len += n;
        }
        conn.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n") catch return;
        for ("abcd") |c| {
            t.gate.wait();
            conn.stream.writeAll(&.{c}) catch return;
        }
    }
};

test "the limit is on idleness: an answer that arrives in pieces is read to the end, however long it takes in all" {
    // The clock: the answer takes 4 x 600 ms in all, longer than the 1 s limit, and still comes back whole. Only a limit
    // on the whole request would have cut it.
    var clock: i64 = 0;
    const slow = try runFake(&clock, 4 * 600, null, 1);
    try std.testing.expectEqualStrings("ok", slow.body);

    // The wire: a real answer in four pieces, each written on the test's say-so, is read to the end through request().
    var t = Trickle{ .server = try loopbackServer() };
    defer t.server.deinit();
    const thread = try std.Thread.spawn(.{}, Trickle.serve, .{&t});
    var i: u8 = 0;
    while (i < 4) : (i += 1) t.gate.post();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const url = try std.fmt.allocPrint(arena_state.allocator(), "http://127.0.0.1:{d}/slow", .{t.server.listen_address.getPort()});
    const got = request(arena_state.allocator(), .GET, url, .{ .timeout_secs = 30 });
    t.stop.store(true, .release);
    (try std.net.tcpConnectToAddress(t.server.listen_address)).close();
    thread.join();
    try std.testing.expectEqualStrings("abcd", (try got).body);
}
