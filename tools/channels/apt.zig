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

pub const Error = error{ BadStanza, MissingField, VersionConflict, ArchitectureNotIndexed, BadKeep };

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

/// The index stanza of a .deb: its control fields, then Filename, Size and SHA256 of the file, Description last.
pub fn stanzaOf(a: Allocator, deb_bytes: []const u8) !Stanza {
    const ctrl = try deb.readControl(a, deb_bytes);
    const fields = try control.parse(a, ctrl);
    const package = control.get(fields, "Package") orelse return error.MissingField;
    const ver = control.get(fields, "Version") orelse return error.MissingField;
    const arch = control.get(fields, "Architecture") orelse return error.MissingField;
    _ = try Version.parse(ver);
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
    try out.append(.{ .name = "Filename", .value = try poolPath(a, package, file_name) });
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
    for (add) |n| {
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
    origin: []const u8,
    label: []const u8,
    description: []const u8,
    suite: []const u8 = "stable",
    codename: []const u8 = "stable",
    component: []const u8 = "main",
    /// Seconds since the epoch: the `Date` field.
    date: u64,
};

const day_names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
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

/// The index files of `archs` (Packages and Packages.gz under `dists/<suite>/<component>/binary-<arch>/`) and the
/// Release that lists them. Paths are relative to the repository root. A stanza whose architecture is not in
/// `archs` is refused: it would be listed nowhere.
pub fn tree(a: Allocator, info: ReleaseInfo, stanzas: []const Stanza, archs: []const []const u8) ![]TreeFile {
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
    const fields = [_]control.Field{
        .{ .name = "Origin", .value = info.origin },
        .{ .name = "Label", .value = info.label },
        .{ .name = "Suite", .value = info.suite },
        .{ .name = "Codename", .value = info.codename },
        .{ .name = "Date", .value = try formatDate(a, info.date) },
        .{ .name = "Architectures", .value = archs_line },
        .{ .name = "Components", .value = info.component },
        .{ .name = "Description", .value = info.description },
    };
    var rel_text = std.ArrayList(u8).init(a);
    try rel_text.appendSlice(try control.render(a, &fields));
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
