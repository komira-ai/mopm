//! //:apt_publish: tools/apt_publish.zig, the publish half of the apt channel, run against a fake `aws` (an S3, a CloudFront and an STS whose
//! state is a directory, which refuses what the publish role's grants refuse), a fake `gpg` (a signature is the sha256 of what it covers) and a
//! fake `curl` (the runner's OIDC endpoint). Nothing here reaches a cloud, holds a key or signs anything.
//!
//! What it proves, and the defect each check would catch:
//!   - the order of the writes: the whole of the index is read before anything is written; both .debs are in the pool before the first object of
//!     the index; the by-hash copy of every Packages and Packages.gz (If-None-Match) before any plain file of the index; every Packages and
//!     Packages.gz before Release, Release.gpg and InRelease, which is last (its If-Match is the commit point); the invalidation last;
//!   - a write interrupted after every one of its puts (the fake aws fails the N-th put, for each N) leaves a state in which the Release and the
//!     InRelease that a client can read list only files whose by-hash copy exists with the listed hash, and InRelease is still the old one until
//!     its own put (a reader sees the old Release with the old hashes, or the new Release whose by-hash files already exist);
//!   - a Release that exists keeps its Origin, Label and Description (the repository is shared with other products);
//!   - a put of a .deb that fails for another reason than a 412 fails the job before anything of the index is written; a Release.gpg that does
//!     not verify fails the signing, and nothing is written; a Packages file that is not the one its Release lists is not uploaded;
//!   - If-None-Match on every .deb, so a released .deb is never replaced, and a 412 on one is "exists" only when the object in the pool has the same bytes
//!     (the tool reads it back and compares): other bytes, or an object the role cannot read, fail the write before any object of the index; the
//!     fake refuses a put to the pool without the header, so a tool that dropped it goes red;
//!   - If-Match on the ETag that was READ for every object of an index that exists, If-None-Match for one that does not; the fake refuses an unconditional put
//!     to the index, so a tool that dropped either header goes red;
//!   - the retry: when another writer changes an object between the read and the write, the write loses (412), says so and exits 0 with conflict=true; a second
//!     attempt that reads again and merges again succeeds and keeps the other writer's change; the last attempt fails instead;
//!   - another product's packages in the index survive the merge, and the .debs are listed below the product's own pool directory;
//!   - the signature: made with exactly the subkey (`<fpr>!`), the passphrase never in an argument, the key and the passphrase only in files of a private
//!     directory that is gone afterwards, even when signing fails; an unsigned index is not written;
//!   - a missing key answered with AccessDenied (the role may not list) is treated as absent;
//!   - the gate: any missing name closes it, with a notice and enabled=false, exit 0, and its notice never holds a value;
//!   - the OIDC exchange: the token request asks for the audience, the credentials are masked and written as AWS_* lines, and every later call of the
//!     tool carries them; a failing token request or role fails.
//! Each refusal injects one defect in an otherwise good scenario, and the good scenario must pass first.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

const fpr = "ABCDEF0123456789ABCDEF0123456789ABCDEF01";
const fpr2 = "0123456789ABCDEF0123456789ABCDEF01234567";
const key_text = "fake key material, not a key\n";
const passphrase = "correct-horse-battery";
const role = "role-for-the-tests";
const oidc_token = "oidc-request-token";
const date = "1700000000";
const bucket = "test-bucket";

const Tools = struct { apt: []const u8, aws: []const u8, gpg: []const u8, curl: []const u8, channels: []const u8 };

const World = struct {
    a: Allocator,
    t: Tools,
    root: []const u8,

    fn path(w: World, name: []const u8) []const u8 {
        return h.join(w.a, &.{ w.root, name }) catch @panic("oom");
    }
    fn read(w: World, name: []const u8) []const u8 {
        return h.readFile(w.a, w.path(name)) catch "";
    }
    fn has(w: World, name: []const u8) bool {
        std.fs.cwd().access(w.path(name), .{}) catch return false;
        return true;
    }
    fn put(w: World, name: []const u8, data: []const u8) !void {
        try h.writeFile(w.path(name), data);
    }
    fn awsLog(w: World) []const u8 {
        return w.read("aws/log");
    }

    /// The environment of a job step: the fakes' settings, the OIDC endpoint, the role, and the key (the secrets are in the environment of the one step that reads them).
    fn env(w: World) !std.process.EnvMap {
        var e = try h.environ(w.a);
        try e.put("FAKE_AWS_DIR", w.path("aws"));
        try e.put("FAKE_AWS_BUCKET", bucket);
        try e.put("FAKE_AWS_ROLE", role);
        try e.put("FAKE_GPG_DIR", w.path("gpg"));
        try e.put("FAKE_GPG_KEY", key_text);
        try e.put("FAKE_GPG_FPR", fpr);
        try e.put("FAKE_GPG_PASS", passphrase);
        try e.put("FAKE_OIDC_TOKEN", oidc_token);
        try e.put("ACTIONS_ID_TOKEN_REQUEST_URL", "https://token.example.test/request?api-version=2");
        try e.put("ACTIONS_ID_TOKEN_REQUEST_TOKEN", oidc_token);
        try e.put("APT_PUBLISH_ROLE_ARN", role);
        try e.put("APT_GPG_PRIVATE_KEY", key_text);
        try e.put("APT_GPG_PASSPHRASE", passphrase);
        try e.put("GITHUB_RUN_ID", "42");
        return e;
    }

    fn runEnv(w: World, e: *std.process.EnvMap, args: []const []const u8) !h.Ran {
        var argv = std.ArrayList([]const u8).init(w.a);
        try argv.append(w.t.apt);
        try argv.appendSlice(args);
        return h.run(w.a, argv.items, e, .{});
    }

    fn run(w: World, args: []const []const u8) !h.Ran {
        var e = try w.env();
        return w.runEnv(&e, args);
    }

    /// The environment after the OIDC exchange: the AWS_* lines it wrote to the env file, as GitHub passes them to the next steps.
    fn credEnv(w: World) !std.process.EnvMap {
        var e = try w.env();
        var lines = std.mem.splitScalar(u8, w.read("github_env"), '\n');
        while (lines.next()) |l| {
            const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
            try e.put(l[0..eq], l[eq + 1 ..]);
        }
        return e;
    }

    /// A .deb of mopm made by `channels deb-package`, as the build makes it.
    fn deb(w: World, dir: []const u8, version: []const u8, arch: []const u8) !void {
        try w.put("mopm-bin", "a binary\n");
        const out = try h.fmt(w.a, "{s}/mopm_{s}_{s}.deb", .{ w.path(dir), version, arch });
        try std.fs.cwd().makePath(w.path(dir));
        var e = try h.environ(w.a);
        const r = try h.run(w.a, &.{ w.t.channels, "deb-package", "--binary", w.path("mopm-bin"), "--name", "mopm", "--version", version, "--arch", arch, "--packaging", "packaging/deb", "--out", out }, &e, .{});
        if (r.code != 0) {
            std.debug.print("channels deb-package failed: {s}\n", .{r.text});
            return error.ToolFailed;
        }
    }

    /// A data-only .deb of architecture all (the keyring's shape), made by `channels deb-data`.
    fn dataDeb(w: World, dir: []const u8, version: []const u8) !void {
        try w.put("keyring.gpg", "binary keyring bytes\n");
        const out = try h.fmt(w.a, "{s}/sample-keyring_{s}_all.deb", .{ w.path(dir), version });
        try std.fs.cwd().makePath(w.path(dir));
        var e = try h.environ(w.a);
        const r = try h.run(w.a, &.{ w.t.channels, "deb-data", "--name", "sample-keyring", "--version", version, "--packaging", "packaging/deb", "--file", try h.fmt(w.a, "644:usr/share/keyrings/sample-keyring.gpg:{s}", .{w.path("keyring.gpg")}), "--out", out }, &e, .{});
        if (r.code != 0) {
            std.debug.print("channels deb-data failed: {s}\n", .{r.text});
            return error.ToolFailed;
        }
    }

    /// `read`, `index`, `sign`, `write` in turn, as the jobs run them, stopping at the first that fails. `tag` names the directories of this attempt.
    fn pipeline(w: World, tag: []const u8, debs: []const u8, last: bool, stop_before_sign: bool) !Pipeline {
        const a = w.a;
        var e = try w.credEnv();
        const cur = try h.fmt(a, "{s}_current", .{tag});
        const next = try h.fmt(a, "{s}_next", .{tag});
        const gho = try h.fmt(a, "{s}_output", .{tag});
        var r = try w.runEnv(&e, &.{ "read", "--aws", w.t.aws, "--bucket", bucket, "--out", w.path(cur) });
        if (r.code != 0) return .{ .stage = "read", .ran = r, .gho = gho };
        r = try w.runEnv(&e, &.{ "index", "--channels", w.t.channels, "--current", w.path(cur), "--out", w.path(next), "--debs", w.path(debs), "--origin", "owner", "--label", "owner", "--description", "owner packages", "--date", date });
        if (r.code != 0) return .{ .stage = "index", .ran = r, .gho = gho };
        if (stop_before_sign) return .{ .stage = "unsigned", .ran = r, .gho = gho };
        r = try w.runEnv(&e, &.{ "sign", "--gpg", w.t.gpg, "--dir", try h.fmt(a, "{s}/dists/stable", .{w.path(next)}), "--work", w.path("work"), "--fingerprint", fpr, "--out", w.path(gho) });
        if (r.code != 0) return .{ .stage = "sign", .ran = r, .gho = gho };
        var argv = std.ArrayList([]const u8).init(a);
        try argv.appendSlice(&.{ "write", "--aws", w.t.aws, "--bucket", bucket, "--distribution", "DISTID", "--hostname", "packages.example.test", "--next", w.path(next), "--debs", w.path(debs), "--out", w.path(gho) });
        if (last) try argv.append("--last");
        r = try w.runEnv(&e, argv.items);
        return .{ .stage = "write", .ran = r, .gho = gho };
    }
};

