//! apt_publish: the publish half of the apt channel, the command line release.yml runs after `publish`. Each command is one
//! step of one job; the jobs are split so that no job holds both the signing key and the cloud role (release.yml says how).
//!
//!   apt_publish gate --label <text> [--out <file>] [--env <NAME> ...] [--true <NAME> ...]
//!       Is every named environment variable set and not empty (--env), or exactly `true` (--true)? Prints a notice naming what
//!       is missing (names, never values) and appends `enabled=true|false` to --out ($GITHUB_OUTPUT). Always exits 0: a job whose
//!       settings are not made yet does nothing and ends green.
//!   apt_publish assume --env-file <$GITHUB_ENV> [--curl <path>] [--aws <path>]
//!       The OIDC exchange: asks the runner for a token for the audience sts.amazonaws.com (curl), exchanges it for the credentials
//!       of the role APT_PUBLISH_ROLE_ARN (aws sts assume-role-with-web-identity), masks them, and writes them as AWS_* lines to
//!       --env-file for the next steps. The job needs `id-token: write`.
//!   apt_publish read --bucket <b> --out <dir> [--aws <path>]
//!       Reads the current index from S3 (never through the CDN, which would hand back a stale ETag): Release first, then every
//!       Packages and Packages.gz of the architectures it lists and of the defaults, and InRelease and Release.gpg. Writes the
//!       copy under <dir>/dists/stable/ and the ETag of each object (`-` for one that does not exist) to <dir>/etags.txt.
//!   apt_publish index --channels <path> --current <dir> --out <dir> --debs <dir> [--pool-dir pool/mopm] --origin <t> --label <t>
//!                     --description <t> [--date <epoch>]
//!       Merges the .debs of <debs> into the index read to <current> (tools/channels apt-index) and writes the new unsigned index
//!       and the ETags it was built from to <out>. Reads no cloud and no key.
//!   apt_publish sign --dir <out>/dists/stable --work <dir> --fingerprint <fpr> [--gpg <path>] [--out <file>]
//!       Signs <dir>/Release with the signing subkey: InRelease (clearsigned) and Release.gpg (detached), and verifies both. The
//!       key is APT_GPG_PRIVATE_KEY and the passphrase APT_GPG_PASSPHRASE, in the environment of this one step; they live in files
//!       of a private directory below --work that is removed at the end, whatever happens. Appends `signed=true` to --out.
//!   apt_publish write --bucket <b> --distribution <id> --hostname <h> --next <dir> --debs <dir> [--pool-dir pool/mopm]
//!                     [--last] [--out <file>] [--aws <path>]
//!       Uploads each .deb to the product's pool with If-None-Match (a 412 means it exists), writes the signed index with
//!       If-Match on the ETag that was read (If-None-Match for an object that did not exist), and then invalidates /apt/dists/*. The order
//!       is what keeps a reader consistent when the write stops anywhere: the .debs, then the by-hash copy of every Packages and
//!       Packages.gz (`main/binary-<arch>/by-hash/SHA256/<hash>`, If-None-Match; the Release says Acquire-By-Hash: yes), then the plain
//!       Packages files, then Release, Release.gpg and InRelease last. The If-Match of InRelease is the commit point. A 412 on the index means someone else wrote in between:
//!       it appends `conflict=true` to --out and exits 0 so the next attempt reads again; with --last it fails instead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gate = @import("apt_publish/gate.zig");
const state = @import("apt_publish/state.zig");
const awsx = @import("apt_publish/awsx.zig");
const gpgx = @import("apt_publish/gpgx.zig");

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("apt_publish: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usage() noreturn {
    std.debug.print("usage: apt_publish gate|assume|read|index|sign|write ... (see tools/apt_publish.zig)\n", .{});
    std.process.exit(2);
}

const Flag = struct { name: []const u8, value: []const u8 };

