//! Unpacking one `.conda` package into a directory, without conda, pixi or a
//! shell.
//!
//! A `.conda` is a zip of stored (method 0) entries: `metadata.json`,
//! `info-<stem>.tar.zst` (the package's `info/` directory) and
//! `pkg-<stem>.tar.zst` (the files to install). `install` reads `info/` first
//! (`index.json`, `paths.json`, `link.json`), then streams the files out of
//! `pkg-` into `dest`, so a 400 MB package is never held in memory. For each
//! file:
//!
//!   - a `paths.json` entry with a `prefix_placeholder` is rewritten to name
//!     `Options.prefix` (core/conda_prefix.zig: text and binary), then written;
//!   - the permission bits of the tar header are kept (the exec bit matters);
//!   - symbolic links are created as they are; hard links become copies;
//!   - the sha256 of what was written is recorded, for the conda-meta record.
//!
//! Noarch python packages are laid out the way conda does: `site-packages/`
//! goes below `lib/python<M.m>/site-packages/`, `python-scripts/` below `bin/`,
//! and each entry point of `info/link.json` becomes a script in `bin/` run by
//! the environment's python. `.pyc` files are not precompiled; python writes
//! them when it imports a module.
//!
//! What it refuses (an error and a message, never a guess): a post-link,
//! pre-link or pre-unlink script (mopm runs no scripts); a path that is
//! absolute, holds `..`, or goes below a symbolic link the install made; a zip
//! that is encrypted, compressed, zip64 or has no `info`/`pkg` pair; a prefix
//! longer than a binary placeholder. Activation scripts (`etc/conda/activate.d`)
//! are installed but never run.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const tar_read = @import("tar_read.zig");
const prefix_mod = @import("conda_prefix.zig");

/// The size of the zstd window buffer `install` needs: conda packages use
/// windows of up to 8 MiB (zstd level 19) and mopm accepts up to 64 MiB.
pub const window_size = 64 << 20;

pub const Diag = struct { message: []const u8 = "" };

pub const Options = struct {
    /// The absolute path the environment will have once installed: prefix
    /// placeholders become this. (The files are written to `dest`, which may
    /// be a temporary directory that is renamed to `prefix` afterwards.)
    prefix: []const u8,
    dest: std.fs.Dir,
    /// The zstd window buffer, `window_size` bytes (shared by all packages).
    window: []u8,
    /// The python of the environment as "MAJOR.MINOR", for noarch python
    /// packages; null when the environment has none.
    python: ?[]const u8 = null,
    /// Directories of `dest` that are symbolic links the install made, so no
    /// later path can go through one. One map for the whole environment.
    links: *std.StringHashMap(void),
    /// Run `codesign` on a Mach-O file whose bytes were rewritten (macOS only).
    codesign: bool = builtin.os.tag == .macos,
};

pub const PathEntry = struct {
    path: []const u8,
    kind: enum { file, softlink, directory },
    size: u64,
    /// The sha256 `paths.json` gives, or "".
    sha256: []const u8,
    /// The sha256 of what was written ("" for a link or a directory).
    sha256_in_prefix: []const u8,
    placeholder: []const u8,
    file_mode: []const u8,
};

pub const Installed = struct {
    name: []const u8,
    version: []const u8,
    build: []const u8,
    build_number: u64,
    subdir: []const u8,
    depends: []const []const u8,
    /// `index.json`, for the fields the record passes on.
    index: std.json.Value,
    /// Everything written, in the order written.
    paths: []const PathEntry,
};

// ------------------------------------------------------------------ zip

const ZipEntry = struct { name: []const u8, offset: u64, size: u64 };

fn rd(comptime T: type, b: []const u8, at: usize) T {
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}

/// Reads exactly `buf.len` bytes at `offset`.
fn preadExact(file: std.fs.File, buf: []u8, offset: u64) !void {
    const n = try file.preadAll(buf, offset);
    if (n != buf.len) return error.UnexpectedEndOfStream;
}

