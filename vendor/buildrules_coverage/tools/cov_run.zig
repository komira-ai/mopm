// Vendored, unmodified, from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/coverage/tools/cov_run.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! cov_run: runs one Mojo test's coverage binary under kcov in a build action and writes its Cobertura report in repository paths.
//!
//! The approach is reduced to what a mopm unit needs: no gate
//! runner, no shared-library drivers. The test binary was built at -O0 with line tables by `mopm unit build`, so its line tables
//! name sources by relative paths (`tests/test_x.mojo`, `<import>/file.mojo`); kcov resolves those against its working directory,
//! so it is run in a tree where they resolve to copies of the sources, and measures only what `--include-path` names.
//!
//!   cov_run --kcov <dir> --normalize <exe> --compiler <dir> --binary <file> --share <dir> --out <report.xml>
//!           [--map <share-relative dir>=<repository dir>]... --must-contain <repository path>
//!           [--include <share-relative path>]... [--refuse-in-binary <text>]...
//!
//!   --kcov      the kcov distribution (bin/kcov, lib/libgcc_s.so.1); it is run in place
//!   --compiler  the compiler closure; its lib/ is on LD_LIBRARY_PATH (the test binary loads libKGENCompilerRTShared.so from it)
//!   --binary    the test, with its native libraries in lib/ beside it (its runpath is $ORIGIN/lib)
//!   --share     the tree of copies the line tables' names resolve in; kcov's working directory
//!   --map       a directory of the tree and the repository directory it copies (both end in `/`): the report's absolute names are
//!               rewritten with them (cov_normalize --map)
//!   --include   what kcov measures, by path in the tree (comma and colon are refused: kcov's option splits on them)
//!   --refuse-in-binary  fail before kcov runs when the binary holds this text: a binary that names the sources by the directory they
//!               were staged in (`.stage/src/`) would have kcov drop them without an error
//!
//! Exit status: the test's under kcov when it fails (128+N for signal N); 1 when the binary names staged paths, kcov wrote no report,
//! or the report was refused; 2 for a usage error.

const std = @import("std");

pub const Map = struct { share_rel: []const u8, repo: []const u8 };

pub const Args = struct {
    kcov: []const u8 = "",
    normalize: []const u8 = "",
    compiler: []const u8 = "",
    binary: []const u8 = "",
    share: []const u8 = "",
    out: []const u8 = "",
    must_contain: []const u8 = "",
    maps: []const Map = &.{},
    includes: []const []const u8 = &.{},
    refuse: []const []const u8 = &.{},
    /// Arguments of the test binary (zig_cover.zig gives the runner its report path); cov_run's own command line has none.
    binary_args: []const []const u8 = &.{},
};

pub const UsageError = error{Usage};

fn hasAny(s: []const u8, set: []const u8) bool {
    return std.mem.indexOfAny(u8, s, set) != null;
}

pub fn parse(a: std.mem.Allocator, argv: []const []const u8, diag: *[]const u8) (UsageError || std.mem.Allocator.Error)!Args {
    var r = Args{};
    var maps = std.ArrayList(Map).empty;
    var includes = std.ArrayList([]const u8).empty;
    var refuse = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        const flag = argv[i];
        if (i + 1 >= argv.len) {
            diag.* = try std.fmt.allocPrint(a, "{s} needs a value", .{flag});
            return error.Usage;
        }
        const v = argv[i + 1];
        if (std.mem.eql(u8, flag, "--kcov")) {
            r.kcov = v;
        } else if (std.mem.eql(u8, flag, "--normalize")) {
            r.normalize = v;
        } else if (std.mem.eql(u8, flag, "--compiler")) {
            r.compiler = v;
        } else if (std.mem.eql(u8, flag, "--binary")) {
            r.binary = v;
        } else if (std.mem.eql(u8, flag, "--share")) {
            r.share = v;
        } else if (std.mem.eql(u8, flag, "--out")) {
            r.out = v;
        } else if (std.mem.eql(u8, flag, "--must-contain")) {
            r.must_contain = v;
        } else if (std.mem.eql(u8, flag, "--map")) {
            const eq = std.mem.indexOfScalar(u8, v, '=') orelse {
                diag.* = try std.fmt.allocPrint(a, "--map {s} is not <share dir>=<repository dir>", .{v});
                return error.Usage;
            };
            const s = v[0..eq];
            const repo = v[eq + 1 ..];
            if (s.len == 0 or s[0] == '/' or s[s.len - 1] != '/' or (repo.len > 0 and (repo[0] == '/' or repo[repo.len - 1] != '/'))) {
                diag.* = try std.fmt.allocPrint(a, "--map {s}: both sides are relative directories ending in /", .{v});
                return error.Usage;
            }
            try maps.append(a, .{ .share_rel = s, .repo = repo });
        } else if (std.mem.eql(u8, flag, "--include")) {
            if (v.len == 0 or v[0] == '/' or hasAny(v, ",: ")) {
                diag.* = try std.fmt.allocPrint(a, "--include {s} must be a relative path without a space, , or :", .{v});
                return error.Usage;
            }
            try includes.append(a, v);
        } else if (std.mem.eql(u8, flag, "--refuse-in-binary")) {
            if (v.len == 0) {
                diag.* = "--refuse-in-binary needs text";
                return error.Usage;
            }
            try refuse.append(a, v);
        } else {
            diag.* = try std.fmt.allocPrint(a, "unknown option {s}", .{flag});
            return error.Usage;
        }
    }
    inline for (.{ "kcov", "normalize", "compiler", "binary", "share", "out", "must_contain" }) |k| {
        if (@field(r, k).len == 0) {
            diag.* = try std.fmt.allocPrint(a, "--{s} is required", .{k});
            return error.Usage;
        }
    }
    if (includes.items.len == 0) {
        diag.* = "at least one --include is required: kcov measures nothing else";
        return error.Usage;
    }
    r.maps = try maps.toOwnedSlice(a);
    r.includes = try includes.toOwnedSlice(a);
    r.refuse = try refuse.toOwnedSlice(a);
    return r;
}

