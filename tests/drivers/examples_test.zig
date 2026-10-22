//! The worked examples of docs/examples.md, run by the built CLI, as a Buck2 test that runs on the test farm.
//!
//! Each directory under examples/ is one example of the page. The page quotes every file of them (the site's
//! test/docs-examples.test.ts holds the page to the files); this driver holds the files to mopm: what the page says a
//! command prints is the file under examples/<name>/expected, and what the page says a command refuses is refused here
//! with the words the page gives. A copy of examples/ is made first, so the committed files are never written to.
//!
//!   greeter    a library: `mopm metadata` and `mopm test --list`
//!   app        a program with a path dependency: `mopm lock` (offline) writes the committed mopm.lock, `mopm tree`
//!   workspace  four packages in one repository, joined by path dependencies at two depths, and no [workspace] table
//!   testing    discovery: bare and self-hosted files, a helper, a test beside the source, an ignored test, a selection
//!   publish    `mopm pack` and `mopm publish --dry-run` (the .mojoc is a stand-in file; no registry is contacted)
//!   toolchain  `[package] mojo`: a version 2 lock with the toolchain closure hash, the unit graph, an unpinned version
//!
//! The last part of each example is a refusal, so that a check that cannot fail is not what holds the page: the same
//! package with one thing changed must be refused, with the message the page quotes.
//!
//! Run by Buck2 (//:examples) from the repository root; MOPM is the built CLI. Nothing here needs Mojo or a network.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

/// A registry nothing listens on: a command that reaches for it fails, so a pass shows that it did not.
const dead_registry = "http://127.0.0.1:1";

const Out = struct { code: u8, stdout: []u8, stderr: []u8 };

