# mopm's Buck2 targets, built with buildrules' rules (.buckconfig names the cell).
# `zig build` (build.zig) stays the contributor's quick path; this file is
# what the farm builds. Both name the same roots, executables, modules and unit
# tests, and `:build_parity` fails if they stop doing so. See CONTRIBUTING.md,
# "Building with Buck2".
#
# Every test is a Zig test: the build has no shell and no Python. A test welded
# into a target gates it: `:mopm` is not built unless `:core_test` and
# `:cli_test` passed, and `:mopm-fake-registry` not unless `:fake_test` did.
# The drivers (`:golden`, `:registry_login`, `:registry_publish`, the contract
# checks `:contract`, `:contract_replay`, `:lock_golden`, `:resolve_e2e`, and
# the Mojo ones, `:autolink`, `:discovery`, `:supervisor`, `:flaky`,
# `:mojo_probe`) run the built programs or read the specs, so they cannot be
# welded into the programs; `buck2 build //...` builds them. A call marked
# `buck-only` on its first line has no counterpart in
# build.zig and is left out of the parity comparison.

load("@buildrules//rules/zig:zig.bzl", "zig_exe", "zig_module")
# zig_test is the pinned buildrules rule plus the ZigTestInfo that zig_coverage reads (vendor/buildrules_coverage/README.md).
load("//vendor/buildrules_coverage:zig_test.bzl", "zig_test")
load("//vendor/buildrules_coverage:zig_cover.bzl", "zig_coverage")
load("//vendor/buildrules_coverage:tools.bzl", "cov_tools")
load("@buildrules//rules/core:platform.bzl", "LINUX_X86_64")
load("@buildrules//ci:workflow_lint.bzl", "actionlint_check")
load("//:buildrules.bzl", "cargo_workspace")

# The Rust workspace (Cargo.toml): `:check` (is the generated table what Cargo.toml / Cargo.lock / rust-toolchain.toml say),
# and one aggregate per step, `:lint :debug :test :release`, over every member. Each member's BUCK file has one
# `cargo_package` call. `buildrules sync` regenerates buildrules.lock.bzl, buildrules.bzl and third_party/buildrules/BUCK.
cargo_workspace(path = ".")

# What every Zig rule here takes: buildrules' pinned busybox and zig, on linux.
_TOOLS = {
    "busybox": "buildrules//rules/pins:busybox",
    "exec_compatible_with": LINUX_X86_64,
    "zig": "buildrules//rules/pins:zig",
}

# The files each root imports by a relative name (all siblings of the root).
# src/core/toolchain/*.json are embedded (@embedFile) by src/core/unit_graph.zig.
_CORE_SRCS = glob(["src/core/*.zig"], exclude = ["src/core/mopm_core.zig"]) + glob(["src/core/toolchain/*.json"])
_CLI_SRCS = glob(["src/cli/*.zig"], exclude = ["src/cli/main.zig", "src/cli/build_options.zig"])
_FAKE_SRCS = glob(["registry/fake/*.zig"], exclude = ["registry/fake/main.zig"])

# A Buck2 glob skips dotfiles: these are named.
_DOTFILES = [
    "tests/new/bin/.gitignore",
    "tests/new/lib/.gitignore",
]

# What the unit tests read at run time, relative to the repository root, which
# is the working directory of the action. Directory globs, so a new fixture is
# picked up without an edit here.
_UNIT_DATA = glob([
    "tests/contract/examples/**",
    "tests/discovery/**",
    "tests/fixtures/**",
    "tests/golden/**",
    "tests/manifest/**",
    "tests/new/**",
    "tests/resolve/golden/**",
    "toolchain/**",
]) + _DOTFILES

# What the golden driver reads (tests/drivers/golden_test.zig).
_GOLDEN_DATA = glob([
    "tests/discovery/**",
    "tests/e2e/flaky/**",
    "tests/fixtures/**",
    "tests/golden/**",
    "tests/manifest/**",
    "tests/new/**",
]) + _DOTFILES

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
    imports = _CORE_SRCS + _UNIT_DATA,
    # The child processes of the supervisor tests (src/core/test_proc.zig):
    # the farm's image has no /bin/sh.
    env_tools = {"MOPM_TEST_CHILD": ":proc-child"},
    **_TOOLS
)

# ---- The CLI -----------------------------------------------------------------

# The version `mopm --version` prints: the dev default (build.zig's -Dversion option replaces it for a release).
zig_module(
    name = "build_options",
    src = "src/cli/build_options.zig",
    visibility = ["PUBLIC"],
)

zig_exe(
    name = "mopm",
    src = "src/cli/main.zig",
    imports = _CLI_SRCS,
    deps = [":mopm_core", ":build_options"],
    unit_tests = [":cli_test"],
    visibility = ["PUBLIC"],
    **_TOOLS
)

zig_test(
    name = "cli_test",
    src = "src/cli/main.zig",
    imports = _CLI_SRCS,
    deps = [":mopm_core", ":build_options"],
    **_TOOLS
)

# ---- mopm-closure: the toolchain closure files, made from a pixi lock ------------

zig_exe(
    name = "mopm-closure",
    src = "tools/closure_gen.zig",
    deps = [":mopm_core"],
    visibility = ["PUBLIC"],
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
    **_TOOLS
)

# ---- The group-publish end-to-end check (run by the group-e2e job of .github/workflows/e2e.yml) ----------

zig_exe(
    name = "mopm-group-e2e",
    src = "tests/drivers/group_e2e.zig",
    imports = ["tests/drivers/harness.zig"],
    deps = [":mopm_core"],
    visibility = ["PUBLIC"],
    **_TOOLS
)

# ---- Helper programs of the tests (no /bin/sh, no #! scripts on the farm) -----

zig_exe(  # buck-only: the child processes of src/core/test_proc.zig's tests
    name = "proc-child",
    src = "tests/drivers/proc_child.zig",
    optimize = "ReleaseSafe",
    **_TOOLS
)

zig_exe(  # buck-only: stands in for mojo in the golden driver
    name = "fake-mojo",
    src = "tests/drivers/fake_mojo.zig",
    **_TOOLS
)

# ---- Test drivers: Zig ports of tests/run_golden.sh and tests/registry_e2e ----

