# The Mojo toolchain closure

`mopm sync` has no solver. The Mojo toolchain it installs (`mojo`, `mojo-compiler`
and everything they need) is a fixed list per Mojo version and platform:

| file | what it is | made by |
|---|---|---|
| `versions.txt` | the Mojo versions mopm can install | a person |
| `mojo-<version>.pixi.lock` | the solver's answer for that version, all platforms | the `toolchain` job of `.github/workflows/kpin-update.yml` (pixi, on GitHub) |
| `../src/core/toolchain/mojo-<version>-<subdir>.json` | the closure of one platform: url, sha256, size and conda-meta fields of every package | `mopm-closure`, from the lock |
| `../src/core/toolchain/zig-for-mojo-<version>.json` | the Zig that links for that Mojo version (url, sha256, size, target triple), per platform | a person |

`mopm plan --unit-graph` hashes the closure file and the Zig pin into the toolchain's
`closure_sha256` (spec/unit-graph.md).

The unit test `closure.zig` ("the committed closure files are the ones made from the
committed locks") fails when a lock and its closure files disagree, so a hash is never
edited by hand. To regenerate after changing a lock:

    zig build run-closure -- toolchain/mojo-<version>.pixi.lock src/core/toolchain

pixi is a solver here and nowhere else: it never runs on a user's machine, and no user
installs it. A package is downloaded from its channel's `url` plus its `path`; a mirror
of the same bytes is one `url` change per channel in each closure file (the sha256 of
every file is unchanged).

The solver is given `python = 3.12.*` as well as `mojo`: the Mojo packages need any
python >= 3.10, and the one the end-to-end tests use is pinned the same way.
