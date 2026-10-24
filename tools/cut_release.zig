//! The release steps .github/workflows/release.yml runs, and the read-only check of a published
//! release. Zig only, standard library only; build it with the pinned Zig and run it from the
//! repository root:
//!
//!     zig build-exe tools/cut_release.zig -femit-bin=<path>
//!
//! Every step is one invocation, and every one takes `gh` (the GitHub CLI, with GH_TOKEN) as its only
//! way to reach GitHub. `--gh <path>` names another program (the tests give a fake `gh`) and
//! `--repo <owner/name>` another repository. A release is made by release.yml alone, on a push to main
//! (RELEASING.md); nobody runs `plan`, `tag` or `publish` by hand.
//!
//!   cut_release plan [--sha <commit>] [--version-file VERSION] [--out <file>]
//!       Reads the base MAJOR.MINOR from the file and prints the version the next release would get:
//!       the highest PATCH among the tags v<base>.N and the releases (draft or published) of the
//!       repository, plus one; 1 when there is none (the first release of 0.0 is 0.0.1). Changes nothing.
//!       Refuses a base below any existing release tag's. With --sha it also refuses a commit that is
//!       superseded (see tag), and when the highest tag already names that commit (a re-run) it prints
//!       that tag's version. release.yml runs it before the build: the candidate is built, user-tested
//!       and later shipped as this version.
//!   cut_release tag --sha <commit> [--expect-version <v>] [--version-file VERSION] [--out <file>]
//!       The one write before the build: creates the annotated tag v<version> at <commit>, which must be
//!       main or an ancestor of it, and must not be superseded: the highest tag v<base>.N must name <commit>
//!       or an ancestor of it (compare says identical or ahead), else this refuses with 'superseded'. A
//!       re-run of an old run after a newer release exists would otherwise tag the OLD commit with the
//!       next number and install.sh would hand users older code. Main's exact tip is not required: pushes
//!       land while a run waits for the macOS runners. With --expect-version it refuses unless the version
//!       it would take is that one (the candidate was built and tested as that version). If the highest tag
//!       already names <commit> (a re-run) it is reused and nothing is created. If creating the tag fails
//!       because the tag exists (another run took the number) it recomputes and tries once more. Prints and,
//!       with --out, appends `version=` and `tag=` lines (the format of $GITHUB_OUTPUT).
//!   cut_release verify-dir <version> <dir> --sha <commit> --source-ref <ref> --trigger <push|workflow_dispatch> [--notes-out <dir>]
//!       Before the tag exists and before anything is published: checks the BUILT files in <dir>. <commit> is on
//!       main (no tag is read: the tag job runs after this); the files are exactly the twelve: the three mopm-<version>-<target>.tar.gz, the two mopm_<version>_<arch>.deb, SHA256SUMS and the
//!       cosign bundle <file>.sigstore.json of each; SHA256SUMS lists each tarball and .deb with the hash it has; each .deb equals, byte for byte, the one the binary in its tarball makes with the metadata in --packaging (default packaging/deb); `gh attestation verify` and `cosign verify-blob` (--cosign, identity pinned to release.yml at <ref>, the commit, <trigger> (the event of the run that signed: exactly `push` or `workflow_dispatch`, nothing else) and the repository pinned) accept every payload file
//!       (attestations pinned to release.yml, <ref> and <commit>); each tarball holds exactly
//!       mopm-<version>-<target>/{mopm,LICENSE}. With --notes-out it writes release-notes.md, pin.txt (the
//!       linux-x86_64 url, sha256 and size) and, only for --trigger push, verified.sha256 (the hash of each of the twelve
//!       files): the manifest `publish` requires. A dry run (workflow_dispatch) verifies the same but writes no manifest, so
//!       what a manual run signed can never be published.
//!   cut_release verify <version> <dir> [--expect-sha256 <hex>]
//!       After the release exists (read-only): the release is published, not a draft, with the prerelease
//!       flag its version calls for, and exactly the twelve assets; its tag is on main; the assets are
//!       downloaded into the empty <dir> and pass the same checks as verify-dir, with the attestation
//!       pinned to main and the tag's commit. Prints the pin. The .debs are checked against the .deb metadata the repository
//!       held at the release's tag (read with `gh api`; --packaging <dir> names a directory instead). A release older than
//!       v0.0.6, the first with .debs, is refused at once: it has none to check.
//!   cut_release publish <version> <dir> --verified <file> --notes <file>
//!       Creates the release v<version> from exactly the twelve files of <dir>, which must be the ones
//!       verified.sha256 lists. A re-run creates no second release and replaces no asset: when the release
//!       exists, every asset it holds must equal the local file byte for byte, or this refuses before
//!       changing anything; only the assets it lacks are added.
//!   cut_release bump-internal --version <v> --sha <commit> --internal-repo <owner/name> --submodule <name> --workdir <dir>
//!       The last step, after publish (tools/bump_internal.zig): opens the pull request that moves the
//!       internal repository's submodule to --sha, as the release bot, with auto-merge. Needs `git` as well
//!       as `gh` (--git <path>), and GH_TOKEN in the environment (never an argument). Idempotent.
//!   cut_release tap --version <v> --formula-file <file> --tap-repo <owner/name> --formula <name> [--asset <stem>] --workdir <dir>
//!       The stage after publish (tools/tap.zig): opens the pull request in the Homebrew tap that adds or updates
//!       Formula/<name>.rb with the formula `channels formula` rendered from the verified SHA256SUMS, as the release
//!       bot, and asks for auto-merge with squash (a tap without required checks refuses it: the pull request then
//!       stays open, with a notice, and the run is green). Refuses a version below the tap's. Needs `git` as well as
//!       `gh`, and GH_TOKEN in the environment (never an argument). Idempotent.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bump_internal = @import("bump_internal.zig");
const tap = @import("tap.zig");
const release_debs = @import("release_debs.zig");

