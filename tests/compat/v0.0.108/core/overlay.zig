//! A staged set read as a read-only local channel: what `--overlay <dir>` of
//! `mopm add`, `mopm lock` and `mopm sync` is.
//!
//! The directory is a staged set (spec/staged-set.md): a `plan.json` that lists
//! members in dependency order, and the `.conda` files it names under
//! `<subdir>/<filename>`. `load` reads it and checks every file against the plan
//! (size, sha256) and every member against its own package metadata, once; after
//! that the set can answer what the registry answers for a package, from the
//! files alone:
//!
//! - `indexText` is the sparse-index file of a staged package (the records the
//!   registry will serve once the version is published), with the dependencies
//!   and native libraries the package's own `lib/mojo/<name>.mopm.json` declares
//!   and a build for exactly the compiler its file name names;
//! - `repodata` is the `<subdir>/repodata.json` entries of its files, merged into
//!   the registry's when the registry is asked at all;
//! - `fileBytes` and `bytesFor` are the bytes of a file, for the natives a lock
//!   hashes and for an install.
//!
//! The set never reaches a lock or a manifest: a lock made with it names the
//! registry's channel and file URLs and the files' sha256, so the same lock holds
//! once the versions are published. A package the set holds is resolved from the
//! set alone (the registry is not asked about it); a package it lacks falls
//! through to the registry. `Index` and `Channel` are the two sources, generic
//! over the registry's. Nothing here writes below the directory.
//!
//! Members with the action `skip` are already on the registry with these bytes
//! and are left to it. A set that holds a `refuse` member is refused whole.

const std = @import("std");
const Allocator = std.mem.Allocator;
const resolve = @import("resolve.zig");
const lock = @import("lock.zig");
const metadata = @import("metadata.zig");
const manifest = @import("manifest.zig");
const semver = @import("semver.zig");
const conda_unpack = @import("conda_unpack.zig");

/// The most a package file may be (the registry's limit).
pub const max_file_bytes: usize = 100_000_000;

pub const subdirs = [_][]const u8{ "noarch", "linux-64", "linux-aarch64", "osx-arm64" };

/// One staged version: its record in the index as the registry will hold it.
pub const Member = struct {
    name: []const u8,
    version: []const u8,
    /// `mojo1.0.0_0`: the same for every file.
    build: []const u8,
    /// `==1.0.0`.
    requires_mojo: []const u8,
    deps: []const resolve.Dep,
    native: []const resolve.Native,
    files: []const resolve.File,
};

pub const Error = error{Refused} || Allocator.Error;

fn refuse(arena: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    why.* = try std.fmt.allocPrint(arena, fmt, args);
    return error.Refused;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

fn getStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn sameDeps(a: []const resolve.Dep, b: []const resolve.Dep) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        const xr = x.range orelse "";
        const yr = y.range orelse "";
        if (!std.mem.eql(u8, xr, yr)) return false;
    }
    return true;
}

fn sameNative(a: []const resolve.Native, b: []const resolve.Native) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.id, y.id) or !std.mem.eql(u8, x.soname, y.soname)) return false;
    }
    return true;
}

/// A file name that is a plain name: no separator, nothing hidden.
fn plainName(s: []const u8) bool {
    return s.len > 0 and s[0] != '.' and std.mem.indexOfAny(u8, s, "/\\") == null;
}

pub const Overlay = struct {
    /// The directory, as given.
    dir: []const u8,
    members: []const Member,

    /// The staged version of `name`, if the set holds the package.
    pub fn member(self: Overlay, name: []const u8) ?*const Member {
        for (self.members) |*m| {
            if (std.mem.eql(u8, m.name, name)) return m;
        }
        return null;
    }

    /// The staged file `<subdir>/<filename>`, if the set holds it.
    pub fn file(self: Overlay, subdir: []const u8, filename: []const u8) ?resolve.File {
        for (self.members) |m| {
            for (m.files) |f| {
                if (std.mem.eql(u8, f.subdir, subdir) and std.mem.eql(u8, f.filename, filename)) return f;
            }
        }
        return null;
    }

    /// The bytes of the staged file `<subdir>/<filename>`, read again and checked against the plan; null when the
    /// set holds no such file.
    pub fn fileBytes(self: Overlay, arena: Allocator, subdir: []const u8, filename: []const u8, why: *[]const u8) Error!?[]const u8 {
        const f = self.file(subdir, filename) orelse return null;
        const path = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ self.dir, f.subdir, f.filename });
        const bytes = std.fs.cwd().readFileAlloc(arena, path, max_file_bytes + 1) catch |e| {
            return refuse(arena, why, "cannot read {s}: {s}", .{ path, @errorName(e) });
        };
        const got = sha256Hex(bytes);
        if (bytes.len != f.size or !std.mem.eql(u8, &got, f.sha256)) {
            return refuse(arena, why, "{s} is not the file plan.json describes: it changed after it was read", .{path});
        }
        return bytes;
    }

    /// The bytes of the file a lock entry pins, when the set holds exactly that file (same package, version, build,
    /// subdir and sha256); null otherwise, and the caller goes to the registry.
    pub fn bytesFor(self: Overlay, arena: Allocator, p: lock.Package, why: *[]const u8) Error!?[]const u8 {
        if (p.source != .registry) return null;
        const m = self.member(p.name) orelse return null;
        if (!std.mem.eql(u8, m.version, p.version) or !std.mem.eql(u8, m.build, p.build)) return null;
        for (m.files) |f| {
            if (std.mem.eql(u8, f.subdir, p.subdir) and std.mem.eql(u8, f.sha256, p.sha256) and f.size == p.size) {
                return self.fileBytes(arena, f.subdir, f.filename, why);
            }
        }
        return null;
    }

    /// `<subdir>/repodata.json` for the staged files of `subdir`. With `inner` (the registry's), its `packages.conda`
    /// with the staged entries added; a registry entry for a staged file name that holds other bytes is refused.
    /// Text of `inner` that is not a repodata.json is returned as it is, for the reader of it to refuse.
    pub fn repodata(self: Overlay, arena: Allocator, subdir: []const u8, inner: ?[]const u8, why: *[]const u8) Error![]const u8 {
        var doc: std.json.Value = undefined;
        if (inner) |text| {
            doc = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return text,
            };
            if (doc != .object) return text;
            const found = doc.object.getPtr("packages.conda") orelse return text;
            if (found.* != .object) return text;
        } else {
            var top = std.json.ObjectMap.init(arena);
            try top.put("packages.conda", .{ .object = std.json.ObjectMap.init(arena) });
            doc = .{ .object = top };
        }
        const packages = doc.object.getPtr("packages.conda").?;
        for (self.members) |m| {
            for (m.files) |f| {
                if (!std.mem.eql(u8, f.subdir, subdir)) continue;
                if (packages.object.get(f.filename)) |held| {
                    const same = held == .object and
                        if (getStr(held.object, "sha256")) |s| std.mem.eql(u8, s, f.sha256) else false;
                    const size_ok = held == .object and
                        if (held.object.get("size")) |s| (s == .integer and s.integer == @as(i64, @intCast(f.size))) else false;
                    if (!same or !size_ok) {
                        return refuse(arena, why, "{s}/{s} is staged in {s} with sha256 {s}, and the registry's repodata.json lists that file name with other bytes; a published version cannot be replaced, so the staged one needs a new version", .{ f.subdir, f.filename, self.dir, f.sha256 });
                    }
                }
                var entry = std.json.ObjectMap.init(arena);
                try entry.put("build", .{ .string = m.build });
                try entry.put("name", .{ .string = try std.fmt.allocPrint(arena, "mojo-{s}", .{m.name}) });
                try entry.put("sha256", .{ .string = f.sha256 });
                try entry.put("size", .{ .integer = @intCast(f.size) });
                try entry.put("subdir", .{ .string = f.subdir });
                try entry.put("version", .{ .string = m.version });
                try packages.object.put(f.filename, .{ .object = entry });
            }
        }
        return std.json.stringifyAlloc(arena, doc, .{});
    }
};

