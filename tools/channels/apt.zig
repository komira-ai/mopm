//! The apt side: the `Packages` stanza of a .deb, merging new .debs into an existing index (monotonic, bounded),
//! `Packages` / `Packages.gz`, and `Release` with the checksums apt checks.
//!
//! Layout (suite `stable`, component `main`):
//!   dists/stable/Release
//!   dists/stable/main/binary-<arch>/Packages and Packages.gz
//!   pool/main/<first letter>/<package>/<package>_<version>_<arch>.deb
//! `Release` lists SHA256 and size of every index file, which is what `apt-get update` verifies after it has
//! verified the signature of `Release` (signing is not done here). Everything is a pure function of its inputs: the
//! `Date` is a parameter, nothing reads the clock.

const std = @import("std");
const Allocator = std.mem.Allocator;
const control = @import("control.zig");
const deb = @import("deb.zig");
const tar = @import("tar.zig");
const version_mod = @import("version.zig");
const Version = version_mod.Version;

pub const Stanza = struct {
    package: []const u8,
    version: Version,
    architecture: []const u8,
    sha256: []const u8,
    /// The stanza text, ending in `\n`.
    text: []const u8,
};

pub const Error = error{ BadStanza, MissingField, VersionConflict, ArchitectureNotIndexed, BadKeep, BadName, BadArchitecture, ReservedField, BadPoolDir };

/// Fields the index writes itself, from the file: a control file that carries one would forge the file's name, size or
/// checksums. Field names are not case sensitive in Debian control files.
const reserved_fields = [_][]const u8{ "Filename", "Size", "SHA256", "MD5sum", "SHA1" };

/// `pool/main/m/mopm/mopm_1.2.3_amd64.deb` for package `mopm`: the first letter, or `lib` and the letter for `lib*`.
pub fn poolPath(a: Allocator, package: []const u8, file_name: []const u8) ![]u8 {
    const dir = if (std.mem.startsWith(u8, package, "lib") and package.len > 3) package[0..4] else package[0..1];
    return std.fmt.allocPrint(a, "pool/main/{s}/{s}/{s}", .{ dir, package, file_name });
}

pub fn debFileName(a: Allocator, package: []const u8, version: []const u8, arch: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}_{s}_{s}.deb", .{ package, version, arch });
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

fn fromFields(a: Allocator, text: []const u8) !Stanza {
    const fields = try control.parse(a, text);
    const package = control.get(fields, "Package") orelse return error.MissingField;
    const ver = control.get(fields, "Version") orelse return error.MissingField;
    const arch = control.get(fields, "Architecture") orelse return error.MissingField;
    const sum = control.get(fields, "SHA256") orelse return error.MissingField;
    return .{
        .package = package,
        .version = try Version.parse(ver),
        .architecture = arch,
        .sha256 = sum,
        .text = text,
    };
}

/// A pool directory a product may own in a repository shared by several: `pool/` and then one or more path segments of
/// lower-case letters, digits and `.+-_`, none empty, `.` or `..`, no leading or trailing slash (it becomes part of a key).
pub fn validPoolDir(dir: []const u8) bool {
    const head = "pool/";
    if (!std.mem.startsWith(u8, dir, head) or dir.len == head.len) return false;
    var segs = std.mem.splitScalar(u8, dir[head.len..], '/');
    while (segs.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
        for (seg) |ch| {
            const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '.' or ch == '+' or ch == '-' or ch == '_';
            if (!ok) return false;
        }
    }
    return true;
}

/// The index stanza of a .deb: its control fields, then Filename, Size and SHA256 of the file, Description last.
/// The file is named in the layout of one repository of one product (`pool/main/<letter>/<package>/`).
pub fn stanzaOf(a: Allocator, deb_bytes: []const u8) !Stanza {
    return stanzaOfIn(a, deb_bytes, null);
}

/// Like `stanzaOf`, but with a `pool_dir` (see `validPoolDir`) the Filename is `<pool_dir>/<file>`: the layout of a repository
/// shared by several products, each of which may write only below its own pool directory.
pub fn stanzaOfIn(a: Allocator, deb_bytes: []const u8, pool_dir: ?[]const u8) !Stanza {
    if (pool_dir) |d| {
        if (!validPoolDir(d)) return error.BadPoolDir;
    }
    const ctrl = try deb.readControl(a, deb_bytes);
    const fields = try control.parse(a, ctrl);
    const package = control.get(fields, "Package") orelse return error.MissingField;
    const ver = control.get(fields, "Version") orelse return error.MissingField;
    const arch = control.get(fields, "Architecture") orelse return error.MissingField;
    // The same rules deb.build applies: the name and the architecture become a path in the pool.
    if (!deb.validName(package)) return error.BadName;
    _ = try Version.parse(ver);
    if (!deb.validArch(arch)) return error.BadArchitecture;
    for (fields) |f| {
        for (reserved_fields) |r| {
            if (std.ascii.eqlIgnoreCase(f.name, r)) return error.ReservedField;
        }
    }
    const file_name = try debFileName(a, package, ver, arch);
    const sum = sha256Hex(deb_bytes);
    var out = std.ArrayList(control.Field).init(a);
    var description: ?control.Field = null;
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "Description")) {
            description = f;
        } else {
            try out.append(f);
        }
    }
    const filename = if (pool_dir) |d| try std.fmt.allocPrint(a, "{s}/{s}", .{ d, file_name }) else try poolPath(a, package, file_name);
    try out.append(.{ .name = "Filename", .value = filename });
    try out.append(.{ .name = "Size", .value = try std.fmt.allocPrint(a, "{d}", .{deb_bytes.len}) });
    try out.append(.{ .name = "SHA256", .value = try a.dupe(u8, &sum) });
    if (description) |d| try out.append(d);
    return fromFields(a, try control.render(a, out.items));
}

