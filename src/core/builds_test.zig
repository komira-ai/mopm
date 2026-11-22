//! Tests of a version with several builds, one per Mojo compiler: what the sparse index reader (resolve.zig) accepts
//! and refuses, which build selection and the "no .mojoc" message use, and the lock built from the build of each Mojo
//! (install_plan.zig). They are in a file of their own so resolve.zig stays small; mopm_core.zig runs them with the rest.

const std = @import("std");
const testroot = @import("testroot.zig");
const Allocator = std.mem.Allocator;
const resolve = @import("resolve.zig");
const lock = @import("lock.zig");
const plan = @import("install_plan.zig");

const sha_a = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";
const sha_b = "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae";
const sha_c = "fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9";
const sha_d = "5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9";

/// A file entry of `komira-ai/core` 1.0.0 built with `compiler`, in the registry's layout.
fn fileOf(comptime version: []const u8, comptime compiler: []const u8, comptime subdir: []const u8, comptime sha: []const u8, comptime size: []const u8) []const u8 {
    return "{\"filename\":\"mojo-komira-ai.core-" ++ version ++ "-mojo" ++ compiler ++ "_0.conda\",\"sha256\":\"" ++ sha ++ "\",\"size\":" ++ size ++ ",\"subdir\":\"" ++ subdir ++ "\"}";
}

/// An entry of `builds`.
fn buildOf(comptime build: []const u8, comptime requires: []const u8, comptime files: []const u8) []const u8 {
    return "{\"build\":\"" ++ build ++ "\",\"files\":[" ++ files ++ "],\"requires_mojo\":\"" ++ requires ++ "\"}";
}

/// The line of `komira-ai/core` `version`: its top-level build is the one for `compiler`; `builds` is the key's value, or
/// null for a line without it.
fn line(comptime version: []const u8, comptime compiler: []const u8, comptime builds: ?[]const u8) []const u8 {
    return "{\"build\":\"mojo" ++ compiler ++ "_0\"," ++ (if (builds) |b| "\"builds\":" ++ b ++ "," else "") ++ "\"deps\":[],\"files\":[" ++ fileOf(version, compiler, "linux-64", sha_a, "1000") ++
        "],\"manifest_sha256\":\"" ++ sha_a ++ "\",\"name\":\"komira-ai/core\",\"published_at\":\"2026-10-13T12:00:00Z\",\"requires_mojo\":\"==" ++ compiler ++ "\",\"state\":\"published\",\"v\":2,\"version\":\"" ++ version ++ "\"}\n";
}

/// `core` 1.0.0 with builds for the compilers named, in this order.
fn builtFor(comptime version: []const u8, comptime compilers: []const []const u8) []const u8 {
    comptime var out: []const u8 = "[";
    inline for (compilers, 0..) |c, i| {
        out = out ++ (if (i > 0) "," else "") ++ buildOf("mojo" ++ c ++ "_0", "==" ++ c, fileOf(version, c, "linux-64", sha_a, "1000"));
    }
    return out ++ "]";
}

fn parse(a: Allocator, text: []const u8) ![]const resolve.Record {
    var diag: resolve.Diagnostic = .{};
    return resolve.parseIndex(a, "komira-ai/core", text, &diag) catch |e| {
        std.debug.print("refused: {s}\n", .{diag.message});
        return e;
    };
}

fn pick(a: Allocator, index: resolve.MemoryIndex, mojo: []const u8, requirement: []const u8) !resolve.Resolution {
    var diag: resolve.Diagnostic = .{};
    return resolve.resolve(a, index, .{ .mojo = mojo, .roots = &.{.{ .name = "komira-ai/core", .requirement = requirement }} }, &diag) catch |e| {
        std.debug.print("resolution failed ({s}): {s}\n", .{ @tagName(diag.kind), diag.message });
        return e;
    };
}

/// The message of the failed resolution of `komira-ai/core` for `mojo`.
fn failure(a: Allocator, index: resolve.MemoryIndex, mojo: []const u8, mojoc_message: bool) ![]const u8 {
    var diag: resolve.Diagnostic = .{};
    try std.testing.expectError(error.ResolveFailed, resolve.resolve(a, index, .{ .mojo = mojo, .roots = &.{.{ .name = "komira-ai/core", .requirement = "1" }}, .mojoc_message = mojoc_message }, &diag));
    try std.testing.expectEqual(resolve.Kind.compiler_mismatch, diag.kind);
    return diag.message;
}

