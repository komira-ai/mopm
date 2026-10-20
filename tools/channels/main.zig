//! channels: the command line over tools/channels (see channels.zig).
//!
//!   channels deb --package <name> --version <X.Y.Z> --arch <arch> --maintainer <text> --homepage <url>
//!                --synopsis <text> [--description-file <path>] --file <mode>:<dest>:<src> [--file ...]
//!                --mtime <epoch seconds> --out <path.deb>
//!       Writes a .deb. <mode> is octal, <dest> the path inside the package with no leading slash, <src> a file.
//!       The same arguments and the same files give the same bytes.
//!   channels apt-index --repo <dir> --out <dir> --deb <path> [--deb ...] --date <epoch seconds>
//!                --origin <text> --label <text> --description <text> [--arch <arch> ...] [--keep <N>]
//!       Reads the Packages files under <dir>/dists/stable/main/binary-<arch>/ (none is an empty index) for the --arch
//!       given (default amd64 and arm64) and for every other binary-<arch> the repository has, so none is dropped; adds the
//!       .debs, and writes the new Packages, Packages.gz and Release under <out>/dists/stable and the .debs under
//!       <out>/pool. Refuses (exit 1, nothing written) to list a version older than the newest one listed for its
//!       package and architecture, or the same version with other bytes. Keeps the newest <N> (default 25) per
//!       package and architecture. Signing is not done here.
//!   channels formula --sums <SHA256SUMS> --name <name> --version <X.Y.Z> --desc <text> --homepage <url>
//!                --license <spdx> (--repo <owner/name> | --url-base <url>) [--no-explicit-version] --out <path.rb>
//!       Renders the Homebrew formula from the checksums in the file and nothing else.
//!   channels monotonic --current <X.Y.Z|none> --next <X.Y.Z>
//!       Prints `advance` or `same` (exit 0), or refuses (exit 1) when <next> is older than <current>.

const std = @import("std");
const Allocator = std.mem.Allocator;
const apt = @import("apt.zig");
const control = @import("control.zig");
const deb = @import("deb.zig");
const formula = @import("formula.zig");
const version_mod = @import("version.zig");

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("channels: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usage() noreturn {
    std.debug.print("usage: channels deb|apt-index|formula|monotonic ... (see tools/channels/main.zig)\n", .{});
    std.process.exit(2);
}

const Flag = struct { name: []const u8, value: []const u8 };

/// `--name value` pairs, in order. A name not in `with_value` or `bare` is a usage error. A bare flag has value "".
fn parseFlags(a: Allocator, args: []const []const u8, with_value: []const []const u8, bare: []const []const u8) ![]Flag {
    var out = std.ArrayList(Flag).init(a);
    var i: usize = 0;
    outer: while (i < args.len) : (i += 1) {
        const arg = args[i];
        for (bare) |b| {
            if (std.mem.eql(u8, arg, b)) {
                try out.append(.{ .name = arg, .value = "" });
                continue :outer;
            }
        }
        for (with_value) |w| {
            if (std.mem.eql(u8, arg, w)) {
                if (i + 1 >= args.len) die("{s} needs a value", .{arg});
                i += 1;
                try out.append(.{ .name = arg, .value = args[i] });
                continue :outer;
            }
        }
        die("unknown argument '{s}'", .{arg});
    }
    return out.items;
}

fn one(flags: []const Flag, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (flags) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            if (found != null) die("{s} given twice", .{name});
            found = f.value;
        }
    }
    return found;
}

fn need(flags: []const Flag, name: []const u8) []const u8 {
    return one(flags, name) orelse die("{s} is required", .{name});
}

fn many(a: Allocator, flags: []const Flag, name: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    for (flags) |f| {
        if (std.mem.eql(u8, f.name, name)) try out.append(f.value);
    }
    return out.items;
}

fn number(s: []const u8, name: []const u8) u64 {
    return std.fmt.parseInt(u64, s, 10) catch die("{s} '{s}' is not a number", .{ name, s });
}

fn readFile(a: Allocator, path: []const u8) []u8 {
    return std.fs.cwd().readFileAlloc(a, path, 1 << 30) catch |err| die("cannot read {s}: {s}", .{ path, @errorName(err) });
}