/// The entries of the zip in `file`; only stored, unencrypted, non-zip64.
fn readZip(arena: Allocator, file: std.fs.File, diag: *Diag) ![]ZipEntry {
    const size = try file.getEndPos();
    const tail_len: usize = @intCast(@min(size, 22 + 65535));
    const tail = try arena.alloc(u8, tail_len);
    try preadExact(file, tail, size - tail_len);
    var found: ?usize = null;
    var i: usize = if (tail_len >= 22) tail_len - 22 + 1 else 0;
    while (i > 0) {
        i -= 1;
        if (rd(u32, tail, i) == 0x06054b50) {
            found = i;
            break;
        }
    }
    const at = found orelse {
        diag.message = "not a zip (no end-of-central-directory record)";
        return error.BadConda;
    };
    const count = rd(u16, tail, at + 10);
    const cd_size = rd(u32, tail, at + 12);
    const cd_off = rd(u32, tail, at + 16);
    if (count == 0xFFFF or cd_size == 0xFFFFFFFF or cd_off == 0xFFFFFFFF) {
        diag.message = "a zip64 archive; mopm does not read those";
        return error.BadConda;
    }
    if (@as(u64, cd_off) + cd_size > size) {
        diag.message = "the zip's central directory is outside the file";
        return error.BadConda;
    }
    const cd = try arena.alloc(u8, cd_size);
    try preadExact(file, cd, cd_off);
    var out = std.ArrayList(ZipEntry).init(arena);
    var p: usize = 0;
    for (0..count) |_| {
        if (p + 46 > cd.len or rd(u32, cd, p) != 0x02014b50) {
            diag.message = "the zip's central directory is damaged";
            return error.BadConda;
        }
        const flags = rd(u16, cd, p + 8);
        const method = rd(u16, cd, p + 10);
        const csize = rd(u32, cd, p + 20);
        const usize_ = rd(u32, cd, p + 24);
        const name_len = rd(u16, cd, p + 28);
        const extra_len = rd(u16, cd, p + 30);
        const comment_len = rd(u16, cd, p + 32);
        const lho = rd(u32, cd, p + 42);
        if (p + 46 + name_len > cd.len) {
            diag.message = "the zip's central directory is damaged";
            return error.BadConda;
        }
        const name = try arena.dupe(u8, cd[p + 46 ..][0..name_len]);
        if (flags & 1 != 0 or method != 0 or csize != usize_) {
            diag.message = try std.fmt.allocPrint(arena, "{s} in the zip is encrypted or compressed; a .conda stores its entries", .{name});
            return error.BadConda;
        }
        var local: [30]u8 = undefined;
        try preadExact(file, &local, lho);
        if (rd(u32, &local, 0) != 0x04034b50) {
            diag.message = "a local header of the zip is damaged";
            return error.BadConda;
        }
        const data = @as(u64, lho) + 30 + rd(u16, &local, 26) + rd(u16, &local, 28);
        if (data + csize > size) {
            diag.message = "an entry of the zip runs past the end of the file";
            return error.BadConda;
        }
        try out.append(.{ .name = name, .offset = data, .size = csize });
        p += 46 + name_len + extra_len + comment_len;
    }
    return out.items;
}

// ------------------------------------------------------------- the install

const BufFile = std.io.BufferedReader(64 * 1024, std.fs.File.Reader);

const Mode = enum { info, pkg };

/// `p` without leading `./` pieces (a leading `.` of a name like `.condarc` stays).
fn stripDotSlash(p: []const u8) []const u8 {
    var s = p;
    while (std.mem.startsWith(u8, s, "./")) s = s[2..];
    return s;
}

const PathMeta = struct { placeholder: []const u8, file_mode: []const u8, sha256: []const u8, size: u64, kind: []const u8 };

