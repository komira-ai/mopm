//! The link planner: from the metadata of every installed package in a
//! closure, compute the arguments that make native libraries link and load.
//!
//! Facts it encodes (each one was observed on a real Mojo toolchain):
//!   * `mojo build` links a shared object with `-L<dir> -l<name>`; a static
//!     archive is passed by path.
//!   * `mojo run` takes one `-Xlinker <shared object>` per library; a static
//!     archive has no effect there, so a static-only library cannot be run.
//!   * The REPL needs the shared objects in the preload set of the JIT
//!     process; static archives cannot be preloaded.
//!   * Every transitive native library must be present in the set: a missing
//!     one kills the process. The order of shared objects does not matter on
//!     Linux. The order of static archives does: a linker looks for the symbols
//!     an archive leaves undefined only in the archives after it, so an archive
//!     comes before every archive it `needs` (a static library may `need` a
//!     static or a shared one; a shared object cannot take symbols from an
//!     archive, so it may not need one).
//!   * One owner per native library: two packages shipping one soname are
//!     refused.
//!   * One library per exclusive group: two native libraries that declare the
//!     same `exclusive` group (two copies of one C library under different
//!     names) link without error and run with two copies of its state, so a
//!     closure holding two is refused.

const std = @import("std");
const Allocator = std.mem.Allocator;
const metadata = @import("metadata.zig");

const List = std.ArrayList([]const u8);

/// One installed package: the directory its metadata file lives in (native
/// file paths are relative to it) and the parsed metadata.
pub const Input = struct {
    dir: []const u8,
    meta: metadata.Metadata,
};

pub const Code = enum {
    duplicate_package,
    duplicate_owner,
    exclusive_conflict,
    missing_package,
    missing_library,
    not_in_preload_set,
    static_only,
    needs_cycle,
};

/// Which command a diagnostic blocks.
pub const Command = enum { all, run, repl };

pub const Diagnostic = struct {
    code: Code,
    command: Command,
    message: []const u8,
};

pub const Plan = struct {
    /// Complete arguments for `mojo build`.
    build: []const []const u8,
    /// Shared objects; each becomes `-Xlinker <path>` for `mojo run`.
    run: []const []const u8,
    /// Shared objects for the REPL's preload variable.
    preload: []const []const u8,
    diagnostics: []const Diagnostic,

    pub fn ok(self: Plan) bool {
        return self.diagnostics.len == 0;
    }
};

/// `dir/file`. Under an absolute `dir` the result is normalised, so that an
/// installed `lib/mojo/x.mopm.json` naming `../libx.so.1` gives `<env>/lib/libx.so.1`
/// (and `-L<env>/lib`), the spelling the run path and the preload list use.
fn join(arena: Allocator, dir: []const u8, file: []const u8) Allocator.Error![]const u8 {
    if (std.fs.path.isAbsolute(dir)) return std.fs.path.resolvePosix(arena, &.{ dir, file });
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return file;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, file });
}

/// A library a closure can put in the preload set: link mode, shared flavour.
fn preloadable(n: metadata.Native) bool {
    return n.mode == .link and n.kind != .static;
}

/// What a soname's owner ships, for the `needs` of the libraries that name it.
const Provides = enum {
    /// A shared object in link mode: in the preload set.
    preload,
    /// A static archive in link mode: on the link line, ahead of what it needs.
    archive,
    /// Anything else (load mode): the package opens it itself.
    other,
};

fn providesOf(n: metadata.Native) Provides {
    if (preloadable(n)) return .preload;
    if (n.mode == .link and n.kind == .static) return .archive;
    return .other;
}