const Cx = struct {
    a: Allocator,
    rep: *h.Report,
    mopm: []const u8,
    /// The copy of examples/ the commands run in.
    tree: []const u8,

    /// `mopm <args>` in `dir` (relative to the copy); stdout and stderr apart.
    fn run(cx: *Cx, dir: []const u8, args: []const []const u8) !Out {
        const argv = try cx.a.alloc([]const u8, args.len + 1);
        argv[0] = cx.mopm;
        @memcpy(argv[1..], args);
        const cwd = try h.join(cx.a, &.{ cx.tree, dir });
        const r = try std.process.Child.run(.{ .allocator = cx.a, .argv = argv, .cwd = cwd, .max_output_bytes = 1 << 22 });
        return .{ .code = switch (r.term) {
            .Exited => |code| code,
            else => 255,
        }, .stdout = r.stdout, .stderr = r.stderr };
    }

    /// A file of the committed examples/ (what the page quotes).
    fn committed(cx: *Cx, rel: []const u8) ![]u8 {
        return h.readFile(cx.a, try h.join(cx.a, &.{ "examples", rel }));
    }

    /// A file of the copy.
    fn copied(cx: *Cx, rel: []const u8) ![]u8 {
        return h.readFile(cx.a, try h.join(cx.a, &.{ cx.tree, rel }));
    }

    /// Writes a file of the copy. The files of a copy are read-only, as staged: one that is there is removed first.
    fn put(cx: *Cx, rel: []const u8, bytes: []const u8) !void {
        const path = try h.join(cx.a, &.{ cx.tree, rel });
        std.fs.cwd().deleteFile(path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        try h.writeFile(path, bytes);
    }

    fn fmt(cx: *Cx, comptime f: []const u8, args: anytype) ![]u8 {
        return std.fmt.allocPrint(cx.a, f, args);
    }

    /// `mopm <args>` in `dir` must exit 0, print on stdout exactly the committed file `expected`, and nothing on stderr.
    fn prints(cx: *Cx, label: []const u8, dir: []const u8, args: []const []const u8, expected: []const u8) !void {
        const r = try cx.run(dir, args);
        const name = try cx.fmt("{s}: exit status 0 and no stderr", .{label});
        cx.rep.check(name, r.code == 0 and r.stderr.len == 0, try cx.fmt("exit {d}: {s}", .{ r.code, r.stderr }));
        cx.rep.same(label, try cx.committed(expected), r.stdout);
    }

    /// `mopm <args>` in `dir` must exit with `code` and say `words` on stderr.
    fn refuses(cx: *Cx, label: []const u8, dir: []const u8, args: []const []const u8, code: u8, words: []const u8) !void {
        const r = try cx.run(dir, args);
        cx.rep.check(label, r.code == code and h.contains(r.stderr, words), try cx.fmt("exit {d}, stdout {s}, stderr {s}", .{ r.code, r.stdout, r.stderr }));
    }

    /// A manifest of the copy, `base` with `from` replaced by `to`, written as <dir>/mopm.toml.
    fn variant(cx: *Cx, dir: []const u8, base: []const u8, from: []const u8, to: []const u8) !void {
        const text = try cx.committed(base);
        if (!h.contains(text, from)) {
            cx.rep.check(try cx.fmt("the variant {s} changes {s}", .{ dir, base }), false, try cx.fmt("{s} does not hold {s}", .{ base, from }));
        }
        try cx.put(try h.join(cx.a, &.{ dir, "mopm.toml" }), try std.mem.replaceOwned(u8, cx.a, text, from, to));
    }
};

fn isHexLower(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

/// `s` with every run of exactly 64 lowercase hex digits written `<sha256>`, and the digits of a line `  size N` and of
/// the `(N bytes` of a `would upload` line written `<n>`: the parts of a packed file that depend on the packer's bytes.
fn scrub(a: Allocator, s: []const u8) ![]u8 {
    var hashed = std.ArrayList(u8).init(a);
    var i: usize = 0;
    while (i < s.len) {
        var j = i;
        while (j < s.len and isHexLower(s[j])) j += 1;
        if (j - i == 64) {
            try hashed.appendSlice("<sha256>");
            i = j;
        } else if (j > i) {
            try hashed.appendSlice(s[i..j]);
            i = j;
        } else {
            try hashed.append(s[i]);
            i += 1;
        }
    }
    var out = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, hashed.items, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append('\n');
        first = false;
        if (std.mem.startsWith(u8, line, "  size ")) {
            try out.appendSlice("  size <n>");
        } else if (std.mem.indexOf(u8, line, " (")) |open| {
            var end = open + 2;
            while (end < line.len and line[end] >= '0' and line[end] <= '9') end += 1;
            if (end > open + 2 and std.mem.startsWith(u8, line[end..], " bytes,")) {
                try out.appendSlice(line[0 .. open + 2]);
                try out.appendSlice("<n>");
                try out.appendSlice(line[end..]);
            } else try out.appendSlice(line);
        } else try out.appendSlice(line);
    }
    return out.items;
}

test "scrub: hashes and sizes, and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sha = "0123456789abcdef" ** 4;
    const text = try std.fmt.allocPrint(a, "packed x\n  sha256 {s}\n  size 4096\nwould upload y (123 bytes, sha256 {s})\nnote (see below)\n{s}0\n", .{ sha, sha, sha });
    try std.testing.expectEqualStrings("packed x\n  sha256 <sha256>\n  size <n>\nwould upload y (<n> bytes, sha256 <sha256>)\nnote (see below)\n" ++ sha ++ "0\n", try scrub(a, text));
}

// ------------------------------------------------------------------ greeter

