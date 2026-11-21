//! `mopm pack` and `mopm publish`: a package as a `.conda`, and onto a registry.
//!
//!   mopm pack    --compiler <version> --mojoc [<subdir>=]<file>... [--native <id>=<subdir>:<file>...]
//!                [--manifest <file>] [-o <dir>]
//!   mopm publish --compiler <version> --mojoc [<subdir>=]<file>... [--native <id>=<subdir>:<file>...]
//!                [--manifest <file>] [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
//!                [--readme <file>] [--dry-run] [--oidc]
//!
//! `pack` writes `<dir>/<subdir>/mojo-<namespace>.<name>-<version>-mojo<compiler>_0.conda`
//! (src/core/conda.zig) and prints each file's sha256. A package that declares
//! `[native.<id>] kind = "static"` gets its archive for each subdir from
//! `--native <id>=<subdir>:<file>` (one per native and subdir; the `.conda` of a
//! subdir holds that subdir's archives at `lib/lib<name>.a`), and a native
//! library is never packed for `noarch`. `publish` packs the
//! same way and then follows the registry's three steps (spec/api/openapi.yaml):
//! begin an upload per file and PUT the bytes to the URL it names, commit the
//! uploads, and poll the publish until it is `published` or `rejected`.
//!
//! Both write the digest of the package's sources into the metadata of every file (`source_sha256`, src/core/source_digest.zig)
//! when the package's library directory exists; when it does not, they say so on standard error and write none. The digest is
//! the same whichever compiler `--compiler` names. `publish` makes the same requests when the version is already published:
//! nothing here refuses it, the registry decides, and it takes a build for another Mojo into a published version only when
//! the sources are the same (`source_sha256`) and the build is new.
//!
//! Before the first upload, `publish` creates the package when the registry does not have it (`PUT /api/v2/packages/<namespace>/<name>`,
//! no body: 201 says `created <name> on <stage>`, 200 means it was there already and says nothing). The registry checks first that
//! the token's user may write the namespace; a refusal is printed and nothing is uploaded. `--dry-run` sends nothing.
//!
//! The token is `$MOPM_TOKEN` when that is set and not empty, else the one
//! `mopm login` stored for the registry. It is sent only to the registry's
//! API, as a bearer token, and is never printed. The PUT to the storage URL
//! carries no token, only the headers the registry named.
//!
//! `--oidc` takes no token from `$MOPM_TOKEN` or a login: inside a GitHub
//! Actions job that may request an identity token, mopm asks GitHub for one
//! with the registry's audience and exchanges it at the registry for a token
//! that may publish this one package version (src/core/ci_oidc.zig). That token
//! is held in memory only. Outside such a job the command stops before any
//! request.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;
const manifest = core.manifest;
const conda = core.conda;
const bins_mod = core.bins;
const source_digest = core.source_digest;
const registry = core.registry;
const credentials = core.credentials;
const ci_oidc = core.ci_oidc;
const registry_cmd = @import("registry_cmd.zig");
const group_publish = @import("group_publish.zig");
const v2 = core.registry_v2;

const usage =
    \\usage: mopm pack    --compiler <mojo version> --mojoc [<subdir>=]<file>... [--native <id>=<subdir>:<file>...]
    \\                    [--manifest <mopm.toml>] [-o <dir>]
    \\       mopm publish --compiler <mojo version> --mojoc [<subdir>=]<file>... [--native <id>=<subdir>:<file>...]
    \\                    [--manifest <mopm.toml>] [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
    \\                    [--readme <file>] [--dry-run] [--oidc]
    \\
    \\  <subdir> is noarch (the default), linux-64, linux-aarch64 or osx-arm64.
    \\  --native gives the static archive (lib<name>.a) of a [native.<id>] for one subdir; never noarch.
    \\  The token is $MOPM_TOKEN, else the one 'mopm login' stored.
    \\  --oidc, inside a GitHub Actions job with 'id-token: write', gets the token from the job's identity instead.
    \\
;

/// The registry serves a readme of at most 64 KiB; a larger one is refused
/// here, before any request.
pub const max_readme_bytes: usize = 65536;
/// The registry accepts a package file of at most 100 MB (decimal).
pub const max_file_bytes: usize = 100_000_000;
/// A version has at most this many files (one per subdir is the most mopm makes).
pub const max_files: usize = 20;
/// How long `publish` waits for the registry to finish a publish.
const wait_secs: i64 = 600;

pub const Cmd = enum { pack, publish };

pub const Mojoc = struct { subdir: []const u8, path: []const u8 };

/// `--native <id>=<subdir>:<file>`: the archive of native library `id` built for `subdir`.
pub const NativeFile = struct { id: []const u8, subdir: []const u8, path: []const u8 };

pub const Flags = struct {
    compiler: []const u8 = "",
    mojoc: []const Mojoc = &.{},
    natives: []const NativeFile = &.{},
    manifest: []const u8 = "mopm.toml",
    out: []const u8 = "dist",
    registry: []const u8 = "prod",
    config_dir: ?[]const u8 = null,
    readme: ?[]const u8 = null,
    dry_run: bool = false,
    /// `--oidc`: the registry token comes from the CI job's identity, not `$MOPM_TOKEN` or a login.
    oidc: bool = false,
};

pub const Parsed = union(enum) { ok: Flags, bad: []const u8 };

fn bad(arena: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!Parsed {
    return .{ .bad = try std.fmt.allocPrint(arena, fmt, args) };
}

fn takesValue(cmd: Cmd, flag: []const u8) bool {
    const common = [_][]const u8{ "--compiler", "--mojoc", "--manifest", "--native" };
    for (common) |c| {
        if (std.mem.eql(u8, c, flag)) return true;
    }
    return switch (cmd) {
        .pack => std.mem.eql(u8, flag, "-o"),
        .publish => std.mem.eql(u8, flag, "--registry") or std.mem.eql(u8, flag, "--config-dir") or std.mem.eql(u8, flag, "--readme"),
    };
}

/// The flags of `pack` or `publish`, or why they are wrong.
pub fn parseFlags(arena: Allocator, cmd: Cmd, args: []const []const u8) Allocator.Error!Parsed {
    var f = Flags{};
    var mojoc = std.ArrayList(Mojoc).init(arena);
    var natives = std.ArrayList(NativeFile).init(arena);
    var have_compiler = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (cmd == .publish and std.mem.eql(u8, a, "--dry-run")) {
            f.dry_run = true;
            continue;
        }
        if (cmd == .publish and std.mem.eql(u8, a, "--oidc")) {
            f.oidc = true;
            continue;
        }
        if (!takesValue(cmd, a)) return bad(arena, "unexpected argument '{s}'", .{a});
        if (i + 1 >= args.len) return bad(arena, "{s} needs a value", .{a});
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, a, "--compiler")) {
            f.compiler = v;
            have_compiler = true;
        } else if (std.mem.eql(u8, a, "--manifest")) {
            f.manifest = v;
        } else if (std.mem.eql(u8, a, "-o")) {
            f.out = v;
        } else if (std.mem.eql(u8, a, "--registry")) {
            f.registry = v;
        } else if (std.mem.eql(u8, a, "--config-dir")) {
            f.config_dir = v;
        } else if (std.mem.eql(u8, a, "--readme")) {
            f.readme = v;
        } else if (std.mem.eql(u8, a, "--native")) {
            // --native <id>=<subdir>:<file>
            const eq = std.mem.indexOfScalar(u8, v, '=') orelse return bad(arena, "--native {s}: expected <id>=<subdir>:<file>", .{v});
            const colon = std.mem.indexOfScalarPos(u8, v, eq + 1, ':') orelse return bad(arena, "--native {s}: expected <id>=<subdir>:<file>", .{v});
            const entry = NativeFile{ .id = v[0..eq], .subdir = v[eq + 1 .. colon], .path = v[colon + 1 ..] };
            if (entry.id.len == 0 or entry.path.len == 0) return bad(arena, "--native {s}: expected <id>=<subdir>:<file>", .{v});
            if (!conda.isSubdir(entry.subdir)) {
                return bad(arena, "--native {s}: '{s}' is not a subdir (linux-64, linux-aarch64, osx-arm64)", .{ v, entry.subdir });
            }
            if (std.mem.eql(u8, entry.subdir, "noarch")) {
                return bad(arena, "--native {s}: an archive is built for one platform; it cannot be packed for noarch", .{v});
            }
            for (natives.items) |n| {
                if (std.mem.eql(u8, n.id, entry.id) and std.mem.eql(u8, n.subdir, entry.subdir)) {
                    return bad(arena, "--native names {s} for {s} twice", .{ entry.id, entry.subdir });
                }
            }
            try natives.append(entry);
        } else {
            // --mojoc <path> or --mojoc <subdir>=<path>: a prefix before the
            // first '=' that has no '/' names a subdir.
            var entry = Mojoc{ .subdir = "noarch", .path = v };
            if (std.mem.indexOfScalar(u8, v, '=')) |eq| {
                if (std.mem.indexOfScalar(u8, v[0..eq], '/') == null) {
                    if (!conda.isSubdir(v[0..eq])) {
                        return bad(arena, "--mojoc {s}: '{s}' is not a subdir (noarch, linux-64, linux-aarch64, osx-arm64)", .{ v, v[0..eq] });
                    }
                    entry = .{ .subdir = v[0..eq], .path = v[eq + 1 ..] };
                }
            }
            if (entry.path.len == 0) return bad(arena, "--mojoc {s}: no file", .{v});
            for (mojoc.items) |m| {
                if (std.mem.eql(u8, m.subdir, entry.subdir)) return bad(arena, "--mojoc names the subdir {s} twice", .{entry.subdir});
            }
            try mojoc.append(entry);
        }
    }
    if (!have_compiler) return bad(arena, "--compiler <exact mojo version> is required", .{});
    if (mojoc.items.len == 0) return bad(arena, "--mojoc <file> is required", .{});
    f.mojoc = mojoc.items;
    f.natives = natives.items;
    return .{ .ok = f };
}

