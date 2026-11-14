//! Tests of import_names.zig: one package per import name in a closure, each clash reported with the shortest
//! dependency path from the root. mopm_core.zig runs them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const im = @import("import_names.zig");
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");
const install_plan = @import("install_plan.zig");

const Package = im.Package;

fn head(comptime count: []const u8, comptime name: []const u8) []const u8 {
    return count ++ " packages in the dependency closure have the import name '" ++ name ++ "'; Mojo imports a package by the part after '/', so a closure holds one package per import name:\n";
}

// Top-level, so that each is comptime-known and `++` joins it to a row.
const json_2 = head("2", "json");
const json_3 = head("3", "json");
const http_2 = head("2", "http");

const tail = "There is no rename: drop one of the dependencies that brings them in.";

fn expectClash(want: []const u8, c: im.Closure) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = (try im.check(arena_state.allocator(), c)) orelse return error.NoClashFound;
    try std.testing.expectEqualStrings(want, got);
}

fn expectNone(c: im.Closure) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    if (try im.check(arena_state.allocator(), c)) |got| {
        std.debug.print("unexpected refusal:\n{s}\n", .{got});
        return error.UnexpectedClash;
    }
}

test "two registry packages of one import name: the design's example, each with its path from the root" {
    try expectClash(json_2 ++
        "  alice/json 1.4.2         alice/app -> alice/http 0.3.0 -> alice/json 1.4.2\n" ++
        "  komira-ai/json 0.1.0     alice/app -> komira-ai/parquet 0.2.0 -> komira-ai/json 0.1.0\n" ++
        tail, .{
        .root = .{ .full = "alice/app", .label = "1.0.0", .deps = &.{ "alice/http", "komira-ai/parquet" } },
        .packages = &.{
            .{ .full = "komira-ai/parquet", .label = "0.2.0", .deps = &.{"komira-ai/json"} },
            .{ .full = "alice/http", .label = "0.3.0", .deps = &.{"alice/json"} },
            .{ .full = "komira-ai/json", .label = "0.1.0" },
            .{ .full = "alice/json", .label = "1.4.2" },
        },
    });
}

test "the root counts: its path is the root alone" {
    try expectClash(json_2 ++
        "  alice/json 0.1.0         alice/json\n" ++
        "  komira-ai/json 0.1.0     alice/json -> alice/http 0.3.0 -> komira-ai/json 0.1.0\n" ++
        tail, .{
        .root = .{ .full = "alice/json", .label = "0.1.0", .deps = &.{"alice/http"} },
        .packages = &.{
            .{ .full = "alice/http", .label = "0.3.0", .deps = &.{"komira-ai/json"} },
            .{ .full = "komira-ai/json", .label = "0.1.0" },
        },
    });
}

test "a path that starts in [dev-dependencies] is marked (dev); a dev-dependency clashes like any other" {
    try expectClash(json_2 ++
        "  alice/json 1.4.2         alice/app -> alice/json 1.4.2\n" ++
        "  komira-ai/json 0.1.0     alice/app -> alice/testkit 0.1.0 -> komira-ai/json 0.1.0 (dev)\n" ++
        tail, .{
        .root = .{ .full = "alice/app", .label = "1.0.0", .deps = &.{"alice/json"} },
        .dev_deps = &.{"alice/testkit"},
        .packages = &.{
            .{ .full = "alice/json", .label = "1.4.2" },
            .{ .full = "alice/testkit", .label = "0.1.0", .deps = &.{"komira-ai/json"} },
            .{ .full = "komira-ai/json", .label = "0.1.0" },
        },
    });
}

