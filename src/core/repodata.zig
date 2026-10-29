//! conda-forge repodata for the names a lock asks about: the records of those names and nothing else.
//! (docs/design/any-conda-forge-native.md, sections 2 and 8, PR 3; the solver that reads the index is the next PR.)
//!
//! `load` reads one subdir of a channel. It prefers sharded repodata (CEP 16): the shard index
//! `<subdir>/repodata_shards.msgpack.zst` names, for every package name, the sha256 of that name's shard, and only
//! the shards of the asked names are fetched, each at `<subdir>/<sha256>.msgpack.zst` (or below `shards_base_url`
//! when the index sets one). A channel that does not serve the index (HTTP 404) is read from
//! `<subdir>/repodata.json.zst` instead, streamed through the decompressor and the JSON reader, so only the records of
//! the asked names are ever held. Any other failure to get the index is an error, never a silent fallback.
//!
//! The cache is a directory the caller opens (`openDefaultCache`: `$XDG_CACHE_HOME/mopm/repodata`, else
//! `$HOME/.cache/mopm/repodata`). A shard is stored under its own hash and is immutable: it is used without any
//! request, after its bytes are hashed again, and a damaged one is fetched anew (offline: an error). The shard index
//! and the full repodata file change under one URL, so each is stored under the hash of its URL with its `ETag`, its
//! sha256 and its size, and every online `load` asks the server whether it changed (`If-None-Match`; 304 reuses the
//! file). `Source.offline` reads the cache only and names what it lacks.
//!
//! Everything read is untrusted: every decompression is capped, every field has a length limit, a shard must hold
//! records of its own name only, and anything wrong with the bytes of a URL is `error.Integrity` with the URL in
//! `diag.message`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack.zig");
const pkg_fetch = @import("pkg_fetch.zig");

pub const Diag = struct { message: []const u8 = "" };

pub const Error = error{
    /// Offline, and the cache lacks something the read needs; `diag` names it.
    NotCached,
    /// The bytes of a URL (fetched now or cached) are not what they must be: a hash that does not match, a stream that
    /// does not decode, a field out of limits, a shard of another name. `diag` names the URL.
    Integrity,
    /// A request failed, or the server answered a status that is neither the file nor "not served".
    FetchFailed,
    /// A subdir that is not a subdir name.
    BadArgument,
};

/// The largest a compressed shard index, a compressed shard and a compressed `repodata.json.zst` may be, and the
/// largest the first two may decompress to. The repodata.json stream is capped by `max_json_raw` as it is read.
pub const max_index_zst: u64 = 16 << 20;
pub const max_index_raw: usize = 64 << 20;
pub const max_shard_zst: u64 = 64 << 20;
pub const max_shard_raw: usize = 64 << 20;
pub const max_json_zst: u64 = 1 << 30;
pub const max_json_raw: u64 = 8 << 30;
/// The longest a string of a record may be, and the most entries a list of a record may have.
pub const max_field: usize = 8192;
pub const max_list: u32 = 8192;
/// The zstd window buffer, the same size conda packages are read with.
const window_size: usize = 64 << 20;

pub const Record = struct {
    name: []const u8,
    version: []const u8,
    build: []const u8,
    /// Match specs, as written.
    depends: []const []const u8,
    constrains: []const []const u8,
    track_features: []const []const u8,
    /// The package file's URL.
    url: []const u8,
    /// Lowercase hex, or "" when the record has none.
    sha256: []const u8,
    size: u64,
};

/// The records read so far, by package name. Every string lives in the index's own arena until `deinit`.
pub const Index = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Record)) = .{},
    urls: std.StringHashMapUnmanaged(void) = .{},

    pub fn init(backing: Allocator) Index {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *Index) void {
        self.arena.deinit();
    }

    /// The records of `name` (all subdirs and builds loaded), in the order read; none when there are none.
    pub fn get(self: *const Index, name: []const u8) []const Record {
        const list = self.map.get(name) orelse return &.{};
        return list.items;
    }

    pub fn count(self: *const Index) usize {
        return self.urls.count();
    }

    /// Adds `r`, whose strings must live in this index's arena. A file already added (same URL) is not added twice.
    fn add(self: *Index, r: Record) !void {
        const a = self.arena.allocator();
        const seen = try self.urls.getOrPut(a, r.url);
        if (seen.found_existing) return;
        const slot = try self.map.getOrPut(a, r.name);
        if (!slot.found_existing) slot.value_ptr.* = .{};
        try slot.value_ptr.append(a, r);
    }
};

