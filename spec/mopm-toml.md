# mopm.toml (draft)

`mopm.toml` sits at the root of a package. This is a draft; `mopm metadata`
reads and checks it.

```toml
[package]
name = "http_client"          # the import name and the registry name
version = "0.4.0"
description = "HTTP/1.1 client"
license = "Apache-2.0"
repository = "https://github.com/example/http_client"
readme = "README.md"

[toolchain]
mojo = "1.0.0"                # exact compiler version, or an array of them; a .mojoc is tied to one

[dependencies]                # Mojo packages
http_core = "1.2"
tls = { version = "0.9" }
local_util = { path = "../local_util" }   # co-development only; not publishable

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
- `[dependencies]`: Mojo packages with version requirements, or a `path`.
- `[native-dependencies]`: native libraries from outside the Mojo ecosystem.
  `kind` (shared | static) is what the package asks for; `mode` (link | load,
  default link) is how consumers' tooling uses it: link means mopm computes the
  link and load flags, load means the package opens the library itself.
- `[dev-dependencies]`: not installed for consumers.
- `[toolchain]`: the Mojo compiler version(s) the package is built with: a
  string or an array of strings, each an exact version. Tools normalise it to an
  array.
- `[native.<id>]`: a native library the package builds and ships. Its entry in
  the installed `<name>.mopm.json` (see `package-metadata.schema.json`) is what
  consumers' tooling reads.
- `[targets]`: the library, executables and tests to build.

## Version requirements

Dependency versions follow cargo's rules:

- A bare version is a caret requirement: `"1.2"` means `>=1.2.0, <2.0.0`;
  `"0.4"` means `>=0.4.0, <0.5.0`; `"0.0.3"` means `=0.0.3`.
- Operators: `^`, `~` (`~1.2` means `>=1.2.0, <1.3.0`), `=`, `>`, `>=`, `<`,
  `<=`, and `*` (any version). Several comparators are joined with commas and
  all must hold: `">=1.2, <1.5"`.
- Pre-release versions (`1.3.0-beta.1`) only match a requirement that names a
  pre-release of the same major.minor.patch.
- Native dependency versions are passed to the native package's ecosystem as
  written (they follow its version scheme, not semver).

## Rules

- A native library has one owner: two packages in one dependency closure may
  not ship the same soname.
- A package that links natives lists, in its generated metadata, every native
  library it needs from other packages.