fn writeFile(path: []const u8, data: []const u8) void {
    const cwd = std.fs.cwd();
    if (std.fs.path.dirname(path)) |d| cwd.makePath(d) catch |err| die("cannot create {s}: {s}", .{ d, @errorName(err) });
    cwd.writeFile(path, data) catch |err| die("cannot write {s}: {s}", .{ path, @errorName(err) });
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) usage();
    const cmd = argv[1];
    const rest = argv[2..];
    if (std.mem.eql(u8, cmd, "deb")) return cmdDeb(a, rest);
    if (std.mem.eql(u8, cmd, "apt-index")) return cmdAptIndex(a, rest);
    if (std.mem.eql(u8, cmd, "formula")) return cmdFormula(a, rest);
    if (std.mem.eql(u8, cmd, "monotonic")) return cmdMonotonic(a, rest);
    usage();
}

fn cmdDeb(a: Allocator, args: []const []const u8) !void {
    const flags = try parseFlags(a, args, &.{
        "--package", "--version", "--arch", "--maintainer", "--homepage", "--synopsis", "--description-file", "--file", "--mtime", "--out",
    }, &.{});
    var files = std.ArrayList(deb.File).init(a);
    for (try many(a, flags, "--file")) |spec| {
        const c1 = std.mem.indexOfScalar(u8, spec, ':') orelse die("--file '{s}' is not <mode>:<dest>:<src>", .{spec});
        const c2 = std.mem.indexOfScalarPos(u8, spec, c1 + 1, ':') orelse die("--file '{s}' is not <mode>:<dest>:<src>", .{spec});
        const mode = std.fmt.parseInt(u32, spec[0..c1], 8) catch die("--file '{s}': the mode is not octal", .{spec});
        try files.append(.{ .path = spec[c1 + 1 .. c2], .mode = mode, .data = readFile(a, spec[c2 + 1 ..]) });
    }
    const long = if (one(flags, "--description-file")) |p| std.mem.trimRight(u8, readFile(a, p), "\n") else "";
    const bytes = deb.build(a, .{
        .name = need(flags, "--package"),
        .version = need(flags, "--version"),
        .architecture = need(flags, "--arch"),
        .maintainer = need(flags, "--maintainer"),
        .homepage = need(flags, "--homepage"),
        .synopsis = need(flags, "--synopsis"),
        .long_description = long,
        .files = files.items,
        .mtime = number(need(flags, "--mtime"), "--mtime"),
    }) catch |err| die("deb: {s}", .{@errorName(err)});
    const out = need(flags, "--out");
    writeFile(out, bytes);
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    std.debug.print("wrote {s} {d} bytes sha256 {s}\n", .{ out, bytes.len, std.fmt.bytesToHex(d, .lower) });
}

/// How many versions of a package and architecture an index keeps when --keep is not given.
const default_keep: usize = 25;

/// The names after `binary-` of the directories under `<repo>/dists/stable/main`; none when there is no such directory.
fn listedArchs(a: Allocator, repo: []const u8) ![]const []const u8 {
    const dir_path = try std.fmt.allocPrint(a, "{s}/dists/stable/main", .{repo});
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => die("cannot read {s}: {s}", .{ dir_path, @errorName(err) }),
    };
    defer dir.close();
    var out = std.ArrayList([]const u8).init(a);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, "binary-")) continue;
        try out.append(try a.dupe(u8, entry.name["binary-".len..]));
    }
    // The directory order is the file system's; the Release sorts, and so does this.
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out.items;
}

