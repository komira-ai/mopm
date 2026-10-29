//! Tests of the repodata reader (repodata.zig) and of the conditional GET it uses (pkg_fetch.get), against a loopback
//! server that serves fixtures built here: the farm has no network. mopm_core.zig runs them with the rest.

const std = @import("std");
const Allocator = std.mem.Allocator;
const conda = @import("conda.zig");
const pkg_fetch = @import("pkg_fetch.zig");
const repodata = @import("repodata.zig");

// ------------------------------------------------------------------ the loopback server

const Route = struct {
    path: []const u8,
    body: []const u8,
    etag: []const u8 = "",
    status: std.http.Status = .ok,
    /// Every request, the requests that carried If-None-Match, and the answers that carried the body.
    hits: u32 = 0,
    conditional: u32 = 0,
    served: u32 = 0,
};

/// Serves its routes (404 for any other path; 304 for a request whose If-None-Match is the route's etag). It is never
/// shut down: its thread ends with the test process, and it lives in page memory because that thread outlives the test.
const Stub = struct {
    server: std.net.Server,
    mu: std.Thread.Mutex = .{},
    routes: std.ArrayListUnmanaged(Route) = .{},

    fn start() !*Stub {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        const stub = try std.heap.page_allocator.create(Stub);
        stub.* = .{ .server = try addr.listen(.{ .reuse_address = true }) };
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
        var inm: ?[]const u8 = null;
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "if-none-match")) inm = h.value;
        }
        var body: []const u8 = "no";
        var etag: []const u8 = "";
        var status: std.http.Status = .not_found;
        self.mu.lock();
        for (self.routes.items) |*r| {
            if (!std.mem.eql(u8, r.path, req.head.target)) continue;
            r.hits += 1;
            body = r.body;
            etag = r.etag;
            status = r.status;
            if (inm) |v| {
                r.conditional += 1;
                if (r.etag.len > 0 and std.mem.eql(u8, v, r.etag)) {
                    status = .not_modified;
                    body = "";
                }
            }
            if (status == .ok) r.served += 1;
            break;
        }
        self.mu.unlock();
        const headers = [_]std.http.Header{.{ .name = "etag", .value = etag }};
        req.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = if (etag.len > 0) headers[0..1] else headers[0..0] }) catch {};
    }

    /// Serves `route`, replacing what its path served before (its counters go on).
    fn put(self: *Stub, route: Route) !void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.routes.items) |*r| {
            if (std.mem.eql(u8, r.path, route.path)) {
                r.body = route.body;
                r.etag = route.etag;
                r.status = route.status;
                return;
            }
        }
        try self.routes.append(std.heap.page_allocator, route);
    }

    fn counts(self: *Stub, path: []const u8) Route {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.routes.items) |r| {
            if (std.mem.eql(u8, r.path, path)) return r;
        }
        return .{ .path = path, .body = "" };
    }

    fn hits(self: *Stub, path: []const u8) u32 {
        return self.counts(path).hits;
    }
};

// ------------------------------------------------------------------ fixtures

/// A MessagePack writer for exactly the shapes the fixtures use.
const W = struct {
    out: std.ArrayList(u8),

    fn init(a: Allocator) W {
        return .{ .out = std.ArrayList(u8).init(a) };
    }

    fn byte(self: *W, b: u8) !void {
        try self.out.append(b);
    }

    fn be(self: *W, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .big);
        try self.out.appendSlice(&b);
    }

    fn map(self: *W, n: usize) !void {
        if (n < 16) return self.byte(0x80 | @as(u8, @intCast(n)));
        try self.byte(0xde);
        try self.be(u16, @intCast(n));
    }

    fn array(self: *W, n: usize) !void {
        if (n < 16) return self.byte(0x90 | @as(u8, @intCast(n)));
        try self.byte(0xdc);
        try self.be(u16, @intCast(n));
    }

    fn str(self: *W, s: []const u8) !void {
        if (s.len < 32) {
            try self.byte(0xa0 | @as(u8, @intCast(s.len)));
        } else if (s.len < 256) {
            try self.byte(0xd9);
            try self.byte(@intCast(s.len));
        } else {
            try self.byte(0xda);
            try self.be(u16, @intCast(s.len));
        }
        try self.out.appendSlice(s);
    }

    fn bin(self: *W, b: []const u8) !void {
        try self.byte(0xc4);
        try self.byte(@intCast(b.len));
        try self.out.appendSlice(b);
    }

    /// An unsigned integer, always in the widest encoding a small value is not usually written in.
    fn uint(self: *W, v: u64) !void {
        if (v < 128) return self.byte(@intCast(v));
        try self.byte(0xcf);
        try self.be(u64, v);
    }
};

const Rec = struct {
    name: []const u8,
    version: []const u8 = "1.0",
    build: []const u8 = "h0_0",
    depends: []const []const u8 = &.{},
    constrains: []const []const u8 = &.{},
    track: []const u8 = "",
    size: u64 = 100,
    /// The sha256 of the file is this byte, 32 times.
    fill: u8 = 0xab,
    /// A `.conda` file (key `packages.conda`), else a `.tar.bz2` (key `packages`).
    conda: bool = true,
};