const IndexDep = struct { name: []const u8, range: ?[]const u8 = null };
const IndexLine = struct {
    v: u8 = 1,
    name: []const u8,
    version: []const u8,
    build: []const u8,
    state: []const u8 = "published",
    requires_mojo: []const u8,
    deps: []const IndexDep,
    native: []const resolve.Native,
    files: []const resolve.File,
};

/// The index file of a staged package: one record, as the registry will serve it.
pub fn indexText(arena: Allocator, m: *const Member) Allocator.Error![]const u8 {
    const deps = try arena.alloc(IndexDep, m.deps.len);
    for (m.deps, deps) |d, *out| out.* = .{ .name = d.name, .range = d.range };
    var out = std.ArrayList(u8).init(arena);
    try std.json.stringify(IndexLine{
        .name = m.name,
        .version = m.version,
        .build = m.build,
        .requires_mojo = m.requires_mojo,
        .deps = deps,
        .native = m.native,
        .files = m.files,
    }, .{ .emit_null_optional_fields = false }, out.writer());
    try out.append('\n');
    return out.items;
}

fn sameVersion(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const x = resolve.semverOf(a) orelse return false;
    const y = resolve.semverOf(b) orelse return false;
    return semver.compare(x, y) == .eq;
}

/// Why the registry's `records` of the package already hold the staged version with other bytes (a different
/// file, or another set of files), or null. The registry never replaces a published version, so a staged one that
/// differs cannot be what the registry gives once it is published.
pub fn registryDiffers(arena: Allocator, dir: []const u8, m: *const Member, records: []const resolve.Record) Allocator.Error!?[]const u8 {
    for (records) |r| {
        if (!sameVersion(r.version, m.version)) continue;
        for (m.files) |f| {
            var found = false;
            for (r.files) |g| {
                if (!std.mem.eql(u8, g.subdir, f.subdir) or !std.mem.eql(u8, g.filename, f.filename)) continue;
                found = true;
                if (!std.mem.eql(u8, g.sha256, f.sha256) or g.size != f.size) {
                    return try std.fmt.allocPrint(arena, "{s} {s} is staged in {s} with {s}/{s} at sha256 {s}, and the registry already holds that version with sha256 {s}; a published version cannot be replaced, so the staged one needs a new version", .{ m.name, m.version, dir, f.subdir, f.filename, f.sha256, g.sha256 });
                }
            }
            if (!found) {
                return try std.fmt.allocPrint(arena, "{s} {s} is staged in {s} with {s}/{s}, and the registry already holds that version without that file; a published version cannot be replaced, so the staged one needs a new version", .{ m.name, m.version, dir, f.subdir, f.filename });
            }
        }
        if (r.files.len != m.files.len) {
            return try std.fmt.allocPrint(arena, "{s} {s} is staged in {s} with {d} files, and the registry already holds that version with {d}; a published version cannot be replaced, so the staged one needs a new version", .{ m.name, m.version, dir, m.files.len, r.files.len });
        }
    }
    return null;
}

/// The subdirs whose repodata.json the registry has to be asked for: those of the files of every picked version the
/// set does not hold.
pub fn registrySubdirs(arena: Allocator, ov: Overlay, res: resolve.Resolution) Allocator.Error![]const []const u8 {
    var out = std.ArrayList([]const u8).init(arena);
    for (res.packages) |p| {
        if (ov.member(p.record.name) != null) continue;
        for (p.record.files) |f| {
            if (!contains(out.items, f.subdir)) try out.append(f.subdir);
        }
    }
    return out.items;
}

/// The resolver's source of index files: a staged package from the set, anything else from `Inner` (the registry's),
/// and `asked` set when `Inner` was asked.
pub fn Index(comptime Inner: type) type {
    return struct {
        overlay: *const Overlay,
        inner: Inner,
        asked: *bool,

        pub fn fetch(self: @This(), arena: Allocator, name: []const u8, diag: *resolve.Diagnostic) resolve.Error!?[]const u8 {
            if (self.overlay.member(name)) |m| return try indexText(arena, m);
            self.asked.* = true;
            return self.inner.fetch(arena, name, diag);
        }
    };
}