const Unpacker = struct {
    arena: Allocator,
    opts: Options,
    diag: *Diag,
    // From info/.
    index_text: ?[]const u8 = null,
    paths_text: ?[]const u8 = null,
    link_text: ?[]const u8 = null,
    // Derived.
    metas: std.StringHashMap(PathMeta),
    noarch_python: bool = false,
    entry_points: []const []const u8 = &.{},
    written: std.ArrayList(PathEntry),

    fn fail(self: *Unpacker, err: anyerror, comptime fmt: []const u8, args: anytype) anyerror {
        self.diag.message = std.fmt.allocPrint(self.arena, fmt, args) catch "out of memory";
        return err;
    }

    fn readAllText(self: *Unpacker, tr: anytype, e: tar_read.Entry) ![]u8 {
        if (e.size > 64 << 20) return self.fail(error.BadConda, "{s} is {d} bytes; too large for an info file", .{ e.name, e.size });
        const buf = try self.arena.alloc(u8, @intCast(e.size));
        var got: usize = 0;
        while (got < buf.len) {
            const n = try tr.read(buf[got..]);
            if (n == 0) return error.UnexpectedEndOfStream;
            got += n;
        }
        return buf;
    }

    fn infoEntry(self: *Unpacker, tr: anytype, e: tar_read.Entry) !void {
        if (e.kind != .file) return;
        const name = stripDotSlash(e.name);
        if (std.mem.eql(u8, name, "info/index.json")) {
            self.index_text = try self.readAllText(tr, e);
        } else if (std.mem.eql(u8, name, "info/paths.json")) {
            self.paths_text = try self.readAllText(tr, e);
        } else if (std.mem.eql(u8, name, "info/link.json")) {
            self.link_text = try self.readAllText(tr, e);
        }
    }

    /// Where the package's `rel` goes in the environment.
    fn mapPath(self: *Unpacker, rel: []const u8) ![]const u8 {
        if (!self.noarch_python) return rel;
        const site = "site-packages/";
        const scripts = "python-scripts/";
        if (std.mem.startsWith(u8, rel, site)) {
            const py = self.opts.python orelse return self.fail(error.NoPython, "a noarch python package, but the environment has no python", .{});
            return std.fmt.allocPrint(self.arena, "lib/python{s}/site-packages/{s}", .{ py, rel[site.len..] });
        }
        if (std.mem.startsWith(u8, rel, scripts)) {
            return std.fmt.allocPrint(self.arena, "bin/{s}", .{rel[scripts.len..]});
        }
        return rel;
    }

    /// A relative path that stays inside the environment, else an error.
    fn safe(self: *Unpacker, rel: []const u8) !void {
        if (rel.len == 0 or rel[0] == '/' or std.mem.indexOfScalar(u8, rel, 0) != null or std.mem.indexOfScalar(u8, rel, '\\') != null)
            return self.fail(error.UnsafePath, "the package holds the path '{s}', which is not a relative path inside the environment", .{rel});
        var it = std.mem.splitScalar(u8, rel, '/');
        var prefix_end: usize = 0;
        while (it.next()) |comp| {
            if (std.mem.eql(u8, comp, "..") or (comp.len == 0 and it.peek() != null))
                return self.fail(error.UnsafePath, "the package holds the path '{s}', which is not a relative path inside the environment", .{rel});
            prefix_end += comp.len;
            // No component may be a symbolic link the install made.
            if (it.peek() != null and self.opts.links.contains(rel[0..prefix_end]))
                return self.fail(error.UnsafePath, "the package writes '{s}' below the symbolic link '{s}'", .{ rel, rel[0..prefix_end] });
            prefix_end += 1;
        }
    }

    /// True when the symbolic link `rel` -> `target` may lead out of the
    /// environment: an absolute target, one that climbs above the root, or one
    /// that goes through a link that does. Nothing is written below such a link.
    fn linkEscapes(self: *Unpacker, rel: []const u8, target: []const u8) !bool {
        if (target.len == 0 or target[0] == '/') return true;
        var parts = std.ArrayList([]const u8).init(self.arena);
        if (std.fs.path.dirname(rel)) |d| {
            var dit = std.mem.splitScalar(u8, d, '/');
            while (dit.next()) |c| {
                if (c.len > 0 and !std.mem.eql(u8, c, ".")) try parts.append(c);
            }
        }
        var it = std.mem.splitScalar(u8, target, '/');
        while (it.next()) |c| {
            if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
            if (std.mem.eql(u8, c, "..")) {
                if (parts.items.len == 0) return true;
                _ = parts.pop();
                continue;
            }
            try parts.append(c);
            const joined = try std.mem.join(self.arena, "/", parts.items);
            if (self.opts.links.contains(joined)) return true;
        }
        return false;
    }

    fn isLinkScript(rel: []const u8) bool {
        const base = std.fs.path.basename(rel);
        if (std.mem.startsWith(u8, base, ".")) {
            for ([_][]const u8{ "-post-link.sh", "-pre-link.sh", "-pre-unlink.sh", "-post-link.bat", "-pre-link.bat", "-pre-unlink.bat" }) |suffix| {
                if (std.mem.endsWith(u8, base, suffix)) return true;
            }
        }
        return false;
    }

    fn ensureParent(self: *Unpacker, rel: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try self.opts.dest.makePath(d);
    }

    fn record(self: *Unpacker, p: PathEntry) !void {
        try self.written.append(p);
    }

    fn pkgEntry(self: *Unpacker, tr: anytype, e: tar_read.Entry) !void {
        const orig = stripDotSlash(e.name);
        if (orig.len == 0) return;
        if (isLinkScript(orig))
            return self.fail(error.LinkScript, "the package holds '{s}', a link script; mopm runs no scripts and so cannot install it", .{orig});
        // Entry names are slices of the tar reader's buffer, valid until its next entry: keep a copy.
        const rel = try self.arena.dupe(u8, try self.mapPath(orig));
        try self.safe(rel);
        const dest = self.opts.dest;
        switch (e.kind) {
            .dir => try dest.makePath(rel),
            .symlink => {
                try self.ensureParent(rel);
                dest.deleteFile(rel) catch {};
                try dest.symLink(e.link, rel, .{});
                if (try self.linkEscapes(rel, e.link)) {
                    try self.opts.links.put(try self.opts.links.allocator.dupe(u8, rel), {});
                }
                const m = self.metas.get(orig);
                try self.record(.{ .path = rel, .kind = .softlink, .size = 0, .sha256 = if (m) |x| x.sha256 else "", .sha256_in_prefix = "", .placeholder = "", .file_mode = "" });
            },
            .hardlink => {
                const target = try self.mapPath(stripDotSlash(e.link));
                try self.safe(target);
                try self.ensureParent(rel);
                dest.deleteFile(rel) catch {};
                try dest.copyFile(target, dest, rel, .{});
                const m = self.metas.get(orig);
                try self.record(.{ .path = rel, .kind = .file, .size = e.size, .sha256 = if (m) |x| x.sha256 else "", .sha256_in_prefix = "", .placeholder = "", .file_mode = "" });
            },
            .file => try self.writeFile(tr, e, orig, rel),
        }
    }

    fn writeFile(self: *Unpacker, tr: anytype, e: tar_read.Entry, orig: []const u8, rel: []const u8) !void {
        const dest = self.opts.dest;
        try self.ensureParent(rel);
        dest.deleteFile(rel) catch {};
        const perm: u32 = if (e.mode & 0o111 != 0) 0o755 else 0o644;
        const file = try dest.createFile(rel, .{ .mode = @intCast(perm) });
        defer file.close();
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        const meta = self.metas.get(orig);
        const placeholder: []const u8 = if (meta) |m| m.placeholder else "";
        var rewritten = false;
        if (placeholder.len > 0) {
            if (e.size > 1 << 30) return self.fail(error.BadConda, "{s} is {d} bytes; too large to rewrite", .{ orig, e.size });
            const gpa = std.heap.page_allocator;
            const data = try gpa.alloc(u8, @intCast(e.size));
            defer gpa.free(data);
            var got: usize = 0;
            while (got < data.len) {
                const n = try tr.read(data[got..]);
                if (n == 0) return error.UnexpectedEndOfStream;
                got += n;
            }
            const binary = if (meta) |m| std.mem.eql(u8, m.file_mode, "binary") else false;
            if (binary) {
                const n = prefix_mod.rewriteBinary(data, placeholder, self.opts.prefix) catch |err| switch (err) {
                    error.PrefixTooLong => return self.fail(error.PrefixTooLong, "{s}: the install prefix {s} is longer than the {d}-byte placeholder in this binary file", .{ orig, self.opts.prefix, placeholder.len }),
                };
                rewritten = n > 0;
                hasher.update(data);
                try file.writeAll(data);
            } else {
                const replaced = try prefix_mod.replaceAll(gpa, data, placeholder, self.opts.prefix);
                defer gpa.free(replaced);
                const fixed = try prefix_mod.fixShebang(gpa, replaced);
                defer {
                    if (fixed.ptr != replaced.ptr) gpa.free(fixed);
                }
                hasher.update(fixed);
                try file.writeAll(fixed);
            }
        } else {
            var buf: [64 * 1024]u8 = undefined;
            while (true) {
                const n = try tr.read(&buf);
                if (n == 0) break;
                hasher.update(buf[0..n]);
                try file.writeAll(buf[0..n]);
            }
        }
        try file.chmod(@intCast(perm));
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const hex = try self.arena.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
        try self.record(.{
            .path = rel,
            .kind = .file,
            .size = e.size,
            .sha256 = if (meta) |m| m.sha256 else "",
            .sha256_in_prefix = hex,
            .placeholder = placeholder,
            .file_mode = if (meta) |m| m.file_mode else "",
        });
        if (rewritten and self.opts.codesign) try self.codesign(rel);
    }

    /// Re-signs a Mach-O file after its bytes changed: Apple silicon kills a
    /// process whose binary's signature no longer matches.
    fn codesign(self: *Unpacker, rel: []const u8) !void {
        const abs = try self.opts.dest.realpathAlloc(self.arena, rel);
        var child = std.process.Child.init(&.{ "codesign", "--force", "--sign", "-", abs }, self.arena);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        const term = child.spawnAndWait() catch |err|
            return self.fail(err, "cannot run codesign on {s}: {s}", .{ rel, @errorName(err) });
        switch (term) {
            .Exited => |c| if (c == 0) return,
            else => {},
        }
        return self.fail(error.CodesignFailed, "codesign failed on {s}", .{rel});
    }

    /// One `bin/<name>` script per noarch python entry point
    /// (`name = module:function`), run by the environment's python.
    fn writeEntryPoints(self: *Unpacker) !void {
        for (self.entry_points) |ep| {
            const eq = std.mem.indexOfScalar(u8, ep, '=') orelse return self.fail(error.BadConda, "entry point '{s}' has no '='", .{ep});
            const name = std.mem.trim(u8, ep[0..eq], " ");
            const target = std.mem.trim(u8, ep[eq + 1 ..], " ");
            const colon = std.mem.indexOfScalar(u8, target, ':') orelse return self.fail(error.BadConda, "entry point '{s}' has no ':'", .{ep});
            const module = target[0..colon];
            const func = target[colon + 1 ..];
            const head = func[0 .. std.mem.indexOfScalar(u8, func, '.') orelse func.len];
            const script = try std.fmt.allocPrint(self.arena,
                \\#!{s}/bin/python
                \\# -*- coding: utf-8 -*-
                \\import re
                \\import sys
                \\
                \\from {s} import {s}
                \\
                \\if __name__ == '__main__':
                \\    sys.argv[0] = re.sub(r'(-script\.pyw|\.exe)?$', '', sys.argv[0])
                \\    sys.exit({s}())
                \\
            , .{ self.opts.prefix, module, head, func });
            const fixed = try prefix_mod.fixShebang(self.arena, script);
            const rel = try std.fmt.allocPrint(self.arena, "bin/{s}", .{name});
            try self.safe(rel);
            try self.ensureParent(rel);
            self.opts.dest.deleteFile(rel) catch {};
            const file = try self.opts.dest.createFile(rel, .{ .mode = 0o755 });
            defer file.close();
            try file.writeAll(fixed);
            try file.chmod(0o755);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(fixed, &digest, .{});
            try self.record(.{ .path = rel, .kind = .file, .size = fixed.len, .sha256 = "", .sha256_in_prefix = try self.arena.dupe(u8, &std.fmt.bytesToHex(digest, .lower)), .placeholder = "", .file_mode = "" });
        }
    }

    /// Streams one tar entry of the zip through zstd and the tar reader.
    fn run(self: *Unpacker, file: std.fs.File, entry: ZipEntry, mode: Mode) !void {
        try file.seekTo(entry.offset);
        var buffered = BufFile{ .unbuffered_reader = file.reader() };
        var limited = std.io.limitedReader(buffered.reader(), entry.size);
        var zs = std.compress.zstd.decompressor(limited.reader(), .{ .window_buffer = self.opts.window });
        var tr = tar_read.tarReader(zs.reader());
        while (try tr.next()) |e| {
            switch (mode) {
                .info => try self.infoEntry(&tr, e),
                .pkg => try self.pkgEntry(&tr, e),
            }
        }
    }
};