fn greeter(cx: *Cx) !void {
    try cx.prints("greeter: mopm metadata", "greeter", &.{"metadata"}, "greeter/expected/metadata.json");
    try cx.prints("greeter: mopm test --list", "greeter", &.{ "test", "--list" }, "greeter/expected/tests.txt");
    // The display fields are checked; the page says a homepage or keywords key is not (yet) part of the format.
    try cx.variant("greeter_homepage", "greeter/mopm.toml", "license = \"Apache-2.0\"\n", "license = \"Apache-2.0\"\nhomepage = \"https://example.com/greeter\"\n");
    try cx.refuses("greeter: homepage is an unknown key of [package]", "greeter_homepage", &.{"metadata"}, 1, "unknown key 'homepage' in [package]");
    try cx.variant("greeter_keywords", "greeter/mopm.toml", "license = \"Apache-2.0\"\n", "license = \"Apache-2.0\"\nkeywords = [\"hello\"]\n");
    try cx.refuses("greeter: keywords is an unknown key of [package]", "greeter_keywords", &.{"metadata"}, 1, "unknown key 'keywords' in [package]");
    try cx.variant("greeter_name", "greeter/mopm.toml", "name = \"greeter\"", "name = \"Greeter\"");
    try cx.refuses("greeter: a package name is a lowercase identifier", "greeter_name", &.{"metadata"}, 1, "package name 'Greeter' must start with a lowercase letter");
    try cx.variant("greeter_version", "greeter/mopm.toml", "version = \"0.1.0\"", "version = \"0.1\"");
    try cx.refuses("greeter: a version is MAJOR.MINOR.PATCH", "greeter_version", &.{"metadata"}, 1, "is not a semantic version");
    try cx.variant("greeter_typo", "greeter/mopm.toml", "[targets]", "[target]");
    try cx.refuses("greeter: an unknown table is refused", "greeter_typo", &.{"metadata"}, 1, "unknown key 'target' in mopm.toml");
}

// ---------------------------------------------------------------------- app

fn app(cx: *Cx) !void {
    // The committed lock is what `mopm lock` writes: delete the copy's, lock, and compare the bytes.
    try std.fs.cwd().deleteFile(try h.join(cx.a, &.{ cx.tree, "app/mopm.lock" }));
    try cx.prints("app: mopm lock (offline) says what it added", "app", &.{ "lock", "--registry", dead_registry }, "app/expected/lock.txt");
    cx.rep.same("app: the lock written is the committed mopm.lock", try cx.committed("app/mopm.lock"), try cx.copied("app/mopm.lock"));
    const again = try cx.run("app", &.{ "lock", "--registry", dead_registry });
    cx.rep.check("app: locking again changes nothing", again.code == 0 and std.mem.eql(u8, again.stdout, "locked 1 packages for mojo 1.0.0\n"), again.stdout);
    try cx.prints("app: mopm tree", "app", &.{"tree"}, "app/expected/tree.txt");
    // A registry requirement needs the registry: with it down, the same project is not locked.
    try cx.variant("app_registry", "app/mopm.toml", "# http_client = \"0.4\"", "http_client = \"0.4\"");
    try cx.refuses("app: a registry dependency needs the registry", "app_registry", &.{ "lock", "--registry", dead_registry }, 1, "cannot reach http://127.0.0.1:1");
}

// ---------------------------------------------------------------- workspace

