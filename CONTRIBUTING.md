# Contributing

- Tooling is written in Zig 0.12.0. Run `zig build test` from the repository
  root before opening a pull request; CI runs it on Linux (x86_64, aarch64) and
  macOS (arm64).
- A bug fix comes with a test that failed before the fix.
- A behaviour change updates the golden files in `tests/golden` in the same
  pull request, and says why.
- Keep files small and the public surface smaller. Document only what the code
  does.
- Open an issue before a large change.
- By contributing you agree your work is licensed under Apache-2.0.

## Building with Buck2, and with `zig build`

Two builds describe the same program, and both stay.

- **`zig build`** is the quick path on your machine: `zig build test` runs the
  unit tests, `zig build` makes `zig-out/bin/mopm`, and
  `tests/run_golden.sh ./zig-out/bin/mopm` runs the golden files. `ci.yml`
  runs exactly these.
- **Buck2** (`./buck2`, a pinned release; the build rules come from the
  `komira` repository, fetched at the commit `.buckconfig` names) is what the
  build farm runs: `./buck2 build //...`. The build has no shell and no Python:
  every test is a Zig test. The unit tests are welded into the executables
  (`//:mopm` is not built unless `//:core_test` and `//:cli_test` passed).
  The Zig drivers in `tests/drivers` run the built programs: `//:golden` (the
  checks of `tests/run_golden.sh`), `//:registry_login` and
  `//:registry_publish` (the checks of `tests/registry_e2e/*.py`).
  `tests/run_golden.sh` and the two Python scripts stay for `ci.yml` until
  `farm.yml` has matched it, and are deleted then.
  The Mojo end-to-end suites run on the farm with no pixi, shell or Python:
  `//:autolink` (`tests/e2e/run.sh`), `//:discovery` (`test_discovery.sh`),
  `//:supervisor` (`test_supervisor.sh`, `check_supervisor.py`) and `//:flaky`
  (`test_flaky.sh`, `check_flaky.py`). They use the Mojo 1.0.0 compiler komira
  pins (`komira//tools/build/toolchains:mojo_compiler`, handed over as a
  directory), komira's zig as the C compiler (`zig cc`, through
  `tests/drivers/zigcc.zig`: `mojo build` links through `cc` on `PATH`), and
  the built `mopm`; `//:mojo_probe` shows the toolchain works from this cell.
  The pinned compiler closure has no lldb, so `mojo repl` cannot run there and
  the REPL checks print `SKIP` (they run if the toolchain gains
  `bin/mojo-lldb`); `ci.yml` still runs them against the pixi environment. Without a farm configured
  (`.buckconfig.local`, gitignored) the actions run on your machine.

A source file you add under `src/core`, `src/cli` or `registry/fake` is picked
up by both (Buck2 takes each directory by glob; it skips dotfiles, so a new
dotfile under `tests/` is named in `BUCK`). A new root source file, executable,
module or `addTest` in `build.zig` needs the matching `zig_exe`, `zig_module`
or `zig_test` in `BUCK`: `//:build_parity` (`zig test tools/build_parity.zig`
from the root) fails when they differ. A call in `BUCK` with no `build.zig`
counterpart (a helper, a driver) says `buck-only` on its first line.

The unit tests read `tests/...` relative to the working directory, the
repository root under `zig build test` and in the Buck2 action; a runner that
starts them elsewhere sets `MOPM_SOURCE_ROOT` (`src/core/testroot.zig`). The
supervisor tests (`src/core/test_proc.zig`) run `/bin/sh -c` scripts, or, when
`MOPM_TEST_CHILD` names `tests/drivers/proc_child.zig`, the same behaviour from
that program.
