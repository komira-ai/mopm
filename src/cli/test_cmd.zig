//! `mopm test --list`: discover the tests of a package and print them, one
//! `<file>::<test>` per line, files in bytewise path order and tests in
//! source line order. Running tests is not implemented yet.
//!
//!   mopm test --list [<path>...]
//!       Read the sources only (core/test_scan.zig). A <path> that is a
//!       directory is a package root, searched by the convention in
//!       core/test_harness.zig; a file is taken as a test file as given.
//!       Default: the current directory.
//!   mopm test --list --check [--strict-discovery] [--prefix <dir>] [<path>...]
//!       Also build every file that has tests (a bare file through its
//!       generated harness, target/mopm/gen/<hash>/<name>.mojo; a
//!       self-hosted file as it is) with `mopm build`, run each binary with
//!       `--skip-all`, and compare the names it lists with the scan. For a
//!       generated harness a difference is always an error. For a
//!       self-hosted file it is a warning, an error with --strict-discovery
//!       (the design's default until the scanner is checked on more code).
//!
//! Exit status: 0 listed; 1 running tests was asked for (not implemented
//! yet) or an I/O failure; 2 a usage error, a discovery error, a failed
//! build, or a listing that differs from the scan; 5 a `--skip-all` listing
//! mopm cannot read (the installed Mojo's TestSuite prints another shape).
//! Nothing is printed on stdout unless the whole list is good.

const std = @import("std");
const core = @import("mopm_core");
const test_scan = core.test_scan;
const test_harness = core.test_harness;

const usage =
    \\usage: mopm test --list [--check [--strict-discovery] [--prefix <dir>]] [<path>...]
    \\
;

const Opts = struct {
    list: bool = false,
    check: bool = false,
    strict: bool = false,
    prefix: ?[]const u8 = null,
    paths: std.ArrayList([]const u8),
};

const File = struct {
    /// As printed and as opened: relative to the root it was found under,
    /// joined to it unless the root is ".", or as given on the command line.
    display: []const u8,
};

fn lessFile(_: void, a: File, b: File) bool {
    return std.mem.lessThan(u8, a.display, b.display);
}

pub fn main(arena: std.mem.Allocator, args: []const []const u8) u8 {
    return run(arena, args) catch |e| {
        std.io.getStdErr().writer().print("mopm test: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };
}

fn run(arena: std.mem.Allocator, args: []const []const u8) !u8 {
    const err = std.io.getStdErr().writer();
    var o = Opts{ .paths = std.ArrayList([]const u8).init(arena) };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--list")) {
            o.list = true;
        } else if (std.mem.eql(u8, a, "--check")) {
            o.check = true;
        } else if (std.mem.eql(u8, a, "--strict-discovery")) {
            o.strict = true;
        } else if (std.mem.eql(u8, a, "--prefix") or std.mem.startsWith(u8, a, "--prefix=")) {
            if (a.len > "--prefix".len) {
                o.prefix = a["--prefix=".len..];
            } else {
                if (i + 1 >= args.len) return usageError("--prefix needs a directory");
                i += 1;
                o.prefix = args[i];
            }
            if (o.prefix.?.len == 0) return usageError("--prefix needs a directory");
        } else if (a.len > 1 and a[0] == '-') {
            try err.print("mopm test: unknown option '{s}'\n\n{s}", .{ a, usage });
            return 2;
        } else {
            try o.paths.append(a);
        }
    }
    if (!o.list) {
        try err.print("mopm test: running tests is not implemented yet; --list prints the tests\n\n{s}", .{usage});
        return 1;
    }
    if (!o.check and (o.strict or o.prefix != null)) return usageError("--strict-discovery and --prefix apply only with --check");
    if (o.paths.items.len == 0) try o.paths.append(".");

    // The files, deduplicated by their display path.
    var files = std.ArrayList(File).init(arena);
    for (o.paths.items) |p| {
        const st = std.fs.cwd().statFile(p) catch |e| {
            try err.print("mopm test: {s}: {s}\n", .{ p, @errorName(e) });
            return 2;
        };
        if (st.kind == .directory) {
            for (try test_harness.findTestFiles(arena, p)) |rel| {
                const shown = if (std.mem.eql(u8, p, ".")) rel else try std.fs.path.join(arena, &.{ p, rel });
                try files.append(.{ .display = shown });
            }
        } else {
            try files.append(.{ .display = p });
        }
    }
    std.sort.insertion(File, files.items, {}, lessFile);

    var failed = false;
    var out = std.ArrayList(u8).init(arena);
    var prev: ?[]const u8 = null;
    for (files.items) |f| {
        if (prev) |q| if (std.mem.eql(u8, q, f.display)) continue;
        prev = f.display;
        const src = std.fs.cwd().readFileAlloc(arena, f.display, 16 << 20) catch |e| {
            try err.print("mopm test: {s}: {s}\n", .{ f.display, @errorName(e) });
            failed = true;
            continue;
        };
        const sc = try test_scan.scan(arena, src);
        for (sc.warnings) |d| try err.print("mopm test: warning: {s}:{d}: {s}\n", .{ f.display, d.line, d.message });
        for (sc.errors) |d| try err.print("mopm test: {s}:{d}: {s}\n", .{ f.display, d.line, d.message });
        if (!sc.ok()) {
            failed = true;
            continue;
        }
        if (o.check and sc.tests.len > 0) {
            switch (try check(arena, o, f, src, sc)) {
                .same => {},
                .warned => {},
                .failed => failed = true,
                .protocol => return 5,
            }
        }
        for (sc.tests) |t| try out.writer().print("{s}::{s}\n", .{ f.display, t.name });
    }
    if (failed) return 2;
    try std.io.getStdOut().writeAll(out.items);
    return 0;
}