zig_test(  # buck-only: tests/drivers/golden_test.zig runs the built CLI over the goldens
    name = "golden",
    src = "tests/drivers/golden_test.zig",
    imports = ["tests/drivers/harness.zig"] + _GOLDEN_DATA,
    env_tools = {
        "MOPM": ":mopm",
        "MOPM_FAKE_MOJO": ":fake-mojo",
    },
    **_TOOLS
)

zig_test(  # buck-only: mopm login, whoami and logout against the fake registry
    name = "registry_login",
    src = "tests/drivers/login_test.zig",
    imports = ["tests/drivers/harness.zig"],
    env_tools = {
        "MOPM": ":mopm",
        "MOPM_FAKE_REGISTRY": ":mopm-fake-registry",
    },
    **_TOOLS
)

zig_test(  # buck-only: mopm pack and publish against the fake registry and a stand-in
    name = "registry_publish",
    src = "tests/drivers/publish_test.zig",
    imports = ["tests/drivers/harness.zig"],
    env_tools = {
        "MOPM": ":mopm",
        "MOPM_FAKE_REGISTRY": ":mopm-fake-registry",
    },
    **_TOOLS
)

zig_exe(  # buck-only: stands in for mojo, the test binary and pixi in :group_publish; records whether MOPM_TOKEN reached it
    name = "env-probe",
    src = "tests/drivers/env_probe.zig",
    **_TOOLS
)

zig_test(  # buck-only: mopm publish --staged and mopm yank --group against the fake registry
    name = "group_publish",
    src = "tests/drivers/group_publish_test.zig",
    imports = ["tests/drivers/harness.zig"],
    env_tools = {
        "MOPM": ":mopm",
        "MOPM_FAKE_REGISTRY": ":mopm-fake-registry",
        "MOPM_ENV_PROBE": ":env-probe",
    },
    **_TOOLS
)

zig_test(  # buck-only: mopm publish --oidc against the fake registry and a stand-in for GitHub's identity-token endpoint
    name = "oidc_publish",
    src = "tests/drivers/oidc_publish_test.zig",
    imports = ["tests/drivers/harness.zig"],
    env_tools = {
        "MOPM": ":mopm",
        "MOPM_FAKE_REGISTRY": ":mopm-fake-registry",
    },
    **_TOOLS
)

zig_test(  # buck-only: mopm stage against the fake registry, and publish --staged on what it writes
    name = "stage",
    src = "tests/drivers/stage_test.zig",
    imports = ["tests/drivers/harness.zig"],
    env_tools = {
        "MOPM": ":mopm",
        "MOPM_FAKE_REGISTRY": ":mopm-fake-registry",
    },
    **_TOOLS
)

# tools/channels' sources, named by a glob so a new file is picked up. The release tools import the .deb writer from there.
_CHANNELS_SRCS = glob(["tools/channels/*.zig"], exclude = ["tools/channels/channels.zig", "tools/channels/main.zig"])

zig_exe(  # buck-only: tools/release.zig, whose `tarball` and `sums` make the fake release of :cut_release
    name = "release-tool",
    src = "tools/release.zig",
    imports = ["tools/release_debs.zig"] + _CHANNELS_SRCS,
    **_TOOLS
)

zig_exe(  # buck-only: tools/cut_release.zig, the release run's steps (plan, tag, verify-dir, publish) and the read-only verify
    name = "cut-release",
    src = "tools/cut_release.zig",
    imports = ["tools/bump_internal.zig", "tools/ghtool.zig", "tools/tap.zig", "tools/release_debs.zig"] + _CHANNELS_SRCS,
    **_TOOLS
)

zig_exe(  # buck-only: a `gh` whose answers are files, for :cut_release
    name = "fake-gh",
    src = "tests/drivers/fake_gh.zig",
    **_TOOLS
)

zig_exe(  # buck-only: a `cosign` that signs nothing (a bundle names the file's sha256), for :cut_release
    name = "fake-cosign",
    src = "tests/drivers/fake_cosign.zig",
    **_TOOLS
)

zig_exe(  # buck-only: a `git` whose answers are files, for :bump_internal and :tap
    name = "fake-git",
    src = "tests/drivers/fake_git.zig",
    **_TOOLS
)

zig_test(  # buck-only: cut_release against the fake gh, with known defects it must refuse
    name = "cut_release",
    src = "tests/drivers/cut_release_test.zig",
    imports = ["tests/drivers/harness.zig"] + glob(["packaging/deb/*"]),
    env_tools = {
        "MOPM_CHANNELS": ":channels",
        "MOPM_CUT_RELEASE": ":cut-release",
        "MOPM_FAKE_GH": ":fake-gh",
        "MOPM_RELEASE_TOOL": ":release-tool",
        "MOPM_FAKE_COSIGN": ":fake-cosign",
    },
    **_TOOLS
)

zig_test(  # buck-only: cut_release bump-internal against the fake gh and the fake git, with known defects it must refuse
    name = "bump_internal",
    src = "tests/drivers/bump_internal_test.zig",
    imports = ["tests/drivers/harness.zig"],
    env_tools = {
        "MOPM_CUT_RELEASE": ":cut-release",
        "MOPM_FAKE_GH": ":fake-gh",
        "MOPM_FAKE_GIT": ":fake-git",
    },
    **_TOOLS
)

zig_test(  # buck-only: cut_release tap against the fake gh and the fake git, with known defects it must refuse
    name = "tap",
    src = "tests/drivers/tap_test.zig",
    imports = ["tests/drivers/harness.zig", "tests/channels/golden/mopm.rb", "tests/channels/tap_guard/mopm.rb"],
    env_tools = {
        "MOPM_CUT_RELEASE": ":cut-release",
        "MOPM_FAKE_GH": ":fake-gh",
        "MOPM_FAKE_GIT": ":fake-git",
    },
    **_TOOLS
)

# ---- tools/channels: the .deb, the apt index and the Homebrew formula of a release, byte for byte ----------------------
# (tools/channels/channels.zig says what each file is. _CHANNELS_SRCS, the sources, is defined above :release-tool, which uses it.)

# What the unit tests and the CLI driver read: the fixtures and the golden files.
_CHANNELS_DATA = glob(["tests/channels/**"])

