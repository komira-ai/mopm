//! Version resolution over the sparse index (spec/index.md).
//!
//! `parseIndex` reads one package's index file and applies the reader's rules
//! (record version, one name, no repeated version, the state's required keys,
//! a final newline). `resolve` picks one version of every package in the
//! closure of the root requirements:
//!
//! - requirements follow cargo's rules (semver.zig), for the project's own
//!   dependencies and for the `range` of a dependency in an index record.
//!   That `range` is the cargo requirement from the publisher's mopm.toml,
//!   verbatim (a record without a range accepts any version). The `depends`
//!   of the channel's repodata.json are never read: they are conda's
//!   spelling of the same graph, for conda and pixi, not for this resolver;
//! - a candidate must be `published` (yanked and taken-down versions are
//!   hidden from new resolution, spec/channel.md) and built for exactly the
//!   project's Mojo (`requires_mojo` is `==<toolchain>`);
//! - candidates are tried newest first, after the version a lock already
//!   pins (`Input.pins`); a dead end backtracks to the latest choice.
//!
//! A registry version is MAJOR.MINOR.PATCH, digits only; `MAJOR.MINOR` is
//! read with a zero patch (`1.0` is `1.0.0`). Every other version string in
//! an index (one part, four or more parts, any pre-release or suffix such as
//! `2.0.0-rc1` or `2.1.0b1`) is ignored: it is never picked, and the resolver
//! adds a warning naming it to `Input.warnings`.
//!
//! A failure sets `Diagnostic`: what kind it is and a message naming the
//! requirements and where each came from.

const std = @import("std");
const testroot = @import("testroot.zig");
const Allocator = std.mem.Allocator;
const semver = @import("semver.zig");

pub const State = enum { published, yanked, tombstoned };

pub const File = struct { subdir: []const u8, filename: []const u8, sha256: []const u8, size: u64 };
pub const Dep = struct { name: []const u8, range: ?[]const u8 = null };
pub const Native = struct { id: []const u8, soname: []const u8 };

/// One line of an index file.
pub const Record = struct {
    name: []const u8,
    version: []const u8,
    build: []const u8,
    state: State,
    yank_reason: []const u8 = "",
    tombstone_reason: []const u8 = "",
    requires_mojo: []const u8,
    deps: []const Dep = &.{},
    native: []const Native = &.{},
    files: []const File,
    /// `version` read as MAJOR.MINOR.PATCH; null when it is not one (ignored).
    sv: ?semver.Version,

    /// Whether this build is for exactly `mojo` (`requires_mojo` is `==<mojo>`).
    pub fn builtFor(r: Record, mojo: []const u8) bool {
        const req = std.mem.trim(u8, r.requires_mojo, " ");
        if (!std.mem.startsWith(u8, req, "==")) return false;
        return std.mem.eql(u8, std.mem.trim(u8, req[2..], " "), mojo);
    }

    /// The compiler the build names (`==1.0.0` gives `1.0.0`), for messages.
    pub fn mojoOf(r: Record) []const u8 {
        const req = std.mem.trim(u8, r.requires_mojo, " ");
        return if (std.mem.startsWith(u8, req, "==")) std.mem.trim(u8, req[2..], " ") else req;
    }
};

pub const Kind = enum {
    /// An index file breaks spec/index.md.
    bad_index,
    /// The index could not be read (network, HTTP status).
    unreachable_index,
    /// A required package has no index file.
    not_found,
    /// A requirement does not parse.
    bad_requirement,
    /// No version matches a requirement.
    no_match,
    /// No version matches every requirement on the package together.
    conflict,
    /// The only versions that match are yanked or taken down.
    yanked,
    /// The only versions that match are built for another Mojo.
    compiler_mismatch,
    /// The search gave up.
    too_complex,
    /// The channel's repodata is missing, malformed or disagrees with the index.
    bad_channel,
};

pub const Diagnostic = struct {
    kind: Kind = .too_complex,
    message: []const u8 = "",
};

pub const Error = error{ ResolveFailed, OutOfMemory };

pub fn fail(arena: Allocator, diag: *Diagnostic, kind: Kind, comptime fmt: []const u8, args: anytype) Error {
    diag.* = .{ .kind = kind, .message = std.fmt.allocPrint(arena, fmt, args) catch return error.OutOfMemory };
    return error.ResolveFailed;
}

fn number(s: []const u8) ?u64 {
    if (s.len == 0 or (s.len > 1 and s[0] == '0')) return null;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(u64, s, 10) catch null;
}

/// A registry version as MAJOR.MINOR.PATCH (`MAJOR.MINOR` gets a zero
/// patch), or null for any other spelling (see the file comment).
pub fn semverOf(text: []const u8) ?semver.Version {
    var parts: [3]u64 = .{ 0, 0, 0 };
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |p| : (n += 1) {
        if (n == 3) return null;
        parts[n] = number(p) orelse return null;
    }
    if (n < 2) return null;
    return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
}

fn sameVersion(a: Record, b: Record) bool {
    if (std.mem.eql(u8, a.version, b.version)) return true;
    const x = a.sv orelse return false;
    const y = b.sv orelse return false;
    return semver.compare(x, y) == .eq;
}

