//! zip_bundle: gathers the deployment packages of several Lambda functions into one directory.
//!
//!   zip_bundle <out_dir> <name>=<zip> ...
//!
//! Creates `<out_dir>` (it must not exist), copies each zip to `<out_dir>/<name>.zip` byte for
//! byte, and writes `<out_dir>/sums`: `<sha256 of the zip>  <name>.zip` in `sha256sum` form, one
//! line per zip, sorted by file name. A deploy downloads the directory, checks the zips against
//! `sums`, and compares each function's CodeSha256 with its line, so every stage runs the same bytes.
//!
//! A name is a function name as the stack takes it: lower-case words joined by `-`. No pairs, an
//! argument without `=`, a name that is not one, a name given twice, an unreadable zip and an
//! `<out_dir>` that exists are each refused with a message naming the problem, exit 1.

const std = @import("std");

pub const Pair = struct { name: []const u8, path: []const u8 };
pub const Zip = struct { name: []const u8, data: []const u8 };

pub const Refused = error{Refused};

/// Splits `<name>=<zip>` at the first `=`; null when there is none.
pub fn parsePair(arg: []const u8) ?Pair {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    return .{ .name = arg[0..eq], .path = arg[eq + 1 ..] };
}

/// True for `^[a-z][a-z0-9]*(-[a-z0-9]+)*$`.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name[0] < 'a' or name[0] > 'z') return false;
    var prev_dash = false;
    for (name, 0..) |c, i| {
        const word = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
        if (word) {
            prev_dash = false;
        } else if (c == '-' and i + 1 < name.len and !prev_dash) {
            prev_dash = true;
        } else {
            return false;
        }
    }
    return true;
}

/// The pairs of the command line, in order. On a refusal `msg` holds the reason (owned by `a`).
pub fn parseArgs(a: std.mem.Allocator, args: []const []const u8, msg: *[]const u8) (Refused || error{OutOfMemory})![]Pair {
    if (args.len == 0) {
        msg.* = "zip_bundle: no <name>=<zip> given";
        return error.Refused;
    }
    var pairs = std.ArrayList(Pair).init(a);
    errdefer pairs.deinit();
    for (args) |arg| {
        const p = parsePair(arg) orelse {
            msg.* = try std.fmt.allocPrint(a, "zip_bundle: `{s}` is not <name>=<zip>", .{arg});
            return error.Refused;
        };
        if (!validName(p.name)) {
            msg.* = try std.fmt.allocPrint(a, "zip_bundle: `{s}` is not a function name (lower-case words joined by '-')", .{p.name});
            return error.Refused;
        }
        for (pairs.items) |before| if (std.mem.eql(u8, before.name, p.name)) {
            msg.* = try std.fmt.allocPrint(a, "zip_bundle: `{s}` is given twice", .{p.name});
            return error.Refused;
        };
        try pairs.append(p);
    }
    return pairs.toOwnedSlice();
}

/// Reads each pair's zip from `dir`. On a refusal `msg` holds the reason (owned by `a`).
pub fn readZips(a: std.mem.Allocator, dir: std.fs.Dir, pairs: []const Pair, msg: *[]const u8) (Refused || error{OutOfMemory})![]Zip {
    var zips = std.ArrayList(Zip).init(a);
    errdefer zips.deinit();
    for (pairs) |p| {
        const data = dir.readFileAlloc(a, p.path, 1 << 30) catch |err| {
            msg.* = try std.fmt.allocPrint(a, "zip_bundle: cannot read {s}: {s}", .{ p.path, @errorName(err) });
            return error.Refused;
        };
        try zips.append(.{ .name = p.name, .data = data });
    }
    return zips.toOwnedSlice();
}

fn fileLess(_: void, x: Zip, y: Zip) bool {
    // Compares `<name>.zip` of each, without building the strings.
    const n = @min(x.name.len, y.name.len);
    for (x.name[0..n], y.name[0..n]) |cx, cy| if (cx != cy) return cx < cy;
    const tail_x = if (x.name.len > n) x.name[n..] else ".zip";
    const tail_y = if (y.name.len > n) y.name[n..] else ".zip";
    return std.mem.order(u8, tail_x, tail_y) == .lt;
}

/// `sha256sum` lines of the zips, sorted by file name (`<name>.zip`).
pub fn sums(a: std.mem.Allocator, zips: []const Zip) ![]u8 {
    const sorted = try a.dupe(Zip, zips);
    defer a.free(sorted);
    std.mem.sort(Zip, sorted, {}, fileLess);
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    const w = out.writer();
    var h: [32]u8 = undefined;
    for (sorted) |z| {
        std.crypto.hash.sha2.Sha256.hash(z.data, &h, .{});
        try w.print("{s}  {s}.zip\n", .{ std.fmt.fmtSliceHexLower(&h), z.name });
    }
    return out.toOwnedSlice();
}

/// Writes `<name>.zip` for each zip and `sums` into `out`.
pub fn writeBundle(a: std.mem.Allocator, out: std.fs.Dir, zips: []const Zip) !void {
    for (zips) |z| {
        const file = try std.fmt.allocPrint(a, "{s}.zip", .{z.name});
        defer a.free(file);
        try out.writeFile(file, z.data);
    }
    const text = try sums(a, zips);
    defer a.free(text);
    try out.writeFile("sums", text);
}

