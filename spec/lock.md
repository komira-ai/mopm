# mopm.lock

`mopm.lock` records the exact packages a project resolved to, so that the same
bytes are installed on every machine and in CI. It is JSON, written by mopm,
committed, and never edited by hand. The schema is `lock.schema.json`.

The lock states only what mopm needs to fetch and verify: where each file
comes from, which bytes it must be, and which Mojo version it was built
with. It does not duplicate package metadata; that stays in the installed
`<name>.mopm.json`.

```json
{
  "lock_version": 1,
  "toolchain": { "mojo": "1.0.0" },
  "channels": ["https://conda.mopm.dev/"],
  "packages": [
    {
      "name": "http_client",
      "version": "0.4.0",
      "build": "mojo1.0.0_0",
      "subdir": "linux-64",
      "channel": "https://conda.mopm.dev/",
      "url": "https://conda.mopm.dev/linux-64/mojo-http_client-0.4.0-mojo1.0.0_0.conda",
      "sha256": "<64 hex digits>",
      "size": 123456,
      "mojo": "1.0.0",
      "deps": ["http_core"],
      "native": [{ "id": "crypto", "soname": "libcrypto_native.so.1", "sha256": "<64 hex digits>" }]
    }
  ]
}
```

## Fields

- `lock_version`: 1 (2 is "Version 2" below). A value mopm does not know is refused with "update mopm".
- `toolchain.mojo`: the Mojo version the project is locked to
  (`[toolchain]` in `mopm.toml`).
- `channels`: the channels packages may come from. This is the root project's
  set and nothing else. A channel ends with `/` and may carry a path
  (`https://conda.mopm.dev/`, `http://127.0.0.1:8080/channel/`); it is https,
  or plain http only to a loopback host (`127.0.0.1`, `[::1]` or `localhost`)
  with a port, for local and test registries. A lock naming any other channel
  is refused.
- `packages[]`, one entry per package per subdir:
  - `name`: the mopm name. The conda name is `mojo-<name>`.
  - `version`, `build`, `subdir`: identify the file.
  - `channel`: the channel the file comes from, with a trailing slash.
  - `url`: the file URL.
  - `sha256`, `size`: the bytes. `mopm install` verifies both before use.
  - `mojo`: the Mojo version the package was built with. A `.mojoc` is tied to
    one compiler, so it must equal `toolchain.mojo`.
  - `deps`: names of direct Mojo dependencies, each present in `packages`.
  - `native`: native libraries the package ships (`id`, `soname`, optional
    `sha256` of the library file, `kind`, `needs`, `exclusive`), copied from the
    package metadata so that link planning can run from the lock alone. `mopm
    lock` writes `sha256`: it fetches the package file of a version that ships
    natives (once, and not again while the old lock pins that file), checks its
    size and sha256 against the channel's repodata, and hashes the library
    file that carries `soname` (the shared object for `kind` shared or both, the
    archive for static), which must be `lib/<soname>` in the package. `kind` is
    `shared` (the default, left out), `static` or `both`; `needs` lists the
    sonames of other packages' libraries this one needs; `exclusive` names a
    group of which a closure may hold one library. All three are the package's
    own declarations, left out when they are the default.

## Rules the schema cannot express

`//:contract` (`tests/drivers/contract.zig`) checks these on the example locks. The CLI must
check them on every read. A violation is an error, not a warning.

1. `packages` is sorted by `name`, then `version`, then `subdir` (each compared
   as a plain byte string, not in version order), with no two entries equal
   in all three. This keeps diffs small and the file
   reproducible.
2. Every `channel` is in `channels`. A lock entry whose channel the root
   project does not list is refused. Only the root project's manifest may add
   channels; a dependency's manifest cannot.
3. `url` is exactly `<channel><subdir>/mojo-<name>-<version>-<build>.conda`.
4. `mojo` of every entry equals `toolchain.mojo`.
5. Every name in `deps` appears in `packages`.
6. A package name comes from at most one channel. The same name on a second
   configured channel is a hard error: it is the shape of a dependency
   confusion attack.
7. No two packages declare the same `soname` in `native`.
8. Each subdir's list in `system_libs` is not empty, sorted by `name` with no
   repeats, and every `deps` name is another entry of that list. Each entry has
   a 64 digit lowercase `sha256`, a positive `size` and an https `.conda` `url`.
9. Each name in a package's `loads` is sorted, appears once, and is an entry of
   `system_libs` for that package's subdir. A path dependency has no `loads`.