test "a shorter path from [dev-dependencies] wins over a longer one; at equal length [dependencies] wins" {
    // komira-ai/json is a dev-dependency itself and also two steps away through alice/http: the shorter path is shown.
    try expectClash(json_2 ++
        "  alice/json 1.4.2         alice/app -> alice/json 1.4.2\n" ++
        "  komira-ai/json 0.1.0     alice/app -> komira-ai/json 0.1.0 (dev)\n" ++
        tail, .{
        .root = .{ .full = "alice/app", .label = "1.0.0", .deps = &.{ "alice/http", "alice/json" } },
        .dev_deps = &.{"komira-ai/json"},
        .packages = &.{
            .{ .full = "alice/http", .label = "0.3.0", .deps = &.{"komira-ai/json"} },
            .{ .full = "alice/json", .label = "1.4.2" },
            .{ .full = "komira-ai/json", .label = "0.1.0" },
        },
    });
    // The same package in both tables: the path from [dependencies].
    try expectClash(json_2 ++
        "  alice/json 1.4.2         alice/app -> alice/json 1.4.2\n" ++
        "  komira-ai/json 0.1.0     alice/app -> komira-ai/json 0.1.0\n" ++
        tail, .{
        .root = .{ .full = "alice/app", .label = "1.0.0", .deps = &.{ "alice/json", "komira-ai/json" } },
        .dev_deps = &.{"komira-ai/json"},
        .packages = &.{
            .{ .full = "alice/json", .label = "1.4.2" },
            .{ .full = "komira-ai/json", .label = "0.1.0" },
        },
    });
}

test "(dev) follows a path from [dev-dependencies] down every step, and a tie at the second step goes to the lesser name" {
    // komira-ai/json is three steps away through alice/testkit and then through both alice/aa and alice/bb.
    try expectClash(json_2 ++
        "  alice/json 1.4.2         alice/app -> alice/json 1.4.2\n" ++
        "  komira-ai/json 0.1.0     alice/app -> alice/testkit 0.1.0 -> alice/aa 0.1.0 -> komira-ai/json 0.1.0 (dev)\n" ++
        tail, .{
        .root = .{ .full = "alice/app", .label = "1.0.0", .deps = &.{"alice/json"} },
        .dev_deps = &.{"alice/testkit"},
        .packages = &.{
            .{ .full = "alice/json", .label = "1.4.2" },
            .{ .full = "alice/testkit", .label = "0.1.0", .deps = &.{ "alice/bb", "alice/aa" } },
            .{ .full = "alice/bb", .label = "0.1.0", .deps = &.{"komira-ai/json"} },
            .{ .full = "alice/aa", .label = "0.1.0", .deps = &.{"komira-ai/json"} },
            .{ .full = "komira-ai/json", .label = "0.1.0" },
        },
    });
}

test "three packages of one import name are all listed, sorted by full name; a tie goes to the lesser path" {
    // bob/json is two steps away through ex/alpha and through ex/zeta: ex/alpha is the lesser name.
    try expectClash(json_3 ++
        "  alice/json 1.0.0     ex/app -> ex/zeta 0.1.0 -> alice/json 1.0.0\n" ++
        "  bob/json 2.0.0       ex/app -> ex/alpha 0.1.0 -> bob/json 2.0.0\n" ++
        "  carol/json 3.0.0     ex/app -> ex/alpha 0.1.0 -> carol/json 3.0.0\n" ++
        tail, .{
        .root = .{ .full = "ex/app", .label = "1.0.0", .deps = &.{ "ex/zeta", "ex/alpha" } },
        .packages = &.{
            .{ .full = "ex/zeta", .label = "0.1.0", .deps = &.{ "bob/json", "alice/json" } },
            .{ .full = "ex/alpha", .label = "0.1.0", .deps = &.{ "carol/json", "bob/json" } },
            .{ .full = "carol/json", .label = "3.0.0" },
            .{ .full = "bob/json", .label = "2.0.0" },
            .{ .full = "alice/json", .label = "1.0.0" },
        },
    });
}