const Pipeline = struct { stage: []const u8, ran: h.Ran, gho: []const u8 };

fn lineNo(log: []const u8, needles: []const []const u8) ?usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |l| : (n += 1) {
        var all = true;
        for (needles) |x| {
            if (std.mem.indexOf(u8, l, x) == null) all = false;
        }
        if (all) return n;
    }
    return null;
}

fn lastLineNo(log: []const u8, needles: []const []const u8) ?usize {
    var n: usize = 0;
    var found: ?usize = null;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |l| : (n += 1) {
        var all = true;
        for (needles) |x| {
            if (std.mem.indexOf(u8, l, x) == null) all = false;
        }
        if (all) found = n;
    }
    return found;
}

fn count(log: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, log, needle);
}

fn before(x: ?usize, y: ?usize) bool {
    return x != null and y != null and x.? < y.?;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

/// What a client sees in the store of the fake S3: is every Packages and Packages.gz that the Release `name` (Release or InRelease) lists also there
/// by its hash, with exactly the listed hash? Null when it is, else what is wrong. A client that reads `name` and then fetches by hash must succeed.
fn byHashProblem(w: World, name: []const u8) ?[]const u8 {
    const text = w.read(h.fmt(w.a, "aws/store/apt/dists/stable/{s}", .{name}) catch @panic("oom"));
    if (text.len == 0) return "the file is not there";
    var listed: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] != ' ') continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const hash = words.next() orelse continue;
        _ = words.next() orelse continue;
        const path = words.next() orelse continue;
        if (!std.mem.endsWith(u8, path, "/Packages") and !std.mem.endsWith(u8, path, "/Packages.gz")) continue;
        listed += 1;
        const dir = std.fs.path.dirname(path) orelse return "a listed path has no directory";
        const body = w.read(h.fmt(w.a, "aws/store/apt/dists/stable/{s}/by-hash/SHA256/{s}", .{ dir, hash }) catch @panic("oom"));
        if (body.len == 0) return h.fmt(w.a, "{s} lists {s} with hash {s}, which has no by-hash file", .{ name, path, hash }) catch @panic("oom");
        if (!std.mem.eql(u8, &sha256Hex(body), hash)) return h.fmt(w.a, "{s}: the by-hash file of {s} does not hash to {s}", .{ name, path, hash }) catch @panic("oom");
    }
    if (listed != 4) return h.fmt(w.a, "{s} lists {d} Packages files, not 4", .{ name, listed }) catch @panic("oom");
    return null;
}

const foreign_packages =
    "Package: other\nVersion: 2.0.0\nArchitecture: amd64\nMaintainer: someone <someone@example.test>\n" ++
    "Filename: pool/other/other_2.0.0_amd64.deb\nSize: 100\nSHA256: 0000000000000000000000000000000000000000000000000000000000000001\nDescription: another product\n";

