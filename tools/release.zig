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
//!   release record <tarball> <outdir>
//!       Writes <outdir>/<tarball name>.sha256 (`<sha256>  <name>`): the exact bytes the user beta ran.
//!   release tested <dist> <tested-dir>
//!       Refuses unless <tested-dir> holds one record per user-tested target (linux-x86_64, linux-aarch64,
//!       macos-arm64), nothing else, and <dist> holds each named tarball with the recorded sha256: the
//!       files attested are the files that passed the user beta. Runs in the attest job before `sums`.
//!   release sign <dir> [--cosign <path>]
//!       After `sums`: signs the four tarballs and SHA256SUMS with keyless `cosign sign-blob` (Sigstore;
//!       the signing identity is the workflow's OIDC token, no key and no secret exists), writing
//!       <file>.sigstore.json beside each, and refuses unless all five bundles exist and are not empty.
//!       Runs only in the attest job of release.yml, the one job that holds id-token.
//!   release install-cosign <dir> [--from <file> --sha256 <hex>]
//!       Downloads cosign v3.0.6 (the official linux-amd64 release binary from github.com/sigstore/cosign) to
//!       <dir>/cosign and REFUSES, leaving no file, unless its sha256 is the one pinned in this source; then
//!       makes it executable and prints <dir>, for $GITHUB_PATH. It replaces sigstore/cosign-installer, which the
//!       org's Actions policy does not allow. `--from` (a local file in place of the download) and `--sha256`
//!       (in place of the pin, only with `--from`) are for the test.
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
    die("usage: release package <version> <target> <zig-target> <outdir> [--run-prefix \"<words>\"] | sums <dir> | check <dir> | tarball <parent> <name> <out.tar.gz> | sign <dir> [--cosign <path>] | record <tarball> <outdir> | tested <dist> <tested-dir> | install-cosign <dir> [--from <file> --sha256 <hex>]", .{});
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
    if (std.mem.eql(u8, cmd, "record")) {
        if (rest.len != 2) usage();
        return record(a, rest[0], rest[1]);
    }
    if (std.mem.eql(u8, cmd, "tested")) {
        if (rest.len != 2) usage();
        return tested(a, rest[0], rest[1]);
    }
    if (std.mem.eql(u8, cmd, "install-cosign")) return installCosign(a, rest);
    if (std.mem.eql(u8, cmd, "sign")) {
        if (rest.len == 1) return sign(a, rest[0], "cosign");
        if (rest.len == 3 and std.mem.eql(u8, rest[1], "--cosign")) return sign(a, rest[0], rest[2]);
        usage();
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

// ---- sign: keyless cosign signatures --------------------------------------------------------

/// `cosign sign-blob --yes --bundle <file>.sigstore.json <file>` for the four tarballs and SHA256SUMS.
fn sign(a: Allocator, dir_path: []const u8, cosign: []const u8) !void {
    const names = try fourTarballs(a, dir_path);
    var files = std.ArrayList([]const u8).init(a);
    try files.appendSlice(names);
    try files.append("SHA256SUMS");
    for (files.items) |n| {
        const file = try std.fs.path.join(a, &.{ dir_path, n });
        const bundle = try std.fmt.allocPrint(a, "{s}.sigstore.json", .{file});
        var child = std.process.Child.init(&.{ cosign, "sign-blob", "--yes", "--bundle", bundle, file }, a);
        const term = child.spawnAndWait() catch |err| die("could not run {s}: {s}", .{ cosign, @errorName(err) });
        if (term != .Exited or term.Exited != 0) die("cosign sign-blob failed for {s}", .{n});
        const st = std.fs.cwd().statFile(bundle) catch die("cosign wrote no bundle for {s}", .{n});
        if (st.size == 0) die("the bundle of {s} is empty", .{n});
    }
    std.debug.print("signed {d} files\n", .{files.items.len});
}

// ---- record, tested: the tarball the user beta passed is the tarball attested -----------------

/// The targets whose tarball release-beta-user.yml walks as a user (macos-x86_64 has no runner).
const tested_targets = [_][]const u8{ "linux-x86_64", "linux-aarch64", "macos-arm64" };

/// Writes `<outdir>/<tarball name>.sha256` holding `<sha256>  <tarball name>`: the bytes the user beta ran.
fn record(a: Allocator, tarball: []const u8, outdir: []const u8) !void {
    const name = std.fs.path.basename(tarball);
    if (!std.mem.startsWith(u8, name, "mopm-") or !std.mem.endsWith(u8, name, ".tar.gz")) die("{s} is not a mopm-*.tar.gz", .{name});
    const hex = sha256Hex(tarball) catch |err| die("cannot read {s}: {s}", .{ tarball, @errorName(err) });
    try std.fs.cwd().makePath(outdir);
    const out = try std.fs.path.join(a, &.{ outdir, try std.fmt.allocPrint(a, "{s}.sha256", .{name}) });
    try std.fs.cwd().writeFile(out, try std.fmt.allocPrint(a, "{s}  {s}\n", .{ hex, name }));
    std.debug.print("recorded {s} {s}\n", .{ name, &hex });
}

/// Refuses unless, for each tested target, `tested_dir` holds exactly one record and `dist_dir` holds the
/// tarball it names with exactly the recorded sha256; and `tested_dir` holds no other file.
fn tested(a: Allocator, dist_dir: []const u8, tested_dir: []const u8) !void {
    var dir = std.fs.cwd().openDir(tested_dir, .{ .iterate = true }) catch |err| die("cannot open {s}: {s}", .{ tested_dir, @errorName(err) });
    defer dir.close();
    var files = std.ArrayList([]const u8).init(a);
    var it = dir.iterate();
    while (try it.next()) |e| try files.append(try a.dupe(u8, e.name));
    var matched: usize = 0;
    for (tested_targets) |t| {
        const suffix = try std.fmt.allocPrint(a, "-{s}.tar.gz.sha256", .{t});
        var found: ?[]const u8 = null;
        for (files.items) |n| {
            if (!std.mem.endsWith(u8, n, suffix)) continue;
            if (found != null) die("two records for {s} in {s}", .{ t, tested_dir });
            found = n;
        }
        const rec = found orelse die("the user beta recorded nothing for {s}: that tarball was not tested", .{t});
        matched += 1;
        const text = try dir.readFileAlloc(a, rec, 4096);
        const line = std.mem.trimRight(u8, text, "\n");
        const name = rec[0 .. rec.len - ".sha256".len];
        if (line.len != 66 + name.len or !std.mem.eql(u8, line[64..66], "  ") or !std.mem.eql(u8, line[66..], name)) die("malformed record {s}", .{rec});
        const have = sha256Hex(try std.fs.path.join(a, &.{ dist_dir, name })) catch |err| die("cannot read {s} in {s}: {s}", .{ name, dist_dir, @errorName(err) });
        if (!std.mem.eql(u8, line[0..64], &have)) die("{s}: the user beta tested sha256 {s}, but the file to attest has {s}", .{ name, line[0..64], &have });
        std.debug.print("tested ok: {s} {s}\n", .{ name, &have });
    }
    if (files.items.len != matched) die("{s} holds {d} files, expected exactly the {d} records of the tested targets", .{ tested_dir, files.items.len, matched });
}

// ---- install-cosign: the cosign binary, by a sha256 pinned here ---------------------------------

/// The cosign the release signs and verifies with. The org's Actions policy allows no third-party action, so
/// release.yml installs it with this step instead of sigstore/cosign-installer. The sha256 is the one in the
/// release's own cosign_checksums.txt (and the one the retired installer carried) for cosign-linux-amd64.
const cosign_version = "v3.0.6";
const cosign_url = "https://github.com/sigstore/cosign/releases/download/" ++ cosign_version ++ "/cosign-linux-amd64";
const cosign_sha256 = "c956e5dfcac53d52bcf058360d579472f0c1d2d9b69f55209e256fe7783f4c74";
/// The download is refused past this size (the real binary is 135 MB).
const cosign_max_bytes: u64 = 256 << 20;

fn isLowerHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |ch| if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return false;
    return true;
}

