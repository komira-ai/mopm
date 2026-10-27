//! Tests of the system libraries in the unit graph (spec/unit-graph.md, "System libraries"): `loads` on the
//! `test` and `bin` units, the graph's `system_libs`, format 3 only when a unit loads, the refusal of a stale lock,
//! and a graph that is byte for byte what it was when the lock pins none. They are in a file of their own so
//! unit_graph.zig stays small; mopm_core.zig runs them with the rest.

const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");
const ug = @import("unit_graph.zig");
const install_plan = @import("install_plan.zig");

const Graph = ug.Graph;

fn put(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    try dir.writeFile(path, bytes);
}

const toml_util_plain = "[package]\nname = \"util\"\nversion = \"0.3.0\"\nmojo = [\"1.0.0\"]\n";
const toml_util_loads = toml_util_plain ++ "\n[native-dependencies]\nlz4 = { mode = \"load\" }\n";

const toml_app_head = "[package]\nname = \"app\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n\n[dependencies]\nhttp_core = \"1.2\"\nutil = { path = \"util\" }\n";
const toml_app_tail = "\n[targets]\nbins = [{ name = \"appbin\", path = \"src/main.mojo\" }]\n";
const toml_app_plain = toml_app_head ++ toml_app_tail;
const toml_app_loads = toml_app_head ++ "\n[native-dependencies]\nlibsqlite = { version = \">=3.40\", mode = \"load\" }\nz = { mode = \"link\" }\n" ++ toml_app_tail;

const members = [_]install_plan.PathDep{.{ .name = "util", .version = "0.3.0", .path = "util" }};

fn writeWorkspace(dir: std.fs.Dir, util_toml: []const u8) !void {
    try put(dir, "src/app/__init__.mojo", "def run():\n    pass\n");
    try put(dir, "src/main.mojo", "def main():\n    pass\n");
    try put(dir, "tests/test_app.mojo", "def main():\n    pass\n");
    try put(dir, "util/mopm.toml", util_toml);
    try put(dir, "util/src/util/__init__.mojo", "def hello():\n    pass\n");
}

fn shaOf(a: Allocator, ch: u8) ![]const u8 {
    const s = try a.alloc(u8, 64);
    @memset(s, ch);
    return s;
}

fn libJson(a: Allocator, name: []const u8, ch: u8, deps: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"name\": \"{s}\", \"version\": \"1.0\", \"build\": \"h0_0\", \"url\": \"https://conda.anaconda.org/conda-forge/linux-64/{s}-1.0-h0_0.conda\", \"sha256\": \"{s}\", \"size\": 10, \"deps\": [{s}]}}", .{ name, name, try shaOf(a, ch), deps });
}

const Pins = enum {
    /// Every library the project loads, pinned for linux-64.
    full,
    /// The same without libsqlite.
    no_sqlite,
    /// A lock written before system libraries: no `system_libs`, no `loads`.
    legacy,
};

/// A version 1 lock of the fixture: http_core for two subdirs (on linux-64 it loads libbrotlidec; the lock pins
/// libraries for linux-64 only, so the osx-arm64 entry loads nothing), and the member util. `sqlite_sha` is the character the sha256 of libsqlite repeats.
fn lockText(a: Allocator, pins: Pins, sqlite_sha: u8) ![]const u8 {
    const loads: []const u8 = if (pins == .legacy) "" else ", \"loads\": [\"libbrotlidec\"]";
    var sys: []const u8 = "";
    if (pins != .legacy) {
        const sqlite = if (pins == .full) try std.fmt.allocPrint(a, "{s},\n", .{try libJson(a, "libsqlite", sqlite_sha, "")}) else "";
        sys = try std.fmt.allocPrint(a, ", \"system_libs\": {{\"linux-64\": [\n{s},\n{s},\n{s}{s}\n]}}", .{
            try libJson(a, "libbrotlicommon", 'b', ""),
            try libJson(a, "libbrotlidec", 'c', "\"libbrotlicommon\""),
            sqlite,
            try libJson(a, "lz4-c", 'd', ""),
        });
    }
    return std.fmt.allocPrint(a,
        \\{{"lock_version": 1, "toolchain": {{"mojo": "1.0.0"}}, "channels": ["https://conda.mopm.dev/"], "packages": [
        \\  {{"name": "http_core", "version": "1.2.5", "build": "mojo1.0.0_0", "subdir": "linux-64", "channel": "https://conda.mopm.dev/", "url": "https://conda.mopm.dev/linux-64/mojo-http_core-1.2.5-mojo1.0.0_0.conda", "sha256": "{s}", "size": 1000, "mojo": "1.0.0"{s}}},
        \\  {{"name": "http_core", "version": "1.2.5", "build": "mojo1.0.0_0", "subdir": "osx-arm64", "channel": "https://conda.mopm.dev/", "url": "https://conda.mopm.dev/osx-arm64/mojo-http_core-1.2.5-mojo1.0.0_0.conda", "sha256": "{s}", "size": 1000, "mojo": "1.0.0"}},
        \\  {{"name": "util", "version": "0.3.0", "source": "path", "path": "util"}}
        \\]{s}}}
        \\
    , .{ try shaOf(a, 'a'), loads, try shaOf(a, 'a'), sys });
}