test "a line without builds is one build: the top-level one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const recs = try parse(a, comptime line("1.0.0", "1.0.0", null));
    try std.testing.expectEqual(@as(usize, 1), recs[0].builds.len);
    try std.testing.expectEqualStrings("mojo1.0.0_0", recs[0].builds[0].build);
    try std.testing.expectEqualStrings("==1.0.0", recs[0].builds[0].requires_mojo);
    try std.testing.expectEqualStrings("mojo-komira-ai.core-1.0.0-mojo1.0.0_0.conda", recs[0].builds[0].files[0].filename);
    try std.testing.expect(recs[0].builtFor("1.0.0"));
    try std.testing.expect(!recs[0].builtFor("1.1.0"));
    try std.testing.expect(recs[0].buildFor("1.1.0") == null);
}

test "a line with builds reads each build; the top-level build, requires_mojo and files are not used for selection" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const recs = try parse(a, comptime line("1.0.0", "1.0.0", builtFor("1.0.0", &.{ "1.0.0", "1.1.0" })));
    try std.testing.expectEqual(@as(usize, 2), recs[0].builds.len);
    try std.testing.expectEqualStrings("mojo1.0.0_0", recs[0].builds[0].build);
    try std.testing.expectEqualStrings("mojo1.1.0_0", recs[0].builds[1].build);
    try std.testing.expectEqualStrings("mojo-komira-ai.core-1.0.0-mojo1.1.0_0.conda", recs[0].buildFor("1.1.0").?.files[0].filename);
    try std.testing.expect(recs[0].builtFor("1.0.0") and recs[0].builtFor("1.1.0"));
    try std.testing.expect(!recs[0].builtFor("1.2.0"));

    // The top-level trio says 1.0.0, but `builds` holds only a build for 1.1.0: the version is for 1.1.0 only.
    const only_11 = try parse(a, comptime line("1.0.0", "1.0.0", builtFor("1.0.0", &.{"1.1.0"})));
    try std.testing.expect(!only_11[0].builtFor("1.0.0"));
    try std.testing.expect(only_11[0].builtFor("1.1.0"));
    // Its top-level build is still the line's own, for a reader that predates `builds`.
    try std.testing.expectEqualStrings("mojo1.0.0_0", only_11[0].build);
}

test "a project on 1.0.0 and one on 1.1.0 each get their own file from the same version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = comptime line("1.0.0", "1.0.0", "[" ++
        buildOf("mojo1.0.0_0", "==1.0.0", fileOf("1.0.0", "1.0.0", "linux-64", sha_a, "1000")) ++ "," ++
        buildOf("mojo1.1.0_0", "==1.1.0", fileOf("1.0.0", "1.1.0", "linux-64", sha_b, "2000")) ++ "]");
    const index = resolve.MemoryIndex{ .files = &.{.{ "komira-ai/core", text }} };

    const r10 = try pick(a, index, "1.0.0", "1");
    try std.testing.expectEqualStrings("1.0.0", r10.packages[0].record.version);
    const f10 = r10.packages[0].record.buildFor(r10.mojo).?.files[0];
    try std.testing.expectEqualStrings("mojo-komira-ai.core-1.0.0-mojo1.0.0_0.conda", f10.filename);
    try std.testing.expectEqualStrings(sha_a, f10.sha256);
    try std.testing.expectEqual(@as(u64, 1000), f10.size);

    const r11 = try pick(a, index, "1.1.0", "1");
    try std.testing.expectEqualStrings("1.0.0", r11.packages[0].record.version);
    const f11 = r11.packages[0].record.buildFor(r11.mojo).?.files[0];
    try std.testing.expectEqualStrings("mojo-komira-ai.core-1.0.0-mojo1.1.0_0.conda", f11.filename);
    try std.testing.expectEqualStrings(sha_b, f11.sha256);
    try std.testing.expectEqual(@as(u64, 2000), f11.size);
}

test "the newest version with a build for the project's Mojo is picked, not the newest version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // 1.0.0 has builds for 1.0.0 and 1.1.0; 1.1.0 only for 1.0.0.
    const text = comptime line("1.0.0", "1.0.0", builtFor("1.0.0", &.{ "1.0.0", "1.1.0" })) ++ line("1.1.0", "1.0.0", builtFor("1.1.0", &.{"1.0.0"}));
    const index = resolve.MemoryIndex{ .files = &.{.{ "komira-ai/core", text }} };
    try std.testing.expectEqualStrings("1.1.0", (try pick(a, index, "1.0.0", "1")).packages[0].record.version);
    try std.testing.expectEqualStrings("1.0.0", (try pick(a, index, "1.1.0", "1")).packages[0].record.version);
}