const targets = [_][]const u8{ "linux-x86_64", "linux-aarch64", "macos-arm64" };
const pin_target = "linux-x86_64";
const sums_name = "SHA256SUMS";

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cut_release: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usage() noreturn {
    die("usage: cut_release [--gh <path>] [--cosign <path>] [--cosign-retry-ms <n>] [--cosign-wait-budget-ms <n>] [--repo <owner/name>] plan [--sha <commit>] | tag --sha <commit> [--expect-version <v>] | verify-dir <version> <dir> --sha <commit> --source-ref <ref> --trigger <push|workflow_dispatch> | verify <version> <dir> | publish <version> <dir> --verified <file> --notes <file> | bump-internal --version <v> --sha <commit> --internal-repo <owner/name> --submodule <name> --workdir <dir> [--git <path>] | tap --version <v> --formula-file <file> --tap-repo <owner/name> --formula <name> [--asset <stem>] --workdir <dir> [--git <path>]", .{});
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
    /// The `cosign` that checks signatures (`--cosign <path>`; the tests give a fake).
    cosign: []const u8 = "cosign",
    /// The delay before the second try of a `cosign verify-blob` that could not fetch the trusted root; the third waits twice as long (`--cosign-retry-ms`).
    cosign_retry_ms: u32 = default_cosign_retry_ms,
    /// The most that all the retries of one verification wait in total (`--cosign-wait-budget-ms`).
    cosign_wait_budget_ms: u64 = max_cosign_wait_ms,
    /// The directory of the .deb metadata (`--packaging <dir>`), which verify uses to rebuild each .deb from its tarball.
    packaging: []const u8 = release_debs.default_packaging,
    /// `--packaging` was given.
    packaging_given: bool = false,
    /// The .deb metadata itself, when it was not read from `packaging` (verify reads the release's own tag).
    meta: ?release_debs.Metadata = null,

    fn run(g: Gh, args: []const []const u8) Ran {
        return g.runExe(g.exe, args);
    }

    fn runExe(g: Gh, exe: []const u8, args: []const []const u8) Ran {
        var argv = std.ArrayList([]const u8).init(g.a);
        argv.append(exe) catch @panic("oom");
        argv.appendSlice(args) catch @panic("oom");
        const r = std.process.Child.run(.{ .allocator = g.a, .argv = argv.items, .max_output_bytes = 1 << 22 }) catch |err| {
            die("could not run {s}: {s}", .{ exe, @errorName(err) });
        };
        return .{ .ok = r.term == .Exited and r.term.Exited == 0, .stdout = r.stdout, .stderr = r.stderr };
    }

    /// Standard output of a gh call that must succeed, without the trailing newline.
    fn must(g: Gh, args: []const []const u8) []const u8 {
        const r = g.run(args);
        if (!r.ok) die("gh {s} failed: {s}", .{ args[0], std.mem.trim(u8, r.stderr, " \r\n") });
        return std.mem.trimRight(u8, r.stdout, "\r\n");
    }

    fn api(g: Gh, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(g.a, "repos/{s}/" ++ fmt, .{g.repo} ++ args) catch @panic("oom");
    }
};

// ---- versions --------------------------------------------------------------------------

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// A number as `semver` writes it: digits, no leading zero (except 0 itself), at most nine of them.
fn canonical(s: []const u8) ?u64 {
    if (!allDigits(s) or s.len > 9) return null;
    if (s.len > 1 and s[0] == '0') return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

/// <major>.<minor>, as the VERSION file holds it.
fn validBase(s: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return false;
    return canonical(s[0..dot]) != null and canonical(s[dot + 1 ..]) != null;
}

/// <major>.<minor>.<patch>, optionally followed by -<suffix>; no leading v.
fn validVersion(v: []const u8) bool {
    const core_end = std.mem.indexOfScalar(u8, v, '-') orelse v.len;
    if (core_end < v.len and core_end + 1 == v.len) return false;
    for (v[core_end..]) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '.' or c == '-';
        if (!ok) return false;
    }
    var parts = std.mem.splitScalar(u8, v[0..core_end], '.');
    var n: usize = 0;
    while (parts.next()) |p| : (n += 1) {
        if (!allDigits(p)) return false;
    }
    return n == 3;
}

