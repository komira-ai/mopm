//! The generator of the validator corpus (tests/validator_corpus).
//!
//! The registry's package validator (service/api/src/validate, and later its Rust port) decides, for the bytes
//! of an upload and what the publisher declared, whether the package is accepted and, if not, which rule
//! refused it first. This file makes the inputs of that decision as files: valid packages, and archives that
//! are wrong in one way (or two) at every layer: the outer zip, the zstd streams, the tars, the metadata,
//! and at the edge of each size limit. It writes `archives/*.conda` and `cases.json`, which names every
//! case, what the publisher declared, the limits in force, and the rule the case was written to hit.
//!
//! What it is not: an oracle. The verdicts live in `verdicts.json`, recorded from the TypeScript validator by
//! service/api/test/validate/corpus.test.ts; a second implementation must reproduce them. A case whose
//! recorded verdict is not the rule it was written for says so in its `note`.
//!
//! Nothing here goes through service/api/test/validate/builder.ts: the archives are written byte by byte, so a
//! fault is the one that was meant and not one a library normalised away. Everything is deterministic: no
//! clock, no random numbers; the zip date is 1980-01-01 and every mode and owner field is fixed.
//!
//! `zig run tests/drivers/validator_corpus.zig -- tests/validator_corpus` rewrites the corpus; the test
//! in validator_corpus_test.zig (Buck2 target //:validator_corpus) fails when the committed files differ from
//! what this file makes, and prints the differing files in base64.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---- the shape of the corpus --------------------------------------------------------------------

pub const Limits = struct {
    max_archive_bytes: ?u64 = null,
    max_file_bytes: ?u64 = null,
    max_unpacked_bytes: ?u64 = null,
    max_files: ?u64 = null,
    max_ratio: ?u64 = null,
    ratio_floor_bytes: ?u64 = null,
    max_metadata_bytes: ?u64 = null,
};

pub const Case = struct {
    id: []const u8,
    /// File name under archives/ (several cases may use one archive, with other limits).
    archive: []const u8,
    /// The rule the case was written to hit, or "ok".
    intent: []const u8,
    what: []const u8,
    name: []const u8 = "demo",
    version: []const u8 = "1.0.0",
    subdir: []const u8 = "noarch",
    filename: []const u8 = "mojo-demo-1.0.0-mojo1.0.0_0.conda",
    sha256: ?[]const u8 = null,
    manifest_sha256: ?[]const u8 = null,
    limits: Limits = .{},
    allow_native: []const []const u8 = &.{},
    note: []const u8 = "",
};

pub const Archive = struct { name: []const u8, bytes: []const u8 };
pub const Corpus = struct { archives: []const Archive, cases: []const Case };

// ---- byte writers -------------------------------------------------------------------------------

const Buf = std.ArrayList(u8);

fn put16(l: *Buf, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try l.appendSlice(&b);
}
fn put32(l: *Buf, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try l.appendSlice(&b);
}
fn cat(a: Allocator, parts: []const []const u8) ![]u8 {
    return std.mem.concat(a, u8, parts);
}
fn pr(a: Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(a, fmt, args);
}
fn hex(a: Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    const h = std.fmt.bytesToHex(d, .lower);
    return a.dupe(u8, &h);
}

// ---- tar ----------------------------------------------------------------------------------------

pub const Item = struct {
    path: []const u8,
    /// '0' file, '5' directory, '1' hard link, '2' symbolic link, '3' and '4' devices, '6' FIFO, anything else as is.
    typeflag: u8 = '0',
    data: []const u8 = "",
    link: []const u8 = "",
};

fn octal(dst: []u8, v: u64) void {
    // dst.len - 1 digits and a NUL, zero padded.
    @memset(dst, '0');
    dst[dst.len - 1] = 0;
    var i: usize = dst.len - 1;
    var x = v;
    while (i > 0) {
        i -= 1;
        dst[i] = '0' + @as(u8, @intCast(x % 8));
        x /= 8;
        if (x == 0) break;
    }
}

/// The checksum of a header: the sum of its bytes with the checksum field as spaces, plus `extra`
/// (a wrong checksum is made by asking for an extra), as six octal digits, a NUL and a space.
pub fn setChecksum(h: *[512]u8, extra: u64) void {
    @memset(h[148..156], ' ');
    var sum: u64 = extra;
    for (h.*) |b| sum += b;
    var i: usize = 6;
    var x = sum;
    while (i > 0) {
        i -= 1;
        h[148 + i] = '0' + @as(u8, @intCast(x % 8));
        x /= 8;
    }
    h[154] = 0;
    h[155] = ' ';
}

pub fn fixChecksum(h: *[512]u8) void {
    setChecksum(h, 0);
}

pub fn tarHeader(path: []const u8, typeflag: u8, size: u64, link: []const u8) [512]u8 {
    var h: [512]u8 = [_]u8{0} ** 512;
    const n: usize = @min(path.len, 100);
    @memcpy(h[0..n], path[0..n]);
    octal(h[100..108], 0o644);
    octal(h[108..116], 0);
    octal(h[116..124], 0);
    octal(h[124..136], size);
    octal(h[136..148], 0);
    h[156] = typeflag;
    const ln: usize = @min(link.len, 100);
    @memcpy(h[157 .. 157 + ln], link[0..ln]);
    @memcpy(h[257..263], "ustar\x00");
    @memcpy(h[263..265], "00");
    fixChecksum(&h);
    return h;
}

fn padTo512(l: *Buf) !void {
    const rem = l.items.len % 512;
    if (rem != 0) try l.appendNTimes(0, 512 - rem);
}

/// Header and data of one entry (data only for regular files), padded.
pub fn tarEntry(l: *Buf, it: Item) !void {
    const withData = it.typeflag == '0';
    const h = tarHeader(it.path, it.typeflag, if (withData) it.data.len else 0, it.link);
    try l.appendSlice(&h);
    if (withData) {
        try l.appendSlice(it.data);
        try padTo512(l);
    }
}

pub fn tarOf(a: Allocator, items: []const Item) ![]u8 {
    var l = Buf.init(a);
    for (items) |it| try tarEntry(&l, it);
    try l.appendNTimes(0, 1024);
    return l.items;
}

/// A tar entry carrying data of its own (typeflag 'x', 'g', 'L', 'K'): header and padded data.
fn tarMeta(l: *Buf, typeflag: u8, name: []const u8, data: []const u8) !void {
    const h = tarHeader(name, typeflag, data.len, "");
    try l.appendSlice(&h);
    try l.appendSlice(data);
    try padTo512(l);
}

/// A pax record "<len> <key>=<value>\n", where len counts the whole record.
fn paxRecord(a: Allocator, key: []const u8, value: []const u8) ![]u8 {
    const body = try pr(a, " {s}={s}\n", .{ key, value });
    var digits: usize = 1;
    while (true) {
        const total = body.len + digits;
        const need: usize = @intCast(std.fmt.count("{d}", .{total}));
        if (need == digits) break;
        digits = need;
    }
    return pr(a, "{d}{s}", .{ body.len + digits, body });
}

// ---- zstd ---------------------------------------------------------------------------------------

const ZSTD_MAGIC = [4]u8{ 0x28, 0xb5, 0x2f, 0xfd };

fn blockHeader(l: *Buf, last: bool, kind: u2, size: u32) !void {
    const v: u32 = (if (last) @as(u32, 1) else 0) | (@as(u32, kind) << 1) | (size << 3);
    try l.append(@truncate(v));
    try l.append(@truncate(v >> 8));
    try l.append(@truncate(v >> 16));
}

/// A frame of raw blocks, with a window descriptor and no content size (the form service/api/src/zstd.ts writes).
pub fn zstRaw(a: Allocator, data: []const u8) ![]u8 {
    var l = Buf.init(a);
    try l.appendSlice(&ZSTD_MAGIC);
    try l.append(0x00);
    try l.append(0x38);
    var off: usize = 0;
    while (true) {
        const n = @min(data.len - off, 131072);
        const last = off + n >= data.len;
        try blockHeader(&l, last, 0, @intCast(n));
        try l.appendSlice(data[off .. off + n]);
        off += n;
        if (last) break;
    }
    return l.items;
}

/// A frame of RLE blocks: `total` bytes of `byte` from a few bytes of input.
pub fn zstRle(a: Allocator, byte: u8, total: usize) ![]u8 {
    var l = Buf.init(a);
    try l.appendSlice(&ZSTD_MAGIC);
    try l.append(0x00);
    try l.append(0x38);
    var off: usize = 0;
    while (true) {
        const n = @min(total - off, 131072);
        const last = off + n >= total;
        try blockHeader(&l, last, 1, @intCast(n));
        try l.append(byte);
        off += n;
        if (last) break;
    }
    return l.items;
}

/// A skippable frame (magic 0x184D2A50) holding `payload`.
fn zstSkippable(a: Allocator, payload: []const u8) ![]u8 {
    var l = Buf.init(a);
    try put32(&l, 0x184D2A50);
    try put32(&l, @intCast(payload.len));
    try l.appendSlice(payload);
    return l.items;
}

/// A single-segment frame that declares a content size (one byte of size field under 256, two bytes from 256 up) and
/// holds `data` as one raw block.
fn zstSingleSegment(a: Allocator, declared: u32, data: []const u8) ![]u8 {
    var l = Buf.init(a);
    try l.appendSlice(&ZSTD_MAGIC);
    if (declared < 256) {
        try l.append(0x20);
        try l.append(@intCast(declared));
    } else {
        try l.append(0x60);
        try put16(&l, @intCast(declared - 256));
    }
    try blockHeader(&l, true, 0, @intCast(data.len));
    try l.appendSlice(data);
    return l.items;
}

// ---- zip ----------------------------------------------------------------------------------------

/// Deflate with stored blocks only: valid, decodable, uncompressed.
fn deflateStored(a: Allocator, data: []const u8) ![]u8 {
    var l = Buf.init(a);
    var off: usize = 0;
    while (true) {
        const n = @min(data.len - off, 65535);
        const last = off + n >= data.len;
        try l.append(if (last) 1 else 0);
        try put16(&l, @intCast(n));
        try put16(&l, ~@as(u16, @intCast(n)));
        try l.appendSlice(data[off .. off + n]);
        off += n;
        if (last) break;
    }
    return l.items;
}