/// The stanzas of a `Packages` file. An empty text is an empty index.
pub fn parsePackages(a: Allocator, text: []const u8) ![]Stanza {
    var out = std.ArrayList(Stanza).init(a);
    errdefer out.deinit();
    for (try control.splitStanzas(a, text)) |s| try out.append(try fromFields(a, s));
    return out.toOwnedSlice();
}

fn stanzaLess(_: void, x: Stanza, y: Stanza) bool {
    switch (std.mem.order(u8, x.package, y.package)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    switch (std.mem.order(u8, x.architecture, y.architecture)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return x.version.order(y.version) == .gt; // newest first
}

pub const Merged = struct {
    /// Sorted: package, architecture, newest version first. At most `keep` per package and architecture.
    stanzas: []Stanza,
    /// How many of the added stanzas were new (the others were already present, byte for byte).
    added: usize,
    /// The versions dropped from the index because more than `keep` were listed.
    dropped: usize,
};

/// Adds `add` to `existing`. A version older than the newest listed for its package and architecture is refused
/// (`ChannelWouldMoveDown`); the same version again is a no-op when the file's sha256 is the same and
/// `VersionConflict` when it is not. Only the newest `keep` versions per package and architecture stay listed.
pub fn merge(a: Allocator, existing: []const Stanza, add: []const Stanza, keep: usize) !Merged {
    if (keep == 0) return error.BadKeep;
    var all = std.ArrayList(Stanza).init(a);
    try all.appendSlice(existing);
    var added: usize = 0;
    for (add, 0..) |n, i| {
        // Among the added stanzas themselves: the same version twice is one (when the bytes are the same) or a conflict.
        var repeat = false;
        for (add[0..i]) |m| {
            if (!std.mem.eql(u8, m.package, n.package) or !std.mem.eql(u8, m.architecture, n.architecture)) continue;
            if (m.version.order(n.version) != .eq) continue;
            if (!std.mem.eql(u8, m.sha256, n.sha256)) return error.VersionConflict;
            repeat = true;
        }
        if (repeat) continue;
        var newest: ?Version = null;
        var same: ?Stanza = null;
        for (existing) |e| {
            if (!std.mem.eql(u8, e.package, n.package) or !std.mem.eql(u8, e.architecture, n.architecture)) continue;
            if (newest == null or e.version.order(newest.?) == .gt) newest = e.version;
            if (e.version.order(n.version) == .eq) same = e;
        }
        switch (try version_mod.checkMove(newest, n.version)) {
            .advance => {
                try all.append(n);
                added += 1;
            },
            .same => {
                if (!std.mem.eql(u8, same.?.sha256, n.sha256)) return error.VersionConflict;
            },
        }
    }
    std.mem.sort(Stanza, all.items, {}, stanzaLess);
    var kept = std.ArrayList(Stanza).init(a);
    var run: usize = 0;
    var dropped: usize = 0;
    for (all.items, 0..) |s, i| {
        if (i > 0 and std.mem.eql(u8, all.items[i - 1].package, s.package) and std.mem.eql(u8, all.items[i - 1].architecture, s.architecture)) {
            run += 1;
        } else {
            run = 0;
        }
        if (run < keep) {
            try kept.append(s);
        } else {
            dropped += 1;
        }
    }
    return .{ .stanzas = try kept.toOwnedSlice(), .added = added, .dropped = dropped };
}

/// The `Packages` text of one architecture: its stanzas, each followed by a blank line.
pub fn renderPackages(a: Allocator, stanzas: []const Stanza, arch: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    for (stanzas) |s| {
        if (!std.mem.eql(u8, s.architecture, arch)) continue;
        try out.appendSlice(s.text);
        try out.append('\n');
    }
    return out.toOwnedSlice();
}

pub const TreeFile = struct { path: []const u8, data: []const u8 };

pub const ReleaseInfo = struct {
    /// Origin, Label and Description are null when the Release carries no such field (see `keepSharedFields`).
    origin: ?[]const u8,
    label: ?[]const u8,
    description: ?[]const u8,
    suite: []const u8 = "stable",
    codename: []const u8 = "stable",
    component: []const u8 = "main",
    /// Seconds since the epoch: the `Date` field.
    date: u64,
};

/// The Release of a shared repository belongs to every product that publishes into it: the Origin, Label and Description of the Release
/// that exists stay exactly as they are (a field it lacks stays absent), and `info` supplies them only for the first Release, when there is
/// none. `existing` is the text of the Release that was read, null when there was none.
pub fn keepSharedFields(a: Allocator, existing: ?[]const u8, info: ReleaseInfo) !ReleaseInfo {
    const text = existing orelse return info;
    if (text.len == 0) return info;
    const fields = try control.parse(a, text);
    var out = info;
    out.origin = control.get(fields, "Origin");
    out.label = control.get(fields, "Label");
    out.description = control.get(fields, "Description");
    return out;
}

const day_names =[_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// RFC 2822 in UTC: `Tue, 20 Oct 2026 12:00:00 UTC`.
pub fn formatDate(a: Allocator, secs: u64) ![]u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    // 1970-01-01 was a Thursday.
    const weekday = (day.day + 3) % 7;
    return std.fmt.allocPrint(a, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        day_names[weekday],
        md.day_index + 1,
        month_names[md.month.numeric() - 1],
        yd.year,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

/// The architectures an index lists: `given` (as it is, so a repeated one is still refused by `tree`), then every architecture of `listed` (the
/// repository's own: an index written without one would drop its packages), then `all` when a stanza to add is for it. `all` is the one
/// architecture added on the strength of a stanza: a package for every architecture must not be refused by `tree`, whichever product publishes
/// first. Any other architecture a stanza names that nobody listed stays refused (`ArchitectureNotIndexed`): that is a .deb built for the wrong target.
pub fn widenArchs(a: Allocator, given: []const []const u8, listed: []const []const u8, add: []const Stanza) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    try out.appendSlice(given);
    for (listed) |arch| try appendNew(&out, arch);
    for (add) |s| {
        if (std.mem.eql(u8, s.architecture, "all")) try appendNew(&out, "all");
    }
    return out.toOwnedSlice();
}

fn appendNew(out: *std.ArrayList([]const u8), arch: []const u8) !void {
    for (out.items) |x| {
        if (std.mem.eql(u8, x, arch)) return;
    }
    try out.append(arch);
}

/// The index files of `archs` (Packages and Packages.gz under `dists/<suite>/<component>/binary-<arch>/`) and the
/// Release that lists them. Paths are relative to the repository root. A stanza whose architecture is not in
/// `archs` is refused: it would be listed nowhere.
pub fn tree(a: Allocator, info: ReleaseInfo, stanzas: []const Stanza, archs: []const []const u8) ![]TreeFile {
    // An architecture is a name (it becomes a directory) and is listed once (its Packages would be written twice).
    for (archs, 0..) |x, i| {
        if (!deb.validArch(x)) return error.BadArchitecture;
        for (archs[0..i]) |y| {
            if (std.mem.eql(u8, x, y)) return error.BadArchitecture;
        }
    }
    for (stanzas) |s| {
        var found = false;
        for (archs) |x| {
            if (std.mem.eql(u8, x, s.architecture)) found = true;
        }
        if (!found) return error.ArchitectureNotIndexed;
    }
    const sorted_archs = try a.dupe([]const u8, archs);
    std.mem.sort([]const u8, sorted_archs, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var files = std.ArrayList(TreeFile).init(a);
    var sums = std.ArrayList(u8).init(a);
    for (sorted_archs) |arch| {
        const packages = try renderPackages(a, stanzas, arch);
        const gz = try tar.gzip(a, packages);
        const rel = try std.fmt.allocPrint(a, "{s}/binary-{s}/Packages", .{ info.component, arch });
        const rel_gz = try std.fmt.allocPrint(a, "{s}.gz", .{rel});
        try files.append(.{ .path = try std.fmt.allocPrint(a, "dists/{s}/{s}", .{ info.suite, rel }), .data = packages });
        try files.append(.{ .path = try std.fmt.allocPrint(a, "dists/{s}/{s}", .{ info.suite, rel_gz }), .data = gz });
        try sums.writer().print(" {s} {d} {s}\n", .{ sha256Hex(packages), packages.len, rel });
        try sums.writer().print(" {s} {d} {s}\n", .{ sha256Hex(gz), gz.len, rel_gz });
    }
    const archs_line = try std.mem.join(a, " ", sorted_archs);
    var fields = std.ArrayList(control.Field).init(a);
    if (info.origin) |v| try fields.append(.{ .name = "Origin", .value = v });
    if (info.label) |v| try fields.append(.{ .name = "Label", .value = v });
    try fields.append(.{ .name = "Suite", .value = info.suite });
    try fields.append(.{ .name = "Codename", .value = info.codename });
    try fields.append(.{ .name = "Date", .value = try formatDate(a, info.date) });
    try fields.append(.{ .name = "Architectures", .value = archs_line });
    try fields.append(.{ .name = "Components", .value = info.component });
    if (info.description) |v| try fields.append(.{ .name = "Description", .value = v });
    // The index files are also served by their hash (`by-hash/SHA256/<hash>` below each binary-<arch> directory, which the publish writes
    // before the plain files), so a client that reads a Release finds the files it lists whatever is written next.
    try fields.append(.{ .name = "Acquire-By-Hash", .value = "yes" });
    var rel_text = std.ArrayList(u8).init(a);
    try rel_text.appendSlice(try control.render(a, fields.items));
    try rel_text.appendSlice("SHA256:\n");
    try rel_text.appendSlice(sums.items);
    try files.append(.{ .path = try std.fmt.allocPrint(a, "dists/{s}/Release", .{info.suite}), .data = try rel_text.toOwnedSlice() });
    return files.toOwnedSlice();
}

// ---- tests -------------------------------------------------------------------------------

const t = std.testing;

fn sampleDeb(a: Allocator, ver: []const u8, arch: []const u8, payload: []const u8) ![]u8 {
    return deb.build(a, .{
        .name = "mopm",
        .version = ver,
        .architecture = arch,
        .maintainer = "mopm authors <apt@mopm.dev>",
        .homepage = "https://mopm.dev",
        .synopsis = "package manager for Mojo",
        .files = &.{.{ .path = "usr/bin/mopm", .data = payload, .mode = 0o755 }},
        .mtime = 1700000000,
    });
}

test "poolPath: first letter, lib prefix kept" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("pool/main/m/mopm/mopm_1.2.3_amd64.deb", try poolPath(a, "mopm", "mopm_1.2.3_amd64.deb"));
    try t.expectEqualStrings("pool/main/libr/libruby/x.deb", try poolPath(a, "libruby", "x.deb"));
    try t.expectEqualStrings("pool/main/l/lib/x.deb", try poolPath(a, "lib", "x.deb"));
}

test "the stanza of a deb names its file, its size and the sha256 of its bytes, and ends with Description" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try sampleDeb(a, "1.2.3", "amd64", "payload");
    const s = try stanzaOf(a, bytes);
    try t.expectEqualStrings("mopm", s.package);
    try t.expectEqualStrings("amd64", s.architecture);
    try t.expectEqualStrings(&sha256Hex(bytes), s.sha256);
    const fields = try control.parse(a, s.text);
    try t.expectEqualStrings("pool/main/m/mopm/mopm_1.2.3_amd64.deb", control.get(fields, "Filename").?);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{d}", .{bytes.len}), control.get(fields, "Size").?);
    try t.expectEqualStrings("Description", fields[fields.len - 1].name);
    try t.expectEqualStrings("Package", fields[0].name);
}

test "validPoolDir: pool/ and clean lower-case segments only" {
    for ([_][]const u8{ "pool/mopm", "pool/a.b-c_d+e", "pool/mopm/x1" }) |d| try t.expect(validPoolDir(d));
    for ([_][]const u8{ "", "pool", "pool/", "mopm", "/pool/mopm", "pool/mopm/", "pool//mopm", "pool/../x", "pool/./x", "pool/Mopm", "pool/a b", "pool/a\\b", "pool/mopm/.." }) |d| try t.expect(!validPoolDir(d));
}

test "a pool directory names the file below it, and a bad one is refused before anything is built" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try sampleDeb(a, "1.2.3", "amd64", "payload");
    const s = try stanzaOfIn(a, bytes, "pool/mopm");
    try t.expectEqualStrings("pool/mopm/mopm_1.2.3_amd64.deb", control.get(try control.parse(a, s.text), "Filename").?);
    // The checksum and size are the file's own, whatever the directory.
    try t.expectEqualStrings(&sha256Hex(bytes), s.sha256);
    try t.expectError(error.BadPoolDir, stanzaOfIn(a, bytes, "pool/../etc"));
    try t.expectError(error.BadPoolDir, stanzaOfIn(a, bytes, "elsewhere"));
}

test "merge: new versions are added, newest first; the same file again is a no-op" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d1 = try stanzaOf(a, try sampleDeb(a, "1.9.0", "amd64", "one"));
    const d2 = try stanzaOf(a, try sampleDeb(a, "1.10.0", "amd64", "two"));
    const first = try merge(a, &.{}, &.{d1}, 25);
    try t.expectEqual(@as(usize, 1), first.added);
    const second = try merge(a, first.stanzas, &.{d2}, 25);
    try t.expectEqual(@as(usize, 1), second.added);
    try t.expectEqual(@as(usize, 2), second.stanzas.len);
    try t.expectEqual(@as(u32, 10), second.stanzas[0].version.minor); // 1.10.0 before 1.9.0
    const again = try merge(a, second.stanzas, &.{d2}, 25);
    try t.expectEqual(@as(usize, 0), again.added);
    try t.expectEqual(@as(usize, 2), again.stanzas.len);
}