fn isHex40(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

/// The base in the VERSION file: one line, MAJOR.MINOR.
fn readBase(a: Allocator, path: []const u8) []const u8 {
    const text = std.fs.cwd().readFileAlloc(a, path, 1 << 10) catch |err| die("cannot read {s}: {s}", .{ path, @errorName(err) });
    const base = std.mem.trimRight(u8, text, "\n");
    if (!validBase(base)) die("{s} holds '{s}', not <major>.<minor> on one line (the release run adds the patch number)", .{ path, std.mem.trim(u8, text, " \r\n") });
    return base;
}

/// N when `name` is the tag v<base>.N (N canonical, nothing after it), else null: v0.1.5 is a patch of
/// base 0.1; v0.10.3, v0.1.5-rc.1, v0.1.05 and v0.1.5.7 are not.
fn patchOf(base: []const u8, name: []const u8) ?u64 {
    if (name.len < 2 or name[0] != 'v') return null;
    const rest = name[1..];
    if (!std.mem.startsWith(u8, rest, base)) return null;
    const after = rest[base.len..];
    if (after.len < 2 or after[0] != '.') return null;
    return canonical(after[1..]);
}

const Highest = struct { patch: u64, name: []const u8 };

fn highest(base: []const u8, names: []const []const u8) ?Highest {
    var best: ?Highest = null;
    for (names) |n| {
        const p = patchOf(base, n) orelse continue;
        if (best == null or p > best.?.patch) best = .{ .patch = p, .name = n };
    }
    return best;
}

/// The patch the next release takes: one more than the highest, 1 when there is none.
fn nextPatch(base: []const u8, names: []const []const u8) u64 {
    return if (highest(base, names)) |h| h.patch + 1 else 1;
}

const per_page = 100;
const max_pages = 50;

/// Every tag name that starts with `prefix` (paged).
fn tagsByPrefix(gh: Gh, prefix: []const u8) []const []const u8 {
    const a = gh.a;
    var names = std.ArrayList([]const u8).init(a);
    const Ref = struct { ref: []const u8 = "" };
    var page: usize = 1;
    while (true) : (page += 1) {
        if (page > max_pages) die("more than {d} tags starting with {s}: cannot tell which number is next", .{ max_pages * per_page, prefix });
        const json = gh.must(&.{ "api", gh.api("git/matching-refs/tags/{s}?per_page={d}&page={d}", .{ prefix, per_page, page }) });
        const parsed = std.json.parseFromSlice([]const Ref, a, json, .{ .ignore_unknown_fields = true }) catch |err| {
            die("cannot read the tag list: {s}", .{@errorName(err)});
        };
        for (parsed.value) |r| {
            const head = "refs/tags/";
            if (std.mem.startsWith(u8, r.ref, head)) names.append(r.ref[head.len..]) catch @panic("oom");
        }
        if (parsed.value.len < per_page) break;
    }
    return names.items;
}

/// Every tag name v<base>.* the repository has (paged).
fn tagNames(gh: Gh, base: []const u8) []const []const u8 {
    return tagsByPrefix(gh, std.fmt.allocPrint(gh.a, "v{s}.", .{base}) catch @panic("oom"));
}

/// (major, minor) of a base or of a plain tag v<major>.<minor>.<patch>; null for anything else.
fn majorMinor(s: []const u8) ?[2]u64 {
    var parts = std.mem.splitScalar(u8, s, '.');
    const maj = canonical(parts.next() orelse return null) orelse return null;
    const min = canonical(parts.next() orelse return null) orelse return null;
    return .{ maj, min };
}

/// The base of VERSION may not go backwards: a tag of a higher MAJOR.MINOR than `base` means the
/// file was lowered (or this is an old commit), and a release would number below what users have.
fn requireBaseNotBehind(gh: Gh, base: []const u8) void {
    const mine = majorMinor(base) orelse die("'{s}' is not <major>.<minor>", .{base});
    for (tagsByPrefix(gh, "v")) |t| {
        if (!validVersion(t[1..]) or std.mem.indexOfScalar(u8, t, '-') != null) continue;
        const theirs = majorMinor(t[1..]) orelse continue;
        if (theirs[0] > mine[0] or (theirs[0] == mine[0] and theirs[1] > mine[1])) {
            die("VERSION holds {s}, below the existing release tag {s}: the base never goes backwards", .{ base, t });
        }
    }
}

/// A release is cut only for a commit that is, or descends from, the commit of the highest v<base>.N tag.
/// A re-run of an old run, after a newer release exists, would otherwise tag the OLD commit with the next
/// number, and install.sh (which installs the latest) would then give users that older code. The exact tip
/// of main is not required: pushes land while a run waits for the macOS runners.
fn requireNotSuperseded(gh: Gh, base: []const u8, tags: []const []const u8, sha: []const u8) void {
    const h = highest(base, tags) orelse return;
    const tag_sha = commitOf(gh, h.name);
    const rel = gh.must(&.{ "api", gh.api("compare/{s}...{s}", .{ tag_sha, sha }), "--jq", ".status" });
    if (!std.mem.eql(u8, rel, "identical") and !std.mem.eql(u8, rel, "ahead")) {
        die("superseded: the commit {s} is not a descendant of the release {s} (commit {s}; compare says '{s}'); tagging it would number old code above newer code. Nothing was changed.", .{ sha, h.name, tag_sha, rel });
    }
}

/// The names whose number is taken: the tags, and every tag_name of the releases, draft or published
/// (a draft may have no tag, but its number is taken).
fn takenNames(gh: Gh, tags: []const []const u8) []const []const u8 {
    var names = std.ArrayList([]const u8).init(gh.a);
    names.appendSlice(tags) catch @panic("oom");
    for (releases(gh)) |r| names.append(r.tag_name) catch @panic("oom");
    return names.items;
}

const Rel = struct { tag_name: []const u8 = "", draft: bool = false };

/// Every release, draft ones included, page by page.
fn releases(gh: Gh) []const Rel {
    var all = std.ArrayList(Rel).init(gh.a);
    var page: usize = 1;
    while (true) : (page += 1) {
        if (page > max_pages) die("more than {d} releases: cannot list them all", .{max_pages * per_page});
        const json = gh.must(&.{ "api", gh.api("releases?per_page={d}&page={d}", .{ per_page, page }) });
        const parsed = std.json.parseFromSlice([]const Rel, gh.a, json, .{ .ignore_unknown_fields = true }) catch |err| {
            die("cannot read the release list: {s}", .{@errorName(err)});
        };
        all.appendSlice(parsed.value) catch @panic("oom");
        if (parsed.value.len < per_page) break;
    }
    return all.items;
}

fn findRelease(gh: Gh, tag: []const u8) ?Rel {
    for (releases(gh)) |r| {
        if (std.mem.eql(u8, r.tag_name, tag)) return r;
    }
    return null;
}

fn commitOf(gh: Gh, ref: []const u8) []const u8 {
    const sha = gh.must(&.{ "api", gh.api("commits/{s}", .{ref}), "--jq", ".sha" });
    if (!isHex40(sha)) die("{s} resolves to '{s}', not a 40-character sha", .{ ref, sha });
    return sha;
}

/// The commit is main's tip or an ancestor of it.
fn requireOnMain(gh: Gh, what: []const u8, sha: []const u8) void {
    const rel = gh.must(&.{ "api", gh.api("compare/main...{s}", .{sha}), "--jq", ".status" });
    if (!std.mem.eql(u8, rel, "identical") and !std.mem.eql(u8, rel, "behind")) {
        die("{s} (commit {s}) is not on main (compare with main says '{s}')", .{ what, sha, rel });
    }
}

fn appendOut(path: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    out(fmt, args);
    const p = path orelse return;
    var f = std.fs.cwd().createFile(p, .{ .truncate = false }) catch |err| die("cannot open {s}: {s}", .{ p, @errorName(err) });
    defer f.close();
    f.seekFromEnd(0) catch |err| die("cannot write {s}: {s}", .{ p, @errorName(err) });
    f.writer().print(fmt, args) catch |err| die("cannot write {s}: {s}", .{ p, @errorName(err) });
}

// ---- plan and tag ----------------------------------------------------------------------

fn planCmd(gh: Gh, sha: ?[]const u8, version_file: []const u8, out_path: ?[]const u8) void {
    const base = readBase(gh.a, version_file);
    requireBaseNotBehind(gh, base);
    const tags = tagNames(gh, base);
    if (sha) |s| {
        if (!isHex40(s)) die("--sha '{s}' is not a 40-character commit sha", .{s});
        requireNotSuperseded(gh, base, tags, s);
        // A re-run of a run that already tagged this commit: that tag's version.
        if (highest(base, tags)) |h| {
            if (std.mem.eql(u8, commitOf(gh, h.name), s)) {
                appendOut(out_path, "version={s}.{d}\n", .{ base, h.patch });
                return;
            }
        }
    }
    const version = std.fmt.allocPrint(gh.a, "{s}.{d}", .{ base, nextPatch(base, takenNames(gh, tags)) }) catch @panic("oom");
    appendOut(out_path, "version={s}\n", .{version});
}

fn tagCmd(gh: Gh, sha: []const u8, expect_version: ?[]const u8, version_file: []const u8, out_path: ?[]const u8) void {
    const a = gh.a;
    if (!isHex40(sha)) die("--sha '{s}' is not a 40-character commit sha", .{sha});
    const base = readBase(a, version_file);
    requireOnMain(gh, "the release commit", sha);
    requireBaseNotBehind(gh, base);

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const tags = tagNames(gh, base);
        const names = takenNames(gh, tags);
        requireNotSuperseded(gh, base, tags, sha);
        // A re-run of the run that made the tag: the tag is this commit's, so this commit's release.
        if (highest(base, tags)) |h| {
            if (std.mem.eql(u8, commitOf(gh, h.name), sha)) {
                const reused = std.fmt.allocPrint(a, "{s}.{d}", .{ base, h.patch }) catch @panic("oom");
                requireExpected(expect_version, reused);
                appendOut(out_path, "version={s}\ntag={s}\n", .{ reused, h.name });
                return;
            }
        }
        const version = std.fmt.allocPrint(a, "{s}.{d}", .{ base, nextPatch(base, names) }) catch @panic("oom");
        requireExpected(expect_version, version);
        const tag = std.fmt.allocPrint(a, "v{s}", .{version}) catch @panic("oom");
        const message = std.fmt.allocPrint(a, "message=mopm {s}\n\nReleased automatically from main commit {s}.", .{ version, sha }) catch @panic("oom");
        const tag_arg = std.fmt.allocPrint(a, "tag={s}", .{tag}) catch @panic("oom");
        const object_arg = std.fmt.allocPrint(a, "object={s}", .{sha}) catch @panic("oom");
        const object = gh.must(&.{ "api", "-X", "POST", gh.api("git/tags", .{}), "-f", tag_arg, "-f", message, "-f", object_arg, "-f", "type=commit", "--jq", ".sha" });
        if (!isHex40(object)) die("the tag object for {s} is '{s}', not a 40-character sha", .{ tag, object });
        const made = gh.run(&.{
            "api", "-X", "POST", gh.api("git/refs", .{}),
            "-f",  std.fmt.allocPrint(a, "ref=refs/tags/{s}", .{tag}) catch @panic("oom"),
            "-f",  std.fmt.allocPrint(a, "sha={s}", .{object}) catch @panic("oom"),
        });
        if (made.ok) {
            appendOut(out_path, "version={s}\ntag={s}\n", .{ version, tag });
            return;
        }
        // The number was taken between the listing and the creation: look again, once.
        if (attempt == 0 and std.mem.indexOf(u8, made.stderr, "already exists") != null) continue;
        die("cannot create the tag {s}: {s}", .{ tag, std.mem.trim(u8, made.stderr, " \r\n") });
    }
}

