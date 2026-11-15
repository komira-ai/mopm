//! The types of the table of registry commands (`registry_commands.zig`, written by tools/api_gen.zig) that
//! `api_cmd.zig` runs: what a command is called, which operation of the generated client it calls, and how its
//! arguments and flags fill that operation's request.

/// How a flag's text is read.
pub const Kind = enum { string, integer, boolean, enumeration, names_or_const };

/// Where a value goes in the request: a path or query parameter (a field of Op.Params) or a field of its body.
pub const In = enum { params, body };

/// A positional argument.
pub const Arg = struct {
    /// `<namespace>/<name>` for a full name, `<field>` otherwise; `[<q>]` is not written here, see `optional`.
    meta: []const u8,
    /// The field it fills; for a full name: "namespace/name" (it fills `namespace` and `name` of Op.Params).
    key: []const u8,
    in: In = .params,
    full_name: bool = false,
    optional: bool = false,
};

/// A `--flag` that fills one field of the request.
pub const Flag = struct {
    /// `--role`: `--` and the field's name with `_` as `-`.
    flag: []const u8,
    /// `<owner|member>`, `<n>`, `<field_name>`, `<full name>...|all_current`; "" for a boolean.
    meta: []const u8,
    key: []const u8,
    in: In,
    kind: Kind,
    /// An enumeration's JSON values, in the proto's order, without UNSPECIFIED.
    values: []const []const u8 = &.{},
    required: bool = false,
    repeated: bool = false,
    /// The JSON text the field has when the flag is not given (`"member"` with the quotes), from `defaults`.
    default: ?[]const u8 = null,
    /// names_or_const: the one string that selects the const member (`all_current`).
    const_value: []const u8 = "",
};

/// A body field this command sends with a fixed value: its JSON text (`true`, `"mopm {cli_version}"`).
pub const Set = struct { key: []const u8, json: []const u8 };

/// Where the request's body comes from.
pub const Body = enum {
    /// The operation has no body.
    none,
    /// The body is made of the flags.
    flags,
    /// The body is the JSON of `--body <file>` (`-`: standard input); the command has no body flags.
    file,
};

/// One command of the command line: `mopm <name>` makes one call of `Op`.
pub const Command = struct {
    /// `org add`
    name: []const u8,
    /// The generated client's operation: `v2.SetMember`.
    Op: type,
    summary: []const u8,
    /// The usage line: `usage: mopm org add <namespace> <user> [--role <owner|member>] [--registry <prod|gamma|beta|url>] [--config-dir <dir>] [--json]\n`
    usage: []const u8,
    /// The whole text of `mopm <name> --help`, equal to tests/golden/registry/<name>.txt.
    help: []const u8,
    /// The operation needs a token (its `security` is not empty).
    token: bool,
    body: Body,
    args: []const Arg = &.{},
    flags: []const Flag = &.{},
    set: []const Set = &.{},
};