fn jsonStr(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

/// Unpacks the `.conda` in `file` according to `opts`. On an error `diag`
/// says why, when mopm has more to say than the error's name.
pub fn install(arena: Allocator, file: std.fs.File, opts: Options, diag: *Diag) !Installed {
    const entries = try readZip(arena, file, diag);
    var info: ?ZipEntry = null;
    var pkg: ?ZipEntry = null;
    for (entries) |e| {
        if (std.mem.startsWith(u8, e.name, "info-") and std.mem.endsWith(u8, e.name, ".tar.zst")) info = e;
        if (std.mem.startsWith(u8, e.name, "pkg-") and std.mem.endsWith(u8, e.name, ".tar.zst")) pkg = e;
    }
    if (info == null or pkg == null) {
        diag.message = "the zip has no info-*.tar.zst and pkg-*.tar.zst pair: not a .conda (format 2)";
        return error.BadConda;
    }

    var u = Unpacker{
        .arena = arena,
        .opts = opts,
        .diag = diag,
        .metas = std.StringHashMap(PathMeta).init(arena),
        .written = std.ArrayList(PathEntry).init(arena),
    };
    try u.run(file, info.?, .info);

    const index_text = u.index_text orelse return u.fail(error.BadConda, "the package has no info/index.json", .{});
    const index = std.json.parseFromSliceLeaky(std.json.Value, arena, index_text, .{}) catch
        return u.fail(error.BadConda, "info/index.json is not JSON", .{});
    if (index != .object) return u.fail(error.BadConda, "info/index.json is not an object", .{});
    const name = jsonStr(index.object.get("name")) orelse return u.fail(error.BadConda, "info/index.json has no name", .{});
    const version = jsonStr(index.object.get("version")) orelse return u.fail(error.BadConda, "info/index.json has no version", .{});
    const build = jsonStr(index.object.get("build")) orelse return u.fail(error.BadConda, "info/index.json has no build", .{});
    const build_number: u64 = if (index.object.get("build_number")) |b| (if (b == .integer and b.integer >= 0) @intCast(b.integer) else 0) else 0;
    var depends = std.ArrayList([]const u8).init(arena);
    if (index.object.get("depends")) |d| {
        if (d == .array) {
            for (d.array.items) |x| {
                if (x == .string) try depends.append(x.string);
            }
        }
    }

    // noarch python?
    if (index.object.get("noarch")) |n| {
        if (n == .string and std.mem.eql(u8, n.string, "python")) u.noarch_python = true;
    }
    if (u.link_text) |text| {
        const link = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
            return u.fail(error.BadConda, "info/link.json is not JSON", .{});
        const noarch: ?std.json.Value = if (link == .object) link.object.get("noarch") else null;
        if (noarch != null and noarch.? == .object) {
            if (jsonStr(noarch.?.object.get("type"))) |t| {
                if (std.mem.eql(u8, t, "python")) u.noarch_python = true;
            }
            const eps: ?std.json.Value = noarch.?.object.get("entry_points");
            if (eps != null and eps.? == .array) {
                var list = std.ArrayList([]const u8).init(arena);
                for (eps.?.array.items) |x| {
                    if (x == .string) try list.append(x.string);
                }
                u.entry_points = list.items;
            }
        }
    }

    if (u.paths_text) |text| {
        const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
            return u.fail(error.BadConda, "info/paths.json is not JSON", .{});
        const list = if (doc == .object) doc.object.get("paths") else null;
        if (list == null or list.? != .array) return u.fail(error.BadConda, "info/paths.json has no paths array", .{});
        for (list.?.array.items) |p| {
            if (p != .object) continue;
            const path = jsonStr(p.object.get("_path")) orelse continue;
            try u.metas.put(path, .{
                .placeholder = jsonStr(p.object.get("prefix_placeholder")) orelse "",
                .file_mode = jsonStr(p.object.get("file_mode")) orelse "",
                .sha256 = jsonStr(p.object.get("sha256")) orelse "",
                .size = if (p.object.get("size_in_bytes")) |s| (if (s == .integer and s.integer >= 0) @intCast(s.integer) else 0) else 0,
                .kind = jsonStr(p.object.get("path_type")) orelse "",
            });
        }
    }

    try u.run(file, pkg.?, .pkg);
    if (u.noarch_python) try u.writeEntryPoints();

    return .{
        .name = name,
        .version = version,
        .build = build,
        .build_number = build_number,
        .subdir = jsonStr(index.object.get("subdir")) orelse "",
        .depends = depends.items,
        .index = index,
        .paths = u.written.items,
    };
}

// ---------------------------------------------------------------- tests

const fx = @import("conda_fixture.zig");

const TestEnv = struct {
    tmp: std.testing.TmpDir,
    window: []u8,
    links: std.StringHashMap(void),
    dest: std.fs.Dir,

    fn init(a: Allocator) !TestEnv {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.makeDir("env");
        const dest = try tmp.dir.openDir("env", .{});
        return .{
            .tmp = tmp,
            .window = try std.testing.allocator.alloc(u8, window_size),
            .links = std.StringHashMap(void).init(a),
            .dest = dest,
        };
    }

    fn deinit(self: *TestEnv) void {
        self.dest.close();
        std.testing.allocator.free(self.window);
        self.tmp.cleanup();
    }

    /// Unpacks `bytes` into `env/` with the prefix `/opt/env`.
    fn unpackBytes(self: *TestEnv, a: Allocator, bytes: []const u8, python: ?[]const u8, diag: *Diag) !Installed {
        try self.tmp.dir.writeFile("p.conda", bytes);
        const f = try self.tmp.dir.openFile("p.conda", .{});
        defer f.close();
        return install(a, f, .{
            .prefix = "/opt/env",
            .dest = self.dest,
            .window = self.window,
            .python = python,
            .links = &self.links,
            .codesign = false,
        }, diag);
    }

    fn read(self: *TestEnv, a: Allocator, path: []const u8) ![]u8 {
        return self.dest.readFileAlloc(a, path, 1 << 20);
    }
};

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "unpack: placeholders, modes, links and the record, byte for byte" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var env = try TestEnv.init(a);
    defer env.deinit();

    const ph = fx.placeholder;
    const script_in = "#!" ++ ph ++ "/bin/python\nprefix=" ++ ph ++ "\n";
    const lib_in = "\x7fELF\x00" ++ ph ++ "/lib\x00after\x00";
    const paths = try std.fmt.allocPrint(a,
        \\{{"paths_version":1,"paths":[
        \\{{"_path":"bin/run","path_type":"hardlink","file_mode":"text","prefix_placeholder":"{s}","sha256":"x","size_in_bytes":{d}}},
        \\{{"_path":"lib/libdemo.so","path_type":"hardlink","file_mode":"binary","prefix_placeholder":"{s}","sha256":"y","size_in_bytes":{d}}},
        \\{{"_path":"bin/tool","path_type":"hardlink","sha256":"z","size_in_bytes":18}},
        \\{{"_path":"bin/alias","path_type":"softlink","sha256":"w","size_in_bytes":3}}
        \\]}}
    , .{ ph, script_in.len, ph, lib_in.len });
    const idx = try fx.indexJson(a, "demo", "1.0", "h0_0", "\"libfoo >=1\"", "");
    const bytes = try fx.conda2(a, "demo-1.0-h0_0", &.{
        .{ .name = "info/index.json", .data = idx },
        .{ .name = "info/paths.json", .data = paths },
        .{ .name = "info/about.json", .data = "{}" },
    }, &.{
        .{ .name = "bin/run", .data = script_in, .mode = 0o755 },
        .{ .name = "lib/libdemo.so", .data = lib_in, .mode = 0o755 },
        .{ .name = "bin/tool", .data = "#!/bin/sh\necho hi\n", .mode = 0o750 },
        .{ .name = "data/readme.txt", .data = "plain\n" },
        .{ .name = ".hidden", .data = "dot\n" },
        .{ .name = "bin/alias", .kind = .symlink, .link = "run", .mode = 0o777 },
        .{ .name = "bin/hard", .kind = .hardlink, .link = "bin/tool", .mode = 0o750 },
        .{ .name = "share/empty/", .kind = .dir, .mode = 0o755 },
    });

    var diag = Diag{};
    const inst = try env.unpackBytes(a, bytes, null, &diag);
    try std.testing.expectEqualStrings("demo", inst.name);
    try std.testing.expectEqualStrings("1.0", inst.version);
    try std.testing.expectEqualStrings("h0_0", inst.build);
    try std.testing.expectEqual(@as(u64, 3), inst.build_number);
    try std.testing.expectEqualStrings("libfoo >=1", inst.depends[0]);

    // Text: every placeholder is the prefix.
    const want_script = "#!/opt/env/bin/python\nprefix=/opt/env\n";
    try std.testing.expectEqualStrings(want_script, try env.read(a, "bin/run"));
    // Binary: the string is rewritten and NUL-padded to its old length; nothing else moves.
    const old_len = ph.len + "/lib".len;
    const want_lib = "\x7fELF\x00" ++ "/opt/env/lib" ++ "\x00" ** (old_len - "/opt/env/lib".len) ++ "\x00after\x00";
    const got_lib = try env.read(a, "lib/libdemo.so");
    try std.testing.expectEqual(lib_in.len, got_lib.len);
    try std.testing.expectEqualSlices(u8, want_lib, got_lib);
    // Untouched files and a dot-file keep their bytes and names.
    try std.testing.expectEqualStrings("plain\n", try env.read(a, "data/readme.txt"));
    try std.testing.expectEqualStrings("dot\n", try env.read(a, ".hidden"));
    try std.testing.expectEqualStrings("#!/bin/sh\necho hi\n", try env.read(a, "bin/tool"));
    // Modes: exec stays exec, plain stays plain.
    for ([_][]const u8{ "bin/run", "lib/libdemo.so", "bin/tool", "bin/hard" }) |p| {
        const s = try env.dest.statFile(p);
        try std.testing.expect(s.mode & 0o111 != 0);
    }
    const plain = try env.dest.statFile("data/readme.txt");
    try std.testing.expect(plain.mode & 0o111 == 0);
    // Links.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("run", try env.dest.readLink("bin/alias", &buf));
    try std.testing.expectEqualStrings("#!/bin/sh\necho hi\n", try env.read(a, "bin/hard"));
    try env.dest.access("share/empty", .{});

    // The record: what was written, with the sha256 of the bytes in the prefix.
    var found = false;
    for (inst.paths) |p| {
        if (std.mem.eql(u8, p.path, "bin/run")) {
            found = true;
            try std.testing.expectEqualStrings(try fx.sha256Hex(a, want_script), p.sha256_in_prefix);
            try std.testing.expectEqualStrings("x", p.sha256);
            try std.testing.expectEqualStrings("text", p.file_mode);
            try std.testing.expectEqualStrings(ph, p.placeholder);
        }
        if (std.mem.eql(u8, p.path, "lib/libdemo.so")) {
            try std.testing.expectEqualStrings(try fx.sha256Hex(a, want_lib), p.sha256_in_prefix);
        }
        if (std.mem.eql(u8, p.path, "bin/alias")) try std.testing.expect(p.kind == .softlink);
    }
    try std.testing.expect(found);
}