test "apt_publish: gate, OIDC exchange, read, index, sign, write, with every known defect refused" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = Tools{
        .apt = try h.toolPath(a, "MOPM_APT_PUBLISH"),
        .aws = try h.toolPath(a, "MOPM_FAKE_AWS"),
        .gpg = try h.toolPath(a, "MOPM_FAKE_GPG"),
        .curl = try h.toolPath(a, "MOPM_FAKE_CURL"),
        .channels = try h.toolPath(a, "MOPM_CHANNELS"),
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rep = h.Report{};
    var n: usize = 0;

    // ---- the gate: a job whose settings are not made does nothing and ends green ------------------------
    {
        n += 1;
        const w = World{ .a = a, .t = t, .root = try h.join(a, &.{ try h.tmpPath(a, &tmp), try h.fmt(a, "gate{d}", .{n}) }) };
        try std.fs.cwd().makePath(w.path("aws"));
        var e = try w.env();
        const names = [_][]const u8{ "APT_PUBLISH_ROLE_ARN", "APT_BUCKET", "APT_DISTRIBUTION_ID", "APT_HOSTNAME" };
        try e.put("APT_BUCKET", "b");
        try e.put("APT_DISTRIBUTION_ID", "d");
        try e.put("APT_HOSTNAME", "host");
        const gate_args = [_][]const u8{ "gate", "--label", "apt publish", "--out", w.path("gho"), "--env", names[0], "--env", names[1], "--env", names[2], "--env", names[3] };
        var r = try w.runEnv(&e, &gate_args);
        rep.check("gate: all four variables set opens it", r.code == 0 and std.mem.eql(u8, w.read("gho"), "enabled=true\n"), r.text);
        for (names) |name| {
            n += 1;
            var e2 = try w.env();
            try e2.put("APT_BUCKET", "b");
            try e2.put("APT_DISTRIBUTION_ID", "d");
            try e2.put("APT_HOSTNAME", "host");
            e2.remove(name);
            const out = try h.fmt(a, "gho_missing_{d}", .{n});
            const args = [_][]const u8{ "gate", "--label", "apt publish", "--out", w.path(out), "--env", names[0], "--env", names[1], "--env", names[2], "--env", names[3] };
            r = try w.runEnv(&e2, &args);
            rep.check(try h.fmt(a, "gate: {s} missing closes it: exit 0, enabled=false, a notice that names it", .{name}), r.code == 0 and std.mem.eql(u8, w.read(out), "enabled=false\n") and h.contains(r.text, "::notice") and h.contains(r.text, name), r.text);
        }
        // The empty string is not set (an unset GitHub variable arrives as an empty one).
        var e3 = try w.env();
        try e3.put("APT_BUCKET", "");
        try e3.put("APT_DISTRIBUTION_ID", "d");
        try e3.put("APT_HOSTNAME", "host");
        r = try w.runEnv(&e3, &gate_args);
        rep.check("gate: an empty value is not set", r.code == 0 and h.contains(r.text, "APT_BUCKET"), r.text);
        // The notice names, it never prints a value.
        var e4 = try w.env();
        try e4.put("APT_DISTRIBUTION_ID", "secret-looking-value");
        e4.remove("APT_BUCKET");
        r = try w.runEnv(&e4, &gate_args);
        rep.check("gate: the notice does not print any value", r.code == 0 and !h.contains(r.text, "secret-looking-value") and !h.contains(r.text, role), r.text);
        // --true: exactly `true`.
        var e5 = try w.env();
        try e5.put("FLAG", "true");
        try e5.put("OFF", "false");
        r = try w.runEnv(&e5, &.{ "gate", "--label", "x", "--out", w.path("gho_true"), "--true", "FLAG" });
        rep.check("gate --true: the value true opens it", r.code == 0 and std.mem.eql(u8, w.read("gho_true"), "enabled=true\n"), r.text);
        r = try w.runEnv(&e5, &.{ "gate", "--label", "x", "--out", w.path("gho_false"), "--true", "OFF" });
        rep.check("gate --true: the value false closes it", r.code == 0 and std.mem.eql(u8, w.read("gho_false"), "enabled=false\n"), r.text);
        r = try w.runEnv(&e5, &.{ "gate", "--label", "x" });
        rep.check("gate: a gate that checks nothing is refused", r.code != 0, r.text);
        rep.check("gate: nothing was called (no cloud, no log)", !w.has("aws/log"), w.awsLog());
    }

    // ---- the OIDC exchange -------------------------------------------------------------------------------
    {
        n += 1;
        const w = World{ .a = a, .t = t, .root = try h.join(a, &.{ try h.tmpPath(a, &tmp), try h.fmt(a, "assume{d}", .{n}) }) };
        try std.fs.cwd().makePath(w.path("aws"));
        var r = try w.run(&.{ "assume", "--env-file", w.path("github_env"), "--curl", t.curl, "--aws", t.aws });
        const envf = w.read("github_env");
        rep.check("assume: writes the three AWS_* lines for the next steps", r.code == 0 and h.contains(envf, "AWS_ACCESS_KEY_ID=ASIAFAKEKEYID\n") and h.contains(envf, "AWS_SECRET_ACCESS_" ++ "KEY=fakesecretaccesskey\n") and h.contains(envf, "AWS_SESSION_" ++ "TOKEN=fakesessiontoken\n"), r.text);
        rep.check("assume: masks the token and the credentials", h.contains(r.text, "::add-mask::fake.jwt.token") and h.contains(r.text, "::add-mask::fakesecretaccesskey") and h.contains(r.text, "::add-mask::fakesessiontoken"), r.text);
        rep.check("assume: asks for the audience sts.amazonaws.com, with the bearer token, and the role by the variable", h.contains(w.awsLog(), "audience=sts.amazonaws.com") and h.contains(w.awsLog(), "--role-arn role-for-the-tests") and h.contains(w.awsLog(), "--role-session-name mopm-apt-42"), w.awsLog());
        rep.check("assume: the credentials are not printed unmasked as a line of their own", !h.hasLine(r.text, "AWS_SECRET_ACCESS_" ++ "KEY=fakesecretaccesskey"), r.text);

        var e = try w.env();
        e.remove("ACTIONS_ID_TOKEN_REQUEST_URL");
        r = try w.runEnv(&e, &.{ "assume", "--env-file", w.path("github_env2"), "--curl", t.curl, "--aws", t.aws });
        rep.check("assume: a job without id-token: write (no request URL) fails and writes nothing", r.code != 0 and h.contains(r.text, "id-token") and !w.has("github_env2"), r.text);
        e = try w.env();
        try e.put("FAKE_OIDC_TOKEN", "another");
        r = try w.runEnv(&e, &.{ "assume", "--env-file", w.path("github_env3"), "--curl", t.curl, "--aws", t.aws });
        rep.check("assume: a refused token request fails and writes nothing", r.code != 0 and !w.has("github_env3"), r.text);
        e = try w.env();
        try e.put("FAKE_AWS_ROLE", "some-other-role");
        r = try w.runEnv(&e, &.{ "assume", "--env-file", w.path("github_env4"), "--curl", t.curl, "--aws", t.aws });
        rep.check("assume: a role that refuses the exchange fails and writes nothing", r.code != 0 and !w.has("github_env4"), r.text);
        e = try w.env();
        e.remove("APT_PUBLISH_ROLE_ARN");
        r = try w.runEnv(&e, &.{ "assume", "--env-file", w.path("github_env5"), "--curl", t.curl, "--aws", t.aws });
        rep.check("assume: no role variable fails", r.code != 0 and !w.has("github_env5"), r.text);
    }

    // ---- the first publish: an empty repository ------------------------------------------------------------
    {
        n += 1;
        const w = World{ .a = a, .t = t, .root = try h.join(a, &.{ try h.tmpPath(a, &tmp), try h.fmt(a, "first{d}", .{n}) }) };
        try std.fs.cwd().makePath(w.path("aws"));
        try std.fs.cwd().makePath(w.path("gpg"));
        try w.deb("debs", "1.2.3", "amd64");
        try w.deb("debs", "1.2.3", "arm64");
        const r = try w.run(&.{ "assume", "--env-file", w.path("github_env"), "--curl", t.curl, "--aws", t.aws });
        rep.check("first: the OIDC exchange works", r.code == 0, r.text);
        const p = try w.pipeline("one", "debs", false, false);
        rep.check("first: read, index, sign and write all succeed", std.mem.eql(u8, p.stage, "write") and p.ran.code == 0, p.ran.text);
        const log = w.awsLog();
        const read_release = lineNo(log, &.{ "get-object", "apt/dists/stable/Release" });
        const first_put = lineNo(log, &.{"put-object"});
        const pool_amd = lineNo(log, &.{ "put-object", "--key apt/pool/mopm/mopm_1.2.3_amd64.deb", "--if-none-match *" });
        const pool_arm = lineNo(log, &.{ "put-object", "--key apt/pool/mopm/mopm_1.2.3_arm64.deb", "--if-none-match *" });
        const first_dists = lineNo(log, &.{ "put-object", "--key apt/dists/" });
        const rel_put = lineNo(log, &.{ "put-object", "--key apt/dists/stable/Release " });
        const inrel_put = lineNo(log, &.{ "put-object", "--key apt/dists/stable/InRelease " });
        const gpg_put = lineNo(log, &.{ "put-object", "--key apt/dists/stable/Release.gpg " });
        const last_packages = lastLineNo(log, &.{ "put-object", "--key apt/dists/stable/main/binary-arm64/Packages.gz " });
        const first_byhash = lineNo(log, &.{ "put-object", "/by-hash/SHA256/", "--if-none-match *" });
        const last_byhash = lastLineNo(log, &.{ "put-object", "/by-hash/SHA256/" });
        const first_plain = lineNo(log, &.{ "put-object", "--key apt/dists/stable/main/binary-amd64/Packages " });
        const invalidation = lineNo(log, &.{ "create-invalidation", "--distribution-id DISTID", "--paths /apt/dists/*" });
        rep.check("first: the index is read from S3 before anything is written", before(read_release, first_put), log);
        rep.check("first: every Packages and Packages.gz is read, so every ETag is known", count(log, "get-object") == 7, log);
        rep.check("first: both .debs are in the pool, with If-None-Match, before the first object of the index", before(pool_amd, first_dists) and before(pool_arm, first_dists), log);
        rep.check("first: Release is written after every Packages file, then Release.gpg, and InRelease last (the commit point)", before(last_packages, rel_put) and before(rel_put, gpg_put) and before(gpg_put, inrel_put), log);
        rep.check("first: the by-hash copy of every Packages and Packages.gz (4 of them, If-None-Match) is written after the .debs and before any plain file of the index", count(log, "/by-hash/SHA256/") == 4 and before(pool_amd, first_byhash) and before(pool_arm, first_byhash) and before(last_byhash, first_plain), log);
        rep.check("first: the by-hash keys are below the binary-<arch> directory of the file and named by the sha256 the Release lists", h.contains(log, "--key apt/dists/stable/main/binary-amd64/by-hash/SHA256/") and h.contains(log, "--key apt/dists/stable/main/binary-arm64/by-hash/SHA256/"), log);
        rep.check("first: the invalidation of /apt/dists/* comes last, once", before(inrel_put, invalidation) and count(log, "create-invalidation") == 1, log);
        rep.check("first: nothing existed, so every object of the index is created with If-None-Match (7 plain and 4 by-hash), none with If-Match", count(log, "--key apt/dists/") - count(log, "get-object") == 11 and count(log, "--if-none-match *") == 13 and count(log, "--if-match") == 0, log);
        rep.check("first: every S3 and CloudFront call carries the credentials of the exchange", count(log, "| key=ASIAFAKEKEYID") == count(log, "s3api") + count(log, "cloudfront") and count(log, "s3api") > 0, log);
        const inrelease = w.read("aws/store/apt/dists/stable/InRelease");
        const release = w.read("aws/store/apt/dists/stable/Release");
        rep.check("first: the Release says Acquire-By-Hash: yes and carries the Origin, Label and Description it was first given", h.contains(release, "Acquire-By-Hash: yes\n") and h.contains(release, "Origin: owner\nLabel: owner\n") and h.contains(release, "Description: owner packages\n"), release);
        for ([_][]const u8{ "amd64", "arm64" }) |arch| {
            for ([_][]const u8{ "Packages", "Packages.gz" }) |name| {
                const body = w.read(try h.fmt(a, "aws/store/apt/dists/stable/main/binary-{s}/{s}", .{ arch, name }));
                const by = w.read(try h.fmt(a, "aws/store/apt/dists/stable/main/binary-{s}/by-hash/SHA256/{s}", .{ arch, sha256Hex(body) }));
                rep.check(try h.fmt(a, "first: the by-hash copy of {s}/{s} holds the same bytes", .{ arch, name }), body.len > 0 and std.mem.eql(u8, body, by), "");
            }
        }
        rep.check("first: InRelease is the Release signed with the subkey and Release.gpg signs the same bytes", release.len > 0 and h.contains(inrelease, release) and h.contains(inrelease, "key=" ++ fpr ++ "!") and h.contains(w.read("aws/store/apt/dists/stable/Release.gpg"), "key=" ++ fpr ++ "!"), inrelease);
        const packages = w.read("aws/store/apt/dists/stable/main/binary-amd64/Packages");
        rep.check("first: the .deb is listed below the product's pool directory, not pool/main", h.contains(packages, "Filename: pool/mopm/mopm_1.2.3_amd64.deb\n") and !h.contains(packages, "pool/main"), packages);
        rep.check("first: the outputs say there was no conflict", h.contains(w.read(p.gho), "signed=true\n") and h.contains(w.read(p.gho), "conflict=false\n"), w.read(p.gho));
        rep.check("first: the fake pool holds both .debs", w.has("aws/store/apt/pool/mopm/mopm_1.2.3_amd64.deb") and w.has("aws/store/apt/pool/mopm/mopm_1.2.3_arm64.deb"), "");

        // The signing: no secret in an argument, no secret left on disk.
        const glog = w.read("gpg/log");
        rep.check("sign: the passphrase and the key are in no gpg argument", glog.len > 0 and !h.contains(glog, passphrase) and !h.contains(glog, "fake key material") and h.contains(glog, "--passphrase-file") and h.contains(glog, "--local-user " ++ fpr ++ "!"), glog);
        var gone = true;
        var homes = std.mem.splitScalar(u8, w.read("gpg/homes"), '\n');
        var seen_homes: usize = 0;
        while (homes.next()) |hm| {
            if (hm.len == 0) continue;
            seen_homes += 1;
            std.fs.cwd().access(hm, .{}) catch continue;
            gone = false;
        }
        rep.check("sign: the private directory of the key and the passphrase is gone afterwards", seen_homes > 0 and gone, w.read("gpg/homes"));
        rep.check("sign: the tool never prints the passphrase or the key", !h.contains(p.ran.text, passphrase) and !h.contains(p.ran.text, "fake key material"), p.ran.text);

        // ---- the second publish: the index exists, and another product is in it -----------------------------------
        // Another product's package joins the amd64 Packages that mopm wrote, as if it published in between.
        const merged = try std.mem.concat(a, u8, &.{ packages, "\n", foreign_packages });
        try w.put("aws/store/apt/dists/stable/main/binary-amd64/Packages", merged);
        try w.put("aws/etag/apt/dists/stable/main/binary-amd64/Packages", "\"other-writer\"");
        try w.deb("debs2", "1.2.4", "amd64");
        try w.deb("debs2", "1.2.4", "arm64");
        // The repository is shared: the Release that is there carries the Origin, Label and Description of another product.
        {
            var rel_text = w.read("aws/store/apt/dists/stable/Release");
            rel_text = try std.mem.replaceOwned(u8, a, rel_text, "Origin: owner\nLabel: owner\n", "Origin: Shared Co\nLabel: Shared Label\n");
            rel_text = try std.mem.replaceOwned(u8, a, rel_text, "Description: owner packages\n", "Description: Shared description\n");
            try w.put("aws/store/apt/dists/stable/Release", rel_text);
        }
        const etag_release = w.read("aws/etag/apt/dists/stable/Release");
        const before_log = w.awsLog().len;
        const p2 = try w.pipeline("two", "debs2", false, false);
        const log2 = w.awsLog()[before_log..];
        rep.check("second: the publish succeeds", std.mem.eql(u8, p2.stage, "write") and p2.ran.code == 0, p2.ran.text);
        const rel2 = try h.fmt(a, "--key apt/dists/stable/Release --body", .{});
        const want_match = try h.fmt(a, "--if-match {s}", .{etag_release});
        rep.check("second: Release is replaced with If-Match on the ETag that was read", lineNo(log2, &.{ "put-object", rel2, want_match }) != null, log2);
        rep.check("second: the Packages that another writer changed is replaced with If-Match on THAT ETag", lineNo(log2, &.{ "put-object", "--key apt/dists/stable/main/binary-amd64/Packages ", "--if-match \"other-writer\"" }) != null, log2);
        rep.check("second: nothing of the plain index is created again (If-None-Match on dists/ only for the 4 new by-hash files)", count(log2, "--key apt/dists/") - count(log2, "get-object") == 11 and count(log2, "/by-hash/SHA256/") == 4 and count(log2, "--if-none-match *") == 2 + 4, log2);
        const release2 = w.read("aws/store/apt/dists/stable/Release");
        rep.check("second: the Release that is there keeps its Origin, Label and Description: mopm's flags do not overwrite another product's", h.contains(release2, "Origin: Shared Co\nLabel: Shared Label\n") and h.contains(release2, "Description: Shared description\n") and !h.contains(release2, "Origin: owner") and !h.contains(release2, "owner packages"), release2);
        rep.check("second: and the signed InRelease carries them too", h.contains(w.read("aws/store/apt/dists/stable/InRelease"), "Origin: Shared Co\nLabel: Shared Label\n"), "");
        rep.check("second: each .deb is still put with If-None-Match", count(log2, "--key apt/pool/mopm/") == 2, log2);
        const packages2 = w.read("aws/store/apt/dists/stable/main/binary-amd64/Packages");
        rep.check("second: both mopm versions and the other product are listed", h.contains(packages2, "Version: 1.2.4") and h.contains(packages2, "Version: 1.2.3") and h.contains(packages2, "Package: other\n") and h.contains(packages2, "Filename: pool/other/other_2.0.0_amd64.deb"), packages2);

        // ---- 412: another writer changes the Release between the read and the write ---------------------------
        try w.deb("debs3", "1.2.5", "amd64");
        try w.deb("debs3", "1.2.5", "arm64");
        try w.put("aws/bump_after_get", "apt/dists/stable/Release\n");
        const p3 = try w.pipeline("three", "debs3", false, false);
        rep.check("conflict: the losing write exits 0 and says conflict=true", std.mem.eql(u8, p3.stage, "write") and p3.ran.code == 0 and h.contains(w.read(p3.gho), "conflict=true\n") and !h.contains(w.read(p3.gho), "conflict=false"), p3.ran.text);
        rep.check("conflict: it says why", h.contains(p3.ran.text, "changed while the index was built"), p3.ran.text);
        rep.check("conflict: nothing is invalidated on a lost write", count(w.awsLog(), "create-invalidation") == 2, w.awsLog());
        rep.check("conflict: the other writer's Release is still there (nothing overwrote it)", h.contains(w.read("aws/store/apt/dists/stable/Release"), "X-Other-Writer: yes"), w.read("aws/store/apt/dists/stable/Release"));
        const p4 = try w.pipeline("four", "debs3", false, false);
        rep.check("conflict: the next attempt reads again and succeeds", std.mem.eql(u8, p4.stage, "write") and p4.ran.code == 0 and h.contains(w.read(p4.gho), "conflict=false\n"), p4.ran.text);
        const packages4 = w.read("aws/store/apt/dists/stable/main/binary-amd64/Packages");
        rep.check("conflict: and lists all three versions and the other product", h.contains(packages4, "Version: 1.2.5") and h.contains(packages4, "Version: 1.2.4") and h.contains(packages4, "Version: 1.2.3") and h.contains(packages4, "Package: other\n"), packages4);
        rep.check("conflict: the Release written is the new one, not the other writer's", !h.contains(w.read("aws/store/apt/dists/stable/Release"), "X-Other-Writer: yes"), w.read("aws/store/apt/dists/stable/Release"));

        // The last attempt fails instead of asking for another.
        try w.deb("debs5", "1.2.6", "amd64");
        try w.deb("debs5", "1.2.6", "arm64");
        try w.put("aws/bump_after_get", "apt/dists/stable/Release\n");
        const p5 = try w.pipeline("five", "debs5", true, false);
        rep.check("conflict: with --last a lost write fails the job", std.mem.eql(u8, p5.stage, "write") and p5.ran.code != 0 and h.contains(p5.ran.text, "last attempt"), p5.ran.text);
        rep.check("conflict: and does not say conflict=true (there is no next attempt)", !h.contains(w.read(p5.gho), "conflict=true"), w.read(p5.gho));

        // ---- an old version moves nothing -------------------------------------------------------------------
        try w.deb("debs_old", "1.0.0", "amd64");
        try w.deb("debs_old", "1.0.0", "arm64");
        const pold = try w.pipeline("old", "debs_old", false, false);
        rep.check("monotonic: a version older than the newest listed is refused at the merge, before any write", std.mem.eql(u8, pold.stage, "index") and pold.ran.code != 0 and h.contains(pold.ran.text, "move the channel down"), pold.ran.text);
    }

    // ---- a .deb that is already in the pool is kept, not an error ----------------------------------------------
    {
        n += 1;
        const w = World{ .a = a, .t = t, .root = try h.join(a, &.{ try h.tmpPath(a, &tmp), try h.fmt(a, "exists{d}", .{n}) }) };
        try std.fs.cwd().makePath(w.path("aws"));
        try std.fs.cwd().makePath(w.path("gpg"));
        try w.deb("debs", "1.2.3", "amd64");
        try w.deb("debs", "1.2.3", "arm64");
        // The same bytes are already there: it is kept, and the publish goes on.
        const same = w.read("debs/mopm_1.2.3_amd64.deb");
        try w.put("aws/store/apt/pool/mopm/mopm_1.2.3_amd64.deb", same);
        try w.put("aws/etag/apt/pool/mopm/mopm_1.2.3_amd64.deb", "\"old\"");
        _ = try w.run(&.{ "assume", "--env-file", w.path("github_env"), "--curl", t.curl, "--aws", t.aws });
        const p = try w.pipeline("one", "debs", false, false);
        rep.check("exists: a 412 on a .deb of the pool with the same bytes is 'exists', and the publish goes on", std.mem.eql(u8, p.stage, "write") and p.ran.code == 0 and h.contains(p.ran.text, "exists already, with the same bytes"), p.ran.text);
        rep.check("exists: the old .deb was not replaced", std.mem.eql(u8, w.read("aws/store/apt/pool/mopm/mopm_1.2.3_amd64.deb"), same), "");
        rep.check("exists: the other .deb was uploaded", w.has("aws/store/apt/pool/mopm/mopm_1.2.3_arm64.deb"), "");
    }

    // ---- a .deb that is in the pool with other bytes is a failure; one that cannot be read to compare is too -----------------
    {
        n += 1;
        const w = World{ .a = a, .t = t, .root = try h.join(a, &.{ try h.tmpPath(a, &tmp), try h.fmt(a, "differs{d}", .{n}) }) };
        try std.fs.cwd().makePath(w.path("aws"));
        try std.fs.cwd().makePath(w.path("gpg"));
        try w.deb("debs", "1.2.3", "amd64");
        try w.deb("debs", "1.2.3", "arm64");
        try w.put("aws/store/apt/pool/mopm/mopm_1.2.3_amd64.deb", "already there, but not this file\n");
        try w.put("aws/etag/apt/pool/mopm/mopm_1.2.3_amd64.deb", "\"old\"");
        _ = try w.run(&.{ "assume", "--env-file", w.path("github_env"), "--curl", t.curl, "--aws", t.aws });
        const p = try w.pipeline("one", "debs", false, false);
        rep.check("differs: a .deb in the pool with other bytes fails the write, naming the key and both hashes", std.mem.eql(u8, p.stage, "write") and p.ran.code != 0 and h.contains(p.ran.text, "mopm_1.2.3_amd64.deb exists already with different bytes") and h.contains(p.ran.text, "sha256"), p.ran.text);
        rep.check("differs: the pool object was not replaced and no index object was written", std.mem.eql(u8, w.read("aws/store/apt/pool/mopm/mopm_1.2.3_amd64.deb"), "already there, but not this file\n") and !w.has("aws/store/apt/dists/stable/InRelease"), "");
        // The same, when the role may not read the pool: the comparison cannot be made, so the write stops.
        try w.put("aws/deny_pool_get", "");
        const p2 = try w.pipeline("two", "debs", false, false);
        rep.check("differs: a pool object that cannot be read to compare is a failure, not a pass", std.mem.eql(u8, p2.stage, "write") and p2.ran.code != 0 and h.contains(p2.ran.text, "could not be read to compare"), p2.ran.text);
    }

    // ---- a missing key that S3 answers with AccessDenied is absent ---------------------------------------------
    {
        n += 1;
        const w = World{ .a = a, .t = t, .root = try h.join(a, &.{ try h.tmpPath(a, &tmp), try h.fmt(a, "denied{d}", .{n}) }) };
        try std.fs.cwd().makePath(w.path("aws"));
        try std.fs.cwd().makePath(w.path("gpg"));
        try w.put("aws/deny_missing", "");
        try w.deb("debs", "1.2.3", "amd64");
        try w.deb("debs", "1.2.3", "arm64");
        _ = try w.run(&.{ "assume", "--env-file", w.path("github_env"), "--curl", t.curl, "--aws", t.aws });
        const p = try w.pipeline("one", "debs", false, false);
        rep.check("denied: AccessDenied on a key that is not there (no List grant) creates the index with If-None-Match", std.mem.eql(u8, p.stage, "write") and p.ran.code == 0 and w.has("aws/store/apt/dists/stable/Release"), p.ran.text);
        rep.check("denied: the read was refused, not skipped (the fake did answer AccessDenied)", h.contains(w.awsLog(), "get-object"), w.awsLog());
    }

    // ---- the refusals of sign and write ------------------------------------------------------------------------
    {
        n += 1;
        const w = World{ .a = a, .t = t, .root = try h.join(a, &.{ try h.tmpPath(a, &tmp), try h.fmt(a, "refuse{d}", .{n}) }) };
        try std.fs.cwd().makePath(w.path("aws"));
        try std.fs.cwd().makePath(w.path("gpg"));
        try w.deb("debs", "1.2.3", "amd64");
        try w.deb("debs", "1.2.3", "arm64");
        _ = try w.run(&.{ "assume", "--env-file", w.path("github_env"), "--curl", t.curl, "--aws", t.aws });
        const unsigned = try w.pipeline("u", "debs", false, true);
        rep.check("refuse: the unsigned index is built", std.mem.eql(u8, unsigned.stage, "unsigned") and unsigned.ran.code == 0 and w.has("u_next/dists/stable/Release") and !w.has("u_next/dists/stable/InRelease"), unsigned.ran.text);
        var e = try w.credEnv();
        const writeArgs = [_][]const u8{ "write", "--aws", t.aws, "--bucket", bucket, "--distribution", "DISTID", "--hostname", "packages.example.test", "--next", w.path("u_next"), "--debs", w.path("debs"), "--out", w.path("gho_w") };
        var r = try w.runEnv(&e, &writeArgs);
        rep.check("refuse: an index that was not signed is not written, and nothing at all is put (not even the pool)", r.code != 0 and h.contains(r.text, "missing from the new index") and !h.contains(w.awsLog(), "put-object"), r.text);

        const signArgs = [_][]const u8{ "sign", "--gpg", t.gpg, "--dir", w.path("u_next/dists/stable"), "--work", w.path("work"), "--fingerprint", fpr, "--out", w.path("gho_s") };
        // Each defect on its own, from a good run.
        e = try w.credEnv();
        try e.put("FAKE_GPG_KEY", "another key\n");
        r = try w.runEnv(&e, &signArgs);
        rep.check("sign: a key gpg cannot import fails, signs nothing, says nothing of signed=true", r.code != 0 and h.contains(r.text, "import") and !w.has("u_next/dists/stable/InRelease") and !w.has("gho_s"), r.text);
        e = try w.credEnv();
        try e.put("APT_GPG_PASSPHRASE", "wrong passphrase");
        r = try w.runEnv(&e, &signArgs);
        rep.check("sign: a wrong passphrase fails and signs nothing", r.code != 0 and !w.has("u_next/dists/stable/InRelease") and !w.has("gho_s"), r.text);
        rep.check("sign: and the wrong passphrase is not printed", !h.contains(r.text, "wrong passphrase"), r.text);
        e = try w.credEnv();
        try e.put("FAKE_GPG_FPR", "1111111111111111111111111111111111111111");
        r = try w.runEnv(&e, &signArgs);
        rep.check("sign: a fingerprint that is not among the imported secret keys fails", r.code != 0 and !w.has("u_next/dists/stable/InRelease"), r.text);
        e = try w.credEnv();
        e.remove("APT_GPG_PRIVATE_KEY");
        r = try w.runEnv(&e, &signArgs);
        rep.check("sign: no key in the environment fails", r.code != 0 and h.contains(r.text, "APT_GPG_PRIVATE_KEY"), r.text);
        e = try w.credEnv();
        r = try w.runEnv(&e, &.{ "sign", "--gpg", t.gpg, "--dir", w.path("u_next/dists/stable"), "--work", w.path("work"), "--fingerprint", "not-a-fingerprint" });
        rep.check("sign: a fingerprint that is not hex fails", r.code != 0, r.text);
        try w.put("gpg/sign_fail", "");
        e = try w.credEnv();
        r = try w.runEnv(&e, &signArgs);
        rep.check("sign: a gpg that fails to sign fails the job and signs nothing", r.code != 0 and !w.has("u_next/dists/stable/InRelease") and !w.has("gho_s"), r.text);
        var gone = true;
        var homes = std.mem.splitScalar(u8, w.read("gpg/homes"), '\n');
        while (homes.next()) |hm| {
            if (hm.len == 0) continue;
            std.fs.cwd().access(hm, .{}) catch continue;
            gone = false;
        }
        rep.check("sign: the private directory is gone after every failure, too", gone and w.read("gpg/homes").len > 0, w.read("gpg/homes"));
        rep.check("sign: no failure printed the passphrase or the key", !h.contains(r.text, passphrase) and !h.contains(r.text, "fake key material"), r.text);

        // The fakes enforce the role: the calls a variant of the tool would make are refused.
        var e2 = try w.credEnv();
        r = try h.run(a, &.{ t.aws, "s3api", "put-object", "--bucket", bucket, "--key", "apt/dists/stable/Release", "--body", w.path("u_next/dists/stable/Release") }, &e2, .{});
        rep.check("fake aws: an unconditional put to the index is AccessDenied", r.code != 0 and h.contains(r.text, "AccessDenied"), r.text);
        r = try h.run(a, &.{ t.aws, "s3api", "put-object", "--bucket", bucket, "--key", "apt/pool/mopm/x.deb", "--body", w.path("u_next/dists/stable/Release") }, &e2, .{});
        rep.check("fake aws: an unconditional put to the pool is AccessDenied", r.code != 0 and h.contains(r.text, "AccessDenied"), r.text);
        r = try h.run(a, &.{ t.aws, "s3api", "put-object", "--bucket", bucket, "--key", "apt/pool/other/x.deb", "--body", w.path("u_next/dists/stable/Release"), "--if-none-match", "*" }, &e2, .{});
        rep.check("fake aws: a put below another product's pool is AccessDenied", r.code != 0 and h.contains(r.text, "AccessDenied"), r.text);
        r = try h.run(a, &.{ t.aws, "s3api", "get-object", "--bucket", bucket, "--key", "apt/pool/other/x.deb", w.path("x") }, &e2, .{});
        rep.check("fake aws: a get below another product's pool is AccessDenied", r.code != 0 and h.contains(r.text, "AccessDenied"), r.text);
    }

    // ---- two signing keys: one --local-user for each, for InRelease and Release.gpg ------------------------------------------
    {
        n += 1;
        const w = World{ .a = a, .t = t, .root = try h.join(a, &.{ try h.tmpPath(a, &tmp), try h.fmt(a, "twokeys{d}", .{n}) }) };
        try std.fs.cwd().makePath(w.path("aws"));
        try std.fs.cwd().makePath(w.path("gpg"));
        try w.deb("debs", "1.2.3", "amd64");
        try w.deb("debs", "1.2.3", "arm64");
        _ = try w.run(&.{ "assume", "--env-file", w.path("github_env"), "--curl", t.curl, "--aws", t.aws });
        const unsigned = try w.pipeline("u", "debs", false, true);
        rep.check("two keys: the unsigned index is built", std.mem.eql(u8, unsigned.stage, "unsigned") and unsigned.ran.code == 0, unsigned.ran.text);
        const both = fpr ++ "," ++ fpr2;
        const signArgs = [_][]const u8{ "sign", "--gpg", t.gpg, "--dir", w.path("u_next/dists/stable"), "--work", w.path("work"), "--fingerprint", both, "--out", w.path("gho_s") };

        // Each defect on its own, from a good run: a list with a key the key file does not hold, a list in another order than gpg is told, and a list that is not a list.
        var e = try w.credEnv();
        try e.put("FAKE_GPG_FPR", fpr);
        var r = try w.runEnv(&e, &signArgs);
        rep.check("two keys: a second key that is not among the imported secret keys fails, names it, and signs nothing", r.code != 0 and h.contains(r.text, "not among the secret keys") and h.contains(r.text, fpr2) and !w.has("u_next/dists/stable/InRelease") and !w.has("gho_s"), r.text);
        rep.check("two keys: and no signing was attempted (the keys are checked first)", !h.contains(w.read("gpg/log"), "--clearsign") and !h.contains(w.read("gpg/log"), "--detach-sign"), w.read("gpg/log"));
        for ([_][]const u8{ fpr ++ ",", "," ++ fpr, fpr ++ ",," ++ fpr2, fpr ++ "," ++ fpr, fpr ++ ";" ++ fpr2 }) |bad| {
            e = try w.credEnv();
            r = try w.runEnv(&e, &.{ "sign", "--gpg", t.gpg, "--dir", w.path("u_next/dists/stable"), "--work", w.path("work"), "--fingerprint", bad, "--out", w.path("gho_bad") });
            rep.check(try h.fmt(a, "two keys: --fingerprint '{s}' fails and signs nothing", .{bad}), r.code != 0 and h.contains(r.text, "--fingerprint") and !w.has("u_next/dists/stable/InRelease") and !w.has("gho_bad"), r.text);
        }
        e = try w.credEnv();
        try e.put("FAKE_GPG_FPR", fpr2 ++ "," ++ fpr);
        r = try w.runEnv(&e, &signArgs);
        rep.check("two keys: the keys are given to gpg in the order of the list (another order is refused by the fake)", r.code != 0 and !w.has("u_next/dists/stable/InRelease"), r.text);

        e = try w.credEnv();
        try e.put("FAKE_GPG_FPR", both);
        try w.put("gpg/log", ""); // only the good run's calls from here on
        r = try w.runEnv(&e, &signArgs);
        rep.check("two keys: the signing succeeds, says how many keys, and outputs signed=true", r.code == 0 and h.contains(r.text, "2 subkey(s)") and h.contains(w.read("gho_s"), "signed=true"), r.text);
        const inrelease = w.read("u_next/dists/stable/InRelease");
        const detached = w.read("u_next/dists/stable/Release.gpg");
        rep.check("two keys: InRelease is signed with both keys", h.contains(inrelease, "key=" ++ fpr ++ "!," ++ fpr2 ++ "!"), inrelease);
        rep.check("two keys: Release.gpg is signed with both keys", h.contains(detached, "key=" ++ fpr ++ "!," ++ fpr2 ++ "!"), detached);
        const glog = w.read("gpg/log");
        rep.check("two keys: the clear and the detached signing each carry one --local-user per key", count(glog, "--local-user " ++ fpr ++ "! --local-user " ++ fpr2 ++ "! --armor --clearsign") == 1 and count(glog, "--local-user " ++ fpr ++ "! --local-user " ++ fpr2 ++ "! --armor --detach-sign") == 1, glog);
        rep.check("two keys: and both keys were looked up among the secret keys", count(glog, "--list-secret-keys --with-colons " ++ fpr ++ "\n") >= 1 and count(glog, "--list-secret-keys --with-colons " ++ fpr2 ++ "\n") >= 1, glog);
        // The signed index is then written as any other.
        var argv = std.ArrayList([]const u8).init(a);
        try argv.appendSlice(&.{ "write", "--aws", t.aws, "--bucket", bucket, "--distribution", "DISTID", "--hostname", "packages.example.test", "--next", w.path("u_next"), "--debs", w.path("debs"), "--out", w.path("gho_w") });
        e = try w.credEnv();
        r = try w.runEnv(&e, argv.items);
        rep.check("two keys: the index signed by both writes", r.code == 0 and h.contains(w.read("aws/store/apt/dists/stable/InRelease"), "key=" ++ fpr ++ "!," ++ fpr2 ++ "!"), r.text);
    }

    // ---- an all package in the shared index, and the next product's publish over it ----------------------------------------------
    {
        n += 1;
        const w = World{ .a = a, .t = t, .root = try h.join(a, &.{ try h.tmpPath(a, &tmp), try h.fmt(a, "allarch{d}", .{n}) }) };
        try std.fs.cwd().makePath(w.path("aws"));
        try std.fs.cwd().makePath(w.path("gpg"));
        try w.dataDeb("kdebs", "2026.10.21");
        try w.deb("debs", "1.2.3", "amd64");
        try w.deb("debs", "1.2.3", "arm64");
        _ = try w.run(&.{ "assume", "--env-file", w.path("github_env"), "--curl", t.curl, "--aws", t.aws });
        const first = try w.pipeline("k", "kdebs", true, false);
        rep.check("all: a package of architecture all published first (nothing lists all yet) goes through read, index, sign and write", std.mem.eql(u8, first.stage, "write") and first.ran.code == 0 and h.contains(w.read(first.gho), "conflict=false"), first.ran.text);
        const rel1 = w.read("aws/store/apt/dists/stable/Release");
        rep.check("all: the Release lists all with amd64 and arm64, and the all Packages is in the store", h.contains(rel1, "Architectures: all amd64 arm64\n") and h.contains(w.read("aws/store/apt/dists/stable/main/binary-all/Packages"), "Package: sample-keyring\n"), rel1);
        // The next product's publish: it reads binary-all because the Release lists it, and writes it back unchanged.
        const second = try w.pipeline("p", "debs", true, false);
        rep.check("all: the next product's publish over an index holding an all package succeeds", std.mem.eql(u8, second.stage, "write") and second.ran.code == 0 and h.contains(w.read(second.gho), "conflict=false"), second.ran.text);
        const rel2 = w.read("aws/store/apt/dists/stable/Release");
        rep.check("all: and the Release still lists all, with the other products' architectures", h.contains(rel2, "Architectures: all amd64 arm64\n") and h.contains(rel2, "main/binary-all/Packages.gz\n"), rel2);
        rep.check("all: and the all Packages still holds the keyring, beside the new packages in their own architectures", h.contains(w.read("aws/store/apt/dists/stable/main/binary-all/Packages"), "Package: sample-keyring\n") and h.contains(w.read("aws/store/apt/dists/stable/main/binary-amd64/Packages"), "Package: mopm\n") and h.contains(w.read("aws/store/apt/dists/stable/main/binary-arm64/Packages"), "Package: mopm\n"), w.read("aws/store/apt/dists/stable/main/binary-all/Packages"));
        rep.check("all: the second publish read the all index (it would otherwise drop it)", h.contains(w.awsLog(), "main/binary-all/Packages"), w.awsLog());
        rep.check("all: and the written Release lists the by-hash copy of the all Packages", h.contains(w.read("aws/store/apt/dists/stable/Release"), "main/binary-all/Packages\n") and count(w.awsLog(), "binary-all/by-hash/SHA256/") >= 2, w.awsLog());
    }

    // ---- an invalidation that fails fails the job; an index with no .deb is refused -------------------------------
    {
        n += 1;
        const w = World{ .a = a, .t = t, .root = try h.join(a, &.{ try h.tmpPath(a, &tmp), try h.fmt(a, "inval{d}", .{n}) }) };
        try std.fs.cwd().makePath(w.path("aws"));
        try std.fs.cwd().makePath(w.path("gpg"));
        try std.fs.cwd().makePath(w.path("nodebs"));
        try w.deb("debs", "1.2.3", "amd64");
        try w.deb("debs", "1.2.3", "arm64");
        _ = try w.run(&.{ "assume", "--env-file", w.path("github_env"), "--curl", t.curl, "--aws", t.aws });
        try w.put("aws/invalidate_fail", "");
        const p = try w.pipeline("one", "debs", false, false);
        rep.check("invalidation: a refused invalidation fails the job (the old index would be served)", std.mem.eql(u8, p.stage, "write") and p.ran.code != 0 and h.contains(p.ran.text, "invalidation"), p.ran.text);
        var e = try w.credEnv();
        const r = try w.runEnv(&e, &.{ "index", "--channels", t.channels, "--current", w.path("one_current"), "--out", w.path("x_next"), "--debs", w.path("nodebs"), "--origin", "o", "--label", "o", "--description", "d", "--date", date });
        rep.check("index: a directory with no .deb is refused", r.code != 0 and h.contains(r.text, "no .deb"), r.text);
    }

    // ---- a write that stops after every put: the state a client can read stays consistent ------------------------------
    // The second publish of a repository that exists is interrupted at its N-th put, for every N (the fake fails that put and every later one and
    // stores nothing from there on). A clean run first says how many puts there are: 2 .debs, 4 by-hash files, 4 plain Packages files, and Release,
    // Release.gpg and InRelease. In every interrupted state: the job fails (not a conflict, not a success), nothing is invalidated, the Release and the
    // InRelease a client can read list only files that exist by their hash, and InRelease is still the old one (it is the last put, the commit point).
    {
        n += 1;
        const root = try h.join(a, &.{ try h.tmpPath(a, &tmp), try h.fmt(a, "sweep{d}", .{n}) });
        var total: usize = 0;
        var k: usize = 0;
        while (k <= 14) : (k += 1) {
            const w = World{ .a = a, .t = t, .root = try h.join(a, &.{ root, try h.fmt(a, "k{d}", .{k}) }) };
            try std.fs.cwd().makePath(w.path("aws"));
            try std.fs.cwd().makePath(w.path("gpg"));
            try w.deb("debs", "1.2.3", "amd64");
            try w.deb("debs", "1.2.3", "arm64");
            try w.deb("debs2", "1.2.4", "amd64");
            try w.deb("debs2", "1.2.4", "arm64");
            _ = try w.run(&.{ "assume", "--env-file", w.path("github_env"), "--curl", t.curl, "--aws", t.aws });
            const p1 = try w.pipeline("one", "debs", false, false);
            if (!(std.mem.eql(u8, p1.stage, "write") and p1.ran.code == 0)) {
                rep.check("sweep: the first publish succeeds", false, p1.ran.text);
                continue;
            }
            const old_inrelease = w.read("aws/store/apt/dists/stable/InRelease");
            const old_release = w.read("aws/store/apt/dists/stable/Release");
            const old_packages = w.read("aws/store/apt/dists/stable/main/binary-amd64/Packages");
            const puts_before = count(w.awsLog(), "put-object");
            if (k >= 1) try w.put("aws/fail_at_put", try h.fmt(a, "{d}\n", .{k}));
            const p2 = try w.pipeline("two", "debs2", false, false);
            const puts = count(w.awsLog(), "put-object") - puts_before;
            const label = try h.fmt(a, "sweep k={d}", .{k});
            if (k == 0) {
                total = puts;
                rep.check("sweep: a clean second publish makes 13 puts (2 .debs, 4 by-hash, 4 Packages, Release, Release.gpg, InRelease)", p2.ran.code == 0 and total == 13, p2.ran.text);
                rep.check("sweep: and it ends with a consistent state: both files list only what is there by hash, and the plain Packages files are the listed ones", byHashProblem(w, "InRelease") == null and byHashProblem(w, "Release") == null and !std.mem.eql(u8, old_inrelease, w.read("aws/store/apt/dists/stable/InRelease")) and !std.mem.eql(u8, old_packages, w.read("aws/store/apt/dists/stable/main/binary-amd64/Packages")), "");
                continue;
            }
            if (k > total) break;
            rep.check(try h.fmt(a, "{s}: the job fails, and it is not reported as a conflict", .{label}), std.mem.eql(u8, p2.stage, "write") and p2.ran.code != 0 and !h.contains(w.read(p2.gho), "conflict=") and h.contains(p2.ran.text, "failed"), p2.ran.text);
            rep.check(try h.fmt(a, "{s}: nothing is invalidated (only the first publish did)", .{label}), count(w.awsLog(), "create-invalidation") == 1, w.awsLog());
            rep.check(try h.fmt(a, "{s}: the InRelease a client reads lists only files that exist by their hash", .{label}), byHashProblem(w, "InRelease") == null, byHashProblem(w, "InRelease") orelse "");
            rep.check(try h.fmt(a, "{s}: and so does the Release", .{label}), byHashProblem(w, "Release") == null, byHashProblem(w, "Release") orelse "");
            rep.check(try h.fmt(a, "{s}: InRelease is still the old one (it is the last put, the commit point)", .{label}), std.mem.eql(u8, old_inrelease, w.read("aws/store/apt/dists/stable/InRelease")), "");
            // The Release is replaced only by the put that comes right before Release.gpg and InRelease.
            const release_replaced = !std.mem.eql(u8, old_release, w.read("aws/store/apt/dists/stable/Release"));
            rep.check(try h.fmt(a, "{s}: the Release is replaced exactly when the failing put comes after it", .{label}), release_replaced == (k > 11), "");
        }
        rep.check("sweep: every put was interrupted once (13 of them)", total == 13, "");
    }

    // ---- a .deb put that fails for another reason than a 412 ---------------------------------------------------------
    {
        n += 1;
        const w = World{ .a = a, .t = t, .root = try h.join(a, &.{ try h.tmpPath(a, &tmp), try h.fmt(a, "debfail{d}", .{n}) }) };
        try std.fs.cwd().makePath(w.path("aws"));
        try std.fs.cwd().makePath(w.path("gpg"));
        try w.deb("debs", "1.2.3", "amd64");
        try w.deb("debs", "1.2.3", "arm64");
        _ = try w.run(&.{ "assume", "--env-file", w.path("github_env"), "--curl", t.curl, "--aws", t.aws });
        try w.put("aws/fail_at_put", "1\n");
        const p = try w.pipeline("one", "debs", false, false);
        const log = w.awsLog();
        rep.check("deb put fails: an InternalError on the first .deb fails the job, naming the key and the error", std.mem.eql(u8, p.stage, "write") and p.ran.code != 0 and h.contains(p.ran.text, "put-object apt/pool/mopm/mopm_1.2.3_amd64.deb failed") and h.contains(p.ran.text, "InternalError"), p.ran.text);
        rep.check("deb put fails: it is neither 'exists already' nor a conflict (no conflict output)", !h.contains(p.ran.text, "exists already") and !h.contains(w.read(p.gho), "conflict"), p.ran.text);
        rep.check("deb put fails: nothing else was put (no second .deb, no by-hash file, no index) and nothing was invalidated", count(log, "put-object") == 1 and count(log, "create-invalidation") == 0 and !w.has("aws/store/apt/dists/stable/Release"), log);
    }

    // ---- a Release.gpg that does not verify ---------------------------------------------------------------------------
    {
        n += 1;
        const w = World{ .a = a, .t = t, .root = try h.join(a, &.{ try h.tmpPath(a, &tmp), try h.fmt(a, "badgpg{d}", .{n}) }) };
        try std.fs.cwd().makePath(w.path("aws"));
        try std.fs.cwd().makePath(w.path("gpg"));
        try w.deb("debs", "1.2.3", "amd64");
        try w.deb("debs", "1.2.3", "arm64");
        _ = try w.run(&.{ "assume", "--env-file", w.path("github_env"), "--curl", t.curl, "--aws", t.aws });
        try w.put("gpg/bad_detached", "");
        const p = try w.pipeline("one", "debs", false, false);
        rep.check("bad Release.gpg: the signing fails and says that Release.gpg does not verify (InRelease, which verifies, is not blamed)", std.mem.eql(u8, p.stage, "sign") and p.ran.code != 0 and h.contains(p.ran.text, "Release.gpg does not verify") and !h.contains(p.ran.text, "InRelease does not verify"), p.ran.text);
        rep.check("bad Release.gpg: signed=true is not output, so the write job does not run", !w.has(p.gho), w.read(p.gho));
        rep.check("bad Release.gpg: nothing was put to the repository, not even the pool", !h.contains(w.awsLog(), "put-object") and !w.has("aws/store/apt/dists/stable/Release"), w.awsLog());
        var gone = true;
        var homes = std.mem.splitScalar(u8, w.read("gpg/homes"), '\n');
        while (homes.next()) |hm| {
            if (hm.len == 0) continue;
            std.fs.cwd().access(hm, .{}) catch continue;
            gone = false;
        }
        rep.check("bad Release.gpg: the private directory of the key is gone", gone and w.read("gpg/homes").len > 0 and !h.contains(p.ran.text, passphrase), w.read("gpg/homes"));
        // The same index signed well verifies: the defect is the signature, not the index.
        std.fs.cwd().deleteFile(w.path("gpg/bad_detached")) catch {};
        const q = try w.pipeline("two", "debs", false, false);
        rep.check("bad Release.gpg: with a good signature the same publish succeeds", std.mem.eql(u8, q.stage, "write") and q.ran.code == 0, q.ran.text);
    }

    // ---- a Packages file that is not the one its Release lists is not uploaded ---------------------------------------------
    {
        n += 1;
        const w = World{ .a = a, .t = t, .root = try h.join(a, &.{ try h.tmpPath(a, &tmp), try h.fmt(a, "tamper{d}", .{n}) }) };
        try std.fs.cwd().makePath(w.path("aws"));
        try std.fs.cwd().makePath(w.path("gpg"));
        try w.deb("debs", "1.2.3", "amd64");
        try w.deb("debs", "1.2.3", "arm64");
        _ = try w.run(&.{ "assume", "--env-file", w.path("github_env"), "--curl", t.curl, "--aws", t.aws });
        const p = try w.pipeline("one", "debs", false, false);
        rep.check("tamper: the good publish succeeds first", std.mem.eql(u8, p.stage, "write") and p.ran.code == 0, p.ran.text);
        var e = try w.credEnv();
        const writeArgs = [_][]const u8{ "write", "--aws", t.aws, "--bucket", bucket, "--distribution", "DISTID", "--hostname", "packages.example.test", "--next", w.path("one_next"), "--debs", w.path("debs"), "--out", w.path("gho_t") };
        const puts_before = count(w.awsLog(), "put-object");
        const packages_path = w.path("one_next/dists/stable/main/binary-amd64/Packages");
        const good = w.read("one_next/dists/stable/main/binary-amd64/Packages");
        try h.writeFile(packages_path, try std.mem.concat(a, u8, &.{ good, "# changed after the index was built\n" }));
        var r = try w.runEnv(&e, &writeArgs);
        rep.check("tamper: a Packages file that does not have the hash its Release lists fails the write before any by-hash file or index object", r.code != 0 and h.contains(r.text, "does not have the hash its Release lists") and count(w.awsLog(), "put-object") - puts_before == 2, r.text);
        try h.writeFile(packages_path, good);
        const release_path = w.path("one_next/dists/stable/Release");
        const release = w.read("one_next/dists/stable/Release");
        try h.writeFile(release_path, try std.mem.replaceOwned(u8, a, release, "main/binary-amd64/Packages\n", "main/binary-amd64/Packagez\n"));
        r = try w.runEnv(&e, &writeArgs);
        rep.check("tamper: a Release that lists no hash for a Packages file fails the write", r.code != 0 and h.contains(r.text, "lists no hash for main/binary-amd64/Packages"), r.text);
        try h.writeFile(release_path, release);
        r = try w.runEnv(&e, &writeArgs);
        rep.check("tamper: the untouched index written again: the .debs and by-hash files exist already (a 412 is 'exists'), and the index objects fail on their stale ETags as a conflict", r.code == 0 and h.contains(r.text, "exists already") and h.contains(w.read("gho_t"), "conflict=true"), r.text);
    }

    try rep.finish();
}