const Shard = struct { name: []const u8, recs: []const Rec };

fn fileName(a: Allocator, r: Rec) ![]u8 {
    return std.fmt.allocPrint(a, "{s}-{s}-{s}{s}", .{ r.name, r.version, r.build, if (r.conda) ".conda" else ".tar.bz2" });
}

fn shaHex(fill: u8) [64]u8 {
    return std.fmt.bytesToHex([_]u8{fill} ** 32, .lower);
}

fn writeRec(w: *W, a: Allocator, r: Rec) !void {
    try w.str(try fileName(a, r));
    try w.map(10);
    try w.str("name");
    try w.str(r.name);
    try w.str("version");
    try w.str(r.version);
    try w.str("build");
    try w.str(r.build);
    try w.str("depends");
    try w.array(r.depends.len);
    for (r.depends) |d| try w.str(d);
    try w.str("constrains");
    try w.array(r.constrains.len);
    for (r.constrains) |d| try w.str(d);
    try w.str("track_features");
    try w.str(r.track);
    try w.str("sha256");
    try w.bin(&([_]u8{r.fill} ** 32));
    try w.str("size");
    try w.uint(r.size);
    // Fields the reader must step over.
    try w.str("timestamp");
    try w.uint(1700000000000);
    try w.str("license");
    try w.str("BSD-3-Clause");
}

/// One shard: `packages` for the `.tar.bz2` records, `packages.conda` for the `.conda` ones, and an empty `removed`.
fn shardBytes(a: Allocator, recs: []const Rec) ![]u8 {
    var w = W.init(a);
    try w.map(3);
    for ([_]bool{ false, true }) |want_conda| {
        try w.str(if (want_conda) "packages.conda" else "packages");
        var n: usize = 0;
        for (recs) |r| {
            if (r.conda == want_conda) n += 1;
        }
        try w.map(n);
        for (recs) |r| {
            if (r.conda == want_conda) try writeRec(&w, a, r);
        }
    }
    try w.str("removed");
    try w.array(0);
    return w.out.items;
}

fn sha256Of(bytes: []const u8) [32]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return d;
}

const Env = struct {
    a: Allocator,
    tmp: std.testing.TmpDir,
    stub: *Stub,
    port: u16,
    channel: []const u8,

    fn init(a: Allocator) !Env {
        const stub = try Stub.start();
        const port = stub.server.listen_address.getPort();
        return .{
            .a = a,
            .tmp = std.testing.tmpDir(.{ .iterate = true }),
            .stub = stub,
            .port = port,
            .channel = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/cf", .{port}),
        };
    }

    fn source(self: *Env, offline: bool) repodata.Source {
        return .{ .channel = self.channel, .cache = self.tmp.dir, .offline = offline };
    }

    fn url(self: *Env, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.a, "http://127.0.0.1:{d}{s}", .{ self.port, path });
    }

    fn shardsPath(self: *Env, subdir: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.a, "/cf/{s}/repodata_shards.msgpack.zst", .{subdir});
    }

    fn jsonPath(self: *Env, subdir: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.a, "/cf/{s}/repodata.json.zst", .{subdir});
    }

    /// Serves a shard index naming every shard of `shards` (a shard of a name nobody asks for is served too), and the
    /// shards: at `<subdir>/<hash>.msgpack.zst`, or at `/shards/<hash>.msgpack.zst` when `shards_base` says so. The
    /// shard hashes (lowercase hex), in order.
    fn serveSharded(self: *Env, subdir: []const u8, shards_base: []const u8, shards: []const Shard, etag: []const u8) ![]const []const u8 {
        const a = self.a;
        var w = W.init(a);
        try w.map(3);
        try w.str("info");
        try w.map(3);
        try w.str("base_url");
        try w.str("");
        try w.str("shards_base_url");
        try w.str(shards_base);
        try w.str("subdir");
        try w.str(subdir);
        try w.str("version");
        try w.uint(1);
        try w.str("shards");
        try w.map(shards.len);
        var hexes = std.ArrayList([]const u8).init(a);
        for (shards) |s| {
            const zst = try conda.zstdStore(a, try shardBytes(a, s.recs));
            const digest = sha256Of(zst);
            const hex = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
            try hexes.append(hex);
            try w.str(s.name);
            try w.bin(&digest);
            const path = if (shards_base.len == 0)
                try std.fmt.allocPrint(a, "/cf/{s}/{s}.msgpack.zst", .{ subdir, hex })
            else
                try std.fmt.allocPrint(a, "/shards/{s}.msgpack.zst", .{hex});
            try self.stub.put(.{ .path = path, .body = zst });
        }
        try self.stub.put(.{ .path = try self.shardsPath(subdir), .body = try conda.zstdStore(a, w.out.items), .etag = etag });
        return hexes.items;
    }

    fn shardPath(self: *Env, subdir: []const u8, hex: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.a, "/cf/{s}/{s}.msgpack.zst", .{ subdir, hex });
    }

    fn serveJson(self: *Env, subdir: []const u8, json: []const u8, etag: []const u8) !void {
        try self.stub.put(.{ .path = try self.jsonPath(subdir), .body = try conda.zstdStore(self.a, json), .etag = etag });
    }
};

fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("\n--- expected to find ---\n{s}\n--- in ---\n{s}\n", .{ needle, hay });
        return error.TestExpectedContains;
    }
}

fn expectStrings(want: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

const numpy_recs = [_]Rec{
    .{ .name = "numpy", .version = "1.26.4", .build = "py311_0", .depends = &.{ "python >=3.11,<3.12.0a0", "libblas >=3.9" }, .constrains = &.{"numpy-base <0a0"}, .track = "mkl blas_openblas", .size = 7000, .fill = 0x11, .conda = false },
    .{ .name = "numpy", .version = "2.0.0", .build = "py312_1", .depends = &.{"python >=3.12"}, .size = 8000, .fill = 0x22 },
};
const python_recs = [_]Rec{.{ .name = "python", .version = "3.12.1", .fill = 0x33 }};
const sharded_names = [_]Shard{
    .{ .name = "numpy", .recs = &numpy_recs },
    .{ .name = "python", .recs = &python_recs },
};

fn expectNumpy(env: *Env, idx: *const repodata.Index) !void {
    const got = idx.get("numpy");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    // `packages` is read before `packages.conda`, so the .tar.bz2 record is first.
    const old = got[0];
    try std.testing.expectEqualStrings("numpy", old.name);
    try std.testing.expectEqualStrings("1.26.4", old.version);
    try std.testing.expectEqualStrings("py311_0", old.build);
    try expectStrings(&.{ "python >=3.11,<3.12.0a0", "libblas >=3.9" }, old.depends);
    try expectStrings(&.{"numpy-base <0a0"}, old.constrains);
    try expectStrings(&.{ "mkl", "blas_openblas" }, old.track_features);
    try std.testing.expectEqualStrings(&shaHex(0x11), old.sha256);
    try std.testing.expectEqual(@as(u64, 7000), old.size);
    const want_url = try std.fmt.allocPrint(env.a, "{s}/linux-64/numpy-1.26.4-py311_0.tar.bz2", .{env.channel});
    try std.testing.expectEqualStrings(want_url, old.url);
    const new = got[1];
    try std.testing.expectEqualStrings("2.0.0", new.version);
    try std.testing.expectEqual(@as(usize, 0), new.constrains.len);
    try std.testing.expectEqual(@as(usize, 0), new.track_features.len);
    try std.testing.expectEqualStrings(&shaHex(0x22), new.sha256);
    try std.testing.expectEqual(@as(u64, 8000), new.size);
}

// ------------------------------------------------------------------ sharded

// Defect it catches: fetching every shard of the channel (tens of thousands) instead of the asked names', or
// misreading a field of a record (the binary digest, the track_features string, the file's URL).
test "repodata: a sharded read fetches the index and the shards of the asked names only, and reads every field" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    const hexes = try env.serveSharded("linux-64", "", &sharded_names, "");

    var idx = repodata.Index.init(std.testing.allocator);
    defer idx.deinit();
    var diag = repodata.Diag{};
    try repodata.load(std.testing.allocator, env.source(false), &idx, "linux-64", &.{ "numpy", "scipy" }, &diag);

    try expectNumpy(&env, &idx);
    try std.testing.expectEqual(@as(usize, 0), idx.get("scipy").len);
    try std.testing.expectEqual(@as(usize, 0), idx.get("python").len);
    try std.testing.expectEqual(@as(usize, 2), idx.count());
    try std.testing.expectEqual(@as(u32, 1), env.stub.hits(try env.shardsPath("linux-64")));
    try std.testing.expectEqual(@as(u32, 1), env.stub.hits(try env.shardPath("linux-64", hexes[0])));
    try std.testing.expectEqual(@as(u32, 0), env.stub.hits(try env.shardPath("linux-64", hexes[1])));
    // Nothing was asked of the full file.
    try std.testing.expectEqual(@as(u32, 0), env.stub.hits(try env.jsonPath("linux-64")));
}

// Defect it catches: ignoring shards_base_url, so a channel that keeps its shards elsewhere is read from the subdir.
test "repodata: a shards_base_url is where the shards are fetched from" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    const base = try env.url("/shards/");
    const hexes = try env.serveSharded("linux-64", base, &sharded_names, "");

    var idx = repodata.Index.init(std.testing.allocator);
    defer idx.deinit();
    var diag = repodata.Diag{};
    try repodata.load(std.testing.allocator, env.source(false), &idx, "linux-64", &.{"numpy"}, &diag);
    try expectNumpy(&env, &idx);
    const at = try std.fmt.allocPrint(a, "/shards/{s}.msgpack.zst", .{hexes[0]});
    try std.testing.expectEqual(@as(u32, 1), env.stub.hits(at));
    try std.testing.expectEqual(@as(u32, 0), env.stub.hits(try env.shardPath("linux-64", hexes[0])));
}

