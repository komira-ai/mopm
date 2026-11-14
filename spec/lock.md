# mopm.lock

`mopm.lock` records the exact packages a project resolved to, so that the same
bytes are installed on every machine and in CI. It is JSON, written by mopm,
committed, and never edited by hand. The schema is `lock.schema.json`.

The lock states only what mopm needs to fetch and verify: where each file
comes from, which bytes it must be, and which Mojo version it was built
with. It does not duplicate package metadata; that stays in the installed
`<import name>.mopm.json`.

Every package in the lock is named by its full name, `<namespace>/<name>`
(`komira-ai/json`; `mopm-toml.md`, "Names"). The part after the `/` is the
import name. A package's conda name is `mojo-<namespace>.<name>`.

One lock covers every Mojo version the project lists: a `.mojoc` is tied to
one compiler, so each registry package carries one build per Mojo version. A
project with `[toolchain] mojo` has a one-element `mojo`.

```json
{
  "lock_version": 3,
  "mojo": ["1.0.0", "1.1.0"],
  "toolchain": { "1.0.0": { "linux-64": "<64 hex digits>" }, "1.1.0": { "linux-64": "<64 hex digits>" } },
  "channels": ["https://conda.mopm.dev/"],
  "packages": [
    {
      "name": "komira-ai/http_client",
      "version": "0.4.0",
      "subdir": "linux-64",
      "channel": "https://conda.mopm.dev/komira-ai/",
      "artifacts": {
        "1.0.0": {
          "build": "mojo1.0.0_0",
          "url": "https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.http_client-0.4.0-mojo1.0.0_0.conda",
          "sha256": "<64 hex digits>",
          "size": 123456
        },
        "1.1.0": {
          "build": "mojo1.1.0_0",
          "url": "https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.http_client-0.4.0-mojo1.1.0_0.conda",
          "sha256": "<64 hex digits>",
          "size": 123500
        }
      },
      "deps": ["komira-ai/http_core"],
      "native": [{ "id": "crypto", "soname": "libcrypto_native.so.1", "sha256": "<64 hex digits>" }]
    }
  ]
}
```

## Fields

- `lock_version`: 3, the only version mopm writes. A lock of version 1 or 2
  predates namespaces: mopm reads it only far enough to report it stale (see
  "Stale locks"). A value above 3 is refused with "update mopm".
- `mojo`: the Mojo versions locked, sorted as byte strings, with no repeats. It
  equals the set `mopm.toml` lists (`[package] mojo`, or the one `[toolchain]
  mojo`); a lock for another set is stale. `mopm sync` installs the builds for
  the first.
- `toolchain`: for each locked Mojo version and each subdir mopm pins a
  toolchain for, the closure hash (`unit-graph.md`, "toolchain"). A Mojo
  version mopm pins no toolchain for has no entry, and that is not an error; an
  entry for a version that is not in `mojo` is refused.
- `channels`: the channel roots packages may come from. This is the root
  project's set and nothing else. A root ends with `/` and may carry a path
  (`https://conda.mopm.dev/`, `http://127.0.0.1:8080/channel/`); it is https,
  or plain http only to a loopback host (`127.0.0.1`, `[::1]` or `localhost`)
  with a port, for local and test registries. A lock naming any other channel
  is refused.
