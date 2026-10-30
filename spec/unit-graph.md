# The unit graph

`mopm plan --unit-graph --locked` prints the build of a project as JSON: every
unit that must be built or fetched, what each reads, and a key that changes
exactly when a unit's result can change. A build system runs the units as
cached, remote actions; `mopm unit build` and `mopm unit test` are what such an
action executes. mopm owns what "build Mojo" means; the build system only
schedules and caches. This file is the format of the graph, the Mojo
versions it names, and the two unit commands. The lock it is made from is
`lock.md`, the manifest is `mopm-toml.md`.

Everything here is offline. `plan` reads `mopm.toml`, `mopm.lock`, the member
sources and mopm's own pins; it never resolves, fetches or runs a program. A
unit is built from the inputs the graph declares and nothing else.

## Mojo versions

A `.mojoc` is tied to one Mojo version: output of 1.0 does not load in 1.1.
So the Mojo version is part of what a unit is.

- `mopm.toml` lists the exact compiler versions a package builds for:
  `[package] mojo = ["1.0.0", "1.1.0"]` (a string is one version). `mopm
  publish` builds one `.mojoc` per listed version and uploads all of them under
  one package version. The older `[toolchain] mojo` is read too, as
  alternatives (a lock is made for the first that resolves); setting both is an
  error.
- A **unit id** is `<name>@<version>#mojo<M>/<mode>[:<file>]`, for example
  `http_client@0.4.0#mojo1.0.0/lib`. One package built for two Mojo versions is
  two units, two actions, two cache entries. `<mode>` is `lib`, `test` (then
  `:<test file>` follows, relative to the workspace) or `bin` (then
  `:<binary name>`).
- A graph is made for one **consumer Mojo version** `M`: `--mojo <M>`, or the
  one version `mopm.toml` lists. Every unit id in it names `M`. The graph says
  so in its top-level `mojo`.
- A lock made from `[package] mojo` is `lock_version` 2 (`lock.md`). It holds,
  per package version, one artifact for each Mojo version it was published
  for, and mopm's toolchain closure hash for each Mojo version it locks and each platform mopm pins (`linux-64`, `linux-aarch64`, `osx-arm64`); a lock that records `linux-64` only still reads.
- `mopm lock` resolves once for each listed Mojo version and takes, for each
  dependency, the newest version in range that has a build for that Mojo. A
  version mopm pins no toolchain for cannot be listed: `mopm lock` stops with
  `mopm has no pinned toolchain for mojo <M> on <subdir> (it pins <list>)`.
  If no acceptable version has a build for `M`, it stops, writing no lock,
  with

      error: http_core 1.2.0 has no .mojoc for Mojo 1.1.0 (published for: 1.0.0). Build with mojo 1.0.0, ask the publisher for a 1.1.0 build, or pin a version that has one.

  `<name> <version>` is the newest version that matches the requirements;
  `published for` lists the Mojo versions that version has builds for. `plan`
  gives the same line when the lock has no artifact for `M`, and nothing falls
  back to another Mojo.

## The graph

```json
{
  "unit_graph": 2,
  "package": "app@1.0.0",
  "mojo": "1.0.0",
  "toolchain": { ... },
  "system_libs": [ { ... }, ... ],
  "units": [ { ... }, ... ]
}
```

`unit_graph` is the format version (this file describes 2, 3 and 4; a reader refuses
another). Version 2 adds the `native` unit and the `built` native entry
("Member natives", below); a graph of a project without member natives differs
from a version 1 graph only in this number. Version 3 adds `system_libs` and the
`loads` of a unit ("System libraries", below); a graph in which no unit has
`loads` is version 2, byte for byte what it was before they existed, and has no
`system_libs`. Version 4 adds `provided` on a `native` unit ("Provided natives",
below); a graph with no provided native keeps its version 2 or 3. `package` is the root package. `units` are sorted by `id`, and the
text is one fixed layout, so the same inputs give the same bytes.

### toolchain

mopm's own pin for `M`, never read from the environment:

| field | meaning |
|---|---|
| `mojo`, `subdir` | the compiler version and platform (`linux-64`, `linux-aarch64` or `osx-arm64`) |
| `cc_target` | the target triple the pinned Zig links for |
| `zig` | `version`, `url`, `sha256`, `size` of the Zig that serves as the C compiler and linker |
| `components` | `name`, `version`, `url`, `sha256`, `size` of the compiler package and, on Linux, the C++ runtime packages it needs (the macOS closure has no such packages) |
| `closure_sha256` | a hash of the whole closure: the Mojo packages (name, version, build, sha256 of each, in order), then the Zig and `cc_target` |