pub const ZEntry = struct {
    name: []const u8,
    data: []const u8,
    deflate: bool = false,
    flags: u16 = 0,
    /// What the central directory says (the local header says the truth unless overridden below).
    method: ?u16 = null,
    crc: ?u32 = null,
    csize: ?u32 = null,
    usz: ?u32 = null,
    lho: ?u32 = null,
    /// The bytes after the local header, instead of the data (as stored or deflated).
    body: ?[]const u8 = null,
    local_name: ?[]const u8 = null,
    local_extra: []const u8 = "",
    local_sig: u32 = 0x04034b50,
    central_sig: u32 = 0x02014b50,
    /// Zero crc and sizes in the local header (the data-descriptor form).
    local_zero: bool = false,
};

pub const ZOpts = struct {
    disk: u16 = 0,
    cd_disk: u16 = 0,
    n_here: ?u16 = null,
    n_total: ?u16 = null,
    cd_size: ?u32 = null,
    cd_off: ?u32 = null,
    comment: []const u8 = "",
    comment_len: ?u16 = null,
};

/// The local header, name, extra field and body of one entry.
pub fn writeLocal(out: *Buf, e: ZEntry, body: []const u8, method: u16, crc: u32, csize: u32, usz: u32) !void {
    const lname = e.local_name orelse e.name;
    try put32(out, e.local_sig);
    try put16(out, 20);
    try put16(out, e.flags);
    try put16(out, method);
    try put16(out, 0);
    try put16(out, 0x21);
    try put32(out, if (e.local_zero) 0 else crc);
    try put32(out, if (e.local_zero) 0 else csize);
    try put32(out, if (e.local_zero) 0 else usz);
    try put16(out, @intCast(lname.len));
    try put16(out, @intCast(e.local_extra.len));
    try out.appendSlice(lname);
    try out.appendSlice(e.local_extra);
    try out.appendSlice(body);
}

pub fn zipOf(a: Allocator, entries: []const ZEntry, o: ZOpts) ![]u8 {
    var out = Buf.init(a);
    var cd = Buf.init(a);
    for (entries) |e| {
        const body: []const u8 = if (e.body) |b| b else if (e.deflate) try deflateStored(a, e.data) else e.data;
        const method: u16 = e.method orelse (if (e.deflate) @as(u16, 8) else 0);
        const crc: u32 = e.crc orelse std.hash.Crc32.hash(e.data);
        const csize: u32 = e.csize orelse @intCast(body.len);
        const usz: u32 = e.usz orelse @intCast(e.data.len);
        const here: u32 = @intCast(out.items.len);
        try writeLocal(&out, e, body, method, crc, csize, usz);

        try put32(&cd, e.central_sig);
        try put16(&cd, 20);
        try put16(&cd, 20);
        try put16(&cd, e.flags);
        try put16(&cd, method);
        try put16(&cd, 0);
        try put16(&cd, 0x21);
        try put32(&cd, crc);
        try put32(&cd, csize);
        try put32(&cd, usz);
        try put16(&cd, @intCast(e.name.len));
        try put16(&cd, 0);
        try put16(&cd, 0);
        try put16(&cd, 0);
        try put16(&cd, 0);
        try put32(&cd, 0);
        try put32(&cd, e.lho orelse here);
        try cd.appendSlice(e.name);
    }
    const cd_off: u32 = @intCast(out.items.len);
    try out.appendSlice(cd.items);
    try put32(&out, 0x06054b50);
    try put16(&out, o.disk);
    try put16(&out, o.cd_disk);
    try put16(&out, o.n_here orelse @as(u16, @intCast(entries.len)));
    try put16(&out, o.n_total orelse @as(u16, @intCast(entries.len)));
    try put32(&out, o.cd_size orelse @as(u32, @intCast(cd.items.len)));
    try put32(&out, o.cd_off orelse cd_off);
    try put16(&out, o.comment_len orelse @as(u16, @intCast(o.comment.len)));
    try out.appendSlice(o.comment);
    return out.items;
}

// ---- a package ----------------------------------------------------------------------------------

const MOJOC = "MOJOC-BYTES-0123456789";
const CONDA_META = "{\"conda_pkg_format_version\": 2}";

pub const Pkg = struct {
    mopm: ?[]const u8 = null,
    index: ?[]const u8 = null,
    conda_meta: []const u8 = CONDA_META,
    pkg_extra: []const Item = &.{},
    info_extra: []const Item = &.{},
    /// Paths removed from the defaults.
    drop: []const []const u8 = &.{},
    /// Whole tars, instead of the built ones.
    pkg_tar: ?[]const u8 = null,
    info_tar: ?[]const u8 = null,
    /// Whole compressed streams, instead of zstd(tar).
    pkg_stream: ?[]const u8 = null,
    info_stream: ?[]const u8 = null,
    deflate: bool = false,
    /// The mojoc file's content (the size cases need a file of a chosen size).
    mojoc: []const u8 = MOJOC,
};

pub const DEFAULT_FILENAME = "mojo-demo-1.0.0-mojo1.0.0_0.conda";
const PKG_ENTRY = "pkg-demo-1.0.0-mojo1.0.0_0.tar.zst";
const INFO_ENTRY = "info-demo-1.0.0-mojo1.0.0_0.tar.zst";
pub const DEFAULT_MOPM = "{\"schema\":1,\"name\":\"demo\",\"version\":\"1.0.0\",\"deps\":[],\"native\":[]}";
pub const DEFAULT_INDEX = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":[\"mojo-compiler ==1.0.0\"]}";

fn dropped(p: Pkg, path: []const u8) bool {
    for (p.drop) |d| if (std.mem.eql(u8, d, path)) return true;
    return false;
}

fn keep(a: Allocator, p: Pkg, items: []const Item, extra: []const Item) ![]const Item {
    var out = std.ArrayList(Item).init(a);
    for (items) |it| if (!dropped(p, it.path)) try out.append(it);
    for (extra) |it| try out.append(it);
    return out.items;
}

/// The three zip entries of a package, in the order metadata, info, pkg (the order the TypeScript builder writes).
pub fn pkgEntries(a: Allocator, p: Pkg) ![]ZEntry {
    const pkg_items = try keep(a, p, &[_]Item{
        .{ .path = "lib/mojo/demo.mojoc", .data = p.mojoc },
        .{ .path = "lib/mojo/demo.mopm.json", .data = p.mopm orelse DEFAULT_MOPM },
    }, p.pkg_extra);
    const info_items = try keep(a, p, &[_]Item{
        .{ .path = "info/index.json", .data = p.index orelse DEFAULT_INDEX },
        .{ .path = "info/licenses/LICENSE", .data = "Apache-2.0" },
    }, p.info_extra);
    const pkg_tar = p.pkg_tar orelse try tarOf(a, pkg_items);
    const info_tar = p.info_tar orelse try tarOf(a, info_items);
    const pkg_stream = p.pkg_stream orelse try zstRaw(a, pkg_tar);
    const info_stream = p.info_stream orelse try zstRaw(a, info_tar);
    const es = try a.alloc(ZEntry, 3);
    es[0] = .{ .name = "metadata.json", .data = p.conda_meta, .deflate = p.deflate };
    es[1] = .{ .name = INFO_ENTRY, .data = info_stream, .deflate = p.deflate };
    es[2] = .{ .name = PKG_ENTRY, .data = pkg_stream, .deflate = p.deflate };
    return es;
}

pub fn pkgBytes(a: Allocator, p: Pkg) ![]u8 {
    return zipOf(a, try pkgEntries(a, p), .{});
}

// ---- the corpus ---------------------------------------------------------------------------------

const Gen = struct {
    a: Allocator,
    archives: std.ArrayList(Archive),
    cases: std.ArrayList(Case),

    fn init(a: Allocator) Gen {
        return .{ .a = a, .archives = std.ArrayList(Archive).init(a), .cases = std.ArrayList(Case).init(a) };
    }

    fn arc(g: *Gen, name: []const u8, bytes: []const u8) !void {
        for (g.archives.items) |x| if (std.mem.eql(u8, x.name, name)) return error.DuplicateArchive;
        try g.archives.append(.{ .name = name, .bytes = bytes });
    }

    /// A case on an archive named like the case; `c` supplies the rest.
    fn raw(g: *Gen, id: []const u8, intent: []const u8, what: []const u8, bytes: []const u8, c: Case) !void {
        const file = try pr(g.a, "{s}.conda", .{id});
        try g.arc(file, bytes);
        var k = c;
        k.id = id;
        k.archive = file;
        k.intent = intent;
        k.what = what;
        try g.cases.append(k);
    }

    /// A case on an archive that already exists (another limit, another declaration).
    fn again(g: *Gen, id: []const u8, intent: []const u8, what: []const u8, archive: []const u8, c: Case) !void {
        var k = c;
        k.id = id;
        k.archive = archive;
        k.intent = intent;
        k.what = what;
        try g.cases.append(k);
    }

    fn pkg(g: *Gen, id: []const u8, intent: []const u8, what: []const u8, p: Pkg, c: Case) !void {
        try g.raw(id, intent, what, try pkgBytes(g.a, p), c);
    }
};

const none: Case = .{ .id = "", .archive = "", .intent = "", .what = "" };

fn withNote(c: Case, note: []const u8) Case {
    var k = c;
    k.note = note;
    return k;
}

fn withLimits(l: Limits) Case {
    var k = none;
    k.limits = l;
    return k;
}

pub fn build(a: Allocator) !Corpus {
    var g = Gen.init(a);

    try valid(&g);
    try archiveLevel(&g);
    try zipLevel(&g);
    try zstdLevel(&g);
    try tarLevel(&g);
    try metadataLevel(&g);
    try orderLevel(&g);
    try boundaries(&g);

    return .{ .archives = g.archives.items, .cases = g.cases.items };
}

