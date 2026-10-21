//! deb_package: the one entry point that turns a built binary into a .deb. Self-contained on purpose: bytes in, bytes out,
//! no file system, no clock, no environment, no network. It is the shape of buildrules' `deb_package` rule, and the
//! rule can lift this file (with deb.zig, control.zig, tar.zig, version.zig) out as it is.
//!
//!   inputs   binary             the bytes of the executable (a static one)
//!            name, version, arch  the package name, `X.Y.Z`, the Debian architecture (amd64, arm64)
//!            control            the metadata fields: Maintainer, Homepage, Description (the synopsis, then the long
//!                               description as continuation lines, ` .` for an empty line), optional Section and Priority
//!            copyright          the text of usr/share/doc/<name>/copyright
//!            lintian_overrides  the text of usr/share/lintian/overrides/<name>
//!   output   the .deb file's bytes
//!
//! What it adds to the binary: the copyright file, a `changelog.gz` written from the name, version and maintainer (a
//! native package has one entry), and the lintian overrides. The same inputs give the same bytes (every time in the file is
//! `mtime`, which is `default_mtime` unless the caller says otherwise): a verifier rebuilds a .deb from the binary inside a release
//! tarball and compares bytes.
//!
//! Deploying a .deb (the apt index, the upload) is not here: that half is apt.zig and the callers of main.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const deb = @import("deb.zig");
const control = @import("control.zig");
const tar = @import("tar.zig");

/// The time written into every member, entry and the changelog: 2026-01-01T00:00:00Z. A fixed date, so the same inputs give the
/// same bytes (a verifier rebuilds the .deb from the tarball alone), and not 0: lintian refuses files dated 1970
/// (package-contains-ancient-file).
pub const default_mtime: u64 = 1767225600;

pub const Inputs = struct {
    binary: []const u8,
    name: []const u8,
    version: []const u8,
    arch: []const u8,
    control: []const u8,
    copyright: []const u8,
    lintian_overrides: []const u8,
    /// Seconds since the epoch, written to every member, entry and the changelog's date.
    mtime: u64 = default_mtime,
};

pub const Error = error{ MissingField, UnknownField, EmptyFile };

const known_fields = [_][]const u8{ "Maintainer", "Homepage", "Description", "Section", "Priority" };

/// The days of the week from a Sunday-based index, and the month names, as RFC 2822 writes them.
const days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// `Thu, 01 Jan 1970 00:00:00 +0000`.
fn rfc2822(a: Allocator, secs: u64) ![]u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay();
    const md = day.calculateYearDay().calculateMonthDay();
    const ds = es.getDaySeconds();
    const weekday = (day.day + 4) % 7; // 1970-01-01 was a Thursday
    return std.fmt.allocPrint(a, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} +0000", .{
        days[weekday],
        md.day_index + 1,
        months[md.month.numeric() - 1],
        day.calculateYearDay().year,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

/// The Debian version of a release version: `1.2.3` stays, a pre-release `1.2.3-rc.1` becomes `1.2.3~rc.1` (dpkg sorts `~` before
/// the release itself).
pub fn debVersion(a: Allocator, version: []const u8) ![]u8 {
    const out = try a.dupe(u8, version);
    if (std.mem.indexOfScalar(u8, out, '-')) |i| out[i] = '~';
    return out;
}

/// The one-entry changelog of a native package.
fn changelog(a: Allocator, name: []const u8, version: []const u8, maintainer: []const u8, mtime: u64) ![]u8 {
    return std.fmt.allocPrint(a, "{s} ({s}) unstable; urgency=medium\n\n  * Release {s}.\n\n -- {s}  {s}\n", .{ name, version, version, maintainer, try rfc2822(a, mtime) });
}

/// The fields of a `control` metadata file, checked: only the known ones, and Maintainer, Homepage and Description present.
const Meta = struct { maintainer: []const u8, homepage: []const u8, synopsis: []const u8, long: []const u8, section: ?[]const u8, priority: ?[]const u8 };