test "merge refuses to move an architecture down, and a changed file under the same version" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const new = try stanzaOf(a, try sampleDeb(a, "1.2.3", "amd64", "one"));
    const old = try stanzaOf(a, try sampleDeb(a, "1.2.2", "amd64", "zero"));
    const changed = try stanzaOf(a, try sampleDeb(a, "1.2.3", "amd64", "different"));
    const index = try merge(a, &.{}, &.{new}, 25);
    try t.expectError(error.ChannelWouldMoveDown, merge(a, index.stanzas, &.{old}, 25));
    try t.expectError(error.VersionConflict, merge(a, index.stanzas, &.{changed}, 25));
    // Another architecture has its own newest version: arm64 1.2.2 is fine beside amd64 1.2.3.
    const arm_old = try stanzaOf(a, try sampleDeb(a, "1.2.2", "arm64", "arm"));
    const both = try merge(a, index.stanzas, &.{arm_old}, 25);
    try t.expectEqual(@as(usize, 2), both.stanzas.len);
}

test "merge keeps the newest N per architecture and counts what it dropped" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var index: []const Stanza = &.{};
    var patch: u32 = 0;
    while (patch < 5) : (patch += 1) {
        const v = try std.fmt.allocPrint(a, "1.0.{d}", .{patch});
        const amd = try stanzaOf(a, try sampleDeb(a, v, "amd64", v));
        const arm = try stanzaOf(a, try sampleDeb(a, v, "arm64", v));
        index = (try merge(a, index, &.{ amd, arm }, 3)).stanzas;
    }
    try t.expectEqual(@as(usize, 6), index.len);
    var amd_versions: usize = 0;
    for (index) |s| {
        if (std.mem.eql(u8, s.architecture, "amd64")) {
            amd_versions += 1;
            try t.expect(s.version.patch >= 2);
        }
    }
    try t.expectEqual(@as(usize, 3), amd_versions);
    try t.expectError(error.BadKeep, merge(a, index, &.{}, 0));
}