pub const Source = struct {
    /// The channel URL, for example `https://conda.anaconda.org/conda-forge`.
    channel: []const u8,
    /// The cache directory (see `openDefaultCache`).
    cache: std.fs.Dir,
    /// Read the cache only; never open a connection.
    offline: bool = false,
};

/// mopm's repodata cache: `$XDG_CACHE_HOME/mopm/repodata` when that variable is set and not empty, else
/// `$HOME/.cache/mopm/repodata`; made if it is not there.
pub fn openDefaultCache(arena: Allocator) !std.fs.Dir {
    const base = if (std.process.getEnvVarOwned(arena, "XDG_CACHE_HOME")) |x|
        if (x.len > 0) x else try homeCache(arena)
    else |_|
        try homeCache(arena);
    const path = try std.fs.path.join(arena, &.{ base, "mopm", "repodata" });
    return std.fs.cwd().makeOpenPath(path, .{});
}

fn homeCache(arena: Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(arena, "HOME");
    return std.fs.path.join(arena, &.{ home, ".cache" });
}

/// Reads the records of `names` in `subdir` of the channel into `index`. A name the channel does not have adds nothing
/// (`index.get` is then empty; whether that is an error is the caller's). `diag.message` is set on every error.
pub fn load(gpa: Allocator, src: Source, index: *Index, subdir: []const u8, names: []const []const u8, diag: *Diag) !void {
    const ia = index.arena.allocator();
    if (!validSubdir(subdir)) {
        diag.message = try std.fmt.allocPrint(ia, "{s} is not a subdir name", .{subdir});
        return error.BadArgument;
    }
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const sa = scratch_state.allocator();
    var window = Window{ .gpa = gpa };
    defer window.deinit();

    var wanted = std.StringHashMap(void).init(sa);
    for (names) |n| try wanted.put(n, {});

    const base = try std.fmt.allocPrint(sa, "{s}/{s}/", .{ std.mem.trimRight(u8, src.channel, "/"), subdir });
    const shards_url = try std.mem.concat(sa, u8, &.{ base, "repodata_shards.msgpack.zst" });
    const json_url = try std.mem.concat(sa, u8, &.{ base, "repodata.json.zst" });

    var shard_diag = Diag{};
    const shard_index: ?[]const u8 = fetchEntry(sa, src, shards_url, max_index_zst, &shard_diag) catch |e| switch (e) {
        // Offline and not cached: the full file may be.
        error.NotCached => null,
        else => {
            diag.message = try ia.dupe(u8, shard_diag.message);
            return e;
        },
    };
    if (shard_index) |file| {
        return loadSharded(sa, ia, src, index, &window, base, file, shards_url, &wanted, diag);
    }

    var json_diag = Diag{};
    const json_file = fetchEntry(sa, src, json_url, max_json_zst, &json_diag) catch |e| {
        diag.message = if (e == error.NotCached)
            try std.fmt.allocPrint(ia, "offline: nothing of {s} is cached; missing {s} and {s}", .{ subdir, shards_url, json_url })
        else
            try ia.dupe(u8, json_diag.message);
        return e;
    };
    if (json_file) |file| {
        return loadJson(gpa, sa, ia, src, index, &window, base, file, json_url, &wanted, diag);
    }
    diag.message = try std.fmt.allocPrint(ia, "neither {s} nor {s} is served", .{ shards_url, json_url });
    return error.FetchFailed;
}

fn validSubdir(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

// ------------------------------------------------------------------ the cache

/// One cached URL: the file named `<key>.body` and its description in `<key>.meta` (three lines: ETag, sha256, size).
const Meta = struct { etag: []const u8, sha256: []const u8, size: u64 };

fn entryKey(sa: Allocator, url: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &d, .{});
    const hex = std.fmt.bytesToHex(d[0..16].*, .lower);
    return sa.dupe(u8, &hex);
}