test "a version whose builds lack the project's Mojo names every build it has" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = comptime line("1.0.0", "1.0.0", builtFor("1.0.0", &.{ "1.0.0", "1.2.0" }));
    const index = resolve.MemoryIndex{ .files = &.{.{ "komira-ai/core", text }} };
    try std.testing.expectEqualStrings(
        "komira-ai/core 1.0.0 has no .mojoc for Mojo 1.1.0 (published for: 1.0.0, 1.2.0). Build with mojo 1.0.0, ask the publisher for a 1.1.0 build, or pin a version that has one.",
        try failure(a, index, "1.1.0", true),
    );
    // Without the "no .mojoc" wording the older message lists the version's compilers.
    try std.testing.expectEqualStrings(
        "no version of komira-ai/core that matches 1 (from mopm.toml) is built for mojo 1.1.0, the project's toolchain: 1.0.0 (mojo 1.0.0, 1.2.0)",
        try failure(a, index, "1.1.0", false),
    );
}

test "the compilers of a version are listed by compiler version, number by number, whatever order the line has" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = comptime line("1.0.0", "1.10.0", builtFor("1.0.0", &.{ "1.10.0", "1.9.0", "1.2.0", "1.2.0.1" }));
    const index = resolve.MemoryIndex{ .files = &.{.{ "komira-ai/core", text }} };
    // "Build with" names the first of the list.
    try std.testing.expectEqualStrings(
        "komira-ai/core 1.0.0 has no .mojoc for Mojo 2.0.0 (published for: 1.2.0, 1.2.0.1, 1.9.0, 1.10.0). Build with mojo 1.2.0, ask the publisher for a 2.0.0 build, or pin a version that has one.",
        try failure(a, index, "2.0.0", true),
    );
    const recs = try parse(a, text);
    const compilers = try recs[0].compilers(a);
    try std.testing.expectEqual(@as(usize, 4), compilers.len);
    try std.testing.expectEqualStrings("1.2.0", compilers[0]);
    try std.testing.expectEqualStrings("1.10.0", compilers[3]);
}

test "compiler versions order part by part: numbers by value, other parts as text, a shorter prefix first" {
    try std.testing.expect(resolve.lessCompiler({}, "1.2.0", "1.10.0"));
    try std.testing.expect(!resolve.lessCompiler({}, "1.10.0", "1.2.0"));
    try std.testing.expect(resolve.lessCompiler({}, "1.0", "1.0.0"));
    try std.testing.expect(!resolve.lessCompiler({}, "1.0.0", "1.0"));
    try std.testing.expect(!resolve.lessCompiler({}, "1.0.0", "1.0.0"));
    try std.testing.expect(resolve.lessCompiler({}, "1.0.0", "2.0.0"));
    try std.testing.expect(resolve.lessCompiler({}, "1.0.0.dev1", "1.0.0.dev2"));
    try std.testing.expect(resolve.lessCompiler({}, "1.0.0.dev1", "1.0.0.rc1"));
    try std.testing.expect(!resolve.lessCompiler({}, "1.0.0.rc1", "1.0.0.dev1"));
    try std.testing.expect(!resolve.lessCompiler({}, "1.x", "1.2"));
    try std.testing.expect(resolve.lessCompiler({}, "1.2", "1.x"));
}

test "a single-build line keeps the messages it always had, including a requires_mojo that is not ==<compiler>" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const odd = comptime line("1.0.0", "1.0.0", null);
    const spaced = try std.mem.replaceOwned(u8, a, odd, "\"requires_mojo\":\"==1.0.0\"", "\"requires_mojo\":\" == 1.0.0 \"");
    const recs = try parse(a, spaced);
    try std.testing.expect(recs[0].builtFor("1.0.0"));
    try std.testing.expectEqualStrings("1.0.0", recs[0].builds[0].mojoOf());

    const range = try std.mem.replaceOwned(u8, a, odd, "\"requires_mojo\":\"==1.0.0\"", "\"requires_mojo\":\">=1.0\"");
    const index = resolve.MemoryIndex{ .files = &.{.{ "komira-ai/core", range }} };
    try std.testing.expect(!(try parse(a, range))[0].builtFor("1.0.0"));
    try std.testing.expectEqualStrings(
        "no version of komira-ai/core that matches 1 (from mopm.toml) is built for mojo 1.0.0, the project's toolchain: 1.0.0 (mojo >=1.0)",
        try failure(a, index, "1.0.0", false),
    );
}

