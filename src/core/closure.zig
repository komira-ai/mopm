//! The Mojo toolchain as a pre-resolved, pinned closure.
//!
//! `mopm sync` has no dependency solver. For each Mojo version mopm supports
//! and each platform (linux-64, linux-aarch64, osx-arm64) a file lists every
//! conda package the toolchain needs (`mojo`, `mojo-compiler` and everything
//! they depend on, down to the C library's companions), each with the url it
//! is downloaded from, its sha256 and size, and the fields of its conda-meta
//! record. Those files are made by `mopm-closure` from the lock a solver wrote
//! (a pixi lock, made by the `toolchain` job of .github/workflows/kpin-update.yml
//! on GitHub, never on a user's machine) and are committed under
//! src/core/toolchain/. The lock is toolchain/mojo-<version>.pixi.lock.
//!
//! A file is JSON, 2-space indented, keys in the order of `Closure`:
//!
//!   {"format": 1, "mojo": "1.0.0", "subdir": "linux-64",
//!    "channels": [{"name": "conda-forge", "url": "https://.../conda-forge/"}],
//!    "packages": [{"name": ..., "version": ..., "build": ..., "build_number": ...,
//!                  "subdir": "linux-64" | "noarch", "channel": "conda-forge",
//!                  "path": "linux-64/<file>.conda", "sha256": ..., "md5": ...,
//!                  "size": ..., "depends": [...], "constrains": [...],
//!                  "license": ..., "timestamp": ...}]}
//!
//! A package is downloaded from the channel's `url` followed by its `path`.
//! The channel urls are the one place a mirror is named: pointing a channel at
//! the mirror is a one-line change per channel, and no sha256 changes, because
//! the bytes are the same.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testroot = @import("testroot.zig");

pub const format_version: u32 = 1;

/// The platforms a closure is made for.
pub const subdirs = [_][]const u8{ "linux-64", "linux-aarch64", "osx-arm64" };

pub const Channel = struct {
    name: []const u8,
    /// Ends with `/`.
    url: []const u8,
};

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    build: []const u8,
    build_number: u64 = 0,
    /// The conda subdir the file is in: the platform's, or `noarch`.
    subdir: []const u8,
    /// The `name` of one of the closure's channels.
    channel: []const u8,
    /// `<subdir>/<name>-<version>-<build>.conda`, below the channel's url.
    path: []const u8,
    sha256: []const u8,
    md5: []const u8 = "",
    size: u64,
    depends: []const []const u8 = &.{},
    constrains: []const []const u8 = &.{},
    license: []const u8 = "",
    timestamp: u64 = 0,
};

pub const Closure = struct {
    format: u32 = format_version,
    /// The Mojo version this closure is for.
    mojo: []const u8,
    /// The platform.
    subdir: []const u8,
    channels: []const Channel,
    packages: []const Package,
};

/// The file name of a package: the last part of its path.
pub fn fileName(p: Package) []const u8 {
    return std.fs.path.basename(p.path);
}

fn channelUrl(c: Closure, name: []const u8) ?[]const u8 {
    for (c.channels) |ch| {
        if (std.mem.eql(u8, ch.name, name)) return ch.url;
    }
    return null;
}

/// Where `p` is downloaded from: its channel's url and its path.
pub fn urlOf(arena: Allocator, c: Closure, p: Package) ![]u8 {
    const base = channelUrl(c, p.channel) orelse return error.UnknownChannel;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ base, p.path });
}

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |ch| {
        if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return false;
    }
    return true;
}