fn parseFlags(a: Allocator, args: []const []const u8, with_value: []const []const u8, bare: []const []const u8) ![]Flag {
    var out = std.ArrayList(Flag).init(a);
    var i: usize = 0;
    outer: while (i < args.len) : (i += 1) {
        const arg = args[i];
        for (bare) |b| {
            if (std.mem.eql(u8, arg, b)) {
                try out.append(.{ .name = arg, .value = "" });
                continue :outer;
            }
        }
        for (with_value) |w| {
            if (std.mem.eql(u8, arg, w)) {
                if (i + 1 >= args.len) die("{s} needs a value", .{arg});
                i += 1;
                try out.append(.{ .name = arg, .value = args[i] });
                continue :outer;
            }
        }
        die("unknown argument '{s}'", .{arg});
    }
    return out.items;
}

fn one(flags: []const Flag, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (flags) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            if (found != null) die("{s} given twice", .{name});
            found = f.value;
        }
    }
    return found;
}

fn need(flags: []const Flag, name: []const u8) []const u8 {
    return one(flags, name) orelse die("{s} is required", .{name});
}

fn many(a: Allocator, flags: []const Flag, name: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    for (flags) |f| {
        if (std.mem.eql(u8, f.name, name)) try out.append(f.value);
    }
    return out.items;
}

/// An environment variable that is set and not empty.
fn getenv(a: Allocator, name: []const u8) ?[]const u8 {
    const v = std.process.getEnvVarOwned(a, name) catch return null;
    return if (v.len == 0) null else v;
}

const Ran = struct { ok: bool, stdout: []const u8, stderr: []const u8 };

fn runProc(a: Allocator, argv: []const []const u8) Ran {
    const r = std.process.Child.run(.{ .allocator = a, .argv = argv, .max_output_bytes = 1 << 27 }) catch |err| {
        die("could not run {s}: {s}", .{ argv[0], @errorName(err) });
    };
    return .{ .ok = r.term == .Exited and r.term.Exited == 0, .stdout = r.stdout, .stderr = r.stderr };
}

/// `aws <args...>` with the tool's own words; the program may be another path (the tests give a fake).
fn aws(a: Allocator, exe: []const u8, args: []const []const u8) Ran {
    var argv = std.ArrayList([]const u8).init(a);
    argv.append(exe) catch @panic("oom");
    argv.appendSlice(args) catch @panic("oom");
    return runProc(a, argv.items);
}

fn say(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(fmt, args) catch {};
}

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \r\n\t");
}

fn readFile(a: Allocator, path: []const u8) []u8 {
    return std.fs.cwd().readFileAlloc(a, path, 1 << 30) catch |err| die("cannot read {s}: {s}", .{ path, @errorName(err) });
}

fn writeFileMode(path: []const u8, data: []const u8, mode: std.fs.File.Mode) void {
    const cwd = std.fs.cwd();
    if (std.fs.path.dirname(path)) |d| cwd.makePath(d) catch |err| die("cannot create {s}: {s}", .{ d, @errorName(err) });
    var f = cwd.createFile(path, .{ .mode = mode }) catch |err| die("cannot write {s}: {s}", .{ path, @errorName(err) });
    defer f.close();
    f.writeAll(data) catch |err| die("cannot write {s}: {s}", .{ path, @errorName(err) });
}

fn writeFile(path: []const u8, data: []const u8) void {
    writeFileMode(path, data, 0o644);
}

