//! A staged set read as a read-only local channel: what `--overlay <dir>` of `mopm add`, `mopm lock` and `mopm sync` is.
//!
//! The directory is a staged set (spec/staged-set.md): a `plan.json` (version 2) that lists members, each by its full
//! name `<namespace>/<name>`, in dependency order, and the `.conda` files it names under `<subdir>/<filename>`
//! (`mojo-<namespace>.<name>-...`). `load` reads it and checks every file against the plan (size, sha256) and every
//! member against its own package metadata, once; after that the set can answer what the registry answers for a
//! package, from the files alone:
//!
//! - `indexText` is the sparse-index file of a staged package (the records the registry will serve once the version
//!   is published), with the dependencies and native libraries the package's own `lib/mojo/<import name>.mopm.json`
//!   declares and one build per compiler its file names name (a set may hold the files of several builds of a version);
//! - `repodata` is the `<namespace>/<subdir>/repodata.json` entries of its files, merged into the registry's when the
//!   registry is asked at all;
//! - `fileBytes` and `bytesFor` are the bytes of a file, for the natives a lock hashes and for an install.
//!
//! The set never reaches a lock or a manifest: a lock made with it names the
//! registry's channel and file URLs and the files' sha256, so the same lock holds
//! once the versions are published. A package the set holds is answered by the set
//! (its staged line stands in for the package's index file), a package it lacks
//! falls through to the registry. The registry is asked for a staged package too:
//! when it already holds the staged version, the set adds its builds to that
//! version and the registry's record, with its other versions, is what resolution
//! sees (`mergedIndexText`); when it does not, the staged line alone is the
//! package. `Index` and `Channel` are the two sources, generic over the registry's.
//! Nothing here writes below the directory.
//!
//! Members with the action `skip` are already on the registry with these bytes
//! and are left to it. A set that holds a `refuse` member is refused whole.

const std = @import("std");
const Allocator = std.mem.Allocator;
const resolve = @import("resolve.zig");
const lock = @import("lock.zig");
const metadata = @import("metadata.zig");
const names = @import("names.zig");
const semver = @import("semver.zig");
const conda_unpack = @import("conda_unpack.zig");

/// The most a package file may be (the registry's limit).
pub const max_file_bytes: usize = 100_000_000;

pub const subdirs = [_][]const u8{ "noarch", "linux-64", "linux-aarch64", "osx-arm64" };

/// One staged version: its record in the index as the registry will hold it.
pub const Member = struct {
    /// The full name, `<namespace>/<name>`.
    name: []const u8,
    version: []const u8,
    deps: []const resolve.Dep,
    native: []const resolve.Native,
    /// The builds the set holds of the version, one per Mojo compiler, by compiler version: the files of each
    /// (`mojo1.0.0_0`, `==1.0.0`). A set made with one compiler has one; a set may also hold a build the
    /// registry's version lacks.
    builds: []const resolve.Build,
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

pub fn sha256Hex(bytes: []const u8) [64]u8 {
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

pub fn sameDeps(a: []const resolve.Dep, b: []const resolve.Dep) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        const xr = x.range orelse "";
        const yr = y.range orelse "";
        if (!std.mem.eql(u8, xr, yr)) return false;
    }
    return true;
}

