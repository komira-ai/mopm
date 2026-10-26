//! The debugserver `mopm repl` hands lldb on macOS 14.
//!
//! `mojo repl` runs the program in lldb. On macOS 14 (Darwin 23) the debugserver packaged with the mojo 1.0.0
//! toolchain crashes at start (SIGSEGV in dyld4::FileRecord::getPath), and the REPL then prints "couldn't find a
//! REPL for mojo". Xcode's own debugserver works there, and lldb takes the one in `LLDB_DEBUGSERVER_PATH`; macOS 15
//! (Darwin 24) runs the packaged one. So on a Mac that is macOS 14 or older, `mopm repl` sets that variable for mojo
//! unless the caller has set it already (`--debugserver <path>` names one explicitly).
//!
//! The pure parts (which Darwin releases need it, where Xcode keeps the file, which of the places holds it) are
//! tested everywhere; `discover`, which asks the machine, is only ever called on macOS.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// The newest Darwin major release that needs Xcode's debugserver: 23 is macOS 14.
pub const last_darwin_needing = 23;

/// Whether the kernel release (`uname -r`, "23.6.0") is one that needs Xcode's debugserver. A string that is not a
/// release number needs nothing: mopm then leaves lldb alone.
pub fn needed(release: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, release, '.') orelse release.len;
    const major = std.fmt.parseInt(u32, release[0..dot], 10) catch return false;
    return major <= last_darwin_needing;
}

/// Where `developer_dir` (`xcode-select -p`: `.../Xcode.app/Contents/Developer`, or the Command Line Tools) may hold
/// the debugserver, best first.
pub fn candidates(arena: Allocator, developer_dir: []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, 2);
    out[0] = try std.fs.path.resolvePosix(arena, &.{ developer_dir, "../SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver" });
    out[1] = try std.fs.path.resolvePosix(arena, &.{ developer_dir, "Library/PrivateFrameworks/LLDB.framework/Versions/A/Resources/debugserver" });
    return out;
}

/// The first of `candidates(developer_dir)` that is a file, or null.
pub fn find(arena: Allocator, developer_dir: []const u8) Allocator.Error!?[]const u8 {
    for (try candidates(arena, developer_dir)) |path| {
        std.fs.cwd().access(path, .{}) catch continue;
        return path;
    }
    return null;
}

pub const Found = union(enum) {
    /// This machine runs the packaged debugserver (not macOS, or macOS 15 and newer).
    not_needed,
    /// The debugserver to hand lldb.
    path: []const u8,
    /// It is needed and there is none: what to tell the user.
    missing: []const u8,
};

/// Asks this machine. Anything but macOS needs nothing.
pub fn discover(arena: Allocator) Allocator.Error!Found {
    return if (builtin.os.tag == .macos) discoverMacos(arena) else .not_needed;
}

fn discoverMacos(arena: Allocator) Allocator.Error!Found {
    // `uname -r`: std.posix.uname needs libc, which mopm is not linked against.
    const rel = std.ChildProcess.run(.{ .allocator = arena, .argv = &.{ "/usr/bin/uname", "-r" } }) catch return .not_needed;
    if (!needed(std.mem.trim(u8, rel.stdout, " \t\r\n"))) return .not_needed;
    const dir = developerDir(arena) orelse
        return .{ .missing = "this is macOS 14 and 'xcode-select -p' names no developer directory: install Xcode or run 'xcode-select --install', or pass --debugserver <path>; mojo's own debugserver crashes here" };
    if (try find(arena, dir)) |path| return .{ .path = path };
    return .{ .missing = try std.fmt.allocPrint(arena, "this is macOS 14 and there is no debugserver under {s}: install Xcode and run 'xcode-select -s <Xcode.app>/Contents/Developer', or pass --debugserver <path>; mojo's own debugserver crashes here", .{dir}) };
}

/// `DEVELOPER_DIR`, else the output of `xcode-select -p`; null when neither gives a directory.
fn developerDir(arena: Allocator) ?[]const u8 {
    if (std.process.getEnvVarOwned(arena, "DEVELOPER_DIR")) |d| {
        if (d.len > 0) return d;
    } else |_| {}
    const r = std.ChildProcess.run(.{ .allocator = arena, .argv = &.{ "/usr/bin/xcode-select", "-p" } }) catch return null;
    switch (r.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }
    const dir = std.mem.trim(u8, r.stdout, " \t\r\n");
    return if (dir.len == 0) null else dir;
}

// ---------------------------------------------------------------- tests

test "needed: Darwin 23 (macOS 14) and older, not 24 (macOS 15) and newer, and not what is not a release" {
    try std.testing.expect(needed("23.6.0"));
    try std.testing.expect(needed("23.0.0"));
    try std.testing.expect(needed("22.6.0"));
    try std.testing.expect(needed("9"));
    try std.testing.expect(!needed("24.0.0"));
    try std.testing.expect(!needed("24"));
    try std.testing.expect(!needed("25.1.0"));
    try std.testing.expect(!needed(""));
    try std.testing.expect(!needed("sonoma"));
    try std.testing.expect(!needed(".5"));
}

test "candidates: Xcode's SharedFrameworks first, the Command Line Tools' PrivateFrameworks second" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const c = try candidates(a, "/Applications/Xcode_15.4.app/Contents/Developer");
    try std.testing.expectEqual(@as(usize, 2), c.len);
    try std.testing.expectEqualStrings("/Applications/Xcode_15.4.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver", c[0]);
    try std.testing.expectEqualStrings("/Applications/Xcode_15.4.app/Contents/Developer/Library/PrivateFrameworks/LLDB.framework/Versions/A/Resources/debugserver", c[1]);
}

fn touch(dir: std.fs.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    const f = try dir.createFile(path, .{});
    f.close();
}

test "find: the first place that holds the file wins; none gives null" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const dev = try std.fs.path.join(a, &.{ root, "Xcode.app/Contents/Developer" });
    try tmp.dir.makePath("Xcode.app/Contents/Developer");

    try std.testing.expect((try find(a, dev)) == null);

    // Only the Command Line Tools' place holds one.
    try touch(tmp.dir, "Xcode.app/Contents/Developer/Library/PrivateFrameworks/LLDB.framework/Versions/A/Resources/debugserver");
    const clt = (try find(a, dev)).?;
    try std.testing.expect(std.mem.endsWith(u8, clt, "Developer/Library/PrivateFrameworks/LLDB.framework/Versions/A/Resources/debugserver"));

    // Xcode's place also does: it wins.
    try touch(tmp.dir, "Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver");
    const xcode = (try find(a, dev)).?;
    try std.testing.expect(std.mem.endsWith(u8, xcode, "Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, xcode, 1, ".."));
}

test "discover: a machine that is not macOS needs nothing" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    switch (try discover(t.allocator())) {
        .not_needed => {},
        else => return error.TestUnexpectedResult,
    }
}
