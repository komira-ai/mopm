# Configuration

This page lists every setting mopm reads, in `mopm.toml`, in `mopm.lock` and in the configuration of the user, with its type, its default, the values it allows and an example. It is part three of the documentation, after [why mopm exists and how it is built](why-and-design.md) and [getting started](getting-started.md), and it is derived from the parsers in `src/core/manifest.zig`, `src/core/toml.zig`, `src/core/lock.zig` and `src/core/credentials.zig`, not from the plan. Where [the mopm.toml draft](../spec/mopm-toml.md) and the code disagree, this page says what the code does today. Every file named in [the worked examples](examples.md) is a real package that the CI of this repository reads with the built `mopm`.

## Where each setting lives

| setting | file or flag | written by | read by |
|---|---|---|---|
| the package: name, version, dependencies, targets | `mopm.toml`, in the package's root | you, and `mopm new`, `mopm init`, `mopm add`, `mopm remove` | `metadata`, `lock`, `update`, `tree`, `sync`, `add`, `remove`, `plan`, `pack`, `publish` |
| the exact packages and bytes | `mopm.lock`, beside `mopm.toml` | `mopm lock`, `update`, `add`, `remove`, `sync` | `tree`, `sync`, `plan`, `lock` |
| an account on a registry | `credentials.json`, in the config directory | `mopm login`, `logout` | `publish`, `whoami`, `logout` |
| which registry | `--registry prod, gamma, beta or a URL` | the command line | the commands that talk to a registry |
| which Mojo environment | `--prefix`, `CONDA_PREFIX`, `MODULAR_HOME` | the command line, your shell | `build`, `run`, `repl`, `test` |

There is no other file. `mopm build`, `run`, `repl` and `test` do not read `mopm.toml`: a test is found by its path, `tests/**/test_*.mojo` and `src/**/tests/test_*.mojo`. mopm does not read a global or a per-user settings file besides `credentials.json`, and the Mojo toolchain that a build system gets from `mopm plan` is pinned in mopm's own source (`src/core/toolchain/`), not in a file you edit. Two directories are made for you and are not settings: `.mopm/` (the environment `mopm sync` makes) and `target/mopm/` (what `mopm test` builds).

## mopm.toml

`mopm.toml` is read from the current directory; `mopm metadata <path>` and `--manifest <file>` of `pack` and `publish` name another. The file is UTF-8 text of at most 1 MiB. mopm reads it with a strict subset of TOML 1.0, and refuses any key or table it does not know, so a typo is an error with a line and column and not a setting that silently does nothing. `mopm metadata` prints how the file was read, as JSON.

### The TOML subset

| accepted | refused, with a message that says so |
|---|---|
| tables `[a.b]`, dotted keys, bare and quoted keys | arrays of tables `[[x]]` (write an inline array of tables) |
| basic strings with the escapes `\b \t \n \f \r \" \\ \uXXXX \UXXXXXXXX`, literal strings `'...'` | multi-line strings, `"""` and `'''` |
| decimal integers that fit 64 bits, without a leading zero | floats, dates and times, `_` in integers, hexadecimal, octal and binary integers |
| booleans, arrays (over several lines, with comments), inline tables | an inline table extended after it is closed, a key or a table defined twice |

Comments run from `#` to the end of the line. Integers and booleans are read, but only a value inside `[package.metadata]` may be one: every key of mopm itself takes a string, an array of strings or a table, and refuses anything else (`'name' in [package] must be a string, not an integer`).

### Top level

Any key other than these is refused, including `workspace`, `tool` and `profile`. There is no `[workspace]` table: the packages of one repository are path dependencies of each other (see the workspace example).

