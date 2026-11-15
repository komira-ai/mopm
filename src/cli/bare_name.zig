//! The refusal of a bare `[package] name` in the root mopm.toml, worded with the namespace `mopm login` stored
//! (spec/mopm-toml.md, "Names"): `lock`, `update`, `sync`, `tree`, `add` and `remove` read the root manifest through
//! install_cmd.zig, which passes a refused message through `reword`. Only that refusal looks anything up, and only when
//! an entry of credentials.json holds a namespace: then it fetches the registry's config.json, whose `api_url` keys the
//! entry. Anything that fails leaves the message as it is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const registry = core.registry;

/// The registry a manifest refusal may ask which namespace the user logged in with (`--registry` and the version of mopm),
/// and the directory holding credentials.json (`config_dir`; null, what every command passes, is the user's default
/// config directory; tests set it to a scratch directory).
pub const Lookup = struct { registry: []const u8, cli_version: []const u8, config_dir: ?[]const u8 = null };

/// `message`, the manifest's refusal, worded with the namespace stored for the registry of `l` when it refuses a bare
/// [package] name and a namespace is stored; otherwise `message` itself.
pub fn reword(arena: Allocator, message: []const u8, l: Lookup) Allocator.Error![]const u8 {
    if (barePackageName(message) == null) return message;
    return rewordBarePackage(arena, message, storedNamespace(arena, l));
}

const bare_package_prefix = "package name '";
const bare_package_middle = "' has no namespace: write name = \"<namespace>/";

/// The name `message` refuses when it is the manifest's refusal of a [package] name with no namespace
/// (`package name 'json' has no namespace: write name = "<namespace>/json"`), else null.
fn barePackageName(message: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, message, bare_package_prefix)) return null;
    const rest = message[bare_package_prefix.len..];
    const at = std.mem.indexOf(u8, rest, bare_package_middle) orelse return null;
    const name = rest[0..at];
    const tail = rest[at + bare_package_middle.len ..];
    if (tail.len != name.len + 1 or !std.mem.startsWith(u8, tail, name) or tail[name.len] != '"') return null;
    return name;
}

/// `message`, worded with the namespace `mopm login` stored when it refuses a bare [package] name and there is one;
/// every other message, and any message with no stored namespace, as it is.
fn rewordBarePackage(arena: Allocator, message: []const u8, stored: ?[]const u8) Allocator.Error![]const u8 {
    const name = barePackageName(message) orelse return message;
    const ns = stored orelse return message;
    return std.fmt.allocPrint(arena, "package name '{s}' has no namespace: write name = \"{s}/{s}\" ({s} is your namespace), or another namespace you publish in", .{ name, ns, name, ns });
}

/// The namespace stored by `mopm login` for the registry `l` names, or null when there is none or anything on the way
/// to it fails (the one request a manifest error makes of the registry: config.json).
fn storedNamespace(arena: Allocator, l: Lookup) ?[]const u8 {
    // With no namespace in credentials.json no registry could give one: ask none.
    const dir = l.config_dir orelse (core.credentials.defaultDir(arena) catch return null);
    if (!core.credentials.anyNamespace(arena, dir)) return null;
    const base = switch (registry.resolve(l.registry)) {
        .ok => |b| b,
        .bad => return null,
    };
    const loaded = registry.load(arena, base, l.cli_version) catch return null;
    const config = switch (loaded) {
        .ok => |c| c,
        .bad => return null,
    };
    const entry = (core.credentials.load(arena, dir, config.api_url) catch return null) orelse return null;
    return entry.namespace;
}

test "a refused bare [package] name is worded with the stored namespace, and every other message is kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bare = "package name 'json' has no namespace: write name = \"<namespace>/json\"";
    try std.testing.expectEqualStrings(
        "package name 'json' has no namespace: write name = \"alice/json\" (alice is your namespace), or another namespace you publish in",
        try rewordBarePackage(a, bare, "alice"),
    );
    // No stored namespace: the manifest's message as it is.
    try std.testing.expectEqualStrings(bare, try rewordBarePackage(a, bare, null));
    // Messages that are not that refusal are never reworded, stored namespace or not.
    const others = [_][]const u8{
        "dependency 'json' has no namespace: write it \"<namespace>/json\" = \"1\"",
        "package name 'Json' is not in lower case; write 'json'",
        "package name 'json' has no namespace: write name = \"<namespace>/other\"",
        "package name 'json' has no namespace: write name = \"<namespace>/json\" and more",
        "package name 'json' has no namespace",
        "",
    };
    for (others) |m| try std.testing.expectEqualStrings(m, try rewordBarePackage(a, m, "alice"));
}

test "the bare [package] name is read out of the manifest's refusal and out of nothing else" {
    try std.testing.expectEqualStrings("json", barePackageName("package name 'json' has no namespace: write name = \"<namespace>/json\"").?);
    try std.testing.expectEqualStrings("a-b_c", barePackageName("package name 'a-b_c' has no namespace: write name = \"<namespace>/a-b_c\"").?);
    try std.testing.expect(barePackageName("package name 'json' has no namespace: write name = \"<namespace>/jso\"") == null);
    try std.testing.expect(barePackageName("package name 'json' has no namespace: write name = \"<namespace>/json") == null);
}

test "reword leaves every message but the bare [package] name refusal as it is, looking nothing up" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The registry spec is not one `registry.resolve` takes: a lookup would stop there, but none is made for these.
    const l = Lookup{ .registry = "nonsense", .cli_version = "0.0.1" };
    const dep = "dependency 'json' has no namespace: write it \"<namespace>/json\" = \"1\"";
    try std.testing.expectEqualStrings(dep, try reword(a, dep, l));
    const upper = "package name 'Json' is not in lower case; write 'json'";
    try std.testing.expectEqualStrings(upper, try reword(a, upper, l));
}