- `packages[]`, one entry per package version per subdir:
  - `name`: the full name, `<namespace>/<name>`.
  - `version`, `subdir`: identify the file.
  - `channel`: the channel the files come from: a root of `channels` followed by
    the package's namespace and `/` (`https://conda.mopm.dev/komira-ai/`).
  - `artifacts`: the builds, keyed by the Mojo version each was built with.
    Keys are listed in `mojo`. Each has `build`, `url` (the file URL), and
    `sha256` and `size` (the bytes; `mopm install` verifies both before use).
    Two Mojo versions may lock different versions of one package: the entry for
    a Mojo version `M` is the one with an artifact for `M`, and a package
    version without one is not part of the closure for `M`.
  - `deps`: full names of direct Mojo dependencies, each present in `packages`.
  - `native`: native libraries the package ships (`id`, `soname`, optional
    `sha256` of the library file, `kind`, `needs`, `exclusive`, `link`), copied from the
    package metadata so that link planning can run from the lock alone. `mopm
    lock` writes `sha256`: it fetches the package file of a version that ships
    natives (once, and not again while the old lock pins that file), checks its
    size and sha256 against the channel's repodata, and hashes the library
    file that carries `soname` (the shared object for `kind` shared or both, the
    archive for static), which must be `lib/<soname>` in the package. `kind` is
    `shared` (the default, left out), `static` or `both`; `needs` lists the
    sonames of other packages' libraries this one needs; `exclusive` names a
    group of which a closure may hold one library; `link` lists the system
    libraries (`c++`, `dl`, `m`, `pthread`; a static library only) that the final
    link of a consumer adds as `-l<name>` after every archive. All four are the
    package's own declarations, left out when they are the default.
  - A path dependency (`name = { path = "..." }` in `mopm.toml`, at any depth) is
    one entry with `"source": "path"`: `name`, `version` (from its own
    `mopm.toml`), `path` (relative to the project) and `deps`. It has no
    `subdir`, `channel`, `artifacts` or `loads`: there is no file to pin, and
    `mopm sync` never downloads it. A name locked as a path dependency has no
    other entry.

## Rules the schema cannot express

`//:contract` (`tests/drivers/contract.zig`) checks these on the example locks. The CLI must
check them on every read. A violation is an error, not a warning.

1. `packages` is sorted by `name`, then `version`, then `subdir` (each compared
   as a plain byte string, not in version order), with no two entries equal
   in all three. This keeps diffs small and the file
   reproducible.
2. Every registry entry's `channel` is a root listed in `channels` followed by
   the entry's namespace and `/`. A lock entry whose root the root project does
   not list is refused. Only the root project's manifest may add channels; a
   dependency's manifest cannot.
3. Each artifact's `url` is exactly
   `<channel><subdir>/mojo-<namespace>.<name>-<version>-<build>.conda`.
4. Every artifact's Mojo version is in `mojo`, and the keys of `artifacts` are
   sorted with no repeats.
5. Every name in `deps` appears in `packages`.
6. A full name comes from at most one root. The same full name from a second
   configured root is a hard error: it is the shape of a dependency confusion
   attack.
7. No two packages declare the same `soname` in `native`.
8. Each subdir's list in `system_libs` is not empty, sorted by `name` with no
   repeats, and every `deps` name is another entry of that list. Each entry has
   a 64 digit lowercase `sha256`, a positive `size` and an https `.conda` `url`.
9. Each name in a package's `loads` is sorted, appears once, and is an entry of
   `system_libs` for that package's subdir. A path dependency has no `loads`.
10. The closure the lock pins, with the root project, holds one package per
    import name (spec/mopm-toml.md, "Rules"): no two entries with different
    full names have the same import name. The CLI checks it on every read
    by `tree`, `sync` and `plan`, and before `lock` writes; the error names each
    package and its shortest dependency path from the root.
11. Every `name` and every item of `deps` is a full name (`mopm-toml.md`,
    "Names"); a bare name is refused.

## Stale locks

A lock of `lock_version` 1 or 2 predates namespaces: its names are bare and its
files are named `mojo-<name>`. mopm reads such a lock only to report it:

```
mopm.lock predates namespaces (lock_version 2); run 'mopm lock'
```

`mopm lock`, `mopm update`, `mopm add`, `mopm remove` and `mopm sync` (without
`--locked`) treat it as no lock and write a version 3 one. `mopm sync --locked`,
`tree`, `plan`, `build` and `test` refuse with the message above.

## Install and update behaviour (what the lock promises)