/// The lock builder's channel: the staged files' entries (merged into `Inner`'s repodata.json for the subdirs listed
/// in `registry_subdirs`, the only ones `Inner` is asked about) and their bytes.
pub fn Channel(comptime Inner: type) type {
    return struct {
        overlay: *const Overlay,
        inner: Inner,
        registry_subdirs: []const []const u8,

        pub fn fetch(self: @This(), arena: Allocator, subdir: []const u8, diag: *resolve.Diagnostic) resolve.Error![]const u8 {
            var why: []const u8 = "";
            const held: ?[]const u8 = if (contains(self.registry_subdirs, subdir)) try self.inner.fetch(arena, subdir, diag) else null;
            return self.overlay.repodata(arena, subdir, held, &why) catch |e| switch (e) {
                error.Refused => return resolve.fail(arena, diag, .bad_channel, "{s}", .{why}),
                error.OutOfMemory => return error.OutOfMemory,
            };
        }

        pub fn fetchConda(self: @This(), arena: Allocator, subdir: []const u8, filename: []const u8, diag: *resolve.Diagnostic) resolve.Error![]const u8 {
            var why: []const u8 = "";
            const bytes = self.overlay.fileBytes(arena, subdir, filename, &why) catch |e| switch (e) {
                error.Refused => return resolve.fail(arena, diag, .bad_channel, "{s}", .{why}),
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (bytes) |b| return b;
            return self.inner.fetchConda(arena, subdir, filename, diag);
        }
    };
}

/// Reads the staged set in `dir_path`. On `error.Refused`, `why` says what is wrong with it.
pub fn load(arena: Allocator, dir_path: []const u8, why: *[]const u8) Error!Overlay {
    var dir = std.fs.cwd().openDir(dir_path, .{}) catch |e| {
        return refuse(arena, why, "cannot open the staged set {s}: {s}", .{ dir_path, @errorName(e) });
    };
    defer dir.close();
    const plan_text = dir.readFileAlloc(arena, "plan.json", 16 << 20) catch |e| {
        return refuse(arena, why, "{s}/plan.json: {s}; a staged set is a directory with a plan.json (spec/staged-set.md)", .{ dir_path, @errorName(e) });
    };
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, plan_text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(arena, why, "{s}/plan.json is not JSON", .{dir_path}),
    };
    if (doc != .object) return refuse(arena, why, "{s}/plan.json is not a JSON object", .{dir_path});
    const version = doc.object.get("version") orelse return refuse(arena, why, "{s}/plan.json has no version", .{dir_path});
    if (version != .integer or version.integer != 1) {
        return refuse(arena, why, "{s}/plan.json: this mopm reads plan version 1", .{dir_path});
    }
    const list = doc.object.get("members") orelse return refuse(arena, why, "{s}/plan.json has no members", .{dir_path});
    if (list != .array) return refuse(arena, why, "{s}/plan.json: members is not an array", .{dir_path});

    // The zstd window of the unpacker, and a scratch arena for each file, so that a set of large files is never held
    // whole.
    const window = try std.heap.page_allocator.alloc(u8, conda_unpack.window_size);
    defer std.heap.page_allocator.free(window);

    var members = std.ArrayList(Member).init(arena);
    for (list.array.items) |mv| {
        if (mv != .object) return refuse(arena, why, "{s}/plan.json: a member is not an object", .{dir_path});
        const mo = mv.object;
        const name = getStr(mo, "name") orelse return refuse(arena, why, "{s}/plan.json: a member has no name", .{dir_path});
        const ver = getStr(mo, "version") orelse return refuse(arena, why, "{s}/plan.json: {s} has no version", .{ dir_path, name });
        const action = getStr(mo, "action") orelse return refuse(arena, why, "{s}/plan.json: {s} {s} has no action", .{ dir_path, name, ver });
        if (std.mem.eql(u8, action, "skip")) continue;
        if (std.mem.eql(u8, action, "refuse")) {
            return refuse(arena, why, "the staged set {s} cannot be published: it refuses {s} {s}: {s}", .{ dir_path, name, ver, getStr(mo, "reason") orelse "no reason given" });
        }
        if (!std.mem.eql(u8, action, "upload")) return refuse(arena, why, "{s}/plan.json: {s} {s} has the action {s}; it is upload, skip or refuse", .{ dir_path, name, ver, action });
        if (try manifest.nameProblem(arena, "package name", name)) |problem| {
            return refuse(arena, why, "{s}/plan.json: {s}", .{ dir_path, problem });
        }
        if (resolve.semverOf(ver) == null or std.mem.count(u8, ver, ".") != 2) {
            return refuse(arena, why, "{s}/plan.json: {s} {s}: a version is MAJOR.MINOR.PATCH", .{ dir_path, name, ver });
        }
        for (members.items) |m| {
            if (std.mem.eql(u8, m.name, name)) return refuse(arena, why, "{s}/plan.json lists {s} twice", .{ dir_path, name });
        }
        const files_v = mo.get("files") orelse return refuse(arena, why, "{s}/plan.json: {s} {s} has no files", .{ dir_path, name, ver });
        if (files_v != .array or files_v.array.items.len == 0 or files_v.array.items.len > 20) {
            return refuse(arena, why, "{s}/plan.json: {s} {s}: files is one to 20 entries", .{ dir_path, name, ver });
        }

        var m = Member{ .name = name, .version = ver, .build = "", .requires_mojo = "", .deps = &.{}, .native = &.{}, .files = &.{} };
        var files = std.ArrayList(resolve.File).init(arena);
        for (files_v.array.items, 0..) |fv, i| {
            if (fv != .object) return refuse(arena, why, "{s}/plan.json: a file of {s} {s} is not an object", .{ dir_path, name, ver });
            const subdir = getStr(fv.object, "subdir") orelse return refuse(arena, why, "{s}/plan.json: a file of {s} {s} has no subdir", .{ dir_path, name, ver });
            const filename = getStr(fv.object, "filename") orelse return refuse(arena, why, "{s}/plan.json: a file of {s} {s} has no filename", .{ dir_path, name, ver });
            const sha = getStr(fv.object, "sha256") orelse return refuse(arena, why, "{s}/plan.json: {s} has no sha256", .{ dir_path, filename });
            const size_v = fv.object.get("size") orelse return refuse(arena, why, "{s}/plan.json: {s} has no size", .{ dir_path, filename });
            if (!contains(&subdirs, subdir)) return refuse(arena, why, "{s}/plan.json: {s}: {s} is not a subdir", .{ dir_path, filename, subdir });
            if (!plainName(filename)) return refuse(arena, why, "{s}/plan.json: {s} is not a plain file name", .{ dir_path, filename });
            if (!isHex64(sha)) return refuse(arena, why, "{s}/plan.json: the sha256 of {s} is not 64 lowercase hex digits", .{ dir_path, filename });
            if (size_v != .integer or size_v.integer < 1 or size_v.integer > @as(i64, @intCast(max_file_bytes))) {
                return refuse(arena, why, "{s}/plan.json: the size of {s} is not 1 to {d}", .{ dir_path, filename, max_file_bytes });
            }
            for (files.items) |g| {
                if (std.mem.eql(u8, g.subdir, subdir) and std.mem.eql(u8, g.filename, filename)) {
                    return refuse(arena, why, "{s}/plan.json lists {s}/{s} twice", .{ dir_path, subdir, filename });
                }
            }

            // The name says the build: mojo-<name>-<version>-<build>.conda, and the build mojo<compiler>_<n>.
            const head = try std.fmt.allocPrint(arena, "mojo-{s}-{s}-", .{ name, ver });
            if (!std.mem.startsWith(u8, filename, head) or !std.mem.endsWith(u8, filename, ".conda")) {
                return refuse(arena, why, "{s}/plan.json: {s} is not a file of {s} {s} (mojo-{s}-{s}-<build>.conda)", .{ dir_path, filename, name, ver, name, ver });
            }
            const build = filename[head.len .. filename.len - ".conda".len];
            const compiler = compilerOf(build) orelse {
                return refuse(arena, why, "{s}/plan.json: the build {s} of {s} is not mojo<compiler>_<n>", .{ dir_path, build, filename });
            };
            if (i == 0) {
                m.build = build;
                m.requires_mojo = try std.fmt.allocPrint(arena, "=={s}", .{compiler});
            } else if (!std.mem.eql(u8, m.build, build)) {
                return refuse(arena, why, "{s}/plan.json: the files of {s} {s} are of different builds ({s}, {s})", .{ dir_path, name, ver, m.build, build });
            }

            // The file: the plan's size and sha256, then its own metadata.
            const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ subdir, filename });
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const sa = scratch.allocator();
            const bytes = dir.readFileAlloc(sa, rel, max_file_bytes + 1) catch |e| {
                return refuse(arena, why, "{s}/{s}: {s}", .{ dir_path, rel, @errorName(e) });
            };
            const got = sha256Hex(bytes);
            if (@as(i64, @intCast(bytes.len)) != size_v.integer or !std.mem.eql(u8, &got, sha)) {
                return refuse(arena, why, "{s}/{s} is not the file plan.json describes: plan.json says {d} bytes, sha256 {s}; the file has {d} bytes, sha256 {s}", .{ dir_path, rel, size_v.integer, sha, bytes.len, &got });
            }
            const meta_path = try std.fmt.allocPrint(sa, "lib/mojo/{s}.mopm.json", .{name});
            var unpack_diag = conda_unpack.Diag{};
            const held = conda_unpack.readFiles(sa, bytes, window, &.{meta_path}, &unpack_diag) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return refuse(arena, why, "{s}/{s} is not a readable .conda: {s}", .{ dir_path, rel, if (unpack_diag.message.len > 0) unpack_diag.message else @errorName(e) }),
            };
            const meta_text = held[0] orelse return refuse(arena, why, "{s}/{s} has no {s}", .{ dir_path, rel, meta_path });
            const meta = metadata.parse(sa, meta_text) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return refuse(arena, why, "{s}/{s}: {s} is not valid package metadata ({s})", .{ dir_path, rel, meta_path, @errorName(e) }),
            };
            if (!std.mem.eql(u8, meta.name, name) or (meta.version.len > 0 and !std.mem.eql(u8, meta.version, ver))) {
                return refuse(arena, why, "{s}/{s}: {s} describes {s} {s}, not {s} {s}", .{ dir_path, rel, meta_path, meta.name, meta.version, name, ver });
            }
            const deps = try arena.alloc(resolve.Dep, meta.deps.len);
            for (meta.deps, deps) |d, *out| {
                out.* = .{ .name = try arena.dupe(u8, d.name), .range = if (d.range.len > 0) try arena.dupe(u8, d.range) else null };
            }
            const natives = try arena.alloc(resolve.Native, meta.native.len);
            for (meta.native, natives) |n, *out| {
                out.* = .{ .id = try arena.dupe(u8, n.id), .soname = try arena.dupe(u8, n.soname) };
            }
            if (i == 0) {
                m.deps = deps;
                m.native = natives;
            } else if (!sameDeps(m.deps, deps) or !sameNative(m.native, natives)) {
                return refuse(arena, why, "{s}/{s} disagrees with the first file of {s} {s} on its dependencies or native libraries", .{ dir_path, rel, name, ver });
            }
            try files.append(.{ .subdir = subdir, .filename = filename, .sha256 = sha, .size = @intCast(size_v.integer) });
        }
        m.files = files.items;
        try members.append(m);
    }
    return .{ .dir = dir_path, .members = members.items };
}

