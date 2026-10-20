//! The library root of tools/channels: what a release channel needs that is not the release itself.
//!
//!   tar.zig      byte-deterministic ustar and gzip, and a reader for them
//!   control.zig  Debian control-file syntax
//!   deb.zig      a .deb written byte-deterministically
//!   apt.zig      Packages / Packages.gz / Release, merging a new .deb into an index, monotonic and bounded
//!   formula.zig  the Homebrew formula from SHA256SUMS
//!   version.zig  X.Y.Z and the rule that a channel never moves down
//!
//! `main.zig` is the command line over these. This root exists so one test target runs the tests of all of them.

pub const tar = @import("tar.zig");
pub const control = @import("control.zig");
pub const deb = @import("deb.zig");
pub const apt = @import("apt.zig");
pub const formula = @import("formula.zig");
pub const version = @import("version.zig");

test {
    _ = tar;
    _ = control;
    _ = deb;
    _ = apt;
    _ = formula;
    _ = version;
    _ = @import("golden_test.zig");
}