/// kcov's command line. `share` is the absolute (real) path of the tree, `work` where the report goes.
pub fn kcovArgv(a: std.mem.Allocator, r: Args, share: []const u8, work: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    try out.append(a, try std.fs.path.join(a, &.{ r.kcov, "bin", "kcov" }));
    try out.append(a, "--cobertura-only");
    try out.append(a, "--skip-solibs");
    try out.append(a, "--configure=cobertura-full-paths=1");
    var inc = std.ArrayList(u8).empty;
    try inc.appendSlice(a, "--include-path=");
    for (r.includes, 0..) |p, i| {
        if (i != 0) try inc.append(a, ',');
        try inc.appendSlice(a, try std.fs.path.join(a, &.{ share, p }));
    }
    try out.append(a, try inc.toOwnedSlice(a));
    try out.append(a, work);
    try out.append(a, r.binary);
    try out.appendSlice(a, r.binary_args);
    return out.toOwnedSlice(a);
}

/// cov_normalize's command line for the raw report `raw`.
pub fn normalizeArgv(a: std.mem.Allocator, r: Args, share: []const u8, raw: []const u8, cwd: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    try out.appendSlice(a, &.{ r.normalize, "--in", raw, "--out", r.out });
    for (r.maps) |m| {
        try out.append(a, "--map");
        try out.append(a, try std.fmt.allocPrint(a, "{s}/{s}={s}", .{ share, m.share_rel, m.repo }));
    }
    try out.appendSlice(a, &.{ "--must-contain", r.must_contain, "--forbid", cwd });
    return out.toOwnedSlice(a);
}

/// The first of `refuse` that `binary` holds, or null.
pub fn heldText(binary: []const u8, refuse: []const []const u8) ?[]const u8 {
    for (refuse) |t| {
        if (std.mem.indexOf(u8, binary, t) != null) return t;
    }
    return null;
}

fn die(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cov_run: " ++ fmt ++ "\n", args);
    std.process.exit(code);
}

fn run(a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, env: *std.process.EnvMap) !u8 {
    var child = std.process.Child.init(argv, a);
    child.cwd = cwd;
    child.env_map = env;
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
    const share = std.fs.cwd().realpathAlloc(a, r.share) catch |e| die(2, "cannot resolve --share {s}: {s}", .{ r.share, @errorName(e) });
    const binary = std.fs.cwd().realpathAlloc(a, r.binary) catch |e| die(2, "cannot resolve --binary {s}: {s}", .{ r.binary, @errorName(e) });
    const compiler = std.fs.cwd().realpathAlloc(a, r.compiler) catch |e| die(2, "cannot resolve --compiler {s}: {s}", .{ r.compiler, @errorName(e) });
    const kcov_dir = std.fs.cwd().realpathAlloc(a, r.kcov) catch |e| die(2, "cannot resolve --kcov {s}: {s}", .{ r.kcov, @errorName(e) });
    const normalize = std.fs.cwd().realpathAlloc(a, r.normalize) catch |e| die(2, "cannot resolve --normalize {s}: {s}", .{ r.normalize, @errorName(e) });

    // The binary names its sources by relative paths, or kcov drops them without an error.
    const bytes = try std.fs.cwd().readFileAlloc(a, binary, 1 << 30);
    if (heldText(bytes, r.refuse)) |t| {
        die(1, "the test binary holds `{s}`: it names a library's sources by the directory they were staged in, which kcov cannot open here and would drop without an error; the library was compiled with a source root that is not its package directory", .{t});
    }

    const work = try std.fmt.allocPrint(a, "{s}.work", .{r.out});
    std.fs.cwd().makePath(work) catch |e| die(1, "cannot create {s}: {s}", .{ work, @errorName(e) });
    const work_abs = try std.fs.cwd().realpathAlloc(a, work);
    var rr = r;
    rr.kcov = kcov_dir;
    rr.binary = binary;
    const kargv = try kcovArgv(a, rr, share, work_abs);
    var env = std.process.EnvMap.init(a);
    try env.put("LD_LIBRARY_PATH", try std.fs.path.join(a, &.{ compiler, "lib" }));
    try env.put("PATH", "/usr/bin:/bin");
    const code = try run(a, kargv, share, &env);
    if (code != 0) die(code, "kcov (or the test under it) exited {d}", .{code});

    // kcov's report: cov.xml with --cobertura-only.
    const raw = try std.fs.path.join(a, &.{ work_abs, "cov.xml" });
    std.fs.cwd().access(raw, .{}) catch die(1, "kcov wrote no {s}", .{raw});
    rr.normalize = normalize;
    rr.out = try std.fs.path.join(a, &.{ cwd, r.out });
    const nargv = try normalizeArgv(a, rr, share, raw, cwd);
    var nenv = std.process.EnvMap.init(a);
    const ncode = try run(a, nargv, null, &nenv);
    if (ncode != 0) die(1, "cov_normalize refused the report (exit {d})", .{ncode});
    std.fs.cwd().deleteTree(work) catch {};
}
