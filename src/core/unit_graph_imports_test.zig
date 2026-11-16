//! The unit graph refuses two packages of one import name in the closure (spec/unit-graph.md; import_names.zig), with
//! each package's shortest dependency path, before it reads a source. In a file of its own so unit_graph.zig stays
//! small; mopm_core.zig runs it.

const std = @import("std");
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");
const ug = @import("unit_graph.zig");
const install_plan = @import("install_plan.zig");

const toml_app = "[package]\nname = \"example/app\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n\n[dependencies]\n\"example/util\" = { path = \"util\" }\n";
const toml_util = "[package]\nname = \"example/util\"\nversion = \"0.3.0\"\nmojo = [\"1.0.0\"]\n\n[dependencies]\n\"{s}/app\" = {{ path = \"../app2\" }}\n";

const lock_text =
    \\{"lock_version": 3, "mojo": ["1.0.0"], "toolchain": {"1.0.0": {"linux-64": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}}, "channels": ["https://conda.mopm.dev/"], "packages": [
    \\  {"name": "example/util", "version": "0.3.0", "source": "path", "path": "util", "deps": ["other/app"]},
    \\  {"name": "other/app", "version": "0.5.0", "source": "path", "path": "app2"}
    \\]}
    \\
;

fn fakeToolchain() ug.Toolchain {
    return .{
        .mojo = "1.0.0",
        .subdir = "linux-64",
        .cc_target = "x86_64-linux-gnu.2.34",
        .closure_sha256 = "c" ** 64,
        .zig = .{ .version = "0.12.0", .url = "https://example.invalid/zig.tar.xz", .sha256 = "f" ** 64, .size = 1 },
        .components = &.{},
    };
}

test "a member with the root's import name in another namespace is refused with both paths; nothing is read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, toml_app, &diag);
    const util = try manifest.parse(a, try std.fmt.allocPrint(a, toml_util, .{"other"}), &diag);
    const members = [_]install_plan.PathDep{
        .{ .name = "util", .full_name = "example/util", .version = "0.3.0", .path = "util", .deps = &.{"other/app"}, .manifest_deps = util.dependencies },
        .{ .name = "app", .full_name = "other/app", .version = "0.5.0", .path = "app2" },
    };
    var why: []const u8 = "";
    const l = try lock.parse(a, lock_text, &why);
    // The directory holds no sources: the refusal comes first.
    try std.testing.expectError(error.Refused, ug.build(a, .{ .dir = "no-such-dir", .m = m, .members = &members, .l = l, .subdir = "linux-64", .mojo = "1.0.0", .toolchain = fakeToolchain() }, &why));
    try std.testing.expectEqualStrings(
        "2 packages in the dependency closure have the import name 'app'; Mojo imports a package by the part after '/', so a closure holds one package per import name:\n" ++
            "  example/app 1.0.0     example/app\n" ++
            "  other/app 0.5.0       example/app -> example/util 0.3.0 -> other/app 0.5.0\n" ++
            "There is no rename: drop one of the dependencies that brings them in.",
        why,
    );
}
