//! //:cut_release: tools/cut_release.zig, the steps release.yml runs (plan, tag, verify-dir, publish)
//! and the read-only check of a published release (verify), run against a fake `gh` (fake_gh.zig)
//! whose state is a directory. Nothing here reaches GitHub, and nothing creates a real tag or release.
//!
//! Each refusal case plants one defect in an otherwise good scenario and requires a non-zero exit
//! with the reason in the output, and the good scenario must pass first, so a refusal is the defect's
//! doing and not the setup's. A refusal must also leave the fake GitHub as it was: no tag, no release,
//! no asset.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

const targets = [_][]const u8{ "linux-x86_64", "linux-aarch64", "macos-arm64", "macos-x86_64" };
const sha = "0123456789abcdef0123456789abcdef01234567";
const other = "fedcba9876543210fedcba9876543210fedcba98";
const names5 = [_][]const u8{ "mopm-1.2.3-linux-x86_64.tar.gz", "mopm-1.2.3-linux-aarch64.tar.gz", "mopm-1.2.3-macos-arm64.tar.gz", "mopm-1.2.3-macos-x86_64.tar.gz", "SHA256SUMS" };
const names10 = names5 ++ [_][]const u8{ "mopm-1.2.3-linux-x86_64.tar.gz.sigstore.json", "mopm-1.2.3-linux-aarch64.tar.gz.sigstore.json", "mopm-1.2.3-macos-arm64.tar.gz.sigstore.json", "mopm-1.2.3-macos-x86_64.tar.gz.sigstore.json", "SHA256SUMS.sigstore.json" };

const Tools = struct { cut: []const u8, gh: []const u8, release: []const u8, cosign: []const u8 };

const World = struct {
    a: Allocator,
    tools: Tools,
    root: []const u8, // the scenario's directory: the fake gh's state
    n: usize = 0,

    fn path(w: World, name: []const u8) []const u8 {
        return h.join(w.a, &.{ w.root, name }) catch @panic("oom");
    }

    fn put(w: World, name: []const u8, data: []const u8) !void {
        try h.writeFile(w.path(name), data);
    }

    fn has(w: World, name: []const u8) bool {
        std.fs.cwd().access(w.path(name), .{}) catch return false;
        return true;
    }

    fn log(w: World) []const u8 {
        return h.readFile(w.a, w.path("log")) catch "";
    }

    /// How many logged gh calls start with `prefix`.
    fn calls(w: World, prefix: []const u8) usize {
        var n: usize = 0;
        var lines = std.mem.splitScalar(u8, w.log(), '\n');
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, prefix)) n += 1;
        }
        return n;
    }

    fn read(w: World, name: []const u8) []const u8 {
        return h.readFile(w.a, w.path(name)) catch "";
    }

    /// The four tarballs for `version` and SHA256SUMS in <root>/<sub>, as the build makes them.
    /// `extra`: an additional file packed into the linux-x86_64 tarball.
    fn assets(w: *World, sub: []const u8, version: []const u8, extra: ?[]const u8) !void {
        const a = w.a;
        var env = try h.environ(a);
        try env.put("FAKE_GH_DIR", w.root);
        const dir = w.path(sub);
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
        const signed = try h.run(a, &.{ w.tools.release, "sign", dir, "--cosign", w.tools.cosign }, &env, .{});
        if (signed.code != 0) {
            std.debug.print("release sign failed: {s}\n", .{signed.text});
            return error.ToolFailed;
        }
    }

    fn run(w: World, args: []const []const u8) !h.Ran {
        const a = w.a;
        var env = try h.environ(a);
        try env.put("FAKE_GH_DIR", w.root);
        var argv = std.ArrayList([]const u8).init(a);
        try argv.appendSlice(&.{ w.tools.cut, "--gh", w.tools.gh, "--cosign", w.tools.cosign });
        try argv.appendSlice(args);
        return h.run(a, argv.items, &env, .{});
    }

    /// The tool with the VERSION file of this scenario.
    fn runV(w: World, args: []const []const u8) !h.Ran {
        var argv = std.ArrayList([]const u8).init(w.a);
        try argv.appendSlice(args);
        try argv.appendSlice(&.{ "--version-file", w.path("VERSION") });
        return w.run(argv.items);
    }
};

/// A fresh scenario: main at `sha`, base 0.0, no tag, no release.
fn fresh(a: Allocator, tools: Tools, tmp: *std.testing.TmpDir, name: []const u8) !World {
    const root = try h.join(a, &.{ try h.tmpPath(a, tmp), name });
    try std.fs.cwd().makePath(root);
    const w = World{ .a = a, .tools = tools, .root = root };
    try w.put("main_sha", sha ++ "\n");
    try w.put("VERSION", "0.0\n");
    return w;
}

/// `count` lines `v0.0.<i> <commit>` for i in from..=to, in order.
fn tagLines(a: Allocator, from: usize, to: usize, commit: []const u8) ![]const u8 {
    var b = std.ArrayList(u8).init(a);
    var i = from;
    while (i <= to) : (i += 1) try b.writer().print("v0.0.{d} {s}\n", .{ i, commit });
    return b.items;
}

/// A scenario with the five built files of 1.2.3 in <root>/assets, the tag v1.2.3 at `sha`, on main.
fn goodVerify(a: Allocator, tools: Tools, tmp: *std.testing.TmpDir, name: []const u8, version: []const u8) !World {
    var w = try fresh(a, tools, tmp, name);
    try w.put("tags", try h.fmt(a, "v{s} {s}\n", .{ version, sha }));
    try w.put("release_exists", "");
    try w.put("releases_page_1", try h.fmt(a, "[{{\"tag_name\":\"v{s}\",\"draft\":false}}]", .{version}));
    try w.assets("assets", version, null);
    return w;
}

fn sha256Of(a: Allocator, p: []const u8) ![]const u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try h.readFile(a, p), &d, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
}

fn freshDir(a: Allocator, w: World, name: []const u8) ![]const u8 {
    const p = try h.join(a, &.{ w.root, name });
    try std.fs.cwd().makePath(p);
    return p;
}

/// Is the directory's file `name` byte-for-byte the one in `other_dir`?
fn same(a: Allocator, d1: []const u8, d2: []const u8, name: []const u8) bool {
    const x = h.readFile(a, h.join(a, &.{ d1, name }) catch return false) catch return false;
    const y = h.readFile(a, h.join(a, &.{ d2, name }) catch return false) catch return false;
    return std.mem.eql(u8, x, y);
}

fn countFiles(w: World, sub: []const u8) usize {
    var d = std.fs.cwd().openDir(w.path(sub), .{ .iterate = true }) catch return 0;
    defer d.close();
    var n: usize = 0;
    var it = d.iterate();
    while (it.next() catch null) |_| n += 1;
    return n;
}

