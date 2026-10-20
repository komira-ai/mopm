//! //:cut_release: tools/cut_release.zig, the maintainer's two release steps, run against a fake
//! `gh` (fake_gh.zig) whose state is a directory. It proves what each step refuses and that the
//! dry run changes nothing. Nothing here reaches GitHub.
//!
//! Each refusal case plants one defect in an otherwise good scenario and requires a non-zero exit
//! with the reason in the output; the good scenario must pass first, so a refusal is the defect's
//! doing and not the setup's.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

const targets = [_][]const u8{ "linux-x86_64", "linux-aarch64", "macos-arm64", "macos-x86_64" };
const sha = "0123456789abcdef0123456789abcdef01234567";
const main_zig = "const x = 1;\npub const version = \"1.2.3\";\n";

const Tools = struct { cut: []const u8, gh: []const u8, release: []const u8 };

const World = struct {
    a: Allocator,
    tools: Tools,
    root: []const u8, // the scenario's directory: the fake gh's state
    n: usize = 0,

    fn put(w: World, name: []const u8, data: []const u8) !void {
        try h.writeFile(try h.join(w.a, &.{ w.root, name }), data);
    }

    fn has(w: World, name: []const u8) bool {
        std.fs.cwd().access(h.join(w.a, &.{ w.root, name }) catch return false, .{}) catch return false;
        return true;
    }

    fn log(w: World) []const u8 {
        return h.readFile(w.a, h.join(w.a, &.{ w.root, "log" }) catch return "") catch "";
    }

    /// The four tarballs for `version` in <root>/assets and SHA256SUMS, as the release job makes them.
    /// `extra`: an additional file packed into the linux-x86_64 tarball.
    fn assets(w: *World, version: []const u8, extra: ?[]const u8) !void {
        const a = w.a;
        const env = try h.environ(a);
        const dir = try h.join(a, &.{ w.root, "assets" });
        try std.fs.cwd().makePath(dir);
        for (targets) |t| {
            w.n += 1;
            const parent = try h.join(a, &.{ w.root, "pkg", try h.fmt(a, "{d}", .{w.n}) });
            const name = try h.fmt(a, "mopm-{s}-{s}", .{ version, t });
            const pkg = try h.join(a, &.{ parent, name });
            try std.fs.cwd().makePath(pkg);
            try h.writeFile(try h.join(a, &.{ pkg, "mopm" }), try h.fmt(a, "binary of {s}\n", .{t}));
            try h.writeFile(try h.join(a, &.{ pkg, "LICENSE" }), "license\n");
            if (extra != null and std.mem.eql(u8, t, "linux-x86_64")) try h.writeFile(try h.join(a, &.{ pkg, extra.? }), "x\n");
            const tgz = try h.join(a, &.{ dir, try h.fmt(a, "{s}.tar.gz", .{name}) });
            const r = try h.run(a, &.{ w.tools.release, "tarball", parent, name, tgz }, &env, .{});
            if (r.code != 0) {
                std.debug.print("release tarball failed: {s}\n", .{r.text});
                return error.ToolFailed;
            }
        }
        const r = try h.run(a, &.{ w.tools.release, "sums", dir }, &env, .{});
        if (r.code != 0) {
            std.debug.print("release sums failed: {s}\n", .{r.text});
            return error.ToolFailed;
        }
    }

    fn run(w: World, args: []const []const u8) !h.Ran {
        const a = w.a;
        var env = try h.environ(a);
        try env.put("FAKE_GH_DIR", w.root);
        var argv = std.ArrayList([]const u8).init(a);
        try argv.appendSlice(&.{ w.tools.cut, "--gh", w.tools.gh });
        try argv.appendSlice(args);
        return h.run(a, argv.items, &env, .{});
    }
};

/// A fresh scenario that `tag 1.2.3` accepts: main at `sha` names 1.2.3, 14 checks, all green.
fn goodTag(a: Allocator, tools: Tools, tmp: *std.testing.TmpDir, name: []const u8) !World {
    const root = try h.join(a, &.{ try h.tmpPath(a, tmp), name });
    try std.fs.cwd().makePath(root);
    const w = World{ .a = a, .tools = tools, .root = root };
    try w.put("main_sha", sha ++ "\n");
    try w.put("main_zig", main_zig);
    try w.put("checks", "14 0\n");
    return w;
}

