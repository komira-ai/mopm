//! Package names (docs/design/namespaces.md, section 1; spec/mopm-toml.md, "Names").
//!
//! A full name is `<namespace>/<name>`, as in `komira-ai/json`. The namespace is a GitHub login in lower case,
//! `^[a-z0-9]+(-[a-z0-9]+)*$`, 1 to 39 characters. The name, `^[a-z][a-z0-9_]{1,63}$`, is what Mojo code imports
//! (`import json`), so it is also called the import name. An import name is never a Mojo keyword or builtin, a
//! reserved name, or a top-level module of the Mojo standard library (`toolchain/std-modules.txt`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_namespace_len = 39;
pub const min_name_len = 2;
pub const max_name_len = 64;

/// A full name split at its `/`.
pub const FullName = struct { namespace: []const u8, name: []const u8 };

/// `full` split at its first `/`, or null when it has none (a bare name). Nothing is checked.
pub fn split(full: []const u8) ?FullName {
    const slash = std.mem.indexOfScalar(u8, full, '/') orelse return null;
    return .{ .namespace = full[0..slash], .name = full[slash + 1 ..] };
}

/// Mojo's keywords: a package of one of these names cannot be imported.
const keywords = [_][]const u8{
    "alias",  "and",      "as",       "assert", "async",  "await",  "borrowed", "break",
    "class",  "comptime", "continue", "def",    "deinit", "del",    "elif",     "else",
    "except", "finally",  "fn",       "for",    "from",   "global", "if",       "import",
    "in",     "inout",    "is",       "lambda", "let",    "mut",    "nonlocal", "not",
    "or",     "out",      "owned",    "pass",   "raise",  "raises", "read",     "ref",
    "return", "self",     "struct",   "trait",  "try",    "var",    "while",    "with",
    "yield",
};

/// The builtins a package of that name would shadow when imported.
const builtins = [_][]const u8{
    "abs",   "all",    "any", "bool", "chr",   "divmod", "enumerate",  "float",
    "hash",  "input",  "int", "isinstance", "iter", "len", "list", "max",
    "min",   "next",   "ord", "pow",  "print", "range",  "repr",       "reversed",
    "round", "sorted", "str", "sum",  "type",  "zip",
};

/// Names kept for mopm and Modular: never a package's import name.
const reserved_names = [_][]const u8{ "mopm", "mojo", "max", "modular", "std", "stdlib" };

/// Namespaces never created, so that a channel URL is never ambiguous: the channel bucket's other top-level
/// prefixes. The conda subdir shapes are in `isSubdirShape`.
const reserved_namespaces = [_][]const u8{ "index", "quarantine", "native-mirror" };

/// The platforms of a conda subdir, `<platform>-<arch>`; `noarch` is the one subdir without an arch.
const subdir_platforms = [_][]const u8{ "linux", "osx", "win", "freebsd", "zos", "wasi", "emscripten" };

/// The top-level modules of the Mojo standard library of every pinned toolchain, read from its `lib/mojo/std.mojoc`
/// (toolchain/README.md). People write `import std.collections` and also the bare `import collections`, so a
/// package of one of these names would shadow it.
pub const std_modules_text = @embedFile("toolchain/std-modules.txt");

fn isOneOf(word: []const u8, list: []const []const u8) bool {
    for (list) |w| {
        if (std.mem.eql(u8, w, word)) return true;
    }
    return false;
}

/// The lines of `text` that are neither empty nor `#` comments, trimmed.
fn listLines(text: []const u8) std.mem.TokenIterator(u8, .scalar) {
    return std.mem.tokenizeScalar(u8, text, '\n');
}

fn listEntry(raw: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    return line;
}

