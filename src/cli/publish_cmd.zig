//! `mopm pack` and `mopm publish`: a package as a `.conda`, and onto a registry.
//!
//!   mopm pack    --compiler <version> --mojoc [<subdir>=]<path>... [--manifest <file>] [-o <dir>]
//!                [--native [<subdir>:]<id>=<path>]... [--native-static [<subdir>:]<id>=<path>]...
//!   mopm publish --compiler <version> --mojoc [<subdir>=]<path>... [--manifest <file>]
//!                [--native [<subdir>:]<id>=<path>]... [--native-static [<subdir>:]<id>=<path>]...
//!                [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
//!                [--readme <file>] [--dry-run]
//!
//! A package that declares `[native.<id>]` libraries is given the built files:
//! `--native` the shared object and `--native-static` the static archive of
//! `<id>`, per subdir (the subdir defaults to noarch, as for `--mojoc`). Each
//! declared library needs the files its kind takes, in every subdir packed.
//! `[native-dependencies]` become `depends` entries of the package
//! (src/core/conda_native.zig); the registry decides which are allowed.
//!
//! `pack` writes `<dir>/<subdir>/mojo-<name>-<version>-mojo<compiler>_0.conda`
//! (src/core/conda.zig) and prints each file's sha256. `publish` packs the
//! same way and then follows the registry's three steps (spec/api/openapi.yaml):
//! begin an upload per file and PUT the bytes to the URL it names, commit the
//! uploads, and poll the publish until it is `published` or `rejected`.
//!
//! The token is `$MOPM_TOKEN` when that is set and not empty, else the one
//! `mopm login` stored for the registry. It is sent only to the registry's
//! API, as a bearer token, and is never printed. The PUT to the storage URL
//! carries no token, only the headers the registry named.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;
const manifest = core.manifest;
const conda = core.conda;
const conda_native = core.conda_native;
const registry = core.registry;
const credentials = core.credentials;
const registry_cmd = @import("registry_cmd.zig");

const usage =
    \\usage: mopm pack    --compiler <mojo version> --mojoc [<subdir>=]<file>... [--manifest <mopm.toml>] [-o <dir>]
    \\                    [--native [<subdir>:]<id>=<file>]... [--native-static [<subdir>:]<id>=<file>]...
    \\       mopm publish --compiler <mojo version> --mojoc [<subdir>=]<file>... [--manifest <mopm.toml>]
    \\                    [--native [<subdir>:]<id>=<file>]... [--native-static [<subdir>:]<id>=<file>]...
    \\                    [--registry <prod|gamma|beta|url>] [--config-dir <dir>] [--readme <file>] [--dry-run]
    \\
    \\  <subdir> is noarch (the default), linux-64, linux-aarch64 or osx-arm64.
    \\  --native gives the shared object, --native-static the static archive, of a [native.<id>]
    \\  library the manifest declares; give them for each subdir a library is packed for.
    \\  The token is $MOPM_TOKEN, else the one 'mopm login' stored.
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

/// A built library file: `--native` (the shared object) or `--native-static`
/// (the static archive) of `id`, for one subdir.
pub const NativeFile = struct { subdir: []const u8, id: []const u8, static: bool, path: []const u8 };

pub const Flags = struct {
    compiler: []const u8 = "",
    mojoc: []const Mojoc = &.{},
    native: []const NativeFile = &.{},
    manifest: []const u8 = "mopm.toml",
    out: []const u8 = "dist",
    registry: []const u8 = "prod",
    config_dir: ?[]const u8 = null,
    readme: ?[]const u8 = null,
    dry_run: bool = false,
};

pub const Parsed = union(enum) { ok: Flags, bad: []const u8 };

const NativeParsed = union(enum) { ok: NativeFile, bad: []const u8 };