/// `1.0.0` of `mojo1.0.0_0`; null for any other spelling of a build.
fn compilerOf(build: []const u8) ?[]const u8 {
    const prefix = "mojo";
    if (!std.mem.startsWith(u8, build, prefix)) return null;
    const us = std.mem.lastIndexOfScalar(u8, build, '_') orelse return null;
    if (us <= prefix.len or us + 1 >= build.len) return null;
    for (build[us + 1 ..]) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return build[prefix.len..us];
}

// ---------------------------------------------------------------- tests

const conda_fixture = @import("conda_fixture.zig");

const test_sha = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";

/// A staged package file: a `.conda` whose metadata is `meta`.
fn testConda(a: Allocator, name: []const u8, version: []const u8, meta: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(a, "lib/mojo/{s}.mopm.json", .{name});
    return conda_fixture.simple(a, name, version, &.{.{ .name = path, .data = meta }});
}

const TestFile = struct { subdir: []const u8 = "linux-64", build: []const u8 = "mojo1.0.0_0", bytes: []const u8 };
const TestMember = struct {
    name: []const u8,
    version: []const u8,
    action: []const u8 = "upload",
    files: []const TestFile = &.{},
};

/// Writes a staged set into a fresh temporary directory and returns its path; plan.json is the one `members` give.
fn testSet(a: Allocator, tmp: *std.testing.TmpDir, members: []const TestMember) ![]const u8 {
    var plan = std.ArrayList(u8).init(a);
    try plan.appendSlice("{\"version\":1,\"members\":[");
    for (members, 0..) |m, i| {
        if (i > 0) try plan.append(',');
        try plan.writer().print("{{\"name\":\"{s}\",\"version\":\"{s}\",\"action\":\"{s}\"", .{ m.name, m.version, m.action });
        if (std.mem.eql(u8, m.action, "skip")) try plan.appendSlice(",\"reason\":\"already published with these bytes\"");
        if (std.mem.eql(u8, m.action, "refuse")) try plan.appendSlice(",\"reason\":\"a different file under a version that exists\"");
        if (m.files.len > 0) {
            try plan.appendSlice(",\"manifest_sha256\":\"" ++ test_sha ++ "\",\"files\":[");
            for (m.files, 0..) |f, j| {
                if (j > 0) try plan.append(',');
                const filename = try std.fmt.allocPrint(a, "mojo-{s}-{s}-{s}.conda", .{ m.name, m.version, f.build });
                try tmp.dir.makePath(f.subdir);
                try tmp.dir.writeFile(try std.fmt.allocPrint(a, "{s}/{s}", .{ f.subdir, filename }), f.bytes);
                try plan.writer().print("{{\"subdir\":\"{s}\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}", .{ f.subdir, filename, sha256Hex(f.bytes), f.bytes.len });
            }
            try plan.append(']');
        }
        try plan.append('}');
    }
    try plan.appendSlice("]}");
    try tmp.dir.writeFile("plan.json", plan.items);
    return tmp.dir.realpathAlloc(a, ".");
}

fn expectRefused(a: Allocator, dir: []const u8, contains_text: []const u8) !void {
    var why: []const u8 = "";
    if (load(a, dir, &why)) |_| {
        std.debug.print("accepted a set that should be refused for: {s}\n", .{contains_text});
        return error.TestUnexpectedResult;
    } else |e| {
        if (e != error.Refused or std.mem.indexOf(u8, why, contains_text) == null) {
            std.debug.print("wanted a refusal naming '{s}', got {s}: {s}\n", .{ contains_text, @errorName(e), why });
            return error.TestUnexpectedResult;
        }
    }
}

const base_meta = "{\"schema\":1,\"name\":\"libbase\",\"version\":\"0.1.0\",\"deps\":[]}";
const app_meta = "{\"schema\":1,\"name\":\"applib\",\"version\":\"0.2.0\",\"deps\":[{\"name\":\"libbase\",\"range\":\"0.1\"},{\"name\":\"outside\"}],\"native\":[{\"id\":\"zz\",\"soname\":\"libzz.a\",\"kind\":\"static\",\"static_file\":\"../libzz.a\"}]}";