fn readMeta(sa: Allocator, cache: std.fs.Dir, name: []const u8) ?Meta {
    const text = cache.readFileAlloc(sa, name, 64 * 1024) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    const etag = lines.next() orelse return null;
    const sha = lines.next() orelse return null;
    const size_text = lines.next() orelse return null;
    if (sha.len != 64) return null;
    const size = std.fmt.parseInt(u64, size_text, 10) catch return null;
    return .{ .etag = etag, .sha256 = sha, .size = size };
}

fn writeFileAtomic(sa: Allocator, dir: std.fs.Dir, name: []const u8, bytes: []const u8) !void {
    var r: [6]u8 = undefined;
    std.crypto.random.bytes(&r);
    const tmp = try std.fmt.allocPrint(sa, "{s}.part-{s}", .{ name, std.fmt.bytesToHex(r, .lower) });
    errdefer dir.deleteFile(tmp) catch {};
    try dir.writeFile(tmp, bytes);
    try dir.rename(tmp, name);
}

/// The name, in the cache, of the file at `url`: the cached copy when the server says it is current (304) or the
/// network is off, else the newly downloaded one. Null when the server does not serve the URL (404). Offline with
/// nothing cached is `NotCached`; a cached copy that no longer has its recorded size and sha256 is `Integrity`
/// offline and is downloaded anew online.
fn fetchEntry(sa: Allocator, src: Source, url: []const u8, max_size: u64, diag: *Diag) !?[]const u8 {
    const key = try entryKey(sa, url);
    const body = try std.fmt.allocPrint(sa, "{s}.body", .{key});
    const meta_name = try std.fmt.allocPrint(sa, "{s}.meta", .{key});
    const meta = readMeta(sa, src.cache, meta_name);
    const valid = if (meta) |m| try pkg_fetch.matches(src.cache, body, .{ .sha256 = m.sha256, .size = m.size }) else false;

    if (src.offline) {
        if (valid) return body;
        if (meta == null) {
            diag.message = try std.fmt.allocPrint(sa, "offline: {s} is not in the cache", .{url});
            return error.NotCached;
        }
        diag.message = try std.fmt.allocPrint(sa, "offline: the cached copy of {s} is missing or does not match its recorded sha256 (delete {s} to forget it)", .{ url, meta_name });
        return error.Integrity;
    }

    var pd = pkg_fetch.Diag{};
    const inm: ?[]const u8 = if (valid and meta.?.etag.len > 0) meta.?.etag else null;
    const got = pkg_fetch.get(sa, src.cache, body, url, .{ .if_none_match = inm, .max_size = max_size }, &pd) catch |e| {
        diag.message = pd.message;
        return switch (e) {
            error.SizeMismatch, error.HashMismatch => error.Integrity,
            error.DownloadFailed => error.FetchFailed,
            else => e,
        };
    };
    if (got.status == 304) {
        if (inm != null) return body;
        diag.message = try std.fmt.allocPrint(sa, "{s} answered 304 to a request that was not conditional", .{url});
        return error.FetchFailed;
    }
    if (got.status == 404) return null;
    if (got.status < 200 or got.status >= 300) {
        diag.message = try std.fmt.allocPrint(sa, "{s} answered HTTP {d}", .{ url, got.status });
        return error.FetchFailed;
    }
    const text = try std.fmt.allocPrint(sa, "{s}\n{s}\n{d}\n", .{ got.etag, got.sha256, got.size });
    try writeFileAtomic(sa, src.cache, meta_name, text);
    return body;
}