// Defect it catches: refetching an immutable shard, or revalidating the index with a plain GET so a 304 is never used.
test "repodata: the shard index is revalidated by ETag (304 reuses the file) and a shard is never fetched twice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    const hexes = try env.serveSharded("linux-64", "", &sharded_names, "\"v1\"");
    const index_path = try env.shardsPath("linux-64");

    for (0..2) |_| {
        var idx = repodata.Index.init(std.testing.allocator);
        defer idx.deinit();
        var diag = repodata.Diag{};
        try repodata.load(std.testing.allocator, env.source(false), &idx, "linux-64", &.{"numpy"}, &diag);
        try expectNumpy(&env, &idx);
    }
    const index_route = env.stub.counts(index_path);
    try std.testing.expectEqual(@as(u32, 2), index_route.hits);
    try std.testing.expectEqual(@as(u32, 1), index_route.conditional);
    try std.testing.expectEqual(@as(u32, 1), index_route.served);
    try std.testing.expectEqual(@as(u32, 1), env.stub.hits(try env.shardPath("linux-64", hexes[0])));
}

// Defect it catches: answering from the cache after the channel moved on (a 304 taken for any answer, or an ETag that
// is stored but not compared), so a lock never sees a new build.
test "repodata: a changed index (new ETag) is downloaded again and its new shard fetched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    _ = try env.serveSharded("linux-64", "", &sharded_names, "\"v1\"");
    {
        var idx = repodata.Index.init(std.testing.allocator);
        defer idx.deinit();
        var diag = repodata.Diag{};
        try repodata.load(std.testing.allocator, env.source(false), &idx, "linux-64", &.{"numpy"}, &diag);
        try std.testing.expectEqual(@as(usize, 2), idx.get("numpy").len);
    }
    const newer = [_]Rec{.{ .name = "numpy", .version = "2.1.0", .build = "py312_0", .fill = 0x44 }};
    const second = [_]Shard{.{ .name = "numpy", .recs = &newer }};
    const hexes = try env.serveSharded("linux-64", "", &second, "\"v2\"");

    var idx = repodata.Index.init(std.testing.allocator);
    defer idx.deinit();
    var diag = repodata.Diag{};
    try repodata.load(std.testing.allocator, env.source(false), &idx, "linux-64", &.{"numpy"}, &diag);
    try std.testing.expectEqual(@as(usize, 1), idx.get("numpy").len);
    try std.testing.expectEqualStrings("2.1.0", idx.get("numpy")[0].version);
    try std.testing.expectEqual(@as(u32, 1), env.stub.hits(try env.shardPath("linux-64", hexes[0])));
    try std.testing.expectEqual(@as(u32, 2), env.stub.counts(try env.shardsPath("linux-64")).served);
}

// Defect it catches: trusting a cached shard by its name alone, so a damaged file in the cache is parsed or kept.
test "repodata: a damaged cached shard is fetched anew online and refused offline, naming the shard" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    const hexes = try env.serveSharded("linux-64", "", &sharded_names, "\"v1\"");
    {
        var idx = repodata.Index.init(std.testing.allocator);
        defer idx.deinit();
        var diag = repodata.Diag{};
        try repodata.load(std.testing.allocator, env.source(false), &idx, "linux-64", &.{"numpy"}, &diag);
    }
    const cached = try std.fmt.allocPrint(a, "{s}.msgpack.zst", .{hexes[0]});
    try env.tmp.dir.writeFile(cached, "not the shard");

    {
        var idx = repodata.Index.init(std.testing.allocator);
        defer idx.deinit();
        var diag = repodata.Diag{};
        try std.testing.expectError(error.Integrity, repodata.load(std.testing.allocator, env.source(true), &idx, "linux-64", &.{"numpy"}, &diag));
        try expectContains(diag.message, hexes[0]);
    }
    var idx = repodata.Index.init(std.testing.allocator);
    defer idx.deinit();
    var diag = repodata.Diag{};
    try repodata.load(std.testing.allocator, env.source(false), &idx, "linux-64", &.{"numpy"}, &diag);
    try expectNumpy(&env, &idx);
    try std.testing.expectEqual(@as(u32, 2), env.stub.hits(try env.shardPath("linux-64", hexes[0])));
}

// ------------------------------------------------------------------ the fallback

fn jsonRecord(a: Allocator, name: []const u8, version: []const u8, build: []const u8, extra: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\{{"build": "{s}", "build_number": 0, "depends": ["python"], "license": "MIT", "md5": "00", "name": "{s}", "noarch": "python", "sha256": "{s}", "size": 10, "subdir": "linux-64", "timestamp": 1700000000000, "version": "{s}"{s}}}
    , .{ build, name, "ab" ** 32, version, extra });
}