// ---- the checks of the twelve files ------------------------------------------------

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

const bundle_suffix = ".sigstore.json";
const oidc_issuer = "https://token.actions.githubusercontent.com";

/// mopm-<version>-<target>.tar.gz for the three targets, mopm_<version>_<arch>.deb for the two linux ones, then SHA256SUMS:
/// the six payload files.
fn payloadAssets(a: Allocator, version: []const u8) [][]const u8 {
    var want = std.ArrayList([]const u8).init(a);
    for (targets) |t| want.append(std.fmt.allocPrint(a, "mopm-{s}-{s}.tar.gz", .{ version, t }) catch @panic("oom")) catch @panic("oom");
    for (release_debs.debs) |d| want.append(release_debs.debName(a, version, d.arch) catch @panic("oom")) catch @panic("oom");
    want.append(sums_name) catch @panic("oom");
    return want.items;
}

/// The twelve assets of a release: the six payload files, then the cosign bundle `<file>.sigstore.json` of each.
fn wantAssets(a: Allocator, version: []const u8) [][]const u8 {
    var want = std.ArrayList([]const u8).init(a);
    const payload = payloadAssets(a, version);
    want.appendSlice(payload) catch @panic("oom");
    for (payload) |p| want.append(std.fmt.allocPrint(a, "{s}{s}", .{ p, bundle_suffix }) catch @panic("oom")) catch @panic("oom");
    return want.items;
}

/// <dir> holds exactly the twelve files, by name (sorted names are returned).
fn checkNames(a: Allocator, dir: std.fs.Dir, where: []const u8, want: [][]const u8) void {
    var have = std.ArrayList([]const u8).init(a);
    var it = dir.iterate();
    while (it.next() catch |err| die("cannot list {s}: {s}", .{ where, @errorName(err) })) |e| {
        have.append(a.dupe(u8, e.name) catch @panic("oom")) catch @panic("oom");
    }
    std.mem.sort([]const u8, have.items, {}, lessThan);
    const sorted = a.dupe([]const u8, want) catch @panic("oom");
    std.mem.sort([]const u8, sorted, {}, lessThan);
    if (have.items.len != sorted.len) die("{s} holds {d} files, expected exactly {d}: {s}", .{ where, have.items.len, sorted.len, std.mem.join(a, " ", have.items) catch "" });
    for (have.items, sorted) |h, w| {
        if (!std.mem.eql(u8, h, w)) die("{s} does not hold the expected set: found {s} where {s} was expected", .{ where, h, w });
    }
}

/// SHA256SUMS lists each of the three tarballs and the two .debs, once, with the hash the file has.
fn checkSums(a: Allocator, dir: std.fs.Dir, want: [][]const u8) void {
    const sums = readAll(a, dir, sums_name);
    var listed: usize = 0;
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line.len < 67 or !std.mem.eql(u8, line[64..66], "  ")) die("malformed SHA256SUMS line: {s}", .{line});
        const file = line[66..];
        var known = false;
        for (want) |w| {
            if (std.mem.eql(u8, w, file) and (std.mem.endsWith(u8, w, ".tar.gz") or std.mem.endsWith(u8, w, ".deb"))) known = true;
        }
        if (!known) die("SHA256SUMS lists {s}, which is not one of the three tarballs and two .debs", .{file});
        const got = sha256Hex(a, readAll(a, dir, file));
        if (!std.mem.eql(u8, line[0..64], got)) die("{s}: sha256 is {s}, SHA256SUMS lists {s}", .{ file, got, line[0..64] });
        listed += 1;
    }
    if (listed != targets.len + release_debs.debs.len) die("SHA256SUMS lists {d} files, expected {d}", .{ listed, targets.len + release_debs.debs.len });
}

/// Every file is attested by this repository's release workflow, for `source_ref` and `sha`.
fn checkAttestations(gh: Gh, dir_path: []const u8, want: [][]const u8, source_ref: []const u8, sha: []const u8) void {
    const a = gh.a;
    const signer = std.fmt.allocPrint(a, "{s}/.github/workflows/release.yml", .{gh.repo}) catch @panic("oom");
    for (want) |w| {
        const path = std.fs.path.join(a, &.{ dir_path, w }) catch @panic("oom");
        const r = gh.run(&.{ "attestation", "verify", path, "-R", gh.repo, "--signer-workflow", signer, "--source-ref", source_ref, "--source-digest", sha });
        if (!r.ok) die("gh attestation verify refused {s}: {s}", .{ w, std.mem.trim(u8, r.stderr, " \r\n") });
    }
}

/// Every payload file has a keyless cosign signature by this repository's release workflow, for `source_ref`
/// and `sha`: the certificate identity and issuer are pinned, and so are the commit and the trigger (the event of the signing run).
fn checkSignatures(gh: Gh, dir_path: []const u8, payload: [][]const u8, source_ref: []const u8, sha: []const u8, trigger: []const u8) void {
    const a = gh.a;
    const identity = std.fmt.allocPrint(a, "https://github.com/{s}/.github/workflows/release.yml@{s}", .{ gh.repo, source_ref }) catch @panic("oom");
    var waited_ms: u64 = 0; // all the waiting of the retries below, bounded by gh.cosign_wait_budget_ms
    for (payload) |w| {
        const path = std.fs.path.join(a, &.{ dir_path, w }) catch @panic("oom");
        const bundle = std.fmt.allocPrint(a, "{s}{s}", .{ path, bundle_suffix }) catch @panic("oom");
        const args = [_][]const u8{ "verify-blob", "--bundle", bundle, "--certificate-identity", identity, "--certificate-oidc-issuer", oidc_issuer, "--certificate-github-workflow-sha", sha, "--certificate-github-workflow-trigger", trigger, "--certificate-github-workflow-repository", gh.repo, path };
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            const r = gh.runExe(gh.cosign, &args);
            if (r.ok) break;
            const err = std.mem.trim(u8, r.stderr, " \r\n");
            if (!isTrustedRootFetchFailure(r.stderr)) die("cosign verify-blob refused {s}: {s}", .{ w, err });
            const wait_ms = @as(u64, gh.cosign_retry_ms) * attempt;
            // out of tries, or the wait would pass the budget of all the retries of this run: a fetch failure, said at once
            if (attempt >= cosign_tries or waited_ms + wait_ms > gh.cosign_wait_budget_ms) die("cosign verify-blob could not fetch the Sigstore trusted root for {s} in {d} tries (a network failure, not a verdict on the signature): {s}", .{ w, attempt, err });
            waited_ms += wait_ms;
            std.debug.print("cut_release: cosign verify-blob could not fetch the Sigstore trusted root for {s} (try {d} of {d}); retrying in {d} ms\n", .{ w, attempt, cosign_tries, wait_ms });
            std.time.sleep(wait_ms * std.time.ns_per_ms);
        }
    }
}

