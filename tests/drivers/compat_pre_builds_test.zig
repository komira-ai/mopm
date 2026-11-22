//! The last command line before a version could have several builds (main at commit 8b8a8cc) reading what this release writes,
//! and this release reading what that one reads, in one process with no socket and no child process.
//!
//! The previous reader is its own code, byte for byte: its sparse-index reader and resolver, its package-metadata reader and its
//! generated registry client, vendored under tests/compat/pre_builds and built as the module `prev_pre_builds`
//! (tests/compat/prev_pre_builds.zig). Every run first checks that each vendored file still hashes to its line of SHA256SUMS, so a
//! run that passes ran the released bytes.
//!
//! What it is given is what this release writes, in the shape the writers use (the TypeScript index writer of service/api
//! and the fake registry write the same keys, sorted): an index line with `builds`, a getVersion body with `builds`, and a
//! package's `<name>.mopm.json` with `source_sha256`, the last made by the current writer itself.
//!
//! The other direction, this release reading a line without `builds`, a v1 line and a getVersion body without `builds`, is held
//! by src/core/builds_test.zig ("a line without builds is one build: the top-level one"), the prod-shape tests of the registry
//! (service/api/test/prod-shape.test.ts, over the fixtures of a registry release that predates `builds`) and
//! tests/drivers/multi_build_test.zig; here it is checked only for the lines this file feeds the previous reader.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const prev = @import("prev_pre_builds");

const snapshot = "tests/compat/pre_builds";

/// The repository root: BUILDRULES_TEST_WORK (the target's `data`) in the Buck2 build, else the current directory (the repository
/// root, as `zig build test` runs).
fn rootDir() !std.fs.Dir {
    const path = std.process.getEnvVarOwned(std.testing.allocator, "BUILDRULES_TEST_WORK") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return std.fs.cwd().openDir(".", .{}),
        else => return err,
    };
    defer std.testing.allocator.free(path);
    return std.fs.cwd().openDir(path, .{});
}

fn sha256Hex(a: Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(a, "{}", .{std.fmt.fmtSliceHexLower(&digest)});
}

/// Every line of `sums` ("<sha256>  <path>", the path relative to `dir`) names a file that hashes to it, and every file under
/// `<vendored>/core` (at any depth) has a line: what the module is built from is the released code, unedited. Null when all of
/// this holds; otherwise the first problem.
fn snapshotProblem(a: Allocator, dir: std.fs.Dir, sums: []const u8, vendored: []const u8) !?[]const u8 {
    const text = dir.readFileAlloc(a, sums, 1 << 20) catch |e| return try std.fmt.allocPrint(a, "{s}: {s}", .{ sums, @errorName(e) });
    var listed = std.StringHashMap(void).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (line.len <= 66 or !std.mem.eql(u8, line[64..66], "  ")) return try std.fmt.allocPrint(a, "not a SHA256SUMS line: {s}", .{line});
        const rel = line[66..];
        const bytes = dir.readFileAlloc(a, rel, 1 << 24) catch |e| return try std.fmt.allocPrint(a, "{s}: {s}", .{ rel, @errorName(e) });
        if (!std.mem.eql(u8, line[0..64], try sha256Hex(a, bytes))) return try std.fmt.allocPrint(a, "{s} does not hash to its line", .{rel});
        try listed.put(rel, {});
    }
    const core_path = try std.fmt.allocPrint(a, "{s}/core", .{vendored});
    var core_dir = dir.openDir(core_path, .{ .iterate = true }) catch |e| return try std.fmt.allocPrint(a, "{s}/: {s}", .{ core_path, @errorName(e) });
    defer core_dir.close();
    var walker = try core_dir.walk(a);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ core_path, entry.path });
        if (!listed.contains(rel)) return try std.fmt.allocPrint(a, "not in SHA256SUMS: {s}", .{rel});
    }
    return null;
}