zig_test(  # buck-only: the unit tests and the golden files of tools/channels
    name = "channels_test",
    src = "tools/channels/channels.zig",
    imports = _CHANNELS_SRCS + _CHANNELS_DATA,
    **_TOOLS
)

zig_exe(  # buck-only: tools/channels/main.zig, not built unless the unit tests and goldens pass
    name = "channels",
    src = "tools/channels/main.zig",
    imports = _CHANNELS_SRCS,
    unit_tests = [":channels_test"],
    visibility = ["PUBLIC"],
    **_TOOLS
)

zig_test(  # buck-only: the channels CLI end to end: byte-determinism (twice, compare), goldens, and the refusals it must make
    name = "channels_cli",
    src = "tests/drivers/channels_cli_test.zig",
    imports = ["tests/drivers/harness.zig"] + _CHANNELS_DATA + glob(["packaging/deb/*"]),
    env_tools = {"CHANNELS": ":channels"},
    data = {".github/workflows/release.yml": ".github/workflows/release.yml"},  # the render command of the release's tap job, run against the tap guard's fixture
    **_TOOLS
)

# ---- tools/apt_publish: the publish half of the apt channel (gate, OIDC exchange, read, index, sign, write) -------------------
# (tools/apt_publish.zig says what each command does. The fakes enforce the grants of the publish role and sign nothing.)
_APT_PUBLISH_SRCS = glob(["tools/apt_publish/*.zig"], exclude = ["tools/apt_publish/lib.zig"])

zig_test(  # buck-only: the unit tests of tools/apt_publish (the gate, the shape of the index and its ETags, the aws answers, the gpg command lines)
    name = "apt_publish_test",
    src = "tools/apt_publish/lib.zig",
    imports = _APT_PUBLISH_SRCS,
    **_TOOLS
)

zig_exe(  # buck-only: tools/apt_publish.zig, not built unless the unit tests pass
    name = "apt-publish",
    src = "tools/apt_publish.zig",
    imports = _APT_PUBLISH_SRCS,
    unit_tests = [":apt_publish_test"],
    **_TOOLS
)

zig_exe(  # buck-only: an `aws` that is a small S3, CloudFront and STS and refuses what the publish role may not do, for :apt_publish
    name = "fake-aws",
    src = "tests/drivers/fake_aws.zig",
    **_TOOLS
)

zig_exe(  # buck-only: a `gpg` that signs nothing (a signature names the sha256 of what it covers), for :apt_publish
    name = "fake-gpg",
    src = "tests/drivers/fake_gpg.zig",
    **_TOOLS
)

zig_exe(  # buck-only: a `curl` that is the runner's OIDC token endpoint, for :apt_publish
    name = "fake-curl",
    src = "tests/drivers/fake_curl.zig",
    **_TOOLS
)

zig_test(  # buck-only: apt_publish against the fake aws, gpg and curl: the order, If-None-Match, If-Match and the 412 retry, the signing, the gate
    name = "apt_publish",
    src = "tests/drivers/apt_publish_test.zig",
    imports = ["tests/drivers/harness.zig"] + glob(["packaging/deb/*"]),
    env_tools = {
        "MOPM_APT_PUBLISH": ":apt-publish",
        "MOPM_CHANNELS": ":channels",
        "MOPM_FAKE_AWS": ":fake-aws",
        "MOPM_FAKE_CURL": ":fake-curl",
        "MOPM_FAKE_GPG": ":fake-gpg",
    },
    **_TOOLS
)

# ---- Contract checks, ported from Python (tests/contract, tests/resolve*) ------

# The JSON Schema validator and what it needs, shared by the contract drivers.
_CONTRACT_LIBS = [
    "tests/drivers/contract.zig",
    "tests/drivers/jsonschema.zig",
    "tests/drivers/regex.zig",
]

zig_test(  # buck-only: tests/contract/validate.py: the spec, the API cases and the examples
    name = "contract",
    src = "tests/drivers/contract_test.zig",
    imports = _CONTRACT_LIBS + [
        "tests/drivers/openapi_check.zig",
        "tests/drivers/yaml.zig",
    ] + glob([
        "spec/**",
        "tests/contract/api/**",
        "tests/contract/examples/**",
        "tests/fixtures/**",
    ]),
    **_TOOLS
)

zig_test(  # buck-only: tests/contract/replay.py: the fake registry answers the contract's API cases
    name = "contract_replay",
    src = "tests/drivers/replay_test.zig",
    imports = _CONTRACT_LIBS + [
        "tests/drivers/harness.zig",
        "tests/drivers/replay_recipes.zig",
        "tests/drivers/replay_group_conflicts.zig",
        "tests/drivers/replay_group_facts.zig",
        "tests/drivers/replay_table.zig",
        "tests/drivers/replay_checks.zig",
        "tests/drivers/yaml.zig",
        "registry/fake/errors.zig",
    ] + glob([
        "spec/**",
        "tests/contract/api/**",
    ]),
    env_tools = {"MOPM_FAKE_REGISTRY": ":mopm-fake-registry"},
    **_TOOLS
)

zig_test(  # buck-only: tests/resolve_e2e/run.py: mopm lock, update and tree against the fake registry
    name = "resolve_e2e",
    src = "tests/drivers/resolve_e2e_test.zig",
    imports = _CONTRACT_LIBS + [
        "tests/drivers/harness.zig",
        "spec/lock.schema.json",
    ] + glob(["tests/resolve_e2e/*"]),
    env_tools = {
        "MOPM": ":mopm",
        "MOPM_FAKE_REGISTRY": ":mopm-fake-registry",
    },
    **_TOOLS
)

zig_test(  # buck-only: mopm add, lock and sync with --overlay (a staged set) against the fake registry and a request-recording stand-in
    name = "overlay_e2e",
    src = "tests/drivers/overlay_e2e_test.zig",
    imports = ["tests/drivers/harness.zig"],
    env_tools = {
        "MOPM": ":mopm",
        "MOPM_FAKE_REGISTRY": ":mopm-fake-registry",
        "FAKE_PIXI": ":fake-pixi",
    },
    **_TOOLS
)

