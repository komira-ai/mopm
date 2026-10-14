//! Native libraries and native dependencies in a packed `.conda`
//! (`mopm pack`; the layout is in spec/channel.md, "Inside a package").
//!
//! A `[native.<id>]` library is a file the caller built; the packer only
//! checks that the files it is given are the ones the manifest declares and
//! that their names are ones the registry accepts, then stores each as
//! `lib/<file name>` and describes it in `lib/mojo/<name>.mopm.json`
//! (spec/package-metadata.schema.json, read back by metadata.zig).
//!
//! A `[native-dependencies]` entry is a system library from conda: it becomes
//! a `depends` entry of `info/index.json` named by its id. Whether the id is
//! on the registry's allow-list is the registry's decision, not the packer's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest = @import("manifest.zig");
const metadata = @import("metadata.zig");

/// A file stored under `lib/`: its name there, and its bytes.
pub const Blob = struct { name: []const u8, data: []const u8 };

/// A native library of one package file, ready to be packed.
pub const Lib = struct {
    id: []const u8,
    kind: metadata.Kind,
    mode: metadata.Mode,
    /// The shared object (kind shared or both).
    shared: ?Blob = null,
    /// The static archive (kind static or both).
    static: ?Blob = null,
    /// Sonames of native libraries from other packages this one needs.
    needs: []const []const u8 = &.{},

    /// The soname the metadata records: the shared object's file name, or the
    /// archive's for a static-only library.
    pub fn soname(l: Lib) []const u8 {
        if (l.shared) |b| return b.name;
        return l.static.?.name;
    }
};

/// A built library file handed to pack for one subdir.
pub const Given = struct {
    /// The `[native.<id>]` it is a file of.
    id: []const u8,
    /// A static archive (`--native-static`) rather than a shared object (`--native`).
    static: bool,
    /// Where it was read from; only its last component is used, as the name under `lib/`.
    path: []const u8,
    data: []const u8,
};

/// A system library the package links: its conda package name and the
/// version constraint exactly as `mopm.toml` wrote it ("" for any).
pub const NativeDep = struct { id: []const u8, version: []const u8 };

fn lessDep(_: void, a: NativeDep, b: NativeDep) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

fn lessLib(_: void, a: Lib, b: Lib) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

/// The `[native-dependencies]` of `m`, sorted by id. Versions are passed on
/// as written: they follow the native package's ecosystem, not semver
/// (spec/mopm-toml.md).
pub fn nativeDepsOf(arena: Allocator, m: manifest.Manifest) Allocator.Error![]const NativeDep {
    const out = try arena.alloc(NativeDep, m.native_dependencies.len);
    for (m.native_dependencies, 0..) |d, i| {
        out[i] = .{ .id = d.name, .version = std.mem.trim(u8, d.version orelse "", " \t") };
    }
    std.mem.sort(NativeDep, out, {}, lessDep);
    return out;
}

/// A file name under `lib/` is at most this long, so that `lib/<name>` fits a ustar path.
const max_name: usize = 96;

const Suffix = enum { so, dylib, a };
const Split = struct { body: []const u8, suffix: Suffix };

/// `libfoo.so.1` -> (`libfoo`, so); null unless the name ends `.so`,
/// `.so.<digits>...`, `.dylib` or `.a`.
fn split(name: []const u8) ?Split {
    if (std.mem.endsWith(u8, name, ".a")) return .{ .body = name[0 .. name.len - 2], .suffix = .a };
    if (std.mem.endsWith(u8, name, ".dylib")) return .{ .body = name[0 .. name.len - 6], .suffix = .dylib };
    var rest = name;
    while (true) {
        if (std.mem.endsWith(u8, rest, ".so")) return .{ .body = rest[0 .. rest.len - 3], .suffix = .so };
        const dot = std.mem.lastIndexOfScalar(u8, rest, '.') orelse return null;
        const digits = rest[dot + 1 ..];
        if (digits.len == 0) return null;
        for (digits) |c| {
            if (!std.ascii.isDigit(c)) return null;
        }
        rest = rest[0..dot];
    }
}

/// The part of a library file name before its first dot: `libfoo` for
/// `libfoo.so.1` and for `libfoo.a`.
fn stemOf(name: []const u8) []const u8 {
    return name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
}

