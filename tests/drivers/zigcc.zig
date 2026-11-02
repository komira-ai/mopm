//! `cc` for the Mojo end-to-end drivers: runs komira's pinned zig as
//! `zig cc -target x86_64-linux-gnu.2.34 <args>`. The farm has no system C
//! compiler; `mojo build` links through `cc` on PATH, and the native test
//! libraries (tests/e2e/native/*.c) are compiled with it. The driver names
//! the zig binary in MOPM_ZIG (and its cache directories in ZIG_*, which
//! this program passes on unchanged).
//!
//! Zig's linker (0.12) is not GNU ld, so the arguments are adapted:
//!   * `-Xlinker --push-state` / `--pop-state` (mopm wraps the planned
//!     libraries in them on Linux) are dropped: zig 0.12 refuses them
//!     ("unsupported linker arg: --push-state"). Its linker (lld) does not
//!     drop an unreferenced library unless told `--as-needed`, which is the
//!     state `--no-as-needed` asks for, so the libraries stay named.
//!   * `-Wl,--enable-new-dtags` is always given: zig links with DT_RPATH, which
//!     the loader applies to a library's own needs too, so a binary would find
//!     libinner (a need of libouter) through the run path mopm adds even when
//!     nothing names it. GNU ld on a distribution toolchain writes DT_RUNPATH,
//!     which does not; the tests are about that behaviour.
//!   * `-Xlinker <value>` (a bare operand, no leading dash) becomes `<value>`, which is how an archive or a shared
//!     object named to the linker gets to zig: zig 0.12 refuses it as a linker argument ("unsupported linker arg")
//!     and takes it as an input file. buildrules' `cc` shim for `mojo_compile` (rules/mojo/tools/cc_shim.zig) makes
//!     the same rewrite, so this driver links what `mopm unit build --natives` names as it will on the real wrapper. The
//!     operand of a `-Xlinker -<opt>` pair stays with its option.
//!   * `-Xlinker -L<dir>` / `-Xlinker -l<lib>` become plain `-L<dir>` / `-l<lib>`,
//!     `-Xlinker --opt` becomes `-Wl,--opt`, and `-Xlinker -rpath -Xlinker <dir>`
//!     becomes `-Wl,-rpath,<dir>`. Run paths are kept: a test checks that the
//!     binary finds its libraries through the one mopm adds.

const std = @import("std");

fn dropped(s: []const u8) bool {
    return std.mem.eql(u8, s, "--push-state") or std.mem.eql(u8, s, "--pop-state");
}

pub fn main() !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const zig = std.process.getEnvVarOwned(a, "MOPM_ZIG") catch {
        std.debug.print("cc: MOPM_ZIG is not set (the driver names komira's zig there)\n", .{});
        return 2;
    };
    const args = try std.process.argsAlloc(a);
    var out = std.ArrayList([]const u8).init(a);
    try out.appendSlice(&.{ zig, "cc", "-target", "x86_64-linux-gnu.2.34", "-Wl,--enable-new-dtags" });
    var i: usize = 1;
    var expect_val = false;
    while (i < args.len) : (i += 1) {
        const s = args[i];
        if (std.mem.eql(u8, s, "-Xlinker") and i + 1 < args.len) {
            const b = args[i + 1];
            i += 1;
            if (expect_val) {
                expect_val = false;
                try out.appendSlice(&.{ s, b });
                continue;
            }
            if (dropped(b)) continue;
            if (std.mem.eql(u8, b, "-rpath") and i + 2 < args.len and std.mem.eql(u8, args[i + 1], "-Xlinker")) {
                try out.append(try std.fmt.allocPrint(a, "-Wl,-rpath,{s}", .{args[i + 2]}));
                i += 2;
            } else if (std.mem.startsWith(u8, b, "-L") or std.mem.startsWith(u8, b, "-l")) {
                try out.append(b);
            } else if (std.mem.startsWith(u8, b, "--")) {
                try out.append(try std.fmt.allocPrint(a, "-Wl,{s}", .{b}));
            } else if (b.len > 0 and b[0] == '-') {
                expect_val = true;
                try out.appendSlice(&.{ s, b });
            } else {
                try out.append(b);
            }
        } else if (std.mem.startsWith(u8, s, "-Wl,") and dropped(s[4..])) {
            continue;
        } else {
            try out.append(s);
        }
    }
    var child = std.process.Child.init(out.items, a);
    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |c| c,
        else => 1,
    };
}