The pins are files in mopm's source, `src/core/toolchain/mojo-<M>-<subdir>.json`
(the closure, made from a pixi lock, `toolchain/README.md`) and
`zig-for-mojo-<M>.json`. A different mopm may pin different bytes for the same
version; that is why the lock records `closure_sha256` and `plan` refuses a
lock whose recorded hash is not the one this mopm computes.

### units

| field | meaning |
|---|---|
| `id` | the unit id above |
| `package`, `version` | the package |
| `kind` | `lib`, `test`, `bin`, `prebuilt` or `native` |
| `root` | `lib`: the package directory, relative to the workspace (never containing `..`) |
| `srcs` | `path` (relative to the workspace, never containing `..`) and `sha256` of each source, sorted by path (for a `native` unit: its C sources) |
| `soname`, `hdrs`, `cflags`, `cflags_by_os`, `includes`, `needs` | `native`: see "Member natives" |
| `deps` | ids of the units this one imports, in the order `mopm.toml` lists them (order is significant) |
| `natives` | `id`, `soname`, `sha256`, `package` of every prebuilt native library in the unit's dependency closure, and `kind`, `needs`, `exclusive` when the lock gives them (left out when `shared`, empty, none); a workspace member's own native library is listed with `id`, `soname`, `package`, `kind`, `needs`, `exclusive` (the same omissions) and `built`, the id of the `native` unit that builds it, and no `sha256`. They are in link order: a library before every library it `needs`, the sonames' order between libraries that do not constrain one another. A closure holding two libraries of one `exclusive` group is refused, naming both (group names are compared exactly: `libcrypto` and `LibCrypto` are two groups; `mopm.toml` refuses a name with leading or trailing whitespace or a control character). The refusal is graph-wide: one unit with a clash refuses the whole graph, so a clash reached only through a dev-only dependency, and so only by the `test:` unit, blocks the build |
| `loads` | `test` and `bin`: the conda names of the system libraries the unit loads at run time, sorted, run dependencies included; each is an entry of the graph's `system_libs` (format 3 only; left out when empty, see "System libraries") |
| `artifact` | `prebuilt`: `url`, `sha256`, `size` of the `.conda` for `M` (from the lock) |
| `mojoc` | `prebuilt`: the `.mojoc` inside that package |
| `profile` | `opt`, `assert`, `debug`: the compiler profile of a `lib`, `test` or `bin` |
| `outputs` | the file names the unit produces: `<package>.mojoc`, `<test stem>.pass`, a binary's name |
| `key` | see below |

A unit is one package (a `lib`), one test file or one binary of a workspace
member; `mojo precompile` takes a whole package, so nothing is finer. A
registry dependency is a `prebuilt` unit: a `.conda` holding a `.mojoc`, fetched
by url and checked by sha256, never compiled. Workspace members (path
dependencies at any depth) compile from the tree; each must list `M` in its own
`mojo`, and each must be below the workspace directory (see "The workspace"). Two libraries of one
name are refused: a package is imported by name.

The prebuilt `natives` of a package are declared inputs. A lock
entry whose native library has no `sha256` is refused. A static library
(`kind` static) whose `needs` names a soname that no package in the unit's
closure ships is refused, and so are libraries that need each other, because no
link order puts one before the other; a shared library resolves its needs when
the loader runs, so a need it names that the closure lacks is not judged here.

### System libraries

A package can open a system library at run time: `[native-dependencies] libsqlite = { version = ">=3.40", mode = "load" }`
in its `mopm.toml`, or the same in a registry package, which says so in the
`depends` of its repodata entry. A test that loads such a library must find the
one the lock pins, not whichever the machine has, so the lock names it
(`lock.md`, "System libraries") and the graph passes the pin on.

- `system_libs` (format 3): the lock's pins for this graph's `subdir`, sorted by
  `name`, each `name`, `version`, `build`, `url`, `sha256`, `size`: a conda
  package of the library or of something it needs to run. Present when some unit
  has `loads`.
