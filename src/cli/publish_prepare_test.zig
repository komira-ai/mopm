//! Tests of what `prepare` (publish_cmd.zig) refuses before it packs anything: a manifest or a path dependency's manifest that
//! cannot be used, a version or compiler that cannot be packed, dependencies, natives and programs that cannot be shipped, and
//! `.mojoc` files that are missing, empty or too many or too big to publish. Each case is written to a temporary directory;
//! `prepare` says why on standard error and returns null.

const std = @import("std");
const Allocator = std.mem.Allocator;
const publish_cmd = @import("publish_cmd.zig");

const head = "[package]\nname = \"example/demo\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n";

const Fx = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,

    fn init(a: Allocator) !Fx {
        const tmp = std.testing.tmpDir(.{});
        return .{ .tmp = tmp, .root = try tmp.dir.realpathAlloc(a, ".") };
    }

    fn put(fx: Fx, rel: []const u8, bytes: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try fx.tmp.dir.makePath(d);
        try fx.tmp.dir.writeFile(rel, bytes);
    }

    /// A package at pkg/ with the manifest `text` and a one-file `.mojoc` for noarch.
    fn package(fx: Fx, text: []const u8) !void {
        try fx.put("pkg/mopm.toml", text);
        try fx.put("demo.mojoc", "the mojoc");
    }

    fn flags(fx: Fx, a: Allocator, compiler: []const u8) !publish_cmd.Flags {
        return .{
            .compiler = compiler,
            .manifest = try std.fs.path.join(a, &.{ fx.root, "pkg/mopm.toml" }),
            .mojoc = try a.dupe(publish_cmd.Mojoc, &.{.{ .subdir = "noarch", .path = try std.fs.path.join(a, &.{ fx.root, "demo.mojoc" }) }}),
        };
    }
};

/// `prepare` of the package `text` with a good `.mojoc` and compiler 1.0.0 for `cmd`.
fn refused(cmd: publish_cmd.Cmd, text: []const u8) !void {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.package(text);
    try std.testing.expect((try publish_cmd.prepare(a, cmd, try fx.flags(a, "1.0.0"))) == null);
}

test "a package with a manifest of that name packs, so the refusals below are the only cause" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.package(head);
    const prep = (try publish_cmd.prepare(a, .publish, try fx.flags(a, "1.0.0"))).?;
    try std.testing.expectEqual(@as(usize, 1), prep.packs.len);
}