fn workspace(cx: *Cx) !void {
    try std.fs.cwd().deleteFile(try h.join(cx.a, &.{ cx.tree, "workspace/mopm.lock" }));
    try cx.prints("workspace: mopm lock locks the members at every depth", "workspace", &.{ "lock", "--registry", dead_registry }, "workspace/expected/lock.txt");
    cx.rep.same("workspace: the lock written is the committed mopm.lock", try cx.committed("workspace/mopm.lock"), try cx.copied("workspace/mopm.lock"));
    try cx.prints("workspace: mopm tree", "workspace", &.{"tree"}, "workspace/expected/tree.txt");
    // Members below the root are what a build system takes: the unit graph has a unit for each.
    const plan = try cx.run("workspace", &.{ "plan", "--unit-graph", "--locked" });
    const units = [_][]const u8{ "\"id\": \"util@0.1.0#mojo1.0.0/lib\"", "\"id\": \"core@0.1.0#mojo1.0.0/lib\"", "\"id\": \"testkit@0.1.0#mojo1.0.0/lib\"", "\"id\": \"app@0.2.0#mojo1.0.0/bin:run\"" };
    var all = plan.code == 0;
    for (units) |u| all = all and h.contains(plan.stdout, u);
    cx.rep.check("workspace: mopm plan has a unit for each member and for the program", all, try cx.fmt("exit {d}: {s}{s}", .{ plan.code, plan.stdout, plan.stderr }));
    // There is no [workspace] table: members are path dependencies.
    const manifest = try cx.committed("workspace/mopm.toml");
    try cx.put("workspace_table/mopm.toml", try std.mem.concat(cx.a, u8, &.{ manifest, "\n[workspace]\nmembers = [\"core\"]\n" }));
    try cx.refuses("workspace: a [workspace] table is refused", "workspace_table", &.{"metadata"}, 1, "unknown key 'workspace' in mopm.toml");
    // A dependency may have a path and a version: the path is what lock, tree and plan use, and the version is only
    // what pack publishes. Same bytes of lock and tree as with the path alone, and no request to the dead registry.
    try h.copyTree(cx.a, try h.join(cx.a, &.{ cx.tree, "workspace" }), try h.join(cx.a, &.{ cx.tree, "workspace_both" }));
    try cx.variant("workspace_both", "workspace/mopm.toml", "core = { path = \"core\" }", "core = { path = \"core\", version = \"0.1\" }");
    try std.fs.cwd().deleteFile(try h.join(cx.a, &.{ cx.tree, "workspace_both/mopm.lock" }));
    try cx.prints("workspace: a dependency with a path and a version is locked at its path, offline", "workspace_both", &.{ "lock", "--registry", dead_registry }, "workspace/expected/lock.txt");
    cx.rep.same("workspace: the lock of a dependency with a path and a version is the lock of the path alone", try cx.committed("workspace/mopm.lock"), try cx.copied("workspace_both/mopm.lock"));
    try cx.prints("workspace: mopm tree of a dependency with a path and a version", "workspace_both", &.{"tree"}, "workspace/expected/tree.txt");
    // The version must be a version requirement.
    try cx.variant("workspace_badreq", "workspace/mopm.toml", "core = { path = \"core\" }", "core = { path = \"core\", version = \"one\" }");
    try cx.refuses("workspace: the version of a dependency with a path must be a requirement", "workspace_badreq", &.{"metadata"}, 1, "dependency 'core' has an invalid version requirement 'one'");
    // One name, one path: util is core's dependency at util, and here also testkit's directory.
    try h.copyTree(cx.a, try h.join(cx.a, &.{ cx.tree, "workspace" }), try h.join(cx.a, &.{ cx.tree, "workspace_other" }));
    try cx.variant("workspace_other", "workspace/mopm.toml", "util = { path = \"util\" }", "util = { path = \"testkit\" }");
    try cx.refuses("workspace: a name cannot be two directories", "workspace_other", &.{ "lock", "--registry", dead_registry }, 1, "one name, one path");
}

// ------------------------------------------------------------------ testing

fn testing(cx: *Cx) !void {
    try cx.prints("testing: the tests found, in path then source order, the ignored one left out", "testing", &.{ "test", "--list" }, "testing/expected/list.txt");
    try cx.prints("testing: a selection by substring of <file>::<test>", "testing", &.{ "test", "--list", "--", "double" }, "testing/expected/list-select.txt");
    try cx.prints("testing: --ignored lists the ignored test only", "testing", &.{ "test", "--list", "--ignored" }, "testing/expected/list-ignored.txt");
    // The ignore directive needs its reason and its issue.
    const suite = try cx.committed("testing/tests/test_suite.mojo");
    try cx.put("testing_no_issue/tests/test_suite.mojo", try std.mem.replaceOwned(u8, cx.a, suite, "# mopm: ignore \"needs the network\" #12", "# mopm: ignore \"needs the network\""));
    try cx.put("testing_no_issue/mopm.toml", try cx.committed("testing/mopm.toml"));
    try cx.refuses("testing: an ignore with no issue reference is refused", "testing_no_issue", &.{ "test", "--list" }, 2, "needs a reason in double quotes and an issue reference");
}

// ------------------------------------------------------------------ publish

const stand_in = "stand-in for the output of `mojo precompile`\n";