test "a tie between paths of one length is decided by the first full name that differs, not by the last step" {
    // q/json is three steps away by p/one -> p/bb and by p/two -> p/aa. p/aa is less than p/bb, but the paths differ
    // first at p/one and p/two.
    try expectClash(json_2 ++
        "  q/json 1.0.0     t/app -> p/one 0.1.0 -> p/bb 0.1.0 -> q/json 1.0.0\n" ++
        "  r/json 1.0.0     t/app -> r/json 1.0.0\n" ++
        tail, .{
        .root = .{ .full = "t/app", .label = "1.0.0", .deps = &.{ "p/two", "r/json", "p/one" } },
        .packages = &.{
            .{ .full = "p/two", .label = "0.1.0", .deps = &.{"p/aa"} },
            .{ .full = "p/one", .label = "0.1.0", .deps = &.{ "p/cc", "p/bb" } },
            .{ .full = "p/aa", .label = "0.1.0", .deps = &.{"q/json"} },
            .{ .full = "p/bb", .label = "0.1.0", .deps = &.{"q/json"} },
            .{ .full = "p/cc", .label = "0.1.0", .deps = &.{"q/json"} },
            .{ .full = "q/json", .label = "1.0.0" },
            .{ .full = "r/json", .label = "1.0.0" },
        },
    });
}

test "two clashing import names at once: both are reported, sorted by import name, with one closing line" {
    try expectClash(http_2 ++
        "  bob/http 2.0.0     ex/app -> bob/http 2.0.0\n" ++
        "  ex/http 0.1.0      ex/app -> ex/http 0.1.0\n" ++
        json_2 ++
        "  alice/json 1.0.0     ex/app -> alice/json 1.0.0\n" ++
        "  bob/json 3.0.0       ex/app -> ex/http 0.1.0 -> bob/json 3.0.0\n" ++
        tail, .{
        .root = .{ .full = "ex/app", .label = "1.0.0", .deps = &.{ "ex/http", "alice/json", "bob/http" } },
        .packages = &.{
            .{ .full = "ex/http", .label = "0.1.0", .deps = &.{"bob/json"} },
            .{ .full = "alice/json", .label = "1.0.0" },
            .{ .full = "bob/http", .label = "2.0.0" },
            .{ .full = "bob/json", .label = "3.0.0" },
        },
    });
}

test "no clash: distinct import names, one package reached twice, a package named twice, a cycle, an unknown name" {
    try expectNone(.{ .root = .{ .full = "ex/app", .label = "1.0.0" } });
    try expectNone(.{
        .root = .{ .full = "ex/app", .label = "1.0.0", .deps = &.{ "ex/http", "ex/json", "ex/missing" } },
        .dev_deps = &.{"ex/json"},
        .packages = &.{
            .{ .full = "ex/http", .label = "0.3.0", .deps = &.{ "ex/json", "ex/app", "ex/gone" } },
            .{ .full = "ex/json", .label = "1.0.0", .deps = &.{"ex/http"} },
            .{ .full = "ex/json", .label = "2.0.0" },
        },
    });
}

test "packages the root does not reach are not in the closure and never clash" {
    try expectNone(.{
        .root = .{ .full = "ex/app", .label = "1.0.0", .deps = &.{"ex/http"} },
        .packages = &.{
            .{ .full = "ex/http", .label = "0.3.0" },
            .{ .full = "alice/json", .label = "1.0.0" },
            .{ .full = "bob/json", .label = "1.0.0", .deps = &.{"alice/json"} },
            .{ .full = "bob/http", .label = "1.0.0" },
        },
    });
}

// ------------------------------------------------------------- ofProject

fn parse(a: Allocator, text: []const u8) !manifest.Manifest {
    var diag: manifest.Diagnostic = .{};
    return manifest.parse(a, text, &diag) catch |e| {
        std.debug.print("{s}\n", .{diag.message});
        return e;
    };
}

const util_toml = "[package]\nname = \"ex/util\"\nversion = \"0.3.0\"\n\n[dependencies]\n\"alice/json\" = {s}\n";

/// ex/util, a path package whose own [dependencies] name alice/json as `dep` (a path or a requirement).
fn util(a: Allocator, dep: []const u8) !install_plan.PathDep {
    const m = try parse(a, try std.fmt.allocPrint(a, util_toml, .{dep}));
    return .{ .name = "util", .full_name = "ex/util", .version = "0.3.0", .path = "util", .deps = &.{"alice/json"}, .manifest_deps = m.dependencies };
}