fn err(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print("mopm: " ++ fmt, args) catch {};
}

/// Why `version` cannot be published, or null.
pub fn versionProblem(arena: Allocator, version: []const u8) Allocator.Error!?[]const u8 {
    if (conda.exactVersion(version)) return null;
    return try std.fmt.allocPrint(arena, "version '{s}' must be exactly MAJOR.MINOR.PATCH (digits, no leading zeros, no pre-release or build part) to be packed", .{version});
}

/// Why `bytes` read from `path` cannot be the readme, or null.
pub fn readmeProblem(arena: Allocator, path: []const u8, bytes: []const u8) Allocator.Error!?[]const u8 {
    if (bytes.len > max_readme_bytes) {
        return try std.fmt.allocPrint(arena, "{s} is {d} bytes; a readme is at most {d} bytes (the registry serves at most 64 KiB)", .{ path, bytes.len, max_readme_bytes });
    }
    if (!std.unicode.utf8ValidateSlice(bytes)) return try std.fmt.allocPrint(arena, "{s} is not UTF-8 text", .{path});
    return null;
}

pub const Prepared = struct {
    m: manifest.Manifest,
    packs: []const conda.Packed,
    manifest_dir: []const u8,
    /// A line to say on standard error before going on (without the `mopm: `): the package carries no source digest.
    note: ?[]const u8 = null,
};