/// The bytes of the shard `hex` (the sha256 of its compressed file) at `url`. The cache holds it as
/// `<hex>.msgpack.zst`; a copy there is used only if it hashes to `hex`.
fn shardFile(sa: Allocator, src: Source, hex: []const u8, url: []const u8, diag: *Diag) ![]u8 {
    const name = try std.fmt.allocPrint(sa, "{s}.msgpack.zst", .{hex});
    const cached: ?[]u8 = src.cache.readFileAlloc(sa, name, max_shard_zst) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    if (cached) |bytes| {
        const h = hashHex(bytes);
        if (std.mem.eql(u8, &h, hex)) return bytes;
        if (src.offline) {
            diag.message = try std.fmt.allocPrint(sa, "offline: the cached shard {s} (of {s}) does not match its hash", .{ name, url });
            return error.Integrity;
        }
    } else if (src.offline) {
        diag.message = try std.fmt.allocPrint(sa, "offline: the shard {s} is not in the cache", .{url});
        return error.NotCached;
    }

    var pd = pkg_fetch.Diag{};
    const got = pkg_fetch.get(sa, src.cache, name, url, .{ .want_sha256 = hex, .max_size = max_shard_zst }, &pd) catch |e| {
        diag.message = pd.message;
        return switch (e) {
            error.SizeMismatch, error.HashMismatch => error.Integrity,
            error.DownloadFailed => error.FetchFailed,
            else => e,
        };
    };
    if (got.status < 200 or got.status >= 300) {
        diag.message = try std.fmt.allocPrint(sa, "{s} answered HTTP {d}", .{ url, got.status });
        return error.FetchFailed;
    }
    return src.cache.readFileAlloc(sa, name, max_shard_zst);
}

fn hashHex(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

// ------------------------------------------------------------------ decoding

/// The zstd window buffer, allocated the first time a stream is decoded.
const Window = struct {
    gpa: Allocator,
    buf: ?[]u8 = null,

    fn get(self: *Window) ![]u8 {
        if (self.buf == null) self.buf = try self.gpa.alloc(u8, window_size);
        return self.buf.?;
    }

    fn deinit(self: *Window) void {
        if (self.buf) |b| self.gpa.free(b);
    }
};

/// What a decode failure is told as: the URL and what failed. Memory errors pass through.
fn damaged(ia: Allocator, diag: *Diag, url: []const u8, what: []const u8, e: anyerror) anyerror {
    if (e == error.OutOfMemory) return e;
    diag.message = std.fmt.allocPrint(ia, "{s} {s}: {s}", .{ url, what, @errorName(e) }) catch return error.OutOfMemory;
    return error.Integrity;
}

fn decompress(sa: Allocator, window: *Window, compressed: []const u8, max_raw: usize) ![]u8 {
    var fbs = std.io.fixedBufferStream(compressed);
    var zs = std.compress.zstd.decompressor(fbs.reader(), .{ .window_buffer = try window.get() });
    return zs.reader().readAllAlloc(sa, max_raw);
}

fn limited(s: []const u8) ![]const u8 {
    if (s.len > max_field) return error.FieldTooLong;
    return s;
}

const Found = struct { name: []const u8, hex: []u8 };

const ShardIndex = struct {
    shards_base_url: []const u8 = "",
    base_url: []const u8 = "",
    found: std.ArrayListUnmanaged(Found) = .{},
};

fn optStr(r: *msgpack.Reader) ![]const u8 {
    if ((try r.peek()) == .nil) {
        try r.skip();
        return "";
    }
    return limited(try r.str());
}

fn parseShardIndex(sa: Allocator, bytes: []const u8, wanted: *const std.StringHashMap(void)) !ShardIndex {
    var out = ShardIndex{};
    var r = msgpack.Reader.init(bytes);
    const n = try r.mapLen();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const key = try r.str();
        if (std.mem.eql(u8, key, "info")) {
            const m = try r.mapLen();
            var j: u32 = 0;
            while (j < m) : (j += 1) {
                const k = try r.str();
                if (std.mem.eql(u8, k, "shards_base_url")) {
                    out.shards_base_url = try sa.dupe(u8, try optStr(&r));
                } else if (std.mem.eql(u8, k, "base_url")) {
                    out.base_url = try sa.dupe(u8, try optStr(&r));
                } else try r.skip();
            }
        } else if (std.mem.eql(u8, key, "shards")) {
            const m = try r.mapLen();
            var j: u32 = 0;
            while (j < m) : (j += 1) {
                const name = try r.str();
                if (!wanted.contains(name)) {
                    try r.skip();
                    continue;
                }
                const h = try r.bin();
                if (h.len != 32) return error.BadShardHash;
                const hex = try sa.alloc(u8, 64);
                hex[0..64].* = std.fmt.bytesToHex(h[0..32].*, .lower);
                try out.found.append(sa, .{ .name = try sa.dupe(u8, name), .hex = hex });
            }
        } else try r.skip();
    }
    return out;
}