zig_test(  # buck-only: tests/resolve/check_golden.py: the goldens pass the lock contract, a faulty writer's output does not
    name = "lock_golden",
    src = "tests/drivers/lock_golden_test.zig",
    imports = _CONTRACT_LIBS + [
        "spec/lock.schema.json",
    ] + glob(["tests/resolve/golden/**"]),
    **_TOOLS
)

zig_test(  # buck-only: docs/examples.md: the files under examples/ are what mopm reads, writes and refuses
    name = "examples",
    src = "tests/drivers/examples_test.zig",
    imports = ["tests/drivers/harness.zig"] + glob(["examples/**"]),
    env_tools = {"MOPM": ":mopm"},
    **_TOOLS
)

# ---- build.zig and this file name the same build, and the check can go red ----

zig_test(  # buck-only: tools/build_parity.zig reads build.zig and this file
    name = "build_parity",
    src = "tools/build_parity.zig",
    imports = [
        "build.zig",
        "BUCK",
        "src/core/mopm_core.zig",
        "src/core/toml.zig",
        "src/cli/main.zig",
        "src/cli/build_options.zig",
        "tools/closure_gen.zig",
        "registry/fake/main.zig",
        "tests/drivers/group_e2e.zig",
    ],
    **_TOOLS
)

# ---- The validator corpus: files made by a Zig generator, and the test that they are what it makes ----

zig_test(  # buck-only: tests/validator_corpus is what tests/drivers/validator_corpus.zig makes
    name = "validator_corpus",
    src = "tests/drivers/validator_corpus_test.zig",
    imports = ["tests/drivers/validator_corpus.zig"] + glob(["tests/validator_corpus/**"]),
    **_TOOLS
)

# ---- Mojo end-to-end drivers (komira's pinned Mojo 1.0.0, no pixi) ----------

zig_exe(  # buck-only: `cc` of the Mojo drivers, zig cc
    name = "zigcc",
    src = "tests/drivers/zigcc.zig",
    **_TOOLS
)

# What the Mojo drivers get: komira's unpacked Mojo toolchain, its zig (the C
# compiler, through :zigcc), and the built CLI.
_MOJO_TOOLS = {
    "CC_SHIM": ":zigcc",
    "MOJO_TOOLCHAIN": "komira//tools/build/toolchains:mojo_compiler",
    "ZIG_DIR": "buildrules//rules/pins:zig",
}

zig_test(  # buck-only: komira's Mojo toolchain works from this cell
    name = "mojo_probe",
    src = "tests/drivers/mojo_probe_test.zig",
    imports = ["tests/drivers/harness.zig", "tests/drivers/mojo_env.zig"],
    exec_tools = _MOJO_TOOLS,
    **_TOOLS
)

_AUTOLINK_DATA = [
    "tests/e2e/native",
    "tests/e2e/pkgs",
    "tests/e2e/prog.mojo",
    "tests/e2e/prog_outer.mojo",
    "tests/e2e/repl.stdin",
    "tests/e2e/repl_outer.stdin",
]
zig_test(  # buck-only: the group-publish check (tests/drivers/group_e2e.zig) against a loopback registry that serves the group routes
    name = "group_e2e",
    src = "tests/drivers/group_e2e_test.zig",
    imports = ["tests/drivers/harness.zig", "tests/drivers/mojo_env.zig", "tests/drivers/group_e2e.zig"],
    deps = [":mopm_core"],
    # The unit tier: the walk is the real one but for the compiler and pixi. The built CLI stages, installs the staged set and
    # publishes it; a stand-in compiler writes the stand-in packages and the README program; a stand-in pixi installs them.
    env_tools = {"MOPM": ":mopm", "FAKE_PIXI": ":fake-pixi", "FAKE_TOOLCHAIN": ":fake-toolchain"},
    **_TOOLS
)

zig_test(  # buck-only: the same walk with the farm's real Mojo 1.0.0, which builds the packages and the README program
    name = "group_e2e_mojo",
    src = "tests/drivers/group_e2e_test.zig",
    imports = ["tests/drivers/harness.zig", "tests/drivers/mojo_env.zig", "tests/drivers/group_e2e.zig"],
    deps = [":mopm_core"],
    exec_tools = dict(_MOJO_TOOLS, MOPM = ":mopm", FAKE_PIXI = ":fake-pixi"),
    **_TOOLS
)

zig_test(  # buck-only: the user-level beta walk (tests/drivers/user_beta.zig) in its farm form: no pixi, no installer
    name = "user_beta",
    src = "tests/drivers/user_beta_test.zig",
    imports = ["tests/drivers/harness.zig", "tests/drivers/mojo_env.zig", "tests/drivers/user_beta.zig", "tests/drivers/user_native.zig"],
    exec_tools = dict(_MOJO_TOOLS, MOPM = ":mopm", MOPM_FAKE_REGISTRY = ":mopm-fake-registry"),
    **_TOOLS
)

zig_test(  # buck-only: the native step of the user-level beta walk (tests/drivers/user_native.zig) with a stand-in compiler and pixi: the switch, the skip line, the output check, and C sources to a published, added, synced, built and run package; it runs on every pull request
    name = "user_native",
    src = "tests/drivers/user_native_test.zig",
    imports = ["tests/drivers/harness.zig", "tests/drivers/user_native.zig"],
    exec_tools = {
        "ZIG_DIR": "buildrules//rules/pins:zig",
        "MOPM": ":mopm",
        "MOPM_FAKE_REGISTRY": ":mopm-fake-registry",
        "FAKE_PIXI": ":fake-pixi",
        "FAKE_TOOLCHAIN": ":fake-toolchain",
    },
    data = ["tests/e2e/natws"],
    **_TOOLS
)


zig_test(  # buck-only: mopm build, run, repl with native libraries; the Zig port of tests/e2e/run.sh
    name = "autolink",
    src = "tests/drivers/test_autolink_test.zig",
    imports = ["tests/drivers/harness.zig", "tests/drivers/mojo_env.zig"],
    exec_tools = dict(_MOJO_TOOLS, MOPM = ":mopm"),
    data = _AUTOLINK_DATA,
    **_TOOLS
)

zig_exe(  # buck-only: the `mojo_compile` wrapper of the toolchain directory `mopm unit build` runs, for a real Mojo (the real wrapper is a buildrules program)
    name = "mojo-compile-shim",
    src = "tests/drivers/mojo_compile_shim.zig",
    **_TOOLS
)