test "Packages parses back to the same stanzas" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s1 = try stanzaOf(a, try sampleDeb(a, "1.0.0", "amd64", "a"));
    const s2 = try stanzaOf(a, try sampleDeb(a, "1.0.1", "amd64", "b"));
    const merged = try merge(a, &.{}, &.{ s1, s2 }, 25);
    const text = try renderPackages(a, merged.stanzas, "amd64");
    const back = try parsePackages(a, text);
    try t.expectEqual(@as(usize, 2), back.len);
    for (merged.stanzas, back) |x, y| try t.expectEqualStrings(x.text, y.text);
    try t.expectEqual(@as(usize, 0), (try renderPackages(a, merged.stanzas, "arm64")).len);
    try t.expectEqual(@as(usize, 0), (try parsePackages(a, "")).len);
}

test "keepSharedFields: the Origin, Label and Description of an existing Release win; the first Release takes the given ones" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mine = ReleaseInfo{ .origin = "mopm", .label = "mopm", .description = "mopm packages", .date = 1700000000 };
    // No Release: the first creation sets all three.
    const first = try keepSharedFields(a, null, mine);
    try t.expectEqualStrings("mopm", first.origin.?);
    try t.expectEqualStrings("mopm packages", first.description.?);
    try t.expectEqual(@as(usize, 1700000000), first.date);
    // An empty file is no Release either.
    try t.expectEqualStrings("mopm", (try keepSharedFields(a, "", mine)).label.?);
    // A Release of another product: its three fields stay (a multi-line Description too), whatever the caller passes.
    const other = "Origin: Shared Co\nLabel: Shared Label\nSuite: stable\nDescription: line one\n line two\nSHA256:\n aa 1 main/binary-amd64/Packages\n";
    const kept = try keepSharedFields(a, other, mine);
    try t.expectEqualStrings("Shared Co", kept.origin.?);
    try t.expectEqualStrings("Shared Label", kept.label.?);
    try t.expectEqualStrings("line one\n line two", kept.description.?);
    // A field the existing Release lacks is not added.
    const bare = try keepSharedFields(a, "Suite: stable\nSHA256:\n aa 1 main/binary-amd64/Packages\n", mine);
    try t.expect(bare.origin == null and bare.label == null and bare.description == null);
    // A Release that is not a control file is an error, not a silent overwrite.
    try t.expectError(error.BadStanza, keepSharedFields(a, "not a control file\n", mine));
    // And the Release rendered from kept fields carries them, and no field that is null.
    const s = try stanzaOf(a, try sampleDeb(a, "1.2.3", "amd64", "one"));
    const files = try tree(a, bare, &.{s}, &.{"amd64"});
    const rel = files[files.len - 1].data;
    try t.expect(std.mem.indexOf(u8, rel, "Origin:") == null and std.mem.indexOf(u8, rel, "Label:") == null and std.mem.indexOf(u8, rel, "\nDescription:") == null);
    try t.expect(std.mem.indexOf(u8, rel, "Acquire-By-Hash: yes\n") != null);
    const full = try tree(a, kept, &.{s}, &.{"amd64"});
    try t.expect(std.mem.indexOf(u8, full[full.len - 1].data, "Origin: Shared Co\nLabel: Shared Label\n") != null);
    try t.expect(std.mem.indexOf(u8, full[full.len - 1].data, "Description: line one\n line two\nAcquire-By-Hash: yes\nSHA256:\n") != null);
}

