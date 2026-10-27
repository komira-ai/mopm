# mopm.toml (draft)

`mopm.toml` sits at the root of a package. This is a draft; `mopm metadata`
reads and checks it.

```toml
[package]
name = "http_client"          # the import name and the registry name
version = "0.4.0"           # MAJOR.MINOR.PATCH, see Package versions
description = "HTTP/1.1 client"
license = "Apache-2.0"
repository = "https://github.com/example/http_client"
homepage = "https://example.com/http_client"
keywords = ["http", "client"]
readme = "README.md"
publish = true                # false: never staged, packed or published (a test-support helper); default true
mojo = ["1.0.0", "1.1.0"]     # exact compiler versions it builds for, one .mojoc each (a .mojoc is tied to one)

[dependencies]                # Mojo packages
http_core = "1.2"
tls = { version = "0.9" }
local_util = { path = "../local_util", version = "0.2" }   # a path needs a version to be published

[native-dependencies]         # non-Mojo libraries the package links
zlib = { version = ">=1.2", kind = "shared", mode = "link" }

[dev-dependencies]            # only for tests and tooling
mopm_test = "0.1"

[native.curl_shim]            # a native library this package ships
kind = "shared"               # shared | static | both
mode = "link"                 # link (mopm computes flags) | load (self-loads)
build = "cmake -S native -B out && cmake --build out"
outputs = ["out/libcurl_shim.so.1"]

[targets]                     # what to build
lib = { path = "src/http_client" }
bins = [{ name = "fetch", path = "src/fetch.mojo" }]
tests = ["tests"]
```

## Sections

- `[package]`: identity. `name` is unique in the registry; only its owner can
  publish versions of it, and a published version is immutable.
  All of `description`, `license`, `repository`, `homepage`, `keywords` and
  `readme` are optional. When present they are checked as below and served by
  the registry's read API (`description`, `license`, `repository`, `homepage`,
  `keywords` and `readme` of a version; spec/api/openapi.yaml). The publish
  pipeline copies them from the file at publish time.
- `publish` (in `[package]`): a boolean, default true. `publish = false` marks a
  package that is a member of a workspace but is never published, such as a
  helper that is only a path `[dev-dependencies]` target of other members. It
  still needs a `name` and `version` and is read like any other package by
  `lock`, `sync`, `build`, `test` and `plan`. `pack`, `publish` and `stage`
  refuse it (`stage` with no package names leaves it out), and a package that is
  published may not list one in `[dependencies]`; `[dev-dependencies]` may.
  Anything but `true` or `false` is refused, naming the key.
- `[dependencies]`: Mojo packages with version requirements. A dependency may
  also have a `path`, for co-development against a local checkout; see
  Dependencies with a path.
- `[native-dependencies]`: native libraries from outside the Mojo ecosystem.
  `kind` (shared | static) is what the package asks for; `mode` (link | load,
  default link) is how consumers' tooling uses it: link means mopm computes the
  link and load flags, load means the package opens the library itself.
- `[dev-dependencies]`: not installed for consumers.
- `mojo` (in `[package]`): the exact Mojo compiler versions the package builds
  for, a string or an array of strings, none repeated. `mopm publish` builds
  one `.mojoc` per version and uploads all of them under the one package
  version; a lock covers every version listed (`lock.md`, "Version 2"), and a
  build system makes one unit per version (`unit-graph.md`). Tools normalise it
  to an array.
- `[toolchain]` (older form): `mojo = <version or array>` read as
  alternatives: a lock is made for the first that resolves. Setting `mojo` in
  `[package]` and `[toolchain]` is an error.
- `[native.<id>]`: a native library the package builds and ships. Its entry in
  the installed `<name>.mopm.json` (see `package-metadata.schema.json`) is what
  consumers' tooling reads. `needs` (sonames of other packages' libraries this
  one needs) and `exclusive` (a group name) are copied into that entry. `mopm
  pack` packs a library with `kind = "static"` and `mode = "link"`, from the
  archive given per subdir (`--native <id>=<subdir>:<file>`); a package that
  declares one has no `noarch` file. A static library can also give `srcs`,
  `hdrs`, `cflags`, `cflags_by_os`, `includes` and `soname`: the C sources a
  build system compiles into its archive (`unit-graph.md`, "Member natives").
- `[targets]`: the library, executables and tests to build.

## Other tools' settings: `[package.metadata]`

mopm refuses a key or table it does not know, so a typo is an error. One place
is left for the settings of other tools, as in cargo's `package.metadata`:
`[package.metadata]`, with one subtable per tool by convention
(`[package.metadata.<tool>]`).