fn parseMeta(a: Allocator, text: []const u8) !Meta {
    const fields = try control.parse(a, text);
    for (fields) |f| {
        var known = false;
        for (known_fields) |k| {
            if (std.mem.eql(u8, f.name, k)) known = true;
        }
        if (!known) return error.UnknownField;
    }
    const maintainer = control.get(fields, "Maintainer") orelse return error.MissingField;
    const homepage = control.get(fields, "Homepage") orelse return error.MissingField;
    const description = control.get(fields, "Description") orelse return error.MissingField;

    var lines = std.mem.splitScalar(u8, description, '\n');
    const synopsis = lines.first();
    var long = std.ArrayList(u8).init(a);
    while (lines.next()) |line| {
        // A continuation line is a space, then the text; ` .` stands for an empty line.
        const text_line = if (line.len > 0 and line[0] == ' ') line[1..] else line;
        if (long.items.len > 0) try long.append('\n');
        if (!std.mem.eql(u8, text_line, ".")) try long.appendSlice(text_line);
    }
    return .{
        .maintainer = maintainer,
        .homepage = homepage,
        .synopsis = synopsis,
        .long = long.items,
        .section = control.get(fields, "Section"),
        .priority = control.get(fields, "Priority"),
    };
}

/// The .deb for `in`. `a` should be an arena: nothing is freed.
pub fn build(a: Allocator, in: Inputs) ![]u8 {
    const version = try debVersion(a, in.version);
    if (in.binary.len == 0 or in.copyright.len == 0 or in.lintian_overrides.len == 0) return error.EmptyFile;
    const meta = try parseMeta(a, in.control);

    const log_gz = try tar.gzip(a, try changelog(a, in.name, version, meta.maintainer, in.mtime));
    const files = [_]deb.File{
        .{ .path = try std.fmt.allocPrint(a, "usr/bin/{s}", .{in.name}), .data = in.binary, .mode = 0o755 },
        .{ .path = try std.fmt.allocPrint(a, "usr/share/doc/{s}/copyright", .{in.name}), .data = in.copyright, .mode = 0o644 },
        .{ .path = try std.fmt.allocPrint(a, "usr/share/doc/{s}/changelog.gz", .{in.name}), .data = log_gz, .mode = 0o644 },
        .{ .path = try std.fmt.allocPrint(a, "usr/share/lintian/overrides/{s}", .{in.name}), .data = in.lintian_overrides, .mode = 0o644 },
    };
    return deb.build(a, .{
        .name = in.name,
        .version = version,
        .architecture = in.arch,
        .maintainer = meta.maintainer,
        .homepage = meta.homepage,
        .synopsis = meta.synopsis,
        .long_description = meta.long,
        .section = meta.section orelse "devel",
        .priority = meta.priority orelse "optional",
        .files = &files,
        .mtime = in.mtime,
    });
}

/// A file of a data-only package: its path inside the package (no leading slash), its bytes and its mode.
pub const DataFile = struct { path: []const u8, data: []const u8, mode: u32 };

pub const DataInputs = struct {
    name: []const u8,
    version: []const u8,
    /// The same fields as `Inputs.control`; Section defaults to `misc`.
    control: []const u8,
    copyright: []const u8,
    /// The files the package installs. Not the copyright or the changelog: the form adds those.
    files: []const DataFile,
    mtime: u64 = default_mtime,
};

pub const DataError = error{ ConffilePath, ReservedPath, BadMode };

