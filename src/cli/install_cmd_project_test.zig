//! Reading a project's manifest and its path dependencies (install_cmd.zig `projectOf`, `parseManifestFor`,
//! `parseLock`): what each failure of that reading refuses, and the requirements a path dependency passes on.

const std = @import("std");
const core = @import("mopm_core");
const manifest = core.manifest;
const install_cmd = @import("install_cmd.zig");

const pkg = "[package]\nname = \"{s}\"\nversion = \"0.1.0\"\n";

/// The project of the root manifest of package `example/app` with `deps` as its [dependencies] lines.
fn projectWith(a: std.mem.Allocator, deps: []const u8) !?install_cmd.Project {
    const text = try std.fmt.allocPrint(a, pkg ++ "\n[dependencies]\n{s}", .{ "example/app", deps });
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, text, &diag);
    return install_cmd.projectOf(a, .lock, m);
}

test "a path dependency with no mopm.toml, or one that cannot be read, refuses the project" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    try tmp.dir.makePath("empty");
    // mopm.toml is a directory: reading it fails with something other than FileNotFound.
    try tmp.dir.makePath("unreadable/mopm.toml");
    const missing = try std.fmt.allocPrint(a, "\"example/empty\" = {{ path = \"{s}/empty\" }}\n", .{root});
    try std.testing.expect((try projectWith(a, missing)) == null);
    const unreadable = try std.fmt.allocPrint(a, "\"example/unreadable\" = {{ path = \"{s}/unreadable\" }}\n", .{root});
    try std.testing.expect((try projectWith(a, unreadable)) == null);
}

test "a path dependency whose mopm.toml names another package is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    try tmp.dir.makePath("util");
    try tmp.dir.writeFile("util/mopm.toml", try std.fmt.allocPrint(a, pkg, .{"other/util"}));
    const deps = try std.fmt.allocPrint(a, "\"example/util\" = {{ path = \"{s}/util\" }}\n", .{root});
    try std.testing.expect((try projectWith(a, deps)) == null);
}

test "one path dependency reached at two different paths is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    try tmp.dir.makePath("util1");
    try tmp.dir.makePath("util2");
    try tmp.dir.makePath("mid");
    try tmp.dir.writeFile("util1/mopm.toml", try std.fmt.allocPrint(a, pkg, .{"example/util"}));
    try tmp.dir.writeFile("util2/mopm.toml", try std.fmt.allocPrint(a, pkg, .{"example/util"}));
    // mid calls example/util by another path than the root does.
    try tmp.dir.writeFile("mid/mopm.toml", try std.fmt.allocPrint(a, pkg ++ "\n[dependencies]\n\"example/util\" = {{ path = \"../util2\" }}\n", .{"example/mid"}));
    const deps = try std.fmt.allocPrint(a, "\"example/util\" = {{ path = \"{s}/util1\" }}\n\"example/mid\" = {{ path = \"{s}/mid\" }}\n", .{ root, root });
    try std.testing.expect((try projectWith(a, deps)) == null);
}

test "the registry requirements of a path dependency join the project's, and its dependency names are listed sorted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    try tmp.dir.makePath("util");
    try tmp.dir.writeFile("util/mopm.toml", try std.fmt.allocPrint(a, pkg ++ "\n[dependencies]\n\"example/zeta\" = \"0.1\"\n\"example/alpha\" = \"0.2\"\n", .{"example/util"}));
    const text = try std.fmt.allocPrint(
        a,
        pkg ++ "\n[dependencies]\n\"example/util\" = {{ path = \"{s}/util\" }}\n\"example/json\" = \"0.3\"\n\n[dev-dependencies]\n\"example/test_kit\" = \"0.4\"\n",
        .{ "example/app", root },
    );
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, text, &diag);
    const p = (try install_cmd.projectOf(a, .lock, m)).?;
    try std.testing.expectEqual(@as(usize, 4), p.roots.len);
    var seen = [_]bool{false} ** 4;
    const names = [_][]const u8{ "example/zeta", "example/alpha", "example/json", "example/test_kit" };
    for (p.roots) |r| {
        for (names, 0..) |n, i| {
            if (std.mem.eql(u8, r.name, n)) seen[i] = true;
        }
    }
    try std.testing.expectEqualSlices(bool, &[_]bool{ true, true, true, true }, &seen);
    try std.testing.expectEqual(@as(usize, 1), p.paths.len);
    try std.testing.expectEqual(@as(usize, 2), p.paths[0].deps.len);
    try std.testing.expectEqualStrings("example/alpha", p.paths[0].deps[0]);
    try std.testing.expectEqualStrings("example/zeta", p.paths[0].deps[1]);
    try std.testing.expectEqual(@as(usize, 2), p.deps.len);
    try std.testing.expectEqualStrings("example/util", p.deps[0]);
    try std.testing.expectEqualStrings("example/json", p.deps[1]);
    try std.testing.expectEqual(@as(usize, 1), p.dev_deps.len);
    try std.testing.expectEqualStrings("example/test_kit", p.dev_deps[0]);
}

test "a manifest that does not parse is refused whether or not a registry lookup is given, and a failed allocation too" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // No credentials in this directory: the refusal of the bare name is not reworded, and no registry is asked.
    const lookup = install_cmd.Lookup{ .registry = "nonsense", .cli_version = "0.0.1", .config_dir = try std.fmt.allocPrint(a, "{s}/none", .{try tmp.dir.realpathAlloc(a, ".")}) };
    try std.testing.expect((try install_cmd.parseManifestFor(a, .lock, "mopm.toml", "[package]\nname = \"json\"\nversion = \"0.1.0\"\n", lookup)) == null);
    try std.testing.expect((try install_cmd.parseManifestFor(a, .lock, "mopm.toml", "[package\n", lookup)) == null);
    try std.testing.expect((try install_cmd.parseManifest(a, .lock, "mopm.toml", "[package\n")) == null);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect((try install_cmd.parseManifest(failing.allocator(), .lock, "mopm.toml", "[package]\nname = \"example/app\"\nversion = \"0.1.0\"\n")) == null);
}

test "a lock that cannot be read for want of memory reports out of memory, not an invalid lock" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var stale: ?[]const u8 = null;
    try std.testing.expectError(error.OutOfMemory, install_cmd.parseLock(failing.allocator(), .lock, "{}", &stale));
    try std.testing.expect(stale == null);
}
