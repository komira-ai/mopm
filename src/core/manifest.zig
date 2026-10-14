//! mopm.toml: read with the TOML subset in toml.zig, then checked against
//! spec/mopm-toml.md. Unknown tables and keys are refused, so a typo is an error
//! rather than a setting that silently does nothing.
//!
//! `writeJson` prints the checked manifest in one fixed shape (`mopm metadata`):
//! every section is present, absent optional values are null, and entries keep
//! the order of the file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const toml = @import("toml.zig");
const metadata = @import("metadata.zig");

pub const Diagnostic = toml.Diagnostic;
pub const Error = toml.Error;

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    description: ?[]const u8 = null,
    license: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    readme: ?[]const u8 = null,
};

/// Where a Mojo dependency comes from: a version requirement or a local path.
pub const Source = union(enum) { version: []const u8, path: []const u8 };

pub const Dep = struct { name: []const u8, source: Source };

/// What a native dependency asks for.
pub const NativeDepKind = enum { shared, static };

pub const NativeDep = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    kind: ?NativeDepKind = null,
};

/// `[native.<id>]`: a native library the package builds and ships.
pub const NativeLib = struct {
    id: []const u8,
    kind: metadata.Kind = .shared,
    mode: metadata.Mode = .link,
    build: ?[]const u8 = null,
    outputs: []const []const u8 = &.{},
};

pub const Bin = struct { name: []const u8, path: []const u8 };

pub const Targets = struct {
    lib: ?[]const u8 = null,
    bins: []const Bin = &.{},
    tests: []const []const u8 = &.{},
};

pub const Manifest = struct {
    package: Package,
    /// `[toolchain] mojo`: one version, or several.
    mojo: []const []const u8 = &.{},
    dependencies: []const Dep = &.{},
    dev_dependencies: []const Dep = &.{},
    native_dependencies: []const NativeDep = &.{},
    native: []const NativeLib = &.{},
    targets: Targets = .{},
};

/// Words a package may not be named: Mojo's keywords, and the builtins a
/// package of that name would shadow when imported.
const keywords = [_][]const u8{
    "alias",  "and",    "as",       "assert",   "async",  "await",  "borrowed", "break",
    "class",  "comptime", "continue", "def",    "deinit", "del",    "elif",     "else",
    "except", "finally", "fn",      "for",      "from",   "global", "if",       "import",
    "in",     "inout",  "is",       "lambda",   "let",    "mut",    "nonlocal", "not",
    "or",     "out",    "owned",    "pass",     "raise",  "raises", "read",     "ref",
    "return", "self",   "struct",   "trait",    "try",    "var",    "while",    "with",
    "yield",
};
const builtins = [_][]const u8{
    "abs",   "all",   "any",  "bool",   "chr",  "divmod", "enumerate", "float",
    "hash",  "input", "int",  "isinstance", "iter", "len", "list",     "max",
    "min",   "next",  "ord",  "pow",    "print", "range", "repr",      "reversed",
    "round", "sorted", "str", "sum",    "type", "zip",
};

fn isOneOf(word: []const u8, list: []const []const u8) bool {
    for (list) |w| {
        if (std.mem.eql(u8, w, word)) return true;
    }
    return false;
}

/// Why `name` cannot name a package (or a Mojo dependency), or null if it can:
/// a package name is a lowercase identifier that is not a Mojo keyword or
/// builtin. `what` starts the message ("package name").
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
    return null;
}

/// Parses and checks a mopm.toml, or fails with `diag` set.
pub fn parse(arena: Allocator, src: []const u8, diag: *Diagnostic) Error!Manifest {
    const root = try toml.parse(arena, src, diag);
    var c = Checker{ .arena = arena, .diag = diag };
    return c.manifest(root);
}

const Table = *const toml.Table;
const Entry = *const toml.Entry;

