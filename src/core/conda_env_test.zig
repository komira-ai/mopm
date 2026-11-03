//! Tests of core/conda_env.zig: the staged replacement of an environment.

const std = @import("std");
const Allocator = std.mem.Allocator;
const env_mod = @import("conda_env.zig");
const fx = @import("conda_fixture.zig");

const Pkg = env_mod.Pkg;
const Diag = env_mod.Diag;
const readStamp = env_mod.readStamp;

/// `recover`, `stage` and `commit`, for a test that needs no look at the candidate.
fn installEnv(arena: Allocator, parent: std.fs.Dir, env_name: []const u8, prefix: []const u8, pkgs: []const Pkg, stamp: []const u8, diag: *Diag) ![]const @import("conda_unpack.zig").Installed {
    _ = try env_mod.recover(arena, parent, env_name);
    const cand = try env_mod.stage(arena, parent, env_name, prefix, pkgs, stamp, diag);
    _ = env_mod.commit(arena, parent, env_name, cand, diag) catch |e| {
        env_mod.discard(parent, cand);
        return e;
    };
    return cand.installed;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    cache: std.fs.Dir,
    parent: std.fs.Dir,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.makeDir("pkgs");
        try tmp.dir.makeDir("m");
        return .{
            .tmp = tmp,
            .cache = try tmp.dir.openDir("pkgs", .{}),
            .parent = try tmp.dir.openDir("m", .{}),
        };
    }

    fn deinit(self: *Fixture) void {
        self.cache.close();
        self.parent.close();
        self.tmp.cleanup();
    }

    fn pin(self: *Fixture, a: Allocator, name: []const u8, version: []const u8, file_name: []const u8, bytes: []const u8) !Pkg {
        try self.cache.writeFile(file_name, bytes);
        return .{
            .name = name,
            .version = version,
            .dir = self.cache,
            .file_name = file_name,
            .sha256 = try fx.sha256Hex(a, bytes),
            .size = bytes.len,
            .url = try std.fmt.allocPrint(a, "http://127.0.0.1:1/{s}", .{file_name}),
            .channel = "http://127.0.0.1:1/",
        };
    }

    /// Stores a package in the cache and returns the pin for it.
    fn add(self: *Fixture, a: Allocator, name: []const u8, version: []const u8, files: []const fx.Item) !Pkg {
        const file_name = try std.fmt.allocPrint(a, "{s}-{s}-h0_0.conda", .{ name, version });
        return self.pin(a, name, version, file_name, try fx.simple(a, name, version, files));
    }

    /// A package whose index.json says `name`, `version` and `build` as given
    /// (JSON text, so escapes are spelled out).
    fn addNamed(self: *Fixture, a: Allocator, name: []const u8, version: []const u8, build: []const u8, parsed_name: []const u8, parsed_version: []const u8) !Pkg {
        const idx = try fx.indexJson(a, name, version, build, "", "");
        const bytes = try fx.conda2(a, "x-1-h0_0", &.{.{ .name = "info/index.json", .data = idx }}, &.{.{ .name = "bin/x", .data = "x\n" }});
        return self.pin(a, parsed_name, parsed_version, "named.conda", bytes);
    }

    fn listIn(dir_: std.fs.Dir, a: Allocator) ![]const u8 {
        var names = std.ArrayList([]const u8).init(a);
        var dir = try dir_.openDir(".", .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |e| try names.append(try a.dupe(u8, e.name));
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        return std.mem.join(a, ",", names.items);
    }

    /// The names in `m/`, sorted.
    fn listing(self: *Fixture, a: Allocator) ![]const u8 {
        return listIn(self.parent, a);
    }

    /// The one name in `m/` that starts with `prefix`.
    fn nameWith(self: *Fixture, a: Allocator, prefix: []const u8) ![]const u8 {
        var found: ?[]const u8 = null;
        var dir = try self.tmp.dir.openDir("m", .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |e| {
            if (std.mem.startsWith(u8, e.name, prefix)) found = try a.dupe(u8, e.name);
        }
        return found.?;
    }
};

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

/// The renames and deletes of recover and commit, failing the ones asked for.
const FailOps = struct {
    /// Bit n set: the (n+1)th rename fails.
    fail_renames: u8 = 0,
    fail_deletes: bool = false,
    renames: u8 = 0,

    pub fn rename(self: *FailOps, parent: std.fs.Dir, old: []const u8, new: []const u8) !void {
        const n = self.renames;
        self.renames += 1;
        if ((self.fail_renames >> @intCast(n)) & 1 == 1) return error.AccessDenied;
        try parent.rename(old, new);
    }
    pub fn deleteTree(self: *FailOps, parent: std.fs.Dir, name: []const u8) !void {
        if (self.fail_deletes) return error.AccessDenied;
        try parent.deleteTree(name);
    }
};

test "installEnv: files, conda-meta records, history; nothing else is left beside the environment" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    const alpha = try f.add(a, "alpha", "1.0", &.{.{ .name = "bin/a", .data = "A\n", .mode = 0o755 }});
    const beta = try f.add(a, "beta", "2.5", &.{.{ .name = "lib/b.txt", .data = "B\n" }});

    // A leftover of an earlier interrupted install is removed.
    try f.parent.makePath(".env.tmp-dead/sub");
    var diag = Diag{};
    const done = try installEnv(a, f.parent, "env", "/opt/mopm/env", &.{ alpha, beta }, "stamp", &diag);
    try std.testing.expectEqual(@as(usize, 2), done.len);
    try std.testing.expectEqualStrings("env", try f.listing(a));

    var env = try f.parent.openDir("env", .{});
    defer env.close();
    try std.testing.expectEqualStrings("A\n", try env.readFileAlloc(a, "bin/a", 100));
    try std.testing.expectEqualStrings("B\n", try env.readFileAlloc(a, "lib/b.txt", 100));
    try std.testing.expect((try env.statFile("bin/a")).mode & 0o111 != 0);
    try env.access("conda-meta/history", .{});
    try std.testing.expectEqualStrings("stamp", readStamp(a, f.parent, "env").?);
    try std.testing.expectEqual(@as(?[]const u8, null), readStamp(a, f.parent, "absent"));

    const text = try env.readFileAlloc(a, "conda-meta/alpha-1.0-h0_0.json", 1 << 20);
    const rec = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    const o = rec.object;
    try std.testing.expectEqualStrings("alpha", o.get("name").?.string);
    try std.testing.expectEqualStrings("1.0", o.get("version").?.string);
    try std.testing.expectEqualStrings("h0_0", o.get("build").?.string);
    try std.testing.expectEqual(@as(i64, 3), o.get("build_number").?.integer);
    try std.testing.expectEqualStrings(alpha.sha256, o.get("sha256").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(alpha.size)), o.get("size").?.integer);
    try std.testing.expectEqualStrings("alpha-1.0-h0_0.conda", o.get("fn").?.string);
    try std.testing.expectEqualStrings("MIT", o.get("license").?.string);
    try std.testing.expectEqualStrings("bin/a", o.get("files").?.array.items[0].string);
    const p0 = o.get("paths_data").?.object.get("paths").?.array.items[0].object;
    try std.testing.expectEqualStrings("bin/a", p0.get("_path").?.string);
    try std.testing.expectEqualStrings(try fx.sha256Hex(a, "A\n"), p0.get("sha256_in_prefix").?.string);
}