/// Tries of `cosign verify-blob` per file when it cannot fetch the Sigstore trusted root.
const cosign_tries: u32 = 3;

/// The default delay (ms) before the second try; the third waits twice as long.
const default_cosign_retry_ms: u32 = 2000;

/// The most (ms) that all the retries of one verification wait in total, across every file. The default waits cost 6000 ms for a file whose fetch never
/// works, so the budget lets two such files retry fully and no more: a long outage does not hold the release file after file.
const max_cosign_wait_ms: u64 = 12_000;

comptime {
    std.debug.assert(default_cosign_retry_ms == 2000 and max_cosign_wait_ms == 12_000);
}

/// cosign's FINAL stderr line says the trusted root (the TUF repository) could not be fetched: a network failure that says nothing about the
/// signature. Only these retry; any other refusal (a signature or certificate mismatch) is final. Only the last line counts: in legacy-bundle
/// mode cosign prints the `Could not fetch trusted_root.json ... Continuing` warning and may then report a real mismatch, which is a verdict.
/// One more shape retries: cosign v3.0.6 (cmd/cosign/cli/verify/common.go, under `co.TrustedMaterial == nil && !verifyOfflineWithKey`) ends a failed fetch with `trusted root is required when
/// using new bundle format`, raised when the trusted material is nil after the fetch failed, and the fetch error itself is only an earlier warning line. That final
/// line retries only when an earlier line holds one of the fetch markers; alone it says nothing about why the root is missing.
fn isTrustedRootFetchFailure(stderr: []const u8) bool {
    const text = std.mem.trim(u8, stderr, " \r\n");
    const cut = std.mem.lastIndexOfScalar(u8, text, '\n');
    const last = if (cut) |i| text[i + 1 ..] else text;
    const earlier = if (cut) |i| text[0..i] else "";
    const markers = [_][]const u8{ "tuf refresh failed", "Could not fetch trusted_root.json", "error getting live trusted root" };
    for (markers) |m| {
        if (std.mem.indexOf(u8, last, m) != null) return true;
    }
    if (std.mem.indexOf(u8, last, "trusted root is required when using new bundle format") != null) {
        for (markers) |m| {
            if (std.mem.indexOf(u8, earlier, m) != null) return true;
        }
    }
    return false;
}


/// Each .deb is the one that the binary inside its tarball makes, byte for byte (release_debs.rebuild with the metadata in
/// `packaging`): a .deb with other bytes than the tarball's binary, or other metadata than the repository's, is refused.
fn checkDebs(gh: Gh, dir: std.fs.Dir, version: []const u8) void {
    const a = gh.a;
    const meta = gh.meta orelse (release_debs.loadPackaging(a, gh.packaging) catch |err| die("cannot read the .deb metadata in {s}: {s}", .{ gh.packaging, @errorName(err) }));
    for (release_debs.debs) |d| {
        const deb_name = release_debs.debName(a, version, d.arch) catch @panic("oom");
        const tar_name = release_debs.tarballName(a, version, d.target) catch @panic("oom");
        const have = readAll(a, dir, deb_name);
        const want = release_debs.rebuild(a, readAll(a, dir, tar_name), version, d, meta) catch |err| die("cannot rebuild {s} from {s}: {s}", .{ deb_name, tar_name, @errorName(err) });
        if (!std.mem.eql(u8, have, want)) die("{s} is not the .deb that the binary in {s} makes (sha256 {s}, rebuilt {s}): it holds other bytes", .{ deb_name, tar_name, sha256Hex(a, have), sha256Hex(a, want) });
    }
}

const Pin = struct { sha256: []const u8, size: usize };

/// Each tarball unpacks into one directory holding exactly mopm and LICENSE. Returns the linux-x86_64 pin.
fn checkLayout(a: Allocator, dir: std.fs.Dir, version: []const u8) Pin {
    var pin = Pin{ .sha256 = "", .size = 0 };
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
        if (std.mem.eql(u8, t, pin_target)) pin = .{ .sha256 = sha256Hex(a, gz), .size = gz.len };
    }
    return pin;
}

fn pinText(a: Allocator, repo: []const u8, version: []const u8, pin: Pin) []const u8 {
    return std.fmt.allocPrint(a, "url    https://github.com/{s}/releases/download/v{s}/mopm-{s}-{s}.tar.gz\nsha256 {s}\nsize   {d}\ndir    mopm-{s}-{s}\n", .{ repo, version, version, pin_target, pin.sha256, pin.size, version, pin_target }) catch @panic("oom");
}

/// The three tarballs and two .debs, SHA256SUMS, the layout, each .deb rebuilt from its tarball; with `attest` also the attestation and the signature of the six payload files.
/// Returns the pin of the linux-x86_64 tarball.
fn checkAssets(gh: Gh, version: []const u8, dir_path: []const u8, attest: ?struct { ref: []const u8, sha: []const u8, trigger: []const u8 }) Pin {
    const a = gh.a;
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| die("cannot open {s}: {s}", .{ dir_path, @errorName(err) });
    defer dir.close();
    const want = wantAssets(a, version);
    const payload = payloadAssets(a, version);
    checkNames(a, dir, dir_path, want);
    checkSums(a, dir, payload);
    if (attest) |t| {
        checkAttestations(gh, dir_path, payload, t.ref, t.sha);
        checkSignatures(gh, dir_path, payload, t.ref, t.sha, t.trigger);
    }
    const pin = checkLayout(a, dir, version);
    checkDebs(gh, dir, version);
    return pin;
}

// ---- verify-dir ------------------------------------------------------------------------