const Checker = struct {
    arena: Allocator,
    diag: *Diagnostic,

    fn fail(c: *Checker, at: toml.Pos, comptime fmt: []const u8, args: anytype) Error {
        return toml.fail(c.arena, c.diag, at, fmt, args);
    }

    /// Refuses any key of `t` not in `allowed`. `where` names `t` in messages.
    fn onlyKeys(c: *Checker, t: Table, where: []const u8, allowed: []const []const u8) Error!void {
        for (t.entries.items) |*e| {
            if (!isOneOf(e.key, allowed)) return c.fail(e.pos, "unknown key '{s}' in {s}", .{ e.key, where });
        }
    }

    fn table(c: *Checker, e: Entry, where: []const u8) Error!Table {
        switch (e.value) {
            .table => |t| return t,
            else => return c.fail(e.pos, "'{s}' in {s} must be a table, not {s}", .{ e.key, where, e.value.typeName() }),
        }
    }

    fn str(c: *Checker, e: Entry, where: []const u8) Error![]const u8 {
        switch (e.value) {
            .string => |s| return s,
            else => return c.fail(e.pos, "'{s}' in {s} must be a string, not {s}", .{ e.key, where, e.value.typeName() }),
        }
    }

    fn optStr(c: *Checker, t: Table, key: []const u8, where: []const u8) Error!?[]const u8 {
        const e = t.get(key) orelse return null;
        return try c.str(e, where);
    }

    fn strings(c: *Checker, e: Entry, where: []const u8) Error![]const []const u8 {
        const items = switch (e.value) {
            .array => |a| a,
            else => return c.fail(e.pos, "'{s}' in {s} must be an array of strings, not {s}", .{ e.key, where, e.value.typeName() }),
        };
        var out = std.ArrayList([]const u8).init(c.arena);
        for (items, 0..) |v, n| {
            switch (v) {
                .string => |s| try out.append(s),
                else => return c.fail(e.pos, "'{s}' in {s} must be an array of strings; element {d} is {s}", .{ e.key, where, n + 1, v.typeName() }),
            }
        }
        return try out.toOwnedSlice();
    }

    fn packageName(c: *Checker, name: []const u8, at: toml.Pos, what: []const u8) Error!void {
        if (try nameProblem(c.arena, what, name)) |message| return c.fail(at, "{s}", .{message});
    }

    fn manifest(c: *Checker, root: Table) Error!Manifest {
        try c.onlyKeys(root, "mopm.toml", &.{
            "package", "toolchain", "dependencies", "dev-dependencies", "native-dependencies", "native", "targets",
        });
        const pkg = root.get("package") orelse return c.fail(.{ .line = 1, .col = 1 }, "missing the [package] table", .{});
        var m = Manifest{ .package = try c.package(try c.table(pkg, "mopm.toml")) };
        if (root.get("toolchain")) |e| m.mojo = try c.toolchain(try c.table(e, "mopm.toml"));
        if (root.get("dependencies")) |e| m.dependencies = try c.deps(try c.table(e, "mopm.toml"), "[dependencies]");
        if (root.get("dev-dependencies")) |e| m.dev_dependencies = try c.deps(try c.table(e, "mopm.toml"), "[dev-dependencies]");
        if (root.get("native-dependencies")) |e| m.native_dependencies = try c.nativeDeps(try c.table(e, "mopm.toml"));
        if (root.get("native")) |e| m.native = try c.nativeLibs(try c.table(e, "mopm.toml"));
        if (root.get("targets")) |e| m.targets = try c.targets(try c.table(e, "mopm.toml"));
        return m;
    }

    fn package(c: *Checker, t: Table) Error!Package {
        const where = "[package]";
        try c.onlyKeys(t, where, &.{ "name", "version", "description", "license", "repository", "readme" });
        const name_e = t.get("name") orelse return c.fail(t.pos, "[package] is missing 'name'", .{});
        const name = try c.str(name_e, where);
        try c.packageName(name, name_e.pos, "package name");
        const version_e = t.get("version") orelse return c.fail(t.pos, "[package] is missing 'version'", .{});
        const version = try c.str(version_e, where);
        if (!isSemver(version)) {
            return c.fail(version_e.pos, "version '{s}' is not a semantic version (MAJOR.MINOR.PATCH, such as 0.1.0)", .{version});
        }
        return .{
            .name = name,
            .version = version,
            .description = try c.optStr(t, "description", where),
            .license = try c.optStr(t, "license", where),
            .repository = try c.optStr(t, "repository", where),
            .readme = try c.optStr(t, "readme", where),
        };
    }

    fn toolchain(c: *Checker, t: Table) Error![]const []const u8 {
        try c.onlyKeys(t, "[toolchain]", &.{"mojo"});
        const e = t.get("mojo") orelse return c.fail(t.pos, "[toolchain] is missing 'mojo'", .{});
        const versions = switch (e.value) {
            .string => |s| try c.arena.dupe([]const u8, &.{s}),
            .array => try c.strings(e, "[toolchain]"),
            else => return c.fail(e.pos, "'mojo' in [toolchain] must be a version string or an array of them, not {s}", .{e.value.typeName()}),
        };
        if (versions.len == 0) return c.fail(e.pos, "'mojo' in [toolchain] names no version", .{});
        for (versions) |v| {
            if (v.len == 0) return c.fail(e.pos, "'mojo' in [toolchain] has an empty version", .{});
        }
        return versions;
    }

    fn deps(c: *Checker, t: Table, where: []const u8) Error![]const Dep {
        var out = std.ArrayList(Dep).init(c.arena);
        for (t.entries.items) |*e| {
            try c.packageName(e.key, e.pos, "dependency name");
            const source: Source = switch (e.value) {
                .string => |s| .{ .version = s },
                .table => |sub| blk: {
                    const in = try std.fmt.allocPrint(c.arena, "dependency '{s}'", .{e.key});
                    try c.onlyKeys(sub, in, &.{ "version", "path" });
                    const version = try c.optStr(sub, "version", in);
                    const path = try c.optStr(sub, "path", in);
                    if (version != null and path != null) {
                        return c.fail(e.pos, "dependency '{s}' sets both 'version' and 'path'; use one", .{e.key});
                    }
                    if (version) |v| break :blk .{ .version = v };
                    if (path) |p| break :blk .{ .path = p };
                    return c.fail(e.pos, "dependency '{s}' needs 'version' or 'path'", .{e.key});
                },
                else => return c.fail(e.pos, "dependency '{s}' in {s} must be a version string or a table with 'version' or 'path', not {s}", .{ e.key, where, e.value.typeName() }),
            };
            switch (source) {
                .version => |v| if (v.len == 0) return c.fail(e.pos, "dependency '{s}' has an empty version requirement", .{e.key}),
                .path => |p| if (p.len == 0) return c.fail(e.pos, "dependency '{s}' has an empty path", .{e.key}),
            }
            try out.append(.{ .name = e.key, .source = source });
        }
        return try out.toOwnedSlice();
    }

    fn nativeDeps(c: *Checker, t: Table) Error![]const NativeDep {
        var out = std.ArrayList(NativeDep).init(c.arena);
        for (t.entries.items) |*e| {
            if (!isNativeName(e.key)) {
                return c.fail(e.pos, "native dependency name '{s}' may contain only letters, digits and '_', '-', '.', '+'", .{e.key});
            }
            var dep = NativeDep{ .name = e.key };
            switch (e.value) {
                .string => |s| dep.version = s,
                .table => |sub| {
                    const in = try std.fmt.allocPrint(c.arena, "native dependency '{s}'", .{e.key});
                    try c.onlyKeys(sub, in, &.{ "version", "kind" });
                    dep.version = try c.optStr(sub, "version", in);
                    if (sub.get("kind")) |k| {
                        const kind = try c.str(k, in);
                        dep.kind = std.meta.stringToEnum(NativeDepKind, kind) orelse
                            return c.fail(k.pos, "'kind' of native dependency '{s}' must be \"shared\" or \"static\", not \"{s}\"", .{ e.key, kind });
                    }
                },
                else => return c.fail(e.pos, "native dependency '{s}' must be a version string or a table, not {s}", .{ e.key, e.value.typeName() }),
            }
            try out.append(dep);
        }
        return try out.toOwnedSlice();
    }

    fn nativeLibs(c: *Checker, t: Table) Error![]const NativeLib {
        var out = std.ArrayList(NativeLib).init(c.arena);
        for (t.entries.items) |*e| {
            const in = try std.fmt.allocPrint(c.arena, "[native.{s}]", .{e.key});
            if (!isIdentifier(e.key)) {
                return c.fail(e.pos, "native library id '{s}' must be a lowercase identifier (letters, digits, '_')", .{e.key});
            }
            const sub = try c.table(e, "[native]");
            try c.onlyKeys(sub, in, &.{ "kind", "mode", "build", "outputs" });
            var lib = NativeLib{ .id = e.key };
            if (sub.get("kind")) |k| {
                const kind = try c.str(k, in);
                lib.kind = std.meta.stringToEnum(metadata.Kind, kind) orelse
                    return c.fail(k.pos, "'kind' in {s} must be \"shared\", \"static\" or \"both\", not \"{s}\"", .{ in, kind });
            }
            if (sub.get("mode")) |k| {
                const mode = try c.str(k, in);
                lib.mode = std.meta.stringToEnum(metadata.Mode, mode) orelse
                    return c.fail(k.pos, "'mode' in {s} must be \"link\" or \"load\", not \"{s}\"", .{ in, mode });
            }
            lib.build = try c.optStr(sub, "build", in);
            if (sub.get("outputs")) |o| lib.outputs = try c.strings(o, in);
            try out.append(lib);
        }
        return try out.toOwnedSlice();
    }

    fn targets(c: *Checker, t: Table) Error!Targets {
        const where = "[targets]";
        try c.onlyKeys(t, where, &.{ "lib", "bins", "tests" });
        var out = Targets{};
        if (t.get("lib")) |e| {
            const lib = try c.table(e, where);
            try c.onlyKeys(lib, "[targets] lib", &.{"path"});
            const path = lib.get("path") orelse return c.fail(e.pos, "'lib' in [targets] needs a 'path'", .{});
            out.lib = try c.str(path, "[targets] lib");
        }
        if (t.get("bins")) |e| {
            const items = switch (e.value) {
                .array => |a| a,
                else => return c.fail(e.pos, "'bins' in [targets] must be an array of tables, not {s}", .{e.value.typeName()}),
            };
            var bins = std.ArrayList(Bin).init(c.arena);
            for (items, 0..) |v, n| {
                const bin = switch (v) {
                    .table => |b| b,
                    else => return c.fail(e.pos, "'bins' in [targets]: element {d} must be a table with 'name' and 'path', not {s}", .{ n + 1, v.typeName() }),
                };
                try c.onlyKeys(bin, "a [targets] bin", &.{ "name", "path" });
                const name = bin.get("name") orelse return c.fail(bin.pos, "a [targets] bin needs a 'name'", .{});
                const path = bin.get("path") orelse return c.fail(bin.pos, "a [targets] bin needs a 'path'", .{});
                try bins.append(.{ .name = try c.str(name, "a [targets] bin"), .path = try c.str(path, "a [targets] bin") });
            }
            out.bins = try bins.toOwnedSlice();
        }
        if (t.get("tests")) |e| out.tests = try c.strings(e, where);
        return out;
    }
};

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isLower(s[0])) return false;
    for (s) |b| {
        if (!std.ascii.isLower(b) and !std.ascii.isDigit(b) and b != '_') return false;
    }
    return true;
}

