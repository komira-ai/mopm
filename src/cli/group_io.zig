//! What a staged publish needs of the world, so its tests need no socket: the network, the clock and the console.
//! `group_publish.zig` re-exports `Net` and `Console`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;

// ---------------------------------------------------------------- the network

/// What the run needs of the world, so its tests need no socket: requests, time and sleeping.
pub const Net = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// The time limit of every request and how often an idempotent one is repeated (`--timeout`, `--retries`).
    policy: http.Policy = .{},

    pub const VTable = struct {
        request: *const fn (ptr: *anyopaque, arena: Allocator, method: std.http.Method, url: []const u8, options: http.Options) anyerror!http.Answer,
        sleep: *const fn (ptr: *anyopaque, secs: u64) void,
        now: *const fn (ptr: *anyopaque) i64,
    };

    /// One request, repeated by the policy when it is idempotent and fails in a way a second try can cure.
    pub fn request(n: Net, arena: Allocator, method: std.http.Method, url: []const u8, options: http.Options) anyerror!http.Answer {
        return http.retrying(arena, n, method, url, options, n.policy);
    }
    /// One try, as `http.retrying` asks for it.
    pub fn once(n: Net, arena: Allocator, method: std.http.Method, url: []const u8, options: http.Options) anyerror!http.Answer {
        return n.vtable.request(n.ptr, arena, method, url, options);
    }
    /// The wait between tries, as `http.retrying` asks for it.
    pub fn pause(n: Net, secs: u64) void {
        n.sleep(secs);
    }
    pub fn sleep(n: Net, secs: u64) void {
        n.vtable.sleep(n.ptr, secs);
    }
    pub fn now(n: Net) i64 {
        return n.vtable.now(n.ptr);
    }
};

var real_marker: u8 = 0;
const real_vtable = Net.VTable{ .request = realRequest, .sleep = realSleep, .now = realNow };

pub fn realNet() Net {
    return .{ .ptr = &real_marker, .vtable = &real_vtable };
}

fn realRequest(_: *anyopaque, arena: Allocator, method: std.http.Method, url: []const u8, options: http.Options) anyerror!http.Answer {
    return http.request(arena, method, url, options);
}

fn realSleep(_: *anyopaque, secs: u64) void {
    std.time.sleep(secs * std.time.ns_per_s);
}

fn realNow(_: *anyopaque) i64 {
    return std.time.timestamp();
}

// ----------------------------------------------------------------- the console

/// What the run says. Each line is held until `flush`, which hands both streams to the sink; with no sink (the tests) the
/// text stays in `out` and `err` to be read.
pub const Console = struct {
    out: std.ArrayList(u8),
    err: std.ArrayList(u8),
    sink: ?*const fn (out: []const u8, err: []const u8) void,

    pub fn init(arena: Allocator, sink: ?*const fn (out: []const u8, err: []const u8) void) Console {
        return .{ .out = std.ArrayList(u8).init(arena), .err = std.ArrayList(u8).init(arena), .sink = sink };
    }

    /// The sink of the real commands: standard output and standard error.
    pub fn stdStreams(out: []const u8, errs: []const u8) void {
        std.io.getStdOut().writeAll(out) catch {};
        std.io.getStdErr().writeAll(errs) catch {};
    }

    pub fn say(c: *Console, comptime fmt: []const u8, args: anytype) void {
        c.out.writer().print(fmt, args) catch {};
        c.flush();
    }

    pub fn fail(c: *Console, comptime fmt: []const u8, args: anytype) void {
        c.err.writer().print("mopm: " ++ fmt, args) catch {};
        c.flush();
    }

    /// A line that goes on from the last `fail`: indented, with no `mopm:`.
    pub fn note(c: *Console, comptime fmt: []const u8, args: anytype) void {
        c.err.writer().print("  " ++ fmt, args) catch {};
        c.flush();
    }

    fn flush(c: *Console) void {
        const sink = c.sink orelse return;
        sink(c.out.items, c.err.items);
        c.out.clearRetainingCapacity();
        c.err.clearRetainingCapacity();
    }
};