/// Where package files are: the index's `base_url` when it is set (a full URL, or a path below the subdir's URL),
/// else the subdir's URL. Ends with a slash.
fn packageBase(sa: Allocator, subdir_url: []const u8, base_url: []const u8) ![]const u8 {
    if (base_url.len == 0) return subdir_url;
    const rooted = if (std.mem.indexOf(u8, base_url, "://") != null) base_url else try std.mem.concat(sa, u8, &.{ subdir_url, base_url });
    if (std.mem.endsWith(u8, rooted, "/")) return rooted;
    return std.mem.concat(sa, u8, &.{ rooted, "/" });
}

fn loadSharded(sa: Allocator, ia: Allocator, src: Source, index: *Index, window: *Window, subdir_url: []const u8, file: []const u8, url: []const u8, wanted: *const std.StringHashMap(void), diag: *Diag) !void {
    const compressed = try src.cache.readFileAlloc(sa, file, max_index_zst);
    const raw = decompress(sa, window, compressed, max_index_raw) catch |e| return damaged(ia, diag, url, "does not decompress", e);
    const si = parseShardIndex(sa, raw, wanted) catch |e| return damaged(ia, diag, url, "is not a shard index", e);
    const pkg_base = try packageBase(sa, subdir_url, si.base_url);
    // A relative shards_base_url is relative to the subdir's URL, like base_url.
    const shard_base = if (si.shards_base_url.len == 0) subdir_url else try packageBase(sa, subdir_url, si.shards_base_url);
    for (si.found.items) |f| {
        const shard_url = try std.fmt.allocPrint(sa, "{s}{s}.msgpack.zst", .{ shard_base, f.hex });
        var sd = Diag{};
        const zst = shardFile(sa, src, f.hex, shard_url, &sd) catch |e| {
            diag.message = try ia.dupe(u8, sd.message);
            return e;
        };
        const shard = decompress(sa, window, zst, max_shard_raw) catch |e| return damaged(ia, diag, shard_url, "does not decompress", e);
        readShard(ia, index, shard, f.name, pkg_base) catch |e| return damaged(ia, diag, shard_url, "is not a shard of that name", e);
    }
}

/// The records of one shard into `index`: every record of `packages` and `packages.conda`, each of the shard's `name`.
fn readShard(ia: Allocator, index: *Index, bytes: []const u8, name: []const u8, pkg_base: []const u8) !void {
    var r = msgpack.Reader.init(bytes);
    const n = try r.mapLen();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const key = try r.str();
        if (!std.mem.eql(u8, key, "packages") and !std.mem.eql(u8, key, "packages.conda")) {
            try r.skip();
            continue;
        }
        const m = try r.mapLen();
        var j: u32 = 0;
        while (j < m) : (j += 1) {
            const filename = try checkedFilename(try r.str());
            const rec = try readRecord(ia, &r, pkg_base, filename);
            if (!std.mem.eql(u8, rec.name, name)) return error.WrongName;
            try index.add(rec);
        }
    }
}

/// A file name goes into a URL, so it holds no separator, no control character and is not dot-only.
fn checkedFilename(s: []const u8) ![]const u8 {
    if (s.len == 0 or s.len > max_field or s[0] == '.') return error.BadFilename;
    for (s) |c| {
        if (c == '/' or c == '\\' or c == '?' or c == '#' or c < 0x20 or c == 0x7f) return error.BadFilename;
    }
    return s;
}

/// One record map of a shard.
fn readRecord(ia: Allocator, r: *msgpack.Reader, pkg_base: []const u8, filename: []const u8) !Record {
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var build: []const u8 = "";
    var depends: []const []const u8 = &.{};
    var constrains: []const []const u8 = &.{};
    var track: []const []const u8 = &.{};
    var sha: []const u8 = "";
    var size: u64 = 0;
    const n = try r.mapLen();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const key = try r.str();
        if (std.mem.eql(u8, key, "name")) {
            name = try ia.dupe(u8, try limited(try r.str()));
        } else if (std.mem.eql(u8, key, "version")) {
            version = try ia.dupe(u8, try limited(try r.str()));
        } else if (std.mem.eql(u8, key, "build")) {
            build = try ia.dupe(u8, try limited(try r.str()));
        } else if (std.mem.eql(u8, key, "depends")) {
            depends = try readList(ia, r);
        } else if (std.mem.eql(u8, key, "constrains")) {
            constrains = try readList(ia, r);
        } else if (std.mem.eql(u8, key, "track_features")) {
            track = try readFeatures(ia, r);
        } else if (std.mem.eql(u8, key, "sha256")) {
            sha = try readDigest(ia, r);
        } else if (std.mem.eql(u8, key, "size")) {
            size = try r.uint();
        } else try r.skip();
    }
    return finish(ia, pkg_base, filename, name orelse return error.NoName, version orelse return error.NoVersion, build, depends, constrains, track, sha, size);
}