/// Why `c` cannot be installed from, or null: the checks `mopm sync` relies on
/// (a pinned sha256 and size for every file, no duplicate names, every channel
/// named, only `.conda` files, `mojo` and `mojo-compiler` at the Mojo version).
pub fn problem(arena: Allocator, c: Closure) Allocator.Error!?[]const u8 {
    if (c.format != format_version) return try std.fmt.allocPrint(arena, "format {d}; this mopm reads format {d}", .{ c.format, format_version });
    var known_subdir = false;
    for (subdirs) |s| known_subdir = known_subdir or std.mem.eql(u8, s, c.subdir);
    if (!known_subdir) return try std.fmt.allocPrint(arena, "subdir {s} is not one mopm supports", .{c.subdir});
    for (c.channels) |ch| {
        if (ch.name.len == 0 or !std.mem.endsWith(u8, ch.url, "/"))
            return try std.fmt.allocPrint(arena, "channel '{s}': the url must end with '/'", .{ch.name});
        if (!(std.mem.startsWith(u8, ch.url, "https://") or std.mem.startsWith(u8, ch.url, "http://127.0.0.1:") or std.mem.startsWith(u8, ch.url, "http://localhost:") or std.mem.startsWith(u8, ch.url, "http://[::1]:")))
            return try std.fmt.allocPrint(arena, "channel '{s}': the url must be https (plain http only to loopback)", .{ch.name});
    }
    var names = std.StringHashMap(void).init(arena);
    var have_mojo = false;
    var have_compiler = false;
    for (c.packages) |p| {
        if (p.name.len == 0 or p.version.len == 0 or p.build.len == 0)
            return try std.fmt.allocPrint(arena, "a package has no name, version or build ({s})", .{p.path});
        if ((try names.fetchPut(p.name, {})) != null)
            return try std.fmt.allocPrint(arena, "{s} is listed twice", .{p.name});
        if (!isHex64(p.sha256)) return try std.fmt.allocPrint(arena, "{s}: sha256 is not 64 lowercase hex digits", .{p.name});
        if (p.size == 0) return try std.fmt.allocPrint(arena, "{s}: size is 0", .{p.name});
        if (channelUrl(c, p.channel) == null) return try std.fmt.allocPrint(arena, "{s}: channel '{s}' is not listed", .{ p.name, p.channel });
        if (!std.mem.endsWith(u8, p.path, ".conda"))
            return try std.fmt.allocPrint(arena, "{s}: {s} is not a .conda file (mopm unpacks .conda only)", .{ p.name, p.path });
        const want_path = try std.fmt.allocPrint(arena, "{s}/{s}-{s}-{s}.conda", .{ p.subdir, p.name, p.version, p.build });
        if (!std.mem.eql(u8, want_path, p.path))
            return try std.fmt.allocPrint(arena, "{s}: path {s} is not {s}", .{ p.name, p.path, want_path });
        if (!std.mem.eql(u8, p.subdir, c.subdir) and !std.mem.eql(u8, p.subdir, "noarch"))
            return try std.fmt.allocPrint(arena, "{s}: subdir {s} is neither {s} nor noarch", .{ p.name, p.subdir, c.subdir });
        if (std.mem.eql(u8, p.name, "mojo")) {
            have_mojo = true;
            if (!std.mem.eql(u8, p.version, c.mojo)) return try std.fmt.allocPrint(arena, "mojo is {s}, not {s}", .{ p.version, c.mojo });
        }
        if (std.mem.eql(u8, p.name, "mojo-compiler")) {
            have_compiler = true;
            if (!std.mem.eql(u8, p.version, c.mojo)) return try std.fmt.allocPrint(arena, "mojo-compiler is {s}, not {s}", .{ p.version, c.mojo });
        }
    }
    if (!have_mojo or !have_compiler) return "the closure lacks mojo or mojo-compiler";
    return null;
}

pub fn parse(arena: Allocator, text: []const u8) !Closure {
    return std.json.parseFromSliceLeaky(Closure, arena, text, .{});
}

pub fn render(arena: Allocator, c: Closure) ![]u8 {
    var out = std.ArrayList(u8).init(arena);
    try std.json.stringify(c, .{ .whitespace = .indent_2 }, out.writer());
    try out.append('\n');
    return out.items;
}

