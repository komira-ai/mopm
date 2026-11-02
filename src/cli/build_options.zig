//! The build's options as a module named `build_options`: the version `mopm --version` prints.
//! This file is the Buck2 build's copy and the dev default. `zig build -Dversion=<v>` (build.zig)
//! replaces the module with one generated from the option, which is how a release gets its version:
//! release.yml computes it (RELEASING.md) and tools/release.zig passes it. Both builds default to
//! the same text, and tests/golden checks `mopm --version` prints it.
pub const version: []const u8 = "0.0.1+dev";
// "+dev" is build metadata, which semver ignores when it orders versions: a development build counts as
// 0.0.1, the oldest release, so a registry's `min_cli_version` of 0.0.1 accepts it (the e2e tests rely on that).