/// The .deb of a data-only package (a keyring, say): Architecture `all`, the given files, the copyright and a `changelog.gz`, and nothing else.
/// There is no way to give it a maintainer script (the control archive is the control file and the md5sums, always) and no conffile (the control
/// archive has no `conffiles`). A path at or below `etc/` is refused (ConffilePath) rather than left to dpkg's rules, and any mode other than exactly
/// 0644 or 0755 is refused (BadMode). The same inputs give the same bytes.
pub fn buildData(a: Allocator, in: DataInputs) ![]u8 {
    const version = try debVersion(a, in.version);
    if (in.copyright.len == 0 or in.files.len == 0) return error.EmptyFile;
    const meta = try parseMeta(a, in.control);
    const copyright_path = try std.fmt.allocPrint(a, "usr/share/doc/{s}/copyright", .{in.name});
    const changelog_path = try std.fmt.allocPrint(a, "usr/share/doc/{s}/changelog.gz", .{in.name});
    var files = std.ArrayList(deb.File).init(a);
    for (in.files) |f| {
        if (f.data.len == 0) return error.EmptyFile;
        if (f.mode != 0o644 and f.mode != 0o755) return error.BadMode;
        if (std.mem.eql(u8, f.path, "etc") or std.mem.startsWith(u8, f.path, "etc/")) return error.ConffilePath;
        if (std.mem.eql(u8, f.path, copyright_path) or std.mem.eql(u8, f.path, changelog_path)) return error.ReservedPath;
        try files.append(.{ .path = f.path, .data = f.data, .mode = f.mode });
    }
    const log_gz = try tar.gzip(a, try changelog(a, in.name, version, meta.maintainer, in.mtime));
    try files.append(.{ .path = copyright_path, .data = in.copyright, .mode = 0o644 });
    try files.append(.{ .path = changelog_path, .data = log_gz, .mode = 0o644 });
    return deb.build(a, .{
        .name = in.name,
        .version = version,
        .architecture = "all",
        .maintainer = meta.maintainer,
        .homepage = meta.homepage,
        .synopsis = meta.synopsis,
        .long_description = meta.long,
        .section = meta.section orelse "misc",
        .priority = meta.priority orelse "optional",
        .files = files.items,
        .mtime = in.mtime,
    });
}

/// The metadata of a package kept as files: `control`, `copyright` and `lintian-overrides` in `dir`.
pub const Metadata = struct {
    control: []const u8,
    copyright: []const u8,
    lintian_overrides: []const u8,

    pub fn load(a: Allocator, dir: std.fs.Dir) !Metadata {
        return .{
            .control = try dir.readFileAlloc(a, "control", 1 << 20),
            .copyright = try dir.readFileAlloc(a, "copyright", 1 << 20),
            .lintian_overrides = try dir.readFileAlloc(a, "lintian-overrides", 1 << 20),
        };
    }
};

// ---- tests -------------------------------------------------------------------------------

const t = std.testing;

const sample_control =
    "Maintainer: mopm authors <apt@mopm.dev>\n" ++
    "Homepage: https://mopm.dev\n" ++
    "Description: package manager for Mojo\n" ++
    " Resolves, locks and builds Mojo packages.\n" ++
    " .\n" ++
    " A static binary.\n";

fn sample(binary: []const u8) Inputs {
    return .{
        .binary = binary,
        .name = "mopm",
        .version = "1.2.3",
        .arch = "amd64",
        .control = sample_control,
        .copyright = "Format: x\nLicense: Apache-2.0\n",
        .lintian_overrides = "mopm: statically-linked-binary [usr/bin/mopm]\n",
    };
}

test "the default time is a real date: not 1970, which lintian refuses" {
    try t.expect(default_mtime > 946684800); // after 2000-01-01
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("Thu, 01 Jan 2026 00:00:00 +0000", try rfc2822(arena.allocator(), default_mtime));
}

test "the date is RFC 2822, from the epoch" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 +0000", try rfc2822(a, 0));
    try t.expectEqualStrings("Tue, 14 Nov 2023 22:13:20 +0000", try rfc2822(a, 1700000000));
    try t.expectEqualStrings("Sun, 29 Feb 2004 12:00:01 +0000", try rfc2822(a, 1078056001));
}

test "the package holds the binary, the copyright, the changelog and the overrides, and its control file reads back" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try build(a, sample("ELF-not-really"));
    const data = try deb.readData(a, bytes);
    var seen: usize = 0;
    for (data) |m| {
        if (std.mem.eql(u8, m.path, "./usr/bin/mopm")) {
            seen += 1;
            try t.expectEqualStrings("ELF-not-really", m.data);
            try t.expectEqual(@as(u32, 0o755), m.mode);
        }
        if (std.mem.eql(u8, m.path, "./usr/share/doc/mopm/changelog.gz")) {
            seen += 1;
            const text = try tar.gunzip(a, m.data);
            try t.expectEqualStrings("mopm (1.2.3) unstable; urgency=medium\n\n  * Release 1.2.3.\n\n -- mopm authors <apt@mopm.dev>  Thu, 01 Jan 2026 00:00:00 +0000\n", text);
        }
        if (std.mem.eql(u8, m.path, "./usr/share/doc/mopm/copyright")) seen += 1;
        if (std.mem.eql(u8, m.path, "./usr/share/lintian/overrides/mopm")) seen += 1;
    }
    try t.expectEqual(@as(usize, 4), seen);
    const ctrl = try deb.readControl(a, bytes);
    const fields = try control.parse(a, ctrl);
    try t.expectEqualStrings("package manager for Mojo\n Resolves, locks and builds Mojo packages.\n .\n A static binary.", control.get(fields, "Description").?);
}