/// Appends to a file ($GITHUB_OUTPUT, $GITHUB_ENV), creating it.
fn appendFile(path: []const u8, data: []const u8) void {
    var f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch |err| die("cannot open {s}: {s}", .{ path, @errorName(err) });
    defer f.close();
    f.seekFromEnd(0) catch |err| die("cannot seek in {s}: {s}", .{ path, @errorName(err) });
    f.writeAll(data) catch |err| die("cannot write {s}: {s}", .{ path, @errorName(err) });
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// The names of the `.deb` files of a directory, sorted. None is an error: a publish with nothing to publish is a mistake.
fn listDebs(a: Allocator, dir_path: []const u8) []const []const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| die("cannot read {s}: {s}", .{ dir_path, @errorName(err) });
    defer dir.close();
    var out = std.ArrayList([]const u8).init(a);
    var it = dir.iterate();
    while (it.next() catch |err| die("cannot read {s}: {s}", .{ dir_path, @errorName(err) })) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".deb")) out.append(a.dupe(u8, e.name) catch @panic("oom")) catch @panic("oom");
    }
    if (out.items.len == 0) die("no .deb in {s}", .{dir_path});
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out.items;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) usage();
    const cmd = argv[1];
    const rest = argv[2..];
    if (std.mem.eql(u8, cmd, "gate")) return cmdGate(a, rest);
    if (std.mem.eql(u8, cmd, "assume")) return cmdAssume(a, rest);
    if (std.mem.eql(u8, cmd, "read")) return cmdRead(a, rest);
    if (std.mem.eql(u8, cmd, "index")) return cmdIndex(a, rest);
    if (std.mem.eql(u8, cmd, "sign")) return cmdSign(a, rest);
    if (std.mem.eql(u8, cmd, "write")) return cmdWrite(a, rest);
    usage();
}

// ---- gate -------------------------------------------------------------------------------------------------------

fn cmdGate(a: Allocator, args: []const []const u8) !void {
    const flags = try parseFlags(a, args, &.{ "--out", "--label", "--env", "--true" }, &.{});
    var checks = std.ArrayList(gate.Check).init(a);
    for (try many(a, flags, "--env")) |n| try checks.append(.{ .name = n });
    for (try many(a, flags, "--true")) |n| try checks.append(.{ .name = n, .must_be_true = true });
    if (checks.items.len == 0) die("a gate needs at least one --env or --true", .{});
    const label = need(flags, "--label");
    var env = try std.process.getEnvMap(a);
    const v = try gate.evaluate(a, &env, checks.items);
    if (v.enabled) {
        say("{s}: everything it needs is set\n", .{label});
    } else {
        say("{s}", .{try gate.notice(a, label, v.missing)});
    }
    if (one(flags, "--out")) |p| appendFile(p, gate.outputLine(v.enabled));
}

// ---- assume: the OIDC exchange ----------------------------------------------------------------------------------

fn cmdAssume(a: Allocator, args: []const []const u8) !void {
    const flags = try parseFlags(a, args, &.{ "--env-file", "--curl", "--aws" }, &.{});
    const env_file = need(flags, "--env-file");
    const curl = one(flags, "--curl") orelse "curl";
    const aws_exe = one(flags, "--aws") orelse "aws";
    const role = getenv(a, "APT_PUBLISH_ROLE_ARN") orelse die("APT_PUBLISH_ROLE_ARN is not set", .{});
    const req_url = getenv(a, "ACTIONS_ID_TOKEN_REQUEST_URL") orelse die("the runner offers no OIDC token (the job needs `permissions: id-token: write`)", .{});
    const req_token = getenv(a, "ACTIONS_ID_TOKEN_REQUEST_TOKEN") orelse die("the runner offers no OIDC token (the job needs `permissions: id-token: write`)", .{});
    say("::add-mask::{s}\n", .{role});

    const sep: []const u8 = if (std.mem.indexOfScalar(u8, req_url, '?') != null) "&" else "?";
    const bearer = try std.fmt.allocPrint(a, "Authorization: Bearer {s}", .{req_token});
    const full_url = try std.fmt.allocPrint(a, "{s}{s}audience=sts.amazonaws.com", .{ req_url, sep });
    const got = runProc(a, &.{ curl, "-sSf", "-H", bearer, full_url });
    if (!got.ok) die("the OIDC token request failed: {s}", .{trimmed(got.stderr)});
    const jwt = awsx.tokenOf(a, got.stdout) catch |err| die("the OIDC token answer has no value: {s}", .{@errorName(err)});
    say("::add-mask::{s}\n", .{jwt});

    const run_id = getenv(a, "GITHUB_RUN_ID") orelse "0";
    const session = try std.fmt.allocPrint(a, "mopm-apt-{s}", .{run_id});
    const sts = aws(a, aws_exe, &.{ "sts", "assume-role-with-web-identity", "--role-arn", role, "--role-session-name", session, "--web-identity-token", jwt, "--duration-seconds", "3600", "--query", "Credentials", "--output", "json" });
    if (!sts.ok) die("assuming the publish role failed: {s}", .{trimmed(sts.stderr)});
    const creds = awsx.credentialsOf(a, sts.stdout) catch |err| die("the credentials answer is unusable: {s}", .{@errorName(err)});
    say("::add-mask::{s}\n::add-mask::{s}\n::add-mask::{s}\n", .{ creds.access_key_id, creds.secret_access_key, creds.session_token });
    const lines = try std.fmt.allocPrint(a, "AWS_ACCESS_KEY_ID={s}\nAWS_SECRET_ACCESS_" ++ "KEY={s}\nAWS_SESSION_" ++ "TOKEN={s}\n", .{ creds.access_key_id, creds.secret_access_key, creds.session_token });
    appendFile(env_file, lines);
    say("assumed the publish role; the credentials are masked and reach the steps after this one\n", .{});
}