test "unpack: a package without paths.json (as mopm pack makes) is copied as it is" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var env = try TestEnv.init(a);
    defer env.deinit();
    const bytes = try fx.simple(a, "plain", "2.0.1", &.{
        .{ .name = "lib/mojo/plain.mojoc", .data = "MOJOC" ++ fx.placeholder },
    });
    var diag = Diag{};
    const inst = try env.unpackBytes(a, bytes, null, &diag);
    try std.testing.expectEqualStrings("plain", inst.name);
    try std.testing.expectEqualStrings("MOJOC" ++ fx.placeholder, try env.read(a, "lib/mojo/plain.mojoc"));
}

test "unpack: a link script is refused, not run" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var env = try TestEnv.init(a);
    defer env.deinit();
    for ([_][]const u8{ "bin/.demo-post-link.sh", "bin/.demo-pre-link.sh", "bin/.demo-pre-unlink.sh" }) |name| {
        const bytes = try fx.simple(a, "demo", "1.0", &.{
            .{ .name = name, .data = "#!/bin/sh\nrm -rf /\n", .mode = 0o755 },
        });
        var diag = Diag{};
        try std.testing.expectError(error.LinkScript, env.unpackBytes(a, bytes, null, &diag));
        try std.testing.expect(std.mem.indexOf(u8, diag.message, "runs no scripts") != null);
    }
}

