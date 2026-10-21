# vendor/buildrules_coverage: Zig and jest coverage, copied until the buildrules pin has it

mopm's Buck2 rules come from buildrules, pinned in `.buckconfig` (`[external_cell_buildrules]`). The coverage rules were written in buildrules
pull request #19 (branch `coverage/floors`), which the pin does not contain. The files here are copied from commit
`3277431a50603ec0792531d2683dd64fbdcae40b` of that branch, each with a header naming its source file. It is a stopgap: when the pin moves past that pull request,
delete this directory, load `zig_test`, `zig_coverage`, `jest_test(coverage = True)` and `jest_coverage_floor` from `@buildrules//...` in `BUCK` and
the five `site/` and `service/` BUCK files, and the targets `cov_tools()` defines (`//:cov_*`) go with it.

| file | what | changed from the source |
|---|---|---|
| `tools/*.zig`, `zig_launch*.zig` | `zig_cover` (builds a test with the coverage options and runs it under kcov), `cov_floor` (the floor check), `cov_summary`, `cov_run`, the block runner, and the launcher's `run` subcommand, with their unit tests | no (a two line header) |
| `tools.bzl` | the BUCK targets of those tools, behind their tests | the targets of the pull request's `rules/coverage/BUCK`, as a macro of the root package |
| `zig_test.bzl` | the pinned `zig_test` rule plus the `ZigTestInfo` provider the coverage rule reads | the rule is the pinned one, same command line |
| `zig_cover.bzl` | `zig_coverage(...)`: the package's coverage and its floor check | tool targets are `//:cov_*`; the floor's label is the target's name |
| `jest_cover.bzl` | `jest_test` (jest with `--coverage`) and `jest_coverage_floor` | `jest_test` is written over buildrules' public `node_tree_build` |

## What a figure is

**Zig, lines.** The unit tests of a package (`zig_test` targets that run no built program) are built again with kcov's line tables and run under kcov, in one action
each; `//:<package>_coverage` is the lines hit and recorded per file, and the total over the package's own sources (`expect`). `//:<package>_coverage_floor`
holds the total to `coverage/<package>.txt` (`lines NN.NN`, hit over recorded rounded down to a hundredth): a figure below the floor fails, and so does one above it,
naming the number to write, so a floor is always what the tests reach and only rises.

What the figure leaves out: code the compiler emitted nothing for (zig analyses what is referenced, so a function no unit test reaches has no line and
no row: the percentage is an upper bound); code of a built program that a process test runs (`env_tools`, `exec_tools`: the process is not instrumented);
the files `BUCK` leaves out of `expect`, with the reason beside each.

**Zig, branches: none.** A branch figure needs LLVM's block counters (`zig test -ffuzz`), which zig 0.15 has and the zig 0.12 mopm is written for does not. The
coverage tools here are built by 0.15 and carry the block code (the process tests of `//:cov_zig_cover` run it), but a mopm package's tests are built by 0.12, so
`zig_coverage(blocks = False)` and a floor file has no `branches` line. The packages build with 0.15 only after the code is ported.

**Jest.** `jest --coverage` over `collectCoverageFrom` of the package's `jest.config.js` (its own source, not its tests); the target `:coverage_run` (a second run beside npm_package's `:test`, which writes no coverage) is the `coverage`
directory of the run, and `:coverage_floor` holds istanbul's `total` lines and branches to the package's `coverage_floor.txt`, with the same both-ways check.

## Raising a floor

Build the package's floor target; when the tests reach more than the floor, it fails and names the number: write it in the floor file in the same change as the tests.
`./buck2 build //:coverage_floors` builds them all; the pull-request build (`farm.yml`, every target but the end-to-end ones) includes it.
