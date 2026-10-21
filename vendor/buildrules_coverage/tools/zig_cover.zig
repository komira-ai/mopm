// Vendored, unmodified, from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/coverage/tools/zig_cover.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! zig_cover: the coverage of one Zig test target, in one action: build its test executable with instrumentation, run it under kcov,
//! and write two reports in repository paths.
//!
//!   zig_cover --zig <dir> --runner <zig_cov_runner.zig> --target <triple> --root <zig root: a file or @argfile>
//!             --kcov <dir> --normalize <exe> --out-lines <cobertura.xml> --out-blocks <file>
//!             --must-contain <repository path> --include <repository path>... [--no-blocks]
//!
//! `--no-blocks` is for a test built by zig 0.12, which has no `-ffuzz` (and not `-fllvm`, which is its only code generator for x86_64):
//! the executable is built plainly, run under kcov with zig's own test runner, and only the line report is written (`--runner` and `--out-blocks`
//! are then not taken).
//!
//! Lines are kcov's: the executable is built `-fllvm` (the self-hosted backend writes line tables kcov finds no lines in) and run under
//! kcov, whose Cobertura report cov_normalize maps to repository paths. Blocks are the compiler's: `-ffuzz` has LLVM count the runs of
//! every basic block, and zig_cov_runner.zig (the test runner of this build) resolves each block's address to a source position and writes
//! them. kcov records no branch for a Zig executable (its report has no `branch` attribute: the line table has no branch information), so the
//! blocks are the branch figure; see README.md.
//!
//! Both come from one executable run once, in the directory it was built in: its debug information names the sources by absolute path,
//! which the run must find again. The test's environment is the caller's (zig_launch run): the executable sees what `zig test` would give it.
//!
//! The blocks file is `# blocks v2`, then one row per distinct source position of an included file, sorted:
//! `<file> TAB <line> TAB <column> TAB <blocks there that ran> TAB <blocks there>`. A position holds several blocks when it is the position of a
//! branch (the debug information gives both arms of a condition the lines around it, so two arms can share one) or of a generic function's
//! instantiations, and each counts. Rows of the test functions themselves are left out: the `try` error exits of a test's assertions never run in
//! a passing test and are not the code under test.
//!
//! Exit status: the test's when it fails (kcov passes it on); 1 when zig, kcov or cov_normalize fail, kcov wrote no report, or no block of an
//! included file was recorded; 2 for a usage error.

const std = @import("std");
const C = @import("cov_run.zig");

pub const Args = struct {
    zig: []const u8 = "",
    runner: []const u8 = "",
    target: []const u8 = "",
    root: []const u8 = "",
    kcov: []const u8 = "",
    normalize: []const u8 = "",
    out_lines: []const u8 = "",
    out_blocks: []const u8 = "",
    must_contain: []const u8 = "",
    includes: []const []const u8 = &.{},
    /// Build with block counters and write the block report; false for `--no-blocks`.
    blocks: bool = true,
};

pub const UsageError = error{Usage};