/// Whether `name` is a top-level module of the Mojo standard library.
pub fn isStdModule(name: []const u8) bool {
    var it = listLines(std_modules_text);
    while (it.next()) |raw| {
        const entry = listEntry(raw) orelse continue;
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

/// Why `name` cannot be an import name (the name of a package, the part after `/`), or null if it can: a lowercase
/// identifier that is not a Mojo keyword or builtin, a reserved name, or a top-level module of the standard library.
/// `what` starts the message ("package name"). The length is checked by `fullNameProblem`.
pub fn nameProblem(arena: Allocator, what: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
    if (name.len == 0) return try std.fmt.allocPrint(arena, "{s} is empty", .{what});
    if (!std.ascii.isLower(name[0])) {
        return try std.fmt.allocPrint(arena, "{s} '{s}' must start with a lowercase letter", .{ what, name });
    }
    for (name) |b| {
        if (!std.ascii.isLower(b) and !std.ascii.isDigit(b) and b != '_') {
            return try std.fmt.allocPrint(arena, "{s} '{s}' may contain only lowercase letters, digits and '_'", .{ what, name });
        }
    }
    if (isOneOf(name, &keywords)) {
        return try std.fmt.allocPrint(arena, "{s} '{s}' is a Mojo keyword; choose another name", .{ what, name });
    }
    if (isOneOf(name, &builtins)) {
        return try std.fmt.allocPrint(arena, "{s} '{s}' would shadow the Mojo builtin '{s}'; choose another name", .{ what, name, name });
    }
    if (isOneOf(name, &reserved_names)) {
        return try std.fmt.allocPrint(arena, "{s} '{s}' is reserved; choose another name", .{ what, name });
    }
    if (isStdModule(name)) {
        return try std.fmt.allocPrint(arena, "{s} '{s}' would shadow the Mojo standard library module std.{s}; choose another name", .{ what, name, name });
    }
    return null;
}

/// `^[a-z0-9]+(-[a-z0-9]+)*$`, any length.
fn isNamespaceShape(ns: []const u8) bool {
    if (ns.len == 0 or ns[0] == '-' or ns[ns.len - 1] == '-') return false;
    var prev: u8 = 0;
    for (ns) |b| {
        if (!std.ascii.isLower(b) and !std.ascii.isDigit(b) and b != '-') return false;
        if (b == '-' and prev == '-') return false;
        prev = b;
    }
    return true;
}

/// `^(noarch|(linux|osx|win|freebsd|zos|wasi|emscripten)-[a-z0-9]+)$`: the shape of a conda subdir.
fn isSubdirShape(ns: []const u8) bool {
    if (std.mem.eql(u8, ns, "noarch")) return true;
    for (subdir_platforms) |p| {
        if (ns.len <= p.len + 1 or !std.mem.startsWith(u8, ns, p) or ns[p.len] != '-') continue;
        var plain = true;
        for (ns[p.len + 1 ..]) |b| plain = plain and (std.ascii.isLower(b) or std.ascii.isDigit(b));
        if (plain) return true;
    }
    return false;
}

/// Why `ns` cannot be a namespace, or null if it can. `subject` names what holds it in the message ("package name
/// 'Acme_x/json'").
pub fn namespaceProblem(arena: Allocator, subject: []const u8, ns: []const u8) Allocator.Error!?[]const u8 {
    if (ns.len == 0) return try std.fmt.allocPrint(arena, "{s} has an empty namespace; a full name is <namespace>/<name>", .{subject});
    if (!isNamespaceShape(ns)) {
        return try std.fmt.allocPrint(arena, "{s}: the namespace '{s}' is not a GitHub login in lower case (letters, digits and single hyphens between them)", .{ subject, ns });
    }
    if (ns.len > max_namespace_len) {
        return try std.fmt.allocPrint(arena, "{s}: the namespace '{s}' is {d} characters; a namespace, a GitHub login, has at most {d}", .{ subject, ns, ns.len, max_namespace_len });
    }
    if (isOneOf(ns, &reserved_namespaces) or isSubdirShape(ns)) {
        return try std.fmt.allocPrint(arena, "{s}: the namespace '{s}' is reserved; publish in your own or an organization's namespace", .{ subject, ns });
    }
    return null;
}

/// Why `full` cannot be a full name, or null if it can. `what` starts the message ("package name", "dependency").
/// A bare name (no `/`) is refused with the full form; the callers with more to say (the manifest) check that first.
pub fn fullNameProblem(arena: Allocator, what: []const u8, full: []const u8) Allocator.Error!?[]const u8 {
    const subject = try std.fmt.allocPrint(arena, "{s} '{s}'", .{ what, full });
    const parts = split(full) orelse {
        return try std.fmt.allocPrint(arena, "{s} has no namespace: write <namespace>/{s}", .{ subject, full });
    };
    if (std.mem.indexOfScalar(u8, parts.name, '/') != null) {
        return try std.fmt.allocPrint(arena, "{s} has more than one '/'; a full name is <namespace>/<name>", .{subject});
    }
    // One spelling: an upper-case form that would be valid in lower case is refused with the lower-case form.
    var upper = false;
    for (full) |b| upper = upper or std.ascii.isUpper(b);
    if (upper) {
        const lower = try std.ascii.allocLowerString(arena, full);
        if (try plainProblem(arena, subject, split(lower).?) == null) {
            return try std.fmt.allocPrint(arena, "{s} is not in lower case; write '{s}'", .{ subject, lower });
        }
    }
    return plainProblem(arena, subject, parts);
}

fn plainProblem(arena: Allocator, subject: []const u8, parts: FullName) Allocator.Error!?[]const u8 {
    if (try namespaceProblem(arena, subject, parts.namespace)) |why| return why;
    const of_name = try std.fmt.allocPrint(arena, "{s}: the import name", .{subject});
    if (try nameProblem(arena, of_name, parts.name)) |why| return why;
    if (parts.name.len < min_name_len or parts.name.len > max_name_len) {
        return try std.fmt.allocPrint(arena, "{s}: the name '{s}' has {d} characters; a name has {d} to {d}", .{ subject, parts.name, parts.name.len, min_name_len, max_name_len });
    }
    return null;
}

// ---------------------------------------------------------------------------
// The pin of toolchain/std-modules.txt
// ---------------------------------------------------------------------------

/// The mojo-compiler package of one Mojo version, as a closure file pins it.
pub const Pin = struct { version: []const u8, subdir: []const u8, sha256: []const u8 };

/// Why the `# from mojo-compiler <version> <subdir> <sha256>` lines of `list` do not match `pins`, or null: each pin
/// has a line with its version, subdir and sha256, and each line is a pin. A toolchain bump changes the pin, and the
/// list is read again from the new package (toolchain/README.md) before this passes.
pub fn pinProblem(arena: Allocator, list: []const u8, pins: []const Pin) Allocator.Error!?[]const u8 {
    var froms = std.ArrayList([]const u8).init(arena);
    var it = listLines(list);
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const prefix = "# from mojo-compiler ";
        if (std.mem.startsWith(u8, line, prefix)) try froms.append(line[prefix.len..]);
    }
    for (pins) |p| {
        const want = try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ p.version, p.subdir, p.sha256 });
        if (!isOneOf(want, froms.items)) {
            return try std.fmt.allocPrint(arena, "toolchain/std-modules.txt was not read from mojo-compiler {s} for {s} (sha256 {s}); read the list again from that package", .{ p.version, p.subdir, p.sha256 });
        }
    }
    for (froms.items) |f| {
        var known = false;
        for (pins) |p| {
            const have = try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ p.version, p.subdir, p.sha256 });
            known = known or std.mem.eql(u8, have, f);
        }
        if (!known) return try std.fmt.allocPrint(arena, "toolchain/std-modules.txt names mojo-compiler {s}, which no closure pins; drop the line", .{f});
    }
    return null;
}

