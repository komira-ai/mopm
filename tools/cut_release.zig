//! Cuts a mopm release by hand, in two steps a maintainer runs with their own `gh` login. Zig only,
//! standard library only; build it with the pinned Zig and run it from anywhere:
//!
//!     zig build-exe tools/cut_release.zig -femit-bin=<path>
//!
//! It does not build, sign or upload anything. The release is made by .github/workflows/release.yml,
//! the one place with contents: write and the attestation permission, when a v<version> tag is
//! pushed; what this tool adds is the checks around that push and the checks after it.
//!
//!   cut_release [--gh <path>] [--repo <owner/name>] tag <version> [--execute]
//!       Checks that main's src/cli/main.zig names <version>, that main's checks are all green,
//!       and that the tag and the release do not exist yet. Then it prints the one command that
//!       would create the tag v<version> at main's commit. It RUNS that command only with
//!       --execute (a dry run is the default); the tag push starts release.yml.
//!   cut_release [--gh <path>] [--repo <owner/name>] verify <version> <dir> [--expect-sha256 <hex>]
//!       After release.yml has finished: downloads the release's assets into <dir> (which must be
//!       empty), and REFUSES unless the release is published and not a draft, the assets are
//!       exactly the four mopm-<version>-<target>.tar.gz and SHA256SUMS, SHA256SUMS lists
//!       each tarball with the hash it has, `gh attestation verify` accepts every asset, and
//!       each tarball holds exactly mopm-<version>-<target>/{mopm,LICENSE}. It prints the URL,
//!       sha256, size and directory of the linux-x86_64 tarball, the row a build system pins.
//!       With --expect-sha256 it also refuses unless that tarball has that hash.
//!
//! Only `tag ... --execute` changes anything. `--gh` names the gh program (tests give a fake).

const std = @import("std");
const Allocator = std.mem.Allocator;

const targets = [_][]const u8{ "linux-x86_64", "linux-aarch64", "macos-arm64", "macos-x86_64" };
const pin_target = "linux-x86_64";

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cut_release: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usage() noreturn {
    die("usage: cut_release [--gh <path>] [--repo <owner/name>] tag <version> [--execute] | verify <version> <dir> [--expect-sha256 <hex>]", .{});
}

fn out(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(fmt, args) catch {};
}

// ---- gh --------------------------------------------------------------------------------

const Ran = struct { ok: bool, stdout: []u8, stderr: []u8 };

const Gh = struct {
    a: Allocator,
    exe: []const u8,
    repo: []const u8,

    fn run(g: Gh, args: []const []const u8) Ran {
        var argv = std.ArrayList([]const u8).init(g.a);
        argv.append(g.exe) catch @panic("oom");
        argv.appendSlice(args) catch @panic("oom");
        const r = std.process.Child.run(.{ .allocator = g.a, .argv = argv.items, .max_output_bytes = 1 << 22 }) catch |err| {
            die("could not run {s}: {s}", .{ g.exe, @errorName(err) });
        };
        return .{ .ok = r.term == .Exited and r.term.Exited == 0, .stdout = r.stdout, .stderr = r.stderr };
    }

    /// Standard output of a gh call that must succeed, without the trailing newline.
    fn must(g: Gh, args: []const []const u8) []const u8 {
        const r = g.run(args);
        if (!r.ok) die("gh {s} failed: {s}", .{ args[0], std.mem.trim(u8, r.stderr, " \r\n") });
        return std.mem.trimRight(u8, r.stdout, "\r\n");
    }

    /// Does the API path exist? A 404 is no; any other failure stops the tool, since "could not
    /// ask" must not read as "absent".
    fn exists(g: Gh, path: []const u8) bool {
        const r = g.run(&.{ "api", path });
        if (r.ok) return true;
        if (std.mem.indexOf(u8, r.stderr, "404") != null or std.mem.indexOf(u8, r.stderr, "Not Found") != null) return false;
        die("could not tell whether {s} exists: {s}", .{ path, std.mem.trim(u8, r.stderr, " \r\n") });
    }

    fn api(g: Gh, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(g.a, "repos/{s}/" ++ fmt, .{g.repo} ++ args) catch @panic("oom");
    }
};

