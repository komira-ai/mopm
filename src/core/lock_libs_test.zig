//! Tests of the system libraries of a lock (lock_libs.zig, spec/lock.md "System libraries"): what is read and written
//! back, each rule that is refused, and the closure of a library. mopm_core.zig runs them with the rest.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lock = @import("lock.zig");
const lock_libs = @import("lock_libs.zig");

fn lib(a: Allocator, name: []const u8, deps: []const u8, sha: []const u8, url: []const u8, size: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"name\": \"{s}\", \"version\": \"3.5\", \"build\": \"h0_0\", \"url\": \"{s}\", \"sha256\": \"{s}\", \"size\": {s}, \"deps\": [{s}]}}", .{ name, url, sha, size, deps });
}

fn goodLib(a: Allocator, name: []const u8, deps: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(a, "https://conda.anaconda.org/conda-forge/linux-64/{s}-3.5-h0_0.conda", .{name});
    return lib(a, name, deps, "b" ** 64, url, "10");
}

/// A version 1 lock of one package, tls, with `loads` text and `libs` text (the entries of system_libs' linux-64).
fn lockText(a: Allocator, loads: []const u8, libs: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\{{"lock_version": 1, "toolchain": {{"mojo": "1.0.0"}}, "channels": ["https://conda.mopm.dev/"], "packages": [
        \\  {{"name": "tls", "version": "1.1.0", "build": "mojo1.0.0_0", "subdir": "linux-64", "channel": "https://conda.mopm.dev/", "url": "https://conda.mopm.dev/linux-64/mojo-tls-1.1.0-mojo1.0.0_0.conda", "sha256": "{s}", "size": 10, "mojo": "1.0.0"{s}}}
        \\], "system_libs": {{"linux-64": [{s}]}}}}
        \\
    , .{ "a" ** 64, loads, libs });
}

/// Why the lock with these parts is refused, or null when it is read.
fn refusal(a: Allocator, loads: []const u8, libs: []const u8) !?[]const u8 {
    var why: []const u8 = "";
    _ = lock.parse(a, try lockText(a, loads, libs), &why) catch |e| {
        if (e == error.Invalid) return why;
        return e;
    };
    return null;
}

fn expectRefused(a: Allocator, loads: []const u8, libs: []const u8, want: []const u8) !void {
    const why = (try refusal(a, loads, libs)) orelse {
        std.debug.print("accepted; want a refusal with '{s}'\n", .{want});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, why, want) == null) {
        std.debug.print("refused with '{s}'; want '{s}'\n", .{ why, want });
        return error.TestUnexpectedResult;
    }
}

test "a lock with system_libs and loads is read, its pins are what it says, and it is written back stably" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const libs = try std.mem.join(a, ",\n", &.{ try goodLib(a, "libsqlite", "\"libzlib\""), try goodLib(a, "libzlib", "") });
    const text = try lockText(a, ", \"loads\": [\"libsqlite\"]", libs);
    var why: []const u8 = "";
    const l = lock.parse(a, text, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqual(@as(usize, 1), l.system_libs.len);
    try std.testing.expectEqualStrings("linux-64", l.system_libs[0].subdir);
    try std.testing.expectEqual(@as(usize, 2), l.system_libs[0].libs.len);
    try std.testing.expectEqualStrings("libsqlite", l.system_libs[0].libs[0].name);
    try std.testing.expectEqualStrings("libzlib", l.system_libs[0].libs[0].deps[0]);
    try std.testing.expectEqual(@as(u64, 10), l.system_libs[0].libs[1].size);
    try std.testing.expectEqualStrings("libsqlite", l.packages[0].loads[0]);
    const once = try lock.render(a, l);
    const again = lock.parse(a, once, &why) catch |e| {
        std.debug.print("written, then refused: {s}\n{s}", .{ why, once });
        return e;
    };
    try std.testing.expectEqualStrings(once, try lock.render(a, again));
    // The layout: `system_libs` is the last key, a lib's `deps` only when it has some.
    try std.testing.expect(std.mem.indexOf(u8, once, "\n  ],\n  \"system_libs\": {\n    \"linux-64\": [\n      {\n        \"name\": \"libsqlite\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, once, "\n      }\n    ]\n  }\n}\n"));
    try std.testing.expect(std.mem.indexOf(u8, once, "\"size\": 10\n      }") != null);
}

test "a lock with neither key is written as it always was" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = "{\"lock_version\": 1, \"toolchain\": {\"mojo\": \"1.0.0\"}, \"channels\": [\"https://conda.mopm.dev/\"], \"packages\": []}\n";
    var why: []const u8 = "";
    const l = try lock.parse(a, text, &why);
    try std.testing.expectEqual(@as(usize, 0), l.system_libs.len);
    const out = try lock.render(a, l);
    try std.testing.expect(std.mem.indexOf(u8, out, "system_libs") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "loads") == null);
}