fn isNativeName(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphanumeric(s[0])) return false;
    for (s) |b| {
        if (!std.ascii.isAlphanumeric(b) and b != '_' and b != '-' and b != '.' and b != '+') return false;
    }
    return true;
}

/// MAJOR.MINOR.PATCH with an optional `-pre.release` and `+build`, as semver.org.
fn isSemver(v: []const u8) bool {
    var rest = v;
    if (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
        if (!dotIdents(rest[plus + 1 ..])) return false;
        rest = rest[0..plus];
    }
    if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
        if (!dotIdents(rest[dash + 1 ..])) return false;
        rest = rest[0..dash];
    }
    var it = std.mem.splitScalar(u8, rest, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (part.len == 0) return false;
        for (part) |d| {
            if (!std.ascii.isDigit(d)) return false;
        }
        if (part.len > 1 and part[0] == '0') return false;
    }
    return n == 3;
}

fn dotIdents(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        if (part.len == 0) return false;
        for (part) |b| {
            if (!std.ascii.isAlphanumeric(b) and b != '-') return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// JSON (`mopm metadata`)
// ---------------------------------------------------------------------------

/// Writes `m` as JSON, ending with a newline.
pub fn writeJson(m: Manifest, w: anytype) !void {
    const p = m.package;
    try w.writeAll("{\n  \"package\": {\n    \"name\": ");
    try jsonStr(w, p.name);
    try w.writeAll(",\n    \"version\": ");
    try jsonStr(w, p.version);
    try w.writeAll(",\n    \"description\": ");
    try jsonOpt(w, p.description);
    try w.writeAll(",\n    \"license\": ");
    try jsonOpt(w, p.license);
    try w.writeAll(",\n    \"repository\": ");
    try jsonOpt(w, p.repository);
    try w.writeAll(",\n    \"readme\": ");
    try jsonOpt(w, p.readme);
    try w.writeAll("\n  },\n  \"toolchain\": {\n    \"mojo\": ");
    try jsonStrList(w, m.mojo);
    try w.writeAll("\n  },\n  \"dependencies\": ");
    try jsonObjects(w, m.dependencies, writeDep);
    try w.writeAll(",\n  \"dev-dependencies\": ");
    try jsonObjects(w, m.dev_dependencies, writeDep);
    try w.writeAll(",\n  \"native-dependencies\": ");
    try jsonObjects(w, m.native_dependencies, writeNativeDep);
    try w.writeAll(",\n  \"native\": ");
    try jsonObjects(w, m.native, writeNativeLib);
    try w.writeAll(",\n  \"targets\": {\n    \"lib\": ");
    if (m.targets.lib) |path| {
        try w.writeAll("{\"path\": ");
        try jsonStr(w, path);
        try w.writeAll("}");
    } else try w.writeAll("null");
    try w.writeAll(",\n    \"bins\": [");
    for (m.targets.bins, 0..) |b, n| {
        if (n > 0) try w.writeAll(", ");
        try w.writeAll("{\"name\": ");
        try jsonStr(w, b.name);
        try w.writeAll(", \"path\": ");
        try jsonStr(w, b.path);
        try w.writeAll("}");
    }
    try w.writeAll("],\n    \"tests\": ");
    try jsonStrList(w, m.targets.tests);
    try w.writeAll("\n  }\n}\n");
}

fn writeDep(w: anytype, d: Dep) !void {
    try w.writeAll("{\"name\": ");
    try jsonStr(w, d.name);
    switch (d.source) {
        .version => |v| {
            try w.writeAll(", \"version\": ");
            try jsonStr(w, v);
        },
        .path => |v| {
            try w.writeAll(", \"path\": ");
            try jsonStr(w, v);
        },
    }
    try w.writeAll("}");
}

fn writeNativeDep(w: anytype, d: NativeDep) !void {
    try w.writeAll("{\"name\": ");
    try jsonStr(w, d.name);
    try w.writeAll(", \"version\": ");
    try jsonOpt(w, d.version);
    try w.writeAll(", \"kind\": ");
    try jsonOpt(w, if (d.kind) |k| @tagName(k) else null);
    try w.writeAll("}");
}

fn writeNativeLib(w: anytype, l: NativeLib) !void {
    try w.writeAll("{\"id\": ");
    try jsonStr(w, l.id);
    try w.writeAll(", \"kind\": ");
    try jsonStr(w, @tagName(l.kind));
    try w.writeAll(", \"mode\": ");
    try jsonStr(w, @tagName(l.mode));
    try w.writeAll(", \"build\": ");
    try jsonOpt(w, l.build);
    try w.writeAll(", \"outputs\": ");
    try jsonStrList(w, l.outputs);
    try w.writeAll("}");
}

/// `[]`, or one object per line.
fn jsonObjects(w: anytype, items: anytype, comptime each: anytype) !void {
    if (items.len == 0) return w.writeAll("[]");
    try w.writeAll("[\n");
    for (items, 0..) |item, n| {
        try w.writeAll("    ");
        try each(w, item);
        try w.writeAll(if (n + 1 < items.len) ",\n" else "\n");
    }
    try w.writeAll("  ]");
}

fn jsonStrList(w: anytype, items: []const []const u8) !void {
    try w.writeAll("[");
    for (items, 0..) |s, n| {
        if (n > 0) try w.writeAll(", ");
        try jsonStr(w, s);
    }
    try w.writeAll("]");
}

fn jsonOpt(w: anytype, s: ?[]const u8) !void {
    if (s) |v| return jsonStr(w, v);
    try w.writeAll("null");
}

fn jsonStr(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |b| {
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{b}),
            else => try w.writeByte(b),
        }
    }
    try w.writeAll("\"");
}