| key | type | default | allowed | example |
|---|---|---|---|---|
| `package` | table | none, required | see `[package]` | `[package]` |
| `toolchain` | table | none | see `[toolchain]`; not together with `[package] mojo` | `[toolchain]` |
| `dependencies` | table | empty | see Dependencies | `[dependencies]` |
| `dev-dependencies` | table | empty | see Dependencies | `[dev-dependencies]` |
| `native-dependencies` | table | empty | see Native dependencies | `[native-dependencies]` |
| `native` | table | empty | one subtable per library, see `[native.<id>]` | `[native.curl_shim]` |
| `targets` | table | empty | see `[targets]` | `[targets]` |

### `[package]`

| key | type | default | allowed | example |
|---|---|---|---|---|
| `name` | string | none, required | a lowercase identifier: a lowercase letter, then lowercase letters, digits and `_`; not a Mojo keyword (`for`, `fn`, `struct`, ...) or a builtin it would shadow (`len`, `print`, `range`, ...) | `name = "http_client"` |
| `version` | string | none, required | semantic versioning: `MAJOR.MINOR.PATCH` with an optional `-pre.release` and `+build`. `pack` and `publish` accept exactly `MAJOR.MINOR.PATCH` | `version = "0.4.0"` |
| `description` | string | none | any string; mopm checks only that it is a string | `description = "HTTP/1.1 client"` |
| `license` | string | none | any string; mopm checks only that it is a string | `license = "Apache-2.0"` |
| `repository` | string | none | any string; mopm checks only that it is a string | `repository = "https://github.com/example/http_client"` |
| `readme` | string | none; `publish` uses `README.md` beside the manifest when it exists | a path, relative to the directory of `mopm.toml`, of a UTF-8 file of at most 64 KiB (65,536 bytes) | `readme = "README.md"` |
| `mojo` | string or array of strings | none | exact compiler versions, such as `"1.0.0"`: at least one, none empty, none repeated; not together with `[toolchain]` | `mojo = ["1.0.0", "1.1.0"]` |
| `metadata` | table | none | any keys and values the TOML subset reads | `[package.metadata.some_tool]` |

A package name is also the name of its directory under `src/` that `mopm new` makes, the import name, and, in the registry, `mojo-<name>`. `homepage` and `keywords`, which [the mopm.toml draft](../spec/mopm-toml.md) lists, are not keys of the parser today: `unknown key 'homepage' in [package]`.

`mojo` in `[package]` makes a version 2 lock (below) for every version listed, and a unit graph for one of them. `[package.metadata]` is the one place for the settings of other tools: mopm neither reads nor checks it, and `mopm metadata` prints it under `package.metadata`, in file order, only when the file has it.

### `[toolchain]`

The older spelling of the compiler pin, and what `mopm new` writes. It is a version-1 lock for the first version in the list that resolves.

| key | type | default | allowed | example |
|---|---|---|---|---|
| `mojo` | string or array of strings | none, required when the table is there | the same as `[package]` `mojo`; a list is read as alternatives, not as all of them | `mojo = "1.0.0"` |

`mopm lock`, `update`, `add`, `remove` and `sync` stop with `mopm.toml has no [toolchain] mojo` when the file names no compiler in either place. `mopm plan` makes a unit graph for one compiler: with several versions listed it asks for `--mojo <version>`.

### Dependencies: `[dependencies]` and `[dev-dependencies]`

Each entry is `name = <requirement>` or `name = { version = <requirement> }` or `name = { path = <directory> }`. The name follows the rules of a package name. `[dev-dependencies]` has the same entries; they are locked and shown in `mopm tree`, and they are dependencies of the test units of `mopm plan`, but they are not part of a packed package.

The keys of the table form:

| key | type | default | allowed | example |
|---|---|---|---|---|
| `version` | string | none | a version requirement (below); beside a `path` it is the requirement that `pack` and `publish` write in place of the path | `{ version = "0.9" }` |
| `path` | string | none | a non-empty directory with its own `mopm.toml` that names the same package; relative to the directory of the manifest that names it | `{ path = "../util" }` |