test "a staged set is read: each member's record has the dependencies and natives of its own metadata, and a build for the compiler its file names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try testSet(a, &tmp, &.{
        .{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .bytes = try testConda(a, "libbase", "0.1.0", base_meta) }} },
        .{ .name = "applib", .version = "0.2.0", .files = &.{.{ .bytes = try testConda(a, "applib", "0.2.0", app_meta) }} },
        .{ .name = "published", .version = "1.0.0", .action = "skip" },
    });
    var why: []const u8 = "";
    const ov = try load(a, dir, &why);
    try std.testing.expectEqual(@as(usize, 2), ov.members.len);
    try std.testing.expect(ov.member("published") == null);
    try std.testing.expect(ov.member("elsewhere") == null);

    // The text parses with the resolver's own reader, and says what the registry will say.
    var diag: resolve.Diagnostic = .{};
    const recs = try resolve.parseIndex(a, "applib", try indexText(a, ov.member("applib").?), &diag);
    try std.testing.expectEqual(@as(usize, 1), recs.len);
    const r = recs[0];
    try std.testing.expectEqualStrings("0.2.0", r.version);
    try std.testing.expectEqualStrings("mojo1.0.0_0", r.build);
    try std.testing.expect(r.builtFor("1.0.0"));
    try std.testing.expect(!r.builtFor("1.1.0"));
    try std.testing.expect(r.state == .published);
    try std.testing.expectEqual(@as(usize, 2), r.deps.len);
    try std.testing.expectEqualStrings("libbase", r.deps[0].name);
    try std.testing.expectEqualStrings("0.1", r.deps[0].range.?);
    try std.testing.expect(r.deps[1].range == null);
    try std.testing.expectEqual(@as(usize, 1), r.native.len);
    try std.testing.expectEqualStrings("libzz.a", r.native[0].soname);
    try std.testing.expectEqualStrings("linux-64", r.files[0].subdir);
    try std.testing.expectEqualStrings("mojo-applib-0.2.0-mojo1.0.0_0.conda", r.files[0].filename);
}

test "a staged set that is not what it says is refused, naming why" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const good = try testConda(a, "libbase", "0.1.0", base_meta);

    // A directory with no plan.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try expectRefused(a, try tmp.dir.realpathAlloc(a, "."), "plan.json");
    }
    // A member the plan refuses refuses the whole set.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try testSet(a, &tmp, &.{
            .{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .bytes = good }} },
            .{ .name = "burnt", .version = "0.3.0", .action = "refuse" },
        });
        try expectRefused(a, dir, "refuses burnt 0.3.0");
    }
    // A file changed after the plan was made: other bytes, then other length.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try testSet(a, &tmp, &.{.{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .bytes = good }} }});
        var changed = try a.dupe(u8, good);
        changed[changed.len / 2] ^= 1;
        try tmp.dir.writeFile("linux-64/mojo-libbase-0.1.0-mojo1.0.0_0.conda", changed);
        try expectRefused(a, dir, "is not the file plan.json describes");
        try tmp.dir.writeFile("linux-64/mojo-libbase-0.1.0-mojo1.0.0_0.conda", try std.mem.concat(a, u8, &.{ good, "x" }));
        try expectRefused(a, dir, "is not the file plan.json describes");
    }
    // A file the plan names that is not there.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try testSet(a, &tmp, &.{.{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .bytes = good }} }});
        try tmp.dir.deleteFile("linux-64/mojo-libbase-0.1.0-mojo1.0.0_0.conda");
        try expectRefused(a, dir, "FileNotFound");
    }
    // Metadata of another package, and none at all.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try testSet(a, &tmp, &.{.{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .bytes = try testConda(a, "libbase", "0.1.0", app_meta) }} }});
        try expectRefused(a, dir, "describes applib 0.2.0, not libbase 0.1.0");
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try testSet(a, &tmp, &.{.{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .bytes = try conda_fixture.simple(a, "libbase", "0.1.0", &.{.{ .name = "lib/other.txt", .data = "x" }}) }} }});
        try expectRefused(a, dir, "has no lib/mojo/libbase.mopm.json");
    }
    // The same package twice; a name that is not the package's; a build that is not a build.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try testSet(a, &tmp, &.{
            .{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .bytes = good }} },
            .{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .bytes = good }} },
        });
        try expectRefused(a, dir, "lists libbase twice");
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try testSet(a, &tmp, &.{.{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .build = "py3_0", .bytes = good }} }});
        try expectRefused(a, dir, "is not mojo<compiler>_<n>");
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try testSet(a, &tmp, &.{.{ .name = "libbase", .version = "0.1", .files = &.{.{ .bytes = good }} }});
        try expectRefused(a, dir, "a version is MAJOR.MINOR.PATCH");
    }
    // Two subdirs that disagree on dependencies: the registry refuses that at publish, so the set is refused now.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try testSet(a, &tmp, &.{.{ .name = "applib", .version = "0.2.0", .files = &.{
            .{ .subdir = "linux-64", .bytes = try testConda(a, "applib", "0.2.0", app_meta) },
            .{ .subdir = "osx-arm64", .bytes = try testConda(a, "applib", "0.2.0", "{\"schema\":1,\"name\":\"applib\",\"version\":\"0.2.0\",\"deps\":[]}") },
        } }});
        try expectRefused(a, dir, "disagrees with the first file of applib 0.2.0");
    }
    // A plan of another version.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile("plan.json", "{\"version\":2,\"members\":[]}");
        try expectRefused(a, try tmp.dir.realpathAlloc(a, "."), "reads plan version 1");
    }
}

/// An inner source that fails the test when it is asked anything.
const Forbidden = struct {
    pub fn fetch(_: Forbidden, _: Allocator, what: []const u8, _: *resolve.Diagnostic) resolve.Error!?[]const u8 {
        std.debug.print("the registry was asked for {s}\n", .{what});
        return error.ResolveFailed;
    }
    pub fn fetchConda(_: Forbidden, _: Allocator, what: []const u8, _: []const u8, _: *resolve.Diagnostic) resolve.Error![]const u8 {
        std.debug.print("the registry was asked for {s}\n", .{what});
        return error.ResolveFailed;
    }
};

const MemoryIndex = resolve.MemoryIndex;

