//! Tests of the source digest in `mopm pack` and `mopm publish` (publish_cmd.zig, src/core/source_digest.zig): what `prepare`
//! packs and what it says when the package has no library directory. A package is written to a temporary directory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const conda = core.conda;
const source_digest = core.source_digest;
const publish_cmd = @import("publish_cmd.zig");

const manifest_text = "[package]\nname = \"example/demo\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n";

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

    fn flags(fx: Fx, a: Allocator, compiler: []const u8) !publish_cmd.Flags {
        return .{
            .compiler = compiler,
            .manifest = try std.fs.path.join(a, &.{ fx.root, "pkg/mopm.toml" }),
            .mojoc = try a.dupe(publish_cmd.Mojoc, &.{.{ .subdir = "noarch", .path = try std.fs.path.join(a, &.{ fx.root, "demo.mojoc" }) }}),
        };
    }
};

fn setup(fx: Fx) !void {
    try fx.put("pkg/mopm.toml", manifest_text);
    try fx.put("demo.mojoc", "the mojoc");
}

test "a package with a library directory is packed with the digest of its sources, the same for every compiler" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try setup(fx);
    try fx.put("pkg/src/demo/lib.mojo", "def f(): pass\n");
    try fx.put("pkg/src/demo/util/helpers.mojo", "def g(): pass\n");

    const one = (try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.0.0"))).?;
    const two = (try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.1.0"))).?;
    try std.testing.expect(one.note == null and two.note == null);

    // The digest is what the core computes for these files, and it is in the metadata, so the hash the commit declares is that
    // of metadata that carries it, for either compiler.
    const digest = (try source_digest.ofPackage(a, one.m, try std.fs.path.join(a, &.{ fx.root, "pkg" }), "mopm.toml")).digest;
    const want = try conda.pack(a, .{ .name = "example/demo", .version = "1.0.0", .compiler = "1.0.0", .subdir = "noarch", .mojoc = "the mojoc", .source_sha256 = &digest });
    try std.testing.expectEqualSlices(u8, want.bytes, one.packs[0].bytes);
    try std.testing.expectEqualSlices(u8, &one.packs[0].manifest_sha256, &two.packs[0].manifest_sha256);
    try std.testing.expect(!std.mem.eql(u8, one.packs[0].file_name, two.packs[0].file_name));
    const without = try conda.pack(a, .{ .name = "example/demo", .version = "1.0.0", .compiler = "1.0.0", .subdir = "noarch", .mojoc = "the mojoc" });
    try std.testing.expect(!std.mem.eql(u8, &without.manifest_sha256, &one.packs[0].manifest_sha256));

    // A change of a source is a change of the digest, hence of the metadata.
    try fx.put("pkg/src/demo/util/helpers.mojo", "def g(): return\n");
    const changed = (try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.0.0"))).?;
    try std.testing.expect(!std.mem.eql(u8, &changed.packs[0].manifest_sha256, &one.packs[0].manifest_sha256));
}

test "a package with no library directory is packed with no digest, and the note says so, exactly" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try setup(fx);

    const prep = (try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.0.0"))).?;
    try std.testing.expectEqualStrings("note: src/demo does not exist, so example/demo 1.0.0 carries no source digest; a build for another Mojo can then never be added to this version", prep.note.?);
    // The bytes are those of a package packed before there was a digest.
    const plain = try conda.pack(a, .{ .name = "example/demo", .version = "1.0.0", .compiler = "1.0.0", .subdir = "noarch", .mojoc = "the mojoc" });
    try std.testing.expectEqualSlices(u8, plain.bytes, prep.packs[0].bytes);
}

test "the library directory is the one [targets] lib names, and a program source counts" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try setup(fx);
    try fx.put("pkg/mopm.toml", manifest_text ++ "\n[targets]\nlib = { path = \"lib/demo\" }\nbins = [{ name = \"tool\", path = \"tools/tool.mojo\" }]\n");
    try fx.put("pkg/tools/tool.mojo", "def main(): pass\n");

    // src/demo is not named, lib/demo is not there: no digest.
    try fx.put("pkg/src/demo/lib.mojo", "not the library\n");
    const none = (try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.0.0"))).?;
    try std.testing.expect(std.mem.startsWith(u8, none.note.?, "note: lib/demo does not exist, so example/demo 1.0.0 carries"));

    try fx.put("pkg/lib/demo/lib.mojo", "def f(): pass\n");
    const first = (try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.0.0"))).?;
    try std.testing.expect(first.note == null);
    try fx.put("pkg/tools/tool.mojo", "def main(): return\n");
    const second = (try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.0.0"))).?;
    try std.testing.expect(!std.mem.eql(u8, &first.packs[0].manifest_sha256, &second.packs[0].manifest_sha256));
}

test "a library directory with something that is not a source is refused before anything is packed" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try setup(fx);
    try fx.put("pkg/src/demo/lib.mojo", "def f(): pass\n");
    try fx.tmp.dir.symLink("/dev/null", "pkg/src/demo/null.mojo", .{});
    try std.testing.expect((try publish_cmd.prepare(a, .pack, try fx.flags(a, "1.0.0"))) == null);
}