/// A fresh scenario that `verify 1.2.3 <dir>` accepts.
fn goodVerify(a: Allocator, tools: Tools, tmp: *std.testing.TmpDir, name: []const u8) !World {
    var w = try goodTag(a, tools, tmp, name);
    try w.put("release_exists", "");
    try w.put("tag_exists", "");
    try w.assets("1.2.3", null);
    return w;
}

fn sha256Of(a: Allocator, path: []const u8) ![]const u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try h.readFile(a, path), &d, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
}

fn freshDir(a: Allocator, w: World, name: []const u8) ![]const u8 {
    const p = try h.join(a, &.{ w.root, name });
    try std.fs.cwd().makePath(p);
    return p;
}

test "cut_release: tag and verify, and every planted defect is refused" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try h.watchdog(300);
    const tools = Tools{
        .cut = try h.toolPath(a, "MOPM_CUT_RELEASE"),
        .gh = try h.toolPath(a, "MOPM_FAKE_GH"),
        .release = try h.toolPath(a, "MOPM_RELEASE_TOOL"),
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rep = h.Report{};

    // ---- tag ------------------------------------------------------------------------------
    {
        const w = try goodTag(a, tools, &tmp, "tag_dry");
        const r = try w.run(&.{ "tag", "1.2.3" });
        rep.check("tag: the dry run succeeds", r.code == 0 and h.contains(r.text, "DRY RUN"), r.text);
        rep.check("tag: the dry run prints the command it would run", h.contains(r.text, "-f ref=refs/tags/v1.2.3 -f sha=" ++ sha), r.text);
        rep.check("tag: the dry run creates nothing", !w.has("tag_exists") and !h.contains(w.log(), "-X POST"), w.log());
    }
    {
        const w = try goodTag(a, tools, &tmp, "tag_exec");
        const r = try w.run(&.{ "tag", "1.2.3", "--execute" });
        rep.check("tag: --execute succeeds", r.code == 0 and h.contains(r.text, "created the tag v1.2.3"), r.text);
        rep.check("tag: --execute posts exactly one ref, at main's commit", w.has("tag_exists") and h.contains(w.log(), "api -X POST repos/komira-ai/mopm/git/refs -f ref=refs/tags/v1.2.3 -f sha=" ++ sha ++ "\n"), w.log());
    }
    {
        const Case = struct { name: []const u8, version: []const u8, why: []const u8 };
        const cases = [_]Case{
            .{ .name = "main_zig", .version = "1.2.4", .why = "says 1.2.3, not 1.2.4" },
            .{ .name = "checks", .version = "1.2.3", .why = "does not have all checks green" },
            .{ .name = "tag_exists", .version = "1.2.3", .why = "already exists" },
            .{ .name = "release_exists", .version = "1.2.3", .why = "already exists" },
            .{ .name = "no_checks", .version = "1.2.3", .why = "does not have all checks green" },
            .{ .name = "leading_v", .version = "v1.2.3", .why = "is not <major>.<minor>.<patch>" },
            // A lookup that fails for any reason but 404 must stop the tool: "could not ask" is not "absent".
            .{ .name = "tag_error", .version = "1.2.3", .why = "could not tell whether" },
            .{ .name = "release_error", .version = "1.2.3", .why = "could not tell whether" },
        };
        for (cases) |c| {
            const w = try goodTag(a, tools, &tmp, try h.fmt(a, "tag_bad_{s}", .{c.name}));
            if (std.mem.eql(u8, c.name, "checks")) try w.put("checks", "14 1\n");
            if (std.mem.eql(u8, c.name, "no_checks")) try w.put("checks", "0 0\n");
            if (std.mem.eql(u8, c.name, "tag_exists")) try w.put("tag_exists", "");
            if (std.mem.eql(u8, c.name, "release_exists")) try w.put("release_exists", "");
            if (std.mem.eql(u8, c.name, "tag_error")) try w.put("tag_error", "");
            if (std.mem.eql(u8, c.name, "release_error")) try w.put("release_error", "");
            const r = try w.run(&.{ "tag", c.version, "--execute" });
            rep.check(try h.fmt(a, "tag: refused with --execute: {s}", .{c.name}), r.code == 1 and h.contains(r.text, c.why) and !h.contains(w.log(), "-X POST"), r.text);
        }
    }

    // ---- verify ---------------------------------------------------------------------------
    {
        var w = try goodVerify(a, tools, &tmp, "verify_ok");
        const dir = try freshDir(a, w, "dl");
        const r = try w.run(&.{ "verify", "1.2.3", dir });
        const want = try sha256Of(a, try h.join(a, &.{ w.root, "assets", "mopm-1.2.3-linux-x86_64.tar.gz" }));
        const size = (try std.fs.cwd().statFile(try h.join(a, &.{ w.root, "assets", "mopm-1.2.3-linux-x86_64.tar.gz" }))).size;
        rep.check("verify: a good release passes", r.code == 0 and h.contains(r.text, "verified v1.2.3"), r.text);
        rep.check("verify: prints the linux-x86_64 url, sha256 and size", h.contains(r.text, "releases/download/v1.2.3/mopm-1.2.3-linux-x86_64.tar.gz") and h.contains(r.text, want) and h.contains(r.text, try h.fmt(a, "size   {d}\n", .{size})), r.text);
        var attested: usize = 0;
        var lines = std.mem.splitScalar(u8, w.log(), '\n');
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "attestation verify ")) attested += 1;
        }
        rep.check("verify: attestation is checked for all five assets", attested == 5, w.log());

        const dir2 = try freshDir(a, w, "dl2");
        const ok = try w.run(&.{ "verify", "1.2.3", dir2, "--expect-sha256", want });
        rep.check("verify: the expected sha256 is accepted", ok.code == 0, ok.text);
        const dir3 = try freshDir(a, w, "dl3");
        const bad = try w.run(&.{ "verify", "1.2.3", dir3, "--expect-sha256", "0" ** 64 });
        rep.check("verify: another sha256 is refused", bad.code == 1 and h.contains(bad.text, "not the expected"), bad.text);
        const full = try w.run(&.{ "verify", "1.2.3", dir });
        rep.check("verify: a directory that is not empty is refused", full.code == 1 and h.contains(full.text, "not empty"), full.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "verify_tamper");
        const tgz = try h.join(a, &.{ w.root, "assets", "mopm-1.2.3-macos-arm64.tar.gz" });
        const f = try std.fs.cwd().openFile(tgz, .{ .mode = .read_write });
        try f.seekFromEnd(0);
        try f.writeAll("x");
        f.close();
        const r = try w.run(&.{ "verify", "1.2.3", try freshDir(a, w, "dl") });
        rep.check("verify: a tarball that is not the one SHA256SUMS lists is refused", r.code == 1 and h.contains(r.text, "SHA256SUMS lists"), r.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "verify_pending");
        try std.fs.cwd().deleteTree(try h.join(a, &.{ w.root, "assets" }));
        try w.assets("1.2.3", "RELEASE-PENDING");
        const r = try w.run(&.{ "verify", "1.2.3", try freshDir(a, w, "dl") });
        rep.check("verify: a tarball with a RELEASE-PENDING file is refused", r.code == 1 and h.contains(r.text, "RELEASE-PENDING"), r.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "verify_missing");
        try std.fs.cwd().deleteFile(try h.join(a, &.{ w.root, "assets", "mopm-1.2.3-macos-x86_64.tar.gz" }));
        const r = try w.run(&.{ "verify", "1.2.3", try freshDir(a, w, "dl") });
        rep.check("verify: three tarballs are refused", r.code == 1 and h.contains(r.text, "assets"), r.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "verify_other_version");
        const r = try w.run(&.{ "verify", "1.2.4", try freshDir(a, w, "dl") });
        rep.check("verify: assets of another version are refused", r.code == 1 and h.contains(r.text, "expected"), r.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "verify_unattested");
        try w.put("attest_refuse", "SHA256SUMS");
        const r = try w.run(&.{ "verify", "1.2.3", try freshDir(a, w, "dl") });
        rep.check("verify: an asset without an attestation is refused", r.code == 1 and h.contains(r.text, "attestation verify refused SHA256SUMS"), r.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "verify_draft");
        try w.put("release_state", "true false\n");
        const r = try w.run(&.{ "verify", "1.2.3", try freshDir(a, w, "dl") });
        rep.check("verify: a draft release is refused", r.code == 1 and h.contains(r.text, "draft"), r.text);
        try w.put("release_state", "false true\n");
        const p = try w.run(&.{ "verify", "1.2.3", try freshDir(a, w, "dl2") });
        rep.check("verify: a prerelease flag on a plain version is refused", p.code == 1 and h.contains(p.text, "draft"), p.text);
    }
    try rep.finish();
}