test "each rule of system_libs and loads is refused, with the reason" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sqlite = try goodLib(a, "libsqlite", "");
    const zlib = try goodLib(a, "libzlib", "");
    const both = try std.mem.join(a, ", ", &.{ sqlite, zlib });
    // What is accepted, so that each refusal below is the one change.
    try std.testing.expect((try refusal(a, ", \"loads\": [\"libsqlite\", \"libzlib\"]", both)) == null);

    try expectRefused(a, ", \"loads\": [\"libbz2\"]", both, "tls: loads libbz2, which system_libs does not pin for linux-64");
    try expectRefused(a, ", \"loads\": [\"libzlib\", \"libsqlite\"]", both, "tls: loads is not sorted with no repeats");
    try expectRefused(a, ", \"loads\": [\"libsqlite\", \"libsqlite\"]", both, "tls: loads is not sorted with no repeats");
    try expectRefused(a, "", try std.mem.join(a, ", ", &.{ zlib, sqlite }), "system_libs of linux-64 is not sorted by name with no repeats (at libsqlite)");
    try expectRefused(a, "", try goodLib(a, "libsqlite", "\"libnothere\""), "libsqlite needs libnothere, which is not another entry of the list");
    try expectRefused(a, "", try goodLib(a, "libsqlite", "\"libsqlite\""), "libsqlite needs libsqlite");
    try expectRefused(a, "", try lib(a, "libsqlite", "", "ABC", "https://conda.example/x.conda", "10"), "libsqlite's sha256 is not 64 lowercase hex digits");
    try expectRefused(a, "", try lib(a, "libsqlite", "", "b" ** 64, "http://conda.example/x.conda", "10"), "is not an https .conda file");
    try expectRefused(a, "", try lib(a, "libsqlite", "", "b" ** 64, "https://conda.example/x.tar.bz2", "10"), "is not an https .conda file");
    try expectRefused(a, "", try goodLib(a, "mojo-compiler", ""), "mojo-compiler is a Mojo package, not a system library");
    try expectRefused(a, "", "", "system_libs of linux-64 is empty");
    try expectRefused(a, "", try lib(a, "libsqlite", "", "b" ** 64, "https://conda.example/x.conda", "0"), "size is not positive");
    try expectRefused(a, "", try std.mem.replaceOwned(u8, a, sqlite, "\"size\": 10, ", ""), "has no size");
    try expectRefused(a, "", try std.mem.replaceOwned(u8, a, sqlite, "\"build\": \"h0_0\", ", ""), "has no build");
    try expectRefused(a, "", try std.mem.replaceOwned(u8, a, sqlite, "\"deps\": []", "\"deps\": [3]"), "has an entry that is not a string");
}

test "a path dependency has no loads, and system_libs must be an object of lists" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const head = "{\"lock_version\": 1, \"toolchain\": {\"mojo\": \"1.0.0\"}, \"channels\": [\"https://conda.mopm.dev/\"], \"packages\": [";
    const path_loads = head ++ "{\"name\": \"util\", \"version\": \"0.3.0\", \"source\": \"path\", \"path\": \"util\", \"loads\": [\"libsqlite\"]}]}";
    try std.testing.expectError(error.Invalid, lock.parse(a, path_loads, &why));
    try std.testing.expectEqualStrings("packages[0] is a path dependency, which has no loads", why);
    try std.testing.expectError(error.Invalid, lock.parse(a, head ++ "], \"system_libs\": []}", &why));
    try std.testing.expectEqualStrings("system_libs is not a JSON object", why);
    try std.testing.expectError(error.Invalid, lock.parse(a, head ++ "], \"system_libs\": {\"linux-64\": {}}}", &why));
    try std.testing.expectEqualStrings("system_libs of linux-64 is not an array", why);
}

test "closureNames: the names and what they need, sorted; a missing name or need is named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = lock_libs.Lib{ .name = "", .version = "1", .build = "0", .url = "https://x/a.conda", .sha256 = "b" ** 64, .size = 1 };
    var libs = [_]lock_libs.Lib{ base, base, base, base, base };
    libs[0].name = "a";
    libs[0].deps = &.{ "b", "c" };
    libs[1].name = "b";
    libs[1].deps = &.{"d"};
    libs[2].name = "c";
    libs[3].name = "d";
    libs[3].deps = &.{"b"}; // a cycle between b and d ends
    libs[4].name = "e";
    var missing: []const u8 = "";
    const got = try lock_libs.closureNames(a, &libs, &.{"a"}, &missing);
    try std.testing.expectEqual(@as(usize, 4), got.len);
    for ([_][]const u8{ "a", "b", "c", "d" }, got) |w, g| try std.testing.expectEqualStrings(w, g);
    // Two names reaching one library list it once; the order of the names does not matter.
    const two = try lock_libs.closureNames(a, &libs, &.{ "e", "d", "e" }, &missing);
    try std.testing.expectEqual(@as(usize, 3), two.len);
    try std.testing.expectEqualStrings("b", two[0]);
    // The first missing name in name order.
    try std.testing.expectError(error.MissingLib, lock_libs.closureNames(a, &libs, &.{ "zz", "a", "yy" }, &missing));
    try std.testing.expectEqualStrings("yy", missing);
    // A need the list does not hold.
    libs[2].deps = &.{"gone"};
    try std.testing.expectError(error.MissingLib, lock_libs.closureNames(a, &libs, &.{"a"}, &missing));
    try std.testing.expectEqualStrings("gone", missing);
}
