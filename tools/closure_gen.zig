//! mopm-closure: make the Mojo toolchain closure files from a pixi lock.
//!
//!   mopm-closure <mojo-<version>.pixi.lock> <output directory>
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

pub fn main() !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    const stderr = std.io.getStdErr().writer();
    if (args.len != 3) {
        try stderr.writeAll("usage: mopm-closure <mojo-<version>.pixi.lock> <output directory>\n");
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