fn finish(ia: Allocator, pkg_base: []const u8, filename: []const u8, name: []const u8, version: []const u8, build: []const u8, depends: []const []const u8, constrains: []const []const u8, track: []const []const u8, sha: []const u8, size: u64) !Record {
    return .{
        .name = name,
        .version = version,
        .build = build,
        .depends = depends,
        .constrains = constrains,
        .track_features = track,
        .url = try std.mem.concat(ia, u8, &.{ pkg_base, filename }),
        .sha256 = sha,
        .size = size,
    };
}

fn readList(ia: Allocator, r: *msgpack.Reader) ![]const []const u8 {
    if ((try r.peek()) == .nil) {
        try r.skip();
        return &.{};
    }
    const n = try r.arrayLen();
    if (n > max_list) return error.ListTooLong;
    const out = try ia.alloc([]const u8, n);
    for (out) |*slot| slot.* = try ia.dupe(u8, try limited(try r.str()));
    return out;
}

/// `track_features`: a string of names separated by spaces or commas (what conda writes), or a list of names.
fn readFeatures(ia: Allocator, r: *msgpack.Reader) ![]const []const u8 {
    switch (try r.peek()) {
        .str => {
            var out = std.ArrayListUnmanaged([]const u8){};
            var it = std.mem.tokenizeAny(u8, try limited(try r.str()), " ,");
            while (it.next()) |t| {
                if (out.items.len >= max_list) return error.ListTooLong;
                try out.append(ia, try ia.dupe(u8, t));
            }
            return out.items;
        },
        else => return readList(ia, r),
    }
}

/// A digest as lowercase hex: 32 bytes (what shards hold), or 64 hex characters.
fn readDigest(ia: Allocator, r: *msgpack.Reader) ![]const u8 {
    switch (try r.peek()) {
        .bin => {
            const b = try r.bin();
            if (b.len != 32) return error.BadDigest;
            return try ia.dupe(u8, &std.fmt.bytesToHex(b[0..32].*, .lower));
        },
        .nil => {
            try r.skip();
            return "";
        },
        else => {
            const s = try r.str();
            if (!isHex64(s)) return error.BadDigest;
            return try std.ascii.allocLowerString(ia, s);
        },
    }
}

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

// ------------------------------------------------------------------ repodata.json.zst

/// The fields of a record of repodata.json that the index keeps; the rest are skipped as they are read.
const JsonRecord = struct {
    name: []const u8,
    version: []const u8,
    build: []const u8 = "",
    depends: []const []const u8 = &.{},
    constrains: []const []const u8 = &.{},
    track_features: ?std.json.Value = null,
    sha256: []const u8 = "",
    size: u64 = 0,
};

/// `innerParse` sets neither of these itself for a reader: strings are copied (the reader reuses its buffer), and none may
/// be longer than 64 KiB (the field limit is checked after, on what is kept).
const json_options = std.json.ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_always, .max_value_len = 64 << 10 };

const JsonInfo = struct { base_url: []const u8 = "" };

fn loadJson(gpa: Allocator, sa: Allocator, ia: Allocator, src: Source, index: *Index, window: *Window, subdir_url: []const u8, file: []const u8, url: []const u8, wanted: *const std.StringHashMap(void), diag: *Diag) !void {
    var f = try src.cache.openFile(file, .{});
    defer f.close();
    var buffered = std.io.bufferedReader(f.reader());
    var zs = std.compress.zstd.decompressor(buffered.reader(), .{ .window_buffer = try window.get() });
    var capped = std.io.limitedReader(zs.reader(), max_json_raw);
    var jr = std.json.reader(gpa, capped.reader());
    defer jr.deinit();
    var record_arena = std.heap.ArenaAllocator.init(gpa);
    defer record_arena.deinit();
    readRepodataJson(sa, ia, &record_arena, &jr, index, subdir_url, wanted) catch |e| return damaged(ia, diag, url, "is not a repodata.json.zst (or is cut short, or over the size limit)", e);
}