fn verifyDirCmd(gh: Gh, version: []const u8, dir_path: []const u8, sha: []const u8, source_ref: []const u8, trigger: []const u8, notes_out: ?[]const u8) void {
    const a = gh.a;
    // The signatures must carry exactly the event of the run that made them; nothing else is accepted.
    const is_push = std.mem.eql(u8, trigger, "push");
    if (!is_push and !std.mem.eql(u8, trigger, "workflow_dispatch")) die("--trigger '{s}' is not push or workflow_dispatch", .{trigger});
    if (!validVersion(version)) die("'{s}' is not <major>.<minor>.<patch>[-suffix] (no leading v)", .{version});
    if (!isHex40(sha)) die("--sha '{s}' is not a 40-character commit sha", .{sha});
    const tag = std.fmt.allocPrint(a, "v{s}", .{version}) catch @panic("oom");

    // verify-dir runs BEFORE the tag job (a red attest, signature or verify leaves no orphan tag): no tag exists yet,
    // and none is read. The commit that was built is on main.
    requireOnMain(gh, "the built commit", sha);

    const pin = checkAssets(gh, version, dir_path, .{ .ref = source_ref, .sha = sha, .trigger = trigger });
    const prerelease = std.mem.indexOfScalar(u8, version, '-') != null;

    if (notes_out) |nd| {
        std.fs.cwd().makePath(nd) catch |err| die("cannot make {s}: {s}", .{ nd, @errorName(err) });
        var d = std.fs.cwd().openDir(dir_path, .{}) catch |err| die("cannot open {s}: {s}", .{ dir_path, @errorName(err) });
        defer d.close();
        var notes = std.ArrayList(u8).init(a);
        const w = notes.writer();
        w.print("mopm {s}\n\nBuilt and released automatically from main commit {s}. Every file below is attested (build provenance) and signed (keyless cosign, Sigstore), both by release.yml, and was verified before this release was created.{s}\n\nsha256 of each file:\n\n", .{ version, sha, if (prerelease) " This is a prerelease." else "" }) catch @panic("oom");
        var manifest = std.ArrayList(u8).init(a);
        for (wantAssets(a, version)) |name| {
            const h = sha256Hex(a, readAll(a, d, name));
            w.print("- `{s}`  {s}\n", .{ name, h }) catch @panic("oom");
            manifest.writer().print("{s}  {s}\n", .{ h, name }) catch @panic("oom");
        }
        w.print("\nThe pin for {s}:\n\n```\n{s}```\n", .{ pin_target, pinText(a, gh.repo, version, pin) }) catch @panic("oom");
        w.print("\nVerify a download (needs the GitHub CLI and cosign), for a file F of this release:\n\n```\ngh attestation verify F -R {s} --signer-workflow {s}/.github/workflows/release.yml\ncosign verify-blob --bundle F.sigstore.json --certificate-identity https://github.com/{s}/.github/workflows/release.yml@refs/heads/main --certificate-oidc-issuer {s} F\n```\n\nThe two `mopm_<version>_<arch>.deb` files install on Debian and Ubuntu (`sudo apt install ./mopm_<version>_amd64.deb`); each is built from the binary in the linux tarball of the same architecture.\n\nmacOS binaries are not yet code-signed or notarized by Apple; see RELEASING.md.\n", .{ gh.repo, gh.repo, gh.repo, oidc_issuer }) catch @panic("oom");
        writeInto(a, nd, "release-notes.md", notes.items);
        writeInto(a, nd, "pin.txt", pinText(a, gh.repo, version, pin));
        // Only what a push signed can be published: a dry run writes no manifest, and publish refuses without one.
        if (is_push) writeInto(a, nd, "verified.sha256", manifest.items);
    }
    out("verified {s} at {s}: three tarballs, two .debs and SHA256SUMS, hashes match, attestations accepted, layout exact, each .deb the one its tarball's binary makes, commit on main.\n", .{ tag, sha });
    out("prerelease: {s}\nthe pin for {s}:\n{s}", .{ if (prerelease) "true" else "false", pin_target, pinText(a, gh.repo, version, pin) });
}

fn writeInto(a: Allocator, dir_path: []const u8, name: []const u8, data: []const u8) void {
    const path = std.fs.path.join(a, &.{ dir_path, name }) catch @panic("oom");
    std.fs.cwd().writeFile(path, data) catch |err| die("cannot write {s}: {s}", .{ path, @errorName(err) });
}

// ---- verify (a published release) ------------------------------------------------------

/// The .deb metadata as the repository held it at `sha` (the commit of the release's tag), read with `gh api` as raw file
/// bytes (not trimmed: a changed final newline is another .deb).
fn packagingAt(gh: Gh, tag: []const u8, sha: []const u8) release_debs.Metadata {
    const a = gh.a;
    var texts: [3][]const u8 = undefined;
    for (release_debs.metadata_files, 0..) |name, i| {
        const path = std.fmt.allocPrint(a, "repos/{s}/contents/{s}/{s}?ref={s}", .{ gh.repo, release_debs.default_packaging, name, sha }) catch @panic("oom");
        const r = gh.run(&.{ "api", path, "-H", "Accept: application/vnd.github.raw+json" });
        if (!r.ok) die("cannot read {s}/{s} as {s} had it ({s}): {s}", .{ release_debs.default_packaging, name, tag, sha, std.mem.trim(u8, r.stderr, " \r\n") });
        texts[i] = r.stdout;
    }
    return .{ .control = texts[0], .copyright = texts[1], .lintian_overrides = texts[2] };
}

fn verifyCmd(gh_in: Gh, version: []const u8, dir_path: []const u8, expect: ?[]const u8) void {
    if (!validVersion(version)) die("'{s}' is not <major>.<minor>.<patch>[-suffix] (no leading v)", .{version});
    if (release_debs.predatesDebs(version)) die("v{s} is older than v0.0.6, the first release with .deb files; verify checks the .debs of a release and cannot check this one (it would find them missing). Nothing was downloaded.", .{version});
    var gh = gh_in;
    const a = gh.a;
    const tag = std.fmt.allocPrint(a, "v{s}", .{version}) catch @panic("oom");

    const state = gh.must(&.{ "release", "view", tag, "-R", gh.repo, "--json", "isDraft,isPrerelease", "--jq", "\"\\(.isDraft) \\(.isPrerelease)\"" });
    const want_state = if (std.mem.indexOfScalar(u8, version, '-') != null) "false true" else "false false";
    if (!std.mem.eql(u8, state, want_state)) die("the release {s} has (draft prerelease) = '{s}', expected '{s}'", .{ tag, state, want_state });

    // The release's asset list is exactly the twelve files (by name, before any download).
    const want = wantAssets(a, version);
    {
        const listing = gh.must(&.{ "release", "view", tag, "-R", gh.repo, "--json", "assets", "--jq", ".assets[].name" });
        var listed = std.ArrayList([]const u8).init(a);
        var names = std.mem.splitScalar(u8, listing, '\n');
        while (names.next()) |n| {
            const t = std.mem.trim(u8, n, " \r");
            if (t.len != 0) listed.append(t) catch @panic("oom");
        }
        for (listed.items) |n| {
            var known = false;
            for (want) |w| {
                if (std.mem.eql(u8, n, w)) known = true;
            }
            if (!known) die("the release {s} has an unexpected asset {s}", .{ tag, n });
        }
        for (want) |w| {
            var found = false;
            for (listed.items) |n| {
                if (std.mem.eql(u8, n, w)) found = true;
            }
            if (!found) die("the release {s} lacks the asset {s}", .{ tag, w });
        }
        if (listed.items.len != want.len) die("the release {s} lists {d} assets, expected exactly {d} (a name is repeated)", .{ tag, listed.items.len, want.len });
    }

    const tag_sha = commitOf(gh, tag);
    requireOnMain(gh, tag, tag_sha);
    // The .deb metadata is the release's own, read at its tag: a later change to packaging/deb does not make an old release fail. --packaging names a directory instead.
    if (!gh.packaging_given) gh.meta = packagingAt(gh, tag, tag_sha);

    std.fs.cwd().makePath(dir_path) catch |err| die("cannot make {s}: {s}", .{ dir_path, @errorName(err) });
    {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| die("cannot open {s}: {s}", .{ dir_path, @errorName(err) });
        defer dir.close();
        var empty_it = dir.iterate();
        if (empty_it.next() catch null) |_| die("{s} is not empty; give an empty directory", .{dir_path});
    }
    _ = gh.must(&.{ "release", "download", tag, "-R", gh.repo, "-D", dir_path, "--pattern", "mopm-*.tar.gz", "--pattern", "mopm_*.deb", "--pattern", sums_name, "--pattern", "*" ++ bundle_suffix });

    // The workflow ran for a push to main, so that is the ref the attestations name.
    const pin = checkAssets(gh, version, dir_path, .{ .ref = "refs/heads/main", .sha = tag_sha, .trigger = "push" });
    if (expect) |e| {
        if (!std.mem.eql(u8, e, pin.sha256)) die("{s} has sha256 {s}, not the expected {s}", .{ pin_target, pin.sha256, e });
    }
    out("verified {s}: three tarballs, two .debs and SHA256SUMS, hashes match, attestations accepted, layout exact, each .deb the one its tarball's binary makes.\n", .{tag});
    out("the pin for {s}:\n{s}", .{ pin_target, pinText(a, gh.repo, version, pin) });
}