## Install and update behaviour (what the lock promises)

- `mopm sync --locked` installs exactly the lock and fails if it would change
  it. It does not read the index.
- Every download is verified against `sha256` and `size`. When the sparse
  index is reachable, `mopm` also compares the index's values with the lock's
  and names both on a mismatch.
- A locked version that was yanked still installs, with a warning that gives
  the reason. A locked version that was taken down fails to install, and the
  error shows the tombstone reason from the index.

## Version 2

A project that lists its Mojo versions under `[package] mojo` (`mopm-toml.md`)
gets a `lock_version` 2 lock: one lock for every Mojo version, because a
`.mojoc` is tied to one compiler. mopm reads both versions; a lock from
`[toolchain] mojo` stays version 1. Version 2 changes the top of the file and
what a package entry carries; `channels` and the rules below keep their
meaning. `lock.schema.json` describes version 1.

```json
{
  "lock_version": 2,
  "mojo": ["1.0.0", "1.1.0"],
  "toolchain": { "1.0.0": { "linux-64": "<64 hex digits>" }, "1.1.0": { "linux-64": "<64 hex digits>" } },
  "channels": ["https://conda.mopm.dev/"],
  "packages": [
    {
      "name": "http_core",
      "version": "1.2.5",
      "subdir": "linux-64",
      "channel": "https://conda.mopm.dev/",
      "artifacts": {
        "1.0.0": { "build": "mojo1.0.0_0", "url": "https://conda.mopm.dev/linux-64/mojo-http_core-1.2.5-mojo1.0.0_0.conda", "sha256": "<64 hex digits>", "size": 1000 },
        "1.1.0": { "build": "mojo1.1.0_0", "url": "https://conda.mopm.dev/linux-64/mojo-http_core-1.2.5-mojo1.1.0_0.conda", "sha256": "<64 hex digits>", "size": 1100 }
      }
    }
  ]
}
```

- `mojo`: the Mojo versions locked, sorted as byte strings, with no repeats.
  It equals the set `mopm.toml` lists; a lock for another set is stale.
- `toolchain`: for each locked Mojo version and each subdir mopm pins a
  toolchain for, the closure hash (`unit-graph.md`, "toolchain"). It replaces
  version 1's `toolchain.mojo`. Every locked version has a closure.
- `packages[]`: one entry per package version per subdir, sorted as in
  version 1. It has no `build`, `url`, `sha256`, `size` or `mojo`; instead
  `artifacts` maps each Mojo version the version has a build for to that
  build's `build`, `url`, `sha256` and `size`. Keys are listed in `mojo`. Two
  Mojo versions may lock different versions of one package: the entry for a
  Mojo version `M` is the one with an artifact for `M`, and a package version
  without one is not part of the closure for `M`. A path dependency is
  unchanged (it has no artifacts). `deps` and `native` are as in version 1.
- Rule 3 holds per artifact (`url` is `<channel><subdir>/mojo-<name>-<version>-<build>.conda`);
  rule 4 becomes: every artifact's Mojo version is in `mojo`.
- `mopm sync` installs the builds for the first locked Mojo version.

## System libraries

A package can open a system library at run time (`[native-dependencies]
libsqlite = { version = ">=3.40", mode = "load" }`). For its tests to run
against the library the project locked, and not against whatever the machine
has, the lock pins the library's conda package. There are two optional keys;
a lock without them is read and written as before, and `lock_version` does not
change.

```json
{
  "packages": [
    { "name": "http_client", "...": "...", "loads": ["libsqlite"] }
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
  pins (every name that is not a `mojo-*` package). A manifest of the root
  project or of a path dependency is read when the unit graph is made, so it has
  no entry here.
- `mopm lock` writes both keys, for every subdir, only when some manifest or
  registry package loads a library; a lock of a project that loads none is
  unchanged, and an old lock is not rewritten until `mopm lock` runs. A version
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
be added within version 1; readers ignore keys they do not know (`system_libs`
and `loads` are such keys, and apply to both versions).

## A project with no registry dependency

`mopm lock` contacts the registry only when it has something to ask it: a
project whose `mopm.toml` and path dependencies' `mopm.toml` files name no
version requirement is locked offline, with no network, and the registry named
by `--registry` is not contacted (it may be unreachable). Its lock holds the
path packages only. `channels` still lists one channel, the default
`https://conda.mopm.dev/`, which nothing is fetched from; the lock is the same
for every `--registry`.