zig_test(  # buck-only: an archive in an empty-module package, from mopm pack and mopm lock to a test linked by mopm unit test, against the real Mojo
    name = "native_static",
    src = "tests/drivers/native_static_test.zig",
    imports = ["tests/drivers/harness.zig", "tests/drivers/mojo_env.zig"],
    exec_tools = dict(_MOJO_TOOLS, MOPM = ":mopm", MOPM_FAKE_REGISTRY = ":mopm-fake-registry", MOJO_COMPILE_SHIM = ":mojo-compile-shim"),
    **_TOOLS
)

zig_test(  # buck-only: a workspace member with its own C library and a package that links it, from mopm lock to an installed --overlay set, against the real Mojo (the beta tier of native_workspace)
    name = "native_workspace_mojo",
    src = "tests/drivers/native_workspace_test.zig",
    imports = ["tests/drivers/harness.zig", "tests/drivers/mojo_env.zig"],
    exec_tools = dict(_MOJO_TOOLS, MOPM = ":mopm", MOPM_FAKE_REGISTRY = ":mopm-fake-registry", FAKE_PIXI = ":fake-pixi", MOJO_COMPILE_SHIM = ":mojo-compile-shim"),
    data = ["tests/e2e/natws"],
    **_TOOLS
)

zig_test(  # buck-only: the same walk with a stand-in compiler and pixi (tests/drivers/fake_toolchain.zig, fake_pixi.zig): the graph, the C build, the link line, the packed archive, the lock and the install; it runs on every pull request
    name = "native_workspace",
    src = "tests/drivers/native_workspace_test.zig",
    imports = ["tests/drivers/harness.zig", "tests/drivers/mojo_env.zig"],
    exec_tools = {
        "CC_SHIM": ":zigcc",
        "ZIG_DIR": "buildrules//rules/pins:zig",
        "MOPM": ":mopm",
        "MOPM_FAKE_REGISTRY": ":mopm-fake-registry",
        "FAKE_PIXI": ":fake-pixi",
        "FAKE_TOOLCHAIN": ":fake-toolchain",
        "MOJO_COMPILE_SHIM": ":mojo-compile-shim",
    },
    data = ["tests/e2e/natws"],
    **_TOOLS
)

zig_test(  # buck-only: mopm build of a package's [targets] (the library as a .mojoc, the programs) and of a program that imports path dependencies, against the real Mojo (the beta tier of build_targets)
    name = "build_targets_mojo",
    src = "tests/drivers/build_targets_test.zig",
    imports = ["tests/drivers/harness.zig", "tests/drivers/mojo_env.zig"],
    exec_tools = dict(_MOJO_TOOLS, MOPM = ":mopm"),
    data = ["tests/e2e/pathdep"],
    **_TOOLS
)

zig_test(  # buck-only: the same walk with a stand-in compiler (tests/drivers/fake_toolchain.zig) that logs its command lines, so it checks what mopm asked the compiler for; it runs on every pull request
    name = "build_targets",
    src = "tests/drivers/build_targets_test.zig",
    imports = ["tests/drivers/harness.zig", "tests/drivers/mojo_env.zig"],
    exec_tools = {
        "CC_SHIM": ":zigcc",
        "ZIG_DIR": "buildrules//rules/pins:zig",
        "MOPM": ":mopm",
        "FAKE_TOOLCHAIN": ":fake-toolchain",
    },
    data = ["tests/e2e/pathdep"],
    **_TOOLS
)

zig_test(  # buck-only: mopm test --list against the real mojo; the Zig port of tests/e2e/test_discovery.sh
    name = "discovery",
    src = "tests/drivers/test_discovery_test.zig",
    imports = ["tests/drivers/harness.zig", "tests/drivers/mojo_env.zig"],
    exec_tools = dict(_MOJO_TOOLS, MOPM = ":mopm"),
    data = [
        "tests/e2e/testpkg",
        "tests/e2e/testpkg_mismatch",
    ],
    **_TOOLS
)

zig_test(  # buck-only: mopm test verdicts, JSON and JUnit, timeouts and the group kill; the Zig port of tests/e2e/test_supervisor.sh and check_supervisor.py
    name = "supervisor",
    src = "tests/drivers/test_supervisor_test.zig",
    imports = [
        "tests/drivers/harness.zig",
        "tests/drivers/mojo_env.zig",
        "tests/drivers/results.zig",
    ],
    exec_tools = dict(_MOJO_TOOLS, MOPM = ":mopm"),
    data = [
        "tests/e2e/native/greet.c",
        "tests/e2e/pkgs/greet",
        "tests/e2e/supervise",
    ],
    **_TOOLS
)

zig_test(  # buck-only: mopm test --retries, --deny-flaky, --ignored, --exact; the Zig port of tests/e2e/test_flaky.sh and check_flaky.py
    name = "flaky",
    src = "tests/drivers/test_flaky_test.zig",
    imports = [
        "tests/drivers/harness.zig",
        "tests/drivers/mojo_env.zig",
        "tests/drivers/results.zig",
    ],
    exec_tools = dict(_MOJO_TOOLS, MOPM = ":mopm"),
    data = ["tests/e2e/flaky"],
    **_TOOLS
)

# ---- The registry API's specification files, staged as `spec/` for service/api:test ----
# (Not a spec/BUCK or tests/contract/api/BUCK package: a package there would cut
# its files out of the globs of the contract checks above.)
filegroup(
    name = "spec",
    srcs = {
        "api/openapi.yaml": "spec/api/openapi.yaml",
        "package-metadata.schema.json": "spec/package-metadata.schema.json",
        "index-record.schema.json": "spec/index-record.schema.json",
        "index-config.schema.json": "spec/index-config.schema.json",
        "takedowns.schema.json": "spec/takedowns.schema.json",
    },
    visibility = ["//service/api:", "//service/infra/stacks:"],
)

# pack's map from a native dependency to its conda package: the registry's native allow-list test reads it.
filegroup(
    name = "pack_conda_zig",
    srcs = {"conda.zig": "src/core/conda.zig"},
    visibility = ["//service/api:"],
)