fn cmdAptIndex(a: Allocator, args: []const []const u8) !void {
    const flags = try parseFlags(a, args, &.{
        "--repo", "--out", "--deb", "--date", "--origin", "--label", "--description", "--arch", "--keep",
    }, &.{});
    const repo = need(flags, "--repo");
    const out_dir = need(flags, "--out");
    var archs_list = std.ArrayList([]const u8).init(a);
    try archs_list.appendSlice(try many(a, flags, "--arch"));
    if (archs_list.items.len == 0) try archs_list.appendSlice(&.{ "amd64", "arm64" });
    // Every architecture the repository already lists stays listed, whatever --arch says: an index written without
    // one would drop its packages.
    for (try listedArchs(a, repo)) |arch| {
        var known = false;
        for (archs_list.items) |x| {
            if (std.mem.eql(u8, x, arch)) known = true;
        }
        if (!known) try archs_list.append(arch);
    }
    const archs: []const []const u8 = archs_list.items;
    const keep: usize = if (one(flags, "--keep")) |k| @intCast(number(k, "--keep")) else default_keep;

    var existing = std.ArrayList(apt.Stanza).init(a);
    for (archs) |arch| {
        const p = try std.fmt.allocPrint(a, "{s}/dists/stable/main/binary-{s}/Packages", .{ repo, arch });
        const text = std.fs.cwd().readFileAlloc(a, p, 1 << 30) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => die("cannot read {s}: {s}", .{ p, @errorName(err) }),
        };
        const parsed = apt.parsePackages(a, text) catch |err| die("{s}: {s}", .{ p, @errorName(err) });
        try existing.appendSlice(parsed);
    }

    var added = std.ArrayList(apt.Stanza).init(a);
    var debs = std.ArrayList([]const u8).init(a);
    for (try many(a, flags, "--deb")) |path| {
        const bytes = readFile(a, path);
        const s = apt.stanzaOf(a, bytes) catch |err| die("{s}: not a usable .deb: {s}", .{ path, @errorName(err) });
        try added.append(s);
        try debs.append(bytes);
    }
    if (added.items.len == 0) die("--deb is required", .{});

    const merged = apt.merge(a, existing.items, added.items, keep) catch |err| switch (err) {
        error.ChannelWouldMoveDown => die("refused: a version older than the newest listed for its package and architecture would move the channel down", .{}),
        error.VersionConflict => die("refused: a version that is already listed comes with other bytes", .{}),
        else => die("merge: {s}", .{@errorName(err)}),
    };
    const info = apt.ReleaseInfo{
        .origin = need(flags, "--origin"),
        .label = need(flags, "--label"),
        .description = need(flags, "--description"),
        .date = number(need(flags, "--date"), "--date"),
    };
    const tree = apt.tree(a, info, merged.stanzas, archs) catch |err| die("tree: {s}", .{@errorName(err)});

    // Everything is computed; only now is anything written.
    for (tree) |f| writeFile(try std.fs.path.join(a, &.{ out_dir, f.path }), f.data);
    for (added.items, debs.items) |s, bytes| {
        const fields = try control.parse(a, s.text);
        writeFile(try std.fs.path.join(a, &.{ out_dir, control.get(fields, "Filename").? }), bytes);
    }
    std.debug.print("apt-index: added {d}, dropped {d}, listed {d}\n", .{ merged.added, merged.dropped, merged.stanzas.len });
}

fn cmdFormula(a: Allocator, args: []const []const u8) !void {
    const flags = try parseFlags(a, args, &.{
        "--sums", "--name", "--version", "--desc", "--homepage", "--license", "--repo", "--url-base", "--out",
    }, &.{"--no-explicit-version"});
    const sums = readFile(a, need(flags, "--sums"));
    const text = formula.render(a, .{
        .name = need(flags, "--name"),
        .version = need(flags, "--version"),
        .desc = need(flags, "--desc"),
        .homepage = need(flags, "--homepage"),
        .license = need(flags, "--license"),
        .repo = one(flags, "--repo") orelse "",
        .url_base = one(flags, "--url-base"),
        .explicit_version = one(flags, "--no-explicit-version") == null,
    }, sums) catch |err| die("formula: {s}", .{@errorName(err)});
    writeFile(need(flags, "--out"), text);
}

fn cmdMonotonic(a: Allocator, args: []const []const u8) !void {
    const flags = try parseFlags(a, args, &.{ "--current", "--next" }, &.{});
    const cur_s = need(flags, "--current");
    const current: ?version_mod.Version = if (std.mem.eql(u8, cur_s, "none")) null else version_mod.Version.parse(cur_s) catch die("--current '{s}' is not X.Y.Z or none", .{cur_s});
    const next_s = need(flags, "--next");
    const next = version_mod.Version.parse(next_s) catch die("--next '{s}' is not X.Y.Z", .{next_s});
    const move = version_mod.checkMove(current, next) catch die("refused: {s} would move a channel that holds {s} down", .{ next_s, cur_s });
    try std.io.getStdOut().writer().print("{s}\n", .{@tagName(move)});
}