pub fn plan(arena: Allocator, inputs: []const Input) Allocator.Error!Plan {
    var diags = std.ArrayList(Diagnostic).init(arena);
    var build_args = List.init(arena);
    var run_paths = List.init(arena);
    var preload = List.init(arena);

    var pkgs = std.StringHashMap(void).init(arena);
    var owners = std.StringHashMap([]const u8).init(arena); // soname -> package
    var provides = std.StringHashMap(Provides).init(arena); // soname -> what its owner ships
    var seen_dirs = std.StringHashMap(void).init(arena);
    var emitted = std.StringHashMap(void).init(arena);

    // Pass 1: package names are unique.
    for (inputs) |inp| {
        const r = try pkgs.getOrPut(inp.meta.name);
        if (r.found_existing) {
            try diags.append(.{
                .code = .duplicate_package,
                .command = .all,
                .message = try std.fmt.allocPrint(arena, "package {s} appears more than once", .{inp.meta.name}),
            });
        }
    }

    // Pass 2: one owner per soname.
    for (inputs) |inp| {
        for (inp.meta.native) |n| {
            const r = try owners.getOrPut(n.soname);
            if (!r.found_existing) {
                r.value_ptr.* = inp.meta.name;
                try provides.put(n.soname, providesOf(n));
            } else if (!std.mem.eql(u8, r.value_ptr.*, inp.meta.name)) {
                try diags.append(.{
                    .code = .duplicate_owner,
                    .command = .all,
                    .message = try std.fmt.allocPrint(
                        arena,
                        "{s} is provided by both {s} and {s}; one owner per native library",
                        .{ n.soname, r.value_ptr.*, inp.meta.name },
                    ),
                });
            }
        }
    }

    // Pass 2b: at most one native library per exclusive group.
    var group_owner = std.StringHashMap(GroupOwner).init(arena);
    for (inputs) |inp| {
        for (inp.meta.native) |n| {
            if (n.exclusive.len == 0) continue;
            const r = try group_owner.getOrPut(n.exclusive);
            if (!r.found_existing) {
                r.value_ptr.* = .{ .package = inp.meta.name, .id = n.id };
            } else if (!std.mem.eql(u8, r.value_ptr.package, inp.meta.name) or !std.mem.eql(u8, r.value_ptr.id, n.id)) {
                try diags.append(.{
                    .code = .exclusive_conflict,
                    .command = .all,
                    .message = try std.fmt.allocPrint(
                        arena,
                        "{s} (native {s}) and {s} (native {s}) are both in exclusive group {s}; a closure links one library of a group",
                        .{ r.value_ptr.package, r.value_ptr.id, inp.meta.name, n.id, n.exclusive },
                    ),
                });
            }
        }
    }

    // Pass 3: every dependency and every needed library is in the closure.
    for (inputs) |inp| {
        for (inp.meta.deps) |d| {
            if (!pkgs.contains(d.name)) {
                try diags.append(.{
                    .code = .missing_package,
                    .command = .all,
                    .message = try std.fmt.allocPrint(
                        arena,
                        "{s} depends on {s}, which is not in the closure",
                        .{ inp.meta.name, d.name },
                    ),
                });
            }
        }
        for (inp.meta.native) |n| {
            if (n.mode != .link) continue; // a load-mode library resolves its own needs
            for (n.needs) |need| {
                if (std.mem.eql(u8, need, n.soname)) {
                    try diags.append(.{
                        .code = .needs_cycle,
                        .command = .all,
                        .message = try std.fmt.allocPrint(arena, "{s} (native {s}) needs itself ({s})", .{ inp.meta.name, n.id, need }),
                    });
                    continue;
                }
                if (provides.get(need)) |owner_ships| {
                    // A static library takes what it needs from a shared object or from an archive; a shared
                    // object is loaded at run time and cannot reach into an archive.
                    const ok = owner_ships == .preload or (owner_ships == .archive and n.kind == .static);
                    if (!ok) {
                        try diags.append(.{
                            .code = .not_in_preload_set,
                            .command = .all,
                            .message = try std.fmt.allocPrint(
                                arena,
                                "{s} (native {s}) needs {s}, which its owner does not ship as a linked shared library",
                                .{ inp.meta.name, n.id, need },
                            ),
                        });
                    }
                } else {
                    try diags.append(.{
                        .code = .missing_library,
                        .command = .all,
                        .message = try std.fmt.allocPrint(
                            arena,
                            "{s} (native {s}) needs {s}, which no package in the closure provides",
                            .{ inp.meta.name, n.id, need },
                        ),
                    });
                }
            }
        }
    }

    // Pass 4: the flags, in input order, except that the static archives come after the
    // shared flags, each before the archives it needs. Only the first owner of a soname
    // contributes.
    var archives = std.ArrayList(Archive).init(arena);
    for (inputs) |inp| {
        for (inp.meta.native) |n| {
            if (n.mode == .load) continue;
            const owner = owners.get(n.soname) orelse continue;
            if (!std.mem.eql(u8, owner, inp.meta.name)) continue;
            const e = try emitted.getOrPut(n.soname);
            if (e.found_existing) continue;

            if (n.kind != .static) {
                // Parsed metadata always has a valid soname; skip otherwise.
                const lib = metadata.linkName(n.soname) orelse continue;
                const path = try join(arena, inp.dir, n.file);
                const d = try seen_dirs.getOrPut(std.fs.path.dirname(path) orelse ".");
                if (!d.found_existing) {
                    try build_args.append(try std.fmt.allocPrint(arena, "-L{s}", .{d.key_ptr.*}));
                }
                try build_args.append(try std.fmt.allocPrint(arena, "-l{s}", .{lib}));
                try run_paths.append(path);
                try preload.append(path);
            } else {
                try archives.append(.{ .soname = n.soname, .needs = n.needs, .path = try join(arena, inp.dir, n.static_file) });
                inline for (.{ Command.run, Command.repl }) |cmd| {
                    try diags.append(.{
                        .code = .static_only,
                        .command = cmd,
                        .message = try std.fmt.allocPrint(
                            arena,
                            "{s} ships only {s} (native {s}); mojo {s} cannot load an archive: use mopm build or ask for a shared flavour",
                            .{ inp.meta.name, std.fs.path.basename(n.static_file), n.id, @tagName(cmd) },
                        ),
                    });
                }
            }
        }
    }

    try orderArchives(arena, archives.items, &build_args, &diags);

    return .{
        .build = try build_args.toOwnedSlice(),
        .run = try run_paths.toOwnedSlice(),
        .preload = try preload.toOwnedSlice(),
        .diagnostics = try diags.toOwnedSlice(),
    };
}