// ---------------------------------------------------------------------------
// Golden tests: tests/manifest/{valid,invalid}. Run from the repository root.
// ---------------------------------------------------------------------------

/// Calls `check(arena, name, toml_source, expected)` for each `<name>.toml` in
/// `dir_path` and its `<name>.<want_ext>`; fails if the directory has none.
fn eachGolden(dir_path: []const u8, want_ext: []const u8, comptime check: anytype) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var seen: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".toml")) continue;
        seen += 1;
        const name = try arena.dupe(u8, entry.name);
        const src = try dir.readFileAlloc(arena, name, 1 << 20);
        const want_name = try std.fmt.allocPrint(arena, "{s}.{s}", .{ name[0 .. name.len - ".toml".len], want_ext });
        const want = try dir.readFileAlloc(arena, want_name, 1 << 20);
        check(arena, src, want) catch |e| {
            std.debug.print("golden case {s}/{s} failed\n", .{ dir_path, name });
            return e;
        };
    }
    try std.testing.expect(seen > 0);
}

fn checkValid(arena: Allocator, src: []const u8, want: []const u8) !void {
    var diag: Diagnostic = .{};
    const m = parse(arena, src, &diag) catch |e| {
        std.debug.print("refused at {d}:{d}: {s}\n", .{ diag.pos.line, diag.pos.col, diag.message });
        return e;
    };
    var out = std.ArrayList(u8).init(arena);
    try writeJson(m, out.writer());
    try std.testing.expectEqualStrings(want, out.items);
}

