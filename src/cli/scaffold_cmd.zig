//! `mopm new` and `mopm init`: a new package, named `<namespace>/<name>`.
//!
//!   mopm new [<namespace>/]<name> [--lib|--bin] [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
//!   mopm init [--lib|--bin] [--name [<namespace>/]<name>] [--registry ...] [--config-dir <dir>]
//!
//! A full name is used as given, with no request. A bare name (for `init` without `--name`, the directory's) gets the
//! namespace `mopm login` stored for `--registry` (default prod). When no entry of credentials.json holds a namespace the
//! command refuses at once, asking nothing; otherwise it fetches the registry's config.json, whose `api_url` keys the
//! entry. The files are src/core/scaffold.zig's.

const std = @import("std");
const core = @import("mopm_core");
const registry_cmd = @import("registry_cmd.zig");

const ScaffoldArgs = struct {
    name: ?[]const u8 = null,
    kind: core.scaffold.Kind = .lib,
    /// `--registry`: where a bare name finds its namespace; null is prod.
    registry: ?[]const u8 = null,
    /// `--config-dir`: where credentials.json is; null is the default directory.
    config_dir: ?[]const u8 = null,
};

/// `new <name> [--lib|--bin] [--registry <r>] [--config-dir <d>]` or `init [--lib|--bin] [--name <name>] [--registry <r>]
/// [--config-dir <d>]`; null if the arguments are neither (a flag with no value or given twice, a second name).
fn scaffoldArgs(cmd: []const u8, args: []const []const u8) ?ScaffoldArgs {
    const is_new = std.mem.eql(u8, cmd, "new");
    var out = ScaffoldArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--lib")) {
            out.kind = .lib;
        } else if (std.mem.eql(u8, a, "--bin")) {
            out.kind = .bin;
        } else if (!is_new and std.mem.eql(u8, a, "--name") and i + 1 < args.len and out.name == null) {
            i += 1;
            out.name = args[i];
        } else if (std.mem.eql(u8, a, "--registry") and i + 1 < args.len and out.registry == null) {
            i += 1;
            out.registry = args[i];
        } else if (std.mem.eql(u8, a, "--config-dir") and i + 1 < args.len and out.config_dir == null) {
            i += 1;
            out.config_dir = args[i];
        } else if (is_new and a.len > 0 and a[0] != '-' and out.name == null) {
            out.name = a;
        } else return null;
    }
    if (is_new and out.name == null) return null;
    return out;
}

/// Where the name being scaffolded came from, which decides how a refusal tells the person to name it.
const NameSource = enum { positional, flag, directory };

const NameResult = union(enum) {
    /// The full name `<namespace>/<name>`.
    ok: []const u8,
    /// The message to print (exit 1).
    refused: []const u8,
};

/// The full name of the package `mopm <cmd>` makes, from the name as given (a full name or a bare one) and the namespace
/// 'mopm login' stored, if any; or why not. A full name never looks at `namespace`. Everything names.fullNameProblem refuses
/// stays refused after the namespace is put in front.
fn scaffoldName(arena: std.mem.Allocator, cmd: []const u8, given: []const u8, source: NameSource, namespace: ?[]const u8) std.mem.Allocator.Error!NameResult {
    var full = given;
    if (core.names.split(given) == null) {
        const ns = namespace orelse {
            const example = switch (source) {
                .positional => "mopm new",
                .flag, .directory => "mopm init --name",
            };
            const tail = if (source == .directory) " (the name comes from this directory)" else "";
            return .{ .refused = try std.fmt.allocPrint(arena, "mopm {s} {s} needs a namespace: run 'mopm login' (your GitHub login is your namespace) or name it, as in '{s} <your login>/{s}'{s}", .{ cmd, given, example, given, tail }) };
        };
        full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ ns, given });
    }
    if (try core.names.fullNameProblem(arena, "package name", full, .refuse)) |problem| {
        return .{ .refused = try std.fmt.allocPrint(arena, "mopm {s}: {s}", .{ cmd, problem }) };
    }
    return .{ .ok = full };
}

/// The user namespace 'mopm login' stored for the registry whose v1 API URL is `api_url`, in `<config_dir>/credentials.json`;
/// null when there is no entry, the entry has none (or an empty one), or the file cannot be read.
fn storedNamespace(arena: std.mem.Allocator, config_dir: []const u8, api_url: []const u8) ?[]const u8 {
    const entry = (core.credentials.load(arena, config_dir, api_url) catch return null) orelse return null;
    const ns = entry.namespace orelse return null;
    if (ns.len == 0) return null;
    return ns;
}