filegroup(
    name = "contract_api",
    srcs = {f[len("tests/contract/api/"):]: f for f in glob(["tests/contract/api/*.json"])},
    visibility = ["//service/api:", "//site:"],
)

# ---- What the Rust crates (service/lambda/*) read -----------------------------------
# Their sources `include_str!` / `include_bytes!` these at their real paths (cargo_package's `extra_srcs` makes them inputs).
# The error table of the API specification and the contract fixtures' rendered errors, and the validator corpus.
export_file(
    name = "lambda.spec.openapi.yaml",
    src = "spec/api/openapi.yaml",
    mode = "reference",
    visibility = ["//service/lambda/core:"],
)

export_file(
    name = "lambda.contract.errors.json",
    src = "tests/contract/api/errors.json",
    mode = "reference",
    visibility = ["//service/lambda/core:"],
)

# The corpus directory itself (mode reference: the source directory, not a copy), for mopm_validate.
export_file(
    name = "validator_corpus_dir",
    src = "tests/validator_corpus",
    mode = "reference",
    visibility = ["//service/lambda/validate:"],
)

filegroup(
    name = "validator_corpus_files",
    srcs = {f[len("tests/validator_corpus/"):]: f for f in glob(["tests/validator_corpus/**"])},
    visibility = ["//service/api:", "//service/lambda/validate:"],
)

# ---- What the site's tests and build read outside site/ (site/BUCK) ----------
# (Plain calls: tools/build_parity.zig reads only plain calls in this file.)
export_file(
    name = "site.README.md",
    src = "README.md",
    visibility = ["//site:"],
)

export_file(
    name = "site.RELEASING.md",
    src = "RELEASING.md",
    visibility = ["//site:"],
)

export_file(
    name = "site.VERSION",
    src = "VERSION",
    visibility = ["//site:"],
)

export_file(
    name = "site.docs.configuration.md",
    src = "docs/configuration.md",
    visibility = ["//site:"],
)

export_file(
    name = "site.docs.getting-started.md",
    src = "docs/getting-started.md",
    visibility = ["//site:"],
)

export_file(
    name = "site.docs.examples.md",
    src = "docs/examples.md",
    visibility = ["//site:"],
)

export_file(
    name = "site.docs.mopm-test.md",
    src = "docs/mopm-test.md",
    visibility = ["//site:"],
)

export_file(
    name = "site.docs.publishing-a-workspace.md",
    src = "docs/publishing-a-workspace.md",
    visibility = ["//site:"],
)

# What the group docs state is read from these (site/test/docs-group.test.ts): the runbook, the changelog, the staged-set spec and
# the three commands' sources.
export_file(
    name = "site.service.docs.runbook.md",
    src = "service/docs/runbook.md",
    visibility = ["//site:"],
)

export_file(
    name = "site.CHANGELOG.md",
    src = "CHANGELOG.md",
    visibility = ["//site:"],
)

export_file(
    name = "site.spec.staged-set.md",
    src = "spec/staged-set.md",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.cli.stage_cmd.zig",
    src = "src/cli/stage_cmd.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.cli.group_publish.zig",
    src = "src/cli/group_publish.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.cli.yank_cmd.zig",
    src = "src/cli/yank_cmd.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.docs.why-and-design.md",
    src = "docs/why-and-design.md",
    visibility = ["//site:"],
)

export_file(
    name = "site.spec.channel.md",
    src = "spec/channel.md",
    visibility = ["//site:"],
)

export_file(
    name = "site.spec.mopm-toml.md",
    src = "spec/mopm-toml.md",
    visibility = ["//site:"],
)

export_file(
    name = "site.spec.package-metadata.schema.json",
    src = "spec/package-metadata.schema.json",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.core.credentials.zig",
    src = "src/core/credentials.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.core.lock.zig",
    src = "src/core/lock.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.core.conda.zig",
    src = "src/core/conda.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.core.manifest.zig",
    src = "src/core/manifest.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.cli.main.zig",
    src = "src/cli/main.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.cli.install_cmd.zig",
    src = "src/cli/install_cmd.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.cli.publish_cmd.zig",
    src = "src/cli/publish_cmd.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.cli.test_cmd.zig",
    src = "src/cli/test_cmd.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.core.closure.zig",
    src = "src/core/closure.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.core.conda_unpack.zig",
    src = "src/core/conda_unpack.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.core.env.zig",
    src = "src/core/env.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.core.metadata.zig",
    src = "src/core/metadata.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.core.registry.zig",
    src = "src/core/registry.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.core.toml.zig",
    src = "src/core/toml.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.src.core.unit_graph.zig",
    src = "src/core/unit_graph.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.tools.cut_release.zig",
    src = "tools/cut_release.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.tools.release.zig",
    src = "tools/release.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.tests.drivers.examples_test.zig",
    src = "tests/drivers/examples_test.zig",
    visibility = ["//site:"],
)

export_file(
    name = "site.workflows.promote.yml",
    src = ".github/workflows/promote.yml",
    visibility = ["//site:"],
)

export_file(
    name = "site.workflows.e2e.yml",
    src = ".github/workflows/e2e.yml",
    visibility = ["//site:"],
)

export_file(
    name = "site.workflows.service-ci.yml",
    src = ".github/workflows/service-ci.yml",
    visibility = ["//site:"],
)

# The worked examples, staged as `examples`: the site's test holds docs/examples.md to every file of them.
filegroup(
    name = "site_examples",
    srcs = {f[len("examples/"):]: f for f in glob(["examples/**"])},
    visibility = ["//site:"],
)

# The scaffold golden of `mopm new --lib`, staged as `tests/new/lib`.
filegroup(
    name = "site_new_lib",
    srcs = {f[len("tests/new/lib/"):]: f for f in glob(["tests/new/lib/**"])},
    visibility = ["//site:"],
)

# ---- The repository's own lints (hygiene, workflows, lint_selftest) ------------------------

# Every tracked file hygiene scans (tests/drivers/hygiene.zig), staged by path under
# BUILDRULES_TEST_WORK: the root package's files (a glob skips dotfiles, so those are named)
# and each sub-package's `lint_files` (a package boundary hides its files from this glob).
# Not scanned: platforms/BUCK and toolchains/BUCK, byte copies of komira's files that
# cannot carry a `lint_files` target of their own (toolchains is another cell) without
# ceasing to be copies; komira's own hygiene scan reads the originals.
_LINT_DOTFILES = [
    ".buckconfig",
    ".gitignore",
    "tests/discovery/tree/tests/.hidden/test_hidden.mojo",
    "tests/new/bin/.gitignore",
    "tests/new/lib/.gitignore",
]