- `mopm sync --locked` installs exactly the lock and fails if it would change
  it. It does not read the index.
- Every download is verified against `sha256` and `size`.
- `mopm sync` installs exactly the lock's pinned bytes. It does not read the
  index, so it does not compare the index's values with the lock's.
- A locked version that was yanked installs with no warning: the lock pins its
  bytes. A locked version that was taken down fails at the download, when the
  registry answers 403, 404 or 410, with
  `<url> answered HTTP <status>: <full name> <version> has been taken down or is unavailable`.
- The Mojo toolchain's files and the lock's `system_libs` for the host's subdir
  are installed too. A recorded toolchain closure for the lock's Mojo and the
  host's subdir must equal the closure being installed, or sync refuses before
  any download.

## System libraries

A package can open a system library at run time (`[native-dependencies]
libsqlite = { version = ">=3.40", mode = "load" }`). For its tests to run
against the library the project locked, and not against whatever the machine
has, the lock pins the library's conda package. There are two optional keys;
a lock without them has none of the keys, and `lock_version` does not change.

```json
{
  "packages": [
    { "name": "komira-ai/http_client", "...": "...", "loads": ["libsqlite"] }
  ],
  "system_libs": {
    "linux-64": [
      {
        "name": "libsqlite",
        "version": "3.50.4",
        "build": "h0aef613_0",
        "url": "https://conda.anaconda.org/conda-forge/linux-64/libsqlite-3.50.4-h0aef613_0.conda",
        "sha256": "<64 hex digits>",
        "size": 938000,
        "deps": ["libzlib"]
      }
    ]
  }
}
```

- `system_libs`: for each subdir, the conda packages of every library that the
  root manifest, a path dependency's manifest or a registry package loads, and of
  everything those need to run, sorted by `name`. An entry has `name`
  (a conda name), `version`, `build`, `url`, `sha256`, `size` (the bytes, as for
  a package) and `deps`, the names of the entries of the same list it needs
  (left out when none). The key is left out when nothing is loaded. mopm does not
  solve: the pins are the catalog of the mopm that wrote the lock (one file per
  subdir, pre-solved and checked when mopm is released), and a library outside
  it is refused. The packages the toolchain already supplies (the compiler's C++
  runtime on Linux, the OS's on macOS) are not listed.
- `loads` of a registry package: the conda names of the libraries it loads,
  sorted, taken from the `depends` of the repodata entry of the file the lock
  pins (every name that is not a `mojo-*` package, `mojo-<namespace>.<name>` ones included). A manifest of the root
  project or of a path dependency is read when the unit graph is made, so it has
  no entry here.
- `mopm lock` writes both keys, for every subdir, only when some manifest or
  registry package loads a library; a lock of a project that loads none has
  neither. A version
  requirement in a manifest (`">=3.40"`) is checked against the pin, and a
  pin that does not meet it is refused: `mopm pins libsqlite 3.51.0 for
  linux-64; requirement ">=4" cannot be met; update mopm`. A name the catalog has
  no entry for is refused for a manifest, naming the names it has.
- `mopm plan` reads the pins (`unit-graph.md`, "System libraries"). A mopm that
  does not know the keys ignores them and prints a graph without `loads`, which
  a build system that compares the committed graph with mopm's output reports.
- The pin is what a test runs against. `mopm sync` may install a newer
  compatible version of a library for development.

## Versioning

`lock_version` changes only for incompatible changes. New optional keys can
be added within version 3; readers ignore keys they do not know (`system_libs`
and `loads` are such keys).

## A project with no registry dependency

`mopm lock` contacts the registry only when it has something to ask it: a
project whose `mopm.toml` and path dependencies' `mopm.toml` files name no
version requirement is locked offline, with no network, and the registry named
by `--registry` is not contacted (it may be unreachable). Its lock holds the
path packages only. `channels` still lists one channel, the default
`https://conda.mopm.dev/`, which nothing is fetched from; the lock is the same
for every `--registry`.
