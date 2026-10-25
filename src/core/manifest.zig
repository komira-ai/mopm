//! mopm.toml: read with the TOML subset in toml.zig, then checked against
//! spec/mopm-toml.md. Unknown tables and keys are refused, so a typo is an error
//! rather than a setting that silently does nothing; `[package.metadata]` is the one place a
//! tool other than mopm keeps its settings, and mopm neither checks nor changes it.
//!
//! `writeJson` prints the checked manifest in one fixed shape (`mopm metadata`):
//! every section is present, absent optional values are null, and entries keep
//! the order of the file (`metadata`, under `package`, only when the file has `[package.metadata]`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const toml = @import("toml.zig");
const metadata = @import("metadata.zig");
const semver = @import("semver.zig");

pub const Diagnostic = toml.Diagnostic;
pub const Error = toml.Error;

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    description: ?[]const u8 = null,
    license: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    readme: ?[]const u8 = null,
    /// `[package.metadata]`: settings of other tools. mopm checks nothing in it and keeps it as written
    /// (spec/mopm-toml.md, "Other tools' settings"); null when absent.
    metadata: ?*const toml.Table = null,
};

/// Where a Mojo dependency comes from: a version requirement or a local path.
pub const Source = union(enum) { version: []const u8, path: []const u8 };

/// `requirement` is the `version` of a dependency that also has a `path`: `source` is then the path (lock, build
/// and sync use it), and the requirement is what `pack` and `publish` write in its place.
pub const Dep = struct { name: []const u8, source: Source, requirement: ?[]const u8 = null };

/// What a native dependency asks for.
pub const NativeDepKind = enum { shared, static };

pub const NativeDep = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    kind: ?NativeDepKind = null,
    /// `link`: mopm computes the linker flags. `load`: the package loads the
    /// library itself at run time.
    mode: metadata.Mode = .link,
};

/// `[native.<id>]`: a native library the package builds and ships.
pub const NativeLib = struct {
    id: []const u8,
    kind: metadata.Kind = .shared,
    mode: metadata.Mode = .link,
    build: ?[]const u8 = null,
    outputs: []const []const u8 = &.{},
    /// Sonames of other packages' native libraries this one needs (the static link order, and the diagnostics of a
    /// closure that lacks one).
    needs: []const []const u8 = &.{},
    /// An exclusivity group: a closure may hold one owner per group. "" for none.
    exclusive: []const u8 = "",
    /// The archive's file name (`lib<name>.a`); "" for `lib<id>.a`. Meant for a native the build system builds (`srcs`).
    soname: []const u8 = "",
    /// Globs, relative to the package, of the C sources and headers of a native the build system builds.
    srcs: []const []const u8 = &.{},
    hdrs: []const []const u8 = &.{},
    /// Compiler flags for every platform, then those of one OS appended after them.
    cflags: []const []const u8 = &.{},
    cflags_by_os: OsFlags = .{},
    /// Include directories, relative to the package; empty means the directories holding `hdrs` files.
    includes: []const []const u8 = &.{},

    /// The archive file name: `soname`, else `lib<id>.a`.
    pub fn archiveName(self: NativeLib, arena: Allocator) Allocator.Error![]const u8 {
        if (self.soname.len > 0) return self.soname;
        return std.fmt.allocPrint(arena, "lib{s}.a", .{self.id});
    }
};

/// `cflags_by_os`: the operating systems a native's flags can be given for.
pub const OsFlags = struct {
    linux: []const []const u8 = &.{},
    macos: []const []const u8 = &.{},
};

pub const Bin = struct { name: []const u8, path: []const u8 };

pub const Targets = struct {
    lib: ?[]const u8 = null,
    bins: []const Bin = &.{},
    tests: []const []const u8 = &.{},
};

