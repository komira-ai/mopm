//! Names of packages in owner namespaces (spec/proposed/namespaces.md, "Names"): the namespace, the full name
//! `<namespace>/<name>`, the reserved namespaces, the import names the registry refuses, and where a package's files
//! go. A package's key in the fake is its v1 name (no `/`) or its full name (one `/`), so the two never meet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util.zig");

/// Whether `s` is a namespace: a GitHub login in lower case, `^[a-z0-9]+(-[a-z0-9]+)*$`, 1 to 39 characters.
pub fn isNamespace(s: []const u8) bool {
    if (s.len < 1 or s.len > 39) return false;
    var it = std.mem.splitScalar(u8, s, '-');
    while (it.next()) |part| {
        if (part.len == 0) return false;
        for (part) |c| {
            if (!std.ascii.isLower(c) and !std.ascii.isDigit(c)) return false;
        }
    }
    return true;
}

/// Platform words of a conda subdir: a namespace `<word>-<anything>` would look like a subdir of the channel root.
const subdir_platforms = [_][]const u8{ "linux", "osx", "win", "freebsd", "zos", "wasi", "emscripten" };
/// The channel bucket's other top-level prefixes.
const reserved_namespaces = [_][]const u8{ "noarch", "index", "quarantine", "native-mirror" };

/// Whether the namespace `s` (in the grammar) is one nobody gets: the shape of a conda subdir,
/// `^(noarch|(linux|osx|win|freebsd|zos|wasi|emscripten)-[a-z0-9]+)$`, and `index`, `quarantine`, `native-mirror`.
pub fn isReservedNamespace(s: []const u8) bool {
    for (reserved_namespaces) |r| {
        if (std.mem.eql(u8, r, s)) return true;
    }
    const dash = std.mem.indexOfScalar(u8, s, '-') orelse return false;
    const rest = s[dash + 1 ..];
    if (rest.len == 0 or std.mem.indexOfScalar(u8, rest, '-') != null) return false;
    for (subdir_platforms) |p| {
        if (std.mem.eql(u8, p, s[0..dash])) return true;
    }
    return false;
}

pub const Full = struct { namespace: []const u8, name: []const u8 };

/// `s` split at its one `/`, or null when it has none or more than one. Either part may still be outside its grammar.
pub fn split(s: []const u8) ?Full {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return null;
    if (std.mem.indexOfScalarPos(u8, s, slash + 1, '/') != null) return null;
    return .{ .namespace = s[0..slash], .name = s[slash + 1 ..] };
}

/// Whether `s` is a full name: a namespace, `/`, and a normalised name (`util.isName`).
pub fn isFullName(s: []const u8) bool {
    const f = split(s) orelse return false;
    return isNamespace(f.namespace) and util.isName(f.name);
}

/// The import name of a package key: the part after `/`, or the whole v1 name.
pub fn importName(key: []const u8) []const u8 {
    const f = split(key) orelse return key;
    return f.name;
}

/// The namespace of a package key, or null for a v1 name.
pub fn namespaceOf(key: []const u8) ?[]const u8 {
    const f = split(key) orelse return null;
    return f.namespace;
}

/// Import names the registry refuses (docs/design/namespaces.md section 1): the names reserved before namespaces, and
/// Mojo's keywords and the builtins a package of that name would shadow, as `src/core/manifest.zig` lists them (the fake
/// cannot import that file; the two lists are kept equal by hand).
const reserved_imports = [_][]const u8{ "mopm", "mojo", "max", "modular", "std", "stdlib" };
const keywords = [_][]const u8{
    "alias",  "and",      "as",       "assert", "async",  "await",  "borrowed", "break",
    "class",  "comptime", "continue", "def",    "deinit", "del",    "elif",     "else",
    "except", "finally",  "fn",       "for",    "from",   "global", "if",       "import",
    "in",     "inout",    "is",       "lambda", "let",    "mut",    "nonlocal", "not",
    "or",     "out",      "owned",    "pass",   "raise",  "raises", "read",     "ref",
    "return", "self",     "struct",   "trait",  "try",    "var",    "while",    "with",
    "yield",
};
const builtins = [_][]const u8{
    "abs",   "all",    "any", "bool",       "chr",   "divmod", "enumerate", "float",
    "hash",  "input",  "int", "isinstance", "iter",  "len",    "list",      "max",
    "min",   "next",   "ord", "pow",        "print", "range",  "repr",      "reversed",
    "round", "sorted", "str", "sum",        "type",  "zip",
};

/// Whether `name` may not be an import name.
pub fn isForbiddenImport(name: []const u8) bool {
    inline for (.{ &reserved_imports, &keywords, &builtins }) |list| {
        for (list) |w| {
            if (std.mem.eql(u8, w, name)) return true;
        }
    }
    return false;
}

