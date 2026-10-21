//! A small HTTP client for the registry: one request per call, the answer's
//! status, body, `x-mopm-request-id` and `Retry-After`, and the contract's
//! error shape (`{"error": {"code", "message", "hint"}}`) made readable.
//!
//! A token goes only into the `Authorization` header; nothing here prints it.

const std = @import("std");
const Allocator = std.mem.Allocator;

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
};

pub fn request(arena: Allocator, method: std.http.Method, url: []const u8, options: Options) !Answer {
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

pub const ApiError = struct { code: []const u8, message: []const u8, hint: []const u8 };

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