/// Expects the refusal of the line of core 1.0.0 whose `builds` is `builds`, with exactly `want` after the line's position.
fn expectRefusedBuilds(a: Allocator, comptime builds: []const u8, want: []const u8) !void {
    const text = comptime line("1.0.0", "1.0.0", builds);
    var diag: resolve.Diagnostic = .{};
    try std.testing.expectError(error.ResolveFailed, resolve.parseIndex(a, "komira-ai/core", text, &diag));
    try std.testing.expectEqual(resolve.Kind.bad_index, diag.kind);
    const full = try std.fmt.allocPrint(a, "the index file of komira-ai/core, line 1: {s}", .{want});
    try std.testing.expectEqualStrings(full, diag.message);
}

/// `expectRefusedBuilds` for a `builds` that holds the one entry `entry`.
fn expectRefusedBuild(a: Allocator, comptime entry: []const u8, want: []const u8) !void {
    try expectRefusedBuilds(a, "[" ++ entry ++ "]", want);
}

const good_10 = buildOf("mojo1.0.0_0", "==1.0.0", fileOf("1.0.0", "1.0.0", "linux-64", sha_a, "1000"));

test "builds that break spec/index.md are refused, naming what is wrong" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const file_11 = comptime fileOf("1.0.0", "1.1.0", "linux-64", sha_a, "1000");

    try expectRefusedBuilds(a, "3", "builds is not an array");
    try expectRefusedBuilds(a, "[]", "builds is empty");
    try expectRefusedBuilds(a, "[1]", "a build is not an object");
    // The keys of a build.
    try expectRefusedBuilds(a, "[{\"files\":[" ++ file_11 ++ "],\"requires_mojo\":\"==1.1.0\"}]", "a build has no build");
    try expectRefusedBuilds(a, "[{\"build\":7,\"files\":[" ++ file_11 ++ "],\"requires_mojo\":\"==1.1.0\"}]", "a build's build is not a string");
    try expectRefusedBuilds(a, "[{\"build\":\"mojo1.1.0_0\",\"files\":[" ++ file_11 ++ "]}]", "a build has no requires_mojo");
    try expectRefusedBuilds(a, "[{\"build\":\"mojo1.1.0_0\",\"files\":[" ++ file_11 ++ "],\"requires_mojo\":[]}]", "a build's requires_mojo is not a string");
    try expectRefusedBuilds(a, "[{\"build\":\"mojo1.1.0_0\",\"requires_mojo\":\"==1.1.0\"}]", "the build mojo1.1.0_0 has no files");
    try expectRefusedBuilds(a, "[{\"build\":\"mojo1.1.0_0\",\"files\":{},\"requires_mojo\":\"==1.1.0\"}]", "the files of the build mojo1.1.0_0 is not an array");
    try expectRefusedBuild(a, buildOf("mojo1.1.0_0", "==1.1.0", ""), "the build mojo1.1.0_0 has no files");
    // The build string is mojo<compiler>_0.
    try expectRefusedBuild(a, buildOf("py3_0", "==1.1.0", file_11), "the build py3_0 is not mojo<compiler>_0");
    try expectRefusedBuild(a, buildOf("mojo1.1.0_1", "==1.1.0", file_11), "the build mojo1.1.0_1 is not mojo<compiler>_0");
    try expectRefusedBuild(a, buildOf("mojo_0", "==1.1.0", file_11), "the build mojo_0 is not mojo<compiler>_0");
    try expectRefusedBuild(a, buildOf("py3.1.0_0", "==1.1.0", file_11), "the build py3.1.0_0 is not mojo<compiler>_0");
    try expectRefusedBuild(a, buildOf("mojo1..0_0", "==1.1.0", file_11), "the build mojo1..0_0 is not mojo<compiler>_0");
    try expectRefusedBuild(a, buildOf("mojo1.x_0", "==1.1.0", file_11), "the build mojo1.x_0 is not mojo<compiler>_0");
    // requires_mojo is ==<that compiler>, exactly.
    try expectRefusedBuild(a, buildOf("mojo1.1.0_0", "==1.0.0", file_11), "the build mojo1.1.0_0 requires ==1.0.0; it is built with mojo 1.1.0, so it requires ==1.1.0");
    try expectRefusedBuild(a, buildOf("mojo1.1.0_0", ">=1.1.0", file_11), "the build mojo1.1.0_0 requires >=1.1.0; it is built with mojo 1.1.0, so it requires ==1.1.0");
    try expectRefusedBuild(a, buildOf("mojo1.1.0_0", "== 1.1.0", file_11), "the build mojo1.1.0_0 requires == 1.1.0; it is built with mojo 1.1.0, so it requires ==1.1.0");
    // No build string twice.
    try expectRefusedBuilds(a, "[" ++ good_10 ++ "," ++ good_10 ++ "]", "the build mojo1.0.0_0 is listed twice");
    // The files of a build, with the checks of the top-level files, and named after the build.
    try expectRefusedBuild(a, buildOf("mojo1.1.0_0", "==1.1.0", fileOf("1.0.0", "1.0.0", "linux-64", sha_a, "1000")), "a file is named mojo-komira-ai.core-1.0.0-mojo1.0.0_0.conda; the conda name of komira-ai/core makes it mojo-komira-ai.core-1.0.0-mojo1.1.0_0.conda");
    try expectRefusedBuild(a, buildOf("mojo1.1.0_0", "==1.1.0", fileOf("1.0.0", "1.1.0", "linux-64", "XYZ", "1000")), "a file's sha256 is not 64 lowercase hex digits");
    try expectRefusedBuild(a, buildOf("mojo1.1.0_0", "==1.1.0", fileOf("1.0.0", "1.1.0", "linux-64", sha_a, "0")), "a file's size is not positive");
    try expectRefusedBuild(a, buildOf("mojo1.1.0_0", "==1.1.0", fileOf("1.0.0", "1.1.0", "linux-64", sha_a, "\"big\"")), "a file's size is not an integer");
    try expectRefusedBuild(a, buildOf("mojo1.1.0_0", "==1.1.0", "{\"filename\":\"mojo-komira-ai.core-1.0.0-mojo1.1.0_0.conda\",\"sha256\":\"" ++ sha_a ++ "\",\"subdir\":\"linux-64\"}"), "a file has no size");
    try expectRefusedBuild(a, buildOf("mojo1.1.0_0", "==1.1.0", "7"), "a file is not an object");
}