fn valid(g: *Gen) !void {
    const a = g.a;
    try g.pkg("ok_minimal", "ok", "the smallest valid package: stored zip entries, raw zstd frames", .{}, none);
    try g.pkg("ok_deflated_entries", "ok", "the same package with the zip entries in deflate stored blocks (method 8)", .{ .deflate = true }, none);
    try g.pkg("ok_directories_and_dot_prefix", "ok", "directory entries of the allowed layout, and a leading ./ on the paths", .{
        .pkg_extra = &[_]Item{ .{ .path = "./lib/", .typeflag = '5' }, .{ .path = "lib/mojo/", .typeflag = '5' } },
        .info_extra = &[_]Item{ .{ .path = "info/", .typeflag = '5' }, .{ .path = "./info/licenses/", .typeflag = '5' } },
    }, none);
    try g.pkg("ok_info_files", "ok", "the optional info/ files the allow-list names, and a nested licence file", .{
        .info_extra = &[_]Item{
            .{ .path = "info/paths.json", .data = "{}" },
            .{ .path = "info/about.json", .data = "{}" },
            .{ .path = "info/files", .data = "" },
            .{ .path = "info/hash_input.json", .data = "{}" },
            .{ .path = "info/licenses/third_party/NOTICE", .data = "n" },
        },
    }, none);
    try g.pkg("ok_native_shared", "ok", "a declared shared library under lib/ (file name equals the soname)", .{
        .mopm = "{\"schema\":1,\"name\":\"demo\",\"version\":\"1.0.0\",\"deps\":[],\"native\":[{\"id\":\"crypto\",\"soname\":\"libcrypto_native.so.1\",\"file\":\"../libcrypto_native.so.1\"}]}",
        .pkg_extra = &[_]Item{.{ .path = "lib/libcrypto_native.so.1", .data = "ELF" }},
    }, none);
    try g.pkg("ok_native_static", "ok", "a declared static library", .{
        .mopm = "{\"schema\":1,\"name\":\"demo\",\"version\":\"1.0.0\",\"deps\":[],\"native\":[{\"id\":\"foo\",\"soname\":\"libfoo.a\",\"kind\":\"static\",\"static_file\":\"../libfoo.a\"}]}",
        .pkg_extra = &[_]Item{.{ .path = "lib/libfoo.a", .data = "!<arch>" }},
    }, none);
    try g.pkg("ok_mojo_dependency", "ok", "a dependency in the metadata and the same one in depends", .{
        .mopm = "{\"schema\":1,\"name\":\"demo\",\"version\":\"1.0.0\",\"deps\":[{\"name\":\"http_core\",\"range\":\">=1.2,<2\"}],\"native\":[]}",
        .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":[\"mojo-compiler ==1.0.0\",\"mojo-http_core >=1.2,<2\"]}",
    }, none);
    try g.pkg("ok_allowed_native_dependency", "ok", "a native library in depends that the allow-list names", .{
        .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":[\"mojo-compiler ==1.0.0\",\"libssl >=3\"]}",
    }, .{ .id = "", .archive = "", .intent = "", .what = "", .allow_native = &[_][]const u8{"libssl"} });
    try g.pkg("ok_unicode_licence_name", "ok", "one non-ASCII licence file name, in one normalisation form", .{
        .info_extra = &[_]Item{.{ .path = "info/licenses/caf\xc3\xa9", .data = "x" }},
    }, none);
    try g.pkg("ok_pax_path", "ok", "a pax extended header that sets the path of the next entry (the pkg tar)", .{ .pkg_tar = try paxTar(a) }, none);
    try g.pkg("ok_gnu_long_name", "ok", "a GNU long name (type L) for a licence file whose name is over 100 bytes (the info tar)", .{ .info_tar = try longNameTar(a) }, none);
    try g.pkg("ok_ustar_prefix", "ok", "a ustar header with a prefix field: prefix + / + name (the info tar)", .{ .info_tar = try prefixTar(a) }, none);
    try g.pkg("ok_zip_data_descriptor_flag", "ok", "general purpose flag bit 3 with zero sizes in the local headers; the central directory has them", .{}, withNote(none, "see the entries edited below"));
    // Edit that last case: the archive was already added by `pkg`, so replace it.
    {
        const es = try pkgEntries(a, .{});
        for (es) |*e| {
            e.flags = 0x08;
            e.local_zero = true;
        }
        g.archives.items[g.archives.items.len - 1].bytes = try zipOf(a, es, .{});
    }
    try g.pkg("ok_zip_local_extra_field", "ok", "an extra field in the local headers (the central directory has none)", .{}, none);
    {
        const es = try pkgEntries(a, .{});
        for (es) |*e| e.local_extra = "\xfe\xca\x04\x00abcd";
        g.archives.items[g.archives.items.len - 1].bytes = try zipOf(a, es, .{});
    }
    try g.pkg("ok_zip_utf8_flag", "ok", "general purpose flag bit 11 (UTF-8 names)", .{}, none);
    {
        const es = try pkgEntries(a, .{});
        for (es) |*e| e.flags = 0x0800;
        g.archives.items[g.archives.items.len - 1].bytes = try zipOf(a, es, .{});
    }
    try g.pkg("ok_zstd_two_frames", "ok", "the info tar as two concatenated zstd frames", .{}, none);
    {
        const es = try pkgEntries(a, .{});
        const tar = try tarOf(a, &[_]Item{ .{ .path = "info/index.json", .data = DEFAULT_INDEX }, .{ .path = "info/licenses/LICENSE", .data = "Apache-2.0" } });
        es[1].data = try cat(a, &[_][]const u8{ try zstRaw(a, tar[0..512]), try zstRaw(a, tar[512..]) });
        g.archives.items[g.archives.items.len - 1].bytes = try zipOf(a, es, .{});
    }
    // Declared hashes that are right.
    {
        const bytes = try pkgBytes(a, .{});
        var c = none;
        c.sha256 = try hex(a, bytes);
        c.manifest_sha256 = try hex(a, DEFAULT_MOPM);
        try g.raw("ok_declared_hashes_right", "ok", "the archive hash and the manifest hash declared, and right", bytes, c);
    }
    // The version spelled differently in the request.
    {
        var c = none;
        c.version = "1.0.0";
        c.filename = DEFAULT_FILENAME;
        try g.pkg("ok_metadata_version_absent", "ok", "the metadata without a version member (it is optional)", .{
            .mopm = "{\"schema\":1,\"name\":\"demo\",\"deps\":[],\"native\":[]}",
        }, c);
    }
}

/// A pkg tar whose mojoc entry is named by a pax record: the header's own name is a decoy.
fn paxTar(a: Allocator) ![]u8 {
    var l = Buf.init(a);
    try tarMeta(&l, 'x', "PaxHeader/x", try paxRecord(a, "path", "lib/mojo/demo.mojoc"));
    try tarEntry(&l, .{ .path = "decoy-name-replaced-by-pax", .data = MOJOC });
    try tarEntry(&l, .{ .path = "lib/mojo/demo.mopm.json", .data = DEFAULT_MOPM });
    try l.appendNTimes(0, 1024);
    return l.items;
}

/// An info tar with a licence file whose name is over 100 bytes, given by a GNU long-name header.
fn longNameTar(a: Allocator) ![]u8 {
    var name = Buf.init(a);
    try name.appendSlice("info/licenses/");
    try name.appendNTimes('n', 120);
    var l = Buf.init(a);
    try tarMeta(&l, 'L', "././@LongLink", try cat(a, &[_][]const u8{ name.items, "\x00" }));
    try tarEntry(&l, .{ .path = "truncated-name", .data = "x" });
    try tarEntry(&l, .{ .path = "info/index.json", .data = DEFAULT_INDEX });
    try l.appendNTimes(0, 1024);
    return l.items;
}

/// An info tar with a licence file named by the ustar prefix field and a short name.
fn prefixTar(a: Allocator) ![]u8 {
    var l = Buf.init(a);
    var h = tarHeader("LICENSE2", '0', 1, "");
    @memcpy(h[345..358], "info/licenses");
    fixChecksum(&h);
    try l.appendSlice(&h);
    try l.appendSlice("x");
    try padTo512(&l);
    try tarEntry(&l, .{ .path = "info/index.json", .data = DEFAULT_INDEX });
    try l.appendNTimes(0, 1024);
    return l.items;
}

fn archiveLevel(g: *Gen) !void {
    const a = g.a;
    try g.raw("archive_empty", "not_an_archive", "zero bytes", "", none);
    try g.raw("archive_one_byte", "not_an_archive", "one byte", "P", none);
    try g.raw("archive_garbage", "not_an_archive", "bytes that are neither a zip nor a bzip2 stream", "this is not an archive at all, just text", none);
    try g.raw("archive_bzip2_named_conda", "not_an_archive", "bzip2 magic under a .conda file name", "BZh91AY&SY", none);
    {
        var c = none;
        c.filename = "mojo-demo-1.0.0-mojo1.0.0_0.tar.bz2";
        try g.raw("archive_bzip2_named_tar_bz2", "format_not_allowed", "bzip2 magic under a .tar.bz2 name: the format is recognised and not accepted", "BZh91AY&SY", c);
        try g.pkg("archive_zip_named_tar_bz2", "not_an_archive", "a zip under a .tar.bz2 file name", .{}, c);
    }
    try g.raw("archive_zip_magic_only", "archive_corrupt", "only the four bytes of a local header signature", "PK\x03\x04", none);
    {
        var c = none;
        c.sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
        try g.pkg("archive_sha256_mismatch", "sha256_mismatch", "a valid package, a wrong archive hash declared", .{}, c);
    }
    {
        var c = none;
        c.sha256 = "ABCDEF0000000000000000000000000000000000000000000000000000000000";
        try g.pkg("archive_sha256_uppercase_declared", "sha256_mismatch", "an upper-case declared hash is compared lower-cased: this one is wrong", .{}, c);
    }
    {
        const bytes = try pkgBytes(a, .{});
        var c = none;
        c.sha256 = try hex(a, bytes);
        const up = try a.dupe(u8, c.sha256.?);
        for (up) |*ch| ch.* = std.ascii.toUpper(ch.*);
        c.sha256 = up;
        try g.raw("archive_sha256_uppercase_right", "ok", "the right hash, declared in upper case: accepted", bytes, c);
    }
}

