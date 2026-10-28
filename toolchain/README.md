# The Mojo toolchain closure

`mopm sync` has no solver. The Mojo toolchain it installs (`mojo`, `mojo-compiler`
and everything they need) is a fixed list per Mojo version and platform:

| file | what it is | made by |
|---|---|---|
| `versions.txt` | the Mojo versions mopm can install | a person |
| `mojo-<version>.pixi.lock` | the solver's answer for that version, all platforms | the `toolchain` job of `.github/workflows/kpin-update.yml` (pixi, on GitHub) |
| `../src/core/toolchain/mojo-<version>-<subdir>.json` | the closure of one platform: url, sha256, size and conda-meta fields of every package | `mopm-closure`, from the lock |
| `natives.txt` | the conda names of the native libraries a package may load (the allow-list), one per line | a person |
| `natives.libs` | the shared libraries each catalog package holds, read from the package files (below) | a person |
| `natives.pixi.lock` | the solver's answer for all of `natives.txt` at once, all platforms; independent of the Mojo version | the same job |
| `../src/core/toolchain/natives-<subdir>.json` | the catalog of one platform: every allow-listed native and what it needs to run, minus what the toolchain already supplies (libgcc, libstdcxx, libcxx); url, sha256 and size of each | `mopm-closure --natives`, from the lock |
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

The native catalog (src/core/native_catalog.zig) is made and checked the same way. To regenerate after
changing `natives.txt` or its lock:

    zig build run-closure -- --natives toolchain/natives.pixi.lock toolchain/natives.txt src/core/toolchain

It fails, and the weekly job with it, when a native needs a package the lock lacks (the catalog is
closed), or when a native asks for a newer `libgcc` or `libstdcxx` than the Mojo closures stage. The
unit test "the committed catalog files are the ones made from the committed lock" fails when the lock,
`natives.txt`, the Mojo closures and the catalog files disagree. A pin moves only with a mopm release,
so a test runs against the version the catalog pins while `mopm sync` may install a newer one inside the
same range.

Each package of the catalog must hold a runtime shared library, and every `lib/` link of it must end at a
file of the same package: conda-forge's `xz` is a metapackage and its `liblzma-devel` links to a library only
`liblzma` holds, so the root is `liblzma`. `natives.libs` records those files, read from the package files
(`unzip -p <file>.conda 'pkg-*' | zstd -dc | tar -tv`), with the sha256 of the package file each line was read
from; the unit test "every package of the native catalog holds a shared library ..." fails for a catalog package
with no regular shared library, a link that leaves its package, a line for a package the catalog does not pin, and a
pin that moved without its lines being read again. Update it with the lock.

The weekly `toolchain` job re-solves the lock and rewrites `natives-*.json`, but does not read the package files, so
it leaves `natives.libs` as it was. A weekly pull request that pins a new build of a native fails that test
(`CatalogPackageUnusable`) until `natives.libs` is regenerated: for each new package list its `lib/*.so*` and
`lib/*.dylib` entries with the command above, replace the lines of that package (with its new sha256) and drop the lines
of packages the catalog no longer pins. The job's pull request body says the same.