/// Where `new` pins other bytes than `old` for the same file: a package file
/// (same channel path) whose sha256 or size changed was republished, which a
/// weekly update must never accept silently. One line per such file.
pub fn alarms(arena: Allocator, old: Closure, new: Closure) Allocator.Error![]const []const u8 {
    var out = std.ArrayList([]const u8).init(arena);
    for (new.packages) |n| {
        for (old.packages) |o| {
            if (!std.mem.eql(u8, o.path, n.path)) continue;
            if (!std.mem.eql(u8, o.sha256, n.sha256) or o.size != n.size) {
                try out.append(try std.fmt.allocPrint(arena, "{s}: was sha256 {s} ({d} bytes), is now {s} ({d} bytes)", .{ n.path, o.sha256, o.size, n.sha256, n.size }));
            }
        }
    }
    return out.items;
}

// ------------------------------------------------------------ pixi.lock

const LockEntry = struct {
    url: []const u8,
    build_number: u64 = 0,
    sha256: []const u8 = "",
    md5: []const u8 = "",
    size: u64 = 0,
    license: []const u8 = "",
    timestamp: u64 = 0,
    depends: std.ArrayList([]const u8),
    constrains: std.ArrayList([]const u8),
};

/// A YAML scalar without its quotes.
fn unquote(arena: Allocator, s: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, s, " \t\r");
    if (t.len >= 2 and t[0] == '\'' and t[t.len - 1] == '\'') {
        return std.mem.replaceOwned(u8, arena, t[1 .. t.len - 1], "''", "'");
    }
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') {
        return std.mem.replaceOwned(u8, arena, t[1 .. t.len - 1], "\\\"", "\"");
    }
    return t;
}

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

pub const LockError = error{BadLock} || Allocator.Error;

