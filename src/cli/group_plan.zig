//! The staged set that `mopm publish --staged <dir>` publishes, and the two records the run keeps beside it
//! (spec/staged-set.md): `plan.json` (read), `state.json` and `report.json` (written).
//!
//! The directory holds a channel layout, `<subdir>/<file>.conda`, and `plan.json`, which names the members in
//! dependency order and, for each, its action and the sha256 and size of every file. Nothing here talks to a registry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const conda = core.conda;
const install = core.install;

/// The registry's limits on a group (spec/api/openapi.yaml, `CreateGroupRequest` and `GroupFile`).
pub const max_members: usize = 500;
pub const max_files_per_member: usize = 20;
pub const max_file_bytes: u64 = 100_000_000;
const max_file_signed: i64 = 100_000_000;
/// A readme is at most 64 KiB (as for `mopm publish`).
pub const max_readme_bytes: usize = 65536;

pub const plan_name = "plan.json";
pub const state_name = "state.json";
pub const report_name = "report.json";

pub const Action = enum { upload, skip, refuse };

pub const File = struct { subdir: []const u8, filename: []const u8, sha256: []const u8, size: u64 };

pub const Member = struct {
    name: []const u8,
    version: []const u8,
    action: Action,
    /// `upload` members only.
    manifest_sha256: []const u8 = "",
    files: []const File = &.{},
    /// A path below the staged directory, or null.
    readme: ?[]const u8 = null,
    /// Why a `skip` or `refuse` member is one, if the plan says.
    reason: []const u8 = "",
};

pub const Plan = struct {
    members: []const Member,
    /// The sha256 of the bytes of plan.json: a state file belongs to one plan.
    sha256: []const u8,

    /// The members to upload, in the plan's (dependency) order.
    pub fn uploads(plan: Plan, arena: Allocator) Allocator.Error![]const Member {
        var out = std.ArrayList(Member).init(arena);
        for (plan.members) |m| {
            if (m.action == .upload) try out.append(m);
        }
        return out.items;
    }
};

pub const Parsed = union(enum) { ok: Plan, bad: []const u8 };

