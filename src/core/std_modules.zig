//! The top-level modules of the Mojo standard library (docs/design/namespaces.md, section 1.1): no package's import
//! name may be one, since Mojo code imports them as `std.<module>` and also by the bare name.
//!
//! `toolchain/mojo-<version>.std-modules.txt` holds one Mojo version's modules, one per line, read from the
//! `lib/mojo/std.mojoc` of that version's pinned mojo-compiler package by `mopm-closure --std-modules`
//! (tools/closure_gen.zig). `src/core/toolchain/std-modules.txt`, which mopm embeds, is the union over every version
//! of `toolchain/versions.txt`, written by the same command; a unit test holds it to that union.

const std = @import("std");
const Allocator = std.mem.Allocator;
const closure = @import("closure.zig");
const conda_unpack = @import("conda_unpack.zig");

/// The prefix of a source path of the standard library, as `std.mojoc` records it.
const source_prefix = "mojo/stdlib/std/";
const zstd_magic = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd };
/// The most a `std.mojoc`'s frame may decompress to (1.0.0's is under 8 MiB).
const max_content: usize = 256 << 20;

pub const Error = error{ NotMojoc, NoModules } || Allocator.Error;

/// The top-level modules recorded in the `std.mojoc` `bytes`, sorted, without repeats: the `<module>` of every source
/// path `mojo/stdlib/std/<module>/...` or `mojo/stdlib/std/<module>.mojo`, except names starting with `_` (outside
/// the name grammar). The file is `MPKG`, a header, and one zstd frame; `window` is a zstd window buffer
/// (`conda_unpack.window_size` bytes). `why` says what is wrong on an error.
pub fn fromMojoc(arena: Allocator, bytes: []const u8, window: []u8, why: *[]const u8) Error![]const []const u8 {
    if (!std.mem.startsWith(u8, bytes, "MPKG")) {
        why.* = "the file does not start with MPKG: not a .mojoc";
        return error.NotMojoc;
    }
    const at = std.mem.indexOfPos(u8, bytes, 4, &zstd_magic) orelse {
        why.* = "the .mojoc holds no zstd frame";
        return error.NotMojoc;
    };
    var fbs = std.io.fixedBufferStream(bytes[at..]);
    var zs = std.compress.zstd.decompressor(fbs.reader(), .{ .window_buffer = window });
    const content = zs.reader().readAllAlloc(arena, max_content) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            why.* = try std.fmt.allocPrint(arena, "the .mojoc's zstd frame cannot be read: {s}", .{@errorName(e)});
            return error.NotMojoc;
        },
    };
    const modules = try modulesOf(arena, content);
    if (modules.len == 0) {
        why.* = "the .mojoc records no source path " ++ source_prefix ++ "<module>";
        return error.NoModules;
    }
    return modules;
}

/// The modules named by the source paths in `content`, sorted, without repeats.
pub fn modulesOf(arena: Allocator, content: []const u8) Allocator.Error![]const []const u8 {
    var found = std.ArrayList([]const u8).init(arena);
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, content, from, source_prefix)) |i| {
        const start = i + source_prefix.len;
        var end = start;
        while (end < content.len and (std.ascii.isAlphanumeric(content[end]) or content[end] == '_')) end += 1;
        from = end;
        if (end == start or content[start] == '_') continue;
        const rest = content[end..];
        const is_dir = std.mem.startsWith(u8, rest, "/");
        const is_file = std.mem.startsWith(u8, rest, ".mojo");
        if (!is_dir and !is_file) continue;
        try found.append(content[start..end]);
    }
    return sortedUnique(arena, found.items);
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn sortedUnique(arena: Allocator, items: []const []const u8) Allocator.Error![]const []const u8 {
    const all = try arena.dupe([]const u8, items);
    std.mem.sort([]const u8, all, {}, lessStr);
    var out = std.ArrayList([]const u8).init(arena);
    for (all) |m| {
        if (out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1], m)) continue;
        try out.append(m);
    }
    return out.items;
}

/// The lines of `text` that are neither empty nor `#` comments, trimmed.
pub fn entries(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out = std.ArrayList([]const u8).init(arena);
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try out.append(line);
    }
    return out.items;
}

