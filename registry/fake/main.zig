//! mopm-fake-registry: a local stand-in for the hosted registry, serving the
//! contract in spec/ (api/openapi.yaml, channel.md, index.md) from memory and a
//! directory, so that the CLI can be tested without the real service.
//!
//!   mopm-fake-registry --dir <dir> [--port <n>] [--stage beta|gamma|prod]
//!
//! It listens on 127.0.0.1 (port 0 picks a free one) and prints
//! `mopm-fake-registry listening on http://127.0.0.1:<port>` as its first line.
//! One request at a time; every connection is closed after its answer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");
const resp = @import("resp.zig");
const State = @import("state.zig").State;

const usage = "usage: mopm-fake-registry --dir <dir> [--port <n>] [--stage beta|gamma|prod]\n";

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    // The registry's state lives as long as the process.
    var lifetime = std.heap.ArenaAllocator.init(gpa);
    const alloc = lifetime.allocator();

    const args = try std.process.argsAlloc(alloc);
    var port: u16 = 0;
    var dir_path: ?[]const u8 = null;
    var stage: []const u8 = "beta";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (i + 1 >= args.len) return fatal(usage);
        if (std.mem.eql(u8, a, "--port")) {
            port = std.fmt.parseInt(u16, args[i + 1], 10) catch return fatal(usage);
        } else if (std.mem.eql(u8, a, "--dir")) {
            dir_path = args[i + 1];
        } else if (std.mem.eql(u8, a, "--stage")) {
            stage = args[i + 1];
            if (!std.mem.eql(u8, stage, "beta") and !std.mem.eql(u8, stage, "gamma") and !std.mem.eql(u8, stage, "prod")) {
                return fatal(usage);
            }
        } else return fatal(usage);
        i += 1;
    }
    const root = dir_path orelse return fatal(usage);
    try std.fs.cwd().makePath(root);

    const address = try std.net.Address.parseIp("127.0.0.1", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    var state = State{
        .alloc = alloc,
        .base_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{server.listen_address.getPort()}),
        .stage = stage,
    };
    const out = std.io.getStdOut().writer();
    try out.print("mopm-fake-registry listening on {s}\n", .{state.base_url});

    while (true) {
        const conn = server.accept() catch |e| {
            std.log.err("accept: {s}", .{@errorName(e)});
            continue;
        };
        serve(gpa, &state, conn);
    }
}

fn fatal(message: []const u8) noreturn {
    std.io.getStdErr().writeAll(message) catch {};
    std.process.exit(2);
}

/// Answers the requests of one connection, then closes it.
fn serve(gpa: Allocator, state: *State, conn: std.net.Server.Connection) void {
    defer conn.stream.close();
    var buf: [64 * 1024]u8 = undefined;
    var http = std.http.Server.init(conn, &buf);
    while (http.state == .ready) {
        var request = http.receiveHead() catch return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        answer(arena.allocator(), state, &request) catch |e| {
            std.log.err("{s} {s}: {s}", .{ @tagName(request.head.method), request.head.target, @errorName(e) });
            return;
        };
    }
}

fn answer(arena: Allocator, state: *State, request: *std.http.Server.Request) !void {
    var authorization: ?[]const u8 = null;
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) authorization = try arena.dupe(u8, h.value);
    }
    const target = try arena.dupe(u8, request.head.target);
    const has_body = request.head.content_length != null or request.head.transfer_encoding == .chunked;
    const body = if (has_body) try (try request.reader()).readAllAlloc(arena, 64 << 20) else "";

    const q = std.mem.indexOfScalar(u8, target, '?');
    var ctx = api.Ctx{
        .arena = arena,
        .state = state,
        .method = request.head.method,
        .path = if (q) |n| target[0..n] else target,
        .query = if (q) |n| target[n + 1 ..] else "",
        .body = body,
        .authorization = authorization,
    };
    const r = api.handle(&ctx) catch |e| blk: {
        std.log.err("{s} {s}: {s}", .{ @tagName(ctx.method), ctx.path, @errorName(e) });
        break :blk try resp.fail(arena, .internal_error, &.{});
    };

    const request_id = try std.fmt.allocPrint(arena, "fake-{d}", .{state.next_request});
    state.next_request += 1;
    var headers = std.ArrayList(std.http.Header).init(arena);
    try headers.append(.{ .name = "x-mopm-request-id", .value = request_id });
    if (r.body.len > 0) try headers.append(.{ .name = "content-type", .value = "application/json" });
    if (r.retry_after) |secs| {
        try headers.append(.{ .name = "retry-after", .value = try std.fmt.allocPrint(arena, "{d}", .{secs}) });
    }
    try request.respond(r.body, .{ .status = r.status, .extra_headers = headers.items, .keep_alive = false });
}

test {
    _ = @import("errors.zig");
    _ = @import("util.zig");
    _ = @import("api.zig");
    _ = @import("auth.zig");
    _ = @import("control.zig");
    _ = @import("packages.zig");
}