/// Reads the manifest and the `.mojoc` files and packs them. Null after
/// printing why not (nothing has touched the network by then).
pub fn prepare(arena: Allocator, cmd: Cmd, f: Flags) anyerror!?Prepared {
    const src = std.fs.cwd().readFileAlloc(arena, f.manifest, 1 << 20) catch |e| {
        err("{s}: {s}\n", .{ f.manifest, @errorName(e) });
        return null;
    };
    var diag: manifest.Diagnostic = .{};
    const m = manifest.parse(arena, src, &diag) catch |e| {
        if (e == error.Invalid) {
            err("{s}:{d}:{d}: {s}\n", .{ f.manifest, diag.pos.line, diag.pos.col, diag.message });
        } else {
            err("{s}: {s}\n", .{ f.manifest, @errorName(e) });
        }
        return null;
    };
    for (m.warnings) |w| err("warning: {s}:{s}\n", .{ f.manifest, w });
    if (!m.package.publish) {
        err("{s}: {s} has publish = false, so it is not packed for a registry or published; remove the key to publish it\n", .{ f.manifest, m.package.full_name });
        return null;
    }
    if (try versionProblem(arena, m.package.version)) |problem| {
        err("{s}: {s}\n", .{ f.manifest, problem });
        return null;
    }
    if (!conda.validCompiler(f.compiler)) {
        err("--compiler {s}: an exact Mojo version is digits and dots, such as 1.0.0\n", .{f.compiler});
        return null;
    }
    var why: []const u8 = "";
    const path_versions = (try pathVersions(arena, m, std.fs.path.dirname(f.manifest) orelse ".")) orelse return null;
    const deps = conda.depsOf(arena, m, path_versions, &why) catch |e| switch (e) {
        error.Unpackable => {
            err("{s}: {s}\n", .{ f.manifest, why });
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const native_deps = conda.nativeDepsOf(arena, m, &why) catch |e| switch (e) {
        error.Unpackable => {
            err("{s}: {s}\n", .{ f.manifest, why });
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    const native_files = switch (try nativeFiles(arena, m, f)) {
        .ok => |files| files,
        .bad => |reason| {
            err("{s}\n", .{reason});
            return null;
        },
    };

    // The programs of `[targets] bins`, as source, in every subdir's package.
    const bins = bins_mod.read(arena, m, std.fs.path.dirname(f.manifest) orelse ".", &why) catch |e| switch (e) {
        error.Unpackable => {
            err("{s}: {s}\n", .{ f.manifest, why });
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    // The digest of the package's sources, the same in every build of the version, whichever compiler made it.
    var source_sha256: []const u8 = "";
    var note: ?[]const u8 = null;
    switch (try source_digest.ofPackage(arena, m, std.fs.path.dirname(f.manifest) orelse ".", f.manifest)) {
        .digest => |d| source_sha256 = try arena.dupe(u8, &d),
        .no_library => |lib| note = try source_digest.noLibraryNote(arena, m, lib),
        .bad => |reason| {
            err("{s}: {s}\n", .{ f.manifest, reason });
            return null;
        },
    }

    var packs = std.ArrayList(conda.Packed).init(arena);
    for (f.mojoc) |entry| {
        const bytes = std.fs.cwd().readFileAlloc(arena, entry.path, 1 << 30) catch |e| {
            err("{s}: {s}\n", .{ entry.path, @errorName(e) });
            return null;
        };
        if (bytes.len == 0) {
            err("{s} is empty\n", .{entry.path});
            return null;
        }
        const p = try conda.pack(arena, .{
            .name = m.package.full_name,
            .version = m.package.version,
            .compiler = f.compiler,
            .subdir = entry.subdir,
            .deps = deps,
            .native_deps = native_deps,
            .mojoc = bytes,
            .natives = native_files.get(entry.subdir) orelse &.{},
            .bins = bins,
            .source_sha256 = source_sha256,
        });
        if (cmd == .publish and p.bytes.len > max_file_bytes) {
            err("{s} is {d} bytes; a package file is at most {d} bytes\n", .{ p.file_name, p.bytes.len, max_file_bytes });
            return null;
        }
        try packs.append(p);
    }
    if (cmd == .publish and packs.items.len > max_files) {
        err("{d} files; a version has at most {d}\n", .{ packs.items.len, max_files });
        return null;
    }
    return .{ .m = m, .packs = packs.items, .manifest_dir = std.fs.path.dirname(f.manifest) orelse ".", .note = note };
}

/// What `nativeFiles` found: the archives by subdir, or why the package cannot be packed.
const Files = union(enum) { ok: std.StringHashMap([]const conda.Native), bad: []const u8 };

fn nativeBad(arena: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!Files {
    return .{ .bad = try std.fmt.allocPrint(arena, fmt, args) };
}

/// The static archives to pack, by subdir: for each `[native.<id>]` of `m` and each subdir `f.mojoc` packs, the file
/// `--native` names, read and checked, or the reason it cannot be done. The registry wants every subdir's file to hold every
/// native the metadata declares and every file of the version to carry the same `.mopm.json`, so a native without an
/// archive for a subdir, a `--native` that nothing declares or packs, and a soname that differs between subdirs are
/// refused here, before a byte is packed.
fn nativeFiles(arena: Allocator, m: manifest.Manifest, f: Flags) anyerror!Files {
    var by_subdir = std.StringHashMap([]const conda.Native).init(arena);
    for (f.natives) |nf| {
        var declared = false;
        for (m.native) |n| declared = declared or std.mem.eql(u8, n.id, nf.id);
        if (!declared) {
            return nativeBad(arena, "--native {s}=...: {s} declares no [native.{s}]", .{ nf.id, f.manifest, nf.id });
        }
        var packed_here = false;
        for (f.mojoc) |entry| packed_here = packed_here or std.mem.eql(u8, entry.subdir, nf.subdir);
        if (!packed_here) {
            return nativeBad(arena, "--native {s}={s}:...: no --mojoc packs the subdir {s}", .{ nf.id, nf.subdir, nf.subdir });
        }
    }
    if (m.native.len == 0) return .{ .ok = by_subdir };
    for (f.mojoc) |entry| {
        if (std.mem.eql(u8, entry.subdir, "noarch")) {
            return nativeBad(arena, "{s} declares native libraries, which are built for one platform; pack linux-64 (or another subdir), not noarch", .{f.manifest});
        }
    }
    for (f.mojoc) |entry| {
        var list = std.ArrayList(conda.Native).init(arena);
        for (m.native) |n| {
            var found: ?NativeFile = null;
            for (f.natives) |nf| {
                if (std.mem.eql(u8, nf.id, n.id) and std.mem.eql(u8, nf.subdir, entry.subdir)) found = nf;
            }
            const nf = found orelse {
                return nativeBad(arena, "native library '{s}' has no archive for {s}: add --native {s}={s}:<lib<name>.a>", .{ n.id, entry.subdir, n.id, entry.subdir });
            };
            const bytes = std.fs.cwd().readFileAlloc(arena, nf.path, 1 << 30) catch |e| {
                return nativeBad(arena, "{s}: {s}", .{ nf.path, @errorName(e) });
            };
            const native = conda.Native{ .id = n.id, .soname = std.fs.path.basename(nf.path), .needs = n.needs, .exclusive = n.exclusive, .link = n.link, .archive = bytes };
            if (try conda.nativeProblem(arena, native)) |why| {
                return nativeBad(arena, "{s}: {s}", .{ nf.path, why });
            }
            // A native the build system builds from `srcs`, or another rule provides, has the name the unit graph gave its archive; consumers' `needs` name it.
            if (n.srcs.len > 0 or n.provided) {
                const want = try n.archiveName(arena);
                if (!std.mem.eql(u8, want, native.soname)) {
                    return nativeBad(arena, "{s}: native library '{s}' is built as {s} (its soname in {s}); the archive given is named {s}", .{ nf.path, n.id, want, f.manifest, native.soname });
                }
            }
            // The first subdir fixes the name; a later one that differs would make a different `.mopm.json`.
            for (by_subdir.get(f.mojoc[0].subdir) orelse &.{}) |first| {
                if (std.mem.eql(u8, first.id, n.id) and !std.mem.eql(u8, first.soname, native.soname)) {
                    return nativeBad(arena, "native library '{s}' is {s} for {s} but {s} for {s}; every subdir's file carries the same metadata, so the archive has one name", .{ n.id, first.soname, f.mojoc[0].subdir, native.soname, entry.subdir });
                }
            }
            try list.append(native);
        }
        try by_subdir.put(entry.subdir, list.items);
    }
    return .{ .ok = by_subdir };
}

/// The version of the package each path dependency (with a version) names, read from its own mopm.toml beside
/// `manifest_dir`. Null after printing why not. A path dependency with no version is left for `depsOf` to refuse.
fn pathVersions(arena: Allocator, m: manifest.Manifest, manifest_dir: []const u8) anyerror!?[]const conda.PathVersion {
    var out = std.ArrayList(conda.PathVersion).init(arena);
    for (m.dependencies) |d| {
        const p = switch (d.source) {
            .path => |p| p,
            .version => continue,
        };
        if (d.requirement == null) continue;
        const file = try std.fs.path.join(arena, &.{ manifest_dir, p, "mopm.toml" });
        const src = std.fs.cwd().readFileAlloc(arena, file, 1 << 20) catch |e| {
            err("{s}: dependency '{s}' has the path '{s}', which cannot be read: {s}\n", .{ file, d.full_name, p, @errorName(e) });
            return null;
        };
        var diag: manifest.Diagnostic = .{};
        const dm = manifest.parse(arena, src, &diag) catch |e| {
            if (e == error.Invalid) {
                err("{s}:{d}:{d}: {s}\n", .{ file, diag.pos.line, diag.pos.col, diag.message });
            } else {
                err("{s}: {s}\n", .{ file, @errorName(e) });
            }
            return null;
        };
        if (!std.mem.eql(u8, dm.package.full_name, d.full_name)) {
            err("{s} names the package {s}, but dependency '{s}' calls it {s}\n", .{ file, dm.package.full_name, d.full_name, d.full_name });
            return null;
        }
        if (!dm.package.publish) {
            err("{s} depends on {s} (at {s}), which has publish = false; a published package cannot need one that is never published (a dev-dependency may)\n", .{ m.package.full_name, d.full_name, file });
            return null;
        }
        try out.append(.{ .name = d.full_name, .version = dm.package.version });
    }
    return out.items;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// The readme text to send, or null for none; `refused` is set when the
/// readme is wrong (after printing why).
fn loadReadme(arena: Allocator, f: Flags, prep: Prepared, refused: *bool) anyerror!?[]const u8 {
    var path: []const u8 = undefined;
    if (f.readme) |p| {
        path = p;
    } else if (prep.m.package.readme) |r| {
        path = try std.fs.path.join(arena, &.{ prep.manifest_dir, r });
    } else {
        path = try std.fs.path.join(arena, &.{ prep.manifest_dir, "README.md" });
        if (!fileExists(path)) return null;
    }
    const bytes = std.fs.cwd().readFileAlloc(arena, path, 1 << 24) catch |e| switch (e) {
        error.FileTooBig => {
            err("{s} is over 16 MiB; a readme is at most {d} bytes (the registry serves at most 64 KiB)\n", .{ path, max_readme_bytes });
            refused.* = true;
            return null;
        },
        else => {
            err("{s}: {s}\n", .{ path, @errorName(e) });
            refused.* = true;
            return null;
        },
    };
    if (try readmeProblem(arena, path, bytes)) |why| {
        err("{s}\n", .{why});
        refused.* = true;
        return null;
    }
    return bytes;
}

pub fn main(arena: Allocator, cmd_name: []const u8, args: []const []const u8, cli_version: []const u8) u8 {
    if (std.mem.eql(u8, cmd_name, "publish") and group_publish.wants(args)) return group_publish.main(arena, args, cli_version);
    const cmd: Cmd = if (std.mem.eql(u8, cmd_name, "pack")) .pack else .publish;
    const parsed = parseFlags(arena, cmd, args) catch return 1;
    const f = switch (parsed) {
        .ok => |f| f,
        .bad => |why| {
            err("{s}\n", .{why});
            std.io.getStdErr().writeAll(usage) catch {};
            return 2;
        },
    };
    const result = switch (cmd) {
        .pack => packCmd(arena, f),
        .publish => publishCmd(arena, f, cli_version),
    };
    return result catch |e| {
        err("{s}\n", .{@errorName(e)});
        return 1;
    };
}

fn packCmd(arena: Allocator, f: Flags) anyerror!u8 {
    const prep = (try prepare(arena, .pack, f)) orelse return 1;
    if (prep.note) |n| err("{s}\n", .{n});
    const out = std.io.getStdOut().writer();
    for (prep.packs) |p| {
        const dir = try std.fs.path.join(arena, &.{ f.out, p.subdir });
        try std.fs.cwd().makePath(dir);
        const path = try std.fs.path.join(arena, &.{ dir, p.file_name });
        try std.fs.cwd().writeFile(path, p.bytes);
        try out.print("packed {s}\n  sha256 {s}\n  size {d}\n  manifest_sha256 {s}\n", .{ path, &p.sha256, p.bytes.len, &p.manifest_sha256 });
        for (p.natives) |n| try out.print("  native {s} sha256 {s} size {d}\n", .{ n.soname, &n.sha256, n.size });
    }
    return 0;
}

/// `$MOPM_TOKEN` if set and not empty, else the stored credential.
pub fn findToken(s: registry_cmd.Session) anyerror!?[]const u8 {
    if (std.process.getEnvVarOwned(s.arena, "MOPM_TOKEN")) |t| {
        const trimmed = std.mem.trim(u8, t, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    } else |_| {}
    if (try credentials.load(s.arena, s.config_dir, s.config.api_url)) |e| return e.token;
    return null;
}

fn publishCmd(arena: Allocator, f: Flags, cli_version: []const u8) anyerror!u8 {
    const prep = (try prepare(arena, .publish, f)) orelse return 1;
    if (prep.note) |n| err("{s}\n", .{n});
    var refused = false;
    const readme = try loadReadme(arena, f, prep, &refused);
    if (refused) return 1;
    const out = std.io.getStdOut().writer();
    const name = prep.m.package.full_name;
    const version = prep.m.package.version;

    if (f.dry_run) {
        for (prep.packs) |p| {
            try out.print("would upload {s}/{s} ({d} bytes, sha256 {s})\n", .{ p.subdir, p.file_name, p.bytes.len, &p.sha256 });
        }
        try out.print("would commit {s} {s} (manifest_sha256 {s})\n", .{ name, version, &prep.packs[0].manifest_sha256 });
        if (readme) |r| try out.print("would send a readme of {d} bytes\n", .{r.len});
        try out.writeAll("dry run: nothing was sent\n");
        return 0;
    }

    // --oidc outside a job that can ask for an identity: stop before any request.
    const actions = if (f.oidc) (ci_oidc.actionsFromEnv(arena) orelse {
        err("{s}\n", .{ci_oidc.outside_actions});
        return 1;
    }) else null;
    const s = registry_cmd.open(arena, .{ .registry = f.registry, .config_dir = f.config_dir }, cli_version) orelse return 1;
    const token = if (actions) |act| switch (try ci_oidc.obtain(arena, http.Real{}, .{}, act, s.config.api_v2_url, s.config.stage, name, version)) {
        .ok => |t| t,
        .bad => |why| {
            err("{s}\n", .{why});
            return 1;
        },
    } else (try findToken(s)) orelse {
        err("not logged in to {s}; run 'mopm login' or set MOPM_TOKEN\n", .{s.config.stage});
        return 1;
    };

    // The package is created when the registry does not have it; the right to write its namespace is the registry's to check, and
    // it does so before anything is uploaded.
    var con = group_publish.Console.init(arena, group_publish.Console.stdStreams);
    if (!try ensurePackage(arena, group_publish.realNet(), &con, s.config.api_v2_url, token, s.config.stage, name)) return 1;

    var ids = std.ArrayList([]const u8).init(arena);
    for (prep.packs) |p| {
        const id = (try uploadFile(s, token, name, version, p)) orelse return 1;
        try ids.append(id);
        try out.print("uploaded {s} ({s})\n", .{ p.file_name, p.subdir });
    }

    // Commit.
    const full = fullOf(name) orelse {
        err(not_full, .{name});
        return 1;
    };
    const commit = v2.CommitPublishParams{
        .namespace = full.namespace,
        .name = full.name,
        .version = version,
        .body = .{ .upload_ids = ids.items, .manifest_sha256 = &prep.packs[0].manifest_sha256, .readme = readme },
    };
    const committed = try v2.sendOnce(v2.CommitPublish, arena, http.Real{}, s.config.api_v2_url, token, commit);
    if (!committed.ok()) {
        registry_cmd.printFailure(committed);
        return 1;
    }
    const accepted = try v2.decode(v2.CommitPublish, arena, committed.body);
    try out.print("committed, publish {s}\n", .{accepted.publish_id});
    return waitForPublish(s, group_publish.realNet(), &con, wait_secs, token, accepted.publish_id, name, version);
}

/// Makes sure the package `name` (a full name) exists on the registry, before anything of it is uploaded: `PUT <api_v2_url>/packages/<name>`
/// with the token and an empty body. The registry checks that the token's user may write the namespace; it answers 201 for a
/// package it created, which this says (`created <name> on <stage>`), and 200 for one it already had, which is a no-op and
/// is not said. Any other answer is printed as every failed request is and the result is false, so the caller stops before
/// an upload. A request that fails before an answer is said the same way.
pub fn ensurePackage(arena: Allocator, net: group_publish.Net, con: *group_publish.Console, api_v2_url: []const u8, token: []const u8, stage: []const u8, name: []const u8) Allocator.Error!bool {
    const full = fullOf(name) orelse {
        con.fail(not_full, .{name});
        return false;
    };
    // An empty body, not none: the request then carries `Content-Length: 0`, which a PUT needs.
    const answer = v2.send(v2.CreatePackage, arena, EmptyBody{ .net = net }, net.policy, api_v2_url, token, .{ .namespace = full.namespace, .name = full.name }) catch |e| {
        con.fail("PUT /packages/{s}: {s}\n", .{ name, @errorName(e) });
        return false;
    };
    if (answer.status == 200) return true;
    if (answer.status == 201) {
        con.say("created {s} on {s}\n", .{ name, stage });
        return true;
    }
    registry_cmd.reportFailure(con, answer);
    return false;
}

/// The net a request without a body goes through with an empty body and no `Content-Type`, so that it carries `Content-Length: 0`.
const EmptyBody = struct {
    net: group_publish.Net,

    pub fn once(self: EmptyBody, arena: Allocator, method: std.http.Method, url: []const u8, options: http.Options) anyerror!http.Answer {
        var sent = options;
        sent.body = "";
        sent.content_type = null;
        // not the registry API: the transport under v2.send for createPackage, which sends no Content-Type and an empty body
        return self.net.once(arena, method, url, sent);
    }

    pub fn pause(self: EmptyBody, secs: u64) void {
        self.net.pause(secs);
    }
};

/// `name` split into its namespace and name for a v2 path; null for a name that is not a full name `<namespace>/<name>`
/// (the manifest checks guarantee one, so this only keeps a bare name from ever becoming a request).
fn fullOf(name: []const u8) ?core.names.FullName {
    return core.names.split(name);
}

/// What is said of a package name that is not a full name, before any request is sent.
const not_full = "'{s}' is not a full name <namespace>/<name>\n";

/// Every header the registry named for a PUT, as given (the client sets Content-Length itself from the body, to the same
/// value); null after printing why not, when a header's value is not text.
pub fn putHeaders(arena: Allocator, put_headers: ?std.json.Value) Allocator.Error!?[]const std.http.Header {
    var headers = std.ArrayList(std.http.Header).init(arena);
    if (put_headers) |ph| switch (ph) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                const value = switch (e.value_ptr.*) {
                    .string => |v| v,
                    else => {
                        err("the registry named an upload header that is not text\n", .{});
                        return null;
                    },
                };
                if (std.ascii.eqlIgnoreCase(e.key_ptr.*, "content-length")) continue;
                try headers.append(.{ .name = e.key_ptr.*, .value = value });
            }
        },
        else => {},
    };
    return headers.items;
}

/// `putHeaders` of the headers `beginUpload` answered (a JSON object of strings).
fn putHeadersOf(arena: Allocator, named: std.json.ArrayHashMap([]const u8)) Allocator.Error!?[]const std.http.Header {
    var object = std.json.ObjectMap.init(arena);
    var it = named.map.iterator();
    while (it.next()) |h| try object.put(h.key_ptr.*, .{ .string = h.value_ptr.* });
    return putHeaders(arena, .{ .object = object });
}

/// Begins the upload of `p` and PUTs its bytes; the upload id, or null after
/// printing why not.
fn uploadFile(s: registry_cmd.Session, token: []const u8, name: []const u8, version: []const u8, p: conda.Packed) anyerror!?[]const u8 {
    const arena = s.arena;
    const full = fullOf(name) orelse {
        err(not_full, .{name});
        return null;
    };
    const begin = v2.BeginUploadParams{
        .namespace = full.namespace,
        .name = full.name,
        .version = version,
        .body = .{ .subdir = std.meta.stringToEnum(v2.Subdir, p.subdir) orelse .unknown, .filename = p.file_name, .sha256 = &p.sha256, .size = @intCast(p.bytes.len) },
    };
    const begun = try v2.sendOnce(v2.BeginUpload, arena, http.Real{}, s.config.api_v2_url, token, begin);
    if (!begun.ok()) {
        registry_cmd.printFailure(begun);
        return null;
    }
    const up = v2.decode(v2.BeginUpload, arena, begun.body) catch |e| {
        // An upload header whose value is not text is said as before the answer was decoded with the generated type.
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, begun.body, .{}) catch null) |value| {
            if (value == .object) if (value.object.get("put_headers")) |named| {
                if ((try putHeaders(arena, named)) == null) return null;
            };
        }
        return e;
    };
    if (!registry.allowedUrl(up.put_url)) {
        err("the registry named an upload URL that is neither https nor loopback http\n", .{});
        return null;
    }

    const headers = (try putHeadersOf(arena, up.put_headers)) orelse return null;
    // No bearer token: the URL is presigned.
    // not the registry API: the file is PUT to the storage URL the registry signed
    const put = try http.request(arena, .PUT, up.put_url, .{
        .body = p.bytes,
        .content_type = null,
        .extra_headers = headers,
    });
    if (!put.ok()) {
        err("uploading {s} failed: the storage answered HTTP {d}\n", .{ p.file_name, put.status });
        return null;
    }
    return up.upload_id;
}

/// Polls the publish `publish_id` until it is published or rejected, or `wait` seconds of `net`'s clock have passed. The
/// clock and the pauses are `net`'s and everything it says goes through `con`, so a test drives it without waiting and
/// without touching the real standard streams.
fn waitForPublish(s: registry_cmd.Session, net: group_publish.Net, con: *group_publish.Console, wait: i64, token: []const u8, publish_id: []const u8, name: []const u8, version: []const u8) anyerror!u8 {
    const arena = s.arena;
    const deadline = net.now() + wait;
    while (net.now() < deadline) {
        const polled = try v2.sendOnce(v2.GetPublishStatus, arena, net, s.config.api_v2_url, token, .{ .publish_id = publish_id });
        if (polled.status == 429) {
            net.pause(@min(polled.retry_after orelse 1, 60));
            continue;
        }
        if (!polled.ok()) {
            registry_cmd.reportFailure(con, polled);
            return 1;
        }
        const state = try v2.decode(v2.GetPublishStatus, arena, polled.body);
        const finished = state.status == .published or state.status == .rejected;
        if (finished) {
            for (state.warnings orelse &.{}) |w| con.fail("warning: {s}\n", .{w});
        }
        if (state.status == .published) {
            con.say("published {s} {s}\n", .{ name, version });
            return 0;
        }
        if (state.status == .rejected) {
            con.fail("rejected: {s}: {s}\n", .{ if (state.rejection_code) |c| @tagName(c) else "unknown", state.message orelse "" });
            return 1;
        }
        net.pause(1);
    }
    const url = try v2.url(v2.GetPublishStatus, arena, s.config.api_v2_url, .{ .publish_id = publish_id });
    con.fail("gave up waiting for the publish after {d} minutes; it may still finish: check 'GET {s}'\n", .{ @divTrunc(wait, 60), url });
    return 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn parseOk(a: Allocator, cmd: Cmd, args: []const []const u8) !Flags {
    const parsed = try parseFlags(a, cmd, args);
    try std.testing.expectEqualStrings("", if (parsed == .bad) parsed.bad else "");
    return parsed.ok;
}

fn parseBad(a: Allocator, cmd: Cmd, args: []const []const u8, needle: []const u8) !void {
    const parsed = try parseFlags(a, cmd, args);
    try std.testing.expect(parsed == .bad);
    try std.testing.expect(std.mem.indexOf(u8, parsed.bad, needle) != null);
}

test "--oidc is a flag of publish and takes no value; pack does not know it" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const base = [_][]const u8{ "--compiler", "1.0.0", "--mojoc", "a.mojoc" };
    try std.testing.expect(!(try parseOk(a, .publish, &base)).oidc);
    const f = try parseOk(a, .publish, &(base ++ [_][]const u8{ "--oidc", "--registry", "beta" }));
    try std.testing.expect(f.oidc);
    try std.testing.expectEqualStrings("beta", f.registry);
    // It takes no value: a word after it is not one.
    try parseBad(a, .publish, &(base ++ [_][]const u8{ "--oidc", "yes" }), "unexpected argument 'yes'");
    try parseBad(a, .pack, &(base ++ [_][]const u8{"--oidc"}), "unexpected argument '--oidc'");
}

test "pack and publish flags" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();

    const p = try parseOk(a, .pack, &.{ "--compiler", "1.0.0", "--mojoc", "a.mojoc", "--mojoc", "linux-64=b.mojoc", "-o", "out", "--manifest", "m/mopm.toml" });
    try std.testing.expectEqualStrings("1.0.0", p.compiler);
    try std.testing.expectEqual(@as(usize, 2), p.mojoc.len);
    try std.testing.expectEqualStrings("noarch", p.mojoc[0].subdir);
    try std.testing.expectEqualStrings("a.mojoc", p.mojoc[0].path);
    try std.testing.expectEqualStrings("linux-64", p.mojoc[1].subdir);
    try std.testing.expectEqualStrings("b.mojoc", p.mojoc[1].path);
    try std.testing.expectEqualStrings("out", p.out);
    try std.testing.expectEqualStrings("m/mopm.toml", p.manifest);

    const q = try parseOk(a, .publish, &.{ "--mojoc", "osx-arm64=x=y.mojoc", "--compiler", "1.0.0", "--registry", "beta", "--config-dir", "c", "--readme", "R.md", "--dry-run" });
    try std.testing.expectEqualStrings("osx-arm64", q.mojoc[0].subdir);
    try std.testing.expectEqualStrings("x=y.mojoc", q.mojoc[0].path);
    try std.testing.expect(q.dry_run);
    try std.testing.expectEqualStrings("beta", q.registry);
    try std.testing.expectEqualStrings("c", q.config_dir.?);
    try std.testing.expectEqualStrings("R.md", q.readme.?);
    try std.testing.expectEqualStrings("mopm.toml", q.manifest);

    // A path with '=' after a '/' is a path, not a subdir.
    const r = try parseOk(a, .pack, &.{ "--compiler", "1.0.0", "--mojoc", "dir/a=b.mojoc" });
    try std.testing.expectEqualStrings("noarch", r.mojoc[0].subdir);
    try std.testing.expectEqualStrings("dir/a=b.mojoc", r.mojoc[0].path);

    try parseBad(a, .pack, &.{ "--mojoc", "a.mojoc" }, "--compiler");
    try parseBad(a, .pack, &.{ "--compiler", "1.0.0" }, "--mojoc");
    try parseBad(a, .pack, &.{ "--compiler", "1.0.0", "--mojoc", "win-64=a" }, "not a subdir");
    try parseBad(a, .pack, &.{ "--compiler", "1.0.0", "--mojoc", "a", "--mojoc", "noarch=b" }, "twice");
    try parseBad(a, .pack, &.{ "--compiler", "1.0.0", "--mojoc", "a", "--dry-run" }, "unexpected argument");
    try parseBad(a, .pack, &.{ "--compiler", "1.0.0", "--mojoc", "a", "--registry", "beta" }, "unexpected argument");
    try parseBad(a, .publish, &.{ "--compiler", "1.0.0", "--mojoc", "a", "-o", "x" }, "unexpected argument");
    try parseBad(a, .publish, &.{ "--compiler", "1.0.0", "--mojoc" }, "needs a value");
    try parseBad(a, .publish, &.{ "--compiler", "1.0.0", "--mojoc", "linux-64=" }, "no file");
}

test "--native names an archive per native library and subdir, and nothing that is not one" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const f = try parseOk(a, .pack, &.{ "--compiler", "1.0.0", "--mojoc", "linux-64=m", "--native", "tls_sys=linux-64:dist/libtls_sys.a", "--native", "tls_sys=osx-arm64:other/libtls_sys.a", "--native", "z=linux-64:a:b" });
    try std.testing.expectEqual(@as(usize, 3), f.natives.len);
    try std.testing.expectEqualStrings("tls_sys", f.natives[0].id);
    try std.testing.expectEqualStrings("linux-64", f.natives[0].subdir);
    try std.testing.expectEqualStrings("dist/libtls_sys.a", f.natives[0].path);
    try std.testing.expectEqualStrings("osx-arm64", f.natives[1].subdir);
    // The first colon after the id ends the subdir: the rest is a path, colons and all.
    try std.testing.expectEqualStrings("a:b", f.natives[2].path);
    // publish takes them too.
    const g = try parseOk(a, .publish, &.{ "--compiler", "1.0.0", "--mojoc", "linux-64=m", "--native", "x=linux-64:p", "--dry-run" });
    try std.testing.expectEqual(@as(usize, 1), g.natives.len);

    try parseBad(a, .pack, &.{ "--compiler", "1.0.0", "--mojoc", "m", "--native", "libx.a" }, "expected <id>=<subdir>:<file>");
    try parseBad(a, .pack, &.{ "--compiler", "1.0.0", "--mojoc", "m", "--native", "x=linux-64" }, "expected <id>=<subdir>:<file>");
    try parseBad(a, .pack, &.{ "--compiler", "1.0.0", "--mojoc", "m", "--native", "=linux-64:p" }, "expected <id>=<subdir>:<file>");
    try parseBad(a, .pack, &.{ "--compiler", "1.0.0", "--mojoc", "m", "--native", "x=linux-64:" }, "expected <id>=<subdir>:<file>");
    try parseBad(a, .pack, &.{ "--compiler", "1.0.0", "--mojoc", "m", "--native", "x=win-64:p" }, "is not a subdir");
    try parseBad(a, .pack, &.{ "--compiler", "1.0.0", "--mojoc", "m", "--native", "x=noarch:p" }, "cannot be packed for noarch");
    try parseBad(a, .pack, &.{ "--compiler", "1.0.0", "--mojoc", "m", "--native", "x=linux-64:p", "--native", "x=linux-64:q" }, "--native names x for linux-64 twice");
    try parseBad(a, .pack, &.{ "--compiler", "1.0.0", "--mojoc", "m", "--native" }, "needs a value");
}

const native_manifest_text =
    \\[package]
    \\name = "example/demo"
    \\version = "0.1.0"
    \\
    \\[toolchain]
    \\mojo = "1.0.0"
    \\
    \\[native.nat]
    \\kind = "static"
    \\needs = ["libz.a"]
    \\exclusive = "libnat"
    \\
;

fn nativeOk(a: Allocator, m: manifest.Manifest, f: Flags) !std.StringHashMap([]const conda.Native) {
    const found = try nativeFiles(a, m, f);
    // A refusal is the test's failure; its reason is what `expectEqualStrings` shows.
    if (found == .bad) try std.testing.expectEqualStrings("", found.bad);
    return found.ok;
}

fn nativeFlags(mojoc: []const Mojoc, natives: []const NativeFile) Flags {
    return .{ .compiler = "1.0.0", .mojoc = mojoc, .natives = natives, .manifest = "m/mopm.toml" };
}

test "nativeFiles reads the archive of each native library for each subdir it packs, and refuses what the registry would" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("linux");
    try tmp.dir.makePath("osx");
    try tmp.dir.writeFile("linux/libnat.a", "!<arch>\nlinux\n");
    try tmp.dir.writeFile("osx/libnat.a", "!<arch>\nosx\n");
    try tmp.dir.writeFile("osx/libother.a", "!<arch>\nosx\n");
    try tmp.dir.makePath("bad");
    try tmp.dir.writeFile("bad/libnat.a", "not an archive at all");
    const root = try tmp.dir.realpathAlloc(a, ".");
    const p = struct {
        fn of(arena: Allocator, r: []const u8, rel: []const u8) []const u8 {
            return std.fs.path.join(arena, &.{ r, rel }) catch unreachable;
        }
    }.of;
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, native_manifest_text, &diag);
    const linux = Mojoc{ .subdir = "linux-64", .path = "x" };
    const osx = Mojoc{ .subdir = "osx-arm64", .path = "x" };
    const n_linux = NativeFile{ .id = "nat", .subdir = "linux-64", .path = p(a, root, "linux/libnat.a") };
    const n_osx = NativeFile{ .id = "nat", .subdir = "osx-arm64", .path = p(a, root, "osx/libnat.a") };

    // Both subdirs: each gets its own archive, named for the library, with the manifest's needs and group.
    const got = try nativeOk(a, m, nativeFlags(&.{ linux, osx }, &.{ n_linux, n_osx }));
    const l = got.get("linux-64").?;
    try std.testing.expectEqual(@as(usize, 1), l.len);
    try std.testing.expectEqualStrings("nat", l[0].id);
    try std.testing.expectEqualStrings("libnat.a", l[0].soname);
    try std.testing.expectEqualStrings("libz.a", l[0].needs[0]);
    try std.testing.expectEqualStrings("libnat", l[0].exclusive);
    try std.testing.expectEqualStrings("!<arch>\nlinux\n", l[0].archive);
    try std.testing.expectEqualStrings("!<arch>\nosx\n", got.get("osx-arm64").?[0].archive);

    // A manifest with no native libraries packs as it always did: no entries, whatever the subdirs.
    const plain = try manifest.parse(a, "[package]\nname = \"example/demo\"\nversion = \"0.1.0\"\n\n[toolchain]\nmojo = \"1.0.0\"\n", &diag);
    const none = try nativeOk(a, plain, nativeFlags(&.{.{ .subdir = "noarch", .path = "x" }}, &.{}));
    try std.testing.expectEqual(@as(u32, 0), none.count());

    // Each of these is a refusal, with its reason.
    const noarch = Mojoc{ .subdir = "noarch", .path = "x" };
    const Refusal = struct { flags: Flags, want: []const u8 };
    const refusals = [_]Refusal{
        .{ .flags = nativeFlags(&.{ linux, osx }, &.{n_linux}), .want = "native library 'nat' has no archive for osx-arm64" },
        .{ .flags = nativeFlags(&.{linux}, &.{ n_linux, .{ .id = "other", .subdir = "linux-64", .path = "x" } }), .want = "declares no [native.other]" },
        .{ .flags = nativeFlags(&.{linux}, &.{ n_linux, n_osx }), .want = "no --mojoc packs the subdir osx-arm64" },
        .{ .flags = nativeFlags(&.{ linux, noarch }, &.{n_linux}), .want = "built for one platform" },
        .{ .flags = nativeFlags(&.{linux}, &.{.{ .id = "nat", .subdir = "linux-64", .path = p(a, root, "bad/libnat.a") }}), .want = "is not a static archive (it does not start with !<arch>)" },
        .{ .flags = nativeFlags(&.{linux}, &.{.{ .id = "nat", .subdir = "linux-64", .path = p(a, root, "absent.a") }}), .want = "FileNotFound" },
        .{ .flags = nativeFlags(&.{ linux, osx }, &.{ n_linux, .{ .id = "nat", .subdir = "osx-arm64", .path = p(a, root, "osx/libother.a") } }), .want = "is libnat.a for linux-64 but libother.a for osx-arm64" },
    };
    for (refusals) |r| {
        const found = try nativeFiles(a, m, r.flags);
        try std.testing.expect(found == .bad);
        try std.testing.expect(std.mem.indexOf(u8, found.bad, r.want) != null);
    }
}