test "formatDate: weekday, month and time of known instants" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 UTC", try formatDate(a, 0));
    try t.expectEqualStrings("Tue, 14 Nov 2023 22:13:20 UTC", try formatDate(a, 1700000000));
    try t.expectEqualStrings("Sun, 29 Feb 2004 23:59:59 UTC", try formatDate(a, 1078099199));
}

test "Release lists the size and sha256 of every index file, and they are the files' own" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try stanzaOf(a, try sampleDeb(a, "1.2.3", "amd64", "one"));
    const info = ReleaseInfo{ .origin = "mopm", .label = "mopm", .description = "mopm packages", .date = 1700000000 };
    const files = try tree(a, info, &.{s}, &.{ "arm64", "amd64" });
    try t.expectEqual(@as(usize, 5), files.len);
    const release = files[files.len - 1];
    try t.expectEqualStrings("dists/stable/Release", release.path);
    const fields = try control.parse(a, release.data[0 .. std.mem.indexOf(u8, release.data, "SHA256:").?]);
    try t.expectEqualStrings("amd64 arm64", control.get(fields, "Architectures").?);
    try t.expectEqualStrings("Tue, 14 Nov 2023 22:13:20 UTC", control.get(fields, "Date").?);
    for (files[0 .. files.len - 1]) |f| {
        const rel = f.path["dists/stable/".len..];
        const line = try std.fmt.allocPrint(a, " {s} {d} {s}\n", .{ sha256Hex(f.data), f.data.len, rel });
        try t.expect(std.mem.indexOf(u8, release.data, line) != null);
    }
    // The .gz holds exactly the Packages next to it.
    try t.expectEqualStrings(files[0].data, try tar.gunzip(a, files[1].data));
    try t.expect(std.mem.indexOf(u8, files[0].data, "Package: mopm\n") != null);
    try t.expectEqual(@as(usize, 0), files[2].data.len); // arm64 has no stanza: an empty Packages, still listed
    // apt-get update fetches an empty Packages for an architecture with no package, so it must be listed.
    try t.expect(std.mem.indexOf(u8, release.data, "main/binary-arm64/Packages\n") != null);
}

