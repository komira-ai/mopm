//! The release packaging tool, run by .github/workflows/release-build.yml, release.yml and
//! release-check.yml (and by tests/drivers/install_script_test.zig to make a fake release). Zig
//! only, standard library only: build it with the pinned Zig,
//!
//!     zig build-exe tools/release.zig -femit-bin=<path>
//!
//! and run it from the repository root.
//!
//!   release package <version> <target> <zig-target> <outdir> [--run-prefix "<words>"]
//!       Builds the CLI (zig build -Doptimize=ReleaseSafe -Dtarget=<zig-target> -Dstrip=true -Dversion=<version>), runs
//!       it with `--version` and REFUSES unless it prints `mopm <version>` (version has no leading
//!       v), and writes <outdir>/mopm-<version>-<target>.tar.gz holding
//!       mopm-<version>-<target>/{mopm,LICENSE}. --run-prefix is a command put before the binary to
//!       run it (`arch -x86_64` for the Intel macOS build on an arm64 runner).
//!   release sums <dir>
//!       Requires exactly four mopm-<version>-<target>.tar.gz in <dir>, one per target, one version;
//!       writes <dir>/SHA256SUMS and checks it.
//!   release check <dir>
//!       Checks <dir>/SHA256SUMS: exactly those four tarballs, each with the hash listed.
//!   release tarball <parent> <name> <out.tar.gz>
//!       Packs the files of <parent>/<name>/ as <name>/<file> (ustar, then gzip).
//!
//! Nothing here uploads anything.

const std = @import("std");
const Allocator = std.mem.Allocator;

const targets = [_][]const u8{ "linux-x86_64", "linux-aarch64", "macos-arm64", "macos-x86_64" };

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("release: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usage() noreturn {
    die("usage: release package <version> <target> <zig-target> <outdir> [--run-prefix \"<words>\"] | sums <dir> | check <dir> | tarball <parent> <name> <out.tar.gz>", .{});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) usage();
    const cmd = argv[1];
    const rest = argv[2..];
    if (std.mem.eql(u8, cmd, "package")) return package(a, rest);
    if (std.mem.eql(u8, cmd, "sums")) {
        if (rest.len != 1) usage();
        return sums(a, rest[0]);
    }
    if (std.mem.eql(u8, cmd, "check")) {
        if (rest.len != 1) usage();
        return check(a, rest[0]);
    }
    if (std.mem.eql(u8, cmd, "tarball")) {
        if (rest.len != 3) usage();
        return makeTarGz(a, rest[0], rest[1], rest[2]);
    }
    usage();
}

// ---- package ---------------------------------------------------------------------------

fn package(a: Allocator, args: []const []const u8) !void {
    if (args.len != 4 and args.len != 6) usage();
    const version = args[0];
    const target = args[1];
    const zig_target = args[2];
    const outdir = args[3];
    var prefix_words = std.ArrayList([]const u8).init(a);
    if (args.len == 6) {
        if (!std.mem.eql(u8, args[4], "--run-prefix")) usage();
        var it = std.mem.tokenizeScalar(u8, args[5], ' ');
        while (it.next()) |w| try prefix_words.append(w);
    }
    var known = false;
    for (targets) |t| {
        if (std.mem.eql(u8, t, target)) known = true;
    }
    if (!known) die("unknown target '{s}'", .{target});
    if (version.len == 0 or version[0] == 'v') die("version '{s}' must be given without a leading v", .{version});
    for (version) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-') die("version '{s}' holds a character outside [0-9A-Za-z.-]", .{version});
    }

    const cwd = std.fs.cwd();
    const name = try std.fmt.allocPrint(a, "mopm-{s}-{s}", .{ version, target });
    const stage = try std.fs.path.join(a, &.{ outdir, "stage" });
    const stage_pkg = try std.fs.path.join(a, &.{ stage, name });
    const prefix = try std.fs.path.join(a, &.{ stage, "prefix" });
    try cwd.makePath(stage_pkg);

    const build_argv = [_][]const u8{
        "zig",                                                 "build",
        "-Doptimize=ReleaseSafe",                              try std.fmt.allocPrint(a, "-Dtarget={s}", .{zig_target}),
        "-Dstrip=true",                                        try std.fmt.allocPrint(a, "-Dversion={s}", .{version}),
        "-p",
        prefix,
    };
    var child = std.process.Child.init(&build_argv, a);
    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) die("zig build failed", .{});

    const bin = try std.fs.path.join(a, &.{ stage_pkg, "mopm" });
    try cwd.copyFile(try std.fs.path.join(a, &.{ prefix, "bin", "mopm" }), cwd, bin, .{});
    try cwd.copyFile("LICENSE", cwd, try std.fs.path.join(a, &.{ stage_pkg, "LICENSE" }), .{});

    var run_argv = std.ArrayList([]const u8).init(a);
    try run_argv.appendSlice(prefix_words.items);
    try run_argv.append(try cwd.realpathAlloc(a, bin));
    try run_argv.append("--version");
    const ran = std.process.Child.run(.{ .allocator = a, .argv = run_argv.items }) catch |err| {
        die("could not run {s} --version: {s}", .{ bin, @errorName(err) });
    };
    const want = try std.fmt.allocPrint(a, "mopm {s}", .{version});
    const got = std.mem.trim(u8, ran.stdout, " \r\n");
    if (ran.term != .Exited or ran.term.Exited != 0 or !std.mem.eql(u8, got, want)) {
        die("the binary reports '{s}', not '{s}'; refusing to package", .{ got, want });
    }

    const out = try std.fmt.allocPrint(a, "{s}.tar.gz", .{try std.fs.path.join(a, &.{ outdir, name })});
    try makeTarGz(a, stage, name, out);
    try cwd.deleteTree(stage);
    std.debug.print("packaged {s} ({s})\n", .{ out, got });
}