/// A repodata.json of `numpy` (one .tar.bz2 and one .conda record), `zlib`, and `filler` records of other names, with
/// a very long depends list in numpy's first record so that records span the reader's buffer.
fn repodataJson(a: Allocator, filler: usize) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    var deps = std.ArrayList(u8).init(a);
    for (0..600) |i| try deps.writer().print("{s}\"dep{d} >=1\"", .{ if (i == 0) "" else ", ", i });
    const numpy1 = try std.fmt.allocPrint(a,
        \\{{"build": "0", "depends": [{s}], "name": "numpy", "sha256": "{s}", "size": 1234, "version": "1.0", "track_features": "feat_a feat_b"}}
    , .{ deps.items, "cd" ** 32 });
    try w.print("{{\"info\": {{\"subdir\": \"linux-64\"}}, \"packages\": {{\"numpy-1.0-0.tar.bz2\": {s}", .{numpy1});
    try w.print(", \"zlib-1.3-0.tar.bz2\": {s}", .{try jsonRecord(a, "zlib", "1.3", "0", "")});
    for (0..filler) |i| {
        try w.print(", \"filler{d}-1.0-0.tar.bz2\": {s}", .{ i, try jsonRecord(a, try std.fmt.allocPrint(a, "filler{d}", .{i}), "1.0", "0", "") });
    }
    try w.print("}}, \"packages.conda\": {{\"numpy-2.0-h1_0.conda\": {s}}}, \"removed\": [], \"repodata_version\": 2}}", .{try jsonRecord(a, "numpy", "2.0", "h1_0", ", \"constrains\": [\"blas <0a0\"]")});
    return out.items;
}

// Defect it catches: a channel without shards being unreadable, a record of an unasked name leaking into the index,
// or a record cut by a read-buffer edge being lost or misread.
test "repodata: a channel without a shard index is read from repodata.json.zst, keeping the asked names only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    // The channel answers 404 for the shard index (a route that answers 404 is what lets the test count the asking).
    try env.stub.put(.{ .path = try env.shardsPath("linux-64"), .body = "not found", .status = .not_found });
    try env.serveJson("linux-64", try repodataJson(a, 300), "\"j1\"");

    var idx = repodata.Index.init(std.testing.allocator);
    defer idx.deinit();
    var diag = repodata.Diag{};
    try repodata.load(std.testing.allocator, env.source(false), &idx, "linux-64", &.{"numpy"}, &diag);

    const got = idx.get("numpy");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqual(@as(usize, 2), idx.count());
    try std.testing.expectEqualStrings("1.0", got[0].version);
    try std.testing.expectEqual(@as(usize, 600), got[0].depends.len);
    try std.testing.expectEqualStrings("dep0 >=1", got[0].depends[0]);
    try std.testing.expectEqualStrings("dep599 >=1", got[0].depends[599]);
    try expectStrings(&.{ "feat_a", "feat_b" }, got[0].track_features);
    try std.testing.expectEqualStrings(&shaHex(0xcd), got[0].sha256);
    try std.testing.expectEqual(@as(u64, 1234), got[0].size);
    const want_url = try std.fmt.allocPrint(a, "{s}/linux-64/numpy-1.0-0.tar.bz2", .{env.channel});
    try std.testing.expectEqualStrings(want_url, got[0].url);
    try std.testing.expectEqualStrings("2.0", got[1].version);
    try std.testing.expectEqualStrings("h1_0", got[1].build);
    try expectStrings(&.{"blas <0a0"}, got[1].constrains);
    try expectStrings(&.{"python"}, got[1].depends);
    try std.testing.expectEqual(@as(usize, 0), idx.get("zlib").len);
    try std.testing.expectEqual(@as(usize, 0), idx.get("filler7").len);
    // The index was asked for first, and was not there.
    try std.testing.expectEqual(@as(u32, 1), env.stub.hits(try env.shardsPath("linux-64")));
    try std.testing.expectEqual(@as(u32, 1), env.stub.hits(try env.jsonPath("linux-64")));
}

// Defect it catches: downloading the 26 to 59 MB file on every lock, or taking a 304 for a failure.
test "repodata: repodata.json.zst is revalidated by ETag and downloaded once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    try env.serveJson("linux-64", try repodataJson(a, 3), "\"j1\"");
    for (0..2) |_| {
        var idx = repodata.Index.init(std.testing.allocator);
        defer idx.deinit();
        var diag = repodata.Diag{};
        try repodata.load(std.testing.allocator, env.source(false), &idx, "linux-64", &.{"numpy"}, &diag);
        try std.testing.expectEqual(@as(usize, 2), idx.get("numpy").len);
    }
    const route = env.stub.counts(try env.jsonPath("linux-64"));
    try std.testing.expectEqual(@as(u32, 2), route.hits);
    try std.testing.expectEqual(@as(u32, 1), route.conditional);
    try std.testing.expectEqual(@as(u32, 1), route.served);
}