An entry needs a `version`, a `path`, or both. With both, `{ path = "../util", version = "0.3" }`, the path is what `mopm lock`, `tree`, `plan`, `build` and `sync` use (the package is built from that directory, and the lock records it as a path), and the version is not looked up in the registry. `mopm pack` and `mopm publish` do the opposite: they write the version into the package they make and never the path, so a consumer of the package asks the registry for `util` 0.3 and gets the registry's copy. The `version` is a version requirement like any other, and a requirement that is not one is refused when the file is read.

Two rules apply when you pack, each refused before any file is made or request is sent, with exit status 1:

- A path dependency with no `version` cannot be packed: `dependency 'x' is a path dependency with no version; add 'version' beside its 'path'`, because a consumer has no checkout to read the path from and nothing says which versions work.
- The package at the `path` must satisfy the `version`: `mopm pack` reads the `mopm.toml` of that directory and refuses with `dependency 'x' requires version "0.4", but the package at '../util' is version 0.3.4; change the requirement or the version of that package` when its `[package] version` is outside the requirement.

A version requirement is a comma-separated list of comparators that must all hold, or `*`:

| form | meaning |
|---|---|
| `"1.2"`, `"^1.2"`, `"1.2.3"` | caret: compatible versions, as cargo reads them (`"1.2"` is at least 1.2.0 and below 2.0.0) |
| `"~1.2"` | tilde: at least 1.2.0 and below 1.3.0 |
| `"=1.2.3"`, `">1.2"`, `">=1.2"`, `"<2"`, `"<=1.5.0"` | an operator and one to three parts |
| `"1.*"`, `"1.2.*"` (also `x` and `X`) | a wildcard, with no operator |
| `">=1.2, <1.5"` | several comparators, joined by commas |
| `"*"` | any version, on its own |

A requirement is refused when it is empty, has an empty comparator, names build metadata (`+...`), has more than three parts, or puts a pre-release on a partial version. A requirement with a pre-release is accepted by the reader, and `pack` refuses it ("a pre-release in a requirement has no conda spelling"). `mopm add <name>` writes `^X.Y.Z`; `mopm add <name>@<requirement>` writes what you gave.

### Native dependencies: `[native-dependencies]`

One entry per library, `name = "1.6"` or `name = { version = ..., kind = ..., mode = ... }`. The name starts with a letter or digit and holds letters, digits and `_ - . +`.

| key | type | default | allowed | example |
|---|---|---|---|---|
| `version` | string | none | any string; it is not interpreted | `version = ">=1.2"` |
| `kind` | string | none | `"shared"` or `"static"` | `kind = "shared"` |
| `mode` | string | `"link"` | `"link"`: mopm computes the linker flags; `"load"`: the package opens the library itself | `mode = "load"` |

### Native libraries: `[native.<id>]`

A native library that the package builds and ships. The id is a lowercase identifier.

| key | type | default | allowed | example |
|---|---|---|---|---|
| `kind` | string | `"shared"` | `"shared"`, `"static"` or `"both"` | `kind = "shared"` |
| `mode` | string | `"link"` | `"link"` or `"load"` | `mode = "link"` |
| `build` | string | none | any string; mopm does not run it | `build = "cmake -S native -B out"` |
| `outputs` | array of strings | empty | any strings | `outputs = ["out/libcurl_shim.so.1"]` |
| `needs` | array of strings | empty | sonames (`lib<name>.<suffix>`) of native libraries of other packages that this one needs; for a static archive they fix its place on the link line (an archive comes before the archives it needs) | `needs = ["libcrypto_sys.a"]` |
| `exclusive` | string | none | a group name, not empty; recorded in the lock and the unit graph; a closure holds one library of a group: `mopm plan --unit-graph` refuses a unit whose closure has two, and the link plan reports `exclusive_conflict`, each naming both libraries; the lock itself may hold several (units that do not share a closure may each use one); group names are compared exactly, case included | `exclusive = "libcrypto"` |