/// The closure for `subdir` in the pixi lock `text` (the `default` environment).
/// `diag` says what is wrong when it returns `error.BadLock`.
pub fn fromPixiLock(arena: Allocator, text: []const u8, subdir: []const u8, diag: *[]const u8) LockError!Closure {
    // Pass 1: the platform's urls from `environments.default.packages.<subdir>`,
    // and every entry of the top-level `packages:` list.
    var wanted = std.ArrayList([]const u8).init(arena);
    var entries = std.StringHashMap(*LockEntry).init(arena);

    const Section = enum { none, environments, packages };
    var section: Section = .none;
    var in_default = false;
    var in_env_packages = false;
    var in_platform = false;
    var cur: ?*LockEntry = null;
    var list_key: enum { none, depends, constrains } = .none;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var lineno: usize = 0;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trimRight(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const ind = indentOf(line);
        const body = line[ind..];
        if (ind == 0 and !std.mem.startsWith(u8, body, "- ")) {
            if (std.mem.eql(u8, body, "environments:")) section = .environments else if (std.mem.eql(u8, body, "packages:")) section = .packages else section = .none;
            cur = null;
            continue;
        }
        switch (section) {
            .none => {},
            .environments => {
                if (ind == 2 and std.mem.endsWith(u8, body, ":")) {
                    in_default = std.mem.eql(u8, body, "default:");
                    in_env_packages = false;
                    in_platform = false;
                } else if (in_default and ind == 4) {
                    in_env_packages = std.mem.eql(u8, body, "packages:");
                    in_platform = false;
                } else if (in_default and in_env_packages and ind == 6 and std.mem.endsWith(u8, body, ":")) {
                    in_platform = std.mem.eql(u8, body[0 .. body.len - 1], subdir);
                } else if (in_default and in_env_packages and in_platform and ind == 6 and std.mem.startsWith(u8, body, "- ")) {
                    const kv = body[2..];
                    if (std.mem.startsWith(u8, kv, "conda: ")) {
                        try wanted.append(try unquote(arena, kv["conda: ".len..]));
                    } else {
                        diag.* = try std.fmt.allocPrint(arena, "line {d}: '{s}' is not a conda package; mopm installs conda packages only", .{ lineno, kv });
                        return error.BadLock;
                    }
                }
            },
            .packages => {
                if (ind == 0) {
                    // "- conda: <url>" starts an entry.
                    const kv = body[2..];
                    if (!std.mem.startsWith(u8, kv, "conda: ")) {
                        diag.* = try std.fmt.allocPrint(arena, "line {d}: '{s}' is not a conda package; mopm installs conda packages only", .{ lineno, kv });
                        return error.BadLock;
                    }
                    const url = try unquote(arena, kv["conda: ".len..]);
                    const e = try arena.create(LockEntry);
                    e.* = .{ .url = url, .depends = std.ArrayList([]const u8).init(arena), .constrains = std.ArrayList([]const u8).init(arena) };
                    try entries.put(url, e);
                    cur = e;
                    list_key = .none;
                } else if (cur) |e| {
                    if (ind == 2 and std.mem.startsWith(u8, body, "- ")) {
                        const item = try unquote(arena, body[2..]);
                        switch (list_key) {
                            .depends => try e.depends.append(item),
                            .constrains => try e.constrains.append(item),
                            .none => {},
                        }
                    } else if (ind == 2) {
                        list_key = .none;
                        const colon = std.mem.indexOfScalar(u8, body, ':') orelse continue;
                        const key = body[0..colon];
                        const val = std.mem.trim(u8, body[colon + 1 ..], " ");
                        if (std.mem.eql(u8, key, "depends")) {
                            list_key = if (val.len == 0) .depends else .none;
                        } else if (std.mem.eql(u8, key, "constrains")) {
                            list_key = if (val.len == 0) .constrains else .none;
                        } else if (std.mem.eql(u8, key, "sha256")) {
                            e.sha256 = try unquote(arena, val);
                        } else if (std.mem.eql(u8, key, "md5")) {
                            e.md5 = try unquote(arena, val);
                        } else if (std.mem.eql(u8, key, "license")) {
                            e.license = try unquote(arena, val);
                        } else if (std.mem.eql(u8, key, "size")) {
                            e.size = std.fmt.parseInt(u64, val, 10) catch 0;
                        } else if (std.mem.eql(u8, key, "build_number")) {
                            e.build_number = std.fmt.parseInt(u64, val, 10) catch 0;
                        } else if (std.mem.eql(u8, key, "timestamp")) {
                            e.timestamp = std.fmt.parseInt(u64, val, 10) catch 0;
                        }
                    }
                    // Deeper lines belong to a key mopm does not read (run_exports, ...).
                }
            },
        }
    }

    if (wanted.items.len == 0) {
        diag.* = try std.fmt.allocPrint(arena, "the lock's default environment has no packages for {s}", .{subdir});
        return error.BadLock;
    }

    // Pass 2: one Package per wanted url.
    var channels = std.ArrayList(Channel).init(arena);
    var pkgs = std.ArrayList(Package).init(arena);
    var mojo: []const u8 = "";
    for (wanted.items) |url| {
        const e = entries.get(url) orelse {
            diag.* = try std.fmt.allocPrint(arena, "{s} is listed for {s} but has no entry in the lock's package list", .{ url, subdir });
            return error.BadLock;
        };
        // <base>/<subdir>/<file>
        const last = std.mem.lastIndexOfScalar(u8, url, '/') orelse return badUrl(arena, diag, url);
        const prev = std.mem.lastIndexOfScalar(u8, url[0..last], '/') orelse return badUrl(arena, diag, url);
        const file = url[last + 1 ..];
        const pkg_subdir = url[prev + 1 .. last];
        const base = url[0 .. prev + 1];
        if (!std.mem.endsWith(u8, file, ".conda")) {
            diag.* = try std.fmt.allocPrint(arena, "{s} is not a .conda file; mopm unpacks .conda only", .{url});
            return error.BadLock;
        }
        if (e.sha256.len == 0 or e.size == 0) {
            diag.* = try std.fmt.allocPrint(arena, "{s}: the lock has no sha256 or size for it", .{url});
            return error.BadLock;
        }
        const stem = file[0 .. file.len - ".conda".len];
        const dash2 = std.mem.lastIndexOfScalar(u8, stem, '-') orelse return badUrl(arena, diag, url);
        const dash1 = std.mem.lastIndexOfScalar(u8, stem[0..dash2], '-') orelse return badUrl(arena, diag, url);
        const name = stem[0..dash1];
        const version = stem[dash1 + 1 .. dash2];
        const build = stem[dash2 + 1 ..];
        // The channel's name is the last segment of its url.
        const trimmed = std.mem.trimRight(u8, base, "/");
        const cname = trimmed[(std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return badUrl(arena, diag, url)) + 1 ..];
        var found = false;
        for (channels.items) |ch| {
            if (std.mem.eql(u8, ch.name, cname)) {
                if (!std.mem.eql(u8, ch.url, base)) {
                    diag.* = try std.fmt.allocPrint(arena, "two channels are both called '{s}': {s} and {s}", .{ cname, ch.url, base });
                    return error.BadLock;
                }
                found = true;
            }
        }
        if (!found) try channels.append(.{ .name = cname, .url = base });
        if (std.mem.eql(u8, name, "mojo")) mojo = version;
        try pkgs.append(.{
            .name = name,
            .version = version,
            .build = build,
            .build_number = e.build_number,
            .subdir = pkg_subdir,
            .channel = cname,
            .path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ pkg_subdir, file }),
            .sha256 = e.sha256,
            .md5 = e.md5,
            .size = e.size,
            .depends = e.depends.items,
            .constrains = e.constrains.items,
            .license = e.license,
            .timestamp = e.timestamp,
        });
    }
    std.mem.sort(Package, pkgs.items, {}, lessPackage);
    std.mem.sort(Channel, channels.items, {}, lessChannel);
    if (mojo.len == 0) {
        diag.* = "the lock has no mojo package";
        return error.BadLock;
    }
    const c = Closure{ .mojo = mojo, .subdir = subdir, .channels = channels.items, .packages = pkgs.items };
    if (try problem(arena, c)) |why| {
        diag.* = why;
        return error.BadLock;
    }
    return c;
}