/// Why `name` cannot be a packed library file, or null. The registry accepts
/// `lib/lib<stem>.so[.N]...`, `.dylib` and `.a` directly under `lib/`, a
/// soname that looks like `lib<stem>.<suffix>`, and a static archive named
/// `<stem>.a` (service/api/src/validate/{layout,metadata}.ts).
fn nameProblem(name: []const u8, static: bool) ?[]const u8 {
    const shape = "its name must be lib<name>.so[.N], lib<name>.dylib or lib<name>.a";
    if (name.len > max_name) return "its name is longer than 96 bytes";
    const s = split(name) orelse return shape;
    if (!std.mem.startsWith(u8, s.body, "lib") or s.body.len <= 3 or s.body[3] == '.') return shape;
    if (static) {
        if (s.suffix != .a or std.mem.indexOfScalar(u8, s.body, '.') != null) {
            return "a static archive must be named lib<name>.a, with no dot in <name>";
        }
    } else if (s.suffix == .a) {
        return "a shared object must be named lib<name>.so[.N] or lib<name>.dylib";
    }
    return null;
}

fn refuse(arena: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) error{ Unpackable, OutOfMemory } {
    why.* = std.fmt.allocPrint(arena, fmt, args) catch return error.OutOfMemory;
    return error.Unpackable;
}

/// Matches the built files `given` for one subdir to the `[native.<id>]`
/// declarations `decls`: every declared library gets exactly the files its
/// kind needs, and nothing else is accepted. Sorted by id. `Unpackable`
/// says in `why` what is wrong.
pub fn assemble(
    arena: Allocator,
    decls: []const manifest.NativeLib,
    given: []const Given,
    why: *[]const u8,
) error{ Unpackable, OutOfMemory }![]const Lib {
    for (given) |g| {
        var declared = false;
        for (decls) |d| {
            if (std.mem.eql(u8, d.id, g.id)) declared = true;
        }
        if (!declared) {
            return refuse(arena, why, "{s} {s}={s}: mopm.toml declares no [native.{s}]", .{ if (g.static) "--native-static" else "--native", g.id, g.path, g.id });
        }
    }

    var libs = std.ArrayList(Lib).init(arena);
    for (decls) |d| {
        var lib = Lib{ .id = d.id, .kind = d.kind, .mode = d.mode };
        for (given) |g| {
            if (!std.mem.eql(u8, g.id, d.id)) continue;
            const flag = if (g.static) "--native-static" else "--native";
            const wanted = if (g.static) d.kind != .shared else d.kind != .static;
            if (!wanted) {
                return refuse(arena, why, "{s} {s}={s}: [native.{s}] has kind \"{s}\", which takes no {s}", .{
                    flag, g.id, g.path, d.id, @tagName(d.kind), if (g.static) "static archive" else "shared object",
                });
            }
            const slot = if (g.static) &lib.static else &lib.shared;
            if (slot.* != null) {
                return refuse(arena, why, "{s} {s}={s}: [native.{s}] already has a {s}", .{ flag, g.id, g.path, d.id, if (g.static) "static archive" else "shared object" });
            }
            const name = std.fs.path.basename(g.path);
            if (nameProblem(name, g.static)) |problem| {
                return refuse(arena, why, "{s} {s}={s}: {s}", .{ flag, g.id, g.path, problem });
            }
            if (g.data.len == 0) return refuse(arena, why, "{s} {s}={s}: the file is empty", .{ flag, g.id, g.path });
            slot.* = .{ .name = name, .data = g.data };
        }
        if (d.kind != .static and lib.shared == null) {
            return refuse(arena, why, "[native.{s}] has kind \"{s}\" and needs a shared object: pass --native {s}=<file>", .{ d.id, @tagName(d.kind), d.id });
        }
        if (d.kind != .shared and lib.static == null) {
            return refuse(arena, why, "[native.{s}] has kind \"{s}\" and needs a static archive: pass --native-static {s}=<file>", .{ d.id, @tagName(d.kind), d.id });
        }
        if (lib.shared != null and lib.static != null and !std.mem.eql(u8, stemOf(lib.shared.?.name), stemOf(lib.static.?.name))) {
            return refuse(arena, why, "[native.{s}]: the shared object {s} and the static archive {s} are not of one library (lib<name> differs)", .{ d.id, lib.shared.?.name, lib.static.?.name });
        }
        try libs.append(lib);
    }

    // Two libraries cannot both be lib/<name>.
    for (libs.items, 0..) |a, i| {
        for (libs.items[i + 1 ..]) |b| {
            for ([_]?Blob{ a.shared, a.static }) |x| {
                for ([_]?Blob{ b.shared, b.static }) |y| {
                    if (x != null and y != null and std.mem.eql(u8, x.?.name, y.?.name)) {
                        return refuse(arena, why, "[native.{s}] and [native.{s}] are both lib/{s}", .{ a.id, b.id, x.?.name });
                    }
                }
            }
        }
    }
    std.mem.sort(Lib, libs.items, {}, lessLib);
    return libs.items;
}