pub fn sameNative(a: []const resolve.Native, b: []const resolve.Native) bool {
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
            for (m.builds) |b| {
                for (b.files) |f| {
                    if (std.mem.eql(u8, f.subdir, subdir) and std.mem.eql(u8, f.filename, filename)) return f;
                }
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
        if (!std.mem.eql(u8, m.version, p.version)) return null;
        for (m.builds) |b| {
            if (!std.mem.eql(u8, b.build, p.build)) continue;
            for (b.files) |f| {
                if (std.mem.eql(u8, f.subdir, p.subdir) and std.mem.eql(u8, f.sha256, p.sha256) and f.size == p.size) {
                    return self.fileBytes(arena, f.subdir, f.filename, why);
                }
            }
        }
        return null;
    }

    /// `<namespace>/<subdir>/repodata.json` for the staged files of the namespace's packages in `subdir`. With `inner` (the
    /// registry's), its `packages.conda` with the staged entries added; a registry entry for a staged file name that holds
    /// other bytes is refused.
    /// Text of `inner` that is not a repodata.json is returned as it is, for the reader of it to refuse.
    pub fn repodata(self: Overlay, arena: Allocator, namespace: []const u8, subdir: []const u8, inner: ?[]const u8, why: *[]const u8) Error![]const u8 {
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
            if (!std.mem.eql(u8, names.namespaceOf(m.name), namespace)) continue;
            for (m.builds) |b| for (b.files) |f| {
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
                try entry.put("build", .{ .string = b.build });
                try entry.put("name", .{ .string = try names.condaName(arena, m.name) });
                try entry.put("sha256", .{ .string = f.sha256 });
                try entry.put("size", .{ .integer = @intCast(f.size) });
                try entry.put("subdir", .{ .string = f.subdir });
                try entry.put("version", .{ .string = m.version });
                try packages.object.put(f.filename, .{ .object = entry });
            };
        }
        return std.json.stringifyAlloc(arena, doc, .{});
    }
};

const IndexDep = struct { name: []const u8, range: ?[]const u8 = null };
const IndexLine = struct {
    v: u8 = 2,
    name: []const u8,
    version: []const u8,
    build: []const u8,
    state: []const u8 = "published",
    requires_mojo: []const u8,
    deps: []const IndexDep,
    native: []const resolve.Native,
    files: []const resolve.File,
    builds: []const resolve.Build,
};

/// The index file of a staged package: one record, as the registry will serve it. Its top-level `build`,
/// `requires_mojo` and `files` are those of the primary build (the lowest compiler); `builds` lists every build.
pub fn indexText(arena: Allocator, m: *const Member) Allocator.Error![]const u8 {
    const deps = try arena.alloc(IndexDep, m.deps.len);
    for (m.deps, deps) |d, *out| out.* = .{ .name = d.name, .range = d.range };
    var out = std.ArrayList(u8).init(arena);
    const primary = m.builds[0];
    try std.json.stringify(IndexLine{
        .name = m.name,
        .version = m.version,
        .build = primary.build,
        .requires_mojo = primary.requires_mojo,
        .deps = deps,
        .native = m.native,
        .files = primary.files,
        .builds = m.builds,
    }, .{ .emit_null_optional_fields = false }, out.writer());
    try out.append('\n');
    return out.items;
}

/// The index file of a staged package when the registry has one (`held`, its text). When the registry's lines include
/// the staged version, the registry's lines with the staged builds added to the line of that version: the version's
/// own fields (dependencies, native libraries, state) and the registry's builds of it stay the registry's, a build both
/// hold is the staged one (`registryDiffers` compares it with the registry's), the top-level `build`, `requires_mojo`
/// and `files` are those of the lowest compiler as the registry writes them, and the registry's other versions stay.
/// The staged line alone when the registry holds no line of the staged version, or `held` is not an index file this
/// can read: the staged version is then new, and the set is the package.
pub fn mergedIndexText(arena: Allocator, m: *const Member, held: []const u8) Allocator.Error![]const u8 {
    const staged = try indexText(arena, m);
    var out = std.ArrayList(u8).init(arena);
    var merged = false;
    var lines = std.mem.splitScalar(u8, held, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return staged,
        };
        if (doc != .object) return staged;
        const version = getStr(doc.object, "version") orelse return staged;
        if (merged or !sameVersion(version, m.version)) {
            try out.appendSlice(line);
            try out.append('\n');
            continue;
        }
        const line_merged = (try addBuilds(arena, m, doc.object)) orelse return staged;
        try std.json.stringify(line_merged, .{}, out.writer());
        try out.append('\n');
        merged = true;
    }
    return if (merged) out.items else staged;
}

