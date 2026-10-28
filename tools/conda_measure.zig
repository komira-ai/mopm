//! Measures what conda-forge serves, as a markdown report on stdout: the facts that decide how mopm reads repodata
//! (docs/design/any-conda-forge-native.md, section 8, PR 1). For each subdir it reports
//!   a. whether repodata_shards.msgpack.zst is served (CEP 16), the size of the shard index, and the size and latency of a few shards;
//!   b. the size of repodata.json.zst;
//!   c. the size of a name-only index (every package name, one per line), raw, gzip -9 and zstd -19, and the time to read it back;
//!   d. time to first byte and total time of each download, from wherever this runs.
//! The name index is built by scanning the decompressed repodata for `"name": "..."` keys; the scan never holds the file.
//!
//!   zig run tools/conda_measure.zig -- <work-dir>
//!
//! It needs the network and the `zstd` and `gzip` programs, so only a GitHub-hosted runner runs it (.github/workflows/conda-measure.yml);
//! a Buck2 farm action has no such guarantee. It reports and never judges: a subdir that fails prints the error and the run goes on.

const std = @import("std");
const Allocator = std.mem.Allocator;

const base = "https://conda.anaconda.org/conda-forge";
const subdirs = [_][]const u8{ "linux-64", "linux-aarch64", "osx-arm64", "noarch" };
const sample_names = [_][]const u8{ "python", "numpy", "openssl", "liblzma", "libzlib" };
const trials = 5;
/// A package name never reaches this length; the scan keeps this many bytes of the previous chunk so a name cut by a chunk edge is seen whole.
const carry = 512;

const Fetch = struct { status: u16 = 0, bytes: u64 = 0, ttfb_ms: u64 = 0, total_ms: u64 = 0 };

/// GET `url` into the file `path`, counting bytes and timing the first byte and the end. A non-2xx status is returned, not an error.
fn fetch(url: []const u8, path: []const u8, a: Allocator) !Fetch {
    var client = std.http.Client{ .allocator = a };
    defer client.deinit();
    var timer = try std.time.Timer.start();
    var header_buf: [16 * 1024]u8 = undefined;
    var req = try client.open(.GET, try std.Uri.parse(url), .{
        .server_header_buffer = &header_buf,
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = "mopm-conda-measure" }, .accept_encoding = .{ .override = "identity" } },
    });
    defer req.deinit();
    try req.send();
    try req.finish();
    try req.wait();
    var r = Fetch{ .status = @intFromEnum(req.response.status), .ttfb_ms = timer.read() / std.time.ns_per_ms };
    if (r.status < 200 or r.status >= 300) return r;
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try req.reader().read(&buf);
        if (n == 0) break;
        try file.writeAll(buf[0..n]);
        r.bytes += n;
    }
    r.total_ms = timer.read() / std.time.ns_per_ms;
    return r;
}

/// The 32 bytes after `name` in a decompressed shard index: msgpack writes the key as a fixstr and the value as a bin8 of length 32.
pub fn findShardHash(index: []const u8, name: []const u8, a: Allocator) !?[32]u8 {
    const needle = try std.mem.concat(a, u8, &.{ &.{@as(u8, 0xa0) | @as(u8, @intCast(name.len))}, name, &.{ 0xc4, 0x20 } });
    defer a.free(needle);
    const at = std.mem.indexOf(u8, index, needle) orelse return null;
    const from = at + needle.len;
    if (from + 32 > index.len) return null;
    return index[from..][0..32].*;
}

/// The value of the `shards_base_url` key of a shard index (a msgpack string), or null.
pub fn shardsBase(index: []const u8) ?[]const u8 {
    const key = "shards_base_url";
    const at = std.mem.indexOf(u8, index, key) orelse return null;
    var i = at + key.len;
    if (i >= index.len) return null;
    var len: usize = undefined;
    switch (index[i]) {
        0xa0...0xbf => |m| {
            len = m & 0x1f;
            i += 1;
        },
        0xd9 => {
            if (i + 2 > index.len) return null;
            len = index[i + 1];
            i += 2;
        },
        else => return null,
    }
    if (i + len > index.len) return null;
    return index[i..][0..len];
}