test "a manifest that cannot be read is refused before anything is packed" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.put("demo.mojoc", "the mojoc");
    try std.testing.expect((try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.0.0"))) == null);
}

test "a manifest that is not valid is refused, whether the parser points at a line or only names the error" {
    try refused(.pack, "[package]\nname = \"example/demo\"\n");
    try refused(.pack, "[package\n");
    // Not UTF-8 text: the parser has no position to give.
    try refused(.pack, "[package]\nname = \"example/demo\xff\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n");
}

test "a package with publish = false is not packed" {
    try refused(.pack, head ++ "publish = false\n");
}

test "a version that is not exactly MAJOR.MINOR.PATCH is refused" {
    try refused(.pack, "[package]\nname = \"example/demo\"\nversion = \"1.0\"\nmojo = [\"1.0.0\"]\n");
}

test "a compiler that is not an exact Mojo version is refused" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.package(head);
    try std.testing.expect((try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.0.0-rc.1"))) == null);
}

test "a path dependency whose manifest cannot be read is refused" {
    try refused(.pack, head ++ "\n[dependencies]\n\"example/dep\" = { version = \"^1.0\", path = \"../dep\" }\n");
}

test "a path dependency whose manifest is not valid is refused, with a position or without" {
    const deps = head ++ "\n[dependencies]\n\"example/dep\" = { version = \"^1.0\", path = \"../dep\" }\n";
    inline for (.{ "[package]\n", "[package\n", "[package]\nname = \"example/dep\xff\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n" }) |dep| {
        var st = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer st.deinit();
        const a = st.allocator();
        var fx = try Fx.init(a);
        defer fx.tmp.cleanup();
        try fx.package(deps);
        try fx.put("dep/mopm.toml", dep);
        try std.testing.expect((try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.0.0"))) == null);
    }
}

test "a path dependency that is another package than the one it is named is refused" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.package(head ++ "\n[dependencies]\n\"example/dep\" = { version = \"^1.0\", path = \"../dep\" }\n");
    try fx.put("dep/mopm.toml", "[package]\nname = \"example/other\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n");
    try std.testing.expect((try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.0.0"))) == null);
}

test "a path dependency with publish = false is refused, and one that is published is packed as a dependency" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.package(head ++ "\n[dependencies]\n\"example/dep\" = { version = \"^1.0\", path = \"../dep\" }\n");
    const dep = "[package]\nname = \"example/dep\"\nversion = \"1.2.0\"\nmojo = [\"1.0.0\"]\n";
    try fx.put("dep/mopm.toml", dep ++ "publish = false\n");
    try std.testing.expect((try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.0.0"))) == null);
    try fx.put("dep/mopm.toml", dep);
    try std.testing.expect((try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.0.0"))) != null);
}

test "a dependency that cannot be a conda dependency is refused" {
    try refused(.pack, head ++ "\n[dependencies]\n\"example/dep\" = { path = \"../dep\" }\n");
}

test "a native dependency to link, which is not packed, is refused" {
    try refused(.pack, head ++ "\n[native-dependencies]\nzlib = \">=1.2\"\n");
}

test "a native the --native flags do not match is refused" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.package(head);
    try fx.put("libz.a", "!<arch>\n");
    var f = try fx.flags(a, "1.0.0");
    f.natives = try a.dupe(publish_cmd.NativeFile, &.{.{ .id = "z", .subdir = "linux-64", .path = try std.fs.path.join(a, &.{ fx.root, "libz.a" }) }});
    try std.testing.expect((try publish_cmd.prepare(a, .pack, f)) == null);
}

test "a program of [targets] bins that is not there is refused" {
    try refused(.pack, head ++ "\n[targets]\nbins = [{ name = \"tool\", path = \"tools/tool.mojo\" }]\n");
}

test "a .mojoc that cannot be read is refused" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.put("pkg/mopm.toml", head);
    try std.testing.expect((try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.0.0"))) == null);
}

test "an empty .mojoc is refused" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.package(head);
    try fx.put("demo.mojoc", "");
    try std.testing.expect((try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.0.0"))) == null);
}

test "a package file over the size a publish takes is refused, and a pack of it is not" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.package(head);
    // A .mojoc of max_file_bytes + 1 bytes: a sparse file of zeros in the temporary directory. The package is the .mojoc and a
    // little metadata, so it is over the limit whatever the container does to the bytes it is given, if it does not compress them.
    {
        var file = try fx.tmp.dir.createFile("demo.mojoc", .{});
        defer file.close();
        try file.setEndPos(publish_cmd.max_file_bytes + 1);
    }
    const f = try fx.flags(a, "1.0.0");
    try std.testing.expect((try publish_cmd.prepare(a, .publish, f)) == null);
    try std.testing.expect((try publish_cmd.prepare(a, .pack, f)) != null);
}

test "a version of more files than a publish takes is refused, and a pack of them is not" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.package(head);
    var f = try fx.flags(a, "1.0.0");
    // `prepare` takes the entries as they are, so one subdir repeated stands for max_files + 1 builds.
    const entries = try a.alloc(publish_cmd.Mojoc, publish_cmd.max_files + 1);
    for (entries) |*e| e.* = f.mojoc[0];
    f.mojoc = entries;
    try std.testing.expect((try publish_cmd.prepare(a, .publish, f)) == null);
    try std.testing.expectEqual(entries.len, (try publish_cmd.prepare(a, .pack, f)).?.packs.len);
}

/// Runs `prepare` with an allocator that fails its `n`th allocation, for each `n` until it packs: each run is refused or
/// fails with `OutOfMemory`, never anything else. Returns how many were refused with null.
fn refusedWhenMemoryRuns(fx: Fx) !usize {
    var refusals: usize = 0;
    var n: usize = 0;
    while (true) : (n += 1) {
        var st = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer st.deinit();
        var failing = std.testing.FailingAllocator.init(st.allocator(), .{ .fail_index = n });
        const a = failing.allocator();
        const got = publish_cmd.prepare(a, .pack, try fx.flags(st.allocator(), "1.0.0")) catch |e| {
            try std.testing.expectEqual(error.OutOfMemory, e);
            continue;
        };
        if (got == null) refusals += 1 else return refusals;
    }
}

test "a manifest that cannot be parsed for want of memory is refused like any other, not packed" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.package(head);
    try std.testing.expect(try refusedWhenMemoryRuns(fx) > 0);
}

test "a path dependency's manifest that cannot be parsed for want of memory is refused like any other" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.package(head ++ "\n[dependencies]\n\"example/dep\" = { version = \"^1.0\", path = \"../dep\" }\n");
    try fx.put("dep/mopm.toml", "[package]\nname = \"example/dep\"\nversion = \"1.2.0\"\nmojo = [\"1.0.0\"]\n");
    try std.testing.expect(try refusedWhenMemoryRuns(fx) > 0);
}