fn publish(cx: *Cx) !void {
    try cx.put("publish/slug.mojoc", stand_in);
    const pack = try cx.run("publish", &.{ "pack", "--compiler", "1.0.0", "--mojoc", "linux-64=slug.mojoc", "-o", "dist" });
    cx.rep.check("publish: mopm pack exits 0", pack.code == 0 and pack.stderr.len == 0, try cx.fmt("exit {d}: {s}", .{ pack.code, pack.stderr }));
    cx.rep.same("publish: mopm pack names the file and its digests", try cx.committed("publish/expected/pack.txt"), try scrub(cx.a, pack.stdout));
    const conda = try cx.copied("publish/dist/linux-64/mojo-slug-1.2.0-mojo1.0.0_0.conda");
    cx.rep.check("publish: the .conda is written where pack said", conda.len > 0, "empty");

    const dry = try cx.run("publish", &.{ "publish", "--compiler", "1.0.0", "--mojoc", "linux-64=slug.mojoc", "--dry-run", "--registry", dead_registry });
    cx.rep.check("publish: --dry-run exits 0 with no registry", dry.code == 0 and dry.stderr.len == 0, try cx.fmt("exit {d}: {s}", .{ dry.code, dry.stderr }));
    cx.rep.same("publish: --dry-run says what it would send", try cx.committed("publish/expected/publish-dry-run.txt"), try scrub(cx.a, dry.stdout));

    // The display fields are not part of the package file: without description, license and repository, the same file.
    var plain = try cx.committed("publish/mopm.toml");
    for ([_][]const u8{ "description = \"Turn a title into a URL slug\"\n", "license = \"Apache-2.0\"\n", "repository = \"https://github.com/example/slug\"\n" }) |line| {
        if (!h.contains(plain, line)) cx.rep.check("publish: the manifest holds the display field line", false, line);
        plain = try std.mem.replaceOwned(u8, cx.a, plain, line, "");
    }
    try cx.put("publish_plain/mopm.toml", plain);
    try cx.put("publish_plain/slug.mojoc", stand_in);
    const bare = try cx.run("publish_plain", &.{ "pack", "--compiler", "1.0.0", "--mojoc", "linux-64=slug.mojoc", "-o", "dist" });
    cx.rep.check("publish: pack does not send description, license or repository (the digests are the same without them)", bare.code == 0 and std.mem.eql(u8, bare.stdout, pack.stdout), try cx.fmt("exit {d}: {s}\n--- with\n{s}", .{ bare.code, bare.stdout, pack.stdout }));

    // What pack refuses, each with the one change that makes the example refuse it.
    const args = [_][]const u8{ "pack", "--compiler", "1.0.0", "--mojoc", "linux-64=slug.mojoc", "-o", "dist" };
    try cx.variant("publish_pre", "publish/mopm.toml", "version = \"1.2.0\"", "version = \"1.2.0-rc.1\"");
    try cx.put("publish_pre/slug.mojoc", stand_in);
    try cx.refuses("publish: a pre-release version cannot be packed", "publish_pre", &args, 1, "must be exactly MAJOR.MINOR.PATCH");
    try cx.variant("publish_path", "publish/mopm.toml", "text_tools = \"0.3\"", "text_tools = { path = \"../text_tools\" }");
    try cx.put("publish_path/slug.mojoc", stand_in);
    try cx.refuses("publish: a path dependency with no version cannot be packed", "publish_path", &args, 1, "dependency 'text_tools' is a path dependency with no version; add 'version' beside its 'path'");
    // With a version beside the path, pack writes the version and not the path: the same package file as the version alone.
    try cx.put("text_tools/mopm.toml", "[package]\nname = \"text_tools\"\nversion = \"0.3.4\"\n\n[toolchain]\nmojo = \"1.0.0\"\n");
    try cx.variant("publish_pathver", "publish/mopm.toml", "text_tools = \"0.3\"", "text_tools = { path = \"../text_tools\", version = \"0.3\" }");
    try cx.put("publish_pathver/slug.mojoc", stand_in);
    const pathver = try cx.run("publish_pathver", &args);
    cx.rep.check("publish: pack of a dependency with a path and a version makes the package of the version alone", pathver.code == 0 and pathver.stderr.len == 0 and std.mem.eql(u8, pathver.stdout, pack.stdout), try cx.fmt("exit {d}: {s}{s}\n--- version alone\n{s}", .{ pathver.code, pathver.stdout, pathver.stderr, pack.stdout }));
    // The package at the path must be a version the requirement accepts.
    try cx.variant("publish_pathver_old", "publish/mopm.toml", "text_tools = \"0.3\"", "text_tools = { path = \"../text_tools\", version = \"0.4\" }");
    try cx.put("publish_pathver_old/slug.mojoc", stand_in);
    try cx.refuses("publish: pack refuses a path whose package does not satisfy the version", "publish_pathver_old", &args, 1, "dependency 'text_tools' requires version \"0.4\", but the package at '../text_tools' is version 0.3.4");
    try cx.variant("publish_native", "publish/mopm.toml", "[targets]", "[native-dependencies]\nzlib = \"1.2\"\n\n[targets]");
    try cx.put("publish_native/slug.mojoc", stand_in);
    try cx.refuses("publish: native dependencies cannot be packed yet", "publish_native", &args, 1, "native dependencies are not packed yet");
    try cx.variant("publish_compiler", "publish/mopm.toml", "mojo = [\"1.0.0\"]", "mojo = [\"1.0.0\"]");
    try cx.put("publish_compiler/slug.mojoc", stand_in);
    const bad_compiler = [_][]const u8{ "pack", "--compiler", "v1", "--mojoc", "linux-64=slug.mojoc", "-o", "dist" };
    try cx.refuses("publish: a compiler is digits and dots", "publish_compiler", &bad_compiler, 1, "an exact Mojo version is digits and dots");
}