fn bad(arena: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!Parsed {
    return .{ .bad = try std.fmt.allocPrint(arena, plan_name ++ ": " ++ fmt, args) };
}

pub fn isSha256(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

/// A name for a file the plan lists: one path segment, no separators, no dots at the front.
fn plainName(s: []const u8) bool {
    if (s.len == 0 or s[0] == '.') return false;
    for (s) |c| {
        if (c == '/' or c == '\\' or c == 0) return false;
    }
    return true;
}

/// A path below the staged directory: relative, no `..`, no empty segment.
fn belowDir(s: []const u8) bool {
    if (s.len == 0 or s[0] == '/') return false;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return false;
        if (std.mem.indexOfScalar(u8, seg, '\\') != null or std.mem.indexOfScalar(u8, seg, 0) != null) return false;
    }
    return true;
}

fn str(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// The plan in `text`, or the first thing wrong with it.
pub fn parsePlan(arena: Allocator, text: []const u8) Allocator.Error!Parsed {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return bad(arena, "is not JSON", .{});
    const top = switch (root) {
        .object => |o| o,
        else => return bad(arena, "is not a JSON object", .{}),
    };
    const v = switch (top.get("version") orelse std.json.Value{ .null = {} }) {
        .integer => |n| n,
        else => return bad(arena, "has no integer 'version'", .{}),
    };
    if (v != 1) return bad(arena, "is version {d}; this mopm reads version 1", .{v});
    const list = switch (top.get("members") orelse std.json.Value{ .null = {} }) {
        .array => |a| a.items,
        else => return bad(arena, "has no 'members' array", .{}),
    };
    if (list.len == 0) return bad(arena, "lists no members", .{});
    var members = std.ArrayList(Member).init(arena);
    var uploads: usize = 0;
    for (list, 0..) |item, i| {
        const o = switch (item) {
            .object => |o| o,
            else => return bad(arena, "member {d} is not a JSON object", .{i}),
        };
        const name = str(o, "name") orelse return bad(arena, "member {d} has no 'name'", .{i});
        const version = str(o, "version") orelse return bad(arena, "{s} has no 'version'", .{name});
        if (!conda.exactVersion(version)) return bad(arena, "{s} has the version '{s}', which is not MAJOR.MINOR.PATCH", .{ name, version });
        for (members.items) |seen| {
            if (std.mem.eql(u8, seen.name, name)) return bad(arena, "lists {s} twice: a group has one version of each package", .{name});
        }
        const action_text = str(o, "action") orelse return bad(arena, "{s} has no 'action'", .{name});
        const action = std.meta.stringToEnum(Action, action_text) orelse return bad(arena, "{s} has the action '{s}' (upload, skip or refuse)", .{ name, action_text });
        var m = Member{ .name = name, .version = version, .action = action, .reason = str(o, "reason") orelse "" };
        if (action == .upload) {
            uploads += 1;
            m.manifest_sha256 = str(o, "manifest_sha256") orelse "";
            if (!isSha256(m.manifest_sha256)) return bad(arena, "{s} needs a 'manifest_sha256' of 64 lowercase hex digits", .{name});
            const files = switch (o.get("files") orelse std.json.Value{ .null = {} }) {
                .array => |a| a.items,
                else => return bad(arena, "{s} has no 'files' array", .{name}),
            };
            if (files.len < 1 or files.len > max_files_per_member) return bad(arena, "{s} lists {d} files; a member has 1 to {d}", .{ name, files.len, max_files_per_member });
            var out = std.ArrayList(File).init(arena);
            for (files) |fv| {
                const fo = switch (fv) {
                    .object => |x| x,
                    else => return bad(arena, "a file of {s} is not a JSON object", .{name}),
                };
                const subdir = str(fo, "subdir") orelse "";
                if (!conda.isSubdir(subdir)) return bad(arena, "a file of {s} has the subdir '{s}' (noarch, linux-64, linux-aarch64 or osx-arm64)", .{ name, subdir });
                const filename = str(fo, "filename") orelse "";
                if (!plainName(filename)) return bad(arena, "a file of {s} has the file name '{s}', which is not a plain file name", .{ name, filename });
                const sha = str(fo, "sha256") orelse "";
                if (!isSha256(sha)) return bad(arena, "{s} in {s} needs a 'sha256' of 64 lowercase hex digits", .{ filename, name });
                const size: u64 = switch (fo.get("size") orelse std.json.Value{ .null = {} }) {
                    .integer => |n| if (n >= 1 and n <= max_file_signed) @intCast(n) else return bad(arena, "{s} in {s} has the size {d}; a file is 1 to {d} bytes", .{ filename, name, n, max_file_bytes }),
                    else => return bad(arena, "{s} in {s} needs an integer 'size'", .{ filename, name }),
                };
                for (out.items) |other| {
                    if (std.mem.eql(u8, other.subdir, subdir) and std.mem.eql(u8, other.filename, filename)) {
                        return bad(arena, "{s} lists {s}/{s} twice", .{ name, subdir, filename });
                    }
                }
                try out.append(.{ .subdir = subdir, .filename = filename, .sha256 = sha, .size = size });
            }
            m.files = out.items;
            if (str(o, "readme")) |r| {
                if (!belowDir(r)) return bad(arena, "the readme of {s} is '{s}', which is not a path below the staged directory", .{ name, r });
                m.readme = r;
            }
        }
        try members.append(m);
    }
    if (uploads > max_members) return bad(arena, "has {d} members to upload; a group has at most {d}", .{ uploads, max_members });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return .{ .ok = .{ .members = members.items, .sha256 = try std.fmt.allocPrint(arena, "{s}", .{std.fmt.fmtSliceHexLower(&digest)}) } };
}

/// Why the staged set cannot be published as it stands, from the plan alone: a member the staging itself refused.
pub fn refusedMember(plan: Plan) ?Member {
    for (plan.members) |m| {
        if (m.action == .refuse) return m;
    }
    return null;
}

const Sum = struct { sha256: [64]u8, size: u64 };

fn sumOf(dir: std.fs.Dir, path: []const u8) !Sum {
    var file = try dir.openFile(path, .{});
    defer file.close();
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var size: u64 = 0;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
        size += n;
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return .{ .sha256 = std.fmt.bytesToHex(digest, .lower), .size = size };
}

pub fn filePath(arena: Allocator, f: File) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ f.subdir, f.filename });
}

