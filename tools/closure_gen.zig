//! mopm-closure: make the Mojo toolchain closure files from a pixi lock, and the native catalog files.
//!
//!   mopm-closure <mojo-<version>.pixi.lock> <output directory>
//!   mopm-closure --natives <natives.pixi.lock> <natives.txt> <closure directory>
//!
//!   mopm-closure --natives-libs <closure directory> <natives.libs>
//!
//! The third form brings toolchain/natives.libs up to date with the natives-<subdir>.json files of the directory
//! (src/core/natives_libs.zig): a package whose sha256 the file already holds is not read again; any other is
//! downloaded from its catalog url, checked against its pinned size and sha256 (a mismatch is exit 1, naming both)
//! and its shared libraries are listed. Run it after the second form. It downloads into `.natives-libs-part`
//! of the working directory and removes that when it is done.
//!
//! The second form writes natives-<subdir>.json into the closure directory (src/core/native_catalog.zig
//! says what they are), from the roots listed in natives.txt and the lock that solved them, and checks the
//! libgcc and libstdcxx floors against every mojo-<version>-<subdir>.json already in that directory. It
//! has the same exit codes.
//!
//! Writes mojo-<version>-<subdir>.json for each platform (src/core/closure.zig
//! says what the files are and why they exist). Used by the `toolchain` job of
//! .github/workflows/kpin-update.yml, which makes the lock with a solver on
//! GitHub, and by anyone who changes a lock by hand. It runs no solver itself.
//! Exit 3 (an alarm, nothing written): a file the output directory already pins
//! is now pinned with other bytes, which means the channel republished it.

const std = @import("std");
const core = @import("mopm_core");
const closure = core.closure;
const native_catalog = core.native_catalog;
const natives_libs = core.natives_libs;
const pkg_fetch = core.pkg_fetch;
const conda_unpack = core.conda_unpack;

pub fn main() !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    const stderr = std.io.getStdErr().writer();
    if (args.len == 5 and std.mem.eql(u8, args[1], "--natives")) return natives(a, args[2], args[3], args[4]);
    if (args.len == 4 and std.mem.eql(u8, args[1], "--natives-libs")) return nativesLibs(a, args[2], args[3]);
    if (args.len != 3) {
        try stderr.writeAll("usage: mopm-closure <mojo-<version>.pixi.lock> <output directory>\n       mopm-closure --natives <natives.pixi.lock> <natives.txt> <closure directory>\n       mopm-closure --natives-libs <closure directory> <natives.libs>\n");
        return 2;
    }
    const lock_text = std.fs.cwd().readFileAlloc(a, args[1], 64 << 20) catch |e| {
        try stderr.print("mopm-closure: {s}: {s}\n", .{ args[1], @errorName(e) });
        return 1;
    };
    var out_dir = std.fs.cwd().openDir(args[2], .{}) catch |e| {
        try stderr.print("mopm-closure: {s}: {s}\n", .{ args[2], @errorName(e) });
        return 1;
    };
    defer out_dir.close();
    const stdout = std.io.getStdOut().writer();
    for (closure.subdirs) |subdir| {
        var why: []const u8 = "";
        const made = closure.fromPixiLock(a, lock_text, subdir, &why) catch |e| switch (e) {
            error.BadLock => {
                try stderr.print("mopm-closure: {s}: {s}: {s}\n", .{ args[1], subdir, why });
                return 1;
            },
            error.OutOfMemory => return e,
        };
        const name = try std.fmt.allocPrint(a, "mojo-{s}-{s}.json", .{ made.mojo, subdir });
        // A file already pinned that now has other bytes is an alarm: nothing is written.
        if (out_dir.readFileAlloc(a, name, 16 << 20)) |old_text| {
            const old = try closure.parse(a, old_text);
            const found = try closure.alarms(a, old, made);
            if (found.len > 0) {
                for (found) |line| try stderr.print("mopm-closure: ALARM {s}: {s}\n", .{ name, line });
                return 3;
            }
        } else |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        }
        try out_dir.writeFile(name, try closure.render(a, made));
        try stdout.print("{s}: {d} packages\n", .{ name, made.packages.len });
    }
    return 0;
}

/// The conda names of natives.txt: one per line, `#` comments and blank lines skipped.
fn rootsOf(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try out.append(line);
    }
    return out.items;
}