/// One version's file, `toolchain/mojo-<version>.std-modules.txt`: one module per line.
pub fn renderVersion(arena: Allocator, modules: []const []const u8) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).init(arena);
    for (modules) |m| {
        try out.appendSlice(m);
        try out.append('\n');
    }
    return out.items;
}

const union_header =
    \\# The top-level modules of the Mojo standard library, the union over every Mojo version of toolchain/versions.txt
    \\# (one toolchain/mojo-<version>.std-modules.txt each). No package's import name may be one (src/core/names.zig).
    \\# Written by `mopm-closure --std-modules`, never by hand (toolchain/README.md).
    \\
;

/// `src/core/toolchain/std-modules.txt`: the header, then the union of `versions` (each a version file's text),
/// sorted, one module per line.
pub fn renderUnion(arena: Allocator, versions: []const []const u8) Allocator.Error![]u8 {
    var all = std.ArrayList([]const u8).init(arena);
    for (versions) |text| try all.appendSlice(try entries(arena, text));
    var out = std.ArrayList(u8).init(arena);
    try out.appendSlice(union_header);
    try out.appendSlice(try renderVersion(arena, try sortedUnique(arena, all.items)));
    return out.items;
}

/// The Mojo versions of `toolchain/versions.txt`.
pub fn versionsOf(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    return entries(arena, text);
}

/// `mopm-closure --std-modules`: for each version of `toolchain_dir/versions.txt`, the linux-64 mojo-compiler that
/// `closure_dir/mojo-<version>-linux-64.json` pins is got through `fetcher` (`bytesOf(arena, file, url, sha256,
/// size) ![]const u8`), checked against its pinned size and sha256, and its `lib/mojo/std.mojoc` read; the version's
/// modules are written to `toolchain_dir/mojo-<version>.std-modules.txt`, and their union to
/// `closure_dir/std-modules.txt`. The answer is the number of versions; on `error.Refused`, `why` names the file and
/// the reason, and the union is not written.
pub fn regenerate(arena: Allocator, closure_dir: std.fs.Dir, toolchain_dir: std.fs.Dir, window: []u8, fetcher: anytype, why: *[]const u8) RegenError!usize {
    const versions = toolchain_dir.readFileAlloc(arena, "versions.txt", 1 << 16) catch |e| return refuse(arena, why, "versions.txt: {s}", .{@errorName(e)});
    var texts = std.ArrayList([]const u8).init(arena);
    for (try versionsOf(arena, versions)) |ver| {
        const name = try std.fmt.allocPrint(arena, "mojo-{s}-linux-64.json", .{ver});
        const text = closure_dir.readFileAlloc(arena, name, 16 << 20) catch |e| return refuse(arena, why, "{s}: {s}", .{ name, @errorName(e) });
        const c = closure.parse(arena, text) catch |e| return refuse(arena, why, "{s}: {s}", .{ name, @errorName(e) });
        var compiler: ?closure.Package = null;
        for (c.packages) |q| {
            if (std.mem.eql(u8, q.name, "mojo-compiler")) compiler = q;
        }
        const p = compiler orelse return refuse(arena, why, "{s} pins no mojo-compiler", .{name});
        const file = closure.fileName(p);
        const url = closure.urlOf(arena, c, p) catch |e| return refuse(arena, why, "{s}: {s}: {s}", .{ name, file, @errorName(e) });
        const bytes = fetcher.bytesOf(arena, file, url, p.sha256, p.size) catch |e| return refuse(arena, why, "{s}: {s}", .{ url, @errorName(e) });
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (bytes.len != p.size or !std.mem.eql(u8, &hex, p.sha256)) {
            return refuse(arena, why, "{s} is {d} bytes with sha256 {s}, but {s} pins {d} bytes with sha256 {s}", .{ file, bytes.len, &hex, name, p.size, p.sha256 });
        }
        var unpack_diag = conda_unpack.Diag{};
        const found = conda_unpack.readFilesLimited(arena, bytes, window, &.{"lib/mojo/std.mojoc"}, .{ .total = 4 << 30 }, &unpack_diag) catch |e| return refuse(arena, why, "{s}: {s}: {s}", .{ file, @errorName(e), unpack_diag.message });
        const mojoc = found[0] orelse return refuse(arena, why, "{s} holds no lib/mojo/std.mojoc", .{file});
        var mojoc_why: []const u8 = "";
        const modules = fromMojoc(arena, mojoc, window, &mojoc_why) catch |e| return refuse(arena, why, "{s}: lib/mojo/std.mojoc: {s}: {s}", .{ file, @errorName(e), mojoc_why });
        const out_text = try renderVersion(arena, modules);
        const out_name = try std.fmt.allocPrint(arena, "mojo-{s}.std-modules.txt", .{ver});
        toolchain_dir.writeFile(out_name, out_text) catch |e| return refuse(arena, why, "{s}: {s}", .{ out_name, @errorName(e) });
        try texts.append(out_text);
    }
    if (texts.items.len == 0) return refuse(arena, why, "versions.txt names no Mojo version", .{});
    closure_dir.writeFile("std-modules.txt", try renderUnion(arena, texts.items)) catch |e| return refuse(arena, why, "std-modules.txt: {s}", .{@errorName(e)});
    return texts.items.len;
}

