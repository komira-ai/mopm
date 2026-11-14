//! The top-level modules of the Mojo standard library (docs/design/namespaces.md, section 1.1): no package's import
//! name may be one, since Mojo code imports them as `std.<module>` and also by the bare name.
//!
//! `toolchain/mojo-<version>.std-modules.txt` holds one Mojo version's modules, one per line, read from the
//! `lib/mojo/std.mojoc` of that version's pinned mojo-compiler package by `mopm-closure --std-modules`
//! (tools/closure_gen.zig). `src/core/toolchain/std-modules.txt`, which mopm embeds, is the union over every version
//! of `toolchain/versions.txt`, written by the same command; a unit test holds it to that union.

const std = @import("std");
const Allocator = std.mem.Allocator;

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

const testing = std.testing;
const conda = @import("conda.zig");
const conda_unpack = @import("conda_unpack.zig");
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
