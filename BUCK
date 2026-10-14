# mopm's Buck2 targets, built with komira's rules (.buckconfig names the cell).
# `zig build` (build.zig) stays the contributor's quick path; this file is
# what the farm builds. Both name the same roots, executables, modules and unit
# tests, and `:build_parity` fails if they stop doing so. See CONTRIBUTING.md,
# "Building with Buck2".
#
# A test welded into a target gates it: `:mopm` is not built unless `:core_test`
# and `:cli_test` passed, and `:mopm-fake-registry` not unless `:fake_test` did.
#
# Rule names and attributes are those of the komira commit .buckconfig pins.
# ASSUMED (the commit that adds them is not merged when this is written):
#   zig_module: deps; zig_test: optimize; script_test and its attributes
#   (srcs, tools, cmd); python_dist (tests/registry_e2e/BUCK).

load("@komira//tools/build/mojo:toolchain.bzl", "script_test", "zig_exe", "zig_module", "zig_test")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

# What every Zig rule here takes: komira's pinned busybox and zig, on linux.
_TOOLS = {
    "busybox": "komira//tools/build/toolchains:busybox",
    "exec_compatible_with": LINUX_X86_64,
    "zig": "komira//tools/build/toolchains:zig",
}

# The files each root imports by a relative name (all siblings of the root).
_CORE_SRCS = glob(["src/core/*.zig"], exclude = ["src/core/mopm_core.zig"])
_CLI_SRCS = glob(["src/cli/*.zig"], exclude = ["src/cli/main.zig"])
_FAKE_SRCS = glob(["registry/fake/*.zig"], exclude = ["registry/fake/main.zig"])

# What the unit tests read at run time, relative to the repository root
# (src/core/testroot.zig; they run with the root as the working directory).
# A directory glob, so a new fixture is picked up without an edit here.
_UNIT_FIXTURES = glob([
    "tests/contract/examples/**",
    "tests/discovery/**",
    "tests/fixtures/**",
    "tests/new/**",
    "tests/resolve/golden/**",
])

# What tests/run_golden.sh reads. Also a directory glob: tests/golden,
# tests/manifest, tests/discovery and tests/fixtures hold the cases, and a
# case added to them (or a line to the script) is part of this target.
_GOLDEN_SRCS = glob([
    "tests/discovery/**",
    "tests/e2e/flaky/**",
    "tests/fixtures/**",
    "tests/golden/**",
    "tests/manifest/**",
    "tests/new/**",
]) + ["tests/run_golden.sh"]

# ---- Library code and its unit tests ----------------------------------------

zig_module(
    name = "mopm_core",
    src = "src/core/mopm_core.zig",
    imports = _CORE_SRCS,
    unit_tests = [":core_test"],
    visibility = ["PUBLIC"],
)

zig_test(
    name = "core_test",
    src = "src/core/mopm_core.zig",
    imports = _CORE_SRCS + _UNIT_FIXTURES,
    optimize = "Debug",
    **_TOOLS
)

# ---- The CLI -----------------------------------------------------------------

zig_exe(
    name = "mopm",
    src = "src/cli/main.zig",
    imports = _CLI_SRCS,
    deps = [":mopm_core"],
    unit_tests = [":cli_test"],
    visibility = ["PUBLIC"],
    **_TOOLS
)

zig_test(
    name = "cli_test",
    src = "src/cli/main.zig",
    imports = _CLI_SRCS,
    deps = [":mopm_core"],
    optimize = "Debug",
    **_TOOLS
)

# ---- The fake registry the CLI is tested against -----------------------------

zig_exe(
    name = "mopm-fake-registry",
    src = "registry/fake/main.zig",
    imports = _FAKE_SRCS,
    unit_tests = [":fake_test"],
    visibility = ["PUBLIC"],
    **_TOOLS
)

zig_test(
    name = "fake_test",
    src = "registry/fake/main.zig",
    imports = _FAKE_SRCS,
    optimize = "Debug",
    **_TOOLS
)

# ---- Golden files ------------------------------------------------------------
# tests/run_golden.sh runs the built CLI over tests/fixtures and compares with
# tests/golden. It lives here, not in a tests/ package: Buck2 globs stop at a
# package boundary, and these fixtures are also the unit tests' (_UNIT_FIXTURES).

script_test(
    name = "golden",
    srcs = _GOLDEN_SRCS,
    tools = {"MOPM": ":mopm"},
    cmd = 'sh tests/run_golden.sh "$MOPM"',
    busybox = _TOOLS["busybox"],
    exec_compatible_with = LINUX_X86_64,
)

# ---- build.zig and this file name the same build ------------------------------

script_test(
    name = "build_parity",
    srcs = [
        "build.zig",
        "BUCK",
        "tools/build_parity.sh",
        "src/core/mopm_core.zig",
        "src/cli/main.zig",
        "registry/fake/main.zig",
    ],
    cmd = "sh tools/build_parity.sh",
    busybox = _TOOLS["busybox"],
    exec_compatible_with = LINUX_X86_64,
)

# The parity check goes red on a build.zig/BUCK mismatch: the mutants of
# tools/build_parity_selftest.sh.
script_test(
    name = "build_parity_selftest",
    srcs = [
        "build.zig",
        "BUCK",
        "tools/build_parity.sh",
        "tools/build_parity_selftest.sh",
        "src/core/mopm_core.zig",
        "src/core/toml.zig",
        "src/cli/main.zig",
        "registry/fake/main.zig",
    ],
    cmd = "sh tools/build_parity_selftest.sh",
    busybox = _TOOLS["busybox"],
    exec_compatible_with = LINUX_X86_64,
)