const app_toml = "[package]\nname = \"ex/app\"\nversion = \"1.0.0\"\n\n[dependencies]\n\"ex/util\" = { path = \"util\" }\n\"komira-ai/json\" = \"0.1\"\n";

test "ofProject before resolution: a path package against a registry package, which shows its requirement" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const members = [_]install_plan.PathDep{
        try util(a, "{ path = \"../json\" }"),
        .{ .name = "json", .full_name = "alice/json", .version = "0.2.0", .path = "json" },
    };
    const c = try im.ofProject(a, try parse(a, app_toml), &members, null);
    try std.testing.expectEqualStrings(json_2 ++
        "  alice/json 0.2.0         ex/app -> ex/util 0.3.0 -> alice/json 0.2.0\n" ++
        "  komira-ai/json \"0.1\"     ex/app -> komira-ai/json \"0.1\"\n" ++
        tail, (try im.check(a, c)).?);
}

test "ofProject with a lock: each locked registry package is its own full name, whatever the manifests name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const members = [_]install_plan.PathDep{try util(a, "\"1\"")};
    const l = lock.Lock{ .mojo = "1.0.0", .channels = &.{}, .packages = &.{
        .{ .name = "alice/json", .version = "1.4.2" },
        .{ .name = "komira-ai/json", .version = "0.1.5" },
        .{ .name = "ex/util", .version = "0.3.0", .source = .path, .path = "util", .deps = &.{"alice/json"} },
    } };
    const c = try im.ofProject(a, try parse(a, app_toml), &members, l);
    try std.testing.expectEqualStrings(json_2 ++
        "  alice/json 1.4.2         ex/app -> ex/util 0.3.0 -> alice/json 1.4.2\n" ++
        "  komira-ai/json 0.1.5     ex/app -> komira-ai/json 0.1.5\n" ++
        tail, (try im.check(a, c)).?);
}

test "ofProject with a lock: the root against a registry package only the lock names, through every entry of its dependent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const m = try parse(a, "[package]\nname = \"ex/json\"\nversion = \"0.1.0\"\n\n[dependencies]\n\"ex/http\" = \"0.3\"\n");
    // A lock lists http once per subdir; only the second entry needs other/json.
    const l = lock.Lock{ .mojo = "1.0.0", .channels = &.{}, .packages = &.{
        .{ .name = "ex/http", .version = "0.3.0", .subdir = "linux-64" },
        .{ .name = "ex/http", .version = "0.3.0", .subdir = "osx-arm64", .deps = &.{"other/json"} },
        .{ .name = "other/json", .version = "1.2.0" },
    } };
    try std.testing.expectEqualStrings(json_2 ++
        "  ex/json 0.1.0        ex/json\n" ++
        "  other/json 1.2.0     ex/json -> ex/http 0.3.0 -> other/json 1.2.0\n" ++
        tail, (try im.check(a, try im.ofProject(a, m, &.{}, l))).?);
}

test "ofProject: a project whose path packages and lock agree has no clash, and a member known only by name has none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const members = [_]install_plan.PathDep{
        try util(a, "\"1\""),
        // A member the caller knows only by its import name (a unit graph's test fixture, say).
        .{ .name = "extra", .version = "0.1.0", .path = "extra", .deps = &.{"ex/util"} },
    };
    const m = try parse(a, "[package]\nname = \"ex/app\"\nversion = \"1.0.0\"\n\n[dependencies]\n\"ex/util\" = { path = \"util\" }\n");
    const l = lock.Lock{ .mojo = "1.0.0", .channels = &.{}, .packages = &.{
        .{ .name = "alice/json", .version = "1.4.2" },
        .{ .name = "ex/util", .version = "0.3.0", .source = .path, .path = "util", .deps = &.{"alice/json"} },
    } };
    try std.testing.expect((try im.check(a, try im.ofProject(a, m, &members, l))) == null);
    try std.testing.expect((try im.check(a, try im.ofProject(a, m, &members, null))) == null);
}