const Line = struct {
    arena: Allocator,
    diag: *Diagnostic,
    name: []const u8,
    n: usize,

    fn bad(l: Line, comptime fmt: []const u8, args: anytype) Error {
        const what = std.fmt.allocPrint(l.arena, fmt, args) catch return error.OutOfMemory;
        return fail(l.arena, l.diag, .bad_index, "the index file of {s}, line {d}: {s}", .{ l.name, l.n, what });
    }

    fn string(l: Line, o: std.json.ObjectMap, key: []const u8) Error![]const u8 {
        return switch (o.get(key) orelse return l.bad("no {s}", .{key})) {
            .string => |s| s,
            else => return l.bad("{s} is not a string", .{key}),
        };
    }

    fn array(l: Line, o: std.json.ObjectMap, key: []const u8) Error![]const std.json.Value {
        return switch (o.get(key) orelse return l.bad("no {s}", .{key})) {
            .array => |a| a.items,
            else => return l.bad("{s} is not an array", .{key}),
        };
    }

    fn object(l: Line, v: std.json.Value, what: []const u8) Error!std.json.ObjectMap {
        return switch (v) {
            .object => |o| o,
            else => return l.bad("{s} is not an object", .{what}),
        };
    }
};

fn parseRecord(arena: Allocator, name: []const u8, text: []const u8, n: usize, diag: *Diagnostic) Error!Record {
    const l = Line{ .arena = arena, .diag = diag, .name = name, .n = n };
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return l.bad("not JSON", .{});
    };
    const o = try l.object(v, "the record");
    const rv = switch (o.get("v") orelse return l.bad("no v", .{})) {
        .integer => |i| i,
        else => return l.bad("v is not an integer", .{}),
    };
    if (rv != 1) return l.bad("record version {d}; this mopm reads 1. Update mopm.", .{rv});
    const rec_name = try l.string(o, "name");
    if (!std.mem.eql(u8, rec_name, name)) return l.bad("names {s}", .{rec_name});
    const state_text = try l.string(o, "state");
    var r = Record{
        .name = rec_name,
        .version = try l.string(o, "version"),
        .build = try l.string(o, "build"),
        .state = std.meta.stringToEnum(State, state_text) orelse return l.bad("unknown state {s}", .{state_text}),
        .requires_mojo = try l.string(o, "requires_mojo"),
        .files = &.{},
        .sv = null,
    };
    r.sv = semverOf(r.version);
    switch (r.state) {
        .published => {},
        .yanked => r.yank_reason = try l.string(o, "yank_reason"),
        .tombstoned => {
            const t = try l.object(o.get("tombstone") orelse return l.bad("tombstoned without a tombstone", .{}), "tombstone");
            r.tombstone_reason = try l.string(t, "reason_code");
        },
    }
    var deps = std.ArrayList(Dep).init(arena);
    for (try l.array(o, "deps")) |dv| {
        const d = try l.object(dv, "a dependency");
        var dep = Dep{ .name = try l.string(d, "name") };
        if (d.get("range") != null) dep.range = try l.string(d, "range");
        try deps.append(dep);
    }
    r.deps = deps.items;
    if (o.get("native") != null) {
        var natives = std.ArrayList(Native).init(arena);
        for (try l.array(o, "native")) |nv| {
            const x = try l.object(nv, "a native library");
            try natives.append(.{ .id = try l.string(x, "id"), .soname = try l.string(x, "soname") });
        }
        r.native = natives.items;
    }
    var files = std.ArrayList(File).init(arena);
    for (try l.array(o, "files")) |fv| {
        const f = try l.object(fv, "a file");
        const sha = try l.string(f, "sha256");
        if (!isSha256(sha)) return l.bad("a file's sha256 is not 64 lowercase hex digits", .{});
        const size: i64 = switch (f.get("size") orelse return l.bad("a file has no size", .{})) {
            .integer => |s| s,
            else => return l.bad("a file's size is not an integer", .{}),
        };
        if (size < 1) return l.bad("a file's size is not positive", .{});
        try files.append(.{ .subdir = try l.string(f, "subdir"), .filename = try l.string(f, "filename"), .sha256 = sha, .size = @intCast(size) });
    }
    if (files.items.len == 0) return l.bad("no files", .{});
    r.files = files.items;
    return r;
}