// ---- main ------------------------------------------------------------------------------

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);

    var gh_exe: []const u8 = "gh";
    var repo: []const u8 = "komira-ai/mopm";
    var execute = false;
    var expect: ?[]const u8 = null;
    var pos = std.ArrayList([]const u8).init(a);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--execute")) {
            execute = true;
        } else if (std.mem.eql(u8, arg, "--gh") or std.mem.eql(u8, arg, "--repo") or std.mem.eql(u8, arg, "--expect-sha256")) {
            i += 1;
            if (i >= argv.len) usage();
            if (std.mem.eql(u8, arg, "--gh")) gh_exe = argv[i];
            if (std.mem.eql(u8, arg, "--repo")) repo = argv[i];
            if (std.mem.eql(u8, arg, "--expect-sha256")) expect = argv[i];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            usage();
        } else try pos.append(arg);
    }
    if (pos.items.len == 0) usage();
    const gh = Gh{ .a = a, .exe = gh_exe, .repo = repo };
    const cmd = pos.items[0];
    if (std.mem.eql(u8, cmd, "tag")) {
        if (pos.items.len != 2 or expect != null) usage();
        return tagCmd(gh, pos.items[1], execute);
    }
    if (std.mem.eql(u8, cmd, "verify")) {
        if (pos.items.len != 3 or execute) usage();
        return verifyCmd(gh, pos.items[1], pos.items[2], expect);
    }
    usage();
}

// ---- version ---------------------------------------------------------------------------

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// <major>.<minor>.<patch>, optionally followed by -<suffix>; no leading v.
fn validVersion(v: []const u8) bool {
    const core_end = std.mem.indexOfScalar(u8, v, '-') orelse v.len;
    if (core_end < v.len and core_end + 1 == v.len) return false;
    var parts = std.mem.splitScalar(u8, v[0..core_end], '.');
    var n: usize = 0;
    while (parts.next()) |p| : (n += 1) {
        if (!allDigits(p)) return false;
    }
    return n == 3;
}

/// The version in the text of src/cli/main.zig.
fn versionIn(text: []const u8) ?[]const u8 {
    const key = "pub const version = \"";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

// ---- tag -------------------------------------------------------------------------------

fn tagCmd(gh: Gh, version: []const u8, execute: bool) void {
    if (!validVersion(version)) die("'{s}' is not <major>.<minor>.<patch>[-suffix] (no leading v)", .{version});
    const a = gh.a;
    const tag = std.fmt.allocPrint(a, "v{s}", .{version}) catch @panic("oom");

    const sha = gh.must(&.{ "api", gh.api("commits/main", .{}), "--jq", ".sha" });
    if (sha.len != 40) die("main's commit '{s}' is not a 40-character sha", .{sha});
    const src = gh.must(&.{ "api", "-H", "Accept: application/vnd.github.raw", gh.api("contents/src/cli/main.zig?ref={s}", .{sha}) });
    const have = versionIn(src) orelse die("no version in src/cli/main.zig at {s}", .{sha});
    if (!std.mem.eql(u8, have, version)) die("src/cli/main.zig at {s} says {s}, not {s}: change the version in a reviewed commit first", .{ sha, have, version });

    const checks_jq = "\"\\(.total_count) \\([.check_runs[] | select(.conclusion != \"success\" and .conclusion != \"skipped\")] | length)\"";
    const checks = gh.must(&.{ "api", gh.api("commits/{s}/check-runs?per_page=100", .{sha}), "--jq", checks_jq });
    var it = std.mem.tokenizeScalar(u8, checks, ' ');
    const total = it.next() orelse "";
    const bad = it.next() orelse "";
    if (std.mem.eql(u8, total, "0") or !allDigits(total) or !std.mem.eql(u8, bad, "0")) {
        die("main's commit {s} does not have all checks green (check runs: {s}, not green: {s})", .{ sha, total, bad });
    }

    if (gh.exists(gh.api("git/ref/tags/{s}", .{tag}))) die("the tag {s} already exists", .{tag});
    if (gh.exists(gh.api("releases/tags/{s}", .{tag}))) die("a release for {s} already exists", .{tag});

    const ref_arg = std.fmt.allocPrint(a, "ref=refs/tags/{s}", .{tag}) catch @panic("oom");
    const sha_arg = std.fmt.allocPrint(a, "sha={s}", .{sha}) catch @panic("oom");
    const create = gh.api("git/refs", .{});
    out("version {s} is in src/cli/main.zig at main = {s}; its checks are green; no tag, no release.\n", .{ version, sha });
    out("command: {s} api -X POST {s} -f {s} -f {s}\n", .{ gh.exe, create, ref_arg, sha_arg });
    if (!execute) {
        out("DRY RUN: nothing was changed. Add --execute to create the tag {s}.\n", .{tag});
        return;
    }
    _ = gh.must(&.{ "api", "-X", "POST", create, "-f", ref_arg, "-f", sha_arg });
    out("created the tag {s}. release.yml builds the four tarballs, attests them and publishes the release;\n", .{tag});
    out("when its run has finished: cut_release verify {s} <empty dir>\n", .{version});
}

// ---- verify ----------------------------------------------------------------------------

fn sha256Hex(a: Allocator, bytes: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)) catch @panic("oom");
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn readAll(a: Allocator, dir: std.fs.Dir, name: []const u8) []u8 {
    return dir.readFileAlloc(a, name, 1 << 30) catch |err| die("cannot read {s}: {s}", .{ name, @errorName(err) });
}