test "a closure the set holds is resolved and locked without asking the registry anything; a package it lacks falls through" {
    const plan = @import("install_plan.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const outside_meta = "{\"schema\":1,\"name\":\"outside\",\"version\":\"1.0.0\",\"deps\":[]}";
    const dir = try testSet(a, &tmp, &.{
        .{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .bytes = try testConda(a, "libbase", "0.1.0", base_meta) }} },
        .{ .name = "applib", .version = "0.2.0", .files = &.{.{ .bytes = try testConda(a, "applib", "0.2.0", "{\"schema\":1,\"name\":\"applib\",\"version\":\"0.2.0\",\"deps\":[{\"name\":\"libbase\",\"range\":\"0.1\"}]}") }} },
        .{ .name = "outside", .version = "1.0.0", .files = &.{.{ .bytes = try testConda(a, "outside", "1.0.0", outside_meta) }} },
    });
    var why: []const u8 = "";
    const ov = try load(a, dir, &why);

    // Fully staged: the inner source fails the test if it is asked for anything.
    var asked = false;
    var diag: resolve.Diagnostic = .{};
    const roots = [_]resolve.Root{.{ .name = "applib", .requirement = "=0.2.0" }};
    const res = try resolve.resolve(a, Index(Forbidden){ .overlay = &ov, .inner = .{}, .asked = &asked }, .{ .mojo = "1.0.0", .roots = &roots }, &diag);
    try std.testing.expect(!asked);
    try std.testing.expectEqual(@as(usize, 2), res.packages.len);
    try std.testing.expectEqualStrings("applib", res.packages[0].record.name);
    try std.testing.expectEqualStrings("libbase", res.packages[1].record.name);
    try std.testing.expectEqual(@as(usize, 0), (try registrySubdirs(a, ov, res)).len);
    const channel = Channel(Forbidden){ .overlay = &ov, .inner = .{}, .registry_subdirs = &.{} };
    const l = try plan.buildLock(a, res, "https://conda.example/", channel, null, &diag);
    try std.testing.expectEqual(@as(usize, 2), l.packages.len);
    try std.testing.expectEqualStrings("https://conda.example/linux-64/mojo-applib-0.2.0-mojo1.0.0_0.conda", l.packages[0].url);
    try std.testing.expectEqualStrings(&sha256Hex(try testConda(a, "libbase", "0.1.0", base_meta)), l.packages[1].sha256);
    try std.testing.expectEqualStrings("https://conda.example/", l.channels[0]);

    // A package the set lacks is asked of the registry, and its subdir's repodata with it.
    const reg_line = "{\"build\":\"mojo1.0.0_0\",\"deps\":[],\"files\":[{\"filename\":\"mojo-registryonly-2.0.0-mojo1.0.0_0.conda\",\"sha256\":\"" ++ test_sha ++ "\",\"size\":1000,\"subdir\":\"linux-64\"}],\"name\":\"registryonly\",\"requires_mojo\":\"==1.0.0\",\"state\":\"published\",\"v\":1,\"version\":\"2.0.0\"}\n";
    const reg_repodata = "{\"packages.conda\":{\"mojo-registryonly-2.0.0-mojo1.0.0_0.conda\":{\"sha256\":\"" ++ test_sha ++ "\",\"size\":1000}},\"removed\":[]}";
    const Registry = struct {
        index: MemoryIndex,
        pub fn fetch(self: @This(), arena: Allocator, name: []const u8, d: *resolve.Diagnostic) resolve.Error!?[]const u8 {
            return self.index.fetch(arena, name, d);
        }
    };
    asked = false;
    const mixed_roots = [_]resolve.Root{ .{ .name = "applib", .requirement = "=0.2.0" }, .{ .name = "registryonly", .requirement = "2" } };
    const reg = Registry{ .index = .{ .files = &.{.{ "registryonly", reg_line }} } };
    const res2 = try resolve.resolve(a, Index(Registry){ .overlay = &ov, .inner = reg, .asked = &asked }, .{ .mojo = "1.0.0", .roots = &mixed_roots }, &diag);
    try std.testing.expect(asked);
    try std.testing.expectEqual(@as(usize, 3), res2.packages.len);
    const subs = try registrySubdirs(a, ov, res2);
    try std.testing.expectEqual(@as(usize, 1), subs.len);
    try std.testing.expectEqualStrings("linux-64", subs[0]);
    const Chan = struct {
        pub fn fetch(_: @This(), _: Allocator, _: []const u8, _: *resolve.Diagnostic) resolve.Error![]const u8 {
            return reg_repodata;
        }
        pub fn fetchConda(_: @This(), _: Allocator, _: []const u8, _: []const u8, _: *resolve.Diagnostic) resolve.Error![]const u8 {
            return error.ResolveFailed;
        }
    };
    const l2 = try plan.buildLock(a, res2, "https://conda.example/", Channel(Chan){ .overlay = &ov, .inner = .{}, .registry_subdirs = subs }, null, &diag);
    try std.testing.expectEqual(@as(usize, 3), l2.packages.len);
}

test "the registry's repodata.json is merged with the staged entries, and a staged file name it lists with other bytes is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try testConda(a, "libbase", "0.1.0", base_meta);
    const dir = try testSet(a, &tmp, &.{.{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .bytes = bytes }} }});
    var why: []const u8 = "";
    const ov = try load(a, dir, &why);

    const only = try ov.repodata(a, "linux-64", null, &why);
    try std.testing.expect(std.mem.indexOf(u8, only, "mojo-libbase-0.1.0-mojo1.0.0_0.conda") != null);
    try std.testing.expect(std.mem.indexOf(u8, only, &sha256Hex(bytes)) != null);

    const theirs = "{\"info\":{\"subdir\":\"linux-64\"},\"packages.conda\":{\"mojo-other-1.0.0-mojo1.0.0_0.conda\":{\"sha256\":\"" ++ test_sha ++ "\",\"size\":7}},\"removed\":[\"x\"]}";
    const merged = try ov.repodata(a, "linux-64", theirs, &why);
    try std.testing.expect(std.mem.indexOf(u8, merged, "mojo-other-1.0.0-mojo1.0.0_0.conda") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "mojo-libbase-0.1.0-mojo1.0.0_0.conda") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"removed\"") != null);

    // The same bytes under the same name: fine. Other bytes, or another size: refused, naming both sides' file.
    const same = try std.fmt.allocPrint(a, "{{\"packages.conda\":{{\"mojo-libbase-0.1.0-mojo1.0.0_0.conda\":{{\"sha256\":\"{s}\",\"size\":{d}}}}},\"removed\":[]}}", .{ sha256Hex(bytes), bytes.len });
    _ = try ov.repodata(a, "linux-64", same, &why);
    const other = "{\"packages.conda\":{\"mojo-libbase-0.1.0-mojo1.0.0_0.conda\":{\"sha256\":\"" ++ test_sha ++ "\",\"size\":9}},\"removed\":[]}";
    try std.testing.expectError(error.Refused, ov.repodata(a, "linux-64", other, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "linux-64/mojo-libbase-0.1.0-mojo1.0.0_0.conda is staged in") != null);
    const resized = try std.fmt.allocPrint(a, "{{\"packages.conda\":{{\"mojo-libbase-0.1.0-mojo1.0.0_0.conda\":{{\"sha256\":\"{s}\",\"size\":{d}}}}},\"removed\":[]}}", .{ sha256Hex(bytes), bytes.len + 1 });
    try std.testing.expectError(error.Refused, ov.repodata(a, "linux-64", resized, &why));

    // Text that is not a repodata.json is handed back for the reader to refuse.
    try std.testing.expectEqualStrings("not json", try ov.repodata(a, "linux-64", "not json", &why));
}