test "a stanza of an architecture the Release does not list is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try stanzaOf(a, try sampleDeb(a, "1.2.3", "armhf", "x"));
    const info = ReleaseInfo{ .origin = "mopm", .label = "mopm", .description = "d", .date = 0 };
    try t.expectError(error.ArchitectureNotIndexed, tree(a, info, &.{s}, &.{ "amd64", "arm64" }));
}

/// A .deb whose control file is exactly `ctrl` (deb.build would refuse a bad one, which is what these tests need to write).
fn rawDeb(a: Allocator, ctrl: []const u8) ![]u8 {
    const control_tar = try tar.write(a, &.{.{ .path = "./control", .mode = 0o644, .data = ctrl }}, 1700000000);
    const data_tar = try tar.write(a, &.{.{ .path = "./", .kind = .dir, .mode = 0o755 }}, 1700000000);
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice("!<arch>\n");
    try deb.arMember(&out, "debian-binary", 1700000000, "2.0\n");
    try deb.arMember(&out, "control.tar.gz", 1700000000, try tar.gzip(a, control_tar));
    try deb.arMember(&out, "data.tar.gz", 1700000000, try tar.gzip(a, data_tar));
    return out.toOwnedSlice();
}

const good_ctrl = "Package: mopm\nVersion: 1.2.3\nArchitecture: amd64\nDescription: d\n";

test "rawDeb with a good control file is indexed (the refusals below are about the fields, not the helper)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try stanzaOf(a, try rawDeb(a, good_ctrl));
    try t.expectEqualStrings("pool/main/m/mopm/mopm_1.2.3_amd64.deb", control.get(try control.parse(a, s.text), "Filename").?);
}

test "a package name, version or architecture that deb.build would refuse is refused (no path out of the pool)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.BadName, stanzaOf(a, try rawDeb(a, "Package: ../../evil\nVersion: 1.2.3\nArchitecture: amd64\nDescription: d\n")));
    try t.expectError(error.BadName, stanzaOf(a, try rawDeb(a, "Package: Mopm\nVersion: 1.2.3\nArchitecture: amd64\nDescription: d\n")));
    try t.expectError(error.BadVersion, stanzaOf(a, try rawDeb(a, "Package: mopm\nVersion: ../1.2.3\nArchitecture: amd64\nDescription: d\n")));
    try t.expectError(error.BadVersion, stanzaOf(a, try rawDeb(a, "Package: mopm\nVersion: 1.2\nArchitecture: amd64\nDescription: d\n")));
    try t.expectError(error.BadArchitecture, stanzaOf(a, try rawDeb(a, "Package: mopm\nVersion: 1.2.3\nArchitecture: ../x\nDescription: d\n")));
    try t.expectError(error.BadArchitecture, stanzaOf(a, try rawDeb(a, "Package: mopm\nVersion: 1.2.3\nArchitecture: AMD64\nDescription: d\n")));
}

test "a control file that carries a field the index writes itself is refused, whatever the case" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "Filename", "Size", "SHA256", "MD5sum", "SHA1", "filename", "SHA256" }) |name| {
        const ctrl = try std.fmt.allocPrint(a, "Package: mopm\nVersion: 1.2.3\nArchitecture: amd64\n{s}: forged\nDescription: d\n", .{name});
        try t.expectError(error.ReservedField, stanzaOf(a, try rawDeb(a, ctrl)));
    }
}