/// The entry names of a ustar archive (the names the tarball packs), in archive order.
fn tarNames(a: Allocator, tar: []const u8) [][]const u8 {
    var names = std.ArrayList([]const u8).init(a);
    var at: usize = 0;
    while (at + 512 <= tar.len) {
        const h = tar[at .. at + 512];
        if (std.mem.allEqual(u8, h, 0)) break;
        const nul = std.mem.indexOfScalar(u8, h[0..100], 0) orelse 100;
        names.append(a.dupe(u8, h[0..nul]) catch @panic("oom")) catch @panic("oom");
        const size_text = std.mem.trim(u8, h[124..136], " \x00");
        const size = std.fmt.parseInt(usize, size_text, 8) catch die("a tar header has the size '{s}'", .{size_text});
        at += 512 + (size + 511) / 512 * 512;
    }
    return names.items;
}

fn verifyCmd(gh: Gh, version: []const u8, dir_path: []const u8, expect: ?[]const u8) void {
    if (!validVersion(version)) die("'{s}' is not <major>.<minor>.<patch>[-suffix] (no leading v)", .{version});
    const a = gh.a;
    const tag = std.fmt.allocPrint(a, "v{s}", .{version}) catch @panic("oom");

    const state = gh.must(&.{ "release", "view", tag, "-R", gh.repo, "--json", "isDraft,isPrerelease", "--jq", "\"\\(.isDraft) \\(.isPrerelease)\"" });
    const want_state = if (std.mem.indexOfScalar(u8, version, '-') != null) "false true" else "false false";
    if (!std.mem.eql(u8, state, want_state)) die("the release {s} has (draft prerelease) = '{s}', expected '{s}'", .{ tag, state, want_state });

    std.fs.cwd().makePath(dir_path) catch |err| die("cannot make {s}: {s}", .{ dir_path, @errorName(err) });
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| die("cannot open {s}: {s}", .{ dir_path, @errorName(err) });
    defer dir.close();
    var empty_it = dir.iterate();
    if (empty_it.next() catch null) |_| die("{s} is not empty; give an empty directory", .{dir_path});

    _ = gh.must(&.{ "release", "download", tag, "-R", gh.repo, "-D", dir_path, "--pattern", "mopm-*.tar.gz", "--pattern", "SHA256SUMS" });

    // The assets are exactly the four tarballs and SHA256SUMS.
    var want = std.ArrayList([]const u8).init(a);
    for (targets) |t| want.append(std.fmt.allocPrint(a, "mopm-{s}-{s}.tar.gz", .{ version, t }) catch @panic("oom")) catch @panic("oom");
    want.append("SHA256SUMS") catch @panic("oom");
    var have = std.ArrayList([]const u8).init(a);
    var it = dir.iterate();
    while (it.next() catch |err| die("cannot list {s}: {s}", .{ dir_path, @errorName(err) })) |e| {
        have.append(a.dupe(u8, e.name) catch @panic("oom")) catch @panic("oom");
    }
    std.mem.sort([]const u8, have.items, {}, lessThan);
    std.mem.sort([]const u8, want.items, {}, lessThan);
    if (have.items.len != want.items.len) die("the release holds {d} assets, expected exactly {d}: {s}", .{ have.items.len, want.items.len, std.mem.join(a, " ", have.items) catch "" });
    for (have.items, want.items) |h, w| {
        if (!std.mem.eql(u8, h, w)) die("the release's assets are not the expected set: found {s} where {s} was expected", .{ h, w });
    }

    // SHA256SUMS lists each tarball with the hash it has.
    const sums = readAll(a, dir, "SHA256SUMS");
    var listed: usize = 0;
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line.len < 67 or !std.mem.eql(u8, line[64..66], "  ")) die("malformed SHA256SUMS line: {s}", .{line});
        const file = line[66..];
        var known = false;
        for (want.items) |w| {
            if (std.mem.eql(u8, w, file) and !std.mem.eql(u8, w, "SHA256SUMS")) known = true;
        }
        if (!known) die("SHA256SUMS lists {s}, which is not one of the four tarballs", .{file});
        const got = sha256Hex(a, readAll(a, dir, file));
        if (!std.mem.eql(u8, line[0..64], got)) die("{s}: sha256 is {s}, SHA256SUMS lists {s}", .{ file, got, line[0..64] });
        listed += 1;
    }
    if (listed != targets.len) die("SHA256SUMS lists {d} files, expected {d}", .{ listed, targets.len });

    // Every asset is attested by this repository's release workflow.
    for (want.items) |w| {
        const path = std.fs.path.join(a, &.{ dir_path, w }) catch @panic("oom");
        const r = gh.run(&.{ "attestation", "verify", path, "-R", gh.repo });
        if (!r.ok) die("gh attestation verify refused {s}: {s}", .{ w, std.mem.trim(u8, r.stderr, " \r\n") });
    }

    // Each tarball unpacks into one directory holding exactly mopm and LICENSE.
    var pin_sha: []const u8 = "";
    var pin_size: usize = 0;
    for (targets) |t| {
        const name = std.fmt.allocPrint(a, "mopm-{s}-{s}", .{ version, t }) catch @panic("oom");
        const file = std.fmt.allocPrint(a, "{s}.tar.gz", .{name}) catch @panic("oom");
        const gz = readAll(a, dir, file);
        var in = std.io.fixedBufferStream(gz);
        var tar = std.ArrayList(u8).init(a);
        std.compress.gzip.decompress(in.reader(), tar.writer()) catch |err| die("{s} is not a gzip file: {s}", .{ file, @errorName(err) });
        const names = tarNames(a, tar.items);
        const expected = [_][]const u8{
            std.fmt.allocPrint(a, "{s}/", .{name}) catch @panic("oom"),
            std.fmt.allocPrint(a, "{s}/LICENSE", .{name}) catch @panic("oom"),
            std.fmt.allocPrint(a, "{s}/mopm", .{name}) catch @panic("oom"),
        };
        var ok = names.len == expected.len;
        if (ok) {
            std.mem.sort([]const u8, names, {}, lessThan);
            for (names, expected) |n, e| {
                if (!std.mem.eql(u8, n, e)) ok = false;
            }
        }
        if (!ok) die("{s} holds [{s}], expected exactly {s}/ with LICENSE and mopm", .{ file, std.mem.join(a, " ", names) catch "", name });
        if (std.mem.eql(u8, t, pin_target)) {
            pin_sha = sha256Hex(a, gz);
            pin_size = gz.len;
        }
    }
    if (expect) |e| {
        if (!std.mem.eql(u8, e, pin_sha)) die("{s} has sha256 {s}, not the expected {s}", .{ pin_target, pin_sha, e });
    }

    out("verified {s}: four tarballs and SHA256SUMS, hashes match, attestations accepted, layout exact.\n", .{tag});
    out("the pin for {s}:\n", .{pin_target});
    out("  url    https://github.com/{s}/releases/download/{s}/mopm-{s}-{s}.tar.gz\n", .{ gh.repo, tag, version, pin_target });
    out("  sha256 {s}\n  size   {d}\n  dir    mopm-{s}-{s}\n", .{ pin_sha, pin_size, version, pin_target });
}
