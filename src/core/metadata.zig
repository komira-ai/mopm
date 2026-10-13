//! Parser for the `<name>.mopm.json` file embedded in every installed package
//! (schema 1; see spec/package-metadata.schema.json).
//!
//! Unknown keys are ignored; a higher `schema` is refused.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const supported_schema: u32 = 1;

/// Which flavours of a native library the package ships.
pub const Kind = enum { shared, static, both };

/// `link`: mopm computes the linker flags. `load`: the package loads the
/// library itself at run time, so mopm adds nothing.
pub const Mode = enum { link, load };

pub const Dep = struct {
    name: []const u8,
    range: []const u8 = "",
};

pub const Native = struct {
    id: []const u8,
    soname: []const u8,
    kind: Kind = .shared,
    mode: Mode = .link,
    /// Shared object, relative to the metadata file (kind shared or both).
    file: []const u8 = "",
    /// Static archive, relative to the metadata file (kind static or both).
    static_file: []const u8 = "",
    /// Sonames of other native libraries (from other packages) this one needs.
    needs: []const []const u8 = &.{},
};

pub const Metadata = struct {
    schema: u32,
    name: []const u8,
    version: []const u8 = "",
    deps: []const Dep = &.{},
    native: []const Native = &.{},
};

pub const ParseError = error{
    InvalidMetadata,
    UnsupportedSchema,
    EmptyName,
    MissingFile,
    BadSoname,
    OutOfMemory,
};

/// The `-l` name of a library: `libfoo_native.so.1` -> `foo_native`,
/// `libfoo.1.dylib` -> `foo`, `libfoo.a` -> `foo`. Null if `soname` is not of
/// the form `lib<name>.<something>`.
pub fn linkName(soname: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, soname, "lib")) return null;
    const rest = soname[3..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    if (dot == 0 or dot + 1 >= rest.len) return null;
    return rest[0..dot];
}

/// Parse and validate. All returned slices live in `arena` (or in `text`,
/// which must outlive the result).
pub fn parse(arena: Allocator, text: []const u8) ParseError!Metadata {
    const m = std.json.parseFromSliceLeaky(Metadata, arena, text, .{
        .ignore_unknown_fields = true,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMetadata,
    };
    if (m.schema > supported_schema) return error.UnsupportedSchema;
    if (m.schema == 0) return error.InvalidMetadata;
    if (m.name.len == 0) return error.EmptyName;
    for (m.native) |n| {
        if (linkName(n.soname) == null) return error.BadSoname;
        if (n.kind != .static and n.file.len == 0) return error.MissingFile;
        if (n.kind != .shared and n.static_file.len == 0) return error.MissingFile;
    }
    return m;
}

fn arenaFor(t: *std.heap.ArenaAllocator) Allocator {
    return t.allocator();
}

test "linkName strips lib prefix and version suffix" {
    try std.testing.expectEqualStrings("foo", linkName("libfoo.so.1").?);
    try std.testing.expectEqualStrings("foo_native", linkName("libfoo_native.so").?);
    try std.testing.expectEqualStrings("foo", linkName("libfoo.1.dylib").?);
    try std.testing.expectEqualStrings("foo", linkName("libfoo.a").?);
    try std.testing.expect(linkName("foo.so") == null);
    try std.testing.expect(linkName("lib.so") == null);
    try std.testing.expect(linkName("libfoo") == null);
    try std.testing.expect(linkName("libfoo.") == null);
}

test "parse a full document with defaults and unknown keys" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const m = try parse(arenaFor(&t),
        \\{ "schema": 1, "name": "http_client", "version": "0.4.0", "extra": [1, 2],
        \\  "deps": [{"name": "http_core", "range": ">=1.2"}],
        \\  "native": [
        \\    {"id": "a", "soname": "liba.so.1", "file": "lib/liba.so.1", "needs": ["libb.so.1"]},
        \\    {"id": "b", "soname": "libb.so.1", "kind": "both", "mode": "load",
        \\     "file": "lib/libb.so.1", "static_file": "lib/libb.a"}
        \\  ] }
    );
    try std.testing.expectEqualStrings("http_client", m.name);
    try std.testing.expectEqual(@as(usize, 1), m.deps.len);
    try std.testing.expectEqualStrings("http_core", m.deps[0].name);
    try std.testing.expectEqual(@as(usize, 2), m.native.len);
    try std.testing.expectEqual(Kind.shared, m.native[0].kind);
    try std.testing.expectEqual(Mode.link, m.native[0].mode);
    try std.testing.expectEqualStrings("libb.so.1", m.native[0].needs[0]);
    try std.testing.expectEqual(Kind.both, m.native[1].kind);
    try std.testing.expectEqual(Mode.load, m.native[1].mode);
}

test "a package without natives parses" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const m = try parse(arenaFor(&t), "{\"schema\": 1, \"name\": \"pure\"}");
    try std.testing.expectEqual(@as(usize, 0), m.native.len);
    try std.testing.expectEqual(@as(usize, 0), m.deps.len);
}

test "a higher schema is refused" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    try std.testing.expectError(error.UnsupportedSchema, parse(arenaFor(&t), "{\"schema\": 2, \"name\": \"x\"}"));
}

test "invalid documents are refused" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = arenaFor(&t);
    try std.testing.expectError(error.InvalidMetadata, parse(a, "not json"));
    try std.testing.expectError(error.InvalidMetadata, parse(a, "{\"name\": \"x\"}"));
    try std.testing.expectError(error.InvalidMetadata, parse(a, "{\"schema\": 0, \"name\": \"x\"}"));
    try std.testing.expectError(error.InvalidMetadata, parse(a,
        \\{"schema": 1, "name": "x", "native": [{"id": "a", "soname": "liba.so", "kind": "weird", "file": "f"}]}
    ));
    try std.testing.expectError(error.EmptyName, parse(a, "{\"schema\": 1, \"name\": \"\"}"));
}

test "natives are validated" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = arenaFor(&t);
    try std.testing.expectError(error.BadSoname, parse(a,
        \\{"schema": 1, "name": "x", "native": [{"id": "a", "soname": "a.so", "file": "f"}]}
    ));
    // shared without a shared file
    try std.testing.expectError(error.MissingFile, parse(a,
        \\{"schema": 1, "name": "x", "native": [{"id": "a", "soname": "liba.so.1"}]}
    ));
    // static without an archive
    try std.testing.expectError(error.MissingFile, parse(a,
        \\{"schema": 1, "name": "x", "native": [{"id": "a", "soname": "liba.a", "kind": "static", "file": "f"}]}
    ));
    // both needs both files
    try std.testing.expectError(error.MissingFile, parse(a,
        \\{"schema": 1, "name": "x", "native": [{"id": "a", "soname": "liba.so.1", "kind": "both", "file": "f"}]}
    ));
}