/// `mopm new` (into a new directory) and `mopm init` (into this one).
pub fn scaffoldCmd(arena: std.mem.Allocator, cmd: []const u8, args: []const []const u8, cli_version: []const u8) u8 {
    const parsed = scaffoldArgs(cmd, args) orelse {
        std.debug.print("usage: mopm new <name> [--lib|--bin] [--registry <prod|gamma|beta|url>] [--config-dir <dir>]\n       mopm init [--lib|--bin] [--name <name>] [--registry <prod|gamma|beta|url>] [--config-dir <dir>]\n", .{});
        return 2;
    };
    const is_new = std.mem.eql(u8, cmd, "new");
    var source: NameSource = if (is_new) .positional else .flag;
    const given = parsed.name orelse blk: {
        const here = std.fs.cwd().realpathAlloc(arena, ".") catch |e| {
            std.debug.print("mopm init: {s}\n", .{@errorName(e)});
            return 1;
        };
        source = .directory;
        break :blk std.fs.path.basename(here);
    };
    // A full name works offline: the registry is opened only for a bare one.
    var namespace: ?[]const u8 = null;
    // It is opened only when some login stored a namespace: with none, no registry could give one.
    if (core.names.split(given) == null) {
        const config_dir = parsed.config_dir orelse (core.credentials.defaultDir(arena) catch null);
        if (config_dir) |cd| {
            if (core.credentials.anyNamespace(arena, cd)) {
                const flags = registry_cmd.Flags{ .registry = parsed.registry orelse "prod", .config_dir = cd };
                // `open` says why the registry could not be read; the refusal below would only repeat a guess.
                const session = registry_cmd.open(arena, flags, cli_version) orelse return 1;
                namespace = storedNamespace(arena, session.config_dir, session.config.api_url);
            }
        }
    }
    const decided = scaffoldName(arena, cmd, given, source, namespace) catch return 1;
    const full = switch (decided) {
        .ok => |f| f,
        .refused => |message| {
            std.debug.print("{s}\n", .{message});
            return 1;
        },
    };
    // The directory, like src/<name>/, is named by the import name; `scaffoldName` has checked the `/`.
    const name = if (core.names.split(full)) |parts| parts.name else full;
    const files = core.scaffold.files(arena, full, parsed.kind) catch return 1;

    var dir = std.fs.cwd();
    var opened: ?std.fs.Dir = null;
    defer if (opened) |*d| d.close();
    if (is_new) {
        std.fs.cwd().makeDir(name) catch |e| {
            if (e == error.PathAlreadyExists) {
                std.debug.print("mopm new: '{s}' already exists\n", .{name});
            } else {
                std.debug.print("mopm new: {s}: {s}\n", .{ name, @errorName(e) });
            }
            return 1;
        };
        opened = std.fs.cwd().openDir(name, .{}) catch |e| {
            std.debug.print("mopm new: {s}: {s}\n", .{ name, @errorName(e) });
            return 1;
        };
        dir = opened.?;
    }
    if (core.scaffold.firstExisting(dir, files)) |path| {
        std.debug.print("mopm {s}: {s} already exists; nothing was written\n", .{ cmd, path });
        return 1;
    }
    core.scaffold.write(dir, files) catch |e| {
        std.debug.print("mopm {s}: {s}\n", .{ cmd, @errorName(e) });
        return 1;
    };
    const what = switch (parsed.kind) {
        .lib => "library",
        .bin => "binary",
    };
    const out = std.io.getStdOut().writer();
    if (is_new) {
        out.print("created {s} package '{s}' in {s}/\n", .{ what, full, name }) catch return 1;
    } else {
        out.print("created {s} package '{s}'\n", .{ what, full }) catch return 1;
    }
    return 0;
}

fn expectNamed(want: []const u8, got: NameResult) !void {
    try std.testing.expectEqualStrings("", if (got == .refused) got.refused else "");
    try std.testing.expectEqualStrings(want, got.ok);
}

fn expectRefused(want: []const u8, got: NameResult) !void {
    try std.testing.expectEqualStrings("", if (got == .ok) got.ok else "");
    try std.testing.expectEqualStrings(want, got.refused);
}

