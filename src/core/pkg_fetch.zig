//! Downloading a package file and keeping it only if it is the pinned bytes.
//!
//! `fetch` streams the body of a GET into a temporary file next to the final
//! one, hashing as it goes, and renames it into place only when its size and
//! sha256 are the pinned ones. A file already in place is used without any
//! network traffic, but only after its own size and sha256 check out again, so
//! a cache entry that was damaged or replaced is downloaded anew, never
//! trusted. Two processes fetching the same file do not disturb each other:
//! each writes its own temporary name, and a rename onto an existing file of
//! the same verified bytes changes nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Diag = struct { message: []const u8 = "" };

pub const Pin = struct {
    /// Lowercase hex sha256 of the file.
    sha256: []const u8,
    size: u64,
};

pub const Error = error{ DownloadFailed, BadStatus, SizeMismatch, HashMismatch };

/// The size and lowercase hex sha256 of the file `name` in `dir`; null when it
/// is not there.
fn digestOf(dir: std.fs.Dir, name: []const u8) !?struct { size: u64, hex: [64]u8 } {
    const file = dir.openFile(name, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer file.close();
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
        total += n;
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    return .{ .size = total, .hex = std.fmt.bytesToHex(d, .lower) };
}

/// True when `name` in `dir` is a file of exactly `pin`'s size and sha256.
pub fn matches(dir: std.fs.Dir, name: []const u8, pin: Pin) !bool {
    const d = (try digestOf(dir, name)) orelse return false;
    return d.size == pin.size and std.mem.eql(u8, &d.hex, pin.sha256);
}

fn tempName(arena: Allocator, final: []const u8) ![]u8 {
    var r: [6]u8 = undefined;
    std.crypto.random.bytes(&r);
    return std.fmt.allocPrint(arena, "{s}.part-{s}", .{ final, std.fmt.bytesToHex(r, .lower) });
}

/// Makes `dir/name` the file at `url` with `pin`'s size and sha256, downloading
/// it unless it is already there. On failure nothing is left at `name` that
/// was not there before (a bad download is removed), and `diag` says why.
pub fn fetch(arena: Allocator, dir: std.fs.Dir, name: []const u8, url: []const u8, pin: Pin, diag: *Diag) !void {
    if (try matches(dir, name, pin)) return;

    const tmp = try tempName(arena, name);
    var kept = false;
    defer {
        if (!kept) dir.deleteFile(tmp) catch {};
    }

    var client = std.http.Client{ .allocator = arena };
    defer client.deinit();
    const uri = std.Uri.parse(url) catch {
        diag.message = try std.fmt.allocPrint(arena, "{s} is not a URL", .{url});
        return error.DownloadFailed;
    };
    var header_buf: [16 * 1024]u8 = undefined;
    var req = client.open(.GET, uri, .{
        .server_header_buffer = &header_buf,
        .keep_alive = false,
        .headers = .{
            .user_agent = .{ .override = "mopm" },
            .accept_encoding = .{ .override = "identity" },
        },
    }) catch |e| {
        diag.message = try std.fmt.allocPrint(arena, "cannot reach {s}: {s}", .{ url, @errorName(e) });
        return error.DownloadFailed;
    };
    defer req.deinit();
    req.send() catch |e| {
        diag.message = try std.fmt.allocPrint(arena, "cannot send the request to {s}: {s}", .{ url, @errorName(e) });
        return error.DownloadFailed;
    };
    req.finish() catch |e| {
        diag.message = try std.fmt.allocPrint(arena, "cannot send the request to {s}: {s}", .{ url, @errorName(e) });
        return error.DownloadFailed;
    };
    req.wait() catch |e| {
        diag.message = try std.fmt.allocPrint(arena, "cannot read the answer of {s}: {s}", .{ url, @errorName(e) });
        return error.DownloadFailed;
    };
    const status = @intFromEnum(req.response.status);
    if (status < 200 or status >= 300) {
        diag.message = try std.fmt.allocPrint(arena, "{s} answered HTTP {d}", .{ url, status });
        return error.BadStatus;
    }

    const file = try dir.createFile(tmp, .{});
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u64 = 0;
    {
        defer file.close();
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = req.reader().read(&buf) catch |e| {
                diag.message = try std.fmt.allocPrint(arena, "the download of {s} broke off: {s}", .{ url, @errorName(e) });
                return error.DownloadFailed;
            };
            if (n == 0) break;
            total += n;
            // Never keep reading past the pinned size.
            if (total > pin.size) {
                diag.message = try std.fmt.allocPrint(arena, "{s} is larger than the pinned {d} bytes; refused", .{ url, pin.size });
                return error.SizeMismatch;
            }
            h.update(buf[0..n]);
            try file.writeAll(buf[0..n]);
        }
    }
    if (total != pin.size) {
        diag.message = try std.fmt.allocPrint(arena, "{s} is {d} bytes; the pin says {d}; refused", .{ url, total, pin.size });
        return error.SizeMismatch;
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    const hex = std.fmt.bytesToHex(d, .lower);
    if (!std.mem.eql(u8, &hex, pin.sha256)) {
        diag.message = try std.fmt.allocPrint(arena, "{s} has sha256 {s}; the pin says {s}; refused", .{ url, hex, pin.sha256 });
        return error.HashMismatch;
    }
    try dir.rename(tmp, name);
    kept = true;
}

// ---------------------------------------------------------------- tests

/// A loopback HTTP server: /good.conda, /bad.conda (the same length, other
/// bytes), /long.conda (longer) and 404 for anything else. It counts requests.
/// It is never shut down: its thread ends with the test process.
const Stub = struct {
    server: std.net.Server,
    good: []const u8,
    bad: []const u8,
    long: []const u8,
    hits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn start(good: []const u8, bad: []const u8, long: []const u8) !*Stub {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        const stub = try std.heap.page_allocator.create(Stub);
        stub.* = .{ .server = try addr.listen(.{ .reuse_address = true }), .good = good, .bad = bad, .long = long };
        const t = try std.Thread.spawn(.{}, serve, .{stub});
        t.detach();
        return stub;
    }

    fn serve(self: *Stub) void {
        while (true) {
            const conn = self.server.accept() catch return;
            self.handle(conn);
        }
    }

    fn handle(self: *Stub, conn: std.net.Server.Connection) void {
        defer conn.stream.close();
        var buf: [8192]u8 = undefined;
        var http = std.http.Server.init(conn, &buf);
        var req = http.receiveHead() catch return;
        _ = self.hits.fetchAdd(1, .monotonic);
        const target = req.head.target;
        if (std.mem.eql(u8, target, "/good.conda")) {
            req.respond(self.good, .{ .keep_alive = false }) catch {};
        } else if (std.mem.eql(u8, target, "/bad.conda")) {
            req.respond(self.bad, .{ .keep_alive = false }) catch {};
        } else if (std.mem.eql(u8, target, "/long.conda")) {
            req.respond(self.long, .{ .keep_alive = false }) catch {};
        } else {
            req.respond("no", .{ .status = .not_found, .keep_alive = false }) catch {};
        }
    }

    fn url(self: *Stub, a: Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ self.server.listen_address.getPort(), path });
    }

    fn count(self: *Stub) u32 {
        return self.hits.load(.monotonic);
    }
};

