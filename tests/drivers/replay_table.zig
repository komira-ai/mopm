//! The recipes of tests/contract/replay.py, in Zig: for each valid API case of
//! an operation the fake registry implements, how to put a fresh fake in the
//! state the case describes and which request to send (a `Step`).
//!
//! `table` is the list of (operation, case name) with the recipe that builds
//! the step, as RECIPES of replay.py. Recipes reach states the public API
//! cannot (a second account, a stale session, time passing, a server fault)
//! through the fake's /_fake controls, documented in registry/fake/README.md.
//! Used by replay_test.zig. The client and the recipes are in replay_recipes.zig,
//! the assertions in replay_checks.zig.

const std = @import("std");
const Value = std.json.Value;

/// The operations the fake implements. Every valid case of these must replay.
pub const implemented = [_][]const u8{
    "getHealth",        "startDeviceLogin", "pollDeviceLogin", "getMe",            "createToken",    "listTokens",
    "revokeToken",      "exchangeOidcToken", "searchPackages", "getPackage",       "claimPackage",   "listVersions",
    "listOwners",       "inviteOwner",      "removeOwner",     "listInvitations",  "acceptInvitation", "beginUpload",
    "commitPublish",    "getPublishStatus", "setYanked",       "getVersion",
};

/// What a recipe asks the replay to assert about the live answer, besides the
/// contract checks (python's `check` lambdas). `args` of the step feed it.
pub const Check = enum {
    none,
    read_only,
    tokens_listed,
    token_gone,
    packages_named,
    packages_all_current,
    name_is,
    search_prefix,
    search_last_page,
    package_info,
    accepted_owner,
    invitations_names,
    one_owner_left,
    status_is,
    rejected_with,
    yank_state_yanked,
    unyank_state,
    state_yanked,
    detail_yanked,
    detail_tombstoned,
    detail_published,
};

pub const After = enum { none, read_only_off, project_limit_restore };

pub const Step = struct {
    op: []const u8,
    path: ?Value = null,
    query: ?Value = null,
    body: ?[]const u8 = null,
    token: ?[]const u8 = null,
    auth: ?[]const u8 = null,
    check: Check = .none,
    args: [2][]const u8 = .{ "", "" },
    after: After = .none,
    malformed: bool = false,
    raw_path: ?[]const u8 = null,
};

pub const Kind = enum {
    health, health_read_only, device_start, poll, device_unknown, me_no_token, me_unknown_token, me_expired, me_revoked, me,
    token_stale, token_named, token_all, tokens_list, token_revoke_unknown, token_revoke,
    oidc, oidc_invalid, oidc_untrusted,
    search_invalid, fault_search, route_missing, search_prefix, search_last_page,
    pkg_invalid_name, pkg_missing, pkg_fault, pkg_info,
    claim_reserved, claim_taken, claim_similar, claim_plain, claim_similar_ok,
    versions, owners,
    invite_not_owner, invite, remove_unknown, remove_last, remove, invitations, accept_unknown, accept,
    begin, begin_too_big, begin_limit, begin_version, begin_read_only,
    commit, commit_version, publish_missing, status, rejected,
    yank, detail, version_invalid, version_missing,
};

pub const Entry = struct { op: []const u8, name: []const u8, kind: Kind, arg: []const u8 = "" };