test "a member's native built from srcs is packed from the archive the build system gives, under the soname the graph names" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile("libshim.a", "!<arch>\nshim\n");
    try tmp.dir.writeFile("libother.a", "!<arch>\nother\n");
    const root = try tmp.dir.realpathAlloc(a, ".");
    var diag: manifest.Diagnostic = .{};
    const head = "[package]\nname = \"example/demo\"\nversion = \"0.1.0\"\n\n[toolchain]\nmojo = \"1.0.0\"\n\n";
    const m = try manifest.parse(a, head ++ "[native.shim]\nkind = \"static\"\nsrcs = [\"native/*.c\"]\n", &diag);
    const renamed = try manifest.parse(a, head ++ "[native.shim]\nkind = \"static\"\nsrcs = [\"native/*.c\"]\nsoname = \"libother.a\"\n", &diag);
    const linux = Mojoc{ .subdir = "linux-64", .path = "x" };
    const file = NativeFile{ .id = "shim", .subdir = "linux-64", .path = try std.fs.path.join(a, &.{ root, "libshim.a" }) };

    // The archive is packed as a registry native is; its name is lib<id>.a, the soname the unit graph gave it.
    const got = try nativeOk(a, m, nativeFlags(&.{linux}, &.{file}));
    const packed_native = got.get("linux-64").?[0];
    try std.testing.expectEqualStrings("shim", packed_native.id);
    try std.testing.expectEqualStrings("libshim.a", packed_native.soname);
    try std.testing.expectEqualStrings("!<arch>\nshim\n", packed_native.archive);

    // An archive under another name than the unit's soname is refused: consumers' `needs` name the soname.
    const found = try nativeFiles(a, renamed, nativeFlags(&.{linux}, &.{file}));
    try std.testing.expect(found == .bad);
    try std.testing.expect(std.mem.indexOf(u8, found.bad, "native library 'shim' is built as libother.a") != null);
    try std.testing.expect(std.mem.indexOf(u8, found.bad, "the archive given is named libshim.a") != null);
    // Pack checks the name only for a native with `srcs`; one without keeps the name of the file it is given.
    const legacy = try manifest.parse(a, head ++ "[native.shim]\nkind = \"static\"\n", &diag);
    const other_file = NativeFile{ .id = "shim", .subdir = "linux-64", .path = try std.fs.path.join(a, &.{ root, "libother.a" }) };
    const kept = try nativeOk(a, legacy, nativeFlags(&.{linux}, &.{other_file}));
    try std.testing.expectEqualStrings("libother.a", kept.get("linux-64").?[0].soname);
}

