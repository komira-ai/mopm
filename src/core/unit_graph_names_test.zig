//! Tests of the names in the unit graph (spec/unit-graph.md, format 6): a unit id and a unit's `package` carry the full
//! name `<namespace>/<name>`, `import` the import name, and the library directory, the `.mojoc` and the staged sources
//! are named by the import name. In a file of their own so unit_graph.zig stays small; mopm_core.zig runs them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");
const ug = @import("unit_graph.zig");
const install_plan = @import("install_plan.zig");

const Graph = ug.Graph;

const c_closure = "c" ** 64;

const toml_app = "[package]\nname = \"acme/app\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n\n[dependencies]\n\"acme/http\" = \"1\"\n\"komira-ai/json\" = { path = \"json\" }\n";
const toml_json = "[package]\nname = \"komira-ai/json\"\nversion = \"0.1.0\"\nmojo = [\"1.0.0\"]\n\n[native.shim]\nkind = \"static\"\nsrcs = [\"native/*.c\"]\n";

const lock_text =
    \\{"lock_version": 3, "mojo": ["1.0.0"], "toolchain": {"1.0.0": {"linux-64": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}}, "channels": ["https://conda.mopm.dev/"], "packages": [
    \\  {"name": "acme/http", "version": "1.2.5", "subdir": "linux-64", "channel": "https://conda.mopm.dev/acme/",
    \\   "artifacts": {"1.0.0": {"build": "mojo1.0.0_0", "url": "https://conda.mopm.dev/acme/linux-64/mojo-acme.http-1.2.5-mojo1.0.0_0.conda", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "size": 1000}}},
    \\  {"name": "komira-ai/json", "version": "0.1.0", "source": "path", "path": "json"}
    \\]}
    \\
;

const lock_no_http =
    \\{"lock_version": 3, "mojo": ["1.0.0"], "toolchain": {"1.0.0": {"linux-64": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}}, "channels": ["https://conda.mopm.dev/"], "packages": [
    \\  {"name": "komira-ai/json", "version": "0.1.0", "source": "path", "path": "json"}
    \\]}
    \\
;

const members = [_]install_plan.PathDep{.{ .name = "json", .full_name = "komira-ai/json", .version = "0.1.0", .path = "json" }};

const id_app = "acme/app@1.0.0#mojo1.0.0/lib";
const id_test = "acme/app@1.0.0#mojo1.0.0/test:tests/test_app.mojo";
const id_http = "acme/http@1.2.5#mojo1.0.0/lib";
const id_json = "komira-ai/json@0.1.0#mojo1.0.0/lib";
const id_native = "native:komira-ai/json/shim";

fn put(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    try dir.writeFile(path, bytes);
}

fn writeWorkspace(dir: std.fs.Dir) !void {
    try put(dir, "src/app/__init__.mojo", "def run():\n    pass\n");
    try put(dir, "tests/test_app.mojo", "def main():\n    pass\n");
    try put(dir, "json/mopm.toml", toml_json);
    try put(dir, "json/src/json/__init__.mojo", "def parse():\n    pass\n");
    try put(dir, "json/native/shim.c", "int shim(void) { return 1; }\n");
}

fn fakeToolchain() ug.Toolchain {
    return .{
        .mojo = "1.0.0",
        .subdir = "linux-64",
        .cc_target = "x86_64-linux-gnu.2.34",
        .closure_sha256 = c_closure,
        .zig = .{ .version = "0.12.0", .url = "https://example.invalid/zig.tar.xz", .sha256 = "f" ** 64, .size = 1 },
        .components = &.{},
    };
}

fn graphOf(a: Allocator, dir: []const u8, lock_json: []const u8, why: *[]const u8) !Graph {
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, toml_app, &diag);
    const l = try lock.parse(a, lock_json, why);
    return ug.build(a, .{ .dir = dir, .m = m, .members = &members, .l = l, .subdir = "linux-64", .mojo = "1.0.0", .toolchain = fakeToolchain() }, why);
}

fn unitOf(g: Graph, id: []const u8) !ug.Unit {
    return g.units[g.find(id) orelse return error.NoSuchUnit];
}