test "merge: one call adding the same version twice with other bytes is a conflict; with the same bytes it is added once" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try stanzaOf(a, try sampleDeb(a, "1.2.3", "amd64", "one"));
    const other = try stanzaOf(a, try sampleDeb(a, "1.2.3", "amd64", "other"));
    try t.expectError(error.VersionConflict, merge(a, &.{}, &.{ one, other }, 25));
    try t.expectError(error.VersionConflict, merge(a, &.{}, &.{ other, one }, 25));
    const twice = try merge(a, &.{}, &.{ one, one }, 25);
    try t.expectEqual(@as(usize, 1), twice.added);
    try t.expectEqual(@as(usize, 1), twice.stanzas.len);
    // Another architecture's 1.2.3 is not the same version of the same thing.
    const arm = try stanzaOf(a, try sampleDeb(a, "1.2.3", "arm64", "other"));
    try t.expectEqual(@as(usize, 2), (try merge(a, &.{}, &.{ one, arm }, 25)).stanzas.len);
}

test "tree refuses an architecture listed twice and one that is not a name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const info = ReleaseInfo{ .origin = "mopm", .label = "mopm", .description = "d", .date = 0 };
    try t.expectError(error.BadArchitecture, tree(a, info, &.{}, &.{ "amd64", "amd64" }));
    try t.expectError(error.BadArchitecture, tree(a, info, &.{}, &.{ "amd64", "arm64", "amd64" }));
    try t.expectError(error.BadArchitecture, tree(a, info, &.{}, &.{"../x"}));
    try t.expectError(error.BadArchitecture, tree(a, info, &.{}, &.{ "amd64", "" }));
    try t.expectError(error.BadArchitecture, tree(a, info, &.{}, &.{"AMD64"}));
}

test "formatDate: every weekday and every month name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 1970-01-01 was a Thursday; the seven days from it are the seven weekdays.
    const week = [_][]const u8{
        "Thu, 01 Jan 1970 00:00:00 UTC", "Fri, 02 Jan 1970 00:00:00 UTC", "Sat, 03 Jan 1970 00:00:00 UTC", "Sun, 04 Jan 1970 00:00:00 UTC",
        "Mon, 05 Jan 1970 00:00:00 UTC", "Tue, 06 Jan 1970 00:00:00 UTC", "Wed, 07 Jan 1970 00:00:00 UTC",
    };
    for (week, 0..) |want, day| try t.expectEqualStrings(want, try formatDate(a, day * 86400));
    // The first of each month of 1970 (not a leap year): days since the epoch, 31 59 90 120 151 181 212 243 273 304 334.
    const months = [_]struct { day: u64, want: []const u8 }{
        .{ .day = 0, .want = "Thu, 01 Jan 1970 00:00:00 UTC" },
        .{ .day = 31, .want = "Sun, 01 Feb 1970 00:00:00 UTC" },
        .{ .day = 59, .want = "Sun, 01 Mar 1970 00:00:00 UTC" },
        .{ .day = 90, .want = "Wed, 01 Apr 1970 00:00:00 UTC" },
        .{ .day = 120, .want = "Fri, 01 May 1970 00:00:00 UTC" },
        .{ .day = 151, .want = "Mon, 01 Jun 1970 00:00:00 UTC" },
        .{ .day = 181, .want = "Wed, 01 Jul 1970 00:00:00 UTC" },
        .{ .day = 212, .want = "Sat, 01 Aug 1970 00:00:00 UTC" },
        .{ .day = 243, .want = "Tue, 01 Sep 1970 00:00:00 UTC" },
        .{ .day = 273, .want = "Thu, 01 Oct 1970 00:00:00 UTC" },
        .{ .day = 304, .want = "Sun, 01 Nov 1970 00:00:00 UTC" },
        .{ .day = 334, .want = "Tue, 01 Dec 1970 00:00:00 UTC" },
    };
    for (months) |m| try t.expectEqualStrings(m.want, try formatDate(a, m.day * 86400));
}

fn sampleAllDeb(a: Allocator, ver: []const u8) ![]u8 {
    return deb.build(a, .{
        .name = "sample-keyring",
        .version = ver,
        .architecture = "all",
        .maintainer = "mopm authors <apt@mopm.dev>",
        .homepage = "https://mopm.dev",
        .synopsis = "a data package",
        .section = "misc",
        .files = &.{.{ .path = "usr/share/keyrings/k.gpg", .data = "key", .mode = 0o644 }},
        .mtime = 1790000000,
    });
}

/// The stanzas of every `binary-<arch>/Packages` a tree holds, and the architectures it has directories for: what `apt-index` reads back
/// from the repository the next product publishes into.
fn readBack(a: Allocator, files: []const TreeFile, stanzas: *std.ArrayList(Stanza), listed: *std.ArrayList([]const u8)) !void {
    const mid = "/main/binary-";
    for (files) |f| {
        const at = std.mem.indexOf(u8, f.path, mid) orelse continue;
        if (!std.mem.endsWith(u8, f.path, "/Packages")) continue;
        try listed.append(f.path[at + mid.len .. f.path.len - "/Packages".len]);
        try stanzas.appendSlice(try parsePackages(a, f.data));
    }
}