test "stage: a file that is not the pinned bytes is refused before anything is unpacked" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    const alpha = try f.add(a, "alpha", "1.0", &.{.{ .name = "bin/a", .data = "A\n" }});
    const tampered = try f.add(a, "beta", "2.0", &.{.{ .name = "bin/b", .data = "B\n" }});
    // The same size, one byte different: only the sha256 can tell.
    const bytes = try f.cache.readFileAlloc(a, tampered.file_name, 1 << 20);
    bytes[bytes.len / 2] ^= 1;
    try f.cache.writeFile(tampered.file_name, bytes);

    var diag = Diag{};
    try std.testing.expectError(error.HashMismatch, env_mod.stage(a, f.parent, "env", "/opt/e", &.{ alpha, tampered }, "stamp", &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "not the pinned file") != null);
    try std.testing.expectEqualStrings("", try f.listing(a));

    // A pin of the wrong size is refused as well.
    var wrong = alpha;
    wrong.size += 1;
    try std.testing.expectError(error.HashMismatch, env_mod.stage(a, f.parent, "env", "/opt/e", &.{wrong}, "stamp", &diag));
    try std.testing.expectEqualStrings("", try f.listing(a));
}

test "installEnv: an install that fails midway leaves no environment, and keeps the old one" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    const alpha = try f.add(a, "alpha", "1.0", &.{.{ .name = "bin/a", .data = "A\n" }});
    const bad = try f.add(a, "bad", "1.0", &.{.{ .name = "bin/.bad-post-link.sh", .data = "#!/bin/sh\n" }});
    const first = try f.add(a, "first", "1.0", &.{.{ .name = "bin/first", .data = "old\n" }});

    var diag = Diag{};
    // No environment yet: the failure leaves the directory empty.
    try std.testing.expectError(error.LinkScript, installEnv(a, f.parent, "env", "/opt/e", &.{ alpha, bad }, "stamp", &diag));
    try std.testing.expectEqualStrings("", try f.listing(a));

    // An environment exists: the failure leaves it exactly as it was.
    _ = try installEnv(a, f.parent, "env", "/opt/e", &.{first}, "old-stamp", &diag);
    try std.testing.expectError(error.LinkScript, installEnv(a, f.parent, "env", "/opt/e", &.{ alpha, bad }, "new-stamp", &diag));
    try std.testing.expectEqualStrings("env", try f.listing(a));
    try std.testing.expectEqualStrings("old-stamp", readStamp(a, f.parent, "env").?);
    var env = try f.parent.openDir("env", .{});
    defer env.close();
    try std.testing.expectEqualStrings("old\n", try env.readFileAlloc(a, "bin/first", 100));
    try std.testing.expectError(error.FileNotFound, env.access("bin/a", .{}));
}