test "unpack: paths that leave the environment are refused" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var env = try TestEnv.init(a);
    defer env.deinit();
    const bad = [_][]const fx.Item{
        &.{.{ .name = "../evil", .data = "x" }},
        &.{.{ .name = "lib/../../evil", .data = "x" }},
        &.{.{ .name = "/etc/evil", .data = "x" }},
        // A symbolic link out, then a file written through it.
        &.{ .{ .name = "lib64", .kind = .symlink, .link = "/tmp", .mode = 0o777 }, .{ .name = "lib64/evil", .data = "x" } },
        // Climbing out with "..", and a chain through a link that leaves.
        &.{ .{ .name = "up", .kind = .symlink, .link = "../..", .mode = 0o777 }, .{ .name = "up/evil", .data = "x" } },
        &.{
            .{ .name = "y", .kind = .symlink, .link = "/tmp", .mode = 0o777 },
            .{ .name = "x", .kind = .symlink, .link = "y", .mode = 0o777 },
            .{ .name = "x/evil", .data = "x" },
        },
    };
    for (bad) |items| {
        const bytes = try fx.simple(a, "evil", "1.0", items);
        var diag = Diag{};
        try std.testing.expectError(error.UnsafePath, env.unpackBytes(a, bytes, null, &diag));
    }
    try std.testing.expectError(error.FileNotFound, env.dest.access("../evil", .{}));
}