test "a snapshot with an edited, an unlisted (at any depth) or a missing file is refused, naming it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const body = "pub const x = 1;\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("v/core/toolchain");
    try tmp.dir.writeFile("v/core/x.zig", body);
    try tmp.dir.writeFile("SHA256SUMS", try std.fmt.allocPrint(a, "{s}  v/core/x.zig\n", .{try sha256Hex(a, body)}));
    try std.testing.expectEqual(@as(?[]const u8, null), try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v"));
    try tmp.dir.writeFile("v/core/x.zig", "pub const x = 2;\n");
    try std.testing.expectEqualStrings("v/core/x.zig does not hash to its line", (try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v")).?);
    try tmp.dir.writeFile("v/core/x.zig", body);
    try tmp.dir.writeFile("v/core/toolchain/extra.json", "{}");
    try std.testing.expectEqualStrings("not in SHA256SUMS: v/core/toolchain/extra.json", (try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v")).?);
    try tmp.dir.deleteFile("v/core/toolchain/extra.json");
    try tmp.dir.deleteFile("v/core/x.zig");
    try std.testing.expectEqualStrings("v/core/x.zig: FileNotFound", (try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v")).?);
    try tmp.dir.writeFile("SHA256SUMS", "abc  v/core/x.zig\n");
    try std.testing.expectEqualStrings("not a SHA256SUMS line: abc  v/core/x.zig", (try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v")).?);
    try tmp.dir.deleteFile("SHA256SUMS");
    try std.testing.expectEqualStrings("SHA256SUMS: FileNotFound", (try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v")).?);
    try tmp.dir.writeFile("SHA256SUMS", "");
    try tmp.dir.deleteTree("v/core");
    try std.testing.expectEqualStrings("v/core/: FileNotFound", (try snapshotProblem(a, tmp.dir, "SHA256SUMS", "v")).?);
}

test "the vendored readers before builds hash to their SHA256SUMS" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var root = try rootDir();
    defer root.close();
    try std.testing.expectEqual(@as(?[]const u8, null), try snapshotProblem(arena_state.allocator(), root, snapshot ++ "/SHA256SUMS", snapshot));
}

// ---- The previous reader on an index line with builds -------------------------------------------------------------------

const sha_a = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";
const sha_b = "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae";
const sha_c = "fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9";
const full_name = "komira-ai/core";

/// A file of `komira-ai/core` `version` built with `compiler` for linux-64, in the registry's layout (keys sorted).
fn fileOf(comptime version: []const u8, comptime compiler: []const u8, comptime sha: []const u8, comptime size: []const u8) []const u8 {
    return "{\"filename\":\"mojo-komira-ai.core-" ++ version ++ "-mojo" ++ compiler ++ "_0.conda\",\"sha256\":\"" ++ sha ++ "\",\"size\":" ++ size ++ ",\"subdir\":\"linux-64\"}";
}

/// An entry of `builds`.
fn buildOf(comptime version: []const u8, comptime compiler: []const u8, comptime sha: []const u8, comptime size: []const u8) []const u8 {
    return "{\"build\":\"mojo" ++ compiler ++ "_0\",\"files\":[" ++ fileOf(version, compiler, sha, size) ++ "],\"requires_mojo\":\"==" ++ compiler ++ "\"}";
}

/// The line of version `version` as the index writer writes a version with several builds: the top-level `build`,
/// `requires_mojo` and `files` are the primary build's (`primary`, the lowest compiler), and `builds` lists every build (a JSON
/// array of `buildOf` entries, the primary first).
fn lineOf(comptime version: []const u8, comptime primary: []const u8, comptime primary_sha: []const u8, comptime primary_size: []const u8, comptime builds: []const u8) []const u8 {
    return "{\"build\":\"mojo" ++ primary ++ "_0\",\"builds\":" ++ builds ++ ",\"deps\":[],\"files\":[" ++ fileOf(version, primary, primary_sha, primary_size) ++
        "],\"manifest_sha256\":\"" ++ sha_a ++ "\",\"name\":\"" ++ full_name ++ "\",\"native\":[],\"provenance\":{\"kind\":\"none\"}," ++
        "\"published_at\":\"2026-10-13T12:00:00Z\",\"requires_mojo\":\"==" ++ primary ++ "\",\"state\":\"published\",\"v\":2,\"version\":\"" ++ version ++ "\"}\n";
}

/// Version 1.0.0 built with Mojo 1.0.0 (primary) and 1.1.0.
const two_builds = lineOf("1.0.0", "1.0.0", sha_a, "1000", "[" ++ buildOf("1.0.0", "1.0.0", sha_a, "1000") ++ "," ++ buildOf("1.0.0", "1.1.0", sha_b, "2000") ++ "]");

/// Version 1.1.0 built with Mojo 1.1.0 (primary) and 1.2.0.
const newer_builds = lineOf("1.1.0", "1.1.0", sha_c, "3000", "[" ++ buildOf("1.1.0", "1.1.0", sha_c, "3000") ++ "," ++ buildOf("1.1.0", "1.2.0", sha_b, "4000") ++ "]");

const IndexOf = prev.resolve.MemoryIndex;

/// What the previous resolver makes of `text`, the index of `komira-ai/core`, for a project on Mojo `mojo` that asks for any version
/// of it: the picked record, or the diagnostic of its failure.
const Outcome = union(enum) { picked: prev.resolve.Record, failed: prev.resolve.Diagnostic };

fn resolveWithPrevious(a: Allocator, text: []const u8, mojo: []const u8) !Outcome {
    const index = IndexOf{ .files = &.{.{ full_name, text }} };
    var diag: prev.resolve.Diagnostic = .{};
    const r = prev.resolve.resolve(a, index, .{
        .mojo = mojo,
        .roots = &.{.{ .name = full_name, .requirement = "1" }},
        .mojoc_message = true,
    }, &diag) catch |e| switch (e) {
        error.ResolveFailed => return .{ .failed = diag },
        else => return e,
    };
    try std.testing.expectEqual(@as(usize, 1), r.packages.len);
    return .{ .picked = r.packages[0].record.* };
}

test "the previous reader takes a line with builds as one build, the top-level one, and resolves Mojo 1.0.0 to its 1.0.0 file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const picked = (try resolveWithPrevious(a, two_builds, "1.0.0")).picked;
    try std.testing.expectEqualStrings("1.0.0", picked.version);
    try std.testing.expectEqualStrings("mojo1.0.0_0", picked.build);
    try std.testing.expectEqualStrings("==1.0.0", picked.requires_mojo);
    try std.testing.expectEqual(@as(usize, 1), picked.files.len);
    try std.testing.expectEqualStrings("mojo-komira-ai.core-1.0.0-mojo1.0.0_0.conda", picked.files[0].filename);
    try std.testing.expectEqualStrings(sha_a, picked.files[0].sha256);
    try std.testing.expectEqual(@as(u64, 1000), picked.files[0].size);
    try std.testing.expectEqualStrings("linux-64", picked.files[0].subdir);
}

test "the previous reader stops on Mojo 1.1.0 with its own 'no .mojoc' message and returns no 1.1.0 file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const failed = (try resolveWithPrevious(a, two_builds, "1.1.0")).failed;
    try std.testing.expectEqual(prev.resolve.Kind.compiler_mismatch, failed.kind);
    try std.testing.expectEqualStrings("komira-ai/core 1.0.0 has no .mojoc for Mojo 1.1.0 (published for: 1.0.0). Build with mojo 1.0.0, ask the publisher for a 1.1.0 build, or pin a version that has one.", failed.message);
}

test "the previous reader never returns a file built with another Mojo than the project's, over an index of two versions with builds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = two_builds ++ newer_builds;

    // 1.1.0's own primary build is for 1.1.0, so it is the newest version for a project on 1.1.0; for 1.0.0 it is skipped.
    const on_10 = (try resolveWithPrevious(a, text, "1.0.0")).picked;
    try std.testing.expectEqualStrings("1.0.0", on_10.version);
    try std.testing.expectEqualStrings("mojo-komira-ai.core-1.0.0-mojo1.0.0_0.conda", on_10.files[0].filename);
    const on_11 = (try resolveWithPrevious(a, text, "1.1.0")).picked;
    try std.testing.expectEqualStrings("1.1.0", on_11.version);
    try std.testing.expectEqualStrings("mojo-komira-ai.core-1.1.0-mojo1.1.0_0.conda", on_11.files[0].filename);
    try std.testing.expectEqualStrings(sha_c, on_11.files[0].sha256);

    // 1.2.0 exists only as a second build of 1.1.0: the previous reader does not see it, and says what the line published for.
    const on_12 = (try resolveWithPrevious(a, text, "1.2.0")).failed;
    try std.testing.expectEqual(prev.resolve.Kind.compiler_mismatch, on_12.kind);
    try std.testing.expectEqualStrings("komira-ai/core 1.1.0 has no .mojoc for Mojo 1.2.0 (published for: 1.1.0). Build with mojo 1.1.0, ask the publisher for a 1.2.0 build, or pin a version that has one.", on_12.message);
}

test "the lines this file feeds the previous reader are lines this release reads as several builds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: core.resolve.Diagnostic = .{};
    const recs = try core.resolve.parseIndex(a, full_name, two_builds ++ newer_builds, &diag);
    try std.testing.expectEqual(@as(usize, 2), recs.len);
    try std.testing.expectEqual(@as(usize, 2), recs[0].builds.len);
    try std.testing.expectEqualStrings("mojo1.1.0_0", recs[0].builds[1].build);
    try std.testing.expect(recs[0].builtFor("1.0.0") and recs[0].builtFor("1.1.0") and !recs[0].builtFor("1.2.0"));
    try std.testing.expect(recs[1].builtFor("1.1.0") and recs[1].builtFor("1.2.0") and !recs[1].builtFor("1.0.0"));
}

// ---- The previous metadata reader on a package file with source_sha256 --------------------------------------------------------

test "the previous metadata reader reads a package's .mopm.json with source_sha256 and ignores the key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // What this release's writer makes, with the digest between schema and version (src/core/conda.zig).
    const digest = "0123456789abcdef" ** 4;
    const text = try core.conda.mopmJson(a, .{ .name = "example/demo", .version = "1.2.3", .compiler = "1.0.0", .subdir = "linux-64", .mojoc = "MOJOC", .source_sha256 = digest });
    try std.testing.expect(std.mem.indexOf(u8, text, "\"source_sha256\":\"" ++ digest ++ "\"") != null);

    const m = try prev.metadata.parse(a, text);
    try std.testing.expectEqual(@as(u32, 2), m.schema);
    try std.testing.expectEqualStrings("example/demo", m.name);
    try std.testing.expectEqualStrings("1.2.3", m.version);
    try std.testing.expectEqual(@as(usize, 0), m.deps.len);
    try std.testing.expectEqual(@as(usize, 0), m.native.len);
}

// ---- The previous generated client on a getVersion answer with builds ---------------------------------------------------------

/// The answer of `GET /api/v2/packages/komira-ai/core/1.0.0` for the version of `two_builds`: the top-level `requires_mojo` and
/// `files` are the primary build's, and `builds` lists both.
const version_body = "{\"name\":\"komira-ai/core\",\"version\":\"1.0.0\",\"state\":\"published\",\"published_at\":\"2026-10-13T12:00:00Z\"," ++
    "\"requires_mojo\":\"==1.0.0\",\"deps\":[],\"native\":[],\"files\":[" ++ fileOf("1.0.0", "1.0.0", sha_a, "1000") ++ "]," ++
    "\"manifest_sha256\":\"" ++ sha_a ++ "\",\"provenance\":{\"kind\":\"none\"}," ++
    "\"builds\":[" ++ buildOf("1.0.0", "1.0.0", sha_a, "1000") ++ "," ++ buildOf("1.0.0", "1.1.0", sha_b, "2000") ++ "]}";

test "the previous registry client decodes a getVersion answer with builds, reads its primary build and ignores builds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try prev.registry_v2.decode(prev.registry_v2.GetVersion, a, version_body);
    try std.testing.expectEqualStrings("komira-ai/core", v.name);
    try std.testing.expectEqualStrings("1.0.0", v.version);
    try std.testing.expectEqual(prev.registry_v2.VersionState.published, v.state);
    try std.testing.expectEqualStrings("==1.0.0", v.requires_mojo);
    try std.testing.expectEqual(@as(usize, 1), v.files.len);
    try std.testing.expectEqualStrings("mojo-komira-ai.core-1.0.0-mojo1.0.0_0.conda", v.files[0].filename);
    try std.testing.expectEqualStrings(sha_a, v.files[0].sha256);
    try std.testing.expectEqual(@as(i64, 1000), v.files[0].size);

    // This release reads the same answer as two builds, so the body is one it writes.
    const now = try core.registry_v2.decode(core.registry_v2.GetVersion, a, version_body);
    try std.testing.expectEqual(@as(usize, 2), now.builds.?.len);
    try std.testing.expectEqualStrings("mojo1.1.0_0", now.builds.?[1].build);
}