fn badUrl(arena: Allocator, diag: *[]const u8, url: []const u8) LockError {
    diag.* = std.fmt.allocPrint(arena, "{s} is not <channel>/<subdir>/<name>-<version>-<build>.conda", .{url}) catch "bad url";
    return error.BadLock;
}

fn lessPackage(_: void, a: Package, b: Package) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn lessChannel(_: void, a: Channel, b: Channel) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

// ---------------------------------------------------------------- tests

const sample_lock =
    \\version: 7
    \\platforms:
    \\- name: linux-64
    \\- name: osx-arm64
    \\environments:
    \\  default:
    \\    channels:
    \\    - url: https://conda.modular.com/max/
    \\    - url: https://conda.anaconda.org/conda-forge/
    \\    packages:
    \\      linux-64:
    \\      - conda: https://conda.anaconda.org/conda-forge/linux-64/libfoo-1.2-h1_3.conda
    \\      - conda: https://conda.anaconda.org/conda-forge/noarch/six-1.17.0-pyhe_1.conda
    \\      - conda: https://conda.modular.com/max/linux-64/mojo-1.0.0-release.conda
    \\      - conda: https://conda.modular.com/max/linux-64/mojo-compiler-1.0.0-release.conda
    \\      osx-arm64:
    \\      - conda: https://conda.modular.com/max/osx-arm64/mojo-1.0.0-release.conda
    \\packages:
    \\- conda: https://conda.anaconda.org/conda-forge/linux-64/libfoo-1.2-h1_3.conda
    \\  build_number: 3
    \\  sha256: 1111111111111111111111111111111111111111111111111111111111111111
    \\  md5: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    \\  depends:
    \\  - __glibc >=2.17,<3.0.a0
    \\  - libgcc >=14
    \\  constrains:
    \\  - foo_impl <0.0a0
    \\  license: MIT
    \\  run_exports:
    \\    weak:
    \\    - libfoo >=1.2,<2.0a0
    \\  size: 1234
    \\  timestamp: 1700000000000
    \\- conda: https://conda.anaconda.org/conda-forge/noarch/six-1.17.0-pyhe_1.conda
    \\  sha256: 2222222222222222222222222222222222222222222222222222222222222222
    \\  depends: []
    \\  license: 'MIT AND "quoted"'
    \\  size: 99
    \\- conda: https://conda.modular.com/max/linux-64/mojo-1.0.0-release.conda
    \\  sha256: 3333333333333333333333333333333333333333333333333333333333333333
    \\  depends:
    \\  - python >=3.10
    \\  - mojo-compiler ==1.0.0
    \\  size: 5000
    \\- conda: https://conda.modular.com/max/linux-64/mojo-compiler-1.0.0-release.conda
    \\  sha256: 4444444444444444444444444444444444444444444444444444444444444444
    \\  size: 7000
    \\- conda: https://conda.modular.com/max/osx-arm64/mojo-1.0.0-release.conda
    \\  sha256: 5555555555555555555555555555555555555555555555555555555555555555
    \\  size: 6000
    \\