// ---- publish ---------------------------------------------------------------------------

fn publishCmd(gh: Gh, version: []const u8, dir_path: []const u8, verified: []const u8, notes: []const u8) void {
    const a = gh.a;
    if (!validVersion(version)) die("'{s}' is not <major>.<minor>.<patch>[-suffix] (no leading v)", .{version});
    const tag = std.fmt.allocPrint(a, "v{s}", .{version}) catch @panic("oom");
    const prerelease = std.mem.indexOfScalar(u8, version, '-') != null;
    const want = wantAssets(a, version);

    // Never publish an older release after a newer one exists: GitHub's "latest" is the newest created, and
    // install.sh installs the latest, so users would be moved back to older code.
    {
        const core = version[0 .. std.mem.indexOfScalar(u8, version, '-') orelse version.len];
        const last_dot = std.mem.lastIndexOfScalar(u8, core, '.').?;
        const base = core[0..last_dot];
        const mine = canonical(core[last_dot + 1 ..]) orelse die("'{s}' has no plain patch number", .{version});
        if (highest(base, tagNames(gh, base))) |h| {
            if (h.patch > mine) die("superseded: the release {s} exists and is newer than {s}; publishing the older one would make it the latest. Nothing was changed.", .{ h.name, tag });
        }
    }

    // Exactly the files that were verified: the twelve names, each with the hash verify-dir recorded.
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| die("cannot open {s}: {s}", .{ dir_path, @errorName(err) });
    defer dir.close();
    checkNames(a, dir, dir_path, want);
    {
        const manifest = std.fs.cwd().readFileAlloc(a, verified, 1 << 16) catch |err| die("cannot read {s}: {s}", .{ verified, @errorName(err) });
        var seen: usize = 0;
        var lines = std.mem.splitScalar(u8, manifest, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (line.len < 67 or !std.mem.eql(u8, line[64..66], "  ")) die("malformed line in {s}: {s}", .{ verified, line });
            const file = line[66..];
            var known = false;
            for (want) |w| {
                if (std.mem.eql(u8, w, file)) known = true;
            }
            if (!known) die("{s} lists {s}, which is not one of the twelve files", .{ verified, file });
            const got = sha256Hex(a, readAll(a, dir, file));
            if (!std.mem.eql(u8, got, line[0..64])) die("{s} is not the file that was verified: sha256 {s}, verified {s}", .{ file, got, line[0..64] });
            seen += 1;
        }
        if (seen != want.len) die("{s} lists {d} files, expected {d}", .{ verified, seen, want.len });
    }

    var missing = std.ArrayList([]const u8).init(a);
    if (findRelease(gh, tag)) |rel| {
        if (rel.draft) die("the release {s} exists as a draft; remove it by hand before a release run can create it", .{tag});
        const state = gh.must(&.{ "release", "view", tag, "-R", gh.repo, "--json", "isDraft,isPrerelease,assets" });
        const View = struct { isPrerelease: bool = false, assets: []const struct { name: []const u8 = "" } = &.{} };
        const view = std.json.parseFromSlice(View, a, state, .{ .ignore_unknown_fields = true }) catch |err| die("cannot read the release {s}: {s}", .{ tag, @errorName(err) });
        if (view.value.isPrerelease != prerelease) die("the release {s} has prerelease = {}, its version calls for {}", .{ tag, view.value.isPrerelease, prerelease });
        // Every asset it holds must be one of ours, byte for byte, before anything is added.
        const held_path = std.fmt.allocPrint(a, "{s}.held", .{dir_path}) catch @panic("oom");
        std.fs.cwd().deleteTree(held_path) catch |err| die("cannot clear {s}: {s}", .{ held_path, @errorName(err) });
        std.fs.cwd().makePath(held_path) catch |err| die("cannot make {s}: {s}", .{ held_path, @errorName(err) });
        var held_dir = std.fs.cwd().openDir(held_path, .{ .iterate = true }) catch |err| die("cannot open {s}: {s}", .{ held_path, @errorName(err) });
        defer held_dir.close();
        for (view.value.assets) |asset| {
            var known = false;
            for (want) |w| {
                if (std.mem.eql(u8, w, asset.name)) known = true;
            }
            if (!known) die("the release {s} holds the asset {s}, which is not one of the twelve files; nothing was changed", .{ tag, asset.name });
        }
        if (view.value.assets.len != 0) _ = gh.must(&.{ "release", "download", tag, "-R", gh.repo, "-D", held_path, "--pattern", "*" });
        for (view.value.assets) |asset| {
            const theirs = readAll(a, held_dir, asset.name);
            const ours = readAll(a, dir, asset.name);
            if (!std.mem.eql(u8, theirs, ours)) die("the release {s} holds {s}, which differs from the verified file; nothing was changed", .{ tag, asset.name });
        }
        for (want) |w| {
            var held = false;
            for (view.value.assets) |asset| {
                if (std.mem.eql(u8, w, asset.name)) held = true;
            }
            if (!held) missing.append(w) catch @panic("oom");
        }
        if (missing.items.len == 0) {
            out("the release {s} exists with all twelve assets, identical to the verified files: nothing to do.\n", .{tag});
            return;
        }
        var args = std.ArrayList([]const u8).init(a);
        args.appendSlice(&.{ "release", "upload", tag }) catch @panic("oom");
        for (missing.items) |m| args.append(std.fs.path.join(a, &.{ dir_path, m }) catch @panic("oom")) catch @panic("oom");
        args.appendSlice(&.{ "-R", gh.repo }) catch @panic("oom");
        _ = gh.must(args.items);
        out("the release {s} existed with {d} of the twelve assets, all identical; added the {d} it lacked.\n", .{ tag, view.value.assets.len, missing.items.len });
        return;
    }

    var args = std.ArrayList([]const u8).init(a);
    args.appendSlice(&.{ "release", "create", tag }) catch @panic("oom");
    for (want) |w| args.append(std.fs.path.join(a, &.{ dir_path, w }) catch @panic("oom")) catch @panic("oom");
    args.appendSlice(&.{ "-R", gh.repo, "--verify-tag", "--title", std.fmt.allocPrint(a, "mopm {s}", .{version}) catch @panic("oom"), "--notes-file", notes }) catch @panic("oom");
    if (prerelease) args.append("--prerelease") catch @panic("oom");
    _ = gh.must(args.items);
    out("created the release {s} with the twelve verified files.\n", .{tag});
}