test "unpack: a prefix longer than a binary placeholder is refused" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var env = try TestEnv.init(a);
    defer env.deinit();
    const paths = "{\"paths_version\":1,\"paths\":[{\"_path\":\"lib/x.so\",\"path_type\":\"hardlink\",\"file_mode\":\"binary\",\"prefix_placeholder\":\"/p\"}]}";
    const idx = try fx.indexJson(a, "x", "1", "h0_0", "", "");
    const bytes = try fx.conda2(a, "x-1-h0_0", &.{
        .{ .name = "info/index.json", .data = idx },
        .{ .name = "info/paths.json", .data = paths },
    }, &.{.{ .name = "lib/x.so", .data = "/p/lib\x00" }});
    var diag = Diag{};
    try std.testing.expectError(error.PrefixTooLong, env.unpackBytes(a, bytes, null, &diag));
}

test "unpack: noarch python is laid out in site-packages, with entry points" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var env = try TestEnv.init(a);
    defer env.deinit();
    const idx = try fx.indexJson(a, "mypkg", "0.1", "pyh_0", "", ",\"noarch\":\"python\"");
    const link = "{\"noarch\":{\"type\":\"python\",\"entry_points\":[\"mytool = mypkg.cli:app.main\"]},\"package_metadata_version\":1}";
    const bytes = try fx.conda2(a, "mypkg-0.1-pyh_0", &.{
        .{ .name = "info/index.json", .data = idx },
        .{ .name = "info/link.json", .data = link },
    }, &.{
        .{ .name = "site-packages/mypkg/__init__.py", .data = "x = 1\n" },
        .{ .name = "python-scripts/helper", .data = "#!/bin/sh\n", .mode = 0o755 },
    });
    var diag = Diag{};
    try std.testing.expectError(error.NoPython, env.unpackBytes(a, bytes, null, &diag));

    const inst = try env.unpackBytes(a, bytes, "3.15", &diag);
    try std.testing.expectEqualStrings("mypkg", inst.name);
    try std.testing.expectEqualStrings("x = 1\n", try env.read(a, "lib/python3.15/site-packages/mypkg/__init__.py"));
    try std.testing.expectEqualStrings("#!/bin/sh\n", try env.read(a, "bin/helper"));
    const tool = try env.read(a, "bin/mytool");
    try std.testing.expect(std.mem.startsWith(u8, tool, "#!/opt/env/bin/python\n"));
    try std.testing.expect(std.mem.indexOf(u8, tool, "from mypkg.cli import app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool, "sys.exit(app.main())") != null);
    try std.testing.expect((try env.dest.statFile("bin/mytool")).mode & 0o111 != 0);
}

test "unpack: a zip that is compressed, truncated or not a zip is refused" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var env = try TestEnv.init(a);
    defer env.deinit();
    const idx = try fx.indexJson(a, "x", "1", "h0_0", "", "");
    const ok = try fx.conda2(a, "x-1-h0_0", &.{.{ .name = "info/index.json", .data = idx }}, &.{.{ .name = "f", .data = "1" }});
    var diag = Diag{};
    _ = try env.unpackBytes(a, ok, null, &diag);

    const deflated = try fx.conda2With(a, "x-1-h0_0", &.{.{ .name = "info/index.json", .data = idx }}, &.{.{ .name = "f", .data = "1" }}, 8);
    try std.testing.expectError(error.BadConda, env.unpackBytes(a, deflated, null, &diag));
    try std.testing.expectError(error.BadConda, env.unpackBytes(a, ok[0 .. ok.len - 30], null, &diag));
    try std.testing.expectError(error.BadConda, env.unpackBytes(a, "not a zip at all, but long enough to hold a record", null, &diag));
}

test "unpack: a relative link that stays inside the environment may be written through" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var env = try TestEnv.init(a);
    defer env.deinit();
    const bytes = try fx.simple(a, "lnk", "1.0", &.{
        .{ .name = "lib/", .kind = .dir, .mode = 0o755 },
        .{ .name = "lib64", .kind = .symlink, .link = "lib", .mode = 0o777 },
        .{ .name = "lib64/x.so", .data = "so" },
    });
    var diag = Diag{};
    _ = try env.unpackBytes(a, bytes, null, &diag);
    try std.testing.expectEqualStrings("so", try env.read(a, "lib/x.so"));
}