test "a provided native is packed under lib<id>.a or its soname, and an archive named otherwise is refused" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile("libshim.a", "!<arch>\nshim\n");
    try tmp.dir.writeFile("libother.a", "!<arch>\nother\n");
    const root = try tmp.dir.realpathAlloc(a, ".");
    var diag: manifest.Diagnostic = .{};
    const head = "[package]\nname = \"example/demo\"\nversion = \"0.1.0\"\n\n[toolchain]\nmojo = \"1.0.0\"\n\n";
    const m = try manifest.parse(a, head ++ "[native.shim]\nkind = \"static\"\nprovided = true\n", &diag);
    const linux = Mojoc{ .subdir = "linux-64", .path = "x" };
    const right = NativeFile{ .id = "shim", .subdir = "linux-64", .path = try std.fs.path.join(a, &.{ root, "libshim.a" }) };
    const wrong = NativeFile{ .id = "shim", .subdir = "linux-64", .path = try std.fs.path.join(a, &.{ root, "libother.a" }) };

    const got = try nativeOk(a, m, nativeFlags(&.{linux}, &.{right}));
    try std.testing.expectEqualStrings("libshim.a", got.get("linux-64").?[0].soname);

    const found = try nativeFiles(a, m, nativeFlags(&.{linux}, &.{wrong}));
    try std.testing.expect(found == .bad);
    try std.testing.expect(std.mem.indexOf(u8, found.bad, "native library 'shim' is built as libshim.a") != null);
    try std.testing.expect(std.mem.indexOf(u8, found.bad, "the archive given is named libother.a") != null);
}