// ---------------------------------------------------------------- toolchain

fn toolchain(cx: *Cx) !void {
    try cx.prints("toolchain: mopm lock", "toolchain", &.{ "lock", "--registry", dead_registry }, "toolchain/expected/lock.txt");
    cx.rep.same("toolchain: a version 2 lock with the closure hash of the pinned toolchain", try cx.committed("toolchain/expected/mopm.lock"), try scrub(cx.a, try cx.copied("toolchain/mopm.lock")));
    const plan = try cx.run("toolchain", &.{ "plan", "--unit-graph", "--locked" });
    cx.rep.check("toolchain: mopm plan prints the unit graph of the lock", plan.code == 0 and h.contains(plan.stdout, "\"unit_graph\": 2") and h.contains(plan.stdout, "\"id\": \"pinned@0.1.0#mojo1.0.0/lib\"") and h.contains(plan.stdout, "\"closure_sha256\": \""), try cx.fmt("exit {d}: {s}{s}", .{ plan.code, plan.stdout, plan.stderr }));
    // A Mojo version mopm pins no toolchain for cannot be listed.
    try cx.variant("toolchain_unpinned", "toolchain/mopm.toml", "mojo = [\"1.0.0\"]", "mojo = [\"1.0.0\", \"1.1.0\"]");
    try cx.put("toolchain_unpinned/src/pinned/__init__.mojo", try cx.committed("toolchain/src/pinned/__init__.mojo"));
    try cx.refuses("toolchain: a Mojo version with no pinned toolchain is refused at lock", "toolchain_unpinned", &.{ "lock", "--registry", dead_registry }, 1, "mopm has no pinned toolchain for mojo 1.1.0");
    // The two forms of the pin are not mixed.
    try cx.variant("toolchain_both", "toolchain/mopm.toml", "[targets]", "[toolchain]\nmojo = \"1.0.0\"\n\n[targets]");
    try cx.refuses("toolchain: [package] mojo and [toolchain] together are refused", "toolchain_both", &.{"metadata"}, 1, "mojo is set in [package] and in [toolchain]; keep [package] mojo");
}

test "the worked examples of docs/examples.md: the files are what mopm reads, writes and refuses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var rep = h.Report{};
    try h.watchdog(120);
    const mopm = try h.toolPath(a, "MOPM");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try h.tmpPath(a, &tmp);
    const tree = try h.join(a, &.{ work, "examples" });
    try h.copyTree(a, "examples", tree);

    var cx = Cx{ .a = a, .rep = &rep, .mopm = mopm, .tree = tree };
    h.stage = "greeter";
    try greeter(&cx);
    h.stage = "app";
    try app(&cx);
    h.stage = "workspace";
    try workspace(&cx);
    h.stage = "testing";
    try testing(&cx);
    h.stage = "publish";
    try publish(&cx);
    h.stage = "toolchain";
    try toolchain(&cx);
    try rep.finish();
}