pub fn parse(a: std.mem.Allocator, argv: []const []const u8, diag: *[]const u8) (UsageError || std.mem.Allocator.Error)!Args {
    var r = Args{};
    var includes = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < argv.len) {
        const flag = argv[i];
        if (std.mem.eql(u8, flag, "--no-blocks")) {
            r.blocks = false;
            i += 1;
            continue;
        }
        i += 2;
        if (i - 1 >= argv.len) {
            diag.* = try std.fmt.allocPrint(a, "{s} needs a value", .{flag});
            return error.Usage;
        }
        const v = argv[i - 1];
        if (std.mem.eql(u8, flag, "--zig")) {
            r.zig = v;
        } else if (std.mem.eql(u8, flag, "--runner")) {
            r.runner = v;
        } else if (std.mem.eql(u8, flag, "--target")) {
            r.target = v;
        } else if (std.mem.eql(u8, flag, "--root")) {
            r.root = v;
        } else if (std.mem.eql(u8, flag, "--kcov")) {
            r.kcov = v;
        } else if (std.mem.eql(u8, flag, "--normalize")) {
            r.normalize = v;
        } else if (std.mem.eql(u8, flag, "--out-lines")) {
            r.out_lines = v;
        } else if (std.mem.eql(u8, flag, "--out-blocks")) {
            r.out_blocks = v;
        } else if (std.mem.eql(u8, flag, "--must-contain")) {
            r.must_contain = v;
        } else if (std.mem.eql(u8, flag, "--include")) {
            // A repository path: kcov's option splits on a comma and a colon, and a path with `..` or a leading slash names no file of the tree.
            if (v.len == 0 or v[0] == '/' or std.mem.indexOfAny(u8, v, ",: ") != null or std.mem.indexOf(u8, v, "..") != null) {
                diag.* = try std.fmt.allocPrint(a, "--include {s} must be a clean relative path without a space, , or :", .{v});
                return error.Usage;
            }
            try includes.append(a, v);
        } else {
            diag.* = try std.fmt.allocPrint(a, "unknown option {s}", .{flag});
            return error.Usage;
        }
    }
    const required = [_]struct { flag: []const u8, value: []const u8, only_blocks: bool }{
        .{ .flag = "--zig", .value = r.zig, .only_blocks = false },
        .{ .flag = "--runner", .value = r.runner, .only_blocks = true },
        .{ .flag = "--target", .value = r.target, .only_blocks = false },
        .{ .flag = "--root", .value = r.root, .only_blocks = false },
        .{ .flag = "--kcov", .value = r.kcov, .only_blocks = false },
        .{ .flag = "--normalize", .value = r.normalize, .only_blocks = false },
        .{ .flag = "--out-lines", .value = r.out_lines, .only_blocks = false },
        .{ .flag = "--out-blocks", .value = r.out_blocks, .only_blocks = true },
        .{ .flag = "--must-contain", .value = r.must_contain, .only_blocks = false },
    };
    for (required) |q| {
        if (q.value.len == 0 and (r.blocks or !q.only_blocks)) {
            diag.* = try std.fmt.allocPrint(a, "{s} is required", .{q.flag});
            return error.Usage;
        }
    }
    if (!r.blocks and (r.runner.len != 0 or r.out_blocks.len != 0)) {
        diag.* = "--no-blocks takes neither --runner nor --out-blocks";
        return error.Usage;
    }
    if (includes.items.len == 0) {
        diag.* = "at least one --include is required: nothing else is measured";
        return error.Usage;
    }
    r.includes = try includes.toOwnedSlice(a);
    return r;
}

/// The command that builds the instrumented test executable at `bin`: LLVM's code generator (zig's own writes line tables kcov finds no
/// line in), the block counters of `-ffuzz`, this build's test runner, and no run. Without blocks, the plain build.
pub fn zigArgv(a: std.mem.Allocator, r: Args, bin: []const u8) ![]const []const u8 {
    const zig = try std.fs.path.join(a, &.{ r.zig, "zig" });
    const emit = try std.fmt.allocPrint(a, "-femit-bin={s}", .{bin});
    if (!r.blocks) return a.dupe([]const u8, &.{ zig, "test", "--test-no-exec", "-target", r.target, emit, r.root });
    return a.dupe([]const u8, &.{ zig, "test", "-fllvm", "-ffuzz", "--test-runner", r.runner, "--test-no-exec", "-target", r.target, emit, r.root });
}

/// What kcov is told to measure: the directories of the included files, once each (a file with no directory stays itself). kcov refuses an
/// option longer than a fixed length ("Too long string!"), and a package of thirty files under a runner's long working directory is longer; the report is
/// the same, since kcov lists only files the executable holds code of, and what is not counted is left out by cov_summary.
pub fn includeDirs(a: std.mem.Allocator, includes: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (includes) |inc| {
        const entry = std.fs.path.dirname(inc) orelse inc;
        var seen = false;
        for (out.items) |o| seen = seen or std.mem.eql(u8, o, entry);
        if (!seen) try out.append(a, entry);
    }
    return out.toOwnedSlice(a);
}

/// cov_normalize's command line: the report `raw`, the tree rooted at `cwd` mapped to repository paths.
pub fn normalizeArgv(a: std.mem.Allocator, r: Args, raw: []const u8, out: []const u8, cwd: []const u8) ![]const []const u8 {
    return a.dupe([]const u8, &.{
        r.normalize,
        "--in",
        raw,
        "--out",
        out,
        "--map",
        try std.fmt.allocPrint(a, "{s}/=", .{cwd}),
        "--must-contain",
        r.must_contain,
        "--forbid",
        cwd,
    });
}