// ---- main ------------------------------------------------------------------------------

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);

    var gh_exe: []const u8 = "gh";
    var repo: []const u8 = "komira-ai/mopm";
    var expect: ?[]const u8 = null;
    var sha: ?[]const u8 = null;
    var source_ref: ?[]const u8 = null;
    var notes_out: ?[]const u8 = null;
    var trigger: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var version_file: []const u8 = "VERSION";
    var verified: ?[]const u8 = null;
    var notes: ?[]const u8 = null;
    var expect_version: ?[]const u8 = null;
    var cosign: []const u8 = "cosign";
    var cosign_retry_ms: u32 = default_cosign_retry_ms;
    var cosign_wait_budget_ms: u64 = max_cosign_wait_ms;
    var packaging: []const u8 = release_debs.default_packaging;
    var packaging_given = false;
    var git_exe: []const u8 = "git";
    var internal_repo: ?[]const u8 = null;
    var submodule: ?[]const u8 = null;
    var bump_version: ?[]const u8 = null;
    var workdir: ?[]const u8 = null;
    var tap_repo: ?[]const u8 = null;
    var formula_name: ?[]const u8 = null;
    var asset: []const u8 = "";
    var formula_file: ?[]const u8 = null;
    var pos = std.ArrayList([]const u8).init(a);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.startsWith(u8, arg, "--")) {
            i += 1;
            if (i >= argv.len) usage();
            const v = argv[i];
            if (std.mem.eql(u8, arg, "--gh")) {
                gh_exe = v;
            } else if (std.mem.eql(u8, arg, "--cosign")) {
                cosign = v;
            } else if (std.mem.eql(u8, arg, "--cosign-retry-ms")) {
                cosign_retry_ms = std.fmt.parseInt(u32, v, 10) catch usage();
            } else if (std.mem.eql(u8, arg, "--cosign-wait-budget-ms")) {
                cosign_wait_budget_ms = std.fmt.parseInt(u64, v, 10) catch usage();
            } else if (std.mem.eql(u8, arg, "--packaging")) {
                packaging = v;
                packaging_given = true;
            } else if (std.mem.eql(u8, arg, "--git")) {
                git_exe = v;
            } else if (std.mem.eql(u8, arg, "--internal-repo")) {
                internal_repo = v;
            } else if (std.mem.eql(u8, arg, "--submodule")) {
                submodule = v;
            } else if (std.mem.eql(u8, arg, "--version")) {
                bump_version = v;
            } else if (std.mem.eql(u8, arg, "--workdir")) {
                workdir = v;
            } else if (std.mem.eql(u8, arg, "--tap-repo")) {
                tap_repo = v;
            } else if (std.mem.eql(u8, arg, "--formula")) {
                formula_name = v;
            } else if (std.mem.eql(u8, arg, "--asset")) {
                asset = v;
            } else if (std.mem.eql(u8, arg, "--formula-file")) {
                formula_file = v;
            } else if (std.mem.eql(u8, arg, "--expect-version")) {
                expect_version = v;
            } else if (std.mem.eql(u8, arg, "--repo")) {
                repo = v;
            } else if (std.mem.eql(u8, arg, "--expect-sha256")) {
                expect = v;
            } else if (std.mem.eql(u8, arg, "--sha")) {
                sha = v;
            } else if (std.mem.eql(u8, arg, "--source-ref")) {
                source_ref = v;
            } else if (std.mem.eql(u8, arg, "--trigger")) {
                trigger = v;
            } else if (std.mem.eql(u8, arg, "--notes-out")) {
                notes_out = v;
            } else if (std.mem.eql(u8, arg, "--out")) {
                out_path = v;
            } else if (std.mem.eql(u8, arg, "--version-file")) {
                version_file = v;
            } else if (std.mem.eql(u8, arg, "--verified")) {
                verified = v;
            } else if (std.mem.eql(u8, arg, "--notes")) {
                notes = v;
            } else usage();
        } else try pos.append(arg);
    }
    if (pos.items.len == 0) usage();
    const gh = Gh{ .a = a, .exe = gh_exe, .repo = repo, .cosign = cosign, .cosign_retry_ms = cosign_retry_ms, .cosign_wait_budget_ms = cosign_wait_budget_ms, .packaging = packaging, .packaging_given = packaging_given };
    const cmd = pos.items[0];
    const n = pos.items.len;
    if (std.mem.eql(u8, cmd, "plan")) {
        if (n != 1) usage();
        return planCmd(gh, sha, version_file, out_path);
    }
    if (std.mem.eql(u8, cmd, "tag")) {
        if (n != 1) usage();
        return tagCmd(gh, sha orelse usage(), expect_version, version_file, out_path);
    }
    if (std.mem.eql(u8, cmd, "verify-dir")) {
        if (n != 3) usage();
        return verifyDirCmd(gh, pos.items[1], pos.items[2], sha orelse usage(), source_ref orelse usage(), trigger orelse usage(), notes_out);
    }
    if (std.mem.eql(u8, cmd, "verify")) {
        if (n != 3 or sha != null or trigger != null) usage();
        return verifyCmd(gh, pos.items[1], pos.items[2], expect);
    }
    if (std.mem.eql(u8, cmd, "publish")) {
        if (n != 3) usage();
        return publishCmd(gh, pos.items[1], pos.items[2], verified orelse usage(), notes orelse usage());
    }
    if (std.mem.eql(u8, cmd, "bump-internal")) {
        if (n != 1) usage();
        return bump_internal.run(a, .{
            .gh = gh_exe,
            .git = git_exe,
            .repo = repo,
            .internal_repo = internal_repo orelse usage(),
            .submodule = submodule orelse usage(),
            .version = bump_version orelse usage(),
            .sha = sha orelse usage(),
            .workdir = workdir orelse usage(),
        });
    }
    if (std.mem.eql(u8, cmd, "tap")) {
        if (n != 1) usage();
        return tap.run(a, .{
            .gh = gh_exe,
            .git = git_exe,
            .repo = repo,
            .tap_repo = tap_repo orelse usage(),
            .formula = formula_name orelse usage(),
            .asset = asset,
            .version = bump_version orelse usage(),
            .formula_file = formula_file orelse usage(),
            .workdir = workdir orelse usage(),
        });
    }
    usage();
}

/// The version the candidate was built and tested as (plan, before the build) must be the version the tag takes.
fn requireExpected(expect: ?[]const u8, version: []const u8) void {
    const e = expect orelse return;
    if (!std.mem.eql(u8, e, version)) die("the candidate was built and tested as {s}, but the next release is {s} (another release landed meanwhile); nothing was tagged", .{ e, version });
}
