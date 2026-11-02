//! Tests of `mopm stage` and the readme forms (stage_cmd.zig, group_readmes.zig): a set whose readmes are too large for the
//! commit request inline is staged when the registry takes readmes as objects, and refused when it does not.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;
const gp = @import("group_publish.zig");
const st = @import("stage_test.zig");
const stage = @import("stage_cmd.zig");

const Net = gp.Net;
const Console = gp.Console;

const health_objects = "{\"status\":\"ok\",\"features\":[\"group_readme_objects\"]}";

/// A registry that answers /health with `health` (or fails it) and finds no version of any package.
const Registry = struct {
    health: ?[]const u8,
    asked: std.ArrayList([]const u8),

    fn net(r: *Registry) Net {
        return .{ .ptr = r, .vtable = &.{ .request = request, .sleep = sleep, .now = now } };
    }

    fn request(ptr: *anyopaque, arena: Allocator, _: std.http.Method, url: []const u8, _: http.Options) anyerror!http.Answer {
        const r: *Registry = @ptrCast(@alignCast(ptr));
        try r.asked.append(try arena.dupe(u8, url));
        if (std.mem.endsWith(u8, url, "/health")) {
            const body = r.health orelse return error.ConnectionRefused;
            return .{ .status = 200, .body = body };
        }
        return .{ .status = 404, .body = "{\"error\":{\"code\":\"version_not_found\",\"message\":\"no such version\",\"hint\":\"\"}}" };
    }

    fn sleep(_: *anyopaque, _: u64) void {}
    fn now(_: *anyopaque) i64 {
        return 0;
    }

    fn healthReads(r: Registry) usize {
        var n: usize = 0;
        for (r.asked.items) |u| {
            if (std.mem.endsWith(u8, u, "/health")) n += 1;
        }
        return n;
    }
};

fn runWith(fx: st.Fx, reg: *Registry, out: []const u8) !struct { code: u8, out: []const u8, err: []const u8 } {
    var console = Console.init(fx.a, null);
    const code = try stage.run(.{ .arena = fx.a, .net = reg.net(), .console = &console, .api_url = st.api, .flags = try fx.flags(out, &.{}) });
    return .{ .code = code, .out = console.out.items, .err = console.err.items };
}

test "readmes too large for the commit request inline are staged when /health lists the capability, and refused when it does not" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    // 80 readmes of 60000 letters: 6.4 MB in base64, over what the commit request may hold inline.
    try st.manyReadmes(fx, 80, 60000, 0, 'r');

    var plain = Registry{ .health = "{\"status\":\"ok\"}", .asked = std.ArrayList([]const u8).init(a) };
    const refused = try runWith(fx, &plain, "plain");
    try std.testing.expectEqual(@as(u8, 1), refused.code);
    try st.expectContainsText(refused.err, "the commit request of the 80 members to upload is ");
    try st.expectContainsText(refused.err, "; nothing was written\n");
    try st.expectContainsText(refused.err, "the registry does not take readmes as objects (its /health lists no group_readme_objects)");
    try std.testing.expectEqual(@as(usize, 1), plain.healthReads());
    try std.testing.expect(!fx.exists("plain"));

    var objects = Registry{ .health = health_objects, .asked = std.ArrayList([]const u8).init(a) };
    const staged = try runWith(fx, &objects, "objects");
    try std.testing.expectEqual(@as(u8, 0), staged.code);
    try std.testing.expectEqual(@as(usize, 1), objects.healthReads());
    try std.testing.expect(fx.exists("objects/plan.json"));
    // The readmes are staged as files, as for a set that fits.
    try std.testing.expect(fx.exists("objects/pkg_0/README.md"));
}

test "a set that fits inline does not ask /health, and one that does not stops when /health cannot be read" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    try st.manyReadmes(fx, 3, 100, 0, 'r');
    var broken = Registry{ .health = null, .asked = std.ArrayList([]const u8).init(a) };
    const fits = try runWith(fx, &broken, "fits");
    try std.testing.expectEqual(@as(u8, 0), fits.code);
    try std.testing.expectEqual(@as(usize, 0), broken.healthReads());
    // The stand-in's clock stands still and its sleeps are no waits.
    broken.net().vtable.sleep(&broken, 1);
    try std.testing.expectEqual(@as(i64, 0), broken.net().vtable.now(&broken));

    try st.manyReadmes(fx, 80, 60000, 0, 'r');
    const stopped = try runWith(fx, &broken, "stopped");
    try std.testing.expectEqual(@as(u8, 1), stopped.code);
    try st.expectContainsText(stopped.err, "mopm: GET /health: ConnectionRefused; nothing was written\n");
    try std.testing.expect(!fx.exists("stopped"));
}