// Defect it catches: a unit id, a package or a native id keyed by the bare name, so two packages of one name in two
// namespaces are one unit; a library directory or `.mojoc` named by the full name, which has a `/` in it.
test "ids and packages are full names; the library directory, the .mojoc and the staged directory are the import name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const g = graphOf(a, dir, lock_text, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqual(@as(u32, 6), g.unit_graph);
    try std.testing.expectEqualStrings("acme/app@1.0.0", g.package);

    const app = try unitOf(g, id_app);
    try std.testing.expectEqualStrings("acme/app", app.package);
    try std.testing.expectEqualStrings("app", app.import);
    try std.testing.expectEqualStrings("src/app", app.root);
    try std.testing.expectEqualStrings("app.mojoc", app.outputs[0]);
    try std.testing.expectEqual(@as(usize, 2), app.deps.len);
    try std.testing.expectEqualStrings(id_http, app.deps[0]);
    try std.testing.expectEqualStrings(id_json, app.deps[1]);

    const tst = try unitOf(g, id_test);
    try std.testing.expectEqualStrings("acme/app", tst.package);
    try std.testing.expectEqualStrings("app", tst.import);

    // A registry package: a prebuilt unit; its `.mojoc` inside the conda package is named by the import name, and
    // its file is in the channel of its namespace.
    const http = try unitOf(g, id_http);
    try std.testing.expectEqualStrings("prebuilt", http.kind);
    try std.testing.expectEqualStrings("acme/http", http.package);
    try std.testing.expectEqualStrings("http", http.import);
    try std.testing.expectEqualStrings("lib/mojo/http.mojoc", http.mojoc);
    try std.testing.expectEqualStrings("https://conda.mopm.dev/acme/linux-64/mojo-acme.http-1.2.5-mojo1.0.0_0.conda", http.artifact.?.url);

    // A path dependency: its library directory is src/<import name>.
    const json = try unitOf(g, id_json);
    try std.testing.expectEqualStrings("komira-ai/json", json.package);
    try std.testing.expectEqualStrings("json", json.import);
    try std.testing.expectEqualStrings("json/src/json", json.root);
    try std.testing.expectEqualStrings("json.mojoc", json.outputs[0]);

    // Its native unit: `native:<full name>/<id>`, the id after the last `/`; the units that link it name the same id.
    const native = try unitOf(g, id_native);
    try std.testing.expectEqualStrings("native", native.kind);
    try std.testing.expectEqualStrings("komira-ai/json", native.package);
    try std.testing.expectEqualStrings("json", native.import);
    try std.testing.expectEqualStrings("shim", native.id[std.mem.lastIndexOfScalar(u8, native.id, '/').? + 1 ..]);
    try std.testing.expectEqualStrings("libshim.a", native.soname);
    try std.testing.expectEqual(@as(usize, 1), app.natives.len);
    try std.testing.expectEqualStrings("komira-ai/json", app.natives[0].package);
    try std.testing.expectEqualStrings(id_native, app.natives[0].built);
}

test "the printed graph has package and import on each unit, in that order, and reads back as the same graph" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const g = try graphOf(a, dir, lock_text, &why);
    const text = try ug.render(a, g);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"unit_graph\": 6,\n  \"package\": \"acme/app@1.0.0\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"id\": \"komira-ai/json@0.1.0#mojo1.0.0/lib\",\n      \"package\": \"komira-ai/json\",\n      \"import\": \"json\",\n      \"version\": \"0.1.0\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"id\": \"native:komira-ai/json/shim\",\n      \"package\": \"komira-ai/json\",\n      \"import\": \"json\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"package\": \"komira-ai/json\", \"kind\": \"static\", \"built\": \"native:komira-ai/json/shim\"}") != null);
    const back = try ug.parse(a, text);
    for (g.units, back.units) |u, v| {
        try std.testing.expectEqualStrings(u.package, v.package);
        try std.testing.expectEqualStrings(u.import, v.import);
    }
    try std.testing.expectEqualStrings(text, try ug.render(a, back));
}

test "a graph text of an older format reads (its format number is the caller's to refuse) and its units have no import name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text =
        \\{"unit_graph": 5, "package": "app@1.0.0", "mojo": "1.0.0",
        \\ "toolchain": {"mojo": "1.0.0", "subdir": "linux-64", "cc_target": "x86_64-linux-gnu.2.34", "closure_sha256": "c", "zig": {"version": "0.12.0", "url": "u", "sha256": "f", "size": 1}, "components": []},
        \\ "units": [{"id": "app@1.0.0#mojo1.0.0/lib", "package": "app", "version": "1.0.0", "kind": "lib", "root": "src/app", "deps": [], "natives": [], "outputs": ["app.mojoc"]}]}
    ;
    const g = try ug.parse(a, text);
    try std.testing.expectEqual(@as(u32, 5), g.unit_graph);
    try std.testing.expectEqualStrings("", g.units[0].import);
}

test "a dependency the lock does not hold is refused by its full name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    try std.testing.expectError(error.Refused, graphOf(a, dir, lock_no_http, &why));
    try std.testing.expectEqualStrings("acme/http is not in mopm.lock for linux-64", why);
}

test "a path dependency's library directory is src/<import name>: without it the refusal names the import name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir);
    try tmp.dir.deleteTree("json/src/json");
    // A directory named by the full name is not the library.
    try put(tmp.dir, "json/src/komira-ai/json/__init__.mojo", "def parse():\n    pass\n");
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    try std.testing.expectError(error.Refused, graphOf(a, dir, lock_text, &why));
    try std.testing.expectEqualStrings("json/mopm.toml has no library directory (src/json or [targets] lib)", why);
}