/// The blocks at one source position of one file: how many there are and how many ran. A position can hold several (the two arms of a branch, or one
/// block per instantiation of a generic function): they are counted, not merged, or an arm that never ran would hide behind the arm that did.
pub const Block = struct { file: []const u8, line: u32, column: u32, hit: u32, total: u32 };

pub const BlocksError = error{ BadRow, NoBlocks, OutOfMemory };

/// True for the function a `test "..."` block compiles to: its name is `<file stem>.test.<name>` (or `<file stem>.test_<n>` for a test
/// without a name).
pub fn isTestFunction(file: []const u8, function: []const u8) bool {
    const base = std.fs.path.basename(file);
    const stem = if (std.mem.endsWith(u8, base, ".zig")) base[0 .. base.len - 4] else base;
    if (!std.mem.startsWith(u8, function, stem)) return false;
    const rest = function[stem.len..];
    if (std.mem.startsWith(u8, rest, ".test.")) return true;
    if (std.mem.startsWith(u8, rest, ".test_")) {
        const digits = rest[".test_".len..];
        if (digits.len == 0) return false;
        for (digits) |c| if (c < '0' or c > '9') return false;
        return true;
    }
    return false;
}

fn lessBlock(_: void, x: Block, y: Block) bool {
    const f = std.mem.order(u8, x.file, y.file);
    if (f != .eq) return f == .lt;
    if (x.line != y.line) return x.line < y.line;
    return x.column < y.column;
}

/// The blocks of `raw` (the runner's rows) that lie in the included files of the tree rooted at `cwd`, outside the test functions, counted
/// per source position, sorted. A row that is not five tab-separated fields is refused; so is a run that
/// recorded no block of an included file, since a build whose instrumentation did nothing must not read as 0 of 0.
pub fn blocks(a: std.mem.Allocator, raw: []const u8, cwd: []const u8, includes: []const []const u8) BlocksError![]Block {
    var list = std.ArrayList(Block).empty;
    var index = std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(u64, usize)).empty;
    var rows = std.mem.splitScalar(u8, raw, '\n');
    var first = true;
    while (rows.next()) |row| {
        if (row.len == 0) continue;
        if (first) {
            first = false;
            if (std.mem.startsWith(u8, row, "# sancov v1 ")) continue;
            return error.BadRow;
        }
        var f = std.mem.splitScalar(u8, row, '\t');
        const file = f.next() orelse return error.BadRow;
        const line_s = f.next() orelse return error.BadRow;
        const col_s = f.next() orelse return error.BadRow;
        const hits_s = f.next() orelse return error.BadRow;
        const function = f.next() orelse return error.BadRow;
        if (f.next() != null) return error.BadRow;
        const line = std.fmt.parseInt(u32, line_s, 10) catch return error.BadRow;
        const column = std.fmt.parseInt(u32, col_s, 10) catch return error.BadRow;
        const hits = std.fmt.parseInt(u8, hits_s, 10) catch return error.BadRow;
        if (std.mem.eql(u8, file, "?")) continue;
        if (!std.mem.startsWith(u8, file, cwd) or file.len <= cwd.len or file[cwd.len] != '/') continue;
        const rel = file[cwd.len + 1 ..];
        var wanted = false;
        for (includes) |inc| wanted = wanted or std.mem.eql(u8, inc, rel);
        if (!wanted) continue;
        if (isTestFunction(rel, function)) continue;
        const key: u64 = (@as(u64, line) << 32) | column;
        const gop = try index.getOrPut(a, rel);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const pos = try gop.value_ptr.getOrPut(a, key);
        if (pos.found_existing) {
            const b = &list.items[pos.value_ptr.*];
            b.total += 1;
            if (hits > 0) b.hit += 1;
        } else {
            pos.value_ptr.* = list.items.len;
            try list.append(a, .{ .file = rel, .line = line, .column = column, .hit = @intFromBool(hits > 0), .total = 1 });
        }
    }
    if (list.items.len == 0) return error.NoBlocks;
    std.mem.sort(Block, list.items, {}, lessBlock);
    return list.toOwnedSlice(a);
}

/// The text of the blocks file.
pub fn render(a: std.mem.Allocator, bs: []const Block) ![]u8 {
    var o = std.ArrayList(u8).empty;
    try o.appendSlice(a, "# blocks v2\n");
    for (bs) |b| try o.print(a, "{s}\t{d}\t{d}\t{d}\t{d}\n", .{ b.file, b.line, b.column, b.hit, b.total });
    return o.toOwnedSlice(a);
}

