//! The flags of `mopm publish --staged` (group_publish.zig re-exports what the other commands and the tests name).

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;

pub const usage =
    \\usage: mopm publish --staged <dir> --registry <prod|gamma|beta|url> [--config-dir <dir>] [--wait <seconds>] [--timeout <seconds>] [--retries <n>] [--dry-run] [--oidc] [--no-commit | --abort]
    \\
    \\  Publishes the staged set in <dir> (plan.json and the files it names) through one group: every member is visible
    \\  together, or none is. --registry is required. A rerun after a failure resumes the same group (<dir>/state.json).
    \\  --oidc, inside a GitHub Actions job with 'id-token: write', gets the token from the job's identity, not $MOPM_TOKEN.
    \\  --no-commit uploads every file and stops with the group open (nothing committed, nothing readable); a later run
    \\  without it resumes the same group and commits. With --oidc, --no-commit asks the registry for a stage-only token (it
    \\  can create, read and abort a group, not commit it); a registry without stage tokens answers a publish token, and the
    \\  run goes on with it and says so. --abort ends the open group <dir>/state.json names.
    \\
;

/// The least the run waits for the group to be visible, unless `--wait` says: the base of the default.
pub const default_wait_secs: i64 = 600;
/// The longest `--timeout` may be: an hour, so a typo does not read as no limit.
pub const max_timeout_secs: u32 = 3600;
/// What each member adds to the default wait: validation and the chain take longer the more members a group has
/// (about 8 to 12 minutes at 170 members, 15 to 25 at 300).
pub const wait_per_member_secs: i64 = 5;

/// The default wait of a group of `members`: `default_wait_secs` plus `wait_per_member_secs` for each member.
pub fn defaultWaitFor(members: usize) i64 {
    return default_wait_secs + wait_per_member_secs * @as(i64, @intCast(members));
}
pub const Flags = struct {
    staged: []const u8,
    registry: []const u8,
    config_dir: ?[]const u8 = null,
    /// `--wait`; null means the default of the group's size (`defaultWaitFor`).
    wait_secs: ?i64 = null,
    /// The connect limit and the longest a read or write waits for the server, per request.
    timeout_secs: u32 = http.default_timeout_secs,
    /// Repeats of a request that can be repeated, after its first try.
    retries: u8 = http.default_retries,
    dry_run: bool = false,
    /// `--oidc`: the registry token comes from the CI job's identity, not `$MOPM_TOKEN` or a login.
    oidc: bool = false,
    /// `--no-commit`: upload, then stop with the group open.
    no_commit: bool = false,
    /// `--abort`: end the open group `state.json` names; no file is read, uploaded or committed.
    abort: bool = false,
};

/// The command that waits for the group again: the flags of this run, without `--dry-run`.
pub fn rerunCommand(arena: Allocator, flags: Flags) Allocator.Error![]const u8 {
    var b = std.ArrayList(u8).init(arena);
    const w = b.writer();
    try w.writeAll("mopm publish --staged ");
    try shellWord(w, flags.staged);
    try w.writeAll(" --registry ");
    try shellWord(w, flags.registry);
    if (flags.config_dir) |c| {
        try w.writeAll(" --config-dir ");
        try shellWord(w, c);
    }
    if (flags.wait_secs) |s| try w.print(" --wait {d}", .{s});
    if (flags.oidc) try w.writeAll(" --oidc");
    return b.items;
}

/// `s` as one shell word: bare when it has only safe characters, else in single quotes.
fn shellWord(w: anytype, s: []const u8) !void {
    var safe = s.len > 0;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/._-:=@+,", c) != null)) safe = false;
    }
    if (safe) return w.writeAll(s);
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

pub const Parsed = union(enum) { ok: Flags, bad: []const u8 };

/// Whether `args` of `mopm publish` are the staged form.
pub fn wants(args: []const []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--staged")) return true;
    }
    return false;
}

pub fn parseFlags(arena: Allocator, args: []const []const u8) Allocator.Error!Parsed {
    var staged: ?[]const u8 = null;
    var reg: ?[]const u8 = null;
    var f = Flags{ .staged = "", .registry = "" };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--dry-run")) {
            f.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--oidc")) {
            f.oidc = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-commit")) {
            f.no_commit = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--abort")) {
            f.abort = true;
            continue;
        }
        const takes = std.mem.eql(u8, a, "--staged") or std.mem.eql(u8, a, "--registry") or std.mem.eql(u8, a, "--config-dir") or std.mem.eql(u8, a, "--wait") or std.mem.eql(u8, a, "--timeout") or std.mem.eql(u8, a, "--retries");
        if (!takes) {
            const why = if (std.mem.eql(u8, a, "--compiler") or std.mem.eql(u8, a, "--mojoc") or std.mem.eql(u8, a, "--manifest") or std.mem.eql(u8, a, "--native") or std.mem.eql(u8, a, "--readme"))
                try std.fmt.allocPrint(arena, "{s} packs one package; --staged publishes a staged set, which was packed already", .{a})
            else
                try std.fmt.allocPrint(arena, "unexpected argument '{s}'", .{a});
            return .{ .bad = why };
        }
        if (i + 1 >= args.len) return .{ .bad = try std.fmt.allocPrint(arena, "{s} needs a value", .{a}) };
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, a, "--staged")) {
            staged = v;
        } else if (std.mem.eql(u8, a, "--registry")) {
            reg = v;
        } else if (std.mem.eql(u8, a, "--config-dir")) {
            f.config_dir = v;
        } else if (std.mem.eql(u8, a, "--timeout")) {
            f.timeout_secs = std.fmt.parseInt(u32, v, 10) catch return .{ .bad = try std.fmt.allocPrint(arena, "--timeout {s}: a number of seconds", .{v}) };
            if (f.timeout_secs == 0 or f.timeout_secs > max_timeout_secs) return .{ .bad = try std.fmt.allocPrint(arena, "--timeout is 1 to {d} seconds", .{max_timeout_secs}) };
        } else if (std.mem.eql(u8, a, "--retries")) {
            f.retries = std.fmt.parseInt(u8, v, 10) catch return .{ .bad = try std.fmt.allocPrint(arena, "--retries {s}: a number from 0 to {d}", .{ v, http.max_retries }) };
            if (f.retries > http.max_retries) return .{ .bad = try std.fmt.allocPrint(arena, "--retries is 0 to {d}", .{http.max_retries}) };
        } else {
            const n = std.fmt.parseInt(i64, v, 10) catch return .{ .bad = try std.fmt.allocPrint(arena, "--wait {s}: a number of seconds", .{v}) };
            if (n < 0) return .{ .bad = "--wait is not negative" };
            f.wait_secs = n;
        }
    }
    f.staged = staged orelse return .{ .bad = "--staged <dir> is required" };
    f.registry = reg orelse return .{ .bad = "--registry is required with --staged: there is no default, so a staged set is never published to a registry by accident" };
    if (f.abort and f.no_commit) return .{ .bad = "--abort ends a group and --no-commit stages one: give one of them" };
    if (f.abort and f.dry_run) return .{ .bad = "--abort cannot be a --dry-run: it sends one request and has nothing to preview" };
    return .{ .ok = f };
}
