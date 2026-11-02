//! Tests of the unit graph on the platforms mopm pins a toolchain for (linux-64, linux-aarch64, osx-arm64): the
//! toolchain of each byte for byte, its components, the lock's closure per platform, and the refusals. They are in a
//! file of their own so unit_graph.zig stays under the size limit; mopm_core.zig runs them with the rest.

const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");
const ug = @import("unit_graph.zig");
const Graph = ug.Graph;
const build = ug.build;
const render = ug.render;
const toolchainFor = ug.toolchainFor;
const lock_subdirs = ug.lock_subdirs;

const test_hex_a = "a" ** 64;
const test_app = "from app import run\n\ndef main():\n    run()\n";

fn put(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    try dir.writeFile(path, bytes);
}

fn pinnedGraph(a: Allocator, dir: []const u8, subdir: []const u8, l: lock.Lock, why: *[]const u8) !Graph {
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, "[package]\nname = \"app\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n", &diag);
    return build(a, .{ .dir = dir, .m = m, .members = &.{}, .l = l, .subdir = subdir, .mojo = "1.0.0" }, why);
}

/// A version 2 lock with no packages whose closures are `recorded`, as `(subdir, hash)` pairs in lock order.
fn lockRecording(a: Allocator, recorded: []const [2][]const u8, why: *[]const u8) !lock.Lock {
    var text = std.ArrayList(u8).init(a);
    try text.appendSlice("{\"lock_version\": 2, \"mojo\": [\"1.0.0\"], \"toolchain\": {\"1.0.0\": {");
    for (recorded, 0..) |r, i| try text.writer().print("{s}\"{s}\": \"{s}\"", .{ if (i == 0) "" else ", ", r[0], r[1] });
    try text.appendSlice("}}, \"channels\": [\"https://conda.mopm.dev/\"], \"packages\": []}\n");
    return lock.parse(a, text.items, why);
}

/// The lock a mopm made before the other platforms were pinned: it records the closure of linux-64 alone.
fn linux64Lock(a: Allocator, why: *[]const u8) !lock.Lock {
    const h = (try toolchainFor(a, "1.0.0", "linux-64", why)).closure_sha256;
    return lockRecording(a, &.{.{ "linux-64", h }}, why);
}

fn emptyApp(dir: std.fs.Dir) !void {
    try put(dir, "src/app/__init__.mojo", "def run():\n    pass\n");
    try put(dir, "tests/test_app.mojo", test_app);
}

/// What `mopm plan --unit-graph` prints above the units for a package with none: the toolchain of one platform.
fn toolchainGolden(a: Allocator, tc: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\n  \"unit_graph\": 2,\n  \"package\": \"app@1.0.0\",\n  \"mojo\": \"1.0.0\",\n  \"toolchain\": {{{s}\n  }},\n  \"units\": []\n}}\n", .{tc});
}

