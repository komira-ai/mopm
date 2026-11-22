//! The readers of the last release before a version could have several builds (the code of main at commit 8b8a8cc), as one
//! module: the sparse-index reader and resolver (resolve.zig), the package-metadata reader (metadata.zig) and the registry
//! client's generated decode (registry_v2.zig), vendored byte for byte under tests/compat/pre_builds (README.md there;
//! SHA256SUMS pins every file). Only this file is written here.
//!
//! The vendored files import nothing but each other and `std`, so they build as part of this module.

pub const resolve = @import("pre_builds/core/resolve.zig");
pub const metadata = @import("pre_builds/core/metadata.zig");
pub const registry_v2 = @import("pre_builds/core/registry_v2.zig");
pub const names = @import("pre_builds/core/names.zig");