fn zipLevel(g: *Gen) !void {
    const a = g.a;
    const base = try pkgEntries(a, .{});

    try g.raw("zip_no_end_record", "archive_corrupt", "a local header and no end of central directory", try cat(a, &[_][]const u8{ "PK\x03\x04", &[_]u8{0} ** 40 }), none);
    {
        const z = try pkgBytes(a, .{});
        try g.raw("zip_trailing_junk", "archive_corrupt", "bytes after the end record: the comment length no longer reaches the end of the file", try cat(a, &[_][]const u8{ z, "junk" }), none);
        try g.raw("zip_prepended_junk", "not_an_archive", "bytes before the first local header: the file no longer starts with a zip signature", try cat(a, &[_][]const u8{ "junk", z }), none);
        try g.raw("zip_prepended_after_signature", "archive_corrupt", "four bytes before the first local header that look like a signature: every offset is off by four", try cat(a, &[_][]const u8{ "PK\x03\x04", z }), none);
        try g.raw("zip_comment_length_short", "archive_corrupt", "an end record whose comment length is one short of the real comment", try zipOf(a, base, .{ .comment = "abc", .comment_len = 2 }), none);
        try g.raw("zip_comment_ok", "ok", "an archive comment whose length is right", try zipOf(a, base, .{ .comment = "a comment" }), none);
    }
    try g.raw("zip_second_disk", "archive_corrupt", "an end record that names disk 1", try zipOf(a, base, .{ .disk = 1 }), none);
    try g.raw("zip_central_on_second_disk", "archive_corrupt", "a central directory on disk 1", try zipOf(a, base, .{ .cd_disk = 1 }), none);
    try g.raw("zip_entry_counts_differ", "archive_corrupt", "entries on this disk differ from entries in total", try zipOf(a, base, .{ .n_here = 2 }), none);
    try g.raw("zip_zip64_count", "archive_corrupt", "the zip64 marker 0xffff as the entry count", try zipOf(a, base, .{ .n_here = 0xffff, .n_total = 0xffff }), none);
    try g.raw("zip_zip64_directory_size", "archive_corrupt", "the zip64 marker as the size of the central directory", try zipOf(a, base, .{ .cd_size = 0xffffffff }), none);
    try g.raw("zip_directory_out_of_bounds", "archive_corrupt", "a central directory that ends past the end record", try zipOf(a, base, .{ .cd_size = 5000 }), none);
    {
        const es = try a.dupe(ZEntry, base);
        es[0].central_sig = 0x02014b51;
        try g.raw("zip_bad_central_signature", "archive_corrupt", "a central directory entry with a wrong signature", try zipOf(a, es, .{}), none);
    }
    {
        // Seventeen entries: one over the limit of sixteen.
        var es = std.ArrayList(ZEntry).init(a);
        try es.appendSlice(base);
        var i: usize = 0;
        while (i < 14) : (i += 1) try es.append(.{ .name = try pr(a, "extra{d}", .{i}), .data = "" });
        try g.raw("zip_seventeen_entries", "archive_corrupt", "seventeen entries: the reader stops at sixteen before the layout rule could count them", try zipOf(a, es.items, .{}), none);
        _ = es.pop();
        try g.raw("zip_sixteen_entries", "conda_layout", "sixteen entries: read, then refused by the layout rule (three are required)", try zipOf(a, es.items, .{}), none);
    }
    inline for (.{
        .{ "zip_encrypted_flag", @as(u16, 0x1), "general purpose flag bit 0 (encrypted)" },
        .{ "zip_strong_encryption_flag", @as(u16, 0x40), "general purpose flag bit 6 (strong encryption)" },
    }) |t| {
        const es = try a.dupe(ZEntry, base);
        es[0].flags = t[1];
        try g.raw(t[0], "archive_corrupt", t[2], try zipOf(a, es, .{}), none);
    }
    {
        var es = try a.dupe(ZEntry, base);
        es[0].method = 12;
        try g.raw("zip_method_bzip2", "archive_corrupt", "compression method 12 (bzip2)", try zipOf(a, es, .{}), none);
        es = try a.dupe(ZEntry, base);
        es[0].csize = 3;
        try g.raw("zip_stored_sizes_differ", "archive_corrupt", "a stored entry whose compressed and uncompressed sizes differ", try zipOf(a, es, .{}), none);
        es = try a.dupe(ZEntry, base);
        es[1].name = "metadata.json";
        try g.raw("zip_duplicate_name", "archive_corrupt", "two entries named metadata.json", try zipOf(a, es, .{}), none);
        es = try a.dupe(ZEntry, base);
        es[0].name = "metadata\xff.json";
        es[0].local_name = "metadata\xff.json";
        try g.raw("zip_name_not_utf8", "archive_corrupt", "an entry name that is not UTF-8", try zipOf(a, es, .{}), none);
        es = try a.dupe(ZEntry, base);
        es[1].local_sig = 0x04034b51;
        try g.raw("zip_bad_local_signature", "archive_corrupt", "the second local header with a wrong signature", try zipOf(a, es, .{}), none);
        es = try a.dupe(ZEntry, base);
        es[0].local_name = "metadata.jsoN";
        try g.raw("zip_local_name_differs", "archive_corrupt", "a local header that names a different file than the central directory", try zipOf(a, es, .{}), none);
        es = try a.dupe(ZEntry, base);
        es[0].crc = 1;
        try g.raw("zip_crc_wrong", "archive_corrupt", "a CRC-32 that is not the data's", try zipOf(a, es, .{}), none);
        es = try a.dupe(ZEntry, base);
        es[0].usz = 99;
        try g.raw("zip_declared_size_wrong_stored", "archive_corrupt", "a stored entry whose declared size is not the data's (and not its compressed size)", try zipOf(a, es, .{}), none);
        es = try a.dupe(ZEntry, base);
        es[0].deflate = true;
        es[0].usz = 5;
        try g.raw("zip_deflate_declared_smaller", "archive_corrupt", "a deflated entry that inflates to more than its declared size", try zipOf(a, es, .{}), none);
        es = try a.dupe(ZEntry, base);
        es[0].deflate = true;
        es[0].usz = 500;
        try g.raw("zip_deflate_declared_larger", "archive_corrupt", "a deflated entry that inflates to less than its declared size", try zipOf(a, es, .{}), none);
        es = try a.dupe(ZEntry, base);
        es[0].deflate = true;
        es[0].body = "\x07\x00\x00";
        try g.raw("zip_deflate_invalid_block", "archive_corrupt", "a deflate stream with the reserved block type 3", try zipOf(a, es, .{}), none);
        es = try a.dupe(ZEntry, base);
        es[0].deflate = true;
        es[0].usz = 5_000_000;
        es[0].csize = 50;
        try g.raw("zip_declared_ratio", "compression_ratio", "a deflated entry that declares 5 MB from 50 bytes: refused from the directory alone", try zipOf(a, es, .{}), none);
    }
    {
        // The data of the first entry holds the whole local record of the second: their byte ranges overlap.
        const inner = ZEntry{ .name = "inner.txt", .data = "inner" };
        var rec = Buf.init(a);
        try writeLocal(&rec, inner, inner.data, 0, std.hash.Crc32.hash(inner.data), 5, 5);
        const outer = ZEntry{ .name = "outer.bin", .data = rec.items };
        var inner_c = inner;
        inner_c.lho = 30 + 9; // the 30-byte local header and the name "outer.bin" come first
        try g.raw("zip_overlapping_entries", "archive_corrupt", "two entries whose byte ranges overlap: the second lives inside the first (the zip-quine shape)", try zipOf(a, &[_]ZEntry{ outer, inner_c }, .{}), none);
    }
    // The layout rule of a .conda: exactly metadata.json, one pkg-*.tar.zst, one info-*.tar.zst.
    {
        var es = try a.dupe(ZEntry, base);
        try g.raw("layout_no_metadata", "conda_layout", "metadata.json missing", try zipOf(a, es[1..], .{}), none);
        try g.raw("layout_no_info_tar", "conda_layout", "the info tar missing", try zipOf(a, &[_]ZEntry{ es[0], es[2] }, .{}), none);
        try g.raw("layout_no_pkg_tar", "conda_layout", "the pkg tar missing", try zipOf(a, es[0..2], .{}), none);
        var four = std.ArrayList(ZEntry).init(a);
        try four.appendSlice(base);
        try four.append(.{ .name = "pkg-other.tar.zst", .data = es[2].data });
        try g.raw("layout_two_pkg_tars", "conda_layout", "a second pkg tar", try zipOf(a, four.items, .{}), none);
        es = try a.dupe(ZEntry, base);
        es[0].name = "metadata.JSON";
        es[0].local_name = "metadata.JSON";
        try g.raw("layout_metadata_name_case", "conda_layout", "metadata.json spelled metadata.JSON", try zipOf(a, es, .{}), none);
    }
    try g.pkg("layout_metadata_version_1", "conda_layout", "conda_pkg_format_version 1", .{ .conda_meta = "{\"conda_pkg_format_version\": 1}" }, none);
    try g.pkg("layout_metadata_not_json", "conda_layout", "metadata.json that is not JSON", .{ .conda_meta = "not json" }, none);
    try g.pkg("layout_metadata_null", "conda_layout", "metadata.json that is JSON null", .{ .conda_meta = "null" }, none);
    try g.pkg("layout_metadata_array", "conda_layout", "metadata.json that is an array", .{ .conda_meta = "[2]" }, none);
    try g.pkg("layout_metadata_invalid_utf8", "conda_layout", "metadata.json with an invalid UTF-8 byte", .{ .conda_meta = "{\"conda_pkg_format_version\": 2, \"x\": \"\xff\"}" }, none);
    try g.pkg("layout_metadata_utf8_bom", "ok", "metadata.json that starts with a UTF-8 byte order mark", .{ .conda_meta = "\xef\xbb\xbf{\"conda_pkg_format_version\": 2}" }, withNote(none, "the decoder drops a leading byte order mark"));
    try g.pkg("layout_info_path_in_pkg_tar", "conda_layout", "an info/ path inside the pkg tar", .{ .pkg_extra = &[_]Item{.{ .path = "info/stray", .data = "x" }} }, none);
    try g.pkg("layout_pkg_path_in_info_tar", "conda_layout", "a lib/ path inside the info tar", .{ .info_extra = &[_]Item{.{ .path = "lib/mojo/stray", .data = "x" }} }, none);
}