fn jsonStr(w: anytype, s: []const u8) !void {
    try std.json.encodeJsonString(s, .{}, w);
}

/// Writes `,"native":[...]` (nothing for no libraries) for the metadata
/// object, between its `name` and `schema` keys. Keys are sorted; `kind` and
/// `mode` are always written; paths are relative to `lib/mojo/`.
pub fn writeJson(arena: Allocator, w: anytype, libs: []const Lib) !void {
    if (libs.len == 0) return;
    try w.writeAll(",\"native\":[");
    for (libs, 0..) |l, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('{');
        if (l.shared) |b| {
            try w.writeAll("\"file\":");
            try jsonStr(w, try std.fmt.allocPrint(arena, "../{s}", .{b.name}));
            try w.writeByte(',');
        }
        try w.writeAll("\"id\":");
        try jsonStr(w, l.id);
        try w.print(",\"kind\":\"{s}\",\"mode\":\"{s}\"", .{ @tagName(l.kind), @tagName(l.mode) });
        if (l.needs.len > 0) {
            try w.writeAll(",\"needs\":[");
            for (l.needs, 0..) |n, j| {
                if (j > 0) try w.writeByte(',');
                try jsonStr(w, n);
            }
            try w.writeByte(']');
        }
        try w.writeAll(",\"soname\":");
        try jsonStr(w, l.soname());
        if (l.static) |b| {
            try w.writeAll(",\"static_file\":");
            try jsonStr(w, try std.fmt.allocPrint(arena, "../{s}", .{b.name}));
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

fn parseManifest(a: Allocator, body: []const u8) !manifest.Manifest {
    const text = try std.fmt.allocPrint(a, "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n\n[toolchain]\nmojo = \"1.0.0\"\n\n{s}\n", .{body});
    var diag: manifest.Diagnostic = .{};
    return manifest.parse(a, text, &diag);
}

fn one(id: []const u8, static: bool, path: []const u8) Given {
    return .{ .id = id, .static = static, .path = path, .data = "BYTES" };
}

/// Runs `assemble` expecting a refusal whose reason contains `needle`.
fn refusal(a: Allocator, body: []const u8, given: []const Given, needle: []const u8) !void {
    const m = try parseManifest(a, body);
    var why: []const u8 = "";
    if (assemble(a, m.native, given, &why)) |_| {
        std.debug.print("accepted; wanted a refusal naming '{s}'\n", .{needle});
        return error.TestUnexpectedResult;
    } else |e| {
        try std.testing.expect(e == error.Unpackable);
    }
    if (std.mem.indexOf(u8, why, needle) == null) {
        std.debug.print("refusal '{s}' lacks '{s}'\n", .{ why, needle });
        return error.TestUnexpectedResult;
    }
}

test "native entries: bytes for shared, static and both" {
    // Catches: a key the reader does not know, an unsorted key, a path not
    // relative to lib/mojo/, a soname taken from the wrong file.
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const m = try parseManifest(a,
        \\[native.both_lib]
        \\kind = "both"
        \\
        \\[native.shared_lib]
        \\mode = "load"
        \\
        \\[native.static_lib]
        \\kind = "static"
        \\
    );
    var why: []const u8 = "";
    const libs = try assemble(a, m.native, &.{
        one("shared_lib", false, "out/libshared_lib.dylib"),
        one("static_lib", true, "out/libstatic_lib.a"),
        one("both_lib", true, "x/libboth.a"),
        one("both_lib", false, "y/libboth.so.2"),
    }, &why);
    var out = std.ArrayList(u8).init(a);
    try writeJson(a, out.writer(), libs);
    try std.testing.expectEqualStrings(
        ",\"native\":[" ++
            "{\"file\":\"../libboth.so.2\",\"id\":\"both_lib\",\"kind\":\"both\",\"mode\":\"link\",\"soname\":\"libboth.so.2\",\"static_file\":\"../libboth.a\"}," ++
            "{\"file\":\"../libshared_lib.dylib\",\"id\":\"shared_lib\",\"kind\":\"shared\",\"mode\":\"load\",\"soname\":\"libshared_lib.dylib\"}," ++
            "{\"id\":\"static_lib\",\"kind\":\"static\",\"mode\":\"link\",\"soname\":\"libstatic_lib.a\",\"static_file\":\"../libstatic_lib.a\"}" ++
            "]",
        out.items,
    );
}

test "native entries: needs is written between mode and soname, and none writes nothing" {
    // Catches: a `needs` the planner cannot read, and a stray "native" key
    // (or an empty array) in a package that ships no library.
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var out = std.ArrayList(u8).init(a);
    try writeJson(a, out.writer(), &.{});
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try writeJson(a, out.writer(), &.{.{
        .id = "x",
        .kind = .shared,
        .mode = .link,
        .shared = .{ .name = "libx.so.1", .data = "d" },
        .needs = &.{ "liby.so.1", "libz.so" },
    }});
    try std.testing.expectEqualStrings(
        ",\"native\":[{\"file\":\"../libx.so.1\",\"id\":\"x\",\"kind\":\"shared\",\"mode\":\"link\",\"needs\":[\"liby.so.1\",\"libz.so\"],\"soname\":\"libx.so.1\"}]",
        out.items,
    );
}

test "native entries round-trip through the metadata reader" {
    // Catches: output that the install side reads differently from what pack
    // meant (a renamed key reads as a missing file, a wrong kind as a default).
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const m = try parseManifest(a,
        \\[native.alpha]
        \\kind = "both"
        \\mode = "load"
        \\
        \\[native.beta]
        \\
    );
    var why: []const u8 = "";
    const libs = try assemble(a, m.native, &.{
        one("alpha", false, "libalpha.1.dylib"),
        one("alpha", true, "libalpha.a"),
        one("beta", false, "libbeta.so.3"),
    }, &why);
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.writeAll("{\"name\":\"demo\"");
    try writeJson(a, w, libs);
    try w.writeAll(",\"schema\":1}");
    const back = try metadata.parse(a, out.items);
    try std.testing.expectEqual(@as(usize, 2), back.native.len);
    try std.testing.expectEqualStrings("alpha", back.native[0].id);
    try std.testing.expectEqualStrings("libalpha.1.dylib", back.native[0].soname);
    try std.testing.expectEqual(metadata.Kind.both, back.native[0].kind);
    try std.testing.expectEqual(metadata.Mode.load, back.native[0].mode);
    try std.testing.expectEqualStrings("../libalpha.1.dylib", back.native[0].file);
    try std.testing.expectEqualStrings("../libalpha.a", back.native[0].static_file);
    try std.testing.expectEqualStrings("beta", back.native[1].id);
    try std.testing.expectEqualStrings("libbeta.so.3", back.native[1].soname);
    try std.testing.expectEqual(metadata.Kind.shared, back.native[1].kind);
    try std.testing.expectEqual(metadata.Mode.link, back.native[1].mode);
    try std.testing.expectEqualStrings("../libbeta.so.3", back.native[1].file);
}

test "native dependencies: sorted by id, versions as written" {
    // Catches: a constraint rewritten into semver/conda spelling (a native
    // version follows its own ecosystem), an unsorted depends list.
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const m = try parseManifest(a,
        \\[native-dependencies]
        \\zlib = ">=1.2"
        \\openssl = { version = "3.0.*", kind = "shared" }
        \\libcurl = { kind = "static" }
        \\
    );
    const deps = try nativeDepsOf(a, m);
    try std.testing.expectEqual(@as(usize, 3), deps.len);
    try std.testing.expectEqualStrings("libcurl", deps[0].id);
    try std.testing.expectEqualStrings("", deps[0].version);
    try std.testing.expectEqualStrings("openssl", deps[1].id);
    try std.testing.expectEqualStrings("3.0.*", deps[1].version);
    try std.testing.expectEqualStrings("zlib", deps[2].id);
    try std.testing.expectEqualStrings(">=1.2", deps[2].version);
}

test "refused: a declared library with no file" {
    // Catches: a package whose metadata declares a library the archive lacks
    // (the registry would reject it as native_missing after the upload).
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    try refusal(a, "[native.zlib]\n", &.{}, "[native.zlib] has kind \"shared\" and needs a shared object: pass --native zlib=<file>");
    try refusal(a, "[native.zlib]\nkind = \"static\"\n", &.{}, "needs a static archive: pass --native-static zlib=<file>");
}

test "refused: a file for an undeclared library" {
    // Catches: a stray library file shipped without a declaration (the
    // registry rejects it as native_undeclared), or a typo in the id.
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    try refusal(a, "[native.zlib]\n", &.{ one("zlib", false, "libz.so.1"), one("zlibb", false, "libz2.so.1") }, "mopm.toml declares no [native.zlibb]");
    try refusal(a, "", &.{one("zlib", true, "libz.a")}, "--native-static zlib=libz.a: mopm.toml declares no [native.zlib]");
}

test "refused: kind both with one file, and a file the kind does not take" {
    // Catches: a `both` library missing one half (the metadata schema needs
    // file and static_file), and a file the kind never reads being packed.
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const both = "[native.zlib]\nkind = \"both\"\n";
    try refusal(a, both, &.{one("zlib", false, "libz.so.1")}, "needs a static archive");
    try refusal(a, both, &.{one("zlib", true, "libz.a")}, "needs a shared object");
    try refusal(a, "[native.zlib]\n", &.{ one("zlib", false, "libz.so.1"), one("zlib", true, "libz.a") }, "which takes no static archive");
    try refusal(a, "[native.zlib]\nkind = \"static\"\n", &.{one("zlib", false, "libz.so.1")}, "which takes no shared object");
    try refusal(a, "[native.zlib]\n", &.{ one("zlib", false, "libz.so.1"), one("zlib", false, "libz.so.2") }, "already has a shared object");
}

test "refused: a file name the registry would not take" {
    // Catches: names outside the registry's lib/ allow-list or not fitting a
    // soname (native_path / path_not_allowed after upload), an empty file,
    // and a static archive that is not of the same library as the shared one.
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const shared = "[native.zlib]\n";
    for ([_][]const u8{ "z.so", "libz", "libz.txt", "libz.so.x", "libz.so.", "lib.so", "lib.z.so", "libz.a", "libz.so.1.a2", "libz.exe" }) |name| {
        refusal(a, shared, &.{one("zlib", false, name)}, "--native zlib=") catch |e| {
            std.debug.print("shared name {s}\n", .{name});
            return e;
        };
    }
    for ([_][]const u8{ "libz.so", "libz.1.a", "z.a", "lib.a", "libz.dylib" }) |name| {
        refusal(a, "[native.zlib]\nkind = \"static\"\n", &.{one("zlib", true, name)}, "--native-static zlib=") catch |e| {
            std.debug.print("static name {s}\n", .{name});
            return e;
        };
    }
    try refusal(a, shared, &.{one("zlib", false, "libz" ++ ("x" ** 90) ++ ".so")}, "longer than 96 bytes");
    try refusal(a, shared, &.{.{ .id = "zlib", .static = false, .path = "libz.so.1", .data = "" }}, "the file is empty");
    try refusal(a, "[native.zlib]\nkind = \"both\"\n", &.{ one("zlib", false, "libz.so.1"), one("zlib", true, "libzstd.a") }, "not of one library");
    try refusal(a, "[native.a]\n\n[native.b]\n", &.{ one("a", false, "d1/libsame.so"), one("b", false, "d2/libsame.so") }, "are both lib/libsame.so");
}

test "accepted names, with the soname taken from the shared object" {
    // Catches: a refusal of a name the registry takes (.so, .so.N.M, .dylib,
    // a dotted lib<name>), or a soname taken from the archive for kind both.
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const m = try parseManifest(a,
        \\[native.a]
        \\
        \\[native.b]
        \\
        \\[native.c]
        \\
        \\[native.d]
        \\kind = "both"
        \\
    );
    var why: []const u8 = "";
    const libs = try assemble(a, m.native, &.{
        one("d", true, "libd.a"),
        one("c", false, "libc_x-y.so.1.2.3"),
        one("b", false, "libb.so"),
        one("a", false, "/abs/dir/liba.1.dylib"),
        one("d", false, "libd.so.9"),
    }, &why);
    try std.testing.expectEqual(@as(usize, 4), libs.len);
    try std.testing.expectEqualStrings("liba.1.dylib", libs[0].soname());
    try std.testing.expectEqualStrings("libb.so", libs[1].soname());
    try std.testing.expectEqualStrings("libc_x-y.so.1.2.3", libs[2].soname());
    try std.testing.expectEqualStrings("libd.so.9", libs[3].soname());
    try std.testing.expectEqualStrings("libd.a", libs[3].static.?.name);
}