```toml
[package.metadata.buildrules]
visibility = ["PUBLIC"]
```

- mopm reads nothing in it and checks nothing in it: any keys, nesting and
  values the TOML subset mopm reads (strings, integers, booleans, arrays,
  tables) are accepted. It must be a table; `metadata = "x"` is an error.
- mopm preserves it. `mopm metadata` prints it, as JSON in file order, under
  `package.metadata`; the key is there only when the file has the table, so
  every other output is unchanged. It does not change a lock, a unit graph or
  a unit's key, and `mopm pack` and `mopm publish` ignore it.
- There is no other such table: `[tool.*]` or any other top-level table is
  still refused.

## Version requirements

Dependency versions follow cargo's rules:

- A bare version is a caret requirement: `"1.2"` means `>=1.2.0, <2.0.0`;
  `"0.4"` means `>=0.4.0, <0.5.0`; `"0.0.3"` means `=0.0.3`.
- Operators: `^`, `~` (`~1.2` means `>=1.2.0, <1.3.0`), `=`, `>`, `>=`, `<`,
  `<=`, and `*` (any version). Several comparators are joined with commas and
  all must hold: `">=1.2, <1.5"`.
- There are no pre-release versions (see Package versions), so a requirement
  never needs to name one.
- Native dependency versions are passed to the native package's ecosystem as
  written (they follow its version scheme, not semver).

## Package versions

`version` is `MAJOR.MINOR.PATCH`: exactly three numbers separated by dots,
each without leading zeros (`0.4.0`, `1.12.3`). There is no pre-release,
post-release, dev or build-metadata suffix and no short form: `1.0`,
`1.0.0.0`, `1.0rc1`, `1.0.0-rc.1`, `1.0.0+local` and `01.0.0` are all invalid.
The registry refuses them at publish (and in any path) with
`invalid_version`, and the grammar is the one in `api/openapi.yaml`
(`Version`). A version has one spelling, so two versions are the same version
exactly when their text is the same. Versions order numerically by major, then
minor, then patch.

## Dependencies with a path

A dependency may name a `path` as well as a `version`. The path is used only
while developing in a checkout: `mopm lock`, `tree`, `plan`, `build` and `sync`
use the path, not the registry. Following cargo, a dependency that has a
`path` and no `version` cannot be packed: `mopm pack` and `mopm publish` refuse
it before any file is made, because a consumer has no checkout to read the path
from and nothing says which versions work. With both, `mopm pack` and
`mopm publish` write the version requirement into the package and never the
path, so the registry only ever sees a requirement. `mopm pack` checks the path package's version: it reads the `mopm.toml` at the path and refuses a package whose own version does not satisfy that requirement.
The version of such a dependency must be a valid version requirement. The
generated `<name>.mopm.json` therefore has a `range` and no `path` for it;
`package-metadata.schema.json` still says `dependentRequired` `path` needs
`range`, so metadata made by hand with a path and no range is refused.

The requirement string of a dependency is recorded exactly as written in
`mopm.toml`. It is the cargo-syntax requirement that mopm's own resolver reads
from the sparse index (`deps[].range`, `index.md`); it is not translated into
conda syntax anywhere that a resolver reads it.

## `[package]` display fields

| field | type | rule |
|---|---|---|
| `description` | string | one line, 1 to 512 characters, no line breaks |
| `license` | string | an SPDX license expression, such as `Apache-2.0` or `MIT OR Apache-2.0`, at most 128 characters |
| `repository` | string | an `https://` URL, at most 2048 characters |
| `homepage` | string | an `https://` URL, at most 2048 characters |
| `keywords` | array of strings | at most 10, unique, each 1 to 32 characters of letters, digits, `-`, `_`, `.` or `+` |
| `readme` | string | path of a Markdown file inside the package, relative to `mopm.toml`; at most 64 KiB (65,536 bytes) of UTF-8 |

A value that breaks its rule is an error, not a warning; the publish pipeline
refuses it. The
registry serves the readme's text, not its path.

These fields are untrusted input. The registry stores the readme, `description`
and `license` verbatim and does not sanitize them. A consumer that renders the
readme must sanitize the Markdown, disable raw HTML and treat its links as
untrusted; `description` and `license` are plain text to escape, never markup.

## Rules

- A native library has one owner: two packages in one dependency closure may
  not ship the same soname.
- A package that links natives lists, in its generated metadata, every native
  library it needs from other packages.