/// A static archive on the link line.
const GroupOwner = struct { package: []const u8, id: []const u8 };
const Archive = struct { soname: []const u8, needs: []const []const u8, path: []const u8 };

/// Appends the paths of `archives` to `build_args`, each before every archive it needs; archives that do not constrain
/// one another stay in the order they came in. A cycle among them gets one `needs_cycle` diagnostic, and the archives
/// of the cycle follow in input order.
fn orderArchives(arena: Allocator, archives: []const Archive, build_args: *List, diags: *std.ArrayList(Diagnostic)) Allocator.Error!void {
    const placed = try arena.alloc(bool, archives.len);
    @memset(placed, false);
    var left: usize = archives.len;
    while (left > 0) {
        var next: ?usize = null;
        for (archives, 0..) |cand, i| {
            if (placed[i]) continue;
            var wanted = false;
            for (archives, 0..) |other, j| {
                if (j == i or placed[j]) continue;
                for (other.needs) |need| wanted = wanted or std.mem.eql(u8, need, cand.soname);
            }
            if (!wanted) {
                next = i;
                break;
            }
        }
        if (next == null) {
            var names = std.ArrayList(u8).init(arena);
            for (archives, 0..) |a, i| {
                if (placed[i]) continue;
                if (names.items.len > 0) try names.appendSlice(", ");
                try names.appendSlice(a.soname);
            }
            try diags.append(.{
                .code = .needs_cycle,
                .command = .all,
                .message = try std.fmt.allocPrint(arena, "{s} need each other; a link order cannot put one before the other", .{names.items}),
            });
            for (archives, 0..) |a, i| {
                if (!placed[i]) try build_args.append(a.path);
            }
            return;
        }
        placed[next.?] = true;
        left -= 1;
        try build_args.append(archives[next.?].path);
    }
}