test "new and init take a full name as given, whatever namespace is stored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try expectNamed("komira-ai/json", try scaffoldName(a, "new", "komira-ai/json", .positional, null));
    try expectNamed("komira-ai/json", try scaffoldName(a, "new", "komira-ai/json", .positional, "someone-else"));
    try expectNamed("komira-ai/demo", try scaffoldName(a, "init", "komira-ai/demo", .flag, null));
    try expectNamed("komira-ai/demo", try scaffoldName(a, "init", "komira-ai/demo", .directory, "someone-else"));
}

test "new and init put the stored namespace in front of a bare name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try expectNamed("octocat/json", try scaffoldName(a, "new", "json", .positional, "octocat"));
    try expectNamed("octocat/demo", try scaffoldName(a, "init", "demo", .flag, "octocat"));
    try expectNamed("octocat/demo", try scaffoldName(a, "init", "demo", .directory, "octocat"));
}

test "new and init refuse a bare name when no namespace is stored, saying how to name it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try expectRefused(
        "mopm new json needs a namespace: run 'mopm login' (your GitHub login is your namespace) or name it, as in 'mopm new <your login>/json'",
        try scaffoldName(a, "new", "json", .positional, null),
    );
    try expectRefused(
        "mopm init demo needs a namespace: run 'mopm login' (your GitHub login is your namespace) or name it, as in 'mopm init --name <your login>/demo' (the name comes from this directory)",
        try scaffoldName(a, "init", "demo", .directory, null),
    );
    try expectRefused(
        "mopm init demo needs a namespace: run 'mopm login' (your GitHub login is your namespace) or name it, as in 'mopm init --name <your login>/demo'",
        try scaffoldName(a, "init", "demo", .flag, null),
    );
}

test "new and init refuse a name the namespace in front does not make valid, with the command's own words" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try expectRefused(
        "mopm new: package name 'octocat/async': the import name 'async' is a Mojo keyword; choose another name",
        try scaffoldName(a, "new", "async", .positional, "octocat"),
    );
    try expectRefused(
        "mopm init: package name 'octocat/collections': the import name 'collections' is a module of the Mojo standard library (std.collections); choose another name",
        try scaffoldName(a, "init", "collections", .directory, "octocat"),
    );
    try expectRefused(
        "mopm init: package name 'octocat/Demo' is not in lower case; write 'octocat/demo'",
        try scaffoldName(a, "init", "Demo", .directory, "octocat"),
    );
    // A full name is checked too, stored namespace or not.
    try expectRefused(
        "mopm new: package name 'example/async': the import name 'async' is a Mojo keyword; choose another name",
        try scaffoldName(a, "new", "example/async", .positional, null),
    );
    try expectRefused(
        "mopm init: package name 'Example/demo' is not in lower case; write 'example/demo'",
        try scaffoldName(a, "init", "Example/demo", .flag, "octocat"),
    );
    try expectRefused(
        "mopm new: package name 'a/b/c' has more than one '/'; a full name is <namespace>/<name>",
        try scaffoldName(a, "new", "a/b/c", .positional, "octocat"),
    );
}

test "new and init read the namespace of the registry's v1 API URL from credentials.json" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    // No credentials.json at all, and a directory that does not exist.
    try std.testing.expect(storedNamespace(a, dir, "https://one.example/api/v1") == null);
    const missing = try std.fs.path.join(a, &.{ dir, "absent" });
    try std.testing.expect(storedNamespace(a, missing, "https://one.example/api/v1") == null);

    try core.credentials.store(a, dir, "https://one.example/api/v1", .{ .token = "t1", .handle = "octocat", .namespace = "octocat" });
    try core.credentials.store(a, dir, "https://two.example/api/v1", .{ .token = "t2", .handle = "octocat" });
    try core.credentials.store(a, dir, "https://three.example/api/v1", .{ .token = "t3", .handle = "hubot", .namespace = "" });
    try core.credentials.store(a, dir, "https://four.example/api/v1", .{ .token = "t4", .handle = "mona", .namespace = "monalisa" });
    try std.testing.expectEqualStrings("octocat", storedNamespace(a, dir, "https://one.example/api/v1").?);
    try std.testing.expectEqualStrings("monalisa", storedNamespace(a, dir, "https://four.example/api/v1").?);
    // An entry without a namespace, an empty one, and a registry never logged in to give none.
    try std.testing.expect(storedNamespace(a, dir, "https://two.example/api/v1") == null);
    try std.testing.expect(storedNamespace(a, dir, "https://three.example/api/v1") == null);
    try std.testing.expect(storedNamespace(a, dir, "https://other.example/api/v1") == null);

    // The stored namespace then names the package.
    try expectNamed("monalisa/json", try scaffoldName(a, "new", "json", .positional, storedNamespace(a, dir, "https://four.example/api/v1")));
    try expectRefused(
        "mopm new json needs a namespace: run 'mopm login' (your GitHub login is your namespace) or name it, as in 'mopm new <your login>/json'",
        try scaffoldName(a, "new", "json", .positional, storedNamespace(a, dir, "https://two.example/api/v1")),
    );
}

