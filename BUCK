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

load("@buildrules//rules/zig:zig.bzl", "zig_exe", "zig_module", "zig_test")
load("@buildrules//rules/core:platform.bzl", "LINUX_X86_64")
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
_CLI_SRCS = glob(["src/cli/*.zig"], exclude = ["src/cli/main.zig"])
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

zig_test(  # buck-only: tests/resolve/check_golden.py: the goldens pass the lock contract, a faulty writer's output does not
    name = "lock_golden",
    src = "tests/drivers/lock_golden_test.zig",
    imports = _CONTRACT_LIBS + [
        "spec/lock.schema.json",
    ] + glob(["tests/resolve/golden/**"]),
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
        "tools/closure_gen.zig",
        "registry/fake/main.zig",
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

zig_test(  # buck-only: mopm build, run, repl with native libraries; the Zig port of tests/e2e/run.sh
    name = "autolink",
    src = "tests/drivers/test_autolink_test.zig",
    imports = ["tests/drivers/harness.zig", "tests/drivers/mojo_env.zig"],
    exec_tools = dict(_MOJO_TOOLS, MOPM = ":mopm"),
    data = _AUTOLINK_DATA,
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
    },
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
    name = "site.docs.mopm-test.md",
    src = "docs/mopm-test.md",
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
    name = "site.src.cli.main.zig",
    src = "src/cli/main.zig",
    visibility = ["//site:"],
)

# The scaffold golden of `mopm new --lib`, staged as `tests/new/lib`.
filegroup(
    name = "site_new_lib",
    srcs = {f[len("tests/new/lib/"):]: f for f in glob(["tests/new/lib/**"])},
    visibility = ["//site:"],
)

# ---- The repository's own lints, ported from Ruby (.github/scripts, tests/lint) ------------

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

zig_test(  # buck-only: .github/scripts/hygiene.rb in Zig, over every file of the repository
    name = "hygiene",
    src = "tests/drivers/hygiene_test.zig",
    imports = _LINT_LIBS + ["tests/drivers/hygiene.zig"],
    data = _REPO_FILES,
    **_TOOLS
)

zig_test(  # buck-only: .github/scripts/workflow_lint.rb in Zig, over the workflows, and the stand-in for its `bash -n`
    name = "workflows",
    src = "tests/drivers/workflow_lint_test.zig",
    imports = _LINT_LIBS + [
        "tests/drivers/shell_syntax.zig",
        "tests/drivers/workflow_lint.zig",
    ],
    data = {f: f for f in glob([".github/workflows/*.yml", ".github/workflows/*.yaml"])},
    **_TOOLS
)

zig_test(  # buck-only: tests/lint/run.rb in Zig: both Zig lints over the fixtures, against run.rb's own table
    name = "lint_selftest",
    src = "tests/drivers/lint_selftest_test.zig",
    imports = _LINT_LIBS + [
        "tests/drivers/hygiene.zig",
        "tests/drivers/shell_syntax.zig",
        "tests/drivers/workflow_lint.zig",
    ],
    data = {f: f for f in glob(["tests/lint/fixtures/*", "tests/lint/run.rb"])},
    **_TOOLS
)

# ---- Ports of the install e2e test and the fake registry's error generator ------------

zig_exe(  # buck-only: stands in for pixi in install_e2e: unpacks the pinned conda files into the environment
    name = "fake-pixi",
    src = "tests/drivers/fake_pixi.zig",
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