fn die(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zig_cover: " ++ fmt ++ "\n", args);
    std.process.exit(code);
}

fn run(a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !u8 {
    var child = std.process.Child.init(argv, a);
    child.cwd = cwd;
    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| @intCast(128 + (s & 0x7f)),
        else => 255,
    };
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    var diag: []const u8 = "";
    const r = parse(a, argv[1..], &diag) catch |e| switch (e) {
        error.Usage => die(2, "{s}", .{diag}),
        else => return e,
    };
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    const abs = struct {
        fn of(al: std.mem.Allocator, base: []const u8, p: []const u8) ![]u8 {
            return if (std.fs.path.isAbsolute(p)) al.dupe(u8, p) else std.fs.path.join(al, &.{ base, p });
        }
    }.of;
    var rr = r;
    rr.zig = try abs(a, cwd, r.zig);
    rr.runner = try abs(a, cwd, r.runner);
    rr.kcov = try abs(a, cwd, r.kcov);
    rr.normalize = try abs(a, cwd, r.normalize);

    const work = try std.fmt.allocPrint(a, "{s}.work", .{r.out_lines});
    std.fs.cwd().makePath(work) catch |e| die(1, "cannot create {s}: {s}", .{ work, @errorName(e) });
    const work_abs = try std.fs.cwd().realpathAlloc(a, work);

    // 1. The instrumented test executable.
    const bin = try std.fs.path.join(a, &.{ work_abs, "test" });
    const zcode = run(a, try zigArgv(a, rr, bin), null) catch |e| die(1, "cannot run zig: {s}", .{@errorName(e)});
    if (zcode != 0) die(zcode, "zig failed to build the test executable (exit {d})", .{zcode});

    // 2. kcov runs it; the runner writes its blocks beside kcov's report.
    const raw_blocks = try std.fs.path.join(a, &.{ work_abs, "blocks.raw" });
    var kc = C.Args{
        .kcov = rr.kcov,
        .binary = bin,
        .includes = try includeDirs(a, r.includes),
        .binary_args = if (r.blocks) &.{try std.fmt.allocPrint(a, "--cov-out={s}", .{raw_blocks})} else &.{},
    };
    kc.share = cwd;
    const kcov_out = try std.fs.path.join(a, &.{ work_abs, "kcov" });
    const kcode = run(a, try C.kcovArgv(a, kc, cwd, kcov_out), cwd) catch |e| die(1, "cannot run kcov: {s}", .{@errorName(e)});
    if (kcode != 0) die(kcode, "kcov (or the test under it) exited {d}", .{kcode});
    const raw_xml = try std.fs.path.join(a, &.{ kcov_out, "cov.xml" });
    std.fs.cwd().access(raw_xml, .{}) catch die(1, "kcov wrote no {s}", .{raw_xml});

    // 3. The line report, in repository paths.
    const out_lines = try abs(a, cwd, r.out_lines);
    const ncode = run(a, try normalizeArgv(a, rr, raw_xml, out_lines, cwd), null) catch |e| die(1, "cannot run cov_normalize: {s}", .{@errorName(e)});
    if (ncode != 0) die(1, "cov_normalize refused the report (exit {d})", .{ncode});

    // 4. The block report.
    if (!r.blocks) {
        std.fs.cwd().deleteTree(work) catch {};
        return;
    }
    const raw = std.fs.cwd().readFileAlloc(a, raw_blocks, 1 << 28) catch |e| die(1, "the runner wrote no block report {s}: {s}", .{ raw_blocks, @errorName(e) });
    const bs = blocks(a, raw, cwd, r.includes) catch |e| switch (e) {
        error.NoBlocks => die(1, "no block of an included file was recorded: the executable was not built with block counters, or its debug information does not name the sources under {s}", .{cwd}),
        error.BadRow => die(1, "{s} is not the runner's block report", .{raw_blocks}),
        error.OutOfMemory => return e,
    };
    const text = try render(a, bs);
    std.fs.cwd().writeFile(.{ .sub_path = r.out_blocks, .data = text }) catch |e| die(1, "cannot write {s}: {s}", .{ r.out_blocks, @errorName(e) });
    std.fs.cwd().deleteTree(work) catch {};
}