test "the same inputs give the same bytes, and other binary bytes give other bytes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try build(a, sample("ELF-not-really"));
    const two = try build(a, sample("ELF-not-really"));
    try t.expectEqualSlices(u8, one, two);
    const other = try build(a, sample("ELF-not-really!"));
    try t.expect(!std.mem.eql(u8, one, other));
}

test "a pre-release version becomes a ~ version, and a bad one is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("0.0.1~rc.1", try debVersion(a, "0.0.1-rc.1"));
    try t.expectEqualStrings("1.2.3", try debVersion(a, "1.2.3"));
    var in = sample("x");
    in.version = "0.0.1-rc.1";
    const bytes = try build(a, in);
    const fields = try control.parse(a, try deb.readControl(a, bytes));
    try t.expectEqualStrings("0.0.1~rc.1", control.get(fields, "Version").?);
    in.version = "0.0.1-";
    try t.expectError(error.BadVersion, build(a, in));
    in.version = "0.0.1-rc 1";
    try t.expectError(error.BadVersion, build(a, in));
}

test "metadata that is missing, unknown or empty is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = sample("x");
    in.control = "Maintainer: m <m@x.dev>\nDescription: d\n";
    try t.expectError(error.MissingField, build(a, in));
    in.control = sample_control ++ "Depends: libc6\n";
    try t.expectError(error.UnknownField, build(a, in));
    in = sample("x");
    in.copyright = "";
    try t.expectError(error.EmptyFile, build(a, in));
    in = sample("");
    try t.expectError(error.EmptyFile, build(a, in));
    in = sample("x");
    in.version = "1.2";
    try t.expectError(error.BadVersion, build(a, in));
}

// ---- the data-only form ------------------------------------------------------------------

const data_control =
    "Maintainer: mopm authors <apt@mopm.dev>\n" ++
    "Homepage: https://mopm.dev\n" ++
    "Description: a data package\n" ++
    " Files only.\n";

const data_files = [_]DataFile{.{ .path = "usr/share/keyrings/sample.gpg", .data = "\x99\x02key-bytes", .mode = 0o644 }};

fn dataSample() DataInputs {
    return .{ .name = "sample-keyring", .version = "2026.10.21", .control = data_control, .copyright = "Format: x\nLicense: Apache-2.0\n", .files = &data_files };
}

test "a data package is Architecture all with exactly its files, the copyright and the changelog" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try buildData(a, dataSample());
    const fields = try control.parse(a, try deb.readControl(a, bytes));
    try t.expectEqualStrings("all", control.get(fields, "Architecture").?);
    try t.expectEqualStrings("misc", control.get(fields, "Section").?);
    try t.expectEqualStrings("2026.10.21", control.get(fields, "Version").?);
    // The control archive is the control file and the md5sums: no maintainer script, no conffiles.
    const members = try deb.readAr(a, bytes);
    for (try tar.read(a, try tar.gunzip(a, members[1].data))) |m| {
        try t.expect(std.mem.eql(u8, m.path, "./") or std.mem.eql(u8, m.path, "./control") or std.mem.eql(u8, m.path, "./md5sums"));
    }
    var files: usize = 0;
    for (try deb.readData(a, bytes)) |m| {
        if (m.kind == .dir) continue;
        files += 1;
        try t.expect(!std.mem.startsWith(u8, m.path, "./etc/"));
        if (std.mem.eql(u8, m.path, "./usr/share/keyrings/sample.gpg")) {
            try t.expectEqualStrings("\x99\x02key-bytes", m.data);
            try t.expectEqual(@as(u32, 0o644), m.mode);
            try t.expectEqual(@as(u32, 0), m.uid);
            try t.expectEqual(@as(u32, 0), m.gid);
        } else {
            try t.expect(std.mem.eql(u8, m.path, "./usr/share/doc/sample-keyring/copyright") or std.mem.eql(u8, m.path, "./usr/share/doc/sample-keyring/changelog.gz"));
            try t.expectEqual(@as(u32, 0o644), m.mode);
        }
    }
    try t.expectEqual(@as(usize, 3), files);
    const two = try buildData(a, dataSample());
    try t.expectEqualSlices(u8, bytes, two);
}