`mopm pack` and `mopm publish` pack a library with `kind = "static"` and `mode = "link"`: the archive is not built by mopm (`build` and `outputs` are descriptive), it is the file named for each subdir with `--native <id>=<subdir>:<file>`, and its file name, `lib<name>.a`, is the library's soname. A package that declares a native library has no `noarch` file, and every subdir it packs needs an archive for every library it declares. The `.mopm.json` that `pack` writes is the same bytes in every subdir's file; what differs between platforms (the archive's sha256 and size) is in `info/about.json` of each file, under `mopm_native`, which nothing reads back.

### `[targets]`

| key | type | default | allowed | example |
|---|---|---|---|---|
| `lib` | table | `src/<name>`, when that directory exists | a table with one key, `path` (below) | `lib = { path = "src/http_client" }` |
| `bins` | array of tables | empty | tables with `name` and `path` (below) | `bins = [{ name = "fetch", path = "src/fetch.mojo" }]` |
| `tests` | array of strings | empty | any strings | `tests = ["tests"]` |

The keys of `lib` and of each entry of `bins`:

| key | type | default | allowed | example |
|---|---|---|---|---|
| `path` | string | none, required | the package directory (`lib`) or the Mojo file with the `main` (`bins`), relative to the manifest; for `mopm plan`, below the root project | `path = "src/main.mojo"` |
| `name` | string | none, required (`bins` only) | the file name of the program that unit makes | `name = "fetch"` |

### What reads each key

Accepted does not mean used. This table says, for every table and key, which commands act on it today; "metadata only" means that the key is checked and printed by `mopm metadata` and no other command reads it.

| key | what reads it |
|---|---|
| `package.name`, `package.version` | `lock`, `tree`, `plan`, `pack`, `publish`, and the lock entry of a path dependency |
| `package.description`, `package.license`, `package.repository` | metadata only: `pack` and `publish` do not send them |
| `package.readme` | `publish`, which sends the file's text; `--readme <file>` overrides it |
| `package.mojo`, `toolchain.mojo` | `lock`, `update`, `add`, `remove`, `sync`, `plan` |
| `package.metadata` | metadata only |
| `dependencies` | `lock`, `update`, `tree`, `sync`, `plan`; `pack` writes them as the package's conda dependencies |
| `dev-dependencies` | `lock`, `tree`, `plan`; not packed |
| `native-dependencies` | metadata only; `pack` refuses a package that has any ("native dependencies are not packed yet") |
| `native` | `pack` and `publish` pack a library with `kind = "static"` and `mode = "link"` (`needs` and `exclusive` go into the package's metadata) and refuse any other kind or mode; `metadata` shows it |
| `targets.lib`, `targets.bins` | `plan`, which makes a unit of each |
| `targets.tests` | metadata only: `mopm test` and `mopm plan` find the tests by their path |

### What pack and publish refuse

`mopm pack` and `mopm publish` read the manifest first and refuse, before any request: a version that is not exactly `MAJOR.MINOR.PATCH` ("digits, no leading zeros, no pre-release or build part"), a path dependency with no version or one whose package is outside its version, a requirement with a pre-release, any `[native-dependencies]`, a `[native.<id>]` that is not a static archive in link mode, a native library without an archive for a subdir it packs (or any native library in a `noarch` file), an archive that does not begin with `!<arch>` or is not named `lib<name>.a`, a compiler that is not digits and dots, and an empty `.mojoc` file. `mopm publish` also refuses a readme over 64 KiB or not UTF-8, a package file over 100 MB, and more than 20 files for one version. The registry has its own limits, which [getting started](getting-started.md) lists.

## mopm.lock

`mopm.lock` is JSON that mopm writes beside `mopm.toml`: commit it, and do not edit it. It is written in one fixed layout (two-space indent, the key order below, `deps` and `native` left out when empty, a final newline), so the same lock is always the same bytes. mopm reads a lock of at most 64 MiB and checks it on every read; a lock that breaks a rule is an error, not a warning. Keys that mopm does not know are ignored, except that a path entry may not carry the keys of a registry entry. `lock_version` 1 is written for a project with `[toolchain] mojo`, and 2 for `[package] mojo`; a lock with a higher number is refused with "Update mopm.".

### The top level

| key | type | default | allowed | example |
|---|---|---|---|---|
| `lock_version` | integer | none, required | `1` or `2` | `"lock_version": 2` |
| `mojo` | array of strings | none, required in version 2 only | the locked Mojo versions, sorted as byte strings, none repeated, at least one; it equals the set of `mopm.toml` | `"mojo": ["1.0.0"]` |
| `toolchain` | object | none, required | version 1: `{"mojo": "<version>"}`. Version 2: for each locked Mojo version, an object from a subdir to the 64 lowercase hex digits of mopm's toolchain closure hash; every locked version has one | `"toolchain": {"1.0.0": {"linux-64": "<sha256>"}}` |
| `channels` | array of strings | none, required | at least one URL, ending in `/`: `https://`, or `http://` only to `127.0.0.1`, `[::1]` or `localhost` with a port | `"channels": ["https://conda.mopm.dev/"]` |
| `packages` | array of objects | none, required | sorted by name, then version, then subdir (plain byte order), no two equal in all three | `"packages": []` |

### A package entry

A registry entry has no `source` key. In version 1 it carries its one file; in version 2 the files are under `artifacts`, one per Mojo version. A path entry (a path dependency, at any depth) has `"source": "path"` and nothing that names a file.

| key | type | default | allowed | example |
|---|---|---|---|---|
| `name` | string | none, required | the mopm name; the conda name is `mojo-<name>` | `"name": "http_core"` |
| `version` | string | none, required | the locked version | `"version": "1.2.5"` |
| `source` | string | absent: a registry entry | `"path"` | `"source": "path"` |
| `path` | string | none, required with `source` | the directory, relative to the project; a name locked as a path has no other entry | `"path": "../util"` |
| `subdir` | string | none, required for a registry entry | any string; mopm writes the platform of the file: `noarch`, `linux-64`, `linux-aarch64` or `osx-arm64` | `"subdir": "linux-64"` |
| `channel` | string | none, required for a registry entry | one of `channels`; one package name comes from one channel only | `"channel": "https://conda.mopm.dev/"` |
| `build` | string | none, required in version 1 | the build string | `"build": "mojo1.0.0_0"` |
| `url` | string | none, required in version 1 | exactly `<channel><subdir>/mojo-<name>-<version>-<build>.conda` | `"url": "https://conda.mopm.dev/linux-64/mojo-http_core-1.2.5-mojo1.0.0_0.conda"` |
| `sha256` | string | none, required in version 1 | 64 lowercase hex digits | `"sha256": "<sha256>"` |
| `size` | integer | none, required in version 1 | at least 1 | `"size": 1000` |
| `mojo` | string | none, required in version 1 | the Mojo version the file was built with; it equals `toolchain.mojo` | `"mojo": "1.0.0"` |
| `artifacts` | object | none, required in version 2 | from each Mojo version to the object below; the versions are in the lock's `mojo` | `"artifacts": {"1.0.0": {}}` |
| `deps` | array of strings | empty | names of direct dependencies, each present in `packages` | `"deps": ["http_core"]` |
| `native` | array of objects | empty | the native libraries the package ships, below | `"native": [{"id": "z", "soname": "libz.so.1", "sha256": "<sha256>"}]` |

Each entry of `artifacts` has these keys, which are the file keys of version 1:

| key | type | default | allowed | example |
|---|---|---|---|---|
| `build` | string | none, required | the build string | `"build": "mojo1.0.0_0"` |
| `url` | string | none, required | as in version 1 | `"url": "https://conda.mopm.dev/..."` |
| `sha256` | string | none, required | 64 lowercase hex digits | `"sha256": "<sha256>"` |
| `size` | integer | none, required | at least 1 | `"size": 1100` |

Each entry of `native` describes a library the package ships. No two packages may ship the same soname, and `mopm plan` refuses a library that has no `sha256`. `mopm lock` writes the `sha256`: for a version that ships natives it downloads the package file once (checking its size and sha256 against the channel's repodata first), reads `<name>.mopm.json` and the library file out of it, and hashes the library; a version whose file the old lock already pins (same name, version, subdir and file sha256, every native hashed) is not downloaded again, and `mopm sync --locked` downloads nothing for this. The file read is the one the package's metadata names, which must be `lib/<soname>`. The package file is held in memory, up to 100 MB (the most `mopm publish` sends); a longer one is refused as too large, and a package whose files decompress to more than 512 MiB (or one file of more than 128 MiB) is refused, as the registry would.

| key | type | default | allowed | example |
|---|---|---|---|---|
| `id` | string | none, required | the library's id in its package's metadata | `"id": "crypto"` |
| `soname` | string | none, required | the file name of the library | `"soname": "libcrypto_native.so.1"` |
| `sha256` | string | none, written by `mopm lock`; optional when read | 64 lowercase hex digits: the sha256 of the library file (not of the package file) | `"sha256": "<sha256>"` |
| `kind` | string | `"shared"`; left out when it is | `"shared"`, `"static"` or `"both"`, as the package's metadata says | `"kind": "static"` |
| `needs` | array of strings | empty; left out when empty | the sonames the library needs, as the package's metadata says | `"needs": ["libcrypto_sys.a"]` |
| `exclusive` | string | none; left out when none | the exclusivity group, as the package's metadata says | `"exclusive": "libcrypto"` |

## The user's configuration

mopm keeps one file for the user, the login, and takes the rest from flags and from the environment.

### credentials.json

`credentials.json` is in the config directory: the one `--config-dir <dir>` names (on `login`, `logout`, `whoami` and `publish`), else `$XDG_CONFIG_HOME/mopm` when `XDG_CONFIG_HOME` is set and not empty, else `$HOME/.config/mopm`. It is written by `mopm login`, to a temporary name with mode 0600 and then renamed, so it is never readable by others; `mopm logout` removes the entry. mopm never prints the token. The file is a JSON object from a registry's API URL (the `api_url` of the registry's index configuration, which is how `--registry` is told apart) to its entry:

| key | type | default | allowed | example |
|---|---|---|---|---|
| `token` | string | none, required | the session token of `mopm login` | `"token": "<token>"` |
| `handle` | string | empty | the account name | `"handle": "octocat"` |

```json
{
  "http://127.0.0.1:8080/api/v1": {
    "handle": "octocat",
    "token": "<token>"
  }
}
```

### Registries

`--registry` takes `prod` (the default, `https://api.mopm.dev`), `gamma` (`https://api.gamma.mopm.dev`), `beta` (`https://api.beta.mopm.dev`) or a URL. A URL is `https://`, or `http://` only to `127.0.0.1`, `[::1]` or `localhost` with a port, for a local registry. It is accepted by `login`, `logout`, `whoami`, `publish`, `lock`, `update`, `sync`, `add` and `remove`. A project with no registry dependency is locked without contacting the registry at all, and the channel its lock lists is `https://conda.mopm.dev/`.

### Environment variables

| variable | meaning |
|---|---|
| `MOPM_TOKEN` | the token `publish` sends, when set and not empty; it wins over a stored login |
| `CONDA_PREFIX`, `MODULAR_HOME` | the Mojo environment, when `--prefix` is not given; `MODULAR_HOME` must end in `/share/max` |
| `XDG_CONFIG_HOME`, `HOME` | where `credentials.json` lives |

Everything else is a flag. `MOPM_VERSION`, `MOPM_HOME` and `MOPM_RELEASES_URL` belong to the install script (`site/static/install.sh`), not to `mopm`.
