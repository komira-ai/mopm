//! mopm core library: package metadata, the mopm.toml manifest, the native link
//! planner, environment discovery and the stock `mojo` command lines.

pub const metadata = @import("metadata.zig");
pub const link_planner = @import("link_planner.zig");
pub const toml = @import("toml.zig");
pub const manifest = @import("manifest.zig");
pub const env = @import("env.zig");
pub const mojo_cmd = @import("mojo_cmd.zig");

test {
    _ = @import("metadata.zig");
    _ = @import("link_planner.zig");
    _ = @import("toml.zig");
    _ = @import("manifest.zig");
    _ = @import("env.zig");
    _ = @import("mojo_cmd.zig");
}