test "the top-level build, requires_mojo and files are still required and checked when builds is there" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const good = comptime line("1.0.0", "1.0.0", "[" ++ good_10 ++ "]");
    var diag: resolve.Diagnostic = .{};
    _ = try resolve.parseIndex(a, "komira-ai/core", good, &diag);
    const Case = struct { from: []const u8, to: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .from = "\"requires_mojo\":\"==1.0.0\",\"state\"", .to = "\"state\"", .want = "no requires_mojo" },
        .{ .from = "{\"build\":\"mojo1.0.0_0\",\"builds\"", .to = "{\"builds\"", .want = "no build" },
        .{ .from = "\"files\":[{\"filename\":\"mojo-komira-ai.core-1.0.0-mojo1.0.0_0.conda\",\"sha256\":\"" ++ sha_a ++ "\",\"size\":1000,\"subdir\":\"linux-64\"}],\"manifest_sha256\"", .to = "\"manifest_sha256\"", .want = "no files" },
        .{ .from = "\"files\":[{\"filename\":\"mojo-komira-ai.core-1.0.0-mojo1.0.0_0.conda\",\"sha256\":\"" ++ sha_a ++ "\",\"size\":1000,\"subdir\":\"linux-64\"}],\"manifest_sha256\"", .to = "\"files\":[],\"manifest_sha256\"", .want = "no files" },
    };
    for (cases) |c| {
        const text = try std.mem.replaceOwned(u8, a, good, c.from, c.to);
        try std.testing.expectError(error.ResolveFailed, resolve.parseIndex(a, "komira-ai/core", text, &diag));
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "the index file of komira-ai/core, line 1: {s}", .{c.want}), diag.message);
    }
    // A top-level file that is not named after the top-level build is refused as before.
    const renamed = try std.mem.replaceOwned(u8, a, good, "\"files\":[{\"filename\":\"mojo-komira-ai.core-1.0.0-mojo1.0.0_0.conda\"", "\"files\":[{\"filename\":\"mojo-komira-ai.core-1.0.0-mojo1.1.0_0.conda\"");
    try std.testing.expectError(error.ResolveFailed, resolve.parseIndex(a, "komira-ai/core", renamed, &diag));
    try std.testing.expect(std.mem.startsWith(u8, diag.message, "the index file of komira-ai/core, line 1: a file is named mojo-komira-ai.core-1.0.0-mojo1.1.0_0.conda;"));
}

