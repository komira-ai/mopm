//! Drives the built `zip_bundle` executable as a process, the way a deploy step does: arguments in, exit status, stderr, and
//! the directory it writes. The build gives it the executable in $ZIP_BUNDLE. Inputs are scratch files in a temporary
//! directory, which is also the child's working directory.

const std = @import("std");

const Run = struct { code: u8, stderr: []const u8 };

fn run(a: std.mem.Allocator, dir: std.fs.Dir, args: []const []const u8) !Run {
    const exe_env = try std.process.getEnvVarOwned(a, "ZIP_BUNDLE");
    const exe = try std.fs.cwd().realpathAlloc(a, exe_env);
    var argv = std.ArrayList([]const u8).init(a);
    try argv.append(exe);
    try argv.appendSlice(args);
    const res = try std.process.Child.run(.{ .allocator = a, .argv = argv.items, .cwd_dir = dir });
    const code: u8 = switch (res.term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stderr = res.stderr };
}

fn expectNoEntry(dir: std.fs.Dir, path: []const u8) !void {
    try std.testing.expectError(error.FileNotFound, dir.statFile(path));
}

fn hex(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &h, .{});
    return std.fmt.allocPrint(a, "{s}", .{std.fmt.fmtSliceHexLower(&h)});
}

test "two zips: exit 0, each zip byte for byte and the exact sums" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const one = "PK\x03\x04 one";
    const two = "\x00\xff\x00 two";
    try tmp.dir.writeFile("in1.zip", one);
    try tmp.dir.writeFile("in2.zip", two);

    const r = try run(a, tmp.dir, &.{ "out", "web-session=in2.zip", "web=in1.zip" });
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings("", r.stderr);

    var out = try tmp.dir.openDir("out", .{ .iterate = true });
    defer out.close();
    try std.testing.expectEqualStrings(one, try out.readFileAlloc(a, "web.zip", 1000));
    try std.testing.expectEqualStrings(two, try out.readFileAlloc(a, "web-session.zip", 1000));
    // `web-session.zip` sorts before `web.zip`: '-' is below '.'.
    const want = try std.fmt.allocPrint(a, "{s}  web-session.zip\n{s}  web.zip\n", .{ try hex(a, two), try hex(a, one) });
    try std.testing.expectEqualStrings(want, try out.readFileAlloc(a, "sums", 1000));
    var n: usize = 0;
    var it = out.iterate();
    while (try it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 3), n);
}

test "a name that is not a function name: exit 1, the message, no out dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile("in.zip", "x");
    const r = try run(a, tmp.dir, &.{ "out", "Web_Login=in.zip" });
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqualStrings("zip_bundle: `Web_Login` is not a function name (lower-case words joined by '-')\n", r.stderr);
    try expectNoEntry(tmp.dir, "out");
}

test "a name given twice: exit 1, the message, no out dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile("in.zip", "x");
    const r = try run(a, tmp.dir, &.{ "out", "web=in.zip", "web=in.zip" });
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqualStrings("zip_bundle: `web` is given twice\n", r.stderr);
    try expectNoEntry(tmp.dir, "out");
}

test "an out dir that exists: exit 1, the message, the directory untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile("in.zip", "x");
    try tmp.dir.makeDir("out");
    try tmp.dir.writeFile("out/keep", "mine");
    const r = try run(a, tmp.dir, &.{ "out", "web=in.zip" });
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqualStrings("zip_bundle: out already exists\n", r.stderr);
    var out = try tmp.dir.openDir("out", .{ .iterate = true });
    defer out.close();
    try std.testing.expectEqualStrings("mine", try out.readFileAlloc(a, "keep", 100));
    var n: usize = 0;
    var it = out.iterate();
    while (try it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "no arguments: exit 1 and the usage line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try run(arena.allocator(), std.fs.cwd(), &.{});
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqualStrings("usage: zip_bundle <out_dir> <name>=<zip> ...\n", r.stderr);
}

test "an out dir and no pairs: exit 1, the message, no out dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try run(a, tmp.dir, &.{"out"});
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqualStrings("zip_bundle: no <name>=<zip> given\n", r.stderr);
    try expectNoEntry(tmp.dir, "out");
}

test "an unreadable zip: exit 1, the message naming it, no out dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile("in.zip", "x");
    const r = try run(a, tmp.dir, &.{ "out", "web=in.zip", "other=missing.zip" });
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqualStrings("zip_bundle: cannot read missing.zip: FileNotFound\n", r.stderr);
    try expectNoEntry(tmp.dir, "out");
}
