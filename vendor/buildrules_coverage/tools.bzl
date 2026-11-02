"""The tools of a Zig coverage run, built here until the buildrules pin has them (README.md in this directory).

Vendored from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b: the targets of
rules/coverage/BUCK that pull request adds (zig_cover, cov_floor, and the changed cov_run and cov_summary), and the `run` launcher of rules/zig.
The cov tools are built by the pinned zig 0.15 (`zig_next`), as buildrules builds them; the packages they measure are built by the zig 0.12 mopm uses.
Each is behind its unit tests, and `cov_zig_cover` behind its process tests. linux x86_64 only.
"""

load("@buildrules//rules/core:platform.bzl", "LINUX_X86_64")
load("@buildrules//rules/coverage:defs.bzl", "cov_tool")
load("@buildrules//rules/zig:zig.bzl", "zig_bootstrap_exe", "zig_exe", "zig_test")

_ZIG = "buildrules//rules/pins:zig_next"
_ZIG_VERSION = "buildrules//rules/pins:zig_next_version"
_BB = "buildrules//rules/pins:busybox"
_D = "vendor/buildrules_coverage/"

def cov_tools():
    # zig_launch with the `run` subcommand (the pinned buildrules one has `test` only): runs a program of the action under the environment of a zig_test.
    zig_bootstrap_exe(
        name = "cov_launch",
        exec_compatible_with = LINUX_X86_64,
        src = _D + "zig_launch.zig",
        test_src = _D + "zig_launch_test.zig",
        zig = "buildrules//rules/pins:zig",
        visibility = ["PUBLIC"],
    )

    zig_test(
        name = "cov_run_unit",
        exec_compatible_with = LINUX_X86_64,
        imports = [_D + "tools/cov_run.zig"],
        src = _D + "tools/cov_run_test.zig",
        busybox = _BB,
        zig = _ZIG,
    )
    zig_test(
        name = "cov_summary_unit",
        exec_compatible_with = LINUX_X86_64,
        imports = [_D + "tools/cov_summary.zig"],
        src = _D + "tools/cov_summary_test.zig",
        busybox = _BB,
        zig = _ZIG,
    )
    zig_exe(
        name = "cov_summary",
        exec_compatible_with = LINUX_X86_64,
        src = _D + "tools/cov_summary.zig",
        unit_tests = [":cov_summary_unit", _ZIG_VERSION],
        busybox = _BB,
        zig = _ZIG,
        visibility = ["PUBLIC"],
    )

    # The test runner of a coverage build, compiled with each test it measures (blocks; unused for the zig 0.12 tests of mopm, which have none).
    native.export_file(
        name = "cov_zig_cov_runner.zig",
        src = _D + "tools/zig_cov_runner.zig",
        visibility = ["PUBLIC"],
    )
    zig_test(
        name = "cov_zig_cover_unit",
        exec_compatible_with = LINUX_X86_64,
        imports = [
            _D + "tools/zig_cover.zig",
            _D + "tools/cov_run.zig",
        ],
        src = _D + "tools/zig_cover_test.zig",
        busybox = _BB,
        zig = _ZIG,
    )
    zig_exe(
        name = "cov_zig_cover_exe",
        exec_compatible_with = LINUX_X86_64,
        imports = [_D + "tools/cov_run.zig"],
        src = _D + "tools/zig_cover.zig",
        unit_tests = [":cov_zig_cover_unit", ":cov_run_unit", _ZIG_VERSION],
        busybox = _BB,
        zig = _ZIG,
    )
    # The executable as a process over small packages of known coverage, with the pinned zig, kcov and cov_normalize. A validation of :cov_zig_cover.
    zig_test(
        name = "cov_zig_cover_exe_test",
        exec_compatible_with = LINUX_X86_64,
        env_tools = {
            "KCOV": "buildrules//rules/coverage:kcov",
            "NORMALIZE": "buildrules//rules/coverage:cov_normalize",
            "PINNED_ZIG": _ZIG,
            "PINNED_ZIG_012": "buildrules//rules/pins:zig",
            "ZIG_COVER": ":cov_zig_cover_exe",
        },
        imports = [
            _D + "tools/fixtures/zig_cover/fail_test.zig",
            _D + "tools/fixtures/zig_cover/leak_test.zig",
            _D + "tools/fixtures/zig_cover/log_test.zig",
            _D + "tools/fixtures/zig_cover/mini.zig",
            _D + "tools/fixtures/zig_cover/mini_test.zig",
            _D + "tools/zig_cov_runner.zig",
        ],
        src = _D + "tools/zig_cover_exe_test.zig",
        busybox = _BB,
        zig = _ZIG,
    )
    cov_tool(
        name = "cov_zig_cover",
        cases = [":cov_zig_cover_exe_test"],
        exec_compatible_with = LINUX_X86_64,
        exe = ":cov_zig_cover_exe",
        visibility = ["PUBLIC"],
    )

    zig_test(
        name = "cov_floor_unit",
        exec_compatible_with = LINUX_X86_64,
        imports = [_D + "tools/cov_floor.zig"],
        src = _D + "tools/cov_floor_test.zig",
        busybox = _BB,
        zig = _ZIG,
    )
    zig_exe(
        name = "cov_floor",
        exec_compatible_with = LINUX_X86_64,
        src = _D + "tools/cov_floor.zig",
        unit_tests = [":cov_floor_unit", _ZIG_VERSION],
        busybox = _BB,
        zig = _ZIG,
        visibility = ["PUBLIC"],
    )