test "installEnv: a new install replaces the old environment whole" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    const alpha = try f.add(a, "alpha", "1.0", &.{.{ .name = "bin/a", .data = "A\n" }});
    const beta = try f.add(a, "beta", "2.0", &.{.{ .name = "bin/b", .data = "B\n" }});
    var diag = Diag{};
    _ = try installEnv(a, f.parent, "env", "/opt/e", &.{alpha}, "stamp", &diag);
    _ = try installEnv(a, f.parent, "env", "/opt/e", &.{beta}, "stamp", &diag);
    try std.testing.expectEqualStrings("env", try f.listing(a));
    var env = try f.parent.openDir("env", .{});
    defer env.close();
    try env.access("bin/b", .{});
    try std.testing.expectError(error.FileNotFound, env.access("bin/a", .{}));
    try std.testing.expectError(error.FileNotFound, env.access("conda-meta/alpha-1.0-h0_0.json", .{}));
}

test "stage: a package that is not the one asked for is refused" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    var alpha = try f.add(a, "alpha", "1.0", &.{.{ .name = "bin/a", .data = "A\n" }});
    alpha.name = "gamma";
    var diag = Diag{};
    try std.testing.expectError(error.PackageMismatch, env_mod.stage(a, f.parent, "env", "/opt/e", &.{alpha}, "stamp", &diag));
    try std.testing.expectEqualStrings("", try f.listing(a));
}

test "stage then discard leaves the directory as it was; stage then commit installs" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    const alpha = try f.add(a, "alpha", "1.0", &.{.{ .name = "bin/a", .data = "A\n" }});
    var diag = Diag{};

    const cand = try env_mod.stage(a, f.parent, "env", "/opt/e", &.{alpha}, "s", &diag);
    try std.testing.expectEqual(@as(usize, 1), cand.installed.len);
    try std.testing.expectEqualStrings(cand.tmp_name, try f.listing(a));
    // The target does not exist while the candidate is only staged.
    try std.testing.expectEqual(@as(?[]const u8, null), readStamp(a, f.parent, "env"));
    env_mod.discard(f.parent, cand);
    try std.testing.expectEqualStrings("", try f.listing(a));

    const again = try env_mod.stage(a, f.parent, "env", "/opt/e", &.{alpha}, "s", &diag);
    const done = try env_mod.commit(a, f.parent, "env", again, &diag);
    try std.testing.expectEqual(@as(usize, 0), done.warnings.len);
    try std.testing.expectEqualStrings("env", try f.listing(a));
    try std.testing.expectEqualStrings("s", readStamp(a, f.parent, "env").?);
}

fn installOld(a: Allocator, f: *Fixture) !void {
    const first = try f.add(a, "first", "1.0", &.{.{ .name = "bin/first", .data = "old\n" }});
    var diag = Diag{};
    _ = try installEnv(a, f.parent, "env", "/opt/e", &.{first}, "old-stamp", &diag);
}