pub const Manifest = struct {
    package: Package,
    /// The Mojo versions, from `[package] mojo` (`mojo_all`) or `[toolchain] mojo`.
    mojo: []const []const u8 = &.{},
    /// `[package] mojo`: the package builds for every version listed (one
    /// `.mojoc` each), and a lock covers all of them. `[toolchain] mojo`, the
    /// older form, lists alternatives: a lock is for the first that resolves.
    mojo_all: bool = false,
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
        const pkg_table = try c.table(pkg, "mopm.toml");
        var m = Manifest{ .package = try c.package(pkg_table) };
        if (pkg_table.get("mojo")) |e| {
            if (root.get("toolchain") != null) return c.fail(e.pos, "mojo is set in [package] and in [toolchain]; keep [package] mojo", .{});
            m.mojo = try c.mojoVersions(e, "[package]");
            m.mojo_all = true;
        }
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
        try c.onlyKeys(t, where, &.{ "name", "version", "description", "license", "repository", "readme", "mojo", "metadata" });
        const name_e = t.get("name") orelse return c.fail(t.pos, "[package] is missing 'name'", .{});
        const name = try c.str(name_e, where);
        try c.packageName(name, name_e.pos, "package name");
        const version_e = t.get("version") orelse return c.fail(t.pos, "[package] is missing 'version'", .{});
        const version = try c.str(version_e, where);
        if (!semver.isPackageVersion(version)) {
            return c.fail(version_e.pos, "version '{s}' must be exactly MAJOR.MINOR.PATCH (digits, no leading zeros, no pre-release or build part, such as 0.1.0)", .{version});
        }
        return .{
            .name = name,
            .version = version,
            .description = try c.optStr(t, "description", where),
            .license = try c.optStr(t, "license", where),
            .repository = try c.optStr(t, "repository", where),
            .readme = try c.optStr(t, "readme", where),
            .metadata = if (t.get("metadata")) |e| try c.table(e, where) else null,
        };
    }

    fn toolchain(c: *Checker, t: Table) Error![]const []const u8 {
        try c.onlyKeys(t, "[toolchain]", &.{"mojo"});
        const e = t.get("mojo") orelse return c.fail(t.pos, "[toolchain] is missing 'mojo'", .{});
        return c.mojoVersions(e, "[toolchain]");
    }

    /// A version string or an array of them, each exact, none repeated.
    fn mojoVersions(c: *Checker, e: Entry, where: []const u8) Error![]const []const u8 {
        const versions = switch (e.value) {
            .string => |s| try c.arena.dupe([]const u8, &.{s}),
            .array => try c.strings(e, where),
            else => return c.fail(e.pos, "'mojo' in {s} must be a version string or an array of them, not {s}", .{ where, e.value.typeName() }),
        };
        if (versions.len == 0) return c.fail(e.pos, "'mojo' in {s} names no version", .{where});
        for (versions, 0..) |v, i| {
            if (v.len == 0) return c.fail(e.pos, "'mojo' in {s} has an empty version", .{where});
            for (versions[0..i]) |u| {
                if (std.mem.eql(u8, u, v)) return c.fail(e.pos, "'mojo' in {s} lists {s} twice", .{ where, v });
            }
        }
        return versions;
    }

    fn deps(c: *Checker, t: Table, where: []const u8) Error![]const Dep {
        var out = std.ArrayList(Dep).init(c.arena);
        for (t.entries.items) |*e| {
            try c.packageName(e.key, e.pos, "dependency name");
            var requirement: ?[]const u8 = null;
            const source: Source = switch (e.value) {
                .string => |s| .{ .version = s },
                .table => |sub| blk: {
                    const in = try std.fmt.allocPrint(c.arena, "dependency '{s}'", .{e.key});
                    try c.onlyKeys(sub, in, &.{ "version", "path" });
                    const version = try c.optStr(sub, "version", in);
                    const path = try c.optStr(sub, "path", in);
                    if (version != null and path != null) {
                        requirement = version;
                        break :blk .{ .path = path.? };
                    }
                    if (version) |v| break :blk .{ .version = v };
                    if (path) |p| break :blk .{ .path = p };
                    return c.fail(e.pos, "dependency '{s}' needs 'version' or 'path'", .{e.key});
                },
                else => return c.fail(e.pos, "dependency '{s}' in {s} must be a version string or a table with 'version' or 'path', not {s}", .{ e.key, where, e.value.typeName() }),
            };
            if (source == .path and source.path.len == 0) return c.fail(e.pos, "dependency '{s}' has an empty path", .{e.key});
            // The requirement of a path dependency is checked like any other: pack writes it into the published package.
            const req_text: ?[]const u8 = if (requirement) |r| r else if (source == .version) source.version else null;
            if (req_text) |v| {
                var why: []const u8 = "";
                _ = semver.parseReq(c.arena, v, &why) catch |err| switch (err) {
                    error.Invalid => return c.fail(e.pos, "dependency '{s}' has an invalid version requirement '{s}': {s}", .{ e.key, v, why }),
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
            try out.append(.{ .name = e.key, .source = source, .requirement = requirement });
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
                    try c.onlyKeys(sub, in, &.{ "version", "kind", "mode" });
                    dep.version = try c.optStr(sub, "version", in);
                    if (sub.get("kind")) |k| {
                        const kind = try c.str(k, in);
                        dep.kind = std.meta.stringToEnum(NativeDepKind, kind) orelse
                            return c.fail(k.pos, "'kind' of native dependency '{s}' must be \"shared\" or \"static\", not \"{s}\"", .{ e.key, kind });
                    }
                    if (sub.get("mode")) |k| {
                        const mode = try c.str(k, in);
                        dep.mode = std.meta.stringToEnum(metadata.Mode, mode) orelse
                            return c.fail(k.pos, "'mode' of native dependency '{s}' must be \"link\" or \"load\", not \"{s}\"", .{ e.key, mode });
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
            try c.onlyKeys(sub, in, &.{ "kind", "mode", "build", "outputs", "needs", "exclusive", "soname", "srcs", "hdrs", "cflags", "cflags_by_os", "includes" });
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
            if (sub.get("needs")) |o| lib.needs = try c.strings(o, in);
            if (try c.optStr(sub, "exclusive", in)) |x| {
                if (x.len == 0) return c.fail(sub.get("exclusive").?.pos, "'exclusive' in {s} must not be empty", .{in});
                if (std.ascii.isWhitespace(x[0]) or std.ascii.isWhitespace(x[x.len - 1])) {
                    return c.fail(sub.get("exclusive").?.pos, "'exclusive' in {s} must not start or end with whitespace (groups are compared exactly)", .{in});
                }
                for (x) |ch| {
                    if (ch < 0x20 or ch == 0x7f) return c.fail(sub.get("exclusive").?.pos, "'exclusive' in {s} must not contain a control character", .{in});
                }
                lib.exclusive = x;
            }
            if (try c.optStr(sub, "soname", in)) |s| {
                if (!isArchiveName(s)) {
                    return c.fail(sub.get("soname").?.pos, "'soname' in {s} must be an archive name lib<name>.a with no other dot, not \"{s}\"", .{ in, s });
                }
                lib.soname = s;
            }
            lib.srcs = try c.memberPaths(sub, "srcs", in, false);
            lib.hdrs = try c.memberPaths(sub, "hdrs", in, false);
            lib.includes = try c.memberPaths(sub, "includes", in, true);
            if (sub.get("cflags")) |o| lib.cflags = try c.strings(o, in);
            if (sub.get("cflags_by_os")) |o| {
                const by_os = try c.table(o, in);
                const where = try std.fmt.allocPrint(c.arena, "cflags_by_os of {s}", .{in});
                for (by_os.entries.items) |*oe| {
                    if (std.mem.eql(u8, oe.key, "linux")) {
                        lib.cflags_by_os.linux = try c.strings(oe, where);
                    } else if (std.mem.eql(u8, oe.key, "macos")) {
                        lib.cflags_by_os.macos = try c.strings(oe, where);
                    } else {
                        return c.fail(oe.pos, "unknown operating system '{s}' in {s}; the known ones are linux and macos", .{ oe.key, where });
                    }
                }
            }
            try out.append(lib);
        }
        return try out.toOwnedSlice();
    }

    /// The array of package-relative paths or globs at `key` of `sub` (empty when absent); a path that is empty,
    /// absolute or leaves the package is refused. `dot_ok`: a lone "." (the package directory) is allowed.
    fn memberPaths(c: *Checker, sub: Table, key: []const u8, in: []const u8, dot_ok: bool) Error![]const []const u8 {
        const e = sub.get(key) orelse return &.{};
        const items = try c.strings(e, in);
        for (items) |p| {
            if (memberPathProblem(p, dot_ok)) |why| return c.fail(e.pos, "'{s}' in {s}: \"{s}\" {s}", .{ key, in, p, why });
        }
        return items;
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

/// Why `p` is not a path inside the package, or null.
fn memberPathProblem(p: []const u8, dot_ok: bool) ?[]const u8 {
    if (p.len == 0) return "is empty";
    if (p[0] == '/') return "is absolute; write it relative to the package";
    if (dot_ok and std.mem.eql(u8, p, ".")) return null;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return "has an empty path segment";
        if (std.mem.eql(u8, seg, "..")) return "leaves the package with '..'";
        if (std.mem.eql(u8, seg, ".")) return "has a '.' segment; leave it out";
    }
    return null;
}

/// `lib<name>.a`, the name of a static archive: no other dot, no slash.
fn isArchiveName(s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, "lib") or !std.mem.endsWith(u8, s, ".a")) return false;
    const stem = s[3 .. s.len - 2];
    if (stem.len == 0) return false;
    for (stem) |ch| {
        if (ch == '.' or ch == '/') return false;
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
    if (p.metadata) |t| {
        try w.writeAll(",\n    \"metadata\": ");
        try jsonTable(w, t);
    }
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
            if (d.requirement) |r| {
                try w.writeAll(", \"version\": ");
                try jsonStr(w, r);
            }
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
    try w.writeAll(", \"mode\": ");
    try jsonStr(w, @tagName(d.mode));
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
    // Left out when absent, so that the output for a manifest that never used them is what it was.
    if (l.needs.len > 0) {
        try w.writeAll(", \"needs\": ");
        try jsonStrList(w, l.needs);
    }
    if (l.exclusive.len > 0) {
        try w.writeAll(", \"exclusive\": ");
        try jsonStr(w, l.exclusive);
    }
    if (l.soname.len > 0) {
        try w.writeAll(", \"soname\": ");
        try jsonStr(w, l.soname);
    }
    const lists = [_]struct { key: []const u8, items: []const []const u8 }{
        .{ .key = "srcs", .items = l.srcs },
        .{ .key = "hdrs", .items = l.hdrs },
        .{ .key = "cflags", .items = l.cflags },
        .{ .key = "includes", .items = l.includes },
    };
    for (lists) |x| {
        if (x.items.len == 0) continue;
        try w.print(", \"{s}\": ", .{x.key});
        try jsonStrList(w, x.items);
    }
    if (l.cflags_by_os.linux.len > 0 or l.cflags_by_os.macos.len > 0) {
        try w.writeAll(", \"cflags_by_os\": {");
        var first = true;
        if (l.cflags_by_os.linux.len > 0) {
            try w.writeAll("\"linux\": ");
            try jsonStrList(w, l.cflags_by_os.linux);
            first = false;
        }
        if (l.cflags_by_os.macos.len > 0) {
            if (!first) try w.writeAll(", ");
            try w.writeAll("\"macos\": ");
            try jsonStrList(w, l.cflags_by_os.macos);
        }
        try w.writeAll("}");
    }
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

/// A TOML value as JSON (tables in file order). Only `[package.metadata]` is written this way.
fn jsonValue(w: anytype, v: toml.Value) anyerror!void {
    switch (v) {
        .string => |s| try jsonStr(w, s),
        .integer => |i| try w.print("{d}", .{i}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .array => |items| {
            try w.writeAll("[");
            for (items, 0..) |item, n| {
                if (n > 0) try w.writeAll(", ");
                try jsonValue(w, item);
            }
            try w.writeAll("]");
        },
        .table => |t| try jsonTable(w, t),
    }
}

fn jsonTable(w: anytype, t: *const toml.Table) anyerror!void {
    try w.writeAll("{");
    for (t.entries.items, 0..) |e, n| {
        if (n > 0) try w.writeAll(", ");
        try jsonStr(w, e.key);
        try w.writeAll(": ");
        try jsonValue(w, e.value);
    }
    try w.writeAll("}");
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

test "a dependency with a path and a version keeps both; the path is its source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};
    const head = "[package]\nname = \"a\"\nversion = \"0.1.0\"\n\n[dependencies]\n";
    const m = try parse(arena, head ++ "both = { version = \"^0.3\", path = \"../both\" }\nonly_path = { path = \"../p\" }\nonly_version = \"1\"\n", &diag);
    try std.testing.expectEqual(@as(usize, 3), m.dependencies.len);
    try std.testing.expectEqualStrings("../both", m.dependencies[0].source.path);
    try std.testing.expectEqualStrings("^0.3", m.dependencies[0].requirement.?);
    try std.testing.expectEqualStrings("../p", m.dependencies[1].source.path);
    try std.testing.expect(m.dependencies[1].requirement == null);
    try std.testing.expectEqualStrings("1", m.dependencies[2].source.version);
    try std.testing.expect(m.dependencies[2].requirement == null);

    // Each half is still checked: the requirement is a requirement, the path is not empty, a third key is unknown.
    try std.testing.expectError(error.Invalid, parse(arena, head ++ "b = { version = \"=>1\", path = \"../b\" }\n", &diag));
    try std.testing.expectError(error.Invalid, parse(arena, head ++ "b = { version = \"1\", path = \"\" }\n", &diag));
    try std.testing.expectError(error.Invalid, parse(arena, head ++ "b = { version = \"1\", path = \"../b\", git = \"x\" }\n", &diag));
}

test "a package's own version is exactly MAJOR.MINOR.PATCH; the registry takes nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};

    for ([_][]const u8{ "0.1.123", "10.20.30", "0.0.0" }) |v| {
        const src = try std.fmt.allocPrint(arena, "[package]\nname = \"a\"\nversion = \"{s}\"\n", .{v});
        const m = parse(arena, src, &diag) catch |e| {
            std.debug.print("refused {s}: {s}\n", .{ v, diag.message });
            return e;
        };
        try std.testing.expectEqualStrings(v, m.package.version);
    }

    for ([_][]const u8{ "1.0.0+b1", "1.0.0-rc.1", "1.0.0.1", "01.0.0", "1.0", "1.0.0+", "1.0.00", "1.0.0 ", "v1.0.0", "1.0.1234567890123456789" }) |v| {
        const src = try std.fmt.allocPrint(arena, "[package]\nname = \"a\"\nversion = \"{s}\"\n", .{v});
        if (parse(arena, src, &diag)) |_| {
            std.debug.print("accepted package version '{s}'\n", .{v});
            return error.TestUnexpectedResult;
        } else |e| {
            try std.testing.expectEqual(error.Invalid, e);
        }
        try std.testing.expectEqual(@as(usize, 3), diag.pos.line);
        const want = try std.fmt.allocPrint(arena, "version '{s}' must be exactly MAJOR.MINOR.PATCH", .{v});
        try std.testing.expect(std.mem.startsWith(u8, diag.message, want));
    }
}

test "dependency requirements keep the full requirement grammar" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};
    const head = "[package]\nname = \"a\"\nversion = \"0.1.0\"\n\n[dependencies]\n";
    const m = parse(arena, head ++ "b = \">=0.1,<0.2\"\nc = \"^1.2.3-rc.1\"\nd = \"~1.2\"\n", &diag) catch |e| {
        std.debug.print("refused: {s}\n", .{diag.message});
        return e;
    };
    try std.testing.expectEqual(@as(usize, 3), m.dependencies.len);
}