// ---- read -------------------------------------------------------------------------------------------------------

/// Reads one object of the index to `dest`. Returns its ETag, or `-` when there is no such object (NoSuchKey, or AccessDenied: the
/// publish role may not list the bucket, so S3 answers a missing key with AccessDenied; a wrong grant shows at the first write instead).
fn fetch(a: Allocator, aws_exe: []const u8, bucket: []const u8, rel: []const u8, dest: []const u8) []const u8 {
    const key = state.indexKey(a, rel) catch @panic("oom");
    if (std.fs.path.dirname(dest)) |d| std.fs.cwd().makePath(d) catch |err| die("cannot create {s}: {s}", .{ d, @errorName(err) });
    const r = aws(a, aws_exe, &.{ "s3api", "get-object", "--bucket", bucket, "--key", key, dest });
    if (r.ok) {
        return awsx.etagOf(a, r.stdout) catch |err| die("get-object {s}: no ETag in the answer: {s}", .{ key, @errorName(err) });
    }
    switch (awsx.classify(r.stderr)) {
        .not_found, .denied => {
            std.fs.cwd().deleteFile(dest) catch {};
            return state.absent;
        },
        else => die("get-object {s} failed: {s}", .{ key, trimmed(r.stderr) }),
    }
}

fn cmdRead(a: Allocator, args: []const []const u8) !void {
    const flags = try parseFlags(a, args, &.{ "--bucket", "--out", "--aws" }, &.{});
    const bucket = need(flags, "--bucket");
    const out = need(flags, "--out");
    const aws_exe = one(flags, "--aws") orelse "aws";
    const root = try std.fs.path.join(a, &.{ out, "dists", "stable" });
    try std.fs.cwd().makePath(root);

    const release_path = try std.fs.path.join(a, &.{ root, "Release" });
    const release_etag = fetch(a, aws_exe, bucket, "Release", release_path);
    const release_text: []const u8 = if (exists(release_path)) readFile(a, release_path) else "";
    const archs = try state.archsOfRelease(a, release_text);
    const files = try state.indexFiles(a, archs);

    var entries = std.ArrayList(state.Entry).init(a);
    for (files) |rel| {
        const etag = if (std.mem.eql(u8, rel, "Release")) release_etag else fetch(a, aws_exe, bucket, rel, try std.fs.path.join(a, &.{ root, rel }));
        try entries.append(.{ .path = rel, .etag = etag });
        say("read {s}: {s}\n", .{ rel, if (std.mem.eql(u8, etag, state.absent)) "does not exist yet" else etag });
    }
    writeFile(try std.fs.path.join(a, &.{ out, state.etags_file }), try state.renderEtags(a, entries.items));
}