/// Hashes every file of the upload members against the plan, and reads the readmes: the first thing that is not as the plan
/// says (a file that is missing, of another size or another sha256, or a readme that cannot be sent), or null. Nothing has
/// been sent when this runs; the bytes that are checked here are checked again as each one is read for its PUT.
pub fn verify(arena: Allocator, dir: std.fs.Dir, plan: Plan) Allocator.Error!?[]const u8 {
    for (plan.members) |m| {
        if (m.action != .upload) continue;
        for (m.files) |f| {
            const path = try filePath(arena, f);
            const got = sumOf(dir, path) catch |e| return try std.fmt.allocPrint(arena, "{s} of {s}: {s}", .{ path, m.name, @errorName(e) });
            if (got.size != f.size) return try std.fmt.allocPrint(arena, "{s} of {s} is {d} bytes; the plan says {d}", .{ path, m.name, got.size, f.size });
            if (!std.mem.eql(u8, &got.sha256, f.sha256)) return try std.fmt.allocPrint(arena, "{s} of {s} has the sha256 {s}; the plan says {s}", .{ path, m.name, &got.sha256, f.sha256 });
        }
        if (m.readme) |r| {
            const text = dir.readFileAlloc(arena, r, max_readme_bytes + 1) catch |e| return try std.fmt.allocPrint(arena, "the readme {s} of {s}: {s}", .{ r, m.name, @errorName(e) });
            if (text.len > max_readme_bytes) return try std.fmt.allocPrint(arena, "the readme {s} of {s} is over {d} bytes", .{ r, m.name, max_readme_bytes });
            if (!std.unicode.utf8ValidateSlice(text)) return try std.fmt.allocPrint(arena, "the readme {s} of {s} is not UTF-8 text", .{ r, m.name });
        }
    }
    return null;
}

/// The bytes of a file, checked against the plan once more; the reason when they are not the planned ones.
pub const Checked = union(enum) { bytes: []const u8, bad: []const u8 };

pub fn readChecked(arena: Allocator, dir: std.fs.Dir, f: File) Allocator.Error!Checked {
    const path = try filePath(arena, f);
    const bytes = dir.readFileAlloc(arena, path, max_file_bytes + 1) catch |e| return .{ .bad = try std.fmt.allocPrint(arena, "{s}: {s}", .{ path, @errorName(e) }) };
    const sha = try install.sha256Hex(arena, bytes);
    if (bytes.len != f.size or !std.mem.eql(u8, sha, f.sha256)) {
        return .{ .bad = try std.fmt.allocPrint(arena, "{s} changed since the plan was read (sha256 {s}, plan {s})", .{ path, sha, f.sha256 }) };
    }
    return .{ .bytes = bytes };
}

// ------------------------------------------------------------------ state.json

/// What a run has done, so a rerun after a failure resumes the same group.
pub const State = struct {
    registry: []const u8,
    plan_sha256: []const u8,
    group_id: []const u8 = "",
    attempt: u32 = 0,
    committed: bool = false,
    /// A `--no-commit` run uploaded every file and stopped with the group open: a later run resumes that group, and says so
    /// clearly if the registry has ended it meanwhile (it does not open the group again behind the caller's back).
    staged: bool = false,
    /// `<package>/<subdir>/<file name>` of each file the registry has taken.
    uploaded: []const []const u8 = &.{},
};

pub const LoadedState = union(enum) { none, ok: State, bad: []const u8 };