test "the registry holding a staged version with other bytes is named; the same bytes, another version and no record are not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try testConda(a, "libbase", "0.1.0", base_meta);
    const dir = try testSet(a, &tmp, &.{.{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .bytes = bytes }} }});
    var why: []const u8 = "";
    const ov = try load(a, dir, &why);
    const m = ov.member("libbase").?;
    const file = "mojo-libbase-0.1.0-mojo1.0.0_0.conda";
    const line = struct {
        fn make(arena: Allocator, version: []const u8, sha: []const u8, size: usize, filename: []const u8) ![]const resolve.Record {
            const text = try std.fmt.allocPrint(arena, "{{\"build\":\"mojo1.0.0_0\",\"deps\":[],\"files\":[{{\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d},\"subdir\":\"linux-64\"}}],\"name\":\"libbase\",\"requires_mojo\":\"==1.0.0\",\"state\":\"published\",\"v\":1,\"version\":\"{s}\"}}\n", .{ filename, sha, size, version });
            var d: resolve.Diagnostic = .{};
            return try resolve.parseIndex(arena, "libbase", text, &d);
        }
    }.make;
    const mine = sha256Hex(bytes);
    try std.testing.expect((try registryDiffers(a, dir, m, try line(a, "0.1.0", &mine, bytes.len, file))) == null);
    try std.testing.expect((try registryDiffers(a, dir, m, try line(a, "0.1.1", test_sha, 5, file))) == null);
    try std.testing.expect((try registryDiffers(a, dir, m, &.{})) == null);
    const other = (try registryDiffers(a, dir, m, try line(a, "0.1.0", test_sha, bytes.len, file))).?;
    try std.testing.expect(std.mem.indexOf(u8, other, "libbase 0.1.0 is staged in") != null);
    try std.testing.expect(std.mem.indexOf(u8, other, "needs a new version") != null);
    const resized = try registryDiffers(a, dir, m, try line(a, "0.1.0", &mine, bytes.len + 1, file));
    try std.testing.expect(resized != null);
    const renamed = try registryDiffers(a, dir, m, try line(a, "0.1.0", &mine, bytes.len, "mojo-libbase-0.1.0-mojo1.0.0_1.conda"));
    try std.testing.expect(renamed != null);
}

test "the bytes of a file come only for the file a lock pins, and from the set itself" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try testConda(a, "libbase", "0.1.0", base_meta);
    const dir = try testSet(a, &tmp, &.{.{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .bytes = bytes }} }});
    var why: []const u8 = "";
    const ov = try load(a, dir, &why);
    const sha = sha256Hex(bytes);
    var p = lock.Package{
        .name = "libbase", .version = "0.1.0", .build = "mojo1.0.0_0", .subdir = "linux-64", .channel = "https://conda.example/",
        .url = "https://conda.example/linux-64/mojo-libbase-0.1.0-mojo1.0.0_0.conda", .sha256 = &sha, .size = bytes.len, .mojo = "1.0.0", .deps = &.{}, .native = &.{},
    };
    const got = (try ov.bytesFor(a, p, &why)).?;
    try std.testing.expectEqualSlices(u8, bytes, got);
    // Another sha256, version, subdir or package: the registry's file, not ours.
    p.sha256 = test_sha;
    try std.testing.expect((try ov.bytesFor(a, p, &why)) == null);
    p.sha256 = &sha;
    p.version = "0.1.1";
    try std.testing.expect((try ov.bytesFor(a, p, &why)) == null);
    p.version = "0.1.0";
    p.subdir = "osx-arm64";
    try std.testing.expect((try ov.bytesFor(a, p, &why)) == null);
    p.subdir = "linux-64";
    p.name = "other";
    try std.testing.expect((try ov.bytesFor(a, p, &why)) == null);
    // A file changed after the set was read is refused.
    try tmp.dir.writeFile("linux-64/mojo-libbase-0.1.0-mojo1.0.0_0.conda", "changed");
    p.name = "libbase";
    try std.testing.expectError(error.Refused, ov.bytesFor(a, p, &why));
}

test "the files of a version agree on dependencies and natives only when each name, range, id and soname does" {
    const d1 = [_]resolve.Dep{ .{ .name = "a", .range = "1" }, .{ .name = "b" } };
    const d2 = [_]resolve.Dep{ .{ .name = "a", .range = "1" }, .{ .name = "b", .range = null } };
    const d3 = [_]resolve.Dep{ .{ .name = "a", .range = "2" }, .{ .name = "b" } };
    const d4 = [_]resolve.Dep{ .{ .name = "a", .range = "1" }, .{ .name = "c" } };
    try std.testing.expect(sameDeps(&d1, &d2));
    try std.testing.expect(!sameDeps(&d1, &d3));
    try std.testing.expect(!sameDeps(&d1, &d4));
    try std.testing.expect(!sameDeps(&d1, d1[0..1]));
    const n1 = [_]resolve.Native{.{ .id = "x", .soname = "libx.a" }};
    const n2 = [_]resolve.Native{.{ .id = "x", .soname = "liby.a" }};
    const n3 = [_]resolve.Native{.{ .id = "y", .soname = "libx.a" }};
    try std.testing.expect(sameNative(&n1, &n1));
    try std.testing.expect(!sameNative(&n1, &n2));
    try std.testing.expect(!sameNative(&n1, &n3));
    try std.testing.expect(!sameNative(&n1, &.{}));
}

test "the set answers for the files it holds only; the channel hands any other package file to the registry's source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try testConda(a, "libbase", "0.1.0", base_meta);
    const dir = try testSet(a, &tmp, &.{.{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .bytes = bytes }} }});
    var why: []const u8 = "";
    const ov = try load(a, dir, &why);
    try std.testing.expect((try ov.fileBytes(a, "linux-64", "mojo-other-1.0.0-mojo1.0.0_0.conda", &why)) == null);
    try std.testing.expect((try ov.fileBytes(a, "osx-arm64", "mojo-libbase-0.1.0-mojo1.0.0_0.conda", &why)) == null);

    const Inner = struct {
        pub fn fetch(_: @This(), _: Allocator, _: []const u8, _: *resolve.Diagnostic) resolve.Error![]const u8 {
            return "{\"packages.conda\":{}}";
        }
        pub fn fetchConda(_: @This(), _: Allocator, _: []const u8, filename: []const u8, _: *resolve.Diagnostic) resolve.Error![]const u8 {
            return filename;
        }
    };
    const channel = Channel(Inner){ .overlay = &ov, .inner = .{}, .registry_subdirs = &.{"linux-64"} };
    var diag: resolve.Diagnostic = .{};
    try std.testing.expectEqualSlices(u8, bytes, try channel.fetchConda(a, "linux-64", "mojo-libbase-0.1.0-mojo1.0.0_0.conda", &diag));
    try std.testing.expectEqualStrings("mojo-theirs-1.0.0-mojo1.0.0_0.conda", try channel.fetchConda(a, "linux-64", "mojo-theirs-1.0.0-mojo1.0.0_0.conda", &diag));
    try std.testing.expect(std.mem.indexOf(u8, try channel.fetch(a, "linux-64", &diag), "mojo-libbase-0.1.0-mojo1.0.0_0.conda") != null);

    // A file changed after the set was read is an error of the channel, naming the file.
    try tmp.dir.writeFile("linux-64/mojo-libbase-0.1.0-mojo1.0.0_0.conda", "changed");
    try std.testing.expectError(error.ResolveFailed, channel.fetchConda(a, "linux-64", "mojo-libbase-0.1.0-mojo1.0.0_0.conda", &diag));
    try std.testing.expectEqual(resolve.Kind.bad_channel, diag.kind);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "changed after it was read") != null);

    // A registry entry for a staged file name with other bytes is an error of the channel too.
    const Clashing = struct {
        pub fn fetch(_: @This(), _: Allocator, _: []const u8, _: *resolve.Diagnostic) resolve.Error![]const u8 {
            return "{\"packages.conda\":{\"mojo-libbase-0.1.0-mojo1.0.0_0.conda\":{\"sha256\":\"" ++ test_sha ++ "\",\"size\":3}}}";
        }
    };
    const clash = Channel(Clashing){ .overlay = &ov, .inner = .{}, .registry_subdirs = &.{"linux-64"} };
    try std.testing.expectError(error.ResolveFailed, clash.fetch(a, "linux-64", &diag));
    try std.testing.expectEqual(resolve.Kind.bad_channel, diag.kind);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "needs a new version") != null);
}