test "an index with an all stanza and amd64 and arm64 stanzas round-trips, and the next product's publish still succeeds" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const info = ReleaseInfo{ .origin = "o", .label = "l", .description = "d", .date = 1790000000 };
    const defaults = [_][]const u8{ "amd64", "arm64" };

    // The first publish into the repository is a package of architecture all (nothing lists `all` yet).
    const kr = try stanzaOfIn(a, try sampleAllDeb(a, "2026.10.21"), "pool/keyring");
    try t.expectEqualStrings("all", kr.architecture);
    const first_archs = try widenArchs(a, &defaults, &.{}, &.{kr});
    const first = try tree(a, info, (try merge(a, &.{}, &.{kr}, 25)).stanzas, first_archs);
    const release1 = first[first.len - 1].data;
    try t.expect(std.mem.indexOf(u8, release1, "Architectures: all amd64 arm64\n") != null);
    var seen_all = false;
    for (first) |f| {
        if (std.mem.eql(u8, f.path, "dists/stable/main/binary-all/Packages")) {
            seen_all = true;
            try t.expect(std.mem.indexOf(u8, f.data, "Package: sample-keyring\n") != null);
        }
    }
    try t.expect(seen_all);

    // Another product publishes its amd64 and arm64 builds next: the all stanza stays, the new ones are added, nothing is refused.
    var existing = std.ArrayList(Stanza).init(a);
    var listed = std.ArrayList([]const u8).init(a);
    try readBack(a, first, &existing, &listed);
    try t.expectEqual(@as(usize, 1), existing.items.len);
    const amd = try stanzaOf(a, try sampleDeb(a, "1.2.3", "amd64", "x86"));
    const arm = try stanzaOf(a, try sampleDeb(a, "1.2.3", "arm64", "aarch"));
    const second_archs = try widenArchs(a, &defaults, listed.items, &.{ amd, arm });
    const second = try tree(a, info, (try merge(a, existing.items, &.{ amd, arm }, 25)).stanzas, second_archs);
    try t.expect(std.mem.indexOf(u8, second[second.len - 1].data, "Architectures: all amd64 arm64\n") != null);
    var back = std.ArrayList(Stanza).init(a);
    var listed2 = std.ArrayList([]const u8).init(a);
    try readBack(a, second, &back, &listed2);
    try t.expectEqual(@as(usize, 3), back.items.len);
    var names = std.ArrayList([]const u8).init(a);
    for (back.items) |s| try names.append(s.architecture);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    try t.expectEqualStrings("all", names.items[0]);
    try t.expectEqualStrings("amd64", names.items[1]);
    try t.expectEqualStrings("arm64", names.items[2]);

    // And the keyring's next version, after both: the same repository takes it, the other products' packages are unchanged.
    const kr2 = try stanzaOfIn(a, try sampleAllDeb(a, "2026.11.2"), "pool/keyring");
    const third_archs = try widenArchs(a, &defaults, listed2.items, &.{kr2});
    const m3 = try merge(a, back.items, &.{kr2}, 25);
    try t.expectEqual(@as(usize, 4), m3.stanzas.len);
    _ = try tree(a, info, m3.stanzas, third_archs);
}

test "widenArchs: the given ones as they are, then the repository's and the added stanzas', each once" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kr = try stanzaOf(a, try sampleAllDeb(a, "2026.10.21"));
    const amd = try stanzaOf(a, try sampleDeb(a, "1.2.3", "amd64", "x"));
    const got = try widenArchs(a, &.{ "amd64", "arm64" }, &.{ "s390x", "amd64", "all" }, &.{ amd, kr });
    try t.expectEqual(@as(usize, 4), got.len);
    try t.expectEqualStrings("amd64", got[0]);
    try t.expectEqualStrings("arm64", got[1]);
    try t.expectEqualStrings("s390x", got[2]);
    try t.expectEqualStrings("all", got[3]);
    // A repeated --arch is kept, so `tree` refuses it as before.
    const twice = try widenArchs(a, &.{ "amd64", "amd64" }, &.{}, &.{});
    try t.expectEqual(@as(usize, 2), twice.len);
    // Only the added stanza names `all`: it is listed.
    const only = try widenArchs(a, &.{"amd64"}, &.{}, &.{kr});
    try t.expectEqual(@as(usize, 2), only.len);
    try t.expectEqualStrings("all", only[1]);
}

test "widenArchs: a stanza of another unlisted architecture does not widen the index, so a .deb for the wrong target is still refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const armhf = try stanzaOf(a, try sampleDeb(a, "1.2.3", "armhf", "x"));
    const got = try widenArchs(a, &.{ "amd64", "arm64" }, &.{}, &.{armhf});
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectError(error.ArchitectureNotIndexed, tree(a, .{ .origin = null, .label = null, .description = null, .date = 0 }, &.{armhf}, got));
}