/// Every distinct value of a `"name": "<value>"` key in the bytes fed to it, in chunks.
pub const Names = struct {
    set: std.StringHashMap(void),
    arena: std.heap.ArenaAllocator,
    joined: std.ArrayList(u8),
    tail: [carry]u8 = undefined,
    tail_len: usize = 0,

    pub fn init(a: Allocator) Names {
        return .{ .set = std.StringHashMap(void).init(a), .arena = std.heap.ArenaAllocator.init(a), .joined = std.ArrayList(u8).init(a) };
    }

    pub fn feed(self: *Names, chunk: []const u8) !void {
        self.joined.clearRetainingCapacity();
        try self.joined.appendSlice(self.tail[0..self.tail_len]);
        try self.joined.appendSlice(chunk);
        const s = self.joined.items;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, s, i, "\"name\"")) |k| : (i = k + 6) {
            var j = k + 6;
            while (j < s.len and (s[j] == ' ' or s[j] == ':')) j += 1;
            if (j >= s.len or s[j] != '"') continue;
            const end = std.mem.indexOfScalarPos(u8, s, j + 1, '"') orelse continue;
            const name = s[j + 1 .. end];
            if (name.len == 0 or self.set.contains(name)) continue;
            try self.set.put(try self.arena.allocator().dupe(u8, name), {});
        }
        self.tail_len = @min(carry, s.len);
        @memcpy(self.tail[0..self.tail_len], s[s.len - self.tail_len ..]);
    }
};

fn run(a: Allocator, argv: []const []const u8) !void {
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv });
    if (r.term != .Exited or r.term.Exited != 0) return error.ChildFailed;
}

fn fileSize(path: []const u8) !u64 {
    return (try std.fs.cwd().statFile(path)).size;
}

fn mib(n: u64) f64 {
    return @as(f64, @floatFromInt(n)) / (1 << 20);
}

fn median(v: []u64) u64 {
    std.mem.sort(u64, v, {}, std.sort.asc(u64));
    return v[v.len / 2];
}

fn shards(w: anytype, a: Allocator, dir: []const u8, sd: []const u8) !void {
    const zst = try std.fmt.allocPrint(a, "{s}/{s}.shards.zst", .{ dir, sd });
    const raw = try std.fmt.allocPrint(a, "{s}/{s}.shards", .{ dir, sd });
    const f = try fetch(try std.fmt.allocPrint(a, "{s}/{s}/repodata_shards.msgpack.zst", .{ base, sd }), zst, a);
    if (f.status != 200) return w.print("| {s} | shards | HTTP {d} (not served) | | | |\n", .{ sd, f.status });
    try run(a, &.{ "zstd", "-d", "-q", "-f", "--long=31", "-o", raw, zst });
    const index = try std.fs.cwd().readFileAlloc(a, raw, 1 << 30);
    const entries = std.mem.count(u8, index, &.{ 0xc4, 0x20 });
    try w.print("| {s} | shard index | {d:.2} MiB zst, {d:.2} MiB raw, ~{d} entries | ttfb {d} ms, total {d} ms | | |\n", .{ sd, mib(f.bytes), mib(index.len), entries, f.ttfb_ms, f.total_ms });
    const shards_base = shardsBase(index) orelse "./shards/";
    const prefix = if (std.mem.startsWith(u8, shards_base, "http")) shards_base else try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ base, sd, std.mem.trimLeft(u8, shards_base, "./") });
    for (sample_names) |name| {
        const hash = (try findShardHash(index, name, a)) orelse {
            try w.print("| {s} | shard {s} | not in the index | | | |\n", .{ sd, name });
            continue;
        };
        const hex = std.fmt.bytesToHex(hash, .lower);
        const url = try std.fmt.allocPrint(a, "{s}{s}{s}.msgpack.zst", .{ prefix, @as([]const u8, if (std.mem.endsWith(u8, prefix, "/")) "" else "/"), &hex });
        var ms: [trials]u64 = undefined;
        var first = Fetch{};
        for (&ms, 0..) |*m, i| {
            const r = try fetch(url, zst, a);
            if (i == 0) first = r;
            m.* = r.total_ms;
        }
        try w.print("| {s} | shard {s} | HTTP {d}, {d} B | first {d} ms | median of {d}: {d} ms | |\n", .{ sd, name, first.status, first.bytes, first.total_ms, trials, median(&ms) });
    }
}

/// Writes the names, sorted, one per line, to `<dir>/<tag>.names` and reports its size raw, gzip -9 and zstd -19, and the time to read the gzip back and split it.
fn nameIndex(w: anytype, a: Allocator, dir: []const u8, tag: []const u8, set: *std.StringHashMap(void)) !void {
    var list = std.ArrayList([]const u8).init(a);
    var it = set.keyIterator();
    while (it.next()) |k| try list.append(k.*);
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    const path = try std.fmt.allocPrint(a, "{s}/{s}.names", .{ dir, tag });
    try std.fs.cwd().writeFile(path, try std.mem.join(a, "\n", list.items));
    try run(a, &.{ "gzip", "-9", "-k", "-f", path });
    try run(a, &.{ "zstd", "-19", "-q", "-f", path, "-o", try std.fmt.allocPrint(a, "{s}.zst", .{path}) });
    var timer = try std.time.Timer.start();
    const gz = try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}.gz", .{path}), 1 << 28);
    var stream = std.io.fixedBufferStream(gz);
    var out = std.ArrayList(u8).init(a);
    try std.compress.gzip.decompress(stream.reader(), out.writer());
    const lines = std.mem.count(u8, out.items, "\n") + 1;
    const ms = timer.read() / std.time.ns_per_ms;
    try w.print("| {s} | name index | {d} names, {d:.2} MiB raw, {d:.2} MiB gzip -9, {d:.2} MiB zstd -19 | read back and split: {d} ms | | |\n", .{
        tag, lines, mib(try fileSize(path)), mib(gz.len), mib(try fileSize(try std.fmt.allocPrint(a, "{s}.zst", .{path}))), ms,
    });
}