test "new and init read a credentials.json that is not JSON as no namespace" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(core.credentials.file_name, "not json");
    const dir = try tmp.dir.realpathAlloc(a, ".");
    try std.testing.expect(storedNamespace(a, dir, "https://one.example/api/v1") == null);
}

test "new and init arguments" {
    try std.testing.expectEqualStrings("demo", scaffoldArgs("new", &.{ "demo", "--bin" }).?.name.?);
    try std.testing.expectEqual(core.scaffold.Kind.bin, scaffoldArgs("new", &.{ "--bin", "demo" }).?.kind);
    try std.testing.expectEqual(core.scaffold.Kind.lib, scaffoldArgs("new", &.{"demo"}).?.kind);
    try std.testing.expectEqual(core.scaffold.Kind.lib, scaffoldArgs("new", &.{ "--bin", "--lib", "demo" }).?.kind);
    try std.testing.expect(scaffoldArgs("new", &.{}) == null);
    try std.testing.expect(scaffoldArgs("new", &.{ "a", "b" }) == null);
    try std.testing.expect(scaffoldArgs("new", &.{ "--name", "a" }) == null);
    try std.testing.expectEqualStrings("x", scaffoldArgs("init", &.{ "--name", "x" }).?.name.?);
    try std.testing.expect(scaffoldArgs("init", &.{}).?.name == null);
    try std.testing.expect(scaffoldArgs("init", &.{"x"}) == null);
    try std.testing.expect(scaffoldArgs("init", &.{"--name"}) == null);
}

test "new and init take --registry and --config-dir, each once, with a value" {
    const n = scaffoldArgs("new", &.{ "json", "--registry", "gamma", "--config-dir", "/c", "--bin" }).?;
    try std.testing.expectEqualStrings("json", n.name.?);
    try std.testing.expectEqualStrings("gamma", n.registry.?);
    try std.testing.expectEqualStrings("/c", n.config_dir.?);
    try std.testing.expectEqual(core.scaffold.Kind.bin, n.kind);
    // Flags may come before the name.
    const front = scaffoldArgs("new", &.{ "--config-dir", "/c", "--registry", "beta", "json" }).?;
    try std.testing.expectEqualStrings("json", front.name.?);
    try std.testing.expectEqualStrings("beta", front.registry.?);
    const i = scaffoldArgs("init", &.{ "--registry", "http://x.example", "--name", "json", "--config-dir", "/d" }).?;
    try std.testing.expectEqualStrings("json", i.name.?);
    try std.testing.expectEqualStrings("http://x.example", i.registry.?);
    try std.testing.expectEqualStrings("/d", i.config_dir.?);
    // Left out, they are null: prod and the default config directory.
    const none = scaffoldArgs("init", &.{}).?;
    try std.testing.expect(none.registry == null);
    try std.testing.expect(none.config_dir == null);

    for ([_][]const u8{ "new", "init" }) |cmd| {
        try std.testing.expect(scaffoldArgs(cmd, &.{"--registry"}) == null);
        try std.testing.expect(scaffoldArgs(cmd, &.{"--config-dir"}) == null);
        try std.testing.expect(scaffoldArgs(cmd, &.{ "--registry", "a", "--registry", "b" }) == null);
        try std.testing.expect(scaffoldArgs(cmd, &.{ "--config-dir", "a", "--config-dir", "b" }) == null);
    }
    try std.testing.expect(scaffoldArgs("new", &.{ "json", "--registry" }) == null);
    try std.testing.expect(scaffoldArgs("init", &.{ "--name", "json", "--config-dir" }) == null);
    try std.testing.expect(scaffoldArgs("new", &.{ "--registry", "gamma" }) == null);
}