fn isSha256(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

/// Reads the index file of `name` (newline-delimited records).
pub fn parseIndex(arena: Allocator, name: []const u8, text: []const u8, diag: *Diagnostic) Error![]const Record {
    if (text.len == 0) return fail(arena, diag, .bad_index, "the index file of {s} is empty", .{name});
    if (text[text.len - 1] != '\n') {
        return fail(arena, diag, .bad_index, "the index file of {s} does not end with a newline: it was cut short", .{name});
    }
    var out = std.ArrayList(Record).init(arena);
    var it = std.mem.splitScalar(u8, text[0 .. text.len - 1], '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        n += 1;
        if (line.len == 0) return fail(arena, diag, .bad_index, "the index file of {s}, line {d}: blank", .{ name, n });
        const r = try parseRecord(arena, name, line, n, diag);
        for (out.items) |prev| {
            if (sameVersion(prev, r)) {
                return fail(arena, diag, .bad_index, "the index file of {s}, line {d}: version {s} repeats {s}", .{ name, n, r.version, prev.version });
            }
        }
        try out.append(r);
    }
    return out.toOwnedSlice();
}

/// A requirement of the project (`mopm.toml`) on a package, or of one of
/// its path dependencies (`from` names which).
pub const Root = struct { name: []const u8, requirement: []const u8, from: []const u8 = "mopm.toml" };
/// A version a lock already pins; tried first while it still fits.
pub const Pin = struct { name: []const u8, version: []const u8 };

pub const Input = struct {
    /// The project's Mojo version: every build must be for exactly this.
    mojo: []const u8,
    roots: []const Root,
    pins: []const Pin = &.{},
    /// Where the resolver adds one line per index version it ignores
    /// because it is not MAJOR.MINOR.PATCH; null to drop them.
    warnings: ?*std.ArrayList([]const u8) = null,
    /// Choices tried before the search gives up.
    max_steps: usize = 100_000,
    /// Word a version with no build for `mojo` as spec/unit-graph.md does
    /// ("<name> <version> has no .mojoc for Mojo <M> (published for: ...)").
    mojoc_message: bool = false,
};

pub const Picked = struct {
    record: *const Record,
    /// Names of its direct dependencies, sorted, without repeats.
    deps: []const []const u8,
};

pub const Resolution = struct {
    mojo: []const u8,
    /// Sorted by name.
    packages: []const Picked,
};

const Req = struct {
    name: []const u8,
    req: semver.Req,
    text: []const u8,
    /// "mopm.toml", or "<name> <version>" of the record that asks.
    from: []const u8,
};

/// Resolves `input`. `source.fetch(arena, name, diag)` returns the text of
/// the index file of `name`, null when there is none, or
/// `error.ResolveFailed` with `diag` set when it cannot be read.
pub fn resolve(arena: Allocator, source: anytype, input: Input, diag: *Diagnostic) Error!Resolution {
    var r = Resolver(@TypeOf(source)){
        .arena = arena,
        .source = source,
        .input = input,
        .diag = diag,
        .reqs = std.ArrayList(Req).init(arena),
        .chosen = std.StringArrayHashMap(*const Record).init(arena),
        .index = std.StringHashMap([]const Record).init(arena),
    };
    diag.* = .{};
    for (input.roots) |root| {
        var why: []const u8 = "";
        const req = semver.parseReq(arena, root.requirement, &why) catch |e| switch (e) {
            error.Invalid => return fail(arena, diag, .bad_requirement, "{s}: {s} = \"{s}\": {s}", .{ root.from, root.name, root.requirement, why }),
            error.OutOfMemory => return error.OutOfMemory,
        };
        try r.reqs.append(.{ .name = root.name, .req = req, .text = root.requirement, .from = root.from });
    }
    if (!try r.solve(0)) {
        if (diag.message.len == 0) diag.* = .{ .kind = .too_complex, .message = "no set of versions satisfies every requirement" };
        return error.ResolveFailed;
    }
    var out = std.ArrayList(Picked).init(arena);
    var it = r.chosen.iterator();
    while (it.next()) |e| {
        const rec = e.value_ptr.*;
        var names = std.ArrayList([]const u8).init(arena);
        for (rec.deps) |d| {
            var dup = false;
            for (names.items) |x| dup = dup or std.mem.eql(u8, x, d.name);
            if (!dup) try names.append(d.name);
        }
        std.mem.sort([]const u8, names.items, {}, lessString);
        try out.append(.{ .record = rec, .deps = names.items });
    }
    std.mem.sort(Picked, out.items, {}, struct {
        fn less(_: void, a: Picked, b: Picked) bool {
            return std.mem.order(u8, a.record.name, b.record.name) == .lt;
        }
    }.less);
    diag.* = .{};
    return .{ .mojo = input.mojo, .packages = out.items };
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn Resolver(comptime S: type) type {
    return struct {
        const Self = @This();

        arena: Allocator,
        source: S,
        input: Input,
        diag: *Diagnostic,
        reqs: std.ArrayList(Req),
        chosen: std.StringArrayHashMap(*const Record),
        index: std.StringHashMap([]const Record),
        steps: usize = 0,

        fn records(self: *Self, r: Req) Error![]const Record {
            if (self.index.get(r.name)) |known| return known;
            const text = (try self.source.fetch(self.arena, r.name, self.diag)) orelse {
                return fail(self.arena, self.diag, .not_found, "{s} (required by {s}) is not in the registry's index", .{ r.name, r.from });
            };
            const parsed = try parseIndex(self.arena, r.name, text, self.diag);
            try self.index.put(r.name, parsed);
            if (self.input.warnings) |w| {
                for (parsed) |rec| {
                    if (rec.sv != null) continue;
                    try w.append(try std.fmt.allocPrint(self.arena, "the index lists {s} {s}, which is not a MAJOR.MINOR.PATCH version; it is ignored", .{ rec.name, rec.version }));
                }
            }
            return parsed;
        }

        /// Records of a name, newest first, the pinned version ahead of all.
        fn ordered(self: *Self, name: []const u8, all: []const Record) Error![]const *const Record {
            var out = std.ArrayList(*const Record).init(self.arena);
            for (all) |*rec| {
                if (rec.sv != null) try out.append(rec);
            }
            std.mem.sort(*const Record, out.items, {}, struct {
                fn newer(_: void, a: *const Record, b: *const Record) bool {
                    return semver.compare(a.sv.?, b.sv.?) == .gt;
                }
            }.newer);
            for (self.input.pins) |pin| {
                if (!std.mem.eql(u8, pin.name, name)) continue;
                for (out.items, 0..) |rec, i| {
                    if (!std.mem.eql(u8, rec.version, pin.version)) continue;
                    std.mem.copyBackwards(*const Record, out.items[1 .. i + 1], out.items[0..i]);
                    out.items[0] = rec;
                    break;
                }
            }
            return out.items;
        }

        fn matchesAll(self: *Self, name: []const u8, rec: *const Record) bool {
            const v = rec.sv orelse return false;
            for (self.reqs.items) |q| {
                if (std.mem.eql(u8, q.name, name) and !q.req.matches(v)) return false;
            }
            return true;
        }

        fn acceptable(self: *Self, name: []const u8, rec: *const Record) bool {
            return rec.state == .published and rec.builtFor(self.input.mojo) and self.matchesAll(name, rec);
        }

        fn note(self: *Self, kind: Kind, comptime fmt: []const u8, args: anytype) Error!void {
            self.diag.* = .{ .kind = kind, .message = try std.fmt.allocPrint(self.arena, fmt, args) };
        }

        fn requirements(self: *Self, name: []const u8) Error![]const u8 {
            var out = std.ArrayList(u8).init(self.arena);
            var first = true;
            for (self.reqs.items) |q| {
                if (!std.mem.eql(u8, q.name, name)) continue;
                try out.writer().print("{s}{s} (from {s})", .{ if (first) "" else ", ", q.text, q.from });
                first = false;
            }
            return out.items;
        }

        /// Sets the diagnostic for `name` when no version can be picked for
        /// a reason of its own: the requirements, the state or the compiler.
        /// When acceptable versions exist, their failure lies deeper and the
        /// diagnostic already set is kept.
        fn explain(self: *Self, name: []const u8) Error!void {
            const all = self.index.get(name) orelse return;
            var count: usize = 0;
            var each_matches = true;
            for (self.reqs.items) |q| {
                if (!std.mem.eql(u8, q.name, name)) continue;
                count += 1;
                var any = false;
                for (all) |rec| {
                    if (rec.sv) |v| any = any or q.req.matches(v);
                }
                each_matches = each_matches and any;
            }
            var matching = std.ArrayList(*const Record).init(self.arena);
            for (all) |*rec| {
                if (self.matchesAll(name, rec)) try matching.append(rec);
            }
            const reqs = try self.requirements(name);
            if (matching.items.len == 0) {
                var have = std.ArrayList(u8).init(self.arena);
                for (all, 0..) |rec, i| {
                    try have.writer().print("{s}{s}{s}", .{ if (i == 0) "" else ", ", rec.version, if (rec.sv == null) " (ignored: not MAJOR.MINOR.PATCH)" else switch (rec.state) {
                        .published => "",
                        .yanked => " (yanked)",
                        .tombstoned => " (taken down)",
                    } });
                }
                if (count > 1 and each_matches) {
                    try self.note(.conflict, "no version of {s} satisfies every requirement on it: {s}; the index has {s}", .{ name, reqs, have.items });
                } else {
                    try self.note(.no_match, "no version of {s} matches {s}; the index has {s}", .{ name, reqs, have.items });
                }
                return;
            }
            var published = std.ArrayList(*const Record).init(self.arena);
            for (matching.items) |rec| {
                if (rec.state == .published) try published.append(rec);
            }
            if (published.items.len == 0) {
                var list = std.ArrayList(u8).init(self.arena);
                for (matching.items, 0..) |rec, i| {
                    const sep = if (i == 0) "" else "; ";
                    switch (rec.state) {
                        .yanked => try list.writer().print("{s}{s} was yanked: {s}", .{ sep, rec.version, rec.yank_reason }),
                        else => try list.writer().print("{s}{s} was taken down ({s})", .{ sep, rec.version, rec.tombstone_reason }),
                    }
                }
                try self.note(.yanked, "every version of {s} that matches {s} is withdrawn: {s}", .{ name, reqs, list.items });
                return;
            }
            var built = false;
            for (published.items) |rec| built = built or rec.builtFor(self.input.mojo);
            if (!built and self.input.mojoc_message) {
                // The newest version that matches, and the compilers it has builds for.
                var best = published.items[0];
                for (published.items) |rec| {
                    if (rec.sv != null and (best.sv == null or semver.compare(rec.sv.?, best.sv.?) == .gt)) best = rec;
                }
                var for_mojo = std.ArrayList([]const u8).init(self.arena);
                for (published.items) |rec| {
                    if (std.mem.eql(u8, rec.version, best.version)) try for_mojo.append(rec.mojoOf());
                }
                std.mem.sort([]const u8, for_mojo.items, {}, lessString);
                const first = for_mojo.items[0];
                try self.note(.compiler_mismatch, "{s} {s} has no .mojoc for Mojo {s} (published for: {s}). Build with mojo {s}, ask the publisher for a {s} build, or pin a version that has one.", .{ name, best.version, self.input.mojo, try std.mem.join(self.arena, ", ", for_mojo.items), first, self.input.mojo });
            } else if (!built) {
                var list = std.ArrayList(u8).init(self.arena);
                for (published.items, 0..) |rec, i| {
                    try list.writer().print("{s}{s} (mojo {s})", .{ if (i == 0) "" else ", ", rec.version, rec.mojoOf() });
                }
                try self.note(.compiler_mismatch, "no version of {s} that matches {s} is built for mojo {s}, the project's toolchain: {s}", .{ name, reqs, self.input.mojo, list.items });
            }
        }

        /// The requirement a record's `deps[]` entry puts on `d.name`: its
        /// `range`, verbatim, as cargo reads it.
        fn dependency(self: *Self, rec: *const Record, d: Dep) Error!Req {
            const text = d.range orelse "*";
            var why: []const u8 = "";
            const req = semver.parseReq(self.arena, text, &why) catch |e| switch (e) {
                error.Invalid => return fail(self.arena, self.diag, .bad_index, "{s} {s} requires {s} \"{s}\": {s}", .{ rec.name, rec.version, d.name, text, why }),
                error.OutOfMemory => return error.OutOfMemory,
            };
            return .{ .name = d.name, .req = req, .text = text, .from = try std.fmt.allocPrint(self.arena, "{s} {s}", .{ rec.name, rec.version }) };
        }

        /// Satisfies `reqs[next..]`, extending `chosen`; false at a dead end.
        fn solve(self: *Self, next: usize) Error!bool {
            self.steps += 1;
            if (self.steps > self.input.max_steps) {
                return fail(self.arena, self.diag, .too_complex, "gave up after trying {d} choices", .{self.input.max_steps});
            }
            if (next == self.reqs.items.len) return true;
            const r = self.reqs.items[next];
            if (self.chosen.get(r.name)) |rec| {
                if (rec.sv != null and r.req.matches(rec.sv.?)) return self.solve(next + 1);
                try self.explain(r.name);
                return false;
            }
            const all = try self.records(r);
            var tried = false;
            for (try self.ordered(r.name, all)) |rec| {
                if (!self.acceptable(r.name, rec)) continue;
                tried = true;
                try self.chosen.put(r.name, rec);
                const mark = self.reqs.items.len;
                for (rec.deps) |d| try self.reqs.append(try self.dependency(rec, d));
                if (try self.solve(next + 1)) return true;
                self.reqs.shrinkRetainingCapacity(mark);
                _ = self.chosen.orderedRemove(r.name);
            }
            if (!tried) try self.explain(r.name);
            return false;
        }
    };
}

// ---------------------------------------------------------------- tests

/// A name and a text, for the in-memory indexes and channels of the tests.
pub const Pair = struct { []const u8, []const u8 };

/// An index held in memory: name -> file text.
pub const MemoryIndex = struct {
    files: []const Pair,

    pub fn fetch(self: MemoryIndex, _: Allocator, name: []const u8, _: *Diagnostic) Error!?[]const u8 {
        for (self.files) |f| {
            if (std.mem.eql(u8, f[0], name)) return f[1];
        }
        return null;
    }
};

const sha_a = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";

/// One index line, in the registry's layout.
fn indexLine(comptime name: []const u8, comptime version: []const u8, comptime extra: []const u8) []const u8 {
    return indexLine2(name, version, "1.0.0", "published", extra);
}

fn indexLine2(comptime name: []const u8, comptime version: []const u8, comptime mojo: []const u8, comptime state: []const u8, comptime extra: []const u8) []const u8 {
    const file = "mojo-" ++ name ++ "-" ++ version ++ "-mojo" ++ mojo ++ "_0.conda";
    return "{\"build\":\"mojo" ++ mojo ++ "_0\"," ++ extra ++
        "\"files\":[{\"filename\":\"" ++ file ++ "\",\"sha256\":\"" ++ sha_a ++ "\",\"size\":1000,\"subdir\":\"linux-64\"}]," ++
        "\"manifest_sha256\":\"" ++ sha_a ++ "\",\"name\":\"" ++ name ++ "\",\"published_at\":\"2026-10-13T12:00:00Z\"," ++
        "\"requires_mojo\":\"==" ++ mojo ++ "\",\"state\":\"" ++ state ++ "\",\"v\":1,\"version\":\"" ++ version ++ "\"}\n";
}

const no_deps = "\"deps\":[],";

fn expectPicks(index: MemoryIndex, roots: []const Root, pins: []const Pin, want: []const [2][]const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const res = resolve(arena_state.allocator(), index, .{ .mojo = "1.0.0", .roots = roots, .pins = pins }, &diag) catch |e| {
        std.debug.print("resolution failed ({s}): {s}\n", .{ @tagName(diag.kind), diag.message });
        return e;
    };
    errdefer {
        for (res.packages) |p| std.debug.print("  picked {s} {s}\n", .{ p.record.name, p.record.version });
    }
    try std.testing.expectEqual(want.len, res.packages.len);
    for (want, res.packages) |w, p| {
        try std.testing.expectEqualStrings(w[0], p.record.name);
        try std.testing.expectEqualStrings(w[1], p.record.version);
    }
}

fn expectFailure(index: MemoryIndex, roots: []const Root, kind: Kind, contains: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    if (resolve(arena_state.allocator(), index, .{ .mojo = "1.0.0", .roots = roots }, &diag)) |res| {
        for (res.packages) |p| std.debug.print("  unexpectedly picked {s} {s}\n", .{ p.record.name, p.record.version });
        return error.TestUnexpectedResult;
    } else |e| if (e != error.ResolveFailed) return e;
    std.testing.expectEqual(kind, diag.kind) catch |e| {
        std.debug.print("message: {s}\n", .{diag.message});
        return e;
    };
    for (contains) |c| {
        if (std.mem.indexOf(u8, diag.message, c) == null) {
            std.debug.print("message '{s}' lacks '{s}'\n", .{ diag.message, c });
            return error.TestUnexpectedResult;
        }
    }
}

const core_versions = indexLine("core", "1.0.0", no_deps) ++ indexLine("core", "1.2.0", no_deps) ++ indexLine("core", "1.2.7", no_deps) ++
    indexLine("core", "1.3.0", no_deps) ++ indexLine("core", "2.0.0", no_deps) ++ indexLine("core", "2.1.0-rc1", no_deps);

test "registry versions are MAJOR.MINOR.PATCH; MAJOR.MINOR gets a zero patch; nothing else is read" {
    const v = semverOf("1.2").?;
    try std.testing.expectEqual(@as(u64, 1), v.major);
    try std.testing.expectEqual(@as(u64, 2), v.minor);
    try std.testing.expectEqual(@as(u64, 0), v.patch);
    const w = semverOf("10.20.30").?;
    try std.testing.expectEqual(@as(u64, 30), w.patch);
    try std.testing.expectEqualStrings("", w.pre);
    for ([_][]const u8{ "1", "1.2.3.4", "2.0.0-rc1", "2.1.0b1", "0.5.0rc1", "1.0.0dev1", "1.0.0+b", "01.2", "1..2", "1.2.", "", "v1.2.3" }) |text| {
        if (semverOf(text)) |_| {
            std.debug.print("read '{s}' as a version\n", .{text});
            return error.TestUnexpectedResult;
        }
    }
}

test "versions that are not MAJOR.MINOR.PATCH are never picked and each gets a warning; 1.0 is 1.0.0" {
    const index = comptime MemoryIndex{ .files = &.{.{
        "legacy",
        indexLine("legacy", "1.0", no_deps) ++ indexLine("legacy", "1.1.0", no_deps) ++
            indexLine("legacy", "1.2.3.4", no_deps) ++ indexLine("legacy", "2.0.0-rc1", no_deps),
    }} };
    // A reader that cut 1.2.3.4 to 1.2.3 would pick it for "1".
    try expectPicks(index, &.{.{ .name = "legacy", .requirement = "1" }}, &.{}, &.{.{ "legacy", "1.1.0" }});
    try expectPicks(index, &.{.{ .name = "legacy", .requirement = "=1.0.0" }}, &.{}, &.{.{ "legacy", "1.0" }});
    try expectPicks(index, &.{.{ .name = "legacy", .requirement = "<1.1" }}, &.{}, &.{.{ "legacy", "1.0" }});
    // A reader that kept the pre-release would pick 2.0.0-rc1 here.
    try expectFailure(index, &.{.{ .name = "legacy", .requirement = ">=2.0.0-rc1" }}, .no_match, &.{"2.0.0-rc1 (ignored: not MAJOR.MINOR.PATCH)"});
    try expectFailure(index, &.{.{ .name = "legacy", .requirement = "=1.2.3" }}, .no_match, &.{"1.2.3.4 (ignored: not MAJOR.MINOR.PATCH)"});
    // A pin on an ignored version is not honoured either.
    try expectPicks(index, &.{.{ .name = "legacy", .requirement = "*" }}, &.{.{ .name = "legacy", .version = "1.2.3.4" }}, &.{.{ "legacy", "1.1.0" }});

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var warnings = std.ArrayList([]const u8).init(a);
    var diag: Diagnostic = .{};
    _ = try resolve(a, index, .{ .mojo = "1.0.0", .roots = &.{.{ .name = "legacy", .requirement = "1" }}, .warnings = &warnings }, &diag);
    try std.testing.expectEqual(@as(usize, 2), warnings.items.len);
    try std.testing.expectEqualStrings("the index lists legacy 1.2.3.4, which is not a MAJOR.MINOR.PATCH version; it is ignored", warnings.items[0]);
    try std.testing.expectEqualStrings("the index lists legacy 2.0.0-rc1, which is not a MAJOR.MINOR.PATCH version; it is ignored", warnings.items[1]);
}

test "requirement edge cases pick the newest version each one allows" {
    const index = comptime MemoryIndex{ .files = &.{.{ "core", core_versions }} };
    const Case = struct { []const u8, []const u8 };
    const cases = [_]Case{
        .{ "1", "1.3.0" }, // caret: newest 1.x, not 2.0.0
        .{ "1.2", "1.3.0" },
        .{ "~1.2", "1.2.7" }, // tilde stops at 1.3
        .{ "=1.2.0", "1.2.0" },
        .{ "<1.2", "1.0.0" },
        .{ ">=1.2, <1.3", "1.2.7" },
        .{ "*", "2.0.0" }, // never 2.1.0-rc1, which is ignored
    };
    for (cases) |case| {
        expectPicks(index, &.{.{ .name = "core", .requirement = case[0] }}, &.{}, &.{.{ "core", case[1] }}) catch |e| {
            std.debug.print("for requirement '{s}'\n", .{case[0]});
            return e;
        };
    }
    // A registry pre-release is ignored, even for a requirement that names one.
    try expectFailure(index, &.{.{ .name = "core", .requirement = ">=2.1.0-rc1" }}, .no_match, &.{ ">=2.1.0-rc1 (from mopm.toml)", "2.1.0-rc1 (ignored" });
    try expectFailure(index, &.{.{ .name = "core", .requirement = ">2.0.0" }}, .no_match, &.{">2.0.0 (from mopm.toml)"});
}

test "a lock's pin is kept while it fits, and dropped when it does not" {
    const index = comptime MemoryIndex{ .files = &.{.{ "core", core_versions }} };
    try expectPicks(index, &.{.{ .name = "core", .requirement = "1" }}, &.{.{ .name = "core", .version = "1.2.0" }}, &.{.{ "core", "1.2.0" }});
    try expectPicks(index, &.{.{ .name = "core", .requirement = "~1.2.7" }}, &.{.{ .name = "core", .version = "1.2.0" }}, &.{.{ "core", "1.2.7" }});
}

test "a diamond resolves to the newest version both sides allow" {
    const index = comptime MemoryIndex{ .files = &.{
        .{ "app_a", indexLine("app_a", "1.0.0", "\"deps\":[{\"name\":\"core\",\"range\":\">=1.2,<2\"}],") },
        .{ "app_b", indexLine("app_b", "1.0.0", "\"deps\":[{\"name\":\"core\",\"range\":\"~1.2\"}],") },
        .{ "core", core_versions },
    } };
    // Newest for app_a alone is 1.3.0; app_b holds it to 1.2.x.
    try expectPicks(index, &.{ .{ .name = "app_a", .requirement = "1" }, .{ .name = "app_b", .requirement = "1" } }, &.{}, &.{
        .{ "app_a", "1.0.0" }, .{ "app_b", "1.0.0" }, .{ "core", "1.2.7" },
    });
}

test "backtracking: an older parent whose dependency fits" {
    const index = comptime MemoryIndex{ .files = &.{
        .{ "top", indexLine("top", "1.0.0", "\"deps\":[{\"name\":\"core\",\"range\":\"^1\"}],") ++
            indexLine("top", "1.1.0", "\"deps\":[{\"name\":\"core\",\"range\":\"^2\"}],") },
        .{ "core", core_versions },
    } };
    // top 1.1.0 needs core 2, which the root forbids; top 1.0.0 is the answer.
    try expectPicks(index, &.{ .{ .name = "top", .requirement = "1" }, .{ .name = "core", .requirement = "<2" } }, &.{}, &.{
        .{ "core", "1.3.0" }, .{ "top", "1.0.0" },
    });
}

test "a conflict names every requirement and where it came from" {
    const index = comptime MemoryIndex{ .files = &.{
        .{ "app_a", indexLine("app_a", "1.0.0", "\"deps\":[{\"name\":\"core\",\"range\":\"^1\"}],") },
        .{ "app_b", indexLine("app_b", "1.0.0", "\"deps\":[{\"name\":\"core\",\"range\":\"^2\"}],") },
        .{ "core", core_versions },
    } };
    try expectFailure(index, &.{ .{ .name = "app_a", .requirement = "1" }, .{ .name = "app_b", .requirement = "1" } }, .conflict, &.{
        "no version of core satisfies every requirement", "^1 (from app_a 1.0.0)", "^2 (from app_b 1.0.0)",
    });
}

test "yanked and taken-down versions are not picked; when only they match, the reason is shown" {
    const index = comptime MemoryIndex{ .files = &.{.{
        "tls",
        indexLine("tls", "1.0.0", no_deps) ++
            indexLine2("tls", "1.1.0", "1.0.0", "yanked", no_deps ++ "\"yank_reason\":\"crashes on empty body\",") ++
            indexLine2("tls", "1.2.0", "1.0.0", "tombstoned", no_deps ++ "\"tombstone\":{\"date\":\"2026-10-14\",\"reason_code\":\"malware\"},"),
    }} };
    try expectPicks(index, &.{.{ .name = "tls", .requirement = "1" }}, &.{}, &.{.{ "tls", "1.0.0" }});
    // A pin on a yanked version is not honoured by new resolution.
    try expectPicks(index, &.{.{ .name = "tls", .requirement = "1" }}, &.{.{ .name = "tls", .version = "1.1.0" }}, &.{.{ "tls", "1.0.0" }});
    try expectFailure(index, &.{.{ .name = "tls", .requirement = "=1.1.0" }}, .yanked, &.{"1.1.0 was yanked: crashes on empty body"});
    try expectFailure(index, &.{.{ .name = "tls", .requirement = ">=1.1" }}, .yanked, &.{ "1.1.0 was yanked", "1.2.0 was taken down (malware)" });
}

test "a build for another mojo is not picked; when only it matches, the compiler is named" {
    const index = comptime MemoryIndex{ .files = &.{.{
        "core",
        indexLine("core", "1.0.0", no_deps) ++ indexLine2("core", "1.1.0", "1.1.0", "published", no_deps),
    }} };
    try expectPicks(index, &.{.{ .name = "core", .requirement = "1" }}, &.{}, &.{.{ "core", "1.0.0" }});
    try expectFailure(index, &.{.{ .name = "core", .requirement = "=1.1.0" }}, .compiler_mismatch, &.{ "built for mojo 1.0.0", "1.1.0 (mojo 1.1.0)" });
}

test "no version with a build for the project's mojo: the error names the version, its builds and the way out" {
    // core 1.2.0 is built for mojo 1.0.0 only; the project builds for 1.1.0.
    const index = comptime MemoryIndex{ .files = &.{.{
        "core",
        indexLine("core", "1.1.0", no_deps) ++ indexLine("core", "1.2.0", no_deps) ++ indexLine2("core", "1.0.0", "1.1.0", "published", no_deps),
    }} };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const roots = [_]Root{.{ .name = "core", .requirement = "1.2" }};
    try std.testing.expectError(error.ResolveFailed, resolve(arena_state.allocator(), index, .{ .mojo = "1.1.0", .roots = &roots, .mojoc_message = true }, &diag));
    try std.testing.expectEqual(Kind.compiler_mismatch, diag.kind);
    try std.testing.expectEqualStrings("core 1.2.0 has no .mojoc for Mojo 1.1.0 (published for: 1.0.0). Build with mojo 1.0.0, ask the publisher for a 1.1.0 build, or pin a version that has one.", diag.message);
    // Without the flag the older wording stays.
    try expectFailure(index, &.{.{ .name = "core", .requirement = "=1.0.0" }}, .compiler_mismatch, &.{"built for mojo 1.0.0"});
}

test "a package with no index file is named with what required it" {
    const index = comptime MemoryIndex{ .files = &.{.{ "top", indexLine("top", "1.0.0", "\"deps\":[{\"name\":\"gone\",\"range\":\"1\"}],") }} };
    try expectFailure(index, &.{.{ .name = "top", .requirement = "1" }}, .not_found, &.{"gone (required by top 1.0.0) is not in the registry's index"});
}

test "index files that break spec/index.md are refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const good = comptime indexLine("core", "1.0.0", no_deps);
    const Case = struct { []const u8, []const u8 };
    const cases = comptime [_]Case{
        .{ good[0 .. good.len - 1], "does not end with a newline" },
        .{ good ++ "\n" ++ good, "blank" },
        .{ good ++ indexLine("core", "1.0", no_deps), "version 1.0 repeats 1.0.0" },
        .{ indexLine("other", "1.0.0", no_deps), "names other" },
        .{ "{\"v\":2}\n", "record version 2; this mopm reads 1. Update mopm." },
        .{ indexLine2("core", "1.0.0", "1.0.0", "yanked", no_deps), "no yank_reason" },
        .{ "not json\n", "not JSON" },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        if (parseIndex(a, "core", case[0], &diag)) |_| {
            std.debug.print("accepted: {s}\n", .{case[1]});
            return error.TestUnexpectedResult;
        } else |e| if (e != error.ResolveFailed) return e;
        if (std.mem.indexOf(u8, diag.message, case[1]) == null) {
            std.debug.print("'{s}' lacks '{s}'\n", .{ diag.message, case[1] });
            return error.TestUnexpectedResult;
        }
    }
}

test "the spec's example index files parse" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    const text = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, "tests/contract/examples/index-record/valid/http_client.ndjson"), 1 << 20);
    const recs = parseIndex(a, "http_client", text, &diag) catch |e| {
        std.debug.print("{s}\n", .{diag.message});
        return e;
    };
    try std.testing.expectEqual(@as(usize, 3), recs.len);
    try std.testing.expectEqual(State.yanked, recs[0].state);
    try std.testing.expectEqualStrings("http_core", recs[1].deps[0].name);
    try std.testing.expectEqualStrings("libcrypto_native.so.1", recs[1].native[0].soname);
}
