//! mopm core library: package metadata and the native link planner.

pub const metadata = @import("metadata.zig");
pub const link_planner = @import("link_planner.zig");

test {
    _ = @import("metadata.zig");
    _ = @import("link_planner.zig");
}