fn lessBuild(_: void, a: std.json.Value, b: std.json.Value) bool {
    return resolve.lessCompiler({}, resolve.compilerOfBuild(getStr(a.object, "build").?).?, resolve.compilerOfBuild(getStr(b.object, "build").?).?);
}

/// `b` as an entry of an index line's `builds`.
fn buildValue(arena: Allocator, b: resolve.Build) Allocator.Error!std.json.Value {
    var files = std.json.Array.init(arena);
    for (b.files) |f| {
        var o = std.json.ObjectMap.init(arena);
        try o.put("subdir", .{ .string = f.subdir });
        try o.put("filename", .{ .string = f.filename });
        try o.put("sha256", .{ .string = f.sha256 });
        try o.put("size", .{ .integer = @intCast(f.size) });
        try files.append(.{ .object = o });
    }
    var o = std.json.ObjectMap.init(arena);
    try o.put("build", .{ .string = b.build });
    try o.put("requires_mojo", .{ .string = b.requires_mojo });
    try o.put("files", .{ .array = files });
    return .{ .object = o };
}

/// The registry's `line` of the staged version with the staged builds in its `builds`; null when the line is not one
/// this can add to (no `builds` and no top-level build, or a build without a readable compiler, `requires_mojo` or `files`).
fn addBuilds(arena: Allocator, m: *const Member, line: std.json.ObjectMap) Allocator.Error!?std.json.Value {
    var builds = std.ArrayList(std.json.Value).init(arena);
    if (line.get("builds")) |listed| {
        if (listed != .array) return null;
        try builds.appendSlice(listed.array.items);
    } else {
        var only = std.json.ObjectMap.init(arena);
        for ([_][]const u8{ "build", "requires_mojo", "files" }) |key| {
            try only.put(key, line.get(key) orelse return null);
        }
        try builds.append(.{ .object = only });
    }
    for (builds.items) |b| {
        if (b != .object) return null;
        const name = getStr(b.object, "build") orelse return null;
        if (resolve.compilerOfBuild(name) == null) return null;
        // The top-level trio is taken from the first build, so each entry must have the other two keys of the right type.
        const requires = b.object.get("requires_mojo") orelse return null;
        const files = b.object.get("files") orelse return null;
        if (requires != .string or files != .array) return null;
    }
    for (m.builds) |sb| {
        const value = try buildValue(arena, sb);
        var replaced = false;
        for (builds.items) |*b| {
            if (std.mem.eql(u8, getStr(b.object, "build").?, sb.build)) {
                b.* = value;
                replaced = true;
            }
        }
        if (!replaced) try builds.append(value);
    }
    std.mem.sort(std.json.Value, builds.items, {}, lessBuild);
    var result = line;
    const primary = builds.items[0].object;
    for ([_][]const u8{ "build", "requires_mojo", "files" }) |key| try result.put(key, primary.get(key).?);
    try result.put("builds", .{ .array = std.json.Array.fromOwnedSlice(arena, builds.items) });
    return .{ .object = result };
}

fn sameVersion(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const x = resolve.semverOf(a) orelse return false;
    const y = resolve.semverOf(b) orelse return false;
    return semver.compare(x, y) == .eq;
}

/// Why the registry's `records` of the package already hold a build of the staged version with other bytes (a
/// different file, or another set of files), or null. The registry never replaces a published file, so a staged build
/// that differs from the registry's build of the same name cannot be what the registry gives once it is published.
/// A staged build the registry's version lacks is an addition and a build only the registry has is untouched: neither
/// is a difference.
pub fn registryDiffers(arena: Allocator, dir: []const u8, m: *const Member, records: []const resolve.Record) Allocator.Error!?[]const u8 {
    for (records) |r| {
        if (!sameVersion(r.version, m.version)) continue;
        for (m.builds) |staged| {
            for (r.builds) |held| {
                if (!std.mem.eql(u8, held.build, staged.build)) continue;
                if (try buildDiffers(arena, dir, m, staged, held)) |why| return why;
            }
        }
    }
    return null;
}

