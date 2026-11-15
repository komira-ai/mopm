//! The lookup behind a refused bare [package] name (bare_name.zig): the namespace `mopm login` stored for the registry,
//! read from a scratch config directory and a loopback registry that serves index/config.json.

const std = @import("std");
const core = @import("mopm_core");
const bare_name = @import("bare_name.zig");

const bare = "package name 'json' has no namespace: write name = \"<namespace>/json\"";
const api_url = "https://api.example.test/api/v1";
const config_json =
    \\{"index_version":2,"stage":"test","api_url":"https://api.example.test/api/v1","api_v2_url":"https://api.example.test/api/v2","channel_url":"https://conda.example.test/","min_cli_version":"0.0.1"}
;

/// A loopback server that answers every request with `status` and `body`, one connection at a time.
const Registry = struct {
    server: std.net.Server,
    status: std.http.Status,
    body: []const u8,

    fn serve(self: *Registry) void {
        while (true) {
            const conn = self.server.accept() catch return;
            defer conn.stream.close();
            var buf: [8 * 1024]u8 = undefined;
            var http_server = std.http.Server.init(conn, &buf);
            var req = http_server.receiveHead() catch continue;
            req.respond(self.body, .{ .status = self.status, .keep_alive = false }) catch continue;
        }
    }
};

/// The base URL of a registry answering with `status` and `body`. The serving thread is detached and outlives the test, so
/// its server is page-allocated and never freed (the convention of the stubs in http.zig and pkg_fetch.zig).
fn startRegistry(arena: std.mem.Allocator, status: std.http.Status, body: []const u8) ![]const u8 {
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    const srv = try std.heap.page_allocator.create(Registry);
    srv.* = .{ .server = try address.listen(.{ .reuse_address = true }), .status = status, .body = body };
    const t = try std.Thread.spawn(.{}, Registry.serve, .{srv});
    t.detach();
    return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.server.listen_address.getPort()});
}

/// The base URL of a loopback port nothing listens on: the connection is refused.
fn closedRegistry(arena: std.mem.Allocator) ![]const u8 {
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try address.listen(.{ .reuse_address = true });
    const port = server.listen_address.getPort();
    server.deinit();
    return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{port});
}

test "a bare [package] name is worded with the namespace stored for the registry that was asked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, "{s}/cfg", .{try tmp.dir.realpathAlloc(a, ".")});
    try core.credentials.store(a, dir, api_url, .{ .token = "t", .handle = "alice", .namespace = "alice" });
    const base = try startRegistry(a, .ok, config_json);
    try std.testing.expectEqualStrings(
        "package name 'json' has no namespace: write name = \"alice/json\" (alice is your namespace), or another namespace you publish in",
        try bare_name.reword(a, bare, .{ .registry = base, .cli_version = "0.0.1", .config_dir = dir }),
    );
}

test "a bare [package] name stays as the manifest worded it when no stored namespace can be found for the registry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    // No credentials file: no registry is asked.
    try std.testing.expectEqualStrings(bare, try bare_name.reword(a, bare, .{ .registry = "nonsense", .cli_version = "0.0.1", .config_dir = try std.fmt.allocPrint(a, "{s}/none", .{root}) }));

    const dir = try std.fmt.allocPrint(a, "{s}/cfg", .{root});
    try core.credentials.store(a, dir, api_url, .{ .token = "t", .handle = "alice", .namespace = "alice" });
    // A registry spec mopm does not take.
    try std.testing.expectEqualStrings(bare, try bare_name.reword(a, bare, .{ .registry = "nonsense", .cli_version = "0.0.1", .config_dir = dir }));
    // A registry that cannot be reached.
    try std.testing.expectEqualStrings(bare, try bare_name.reword(a, bare, .{ .registry = try closedRegistry(a), .cli_version = "0.0.1", .config_dir = dir }));
    // A registry that answers HTTP 404 for its configuration.
    try std.testing.expectEqualStrings(bare, try bare_name.reword(a, bare, .{ .registry = try startRegistry(a, .not_found, "no"), .cli_version = "0.0.1", .config_dir = dir }));
    // A registry whose configuration is not one.
    try std.testing.expectEqualStrings(bare, try bare_name.reword(a, bare, .{ .registry = try startRegistry(a, .ok, "not json"), .cli_version = "0.0.1", .config_dir = dir }));
    // A registry whose api_url holds no stored entry.
    const other = try std.fmt.allocPrint(a, "{s}/other", .{root});
    try core.credentials.store(a, other, "https://api.elsewhere.test/api/v1", .{ .token = "t", .handle = "bob", .namespace = "bob" });
    try std.testing.expectEqualStrings(bare, try bare_name.reword(a, bare, .{ .registry = try startRegistry(a, .ok, config_json), .cli_version = "0.0.1", .config_dir = other }));
}