// ---- index ------------------------------------------------------------------------------------------------------

fn cmdIndex(a: Allocator, args: []const []const u8) !void {
    const flags = try parseFlags(a, args, &.{ "--channels", "--current", "--out", "--debs", "--pool-dir", "--origin", "--label", "--description", "--date" }, &.{});
    const channels = need(flags, "--channels");
    const current = need(flags, "--current");
    const out = need(flags, "--out");
    const debs_dir = need(flags, "--debs");
    const pool_dir = one(flags, "--pool-dir") orelse "pool/mopm";
    const date = if (one(flags, "--date")) |d| d else try std.fmt.allocPrint(a, "{d}", .{std.time.timestamp()});
    const etags_in = try std.fs.path.join(a, &.{ current, state.etags_file });
    if (!exists(etags_in)) die("{s} is missing: run `read` first", .{etags_in});

    var argv = std.ArrayList([]const u8).init(a);
    try argv.appendSlice(&.{ channels, "apt-index", "--repo", current, "--out", out, "--date", date, "--origin", need(flags, "--origin"), "--label", need(flags, "--label"), "--description", need(flags, "--description"), "--pool-dir", pool_dir });
    for (listDebs(a, debs_dir)) |name| {
        try argv.append("--deb");
        try argv.append(try std.fs.path.join(a, &.{ debs_dir, name }));
    }
    const r = runProc(a, argv.items);
    if (!r.ok) die("the index was not merged: {s}", .{trimmed(r.stderr)});
    say("{s}", .{r.stderr});
    // The new index was built from exactly the objects whose ETags these are.
    writeFile(try std.fs.path.join(a, &.{ out, state.etags_file }), readFile(a, etags_in));
}

// ---- sign -------------------------------------------------------------------------------------------------------

fn cmdSign(a: Allocator, args: []const []const u8) !void {
    const flags = try parseFlags(a, args, &.{ "--dir", "--work", "--fingerprint", "--gpg", "--out" }, &.{});
    const dir = need(flags, "--dir");
    const gpg = one(flags, "--gpg") orelse "gpg";
    const fpr = gpgx.cleanFingerprint(a, need(flags, "--fingerprint")) catch die("--fingerprint is not a fingerprint", .{});
    const key = getenv(a, "APT_GPG_PRIVATE_KEY") orelse die("APT_GPG_PRIVATE_KEY is not set", .{});
    const pass: []const u8 = std.process.getEnvVarOwned(a, "APT_GPG_PASSPHRASE") catch "";
    const release = try std.fs.path.join(a, &.{ dir, "Release" });
    if (!exists(release)) die("{s} does not exist: nothing to sign", .{release});

    // A private directory (0700) holds the keyring, the key and the passphrase; it is removed whatever happens next.
    const home = try std.fs.path.join(a, &.{ need(flags, "--work"), "gnupg" });
    std.fs.cwd().deleteTree(home) catch {};
    if (std.fs.path.dirname(home)) |d| try std.fs.cwd().makePath(d);
    std.posix.mkdir(home, 0o700) catch |err| die("cannot create {s}: {s}", .{ home, @errorName(err) });
    const key_file = try std.fs.path.join(a, &.{ home, "key.asc" });
    const pass_file = try std.fs.path.join(a, &.{ home, "pass" });
    writeFileMode(key_file, key, 0o600);
    writeFileMode(pass_file, pass, 0o600);

    const in_release = try std.fs.path.join(a, &.{ dir, "InRelease" });
    const detached = try std.fs.path.join(a, &.{ dir, "Release.gpg" });
    const failure = gpgSteps(a, gpg, home, fpr, key_file, pass_file, release, in_release, detached);
    // die() exits without running defers, so the private directory goes here, before anything can fail the process.
    std.fs.cwd().deleteTree(home) catch {};
    if (failure) |msg| die("{s}", .{msg});
    say("signed Release with the subkey {s}: InRelease and Release.gpg verify\n", .{fpr});
    if (one(flags, "--out")) |p| appendFile(p, "signed=true\n");
}