/// Text form used by `mopm link-plan` and by the golden files.
pub fn render(p: Plan, w: anytype) !void {
    try w.writeAll("build:\n");
    for (p.build) |a| try w.print("  {s}\n", .{a});
    try w.writeAll("run:\n");
    for (p.run) |a| try w.print("  -Xlinker {s}\n", .{a});
    try w.writeAll("repl-preload:\n");
    for (p.preload) |a| try w.print("  {s}\n", .{a});
    try w.writeAll("diagnostics:\n");
    for (p.diagnostics) |d| try w.print("  [{s}] {s}: {s}\n", .{ @tagName(d.command), @tagName(d.code), d.message });
}

/// Read and parse a `<name>.mopm.json`; its directory anchors the native paths.
pub fn loadInput(arena: Allocator, path: []const u8) !Input {
    const text = try std.fs.cwd().readFileAlloc(arena, path, 1 << 20);
    const meta = try metadata.parse(arena, text);
    return .{ .dir = std.fs.path.dirname(path) orelse ".", .meta = meta };
}

// ---------------------------------------------------------------- tests

fn mk(a: Allocator, dir: []const u8, json: []const u8) !Input {
    return .{ .dir = dir, .meta = try metadata.parse(a, json) };
}

fn has(p: Plan, code: Code, cmd: Command) bool {
    for (p.diagnostics) |d| {
        if (d.code == code and d.command == cmd) return true;
    }
    return false;
}

fn expectList(want: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

const pkg_shared =
    \\{"schema": 1, "name": "app", "native": [
    \\  {"id": "x", "soname": "libx.so.1", "file": "lib/libx.so.1"}]}
;

test "shared library: -L/-l for build, -Xlinker path for run, preload for the REPL" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, "pk", pkg_shared)});
    try expectList(&.{ "-Lpk/lib", "-lx" }, p.build);
    try expectList(&.{"pk/lib/libx.so.1"}, p.run);
    try expectList(&.{"pk/lib/libx.so.1"}, p.preload);
    try std.testing.expect(p.ok());
}

test "static-only library: archive by path for build, an error for run and repl" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, "pk",
        \\{"schema": 1, "name": "s", "native": [
        \\  {"id": "x", "soname": "libx.a", "kind": "static", "static_file": "lib/libx.a"}]}
    )});
    try expectList(&.{"pk/lib/libx.a"}, p.build);
    try std.testing.expectEqual(@as(usize, 0), p.run.len);
    try std.testing.expectEqual(@as(usize, 0), p.preload.len);
    try std.testing.expect(has(p, .static_only, .run));
    try std.testing.expect(has(p, .static_only, .repl));
    try std.testing.expect(!has(p, .static_only, .all));
}

test "kind both: the shared object is used, not the archive" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, "pk",
        \\{"schema": 1, "name": "b", "native": [
        \\  {"id": "x", "soname": "libx.so.1", "kind": "both",
        \\   "file": "lib/libx.so.1", "static_file": "lib/libx.a"}]}
    )});
    try expectList(&.{ "-Lpk/lib", "-lx" }, p.build);
    try expectList(&.{"pk/lib/libx.so.1"}, p.run);
    try std.testing.expect(p.ok());
}

test "load mode contributes no flags" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, "pk",
        \\{"schema": 1, "name": "l", "native": [
        \\  {"id": "x", "soname": "libx.so.1", "mode": "load", "file": "lib/libx.so.1"}]}
    )});
    try std.testing.expectEqual(@as(usize, 0), p.build.len);
    try std.testing.expectEqual(@as(usize, 0), p.run.len);
    try std.testing.expectEqual(@as(usize, 0), p.preload.len);
    try std.testing.expect(p.ok());
}

const needs_b =
    \\{"schema": 1, "name": "a", "deps": [{"name": "b"}], "native": [
    \\  {"id": "a", "soname": "liba.so.1", "file": "lib/liba.so.1", "needs": ["libb.so.1"]}]}
;
const provides_b =
    \\{"schema": 1, "name": "b", "native": [
    \\  {"id": "b", "soname": "libb.so.1", "file": "lib/libb.so.1"}]}
;

test "a transitive library must be present" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, "d", needs_b)});
    try std.testing.expect(has(p, .missing_library, .all));
    try std.testing.expect(has(p, .missing_package, .all));
}