pub const RegenError = error{Refused} || Allocator.Error;

fn refuse(arena: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) RegenError {
    why.* = try std.fmt.allocPrint(arena, fmt, args);
    return error.Refused;
}

const testing = std.testing;
const conda = @import("conda.zig");
const conda_fixture = @import("conda_fixture.zig");
const testroot = @import("testroot.zig");

/// A `std.mojoc` holding `content`: `MPKG`, a 92-byte header, then the content as one zstd frame.
fn fakeMojoc(a: Allocator, content: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice("MPKG");
    try out.appendNTimes('0', 92);
    try out.appendSlice(try conda.zstdStore(a, content));
    return out.items;
}

test "the modules of a std.mojoc are the first component of its std source paths, sorted, once each" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const window = try a.alloc(u8, conda_unpack.window_size);
    const content = "\x00oss/modular/mojo/stdlib/std/collections/dict.mojo\x01" ++
        "oss/modular/mojo/stdlib/std/os/path/path.mojo\x02" ++
        "oss/modular/mojo/stdlib/std/collections/list.mojo\x00" ++
        // A module that is one file, the package's own __init__ and a private package: one module, two left out.
        "oss/modular/mojo/stdlib/std/origin.mojo\x00oss/modular/mojo/stdlib/std/__init__.mojo\x00" ++
        "oss/modular/mojo/stdlib/std/_plugin/x.mojo\x00" ++
        // A prefix with no module after it, and a name that is neither a directory nor a .mojo file.
        "mojo/stdlib/std/\x00mojo/stdlib/std/notes.txt\x00";
    var why: []const u8 = "";
    const got = try fromMojoc(a, try fakeMojoc(a, content), window, &why);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("collections", got[0]);
    try testing.expectEqualStrings("origin", got[1]);
    try testing.expectEqualStrings("os", got[2]);
    try testing.expectEqualStrings("collections\norigin\nos\n", try renderVersion(a, got));
}

test "a file that is not a .mojoc, has no frame, a broken frame, or no std source path is refused, saying why" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const window = try a.alloc(u8, conda_unpack.window_size);
    var why: []const u8 = "";
    try testing.expectError(error.NotMojoc, fromMojoc(a, "PK\x03\x04", window, &why));
    try testing.expectEqualStrings("the file does not start with MPKG: not a .mojoc", why);
    try testing.expectError(error.NotMojoc, fromMojoc(a, "MPKG" ++ "0" ** 92, window, &why));
    try testing.expectEqualStrings("the .mojoc holds no zstd frame", why);
    try testing.expectError(error.NotMojoc, fromMojoc(a, "MPKG\x28\xb5\x2f\xfd\xff\xff\xff\xff", window, &why));
    try testing.expect(std.mem.startsWith(u8, why, "the .mojoc's zstd frame cannot be read: "));
    try testing.expectError(error.NoModules, fromMojoc(a, try fakeMojoc(a, "mojo/stdlib/other/x.mojo"), window, &why));
    try testing.expectEqualStrings("the .mojoc records no source path mojo/stdlib/std/<module>", why);
}

