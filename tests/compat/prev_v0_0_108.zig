//! The previous release (v0.0.108, the last one before names moved into namespaces) as one module: the readers of its
//! command line's core (src/core at the tag) and its fake registry (registry/fake at the tag), vendored byte for byte under
//! tests/compat/v0.0.108 (README.md there; SHA256SUMS pins every file). Only this file is written here.
//!
//! The core files import nothing but each other and `std`, so they build as part of this module; the fake registry's handler
//! is called as the server calls it, through `Fx`, defined below.

const std = @import("std");
const Value = std.json.Value;

pub const manifest = @import("v0.0.108/core/manifest.zig");
pub const lock = @import("v0.0.108/core/lock.zig");
pub const metadata = @import("v0.0.108/core/metadata.zig");
pub const registry = @import("v0.0.108/core/registry.zig");
pub const resolve = @import("v0.0.108/core/resolve.zig");
pub const unit_graph = @import("v0.0.108/core/unit_graph.zig");
pub const overlay = @import("v0.0.108/core/overlay.zig");
pub const ci_oidc = @import("v0.0.108/core/ci_oidc.zig");
pub const http = @import("v0.0.108/core/http.zig");

const api = @import("v0.0.108/fake/api.zig");
pub const st = @import("v0.0.108/fake/state.zig");
const files = @import("v0.0.108/fake/files.zig");

/// The version string this release's `mopm --version` printed.
pub const cli_version = "0.0.108";

pub const Reply = struct { status: u16, body: []const u8, value: Value };

/// The previous fake registry over a temporary data directory, holding the account `alice`.
pub const Fx = struct {
    tmp: std.testing.TmpDir,
    life: std.heap.ArenaAllocator,
    state: st.State,
    alice: *st.User,

    pub fn setup(fx: *Fx, base_url: []const u8) !void {
        fx.tmp = std.testing.tmpDir(.{});
        fx.life = std.heap.ArenaAllocator.init(std.testing.allocator);
        const a = fx.life.allocator();
        const dir = try fx.tmp.dir.realpathAlloc(a, ".");
        fx.state = .{ .alloc = a, .base_url = base_url, .stage = "beta", .dir = dir };
        fx.alice = try fx.state.ensureUser("alice");
        try files.rewrite(a, &fx.state);
    }

    pub fn deinit(fx: *Fx) void {
        fx.life.deinit();
        fx.tmp.cleanup();
    }

    /// One request, as the server serves it: the request data lives in an arena that is freed after the answer.
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