// Defect it catches: any failure of the index treated as "not served", so a channel outage silently reads a stale or
// different file instead of failing.
test "repodata: a server error on the shard index is a fetch error, not a fallback" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    try env.stub.put(.{ .path = try env.shardsPath("linux-64"), .body = "oops", .status = .internal_server_error });
    try env.serveJson("linux-64", try repodataJson(a, 1), "");

    var idx = repodata.Index.init(std.testing.allocator);
    defer idx.deinit();
    var diag = repodata.Diag{};
    try std.testing.expectError(error.FetchFailed, repodata.load(std.testing.allocator, env.source(false), &idx, "linux-64", &.{"numpy"}, &diag));
    try expectContains(diag.message, "repodata_shards.msgpack.zst");
    try expectContains(diag.message, "500");
    try std.testing.expectEqual(@as(u32, 0), env.stub.hits(try env.jsonPath("linux-64")));
}

test "repodata: a channel that serves neither file is a fetch error naming both" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    var idx = repodata.Index.init(std.testing.allocator);
    defer idx.deinit();
    var diag = repodata.Diag{};
    try std.testing.expectError(error.FetchFailed, repodata.load(std.testing.allocator, env.source(false), &idx, "osx-arm64", &.{"numpy"}, &diag));
    try expectContains(diag.message, "/cf/osx-arm64/repodata_shards.msgpack.zst");
    try expectContains(diag.message, "/cf/osx-arm64/repodata.json.zst");
}

// ------------------------------------------------------------------ offline

// Defect it catches: offline mode that still opens a connection, or a warm cache that cannot answer by itself.
test "repodata: offline reads the cache alone, for the sharded path and for the fallback" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    const hexes = try env.serveSharded("linux-64", "", &sharded_names, "\"v1\"");
    try env.serveJson("noarch", try repodataJson(a, 2), "\"j1\"");
    for ([_][]const u8{ "linux-64", "noarch" }) |subdir| {
        var idx = repodata.Index.init(std.testing.allocator);
        defer idx.deinit();
        var diag = repodata.Diag{};
        try repodata.load(std.testing.allocator, env.source(false), &idx, subdir, &.{"numpy"}, &diag);
    }
    const before = [_]u32{
        env.stub.hits(try env.shardsPath("linux-64")),
        env.stub.hits(try env.shardPath("linux-64", hexes[0])),
        env.stub.hits(try env.shardsPath("noarch")),
        env.stub.hits(try env.jsonPath("noarch")),
    };

    var idx = repodata.Index.init(std.testing.allocator);
    defer idx.deinit();
    var diag = repodata.Diag{};
    try repodata.load(std.testing.allocator, env.source(true), &idx, "linux-64", &.{"numpy"}, &diag);
    try expectNumpy(&env, &idx);
    var idx2 = repodata.Index.init(std.testing.allocator);
    defer idx2.deinit();
    try repodata.load(std.testing.allocator, env.source(true), &idx2, "noarch", &.{"numpy"}, &diag);
    try std.testing.expectEqual(@as(usize, 2), idx2.get("numpy").len);

    const after = [_]u32{
        env.stub.hits(try env.shardsPath("linux-64")),
        env.stub.hits(try env.shardPath("linux-64", hexes[0])),
        env.stub.hits(try env.shardsPath("noarch")),
        env.stub.hits(try env.jsonPath("noarch")),
    };
    try std.testing.expectEqualSlices(u32, &before, &after);
}

// Defect it catches: an offline miss that is an empty result (a lock that silently has no packages) or an error that
// does not say what to fetch.
test "repodata: offline with nothing cached is NotCached, naming the index and the full file; a missing shard is named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    const hexes = try env.serveSharded("linux-64", "", &sharded_names, "\"v1\"");

    {
        var idx = repodata.Index.init(std.testing.allocator);
        defer idx.deinit();
        var diag = repodata.Diag{};
        try std.testing.expectError(error.NotCached, repodata.load(std.testing.allocator, env.source(true), &idx, "linux-64", &.{"numpy"}, &diag));
        try expectContains(diag.message, try env.url("/cf/linux-64/repodata_shards.msgpack.zst"));
        try expectContains(diag.message, try env.url("/cf/linux-64/repodata.json.zst"));
    }
    // Warm the cache with the shard of python only; numpy's is then the missing piece.
    {
        var idx = repodata.Index.init(std.testing.allocator);
        defer idx.deinit();
        var diag = repodata.Diag{};
        try repodata.load(std.testing.allocator, env.source(false), &idx, "linux-64", &.{"python"}, &diag);
        try std.testing.expectEqual(@as(usize, 1), idx.get("python").len);
    }
    var idx = repodata.Index.init(std.testing.allocator);
    defer idx.deinit();
    var diag = repodata.Diag{};
    try std.testing.expectError(error.NotCached, repodata.load(std.testing.allocator, env.source(true), &idx, "linux-64", &.{"numpy"}, &diag));
    try expectContains(diag.message, try env.url(try env.shardPath("linux-64", hexes[0])));
    try std.testing.expectEqual(@as(u32, 0), env.stub.hits(try env.shardPath("linux-64", hexes[0])));
}