fn expectOldEnv(a: Allocator, f: *Fixture) !void {
    try std.testing.expectEqualStrings("old-stamp", readStamp(a, f.parent, "env").?);
    var env = try f.parent.openDir("env", .{});
    defer env.close();
    try std.testing.expectEqualStrings("old\n", try env.readFileAlloc(a, "bin/first", 100));
}

test "commit: the first rename failing leaves the old environment; the second puts it back byte for byte" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    try installOld(a, &f);
    const alpha = try f.add(a, "alpha", "1.0", &.{.{ .name = "bin/a", .data = "A\n" }});
    var diag = Diag{};

    // The target cannot be moved aside.
    var cand = try env_mod.stage(a, f.parent, "env", "/opt/e", &.{alpha}, "new-stamp", &diag);
    var ops = FailOps{ .fail_renames = 0b1 };
    try std.testing.expectError(error.AccessDenied, env_mod.commitWith(&ops, a, f.parent, "env", cand, &diag));
    try std.testing.expectEqualStrings("cannot move env aside: AccessDenied", diag.message);
    try expectOldEnv(a, &f);
    env_mod.discard(f.parent, cand);
    try std.testing.expectEqualStrings("env", try f.listing(a));

    // The candidate cannot take its place: the old one is renamed back.
    cand = try env_mod.stage(a, f.parent, "env", "/opt/e", &.{alpha}, "new-stamp", &diag);
    ops = FailOps{ .fail_renames = 0b10 };
    try std.testing.expectError(error.AccessDenied, env_mod.commitWith(&ops, a, f.parent, "env", cand, &diag));
    try std.testing.expectEqualStrings("cannot move the new environment to env: AccessDenied", diag.message);
    try expectOldEnv(a, &f);
    env_mod.discard(f.parent, cand);
    try std.testing.expectEqualStrings("env", try f.listing(a));
}

test "commit: a rollback that fails keeps the backup, names it, and the next recover puts it back" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    try installOld(a, &f);
    const alpha = try f.add(a, "alpha", "1.0", &.{.{ .name = "bin/a", .data = "A\n" }});
    var diag = Diag{};

    const cand = try env_mod.stage(a, f.parent, "env", "/opt/e", &.{alpha}, "new-stamp", &diag);
    var ops = FailOps{ .fail_renames = 0b110 };
    try std.testing.expectError(error.BackupKept, env_mod.commitWith(&ops, a, f.parent, "env", cand, &diag));
    const backup = try f.nameWith(a, ".env.old-");
    try std.testing.expectEqualStrings(backup, diag.message);
    env_mod.discard(f.parent, cand);
    try std.testing.expectEqualStrings(backup, try f.listing(a));

    const got = try env_mod.recover(a, f.parent, "env");
    try std.testing.expectEqualStrings(backup, got.restored.?);
    try std.testing.expectEqual(@as(usize, 0), got.warnings.len);
    try expectOldEnv(a, &f);
    try std.testing.expectEqualStrings("env", try f.listing(a));
}

test "commit: without an environment a failing rename is reported; a failing delete of the backup is a warning" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    const alpha = try f.add(a, "alpha", "1.0", &.{.{ .name = "bin/a", .data = "A\n" }});
    var diag = Diag{};

    var cand = try env_mod.stage(a, f.parent, "env", "/opt/e", &.{alpha}, "s1", &diag);
    var ops = FailOps{ .fail_renames = 0b1 };
    try std.testing.expectError(error.AccessDenied, env_mod.commitWith(&ops, a, f.parent, "env", cand, &diag));
    try std.testing.expectEqualStrings("cannot move the new environment to env: AccessDenied", diag.message);
    env_mod.discard(f.parent, cand);
    try std.testing.expectEqualStrings("", try f.listing(a));

    _ = try installEnv(a, f.parent, "env", "/opt/e", &.{alpha}, "s1", &diag);
    cand = try env_mod.stage(a, f.parent, "env", "/opt/e", &.{alpha}, "s2", &diag);
    ops = FailOps{ .fail_deletes = true };
    const done = try env_mod.commitWith(&ops, a, f.parent, "env", cand, &diag);
    try std.testing.expectEqual(@as(usize, 1), done.warnings.len);
    const backup = try f.nameWith(a, ".env.old-");
    const want = try std.fmt.allocPrint(a, "cannot remove {s}: AccessDenied", .{backup});
    try std.testing.expectEqualStrings(want, done.warnings[0]);
    try std.testing.expectEqualStrings("s2", readStamp(a, f.parent, "env").?);

    // The next recover removes the backup now that the environment is there.
    const got = try env_mod.recover(a, f.parent, "env");
    try std.testing.expectEqual(@as(?[]const u8, null), got.restored);
    try std.testing.expectEqualStrings("env", try f.listing(a));
}

