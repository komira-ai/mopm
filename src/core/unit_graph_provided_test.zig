//! Tests of a `provided` native in the unit graph (spec/unit-graph.md, "Provided natives"): a member's static
//! archive that another build produces. The graph has a `native` unit for it with nothing to compile, the units that
//! link it list it as built, and the graph says format 4 so that a reader that does not know `provided` is
//! refused instead of compiling nothing. In a file of their own so unit_graph.zig stays small; mopm_core.zig runs them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");
const ug = @import("unit_graph.zig");
const install_plan = @import("install_plan.zig");

const Graph = ug.Graph;

const toml_app = "[package]\nname = \"app\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n\n[dependencies]\nutil = { path = \"util\" }\n";
const toml_util_head = "[package]\nname = \"util\"\nversion = \"0.3.0\"\nmojo = [\"1.0.0\"]\n";
/// util ships two archives built elsewhere; s2n leaves its symbols to awslc.
const toml_util_provided = toml_util_head ++
    "\n[native.awslc]\nkind = \"static\"\nprovided = true\nexclusive = \"libawslc\"\n" ++
    "\n[native.s2n]\nkind = \"static\"\nprovided = true\nneeds = [\"libawslc.a\"]\n";
const toml_util_srcs = toml_util_head ++ "\n[native.shim]\nkind = \"static\"\nsrcs = [\"native/*.c\"]\n";

const lock_text =
    \\{"lock_version": 1, "toolchain": {"mojo": "1.0.0"}, "channels": ["https://conda.mopm.dev/"], "packages": [
    \\  {"name": "util", "version": "0.3.0", "source": "path", "path": "util"}
    \\]}
    \\
;

const members = [_]install_plan.PathDep{.{ .name = "util", .version = "0.3.0", .path = "util" }};

const id_app = "app@1.0.0#mojo1.0.0/lib";
const id_util = "util@0.3.0#mojo1.0.0/lib";
const id_awslc = "native:util/awslc";
const id_s2n = "native:util/s2n";

fn put(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    try dir.writeFile(path, bytes);
}

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

fn graphOf(a: Allocator, util_toml: []const u8, with_c: bool, why: *[]const u8) !Graph {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try put(tmp.dir, "src/app/__init__.mojo", "def run():\n    pass\n");
    try put(tmp.dir, "util/mopm.toml", util_toml);
    try put(tmp.dir, "util/src/util/__init__.mojo", "def hello():\n    pass\n");
    if (with_c) try put(tmp.dir, "util/native/shim.c", "int shim(void) { return 1; }\n");
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, toml_app, &diag);
    const l = try lock.parse(a, lock_text, why);
    return ug.build(a, .{ .dir = dir, .m = m, .members = &members, .l = l, .subdir = "linux-64", .mojo = "1.0.0", .toolchain = fakeToolchain() }, why);
}

fn sonames(a: Allocator, u: ug.Unit) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    for (u.natives, 0..) |n, i| {
        if (i > 0) try out.append(' ');
        try out.appendSlice(n.soname);
    }
    return out.items;
}

// Defect it catches: a native with no sources refused when the graph is made, so a package whose archive is built by
// another rule cannot be planned; or dropped from the graph, so a test is linked without it.
test "a provided native is a native unit with nothing to compile, and the member's units list it as built" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const g = graphOf(a, toml_util_provided, false, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    const nu = g.units[g.find(id_awslc) orelse return error.NoSuchUnit];
    try std.testing.expectEqualStrings("native", nu.kind);
    try std.testing.expectEqualStrings("libawslc.a", nu.soname);
    try std.testing.expectEqual(@as(usize, 0), nu.srcs.len);
    try std.testing.expectEqual(@as(usize, 0), nu.hdrs.len);
    try std.testing.expectEqualStrings("libawslc.a", nu.outputs[0]);
    // The library of util links both, s2n first because it leaves its symbols to awslc; so does app, which depends on util.
    for ([_][]const u8{ id_util, id_app }) |id| {
        const u = g.units[g.find(id) orelse return error.NoSuchUnit];
        try std.testing.expectEqualStrings("libs2n.a libawslc.a", try sonames(a, u));
        try std.testing.expectEqualStrings(id_s2n, u.natives[0].built);
        try std.testing.expectEqualStrings("", u.natives[0].sha256);
        try std.testing.expectEqualStrings("libawslc", u.natives[1].exclusive);
    }
    const s2n = g.units[g.find(id_s2n).?];
    try std.testing.expectEqualStrings("libawslc.a", s2n.needs[0]);
}

