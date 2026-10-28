//! (Interface only; the reading follows.) conda-forge repodata for the names a lock asks about: the records of those names and nothing else.
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

pub fn openDefaultCache(arena: Allocator) !std.fs.Dir {
    _ = arena;
    return error.NotCached;
}

pub fn load(gpa: Allocator, src: Source, index: *Index, subdir: []const u8, names: []const []const u8, diag: *Diag) !void {
    _ = .{ gpa, src, index, subdir, names, diag };
    return error.NotCached;
}