test "a plan that is not what the spec says is refused, naming the member" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const good = try testConda(a, "libbase", "0.1.0", base_meta);
    const sha = sha256Hex(good);
    const file = try std.fmt.allocPrint(a, "{{\"subdir\":\"linux-64\",\"filename\":\"mojo-libbase-0.1.0-mojo1.0.0_0.conda\",\"sha256\":\"{s}\",\"size\":{d}}}", .{ sha, good.len });
    const Case = struct { plan: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .plan = "[]", .want = "is not a JSON object" },
        .{ .plan = "{", .want = "is not JSON" },
        .{ .plan = "{\"members\":[]}", .want = "has no version" },
        .{ .plan = "{\"version\":1}", .want = "has no members" },
        .{ .plan = "{\"version\":1,\"members\":{}}", .want = "members is not an array" },
        .{ .plan = "{\"version\":1,\"members\":[1]}", .want = "a member is not an object" },
        .{ .plan = "{\"version\":1,\"members\":[{\"version\":\"1.0.0\"}]}", .want = "a member has no name" },
        .{ .plan = "{\"version\":1,\"members\":[{\"name\":\"x\"}]}", .want = "x has no version" },
        .{ .plan = "{\"version\":1,\"members\":[{\"name\":\"x\",\"version\":\"1.0.0\"}]}", .want = "x 1.0.0 has no action" },
        .{ .plan = "{\"version\":1,\"members\":[{\"name\":\"x\",\"version\":\"1.0.0\",\"action\":\"publish\"}]}", .want = "has the action publish" },
        .{ .plan = "{\"version\":1,\"members\":[{\"name\":\"BadName\",\"version\":\"1.0.0\",\"action\":\"upload\"}]}", .want = "must start with a lowercase letter" },
        .{ .plan = "{\"version\":1,\"members\":[{\"name\":\"x\",\"version\":\"1.0.0\",\"action\":\"upload\"}]}", .want = "x 1.0.0 has no files" },
        .{ .plan = "{\"version\":1,\"members\":[{\"name\":\"x\",\"version\":\"1.0.0\",\"action\":\"upload\",\"files\":[]}]}", .want = "files is one to 20 entries" },
        .{ .plan = "{\"version\":1,\"members\":[{\"name\":\"x\",\"version\":\"1.0.0\",\"action\":\"upload\",\"files\":[1]}]}", .want = "a file of x 1.0.0 is not an object" },
        .{ .plan = "{\"version\":1,\"members\":[{\"name\":\"x\",\"version\":\"1.0.0\",\"action\":\"upload\",\"files\":[{}]}]}", .want = "a file of x 1.0.0 has no subdir" },
        .{ .plan = "{\"version\":1,\"members\":[{\"name\":\"x\",\"version\":\"1.0.0\",\"action\":\"upload\",\"files\":[{\"subdir\":\"win-64\",\"filename\":\"f\",\"sha256\":\"a\",\"size\":1}]}]}", .want = "win-64 is not a subdir" },
        .{ .plan = "{\"version\":1,\"members\":[{\"name\":\"x\",\"version\":\"1.0.0\",\"action\":\"upload\",\"files\":[{\"subdir\":\"noarch\",\"filename\":\"../f\",\"sha256\":\"a\",\"size\":1}]}]}", .want = "is not a plain file name" },
        .{ .plan = "{\"version\":1,\"members\":[{\"name\":\"x\",\"version\":\"1.0.0\",\"action\":\"upload\",\"files\":[{\"subdir\":\"noarch\",\"filename\":\"f\",\"sha256\":\"a\",\"size\":1}]}]}", .want = "is not 64 lowercase hex digits" },
        .{ .plan = "{\"version\":1,\"members\":[{\"name\":\"x\",\"version\":\"1.0.0\",\"action\":\"upload\",\"files\":[{\"subdir\":\"noarch\",\"filename\":\"f\",\"sha256\":\"" ++ test_sha ++ "\",\"size\":0}]}]}", .want = "the size of f is not 1 to" },
        .{ .plan = "{\"version\":1,\"members\":[{\"name\":\"x\",\"version\":\"1.0.0\",\"action\":\"upload\",\"files\":[{\"subdir\":\"noarch\",\"filename\":\"mojo-y-1.0.0-mojo1.0.0_0.conda\",\"sha256\":\"" ++ test_sha ++ "\",\"size\":5}]}]}", .want = "is not a file of x 1.0.0" },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile("plan.json", case.plan);
        try expectRefused(a, try tmp.dir.realpathAlloc(a, "."), case.want);
    }

    // The same file twice, two builds in one version, and bytes that are not a package or have broken metadata.
    const twice = try std.fmt.allocPrint(a, "{{\"version\":1,\"members\":[{{\"name\":\"libbase\",\"version\":\"0.1.0\",\"action\":\"upload\",\"files\":[{s},{s}]}}]}}", .{ file, file });
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.makePath("linux-64");
        try tmp.dir.writeFile("linux-64/mojo-libbase-0.1.0-mojo1.0.0_0.conda", good);
        try tmp.dir.writeFile("plan.json", twice);
        try expectRefused(a, try tmp.dir.realpathAlloc(a, "."), "lists linux-64/mojo-libbase-0.1.0-mojo1.0.0_0.conda twice");
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try testSet(a, &tmp, &.{.{ .name = "libbase", .version = "0.1.0", .files = &.{
            .{ .subdir = "linux-64", .bytes = good },
            .{ .subdir = "osx-arm64", .build = "mojo1.1.0_0", .bytes = good },
        } }});
        try expectRefused(a, dir, "are of different builds");
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try testSet(a, &tmp, &.{.{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .bytes = "this is not a zip" }} }});
        try expectRefused(a, dir, "is not a readable .conda");
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try testSet(a, &tmp, &.{.{ .name = "libbase", .version = "0.1.0", .files = &.{.{ .bytes = try testConda(a, "libbase", "0.1.0", "not json") }} }});
        try expectRefused(a, dir, "is not valid package metadata");
    }
}
