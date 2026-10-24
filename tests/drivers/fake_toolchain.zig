//! Stands in for the Mojo compiler in the unit tier of tests/drivers/group_e2e_test.zig, where the walk of the group end-to-end
//! check runs without the Mojo toolchain (the tests that need it run in the beta tier, //:group_e2e_mojo). It is installed as
//! `<prefix>/bin/mojo` and does what the walk relies on, with no compiler behind it:
//!
//!   mojo precompile [-I<dir>]... <package dir> -o <file>   writes a stand-in .mojoc that names the package
//!   mojo build <file> ... -o <file>                         writes an executable: a copy of this program
//!
//! Run under any other name (the executable `mojo build` wrote), it prints the line the README program of the group check
//! prints and exits 0. Any other use of `mojo` ends 2, so a walk that asks the compiler for something else is red.
//!
//! A test that needs a program which exits 0 and prints another line sets `FAKE_TOOLCHAIN_PROGRAM_OUTPUT` in the environment of its
//! own run: the program then prints that text instead.

const std = @import("std");

/// What the README program of the group check prints (tests/drivers/group_e2e.zig, readme_output).
const program_output = "zz_e2e total 3\n";

/// The variable that replaces `program_output` for one run.
const output_env = "FAKE_TOOLCHAIN_PROGRAM_OUTPUT";

/// The file named by the last `-o` among `args`, or null.
fn outputOf(args: []const []const u8) ?[]const u8 {
    var i = args.len;
    while (i > 1) {
        i -= 1;
        if (std.mem.eql(u8, args[i - 1], "-o")) return args[i];
    }
    return null;
}

pub fn main() !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    if (!std.mem.eql(u8, std.fs.path.basename(args[0]), "mojo")) {
        const line: []const u8 = std.process.getEnvVarOwned(a, output_env) catch @as([]const u8, program_output);
        try std.io.getStdOut().writer().writeAll(line);
        return 0;
    }
    if (args.len < 2) return 2;
    const target = outputOf(args) orelse return 2;
    const cwd = std.fs.cwd();
    if (std.mem.eql(u8, args[1], "precompile")) {
        // The package is the argument that is not a flag, not the value of one, and not the output.
        var package: []const u8 = "";
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-o")) {
                i += 1;
            } else if (!std.mem.startsWith(u8, args[i], "-")) {
                package = args[i];
            }
        }
        try cwd.writeFile(target, try std.fmt.allocPrint(a, "stand-in mojoc of {s}\n", .{package}));
        return 0;
    }
    if (std.mem.eql(u8, args[1], "build")) {
        try cwd.copyFile(try std.fs.selfExePathAlloc(a), cwd, target, .{});
        const f = try cwd.openFile(target, .{});
        defer f.close();
        try f.chmod(0o755);
        return 0;
    }
    return 2;
}