fn zstdLevel(g: *Gen) !void {
    const a = g.a;
    const info_tar = try tarOf(a, &[_]Item{ .{ .path = "info/index.json", .data = DEFAULT_INDEX }, .{ .path = "info/licenses/LICENSE", .data = "Apache-2.0" } });
    const good = try zstRaw(a, info_tar);

    try g.pkg("zstd_not_a_frame", "archive_corrupt", "an info stream that does not start with the zstd magic", .{ .info_stream = "NOT-ZSTD-AT-ALL" }, none);
    try g.pkg("zstd_empty_stream", "archive_corrupt", "an empty info stream", .{ .info_stream = "" }, none);
    try g.pkg("zstd_magic_only", "archive_corrupt", "only the magic number", .{ .info_stream = &ZSTD_MAGIC }, none);
    try g.pkg("zstd_truncated_in_block", "archive_corrupt", "a frame cut in the middle of its block", .{ .info_stream = good[0 .. good.len / 2] }, none);
    try g.pkg("zstd_truncated_before_last_block", "archive_corrupt", "a frame cut at a block boundary, before the block marked last", .{
        .info_stream = try cat(a, &[_][]const u8{ &ZSTD_MAGIC, "\x00\x38", &[_]u8{ 0x00, 0x08, 0x00 }, info_tar[0..1] }),
    }, none);
    try g.pkg("zstd_reserved_block_type", "archive_corrupt", "a block of the reserved type 3", .{
        .info_stream = try cat(a, &[_][]const u8{ &ZSTD_MAGIC, "\x00\x38", &[_]u8{ 0x07, 0x00, 0x00 } }),
    }, none);
    try g.pkg("zstd_trailing_garbage", "archive_corrupt", "bytes after the last frame", .{ .info_stream = try cat(a, &[_][]const u8{ good, "JUNKJUNK" }) }, none);
    try g.pkg("zstd_skippable_frame_first", "archive_corrupt", "a skippable zstd frame before the real one: the reader insists that a stream start with the zstd magic number", .{
        .info_stream = try cat(a, &[_][]const u8{ try zstSkippable(a, "ignore me"), good }),
    }, none);
    try g.pkg("zstd_skippable_after", "ok", "a skippable frame after the real one", .{ .info_stream = try cat(a, &[_][]const u8{ good, try zstSkippable(a, "ignore me") }) }, none);
    try g.pkg("zstd_two_real_frames_split_mid_header", "ok", "the tar cut inside a tar header, in two frames", .{
        .info_stream = try cat(a, &[_][]const u8{ try zstRaw(a, info_tar[0..100]), try zstRaw(a, info_tar[100..]) }),
    }, none);
    try g.pkg("zstd_declared_size_exact", "ok", "a single-segment frame whose declared content size is the tar's size", .{
        .info_stream = try zstSingleSegment(a, @intCast(info_tar.len), info_tar),
    }, none);
    try g.pkg("zstd_declared_size_smaller", "archive_corrupt", "a single-segment frame that declares 100 bytes of content and holds the whole tar", .{
        .info_stream = try zstSingleSegment(a, 100, info_tar),
    }, none);
    try g.pkg("zstd_declared_size_larger", "ok", "a single-segment frame that declares 5000 bytes of content and holds 3072: a content size larger than the content is accepted", .{
        .info_stream = try zstSingleSegment(a, 5000, info_tar),
    }, none);
    // Bombs, with limits that make the guard fire at a small size.
    {
        const rle = try zstRle(a, 0x41, 200_000);
        var l = withLimits(.{ .max_unpacked_bytes = 100_000, .max_files = 2 });
        l.note = "max_files 2 (the info tar's two entries) shrinks the allowance the collector adds for tar headers to about 69 KB";
        try g.pkg("zstd_rle_past_unpacked_limit", "unpacked_too_large", "an RLE frame that expands to 200000 bytes under a 100000 byte limit", .{ .pkg_stream = rle }, l);
    }
    {
        const rle = try zstRle(a, 0x41, 3_000_000);
        try g.pkg("zstd_rle_ratio_bomb", "compression_ratio", "an RLE frame of about 100 bytes that expands to 3 MB under the default limits", .{ .pkg_stream = rle }, none);
    }
    {
        // Not a tar: the guard lets it through (ratio exactly at the limit) and the tar reader refuses it. See the boundary cases.
        const rle = try zstRle(a, 0x41, 4000);
        try g.pkg("zstd_rle_not_a_tar", "tar_header", "an RLE frame of 4000 bytes of 'A': under the guards, and not a tar", .{ .pkg_stream = rle }, none);
    }
}