test "golden: the toolchain of the unit graph on each platform mopm pins, byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const want = [_]struct { subdir: []const u8, tc: []const u8 }{
        .{ .subdir = "linux-64", .tc =
        \\
        \\    "mojo": "1.0.0",
        \\    "subdir": "linux-64",
        \\    "cc_target": "x86_64-linux-gnu.2.34",
        \\    "closure_sha256": "3ed75e01401544e0d660ee48dc387dacce437e3833ac296d4a0601f28abd4aec",
        \\    "zig": {"version": "0.12.0", "url": "https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz", "sha256": "c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad", "size": 45480516},
        \\    "components": [
        \\      {"name": "libgcc", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libgcc-16.2.0-ha9f2e26_7.conda", "sha256": "e031634c3a928f9594eba868bc46ef5230d6571a364a0c63215b06c4563bfcea", "size": 1058444},
        \\      {"name": "libstdcxx", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libstdcxx-16.2.0-h934c35e_7.conda", "sha256": "fa7018298629fc429971fffd6ecba3d27a7b02e4e890d6a93ea01ffebe8cb745", "size": 6615436},
        \\      {"name": "mojo-compiler", "version": "1.0.0", "url": "https://conda.modular.com/max/linux-64/mojo-compiler-1.0.0-release.conda", "sha256": "4394c6146d47ec7794a9a3ed5775ae158f59f83f8e1aed59408b17c4909821b3", "size": 68511359}
        \\    ]
        },
        .{ .subdir = "linux-aarch64", .tc =
        \\
        \\    "mojo": "1.0.0",
        \\    "subdir": "linux-aarch64",
        \\    "cc_target": "aarch64-linux-gnu.2.34",
        \\    "closure_sha256": "84a22df9ff1ca84c7eb47a3b3d5eaede4c970ee85b660853f640841b5dfa03c3",
        \\    "zig": {"version": "0.12.0", "url": "https://ziglang.org/download/0.12.0/zig-linux-aarch64-0.12.0.tar.xz", "sha256": "754f1029484079b7e0ca3b913a0a2f2a6afd5a28990cb224fe8845e72f09de63", "size": 41849060},
        \\    "components": [
        \\      {"name": "libgcc", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-aarch64/libgcc-16.2.0-h205dda4_7.conda", "sha256": "eae7a3449d5a3b5351c5427137c076cc3fc826645c7bfc42dc10772b783826f1", "size": 627793},
        \\      {"name": "libstdcxx", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-aarch64/libstdcxx-16.2.0-hef695bb_7.conda", "sha256": "b241a3acfa9cdb1359112864a1241225533c92642de3000d52ae65ef5d3a9786", "size": 6236630},
        \\      {"name": "mojo-compiler", "version": "1.0.0", "url": "https://conda.modular.com/max/linux-aarch64/mojo-compiler-1.0.0-release.conda", "sha256": "da1772742c54f1f8f7b883e6338b1fe5de4592f2c882220dcceae623cc661e57", "size": 66479788}
        \\    ]
        },
        .{ .subdir = "osx-arm64", .tc =
        \\
        \\    "mojo": "1.0.0",
        \\    "subdir": "osx-arm64",
        \\    "cc_target": "aarch64-macos.11.0",
        \\    "closure_sha256": "0d34e9a60951231f6c2161f6620957ff086542b217b187774fdf9d82b76046a1",
        \\    "zig": {"version": "0.12.0", "url": "https://ziglang.org/download/0.12.0/zig-macos-aarch64-0.12.0.tar.xz", "sha256": "294e224c14fd0822cfb15a35cf39aa14bd9967867999bf8bdfe3db7ddec2a27f", "size": 43447724},
        \\    "components": [
        \\      {"name": "mojo-compiler", "version": "1.0.0", "url": "https://conda.modular.com/max/osx-arm64/mojo-compiler-1.0.0-release.conda", "sha256": "c52054bc444d851e5c38cc33e790fb011a1080470244aaa59351ac5056d08c59", "size": 61221085}
        \\    ]
        },
    };
    for (want) |w| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try emptyApp(tmp.dir);
        const dir = try tmp.dir.realpathAlloc(a, ".");
        var why: []const u8 = "";
        const l = try linux64Lock(a, &why);
        const g = pinnedGraph(a, dir, w.subdir, l, &why) catch |e| {
            std.debug.print("{s} refused: {s}\n", .{ w.subdir, why });
            return e;
        };
        const text = try render(a, .{ .package = g.package, .mojo = g.mojo, .toolchain = g.toolchain, .units = &.{} });
        std.testing.expectEqualStrings(try toolchainGolden(a, w.tc), text) catch |e| {
            std.debug.print("---- actual ({s}) ----\n{s}---- end ----\n", .{ w.subdir, text });
            return e;
        };
        // The whole graph names the same toolchain and holds the package's units.
        try std.testing.expectEqualStrings(w.subdir, g.toolchain.subdir);
        try std.testing.expect(g.find("app@1.0.0#mojo1.0.0/lib") != null);
    }
}

test "the components a toolchain lists follow its platform: Linux has the C++ runtime packages, macOS the compiler alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    for ([_][]const u8{ "linux-64", "linux-aarch64" }) |subdir| {
        const tc = try toolchainFor(a, "1.0.0", subdir, &why);
        try std.testing.expectEqual(@as(usize, 3), tc.components.len);
        try std.testing.expectEqualStrings("libgcc", tc.components[0].name);
        try std.testing.expectEqualStrings("libstdcxx", tc.components[1].name);
        try std.testing.expectEqualStrings("mojo-compiler", tc.components[2].name);
    }
    const mac = try toolchainFor(a, "1.0.0", "osx-arm64", &why);
    try std.testing.expectEqual(@as(usize, 1), mac.components.len);
    try std.testing.expectEqualStrings("mojo-compiler", mac.components[0].name);
    try std.testing.expect(std.mem.indexOf(u8, mac.components[0].url, "/osx-arm64/") != null);
    try std.testing.expectEqualStrings("aarch64-macos.11.0", mac.cc_target);
    try std.testing.expectEqualStrings("aarch64-linux-gnu.2.34", (try toolchainFor(a, "1.0.0", "linux-aarch64", &why)).cc_target);
}