;

const sample_json =
    \\{
    \\  "format": 1,
    \\  "mojo": "1.0.0",
    \\  "subdir": "linux-64",
    \\  "channels": [
    \\    {
    \\      "name": "conda-forge",
    \\      "url": "https://conda.anaconda.org/conda-forge/"
    \\    },
    \\    {
    \\      "name": "max",
    \\      "url": "https://conda.modular.com/max/"
    \\    }
    \\  ],
    \\  "packages": [
    \\    {
    \\      "name": "libfoo",
    \\      "version": "1.2",
    \\      "build": "h1_3",
    \\      "build_number": 3,
    \\      "subdir": "linux-64",
    \\      "channel": "conda-forge",
    \\      "path": "linux-64/libfoo-1.2-h1_3.conda",
    \\      "sha256": "1111111111111111111111111111111111111111111111111111111111111111",
    \\      "md5": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    \\      "size": 1234,
    \\      "depends": [
    \\        "__glibc >=2.17,<3.0.a0",
    \\        "libgcc >=14"
    \\      ],
    \\      "constrains": [
    \\        "foo_impl <0.0a0"
    \\      ],
    \\      "license": "MIT",
    \\      "timestamp": 1700000000000
    \\    },
    \\    {
    \\      "name": "mojo",
    \\      "version": "1.0.0",
    \\      "build": "release",
    \\      "build_number": 0,
    \\      "subdir": "linux-64",
    \\      "channel": "max",
    \\      "path": "linux-64/mojo-1.0.0-release.conda",
    \\      "sha256": "3333333333333333333333333333333333333333333333333333333333333333",
    \\      "md5": "",
    \\      "size": 5000,
    \\      "depends": [
    \\        "python >=3.10",
    \\        "mojo-compiler ==1.0.0"
    \\      ],
    \\      "constrains": [],
    \\      "license": "",
    \\      "timestamp": 0
    \\    },
    \\    {
    \\      "name": "mojo-compiler",
    \\      "version": "1.0.0",
    \\      "build": "release",
    \\      "build_number": 0,
    \\      "subdir": "linux-64",
    \\      "channel": "max",
    \\      "path": "linux-64/mojo-compiler-1.0.0-release.conda",
    \\      "sha256": "4444444444444444444444444444444444444444444444444444444444444444",
    \\      "md5": "",
    \\      "size": 7000,
    \\      "depends": [],
    \\      "constrains": [],
    \\      "license": "",
    \\      "timestamp": 0
    \\    },
    \\    {
    \\      "name": "six",
    \\      "version": "1.17.0",
    \\      "build": "pyhe_1",
    \\      "build_number": 0,
    \\      "subdir": "noarch",
    \\      "channel": "conda-forge",
    \\      "path": "noarch/six-1.17.0-pyhe_1.conda",
    \\      "sha256": "2222222222222222222222222222222222222222222222222222222222222222",
    \\      "md5": "",
    \\      "size": 99,
    \\      "depends": [],
    \\      "constrains": [],
    \\      "license": "MIT AND \"quoted\"",
    \\      "timestamp": 0
    \\    }
    \\  ]
    \\}
    \\
