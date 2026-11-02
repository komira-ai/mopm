//! //:channels_cli: the `channels` program (tools/channels/main.zig) end to end, on files.
//!
//! What it proves, and the defect each check would catch:
//!   - determinism: the same arguments give the same .deb bytes twice, and the bytes are the golden ones (a writer that
//!     put a clock, a path or a directory order into the file would differ between the two runs or from the golden);
//!   - the compare is live: a later mtime, other file bytes, another version give other bytes (a determinism check that
//!     compares a file with itself passes whatever the writer does);
//!   - an existing Release keeps its Origin, Label and Description (the repository is shared); the first Release takes the flags;
//!   - the apt tree after two additions is the golden Packages and Release, byte for byte, the Release lists the size and
//!     sha256 of the files on disk, a second run gives the same tree, and the new .debs are in the pool;
//!   - a channel never moves down: an older version, or the same version with other bytes, is refused with exit 1 and
//!     NOTHING is written (no output directory at all); the same file again is a no-op;
//!   - retention: with --keep 2 the third newest version is dropped from the index; without --keep the newest 25 stay;
//!   - re-indexing with one --arch keeps the published packages of every other architecture the repository lists;
//!   - an architecture given twice, or that is not a name, is refused;
//!   - the formula is the golden one, and a missing platform, a stray tarball of another version or a bad version is
//!     refused with no file written;
//!   - `monotonic` says advance, same, or refuses with exit 1.
//! Each refusal is a known defect (a variant input) and the check requires the refusal for that reason.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

const fx = "tests/channels/fixtures/";
const gold = "tests/channels/golden/";
const mtime = "1700000000";

const World = struct {
    a: Allocator,
    tool: []const u8,
    root: []const u8,

    fn path(w: World, name: []const u8) []const u8 {
        return h.join(w.a, &.{ w.root, name }) catch @panic("oom");
    }

    fn has(w: World, name: []const u8) bool {
        std.fs.cwd().access(w.path(name), .{}) catch return false;
        return true;
    }

    fn read(w: World, name: []const u8) []const u8 {
        return h.readFile(w.a, w.path(name)) catch "";
    }

    fn run(w: World, args: []const []const u8) !h.Ran {
        var env = try h.environ(w.a);
        var argv = std.ArrayList([]const u8).init(w.a);
        try argv.append(w.tool);
        try argv.appendSlice(args);
        return h.run(w.a, argv.items, &env, .{});
    }

    /// `channels deb` for the fixture package; `bin` is the file that becomes /usr/bin/mopm.
    fn deb(w: World, version: []const u8, arch: []const u8, bin: []const u8, time: []const u8, out: []const u8) !h.Ran {
        return w.run(&.{
            "deb",                   "--package", "mopm",
            "--version",             version,     "--arch",
            arch,                    "--maintainer", "mopm authors <apt@mopm.dev>",
            "--homepage",            "https://mopm.dev", "--synopsis",
            "package manager for Mojo", "--description-file", fx ++ "description.txt",
            "--file",                try h.fmt(w.a, "755:usr/bin/mopm:{s}", .{bin}),
            "--file",                "644:usr/share/doc/mopm/copyright:" ++ fx ++ "copyright",
            "--mtime",               time,
            "--out",                 w.path(out),
        });
    }

    /// `channels apt-index` over `debs`.
    fn index(w: World, repo: []const u8, out: []const u8, debs: []const []const u8, extra: []const []const u8) !h.Ran {
        var argv = std.ArrayList([]const u8).init(w.a);
        try argv.appendSlice(&.{ "apt-index", "--repo", w.path(repo), "--out", w.path(out), "--date", mtime, "--origin", "mopm", "--label", "mopm", "--description", "mopm packages" });
        for (debs) |d| try argv.appendSlice(&.{ "--deb", w.path(d) });
        try argv.appendSlice(extra);
        return w.run(argv.items);
    }
};

fn cat(a: Allocator, parts: []const []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    for (parts) |p| try out.appendSlice(p);
    return out.items;
}

fn sha256Line(a: Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return h.fmt(a, "{s}\n", .{std.fmt.bytesToHex(d, .lower)});
}

fn sha256Hex(a: Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return h.fmt(a, "{s}", .{std.fmt.bytesToHex(d, .lower)});
}

/// The words of a shell command line as the release workflow writes it: words split on spaces, "double quotes" group,
/// `$NAME` is replaced from `vars` (an unknown name, a single quote or a backslash is an error: this reads the one line
/// of the render step and nothing more).
fn shellWords(a: Allocator, text: []const u8, vars: []const [2][]const u8) ![]const []const u8 {
    var words = std.ArrayList([]const u8).init(a);
    var cur = std.ArrayList(u8).init(a);
    var in_word = false;
    var quoted = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        switch (ch) {
            '\'', '\\' => return error.UnsupportedShell,
            '"' => {
                quoted = !quoted;
                in_word = true;
            },
            ' ' => {
                if (quoted) {
                    try cur.append(ch);
                } else if (in_word) {
                    try words.append(try cur.toOwnedSlice());
                    in_word = false;
                }
            },
            '$' => {
                var j = i + 1;
                while (j < text.len and (std.ascii.isUpper(text[j]) or text[j] == '_')) j += 1;
                const name = text[i + 1 .. j];
                var found = false;
                for (vars) |v| {
                    if (std.mem.eql(u8, v[0], name)) {
                        try cur.appendSlice(v[1]);
                        found = true;
                    }
                }
                if (!found) return error.UnknownVariable;
                in_word = true;
                i = j - 1;
            },
            else => {
                try cur.append(ch);
                in_word = true;
            },
        }
    }
    if (quoted) return error.UnterminatedQuote;
    if (in_word) try words.append(try cur.toOwnedSlice());
    return words.items;
}