/// The sha256 of the mojo-compiler package in a closure file's JSON (src/core/toolchain/mojo-<version>-<subdir>.json).
/// Only the tests read it.
/// "" when it has none, which no `# from` line matches.
fn compilerSha(arena: Allocator, closure: []const u8) ![]const u8 {
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, arena, closure, .{});
    var sha: []const u8 = "";
    for (doc.object.get("packages").?.array.items) |p| {
        if (std.mem.eql(u8, p.object.get("name").?.string, "mojo-compiler")) sha = p.object.get("sha256").?.string;
    }
    return sha;
}

const testing = std.testing;

fn expectProblem(want: ?[]const u8, got: ?[]const u8) !void {
    if (want) |w| {
        const g = got orelse {
            std.debug.print("accepted; wanted: {s}\n", .{w});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings(w, g);
    } else if (got) |g| {
        std.debug.print("refused: {s}\n", .{g});
        return error.TestUnexpectedResult;
    }
}

test "a full name is a lower-case namespace, one '/', and an importable name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ok = [_][]const u8{ "komira-ai/json", "a/xy", "a1-b2-c3/http_client", "0/ab", "x" ** 39 ++ "/" ++ "y" ** 64 };
    for (ok) |full| try expectProblem(null, try fullNameProblem(a, "package name", full));

    const cases = [_][2][]const u8{
        .{ "json", "package name 'json' has no namespace: write <namespace>/json" },
        .{ "a/b/cd", "package name 'a/b/cd' has more than one '/'; a full name is <namespace>/<name>" },
        .{ "/json", "package name '/json' has an empty namespace; a full name is <namespace>/<name>" },
        .{ "Komira-AI/json", "package name 'Komira-AI/json' is not in lower case; write 'komira-ai/json'" },
        .{ "komira-ai/Json", "package name 'komira-ai/Json' is not in lower case; write 'komira-ai/json'" },
        .{ "Komira_AI/json", "package name 'Komira_AI/json': the namespace 'Komira_AI' is not a GitHub login in lower case (letters, digits and single hyphens between them)" },
        .{ "-ai/json", "package name '-ai/json': the namespace '-ai' is not a GitHub login in lower case (letters, digits and single hyphens between them)" },
        .{ "ai-/json", "package name 'ai-/json': the namespace 'ai-' is not a GitHub login in lower case (letters, digits and single hyphens between them)" },
        .{ "a--i/json", "package name 'a--i/json': the namespace 'a--i' is not a GitHub login in lower case (letters, digits and single hyphens between them)" },
        .{ "a.i/json", "package name 'a.i/json': the namespace 'a.i' is not a GitHub login in lower case (letters, digits and single hyphens between them)" },
        .{ "x" ** 40 ++ "/json", "package name '" ++ "x" ** 40 ++ "/json': the namespace '" ++ "x" ** 40 ++ "' is 40 characters; a namespace, a GitHub login, has at most 39" },
        .{ "noarch/json", "package name 'noarch/json': the namespace 'noarch' is reserved; publish in your own or an organization's namespace" },
        .{ "linux-64/json", "package name 'linux-64/json': the namespace 'linux-64' is reserved; publish in your own or an organization's namespace" },
        .{ "osx-arm64/json", "package name 'osx-arm64/json': the namespace 'osx-arm64' is reserved; publish in your own or an organization's namespace" },
        .{ "emscripten-wasm32/json", "package name 'emscripten-wasm32/json': the namespace 'emscripten-wasm32' is reserved; publish in your own or an organization's namespace" },
        .{ "index/json", "package name 'index/json': the namespace 'index' is reserved; publish in your own or an organization's namespace" },
        .{ "native-mirror/json", "package name 'native-mirror/json': the namespace 'native-mirror' is reserved; publish in your own or an organization's namespace" },
        .{ "komira-ai/", "package name 'komira-ai/': the import name is empty" },
        .{ "komira-ai/1json", "package name 'komira-ai/1json': the import name '1json' must start with a lowercase letter" },
        .{ "komira-ai/js-on", "package name 'komira-ai/js-on': the import name 'js-on' may contain only lowercase letters, digits and '_'" },
        .{ "komira-ai/a", "package name 'komira-ai/a': the name 'a' has 1 characters; a name has 2 to 64" },
        .{ "komira-ai/" ++ "y" ** 65, "package name 'komira-ai/" ++ "y" ** 65 ++ "': the name '" ++ "y" ** 65 ++ "' has 65 characters; a name has 2 to 64" },
        .{ "komira-ai/fn", "package name 'komira-ai/fn': the import name 'fn' is a Mojo keyword; choose another name" },
        .{ "komira-ai/hash", "package name 'komira-ai/hash': the import name 'hash' would shadow the Mojo builtin 'hash'; choose another name" },
        .{ "komira-ai/mopm", "package name 'komira-ai/mopm': the import name 'mopm' is reserved; choose another name" },
        .{ "komira-ai/stdlib", "package name 'komira-ai/stdlib': the import name 'stdlib' is reserved; choose another name" },
        .{ "komira-ai/collections", "package name 'komira-ai/collections': the import name 'collections' would shadow the Mojo standard library module std.collections; choose another name" },
        .{ "komira-ai/hashlib", "package name 'komira-ai/hashlib': the import name 'hashlib' would shadow the Mojo standard library module std.hashlib; choose another name" },
    };
    for (cases) |c| try expectProblem(c[1], try fullNameProblem(a, "package name", c[0]));
}