test "version refusals" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    try std.testing.expect((try versionProblem(a, "1.0.0")) == null);
    try std.testing.expect((try versionProblem(a, "0.0.0")) == null);
    for ([_][]const u8{ "1.0", "1", "1.0.0-rc.1", "1.0.0+7", "01.0.0", "1.0.0.0", "1.0.a" }) |v| {
        const why = (try versionProblem(a, v)) orelse "(accepted)";
        try std.testing.expect(std.mem.indexOf(u8, why, "exactly MAJOR.MINOR.PATCH") != null);
    }
}

test "the readme limit is 64 KiB" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const at_limit = try a.alloc(u8, max_readme_bytes);
    @memset(at_limit, 'a');
    try std.testing.expectEqual(@as(usize, 65536), max_readme_bytes);
    try std.testing.expect((try readmeProblem(a, "README.md", at_limit)) == null);
    const over = try a.alloc(u8, max_readme_bytes + 1);
    @memset(over, 'a');
    const why = (try readmeProblem(a, "README.md", over)).?;
    try std.testing.expect(std.mem.indexOf(u8, why, "at most 65536 bytes") != null);
    try std.testing.expect((try readmeProblem(a, "README.md", "\xff\xfe")) != null);
    try std.testing.expect((try readmeProblem(a, "README.md", "# caf\xc3\xa9\n")) == null);
}