fn tarLevel(g: *Gen) !void {
    const a = g.a;
    const mojoc = Item{ .path = "lib/mojo/demo.mojoc", .data = MOJOC };
    const mopm = Item{ .path = "lib/mojo/demo.mopm.json", .data = DEFAULT_MOPM };
    const std_pkg = [_]Item{ mojoc, mopm };

    // Header faults, in the pkg tar.
    {
        var l = Buf.init(a);
        var h = tarHeader("lib/mojo/demo.mojoc", '0', MOJOC.len, "");
        h[148] = '9';
        try l.appendSlice(&h);
        try l.appendSlice(MOJOC);
        try padTo512(&l);
        try tarEntry(&l, mopm);
        try l.appendNTimes(0, 1024);
        try g.pkg("tar_checksum_wrong", "tar_header", "a header checksum whose first digit is wrong", .{ .pkg_tar = l.items }, none);
    }
    {
        var l = Buf.init(a);
        var h = tarHeader("lib/mojo/demo.mojoc", '0', MOJOC.len, "");
        setChecksum(&h, 1); // the right sum plus one
        try l.appendSlice(&h);
        try l.appendSlice(MOJOC);
        try padTo512(&l);
        try tarEntry(&l, mopm);
        try l.appendNTimes(0, 1024);
        try g.pkg("tar_checksum_off_by_one", "tar_header", "a header checksum that is the sum plus one", .{ .pkg_tar = l.items }, none);
    }
    {
        var l = Buf.init(a);
        var h = tarHeader("lib/mojo/demo.mojoc", '0', MOJOC.len, "");
        h[124] = 0x80;
        fixChecksum(&h);
        try l.appendSlice(&h);
        try l.appendSlice(MOJOC);
        try padTo512(&l);
        try l.appendNTimes(0, 1024);
        try g.pkg("tar_size_base256", "tar_header", "a size field in base-256 (high bit set)", .{ .pkg_tar = l.items }, none);
    }
    {
        var l = Buf.init(a);
        var h = tarHeader("lib/mojo/demo.mojoc", '0', MOJOC.len, "");
        @memcpy(h[124..136], "0000000089\x00\x00");
        fixChecksum(&h);
        try l.appendSlice(&h);
        try l.appendSlice(MOJOC);
        try padTo512(&l);
        try l.appendNTimes(0, 1024);
        try g.pkg("tar_size_not_octal", "tar_header", "a size field with the digits 8 and 9", .{ .pkg_tar = l.items }, none);
    }
    {
        const t = try tarOf(a, &std_pkg);
        try g.pkg("tar_truncated_in_entry", "tar_header", "a tar cut inside the data of an entry", .{ .pkg_tar = t[0..600] }, none);
        try g.pkg("tar_no_end_marker", "tar_header", "a tar without its two zero blocks", .{ .pkg_tar = t[0 .. t.len - 1024] }, none);
        try g.pkg("tar_one_zero_block", "ok", "a tar with one zero block, not two", .{ .pkg_tar = t[0 .. t.len - 512] }, withNote(none, "one zero block is an end marker; the reader accepts it when nothing follows"));
        try g.pkg("tar_data_after_end", "tar_header", "non-zero bytes after the end marker", .{ .pkg_tar = try cat(a, &[_][]const u8{ t, "x" }) }, none);
        try g.pkg("tar_zero_padding_after_end", "ok", "more zero bytes after the end marker", .{ .pkg_tar = try cat(a, &[_][]const u8{ t, &[_]u8{0} ** 2048 }) }, none);
    }
    // pax.
    {
        var l = Buf.init(a);
        try tarMeta(&l, 'x', "PaxHeader/x", try paxRecord(a, "size", "600"));
        try tarEntry(&l, mojoc);
        try tarEntry(&l, mopm);
        try l.appendNTimes(0, 1024);
        try g.pkg("tar_pax_size_override", "tar_header", "a pax size record that makes the next entry 600 bytes long: the data swallows the next header and the tar falls out of step", .{ .pkg_tar = l.items }, none);
    }
    {
        var l = Buf.init(a);
        try tarMeta(&l, 'x', "PaxHeader/x", try paxRecord(a, "path", "../escape"));
        try tarEntry(&l, .{ .path = "harmless", .data = "x" });
        try tarEntry(&l, mojoc);
        try tarEntry(&l, mopm);
        try l.appendNTimes(0, 1024);
        try g.pkg("tar_pax_path_traversal", "path_traversal", "a pax path record of ../escape", .{ .pkg_tar = l.items }, none);
    }
    {
        var l = Buf.init(a);
        try tarMeta(&l, 'x', "PaxHeader/x", "9 path=ab\n");
        try tarEntry(&l, mojoc);
        try l.appendNTimes(0, 1024);
        try g.pkg("tar_pax_record_malformed", "tar_header", "a pax record whose length field is wrong", .{ .pkg_tar = l.items }, none);
    }
    {
        var l = Buf.init(a);
        try tarMeta(&l, 'g', "pax_global_header", try paxRecord(a, "comment", "hello"));
        try tarEntry(&l, mojoc);
        try tarEntry(&l, mopm);
        try l.appendNTimes(0, 1024);
        try g.pkg("tar_pax_global_header_ignored", "ok", "a global pax header (ignored)", .{ .pkg_tar = l.items }, none);
    }
    {
        var l = Buf.init(a);
        try tarEntry(&l, mojoc);
        try tarEntry(&l, mopm);
        try tarMeta(&l, 'L', "././@LongLink", "info/licenses/orphan\x00");
        try l.appendNTimes(0, 1024);
        try g.pkg("tar_ends_after_long_name", "tar_header", "the end marker right after a GNU long-name header", .{ .pkg_tar = l.items }, none);
    }
    // Entry types.
    inline for (.{
        .{ "tar_symlink", "symlink", '2', "a symbolic link" },
        .{ "tar_hardlink", "hardlink", '1', "a hard link" },
        .{ "tar_char_device", "special_file", '3', "a character device" },
        .{ "tar_block_device", "special_file", '4', "a block device" },
        .{ "tar_fifo", "special_file", '6', "a FIFO" },
        .{ "tar_contiguous_file", "special_file", '7', "a contiguous file (type 7)" },
        .{ "tar_sparse_file", "special_file", 'S', "a sparse file (type S)" },
        .{ "tar_unknown_type", "tar_header", 'Z', "an unknown entry type" },
    }) |t| {
        try g.pkg(t[0], t[1], t[3], .{ .pkg_extra = &[_]Item{.{ .path = "lib/mojo/link", .typeflag = t[2], .link = "target" }} }, none);
    }
    // Paths.
    inline for (.{
        .{ "path_absolute", "path_absolute", "/etc/passwd", "an absolute path" },
        .{ "path_drive_letter", "path_absolute", "C:/windows/x", "a path that starts with a drive letter" },
        .{ "path_traversal", "path_traversal", "lib/../../escape", "a path that climbs out of the root" },
        .{ "path_traversal_first", "path_traversal", "../lib/mojo/x", "a path that starts with .." },
        .{ "path_backslash", "path_unsafe", "lib\\mojo\\x", "backslashes" },
        .{ "path_control_char", "path_unsafe", "lib/mojo/a\x01b", "a control character" },
        .{ "path_del_char", "path_unsafe", "lib/mojo/a\x7fb", "the DEL character" },
        .{ "path_empty_segment", "path_unsafe", "lib//mojo/x", "an empty segment" },
        .{ "path_dot_segment", "path_unsafe", "lib/./mojo/x", "a dot segment in the middle" },
        .{ "path_not_utf8", "path_unsafe", "lib/mojo/\xff", "a path that is not UTF-8" },
    }) |t| {
        try g.pkg(t[0], t[1], t[3], .{ .pkg_extra = &[_]Item{.{ .path = t[2], .data = "x" }} }, none);
    }
    // Names that are the same file on another filesystem, and layout.
    try g.pkg("collision_duplicate", "duplicate_path", "the same path twice", .{ .info_extra = &[_]Item{ .{ .path = "info/licenses/A", .data = "1" }, .{ .path = "info/licenses/A", .data = "2" } } }, none);
    try g.pkg("collision_case", "unicode_collision", "paths that differ only by case", .{ .info_extra = &[_]Item{ .{ .path = "info/licenses/Readme", .data = "1" }, .{ .path = "info/licenses/README", .data = "2" } } }, none);
    try g.pkg("collision_nfc_nfd", "unicode_collision", "caf\xc3\xa9 in NFC and in NFD", .{ .info_extra = &[_]Item{ .{ .path = "info/licenses/caf\xc3\xa9", .data = "1" }, .{ .path = "info/licenses/cafe\xcc\x81", .data = "2" } } }, none);
    try g.pkg("collision_nfkc_ligature", "unicode_collision", "the ligature U+FB01 and the letters fi (equal under NFKC)", .{ .info_extra = &[_]Item{ .{ .path = "info/licenses/\xef\xac\x81le", .data = "1" }, .{ .path = "info/licenses/file", .data = "2" } } }, none);
    try g.pkg("collision_fullwidth", "unicode_collision", "a full-width letter and its ASCII form", .{ .info_extra = &[_]Item{ .{ .path = "info/licenses/\xef\xbd\x81", .data = "1" }, .{ .path = "info/licenses/a", .data = "2" } } }, none);
    try g.pkg("collision_dir_and_file", "duplicate_path", "a directory and a file of the same path", .{ .info_extra = &[_]Item{ .{ .path = "info/licenses/d", .typeflag = '5' }, .{ .path = "info/licenses/d", .data = "x" } } }, none);
    try g.pkg("layout_bin_dir", "bin_dir", "a file under bin/", .{ .pkg_extra = &[_]Item{.{ .path = "bin/tool", .data = "x" }} }, none);
    try g.pkg("layout_sbin_dir", "bin_dir", "a file under sbin/", .{ .pkg_extra = &[_]Item{.{ .path = "sbin/tool", .data = "x" }} }, none);
    try g.pkg("layout_scripts_dir", "bin_dir", "a file under Scripts/", .{ .pkg_extra = &[_]Item{.{ .path = "Scripts/tool.exe", .data = "x" }} }, none);
    try g.pkg("layout_post_link_script", "link_script", "a post-link script", .{ .pkg_extra = &[_]Item{.{ .path = "lib/mojo/post-link.sh", .data = "x" }} }, none);
    try g.pkg("layout_pre_unlink_bat", "link_script", "a pre-unlink.bat in any directory", .{ .info_extra = &[_]Item{.{ .path = "info/licenses/Pre-Unlink.BAT", .data = "x" }} }, none);
    try g.pkg("layout_info_link_json", "link_script", "info/link.json", .{ .info_extra = &[_]Item{.{ .path = "info/link.json", .data = "{}" }} }, none);
    try g.pkg("layout_etc_conda", "link_script", "a file under etc/conda/", .{ .pkg_extra = &[_]Item{.{ .path = "etc/conda/activate.d/x.sh", .data = "x" }} }, none);
    try g.pkg("layout_unlisted_file", "layout_not_allowed", "a file outside the allow-list", .{ .pkg_extra = &[_]Item{.{ .path = "share/doc/readme", .data = "x" }} }, none);
    try g.pkg("layout_unlisted_dir", "layout_not_allowed", "a directory outside the allow-list", .{ .pkg_extra = &[_]Item{.{ .path = "share/", .typeflag = '5' }} }, none);
    try g.pkg("layout_other_mojoc", "layout_not_allowed", "a .mojoc under another name", .{ .pkg_extra = &[_]Item{.{ .path = "lib/mojo/other.mojoc", .data = "x" }} }, none);
    try g.pkg("layout_lib_subdir_native", "layout_not_allowed", "a library file in a subdirectory of lib/", .{ .pkg_extra = &[_]Item{.{ .path = "lib/sub/libx.so", .data = "x" }} }, none);
}