;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "a pixi lock becomes the closure of one platform, byte for byte" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var why: []const u8 = "";
    const c = try fromPixiLock(a, sample_lock, "linux-64", &why);
    try std.testing.expectEqualStrings(sample_json, try render(a, c));
    // The file reads back to the same closure, and the url is channel + path.
    const back = try parse(a, sample_json);
    try std.testing.expectEqualStrings(sample_json, try render(a, back));
    try std.testing.expectEqualStrings("https://conda.modular.com/max/linux-64/mojo-compiler-1.0.0-release.conda", try urlOf(a, back, back.packages[2]));
    try std.testing.expectEqual(@as(?[]const u8, null), try problem(a, back));
}

test "the lock's other platform: the entries it names, no others" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var why: []const u8 = "";
    // osx-arm64 has mojo but no mojo-compiler: refused, and why.
    try std.testing.expectError(error.BadLock, fromPixiLock(a, sample_lock, "osx-arm64", &why));
    try std.testing.expectEqualStrings("the closure lacks mojo or mojo-compiler", why);
    try std.testing.expectError(error.BadLock, fromPixiLock(a, sample_lock, "linux-aarch64", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "no packages for linux-aarch64") != null);
}

test "a lock the installer cannot use is refused, with the reason" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var why: []const u8 = "";
    const bz2 = try std.mem.replaceOwned(u8, a, sample_lock, "libfoo-1.2-h1_3.conda", "libfoo-1.2-h1_3.tar.bz2");
    try std.testing.expectError(error.BadLock, fromPixiLock(a, bz2, "linux-64", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "not a .conda file") != null);

    const nosha = try std.mem.replaceOwned(u8, a, sample_lock, "  sha256: 2222222222222222222222222222222222222222222222222222222222222222\n", "");
    try std.testing.expectError(error.BadLock, fromPixiLock(a, nosha, "linux-64", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "no sha256 or size") != null);

    const pypi = try std.mem.replaceOwned(u8, a, sample_lock, "      - conda: https://conda.modular.com/max/linux-64/mojo-compiler-1.0.0-release.conda\n", "      - pypi: https://example.invalid/x.whl\n");
    try std.testing.expectError(error.BadLock, fromPixiLock(a, pypi, "linux-64", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "conda packages only") != null);

    const short = try std.mem.replaceOwned(u8, a, sample_lock, "  sha256: 1111111111111111111111111111111111111111111111111111111111111111\n", "  sha256: 11\n");
    try std.testing.expectError(error.BadLock, fromPixiLock(a, short, "linux-64", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "64 lowercase hex") != null);
}

test "problem: what the installer relies on" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const c = try parse(a, sample_json);
    try std.testing.expectEqual(@as(?[]const u8, null), try problem(a, c));

    var bad = c;
    bad.channels = &.{.{ .name = "max", .url = "http://conda.example/max/" }, .{ .name = "conda-forge", .url = "https://conda.anaconda.org/conda-forge/" }};
    try std.testing.expect((try problem(a, bad)) != null);
    bad.channels = &.{.{ .name = "max", .url = "https://conda.modular.com/max" }, .{ .name = "conda-forge", .url = "https://conda.anaconda.org/conda-forge/" }};
    try std.testing.expect((try problem(a, bad)) != null);

    // A mirror is a channel url change and nothing else.
    var mirror = c;
    mirror.channels = &.{ .{ .name = "conda-forge", .url = "https://mirror.example/forge/" }, .{ .name = "max", .url = "https://mirror.example/max/" } };
    try std.testing.expectEqual(@as(?[]const u8, null), try problem(a, mirror));
    try std.testing.expectEqualStrings("https://mirror.example/forge/linux-64/libfoo-1.2-h1_3.conda", try urlOf(a, mirror, c.packages[0]));

    var twice = c;
    twice.packages = &.{ c.packages[0], c.packages[0] };
    try std.testing.expect((try problem(a, twice)) != null);

    var wrong_path = c;
    var pk = c.packages[0];
    pk.path = "linux-64/other.conda";
    wrong_path.packages = &.{ pk, c.packages[1], c.packages[2] };
    try std.testing.expect((try problem(a, wrong_path)) != null);
}