pub const table = [_]Entry{
    .{ .op = "getHealth", .name = "prod is up", .kind = .health },
    .{ .op = "getHealth", .name = "beta in read-only mode", .kind = .health_read_only },
    .{ .op = "startDeviceLogin", .name = "start login", .kind = .device_start },
    .{ .op = "pollDeviceLogin", .name = "poll while pending", .kind = .poll, .arg = "pending" },
    .{ .op = "pollDeviceLogin", .name = "poll approved", .kind = .poll, .arg = "approve" },
    .{ .op = "pollDeviceLogin", .name = "poll denied", .kind = .poll, .arg = "deny" },
    .{ .op = "pollDeviceLogin", .name = "poll expired", .kind = .poll, .arg = "expire" },
    .{ .op = "pollDeviceLogin", .name = "error device_code_unknown", .kind = .device_unknown },
    .{ .op = "getMe", .name = "error token_missing", .kind = .me_no_token },
    .{ .op = "getMe", .name = "error token_unknown", .kind = .me_unknown_token },
    .{ .op = "getMe", .name = "error token_expired", .kind = .me_expired },
    .{ .op = "getMe", .name = "error token_revoked", .kind = .me_revoked },
    .{ .op = "getMe", .name = "whoami", .kind = .me },
    .{ .op = "createToken", .name = "error stale_session", .kind = .token_stale },
    .{ .op = "createToken", .name = "create a token for named packages", .kind = .token_named },
    .{ .op = "createToken", .name = "create a token for all current packages", .kind = .token_all },
    .{ .op = "listTokens", .name = "list tokens never returns a secret", .kind = .tokens_list },
    .{ .op = "revokeToken", .name = "error token_not_found", .kind = .token_revoke_unknown },
    .{ .op = "revokeToken", .name = "revoke a token", .kind = .token_revoke },
    .{ .op = "exchangeOidcToken", .name = "exchange a CI identity token", .kind = .oidc },
    .{ .op = "exchangeOidcToken", .name = "error oidc_token_invalid", .kind = .oidc_invalid },
    .{ .op = "exchangeOidcToken", .name = "error oidc_not_trusted", .kind = .oidc_untrusted },
    .{ .op = "searchPackages", .name = "error invalid_request", .kind = .search_invalid },
    .{ .op = "searchPackages", .name = "error rate_limited", .kind = .fault_search, .arg = "rate_limited" },
    .{ .op = "searchPackages", .name = "error unavailable", .kind = .fault_search, .arg = "unavailable" },
    .{ .op = "getHealth", .name = "error route_not_found", .kind = .route_missing },
    .{ .op = "searchPackages", .name = "search by prefix", .kind = .search_prefix },
    .{ .op = "searchPackages", .name = "search, last page, claimed package with no version", .kind = .search_last_page },
    .{ .op = "getPackage", .name = "error invalid_name", .kind = .pkg_invalid_name },
    .{ .op = "getPackage", .name = "error package_not_found", .kind = .pkg_missing },
    .{ .op = "getPackage", .name = "error internal_error", .kind = .pkg_fault },
    .{ .op = "getPackage", .name = "package info", .kind = .pkg_info, .arg = "checked" },
    .{ .op = "getPackage", .name = "package info with homepage, keywords and the latest readme", .kind = .pkg_info },
    .{ .op = "claimPackage", .name = "error name_reserved", .kind = .claim_reserved },
    .{ .op = "claimPackage", .name = "error name_taken", .kind = .claim_taken },
    .{ .op = "claimPackage", .name = "error name_too_similar", .kind = .claim_similar },
    .{ .op = "claimPackage", .name = "claim with no body", .kind = .claim_plain },
    .{ .op = "claimPackage", .name = "claim a similar name on purpose", .kind = .claim_similar_ok },
    .{ .op = "listVersions", .name = "list versions", .kind = .versions },
    .{ .op = "listOwners", .name = "list owners", .kind = .owners },
    .{ .op = "inviteOwner", .name = "error not_owner", .kind = .invite_not_owner },
    .{ .op = "inviteOwner", .name = "error user_not_found", .kind = .invite, .arg = "ghost" },
    .{ .op = "inviteOwner", .name = "error already_owner", .kind = .invite, .arg = "owner" },
    .{ .op = "inviteOwner", .name = "invite an owner", .kind = .invite, .arg = "new" },
    .{ .op = "removeOwner", .name = "error owner_not_found", .kind = .remove_unknown },
    .{ .op = "removeOwner", .name = "error last_owner", .kind = .remove_last },
    .{ .op = "removeOwner", .name = "remove an owner", .kind = .remove },
    .{ .op = "listInvitations", .name = "list invitations", .kind = .invitations },
    .{ .op = "acceptInvitation", .name = "error invitation_not_found", .kind = .accept_unknown },
    .{ .op = "acceptInvitation", .name = "error invitation_expired", .kind = .accept, .arg = "expire" },
    .{ .op = "acceptInvitation", .name = "accept an invitation", .kind = .accept },
    .{ .op = "beginUpload", .name = "begin an upload", .kind = .begin },
    .{ .op = "beginUpload", .name = "error payload_too_large", .kind = .begin_too_big },
    .{ .op = "beginUpload", .name = "error limit_exceeded", .kind = .begin_limit },
    .{ .op = "beginUpload", .name = "error invalid_version: two parts", .kind = .begin_version, .arg = "1.0" },
    .{ .op = "beginUpload", .name = "error read_only_mode", .kind = .begin_read_only },
    .{ .op = "commitPublish", .name = "commit", .kind = .commit, .arg = "ok" },
    .{ .op = "commitPublish", .name = "commit with the display fields", .kind = .commit, .arg = "display" },
    .{ .op = "commitPublish", .name = "error invalid_version: pre-release suffix", .kind = .commit_version, .arg = "1.0.0rc1" },
    .{ .op = "commitPublish", .name = "error upload_invalid", .kind = .commit, .arg = "not uploaded" },
    .{ .op = "commitPublish", .name = "error version_exists", .kind = .commit, .arg = "exists" },
    .{ .op = "commitPublish", .name = "error upload_used", .kind = .commit, .arg = "used" },
    .{ .op = "getPublishStatus", .name = "error publish_not_found", .kind = .publish_missing },
    .{ .op = "getPublishStatus", .name = "status pending", .kind = .status, .arg = "0:pending" },
    .{ .op = "getPublishStatus", .name = "status validating", .kind = .status, .arg = "1:validating" },
    .{ .op = "getPublishStatus", .name = "status indexing", .kind = .status, .arg = "2:indexing" },
    .{ .op = "getPublishStatus", .name = "status published", .kind = .status, .arg = "3:published" },
    .{ .op = "getPublishStatus", .name = "rejected: archive_invalid", .kind = .rejected, .arg = "archive_invalid" },
    .{ .op = "getPublishStatus", .name = "rejected: path_not_allowed", .kind = .rejected, .arg = "path_not_allowed" },
    .{ .op = "getPublishStatus", .name = "rejected: limit_exceeded", .kind = .rejected, .arg = "limit_exceeded" },
    .{ .op = "getPublishStatus", .name = "rejected: manifest_invalid", .kind = .rejected, .arg = "manifest_invalid" },
    .{ .op = "getPublishStatus", .name = "rejected: filename_mismatch", .kind = .rejected, .arg = "filename_mismatch" },
    .{ .op = "getPublishStatus", .name = "rejected: sha256_mismatch", .kind = .rejected, .arg = "sha256_mismatch" },
    .{ .op = "getPublishStatus", .name = "rejected: dependency_not_allowed", .kind = .rejected, .arg = "dependency_not_allowed" },
    .{ .op = "setYanked", .name = "error scope_missing", .kind = .yank, .arg = "scope_missing" },
    .{ .op = "setYanked", .name = "error invalid_transition", .kind = .yank, .arg = "tombstoned" },
    .{ .op = "setYanked", .name = "yank", .kind = .yank, .arg = "yank" },
    .{ .op = "setYanked", .name = "yank with a publish token", .kind = .yank, .arg = "publish token" },
    .{ .op = "setYanked", .name = "unyank", .kind = .yank, .arg = "unyank" },
    .{ .op = "getVersion", .name = "error invalid_version", .kind = .version_invalid },
    .{ .op = "getVersion", .name = "error version_not_found", .kind = .version_missing },
    .{ .op = "getVersion", .name = "version detail", .kind = .detail, .arg = "published" },
    // The display fields are optional and the fake publishes none of them (the publish pipeline fills them from
    // mopm.toml), so these replay the ordinary state: the fake must still answer a valid VersionDetail without them.
    .{ .op = "getVersion", .name = "version detail with the mopm.toml display fields", .kind = .detail, .arg = "published" },
    .{ .op = "getVersion", .name = "yanked version keeps its files and says why", .kind = .detail, .arg = "yanked" },
    .{ .op = "getVersion", .name = "tombstoned version has no url", .kind = .detail, .arg = "tombstoned" },
};