pub fn loadState(arena: Allocator, dir: std.fs.Dir) !LoadedState {
    const text = dir.readFileAlloc(arena, state_name, 1 << 24) catch |e| switch (e) {
        error.FileNotFound => return .none,
        else => return .{ .bad = try std.fmt.allocPrint(arena, "{s}: {s}", .{ state_name, @errorName(e) }) },
    };
    const state = std.json.parseFromSliceLeaky(State, arena, text, .{ .ignore_unknown_fields = true }) catch {
        return .{ .bad = try std.fmt.allocPrint(arena, "{s} is not a state file of this mopm", .{state_name}) };
    };
    return .{ .ok = state };
}

pub fn saveState(arena: Allocator, dir: std.fs.Dir, state: State) !void {
    var out = std.ArrayList(u8).init(arena);
    try std.json.stringify(state, .{ .whitespace = .indent_2 }, out.writer());
    try out.append('\n');
    try writeAtomic(dir, state_name, out.items);
}

/// Writes through a temporary file and a rename, so a run killed in the middle leaves the old file or the new one.
fn writeAtomic(dir: std.fs.Dir, name: []const u8, bytes: []const u8) !void {
    var af = try dir.atomicFile(name, .{});
    defer af.deinit();
    try af.file.writeAll(bytes);
    try af.finish();
}

// ----------------------------------------------------------------- report.json

pub const FileReport = struct { subdir: []const u8, filename: []const u8, sha256: []const u8 };

pub const MemberReport = struct {
    name: []const u8,
    version: []const u8,
    /// `published`, `staged`, `skipped`, `rejected`, `not_published` or `pending`.
    outcome: []const u8,
    /// The registry's code for a rejected member, or why the plan skipped one.
    code: ?[]const u8 = null,
    files: []const FileReport = &.{},
};

pub const Report = struct {
    run_id: []const u8,
    registry: []const u8,
    group_id: ?[]const u8 = null,
    /// The group's status as last read, or null if it was not read.
    group_status: ?[]const u8 = null,
    /// `published`, `staged`, `aborted`, `nothing_to_abort`, `failed`, `rate_limited`, `no_group_publish`, `timed_out`.
    outcome: []const u8,
    /// The sha256 of plan.json this run published, staged or aborted; the stage and commit jobs compare it.
    plan_sha256: ?[]const u8 = null,
    members: []const MemberReport,
};

pub fn saveReport(arena: Allocator, dir: std.fs.Dir, report: Report) !void {
    var out = std.ArrayList(u8).init(arena);
    try std.json.stringify(report, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, out.writer());
    try out.append('\n');
    try writeAtomic(dir, report_name, out.items);
}

/// 16 hex digits, different on every run.
pub fn newRunId(arena: Allocator) Allocator.Error![]const u8 {
    var bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.fmt.allocPrint(arena, "{s}", .{std.fmt.fmtSliceHexLower(&bytes)});
}

// ------------------------------------------------------------------------ tests

const sha_a = "a" ** 64;
const sha_b = "b" ** 64;


// The helpers state what they check in one line each, so a failing test shows the refusal it got or the plan it accepted.
fn okPlan(a: Allocator, text: []const u8) !Plan {
    const parsed = try parsePlan(a, text);
    try std.testing.expectEqualStrings("a plan", if (parsed == .ok) "a plan" else parsed.bad);
    return parsed.ok;
}

fn refused(a: Allocator, text: []const u8, needle: []const u8) !void {
    const parsed = try parsePlan(a, text);
    try std.testing.expectEqualStrings(needle, if (parsed == .bad and std.mem.indexOf(u8, parsed.bad, needle) != null) needle else if (parsed == .bad) parsed.bad else "(accepted)");
}