test "with the transitive library present, both are in the preload set" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{ try mk(a, "d", needs_b), try mk(a, "d", provides_b) });
    try std.testing.expect(p.ok());
    try expectList(&.{ "d/lib/liba.so.1", "d/lib/libb.so.1" }, p.preload);
    try expectList(&.{ "d/lib/liba.so.1", "d/lib/libb.so.1" }, p.run);
    try expectList(&.{ "-Ld/lib", "-la", "-lb" }, p.build);
}

test "order does not matter, presence does" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{ try mk(a, "d", provides_b), try mk(a, "d", needs_b) });
    try std.testing.expect(p.ok());
    try expectList(&.{ "d/lib/libb.so.1", "d/lib/liba.so.1" }, p.preload);
}

test "a shared library that needs a load-mode library is told its owner does not ship it linked" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{ try mk(a, "d", needs_b), try mk(a, "d",
        \\{"schema": 1, "name": "b", "native": [
        \\  {"id": "b", "soname": "libb.so.1", "mode": "load", "file": "lib/libb.so.1"}]}
    ) });
    try std.testing.expect(has(p, .not_in_preload_set, .all));
    try std.testing.expect(!has(p, .missing_library, .all));
}

// A static archive that needs another (the shape of a TLS library over a crypto library).
const static_a_needs_b =
    \\{"schema": 1, "name": "a", "deps": [{"name": "b"}], "native": [
    \\  {"id": "a", "soname": "liba.a", "kind": "static", "static_file": "lib/liba.a", "needs": ["libb.a"]}]}
;
const static_b =
    \\{"schema": 1, "name": "b", "native": [
    \\  {"id": "b", "soname": "libb.a", "kind": "static", "static_file": "lib/libb.a"}]}
;

test "a static library may need another static library: the edge is accepted" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{ try mk(a, "d", static_a_needs_b), try mk(a, "d", static_b) });
    try std.testing.expect(!has(p, .not_in_preload_set, .all));
    try std.testing.expect(!has(p, .missing_library, .all));
    try std.testing.expect(!has(p, .missing_package, .all));
    try std.testing.expect(!has(p, .needs_cycle, .all));
    try expectList(&.{ "d/lib/liba.a", "d/lib/libb.a" }, p.build);
}

test "a static library may need a shared one; a shared library may not need an archive" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    // static a -> shared b: both are linked, and b is in the preload set.
    const ok = try plan(a, &.{ try mk(a, "d",
        \\{"schema": 1, "name": "a", "deps": [{"name": "b"}], "native": [
        \\  {"id": "a", "soname": "liba.a", "kind": "static", "static_file": "lib/liba.a", "needs": ["libb.so.1"]}]}
    ), try mk(a, "d", provides_b) });
    try std.testing.expect(!has(ok, .not_in_preload_set, .all));
    // shared a -> static b: the loader cannot give a the symbols of an archive.
    const bad = try plan(a, &.{ try mk(a, "d", needs_b), try mk(a, "d",
        \\{"schema": 1, "name": "b", "native": [
        \\  {"id": "b", "soname": "libb.so.1", "kind": "static", "static_file": "lib/libb.a"}]}
    ) });
    try std.testing.expect(has(bad, .not_in_preload_set, .all));
}

test "a static library that needs one nobody ships is missing_library, as a shared one is" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, "d", static_a_needs_b)});
    try std.testing.expect(has(p, .missing_library, .all));
    try std.testing.expect(!has(p, .not_in_preload_set, .all));
}

test "static archives are linked each before the ones it needs, whatever order they are given in" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    // b is given first, but a needs b: a must come first on the link line.
    const p = try plan(a, &.{ try mk(a, "d", static_b), try mk(a, "d", static_a_needs_b) });
    try expectList(&.{ "d/lib/liba.a", "d/lib/libb.a" }, p.build);
    // The shared flags stay where the input order put them, ahead of the archives.
    const mixed = try plan(a, &.{ try mk(a, "d", static_b), try mk(a, "d", static_a_needs_b), try mk(a, "e", pkg_shared) });
    try expectList(&.{ "-Le/lib", "-lx", "d/lib/liba.a", "d/lib/libb.a" }, mixed.build);
    // Three in a chain, given in the worst order.
    const chain = try plan(a, &.{
        try mk(a, "d", static_b),
        try mk(a, "d",
            \\{"schema": 1, "name": "c", "native": [
            \\  {"id": "c", "soname": "libc.a", "kind": "static", "static_file": "lib/libc.a"}]}
        ),
        try mk(a, "d",
            \\{"schema": 1, "name": "a", "deps": [{"name": "b"}, {"name": "c"}], "native": [
            \\  {"id": "a", "soname": "liba.a", "kind": "static", "static_file": "lib/liba.a", "needs": ["libb.a", "libc.a"]}]}
        ),
    });
    try expectList(&.{ "d/lib/liba.a", "d/lib/libb.a", "d/lib/libc.a" }, chain.build);
}