// Defect it catches: a reader that does not know `provided` accepting the graph and building an empty archive.
test "a graph with a provided native is format 4, says provided on the unit, and reads back as itself" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const g = try graphOf(a, toml_util_provided, false, &why);
    try std.testing.expectEqual(@as(u32, 4), g.unit_graph);
    const text = try ug.render(a, g);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"unit_graph\": 4,") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"soname\": \"libawslc.a\",\n      \"provided\": true,") != null);
    const back = try ug.parse(a, text);
    try std.testing.expectEqual(@as(u32, 4), back.unit_graph);
    try std.testing.expect(std.mem.indexOf(u8, try ug.render(a, back), "\"provided\": true") != null);
    try std.testing.expectEqualStrings(text, try ug.render(a, back));
}

// Defect it catches: the format number moving for graphs that have no provided native, which a reader of format 2
// would then refuse.
test "a native built from srcs keeps format 2 and prints no provided" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const g = try graphOf(a, toml_util_srcs, true, &why);
    try std.testing.expectEqual(ug.format_version, g.unit_graph);
    const text = try ug.render(a, g);
    try std.testing.expect(std.mem.indexOf(u8, text, "provided") == null);
}

const toml_util_link = toml_util_head ++
    "\n[native.awslc]\nkind = \"static\"\nprovided = true\nlink = [\"c++\"]\n" ++
    "\n[native.s2n]\nkind = \"static\"\nprovided = true\nneeds = [\"libawslc.a\"]\nlink = [\"c++\", \"pthread\"]\n";

// Defect it catches: the system libraries of a provided native (the archive of a C++ library another rule builds) left out
// of the units that link it, so a Buck2 build of a consumer fails on libc++'s symbols; a name given once per archive;
// the graph keeping format 4, which a reader that does not know `link` accepts and links without them.
test "provided natives that name system libraries: one link list per linking unit, each name once, format 5" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const g = graphOf(a, toml_util_link, false, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqual(ug.format_link, g.unit_graph);
    for ([_][]const u8{ id_util, id_app }) |id| {
        const u = g.units[g.find(id) orelse return error.NoSuchUnit];
        try std.testing.expectEqualStrings("libs2n.a libawslc.a", try sonames(a, u));
        try std.testing.expectEqual(@as(usize, 2), u.link.len);
        try std.testing.expectEqualStrings("c++", u.link[0]);
        try std.testing.expectEqualStrings("pthread", u.link[1]);
    }
    // The native units themselves are compiled by nobody and link nothing.
    try std.testing.expectEqual(@as(usize, 0), g.units[g.find(id_awslc).?].link.len);
    const text = try ug.render(a, g);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"unit_graph\": 5,") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"provided\": true") != null);
    try std.testing.expectEqualStrings(text, try ug.render(a, try ug.parse(a, text)));

    // The same natives without `link` are format 4, and the key of a linking unit moves when a name is added.
    const plain = try graphOf(a, toml_util_provided, false, &why);
    try std.testing.expectEqual(ug.format_provided, plain.unit_graph);
    try std.testing.expect(!std.mem.eql(u8, plain.units[plain.find(id_app).?].key, g.units[g.find(id_app).?].key));
}

// Defect it catches: a name outside the allowed list reaching a graph by way of a lock someone edited or another tool wrote.
test "a lock that names a system library outside the allowed list is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const text =
        \\{"lock_version": 1, "toolchain": {"mojo": "1.0.0"}, "channels": ["https://conda.mopm.dev/"], "packages": [
        \\  {"name": "p", "version": "1.0.0", "build": "mojo1.0.0_0", "subdir": "linux-64", "channel": "https://conda.mopm.dev/",
        \\   "url": "https://conda.mopm.dev/linux-64/mojo-p-1.0.0-mojo1.0.0_0.conda", "sha256": "
    ++ ("a" ** 64) ++
        \\", "size": 1, "mojo": "1.0.0",
        \\   "native": [{"id": "p", "soname": "libp.a", "kind": "static", "link": ["-Wl,-z,execstack"]}]}
        \\]}
    ;
    try std.testing.expectError(error.Invalid, lock.parse(a, text, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "native library p: link: '-Wl,-z,execstack' is not a system library a native may link") != null);
    const shared = try std.mem.replaceOwned(u8, a, text, "\"kind\": \"static\", \"link\": [\"-Wl,-z,execstack\"]", "\"link\": [\"m\"]");
    try std.testing.expectError(error.Invalid, lock.parse(a, shared, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "has a link but is not static") != null);
}