const member_a =
    \\{"name":"a","version":"1.0.0","action":"upload","manifest_sha256":"
++ sha_a ++
    \\","files":[{"subdir":"noarch","filename":"mojo-a-1.0.0-mojo1.0.0_0.conda","sha256":"
++ sha_b ++
    \\","size":10}]}
;

test "a plan names its members in order, with their actions and files" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const plan = try okPlan(a, "{\"version\":1,\"members\":[" ++ member_a ++
        ",{\"name\":\"b\",\"version\":\"2.1.0\",\"action\":\"skip\",\"reason\":\"already published\"}," ++
        "{\"name\":\"c\",\"version\":\"0.0.1\",\"action\":\"refuse\",\"reason\":\"yanked\"}]}");
    try std.testing.expectEqual(@as(usize, 3), plan.members.len);
    try std.testing.expectEqualStrings("a", plan.members[0].name);
    try std.testing.expectEqual(Action.upload, plan.members[0].action);
    try std.testing.expectEqualStrings("mojo-a-1.0.0-mojo1.0.0_0.conda", plan.members[0].files[0].filename);
    try std.testing.expectEqual(@as(u64, 10), plan.members[0].files[0].size);
    try std.testing.expectEqualStrings("already published", plan.members[1].reason);
    try std.testing.expectEqualStrings("c", refusedMember(plan).?.name);
    const up = try plan.uploads(a);
    try std.testing.expectEqual(@as(usize, 1), up.len);
    try std.testing.expectEqual(@as(usize, 64), plan.sha256.len);
    // The same bytes are the same plan; one byte more is another.
    const again = try okPlan(a, "{\"version\":1,\"members\":[" ++ member_a ++ "]}");
    try std.testing.expect(!std.mem.eql(u8, again.sha256, plan.sha256));
    try std.testing.expectEqualStrings(again.sha256, (try okPlan(a, "{\"version\":1,\"members\":[" ++ member_a ++ "]}")).sha256);
    try std.testing.expect(refusedMember(again) == null);
    const readme = try okPlan(a, "{\"version\":1,\"members\":[" ++ member_a[0 .. member_a.len - 1] ++ ",\"readme\":\"docs/a.md\"}]}");
    try std.testing.expectEqualStrings("docs/a.md", readme.members[0].readme.?);
}