test "the union is every version's modules once, sorted, under the header" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const got = try renderUnion(a, &.{ "os\nsys\n", "atomic\nos\n\n" });
    try testing.expectEqualStrings(union_header ++ "atomic\nos\nsys\n", got);
    try testing.expectEqual(@as(usize, 3), (try entries(a, got)).len);
}

test "the embedded list is the union of the list of every version of toolchain/versions.txt" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const versions = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, "toolchain/versions.txt"), 1 << 16);
    var texts = std.ArrayList([]const u8).init(a);
    for (try versionsOf(a, versions)) |v| {
        const file = try std.fmt.allocPrint(a, "toolchain/mojo-{s}.std-modules.txt", .{v});
        const text = std.fs.cwd().readFileAlloc(a, try testroot.path(a, file), 1 << 16) catch |e| {
            std.debug.print("{s}: {s}; run mopm-closure --std-modules src/core/toolchain toolchain\n", .{ file, @errorName(e) });
            return e;
        };
        try texts.append(text);
    }
    try testing.expect(texts.items.len > 0);
    const want = try renderUnion(a, texts.items);
    const embedded = @embedFile("toolchain/std-modules.txt");
    if (!std.mem.eql(u8, want, embedded)) {
        std.debug.print("src/core/toolchain/std-modules.txt is not the union of the toolchain/mojo-<version>.std-modules.txt files; run mopm-closure --std-modules src/core/toolchain toolchain\n", .{});
        return error.TestUnexpectedResult;
    }
}

/// The fetcher of the tests: the bytes it was given, whatever is asked, and the url it was asked for.
const FakeFetcher = struct {
    bytes: []const u8,
    fail: bool = false,
    asked: []const u8 = "",

    pub fn bytesOf(self: *FakeFetcher, arena: Allocator, file: []const u8, url: []const u8, sha256: []const u8, size: u64) ![]const u8 {
        _ = sha256;
        _ = size;
        self.asked = try std.fmt.allocPrint(arena, "{s} {s}", .{ file, url });
        if (self.fail) return error.DownloadFailed;
        return self.bytes;
    }
};

/// A closure file pinning `compiler` (the package's bytes) as the mojo-compiler of mojo 1.0.0, or no compiler.
fn closureJson(a: Allocator, compiler: ?[]const u8) ![]u8 {
    const pkgs = if (compiler) |bytes|
        try std.fmt.allocPrint(a, "{{\"name\": \"mojo-compiler\", \"version\": \"1.0.0\", \"build\": \"release\", \"subdir\": \"linux-64\", \"channel\": \"max\", \"path\": \"linux-64/mojo-compiler-1.0.0-release.conda\", \"sha256\": \"{s}\", \"size\": {d}}}", .{ try conda_fixture.sha256Hex(a, bytes), bytes.len })
    else
        "";
    return std.fmt.allocPrint(a, "{{\"mojo\": \"1.0.0\", \"subdir\": \"linux-64\", \"channels\": [{{\"name\": \"max\", \"url\": \"https://conda.example/max/\"}}], \"packages\": [{s}]}}", .{pkgs});
}

