//! The fake registry of the previous release (v0.0.104) as a module: the request handler of the vendored files in
//! tests/compat/v0.0.104/fake (byte for byte as released, see the README there) and a fixture to call it, the part of
//! registry/fake/groups_test.zig at that tag (`Fx`) that the compat test needs. Only this file is written here.
//!
//! The handler is built as the server builds it: `api.handle` is given a `Ctx` whose request data lives in an arena that is
//! freed after the answer.

const std = @import("std");
const Value = std.json.Value;
pub const api = @import("v0.0.104/fake/api.zig");
pub const st = @import("v0.0.104/fake/state.zig");
const files = @import("v0.0.104/fake/files.zig");

pub const Reply = struct { status: u16, body: []const u8, value: Value };

pub const Fx = struct {
    tmp: std.testing.TmpDir,
    life: std.heap.ArenaAllocator,
    state: st.State,
    alice: *st.User,

    pub fn setup(fx: *Fx) !void {
        fx.tmp = std.testing.tmpDir(.{});
        fx.life = std.heap.ArenaAllocator.init(std.testing.allocator);
        const a = fx.life.allocator();
        const dir = try fx.tmp.dir.realpathAlloc(a, ".");
        fx.state = .{ .alloc = a, .base_url = "http://fake.test", .stage = "beta", .dir = dir };
        fx.alice = try fx.state.ensureUser("alice");
        try files.rewrite(a, &fx.state);
    }

    pub fn deinit(fx: *Fx) void {
        fx.life.deinit();
        fx.tmp.cleanup();
    }

    /// One request, as the server serves it.
    pub fn call(fx: *Fx, method: std.http.Method, path: []const u8, body: []const u8, token: ?[]const u8) !Reply {
        const life = fx.life.allocator();
        var request_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer request_arena.deinit();
        const a = request_arena.allocator();
        var ctx = api.Ctx{
            .arena = a,
            .state = &fx.state,
            .method = method,
            .path = try a.dupe(u8, path),
            .query = "",
            .body = try a.dupe(u8, body),
            .authorization = if (token) |t| try std.fmt.allocPrint(a, "Bearer {s}", .{t}) else null,
        };
        const r = try api.handle(&ctx);
        const kept = try life.dupe(u8, r.body);
        const value = std.json.parseFromSliceLeaky(Value, life, kept, .{}) catch Value{ .null = {} };
        return .{ .status = @intFromEnum(r.status), .body = kept, .value = value };
    }
};