fn repodata(w: anytype, a: Allocator, dir: []const u8, sd: []const u8, all: *std.StringHashMap(void)) !void {
    const zst = try std.fmt.allocPrint(a, "{s}/{s}.repodata.zst", .{ dir, sd });
    const f = try fetch(try std.fmt.allocPrint(a, "{s}/{s}/repodata.json.zst", .{ base, sd }), zst, a);
    try w.print("| {s} | repodata.json.zst | HTTP {d}, {d:.1} MiB | ttfb {d} ms, total {d} ms | | |\n", .{ sd, f.status, mib(f.bytes), f.ttfb_ms, f.total_ms });
    if (f.status != 200) return;
    var names = Names.init(a);
    var child = std.process.Child.init(&.{ "zstd", "-d", "-q", "-c", "--long=31", zst }, a);
    child.stdout_behavior = .Pipe;
    try child.spawn();
    var buf: [1 << 20]u8 = undefined;
    while (true) {
        const n = try child.stdout.?.read(&buf);
        if (n == 0) break;
        try names.feed(buf[0..n]);
    }
    _ = try child.wait();
    var it = names.set.keyIterator();
    while (it.next()) |k| try all.put(k.*, {});
    try nameIndex(w, a, dir, sd, &names.set);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len != 2) {
        std.debug.print("usage: conda_measure <work-dir>\n", .{});
        std.process.exit(2);
    }
    try std.fs.cwd().makePath(args[1]);
    const w = std.io.getStdOut().writer();
    try w.print("| subdir | what | size | latency | | |\n|---|---|---|---|---|---|\n", .{});
    var all = std.StringHashMap(void).init(a);
    for (subdirs) |sd| {
        shards(w, a, args[1], sd) catch |e| try w.print("| {s} | shards | error {s} | | | |\n", .{ sd, @errorName(e) });
        repodata(w, a, args[1], sd, &all) catch |e| try w.print("| {s} | repodata | error {s} | | | |\n", .{ sd, @errorName(e) });
    }
    nameIndex(w, a, args[1], "all-subdirs", &all) catch |e| try w.print("| all | name index | error {s} | | | |\n", .{@errorName(e)});
}

test "findShardHash reads the 32 bytes after a msgpack key" {
    const a = std.testing.allocator;
    var idx: [64]u8 = undefined;
    @memset(&idx, 0);
    const rec = [_]u8{ 0xa5, 'n', 'u', 'm', 'p', 'y', 0xc4, 0x20 } ++ [_]u8{0xab} ** 32;
    @memcpy(idx[3 .. 3 + rec.len], &rec);
    const h = (try findShardHash(idx[0 .. 3 + rec.len], "numpy", a)).?;
    try std.testing.expectEqualSlices(u8, &([_]u8{0xab} ** 32), &h);
    try std.testing.expect((try findShardHash(idx[0 .. 3 + rec.len], "scipy", a)) == null);
    // a key with its value cut short is not a hash
    try std.testing.expect((try findShardHash(idx[0 .. 3 + rec.len - 1], "numpy", a)) == null);
}

test "shardsBase reads a fixstr and a str8 value, and refuses a cut one" {
    try std.testing.expectEqualStrings("./shards/", shardsBase("\xafshards_base_url\xa9./shards/").?);
    try std.testing.expectEqualStrings("https://h/s/", shardsBase("\xafshards_base_url\xd9\x0chttps://h/s/").?);
    try std.testing.expect(shardsBase("\xafshards_base_url\xa9./sh") == null);
    try std.testing.expect(shardsBase("nothing here") == null);
}

test "Names finds each name once, across chunk edges, and ignores strings that are not a name key" {
    var n = Names.init(std.testing.allocator);
    defer n.arena.deinit();
    defer n.joined.deinit();
    defer n.set.deinit();
    const doc = "{\"a-1.conda\": {\"name\": \"numpy\", \"depends\": [\"name >=1\"]}, \"b\": {\"name\":\"libzlib\"}, \"c\": {\"name\": \"numpy\"}}";
    var i: usize = 0;
    while (i < doc.len) : (i += 7) try n.feed(doc[i..@min(doc.len, i + 7)]);
    try std.testing.expectEqual(@as(u32, 2), n.set.count());
    try std.testing.expect(n.set.contains("numpy") and n.set.contains("libzlib"));
}