// ---- write ------------------------------------------------------------------------------------------------------

const Put = enum { ok, lost, failed };

/// One conditional put. `cond` is `--if-match <etag>` or `--if-none-match *`.
fn put(a: Allocator, aws_exe: []const u8, bucket: []const u8, key: []const u8, body: []const u8, cond: [2][]const u8) struct { result: Put, stderr: []const u8 } {
    const r = aws(a, aws_exe, &.{ "s3api", "put-object", "--bucket", bucket, "--key", key, "--body", body, cond[0], cond[1] });
    if (r.ok) return .{ .result = .ok, .stderr = "" };
    return .{ .result = if (awsx.classify(r.stderr) == .precondition) .lost else .failed, .stderr = trimmed(r.stderr) };
}

fn cmdWrite(a: Allocator, args: []const []const u8) !void {
    const flags = try parseFlags(a, args, &.{ "--bucket", "--distribution", "--hostname", "--next", "--debs", "--pool-dir", "--out", "--aws" }, &.{"--last"});
    const bucket = need(flags, "--bucket");
    const distribution = need(flags, "--distribution");
    const hostname = need(flags, "--hostname");
    const next = need(flags, "--next");
    const pool_dir = one(flags, "--pool-dir") orelse "pool/mopm";
    const aws_exe = one(flags, "--aws") orelse "aws";
    const last = one(flags, "--last") != null;
    const out = one(flags, "--out");

    const root = try std.fs.path.join(a, &.{ next, "dists", "stable" });
    const release = readFile(a, try std.fs.path.join(a, &.{ root, "Release" }));
    const files = try state.indexFiles(a, try state.archsOfRelease(a, release));
    for (files) |rel| {
        const p = try std.fs.path.join(a, &.{ root, rel });
        if (!exists(p)) die("{s} is missing from the new index: it was not built or not signed", .{p});
    }
    const etags = state.parseEtags(a, readFile(a, try std.fs.path.join(a, &.{ next, state.etags_file }))) catch |err| die("etags.txt: {s}", .{@errorName(err)});

    // The pool first: the index must never list a .deb that is not there. A .deb is never overwritten: a 412 means it exists.
    const debs_dir = need(flags, "--debs");
    for (listDebs(a, debs_dir)) |name| {
        const key = state.poolKey(a, pool_dir, name) catch |err| die("{s}: {s}", .{ name, @errorName(err) });
        const r = put(a, aws_exe, bucket, key, try std.fs.path.join(a, &.{ debs_dir, name }), .{ "--if-none-match", "*" });
        switch (r.result) {
            .ok => say("uploaded {s}\n", .{key}),
            .lost => say("{s} exists already; it is kept as it is\n", .{key}),
            .failed => die("put-object {s} failed: {s}", .{ key, r.stderr }),
        }
    }

    // The by-hash copies of every Packages and Packages.gz, before any plain file of the index changes: the Release lists these files by hash
    // (`Acquire-By-Hash: yes`), so a client that reads the old Release finds the old files by their hashes and one that reads the new Release
    // finds the new ones, whatever part of this write has happened. They are named by their content, so a 412 means the same bytes are there.
    for (files) |rel| {
        if (!state.isPackagesFile(rel)) continue;
        const file_path = try std.fs.path.join(a, &.{ root, rel });
        const hash = state.sha256Hex(readFile(a, file_path));
        const listed = state.releaseHashOf(release, rel) orelse die("the Release lists no hash for {s}", .{rel});
        if (!std.mem.eql(u8, listed, &hash)) die("{s} does not have the hash its Release lists: the index was changed after it was built", .{rel});
        const key = try state.byHashKey(a, rel, &hash);
        const r = put(a, aws_exe, bucket, key, file_path, .{ "--if-none-match", "*" });
        switch (r.result) {
            .ok => say("uploaded {s}\n", .{key}),
            .lost => say("{s} exists already; it is kept as it is\n", .{key}),
            .failed => die("put-object {s} failed: {s}", .{ key, r.stderr }),
        }
    }

    // The index: each object only if it is still the version that was read. The Packages files first, then Release, Release.gpg, and InRelease
    // last: the If-Match of InRelease is the commit point, and a reader that sees the new InRelease finds everything it lists.
    for (files) |rel| {
        const key = try state.indexKey(a, rel);
        const tag = state.etagOf(etags, rel);
        const cond: [2][]const u8 = if (tag == null or std.mem.eql(u8, tag.?, state.absent)) .{ "--if-none-match", "*" } else .{ "--if-match", tag.? };
        const r = put(a, aws_exe, bucket, key, try std.fs.path.join(a, &.{ root, rel }), cond);
        switch (r.result) {
            .ok => say("wrote {s}\n", .{key}),
            .lost => {
                if (last) die("{s} changed while the index was built, and this was the last attempt: nothing more is written", .{key});
                say("::notice title=apt index::{s} changed while the index was built; the next attempt reads it again\n", .{key});
                if (out) |p| appendFile(p, "conflict=true\n");
                return;
            },
            .failed => die("put-object {s} failed: {s}", .{ key, r.stderr }),
        }
    }

    const inv = aws(a, aws_exe, &.{ "cloudfront", "create-invalidation", "--distribution-id", distribution, "--paths", "/apt/dists/*" });
    if (!inv.ok) die("the invalidation of /apt/dists/* failed: {s}", .{trimmed(inv.stderr)});
    say("invalidated /apt/dists/*; the index is at https://{s}/apt/dists/stable/InRelease\n", .{hostname});
    if (out) |p| appendFile(p, "conflict=false\n");
}

