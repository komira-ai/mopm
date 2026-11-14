//! //:import_clash_cli: the built `mopm` refuses a closure with two packages of one import name
//! (spec/mopm-toml.md, "Rules"; spec/lock.md, rule 10), run as a command on projects in a temporary directory.
//!
//! What it proves:
//!   - `mopm lock` refuses two path packages of one import name in two namespaces, and a path package against a
//!     registry dependency of the same import name, with exit 1, the full message and each package's path from
//!     the root; an existing mopm.lock keeps its bytes, and none is written where there was none;
//!   - `mopm tree` and `mopm sync --locked` refuse a lock whose closure holds the root's import name a second time,
//!     with exit 1 and the message, and leave the lock as it was; the same project with a sound lock draws its tree.
//! Every refusal comes before any request: no case needs a registry or a network.
//!
//! Run by Buck2 (//:import_clash_cli) and by `zig build test`; MOPM is the built CLI.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

const head_fmt = "mopm {s}: 2 packages in the dependency closure have the import name '{s}'; Mojo imports a package by the part after '/', so a closure holds one package per import name:\n";
const tail = "There is no rename: drop one of the dependencies that brings them in.\n";

const World = struct {
    a: Allocator,
    mopm: []const u8,
    root: []const u8,
    env: std.process.EnvMap,

    fn put(w: *World, rel: []const u8, bytes: []const u8) !void {
        const path = try h.join(w.a, &.{ w.root, rel });
        try std.fs.cwd().makePath(std.fs.path.dirname(path).?);
        try h.writeFile(path, bytes);
    }

    fn mopmIn(w: *World, dir: []const u8, args: []const []const u8) !h.Ran {
        const argv = try w.a.alloc([]const u8, args.len + 1);
        argv[0] = w.mopm;
        @memcpy(argv[1..], args);
        return h.run(w.a, argv, &w.env, .{ .cwd = try h.join(w.a, &.{ w.root, dir }) });
    }

    fn exists(w: *World, rel: []const u8) bool {
        std.fs.cwd().access(h.join(w.a, &.{ w.root, rel }) catch return false, .{}) catch return false;
        return true;
    }

    fn read(w: *World, rel: []const u8) ![]u8 {
        return h.readFile(w.a, try h.join(w.a, &.{ w.root, rel }));
    }
};

fn pkg(a: Allocator, full: []const u8, version: []const u8, deps: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "[package]\nname = \"{s}\"\nversion = \"{s}\"\n\n[toolchain]\nmojo = \"1.0.0\"\n\n[dependencies]\n{s}", .{ full, version, deps });
}

fn entry(a: Allocator, name: []const u8, version: []const u8, comptime sha: u8, deps: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\    {{"name": "{s}", "version": "{s}", "build": "mojo1.0.0_0", "subdir": "linux-64", "channel": "https://conda.mopm.dev/", "url": "https://conda.mopm.dev/linux-64/mojo-{s}-{s}-mojo1.0.0_0.conda", "sha256": "{s}", "size": 1000, "mojo": "1.0.0"{s}}}
    , .{ name, version, name, version, &([_]u8{sha} ** 64), deps });
}

fn lockOf(a: Allocator, entries: []const []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\n  \"lock_version\": 1,\n  \"toolchain\": {{\"mojo\": \"1.0.0\"}},\n  \"channels\": [\"https://conda.mopm.dev/\"],\n  \"packages\": [\n{s}\n  ]\n}}\n", .{try std.mem.join(a, ",\n", entries)});
}

fn expectRefused(ran: h.Ran, want: []const u8) !void {
    if (ran.signaled or ran.code != 1) {
        std.debug.print("exit {d} (signaled {}), want 1; output:\n{s}\n", .{ ran.code, ran.signaled, ran.text });
        return error.WrongExit;
    }
    try std.testing.expectEqualStrings(want, ran.text);
}