/// Why the staged build `staged` is not the registry's `held` build of the same name, or null when it is.
fn buildDiffers(arena: Allocator, dir: []const u8, m: *const Member, staged: resolve.Build, held: resolve.Build) Allocator.Error!?[]const u8 {
    for (staged.files) |f| {
        var found = false;
        for (held.files) |g| {
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
    if (held.files.len != staged.files.len) {
        return try std.fmt.allocPrint(arena, "{s} {s} is staged in {s} with {d} files of {s}, and the registry already holds that build with {d}; a published version cannot be replaced, so the staged one needs a new version", .{ m.name, m.version, dir, staged.files.len, staged.build, held.files.len });
    }
    return null;
}

fn holdsBuild(m: *const Member, build: []const u8) bool {
    for (m.builds) |b| {
        if (std.mem.eql(u8, b.build, build)) return true;
    }
    return false;
}

/// The channels whose repodata.json the registry has to be asked for, each as `<namespace>/<subdir>`: those of the files
/// of the build each picked version has for the Mojo, unless the set holds that build (a version the set adds a build to
/// has other builds that only the registry holds).
pub fn registrySubdirs(arena: Allocator, ov: Overlay, res: resolve.Resolution) Allocator.Error![]const []const u8 {
    var out = std.ArrayList([]const u8).init(arena);
    for (res.packages) |p| {
        const build = p.record.buildFor(res.mojo) orelse continue;
        if (ov.member(p.record.name)) |m| {
            if (sameVersion(m.version, p.record.version) and holdsBuild(m, build.build)) continue;
        }
        for (build.files) |f| {
            const key = try std.fmt.allocPrint(arena, "{s}/{s}", .{ names.namespaceOf(p.record.name), f.subdir });
            if (!contains(out.items, key)) try out.append(key);
        }
    }
    return out.items;
}

/// The resolver's source of index files: a staged package from the set (merged into the registry's record of its version
/// when the registry holds that version), anything else from `Inner` (the registry's), and `asked` set when `Inner`
/// answered. For a staged package a registry that cannot be read (no network, a refusal) is not an error: the staged
/// line is used alone and `asked` is left as it was, so a closure the set holds whole still needs no registry.
pub fn Index(comptime Inner: type) type {
    return struct {
        overlay: *const Overlay,
        inner: Inner,
        asked: *bool,

        pub fn fetch(self: @This(), arena: Allocator, name: []const u8, diag: *resolve.Diagnostic) resolve.Error!?[]const u8 {
            const m = self.overlay.member(name) orelse {
                self.asked.* = true;
                return self.inner.fetch(arena, name, diag);
            };
            const held = self.inner.fetch(arena, name, diag) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ResolveFailed => {
                    diag.* = .{};
                    return try indexText(arena, m);
                },
            };
            self.asked.* = true;
            return try mergedIndexText(arena, m, held orelse return try indexText(arena, m));
        }
    };
}

/// The lock builder's channel: the staged files' entries (merged into `Inner`'s repodata.json for the
/// `<namespace>/<subdir>` channels listed in `registry_subdirs`, the only ones `Inner` is asked about) and their bytes.
/// `Inner` is a `plan.buildLock` channel: `fetch(arena, namespace, subdir, diag)`, `fetchConda(arena, namespace, subdir, filename, diag)`.
pub fn Channel(comptime Inner: type) type {
    return struct {
        overlay: *const Overlay,
        inner: Inner,
        registry_subdirs: []const []const u8,

        pub fn fetch(self: @This(), arena: Allocator, namespace: []const u8, subdir: []const u8, diag: *resolve.Diagnostic) resolve.Error![]const u8 {
            var why: []const u8 = "";
            const key = try std.fmt.allocPrint(arena, "{s}/{s}", .{ namespace, subdir });
            const held: ?[]const u8 = if (contains(self.registry_subdirs, key)) try self.inner.fetch(arena, namespace, subdir, diag) else null;
            return self.overlay.repodata(arena, namespace, subdir, held, &why) catch |e| switch (e) {
                error.Refused => return resolve.fail(arena, diag, .bad_channel, "{s}", .{why}),
                error.OutOfMemory => return error.OutOfMemory,
            };
        }

        pub fn fetchConda(self: @This(), arena: Allocator, namespace: []const u8, subdir: []const u8, filename: []const u8, diag: *resolve.Diagnostic) resolve.Error![]const u8 {
            var why: []const u8 = "";
            const bytes = self.overlay.fileBytes(arena, subdir, filename, &why) catch |e| switch (e) {
                error.Refused => return resolve.fail(arena, diag, .bad_channel, "{s}", .{why}),
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (bytes) |b| return b;
            return self.inner.fetchConda(arena, namespace, subdir, filename, diag);
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
    if (version == .integer and version.integer == 1) {
        return refuse(arena, why, "{s}/plan.json is version 1 (it predates namespaces); stage the set again", .{dir_path});
    }
    if (version != .integer or version.integer != 2) {
        return refuse(arena, why, "{s}/plan.json: this mopm reads plan version 2", .{dir_path});
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
        if (try names.fullNameProblem(arena, "package name", name, .refuse)) |problem| {
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

        var m = Member{ .name = name, .version = ver, .deps = &.{}, .native = &.{}, .builds = &.{} };
        var files = std.ArrayList(resolve.File).init(arena);
        var staged_builds = std.ArrayList(StagedBuild).init(arena);
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

            // The name says the build: mojo-<namespace>.<name>-<version>-<build>.conda, and the build mojo<compiler>_0.
            const conda_name = try names.condaName(arena, name);
            const head = try std.fmt.allocPrint(arena, "{s}-{s}-", .{ conda_name, ver });
            if (!std.mem.startsWith(u8, filename, head) or !std.mem.endsWith(u8, filename, ".conda")) {
                return refuse(arena, why, "{s}/plan.json: {s} is not a file of {s} {s} ({s}-{s}-<build>.conda)", .{ dir_path, filename, name, ver, conda_name, ver });
            }
            const build = filename[head.len .. filename.len - ".conda".len];
            const compiler = resolve.compilerOfBuild(build) orelse {
                return refuse(arena, why, "{s}/plan.json: the build {s} of {s} is not mojo<compiler>_0", .{ dir_path, build, filename });
            };
            var known = false;
            for (staged_builds.items) |sb| known = known or std.mem.eql(u8, sb.build, build);
            if (!known) try staged_builds.append(.{ .build = build, .compiler = compiler });

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
            const meta_path = try std.fmt.allocPrint(sa, "lib/mojo/{s}.mopm.json", .{names.importName(name)});
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
        const stem = try std.fmt.allocPrint(arena, "{s}-{s}-", .{ try names.condaName(arena, name), ver });
        m.builds = try groupBuilds(arena, staged_builds.items, files.items, stem);
        try members.append(m);
    }
    return .{ .dir = dir_path, .members = members.items };
}

const StagedBuild = struct { build: []const u8, compiler: []const u8 };

fn lessStaged(_: void, a: StagedBuild, b: StagedBuild) bool {
    return resolve.lessCompiler({}, a.compiler, b.compiler);
}

/// The builds of a staged version: one per build of `staged`, by compiler version, each with those of `files` named
/// `<stem><build>.conda`.
fn groupBuilds(arena: Allocator, staged: []StagedBuild, files: []const resolve.File, stem: []const u8) Allocator.Error![]const resolve.Build {
    std.mem.sort(StagedBuild, staged, {}, lessStaged);
    const out = try arena.alloc(resolve.Build, staged.len);
    for (staged, out) |sb, *b| {
        const want = try std.fmt.allocPrint(arena, "{s}{s}.conda", .{ stem, sb.build });
        var mine = std.ArrayList(resolve.File).init(arena);
        for (files) |f| {
            if (std.mem.eql(u8, f.filename, want)) try mine.append(f);
        }
        b.* = .{ .build = sb.build, .requires_mojo = try std.fmt.allocPrint(arena, "=={s}", .{sb.compiler}), .files = mine.items };
    }
    return out;
}
