//! mopm core library: package metadata, the mopm.toml manifest and semantic
//! versions, new-package scaffolding, the native link planner, environment
//! discovery, the stock `mojo` command lines, and `mopm test`: discovery,
//! harness generation, the process supervisor, the reports and the filters.

pub const metadata = @import("metadata.zig");
pub const link_planner = @import("link_planner.zig");
pub const toml = @import("toml.zig");
pub const manifest = @import("manifest.zig");
pub const scaffold = @import("scaffold.zig");
pub const semver = @import("semver.zig");
pub const env = @import("env.zig");
pub const mojo_cmd = @import("mojo_cmd.zig");
pub const test_scan = @import("test_scan.zig");
pub const test_harness = @import("test_harness.zig");
pub const autolink = @import("autolink.zig");
pub const test_proc = @import("test_proc.zig");
pub const test_report = @import("test_report.zig");
pub const test_filter = @import("test_filter.zig");
pub const http = @import("http.zig");
pub const registry = @import("registry.zig");
pub const credentials = @import("credentials.zig");
pub const conda = @import("conda.zig");

test {
    _ = @import("metadata.zig");
    _ = @import("link_planner.zig");
    _ = @import("toml.zig");
    _ = @import("manifest.zig");
    _ = @import("scaffold.zig");
    _ = @import("semver.zig");
    _ = @import("env.zig");
    _ = @import("mojo_cmd.zig");
    _ = @import("test_scan.zig");
    _ = @import("test_harness.zig");
    _ = @import("autolink.zig");
    _ = @import("test_proc.zig");
    _ = @import("test_report.zig");
    _ = @import("test_filter.zig");
    _ = @import("http.zig");
    _ = @import("registry.zig");
    _ = @import("credentials.zig");
    _ = @import("conda.zig");
}