fn hexOf(a: Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
}

fn names(a: Allocator, dir: std.fs.Dir) ![]const u8 {
    var list = std.ArrayList([]const u8).init(a);
    var it = dir.iterate();
    while (try it.next()) |e| try list.append(try a.dupe(u8, e.name));
    std.mem.sort([]const u8, list.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return std.mem.join(a, ",", list.items);
}

// A body larger than one read buffer, so the loop runs more than once.
const good_bytes = "0123456789abcdef" ** 8192;
const bad_bytes = "0123456789abcdeF" ** 8192;
const long_bytes = good_bytes ++ "!";

test "fetch: download and verify, then reuse the file without any request" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const stub = try Stub.start(good_bytes, bad_bytes, long_bytes);
    const pin = Pin{ .sha256 = try hexOf(a, good_bytes), .size = good_bytes.len };
    var diag = Diag{};

    try fetch(a, tmp.dir, "pkg.conda", try stub.url(a, "/good.conda"), pin, &diag);
    try std.testing.expectEqualStrings(good_bytes, try tmp.dir.readFileAlloc(a, "pkg.conda", 1 << 20));
    try std.testing.expectEqual(@as(u32, 1), stub.count());
    try std.testing.expectEqualStrings("pkg.conda", try names(a, tmp.dir));

    // The URL now points at nothing: a verified copy is used without asking.
    try fetch(a, tmp.dir, "pkg.conda", try stub.url(a, "/gone.conda"), pin, &diag);
    try std.testing.expectEqual(@as(u32, 1), stub.count());

    // A damaged copy is not trusted: it is downloaded again.
    try tmp.dir.writeFile("pkg.conda", "damaged");
    try fetch(a, tmp.dir, "pkg.conda", try stub.url(a, "/good.conda"), pin, &diag);
    try std.testing.expectEqual(@as(u32, 2), stub.count());
    try std.testing.expectEqualStrings(good_bytes, try tmp.dir.readFileAlloc(a, "pkg.conda", 1 << 20));
}