test "alarms: the same file with other bytes is reported; a new version is not" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const old = try parse(a, sample_json);
    try std.testing.expectEqual(@as(usize, 0), (try alarms(a, old, old)).len);

    var changed = old;
    var pk = old.packages[0];
    pk.sha256 = "9" ** 64;
    changed.packages = &.{ pk, old.packages[1], old.packages[2], old.packages[3] };
    const got = try alarms(a, old, changed);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(std.mem.startsWith(u8, got[0], "linux-64/libfoo-1.2-h1_3.conda: was sha256 1111"));

    // A new build of a package is another file: no alarm.
    var moved = old;
    var nk = old.packages[0];
    nk.build = "h2_4";
    nk.path = "linux-64/libfoo-1.2-h2_4.conda";
    nk.sha256 = "8" ** 64;
    moved.packages = &.{ nk, old.packages[1], old.packages[2], old.packages[3] };
    try std.testing.expectEqual(@as(usize, 0), (try alarms(a, old, moved)).len);
}

// The committed closures are what the generator makes from the committed
// locks, so no one edits a hash by hand and a lock cannot move without its
// closure files moving with it.
test "the committed closure files are the ones made from the committed locks" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const versions_text = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, "toolchain/versions.txt"), 1 << 16);
    var seen: usize = 0;
    var it = std.mem.tokenizeScalar(u8, versions_text, '\n');
    while (it.next()) |line| {
        const ver = std.mem.trim(u8, line, " \t\r");
        if (ver.len == 0 or ver[0] == '#') continue;
        const lock_text = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, try std.fmt.allocPrint(a, "toolchain/mojo-{s}.pixi.lock", .{ver})), 16 << 20);
        for (subdirs) |subdir| {
            var why: []const u8 = "";
            const made = fromPixiLock(a, lock_text, subdir, &why) catch |e| {
                std.debug.print("mojo {s} {s}: {s}: {s}\n", .{ ver, subdir, @errorName(e), why });
                return e;
            };
            try std.testing.expectEqualStrings(ver, made.mojo);
            const file = try std.fmt.allocPrint(a, "src/core/toolchain/mojo-{s}-{s}.json", .{ ver, subdir });
            const committed = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, file), 16 << 20);
            const want = try render(a, made);
            if (!std.mem.eql(u8, want, committed)) {
                var at: usize = 0;
                while (at < want.len and at < committed.len and want[at] == committed[at]) at += 1;
                const from = at -| 60;
                std.debug.print("first difference at byte {d}\n  made:      {s}\n  committed: {s}\n", .{ at, want[from..@min(want.len, at + 60)], committed[from..@min(committed.len, at + 60)] });
                std.debug.print("{s} is not what mopm-closure makes from toolchain/mojo-{s}.pixi.lock; run: zig build run-closure -- toolchain/mojo-{s}.pixi.lock src/core/toolchain\n", .{ file, ver, ver });
                return error.ClosureOutOfDate;
            }
            // And each committed file is usable as it stands.
            try std.testing.expectEqual(@as(?[]const u8, null), try problem(a, try parse(a, committed)));
            seen += 1;
        }
    }
    try std.testing.expect(seen >= subdirs.len);
}