- `loads` of a `test` or `bin` unit: the names of the system libraries of the
  unit's closure (its own package, its dependencies, and for a test the
  dev-dependencies) and, with them, the libraries those need. The library of a
  package that is not in a unit's closure is not in its `loads`. A library is
  loaded by its conda name; names the build system must match against
  `system_libs`. The libraries are loaded, never linked: they are not in
  `natives`.
- A build system puts the unpacked libraries of `loads` on the loader path of
  the run of that unit and of no other action. A rules version that does not know
  `loads` must not read a version 3 graph (it would run the test against the
  machine's libraries), which is why the format number changes.
- A lock written before `system_libs` (it has none at all) gives no `loads`: the
  graph is the one mopm printed before, and the run is not hermetic. A lock that
  has `system_libs`, with a manifest or registry package that loads a library the
  lock does not pin for the graph's subdir, is stale: `plan` refuses with
  `mopm.lock has no system library <name> for <subdir>; run 'mopm lock'`.

### key

`key` is the lower-case hex sha256 of

    "toolchain " <closure_sha256> "\n"
    <the unit as printed, at four spaces of indent, without key>
    { "\n" <key of dependency> }    for each of deps, in order
    { "\nnative " <key of the native unit> }    for each built native of the unit, in link order
    { "\nsystem_lib " <name> " " <sha256> }    for each of the unit's loads, in order

It changes when the unit's id (so `M`), sources, dependency list or order,
natives, profile or outputs change, when the toolchain closure changes, and,
through the dependency keys, when anything it imports changes. A built native
adds the key of its `native` unit, so a unit that links an archive changes
when that archive's sources, headers or flags do. A unit that loads a system
library changes when the pinned bytes of that library do, not only when its name
does. A build system
adds the hash of the mopm binary that runs the unit to its action key. Editing
one package re-runs it and its dependents; unchanged `.mojoc` bytes stop the
cascade there.

### example

Two packages for Mojo 1.0.0 (the layout is the exact output; hashes shortened):

```json
{
  "id": "http_core@1.2.5#mojo1.0.0/lib",
  "package": "http_core",
  "version": "1.2.5",
  "kind": "prebuilt",
  "artifact": {"url": "https://conda.mopm.dev/linux-64/mojo-http_core-1.2.5-mojo1.0.0_0.conda", "sha256": "aaaa...", "size": 1000},
  "mojoc": "lib/mojo/http_core.mojoc",
  "deps": [],
  "natives": [
    {"id": "z", "soname": "libz_native.so.1", "sha256": "348e...", "package": "http_core"}
  ],
  "key": "b6bc..."
}
```

For the same package at Mojo 1.1.0 the unit is `http_core@1.2.5#mojo1.1.0/lib`
and its `artifact` is the 1.1.0 build. `tests/` holds the full output for a
workspace built for both (`src/core/unit_graph.zig`, "golden").

## Member natives

A workspace member (the root package, or a path dependency at any depth) can
build a native library of its own: a static archive made from C sources.

```toml
[native.shim]
kind = "static"                    # the only kind a unit graph builds
srcs = ["native/*.c"]              # globs, relative to the member; required
hdrs = ["native/*.h"]              # optional
cflags = ["-O2"]                   # optional, for every platform
cflags_by_os = { linux = ["-DLINUX"], macos = ["-DMACOS"] }   # optional, appended after cflags on that OS
includes = ["native"]              # optional; default: every directory holding a hdrs file
needs = ["libother.a"]             # sonames of other packages' libraries this one needs
exclusive = "libshim"              # optional group, as for any native library
soname = "libshim.a"               # optional; default lib<id>.a
```

A glob is a `/`-separated path: `*`, `?` and `[abc]` match within a segment,
a segment of `**` matches any number of directories. Names that start with
`.` are never matched, symbolic links are never followed by a glob, and a
pattern that matches no file is refused (a file an earlier pattern named
counts as matched). A path may not be absolute or contain `..`, and a literal
path may not be a symbolic link or pass through one. A file may not be in both
`srcs` and `hdrs`. `cflags_by_os` knows `linux` and `macos`;
any other key is refused. There is no CPU level in a manifest: the build system
compiles at the platform's baseline.

A `shared` or `both` native, one with `mode = "load"`, and one with no `srcs`
(unless it is `provided`, below) are refused when the graph is made, naming the
manifest and the native.

Each such native is one **`native` unit**, `native:<package>/<id>` (the id is
not followed by `#mojo<M>`: C code does not depend on the Mojo version):

| field | meaning |
|---|---|
| `id`, `package`, `version`, `kind` | the unit id, the member, its version, and `native` |
| `soname` | the archive's file name |
| `srcs`, `hdrs` | `path` (relative to the workspace) and `sha256`, sorted by path |
| `cflags`, `cflags_by_os`, `includes`, `needs` | as the manifest gives them (`includes` relative to the member, and the directories of `hdrs` when the manifest gives none; each left out when empty) |
| `deps`, `natives` | always empty |
| `outputs` | `[soname]` |
| `key` | as for any unit: sources, headers, flags and the toolchain closure |

The unit has no `artifact`: the build system compiles the sources and archives
the objects. Every `lib`, `test` and `bin` unit of the member, and of every
package that depends on it, lists it in `natives` as a **built** entry:

    {"id": "shim", "soname": "libshim.a", "package": "app", "kind": "static", "built": "native:app/shim"}

It has no `sha256`: the archive is a product of the build. It stands in the
link order like any other native, so a member's archive comes before the
archives it `needs`, whether those are another member's or a prebuilt package's.
The `exclusive` rule and the rule that two natives of one soname may not meet
in a unit apply to built and prebuilt libraries alike.

`mopm pack` and `mopm publish` pack a member's static native from the archive
the build system gives (`--native <id>=<subdir>:<file>`), as they pack any
static native; its file name must be the `soname` of the unit. `mopm lock` of
a project that depends on the published package pins the archive's sha256, so
consumers get a prebuilt entry.

With `--workspace-root` (see "The workspace") a native is named, as any unit of
the member is, by the package and not by where the package sits: a member at
`src/app` that builds `[native.shim]` gives the unit `native:app/shim`, whose
`srcs` and `hdrs` are paths from the workspace (`src/app/native/shim.c`), while
its `includes` stay relative to the member. This holds for the root package
and for a path dependency at any depth.

## Provided natives

A static native can be built by something other than mopm: `[native.<id>]` with
`kind = "static"` and `provided = true` (and no `srcs`, `hdrs`, `cflags`,
`cflags_by_os`, `includes`, `build` or `outputs`; `mopm.toml` refuses them with
`provided`). The archive is the product of a rule of the build system, which
packs it as `lib<id>.a` into the conda artifact; `needs`, `exclusive` and
`soname` are read as for any native.

The graph has a `native` unit for it, as for a built native, with `"provided":
true`, the `soname` and `outputs`, and no `srcs`, `hdrs`, `cflags` or
`includes`. The build system does not compile it: it supplies the archive of
that name. The `lib`, `test` and `bin` units that link it list it in `natives`
as built, in the link order of "Member natives" (a library before every library
it `needs`). The unit's `key` covers the declaration, not the archive's bytes,
so a build system that caches by `key` adds the archive's digest. A consumer
that depends on the published package gets a prebuilt entry from its lock, as
for any static native. A graph with a provided unit is format 4, which a reader
that does not know `provided` refuses (it would make an empty archive of a unit
with no sources); a format 4 graph has `system_libs` and `loads` exactly when a
format 3 graph would.

## The workspace

Every path in the graph (`root`, the `path` of each source, the file named by a
`test:` unit id) is relative to one directory, the **workspace**, and a path
never contains `..`. By default the workspace is the directory `mopm plan` runs
in, so every member is below the package: a path dependency written `../util`
is refused.

    mopm plan --unit-graph --locked --workspace-root <dir>

makes `<dir>` the workspace, for packages that sit beside their dependencies in
one repository (a repository's `src/` holding a directory per package, each
with `{ path = "../other" }`). `<dir>` is relative to the current directory or
absolute, and must be an existing directory that contains the package's
directory (compared after resolving links). Then:

- the paths in the graph are relative to `<dir>`: a package at `<dir>/src/app`
  with the sibling `<dir>/src/util` has the units' roots `src/app/src/app` and
  `src/util/src/util`, and the package's tests are `src/app/tests/...`;
- every path dependency, at any depth, must be below `<dir>` (its path is
  resolved from the package's directory, as `mopm.lock` records it, whichever
  member names it); one that is not is refused, naming the member and `<dir>`.
  A member two others share, or that is reached through another member, is one
  unit;
- the package's own library, binaries and tests are found in its directory, as
  they are without the flag; a library or binary the manifest points at outside
  the package is refused. Tests of members are not planned;
- the "below `<dir>`" check is lexical: `.` and `..` in the paths of `mopm.toml`
  and `mopm.lock` are resolved as text, and symlinks inside `<dir>` are neither
  followed nor checked. A member that is a symlink pointing outside `<dir>` is
  accepted, as it is without the flag. A refusal shows the path as written and,
  when it differs, the resolved one (`.` for `<dir>` itself);
- a unit's `key` hashes its rendering, so it depends on the path from `<dir>`
  and not on where `<dir>` is on disk: the same repository checked out
  elsewhere gives the same graph.

Without the flag the workspace is the current directory and the output is what
it was before the flag existed. The flag is valid only with `--unit-graph`.

## Exit status of `mopm plan`

| status | meaning |
|---|---|
| 0 | the graph was printed |
| 1 | any other failure |
| 2 | a usage error: `--unit-graph` and `--locked` are both required; `--mojo` is required when `mopm.toml` lists several versions; `--workspace-root` needs a directory and is valid only with `--unit-graph` |
| 3 | there is no usable lock, or it is out of date with `mopm.toml` (a requirement, a path dependency or the Mojo versions changed). Run `mopm lock`; `plan` never repairs |
| 4 | the graph cannot be made from this project and lock: no toolchain pinned for `M`, a lock that does not lock `M` or records another closure, no `.mojoc` for `M`, a native library without sha256, a member outside the workspace or not listing `M`, a missing source, a `--workspace-root` that is not an existing directory or does not contain the package |

A refusal is one line on standard error, `error: <reason>`.

## Running a unit

    mopm unit build --unit <id> --graph <file> --out <dir> --toolchain <dir>
                    [--src <dir>] [--deps <dir>] [--natives <dir>] [--stage <dir>]
                    [--target-cpu <level>]
    mopm unit test  (the same options)

`unit build` builds one `lib`, `test` or `bin` unit. A `native` unit is the build system's to compile and is refused, like a `prebuilt` one. `unit test` builds one
`test` unit and runs the binary; a pass leaves `<test stem>.pass` in `--out`.

| option | the directory holds |
|---|---|
| `--src` (`.`) | the member sources; the graph's `srcs` paths are relative to it |
| `--deps` (`deps`) | `<package>.mojoc` of every unit in the transitive closure of `deps`, flat. A `prebuilt` unit's file is the `.mojoc` unpacked from its `.conda` |
| `--natives` (`natives`) | the native libraries, flat, by `soname`. A prebuilt one is checked against the graph's sha256; a `built` one must exist and begin with `!<arch>` followed by a newline (an `ar` archive), and has no hash to match |
| `--toolchain` | `mojo_compile`, the pinned hermetic wrapper, and `CLOSURE_SHA256`, one line naming the closure it is |
| `--stage` (`<out>.stage`) | scratch: the tree the compiler sees |
| `--out` | the outputs |
| `--target-cpu` (none) | the CPU level, see "Target CPU" below |

Before any program runs, mopm checks every declared input and stops with exit
status 4 and `error: <reason>` on the first that fails: the toolchain's
`CLOSURE_SHA256` is not the graph's `closure_sha256`; `mojo_compile` is
missing; a source is missing or its sha256 is not the graph's; a dependency's
`.mojoc` is missing or empty; a native library is missing or its sha256 is
not the graph's (a built one: missing, or not an archive). A `prebuilt` unit is refused (it is fetched, not built), and
so is `unit test` on a unit that is not a test. Nothing is resolved or
fetched, and nothing but the declared inputs is read.

Then mopm stages the sources and each dependency's `.mojoc` (alone in its own
`-I` directory: a directory given to the compiler holds one `.mojoc`) and
executes `<toolchain>/mojo_compile` with an **empty environment**. mopm does
not set up the compiler: the wrapper owns the closure check, the environment
it builds, zig as `cc`, the runpath rules and the watchdog (exit status 124
when it kills a hung compiler), and mopm passes its exit status on. The
arguments are

    [--runpath=$ORIGIN/lib]  --source-root=<root>  --  <mojo arguments>