fn bad(arena: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!Parsed {
    return .{ .bad = try std.fmt.allocPrint(arena, fmt, args) };
}

fn takesValue(cmd: Cmd, flag: []const u8) bool {
    const common = [_][]const u8{ "--compiler", "--mojoc", "--manifest", "--native", "--native-static" };
    for (common) |c| {
        if (std.mem.eql(u8, c, flag)) return true;
    }
    return switch (cmd) {
        .pack => std.mem.eql(u8, flag, "-o"),
        .publish => std.mem.eql(u8, flag, "--registry") or std.mem.eql(u8, flag, "--config-dir") or std.mem.eql(u8, flag, "--readme"),
    };
}

/// `[<subdir>:]<id>=<path>`, the value of `flag` (`--native` or `--native-static`).
fn parseNative(arena: Allocator, flag: []const u8, v: []const u8) Allocator.Error!NativeParsed {
    const eq = std.mem.indexOfScalar(u8, v, '=') orelse {
        return .{ .bad = try std.fmt.allocPrint(arena, "{s} {s}: expected [<subdir>:]<id>=<file>", .{ flag, v }) };
    };
    var subdir: []const u8 = "noarch";
    var id = v[0..eq];
    if (std.mem.indexOfScalar(u8, id, ':')) |colon| {
        subdir = id[0..colon];
        id = id[colon + 1 ..];
        if (!conda.isSubdir(subdir)) {
            return .{ .bad = try std.fmt.allocPrint(arena, "{s} {s}: '{s}' is not a subdir (noarch, linux-64, linux-aarch64, osx-arm64)", .{ flag, v, subdir }) };
        }
    }
    if (id.len == 0) return .{ .bad = try std.fmt.allocPrint(arena, "{s} {s}: no id", .{ flag, v }) };
    if (v[eq + 1 ..].len == 0) return .{ .bad = try std.fmt.allocPrint(arena, "{s} {s}: no file", .{ flag, v }) };
    return .{ .ok = .{ .subdir = subdir, .id = id, .static = std.mem.eql(u8, flag, "--native-static"), .path = v[eq + 1 ..] } };
}

/// The flags of `pack` or `publish`, or why they are wrong.
pub fn parseFlags(arena: Allocator, cmd: Cmd, args: []const []const u8) Allocator.Error!Parsed {
    var f = Flags{};
    var mojoc = std.ArrayList(Mojoc).init(arena);
    var native = std.ArrayList(NativeFile).init(arena);
    var have_compiler = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (cmd == .publish and std.mem.eql(u8, a, "--dry-run")) {
            f.dry_run = true;
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
        } else if (std.mem.eql(u8, a, "--native") or std.mem.eql(u8, a, "--native-static")) {
            const entry = switch (try parseNative(arena, a, v)) {
                .ok => |e| e,
                .bad => |why| return .{ .bad = why },
            };
            for (native.items) |n| {
                if (n.static == entry.static and std.mem.eql(u8, n.subdir, entry.subdir) and std.mem.eql(u8, n.id, entry.id)) {
                    return bad(arena, "{s} names {s} twice for the subdir {s}", .{ a, entry.id, entry.subdir });
                }
            }
            try native.append(entry);
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
    f.native = native.items;
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

/// The URL of a publish's status: `status_url` is a path on the API's host
/// (`/api/v1/publishes/...`), resolved against the scheme and host of
/// `api_url`. Null when it is not such a path.
pub fn resolveStatusUrl(arena: Allocator, api_url: []const u8, status_url: []const u8) Allocator.Error!?[]const u8 {
    const prefix = "/api/v1/publishes/";
    if (!std.mem.startsWith(u8, status_url, prefix) or status_url.len == prefix.len) return null;
    const scheme_end = (std.mem.indexOf(u8, api_url, "://") orelse return null) + 3;
    const origin_end = std.mem.indexOfScalarPos(u8, api_url, scheme_end, '/') orelse api_url.len;
    return try std.fmt.allocPrint(arena, "{s}{s}", .{ api_url[0..origin_end], status_url });
}

const Prepared = struct {
    m: manifest.Manifest,
    packs: []const conda.Packed,
    manifest_dir: []const u8,
};

/// Reads the manifest and the `.mojoc` files and packs them. Null after
/// printing why not (nothing has touched the network by then).
fn prepare(arena: Allocator, cmd: Cmd, f: Flags) anyerror!?Prepared {
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
    if (try versionProblem(arena, m.package.version)) |problem| {
        err("{s}: {s}\n", .{ f.manifest, problem });
        return null;
    }
    if (!conda.validCompiler(f.compiler)) {
        err("--compiler {s}: an exact Mojo version is digits and dots, such as 1.0.0\n", .{f.compiler});
        return null;
    }
    var why: []const u8 = "";
    const deps = conda.depsOf(arena, m, &why) catch |e| switch (e) {
        error.Unpackable => {
            err("{s}: {s}\n", .{ f.manifest, why });
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    const native_deps = try conda_native.nativeDepsOf(arena, m);
    for (f.native) |n| {
        var packed_subdir = false;
        for (f.mojoc) |mc| {
            if (std.mem.eql(u8, mc.subdir, n.subdir)) packed_subdir = true;
        }
        if (!packed_subdir) {
            err("{s} {s}:{s}={s}: no --mojoc for the subdir {s}\n", .{ if (n.static) "--native-static" else "--native", n.subdir, n.id, n.path, n.subdir });
            return null;
        }
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
        var given = std.ArrayList(conda_native.Given).init(arena);
        for (f.native) |n| {
            if (!std.mem.eql(u8, n.subdir, entry.subdir)) continue;
            const data = std.fs.cwd().readFileAlloc(arena, n.path, 1 << 30) catch |e| {
                err("{s}: {s}\n", .{ n.path, @errorName(e) });
                return null;
            };
            try given.append(.{ .id = n.id, .static = n.static, .path = n.path, .data = data });
        }
        const libs = conda_native.assemble(arena, m.native, given.items, &why) catch |e| switch (e) {
            error.Unpackable => {
                err("{s}: {s}: {s}\n", .{ f.manifest, entry.subdir, why });
                return null;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        const p = try conda.pack(arena, .{
            .name = m.package.name,
            .version = m.package.version,
            .compiler = f.compiler,
            .subdir = entry.subdir,
            .deps = deps,
            .mojoc = bytes,
            .natives = libs,
            .native_deps = native_deps,
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
    return .{ .m = m, .packs = packs.items, .manifest_dir = std.fs.path.dirname(f.manifest) orelse "." };
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
    const out = std.io.getStdOut().writer();
    for (prep.packs) |p| {
        const dir = try std.fs.path.join(arena, &.{ f.out, p.subdir });
        try std.fs.cwd().makePath(dir);
        const path = try std.fs.path.join(arena, &.{ dir, p.file_name });
        try std.fs.cwd().writeFile(path, p.bytes);
        try out.print("packed {s}\n  sha256 {s}\n  size {d}\n  manifest_sha256 {s}\n", .{ path, &p.sha256, p.bytes.len, &p.manifest_sha256 });
    }
    return 0;
}

/// `$MOPM_TOKEN` if set and not empty, else the stored credential.
fn findToken(s: registry_cmd.Session) anyerror!?[]const u8 {
    if (std.process.getEnvVarOwned(s.arena, "MOPM_TOKEN")) |t| {
        const trimmed = std.mem.trim(u8, t, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    } else |_| {}
    if (try credentials.load(s.arena, s.config_dir, s.config.api_url)) |e| return e.token;
    return null;
}

fn publishCmd(arena: Allocator, f: Flags, cli_version: []const u8) anyerror!u8 {
    const prep = (try prepare(arena, .publish, f)) orelse return 1;
    var refused = false;
    const readme = try loadReadme(arena, f, prep, &refused);
    if (refused) return 1;
    const out = std.io.getStdOut().writer();
    const name = prep.m.package.name;
    const version = prep.m.package.version;

    if (f.dry_run) {
        for (prep.packs) |p| {
            try out.print("would upload {s}/{s} ({d} bytes, sha256 {s})\n", .{ p.subdir, p.file_name, p.bytes.len, &p.sha256 });
        }
        try out.print("would commit mojo-{s} {s} (manifest_sha256 {s})\n", .{ name, version, &prep.packs[0].manifest_sha256 });
        if (readme) |r| try out.print("would send a readme of {d} bytes\n", .{r.len});
        try out.writeAll("dry run: nothing was sent\n");
        return 0;
    }

    const s = registry_cmd.open(arena, .{ .registry = f.registry, .config_dir = f.config_dir }, cli_version) orelse return 1;
    const token = (try findToken(s)) orelse {
        err("not logged in to {s}; run 'mopm login' or set MOPM_TOKEN\n", .{s.config.stage});
        return 1;
    };

    var ids = std.ArrayList([]const u8).init(arena);
    for (prep.packs) |p| {
        const id = (try uploadFile(s, token, name, version, p)) orelse return 1;
        try ids.append(id);
        try out.print("uploaded {s} ({s})\n", .{ p.file_name, p.subdir });
    }

    // Commit.
    var body = std.ArrayList(u8).init(arena);
    const w = body.writer();
    try w.writeAll("{\"upload_ids\":[");
    for (ids.items, 0..) |id, i| {
        if (i > 0) try w.writeByte(',');
        try std.json.encodeJsonString(id, .{}, w);
    }
    try w.print("],\"manifest_sha256\":\"{s}\"", .{&prep.packs[0].manifest_sha256});
    if (readme) |r| {
        try w.writeAll(",\"readme\":");
        try std.json.encodeJsonString(r, .{}, w);
    }
    try w.writeByte('}');
    const path = try std.fmt.allocPrint(arena, "/packages/{s}/{s}/publish", .{ name, version });
    const committed = try http.request(arena, .POST, try s.api(path), .{ .token = token, .body = body.items });
    if (!committed.ok()) {
        registry_cmd.printFailure(committed);
        return 1;
    }
    const accepted = try std.json.parseFromSliceLeaky(struct {
        publish_id: []const u8,
        status_url: []const u8,
    }, arena, committed.body, .{ .ignore_unknown_fields = true });
    try out.print("committed, publish {s}\n", .{accepted.publish_id});
    const status_url = (try resolveStatusUrl(arena, s.config.api_url, accepted.status_url)) orelse {
        err("the registry sent a status URL that is not a path under /api/v1/publishes/\n", .{});
        return 1;
    };
    return waitForPublish(s, token, status_url, name, version);
}

/// Begins the upload of `p` and PUTs its bytes; the upload id, or null after
/// printing why not.
fn uploadFile(s: registry_cmd.Session, token: []const u8, name: []const u8, version: []const u8, p: conda.Packed) anyerror!?[]const u8 {
    const arena = s.arena;
    const begin_body = try std.fmt.allocPrint(
        arena,
        "{{\"subdir\":\"{s}\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}",
        .{ p.subdir, p.file_name, &p.sha256, p.bytes.len },
    );
    const path = try std.fmt.allocPrint(arena, "/packages/{s}/{s}/files", .{ name, version });
    const begun = try http.request(arena, .POST, try s.api(path), .{ .token = token, .body = begin_body });
    if (!begun.ok()) {
        registry_cmd.printFailure(begun);
        return null;
    }
    const up = try std.json.parseFromSliceLeaky(struct {
        upload_id: []const u8,
        put_url: []const u8,
        put_headers: ?std.json.Value = null,
    }, arena, begun.body, .{ .ignore_unknown_fields = true });
    if (!registry.allowedUrl(up.put_url)) {
        err("the registry named an upload URL that is neither https nor loopback http\n", .{});
        return null;
    }

    // Every header the registry named, as given. The client sets
    // Content-Length itself from the body, to the same value.
    var headers = std.ArrayList(std.http.Header).init(arena);
    if (up.put_headers) |ph| switch (ph) {
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
    // No bearer token: the URL is presigned.
    const put = try http.request(arena, .PUT, up.put_url, .{
        .body = p.bytes,
        .content_type = null,
        .extra_headers = headers.items,
    });
    if (!put.ok()) {
        err("uploading {s} failed: the storage answered HTTP {d}\n", .{ p.file_name, put.status });
        return null;
    }
    return up.upload_id;
}

fn waitForPublish(s: registry_cmd.Session, token: []const u8, url: []const u8, name: []const u8, version: []const u8) anyerror!u8 {
    const arena = s.arena;
    const out = std.io.getStdOut().writer();
    const deadline = std.time.timestamp() + wait_secs;
    while (std.time.timestamp() < deadline) {
        const polled = try http.request(arena, .GET, url, .{ .token = token });
        if (polled.status == 429) {
            std.time.sleep(@as(u64, @min(polled.retry_after orelse 1, 60)) * std.time.ns_per_s);
            continue;
        }
        if (!polled.ok()) {
            registry_cmd.printFailure(polled);
            return 1;
        }
        const state = try std.json.parseFromSliceLeaky(struct {
            status: []const u8,
            rejection_code: ?[]const u8 = null,
            message: ?[]const u8 = null,
        }, arena, polled.body, .{ .ignore_unknown_fields = true });
        if (std.mem.eql(u8, state.status, "published")) {
            try out.print("published mojo-{s} {s}\n", .{ name, version });
            return 0;
        }
        if (std.mem.eql(u8, state.status, "rejected")) {
            err("rejected: {s}: {s}\n", .{ state.rejection_code orelse "unknown", state.message orelse "" });
            return 1;
        }
        std.time.sleep(std.time.ns_per_s);
    }
    err("gave up waiting for the publish after {d} minutes; it may still finish: check 'GET {s}'\n", .{ @divTrunc(wait_secs, 60), url });
    return 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn parseOk(a: Allocator, cmd: Cmd, args: []const []const u8) !Flags {
    return switch (try parseFlags(a, cmd, args)) {
        .ok => |f| f,
        .bad => |why| {
            std.debug.print("unexpected refusal: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    };
}

fn parseBad(a: Allocator, cmd: Cmd, args: []const []const u8, needle: []const u8) !void {
    switch (try parseFlags(a, cmd, args)) {
        .ok => return error.TestUnexpectedResult,
        .bad => |why| if (std.mem.indexOf(u8, why, needle) == null) {
            std.debug.print("refusal '{s}' lacks '{s}'\n", .{ why, needle });
            return error.TestUnexpectedResult;
        },
    }
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

test "native flags" {
    // Catches: a --native value split at the wrong separator (a path with ':'
    // or '=' in it), the shared and static flags swapped, a subdir typo
    // accepted, and the same library file given twice.
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const base = [_][]const u8{ "--compiler", "1.0.0", "--mojoc", "a.mojoc" };

    const p = try parseOk(a, .pack, &(base ++ [_][]const u8{
        "--native",
        "zlib=out/libz.so.1",
        "--native-static",
        "zlib=out/libz.a",
        "--native",
        "linux-64:curl_shim=b/libcurl_shim.so",
        "--native-static",
        "osx-arm64:zlib=lib/a=b/libz.a",
    }));
    try std.testing.expectEqual(@as(usize, 4), p.native.len);
    try std.testing.expectEqualStrings("noarch", p.native[0].subdir);
    try std.testing.expectEqualStrings("zlib", p.native[0].id);
    try std.testing.expectEqualStrings("out/libz.so.1", p.native[0].path);
    try std.testing.expect(!p.native[0].static);
    try std.testing.expect(p.native[1].static);
    try std.testing.expectEqualStrings("out/libz.a", p.native[1].path);
    try std.testing.expectEqualStrings("linux-64", p.native[2].subdir);
    try std.testing.expectEqualStrings("curl_shim", p.native[2].id);
    try std.testing.expectEqualStrings("osx-arm64", p.native[3].subdir);
    try std.testing.expectEqualStrings("lib/a=b/libz.a", p.native[3].path);

    const q = try parseOk(a, .publish, &(base ++ [_][]const u8{ "--native", "zlib=libz.so" }));
    try std.testing.expectEqual(@as(usize, 1), q.native.len);
    const none = try parseOk(a, .pack, &base);
    try std.testing.expectEqual(@as(usize, 0), none.native.len);

    try parseBad(a, .pack, &(base ++ [_][]const u8{ "--native", "libz.so" }), "expected [<subdir>:]<id>=<file>");
    try parseBad(a, .pack, &(base ++ [_][]const u8{ "--native", "win-64:zlib=libz.so" }), "not a subdir");
    try parseBad(a, .pack, &(base ++ [_][]const u8{ "--native-static", "linux-64:=libz.a" }), "no id");
    try parseBad(a, .pack, &(base ++ [_][]const u8{ "--native", "zlib=" }), "no file");
    try parseBad(a, .pack, &(base ++ [_][]const u8{ "--native", "zlib=a.so", "--native", "noarch:zlib=b.so" }), "twice");
    try parseBad(a, .pack, &(base ++ [_][]const u8{"--native"}), "needs a value");
}

test "version refusals" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    try std.testing.expect((try versionProblem(a, "1.0.0")) == null);
    try std.testing.expect((try versionProblem(a, "0.0.0")) == null);
    for ([_][]const u8{ "1.0", "1", "1.0.0-rc.1", "1.0.0+7", "01.0.0", "1.0.0.0", "1.0.a" }) |v| {
        const why = (try versionProblem(a, v)) orelse {
            std.debug.print("accepted {s}\n", .{v});
            return error.TestUnexpectedResult;
        };
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

test "the status URL resolves against the API host" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:5000/api/v1/publishes/pub_1",
        (try resolveStatusUrl(a, "http://127.0.0.1:5000/api/v1", "/api/v1/publishes/pub_1")).?,
    );
    try std.testing.expectEqualStrings(
        "https://mopm.dev/api/v1/publishes/x",
        (try resolveStatusUrl(a, "https://mopm.dev/api/v1", "/api/v1/publishes/x")).?,
    );
    try std.testing.expect((try resolveStatusUrl(a, "https://mopm.dev/api/v1", "https://evil.example/api/v1/publishes/x")) == null);
    try std.testing.expect((try resolveStatusUrl(a, "https://mopm.dev/api/v1", "//evil.example/api/v1/publishes/x")) == null);
    try std.testing.expect((try resolveStatusUrl(a, "https://mopm.dev/api/v1", "/api/v1/publishes/")) == null);
    try std.testing.expect((try resolveStatusUrl(a, "https://mopm.dev/api/v1", "/other")) == null);
}
