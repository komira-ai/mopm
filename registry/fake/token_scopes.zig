//! What each token scope lets a token do in the fake, kept apart from the routes that ask. `stage` prepares a group (create, read, abort)
//! and nothing else: it never commits, yanks or claims.

const std = @import("std");
const st = @import("state.zig");

/// Reading or aborting a group: an API token that may stage or publish (any package), or a CI token. A yank-only token may not.
pub fn mayStage(t: *const st.Token) bool {
    if (t.kind != .api) return true;
    for (t.scopes) |sc| {
        if (sc == .publish or sc == .stage) return true;
    }
    return false;
}

/// Committing a group: an API token with `publish`, or a CI token that is not a stage token. `stage` is never enough.
pub fn mayCommit(t: *const st.Token) bool {
    if (t.kind != .api) return !t.oidc_stage;
    return std.mem.indexOfScalar(st.Scope, t.scopes, .publish) != null;
}

/// Claiming a package: refused for an API token that has `stage` and neither `publish` nor `yank`. Any other token is as before.
pub fn mayClaim(t: *const st.Token) bool {
    if (t.kind != .api) return true;
    if (std.mem.indexOfScalar(st.Scope, t.scopes, .stage) == null) return true;
    return std.mem.indexOfScalar(st.Scope, t.scopes, .publish) != null or std.mem.indexOfScalar(st.Scope, t.scopes, .yank) != null;
}