test "names that only look like a conda subdir or a reserved prefix are namespaces" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // `linux` alone, a subdir shape with a hyphen in its arch, and a reserved word with more to it are not reserved.
    for ([_][]const u8{ "linux", "osx-arm-64", "noarch-x", "indexer", "win" }) |ns| {
        try expectProblem(null, try namespaceProblem(a, "x", ns));
    }
}

test "the standard library list holds the modules people import, and only names" {
    for ([_][]const u8{ "collections", "memory", "os", "sys", "testing", "python", "hashlib", "utils", "gpu", "time" }) |m| {
        try testing.expect(isStdModule(m));
    }
    // Names of packages that stay: the list is not a substring match, and a comment line is not an entry.
    for ([_][]const u8{ "json", "hashing", "collection", "from", "", "_plugin" }) |m| {
        try testing.expect(!isStdModule(m));
    }
    var it = listLines(std_modules_text);
    var entries: usize = 0;
    while (it.next()) |raw| {
        const entry = listEntry(raw) orelse continue;
        entries += 1;
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        // Every entry is refused as an import name (some, such as iter, are builtins as well).
        try testing.expect(try nameProblem(arena_state.allocator(), "x", entry) != null);
    }
    try testing.expect(entries > 0);
}

test "the standard library list was read from the mojo-compiler each closure pins" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The closures mopm embeds (src/core/toolchain/mojo-<version>-<subdir>.json); the list is read on linux-64.
    const unit_graph = @import("unit_graph.zig");
    var pins = std.ArrayList(Pin).init(a);
    for (unit_graph.targets) |t| {
        if (!std.mem.eql(u8, t.subdir, "linux-64")) continue;
        const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, t.closure, .{});
        const version = doc.object.get("mojo").?.string;
        try pins.append(.{ .version = version, .subdir = t.subdir, .sha256 = try compilerSha(a, t.closure) });
    }
    try testing.expect(pins.items.len > 0);
    try expectProblem(null, try pinProblem(a, std_modules_text, pins.items));
}