test "each platform's closure hash is its own" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    var seen = std.ArrayList([]const u8).init(a);
    for (lock_subdirs) |subdir| {
        const h = (try toolchainFor(a, "1.0.0", subdir, &why)).closure_sha256;
        try std.testing.expect(lock.isSha256(h));
        for (seen.items) |s| try std.testing.expect(!std.mem.eql(u8, s, h));
        try seen.append(h);
    }
    try std.testing.expectEqual(@as(usize, 3), seen.items.len);
}

test "a subdir mopm pins no toolchain for is refused, naming what it pins" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    for ([_][]const u8{ "osx-64", "win-64", "linux-ppc64le", "noarch", "" }) |subdir| {
        try std.testing.expectError(error.Refused, toolchainFor(a, "1.0.0", subdir, &why));
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mopm has no pinned toolchain for mojo 1.0.0 on {s} (it pins mojo 1.0.0 on linux-64, linux-aarch64 and osx-arm64)", .{subdir}), why);
    }
    // The graph is refused the same way, before any source is read.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try emptyApp(tmp.dir);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const l = try linux64Lock(a, &why);
    try std.testing.expectError(error.Refused, pinnedGraph(a, dir, "osx-64", l, &why));
    try std.testing.expect(std.mem.startsWith(u8, why, "mopm has no pinned toolchain for mojo 1.0.0 on osx-64"));
}

test "the lock records one closure per platform and reads them back; a lock of linux-64 alone still reads and builds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try emptyApp(tmp.dir);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";

    var pairs = std.ArrayList([2][]const u8).init(a);
    for (lock_subdirs) |subdir| try pairs.append(.{ subdir, (try toolchainFor(a, "1.0.0", subdir, &why)).closure_sha256 });
    const all = try lockRecording(a, pairs.items, &why);
    try std.testing.expectEqual(@as(usize, 3), all.closures.len);
    for (all.closures, 0..) |c, i| {
        try std.testing.expectEqualStrings(pairs.items[i][0], c.subdir);
        try std.testing.expectEqualStrings(pairs.items[i][1], c.sha256);
    }
    // Written and read again, the lock is the same text and the same closures.
    const text = try lock.render(a, all);
    const again = try lock.parse(a, text, &why);
    try std.testing.expectEqualStrings(text, try lock.render(a, again));
    try std.testing.expectEqual(@as(usize, 3), again.closures.len);
    // Every platform's graph accepts the lock that records its own closure.
    for (lock_subdirs) |subdir| {
        const g = pinnedGraph(a, dir, subdir, again, &why) catch |e| {
            std.debug.print("{s} refused: {s}\n", .{ subdir, why });
            return e;
        };
        try std.testing.expectEqualStrings(subdir, g.toolchain.subdir);
    }

    // A lock made before the other platforms were pinned records linux-64 alone: it reads, and every platform's graph is made from it.
    const old = try lockRecording(a, pairs.items[0..1], &why);
    try std.testing.expectEqual(@as(usize, 1), old.closures.len);
    try std.testing.expectEqualStrings("linux-64", old.closures[0].subdir);
    for (lock_subdirs) |subdir| _ = try pinnedGraph(a, dir, subdir, old, &why);
}

test "a closure recorded for linux-aarch64 or osx-arm64 that this mopm does not pin is a stale lock" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try emptyApp(tmp.dir);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    for ([_][]const u8{ "linux-aarch64", "osx-arm64" }) |subdir| {
        const l = try lockRecording(a, &.{.{ subdir, test_hex_a }}, &why);
        try std.testing.expectError(error.Refused, pinnedGraph(a, dir, subdir, l, &why));
        const pinned = (try toolchainFor(a, "1.0.0", subdir, &why)).closure_sha256;
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mopm.lock records toolchain closure {s} for mojo 1.0.0 on {s}, but this mopm pins {s}; run 'mopm lock'", .{ test_hex_a, subdir, pinned }), why);
        // The other platforms are not held to it.
        const other = if (std.mem.eql(u8, subdir, "osx-arm64")) "linux-aarch64" else "osx-arm64";
        _ = try pinnedGraph(a, dir, other, l, &why);
    }
}