- a `lib`: `<root>` is `<stage>/src/<package>`, the package directory, and the command is `precompile -I<dep dir>... <stage>/src/<package> -o <out>/<package>.mojoc`. The wrapper runs the compiler from the parent of the root and names the package by its basename, so the `.mojoc` records `<package>/<file>.mojo` and no staged path: one package staged at two paths gives the same bytes
- a `test` or `bin`: `<root>` is `<stage>/src`, and the command is `build -D ASSERT=<assert> --optimization-level <opt> [-g]
  -I<dep dir>... <stage>/src/<file> -o <out>/<name> [-Xlinker <natives>/<soname>]...`,
  with the shared libraries also copied to `<out>/lib/` beside the binary
  (`--runpath=$ORIGIN/lib`: no absolute path is baked in); a static archive is
  linked into the binary and is not copied. The `-Xlinker` operands are in the
  unit's `natives` order

A native library reaches the linker as `-Xlinker <path>`. The wrapper's `cc` must hand that
operand to the C driver as an input file: zig's own driver refuses a bare operand given to `-Xlinker` ("unsupported
linker arg"), and buildrules' `cc` shim for `mojo_compile` rewrites it into one. On the pinned compiler and zig (tests/drivers/native_static_test.zig) archives are found whatever their
order (lld does not care), and the order of `natives` is kept for a linker that does.