fn checkInvalid(arena: Allocator, src: []const u8, want: []const u8) !void {
    var diag: Diagnostic = .{};
    if (parse(arena, src, &diag)) |_| {
        std.debug.print("accepted a manifest that must be refused\n", .{});
        return error.TestUnexpectedResult;
    } else |e| {
        if (e != error.Invalid) return e;
    }
    const got = try std.fmt.allocPrint(arena, "{d}:{d}: {s}\n", .{ diag.pos.line, diag.pos.col, diag.message });
    try std.testing.expectEqualStrings(want, got);
}

test "golden: each tests/manifest/valid/<name>.toml prints <name>.json" {
    try eachGolden("tests/manifest/valid", "json", checkValid);
}

test "golden: each tests/manifest/invalid/<name>.toml is refused with <name>.err" {
    try eachGolden("tests/manifest/invalid", "err", checkInvalid);
}

test "semantic versions" {
    for ([_][]const u8{ "0.1.0", "1.2.3", "10.0.0-rc.1", "1.0.0+build.5", "1.0.0-alpha-1" }) |v| {
        try std.testing.expect(isSemver(v));
    }
    for ([_][]const u8{ "1.0", "1.0.0.0", "01.0.0", "1.0.0-", "1.0.0+", "v1.0.0", "1..0", "" }) |v| {
        try std.testing.expect(!isSemver(v));
    }
}