test "cut_release: plan, tag, verify-dir, publish, verify, and every planted defect is refused" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try h.watchdog(600);
    const tools = Tools{
        .cut = try h.toolPath(a, "MOPM_CUT_RELEASE"),
        .gh = try h.toolPath(a, "MOPM_FAKE_GH"),
        .release = try h.toolPath(a, "MOPM_RELEASE_TOOL"),
        .cosign = try h.toolPath(a, "MOPM_FAKE_COSIGN"),
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rep = h.Report{};

    // ---- plan: the version of the next release ---------------------------------------------
    {
        const w = try fresh(a, tools, &tmp, "plan_first");
        const r = try w.runV(&.{ "plan", "--out", w.path("gh_output") });
        rep.check("plan: no tag and no release on base 0.0 gives 0.0.1, the first release", r.code == 0 and h.contains(r.text, "version=0.0.1\n") and !h.contains(r.text, "0.0.0"), r.text);
        rep.check("plan: --out appends the version in the GITHUB_OUTPUT form", std.mem.eql(u8, w.read("gh_output"), "version=0.0.1\n"), w.read("gh_output"));
        rep.check("plan: changes nothing (no POST)", w.calls("api -X POST") == 0, w.log());
    }
    {
        // Numeric, not lexical: v0.0.10 is above v0.0.9 and v0.0.2.
        const w = try fresh(a, tools, &tmp, "plan_numeric");
        try w.put("tags", try h.fmt(a, "v0.0.2 {s}\nv0.0.10 {s}\nv0.0.9 {s}\n", .{ sha, sha, sha }));
        const r = try w.runV(&.{"plan"});
        rep.check("plan: the highest PATCH is compared as a number (v0.0.10 over v0.0.9)", r.code == 0 and h.contains(r.text, "version=0.0.11\n"), r.text);
    }
    {
        // A draft release has no tag but its number is taken.
        const w = try fresh(a, tools, &tmp, "plan_draft");
        try w.put("tags", try tagLines(a, 1, 3, sha));
        try w.put("releases_page_1", "[{\"tag_name\":\"v0.0.7\",\"draft\":true},{\"tag_name\":\"v0.0.2\",\"draft\":false}]");
        const r = try w.runV(&.{"plan"});
        rep.check("plan: the tag_name of a draft release counts (v0.0.7 draft, tags up to v0.0.3 gives 0.0.8)", r.code == 0 and h.contains(r.text, "version=0.0.8\n"), r.text);
    }
    {
        // Only v<base>.<canonical N> counts: another minor (v0.10.9 against base 0.1), another major,
        // a suffix, a leading zero, a non-number and a fourth part are all ignored.
        const w = try fresh(a, tools, &tmp, "plan_other_bases");
        try w.put("VERSION", "0.1\n");
        try w.put("tags", try h.fmt(a, "v0.1.5 {s}\nv0.0.9 {s}\nv0.0.99 {s}\nv0.1.40-rc.1 {s}\nv0.1.07 {s}\nv0.1.x {s}\nv0.1.60.1 {s}\n", .{ sha, sha, sha, sha, sha, sha, sha }));
        const r = try w.runV(&.{"plan"});
        rep.check("plan: lower bases, suffixes, leading zeros and non-numbers are ignored (0.1.5 gives 0.1.6)", r.code == 0 and h.contains(r.text, "version=0.1.6\n"), r.text);
    }
    {
        // More than one page of tags: the highest is on the second page.
        const w = try fresh(a, tools, &tmp, "plan_pages");
        try w.put("tags", try tagLines(a, 1, 150, sha));
        const r = try w.runV(&.{"plan"});
        rep.check("plan: 150 tags span two pages and the highest, on page 2, counts (gives 0.0.151)", r.code == 0 and h.contains(r.text, "version=0.0.151\n"), r.text);
        try w.put("releases_page_1", try (struct {
            fn page(al: Allocator) ![]const u8 {
                var b = std.ArrayList(u8).init(al);
                try b.append('[');
                for (0..100) |i| try b.writer().print("{s}{{\"tag_name\":\"v0.0.{d}\",\"draft\":false}}", .{ if (i == 0) "" else ",", i + 1 });
                try b.append(']');
                return b.items;
            }
        }).page(a));
        try w.put("releases_page_2", "[{\"tag_name\":\"v0.0.400\",\"draft\":true}]");
        const q = try w.runV(&.{"plan"});
        rep.check("plan: a draft on page 2 of the release list counts (gives 0.0.401)", q.code == 0 and h.contains(q.text, "version=0.0.401\n"), q.text);
    }
    {
        const bad = [_][]const u8{ "0.0.1\n", "v0.0\n", "", "0.0\n0.1\n", "00.1\n", "0.x\n", "0\n", "0.0-rc\n" };
        for (bad, 0..) |text, i| {
            const w = try fresh(a, tools, &tmp, try h.fmt(a, "plan_bad_{d}", .{i}));
            try w.put("VERSION", text);
            const r = try w.runV(&.{"plan"});
            rep.check(try h.fmt(a, "plan: VERSION '{s}' is refused", .{std.mem.trim(u8, text, "\n")}), r.code == 1 and h.contains(r.text, "not <major>.<minor>"), r.text);
        }
    }

    // ---- tag: the one write before the build ------------------------------------------------
    {
        const w = try fresh(a, tools, &tmp, "tag_first");
        const r = try w.runV(&.{ "tag", "--sha", sha, "--out", w.path("gh_output") });
        rep.check("tag: the first release creates the annotated tag v0.0.1", r.code == 0 and std.mem.eql(u8, w.read("gh_output"), "version=0.0.1\ntag=v0.0.1\n"), r.text);
        const log = w.log();
        const obj = std.mem.indexOf(u8, log, "api -X POST repos/komira-ai/mopm/git/tags -f tag=v0.0.1 -f message=mopm 0.0.1") orelse log.len;
        const ref = std.mem.indexOf(u8, log, "api -X POST repos/komira-ai/mopm/git/refs -f ref=refs/tags/v0.0.1 -f sha=1111111111111111111111111111111111111111") orelse 0;
        rep.check("tag: the tag object (type commit, at the pushed commit) is made before the ref that names it", obj < ref and h.contains(log, "-f object=" ++ sha ++ " -f type=commit"), log);
        rep.check("tag: nothing else is written (two POSTs, no release)", w.calls("api -X POST") == 2 and !w.has("release_exists"), log);
    }
    {
        const w = try fresh(a, tools, &tmp, "tag_next");
        try w.put("tags", try tagLines(a, 1, 4, other));
        try w.put("compare_tag_" ++ other, "ahead\n"); // the commit is a descendant of the highest release (v0.0.4)
        const r = try w.runV(&.{ "tag", "--sha", sha });
        rep.check("tag: with v0.0.4 taken by another commit the new tag is v0.0.5", r.code == 0 and h.contains(r.text, "version=0.0.5\ntag=v0.0.5\n") and h.contains(w.read("tags"), "v0.0.5 " ++ sha), r.text);
    }
    {
        // A re-run of a run that already tagged this commit reuses the tag: no second number.
        const w = try fresh(a, tools, &tmp, "tag_rerun");
        try w.put("tags", try h.fmt(a, "v0.0.1 {s}\nv0.0.2 {s}\n", .{ other, sha }));
        const r = try w.runV(&.{ "tag", "--sha", sha });
        rep.check("tag: a re-run on a commit whose tag is the highest reuses it (0.0.2) and creates nothing", r.code == 0 and h.contains(r.text, "version=0.0.2\ntag=v0.0.2\n") and w.calls("api -X POST") == 0, r.text);
    }
    {
        // Another run took the number between the listing and the creation: recompute, once.
        const w = try fresh(a, tools, &tmp, "tag_race");
        try w.put("tags", try tagLines(a, 1, 1, other));
        try w.put("race", "v0.0.2 " ++ other ++ "\n");
        const r = try w.runV(&.{ "tag", "--sha", sha });
        rep.check("tag: a lost race (v0.0.2 taken meanwhile) recomputes and creates v0.0.3", r.code == 0 and h.contains(r.text, "version=0.0.3\ntag=v0.0.3\n") and h.contains(w.read("tags"), "v0.0.3 " ++ sha), r.text);
        rep.check("tag: the race cost exactly two ref attempts", w.calls("api -X POST repos/komira-ai/mopm/git/refs") == 2, w.log());
        rep.check("tag: the version is printed once, for the tag that exists (no 0.0.2 line)", !h.contains(r.text, "version=0.0.2"), r.text);
    }
    {
        // Never a loop: a second failure ends the run.
        const w = try fresh(a, tools, &tmp, "tag_taken");
        try w.put("ref_taken", "");
        const r = try w.runV(&.{ "tag", "--sha", sha });
        rep.check("tag: when the retry also fails the tool stops with the reason", r.code == 1 and h.contains(r.text, "cannot create the tag v0.0.1") and w.calls("api -X POST repos/komira-ai/mopm/git/refs") == 2, r.text);
        rep.check("tag: and never wrote a tag", !h.contains(w.read("tags"), sha), w.read("tags"));
    }
    {
        const w = try fresh(a, tools, &tmp, "tag_off_main");
        try w.put("compare_status", "diverged\n");
        const r = try w.runV(&.{ "tag", "--sha", sha });
        rep.check("tag: a commit that is not on main is refused before anything is written", r.code == 1 and h.contains(r.text, "is not on main") and w.calls("api -X POST") == 0, r.text);
        const b = try w.runV(&.{ "tag", "--sha", "abc123" });
        rep.check("tag: a sha that is not 40 hex digits is refused", b.code == 1 and h.contains(b.text, "40-character") and w.calls("api -X POST") == 0, b.text);
        try w.put("compare_status", "ahead\n");
        const c = try w.runV(&.{ "tag", "--sha", sha });
        rep.check("tag: a commit ahead of main is refused", c.code == 1 and h.contains(c.text, "is not on main"), c.text);
    }

    // ---- tag and plan: a superseded commit, the version the candidate was tested as, the base ---
    {
        // The re-run hazard: an old run is re-run after a newer release exists. The old commit is not main's
        // tip, and v0.0.3 names a commit it is behind: it must not become v0.0.4.
        const w = try fresh(a, tools, &tmp, "tag_superseded");
        try w.put("tags", try tagLines(a, 1, 3, other));
        try w.put("compare_status", "behind\n");
        try w.put("compare_tag_" ++ other, "behind\n");
        const r = try w.runV(&.{ "tag", "--sha", sha });
        rep.check("tag: a commit behind the highest release tag is refused as superseded, with no POST", r.code == 1 and h.contains(r.text, "superseded") and h.contains(r.text, "v0.0.3") and w.calls("api -X POST") == 0, r.text);
        rep.check("tag: and no tag was written", !h.contains(w.read("tags"), sha), w.read("tags"));
        try w.put("compare_tag_" ++ other, "diverged\n");
        const d = try w.runV(&.{ "tag", "--sha", sha });
        rep.check("tag: a commit that diverged from the highest release is refused too", d.code == 1 and h.contains(d.text, "superseded") and w.calls("api -X POST") == 0, d.text);
        try w.put("compare_tag_" ++ other, "ahead\n");
        const ok = try w.runV(&.{ "tag", "--sha", sha });
        rep.check("tag: control: the same commit, once it is ahead of the highest release (not main's tip), is tagged", ok.code == 0 and h.contains(ok.text, "version=0.0.4\n") and w.calls("api -X POST") == 2, ok.text);
    }
    {
        // Only the highest tag counts: an older release the commit is behind does not refuse it.
        const w = try fresh(a, tools, &tmp, "tag_superseded_only_highest");
        try w.put("tags", try h.fmt(a, "v0.0.1 {s}\nv0.0.2 {s}\n", .{ other, sha }));
        try w.put("compare_tag_" ++ other, "behind\n");
        const r = try w.runV(&.{ "tag", "--sha", sha });
        rep.check("tag: the guard compares with the highest tag only (v0.0.2 is this commit's: reused)", r.code == 0 and h.contains(r.text, "version=0.0.2\n"), r.text);
    }
    {
        const w = try fresh(a, tools, &tmp, "plan_superseded");
        try w.put("tags", try tagLines(a, 1, 3, other));
        try w.put("compare_tag_" ++ other, "behind\n");
        const r = try w.runV(&.{ "plan", "--sha", sha });
        rep.check("plan --sha: a superseded commit is refused before the build", r.code == 1 and h.contains(r.text, "superseded"), r.text);
        const free = try w.runV(&.{"plan"});
        rep.check("plan without --sha does not look at the commit (a dry run of the numbering)", free.code == 0 and h.contains(free.text, "version=0.0.4\n"), free.text);
        try w.put("compare_tag_" ++ other, "ahead\n");
        const next = try w.runV(&.{ "plan", "--sha", sha });
        rep.check("plan --sha: a descendant of the highest release gets the next number", next.code == 0 and h.contains(next.text, "version=0.0.4\n"), next.text);
        try w.put("tags", try h.fmt(a, "v0.0.1 {s}\nv0.0.2 {s}\n", .{ other, sha }));
        const rerun = try w.runV(&.{ "plan", "--sha", sha });
        rep.check("plan --sha: a re-run of the run that tagged this commit gets that tag's version (0.0.2)", rerun.code == 0 and h.contains(rerun.text, "version=0.0.2\n"), rerun.text);
    }
    {
        const w = try fresh(a, tools, &tmp, "tag_expect");
        const bad = try w.runV(&.{ "tag", "--sha", sha, "--expect-version", "0.0.2" });
        rep.check("tag --expect-version: a different next version is refused, with no POST", bad.code == 1 and h.contains(bad.text, "built and tested as 0.0.2") and w.calls("api -X POST") == 0, bad.text);
        const ok = try w.runV(&.{ "tag", "--sha", sha, "--expect-version", "0.0.1" });
        rep.check("tag --expect-version: the planned version is tagged", ok.code == 0 and h.contains(ok.text, "version=0.0.1\ntag=v0.0.1\n"), ok.text);
        const again = try w.runV(&.{ "tag", "--sha", sha, "--expect-version", "0.0.3" });
        rep.check("tag --expect-version: a re-run's reused tag is checked against it too", again.code == 1 and h.contains(again.text, "built and tested as 0.0.3"), again.text);
    }
    {
        // VERSION may not go backwards.
        const w = try fresh(a, tools, &tmp, "base_backwards");
        try w.put("VERSION", "0.1\n");
        try w.put("tags", try h.fmt(a, "v0.2.1 {s}\n", .{sha}));
        const p = try w.runV(&.{"plan"});
        rep.check("plan: a base below an existing release tag's (0.1 against v0.2.1) is refused", p.code == 1 and h.contains(p.text, "never goes backwards") and h.contains(p.text, "v0.2.1"), p.text);
        const t = try w.runV(&.{ "tag", "--sha", sha });
        rep.check("tag: and so is tagging with it, with no POST", t.code == 1 and h.contains(t.text, "never goes backwards") and w.calls("api -X POST") == 0, t.text);
        try w.put("VERSION", "1.0\n");
        const up = try w.runV(&.{"plan"});
        rep.check("plan: a higher base is fine (1.0 gives 1.0.1)", up.code == 0 and h.contains(up.text, "version=1.0.1\n"), up.text);
        try w.put("VERSION", "0.2\n");
        const same_base = try w.runV(&.{"plan"});
        rep.check("plan: the same base continues (0.2 against v0.2.1 gives 0.2.2)", same_base.code == 0 and h.contains(same_base.text, "version=0.2.2\n"), same_base.text);
    }

    // ---- verify-dir: the built files, before anything is published --------------------------
    {
        var w = try goodVerify(a, tools, &tmp, "vd_ok", "1.2.3");
        const dir = w.path("assets");
        const notes = w.path("notes");
        const r = try w.run(&.{ "verify-dir", "1.2.3", dir, "--sha", sha, "--source-ref", "refs/heads/main", "--notes-out", notes });
        const want = try sha256Of(a, try h.join(a, &.{ dir, "mopm-1.2.3-linux-x86_64.tar.gz" }));
        const size = (try std.fs.cwd().statFile(try h.join(a, &.{ dir, "mopm-1.2.3-linux-x86_64.tar.gz" }))).size;
        rep.check("verify-dir: good built files pass before any release exists", r.code == 0 and h.contains(r.text, "verified v1.2.3 at " ++ sha), r.text);
        rep.check("verify-dir: prints the pin: url, sha256 and size of the linux-x86_64 tarball", h.contains(r.text, "releases/download/v1.2.3/mopm-1.2.3-linux-x86_64.tar.gz") and h.contains(r.text, want) and h.contains(r.text, try h.fmt(a, "size   {d}\n", .{size})), r.text);
        rep.check("verify-dir: attestation is checked for all five payload files", w.calls("attestation verify ") == 5, w.log());
        rep.check("verify-dir: attestation is pinned to release.yml, the given ref and the commit", h.contains(w.log(), "--signer-workflow komira-ai/mopm/.github/workflows/release.yml --source-ref refs/heads/main --source-digest " ++ sha ++ "\n"), w.log());
        rep.check("verify-dir: reads no release (none exists yet in a real run)", w.calls("release ") == 0, w.log());
        const nt = h.readFile(a, try h.join(a, &.{ notes, "release-notes.md" })) catch "";
        rep.check("verify-dir: the notes name the version, the commit and the hash of every file", h.contains(nt, "mopm 1.2.3") and h.contains(nt, sha) and h.contains(nt, want) and h.contains(nt, "`SHA256SUMS`") and !h.contains(nt, "prerelease"), nt);
        const pin = h.readFile(a, try h.join(a, &.{ notes, "pin.txt" })) catch "";
        rep.check("verify-dir: pin.txt is the pin", h.contains(pin, "sha256 " ++ "") and h.contains(pin, want) and h.contains(pin, "dir    mopm-1.2.3-linux-x86_64"), pin);
        const man = h.readFile(a, try h.join(a, &.{ notes, "verified.sha256" })) catch "";
        var lines: usize = 0;
        var it = std.mem.splitScalar(u8, man, '\n');
        while (it.next()) |l| {
            if (l.len != 0) lines += 1;
        }
        rep.check("verify-dir: verified.sha256 lists the ten files", lines == 10 and h.contains(man, "  SHA256SUMS.sigstore.json"), man);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "vd_tamper", "1.2.3");
        const tgz = w.path("assets/mopm-1.2.3-macos-arm64.tar.gz");
        const f = try std.fs.cwd().openFile(tgz, .{ .mode = .read_write });
        try f.seekFromEnd(0);
        try f.writeAll("x");
        f.close();
        const r = try w.run(&.{ "verify-dir", "1.2.3", w.path("assets"), "--sha", sha, "--source-ref", "refs/heads/main" });
        rep.check("verify-dir: a tarball that is not the one SHA256SUMS lists is refused", r.code == 1 and h.contains(r.text, "SHA256SUMS lists"), r.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "vd_pending", "1.2.3");
        try std.fs.cwd().deleteTree(w.path("assets"));
        try w.assets("assets", "1.2.3", "RELEASE-PENDING");
        const r = try w.run(&.{ "verify-dir", "1.2.3", w.path("assets"), "--sha", sha, "--source-ref", "refs/heads/main" });
        rep.check("verify-dir: a tarball with a RELEASE-PENDING file is refused", r.code == 1 and h.contains(r.text, "RELEASE-PENDING"), r.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "vd_missing", "1.2.3");
        try std.fs.cwd().deleteFile(w.path("assets/mopm-1.2.3-macos-x86_64.tar.gz"));
        const r = try w.run(&.{ "verify-dir", "1.2.3", w.path("assets"), "--sha", sha, "--source-ref", "refs/heads/main" });
        rep.check("verify-dir: three tarballs are refused", r.code == 1 and h.contains(r.text, "holds 9 files, expected exactly 10"), r.text);
        try w.put("assets/mopm-1.2.3-macos-x86_64.tar.gz", "not a tarball");
        try w.put("assets/stray.txt", "x");
        const s = try w.run(&.{ "verify-dir", "1.2.3", w.path("assets"), "--sha", sha, "--source-ref", "refs/heads/main" });
        rep.check("verify-dir: a sixth file is refused", s.code == 1 and h.contains(s.text, "holds 11 files, expected exactly 10"), s.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "vd_version", "1.2.3");
        const r = try w.run(&.{ "verify-dir", "1.2.4", w.path("assets"), "--sha", sha, "--source-ref", "refs/heads/main" });
        rep.check("verify-dir: files of another version are refused", r.code == 1, r.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "vd_unattested", "1.2.3");
        try w.put("attest_refuse", "SHA256SUMS");
        const r = try w.run(&.{ "verify-dir", "1.2.3", w.path("assets"), "--sha", sha, "--source-ref", "refs/heads/main" });
        rep.check("verify-dir: a file without an attestation is refused", r.code == 1 and h.contains(r.text, "attestation verify refused SHA256SUMS"), r.text);
    }
    {
        // Keyless signatures: cosign verify-blob on every payload file, identity and commit pinned.
        var w = try goodVerify(a, tools, &tmp, "vd_signatures", "1.2.3");
        const dir = w.path("assets");
        const ok = try w.run(&.{ "verify-dir", "1.2.3", dir, "--sha", sha, "--source-ref", "refs/heads/main" });
        const cl = w.read("cosign_log");
        var verifies: usize = 0;
        var lines = std.mem.splitScalar(u8, cl, '\n');
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "verify-blob ")) verifies += 1;
        }
        rep.check("verify-dir: the signature of each of the five payload files is verified", ok.code == 0 and verifies == 5, cl);
        rep.check("verify-dir: the signature is pinned to release.yml at the ref, the OIDC issuer, the commit, the push trigger and the repository", h.contains(cl, "--certificate-identity https://github.com/komira-ai/mopm/.github/workflows/release.yml@refs/heads/main --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-github-workflow-sha " ++ sha ++ " --certificate-github-workflow-trigger push --certificate-github-workflow-repository komira-ai/mopm "), cl);

        try w.put("cosign_refuse", "mopm-1.2.3-macos-arm64.tar.gz");
        const r = try w.run(&.{ "verify-dir", "1.2.3", dir, "--sha", sha, "--source-ref", "refs/heads/main" });
        rep.check("verify-dir: a file with no valid signature is refused by name", r.code == 1 and h.contains(r.text, "cosign verify-blob refused mopm-1.2.3-macos-arm64.tar.gz"), r.text);
        try std.fs.cwd().deleteFile(w.path("cosign_refuse"));

        // A bundle that signs other bytes (the file was changed after signing, SHA256SUMS kept consistent).
        try w.put("assets/SHA256SUMS.sigstore.json", "fake-cosign-bundle sha256=" ++ "0" ** 64 ++ "\n");
        const t = try w.run(&.{ "verify-dir", "1.2.3", dir, "--sha", sha, "--source-ref", "refs/heads/main" });
        rep.check("verify-dir: a bundle that does not match its file is refused", t.code == 1 and h.contains(t.text, "cosign verify-blob refused SHA256SUMS"), t.text);

        var w2 = try goodVerify(a, tools, &tmp, "vd_unsigned", "1.2.3");
        try std.fs.cwd().deleteFile(w2.path("assets/mopm-1.2.3-linux-x86_64.tar.gz.sigstore.json"));
        const m = try w2.run(&.{ "verify-dir", "1.2.3", w2.path("assets"), "--sha", sha, "--source-ref", "refs/heads/main" });
        rep.check("verify-dir: a missing bundle is refused (nine files, ten expected)", m.code == 1 and h.contains(m.text, "holds 9 files, expected exactly 10"), m.text);
    }
    {
        // release sign: refuses when cosign fails, and signs nothing it was not given.
        var w = try goodVerify(a, tools, &tmp, "sign_fail", "1.2.3");
        try w.put("cosign_sign_fail", "");
        var env = try h.environ(a);
        try env.put("FAKE_GH_DIR", w.root);
        const r = try h.run(a, &.{ tools.release, "sign", w.path("assets"), "--cosign", tools.cosign }, &env, .{});
        rep.check("release sign: a failing cosign fails the step", r.code != 0 and h.contains(r.text, "cosign sign-blob failed"), r.text);
        try std.fs.cwd().deleteFile(w.path("cosign_sign_fail"));
        const ok = try h.run(a, &.{ tools.release, "sign", w.path("assets"), "--cosign", tools.cosign }, &env, .{});
        rep.check("release sign: control: with cosign working it signs the five payload files", ok.code == 0 and h.contains(ok.text, "signed 5 files"), ok.text);
    }
    {
        // release record / tested: the tarballs attested are the tarballs the user beta passed.
        var w = try goodVerify(a, tools, &tmp, "tested_flow", "1.2.3");
        var env = try h.environ(a);
        try env.put("FAKE_GH_DIR", w.root);
        const dist = w.path("assets");
        const rec = w.path("tested");
        for ([_][]const u8{ "linux-x86_64", "linux-aarch64", "macos-arm64" }) |t| {
            const rr = try h.run(a, &.{ tools.release, "record", try h.join(a, &.{ dist, try h.fmt(a, "mopm-1.2.3-{s}.tar.gz", .{t}) }), rec }, &env, .{});
            if (rr.code != 0) {
                std.debug.print("release record failed: {s}\n", .{rr.text});
                return error.ToolFailed;
            }
        }
        const ok = try h.run(a, &.{ tools.release, "tested", dist, rec }, &env, .{});
        rep.check("release tested: control: the files attested are the files recorded as tested", ok.code == 0 and h.contains(ok.text, "tested ok: mopm-1.2.3-macos-arm64.tar.gz"), ok.text);

        // The recorded line names the sha256 of the very file.
        const want = try sha256Of(a, try h.join(a, &.{ dist, "mopm-1.2.3-linux-x86_64.tar.gz" }));
        const line = try h.readFile(a, try h.join(a, &.{ rec, "mopm-1.2.3-linux-x86_64.tar.gz.sha256" }));
        rep.check("release record: writes `<sha256>  <name>` of the tarball", std.mem.eql(u8, line, try h.fmt(a, "{s}  mopm-1.2.3-linux-x86_64.tar.gz\n", .{want})), line);

        // Mutant: the tarball changed after it was tested.
        try h.writeFile(try h.join(a, &.{ dist, "mopm-1.2.3-linux-aarch64.tar.gz" }), "a different tarball\n");
        const bad = try h.run(a, &.{ tools.release, "tested", dist, rec }, &env, .{});
        rep.check("release tested: a tarball that is not the one the user beta passed is refused, by name", bad.code != 0 and h.contains(bad.text, "mopm-1.2.3-linux-aarch64.tar.gz: the user beta tested sha256"), bad.text);

        // Mutant: a platform leg left no record (the changed tarball is recorded again, so only this defect remains).
        const rr2 = try h.run(a, &.{ tools.release, "record", try h.join(a, &.{ dist, "mopm-1.2.3-linux-aarch64.tar.gz" }), rec }, &env, .{});
        if (rr2.code != 0) return error.ToolFailed;
        try std.fs.cwd().deleteFile(try h.join(a, &.{ rec, "mopm-1.2.3-macos-arm64.tar.gz.sha256" }));
        const missing = try h.run(a, &.{ tools.release, "tested", dist, rec }, &env, .{});
        rep.check("release tested: a target with no record is refused", missing.code != 0 and h.contains(missing.text, "recorded nothing for macos-arm64"), missing.text);

        // Mutant: a record of a target that is not tested.
        // (Control first: with the changed tarball and the missing leg recorded again, it passes.)
        for ([_][]const u8{ "linux-aarch64", "macos-arm64" }) |t| {
            const rr = try h.run(a, &.{ tools.release, "record", try h.join(a, &.{ dist, try h.fmt(a, "mopm-1.2.3-{s}.tar.gz", .{t}) }), rec }, &env, .{});
            if (rr.code != 0) return error.ToolFailed;
        }
        const again = try h.run(a, &.{ tools.release, "tested", dist, rec }, &env, .{});
        try h.writeFile(try h.join(a, &.{ rec, "mopm-1.2.3-macos-x86_64.tar.gz.sha256" }), "x\n");
        const extra = try h.run(a, &.{ tools.release, "tested", dist, rec }, &env, .{});
        rep.check("release tested: a record beyond the three tested targets is refused", again.code == 0 and extra.code != 0 and h.contains(extra.text, "expected exactly the 3 records"), extra.text);
    }
    {
        // A re-run of an old release run after a newer release exists must not publish the old one last.
        var w = try fresh(a, tools, &tmp, "pub_superseded");
        try w.put("tags", "v1.2.3 " ++ sha ++ "\nv1.2.4 " ++ other ++ "\n");
        try w.assets("dist", "1.2.3", null);
        const v = try w.run(&.{ "verify-dir", "1.2.3", w.path("dist"), "--sha", sha, "--source-ref", "refs/heads/main", "--notes-out", w.path("notes") });
        const pub_args = [_][]const u8{ "publish", "1.2.3", w.path("dist"), "--verified", w.path("notes/verified.sha256"), "--notes", w.path("notes/release-notes.md") };
        const r = try w.run(&pub_args);
        rep.check("publish: with v1.2.4 existing, publishing 1.2.3 is refused as superseded, creating and uploading nothing", v.code == 0 and r.code == 1 and h.contains(r.text, "superseded") and w.calls("release create ") == 0 and w.calls("release upload ") == 0 and w.calls("api -X POST") == 0, r.text);
        try w.put("tags", "v1.2.3 " ++ sha ++ "\n");
        const ok = try w.run(&pub_args);
        rep.check("publish: control: with v1.2.3 the highest, the same publish succeeds", ok.code == 0 and w.calls("release create v1.2.3 ") == 1, ok.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "vd_tag_elsewhere", "1.2.3");
        try w.put("tags", "v1.2.3 " ++ other ++ "\n");
        const r = try w.run(&.{ "verify-dir", "1.2.3", w.path("assets"), "--sha", sha, "--source-ref", "refs/heads/main" });
        rep.check("verify-dir: a tag that names another commit than the built one is refused", r.code == 1 and h.contains(r.text, "not the commit " ++ sha) and w.calls("attestation") == 0, r.text);
        try w.put("tags", "v9.9.9 " ++ sha ++ "\n");
        const m = try w.run(&.{ "verify-dir", "1.2.3", w.path("assets"), "--sha", sha, "--source-ref", "refs/heads/main" });
        rep.check("verify-dir: a missing tag is refused", m.code == 1 and h.contains(m.text, "gh api failed") and w.calls("attestation") == 0, m.text);
        try w.put("tags", "v1.2.3 " ++ sha ++ "\n");
        try w.put("compare_status", "diverged\n");
        const o = try w.run(&.{ "verify-dir", "1.2.3", w.path("assets"), "--sha", sha, "--source-ref", "refs/heads/main" });
        rep.check("verify-dir: a commit that is not on main is refused", o.code == 1 and h.contains(o.text, "is not on main"), o.text);
        const b = try w.run(&.{ "verify-dir", "1.2.3", w.path("assets"), "--sha", "abc", "--source-ref", "refs/heads/main" });
        rep.check("verify-dir: a sha that is not 40 hex digits is refused", b.code == 1 and h.contains(b.text, "40-character"), b.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "vd_rc", "0.0.1-rc.1");
        const r = try w.run(&.{ "verify-dir", "0.0.1-rc.1", w.path("assets"), "--sha", sha, "--source-ref", "refs/heads/main", "--notes-out", w.path("notes") });
        rep.check("verify-dir: a prerelease version passes and says it is a prerelease", r.code == 0 and h.contains(r.text, "prerelease: true"), r.text);
        const nt = h.readFile(a, w.path("notes/release-notes.md")) catch "";
        rep.check("verify-dir: its notes say so", h.contains(nt, "This is a prerelease."), nt);
    }

    // ---- publish: the verified files, once ---------------------------------------------------
    {
        // The whole flow on the fake: verify the built files in dist, then publish them.
        var w = try fresh(a, tools, &tmp, "pub_ok");
        try w.put("tags", "v1.2.3 " ++ sha ++ "\n");
        try w.assets("dist", "1.2.3", null);
        const v = try w.run(&.{ "verify-dir", "1.2.3", w.path("dist"), "--sha", sha, "--source-ref", "refs/heads/main", "--notes-out", w.path("notes") });
        rep.check("publish: setup: the built files verify", v.code == 0, v.text);
        const r = try w.run(&.{ "publish", "1.2.3", w.path("dist"), "--verified", w.path("notes/verified.sha256"), "--notes", w.path("notes/release-notes.md") });
        rep.check("publish: creates the release from exactly the ten verified files", r.code == 0 and h.contains(r.text, "created the release v1.2.3") and w.calls("release create v1.2.3 ") == 1 and countFiles(w, "assets") == 10, r.text);
        var same_all = true;
        for (names10) |n| same_all = same_all and same(a, w.path("dist"), w.path("assets"), n);
        rep.check("publish: every published asset is the verified file, byte for byte", same_all, w.log());
        rep.check("publish: tag check, title, notes file, no prerelease flag", h.contains(w.log(), "--verify-tag --title mopm 1.2.3 --notes-file " ++ "") and !h.contains(w.log(), "--prerelease") and h.contains(w.read("release_notes"), "mopm 1.2.3"), w.log());

        // A re-run: the release exists with all five identical assets. Nothing is created or replaced.
        try w.put("releases_page_1", "[{\"tag_name\":\"v1.2.3\",\"draft\":false}]");
        const again = try w.run(&.{ "publish", "1.2.3", w.path("dist"), "--verified", w.path("notes/verified.sha256"), "--notes", w.path("notes/release-notes.md") });
        rep.check("publish: a re-run finds the release and does nothing", again.code == 0 and h.contains(again.text, "nothing to do") and w.calls("release create ") == 1 and w.calls("release upload ") == 0, again.text);

        // The re-run after a failure half-way: the release holds only some assets, identical.
        try std.fs.cwd().deleteFile(w.path("assets/mopm-1.2.3-macos-arm64.tar.gz"));
        try std.fs.cwd().deleteFile(w.path("assets/SHA256SUMS"));
        const part = try w.run(&.{ "publish", "1.2.3", w.path("dist"), "--verified", w.path("notes/verified.sha256"), "--notes", w.path("notes/release-notes.md") });
        rep.check("publish: a re-run adds exactly the assets the release lacks", part.code == 0 and w.calls("release upload ") == 1 and w.calls("release create ") == 1 and h.contains(w.log(), "mopm-1.2.3-macos-arm64.tar.gz") and countFiles(w, "assets") == 10, part.text);

        // A held asset that differs: refused, and nothing is changed (no upload, the asset is as it was).
        try w.put("assets/mopm-1.2.3-linux-aarch64.tar.gz", "tampered");
        try std.fs.cwd().deleteFile(w.path("assets/SHA256SUMS"));
        const before = w.calls("release upload ");
        const bad = try w.run(&.{ "publish", "1.2.3", w.path("dist"), "--verified", w.path("notes/verified.sha256"), "--notes", w.path("notes/release-notes.md") });
        rep.check("publish: an existing asset that differs is refused, and nothing is uploaded or replaced", bad.code == 1 and h.contains(bad.text, "differs from the verified file") and w.calls("release upload ") == before and std.mem.eql(u8, w.read("assets/mopm-1.2.3-linux-aarch64.tar.gz"), "tampered") and !w.has("assets/SHA256SUMS"), bad.text);
        try w.put("assets/mopm-1.2.3-linux-aarch64.tar.gz", w.read("dist/mopm-1.2.3-linux-aarch64.tar.gz"));
        try w.put("assets/stray.txt", "x");
        const stray = try w.run(&.{ "publish", "1.2.3", w.path("dist"), "--verified", w.path("notes/verified.sha256"), "--notes", w.path("notes/release-notes.md") });
        rep.check("publish: an asset that is not one of the five is refused, and nothing is uploaded", stray.code == 1 and h.contains(stray.text, "stray.txt") and w.calls("release upload ") == before, stray.text);
    }
    {
        var w = try fresh(a, tools, &tmp, "pub_refuse");
        try w.put("tags", "v1.2.3 " ++ sha ++ "\n");
        try w.assets("dist", "1.2.3", null);
        const v = try w.run(&.{ "verify-dir", "1.2.3", w.path("dist"), "--sha", sha, "--source-ref", "refs/heads/main", "--notes-out", w.path("notes") });
        rep.check("publish: setup: the built files verify", v.code == 0, v.text);
        const pub_args = [_][]const u8{ "publish", "1.2.3", w.path("dist"), "--verified", w.path("notes/verified.sha256"), "--notes", w.path("notes/release-notes.md") };

        // A file changed after verify-dir: not the verified file.
        const f = try std.fs.cwd().openFile(w.path("dist/mopm-1.2.3-macos-x86_64.tar.gz"), .{ .mode = .read_write });
        try f.seekFromEnd(0);
        try f.writeAll("x");
        f.close();
        const r = try w.run(&pub_args);
        rep.check("publish: a file changed since verification is refused, and no release is created", r.code == 1 and h.contains(r.text, "is not the file that was verified") and w.calls("release create ") == 0, r.text);

        var w2 = try fresh(a, tools, &tmp, "pub_refuse2");
        try w2.put("tags", "v1.2.3 " ++ sha ++ "\n");
        try w2.assets("dist", "1.2.3", null);
        _ = try w2.run(&.{ "verify-dir", "1.2.3", w2.path("dist"), "--sha", sha, "--source-ref", "refs/heads/main", "--notes-out", w2.path("notes") });
        const args2 = [_][]const u8{ "publish", "1.2.3", w2.path("dist"), "--verified", w2.path("notes/verified.sha256"), "--notes", w2.path("notes/release-notes.md") };
        try w2.put("dist/extra.txt", "x");
        const e = try w2.run(&args2);
        rep.check("publish: a sixth file in the directory is refused", e.code == 1 and h.contains(e.text, "holds 11 files") and w2.calls("release create ") == 0, e.text);
        try std.fs.cwd().deleteFile(w2.path("dist/extra.txt"));
        try std.fs.cwd().deleteFile(w2.path("dist/SHA256SUMS"));
        const m = try w2.run(&args2);
        rep.check("publish: a missing file is refused", m.code == 1 and h.contains(m.text, "holds 9 files") and w2.calls("release create ") == 0, m.text);
    }
    {
        // A draft of the tag, and a prerelease flag that does not match the version.
        var w = try fresh(a, tools, &tmp, "pub_state");
        try w.put("tags", "v1.2.3 " ++ sha ++ "\n");
        try w.assets("dist", "1.2.3", null);
        _ = try w.run(&.{ "verify-dir", "1.2.3", w.path("dist"), "--sha", sha, "--source-ref", "refs/heads/main", "--notes-out", w.path("notes") });
        const args = [_][]const u8{ "publish", "1.2.3", w.path("dist"), "--verified", w.path("notes/verified.sha256"), "--notes", w.path("notes/release-notes.md") };
        try w.put("releases_page_1", "[{\"tag_name\":\"v1.2.3\",\"draft\":true}]");
        const d = try w.run(&args);
        rep.check("publish: a draft release of the tag is refused and left alone", d.code == 1 and h.contains(d.text, "exists as a draft") and w.calls("release create ") == 0 and w.calls("release upload ") == 0, d.text);
        try w.put("releases_page_1", "[{\"tag_name\":\"v1.2.3\",\"draft\":false}]");
        try w.put("release_exists", "");
        try w.put("release_state", "false true\n");
        const p = try w.run(&args);
        rep.check("publish: a prerelease flag on a plain version is refused", p.code == 1 and h.contains(p.text, "prerelease = true"), p.text);
    }
    {
        var w = try fresh(a, tools, &tmp, "pub_rc");
        try w.put("tags", "v0.0.1-rc.1 " ++ sha ++ "\n");
        try w.assets("dist", "0.0.1-rc.1", null);
        const v = try w.run(&.{ "verify-dir", "0.0.1-rc.1", w.path("dist"), "--sha", sha, "--source-ref", "refs/heads/main", "--notes-out", w.path("notes") });
        const r = try w.run(&.{ "publish", "0.0.1-rc.1", w.path("dist"), "--verified", w.path("notes/verified.sha256"), "--notes", w.path("notes/release-notes.md") });
        rep.check("publish: a prerelease version is created with --prerelease", v.code == 0 and r.code == 0 and h.contains(w.log(), "--prerelease") and h.contains(w.read("release_state"), "false true"), r.text);
    }

    // ---- verify: a published release, read-only -----------------------------------------------
    {
        var w = try goodVerify(a, tools, &tmp, "verify_ok", "1.2.3");
        const dir = try freshDir(a, w, "dl");
        const r = try w.run(&.{ "verify", "1.2.3", dir });
        const want = try sha256Of(a, try h.join(a, &.{ w.root, "assets", "mopm-1.2.3-linux-x86_64.tar.gz" }));
        rep.check("verify: a good release passes", r.code == 0 and h.contains(r.text, "verified v1.2.3") and h.contains(r.text, want), r.text);
        rep.check("verify: attestation is checked for the five payload assets, pinned to release.yml, main and the tag's commit", w.calls("attestation verify ") == 5 and h.contains(w.log(), "--signer-workflow komira-ai/mopm/.github/workflows/release.yml --source-ref refs/heads/main --source-digest " ++ sha ++ "\n"), w.log());
        rep.check("verify: the signatures are checked too, pinned to main, the tag's commit, the push trigger and the repository", h.contains(w.read("cosign_log"), "--certificate-identity https://github.com/komira-ai/mopm/.github/workflows/release.yml@refs/heads/main --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-github-workflow-sha " ++ sha ++ " --certificate-github-workflow-trigger push --certificate-github-workflow-repository komira-ai/mopm "), w.read("cosign_log"));
        rep.check("verify: changes nothing (no create, no upload, no POST)", w.calls("release create") == 0 and w.calls("release upload") == 0 and w.calls("api -X POST") == 0, w.log());
        const ok = try w.run(&.{ "verify", "1.2.3", try freshDir(a, w, "dl2"), "--expect-sha256", want });
        rep.check("verify: the expected sha256 is accepted", ok.code == 0, ok.text);
        const bad = try w.run(&.{ "verify", "1.2.3", try freshDir(a, w, "dl3"), "--expect-sha256", "0" ** 64 });
        rep.check("verify: another sha256 is refused", bad.code == 1 and h.contains(bad.text, "not the expected"), bad.text);
        const full = try w.run(&.{ "verify", "1.2.3", dir });
        rep.check("verify: a directory that is not empty is refused", full.code == 1 and h.contains(full.text, "not empty"), full.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "verify_tamper", "1.2.3");
        const f = try std.fs.cwd().openFile(w.path("assets/mopm-1.2.3-macos-arm64.tar.gz"), .{ .mode = .read_write });
        try f.seekFromEnd(0);
        try f.writeAll("x");
        f.close();
        const r = try w.run(&.{ "verify", "1.2.3", try freshDir(a, w, "dl") });
        rep.check("verify: a tarball that is not the one SHA256SUMS lists is refused", r.code == 1 and h.contains(r.text, "SHA256SUMS lists"), r.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "verify_draft", "1.2.3");
        try w.put("release_state", "true false\n");
        const r = try w.run(&.{ "verify", "1.2.3", try freshDir(a, w, "dl") });
        rep.check("verify: a draft release is refused", r.code == 1 and h.contains(r.text, "draft"), r.text);
        try w.put("release_state", "false true\n");
        const p = try w.run(&.{ "verify", "1.2.3", try freshDir(a, w, "dl2") });
        rep.check("verify: a prerelease flag on a plain version is refused", p.code == 1 and h.contains(p.text, "draft"), p.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "verify_extra_asset", "1.2.3");
        try w.put("asset_list", "mopm-1.2.3-linux-x86_64.tar.gz\nmopm-1.2.3-linux-aarch64.tar.gz\nmopm-1.2.3-macos-arm64.tar.gz\nmopm-1.2.3-macos-x86_64.tar.gz\nSHA256SUMS\nstray.txt\n");
        const r = try w.run(&.{ "verify", "1.2.3", try freshDir(a, w, "dl") });
        rep.check("verify: an extra asset in the release's list is refused by name, before any download", r.code == 1 and h.contains(r.text, "unexpected asset stray.txt") and w.calls("release download") == 0, r.text);
        try w.put("asset_list", "mopm-1.2.3-linux-x86_64.tar.gz\nmopm-1.2.3-linux-aarch64.tar.gz\nmopm-1.2.3-macos-arm64.tar.gz\nSHA256SUMS\n");
        const m = try w.run(&.{ "verify", "1.2.3", try freshDir(a, w, "dl2") });
        rep.check("verify: a missing asset in the release's list is refused by name", m.code == 1 and h.contains(m.text, "lacks the asset mopm-1.2.3-macos-x86_64.tar.gz"), m.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "verify_off_main", "1.2.3");
        try w.put("compare_status", "diverged\n");
        const r = try w.run(&.{ "verify", "1.2.3", try freshDir(a, w, "dl") });
        rep.check("verify: a tag on a commit that diverged from main is refused before the download", r.code == 1 and h.contains(r.text, "is not on main") and w.calls("release download") == 0, r.text);
        try w.put("compare_status", "identical\n");
        const ok = try w.run(&.{ "verify", "1.2.3", try freshDir(a, w, "dl3") });
        rep.check("verify: a tag at main's tip is accepted", ok.code == 0, ok.text);
    }
    {
        var w = try goodVerify(a, tools, &tmp, "verify_rc", "0.0.1-rc.1");
        try w.put("release_state", "false true\n");
        const r = try w.run(&.{ "verify", "0.0.1-rc.1", try freshDir(a, w, "dl") });
        rep.check("verify: a prerelease version with the prerelease flag passes", r.code == 0 and h.contains(r.text, "verified v0.0.1-rc.1"), r.text);
        try w.put("release_state", "false false\n");
        const p = try w.run(&.{ "verify", "0.0.1-rc.1", try freshDir(a, w, "dl2") });
        rep.check("verify: a prerelease version without the prerelease flag is refused", p.code == 1 and h.contains(p.text, "expected 'false true'"), p.text);
    }
    try rep.finish();
}