fn metadataLevel(g: *Gen) !void {
    try g.pkg("meta_mojoc_missing", "mojoc_missing", "the compiled library is not in the package", .{ .drop = &[_][]const u8{"lib/mojo/demo.mojoc"} }, none);
    try g.pkg("meta_manifest_missing", "manifest_missing", "lib/mojo/demo.mopm.json missing", .{ .drop = &[_][]const u8{"lib/mojo/demo.mopm.json"} }, none);
    try g.pkg("meta_index_missing", "index_missing", "info/index.json missing", .{ .drop = &[_][]const u8{"info/index.json"} }, none);
    try g.pkg("meta_manifest_not_json", "manifest_json", "the manifest is not JSON", .{ .mopm = "not json" }, none);
    try g.pkg("meta_manifest_not_object", "manifest_json", "the manifest is a JSON array", .{ .mopm = "[1]" }, none);
    try g.pkg("meta_manifest_invalid_utf8", "manifest_json", "the manifest has an invalid UTF-8 byte", .{ .mopm = "{\"schema\":1,\"name\":\"demo\",\"x\":\"\xff\"}" }, none);
    try g.pkg("meta_manifest_schema_2", "manifest_schema", "schema 2", .{ .mopm = "{\"schema\":2,\"name\":\"demo\"}" }, none);
    try g.pkg("meta_manifest_schema_string", "manifest_schema", "schema \"1\" as a string", .{ .mopm = "{\"schema\":\"1\",\"name\":\"demo\"}" }, none);
    try g.pkg("meta_manifest_name_empty", "manifest_schema", "an empty name", .{ .mopm = "{\"schema\":1,\"name\":\"\"}" }, none);
    try g.pkg("meta_manifest_version_suffix", "manifest_schema", "a version with a pre-release suffix", .{ .mopm = "{\"schema\":1,\"name\":\"demo\",\"version\":\"1.0.0rc1\"}" }, none);
    try g.pkg("meta_manifest_deps_not_array", "manifest_schema", "deps that is an object", .{ .mopm = "{\"schema\":1,\"name\":\"demo\",\"deps\":{}}" }, none);
    try g.pkg("meta_manifest_dep_path_without_range", "manifest_schema", "a dependency with a path and no range", .{ .mopm = "{\"schema\":1,\"name\":\"demo\",\"deps\":[{\"name\":\"x\",\"path\":\"../x\"}]}" }, none);
    try g.pkg("meta_manifest_native_bad_soname", "manifest_schema", "a soname that does not look like lib<name>.<suffix>", .{ .mopm = "{\"schema\":1,\"name\":\"demo\",\"native\":[{\"id\":\"a\",\"soname\":\"x.so\",\"file\":\"../x.so\"}]}" }, none);
    try g.pkg("meta_manifest_native_bad_kind", "manifest_schema", "a native kind that is none of shared, static, both", .{ .mopm = "{\"schema\":1,\"name\":\"demo\",\"native\":[{\"id\":\"a\",\"soname\":\"libx.so\",\"kind\":\"dynamic\",\"file\":\"../libx.so\"}]}" }, none);
    try g.pkg("meta_manifest_native_shared_without_file", "manifest_schema", "a shared library without a file", .{ .mopm = "{\"schema\":1,\"name\":\"demo\",\"native\":[{\"id\":\"a\",\"soname\":\"libx.so\"}]}" }, none);
    try g.pkg("meta_manifest_native_bad_exclusive", "manifest_schema", "a native exclusive group that is not a string", .{ .mopm = "{\"schema\":1,\"name\":\"demo\",\"native\":[{\"id\":\"a\",\"soname\":\"libx.so\",\"file\":\"../libx.so\",\"exclusive\":1}]}" }, none);
    try g.pkg("meta_native_path_climbs", "native_path", "a native file that resolves outside lib/", .{ .mopm = "{\"schema\":1,\"name\":\"demo\",\"native\":[{\"id\":\"a\",\"soname\":\"libx.so\",\"file\":\"../../x/libx.so\"}]}" }, none);
    try g.pkg("meta_native_path_absolute", "native_path", "an absolute native file", .{ .mopm = "{\"schema\":1,\"name\":\"demo\",\"native\":[{\"id\":\"a\",\"soname\":\"libx.so\",\"file\":\"/lib/libx.so\"}]}" }, none);
    try g.pkg("meta_native_name_mismatch", "native_path", "a file name that does not fit the soname", .{
        .mopm = "{\"schema\":1,\"name\":\"demo\",\"native\":[{\"id\":\"a\",\"soname\":\"libx.so.1\",\"file\":\"../liby.so.1\"}]}",
        .pkg_extra = &[_]Item{.{ .path = "lib/liby.so.1", .data = "x" }},
    }, none);
    try g.pkg("meta_native_duplicate_id", "manifest_schema", "two native entries with one id", .{
        .mopm = "{\"schema\":1,\"name\":\"demo\",\"native\":[{\"id\":\"a\",\"soname\":\"libx.so\",\"file\":\"../libx.so\"},{\"id\":\"a\",\"soname\":\"liby.so\",\"file\":\"../liby.so\"}]}",
        .pkg_extra = &[_]Item{ .{ .path = "lib/libx.so", .data = "x" }, .{ .path = "lib/liby.so", .data = "y" } },
    }, none);
    try g.pkg("meta_native_declared_missing", "native_missing", "a declared library that is not in the package", .{
        .mopm = "{\"schema\":1,\"name\":\"demo\",\"native\":[{\"id\":\"a\",\"soname\":\"libx.so\",\"file\":\"../libx.so\"}]}",
    }, none);
    try g.pkg("meta_native_present_undeclared", "native_undeclared", "a library file the metadata does not declare", .{ .pkg_extra = &[_]Item{.{ .path = "lib/libx.so", .data = "x" }} }, none);
    try g.pkg("meta_name_mismatch", "name_mismatch", "the manifest names another package", .{ .mopm = "{\"schema\":1,\"name\":\"other\"}" }, none);
    try g.pkg("meta_manifest_version_mismatch", "version_mismatch", "the manifest version differs from the published one", .{ .mopm = "{\"schema\":1,\"name\":\"demo\",\"version\":\"1.0.1\"}" }, none);
    try g.pkg("meta_index_not_json", "index_invalid", "info/index.json is not JSON", .{ .index = "{" }, none);
    try g.pkg("meta_index_name_mismatch", "name_mismatch", "info/index.json names another package", .{ .index = "{\"name\":\"mojo-other\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":[\"mojo-compiler ==1.0.0\"]}" }, none);
    try g.pkg("meta_index_version_mismatch", "version_mismatch", "info/index.json has another version", .{ .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.1\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":[\"mojo-compiler ==1.0.0\"]}" }, none);
    try g.pkg("meta_index_subdir_mismatch", "subdir_mismatch", "info/index.json says linux-64, the request says noarch", .{ .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"linux-64\",\"depends\":[\"mojo-compiler ==1.0.0\"]}" }, none);
    try g.pkg("meta_index_build_malformed", "index_invalid", "a build string that is not mojo<compiler>_0", .{ .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"py3_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":[\"mojo-compiler ==1.0.0\"]}" }, none);
    try g.pkg("meta_index_build_number_1", "index_invalid", "build_number 1", .{ .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":1,\"subdir\":\"noarch\",\"depends\":[\"mojo-compiler ==1.0.0\"]}" }, none);
    try g.pkg("meta_index_depends_not_array", "index_invalid", "depends that is a string", .{ .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":\"mojo-compiler ==1.0.0\"}" }, none);
    try g.pkg("meta_compiler_missing", "compiler_missing", "depends without the compiler", .{ .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":[]}" }, none);
    try g.pkg("meta_compiler_twice", "compiler_mismatch", "the compiler named twice", .{ .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":[\"mojo-compiler ==1.0.0\",\"mojo-compiler ==1.0.0\"]}" }, none);
    try g.pkg("meta_compiler_other_version", "compiler_mismatch", "a compiler version that is not the build string's", .{ .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":[\"mojo-compiler ==1.0.1\"]}" }, none);
    try g.pkg("meta_compiler_range", "compiler_mismatch", "a compiler range instead of an exact version", .{ .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":[\"mojo-compiler >=1.0.0\"]}" }, none);
    try g.pkg("meta_compiler_extra_spaces", "ok", "the compiler with extra spaces: they are collapsed before the comparison", .{ .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":[\"mojo-compiler   ==1.0.0\"]}" }, none);
    try g.pkg("meta_dependency_not_allowed", "dependency_not_allowed", "a native dependency that is not on the allow-list", .{ .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":[\"mojo-compiler ==1.0.0\",\"libssl >=3\"]}" }, none);
    try g.pkg("meta_dependency_python", "dependency_not_allowed", "a python dependency", .{ .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":[\"mojo-compiler ==1.0.0\",\"python >=3.9\"]}" }, none);
    try g.pkg("meta_deps_missing_from_index", "deps_mismatch", "a manifest dependency that depends does not list", .{ .mopm = "{\"schema\":1,\"name\":\"demo\",\"deps\":[{\"name\":\"http_core\"}]}" }, none);
    try g.pkg("meta_deps_extra_in_index", "deps_mismatch", "a mojo-* dependency in depends that the manifest does not declare", .{ .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":[\"mojo-compiler ==1.0.0\",\"mojo-http_core\"]}" }, none);
    {
        var c = none;
        c.filename = "mojo-demo-1.0.0-mojo1.0.0_1.conda";
        try g.pkg("meta_filename_mismatch", "filename_mismatch", "a file name whose build is not the metadata's", .{}, c);
    }
    {
        var c = none;
        c.manifest_sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
        try g.pkg("meta_manifest_sha256_mismatch", "manifest_sha256_mismatch", "a wrong manifest hash declared at commit", .{}, c);
    }
    {
        var c = none;
        c.version = "1.0";
        c.filename = "mojo-demo-1.0-mojo1.0.0_0.conda";
        try g.pkg("meta_published_version_two_parts", "version_mismatch", "the request says 1.0, which is not a version (three numbers are required): it equals nothing in the archive", .{}, c);
    }
    {
        var c = none;
        c.name = "other";
        c.filename = "mojo-other-1.0.0-mojo1.0.0_0.conda";
        try g.pkg("meta_request_names_another_package", "layout_not_allowed", "the publisher declared another package name than the archive's: the archive's files are not that package's", .{}, c);
    }
    {
        var c = none;
        c.subdir = "linux-64";
        try g.pkg("meta_request_names_another_subdir", "subdir_mismatch", "the publisher declared another subdir than the archive's", .{}, c);
    }
}

fn orderLevel(g: *Gen) !void {
    const a = g.a;
    const stray_pkg = [_]Item{.{ .path = "lib/../x", .data = "x" }};
    // Each case holds two faults; the intent is the rule the TypeScript code reaches first (read from its order of checks).
    try g.pkg("order_traversal_then_mojoc_missing", "path_traversal", "a traversal path, and the mojoc missing: the tar is read before the layout is checked", .{
        .pkg_extra = &stray_pkg,
        .drop = &[_][]const u8{"lib/mojo/demo.mojoc"},
    }, none);
    try g.pkg("order_collision_then_layout", "unicode_collision", "two colliding names, one of them outside the layout: collisions are checked first", .{
        .pkg_extra = &[_]Item{ .{ .path = "share/Readme", .data = "1" }, .{ .path = "share/README", .data = "2" } },
    }, none);
    try g.pkg("order_layout_then_mojoc_missing", "layout_not_allowed", "a file outside the layout and the mojoc missing: classification precedes the presence checks", .{
        .pkg_extra = &[_]Item{.{ .path = "share/x", .data = "x" }},
        .drop = &[_][]const u8{"lib/mojo/demo.mojoc"},
    }, none);
    try g.pkg("order_mojoc_missing_then_manifest_missing", "mojoc_missing", "the mojoc and the manifest both missing", .{ .drop = &[_][]const u8{ "lib/mojo/demo.mojoc", "lib/mojo/demo.mopm.json" } }, none);
    try g.pkg("order_manifest_missing_then_index_missing", "manifest_missing", "the manifest and the index both missing", .{ .drop = &[_][]const u8{ "lib/mojo/demo.mopm.json", "info/index.json" } }, none);
    try g.pkg("order_manifest_json_then_index_json", "manifest_json", "a broken manifest and a broken index: the manifest is parsed first", .{ .mopm = "{", .index = "{" }, none);
    try g.pkg("order_name_then_index_version", "name_mismatch", "a wrong manifest name and a wrong index version: the manifest name is checked first", .{
        .mopm = "{\"schema\":1,\"name\":\"other\"}",
        .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.1\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"noarch\",\"depends\":[\"mojo-compiler ==1.0.0\"]}",
    }, none);
    try g.pkg("order_mopm_version_then_index_subdir", "version_mismatch", "a wrong manifest version and a wrong subdir", .{
        .mopm = "{\"schema\":1,\"name\":\"demo\",\"version\":\"1.0.1\"}",
        .index = "{\"name\":\"mojo-demo\",\"version\":\"1.0.0\",\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"subdir\":\"linux-64\",\"depends\":[\"mojo-compiler ==1.0.0\"]}",
    }, none);
    {
        var c = none;
        c.filename = "mojo-demo-1.0.0-mojo1.0.0_1.conda";
        try g.pkg("order_deps_then_filename", "deps_mismatch", "a deps mismatch and a wrong file name: the dependencies are checked first", .{
            .mopm = "{\"schema\":1,\"name\":\"demo\",\"deps\":[{\"name\":\"http_core\"}]}",
        }, c);
    }
    try g.pkg("order_native_missing_then_undeclared", "native_missing", "a declared library absent and an undeclared one present: declared first", .{
        .mopm = "{\"schema\":1,\"name\":\"demo\",\"native\":[{\"id\":\"a\",\"soname\":\"libx.so\",\"file\":\"../libx.so\"}]}",
        .pkg_extra = &[_]Item{.{ .path = "lib/liby.so", .data = "y" }},
    }, none);
    {
        // Size beats hash beats magic.
        const bytes = try pkgBytes(a, .{});
        var c = withLimits(.{ .max_archive_bytes = @as(u64, bytes.len - 1) });
        c.sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
        try g.raw("order_size_then_hash", "archive_too_large", "an archive over the size limit with a wrong hash: size first", bytes, c);
        var d = none;
        d.sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
        try g.raw("order_hash_then_magic", "sha256_mismatch", "bytes that are not an archive, with a wrong hash declared: the hash is checked first", "not an archive", d);
    }
    {
        // metadata.json is checked before the tars are read.
        try g.pkg("order_metadata_then_tars", "conda_layout", "a bad metadata.json and a bad info tar: metadata.json first", .{
            .conda_meta = "{}",
            .info_tar = "short",
        }, none);
        try g.pkg("order_info_tar_then_pkg_tar", "tar_header", "a bad info tar and a bad pkg tar: the info tar is read first (a traversal in the pkg tar is not reached)", .{
            .info_tar = "short",
            .pkg_extra = &stray_pkg,
        }, none);
        try g.pkg("order_info_stream_then_pkg_stream", "archive_corrupt", "a bad info stream and a decompression bomb in the pkg stream: the info stream is read first", .{ .info_stream = "x", .pkg_stream = try zstRle(a, 0x41, 3_000_000) }, none);
    }
    try g.pkg("order_symlink_then_traversal", "symlink", "a symlink entry before a traversal entry: first entry wins", .{
        .pkg_extra = &[_]Item{ .{ .path = "lib/mojo/l", .typeflag = '2', .link = "x" }, .{ .path = "lib/../x", .data = "x" } },
    }, none);
    try g.pkg("order_traversal_then_symlink", "path_traversal", "a traversal entry before a symlink entry: first entry wins", .{
        .pkg_extra = &[_]Item{ .{ .path = "lib/../x", .data = "x" }, .{ .path = "lib/mojo/l", .typeflag = '2', .link = "x" } },
    }, none);
}

fn boundaries(g: *Gen) !void {
    const a = g.a;
    // Each limit at cap - 1, cap and cap + 1 on one archive. The sizes are measured here, from the bytes.

    // The archive size.
    {
        const bytes = try pkgBytes(a, .{});
        const n: u64 = bytes.len;
        try g.raw("limit_archive_below", "archive_too_large", "the archive is one byte over the limit", bytes, withLimits(.{ .max_archive_bytes = n - 1 }));
        try g.again("limit_archive_at", "ok", "the archive is exactly the limit", "limit_archive_below.conda", withLimits(.{ .max_archive_bytes = n }));
        try g.again("limit_archive_above", "ok", "the limit is one byte over the archive", "limit_archive_below.conda", withLimits(.{ .max_archive_bytes = n + 1 }));
    }
    // The unpacked total as the zip reader sees it: the sum of the entries' declared sizes.
    {
        const es = try pkgEntries(a, .{});
        var z: u64 = 0;
        for (es) |e| z += e.data.len;
        try g.pkg("limit_unpacked_below", "unpacked_too_large", "the zip entries together are one byte over the unpacked limit", .{}, withLimits(.{ .max_unpacked_bytes = z - 1 }));
        try g.again("limit_unpacked_at", "ok", "the zip entries together are exactly the unpacked limit", "limit_unpacked_below.conda", withLimits(.{ .max_unpacked_bytes = z }));
        try g.again("limit_unpacked_above", "ok", "one byte under the unpacked limit", "limit_unpacked_below.conda", withLimits(.{ .max_unpacked_bytes = z + 1 }));
    }
    // One file of the tar.
    {
        const big = try a.alloc(u8, 1000);
        @memset(big, 'm');
        try g.pkg("limit_file_below", "file_too_large", "a tar entry of 1000 bytes under a limit of 999", .{ .mojoc = big }, withLimits(.{ .max_file_bytes = 999 }));
        try g.again("limit_file_at", "ok", "a tar entry of exactly the limit", "limit_file_below.conda", withLimits(.{ .max_file_bytes = 1000 }));
        try g.again("limit_file_above", "ok", "a tar entry one byte under the limit", "limit_file_below.conda", withLimits(.{ .max_file_bytes = 1001 }));
    }
    // The number of entries (files and directories, over both tars): lib/mojo/demo.mojoc, the manifest, index.json, LICENSE.
    {
        try g.pkg("limit_files_below", "too_many_files", "four entries under a limit of three", .{}, withLimits(.{ .max_files = 3 }));
        try g.again("limit_files_at", "ok", "four entries under a limit of four", "limit_files_below.conda", withLimits(.{ .max_files = 4 }));
        try g.again("limit_files_above", "ok", "four entries under a limit of five", "limit_files_below.conda", withLimits(.{ .max_files = 5 }));
    }
    // The size of each metadata file: the larger of the two is the manifest or the index.
    {
        const m: u64 = @max(DEFAULT_MOPM.len, DEFAULT_INDEX.len);
        try g.pkg("limit_metadata_below", "manifest_too_large", "the larger metadata file is one byte over the limit", .{}, withLimits(.{ .max_metadata_bytes = m - 1 }));
        try g.again("limit_metadata_at", "ok", "the larger metadata file is exactly the limit", "limit_metadata_below.conda", withLimits(.{ .max_metadata_bytes = m }));
        try g.again("limit_metadata_above", "ok", "the limit is one byte over the larger metadata file", "limit_metadata_below.conda", withLimits(.{ .max_metadata_bytes = m + 1 }));
    }
    // The expansion ratio of a zstd stream: 4000 bytes from a stream of 10 bytes (6 of frame header, 4 of block).
    {
        const rle = try zstRle(a, 0x41, 4000);
        try g.pkg("limit_ratio_below", "compression_ratio", "4000 bytes from 10: ratio 400 under a limit of 399", .{ .pkg_stream = rle }, withLimits(.{ .max_ratio = 399, .ratio_floor_bytes = 100 }));
        try g.again("limit_ratio_at", "tar_header", "4000 bytes from 10 under a limit of 400: the guard is not tripped, the tar reader refuses the bytes", "limit_ratio_below.conda", withLimits(.{ .max_ratio = 400, .ratio_floor_bytes = 100 }));
        try g.again("limit_ratio_above", "tar_header", "4000 bytes from 10 under a limit of 401", "limit_ratio_below.conda", withLimits(.{ .max_ratio = 401, .ratio_floor_bytes = 100 }));
        try g.again("limit_ratio_floor_at", "tar_header", "the same stream where the floor equals its size: below the floor nothing is judged by ratio", "limit_ratio_below.conda", withLimits(.{ .max_ratio = 1, .ratio_floor_bytes = 4000 }));
        try g.again("limit_ratio_floor_below", "compression_ratio", "the floor one byte under the stream's size", "limit_ratio_below.conda", withLimits(.{ .max_ratio = 1, .ratio_floor_bytes = 3999 }));
    }
}

// ---- cases.json ---------------------------------------------------------------------------------

fn jstr(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        0...9, 11...31 => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn jlimits(w: anytype, l: Limits) !void {
    try w.writeAll("{");
    var first = true;
    inline for (std.meta.fields(Limits)) |f| {
        if (@field(l, f.name)) |v| {
            if (!first) try w.writeAll(", ");
            first = false;
            try w.print("\"{s}\": {d}", .{ f.name, v });
        }
    }
    try w.writeAll("}");
}

/// cases.json: one object per case, in the order the cases were made.
pub fn casesJson(a: Allocator, c: Corpus) ![]u8 {
    var l = Buf.init(a);
    const w = l.writer();
    try w.writeAll("{\n  \"format\": 1,\n  \"cases\": [\n");
    for (c.cases, 0..) |k, i| {
        try w.writeAll("    {\n      \"id\": ");
        try jstr(w, k.id);
        try w.writeAll(",\n      \"archive\": ");
        try jstr(w, k.archive);
        try w.writeAll(",\n      \"intent\": ");
        try jstr(w, k.intent);
        try w.writeAll(",\n      \"what\": ");
        try jstr(w, k.what);
        try w.writeAll(",\n      \"expect\": {\"name\": ");
        try jstr(w, k.name);
        try w.writeAll(", \"version\": ");
        try jstr(w, k.version);
        try w.writeAll(", \"subdir\": ");
        try jstr(w, k.subdir);
        try w.writeAll(", \"filename\": ");
        try jstr(w, k.filename);
        if (k.sha256) |s| {
            try w.writeAll(", \"sha256\": ");
            try jstr(w, s);
        }
        if (k.manifest_sha256) |s| {
            try w.writeAll(", \"manifest_sha256\": ");
            try jstr(w, s);
        }
        try w.writeAll("},\n      \"limits\": ");
        try jlimits(w, k.limits);
        try w.writeAll(",\n      \"allow_native\": [");
        for (k.allow_native, 0..) |n, j| {
            if (j > 0) try w.writeAll(", ");
            try jstr(w, n);
        }
        try w.writeAll("],\n      \"note\": ");
        try jstr(w, k.note);
        try w.writeAll("\n    }");
        try w.writeAll(if (i + 1 < c.cases.len) ",\n" else "\n");
    }
    try w.writeAll("  ]\n}\n");
    return l.items;
}

// ---- writing the corpus to a directory -------------------------------------------------------------

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len != 2) {
        std.debug.print("usage: validator_corpus <directory>   (writes <directory>/cases.json and <directory>/archives/*)\n", .{});
        std.process.exit(2);
    }
    const corpus = try build(a);
    var root = try std.fs.cwd().makeOpenPath(args[1], .{});
    defer root.close();
    try root.makePath("archives");
    var arch = try root.openDir("archives", .{});
    defer arch.close();
    for (corpus.archives) |x| {
        const f = try arch.createFile(x.name, .{});
        defer f.close();
        try f.writeAll(x.bytes);
    }
    const f = try root.createFile("cases.json", .{});
    defer f.close();
    try f.writeAll(try casesJson(a, corpus));
}