test "a list read from another package, or naming a version no closure pins, is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const list = "# from mojo-compiler 1.0.0 linux-64 " ++ "a" ** 64 ++ "\ncollections\n";
    const pinned = [_]Pin{.{ .version = "1.0.0", .subdir = "linux-64", .sha256 = "a" ** 64 }};
    try expectProblem(null, try pinProblem(a, list, &pinned));

    const moved = [_]Pin{.{ .version = "1.0.0", .subdir = "linux-64", .sha256 = "b" ** 64 }};
    try expectProblem("toolchain/std-modules.txt was not read from mojo-compiler 1.0.0 for linux-64 (sha256 " ++ "b" ** 64 ++ "); read the list again from that package", try pinProblem(a, list, &moved));

    const added = [_]Pin{ pinned[0], .{ .version = "1.1.0", .subdir = "linux-64", .sha256 = "c" ** 64 } };
    try expectProblem("toolchain/std-modules.txt was not read from mojo-compiler 1.1.0 for linux-64 (sha256 " ++ "c" ** 64 ++ "); read the list again from that package", try pinProblem(a, list, &added));

    try expectProblem("toolchain/std-modules.txt names mojo-compiler 1.0.0 linux-64 " ++ "a" ** 64 ++ ", which no closure pins; drop the line", try pinProblem(a, list, &.{}));

    // A closure without a mojo-compiler pins no package, so no line can match it.
    try testing.expectEqualStrings("", try compilerSha(a, "{\"packages\": [{\"name\": \"libgcc\", \"sha256\": \"x\"}]}"));
}