fn fakeToolchain(subdir: []const u8) ug.Toolchain {
    return .{
        .mojo = "1.0.0",
        .subdir = subdir,
        .cc_target = "x86_64-linux-gnu.2.34",
        .closure_sha256 = "c" ** 64,
        .zig = .{ .version = "0.12.0", .url = "https://example.invalid/zig.tar.xz", .sha256 = "f" ** 64, .size = 1 },
        .components = &.{},
    };
}

/// The graph of the fixture for `subdir`, with the root manifest `app_toml` and the member manifest `util_toml`.
fn graphOf(a: Allocator, app_toml: []const u8, util_toml: []const u8, l_text: []const u8, subdir: []const u8, why: *[]const u8) !Graph {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, util_toml);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, app_toml, &diag);
    const l = lock.parse(a, l_text, why) catch |e| {
        std.debug.print("lock refused: {s}\n", .{why.*});
        return e;
    };
    return ug.build(a, .{ .dir = dir, .m = m, .members = &members, .l = l, .subdir = subdir, .mojo = "1.0.0", .toolchain = fakeToolchain(subdir) }, why);
}

fn unitNamed(g: Graph, kind: []const u8) !ug.Unit {
    for (g.units) |u| {
        if (std.mem.eql(u8, u.kind, kind)) return u;
    }
    return error.NoSuchUnit;
}

fn expectLoads(want: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "the test and the binary load the libraries of their closure and what those need; no other unit does" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const g = graphOf(a, toml_app_loads, toml_util_loads, try lockText(a, .full, 'e'), "linux-64", &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    // The root's libsqlite, the registry package's libbrotlidec and, through it, libbrotlicommon, the member's lz4.
    const want = [_][]const u8{ "libbrotlicommon", "libbrotlidec", "libsqlite", "lz4-c" };
    var tests: usize = 0;
    var bins: usize = 0;
    for (g.units) |u| {
        if (std.mem.eql(u8, u.kind, "test")) {
            tests += 1;
            try expectLoads(&want, u.loads);
        } else if (std.mem.eql(u8, u.kind, "bin")) {
            bins += 1;
            try expectLoads(&want, u.loads);
        } else {
            try std.testing.expectEqual(@as(usize, 0), u.loads.len);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), tests);
    try std.testing.expectEqual(@as(usize, 1), bins);
    // A graph with loads says so, and lists the pins of its subdir: every library of the lock, by name.
    try std.testing.expectEqual(ug.format_loads, g.unit_graph);
    try std.testing.expectEqual(@as(usize, 4), g.system_libs.len);
    try std.testing.expectEqualStrings("libbrotlicommon", g.system_libs[0].name);
    try std.testing.expectEqualStrings("lz4-c", g.system_libs[3].name);
    try std.testing.expectEqualStrings("https://conda.anaconda.org/conda-forge/linux-64/libsqlite-1.0-h0_0.conda", g.system_libs[2].url);
    try std.testing.expectEqualStrings(try shaOf(a, 'e'), g.system_libs[2].sha256);
}

test "the graph is printed with its format, system_libs and loads, and read back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const g = try graphOf(a, toml_app_loads, toml_util_loads, try lockText(a, .full, 'e'), "linux-64", &why);
    const text = try ug.render(a, g);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"unit_graph\": 3,") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"system_libs\": [\n    {\"name\": \"libbrotlicommon\", \"version\": \"1.0\", \"build\": \"h0_0\", \"url\": ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"loads\": [\"libbrotlicommon\", \"libbrotlidec\", \"libsqlite\", \"lz4-c\"],\n      \"profile\"") != null);
    const again = try ug.parse(a, text);
    try std.testing.expectEqual(ug.format_loads, again.unit_graph);
    try std.testing.expectEqual(g.system_libs.len, again.system_libs.len);
    try expectLoads((try unitNamed(g, "test")).loads, (try unitNamed(again, "test")).loads);
    try std.testing.expectEqualStrings(text, try ug.render(a, again));
}