_LINT_PACKAGES = [
    "service/api",
    "service/config",
    "service/infra/access",
    "service/infra/dns",
    "service/infra/stacks",
    "service/lambda/aws",
    "service/lambda/core",
    "service/lambda/validate",
    "service/lambda/ports",
    "service/lambda/testing",
    "site",
    "tools/lambda",
    "tools/node",
]

_ROOT_FILES = glob(["**", ".github/**"]) + _LINT_DOTFILES

# (One line each: tools/build_parity.zig reads BUCK line by line and refuses a line that starts a loop.)
_REPO_FILES = {f: f for f in _ROOT_FILES} | {pkg: "//{}:lint_files".format(pkg) for pkg in _LINT_PACKAGES}

# The files the Zig lints read, by source: the three test roots share these.
_LINT_LIBS = [
    "tests/drivers/lint_common.zig",
    "tests/drivers/yaml.zig",
]

zig_test(  # buck-only: the hygiene scan, over every file of the repository
    name = "hygiene",
    src = "tests/drivers/hygiene_test.zig",
    imports = _LINT_LIBS + ["tests/drivers/hygiene.zig"],
    data = _REPO_FILES,
    **_TOOLS
)

zig_test(  # buck-only: `kpin check` (buildrules' kpin) over every pins.lock.bzl, with a stale lock shown refused
    name = "kpin_check",
    src = "tests/drivers/kpin_check_test.zig",
    imports = ["tests/drivers/harness.zig"],
    data = _REPO_FILES,
    exec_tools = {"KPIN": "buildrules//rules/kpin:kpin"},
    **_TOOLS
)

zig_test(  # buck-only: the workflow lint, over the workflows, with a stand-in for `bash -n`
    name = "workflows",
    src = "tests/drivers/workflow_lint_test.zig",
    imports = _LINT_LIBS + [
        "tests/drivers/shell_syntax.zig",
        "tests/drivers/release_lint.zig",
        "tests/drivers/workflow_lint.zig",
    ],
    data = dict({f: f for f in glob([".github/workflows/*.yml", ".github/workflows/*.yaml"])}, **{"tools/install_osv_scanner.zig": "tools/install_osv_scanner.zig"}),  # the installer: the pinned version, the sha256 and the refusal
    **_TOOLS
)

zig_test(  # buck-only: release.yml's scopes, stage order and path filter (tests/drivers/release_lint.zig), with a faulty variant per rule
    name = "release_workflow",
    src = "tests/drivers/release_lint_test.zig",
    imports = _LINT_LIBS + ["tests/drivers/release_lint.zig"],
    data = dict({f: f for f in glob([".github/workflows/*.yml", ".github/workflows/*.yaml"])}, **{"tools/cut_release.zig": "tools/cut_release.zig", "tools/apt_publish.zig": "tools/apt_publish.zig"}),  # the tools: gh release create must carry --verify-tag; the apt puts carry the conditions the role requires
    **_TOOLS
)

zig_test(  # buck-only: the Dependabot autopin workflows (tests/drivers/autopin_lint.zig): their gates, tokens and step order, R1-R4, M2/M2b, with a faulty variant per rule
    name = "autopin_workflows",
    src = "tests/drivers/autopin_lint_test.zig",
    imports = _LINT_LIBS + ["tests/drivers/autopin_lint.zig"],
    data = {f: f for f in glob([".github/workflows/**", ".github/actions/**"])},  # every file there, not only the .yml: the lint refuses the others
    **_TOOLS
)

zig_test(  # buck-only: both lints over the fixtures, against the table in the test
    name = "lint_selftest",
    src = "tests/drivers/lint_selftest_test.zig",
    imports = _LINT_LIBS + [
        "tests/drivers/hygiene.zig",
        "tests/drivers/shell_syntax.zig",
        "tests/drivers/release_lint.zig",
        "tests/drivers/workflow_lint.zig",
    ],
    data = {f: f for f in glob(["tests/lint/fixtures/*"])},
    **_TOOLS
)

# ---- Ports of the install e2e test and the fake registry's error generator ------------

zig_exe(  # buck-only: stands in for pixi in install_e2e: unpacks the pinned conda files into the environment
    name = "fake-pixi",
    src = "tests/drivers/fake_pixi.zig",
    **_TOOLS
)

zig_exe(  # buck-only: stands in for the Mojo compiler in the unit tier of group_e2e: writes stand-in .mojoc files and executables
    name = "fake-toolchain",
    src = "tests/drivers/fake_toolchain.zig",
    **_TOOLS
)

zig_test(  # buck-only: mopm sync against the fake registry and the real Mojo; the Zig port of tests/install_e2e/run.py
    name = "install_e2e",
    src = "tests/drivers/install_e2e_test.zig",
    imports = ["tests/drivers/harness.zig", "tests/drivers/mojo_env.zig"],
    exec_tools = dict(_MOJO_TOOLS, MOPM = ":mopm", MOPM_FAKE_REGISTRY = ":mopm-fake-registry", FAKE_PIXI = ":fake-pixi"),
    data = [
        "tests/e2e/native/greet.c",
        "tests/e2e/pkgs/greet",
        "tests/install_e2e/prog.mojo",
    ],
    **_TOOLS
)

zig_exe(  # buck-only: regenerates registry/fake/errors.zig from spec/api/openapi.yaml (the Zig port of gen_errors.py)
    name = "gen_errors",
    src = "tests/drivers/gen_errors.zig",
    imports = ["tests/drivers/errors_gen.zig", "tests/drivers/yaml.zig"],
    **_TOOLS
)

zig_test(  # buck-only: registry/fake/errors.zig is what gen_errors makes of the spec, and the generator's refusals
    name = "gen_errors_current",
    src = "tests/drivers/gen_errors_test.zig",
    imports = ["tests/drivers/errors_gen.zig", "tests/drivers/harness.zig", "tests/drivers/yaml.zig"],
    data = ["spec/api/openapi.yaml", "registry/fake/errors.zig"],
    **_TOOLS
)