test "mopm lock, tree and sync refuse two packages of one import name, with paths, and keep the lock" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var w = World{ .a = a, .mopm = try h.toolPath(a, "MOPM"), .root = try h.tmpPath(a, &tmp), .env = try h.environ(a) };

    // 1. Two path packages: example/util, and other/util through example/mid.
    try w.put("two_paths/mopm.toml", try pkg(a, "example/app", "1.0.0", "\"example/util\" = { path = \"util\" }\n\"example/mid\" = { path = \"mid\" }\n"));
    try w.put("two_paths/util/mopm.toml", try pkg(a, "example/util", "0.3.0", ""));
    try w.put("two_paths/mid/mopm.toml", try pkg(a, "example/mid", "0.2.0", "\"other/util\" = { path = \"../other_util\" }\n"));
    try w.put("two_paths/other_util/mopm.toml", try pkg(a, "other/util", "0.5.0", ""));
    const old_lock = try lockOf(a, &.{});
    try w.put("two_paths/mopm.lock", old_lock);
    try expectRefused(try w.mopmIn("two_paths", &.{"lock"}), try std.mem.concat(a, u8, &.{ try std.fmt.allocPrint(a, head_fmt, .{ "lock", "util" }), "" ++
        "  example/util 0.3.0     example/app -> example/util 0.3.0\n" ++
        "  other/util 0.5.0       example/app -> example/mid 0.2.0 -> other/util 0.5.0\n" ++
        tail }));
    try std.testing.expectEqualStrings(old_lock, try w.read("two_paths/mopm.lock"));

    // 2. A path package (alice/json, through example/util) against a registry dependency (komira-ai/json): refused
    // before resolution, so the registry is never asked and its requirement stands in for a version.
    try w.put("path_registry/mopm.toml", try pkg(a, "example/app", "1.0.0", "\"example/util\" = { path = \"util\" }\n\"komira-ai/json\" = \"0.1\"\n"));
    try w.put("path_registry/util/mopm.toml", try pkg(a, "example/util", "0.3.0", "\"alice/json\" = { path = \"../json\" }\n"));
    try w.put("path_registry/json/mopm.toml", try pkg(a, "alice/json", "0.2.0", ""));
    try expectRefused(try w.mopmIn("path_registry", &.{"lock"}), try std.mem.concat(a, u8, &.{ try std.fmt.allocPrint(a, head_fmt, .{ "lock", "json" }), "" ++
        "  alice/json 0.2.0         example/app -> example/util 0.3.0 -> alice/json 0.2.0\n" ++
        "  komira-ai/json \"0.1\"     example/app -> komira-ai/json \"0.1\"\n" ++
        tail }));
    try std.testing.expect(!w.exists("path_registry/mopm.lock"));

    // 3. A lock that pins a second json under the root example/json: tree and sync read it and refuse.
    try w.put("lock_read/mopm.toml", try pkg(a, "example/json", "0.1.0", "\"example/http\" = \"0.3\"\n"));
    const clash_lock = try lockOf(a, &.{ try entry(a, "http", "0.3.0", 'a', ", \"deps\": [\"json\"]"), try entry(a, "json", "1.2.0", 'b', "") });
    try w.put("lock_read/mopm.lock", clash_lock);
    const rows =
        "  example/json 0.1.0     example/json\n" ++
        "  json 1.2.0             example/json -> example/http 0.3.0 -> json 1.2.0\n" ++
        tail;
    try expectRefused(try w.mopmIn("lock_read", &.{"tree"}), try std.mem.concat(a, u8, &.{ try std.fmt.allocPrint(a, head_fmt, .{ "tree", "json" }), rows }));
    try expectRefused(try w.mopmIn("lock_read", &.{ "sync", "--locked" }), try std.mem.concat(a, u8, &.{ try std.fmt.allocPrint(a, head_fmt, .{ "sync", "json" }), rows }));
    try std.testing.expectEqualStrings(clash_lock, try w.read("lock_read/mopm.lock"));

    // 4. The same lock without the second json: tree draws it.
    try w.put("sound/mopm.toml", try pkg(a, "example/json", "0.1.0", "\"example/http\" = \"0.3\"\n"));
    try w.put("sound/mopm.lock", try lockOf(a, &.{try entry(a, "http", "0.3.0", 'a', "")}));
    const ok = try w.mopmIn("sound", &.{"tree"});
    if (ok.signaled or ok.code != 0) {
        std.debug.print("tree on a sound lock: exit {d}; output:\n{s}\n", .{ ok.code, ok.text });
        return error.WrongExit;
    }
    try std.testing.expect(h.contains(ok.text, "http 0.3.0"));
}