fn usageError(msg: []const u8) u8 {
    std.io.getStdErr().writer().print("mopm test: {s}\n\n{s}", .{ msg, usage }) catch {};
    return 2;
}

const Checked = enum { same, warned, failed, protocol };

/// Build the file (through its harness when bare), list it with
/// `--skip-all`, and compare with the scan.
fn check(arena: std.mem.Allocator, o: Opts, f: File, src: []const u8, sc: test_scan.Scan) !Checked {
    const err = std.io.getStdErr().writer();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(f.display, &digest, .{});
    const hash = try std.fmt.allocPrint(arena, "{s}", .{std.fmt.fmtSliceHexLower(digest[0..8])});
    const base = std.fs.path.basename(f.display);
    const stem = base[0 .. base.len - std.fs.path.extension(base).len];

    var program = f.display;
    if (sc.kind == .bare) {
        const dir = try std.fs.path.join(arena, &.{ "target", "mopm", "gen", hash });
        try std.fs.cwd().makePath(dir);
        program = try std.fs.path.join(arena, &.{ dir, base });
        try std.fs.cwd().writeFile(program, try test_harness.generate(arena, src, sc.tests));
    }
    const bin_dir = try std.fs.path.join(arena, &.{ "target", "mopm", "bin", hash });
    try std.fs.cwd().makePath(bin_dir);
    const bin = try std.fs.path.join(arena, &.{ bin_dir, stem });

    var argv = std.ArrayList([]const u8).init(arena);
    try argv.appendSlice(&.{ try std.fs.selfExePathAlloc(arena), "build", program, "-o", bin });
    if (o.prefix) |p| try argv.appendSlice(&.{ "--prefix", p });
    const built = try std.ChildProcess.run(.{ .allocator = arena, .argv = argv.items, .max_output_bytes = 16 << 20 });
    if (!exitedZero(built.term)) {
        try err.print("mopm test: {s}: the build failed ({s}):\n{s}{s}", .{ f.display, program, built.stdout, built.stderr });
        return .failed;
    }

    const listed = try std.ChildProcess.run(.{ .allocator = arena, .argv = &.{ bin, "--skip-all" }, .max_output_bytes = 16 << 20 });
    if (!exitedZero(listed.term)) {
        try err.print("mopm test: {s}: `{s} --skip-all` failed:\n{s}{s}", .{ f.display, bin, listed.stdout, listed.stderr });
        return .failed;
    }
    const names = test_harness.parseListing(arena, listed.stdout) catch |e| switch (e) {
        error.ProtocolMismatch => {
            try err.print("mopm test: {s}: `{s} --skip-all` printed a listing mopm cannot read; the installed Mojo's std.testing.TestSuite is not the one mopm knows (Mojo 1.0.0). Its output:\n{s}{s}", .{ f.display, bin, listed.stdout, listed.stderr });
            return .protocol;
        },
        else => |x| return x,
    };
    var scanned = std.ArrayList([]const u8).init(arena);
    for (sc.tests) |t| try scanned.append(t.name);
    const d = try test_harness.compare(arena, scanned.items, names);
    if (d.same()) return .same;

    const fatal = sc.kind == .bare or o.strict;
    try err.print("mopm test: {s}{s}: the scan and the `--skip-all` listing of the built {s} differ\n", .{
        @as([]const u8, if (fatal) "" else "warning: "),
        f.display,
        @as([]const u8, if (sc.kind == .bare) "harness" else "file"),
    });
    try printNames(err, "only in the scan:   ", d.only_scan);
    try printNames(err, "only in the listing:", d.only_listing);
    try printNames(err, "scan:               ", scanned.items);
    try printNames(err, "listing:            ", names);
    return if (fatal) .failed else .warned;
}

fn printNames(w: anytype, label: []const u8, names: []const []const u8) !void {
    try w.print("  {s}", .{label});
    for (names) |n| try w.print(" {s}", .{n});
    try w.writeByte('\n');
}

fn exitedZero(term: std.ChildProcess.Term) bool {
    return switch (term) {
        .Exited => |c| c == 0,
        else => false,
    };
}
