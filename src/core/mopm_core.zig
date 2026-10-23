//! mopm core library: package metadata, the mopm.toml manifest and semantic
//! versions, new-package scaffolding, the native link planner, environment
//! discovery, the stock `mojo` command lines, and `mopm test`: discovery,
//! harness generation, the process supervisor, the reports and the filters, and
//! version resolution over the sparse index into mopm.lock, and installing a
//! lock into the project's pixi environment; and, without pixi, unpacking
//! `.conda` packages into a conda environment.

pub const metadata = @import("metadata.zig");
pub const link_planner = @import("link_planner.zig");
pub const toml = @import("toml.zig");
pub const toml_edit = @import("toml_edit.zig");
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
pub const child_env = @import("child_env.zig");
pub const http = @import("http.zig");
pub const registry = @import("registry.zig");
pub const credentials = @import("credentials.zig");
pub const conda = @import("conda.zig");
pub const resolve = @import("resolve.zig");
pub const lock = @import("lock.zig");
pub const install_plan = @import("install_plan.zig");
pub const install = @import("install.zig");
pub const tar_read = @import("tar_read.zig");
pub const conda_prefix = @import("conda_prefix.zig");
pub const conda_unpack = @import("conda_unpack.zig");
pub const conda_env = @import("conda_env.zig");
pub const pkg_fetch = @import("pkg_fetch.zig");
pub const closure = @import("closure.zig");
pub const unit_graph = @import("unit_graph.zig");
pub const unit_run = @import("unit_run.zig");
pub const target_cpu = @import("target_cpu.zig");

test {
    _ = @import("metadata.zig");
    _ = @import("link_planner.zig");
    _ = @import("toml.zig");
    _ = @import("toml_edit.zig");
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
    _ = @import("resolve.zig");
    _ = @import("lock.zig");
    _ = @import("install_plan.zig");
    _ = @import("install.zig");
    _ = @import("tar_read.zig");
    _ = @import("conda_prefix.zig");
    _ = @import("conda_unpack.zig");
    _ = @import("conda_env.zig");
    _ = @import("pkg_fetch.zig");
    _ = @import("closure.zig");
    _ = @import("unit_graph.zig");
    _ = @import("unit_run.zig");
    _ = @import("target_cpu.zig");
    _ = @import("testroot.zig");
}