test "a data package is indexed like any other: its stanza says all" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try @import("apt.zig").stanzaOf(a, try buildData(a, dataSample()));
    try t.expectEqualStrings("all", s.architecture);
    try t.expectEqualStrings("sample-keyring", s.package);
}

test "a data package refuses what would make it more than data" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = dataSample();
    const conf = [_]DataFile{.{ .path = "etc/sample.conf", .data = "x", .mode = 0o644 }};
    in.files = &conf;
    try t.expectError(error.ConffilePath, buildData(a, in));
    const etc = [_]DataFile{.{ .path = "etc", .data = "x", .mode = 0o644 }};
    in.files = &etc;
    try t.expectError(error.ConffilePath, buildData(a, in));
    // `etcetera/` is not `etc/`.
    const near = [_]DataFile{.{ .path = "usr/etcetera/x", .data = "x", .mode = 0o644 }};
    in.files = &near;
    _ = try buildData(a, in);
    const clash = [_]DataFile{.{ .path = "usr/share/doc/sample-keyring/copyright", .data = "x", .mode = 0o644 }};
    in.files = &clash;
    try t.expectError(error.ReservedPath, buildData(a, in));
    const clash2 = [_]DataFile{.{ .path = "usr/share/doc/sample-keyring/changelog.gz", .data = "x", .mode = 0o644 }};
    in.files = &clash2;
    try t.expectError(error.ReservedPath, buildData(a, in));
    const suid = [_]DataFile{.{ .path = "usr/bin/x", .data = "x", .mode = 0o4755 }};
    in.files = &suid;
    try t.expectError(error.BadMode, buildData(a, in));
    for ([_]u32{ 0o600, 0o700, 0o555, 0o444, 0o664, 0o775, 0o666, 0o000, 0o4755, 0o1755 }) |bad| {
        const one = [_]DataFile{.{ .path = "usr/share/x", .data = "x", .mode = bad }};
        in.files = &one;
        try t.expectError(error.BadMode, buildData(a, in));
    }
    const ok755 = [_]DataFile{.{ .path = "usr/bin/x", .data = "x", .mode = 0o755 }};
    in.files = &ok755;
    _ = try buildData(a, in);
    const gw = [_]DataFile{.{ .path = "usr/share/x", .data = "x", .mode = 0o664 }};
    in.files = &gw;
    try t.expectError(error.BadMode, buildData(a, in));
    const empty = [_]DataFile{.{ .path = "usr/share/x", .data = "", .mode = 0o644 }};
    in.files = &empty;
    try t.expectError(error.EmptyFile, buildData(a, in));
    in.files = &.{};
    try t.expectError(error.EmptyFile, buildData(a, in));
    in = dataSample();
    in.copyright = "";
    try t.expectError(error.EmptyFile, buildData(a, in));
    in = dataSample();
    in.control = data_control ++ "Depends: gnupg\n";
    try t.expectError(error.UnknownField, buildData(a, in));
    in.control = "Maintainer: m <m@x>\nDescription: d\n";
    try t.expectError(error.MissingField, buildData(a, in));
    in = dataSample();
    in.name = "Bad Name";
    try t.expectError(error.BadName, buildData(a, in));
}

test "a date version: the shared version rules take 2026.10.9 and order it numerically (before 2026.10.21), and refuse the zero-padded 2026.10.09" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = dataSample();
    in.version = "2026.10.9";
    const fields = try control.parse(a, try deb.readControl(a, try buildData(a, in)));
    try t.expectEqualStrings("2026.10.9", control.get(fields, "Version").?);
    const version_mod = @import("version.zig");
    const nine = try version_mod.Version.parse("2026.10.9");
    const twenty_one = try version_mod.Version.parse("2026.10.21");
    try t.expectEqual(std.math.Order.lt, nine.order(twenty_one));
    in.version = "2026.10.09";
    try t.expectError(error.BadVersion, buildData(a, in));
}