test "a version is still one line: two lines for it are refused whatever their builds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = comptime line("1.0.0", "1.0.0", builtFor("1.0.0", &.{"1.0.0"})) ++ line("1.0", "1.1.0", builtFor("1.0", &.{"1.1.0"}));
    var diag: resolve.Diagnostic = .{};
    try std.testing.expectError(error.ResolveFailed, resolve.parseIndex(a, "komira-ai/core", text, &diag));
    try std.testing.expectEqualStrings("the index file of komira-ai/core, line 2: version 1.0 repeats 1.0.0", diag.message);
}

// ------------------------------------------------------------------ the index line of a published package

test "a published index line from before builds reads as one build, resolves for Mojo 1.0.0 to its file, and names its compiler for Mojo 1.1.0" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, "tests/fixtures/index/komira-ai.json.ndjson"), 1 << 20);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"builds\"") == null);
    var diag: resolve.Diagnostic = .{};
    const recs = try resolve.parseIndex(a, "komira-ai/json", text, &diag);
    try std.testing.expectEqual(@as(usize, 1), recs.len);
    const rec = recs[0];
    try std.testing.expectEqual(@as(usize, 1), rec.builds.len);
    try std.testing.expectEqualStrings("mojo1.0.0_0", rec.builds[0].build);
    try std.testing.expectEqualStrings("==1.0.0", rec.builds[0].requires_mojo);

    const index = resolve.MemoryIndex{ .files = &.{.{ "komira-ai/json", text }} };
    const roots = [_]resolve.Root{.{ .name = "komira-ai/json", .requirement = "*" }};
    const res = try resolve.resolve(a, index, .{ .mojo = "1.0.0", .roots = &roots }, &diag);
    try std.testing.expectEqual(@as(usize, 1), res.packages.len);
    const picked = res.packages[0].record;
    try std.testing.expectEqualStrings("0.1.387", picked.version);
    // The file it picks is the line's top-level file, as before.
    const file = picked.buildFor("1.0.0").?.files[0];
    try std.testing.expectEqualStrings(picked.files[0].filename, file.filename);
    try std.testing.expectEqualStrings("mojo-komira-ai.json-0.1.387-mojo1.0.0_0.conda", file.filename);
    try std.testing.expectEqualStrings("3a4db3a9e53ea51f5099ca3c03a0139c4c557b67dd33d06a6e67709202aa2750", file.sha256);
    try std.testing.expectEqual(@as(u64, 122401), file.size);
    try std.testing.expectEqualStrings("linux-64", file.subdir);

    // Its lock entry is that file.
    const repodata = "{\"info\":{\"subdir\":\"linux-64\"},\"packages\":{},\"packages.conda\":{\"mojo-komira-ai.json-0.1.387-mojo1.0.0_0.conda\":{\"build\":\"mojo1.0.0_0\",\"depends\":[\"mojo-compiler ==1.0.0\"],\"sha256\":\"3a4db3a9e53ea51f5099ca3c03a0139c4c557b67dd33d06a6e67709202aa2750\",\"size\":122401}},\"removed\":[]}\n";
    const channel = plan.MemoryChannel{ .files = &.{.{ "komira-ai/linux-64", repodata }} };
    const l = try plan.buildLock(a, res, "https://conda.mopm.dev/", channel, null, &diag);
    try std.testing.expectEqual(@as(usize, 1), l.packages.len);
    try std.testing.expectEqualStrings("mojo1.0.0_0", l.packages[0].build);
    try std.testing.expectEqualStrings("https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.json-0.1.387-mojo1.0.0_0.conda", l.packages[0].url);

    // For Mojo 1.1.0 there is no build, and the message says which compiler there is one for.
    try std.testing.expectError(error.ResolveFailed, resolve.resolve(a, index, .{ .mojo = "1.1.0", .roots = &roots, .mojoc_message = true }, &diag));
    try std.testing.expectEqual(resolve.Kind.compiler_mismatch, diag.kind);
    try std.testing.expectEqualStrings("komira-ai/json 0.1.387 has no .mojoc for Mojo 1.1.0 (published for: 1.0.0). Build with mojo 1.0.0, ask the publisher for a 1.1.0 build, or pin a version that has one.", diag.message);
}

