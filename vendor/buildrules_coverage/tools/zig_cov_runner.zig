// Vendored, unmodified, from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/coverage/tools/zig_cov_runner.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! zig_cov_runner: the test runner of a coverage build (`zig test --test-runner`, zig 0.15, with -fllvm -ffuzz), and the source of the
//! branch numbers.
//!
//! It runs the tests as zig's own runner does when the binary is started by hand (every test, a fresh `std.testing.allocator` for each, a
//! leak or a logged error or a failure is a failed run, exit status 1), then, with `--cov-out=<file>`, writes what the build's
//! instrumentation recorded. `-ffuzz` makes LLVM count, in one byte per basic block, how often the block ran (the "inline 8-bit
//! counters" of sanitizer coverage) and list the address of each block; this runner resolves each address to a source position with
//! the debug information of its own executable and writes one row per block:
//!
//!   <file as the debug information names it> TAB <line> TAB <column> TAB <hits, 0..255> TAB <function>
//!
//! The first line is `# sancov v1 <blocks>`. A block whose address has no source position is written with the file `?`. The numbers
//! are blocks of the control-flow graph (the entry of every function, both arms of every branch, the join points), the nearest
//! thing to branch coverage the compiler gives; zig_cover.zig turns the rows into the package's report.
//!
//! The runner is a root module of its own, so its own functions carry `@disableInstrumentation()`: they must not count.
//!
//! It also defines the callbacks instrumented code calls for a comparison, a switch and an indirect call, as functions that do nothing. Zig's
//! own definitions belong to its fuzzer (lib/fuzzer.zig): they record every compared value in a table that is not safe to touch from two
//! threads, and a test that starts a thread crashed in it. Nothing here fuzzes, so the table is not needed, and with these definitions the
//! fuzzer is not linked at all.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

pub const std_options: std.Options = .{ .logFn = log };

var log_err_count: usize = 0;

export threadlocal var __sancov_lowest_stack: usize = 0;

export fn __sanitizer_cov_trace_const_cmp1(a: u8, b: u8) void {
    @disableInstrumentation();
    _ = .{ a, b };
}
export fn __sanitizer_cov_trace_cmp1(a: u8, b: u8) void {
    @disableInstrumentation();
    _ = .{ a, b };
}
export fn __sanitizer_cov_trace_const_cmp2(a: u16, b: u16) void {
    @disableInstrumentation();
    _ = .{ a, b };
}
export fn __sanitizer_cov_trace_cmp2(a: u16, b: u16) void {
    @disableInstrumentation();
    _ = .{ a, b };
}
export fn __sanitizer_cov_trace_const_cmp4(a: u32, b: u32) void {
    @disableInstrumentation();
    _ = .{ a, b };
}
export fn __sanitizer_cov_trace_cmp4(a: u32, b: u32) void {
    @disableInstrumentation();
    _ = .{ a, b };
}
export fn __sanitizer_cov_trace_const_cmp8(a: u64, b: u64) void {
    @disableInstrumentation();
    _ = .{ a, b };
}
export fn __sanitizer_cov_trace_cmp8(a: u64, b: u64) void {
    @disableInstrumentation();
    _ = .{ a, b };
}
export fn __sanitizer_cov_trace_switch(value: u64, cases: [*]u64) void {
    @disableInstrumentation();
    _ = .{ value, cases };
}
export fn __sanitizer_cov_trace_pc_indir(callee: usize) void {
    @disableInstrumentation();
    _ = callee;
}
export fn __sanitizer_cov_8bit_counters_init(start: usize, end: usize) void {
    @disableInstrumentation();
    _ = .{ start, end };
}
export fn __sanitizer_cov_pcs_init(start: usize, end: usize) void {
    @disableInstrumentation();
    _ = .{ start, end };
}

pub fn main() void {
    @disableInstrumentation();
    var out_path: ?[]const u8 = null;
    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |a| {
        if (std.mem.startsWith(u8, a, "--cov-out=")) {
            out_path = a["--cov-out=".len..];
        } else {
            std.debug.print("zig_cov_runner: unknown argument {s}\n", .{a});
            std.process.exit(2);
        }
    }

    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaks: usize = 0;
    for (builtin.test_functions, 0..) |test_fn, i| {
        testing.allocator_instance = .{};
        testing.log_level = .warn;
        std.debug.print("{d}/{d} {s}...", .{ i + 1, builtin.test_functions.len, test_fn.name });
        if (test_fn.func()) |_| {
            passed += 1;
            std.debug.print("OK\n", .{});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skipped += 1;
                std.debug.print("SKIP\n", .{});
            },
            else => {
                failed += 1;
                std.debug.print("FAIL ({s})\n", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
            },
        }
        if (testing.allocator_instance.deinit() == .leak) leaks += 1;
    }
    if (failed == 0 and skipped == 0) {
        std.debug.print("All {d} tests passed.\n", .{passed});
    } else {
        std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ passed, skipped, failed });
    }
    if (log_err_count != 0) std.debug.print("{d} errors were logged.\n", .{log_err_count});
    if (leaks != 0) std.debug.print("{d} tests leaked memory.\n", .{leaks});
    // The report is written even when a test failed: the caller decides what a failed run is worth (it refuses it).
    if (out_path) |p| writeBlocks(p) catch |e| {
        std.debug.print("zig_cov_runner: cannot write {s}: {s}\n", .{ p, @errorName(e) });
        std.process.exit(1);
    };
    if (failed != 0 or leaks != 0 or log_err_count != 0) std.process.exit(1);
}

fn writeBlocks(path: []const u8) !void {
    @disableInstrumentation();
    const cs = @extern([*]u8, .{ .name = "__start___sancov_cntrs", .linkage = .weak }) orelse return error.NotBuiltWithFuzz;
    const ce = @extern([*]u8, .{ .name = "__stop___sancov_cntrs", .linkage = .weak }) orelse return error.NotBuiltWithFuzz;
    const ps = @extern([*]usize, .{ .name = "__start___sancov_pcs1", .linkage = .weak }) orelse return error.NotBuiltWithFuzz;
    const pe = @extern([*]usize, .{ .name = "__stop___sancov_pcs1", .linkage = .weak }) orelse return error.NotBuiltWithFuzz;
    const counters = cs[0 .. ce - cs];
    const pcs = ps[0 .. pe - ps];
    if (counters.len != pcs.len) return error.CountersAndAddressesDiffer;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();
    var rows = std.ArrayList(u8).empty;
    try rows.print(gpa, "# sancov v1 {d}\n", .{counters.len});
    const info = try std.debug.getSelfDebugInfo();
    for (counters, pcs) |hits, pc| {
        const located = locate(gpa, info, pc);
        if (located) |l| {
            try rows.print(gpa, "{s}\t{d}\t{d}\t{d}\t{s}\n", .{ l.file, l.line, l.column, hits, l.function });
        } else {
            try rows.print(gpa, "?\t0\t0\t{d}\t?\n", .{hits});
        }
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = rows.items });
}

const Located = struct { file: []const u8, line: u64, column: u64, function: []const u8 };

fn locate(gpa: std.mem.Allocator, info: *std.debug.SelfInfo, pc: usize) ?Located {
    @disableInstrumentation();
    const module = info.getModuleForAddress(pc) catch return null;
    const symbol = module.getSymbolAtAddress(gpa, pc) catch return null;
    const where = symbol.source_location orelse return null;
    return .{ .file = where.file_name, .line = where.line, .column = where.column, .function = symbol.name };
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) log_err_count +|= 1;
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n", args);
    }
}