test "a PUT carries the headers the registry named, as given, except the length the client sets itself" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const named = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"x-amz-checksum-sha256\":\"abc=\",\"Content-Length\":\"7\",\"x-amz-meta-n\":\"v\"}", .{});
    const headers = (try putHeaders(a, named)).?;
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("x-amz-checksum-sha256", headers[0].name);
    try std.testing.expectEqualStrings("abc=", headers[0].value);
    try std.testing.expectEqualStrings("x-amz-meta-n", headers[1].name);
    // None named, or not an object: none sent.
    try std.testing.expectEqual(@as(usize, 0), (try putHeaders(a, null)).?.len);
    try std.testing.expectEqual(@as(usize, 0), (try putHeaders(a, .{ .string = "x" })).?.len);
    // A value that is not text is refused.
    const odd = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"x-n\":3}", .{});
    try std.testing.expect((try putHeaders(a, odd)) == null);
}

test "the headers of a beginUpload answer are the PUT's headers as the registry named them" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const up = try v2.decode(v2.BeginUpload, a, "{\"upload_id\":\"up_1\",\"put_url\":\"https://s3.test/x\",\"put_headers\":{\"x-amz-checksum-sha256\":\"abc=\",\"x-amz-meta-n\":\"v\"},\"expires_at\":\"2026-10-25T00:05:00Z\"}");
    try std.testing.expectEqualStrings("up_1", up.upload_id);
    const headers = (try putHeadersOf(a, up.put_headers)).?;
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("x-amz-checksum-sha256", headers[0].name);
    try std.testing.expectEqualStrings("abc=", headers[0].value);
    try std.testing.expectEqualStrings("x-amz-meta-n", headers[1].name);
    try std.testing.expectEqualStrings("v", headers[1].value);
}

const gt = @import("group_publish_test.zig");
const status_head = "{\"publish_id\":\"pub_1\",\"name\":\"example/x\",\"version\":\"1.0.0\",";
const pending = status_head ++ "\"status\":\"validating\"}";
const done = status_head ++ "\"status\":\"published\"}";

fn waitSession(a: Allocator) registry_cmd.Session {
    return .{ .arena = a, .config = .{ .stage = "beta", .api_url = "http://127.0.0.1:1/api/v1", .api_v2_url = "http://127.0.0.1:1/api/v2", .channel_url = "", .min_cli_version = "", .read_only = false }, .config_dir = "unused" };
}

test "the wait for a publish polls once a second on the net's clock until the registry says published" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = group_publish.Console.init(a, null);
    var script = gt.Script{ .steps = &.{
        .{ .method = .GET, .suffix = "pub_1", .status = 200, .body = pending },
        .{ .method = .GET, .suffix = "pub_1", .status = 200, .body = pending },
        .{ .method = .GET, .suffix = "pub_1", .status = 200, .body = done },
    }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 0), try waitForPublish(waitSession(a), script.net(), &con, 600, "tok", "pub_1", "example/x", "1.0.0"));
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqual(@as(usize, 3), script.seen.items.len);
    // One second between polls: two pauses between three polls.
    try std.testing.expectEqual(@as(u64, 2), script.slept);
    for (script.seen.items) |x| try std.testing.expectEqualStrings("tok", x.token.?);
    // What it says goes through the console it was given, not the process's standard output.
    try std.testing.expectEqualStrings("published example/x 1.0.0\n", con.out.items);
    try std.testing.expectEqualStrings("", con.err.items);
}

test "a publish that never finishes is given up on when the net's clock passes the wait, not before" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = group_publish.Console.init(a, null);
    var script = gt.Script{ .steps = &.{.{ .method = .GET, .suffix = "pub_1", .status = 200, .body = pending }}, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try waitForPublish(waitSession(a), script.net(), &con, 5, "tok", "pub_1", "example/x", "1.0.0"));
    // A wait of 5 seconds is five polls, one at each second of the clock, and five pauses: the clock is exactly at the limit.
    try std.testing.expectEqual(@as(usize, 5), script.seen.items.len);
    try std.testing.expectEqual(@as(u64, 5), script.slept);
    try std.testing.expect(std.mem.startsWith(u8, con.err.items, "mopm: gave up waiting for the publish after 0 minutes;"));

    // A wait of zero polls nothing.
    var none = gt.Script{ .steps = &.{.{ .method = .GET, .suffix = "pub_1", .status = 200, .body = pending }}, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try waitForPublish(waitSession(a), none.net(), &con, 0, "tok", "pub_1", "example/x", "1.0.0"));
    try std.testing.expectEqual(@as(usize, 0), none.seen.items.len);
}

test "a 429 waits the registry's Retry-After, one second when it names none, and never more than 60" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = group_publish.Console.init(a, null);
    var named = gt.Script{ .steps = &.{
        .{ .method = .GET, .suffix = "pub_1", .status = 429, .retry_after = 7 },
        .{ .method = .GET, .suffix = "pub_1", .status = 200, .body = done },
    }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 0), try waitForPublish(waitSession(a), named.net(), &con, 600, "tok", "pub_1", "example/x", "1.0.0"));
    try std.testing.expectEqual(@as(u64, 7), named.slept);
    try std.testing.expectEqual(@as(usize, 2), named.seen.items.len);

    var unnamed = gt.Script{ .steps = &.{
        .{ .method = .GET, .suffix = "pub_1", .status = 429 },
        .{ .method = .GET, .suffix = "pub_1", .status = 200, .body = done },
    }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 0), try waitForPublish(waitSession(a), unnamed.net(), &con, 600, "tok", "pub_1", "example/x", "1.0.0"));
    try std.testing.expectEqual(@as(u64, 1), unnamed.slept);

    var huge = gt.Script{ .steps = &.{
        .{ .method = .GET, .suffix = "pub_1", .status = 429, .retry_after = 3600 },
        .{ .method = .GET, .suffix = "pub_1", .status = 200, .body = done },
    }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 0), try waitForPublish(waitSession(a), huge.net(), &con, 600, "tok", "pub_1", "example/x", "1.0.0"));
    try std.testing.expectEqual(@as(u64, 60), huge.slept);

    // A pause that carries the clock past the wait ends the wait: no poll follows it.
    var late = gt.Script{ .steps = &.{.{ .method = .GET, .suffix = "pub_1", .status = 429, .retry_after = 60 }}, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try waitForPublish(waitSession(a), late.net(), &con, 30, "tok", "pub_1", "example/x", "1.0.0"));
    try std.testing.expectEqual(@as(usize, 1), late.seen.items.len);
    try std.testing.expectEqual(@as(u64, 60), late.slept);
}