/// What follows the leading comment lines (`# ...`) of the copy of the tap's fixture.
fn withoutHeader(text: []const u8) []const u8 {
    var rest = text;
    while (std.mem.startsWith(u8, rest, "#")) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return "";
        rest = rest[nl + 1 ..];
    }
    return rest;
}

test "channels: determinism, goldens, the apt tree, the formula, and every known defect refused" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = World{ .a = a, .tool = try h.toolPath(a, "CHANNELS"), .root = try h.tmpPath(a, &tmp) };
    var rep = h.Report{};
    const bin = fx ++ "mopm.bin";

    // ---- the .deb: twice, compare; the golden; and the compare is live ------------------------------------------
    {
        const r1 = try w.deb("1.2.3", "amd64", bin, mtime, "one.deb");
        const r2 = try w.deb("1.2.3", "amd64", bin, mtime, "two.deb");
        rep.check("deb: the program succeeds", r1.code == 0 and r2.code == 0, r1.text);
        rep.same("deb: built twice, the two files are the same bytes", w.read("one.deb"), w.read("two.deb"));
        rep.check("deb: the file is not empty and is an ar archive", w.read("one.deb").len > 200 and std.mem.startsWith(u8, w.read("one.deb"), "!<arch>\n"), "no ar magic");
        rep.same("deb: the sha256 is the golden one (amd64)", h.readFile(a, gold ++ "mopm_1.2.3_amd64.deb.sha256") catch "", try sha256Line(a, w.read("one.deb")));
        _ = try w.deb("1.2.3", "arm64", bin, mtime, "arm.deb");
        rep.same("deb: the sha256 is the golden one (arm64)", h.readFile(a, gold ++ "mopm_1.2.3_arm64.deb.sha256") catch "", try sha256Line(a, w.read("arm.deb")));

        try h.writeFile(w.path("other.bin"), "other bytes for the binary\n");
        _ = try w.deb("1.2.3", "amd64", bin, "1700000001", "later.deb");
        _ = try w.deb("1.2.3", "amd64", w.path("other.bin"), mtime, "otherbin.deb");
        _ = try w.deb("1.2.4", "amd64", bin, mtime, "newer.deb");
        rep.check("defect: a later mtime gives other bytes", !std.mem.eql(u8, w.read("one.deb"), w.read("later.deb")) and w.read("later.deb").len > 0, "same bytes");
        rep.check("defect: another binary gives other bytes", !std.mem.eql(u8, w.read("one.deb"), w.read("otherbin.deb")) and w.read("otherbin.deb").len > 0, "same bytes");
        rep.check("defect: another version gives other bytes", !std.mem.eql(u8, w.read("one.deb"), w.read("newer.deb")) and w.read("newer.deb").len > 0, "same bytes");

        const bad_version = try w.deb("1.2", "amd64", bin, mtime, "badv.deb");
        rep.check("defect: a version that is not X.Y.Z is refused and writes nothing", bad_version.code == 1 and h.contains(bad_version.text, "BadVersion") and !w.has("badv.deb"), bad_version.text);
        const bad_mode = try w.run(&.{ "deb", "--package", "mopm", "--version", "1.2.3", "--arch", "amd64", "--maintainer", "m <m@m>", "--homepage", "https://mopm.dev", "--synopsis", "s", "--file", "999:usr/bin/mopm:" ++ bin, "--mtime", mtime, "--out", w.path("badmode.deb") });
        rep.check("defect: a mode that is not octal is refused", bad_mode.code == 1 and h.contains(bad_mode.text, "not octal") and !w.has("badmode.deb"), bad_mode.text);
        const escape = try w.run(&.{ "deb", "--package", "mopm", "--version", "1.2.3", "--arch", "amd64", "--maintainer", "m <m@m>", "--homepage", "https://mopm.dev", "--synopsis", "s", "--file", "755:../etc/mopm:" ++ bin, "--mtime", mtime, "--out", w.path("escape.deb") });
        rep.check("defect: a path that climbs out of the package is refused", escape.code == 1 and h.contains(escape.text, "BadPath") and !w.has("escape.deb"), escape.text);
    }

    // ---- deb-package: the release's .deb, from a binary and the metadata in packaging/deb ---------------------------
    {
        const pk = "packaging/deb";
        const r1 = try w.run(&.{ "deb-package", "--binary", bin, "--name", "mopm", "--version", "1.2.3", "--arch", "amd64", "--packaging", pk, "--out", w.path("p1.deb") });
        const r2 = try w.run(&.{ "deb-package", "--binary", bin, "--name", "mopm", "--version", "1.2.3", "--arch", "amd64", "--packaging", pk, "--out", w.path("p2.deb") });
        rep.check("deb-package: the program succeeds", r1.code == 0 and r2.code == 0 and h.contains(r1.text, "wrote "), r1.text);
        rep.same("deb-package: built twice, the two files are the same bytes", w.read("p1.deb"), w.read("p2.deb"));
        rep.check("deb-package: the file is an ar archive", w.read("p1.deb").len > 200 and std.mem.startsWith(u8, w.read("p1.deb"), "!<arch>\n"), "no ar magic");

        try h.writeFile(w.path("pother.bin"), "other bytes for the binary\n");
        _ = try w.run(&.{ "deb-package", "--binary", w.path("pother.bin"), "--name", "mopm", "--version", "1.2.3", "--arch", "amd64", "--packaging", pk, "--out", w.path("p3.deb") });
        rep.check("defect: another binary gives other bytes (the compare is live)", w.read("p3.deb").len > 0 and !std.mem.eql(u8, w.read("p1.deb"), w.read("p3.deb")), "same bytes");
        _ = try w.run(&.{ "deb-package", "--binary", bin, "--name", "mopm", "--version", "1.2.3", "--arch", "arm64", "--packaging", pk, "--out", w.path("p4.deb") });
        rep.check("defect: another architecture gives other bytes", w.read("p4.deb").len > 0 and !std.mem.eql(u8, w.read("p1.deb"), w.read("p4.deb")), "same bytes");

        // The package is what apt-index reads: its control file parses and lists mopm 1.2.3.
        const idx = try w.index("nowhere", "pidx", &.{"p1.deb"}, &.{});
        rep.check("deb-package: apt-index accepts the .deb and lists it", idx.code == 0 and h.contains(idx.text, "added 1") and h.contains(w.read("pidx/dists/stable/main/binary-amd64/Packages"), "Package: mopm\nVersion: 1.2.3\n"), idx.text);

        // Metadata that the package format cannot carry is refused and writes nothing.
        for ([_][]const u8{ "control", "copyright", "lintian-overrides" }) |n| {
            try h.writeFile(try h.fmt(a, "{s}/pk_bad/{s}", .{ w.root, n }), h.readFile(a, try h.fmt(a, "{s}/{s}", .{ pk, n })) catch "");
        }
        try h.writeFile(w.path("pk_bad/control"), try h.fmt(a, "{s}Depends: libc6\n", .{h.readFile(a, pk ++ "/control") catch ""}));
        const unknown = try w.run(&.{ "deb-package", "--binary", bin, "--name", "mopm", "--version", "1.2.3", "--arch", "amd64", "--packaging", w.path("pk_bad"), "--out", w.path("bad1.deb") });
        rep.check("defect: a control field the package does not allow is refused, nothing written", unknown.code == 1 and h.contains(unknown.text, "UnknownField") and !w.has("bad1.deb"), unknown.text);
        const nodir = try w.run(&.{ "deb-package", "--binary", bin, "--name", "mopm", "--version", "1.2.3", "--arch", "amd64", "--packaging", w.path("no_such_dir"), "--out", w.path("bad2.deb") });
        rep.check("defect: a metadata directory that is not there is refused, nothing written", nodir.code == 1 and h.contains(nodir.text, "cannot open") and !w.has("bad2.deb"), nodir.text);
        try h.writeFile(w.path("empty.bin"), "");
        const empty = try w.run(&.{ "deb-package", "--binary", w.path("empty.bin"), "--name", "mopm", "--version", "1.2.3", "--arch", "amd64", "--packaging", pk, "--out", w.path("bad3.deb") });
        rep.check("defect: an empty binary is refused, nothing written", empty.code == 1 and h.contains(empty.text, "EmptyFile") and !w.has("bad3.deb"), empty.text);
        const badv = try w.run(&.{ "deb-package", "--binary", bin, "--name", "mopm", "--version", "1.2", "--arch", "amd64", "--packaging", pk, "--out", w.path("bad4.deb") });
        rep.check("defect: a version that is not X.Y.Z is refused, nothing written", badv.code == 1 and h.contains(badv.text, "BadVersion") and !w.has("bad4.deb"), badv.text);
    }

    // ---- deb-data and architecture all: a data-only package, and the index it joins ----------------------------------------
    {
        const pk = "packaging/deb";
        const kr_args = [_][]const u8{ "deb-data", "--name", "sample-keyring", "--version", "2026.10.21", "--packaging", pk, "--file", "644:usr/share/keyrings/sample-keyring.gpg:" ++ fx ++ "copyright" };
        const d1 = try w.run(try cat(a, &.{ &kr_args, &.{ "--out", w.path("kr1.deb") } }));
        const d2 = try w.run(try cat(a, &.{ &kr_args, &.{ "--out", w.path("kr2.deb") } }));
        rep.check("deb-data: the program succeeds", d1.code == 0 and d2.code == 0 and h.contains(d1.text, "wrote "), d1.text);
        rep.same("deb-data: built twice, the same bytes", w.read("kr1.deb"), w.read("kr2.deb"));
        const kr_idx = try w.index("nowhere", "kr_first", &.{"kr1.deb"}, &.{});
        const kr_release = w.read("kr_first/dists/stable/Release");
        rep.check("apt-index: an all package into an empty repository succeeds and the Release lists all with amd64 and arm64", kr_idx.code == 0 and h.contains(kr_release, "Architectures: all amd64 arm64\n") and h.contains(kr_release, "main/binary-all/Packages.gz\n") and h.contains(w.read("kr_first/dists/stable/main/binary-all/Packages"), "Package: sample-keyring\nVersion: 2026.10.21\nArchitecture: all\n"), kr_idx.text);

        // The next product's publish (here: mopm amd64 and arm64 builds) over the repository that now lists all.
        _ = try w.deb("1.2.3", "amd64", bin, mtime, "kn_amd.deb");
        _ = try w.deb("1.2.3", "arm64", bin, mtime, "kn_arm.deb");
        const next = try w.index("kr_first", "kr_next", &.{ "kn_amd.deb", "kn_arm.deb" }, &.{});
        rep.check("apt-index: the next product's publish over a repository holding an all package succeeds and lists all", next.code == 0 and h.contains(next.text, "added 2, dropped 0, listed 3") and h.contains(w.read("kr_next/dists/stable/Release"), "Architectures: all amd64 arm64\n"), next.text);
        rep.same("apt-index: and the all Packages is unchanged by it", w.read("kr_first/dists/stable/main/binary-all/Packages"), w.read("kr_next/dists/stable/main/binary-all/Packages"));
        rep.check("apt-index: and the new packages are listed for their own architectures", h.contains(w.read("kr_next/dists/stable/main/binary-amd64/Packages"), "Package: mopm\n") and h.contains(w.read("kr_next/dists/stable/main/binary-arm64/Packages"), "Package: mopm\n"), next.text);
        // And the keyring's own next version over that.
        const kr3 = try w.run(&.{ "deb-data", "--name", "sample-keyring", "--version", "2026.11.2", "--packaging", pk, "--file", "644:usr/share/keyrings/sample-keyring.gpg:" ++ fx ++ "copyright", "--out", w.path("kr3.deb") });
        const again = try w.index("kr_next", "kr_again", &.{"kr3.deb"}, &.{});
        rep.check("apt-index: the all package's next version over the shared repository succeeds, the others stay", kr3.code == 0 and again.code == 0 and h.contains(again.text, "added 1, dropped 0, listed 4") and h.contains(w.read("kr_again/dists/stable/main/binary-amd64/Packages"), "Package: mopm\n"), again.text);

        // Refusals: nothing is written.
        const conf = try w.run(&.{ "deb-data", "--name", "sample-keyring", "--version", "2026.10.21", "--packaging", pk, "--file", "644:etc/sample.conf:" ++ fx ++ "copyright", "--out", w.path("bad_conf.deb") });
        rep.check("defect: deb-data with a file below etc/ is refused, nothing written", conf.code == 1 and h.contains(conf.text, "ConffilePath") and !w.has("bad_conf.deb"), conf.text);
        const suid = try w.run(&.{ "deb-data", "--name", "sample-keyring", "--version", "2026.10.21", "--packaging", pk, "--file", "4755:usr/bin/x:" ++ fx ++ "copyright", "--out", w.path("bad_mode.deb") });
        rep.check("defect: deb-data with a setuid mode is refused, nothing written", suid.code == 1 and h.contains(suid.text, "BadMode") and !w.has("bad_mode.deb"), suid.text);
        const nofiles = try w.run(&.{ "deb-data", "--name", "sample-keyring", "--version", "2026.10.21", "--packaging", pk, "--out", w.path("bad_nofiles.deb") });
        rep.check("defect: deb-data with no file is refused, nothing written", nofiles.code == 1 and h.contains(nofiles.text, "EmptyFile") and !w.has("bad_nofiles.deb"), nofiles.text);
        const nodir = try w.run(&.{ "deb-data", "--name", "sample-keyring", "--version", "2026.10.21", "--packaging", w.path("no_such_dir"), "--file", "644:usr/share/x:" ++ fx ++ "copyright", "--out", w.path("bad_dir.deb") });
        rep.check("defect: deb-data with no metadata directory is refused, nothing written", nodir.code == 1 and h.contains(nodir.text, "cannot open") and !w.has("bad_dir.deb"), nodir.text);
        const badspec = try w.run(&.{ "deb-data", "--name", "sample-keyring", "--version", "2026.10.21", "--packaging", pk, "--file", "644:nocolon", "--out", w.path("bad_spec.deb") });
        rep.check("defect: deb-data with a malformed --file is refused", badspec.code == 1 and h.contains(badspec.text, "is not <mode>:<dest>:<src>") and !w.has("bad_spec.deb"), badspec.text);
        const badoct = try w.run(&.{ "deb-data", "--name", "sample-keyring", "--version", "2026.10.21", "--packaging", pk, "--file", "9:usr/x:" ++ fx ++ "copyright", "--out", w.path("bad_oct.deb") });
        rep.check("defect: deb-data with a mode that is not octal is refused", badoct.code == 1 and h.contains(badoct.text, "not octal") and !w.has("bad_oct.deb"), badoct.text);
    }

    // ---- the apt tree: two additions, the goldens, the files' own checksums ------------------------------------------
    {
        _ = try w.deb("1.2.2", "amd64", bin, mtime, "d122a.deb");
        const first = try w.index("nowhere", "r1", &.{"d122a.deb"}, &.{});
        rep.check("apt-index: into an empty repository succeeds", first.code == 0 and h.contains(first.text, "added 1"), first.text);
        const second = try w.index("r1", "r2", &.{ "one.deb", "arm.deb" }, &.{});
        rep.check("apt-index: a second addition succeeds", second.code == 0 and h.contains(second.text, "added 2") and h.contains(second.text, "listed 3"), second.text);
        rep.same("apt-index: Packages (amd64) is the golden one: newest first, both versions", h.readFile(a, gold ++ "Packages_amd64") catch "", w.read("r2/dists/stable/main/binary-amd64/Packages"));
        rep.same("apt-index: Packages (arm64) is the golden one", h.readFile(a, gold ++ "Packages_arm64") catch "", w.read("r2/dists/stable/main/binary-arm64/Packages"));
        rep.same("apt-index: Release is the golden one", h.readFile(a, gold ++ "Release") catch "", w.read("r2/dists/stable/Release"));
        for ([_][]const u8{ "main/binary-amd64/Packages", "main/binary-amd64/Packages.gz", "main/binary-arm64/Packages", "main/binary-arm64/Packages.gz" }) |f| {
            const bytes = w.read(try h.fmt(a, "r2/dists/stable/{s}", .{f}));
            const line = try h.fmt(a, " {s} {d} {s}\n", .{ try sha256Hex(a, bytes), bytes.len, f });
            rep.check(try h.fmt(a, "apt-index: Release lists the size and sha256 of the file on disk: {s}", .{f}), bytes.len > 0 and h.contains(w.read("r2/dists/stable/Release"), line), line);
        }
        rep.same("apt-index: the new amd64 .deb is in the pool, as it was given", w.read("one.deb"), w.read("r2/pool/main/m/mopm/mopm_1.2.3_amd64.deb"));
        rep.same("apt-index: the new arm64 .deb is in the pool, as it was given", w.read("arm.deb"), w.read("r2/pool/main/m/mopm/mopm_1.2.3_arm64.deb"));

        const again = try w.index("r1", "r3", &.{ "one.deb", "arm.deb" }, &.{});
        rep.check("apt-index: the same inputs again succeed", again.code == 0, again.text);
        for ([_][]const u8{ "dists/stable/Release", "dists/stable/main/binary-amd64/Packages", "dists/stable/main/binary-amd64/Packages.gz", "dists/stable/main/binary-arm64/Packages", "dists/stable/main/binary-arm64/Packages.gz" }) |f| {
            rep.same(try h.fmt(a, "apt-index: byte-determinism, twice from the same inputs: {s}", .{f}), w.read(try h.fmt(a, "r2/{s}", .{f})), w.read(try h.fmt(a, "r3/{s}", .{f})));
        }

        // The same file again is a no-op, not an error.
        const noop = try w.index("r2", "r4", &.{"one.deb"}, &.{});
        rep.check("apt-index: the same .deb again adds nothing and succeeds", noop.code == 0 and h.contains(noop.text, "added 0"), noop.text);
        rep.same("apt-index: and the amd64 index is unchanged", w.read("r2/dists/stable/main/binary-amd64/Packages"), w.read("r4/dists/stable/main/binary-amd64/Packages"));

        // A product's own pool directory (a repository several products share): the .debs are listed and written below it, the checksums are the files' own.
        const shared = try w.index("r1", "r_shared", &.{ "one.deb", "arm.deb" }, &.{ "--pool-dir", "pool/mopm" });
        const shared_packages = w.read("r_shared/dists/stable/main/binary-amd64/Packages");
        rep.check("apt-index --pool-dir: succeeds, lists the new .deb below pool/mopm and keeps the old stanza as it was", shared.code == 0 and h.contains(shared_packages, "Filename: pool/mopm/mopm_1.2.3_amd64.deb\n") and h.contains(shared_packages, "Filename: pool/main/m/mopm/mopm_1.2.2_amd64.deb\n"), shared.text);
        rep.same("apt-index --pool-dir: the .deb is written below the directory, as it was given", w.read("one.deb"), w.read("r_shared/pool/mopm/mopm_1.2.3_amd64.deb"));
        rep.check("apt-index --pool-dir: nothing is written to pool/main", !w.has("r_shared/pool/main"), shared.text);
        for ([_][]const u8{ "pool/../etc", "elsewhere", "pool/", "pool/Mopm" }) |bad| {
            const refused = try w.index("r1", "r_badpool", &.{"one.deb"}, &.{ "--pool-dir", bad });
            rep.check(try h.fmt(a, "defect: apt-index --pool-dir {s} is refused, nothing written", .{bad}), refused.code == 1 and h.contains(refused.text, "BadPoolDir") and !w.has("r_badpool"), refused.text);
        }

        // A shared repository: the Release another product wrote keeps its Origin, Label and Description; the flags apply to the first Release only.
        try h.writeFile(w.path("r_other/dists/stable/Release"), "Origin: Shared Co\nLabel: Shared Label\nSuite: stable\nCodename: stable\nDate: Tue, 14 Nov 2023 22:13:20 UTC\nArchitectures: amd64 arm64\nComponents: main\nDescription: the shared packages\n of Shared Co\nSHA256:\n");
        const shared_kept = try w.index("r_other", "r_kept", &.{ "one.deb", "arm.deb" }, &.{});
        const kept_release = w.read("r_kept/dists/stable/Release");
        rep.check("apt-index: an existing Release keeps its Origin, Label and Description (mopm's flags do not overwrite them)", shared_kept.code == 0 and h.contains(kept_release, "Origin: Shared Co\nLabel: Shared Label\n") and h.contains(kept_release, "Description: the shared packages\n of Shared Co\nAcquire-By-Hash: yes\n") and !h.contains(kept_release, "Origin: mopm") and !h.contains(kept_release, "Label: mopm") and !h.contains(kept_release, "mopm packages"), shared_kept.text);
        rep.check("apt-index: the first Release (none read) takes the three flags", h.contains(w.read("r2/dists/stable/Release"), "Origin: mopm\nLabel: mopm\n") and h.contains(w.read("r2/dists/stable/Release"), "Description: mopm packages\n"), w.read("r2/dists/stable/Release"));
        try h.writeFile(w.path("r_junkrel/dists/stable/Release"), "this is not a control file\n");
        const junkrel = try w.index("r_junkrel", "r_junkrel_out", &.{"one.deb"}, &.{});
        rep.check("defect: a Release that cannot be read as a control file is refused, nothing written", junkrel.code == 1 and h.contains(junkrel.text, "BadStanza") and !w.has("r_junkrel_out"), junkrel.text);
        try std.fs.cwd().makePath(w.path("r_dirrel/dists/stable/Release"));
        const dirrel = try w.index("r_dirrel", "r_dirrel_out", &.{"one.deb"}, &.{});
        rep.check("defect: a Release that cannot be opened is refused, nothing written", dirrel.code == 1 and h.contains(dirrel.text, "cannot read") and !w.has("r_dirrel_out"), dirrel.text);

        // ---- known defects: each is refused for its reason, and nothing at all is written ---------------------------
        const down =try w.index("r2", "r_down", &.{"d122a.deb"}, &.{});
        rep.check("defect: an older version would move the channel down: refused, nothing written", down.code == 1 and h.contains(down.text, "refused") and h.contains(down.text, "down") and !w.has("r_down"), down.text);
        const conflict = try w.index("r2", "r_conflict", &.{"otherbin.deb"}, &.{});
        rep.check("defect: a listed version with other bytes is refused, nothing written", conflict.code == 1 and h.contains(conflict.text, "other bytes") and !w.has("r_conflict"), conflict.text);
        const junk = try w.index("r2", "r_junk", &.{}, &.{ "--deb", fx ++ "copyright" });
        rep.check("defect: a file that is not a .deb is refused, nothing written", junk.code == 1 and h.contains(junk.text, "not a usable .deb") and !w.has("r_junk"), junk.text);
        const nodeb = try w.run(&.{ "apt-index", "--repo", w.path("r2"), "--out", w.path("r_nodeb"), "--date", mtime, "--origin", "mopm", "--label", "mopm", "--description", "d" });
        rep.check("defect: no .deb is refused, nothing written", nodeb.code == 1 and h.contains(nodeb.text, "--deb is required") and !w.has("r_nodeb"), nodeb.text);
        const nodate = try w.run(&.{ "apt-index", "--repo", w.path("r2"), "--out", w.path("r_nodate"), "--deb", w.path("one.deb"), "--origin", "mopm", "--label", "mopm", "--description", "d" });
        rep.check("defect: no --date is refused (the tool never reads the clock), nothing written", nodate.code == 1 and h.contains(nodate.text, "--date is required") and !w.has("r_nodate"), nodate.text);
        _ = try w.deb("1.2.3", "armhf", bin, mtime, "armhf.deb");
        const stray = try w.index("r2", "r_stray", &.{"armhf.deb"}, &.{});
        rep.check("defect: a .deb of an architecture the index does not list is refused, nothing written", stray.code == 1 and h.contains(stray.text, "ArchitectureNotIndexed") and !w.has("r_stray"), stray.text);
        const dup_arch = try w.index("r2", "r_duparch", &.{"one.deb"}, &.{ "--arch", "amd64", "--arch", "amd64" });
        rep.check("defect: an architecture given twice is refused, nothing written", dup_arch.code == 1 and h.contains(dup_arch.text, "BadArchitecture") and !w.has("r_duparch"), dup_arch.text);
        const odd_arch = try w.index("r2", "r_oddarch", &.{"one.deb"}, &.{ "--arch", "../AMD64" });
        rep.check("defect: an architecture that is not a name is refused, nothing written", odd_arch.code == 1 and h.contains(odd_arch.text, "BadArchitecture") and !w.has("r_oddarch"), odd_arch.text);

        // ---- re-indexing with one --arch must not drop the published packages of the other architectures ---------------
        const one_arch = try w.index("r2", "r_onearch", &.{"newer.deb"}, &.{ "--arch", "amd64" });
        rep.check("apt-index: --arch amd64 over a repository that also lists arm64 succeeds", one_arch.code == 0 and h.contains(one_arch.text, "listed 4"), one_arch.text);
        rep.same("apt-index: and the arm64 Packages is the golden one still (its stanza was kept)", h.readFile(a, gold ++ "Packages_arm64") catch "", w.read("r_onearch/dists/stable/main/binary-arm64/Packages"));
        rep.check("apt-index: and the arm64 Packages.gz and the Release still list arm64", w.has("r_onearch/dists/stable/main/binary-arm64/Packages.gz") and h.contains(w.read("r_onearch/dists/stable/Release"), "Architectures: amd64 arm64\n") and h.contains(w.read("r_onearch/dists/stable/Release"), "main/binary-arm64/Packages.gz\n"), w.read("r_onearch/dists/stable/Release"));
        const unknown = try w.index("r2", "r_unknown", &.{"one.deb"}, &.{"--force"});
        rep.check("defect: an unknown flag is refused", unknown.code == 1 and h.contains(unknown.text, "unknown argument") and !w.has("r_unknown"), unknown.text);

        // ---- retention: --keep 2 drops the third newest version ----------------------------------------------------
        const keep = try w.index("r2", "r_keep", &.{"newer.deb"}, &.{ "--keep", "2" });
        const listed = w.read("r_keep/dists/stable/main/binary-amd64/Packages");
        rep.check("apt-index: --keep 2 drops the oldest of three and says so", keep.code == 0 and h.contains(keep.text, "dropped 1") and h.contains(listed, "Version: 1.2.4\n") and h.contains(listed, "Version: 1.2.3\n") and !h.contains(listed, "Version: 1.2.2\n"), keep.text);
        const keep0 = try w.index("r2", "r_keep0", &.{"newer.deb"}, &.{ "--keep", "0" });
        rep.check("defect: --keep 0 would empty the index: refused, nothing written", keep0.code == 1 and !w.has("r_keep0"), keep0.text);

        // Without --keep the newest 25 stay: 27 versions in one call list 25 and drop 2 (24 or 26 would say otherwise).
        var many_debs = std.ArrayList([]const u8).init(a);
        var n: usize = 0;
        while (n < 27) : (n += 1) {
            const name = try h.fmt(a, "many{d}.deb", .{n});
            _ = try w.deb(try h.fmt(a, "1.0.{d}", .{n}), "amd64", bin, mtime, name);
            try many_debs.append(name);
        }
        const dflt = try w.index("nowhere", "r_default", many_debs.items, &.{});
        const kept = w.read("r_default/dists/stable/main/binary-amd64/Packages");
        rep.check("apt-index: the default keeps the newest 25 of 27 and drops 2", dflt.code == 0 and h.contains(dflt.text, "added 27, dropped 2, listed 25") and h.contains(kept, "Version: 1.0.26\n") and h.contains(kept, "Version: 1.0.2\n") and !h.contains(kept, "Version: 1.0.1\n"), dflt.text);
    }

    // ---- the formula ------------------------------------------------------------------------------------------------
    {
        const base = [_][]const u8{ "formula", "--name", "mopm", "--version", "1.2.3", "--desc", "Package manager for Mojo", "--homepage", "https://mopm.dev", "--license", "Apache-2.0" };
        const good = try w.run(try cat(a, &.{ &base, &.{ "--repo", "komira-ai/mopm", "--sums", fx ++ "SHA256SUMS", "--out", w.path("mopm.rb") } }));
        rep.check("formula: renders from the fixture SHA256SUMS", good.code == 0, good.text);
        rep.same("formula: is the golden one", h.readFile(a, gold ++ "mopm.rb") catch "", w.read("mopm.rb"));

        const local = try w.run(try cat(a, &.{ &base, &.{ "--url-base", "file:///tmp/dist", "--sums", fx ++ "SHA256SUMS", "--no-explicit-version", "--out", w.path("local.rb") } }));
        rep.check("formula: a file:// base and no version line", local.code == 0 and h.contains(w.read("local.rb"), "url \"file:///tmp/dist/mopm-1.2.3-macos-arm64.tar.gz\"") and !h.contains(w.read("local.rb"), "  version "), local.text);

        // Known defects in the SHA256SUMS: take a line out, add a stray one, damage one.
        const sums = try h.readFile(a, fx ++ "SHA256SUMS");
        var lines = std.mem.splitScalar(u8, sums, '\n');
        var kept = std.ArrayList(u8).init(a);
        while (lines.next()) |l| {
            if (l.len == 0 or h.contains(l, "macos-arm64")) continue;
            try kept.appendSlice(l);
            try kept.append('\n');
        }
        try h.writeFile(w.path("sums_missing"), kept.items);
        const missing = try w.run(try cat(a, &.{ &base, &.{ "--repo", "komira-ai/mopm", "--sums", w.path("sums_missing"), "--out", w.path("missing.rb") } }));
        rep.check("defect: a SHA256SUMS without macos-arm64 is refused, no formula written", missing.code == 1 and h.contains(missing.text, "MissingTarball") and !w.has("missing.rb"), missing.text);

        try h.writeFile(w.path("sums_stray"), try h.fmt(a, "{s}{s}  mopm-1.2.2-macos-arm64.tar.gz\n", .{ sums, "0" ** 64 }));
        const stray = try w.run(try cat(a, &.{ &base, &.{ "--repo", "komira-ai/mopm", "--sums", w.path("sums_stray"), "--out", w.path("stray.rb") } }));
        rep.check("defect: a tarball of another version in SHA256SUMS is refused", stray.code == 1 and h.contains(stray.text, "UnexpectedTarball") and !w.has("stray.rb"), stray.text);

        try h.writeFile(w.path("sums_bad"), try h.fmt(a, "ZZ{s}", .{sums[2..]}));
        const bad = try w.run(try cat(a, &.{ &base, &.{ "--repo", "komira-ai/mopm", "--sums", w.path("sums_bad"), "--out", w.path("bad.rb") } }));
        rep.check("defect: a damaged checksum (upper-case letters, not what sha256sum writes) is refused", bad.code == 1 and h.contains(bad.text, "BadHash") and !w.has("bad.rb"), bad.text);

        const wrong_version = try w.run(&.{ "formula", "--name", "mopm", "--version", "1.2.4", "--desc", "d", "--homepage", "https://mopm.dev", "--license", "Apache-2.0", "--repo", "komira-ai/mopm", "--sums", fx ++ "SHA256SUMS", "--out", w.path("v124.rb") });
        rep.check("defect: SHA256SUMS of 1.2.3 for a 1.2.4 formula is refused", wrong_version.code == 1 and h.contains(wrong_version.text, "UnexpectedTarball") and !w.has("v124.rb"), wrong_version.text);
    }

    // ---- the release's `tap` job: its own render command, against the tap guard's fixture ------------------------------------
    // The Homebrew tap admits a formula only if it is the renderer's exact output (an allow-list template in the tap's
    // .github/guard/guard.js). The command below is read from .github/workflows/release.yml (the line release_lint.zig pins), its
    // variables are filled in as the job has them, and the program runs on the fixture SHA256SUMS. The file it writes must be the
    // tap's own fixture, byte for byte: tests/channels/tap_guard/mopm.rb, a copy that names the tap commit it was taken from.
    // A flag that changes the output (no explicit version, another url base, another name) would make a pull request the guard
    // refuses, and shows here, in the release's own tests, instead of as a stuck pull request after the release.
    {
        const guard = "tests/channels/tap_guard/mopm.rb";
        const copy = h.readFile(a, guard) catch "";
        rep.check("tap job: the copy of the tap's fixture names the commit of the tap it was taken from", h.contains(copy, "Source: komira-ai/homebrew-tap at commit ") and h.contains(copy, "(test/fixtures/mopm.rb)") and copy.len > 400, copy);
        const want = withoutHeader(copy);
        // The golden formula is the default render (with its version line); the tap's fixture is the same file without that line.
        const golden = h.readFile(a, gold ++ "mopm.rb") catch "";
        rep.same("tap job: the copy of the tap's fixture is the golden formula without its version line", try std.mem.replaceOwned(u8, a, golden, "  version \"1.2.3\"\n", ""), want);
        rep.check("tap job: the copy of the tap's fixture has no version line", !h.contains(want, "  version "), want);

        const yml = h.readFile(a, ".github/workflows/release.yml") catch "";
        const marker = "run: '\"$RUNNER_TEMP/channels\" formula ";
        const at = std.mem.indexOf(u8, yml, marker);
        rep.check("tap job: release.yml has exactly one render step", at != null and std.mem.count(u8, yml, marker) == 1, "release.yml");
        if (at) |s| {
            const start = s + "run: '".len;
            const end = std.mem.indexOfScalarPos(u8, yml, start, '\n') orelse yml.len;
            const line = std.mem.trimRight(u8, yml[start..end], " \r");
            rep.check("tap job: the render command is a single-quoted YAML string", line.len > 2 and line[line.len - 1] == '\'', line);
            const cmd = line[0 .. line.len - 1];
            const vars = [_][2][]const u8{ .{ "RUNNER_TEMP", w.root }, .{ "VERSION", "1.2.3" }, .{ "GITHUB_REPOSITORY", "komira-ai/mopm" } };
            const words = try shellWords(a, cmd, &vars);
            var args = std.ArrayList([]const u8).init(a);
            for (words[1..]) |x| try args.append(if (std.mem.eql(u8, x, "dist/SHA256SUMS")) fx ++ "SHA256SUMS" else x);
            rep.check("tap job: the command runs the channels program built in the job, with the formula verb", std.mem.eql(u8, words[0], try h.join(a, &.{ w.root, "channels" })) and std.mem.eql(u8, words[1], "formula"), cmd);
            rep.check("tap job: it reads the job's dist/SHA256SUMS and writes the file the tool step takes", h.contains(cmd, "--sums dist/SHA256SUMS") and h.contains(cmd, "--out \"$RUNNER_TEMP/tap/mopm.rb\""), cmd);

            const good = try w.run(args.items);
            rep.check("tap job: the exact command line renders", good.code == 0 and w.has("tap/mopm.rb"), good.text);
            rep.same("tap job: ... and the file is the tap guard's fixture, byte for byte", want, w.read("tap/mopm.rb"));

            // Variants of the command line: each must produce a formula that is NOT the fixture (or no formula), so the compare is live.
            const plants = [_]struct { name: []const u8, extra: []const []const u8 }{
                .{ .name = "the version line (flag dropped)", .extra = &.{} },
                .{ .name = "another url base", .extra = &.{ "--url-base", "https://example.com/dl" } },
            };
            for (plants, 0..) |p, pi| {
                const out_name = try h.fmt(a, "tap_defect_{d}.rb", .{pi});
                var margs = std.ArrayList([]const u8).init(a);
                for (args.items, 0..) |x, k| {
                    if (pi == 0 and std.mem.eql(u8, x, "--no-explicit-version")) continue;
                    if (k > 0 and std.mem.eql(u8, args.items[k - 1], "--out")) {
                        try margs.append(w.path(out_name));
                    } else try margs.append(x);
                }
                try margs.appendSlice(p.extra);
                const r = try w.run(margs.items);
                rep.check(try h.fmt(a, "tap job defect: {s} does not render the tap guard's fixture", .{p.name}), r.code != 0 or !std.mem.eql(u8, w.read(out_name), want), r.text);
            }
            var no_repo = std.ArrayList([]const u8).init(a);
            var skip: usize = 0;
            for (args.items) |x| {
                if (skip > 0) {
                    skip -= 1;
                    continue;
                }
                if (std.mem.eql(u8, x, "--repo")) {
                    skip = 1;
                    continue;
                }
                try no_repo.append(if (std.mem.eql(u8, x, w.path("tap/mopm.rb"))) w.path("tap_no_repo.rb") else x);
            }
            const nr = try w.run(no_repo.items);
            rep.check("tap job defect: no --repo (no release url) renders nothing", nr.code != 0 and !w.has("tap_no_repo.rb"), nr.text);
        }
    }

    // ---- monotonic ----------------------------------------------------------------------------------------------------
    {
        const Case = struct { current: []const u8, next: []const u8, code: u8, says: []const u8 };
        const cases = [_]Case{
            .{ .current = "none", .next = "1.2.3", .code = 0, .says = "advance" },
            .{ .current = "1.2.3", .next = "1.2.3", .code = 0, .says = "same" },
            .{ .current = "1.2.3", .next = "1.2.4", .code = 0, .says = "advance" },
            .{ .current = "1.9.0", .next = "1.10.0", .code = 0, .says = "advance" },
            .{ .current = "1.10.0", .next = "1.9.0", .code = 1, .says = "refused" },
            .{ .current = "1.2.3", .next = "1.2.2", .code = 1, .says = "refused" },
            .{ .current = "1.2.3", .next = "v1.2.4", .code = 1, .says = "is not X.Y.Z" },
            .{ .current = "latest", .next = "1.2.4", .code = 1, .says = "is not X.Y.Z or none" },
        };
        for (cases) |c| {
            const r = try w.run(&.{ "monotonic", "--current", c.current, "--next", c.next });
            rep.check(try h.fmt(a, "monotonic: {s} -> {s} says {s}", .{ c.current, c.next, c.says }), r.code == c.code and h.contains(r.text, c.says), r.text);
        }
    }
    try rep.finish();
}