/// The gpg half of `sign`: null when everything worked, else the reason. It returns instead of dying so that the caller can
/// remove the private directory first.
fn gpgSteps(a: Allocator, gpg: []const u8, home: []const u8, fpr: []const u8, key_file: []const u8, pass_file: []const u8, release: []const u8, in_release: []const u8, detached: []const u8) ?[]const u8 {
    const Kind = enum { import, list, clear, detach, verify_clear, verify_detached };
    const steps = [_]struct { what: []const u8, kind: Kind }{
        .{ .what = "gpg could not import the key", .kind = .import },
        .{ .what = "the signing key is not among the secret keys that were imported", .kind = .list },
        .{ .what = "gpg could not sign InRelease", .kind = .clear },
        .{ .what = "gpg could not sign Release.gpg", .kind = .detach },
        .{ .what = "InRelease does not verify", .kind = .verify_clear },
        .{ .what = "Release.gpg does not verify", .kind = .verify_detached },
    };
    for (steps) |s| {
        const built = switch (s.kind) {
            .import => gpgx.importArgs(a, gpg, home, key_file),
            .list => gpgx.listArgs(a, gpg, home, fpr),
            .clear => gpgx.clearsignArgs(a, gpg, home, fpr, pass_file, release, in_release),
            .detach => gpgx.detachArgs(a, gpg, home, fpr, pass_file, release, detached),
            .verify_clear => gpgx.verifyClearArgs(a, gpg, home, in_release),
            .verify_detached => gpgx.verifyDetachedArgs(a, gpg, home, detached, release),
        };
        const argv = built catch return "out of memory";
        const r = runProc(a, argv);
        if (!r.ok) return std.fmt.allocPrint(a, "{s}: {s}", .{ s.what, trimmed(r.stderr) }) catch "gpg failed";
    }
    return null;
}