test "a plan that is not one is refused, with the reason" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const head = "{\"version\":1,\"members\":[";
    const file = "{\"subdir\":\"noarch\",\"filename\":\"mojo-a-1.0.0-x.conda\",\"sha256\":\"" ++ sha_b ++ "\",\"size\":10}";
    const upload = "{\"name\":\"a\",\"version\":\"1.0.0\",\"action\":\"upload\",\"manifest_sha256\":\"" ++ sha_a ++ "\",\"files\":[";
    try refused(a, "not json", "is not JSON");
    try refused(a, "[]", "not a JSON object");
    try refused(a, "{}", "no integer 'version'");
    try refused(a, "{\"version\":2,\"members\":[]}", "is version 2");
    try refused(a, "{\"version\":1}", "no 'members' array");
    try refused(a, head ++ "]}", "lists no members");
    try refused(a, head ++ "3]}", "member 0 is not a JSON object");
    try refused(a, head ++ "{}]}", "member 0 has no 'name'");
    try refused(a, head ++ "{\"name\":\"a\"}]}", "a has no 'version'");
    try refused(a, head ++ "{\"name\":\"a\",\"version\":\"1.0\"}]}", "not MAJOR.MINOR.PATCH");
    try refused(a, head ++ "{\"name\":\"a\",\"version\":\"1.0.0\"}]}", "a has no 'action'");
    try refused(a, head ++ "{\"name\":\"a\",\"version\":\"1.0.0\",\"action\":\"push\"}]}", "the action 'push'");
    try refused(a, head ++ "{\"name\":\"a\",\"version\":\"1.0.0\",\"action\":\"skip\"},{\"name\":\"a\",\"version\":\"1.0.1\",\"action\":\"skip\"}]}", "lists a twice");
    try refused(a, head ++ "{\"name\":\"a\",\"version\":\"1.0.0\",\"action\":\"upload\"}]}", "'manifest_sha256'");
    try refused(a, head ++ "{\"name\":\"a\",\"version\":\"1.0.0\",\"action\":\"upload\",\"manifest_sha256\":\"" ++ sha_a ++ "\"}]}", "no 'files' array");
    try refused(a, head ++ upload ++ "]}]}", "lists 0 files");
    try refused(a, head ++ upload ++ "3]}]}", "is not a JSON object");
    try refused(a, head ++ upload ++ "{}]}]}", "the subdir ''");
    try refused(a, head ++ upload ++ "{\"subdir\":\"win-64\"}]}]}", "the subdir 'win-64'");
    try refused(a, head ++ upload ++ "{\"subdir\":\"noarch\",\"filename\":\"../x.conda\"}]}]}", "not a plain file name");
    try refused(a, head ++ upload ++ "{\"subdir\":\"noarch\",\"filename\":\"x.conda\",\"sha256\":\"zz\"}]}]}", "'sha256' of 64");
    try refused(a, head ++ upload ++ "{\"subdir\":\"noarch\",\"filename\":\"x.conda\",\"sha256\":\"" ++ sha_b ++ "\"}]}]}", "integer 'size'");
    try refused(a, head ++ upload ++ "{\"subdir\":\"noarch\",\"filename\":\"x.conda\",\"sha256\":\"" ++ sha_b ++ "\",\"size\":0}]}]}", "has the size 0");
    try refused(a, head ++ upload ++ "{\"subdir\":\"noarch\",\"filename\":\"x.conda\",\"sha256\":\"" ++ sha_b ++ "\",\"size\":100000001}]}]}", "has the size 100000001");
    try refused(a, head ++ upload ++ file ++ "," ++ file ++ "]}]}", "twice");
    try refused(a, head ++ upload[0 .. upload.len] ++ file ++ "],\"readme\":\"/etc/passwd\"}]}", "not a path below the staged directory");
    try refused(a, head ++ upload[0 .. upload.len] ++ file ++ "],\"readme\":\"../x.md\"}]}", "not a path below the staged directory");
    // More members than a group may hold.
    var many = std.ArrayList(u8).init(a);
    try many.appendSlice(head);
    for (0..max_members + 1) |i| {
        if (i != 0) try many.append(',');
        try many.writer().print("{{\"name\":\"p{d}\",\"version\":\"1.0.0\",\"action\":\"upload\",\"manifest_sha256\":\"{s}\",\"files\":[{s}]}}", .{ i, sha_a, file });
    }
    try many.appendSlice("]}");
    try refused(a, many.items, "has 501 members to upload");
    // Too many files for one member.
    var files = std.ArrayList(u8).init(a);
    for (0..max_files_per_member + 1) |i| {
        if (i != 0) try files.append(',');
        try files.writer().print("{{\"subdir\":\"noarch\",\"filename\":\"f{d}.conda\",\"sha256\":\"{s}\",\"size\":1}}", .{ i, sha_b });
    }
    try refused(a, try std.fmt.allocPrint(a, "{s}{s}{s}]}}]}}", .{ head, upload, files.items }), "lists 21 files");
}

test "paths below the directory" {
    try std.testing.expect(belowDir("README.md"));
    try std.testing.expect(belowDir("docs/a/README.md"));
    for ([_][]const u8{ "", "/abs", "../up", "a/../b", "a//b", "./a", "a\\b" }) |p| try std.testing.expect(!belowDir(p));
    try std.testing.expect(plainName("mojo-a-1.0.0-x.conda"));
    for ([_][]const u8{ "", ".hidden", "a/b", "a\\b", ".." }) |p| try std.testing.expect(!plainName(p));
}