test "recover: a backup alone is put back; a temporary directory is removed; a backup goes only when the environment exists" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();

    // Nothing to do.
    var got = try env_mod.recover(a, f.parent, "env");
    try std.testing.expectEqual(@as(?[]const u8, null), got.restored);
    try std.testing.expectEqual(@as(usize, 0), got.warnings.len);

    // Backups with no environment: the newest comes back, the other goes.
    try f.parent.makePath(".env.old-aa/bin");
    try f.parent.writeFile(".env.old-aa/bin/v", "aa");
    try f.parent.makePath(".env.old-bb/bin");
    try f.parent.writeFile(".env.old-bb/bin/v", "bb");
    try f.parent.makePath(".env.tmp-cc/bin");
    try f.parent.makePath(".other.old-dd");
    got = try env_mod.recover(a, f.parent, "env");
    try std.testing.expectEqualStrings(".env.old-bb", got.restored.?);
    try std.testing.expectEqual(@as(usize, 0), got.warnings.len);
    try std.testing.expectEqualStrings(".other.old-dd,env", try f.listing(a));
    try std.testing.expectEqualStrings("bb", try f.parent.readFileAlloc(a, "env/bin/v", 10));

    // With the environment present a backup is only removed.
    try f.parent.makePath(".env.old-ee");
    got = try env_mod.recover(a, f.parent, "env");
    try std.testing.expectEqual(@as(?[]const u8, null), got.restored);
    try std.testing.expectEqualStrings(".other.old-dd,env", try f.listing(a));
}

test "recover: what cannot be deleted or renamed is a warning, not an error" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();

    try f.parent.makePath(".env.tmp-aa");
    try f.parent.makePath("env");
    try f.parent.makePath(".env.old-bb");
    var ops = FailOps{ .fail_deletes = true };
    var got = try env_mod.recoverWith(&ops, a, f.parent, "env");
    try std.testing.expectEqual(@as(usize, 2), got.warnings.len);
    try std.testing.expectEqualStrings("cannot remove .env.tmp-aa: AccessDenied", got.warnings[0]);
    try std.testing.expectEqualStrings("cannot remove .env.old-bb: AccessDenied", got.warnings[1]);
    try std.testing.expectEqualStrings(".env.old-bb,.env.tmp-aa,env", try f.listing(a));

    // A backup that cannot be renamed back stays, and is reported.
    try f.parent.deleteTree("env");
    ops = FailOps{ .fail_renames = 0b1, .fail_deletes = true };
    got = try env_mod.recoverWith(&ops, a, f.parent, "env");
    try std.testing.expectEqual(@as(?[]const u8, null), got.restored);
    try std.testing.expectEqualStrings("cannot put .env.old-bb back as env: AccessDenied", got.warnings[0]);
    try std.testing.expectEqualStrings(".env.old-bb,.env.tmp-aa", try f.listing(a));
}

test "stage: a path two packages install is allowed only with the same bytes in both" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    var diag = Diag{};
    const x_a = try f.add(a, "alpha", "1.0", &.{.{ .name = "lib/x", .data = "same\n" }});
    const x_same = try f.add(a, "beta", "2.0", &.{.{ .name = "lib/x", .data = "same\n" }});
    const x_other = try f.add(a, "gamma", "3.0", &.{.{ .name = "lib/x", .data = "other\n" }});
    const x_link = try f.add(a, "delta", "4.0", &.{.{ .name = "lib/x", .kind = .symlink, .link = "y", .mode = 0o777 }});

    const ok = try env_mod.stage(a, f.parent, "env", "/opt/e", &.{ x_a, x_same }, "s", &diag);
    env_mod.discard(f.parent, ok);
    try std.testing.expectEqualStrings("", try f.listing(a));

    try std.testing.expectError(error.PathConflict, env_mod.stage(a, f.parent, "env", "/opt/e", &.{ x_a, x_other }, "s", &diag));
    try std.testing.expectEqualStrings("lib/x is installed by both alpha 1.0 and gamma 3.0 with different contents; refused", diag.message);
    try std.testing.expectEqualStrings("", try f.listing(a));

    try std.testing.expectError(error.PathConflict, env_mod.stage(a, f.parent, "env", "/opt/e", &.{ x_a, x_link }, "s", &diag));
    try std.testing.expectEqualStrings("lib/x is installed by both alpha 1.0 and delta 4.0 with different contents; refused", diag.message);

    try std.testing.expectError(error.PathConflict, env_mod.stage(a, f.parent, "env", "/opt/e", &.{ x_link, x_a }, "s", &diag));
    try std.testing.expectEqualStrings("lib/x is installed by both delta 4.0 and alpha 1.0 with different contents; refused", diag.message);
    try std.testing.expectEqualStrings("", try f.listing(a));
}