// ---- tarball: ustar, then gzip -----------------------------------------------------------

fn octal(field: []u8, value: u64) void {
    var v = value;
    var i = field.len - 1;
    field[i] = 0;
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
}

fn tarHeader(list: *std.ArrayList(u8), name: []const u8, mode: u64, size: u64, kind: u8) !void {
    if (name.len > 100) die("tar name too long: {s}", .{name});
    var h = [_]u8{0} ** 512;
    @memcpy(h[0..name.len], name);
    octal(h[100..108], mode);
    octal(h[108..116], 0);
    octal(h[116..124], 0);
    octal(h[124..136], size);
    octal(h[136..148], 0);
    @memset(h[148..156], ' ');
    h[156] = kind;
    @memcpy(h[257..263], "ustar\x00");
    h[263] = '0';
    h[264] = '0';
    var sum: u64 = 0;
    for (h) |b| sum += b;
    octal(h[148..155], sum);
    h[155] = ' ';
    try list.appendSlice(&h);
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn makeTarGz(a: Allocator, parent: []const u8, name: []const u8, out_path: []const u8) !void {
    const cwd = std.fs.cwd();
    var dir = try cwd.openDir(try std.fs.path.join(a, &.{ parent, name }), .{ .iterate = true });
    defer dir.close();
    var names = std.ArrayList([]const u8).init(a);
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file) die("{s}/{s}: only plain files are packed", .{ name, e.name });
        try names.append(try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var tar = std.ArrayList(u8).init(a);
    try tarHeader(&tar, try std.fmt.allocPrint(a, "{s}/", .{name}), 0o755, 0, '5');
    for (names.items) |n| {
        var f = try dir.openFile(n, .{});
        defer f.close();
        const st = try f.stat();
        const data = try f.readToEndAlloc(a, 1 << 30);
        try tarHeader(&tar, try std.fmt.allocPrint(a, "{s}/{s}", .{ name, n }), @as(u64, @intCast(st.mode)) & 0o777, data.len, '0');
        try tar.appendSlice(data);
        try tar.appendNTimes(0, (512 - data.len % 512) % 512);
    }
    try tar.appendNTimes(0, 1024);

    var fbs = std.io.fixedBufferStream(tar.items);
    var out = try cwd.createFile(out_path, .{});
    defer out.close();
    var bw = std.io.bufferedWriter(out.writer());
    try std.compress.gzip.compress(fbs.reader(), bw.writer(), .{});
    try bw.flush();
}

// ---- SHA256SUMS ----------------------------------------------------------------------------

fn sha256Hex(path: []const u8) ![64]u8 {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// The names of the mopm-*.tar.gz in `dir`, sorted. Refuses unless there are exactly four: one per
/// target, all of one version.
fn fourTarballs(a: Allocator, dir_path: []const u8) ![][]const u8 {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var names = std.ArrayList([]const u8).init(a);
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (std.mem.startsWith(u8, e.name, "mopm-") and std.mem.endsWith(u8, e.name, ".tar.gz")) {
            try names.append(try a.dupe(u8, e.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    if (names.items.len != targets.len) die("expected exactly {d} mopm-*.tar.gz in {s}, found {d}", .{ targets.len, dir_path, names.items.len });
    var version: ?[]const u8 = null;
    for (targets) |t| {
        const suffix = try std.fmt.allocPrint(a, "-{s}.tar.gz", .{t});
        var found: usize = 0;
        for (names.items) |n| {
            if (!std.mem.endsWith(u8, n, suffix)) continue;
            found += 1;
            const v = n["mopm-".len .. n.len - suffix.len];
            if (version) |prev| {
                if (!std.mem.eql(u8, prev, v)) die("tarballs of two versions: {s} and {s}", .{ prev, v });
            } else version = v;
        }
        if (found != 1) die("expected one tarball for {s}, found {d}", .{ t, found });
    }
    return names.items;
}

fn sums(a: Allocator, dir_path: []const u8) !void {
    const names = try fourTarballs(a, dir_path);
    var text = std.ArrayList(u8).init(a);
    for (names) |n| {
        const hex = try sha256Hex(try std.fs.path.join(a, &.{ dir_path, n }));
        try text.writer().print("{s}  {s}\n", .{ hex, n });
    }
    try std.fs.cwd().writeFile(try std.fs.path.join(a, &.{ dir_path, "SHA256SUMS" }), text.items);
    try check(a, dir_path);
}

fn check(a: Allocator, dir_path: []const u8) !void {
    const names = try fourTarballs(a, dir_path);
    const text = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ dir_path, "SHA256SUMS" }), 1 << 20);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var listed: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line.len < 67 or !std.mem.eql(u8, line[64..66], "  ")) die("malformed SHA256SUMS line: {s}", .{line});
        const hex = line[0..64];
        const n = line[66..];
        var known = false;
        for (names) |m| {
            if (std.mem.eql(u8, m, n)) known = true;
        }
        if (!known) die("SHA256SUMS lists {s}, which is not one of the four tarballs", .{n});
        const got = try sha256Hex(try std.fs.path.join(a, &.{ dir_path, n }));
        if (!std.mem.eql(u8, hex, &got)) die("{s}: sha256 {s} is not the listed {s}", .{ n, &got, hex });
        listed += 1;
    }
    if (listed != names.len) die("SHA256SUMS lists {d} files, expected {d}", .{ listed, names.len });
    std.debug.print("SHA256SUMS ok: {d} tarballs\n", .{listed});
}