/// Creates `path` under `parent` (with its own parents); `error.PathAlreadyExists` when it exists.
pub fn makeOut(parent: std.fs.Dir, path: []const u8) !std.fs.Dir {
    if (std.fs.path.dirname(path)) |d| try parent.makePath(d);
    try parent.makeDir(path);
    return parent.openDir(path, .{});
}

fn refuse(msg: []const u8) noreturn {
    std.debug.print("{s}\n", .{msg});
    std.process.exit(1);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 2) refuse("usage: zip_bundle <out_dir> <name>=<zip> ...");
    var msg: []const u8 = "";
    const pairs = parseArgs(a, args[2..], &msg) catch |err| switch (err) {
        error.Refused => refuse(msg),
        else => return err,
    };
    const cwd = std.fs.cwd();
    const zips = readZips(a, cwd, pairs, &msg) catch |err| switch (err) {
        error.Refused => refuse(msg),
        else => return err,
    };
    var out = makeOut(cwd, args[1]) catch |err| switch (err) {
        error.PathAlreadyExists => refuse(try std.fmt.allocPrint(a, "zip_bundle: {s} already exists", .{args[1]})),
        else => return err,
    };
    defer out.close();
    try writeBundle(a, out, zips);
}

fn expectRefused(args: []const []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    try std.testing.expectError(error.Refused, parseArgs(arena.allocator(), args, &msg));
    try std.testing.expectEqualStrings(want, msg);
}

test "no pairs is refused" {
    try expectRefused(&.{}, "zip_bundle: no <name>=<zip> given");
}

test "an argument without = is refused" {
    try expectRefused(&.{ "a=x.zip", "b.zip" }, "zip_bundle: `b.zip` is not <name>=<zip>");
}

test "a name that is not a function name is refused" {
    const bad = [_][]const u8{ "", "Web", "1a", "-a", "a-", "a--b", "a_b", "a.b", "a b", "a/b", "é" };
    for (bad) |name| {
        const arg = try std.fmt.allocPrint(std.testing.allocator, "{s}=x.zip", .{name});
        defer std.testing.allocator.free(arg);
        const want = try std.fmt.allocPrint(std.testing.allocator, "zip_bundle: `{s}` is not a function name (lower-case words joined by '-')", .{name});
        defer std.testing.allocator.free(want);
        try expectRefused(&.{arg}, want);
    }
}

test "a name given twice is refused" {
    try expectRefused(&.{ "a=x.zip", "b=y.zip", "a=z.zip" }, "zip_bundle: `a` is given twice");
}

test "names the stack accepts are taken, with the path after the first =" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    const pairs = try parseArgs(arena.allocator(), &.{ "web-login=a/b.zip", "a1-b2-c=x=y", "z=" }, &msg);
    try std.testing.expectEqual(@as(usize, 3), pairs.len);
    try std.testing.expectEqualStrings("web-login", pairs[0].name);
    try std.testing.expectEqualStrings("a/b.zip", pairs[0].path);
    try std.testing.expectEqualStrings("a1-b2-c", pairs[1].name);
    try std.testing.expectEqualStrings("x=y", pairs[1].path);
    try std.testing.expectEqualStrings("z", pairs[2].name);
    try std.testing.expectEqualStrings("", pairs[2].path);
}

test "an unreadable zip is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var msg: []const u8 = "";
    try std.testing.expectError(error.Refused, readZips(arena.allocator(), tmp.dir, &.{.{ .name = "a", .path = "missing.zip" }}, &msg));
    try std.testing.expectEqualStrings("zip_bundle: cannot read missing.zip: FileNotFound", msg);
}

test "sums are sha256sum lines sorted by file name" {
    const a = std.testing.allocator;
    const got = try sums(a, &.{
        .{ .name = "web-session", .data = "abc" },
        .{ .name = "web", .data = "" },
        .{ .name = "web-login", .data = "abc" },
    });
    defer a.free(got);
    const abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    // `web-login.zip` and `web-session.zip` sort before `web.zip`: '-' is below '.'.
    try std.testing.expectEqualStrings(abc ++ "  web-login.zip\n" ++ abc ++ "  web-session.zip\n" ++ empty ++ "  web.zip\n", got);
}

test "a bundle holds each zip byte for byte and its sums" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile("in1.zip", "abc");
    try tmp.dir.writeFile("in2.zip", "\x00\xff\x00");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var msg: []const u8 = "";
    const pairs = try parseArgs(arena.allocator(), &.{ "two=in2.zip", "one=in1.zip" }, &msg);
    const zips = try readZips(arena.allocator(), tmp.dir, pairs, &msg);
    var out = try makeOut(tmp.dir, "deep/out");
    defer out.close();
    try writeBundle(a, out, zips);
    const one = try out.readFileAlloc(a, "one.zip", 100);
    defer a.free(one);
    try std.testing.expectEqualStrings("abc", one);
    const two = try out.readFileAlloc(a, "two.zip", 100);
    defer a.free(two);
    try std.testing.expectEqualStrings("\x00\xff\x00", two);
    const got = try out.readFileAlloc(a, "sums", 1000);
    defer a.free(got);
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("\x00\xff\x00", &h, .{});
    const want = try std.fmt.allocPrint(a, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  one.zip\n{s}  two.zip\n", .{std.fmt.fmtSliceHexLower(&h)});
    defer a.free(want);
    try std.testing.expectEqualStrings(want, got);
}

test "an output directory that exists is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("out");
    try std.testing.expectError(error.PathAlreadyExists, makeOut(tmp.dir, "out"));
}