test "--std-modules writes each version's list and the union from the pinned mojo-compiler, and refuses what does not check out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const window = try a.alloc(u8, conda_unpack.window_size);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cdir = try tmp.dir.makeOpenPath("closures", .{});
    defer cdir.close();
    var tdir = try tmp.dir.makeOpenPath("toolchain", .{});
    defer tdir.close();
    try tdir.writeFile("versions.txt", "# the versions\n1.0.0\n");

    const mojoc = try fakeMojoc(a, "oss/modular/mojo/stdlib/std/os/path.mojo\x00oss/modular/mojo/stdlib/std/collections/list.mojo");
    const pkg = try conda_fixture.simple(a, "mojo-compiler", "1.0.0", &.{.{ .name = "lib/mojo/std.mojoc", .data = mojoc }});
    try cdir.writeFile("mojo-1.0.0-linux-64.json", try closureJson(a, pkg));
    var why: []const u8 = "";
    var good = FakeFetcher{ .bytes = pkg };
    try testing.expectEqual(@as(usize, 1), try regenerate(a, cdir, tdir, window, &good, &why));
    try testing.expectEqualStrings("mojo-compiler-1.0.0-release.conda https://conda.example/max/linux-64/mojo-compiler-1.0.0-release.conda", good.asked);
    try testing.expectEqualStrings("collections\nos\n", try tdir.readFileAlloc(a, "mojo-1.0.0.std-modules.txt", 1 << 16));
    try testing.expectEqualStrings(union_header ++ "collections\nos\n", try cdir.readFileAlloc(a, "std-modules.txt", 1 << 16));

    // Other bytes than the pin: refused, naming both, and nothing more is written.
    try cdir.deleteFile("std-modules.txt");
    var other = FakeFetcher{ .bytes = "not the package" };
    try testing.expectError(error.Refused, regenerate(a, cdir, tdir, window, &other, &why));
    const want = try std.fmt.allocPrint(a, "mojo-compiler-1.0.0-release.conda is 15 bytes with sha256 {s}, but mojo-1.0.0-linux-64.json pins {d} bytes with sha256 {s}", .{ try conda_fixture.sha256Hex(a, "not the package"), pkg.len, try conda_fixture.sha256Hex(a, pkg) });
    try testing.expectEqualStrings(want, why);
    try testing.expectError(error.FileNotFound, cdir.access("std-modules.txt", .{}));

    var down = FakeFetcher{ .bytes = pkg, .fail = true };
    try testing.expectError(error.Refused, regenerate(a, cdir, tdir, window, &down, &why));
    try testing.expectEqualStrings("https://conda.example/max/linux-64/mojo-compiler-1.0.0-release.conda: DownloadFailed", why);

    // A package without the library, and one whose library is not a .mojoc.
    const empty = try conda_fixture.simple(a, "mojo-compiler", "1.0.0", &.{.{ .name = "lib/other.txt", .data = "x" }});
    try cdir.writeFile("mojo-1.0.0-linux-64.json", try closureJson(a, empty));
    var no_lib = FakeFetcher{ .bytes = empty };
    try testing.expectError(error.Refused, regenerate(a, cdir, tdir, window, &no_lib, &why));
    try testing.expectEqualStrings("mojo-compiler-1.0.0-release.conda holds no lib/mojo/std.mojoc", why);
    const junk = try conda_fixture.simple(a, "mojo-compiler", "1.0.0", &.{.{ .name = "lib/mojo/std.mojoc", .data = "junk" }});
    try cdir.writeFile("mojo-1.0.0-linux-64.json", try closureJson(a, junk));
    var bad_lib = FakeFetcher{ .bytes = junk };
    try testing.expectError(error.Refused, regenerate(a, cdir, tdir, window, &bad_lib, &why));
    try testing.expectEqualStrings("mojo-compiler-1.0.0-release.conda: lib/mojo/std.mojoc: NotMojoc: the file does not start with MPKG: not a .mojoc", why);

    // A closure that pins no compiler, a version with no closure, and no version at all.
    try cdir.writeFile("mojo-1.0.0-linux-64.json", try closureJson(a, null));
    try testing.expectError(error.Refused, regenerate(a, cdir, tdir, window, &good, &why));
    try testing.expectEqualStrings("mojo-1.0.0-linux-64.json pins no mojo-compiler", why);
    try tdir.writeFile("versions.txt", "1.0.0\n9.9.9\n");
    try cdir.writeFile("mojo-1.0.0-linux-64.json", try closureJson(a, pkg));
    try testing.expectError(error.Refused, regenerate(a, cdir, tdir, window, &good, &why));
    try testing.expectEqualStrings("mojo-9.9.9-linux-64.json: FileNotFound", why);
    try tdir.writeFile("versions.txt", "# none\n");
    try testing.expectError(error.Refused, regenerate(a, cdir, tdir, window, &good, &why));
    try testing.expectEqualStrings("versions.txt names no Mojo version", why);
}