test "fetch: tampered bytes, a wrong length and an error status are refused and leave nothing" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const stub = try Stub.start(good_bytes, bad_bytes, long_bytes);
    const pin = Pin{ .sha256 = try hexOf(a, good_bytes), .size = good_bytes.len };
    var diag = Diag{};

    // The same length, one byte different: only the sha256 can tell.
    try std.testing.expectError(error.HashMismatch, fetch(a, tmp.dir, "pkg.conda", try stub.url(a, "/bad.conda"), pin, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "refused") != null);
    try std.testing.expectEqualStrings("", try names(a, tmp.dir));

    try std.testing.expectError(error.SizeMismatch, fetch(a, tmp.dir, "pkg.conda", try stub.url(a, "/long.conda"), pin, &diag));
    try std.testing.expectEqualStrings("", try names(a, tmp.dir));

    try std.testing.expectError(error.BadStatus, fetch(a, tmp.dir, "pkg.conda", try stub.url(a, "/missing.conda"), pin, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "HTTP 404") != null);
    try std.testing.expectEqualStrings("", try names(a, tmp.dir));

    // A refused download does not disturb a verified file that was there.
    try fetch(a, tmp.dir, "keep.conda", try stub.url(a, "/good.conda"), pin, &diag);
    try tmp.dir.writeFile("other.conda", "x");
    try std.testing.expectError(error.HashMismatch, fetch(a, tmp.dir, "other.conda", try stub.url(a, "/bad.conda"), pin, &diag));
    try std.testing.expectEqualStrings(good_bytes, try tmp.dir.readFileAlloc(a, "keep.conda", 1 << 20));
}

test "fetch: two fetches of the same file at once both end with the verified file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const stub = try Stub.start(good_bytes, bad_bytes, long_bytes);
    const pin = Pin{ .sha256 = try hexOf(a, good_bytes), .size = good_bytes.len };
    const url = try stub.url(a, "/good.conda");

    const Worker = struct {
        fn run(dir: std.fs.Dir, u: []const u8, p: Pin, ok: *bool) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            var d = Diag{};
            fetch(arena.allocator(), dir, "pkg.conda", u, p, &d) catch {
                ok.* = false;
                return;
            };
            ok.* = true;
        }
    };
    var ok1 = false;
    var ok2 = false;
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{ tmp.dir, url, pin, &ok1 });
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{ tmp.dir, url, pin, &ok2 });
    t1.join();
    t2.join();
    try std.testing.expect(ok1 and ok2);
    try std.testing.expect(try matches(tmp.dir, "pkg.conda", pin));
    try std.testing.expectEqualStrings("pkg.conda", try names(a, tmp.dir));
}