test "repodata: a cached index that no longer matches its record is refused offline and fetched anew online" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    _ = try env.serveSharded("linux-64", "", &sharded_names, "\"v1\"");
    {
        var idx = repodata.Index.init(std.testing.allocator);
        defer idx.deinit();
        var diag = repodata.Diag{};
        try repodata.load(std.testing.allocator, env.source(false), &idx, "linux-64", &.{"numpy"}, &diag);
    }
    // Damage every cached index or full file (the `.body` files); the shards (`.msgpack.zst`) stay.
    var it = env.tmp.dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".body")) try env.tmp.dir.writeFile(entry.name, "damaged");
    }
    {
        var idx = repodata.Index.init(std.testing.allocator);
        defer idx.deinit();
        var diag = repodata.Diag{};
        try std.testing.expectError(error.Integrity, repodata.load(std.testing.allocator, env.source(true), &idx, "linux-64", &.{"numpy"}, &diag));
        try expectContains(diag.message, "repodata_shards.msgpack.zst");
    }
    var idx = repodata.Index.init(std.testing.allocator);
    defer idx.deinit();
    var diag = repodata.Diag{};
    try repodata.load(std.testing.allocator, env.source(false), &idx, "linux-64", &.{"numpy"}, &diag);
    try expectNumpy(&env, &idx);
    // The damaged copy was not offered to the server as current: the answer was a full one.
    try std.testing.expectEqual(@as(u32, 2), env.stub.counts(try env.shardsPath("linux-64")).served);
}

// ------------------------------------------------------------------ integrity

fn expectDamagedShard(env: *Env, hex: []const u8, names: []const []const u8) !void {
    var idx = repodata.Index.init(std.testing.allocator);
    defer idx.deinit();
    var diag = repodata.Diag{};
    try std.testing.expectError(error.Integrity, repodata.load(std.testing.allocator, env.source(false), &idx, "linux-64", names, &diag));
    try expectContains(diag.message, try env.url(try env.shardPath("linux-64", hex)));
    try std.testing.expectEqual(@as(usize, 0), idx.count());
}

/// Serves an index that names `name` with the hash of `zst`, and `zst` as that shard. The hash, in hex.
fn serveRawShard(env: *Env, name: []const u8, zst: []const u8, served_as: []const u8) ![]const u8 {
    const a = env.a;
    var w = W.init(a);
    try w.map(2);
    try w.str("info");
    try w.map(1);
    try w.str("shards_base_url");
    try w.str("");
    try w.str("shards");
    try w.map(1);
    try w.str(name);
    const digest = sha256Of(zst);
    try w.bin(&digest);
    const hex = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
    try env.stub.put(.{ .path = try env.shardsPath("linux-64"), .body = try conda.zstdStore(a, w.out.items) });
    try env.stub.put(.{ .path = try env.shardPath("linux-64", hex), .body = served_as });
    return hex;
}

// Defect it catches: a shard whose bytes are not the hash the index named being parsed (a tampered or truncated
// download), or kept in the cache where the next run would trust it.
test "repodata: a shard that is not the bytes of its hash is an integrity error naming its URL, and is not kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    const good = try conda.zstdStore(a, try shardBytes(a, &numpy_recs));
    var bent = try a.dupe(u8, good);
    bent[bent.len - 1] ^= 0xff;
    const hex = try serveRawShard(&env, "numpy", good, bent);
    try expectDamagedShard(&env, hex, &.{"numpy"});
    const kept = try std.fmt.allocPrint(a, "{s}.msgpack.zst", .{hex});
    try std.testing.expectError(error.FileNotFound, env.tmp.dir.access(kept, .{}));
}

// Defect it catches: bytes that hash right but do not decode (a bad producer) reaching the solver as an empty set.
test "repodata: a shard that hashes right but is not a zstd stream of msgpack is an integrity error naming its URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    const garbage = "this is not zstd at all";
    const hex = try serveRawShard(&env, "numpy", garbage, garbage);
    try expectDamagedShard(&env, hex, &.{"numpy"});

    // Valid zstd of bytes that are not a shard: a map of one pair whose value is cut.
    const cut = try conda.zstdStore(a, &.{ 0x81, 0xa8, 'p', 'a', 'c', 'k', 'a', 'g', 'e', 's', 0x81 });
    const hex2 = try serveRawShard(&env, "numpy", cut, cut);
    try expectDamagedShard(&env, hex2, &.{"numpy"});
}

// Defect it catches: a shard filed under one name holding another name's records, which would put a wrong package
// into the closure of the asked one.
test "repodata: a shard holding a record of another name is an integrity error naming its URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    const zst = try conda.zstdStore(a, try shardBytes(a, &python_recs));
    const hex = try serveRawShard(&env, "numpy", zst, zst);
    try expectDamagedShard(&env, hex, &.{"numpy"});
}