test "verify finds a missing file, another size, another sha256 and a bad readme; readChecked finds a change since" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("noarch");
    try tmp.dir.writeFile("noarch/f.conda", "0123456789");
    const sha = try install.sha256Hex(a, "0123456789");
    const text = try std.fmt.allocPrint(a,
        \\{{"version":1,"members":[{{"name":"a","version":"1.0.0","action":"upload","manifest_sha256":"{s}","readme":"R.md",
        \\"files":[{{"subdir":"noarch","filename":"f.conda","sha256":"{s}","size":10}}]}}]}}
    , .{ sha_a, sha });
    const plan = try okPlan(a, text);
    // The readme is missing at first.
    try std.testing.expect(std.mem.indexOf(u8, (try verify(a, tmp.dir, plan)).?, "the readme R.md of a: FileNotFound") != null);
    try tmp.dir.writeFile("R.md", "# a\n");
    try std.testing.expect((try verify(a, tmp.dir, plan)) == null);
    try tmp.dir.writeFile("R.md", "\xff\xfe");
    try std.testing.expect(std.mem.indexOf(u8, (try verify(a, tmp.dir, plan)).?, "not UTF-8") != null);
    const big = try a.alloc(u8, max_readme_bytes + 1);
    @memset(big, 'a');
    try tmp.dir.writeFile("R.md", big);
    try std.testing.expect(std.mem.indexOf(u8, (try verify(a, tmp.dir, plan)).?, "is over 65536 bytes") != null);
    try tmp.dir.writeFile("R.md", "# a\n");

    try std.testing.expect((try readChecked(a, tmp.dir, plan.members[0].files[0])) == .bytes);
    try tmp.dir.writeFile("noarch/f.conda", "0123456780");
    try std.testing.expect(std.mem.indexOf(u8, (try verify(a, tmp.dir, plan)).?, "has the sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, (try readChecked(a, tmp.dir, plan.members[0].files[0])).bad, "changed since the plan was read") != null);
    try tmp.dir.writeFile("noarch/f.conda", "short");
    try std.testing.expect(std.mem.indexOf(u8, (try verify(a, tmp.dir, plan)).?, "is 5 bytes; the plan says 10") != null);
    try tmp.dir.deleteFile("noarch/f.conda");
    try std.testing.expect(std.mem.indexOf(u8, (try verify(a, tmp.dir, plan)).?, "FileNotFound") != null);
    try std.testing.expect(std.mem.indexOf(u8, (try readChecked(a, tmp.dir, plan.members[0].files[0])).bad, "FileNotFound") != null);
    // Members that are not uploaded are not looked at.
    const skipped = try okPlan(a, "{\"version\":1,\"members\":[{\"name\":\"a\",\"version\":\"1.0.0\",\"action\":\"skip\"}]}");
    try std.testing.expect((try verify(a, tmp.dir, skipped)) == null);
}

test "the state and the report are written whole, and the state is read back" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expect((try loadState(a, tmp.dir)) == .none);
    try saveState(a, tmp.dir, .{ .registry = "http://r/api/v1", .plan_sha256 = sha_a, .group_id = "grp_1", .attempt = 2, .committed = true, .uploaded = &.{"a/noarch/f.conda"} });
    const loaded = (try loadState(a, tmp.dir)).ok;
    try std.testing.expectEqualStrings("grp_1", loaded.group_id);
    try std.testing.expectEqual(@as(u32, 2), loaded.attempt);
    try std.testing.expect(loaded.committed);
    try std.testing.expectEqualStrings("a/noarch/f.conda", loaded.uploaded[0]);
    try tmp.dir.writeFile(state_name, "{not json");
    try std.testing.expect(std.mem.indexOf(u8, (try loadState(a, tmp.dir)).bad, "not a state file") != null);
    try tmp.dir.deleteFile(state_name);
    try tmp.dir.makeDir(state_name);
    try std.testing.expect((try loadState(a, tmp.dir)) == .bad);

    try saveReport(a, tmp.dir, .{ .run_id = try newRunId(a), .registry = "http://r/api/v1", .outcome = "published", .members = &.{
        .{ .name = "a", .version = "1.0.0", .outcome = "published", .files = &.{.{ .subdir = "noarch", .filename = "f.conda", .sha256 = sha_b }} },
        .{ .name = "b", .version = "2.0.0", .outcome = "skipped", .code = "already published" },
    } });
    const text = try tmp.dir.readFileAlloc(a, report_name, 1 << 16);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"outcome\": \"skipped\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"group_id\"") == null);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    try std.testing.expectEqual(@as(usize, 16), parsed.object.get("run_id").?.string.len);
    try std.testing.expect(!std.mem.eql(u8, try newRunId(a), try newRunId(a)));
}
