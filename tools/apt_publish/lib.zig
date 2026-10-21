//! The library root of tools/apt_publish.zig, the publish half of the apt channel: the fail-safe gate, the shape of the shared index
//! and its ETags, the `aws` answers, and the `gpg` command lines. `../apt_publish.zig` is the command line over these (it runs the
//! processes); this root exists so one test target runs the tests of all of them.

pub const gate = @import("gate.zig");
pub const state = @import("state.zig");
pub const awsx = @import("awsx.zig");
pub const gpgx = @import("gpgx.zig");

test {
    _ = gate;
    _ = state;
    _ = awsx;
    _ = gpgx;
}