// ------------------------------------------------------------------ the lock

/// The repodata.json of one subdir of the komira-ai channel, holding the files of core 1.0.0 `entries` say, each
/// `{ compiler, sha, size }`.
fn repodataOf(a: Allocator, subdir: []const u8, entries: []const [3][]const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    try out.writer().print("{{\"info\":{{\"subdir\":\"{s}\"}},\"packages\":{{}},\"packages.conda\":{{", .{subdir});
    for (entries, 0..) |e, i| {
        try out.writer().print("{s}\"mojo-komira-ai.core-1.0.0-mojo{s}_0.conda\":{{\"build\":\"mojo{s}_0\",\"depends\":[\"mojo-compiler =={s}\"],\"sha256\":\"{s}\",\"size\":{s}}}", .{ if (i > 0) "," else "", e[0], e[0], e[0], e[1], e[2] });
    }
    try out.appendSlice("},\"removed\":[]}\n");
    return out.items;
}

test "a version with builds for 1.0.0 and 1.1.0, resolved for both, is one entry per subdir with an artifact per Mojo, each with its own file, url, sha256 and size" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = comptime line("1.0.0", "1.0.0", "[" ++
        buildOf("mojo1.0.0_0", "==1.0.0", fileOf("1.0.0", "1.0.0", "linux-64", sha_a, "1001") ++ "," ++ fileOf("1.0.0", "1.0.0", "osx-arm64", sha_b, "1002")) ++ "," ++
        buildOf("mojo1.1.0_0", "==1.1.0", fileOf("1.0.0", "1.1.0", "linux-64", sha_c, "1003") ++ "," ++ fileOf("1.0.0", "1.1.0", "osx-arm64", sha_d, "1004")) ++ "]");
    const index = resolve.MemoryIndex{ .files = &.{.{ "komira-ai/core", text }} };
    // The channel holds the files of both builds in each subdir.
    const channel = plan.MemoryChannel{ .files = &.{
        .{ "komira-ai/linux-64", try repodataOf(a, "linux-64", &.{ .{ "1.0.0", sha_a, "1001" }, .{ "1.1.0", sha_c, "1003" } }) },
        .{ "komira-ai/osx-arm64", try repodataOf(a, "osx-arm64", &.{ .{ "1.0.0", sha_b, "1002" }, .{ "1.1.0", sha_d, "1004" } }) },
    } };

    var diag: resolve.Diagnostic = .{};
    const for_10 = try plan.buildLock(a, try pick(a, index, "1.0.0", "1"), "https://conda.mopm.dev/", channel, null, &diag);
    const for_11 = try plan.buildLock(a, try pick(a, index, "1.1.0", "1"), "https://conda.mopm.dev/", channel, null, &diag);

    // Each Mojo's lock holds only the files of its own build.
    try std.testing.expectEqual(@as(usize, 2), for_10.packages.len);
    for (for_10.packages) |p| try std.testing.expectEqualStrings("mojo1.0.0_0", p.build);
    try std.testing.expectEqual(@as(usize, 2), for_11.packages.len);
    for (for_11.packages) |p| try std.testing.expectEqualStrings("mojo1.1.0_0", p.build);

    const closures = [_]lock.Closure{
        .{ .mojo = "1.0.0", .subdir = "linux-64", .sha256 = "c" ** 64 },
        .{ .mojo = "1.0.0", .subdir = "osx-arm64", .sha256 = "c" ** 64 },
        .{ .mojo = "1.1.0", .subdir = "linux-64", .sha256 = "d" ** 64 },
        .{ .mojo = "1.1.0", .subdir = "osx-arm64", .sha256 = "d" ** 64 },
    };
    const merged = try plan.mergeMojos(a, &.{ for_11, for_10 }, &closures);
    try std.testing.expectEqual(@as(usize, 2), merged.packages.len);
    const Want = struct { subdir: []const u8, sha_10: []const u8, size_10: u64, sha_11: []const u8, size_11: u64 };
    const wants = [_]Want{
        .{ .subdir = "linux-64", .sha_10 = sha_a, .size_10 = 1001, .sha_11 = sha_c, .size_11 = 1003 },
        .{ .subdir = "osx-arm64", .sha_10 = sha_b, .size_10 = 1002, .sha_11 = sha_d, .size_11 = 1004 },
    };
    for (wants, merged.packages) |w, p| {
        try std.testing.expectEqualStrings("komira-ai/core", p.name);
        try std.testing.expectEqualStrings("1.0.0", p.version);
        try std.testing.expectEqualStrings(w.subdir, p.subdir);
        try std.testing.expectEqual(@as(usize, 2), p.artifacts.len);
        try std.testing.expectEqualStrings("1.0.0", p.artifacts[0].mojo);
        try std.testing.expectEqualStrings("mojo1.0.0_0", p.artifacts[0].build);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "https://conda.mopm.dev/komira-ai/{s}/mojo-komira-ai.core-1.0.0-mojo1.0.0_0.conda", .{w.subdir}), p.artifacts[0].url);
        try std.testing.expectEqualStrings(w.sha_10, p.artifacts[0].sha256);
        try std.testing.expectEqual(w.size_10, p.artifacts[0].size);
        try std.testing.expectEqualStrings("1.1.0", p.artifacts[1].mojo);
        try std.testing.expectEqualStrings("mojo1.1.0_0", p.artifacts[1].build);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "https://conda.mopm.dev/komira-ai/{s}/mojo-komira-ai.core-1.0.0-mojo1.1.0_0.conda", .{w.subdir}), p.artifacts[1].url);
        try std.testing.expectEqualStrings(w.sha_11, p.artifacts[1].sha256);
        try std.testing.expectEqual(w.size_11, p.artifacts[1].size);
    }
    // The merged lock is one the lock reader accepts, and it reads back to the same bytes.
    try std.testing.expectEqual(@as(?[]const u8, null), try lock.check(a, merged));
    const written = try lock.render(a, merged);
    var why: []const u8 = "";
    try std.testing.expectEqualStrings(written, try lock.render(a, try lock.parse(a, written, &why)));
}