The `precompile` arguments are those the Mojo build rules that run this
compiler use. The `build` arguments (`-D ASSERT`, `--optimization-level`,
`-Xlinker`) are what `mopm test` and `mopm build` already pass; mopm has not run
them through this wrapper against a real Mojo.

`unit test` runs the binary it built with an environment that holds one
variable, `LD_LIBRARY_PATH=<toolchain>/lib`, when `--toolchain` has a `lib/`
directory, and nothing else: no `HOME`, no `PATH`, nothing of the host's. That
directory is where the compiler's runtime (`libKGENCompilerRTShared.so`) is,
a part of the closure `CLOSURE_SHA256` names, so a test that needs the runtime
can load it and the run still reads only declared inputs. With no `lib/` the
environment is empty. (`unit build` runs only the wrapper, with an empty
environment: the wrapper makes the compiler's own.)

When the wrapper exits 0, the output must exist and not be empty, or the unit
fails. Not done yet: the test supervisor (`mopm test` runs each test file under
timeouts and a group kill; `unit test` runs the binary directly), coverage, and
ISA levels in the graph's profile (the level is an option of the command, below). A workspace member's own native libraries (`[native.<id>]`) are in the graph as `native` units that the build system builds ("Member natives"); mopm does not compile C.

## Target CPU

    mopm unit build ... --target-cpu <level>
    mopm unit test  ... --target-cpu <level>

The level is the CPU a test or binary is compiled for. The caller gives it;
mopm does not read it from the graph, a profile or the environment, and does
not default it. mopm maps it to the compiler's option and nothing else:

| level | passed to `mojo build` |
|---|---|
| `x86-64` | `--target-cpu x86-64` |
| `x86-64-v2` | `--target-cpu x86-64-v2` |
| `x86-64-v3` | `--target-cpu x86-64-v3` |
| `x86-64-v4` | `--target-cpu x86-64-v4` |
| `armv8.0-a` .. `armv8.4-a` | refused: no verified Mojo spelling |
| no `--target-cpu` | no CPU argument: the compiler's own default |

The two arguments are placed right after `build`. Any other value, and an Arm
level, is a usage error (exit status 2, `mopm unit: <reason>` on standard
error) before any input is read or program run. An Arm level is named in the
refusal so the caller can tell "not supported yet" from "misspelt"; it is
accepted the day its spelling has been run against `mojo build`, not before.
(`x86-64` is the lowest x86 level, called v1 elsewhere.)

A `lib` unit gets no CPU argument at any level, because `mojo precompile`
rejects the option and a `.mojoc` holds no machine code: the same library
bytes serve every level, and the level is accepted and ignored for a `lib`.
Only a `test` or `bin` unit, which generates code, differs by level.

**Identity.** The level is not in the unit graph and mopm writes no manifest of
the outputs, so the level is part of the output identity only if the caller
puts it in its cache key. It must: the same unit at two levels is two different
binaries, and nothing in the unit's declared inputs tells them apart. In a Buck2
build the level is an argument of the action, so it is in the action key and in
the output path of the configuration that chose it. We did not add it to the
graph because the graph describes what a unit reads and is meant to be the same
for every level (a `lib` and its key do not change), and we did not write a
manifest because the outputs are the files the graph names, and a new file
would change the set that a caller declares and verifies. A caller that
does not pass the level through its key will reuse a v1 binary for a v3 request.