test "the warnings of a finished publish are printed to standard error, and a status without them or with fields the CLI does not know is as before" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = group_publish.Console.init(a, null);
    var warned = gt.Script{ .steps = &.{
        .{ .method = .GET, .suffix = "pub_1", .status = 200, .body = status_head ++ "\"status\":\"validating\",\"warnings\":[\"not yet\"]}" },
        .{ .method = .GET, .suffix = "pub_1", .status = 200, .body = status_head ++ "\"status\":\"published\",\"warnings\":[\"native dependency 'libpgn' is not a conda-forge package name\",\"second\"],\"future\":{\"a\":1}}" },
    }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 0), try waitForPublish(waitSession(a), warned.net(), &con, 600, "tok", "pub_1", "example/x", "1.0.0"));
    try std.testing.expectEqualStrings("mopm: warning: native dependency 'libpgn' is not a conda-forge package name\nmopm: warning: second\n", con.err.items);
    try std.testing.expectEqualStrings("published example/x 1.0.0\n", con.out.items);
    var plain = group_publish.Console.init(a, null);
    var quiet = gt.Script{ .steps = &.{.{ .method = .GET, .suffix = "pub_1", .status = 200, .body = status_head ++ "\"status\":\"published\",\"future\":[1]}" }}, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 0), try waitForPublish(waitSession(a), quiet.net(), &plain, 600, "tok", "pub_1", "example/x", "1.0.0"));
    try std.testing.expectEqualStrings("", plain.err.items);
}

test "a rejected publish and a failing poll end the wait at once, with no pause" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = group_publish.Console.init(a, null);
    var rejected = gt.Script{ .steps = &.{.{ .method = .GET, .suffix = "pub_1", .status = 200, .body = status_head ++ "\"status\":\"rejected\",\"rejection_code\":\"manifest_invalid\",\"message\":\"no\"}" }}, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try waitForPublish(waitSession(a), rejected.net(), &con, 600, "tok", "pub_1", "example/x", "1.0.0"));
    try std.testing.expectEqual(@as(u64, 0), rejected.slept);
    try std.testing.expectEqualStrings("mopm: rejected: manifest_invalid: no\n", con.err.items);
    var broken = gt.Script{ .steps = &.{.{ .method = .GET, .suffix = "pub_1", .status = 500 }}, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try waitForPublish(waitSession(a), broken.net(), &con, 600, "tok", "pub_1", "example/x", "1.0.0"));
    try std.testing.expectEqual(@as(u64, 0), broken.slept);
    try std.testing.expectEqual(@as(usize, 1), broken.seen.items.len);
}

test "a status this CLI does not know is polled again, and a rejection code it does not know is said as unknown" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = group_publish.Console.init(a, null);
    var script = gt.Script{ .steps = &.{
        .{ .method = .GET, .suffix = "pub_1", .status = 200, .body = status_head ++ "\"status\":\"reviewing\"}" },
        .{ .method = .GET, .suffix = "pub_1", .status = 200, .body = status_head ++ "\"status\":\"rejected\",\"rejection_code\":\"bad\",\"message\":\"no\"}" },
    }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try waitForPublish(waitSession(a), script.net(), &con, 600, "tok", "pub_1", "example/x", "1.0.0"));
    try std.testing.expectEqual(@as(usize, 2), script.seen.items.len);
    try std.testing.expectEqual(@as(u64, 1), script.slept);
    try std.testing.expectEqualStrings("mopm: rejected: unknown: no\n", con.err.items);
}

test "publish creates a package the registry does not have: PUT to its full name with the token and no body, and says created" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = group_publish.Console.init(a, null);
    var script = gt.newScript(a, &.{.{ .method = .PUT, .suffix = "/packages/example/x", .status = 201, .body = "{\"name\":\"example/x\"}" }});
    try std.testing.expect(try ensurePackage(a, script.net(), &con, "http://127.0.0.1:1/api/v2", "tok", "beta", "example/x"));
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqual(@as(usize, 1), script.seen.items.len);
    const sent = script.seen.items[0];
    try std.testing.expectEqual(std.http.Method.PUT, sent.method);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/api/v2/packages/example/x", sent.url);
    try std.testing.expectEqualStrings("tok", sent.token.?);
    try std.testing.expectEqual(@as(usize, 0), if (sent.body) |b| b.len else 0);
    try std.testing.expect(!sent.content_type_set);
    try std.testing.expectEqualStrings("created example/x on beta\n", con.out.items);
    try std.testing.expectEqualStrings("", con.err.items);
}

test "a package name that is not a full name is refused before any request" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = group_publish.Console.init(a, null);
    var script = gt.newScript(a, &.{});
    try std.testing.expect(!(try ensurePackage(a, script.net(), &con, "http://127.0.0.1:1/api/v2", "tok", "beta", "x")));
    try std.testing.expectEqual(@as(usize, 0), script.seen.items.len);
    try std.testing.expectEqualStrings("mopm: 'x' is not a full name <namespace>/<name>\n", con.err.items);
    try std.testing.expect(fullOf("x") == null);
    try std.testing.expectEqualStrings("example", fullOf("example/x").?.namespace);
}

test "publish of a package the registry already has says nothing about creating it and goes on" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = group_publish.Console.init(a, null);
    var script = gt.newScript(a, &.{.{ .method = .PUT, .suffix = "/packages/example/x", .status = 200, .body = "{\"name\":\"example/x\"}" }});
    try std.testing.expect(try ensurePackage(a, script.net(), &con, "http://127.0.0.1:1/api/v2", "tok", "beta", "example/x"));
    try std.testing.expectEqual(@as(usize, 1), script.seen.items.len);
    try std.testing.expectEqualStrings("", con.out.items);
    try std.testing.expectEqualStrings("", con.err.items);
}

test "publish refuses with the registry's message, and goes no further, when the namespace is not the user's or is not valid" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const refusals = [_]struct { status: u16, body: []const u8, err: []const u8 }{
        .{
            .status = 403,
            .body = "{\"error\":{\"code\":\"not_namespace_member\",\"message\":\"You are not a member of the namespace 'example'.\",\"hint\":\"Ask an owner to add you.\"}}",
            .err = "mopm: You are not a member of the namespace 'example'.\n  hint: Ask an owner to add you.\n  request id: req-test\n",
        },
        .{
            .status = 400,
            .body = "{\"error\":{\"code\":\"invalid_namespace\",\"message\":\"'Example' is not a valid namespace.\",\"hint\":\"Use lower case.\"}}",
            .err = "mopm: 'Example' is not a valid namespace.\n  hint: Use lower case.\n  request id: req-test\n",
        },
    };
    for (refusals) |r| {
        var con = group_publish.Console.init(a, null);
        var script = gt.newScript(a, &.{.{ .method = .PUT, .suffix = "/packages/example/x", .status = r.status, .body = r.body }});
        try std.testing.expect(!(try ensurePackage(a, script.net(), &con, "http://127.0.0.1:1/api/v2", "tok", "beta", "example/x")));
        try std.testing.expectEqual(@as(usize, 1), script.seen.items.len);
        try std.testing.expectEqualStrings("", con.out.items);
        try std.testing.expectEqualStrings(r.err, con.err.items);
    }
}

test "publish stops when the request for the package fails before any answer, naming the request" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = group_publish.Console.init(a, null);
    var script = gt.newScript(a, &.{.{ .method = .PUT, .suffix = "/packages/example/x", .status = 0, .err = error.InvalidUri }});
    try std.testing.expect(!(try ensurePackage(a, script.net(), &con, "http://127.0.0.1:1/api/v2", "tok", "beta", "example/x")));
    try std.testing.expectEqualStrings("mopm: PUT /packages/example/x: InvalidUri\n", con.err.items);
    try std.testing.expectEqualStrings("", con.out.items);
}