test "the lock takes a file's sha256 and size for its build from the repodata that names that build's file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = comptime line("1.0.0", "1.0.0", "[" ++
        buildOf("mojo1.0.0_0", "==1.0.0", fileOf("1.0.0", "1.0.0", "linux-64", sha_a, "1001")) ++ "," ++
        buildOf("mojo1.1.0_0", "==1.1.0", fileOf("1.0.0", "1.1.0", "linux-64", sha_c, "1003")) ++ "]");
    const index = resolve.MemoryIndex{ .files = &.{.{ "komira-ai/core", text }} };
    // The repodata disagrees with the index about the 1.1.0 file only.
    const channel = plan.MemoryChannel{ .files = &.{.{ "komira-ai/linux-64", try repodataOf(a, "linux-64", &.{ .{ "1.0.0", sha_a, "1001" }, .{ "1.1.0", sha_d, "1003" } }) }} };
    var diag: resolve.Diagnostic = .{};
    _ = try plan.buildLock(a, try pick(a, index, "1.0.0", "1"), "https://conda.mopm.dev/", channel, null, &diag);
    try std.testing.expectError(error.ResolveFailed, plan.buildLock(a, try pick(a, index, "1.1.0", "1"), "https://conda.mopm.dev/", channel, null, &diag));
    try std.testing.expectEqual(resolve.Kind.bad_channel, diag.kind);
    try std.testing.expectEqualStrings("mojo-komira-ai.core-1.0.0-mojo1.1.0_0.conda: the index says sha256 " ++ sha_c ++ ", size 1003; komira-ai/linux-64/repodata.json says sha256 " ++ sha_d ++ ", size 1003", diag.message);
}

test "a lock is not built for a Mojo the picked version has no build for" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const recs = try parse(a, comptime line("1.0.0", "1.0.0", builtFor("1.0.0", &.{"1.0.0"})));
    const res = resolve.Resolution{ .mojo = "1.1.0", .packages = &.{.{ .record = &recs[0], .deps = &.{} }} };
    var diag: resolve.Diagnostic = .{};
    const channel = plan.MemoryChannel{ .files = &.{} };
    try std.testing.expectError(error.ResolveFailed, plan.buildLock(a, res, "https://conda.mopm.dev/", channel, null, &diag));
    try std.testing.expectEqual(resolve.Kind.compiler_mismatch, diag.kind);
    try std.testing.expectEqualStrings("komira-ai/core 1.0.0 has no build for Mojo 1.1.0", diag.message);
}