test "a lock that pins no system library gives the graph it always gave: format 2, no loads, the same bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    // The manifests name libraries to load; the lock was written before it could pin them.
    const old = try graphOf(a, toml_app_loads, toml_util_loads, try lockText(a, .legacy, 'e'), "linux-64", &why);
    // The same project with no library named at all.
    const plain = try graphOf(a, toml_app_plain, toml_util_plain, try lockText(a, .legacy, 'e'), "linux-64", &why);
    try std.testing.expectEqual(ug.format_version, old.unit_graph);
    try std.testing.expectEqual(@as(usize, 0), old.system_libs.len);
    for (old.units) |u| try std.testing.expectEqual(@as(usize, 0), u.loads.len);
    const text = try ug.render(a, old);
    try std.testing.expectEqualStrings(try ug.render(a, plain), text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"unit_graph\": 2,") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "loads") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "system_libs") == null);
}

test "a project that loads nothing keeps format 2 even when the lock pins libraries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    // Libraries are pinned for another reason (the registry package asks for libbrotlidec), but no test or binary
    // has a closure that loads one: here the registry package is not a dependency of anything the graph holds.
    const toml_no_deps = "[package]\nname = \"app\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n";
    const g = try graphOf(a, toml_no_deps, toml_util_plain, try lockText(a, .full, 'e'), "linux-64", &why);
    try std.testing.expectEqual(ug.format_version, g.unit_graph);
    try std.testing.expectEqual(@as(usize, 0), g.system_libs.len);
    for (g.units) |u| try std.testing.expectEqual(@as(usize, 0), u.loads.len);
}

test "the key of a unit that loads a library changes with the pin of that library, and only that unit's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const one = try graphOf(a, toml_app_loads, toml_util_loads, try lockText(a, .full, 'e'), "linux-64", &why);
    const other = try graphOf(a, toml_app_loads, toml_util_loads, try lockText(a, .full, 'f'), "linux-64", &why);
    const same = try graphOf(a, toml_app_loads, toml_util_loads, try lockText(a, .full, 'e'), "linux-64", &why);
    const t1 = try unitNamed(one, "test");
    try std.testing.expect(!std.mem.eql(u8, t1.key, (try unitNamed(other, "test")).key));
    try std.testing.expect(!std.mem.eql(u8, (try unitNamed(one, "bin")).key, (try unitNamed(other, "bin")).key));
    try std.testing.expectEqualStrings(t1.key, (try unitNamed(same, "test")).key);
    // The libraries are loaded at run time, not compiled in: no library unit is another unit for it.
    for (one.units, other.units) |u, v| {
        if (std.mem.eql(u8, u.kind, "test") or std.mem.eql(u8, u.kind, "bin")) continue;
        try std.testing.expectEqualStrings(u.key, v.key);
    }
}

test "a library the lock does not pin is refused, naming it and the subdir, and the command that fixes it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    // The manifest asks for libsqlite; the lock pins the others.
    try std.testing.expectError(error.Refused, graphOf(a, toml_app_loads, toml_util_loads, try lockText(a, .no_sqlite, 'e'), "linux-64", &why));
    try std.testing.expectEqualStrings("mopm.lock has no system library libsqlite for linux-64; run 'mopm lock'", why);
    // A subdir the lock pins nothing for.
    why = "";
    try std.testing.expectError(error.Refused, graphOf(a, toml_app_loads, toml_util_loads, try lockText(a, .full, 'e'), "osx-arm64", &why));
    try std.testing.expectEqualStrings("mopm.lock has no system library libsqlite for osx-arm64; run 'mopm lock'", why);
}

test "a library the member's manifest loads and the lock does not pin is refused too" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    // The root loads nothing of its own; the member loads lz4, which this lock pins nothing of: take it out.
    const text = try lockText(a, .full, 'e');
    const lz4 = try libJson(a, "lz4-c", 'd', "");
    const without = try std.mem.replaceOwned(u8, a, text, try std.fmt.allocPrint(a, ",\n{s}\n", .{lz4}), "\n");
    try std.testing.expect(without.len < text.len);
    try std.testing.expectError(error.Refused, graphOf(a, toml_app_plain, toml_util_loads, without, "linux-64", &why));
    try std.testing.expectEqualStrings("mopm.lock has no system library lz4-c for linux-64; run 'mopm lock'", why);
}