test "stage: the packages' own info/ files may differ; any other path may not" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    var diag = Diag{};
    const one = try f.add(a, "alpha", "1.0", &.{ .{ .name = "info/licenses/LICENSE", .data = "MIT\n" }, .{ .name = "bin/a", .data = "A\n" } });
    const two = try f.add(a, "beta", "2.0", &.{ .{ .name = "info/licenses/LICENSE", .data = "BSD\n" }, .{ .name = "bin/b", .data = "B\n" } });
    const cand = try env_mod.stage(a, f.parent, "env", "/opt/e", &.{ one, two }, "s", &diag);
    env_mod.discard(f.parent, cand);
    try std.testing.expectEqualStrings("", try f.listing(a));

    const clash = try f.add(a, "gamma", "3.0", &.{.{ .name = "bin/a", .data = "other\n" }});
    try std.testing.expectError(error.PathConflict, env_mod.stage(a, f.parent, "env", "/opt/e", &.{ one, clash }, "s", &diag));
}

test "stage: an archive whose name, version or build is not a plain component is refused, and nothing is written outside the candidate" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    var diag = Diag{};

    const Case = struct { name: []const u8, version: []const u8, build: []const u8, parsed_name: []const u8, parsed_version: []const u8, message: []const u8 };
    const cases = [_]Case{
        .{ .name = "../../x", .version = "1.0", .build = "h0_0", .parsed_name = "../../x", .parsed_version = "1.0", .message = "named.conda: its name '../../x' is not a safe file name part; refused" },
        .{ .name = "evil", .version = "1.0", .build = "a/b", .parsed_name = "evil", .parsed_version = "1.0", .message = "named.conda: its build 'a/b' is not a safe file name part; refused" },
        .{ .name = "evil", .version = "..", .build = "h0_0", .parsed_name = "evil", .parsed_version = "..", .message = "named.conda: its version '..' is not a safe file name part; refused" },
        .{ .name = "", .version = "1.0", .build = "h0_0", .parsed_name = "", .parsed_version = "1.0", .message = "named.conda: its name '' is not a safe file name part; refused" },
        .{ .name = "a\\u0000b", .version = "1.0", .build = "h0_0", .parsed_name = "a\x00b", .parsed_version = "1.0", .message = "named.conda: its name 'a\\x00b' is not a safe file name part; refused" },
    };
    for (cases) |c| {
        const pkg = try f.addNamed(a, c.name, c.version, c.build, c.parsed_name, c.parsed_version);
        try std.testing.expectError(error.UnsafeName, env_mod.stage(a, f.parent, "env", "/opt/e", &.{pkg}, "s", &diag));
        try std.testing.expectEqualStrings(c.message, diag.message);
        try std.testing.expectEqualStrings("", try f.listing(a));
        try std.testing.expectEqualStrings("m,pkgs", try Fixture.listIn(f.tmp.dir, a));
    }

    // The file name of the pin itself is checked as well.
    var pkg = try f.add(a, "alpha", "1.0", &.{.{ .name = "bin/a", .data = "A\n" }});
    pkg.file_name = "../pkgs/alpha-1.0-h0_0.conda";
    try std.testing.expectError(error.UnsafeName, env_mod.stage(a, f.parent, "env", "/opt/e", &.{pkg}, "s", &diag));
    try std.testing.expectEqualStrings("'../pkgs/alpha-1.0-h0_0.conda' is not a safe file name; refused", diag.message);
    try std.testing.expectEqualStrings("", try f.listing(a));
}
