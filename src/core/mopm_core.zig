//! mopm core library: package metadata, the mopm.toml manifest and semantic
//! versions, the native link planner, environment discovery, the stock `mojo`
//! command lines, and `mopm test`: discovery, harness generation, the
//! process supervisor, the reports and the filters.

pub const metadata = @import("metadata.zig");
pub const link_planner = @import("link_planner.zig");
pub const toml = @import("toml.zig");
pub const manifest = @import("manifest.zig");
pub const semver = @import("semver.zig");
pub const env = @import("env.zig");
pub const mojo_cmd = @import("mojo_cmd.zig");
pub const test_scan = @import("test_scan.zig");
pub const test_harness = @import("test_harness.zig");
pub const autolink = @import("autolink.zig");
pub const test_proc = @import("test_proc.zig");
pub const test_report = @import("test_report.zig");
pub const test_filter = @import("test_filter.zig");

test {
    _ = @import("metadata.zig");
    _ = @import("link_planner.zig");
    _ = @import("toml.zig");
    _ = @import("manifest.zig");
    _ = @import("semver.zig");
    _ = @import("env.zig");
    _ = @import("mojo_cmd.zig");
    _ = @import("test_scan.zig");
    _ = @import("test_harness.zig");
    _ = @import("autolink.zig");
    _ = @import("test_proc.zig");
    _ = @import("test_report.zig");
    _ = @import("test_filter.zig");
}