fn readRepodataJson(sa: Allocator, ia: Allocator, record_arena: *std.heap.ArenaAllocator, jr: anytype, index: *Index, subdir_url: []const u8, wanted: *const std.StringHashMap(void)) !void {
    const ra = record_arena.allocator();
    var pkg_base = subdir_url;
    if ((try jr.next()) != .object_begin) return error.NotAnObject;
    while (true) {
        const t = try jr.nextAlloc(ra, .alloc_if_needed);
        const key: []const u8 = switch (t) {
            .object_end => return,
            .string => |s| s,
            .allocated_string => |s| s,
            else => return error.NotAnObject,
        };
        if (std.mem.eql(u8, key, "info")) {
            const info = try std.json.innerParse(JsonInfo, ra, jr, json_options);
            pkg_base = try packageBase(sa, subdir_url, try ia.dupe(u8, try limited(info.base_url)));
        } else if (std.mem.eql(u8, key, "packages") or std.mem.eql(u8, key, "packages.conda")) {
            try readJsonPackages(ia, record_arena, jr, index, pkg_base, wanted);
        } else {
            try jr.skipValue();
        }
        _ = record_arena.reset(.retain_capacity);
    }
}

fn readJsonPackages(ia: Allocator, record_arena: *std.heap.ArenaAllocator, jr: anytype, index: *Index, pkg_base: []const u8, wanted: *const std.StringHashMap(void)) !void {
    const ra = record_arena.allocator();
    if ((try jr.next()) != .object_begin) return error.NotAnObject;
    while (true) {
        _ = record_arena.reset(.retain_capacity);
        const t = try jr.nextAlloc(ra, .alloc_if_needed);
        const key: []const u8 = switch (t) {
            .object_end => return,
            .string => |s| s,
            .allocated_string => |s| s,
            else => return error.NotAnObject,
        };
        // The key lives in the reader's buffer, which the record's read reuses.
        const filename = try ra.dupe(u8, key);
        const raw = try std.json.innerParse(JsonRecord, ra, jr, json_options);
        if (!wanted.contains(raw.name)) continue;
        _ = try checkedFilename(filename);
        var track: []const []const u8 = &.{};
        if (raw.track_features) |tf| track = try jsonFeatures(ia, tf);
        const rec = try finish(
            ia,
            pkg_base,
            filename,
            try ia.dupe(u8, try limited(raw.name)),
            try ia.dupe(u8, try limited(raw.version)),
            try ia.dupe(u8, try limited(raw.build)),
            try copyList(ia, raw.depends),
            try copyList(ia, raw.constrains),
            track,
            try jsonDigest(ia, raw.sha256),
            raw.size,
        );
        try index.add(rec);
    }
}

fn copyList(ia: Allocator, list: []const []const u8) ![]const []const u8 {
    if (list.len > max_list) return error.ListTooLong;
    const out = try ia.alloc([]const u8, list.len);
    for (list, out) |s, *slot| slot.* = try ia.dupe(u8, try limited(s));
    return out;
}

fn jsonDigest(ia: Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return "";
    if (!isHex64(s)) return error.BadDigest;
    return std.ascii.allocLowerString(ia, s);
}

fn jsonFeatures(ia: Allocator, v: std.json.Value) ![]const []const u8 {
    var out = std.ArrayListUnmanaged([]const u8){};
    switch (v) {
        .null => {},
        .string => |s| {
            var it = std.mem.tokenizeAny(u8, try limited(s), " ,");
            while (it.next()) |t| {
                if (out.items.len >= max_list) return error.ListTooLong;
                try out.append(ia, try ia.dupe(u8, t));
            }
        },
        .array => |a| {
            if (a.items.len > max_list) return error.ListTooLong;
            for (a.items) |item| {
                if (item != .string) return error.BadFeature;
                try out.append(ia, try ia.dupe(u8, try limited(item.string)));
            }
        },
        else => return error.BadFeature,
    }
    return out.items;
}