# ---- actionlint: a strict parse and check of every workflow ---------------------------------

# The Zig lints above read workflows with a small YAML reader that is lenient: an unquoted `name: ... (contents write: the tag)`
# parsed as a name, reached a push, and GitHub refused the workflow (startup_failure). actionlint is a real YAML parser plus the
# workflow schema, expressions and contexts. This is buildrules' own rule over its pinned actionlint (1.7.12), a build action
# with no network and no host tool; lint.yml runs the same binary, installed by tools/install_actionlint.zig.
actionlint_check(  # buck-only: the pinned actionlint over every workflow file
    name = "actionlint",
    exec_compatible_with = LINUX_X86_64,
    actionlint = "buildrules//rules/pins:actionlint_linux_amd64.tar.gz",
    workflows = glob([".github/workflows/*.yml", ".github/workflows/*.yaml"]),
)

zig_exe(  # buck-only: installs the pinned actionlint for lint.yml (sha256-checked download)
    name = "install-actionlint",
    src = "tools/install_actionlint.zig",
    **_TOOLS
)

zig_exe(  # buck-only: installs the pinned OSV-Scanner for advisories.yml (sha256-checked download); built so the farm compiles it
    name = "install-osv-scanner",
    src = "tools/install_osv_scanner.zig",
    **_TOOLS
)

# ---- Coverage: the lines the unit tests reach, held to a floor per package ------------------------------------------------
# (vendor/buildrules_coverage/README.md says what each figure is, what it leaves out, and how a floor is written.)

# The tools of a coverage run (zig_cover, cov_floor, cov_summary, the launcher), built here until the buildrules pin has them.
cov_tools()

# Each package: the unit tests of its sources run again under kcov (the same compile and environment), and `<package>_coverage_floor`
# holds the lines they reach to coverage/<package>.txt, as a minimum: a fall below the floor fails, a figure above it passes and a hint says the floor may be raised.
# The packages are built by zig 0.12, which has no block counters (-ffuzz), so the report is lines only (`blocks = False`).
# `expect` is the package's own sources; a file in it that no listed test compiled fails the summary. Process tests (a test that runs a built
# program, `env_tools`) measure the program's behaviour, not its sources, and are not listed.
zig_coverage(
    name = "core_coverage",
    blocks = False,
    floor = "coverage/core.txt",
    test_targets = [":core_test"],
    expect = glob(["src/core/*.zig"]),
)

zig_coverage(
    name = "cli_coverage",
    blocks = False,
    floor = "coverage/cli.txt",
    test_targets = [":cli_test"],
    # build_options.zig is a module of constants (a declaration has no line); test_cmd.zig is compiled only into the mopm program, not into the unit test binary.
    expect = glob(["src/cli/*.zig"], exclude = ["src/cli/build_options.zig", "src/cli/test_cmd.zig"]),
)

zig_coverage(
    name = "fake_registry_coverage",
    blocks = False,
    floor = "coverage/fake_registry.txt",
    test_targets = [":fake_test"],
    # control.zig is imported by main.zig, but only the code of main() calls it; the unit test binary has no line of it.
    expect = glob(["registry/fake/*.zig"], exclude = ["registry/fake/control.zig"]),
)

zig_coverage(
    name = "channels_coverage",
    blocks = False,
    floor = "coverage/channels.txt",
    test_targets = [":channels_test"],
    expect = glob(["tools/channels/*.zig"], exclude = ["tools/channels/main.zig"]),
)

zig_coverage(
    name = "apt_publish_coverage",
    blocks = False,
    floor = "coverage/apt_publish.txt",
    test_targets = [":apt_publish_test"],
    # tools/apt_publish.zig, the command line, runs processes and is measured by :apt_publish (a process test), not here.
    expect = glob(["tools/apt_publish/*.zig"]),
)

zig_coverage(
    name = "build_parity_coverage",
    blocks = False,
    floor = "coverage/build_parity.txt",
    test_targets = [":build_parity"],
    expect = ["tools/build_parity.zig"],
)

zig_coverage(
    name = "group_e2e_coverage",
    blocks = False,
    floor = "coverage/group_e2e.txt",
    test_targets = [":group_e2e"],
    # The check the group-e2e job runs, driven here against a loopback registry that serves the group routes (the test file's own
    # lines are not counted: they are the registry).
    expect = ["tests/drivers/group_e2e.zig"],
)

zig_coverage(
    name = "drivers_coverage",
    blocks = False,
    floor = "coverage/drivers.txt",
    test_targets = [":contract", ":lock_golden", ":validator_corpus", ":hygiene", ":workflows", ":release_workflow", ":autopin_workflows", ":lint_selftest", ":gen_errors_current"],
    expect = [
        "tests/drivers/autopin_lint.zig",
        "tests/drivers/contract.zig",
        "tests/drivers/errors_gen.zig",
        "tests/drivers/hygiene.zig",
        "tests/drivers/jsonschema.zig",
        "tests/drivers/lint_common.zig",
        "tests/drivers/openapi_check.zig",
        "tests/drivers/regex.zig",
        "tests/drivers/release_lint.zig",
        "tests/drivers/shell_syntax.zig",
        "tests/drivers/validator_corpus.zig",
        "tests/drivers/workflow_lint.zig",
        "tests/drivers/yaml.zig",
    ],
)

# Every package's floor, in one target: `./buck2 build //:coverage_floors`.
filegroup(
    name = "coverage_floors",
    srcs = {
        "apt_publish": ":apt_publish_coverage_floor",
        "build_parity": ":build_parity_coverage_floor",
        "channels": ":channels_coverage_floor",
        "cli": ":cli_coverage_floor",
        "core": ":core_coverage_floor",
        "drivers": ":drivers_coverage_floor",
        "fake_registry": ":fake_registry_coverage_floor",
        "group_e2e": ":group_e2e_coverage_floor",
        "service_api": "//service/api:coverage_floor",
        "service_infra_access": "//service/infra/access:coverage_floor",
        "service_infra_dns": "//service/infra/dns:coverage_floor",
        "service_infra_stacks": "//service/infra/stacks:coverage_floor",
        "site": "//site:coverage_floor",
    },
)