test "static archives that do not constrain one another keep their input order" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const c =
        \\{"schema": 1, "name": "c", "native": [
        \\  {"id": "c", "soname": "libc.a", "kind": "static", "static_file": "lib/libc.a"}]}
    ;
    const p = try plan(a, &.{ try mk(a, "d", c), try mk(a, "d", static_b) });
    try expectList(&.{ "d/lib/libc.a", "d/lib/libb.a" }, p.build);
}

test "static archives that need each other are refused, once, and are still all on the line" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{ try mk(a, "d", static_a_needs_b), try mk(a, "d",
        \\{"schema": 1, "name": "b", "native": [
        \\  {"id": "b", "soname": "libb.a", "kind": "static", "static_file": "lib/libb.a", "needs": ["liba.a"]}]}
    ) });
    try std.testing.expect(has(p, .needs_cycle, .all));
    var n: usize = 0;
    for (p.diagnostics) |d| {
        if (d.code == .needs_cycle) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), n);
    try expectList(&.{ "d/lib/liba.a", "d/lib/libb.a" }, p.build);
}

test "two packages owning one native library are refused" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{ try mk(a, "d1", provides_b), try mk(a, "d2",
        \\{"schema": 1, "name": "other", "native": [
        \\  {"id": "b2", "soname": "libb.so.1", "file": "lib/libb.so.1"}]}
    ) });
    try std.testing.expect(has(p, .duplicate_owner, .all));
    // only the first owner contributes flags
    try expectList(&.{"d1/lib/libb.so.1"}, p.preload);
}

test "the same package twice is refused" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{ try mk(a, "d", provides_b), try mk(a, "d", provides_b) });
    try std.testing.expect(has(p, .duplicate_package, .all));
    try std.testing.expect(!has(p, .duplicate_owner, .all));
    try expectList(&.{"d/lib/libb.so.1"}, p.preload);
}

test "a package with no natives plans nothing" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, ".", "{\"schema\": 1, \"name\": \"pure\"}")});
    try std.testing.expect(p.ok());
    try std.testing.expectEqual(@as(usize, 0), p.build.len);
}

test "a dot directory does not prefix paths" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, ".", pkg_shared)});
    try expectList(&.{ "-Llib", "-lx" }, p.build);
    try expectList(&.{"lib/libx.so.1"}, p.run);
}

test "an absolute directory is normalised: ../ from lib/mojo lands in lib" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, "/env/lib/mojo",
        \\{"schema": 1, "name": "app", "native": [
        \\  {"id": "x", "soname": "libx.so.1", "file": "../libx.so.1"}]}
    )});
    try expectList(&.{ "-L/env/lib", "-lx" }, p.build);
    try expectList(&.{"/env/lib/libx.so.1"}, p.run);
    try expectList(&.{"/env/lib/libx.so.1"}, p.preload);
}

// Golden tests: read tests/fixtures and tests/golden relative to the working
// directory, so run `zig build test` from the repository root.
fn golden(name: []const u8, files: []const []const u8) !void {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    var inputs = std.ArrayList(Input).init(a);
    for (files) |f| {
        const path = try std.fmt.allocPrint(a, "tests/fixtures/{s}/{s}.mopm.json", .{ name, f });
        try inputs.append(try loadInput(a, path));
    }
    const p = try plan(a, inputs.items);
    var out = std.ArrayList(u8).init(a);
    try render(p, out.writer());
    const want = try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "tests/golden/{s}.txt", .{name}), 1 << 20);
    try std.testing.expectEqualStrings(want, out.items);
}