/// The conda package name of a key: `mojo-<name>` for a v1 name, `mojo-<namespace>.<name>` for a full name.
pub fn condaName(arena: Allocator, key: []const u8) Allocator.Error![]const u8 {
    const f = split(key) orelse return std.fmt.allocPrint(arena, "mojo-{s}", .{key});
    return std.fmt.allocPrint(arena, "mojo-{s}.{s}", .{ f.namespace, f.name });
}

/// The channel directory of a key under the data directory: `channel` (the flat root) for a v1 name,
/// `channel/<namespace>` for a full name (spec/proposed/namespaces.md, "channel.md").
pub fn channelDir(arena: Allocator, key: []const u8) Allocator.Error![]const u8 {
    const ns = namespaceOf(key) orelse return "channel";
    return std.fmt.allocPrint(arena, "channel/{s}", .{ns});
}

/// `<aa>/<bb>` of `s`: its first two and next two characters, padded on the right with `_`.
pub fn shard(buf: *[5]u8, s: []const u8) []const u8 {
    buf.* = .{ '_', '_', '/', '_', '_' };
    for (s[0..@min(s.len, 4)], 0..) |c, i| buf[if (i < 2) i else i + 1] = c;
    return buf;
}

/// The index path of a key under the data directory: `index/<aa>/<bb>/<name>` for a v1 name (spec/index.md),
/// `index/v2/<aa>/<bb>/<namespace>/<name>` for a full name, sharded by the namespace.
pub fn indexPath(arena: Allocator, key: []const u8) Allocator.Error![]const u8 {
    var buf: [5]u8 = undefined;
    if (split(key)) |f| return std.fmt.allocPrint(arena, "index/v2/{s}/{s}", .{ shard(&buf, f.namespace), key });
    return std.fmt.allocPrint(arena, "index/{s}/{s}", .{ shard(&buf, key), key });
}

test "namespaces: the lower-case GitHub login grammar, at most 39 characters" {
    for ([_][]const u8{ "komira-ai", "a", "0", "ab", "x1", "a-b-c", "a" ** 39 }) |s| try std.testing.expect(isNamespace(s));
    for ([_][]const u8{ "", "Komira-AI", "-a", "a-", "a--b", "a_b", "a.b", "a/b", "a" ** 40, "é" }) |s| try std.testing.expect(!isNamespace(s));
}

test "reserved namespaces: conda subdir shapes and the bucket's prefixes" {
    for ([_][]const u8{ "noarch", "linux-64", "linux-aarch64", "osx-arm64", "win-32", "freebsd-x", "zos-z", "wasi-wasm32", "emscripten-wasm32", "index", "quarantine", "native-mirror" }) |s| {
        try std.testing.expect(isReservedNamespace(s));
    }
    for ([_][]const u8{ "linux", "linux-64-x", "osx", "komira-ai", "noarch-x", "indexes", "mirror" }) |s| try std.testing.expect(!isReservedNamespace(s));
}

test "full names split at their one slash" {
    try std.testing.expect(isFullName("komira-ai/json"));
    try std.testing.expect(isFullName("ab/x1"));
    for ([_][]const u8{ "json", "komira-ai/", "/json", "komira-ai/json/x", "Komira-AI/json", "komira_ai/json", "komira-ai/Json", "komira-ai/my-json", "komira-ai/j", "a" ** 40 ++ "/json" }) |s| {
        try std.testing.expect(!isFullName(s));
    }
    try std.testing.expectEqualStrings("json", importName("komira-ai/json"));
    try std.testing.expectEqualStrings("json", importName("json"));
    try std.testing.expectEqualStrings("komira-ai", namespaceOf("komira-ai/json").?);
    try std.testing.expect(namespaceOf("json") == null);
}

test "forbidden import names: reserved, keywords, builtins" {
    for ([_][]const u8{ "mopm", "mojo", "max", "modular", "std", "stdlib", "fn", "struct", "yield", "len", "zip" }) |s| try std.testing.expect(isForbiddenImport(s));
    for ([_][]const u8{ "json", "hashing", "maxx", "lens" }) |s| try std.testing.expect(!isForbiddenImport(s));
}

test "conda names, channel directories and index paths of both kinds of key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("mojo-komira-ai.json", try condaName(a, "komira-ai/json"));
    try std.testing.expectEqualStrings("mojo-json", try condaName(a, "json"));
    try std.testing.expectEqualStrings("channel/komira-ai", try channelDir(a, "komira-ai/json"));
    try std.testing.expectEqualStrings("channel", try channelDir(a, "json"));
    try std.testing.expectEqualStrings("index/v2/ko/mi/komira-ai/json", try indexPath(a, "komira-ai/json"));
    try std.testing.expectEqualStrings("index/v2/ab/__/ab/x1", try indexPath(a, "ab/x1"));
    try std.testing.expectEqualStrings("index/v2/a_/__/a/json", try indexPath(a, "a/json"));
    try std.testing.expectEqualStrings("index/ht/tp/http_client", try indexPath(a, "http_client"));
    try std.testing.expectEqualStrings("index/tl/s_/tls", try indexPath(a, "tls"));
}