// Defect it catches: an unbounded field of an untrusted record (memory spent on a length a producer chose), or a file
// name that reaches a URL with a path separator in it.
test "repodata: a field over the limit and a file name with a separator are integrity errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    const long_version = try a.alloc(u8, repodata.max_field + 1);
    @memset(long_version, '1');
    const too_long = [_]Rec{.{ .name = "numpy", .version = long_version }};
    const zst = try conda.zstdStore(a, try shardBytes(a, &too_long));
    const hex = try serveRawShard(&env, "numpy", zst, zst);
    try expectDamagedShard(&env, hex, &.{"numpy"});

    const slash = [_]Rec{.{ .name = "numpy", .build = "../evil" }};
    const zst2 = try conda.zstdStore(a, try shardBytes(a, &slash));
    const hex2 = try serveRawShard(&env, "numpy", zst2, zst2);
    try expectDamagedShard(&env, hex2, &.{"numpy"});
}

// Defect it catches: a truncated download of the full file parsed as far as it goes, so a lock sees some builds only.
test "repodata: a cut repodata.json.zst is an integrity error naming its URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    const whole = try repodataJson(a, 5);
    try env.serveJson("linux-64", whole[0 .. whole.len - 40], "");

    var idx = repodata.Index.init(std.testing.allocator);
    defer idx.deinit();
    var diag = repodata.Diag{};
    try std.testing.expectError(error.Integrity, repodata.load(std.testing.allocator, env.source(false), &idx, "linux-64", &.{"numpy"}, &diag));
    try expectContains(diag.message, try env.url("/cf/linux-64/repodata.json.zst"));
}

test "repodata: a subdir that is not a name is refused before any request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    var idx = repodata.Index.init(std.testing.allocator);
    defer idx.deinit();
    var diag = repodata.Diag{};
    for ([_][]const u8{ "", "../x", "linux/64", "Linux-64" }) |bad| {
        try std.testing.expectError(error.BadArgument, repodata.load(std.testing.allocator, env.source(false), &idx, bad, &.{"numpy"}, &diag));
    }
}

// ------------------------------------------------------------------ pkg_fetch.get

// Defect it catches: a conditional GET that rewrites the file on 304, a body kept past its limit or against its
// expected hash, or an ETag that is not handed back.
test "pkg_fetch.get: 200 keeps the file and returns its ETag, size and sha256; 304 and other statuses touch nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    try env.stub.put(.{ .path = "/f", .body = "hello world", .etag = "\"e1\"" });
    var diag = pkg_fetch.Diag{};
    const url = try env.url("/f");

    const first = try pkg_fetch.get(a, env.tmp.dir, "f.bin", url, .{ .max_size = 100 }, &diag);
    try std.testing.expectEqual(@as(u16, 200), first.status);
    try std.testing.expectEqualStrings("\"e1\"", first.etag);
    try std.testing.expectEqual(@as(u64, 11), first.size);
    const want = std.fmt.bytesToHex(sha256Of("hello world"), .lower);
    try std.testing.expectEqualStrings(&want, &first.sha256);
    try std.testing.expectEqualStrings("hello world", try env.tmp.dir.readFileAlloc(a, "f.bin", 100));

    const again = try pkg_fetch.get(a, env.tmp.dir, "f.bin", url, .{ .max_size = 100, .if_none_match = "\"e1\"" }, &diag);
    try std.testing.expectEqual(@as(u16, 304), again.status);
    try std.testing.expectEqual(@as(u32, 1), env.stub.counts("/f").served);
    // An ETag that is not current gets the body again.
    const stale = try pkg_fetch.get(a, env.tmp.dir, "f.bin", url, .{ .max_size = 100, .if_none_match = "\"old\"" }, &diag);
    try std.testing.expectEqual(@as(u16, 200), stale.status);

    const missing = try pkg_fetch.get(a, env.tmp.dir, "g.bin", try env.url("/nothing"), .{ .max_size = 100 }, &diag);
    try std.testing.expectEqual(@as(u16, 404), missing.status);
    try std.testing.expectError(error.FileNotFound, env.tmp.dir.access("g.bin", .{}));
}

test "pkg_fetch.get: a body over the limit or not of the expected sha256 is refused, named, and leaves nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = try Env.init(a);
    defer env.tmp.cleanup();
    try env.stub.put(.{ .path = "/f", .body = "hello world" });
    const url = try env.url("/f");
    var diag = pkg_fetch.Diag{};

    try std.testing.expectError(error.SizeMismatch, pkg_fetch.get(a, env.tmp.dir, "f.bin", url, .{ .max_size = 10 }, &diag));
    try expectContains(diag.message, url);
    try std.testing.expectError(error.HashMismatch, pkg_fetch.get(a, env.tmp.dir, "f.bin", url, .{ .max_size = 100, .want_sha256 = &([_]u8{'0'} ** 64) }, &diag));
    try expectContains(diag.message, url);
    try std.testing.expectError(error.FileNotFound, env.tmp.dir.access("f.bin", .{}));
    var it = env.tmp.dir.iterate();
    try std.testing.expect((try it.next()) == null);

    const ok_hash = std.fmt.bytesToHex(sha256Of("hello world"), .lower);
    const got = try pkg_fetch.get(a, env.tmp.dir, "f.bin", url, .{ .max_size = 100, .want_sha256 = &ok_hash }, &diag);
    try std.testing.expectEqual(@as(u16, 200), got.status);
}