test "golden: chain (a shared library needing a both-flavour library)" {
    try golden("chain", &.{ "http_client", "crypto" });
}

test "golden: missing transitive library" {
    try golden("missing", &.{"http_client"});
}

test "golden: duplicate owner" {
    try golden("dup", &.{ "pkg_a", "pkg_b" });
}

test "golden: static only" {
    try golden("static", &.{"staticpkg"});
}

test "golden: a static library over the static library it needs, given in the other order" {
    try golden("static_chain", &.{ "crypto_sys", "tls_sys" });
}

test "a library that needs its own soname is refused" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, "d",
        \\{"schema": 1, "name": "a", "native": [
        \\  {"id": "a", "soname": "liba.a", "kind": "static", "static_file": "lib/liba.a", "needs": ["liba.a"]}]}
    )});
    try std.testing.expect(has(p, .needs_cycle, .all));
    try std.testing.expect(!has(p, .missing_library, .all));
}

fn groupPkg(a: Allocator, name: []const u8, soname: []const u8, group: []const u8) !Input {
    const stem = soname[0 .. soname.len - 2];
    const text = try std.fmt.allocPrint(a,
        \\{{"schema": 1, "name": "{s}", "native": [
        \\  {{"id": "{s}", "soname": "{s}", "kind": "static", "static_file": "lib/{s}"{s}{s}{s}}}]}}
    , .{ name, stem, soname, soname, if (group.len > 0) ", \"exclusive\": \"" else "", group, if (group.len > 0) "\"" else "" });
    return mk(a, "d", text);
}

// Defect it catches: two copies of one C library (say two prefixed builds of a crypto library) in one closure, which
// link without error and run with two copies of its state. Defect caught: the groups are compared with `!`; the
// pass is removed; a library with no group is made to conflict with another with none.
test "two native libraries of one exclusive group are refused, naming both; other groups and no group are not" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const bad = try plan(a, &.{ try groupPkg(a, "crypto_a", "libca.a", "libcrypto"), try groupPkg(a, "crypto_b", "libcb.a", "libcrypto") });
    try std.testing.expect(has(bad, .exclusive_conflict, .all));
    var found: usize = 0;
    for (bad.diagnostics) |d| {
        if (d.code != .exclusive_conflict) continue;
        found += 1;
        try std.testing.expectEqualStrings("crypto_a (native libca) and crypto_b (native libcb) are both in exclusive group libcrypto; a closure links one library of a group", d.message);
    }
    try std.testing.expectEqual(@as(usize, 1), found);
    // Distinct groups, no group, and a group held once are all fine.
    const other = try plan(a, &.{ try groupPkg(a, "crypto_a", "libca.a", "libcrypto"), try groupPkg(a, "tls_b", "libcb.a", "libtls") });
    try std.testing.expect(!has(other, .exclusive_conflict, .all));
    const none = try plan(a, &.{ try groupPkg(a, "crypto_a", "libca.a", ""), try groupPkg(a, "crypto_b", "libcb.a", "") });
    try std.testing.expect(!has(none, .exclusive_conflict, .all));
    // The same package given twice is duplicate_package and nothing more: its one library is not "two in the group".
    const twice = try plan(a, &.{ try groupPkg(a, "crypto_a", "libca.a", "libcrypto"), try groupPkg(a, "crypto_a", "libca.a", "libcrypto") });
    try std.testing.expect(has(twice, .duplicate_package, .all));
    try std.testing.expect(!has(twice, .exclusive_conflict, .all));
    // Two libraries of one package in one group are two libraries too.
    const same_pkg = try plan(a, &.{try mk(a, "d",
        \\{"schema": 1, "name": "both", "native": [
        \\  {"id": "x", "soname": "libx.a", "kind": "static", "static_file": "lib/libx.a", "exclusive": "g"},
        \\  {"id": "y", "soname": "liby.a", "kind": "static", "static_file": "lib/liby.a", "exclusive": "g"}]}
    )});
    try std.testing.expect(has(same_pkg, .exclusive_conflict, .all));
}