fn natives(a: std.mem.Allocator, lock_path: []const u8, roots_path: []const u8, dir_path: []const u8) !u8 {
    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();
    const lock_text = std.fs.cwd().readFileAlloc(a, lock_path, 64 << 20) catch |e| {
        try stderr.print("mopm-closure: {s}: {s}\n", .{ lock_path, @errorName(e) });
        return 1;
    };
    const roots_text = std.fs.cwd().readFileAlloc(a, roots_path, 1 << 20) catch |e| {
        try stderr.print("mopm-closure: {s}: {s}\n", .{ roots_path, @errorName(e) });
        return 1;
    };
    const roots = try rootsOf(a, roots_text);
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |e| {
        try stderr.print("mopm-closure: {s}: {s}\n", .{ dir_path, @errorName(e) });
        return 1;
    };
    defer dir.close();
    for (closure.subdirs) |subdir| {
        // The Mojo closures of this platform: mojo-<version>-<subdir>.json.
        var toolchains = std.ArrayList(closure.Closure).init(a);
        const suffix = try std.fmt.allocPrint(a, "-{s}.json", .{subdir});
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "mojo-") or !std.mem.endsWith(u8, entry.name, suffix)) continue;
            const text = try dir.readFileAlloc(a, entry.name, 16 << 20);
            try toolchains.append(try closure.parse(a, text));
        }
        var why: []const u8 = "";
        const made = native_catalog.fromPixiLock(a, lock_text, subdir, roots, toolchains.items, &why) catch |e| switch (e) {
            error.BadLock => {
                try stderr.print("mopm-closure: {s}: {s}: {s}\n", .{ lock_path, subdir, why });
                return 1;
            },
            error.OutOfMemory => return e,
        };
        const name = try std.fmt.allocPrint(a, "natives-{s}.json", .{subdir});
        if (dir.readFileAlloc(a, name, 16 << 20)) |old_text| {
            const old = try native_catalog.parse(a, old_text);
            const found = try closure.alarmsOfPackages(a, old.packages, made.packages);
            if (found.len > 0) {
                for (found) |line| try stderr.print("mopm-closure: ALARM {s}: {s}\n", .{ name, line });
                return 3;
            }
        } else |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        }
        try dir.writeFile(name, try native_catalog.render(a, made));
        try stdout.print("{s}: {d} packages\n", .{ name, made.packages.len });
    }
    return 0;
}

/// Gives `regenerate` the bytes of a package: downloaded from the catalog's url, checked against the pinned size and sha256.
const Downloads = struct {
    dir: std.fs.Dir,
    catalogs: []const native_catalog.Catalog,
    diag: *pkg_fetch.Diag,

    pub fn bytesOf(self: *Downloads, arena: std.mem.Allocator, subdir: []const u8, p: closure.Package) ![]const u8 {
        for (self.catalogs) |c| {
            if (!std.mem.eql(u8, c.subdir, subdir)) continue;
            const url = try native_catalog.urlOf(arena, c, p);
            const name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ subdir, std.fs.path.basename(p.path) });
            try pkg_fetch.fetch(arena, self.dir, name, url, .{ .sha256 = p.sha256, .size = p.size }, self.diag);
            return self.dir.readFileAlloc(arena, name, 1 << 30);
        }
        return error.FileNotFound;
    }
};

fn nativesLibs(a: std.mem.Allocator, dir_path: []const u8, libs_path: []const u8) !u8 {
    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();
    var dir = std.fs.cwd().openDir(dir_path, .{}) catch |e| {
        try stderr.print("mopm-closure: {s}: {s}\n", .{ dir_path, @errorName(e) });
        return 1;
    };
    defer dir.close();
    var catalogs = std.ArrayList(native_catalog.Catalog).init(a);
    for (closure.subdirs) |subdir| {
        const name = try std.fmt.allocPrint(a, "natives-{s}.json", .{subdir});
        const text = dir.readFileAlloc(a, name, 16 << 20) catch |e| {
            try stderr.print("mopm-closure: {s}/{s}: {s}\n", .{ dir_path, name, @errorName(e) });
            return 1;
        };
        try catalogs.append(try native_catalog.parse(a, text));
    }
    const old_text = std.fs.cwd().readFileAlloc(a, libs_path, 4 << 20) catch |e| switch (e) {
        error.FileNotFound => "",
        else => {
            try stderr.print("mopm-closure: {s}: {s}\n", .{ libs_path, @errorName(e) });
            return 1;
        },
    };
    var part = try std.fs.cwd().makeOpenPath(".natives-libs-part", .{});
    defer {
        part.close();
        std.fs.cwd().deleteTree(".natives-libs-part") catch {};
    }
    var fetch_diag = pkg_fetch.Diag{};
    var downloads = Downloads{ .dir = part, .catalogs = catalogs.items, .diag = &fetch_diag };
    var diag = natives_libs.Diag{};
    const window = try a.alloc(u8, conda_unpack.window_size);
    const text = natives_libs.regenerate(a, old_text, catalogs.items, window, &downloads, &diag) catch |e| {
        const why = if (diag.message.len > 0) diag.message else fetch_diag.message;
        try stderr.print("mopm-closure: {s}: {s}: {s}\n", .{ libs_path, @errorName(e), why });
        return 1;
    };
    try std.fs.cwd().writeFile(libs_path, text);
    try stdout.print("{s}: {d} bytes\n", .{ libs_path, text.len });
    return 0;
}