/// Copies `reader` to `out`, hashing what passes; refuses more than `limit` bytes.
fn pump(reader: anytype, out: std.fs.File, h: *std.crypto.hash.sha2.Sha256, limit: u64) !void {
    var buf: [64 * 1024]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        total += n;
        if (total > limit) return error.TooLarge;
        h.update(buf[0..n]);
        try out.writeAll(buf[0..n]);
    }
}

fn fetchInto(a: Allocator, out: std.fs.File, h: *std.crypto.hash.sha2.Sha256) !void {
    var client = std.http.Client{ .allocator = a };
    defer client.deinit();
    const uri = try std.Uri.parse(cosign_url);
    var header_buf: [16 * 1024]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &header_buf,
        .keep_alive = false,
        .headers = .{
            .user_agent = .{ .override = "mopm-release" },
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer req.deinit();
    try req.send();
    try req.finish();
    try req.wait();
    const status = @intFromEnum(req.response.status);
    if (status < 200 or status >= 300) {
        std.debug.print("release: {s} answered HTTP {d}\n", .{ cosign_url, status });
        return error.BadStatus;
    }
    try pump(req.reader(), out, h, cosign_max_bytes);
}

/// `install-cosign <dir> [--from <file> --sha256 <hex>]`: downloads cosign-linux-amd64 to <dir>/cosign, REFUSES
/// (and leaves no file) unless its sha256 is the one pinned above, makes it executable and prints <dir> (for
/// $GITHUB_PATH). `--from` reads a local file in place of the download and `--sha256` replaces the pin; both
/// exist for the test, and `--sha256` is refused without `--from`, so the real download can only meet the pin.
fn installCosign(a: Allocator, args: []const []const u8) !void {
    if (args.len == 0) usage();
    const dir_path = args[0];
    var from: ?[]const u8 = null;
    var want: []const u8 = cosign_sha256;
    var custom_pin = false;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) usage();
        if (std.mem.eql(u8, args[i], "--from")) {
            from = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--sha256")) {
            want = args[i + 1];
            custom_pin = true;
        } else usage();
    }
    if (custom_pin and from == null) die("--sha256 is only accepted with --from: the download is checked against the pin in this file", .{});
    if (!isLowerHex64(want)) die("the expected sha256 '{s}' is not 64 lowercase hex digits", .{want});

    const cwd = std.fs.cwd();
    try cwd.makePath(dir_path);
    const dest = try std.fs.path.join(a, &.{ dir_path, "cosign" });
    const part = try std.fs.path.join(a, &.{ dir_path, "cosign.part" });
    // A failed install leaves no cosign behind, not even an older one.
    cwd.deleteFile(dest) catch {};
    cwd.deleteFile(part) catch {};

    var h = std.crypto.hash.sha2.Sha256.init(.{});
    const out = try cwd.createFile(part, .{});
    var got: ?anyerror = null;
    if (from) |path| {
        if (cwd.openFile(path, .{})) |f| {
            defer f.close();
            pump(f.reader(), out, &h, cosign_max_bytes) catch |e| {
                got = e;
            };
        } else |e| {
            got = e;
            std.debug.print("release: cannot open {s}: {s}\n", .{ path, @errorName(e) });
        }
    } else {
        fetchInto(a, out, &h) catch |e| {
            got = e;
        };
    }
    out.close();
    if (got) |e| {
        cwd.deleteFile(part) catch {};
        die("cosign {s} was not installed: {s}", .{ cosign_version, @errorName(e) });
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, want)) {
        cwd.deleteFile(part) catch {};
        die("the cosign file has sha256 {s}, not the expected {s}; refusing to install it", .{ &hex, want });
    }
    try cwd.rename(part, dest);
    const f = try cwd.openFile(dest, .{});
    defer f.close();
    try f.chmod(0o755);
    std.debug.print("installed cosign {s} (sha256 {s})\n", .{ cosign_version, &hex });
    try std.io.getStdOut().writer().print("{s}\n", .{try cwd.realpathAlloc(a, dir_path)});
}
