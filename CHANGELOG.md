# Changelog

User-visible changes, newest first. Releases are cut automatically (RELEASING.md); the notes of a GitHub release list its files and
checksums, and this file says what changed. The details of a command are on its page of the documentation.

## Unreleased

### A package version can carry one build for each Mojo version; builds for other Mojo versions can be added to a published version

Additive: the index record, the API's `VersionDetail` and the package metadata gain optional keys, `plan.json` stays version 2, and `index_version`, `v` and `lock_version` do not change; a mopm before this one reads the same record as before. A version now has one or more builds, one for each Mojo compiler (build string `mojo<compiler>_0`, `mojo-compiler ==<compiler>` in `depends`), and its primary build is the one with the lowest compiler. A sparse-index record (`/index/v2/...`) has a new key `builds`, every build of the version sorted by compiler, each with `build`, `requires_mojo` and `files`; the top-level `build`, `requires_mojo` and `files` keep their meaning and are the primary build, so a reader that does not know `builds` sees that build only (the released mopm, which pins Mojo 1.0.0, resolves a version with a 1.0.0 build as before and, for a version without one, stops with its existing `has no .mojoc for Mojo 1.0.0 (published for: <primary>)`). The `getVersion` answer of `/api/v2` has the same list as `builds` (field 23, `VersionBuild`); `/api/v1` is unchanged. The registry creates each file once and never replaces it; a new version may be published with several builds at once, and a build for another Mojo can be added to a published version (not a yanked or taken-down one), one build for each publish or group member, when it is built from the same source: every archive of a version has the same `<import>.mopm.json` bytes and the same `depends` apart from `mojo-compiler`, and an added build's metadata must carry `source_sha256`, which `mopm pack`, `publish` and `stage` now write (a digest of the package's `mopm.toml`, library files and program sources, defined in `spec/channel.md`). A version published before this change has no `source_sha256` and takes no added build. An added build has no state of its own (yank, unyank and takedown act on the whole version), and a rejected add burns that build of that version. `mopm stage --artifacts <mojo>=<dir>`, repeated once for each compiler, stages several builds of a version in one run; for a version the registry already has, `stage` makes an `upload` member of the one build it lacks, and refuses a replaced file, a build from other sources and more than one new build. `mopm publish --staged` sends that member like any other, and `mopm publish --compiler <v>` to a published version adds that build. `mopm lock` takes, for each Mojo the project lists, the newest in-range version that has a build for that Mojo, and the no-build error lists every build of the version (`published for: 1.0.0, 1.2.0`). See `spec/channel.md`, `spec/index.md`, `spec/staged-set.md` and `docs/publishing-a-workspace.md`.

### The registry commands are generated from the API contract; `yank --group` is `group yank`, `org add --owner` is `--role owner`

Not additive for three commands. Every operation of the registry's API (`spec/api/mopm/registry/v2/registry.proto`) except the website's sign-in and tutorial operations now has a generated command that makes one call of it: `mopm health`, `whoami`, `token create|list|revoke`, `namespace info`, `org add|remove|list`, `search`, `package info|create|versions|version`, `publish status`, `group status|abort|yank|unyank`, `yank` and `unyank`; `mopm --help` lists them, and `mopm <command> --help` prints the flags and the registry's description of the operation. A generated command takes the same `--registry`, `--config-dir` and `--json`; a refusal prints the registry's message, its `code`, a `hint`, `retry after` and `request id`. What changes: `mopm whoami` prints the registry's answer as `key: value` lines (the handle, the GitHub id and each namespace with its kind, role and packages) instead of the former sentence, and `--json` prints it as JSON; `mopm org add <org> <user> --owner` is `mopm org add <org> <user> --role owner` (`--role member` is the default); `mopm yank --group <id> --reason <text>` is `mopm group yank <group_id> --reason <text>`, `--unyank` is `mopm group unyank <group_id>`, and neither waits any more: they print the group the registry answers with at once, and `mopm group status <group_id>` shows its yank (`--wait` is gone). Like every generated command they take `--registry` with the default `prod` (the old `yank --group` had no default), and a yank without `--reason` is refused by the registry, not before the request. `mopm login`, `logout`, `org create`, `pack`, `publish` and `stage` stay as they are.

### `mopm login` stores your namespace; `whoami` lists your namespaces; `new` and `init` default to it

Additive for the files (`credentials.json` gains an optional `namespace` per registry, which older readers ignore); the output of `whoami` changes. After the device login is approved, `mopm login` asks the registry `GET <api_v2_url>/me` and stores the user namespace (the one of kind `user` equal to the handle in lower case, else the first of kind `user`), then prints `Logged in to <registry> as <handle>; your namespace is <namespace>.` If the GitHub login cannot be a namespace (another account holds it, it is reserved, or it is not valid) it says so and stores none; if `/me` fails, the token is stored all the same and mopm prints `mopm: could not read your namespace from <registry>; 'mopm whoami' shows it`. `mopm whoami` prints `<handle> (GitHub id <id>) on <registry>`, then `namespaces:` and one line for each, `  <namespace> (<kind>, <role>): <full names>`, and the line about an unavailable login. `mopm new` and `mopm init` take `--registry` and `--config-dir`; a bare name becomes `<stored namespace>/<name>` (a full name works offline and reads nothing; a bare name fetches the registry's `config.json` only when some login stored a namespace). With no stored namespace a bare name is refused: `mopm new json needs a namespace: run 'mopm login' (your GitHub login is your namespace) or name it, as in 'mopm new <your login>/json'` (for `init`, `as in 'mopm init --name <your login>/<name>'`). See [getting started](docs/getting-started.md) and [configuration](docs/configuration.md).

### `mopm org create | add | remove | list` manage an organization's namespace

Additive: new commands and new `/api/v2` operations. `mopm org create <org>` registers the GitHub organization's login as a namespace: it prints `To register the GitHub organization <org> on <registry>, open <url> and enter the code <code>`, waits for the GitHub device approval (scope `read:org`, asked for this step only, the token discarded), and prints `Registered <org> on <registry> (GitHub organization id <id>); you are its owner.` The approving account must be the logged-in one and an active admin of the organization. `mopm org add <org> <user> [--owner]`, `remove <org> <user>` and `list <org>` manage the members by mopm username; a write in the namespace checks only the registry's member table, so a removed member is refused at once. The login asks `read:user` only, and `whoami` roles are `owner` and `member`. See [getting started](docs/getting-started.md).

### `mopm add` of a bare name suggests full names; `[package] name` refusals name your namespace

`mopm add json` is refused as before, and the message now lists the packages named `json` on the registry (`GET <api_v2_url>/packages?q=json&limit=100`, up to 5 whose name part is exactly `json`): `dependency 'json' has no namespace: write it as <namespace>/json; packages named json on prod: komira-ai/json, alice/json (as in 'mopm add komira-ai/json')`, or `...; no package on prod is named json`. When the registry cannot be read the message is the old one. mopm never adds a suggestion. `lock`, `update`, `sync`, `tree`, `add` and `remove` refuse a bare `[package]` name with the stored namespace: `package name 'json' has no namespace: write name = "alice/json" (alice is your namespace), or another namespace you publish in`.

### `mopm publish` creates the package; `mopm stage --artifacts` reads `<subdir>/<namespace>/<name>.mojoc`

Not additive for `stage`: the old artifact layout is not read. `mopm publish` sends `PUT <api_v2_url>/packages/<namespace>/<name>` with no body after the token is read and before any upload; a 201 prints `created <full name> on <registry>`, a 200 prints nothing, and any other answer ends the run with exit status 1 (`--dry-run` sends nothing). `mopm publish --staged` does the same for each member it uploads, in plan order, before it creates a new group; a run that resumes a group sends none. `mopm stage --artifacts <dir>` reads `<dir>/<subdir>/<namespace>/<name>.mojoc` and `<dir>/<subdir>/<namespace>/<name>.native/lib<id>.a` (it read `<dir>/<subdir>/<import name>.mojoc` before); a member with no file is refused with `<full name> has no build artifact: expected <dir>/<subdir>/<namespace>/<name>.mojoc for one of noarch, linux-64, linux-aarch64, osx-arm64`. See [publishing a workspace](docs/publishing-a-workspace.md).

### The index, the lock, the channel, package metadata, the unit graph and the staged set name packages by full name

Not additive: every format below changes version, so a mopm before this one refuses what this one writes, and this one refuses what an older one wrote, each with a message. A registry must serve index version 2: `config.json` lists it in `index_versions` beside `api_v2_url`, and mopm refuses a registry without it (`the registry at <url> serves no namespaced packages (index version 2); it is older than this mopm`). mopm reads `/index/v2/<aa>/<bb>/<namespace>/<name>` (`aa`, `bb` from the namespace), whose records are `"v": 2` with full names. Each namespace is its own conda channel, `<channel_url><namespace>/`, and a package's conda name is `mojo-<namespace>.<name>` (`komira-ai/json` is `mojo-komira-ai.json`, the file `mojo-komira-ai.json-0.1.0-mojo1.0.0_0.conda`); inside it the files keep the import name, `lib/mojo/json.mojoc` and `lib/mojo/json.mopm.json`, whose `schema` is 2 with full names. `mopm.lock` is `lock_version` 3: the shape of version 2 (a `mojo` list, `toolchain` closures, `artifacts` per Mojo version) for every project, full names sorted as bytes, each entry's `channel` a listed root followed by its namespace, and no two entries with one import name; a locked Mojo version that mopm pins no toolchain for has no `toolchain` entry, which lock 3 accepts. A lock of version 1 or 2 is rewritten by `mopm lock` (and `update`, `add`, `remove` and `sync` without `--locked`); `sync --locked`, `tree`, `plan`, `build` and `test` refuse it with `mopm.lock predates namespaces (lock_version <n>); run 'mopm lock'`. The unit graph is format 6: unit ids carry the full name (`komira-ai/json@0.1.0#mojo1.0.0/lib`, `native:komira-ai/json/<id>`), `package` is the full name and a new `import` field the import name; `mopm unit` reads format 6 only. The staged set's `plan.json` is version 2 with full names; a version 1 set is refused, naming the file: stage it again. Every request that names a package (publish, the staged set's groups, its yank, the CI identity exchange) goes to `api_v2_url` with `/packages/<namespace>/<name>/...`; login, `whoami` and tokens still use `api_url`. See [the index](spec/index.md), [the channel](spec/channel.md), [the lock](spec/lock.md), [the unit graph](spec/unit-graph.md) and [the staged set](spec/staged-set.md).

### Package names in `mopm.toml` are full names, `<namespace>/<name>`

Not additive: a `mopm.toml` accepted before is refused now. `[package] name` and every key of `[dependencies]` and `[dev-dependencies]` is a full name such as `komira-ai/json`: a namespace (a GitHub login in lower case, 1 to 39 characters) and the name, which is what Mojo code imports (`import json`). A key holding `/` is quoted: `"komira-ai/json" = "0.1"`. A name without a namespace is refused with the full form in the message (`dependency 'json' has no namespace: write it "<namespace>/json" = "0.1"`); an upper-case name is refused with its lower-case spelling; reserved namespaces (the shape of a conda subdir, `index`, `quarantine`, `native-mirror`) are refused. The import name of a package may not be a top-level module of the Mojo standard library (`collections`, `memory`, `os`, `hashlib` and the rest, read from the pinned toolchain into `toolchain/mojo-<version>.std-modules.txt`; a dependency key with such a name is read with a warning), nor `mopm`, `mojo`, `max`, `modular`, `std` or `stdlib`, besides Mojo's keywords and builtins as before, and is 2 to 64 characters. `[targets] lib` must end in the import name (Mojo imports a package by its directory's name). A path dependency's key must be the full name at the path, and `mopm stage` refuses two members of one workspace with the same import name. `mopm new` and `mopm init` take a full name (`mopm new komira-ai/json` makes the directory `json`), and so do `mopm add` and `mopm remove`. `mopm metadata` prints full names. See [mopm.toml](spec/mopm-toml.md), "Names", and `docs/design/namespaces.md`.

### Two packages with one import name in a closure are refused, with their dependency paths

Not additive: a closure accepted before can be refused now. Mojo imports a package by the part of its name after `/`, so a closure (the root, its `[dependencies]` and `[dev-dependencies]`, and the `[dependencies]` of every path and registry package, at any depth) may hold one package per import name. `mopm lock` (and `update`, `add`, `remove`) refuses a closure with two, before writing anything (exit 1); so does every command that reads the project (`tree`, `sync`, `plan`, `build`) for the clashes its manifests show, `tree` and `sync` for the lock they read, and `mopm plan` when it makes the unit graph. The error lists every clashing import name and, for each package that has it, the shortest dependency path from the root, `(dev)` on a path that starts in `[dev-dependencies]`. There is no rename. This replaces the shorter refusal of two path dependencies with one import name. See [mopm.toml](spec/mopm-toml.md), "Rules".

### `mopm sync` installs the environment itself: no pixi

`mopm sync` no longer writes a pixi project or runs pixi, and needs nothing but mopm. It downloads each locked package of the host's platform and each file of the pinned Mojo toolchain of the lock's Mojo version (`mojo`, `mojo-compiler` and every package they need, each with its sha256 and size, built into mopm), refuses any file whose size or sha256 is not the pinned one, unpacks them all into a temporary directory beside `.mopm/env` and renames it into place: if anything fails, the environment that was there stays. The environment is `.mopm/env` (it was `.mopm/.pixi/envs/default`), and `mopm build`, `run`, `repl` and `test` use it when no `--prefix`, `CONDA_PREFIX` or `MODULAR_HOME` names another. A second sync with the same lock finds the environment current and downloads nothing. Locked files are kept in `.mopm/pkgs`; the toolchain's in `--cache <dir>` (default `$XDG_CACHE_HOME/mopm/pkgs`, else `~/.cache/mopm/pkgs`). `--toolchain <file>` names another toolchain closure file (a mirror: the same files at other URLs). `--pixi` is removed. A locked package whose conda name is a toolchain package's is refused. Sync no longer reads the channel's repodata to check the lock against it (the lock's sha256 and size are the pin), so a yanked locked version installs without the warning it printed before. The lock's system libraries for the host's platform are installed too (a library the lock pins that the toolchain also holds replaces it, with a warning, when the bytes differ). Only one sync runs in a project at a time: a second prints that it is waiting for `.mopm/sync.lock` and continues afterwards. The toolchain's and the libraries' files are kept in the cache as `<cache>/<sha256>/<file>`, and `--cache` inside `.mopm/env` is refused before anything changes. The environment's stamp now includes the project's absolute path, so a moved project, and an environment made by an earlier mopm, are installed again once; an environment with a matching stamp that is missing a file or whose package no longer matches is installed again, with a message saying why. A version 2 lock that records a toolchain closure for its Mojo and platform refuses a sync whose closure differs, before any download. The new environment is checked before it replaces the old one, and a sync interrupted between the two renames is repaired by the next. See `docs/design/native-sync.md`. A project synced by an earlier mopm keeps its `.mopm/.pixi`, `.mopm/channel` and `.mopm/pixi.toml`, which nothing reads any more; delete them to reclaim the space.

### A group's readmes travel as uploaded objects, so the commit request no longer grows with them

Additive. `GET /health` has an optional `features` list, and a registry that serves `group_readme_objects` takes a member's readme in `POST /groups` as `{sha256, size}` (not part of the group id), answers where to PUT it, and accepts it in `POST /groups/{id}/commit` as `{sha256, size}` instead of the text. The registry reads the object, refuses a missing one or one whose bytes differ (`upload_invalid`, naming the member) and text that is not UTF-8 (`invalid_request`), and stores the same readme as an inline one would. `mopm publish --staged` reads `/health` (no token) on every run when a member has a readme, and uses objects when the registry lists the feature; against a registry that does not, it sends the readmes inline and refuses a set over the commit size limit as before, saying that the registry does not take readme objects. The form is chosen again on every run (a run that resumes a group defers the refusal until the group is found open, and one whose commit was sent reads no `/health`), and `plan.json` and `state.json` are unchanged. `mopm stage` reads `/health` only when the inline commit body would be over the limit, to learn whether the refusal stands, and writes the same plan either way; it does not choose or store a form. A registry from before the feature refuses a readme object in a commit with `invalid_request` and leaves the group open. See the [staged set](spec/staged-set.md) and [publishing a workspace](docs/publishing-a-workspace.md).

### `[native.<id>] link`: the system libraries a static native's consumers link

Additive: a manifest without the key behaves as before. `link = ["c++"]` on a `kind = "static"`, `mode = "link"` native (with or without `provided = true`) names the system libraries the final link of any consumer must add, so a package whose archive holds C++ links libc++ in every consumer. The names are `c++`, `dl`, `m` and `pthread` (a closed list), none twice. `mopm pack`, `publish` and `stage` write the key into `<name>.mopm.json`, `mopm lock` copies it into the lock, and `mopm build` adds `-l<name>` once, at the end of the link, after every archive, however many natives name it, in the order `c++`, `dl`, `m`, `pthread`. `mopm plan --unit-graph` gives each unit that links archives a `link` list of the same names, and a graph that has one says `"unit_graph": 5`; `mopm unit` reads formats 2 to 5. A `mopm` that predates the key ignores it in the metadata and the lock (the link then fails on undefined symbols) and refuses a format 5 graph. See [mopm.toml](spec/mopm-toml.md) and the [unit graph](spec/unit-graph.md), "System libraries of a native".

### `[native.<id>] provided = true`: a static native whose archive another build produces

Additive: a manifest without the key behaves as before. `[native.<id>]` with `kind = "static"` and `provided = true` and no `srcs` declares a library that mopm does not compile: a build system's own rule builds the archive and packs it as `lib<id>.a`, and `mopm pack`, `mopm publish` and `mopm stage` pack it as they pack any static native (`--native`, or `<name>.native/lib<id>.a`). With `provided = true`, `srcs`, `hdrs`, `cflags`, `cflags_by_os`, `includes`, `build` and `outputs` are refused (each names the contradiction), and so is any `kind` but `"static"` and any `mode` but `"link"`; `needs`, `exclusive` and `soname` still apply. `mopm plan --unit-graph` lists the library as a `native` unit with `"provided": true` and no sources, and the units that link it list it as built, in link order; a graph that has one says `"unit_graph": 4`, and `mopm unit` reads formats 2, 3 and 4. The lock is unchanged: a consumer's `mopm lock` pins the published archive as for any static native. See [mopm.toml](spec/mopm-toml.md) and the [unit graph](spec/unit-graph.md), "Provided natives".

### The registry accepts any conda-forge package under `[native-dependencies]`

The registry no longer keeps a fixed list of the native libraries a package may name in `depends` (`lz4-c`, `zstd`, `liblzma` and the rest). A package that names any conda package is accepted, and `xz` and `liblzma` are two such names. The only refusal is malformed text: a name that is not a conda name (lower-case letters, digits, `.`, `_` and `-`), a requirement with more than a version and a build string, a version or build with characters outside conda's, or `mojo-` alone; the rejection code is the existing `dependency_not_allowed`. A name that conda-forge does not list is accepted with a warning that names it (a typo is likely; a package newer than the registry's copy is possible), and so is every native name when the registry's copy of conda-forge's names is more than a day old or cannot be read. The warnings are in the new optional `warnings` list of `GET /publishes/{id}` and `mopm publish` prints them to standard error when the publish finishes; a `mopm` that predates the field ignores it. A group publish keeps its warnings in the registry's log for now. See the design in `docs/design/any-conda-forge-native.md`.

### `lzma` and `xz` are the conda package `liblzma`

A native dependency named `lzma`, `xz`, `liblzma` or `liblzma.so.5` is now recorded in `depends` as `liblzma`, the conda-forge package that holds the runtime library, and the pinned native catalog pins `liblzma` instead of `xz`. conda-forge's `xz` is a metapackage whose closure (`xz-tools`, `xz-gpl-tools`, `liblzma-devel`) holds no library a program can load, so a test that unpacked every pinned system library was refused. A package already published with `xz` in its `depends` is still accepted by the registry; a package packed with this mopm names `liblzma` instead, so its `depends` differs from before for these libraries only. Nothing else in the catalog changes: every other pinned package was checked for a runtime shared library and for links that stay inside the package, and a test now holds both. See [configuration](docs/configuration.md), "Native libraries".

### `mopm whoami` works against the hosted registry

`GET /api/v1/me` (the operation `mopm whoami` calls) is now served: it answers the account behind a session or an API token with its GitHub id, handle and the packages it owns, and `pending_invitations` is always 0 because invitations are not served yet. A CI token is refused as `scope_missing`. Before this, the hosted registry answered `route_not_found` and only the registry that `mopm` runs against in tests served it.

### `[package] publish = false` keeps a workspace member out of publishing

Additive: a manifest without the key behaves as before. A package with `publish = false` (a test-support helper that other members use by `path`) is left out by `mopm stage` when no package is named, with one line saying so, and refused by `mopm stage <name>`, `mopm pack` and `mopm publish`. A package that is published may not have one in its `[dependencies]`; its `[dev-dependencies]` may. Every other command reads it like any package. A value that is not `true` or `false` is refused, naming the key. See [configuration](docs/configuration.md) and [publishing a workspace](docs/publishing-a-workspace.md).

### One exchange covers up to 500 packages, and an account's daily claim limit can be raised

`POST /auth/oidc/exchange` takes up to 500 entries in `packages` (it was 100), the most members a group may have, and `mopm publish --staged --oidc` sends a set of up to 500 members (it refused more than 100 before any request). The registry looks the names up and creates the missing ones sixteen at a time, and the answers and refusals are those of one at a time (the first failing name in the request is the one named). A request of 501 names is still `invalid_request`. The body of the exchange may be up to 128 KiB (the other auth routes keep 64 KiB), so a set of 500 names and versions of the longest length is not refused for its size. The registry that `mopm` runs against in tests takes 500 as well. A claim (`POST /packages/{name}/claim`) is still limited to 50 a UTC day for an account and for a token; the operator of a registry can set a higher daily limit (at most 1000) for named accounts without a deploy. Nothing changes for an account without that setting.

### A package can publish programs, and `mopm run --bin` runs one

Additive. A package lists programs in `[targets] bins`; `mopm pack`, `mopm publish` and `mopm stage` now put the source of each (the `.mojo` file the entry names) in the package at `lib/mojo/<package>.bins/<name>.mojo`, and refuse a name that is not lower case letters, digits and underscores, a name listed twice, a path outside the package directory or not ending in `.mojo`, and an unreadable or empty file. No executable is packed: the registry still refuses `bin/`, and the program is built by the Mojo of the machine that runs it. The registry's validators (TypeScript and Rust) accept exactly those paths and no other file below `lib/mojo/<package>.bins/`. `mopm run --bin <package>:<program>` runs the program of an installed package with the environment's packages importable; it refuses a package that is not installed and a program the package does not ship. A package with no `bins` packs to the same bytes as before. See [configuration](docs/configuration.md), "Programs in a published package".

### `mopm lock` pins the system libraries a project loads, and `mopm plan` passes them on

Additive: a project that loads no system library gets the lock and the unit graph it always got, byte for byte. When a `mopm.toml` of the project (or of a path dependency), or a registry package it uses, declares `[native-dependencies] <name> = { mode = "load" }`, `mopm lock` now adds a `system_libs` key to `mopm.lock`: for each platform, the conda packages of those libraries and of what they need to run (url, sha256, size), taken from the catalog this mopm pins, and a `loads` list on each registry package that loads one. `lock_version` does not change, and an older mopm ignores both keys. A version requirement is checked against the pin (`mopm pins libsqlite 3.51.0 for linux-64; requirement ">=4" cannot be met; update mopm`), and a name outside the catalog is refused. `mopm plan --unit-graph` gives each `test` and `bin` unit the `loads` of its closure and the graph a `system_libs` list, as unit graph format 3; a graph with no `loads` stays format 2. A lock that has `system_libs` while a manifest names a library it lacks is stale: `mopm lock` fixes it. `mopm unit test` refuses a unit that has `loads`, as it cannot put the libraries on the loader path. See [`spec/lock.md`](spec/lock.md) and [`spec/unit-graph.md`](spec/unit-graph.md).

### The registry has a `stage` token scope and a `stage` purpose for the CI exchange

Additive: every token and request that worked keeps working as it did, but for an unknown `purpose`, below. A token with the new scope `stage` may create, read and abort a group, and
nothing else: committing a group, publishing a single version and yanking (a version or a group) are refused as `scope_missing`, whatever else the
token holds. `POST /auth/oidc/exchange` takes an optional `purpose` (`publish`, the default, or `stage`); `stage` mints the same token for the same
packages and versions with the one scope `stage`, and answers `token_kind` `stage`. Any other `purpose` is `invalid_request`. Who may mint a
publish token is unchanged. A claim (`POST /packages/{name}/claim`) is refused as `scope_missing` for an API token whose only scope is `stage`; a token
with `publish` or `yank`, and a session, claim as before. One request that used to work now fails: an exchange body that carries a `purpose` other
than `publish` or `stage` (nothing sends the field today). `mopm` does not ask for a stage token yet. See `spec/api/openapi.yaml` and [staged sets](spec/staged-set.md).

### The registry shows a group's files, names a version's group, and takes a commit without `manifest_sha256`

All three are additive. `GET /groups/{id}` lists each member's declared `files` (`subdir`, `filename`, `sha256`, `size`), and, while the group is
`open`, whether each file is in storage (`uploaded`); the read creates, reopens and charges nothing, and access is unchanged (a group that is not
yours is still `group_not_found`). The derivation of a group id is now documented and pinned by test vectors, so a client can compute the id and
read the group without a local record. `GET /packages/{name}/{version}` carries `group_id` for a version a group published. `manifest_sha256` is
optional in the commit of a single publish and of each member of a group: given, it is checked as before; absent, the version holds the hash the
registry computes from the archive. `mopm` still sends it. See `spec/api/openapi.yaml` and [staged sets](spec/staged-set.md).

### The registry says why a group could not be created

A `group_conflict` answer now carries an optional `error.reason` (`number_held`, `group_failed`, `open_cap`, `supersede_cap`, `takeover_blocked`,
`number_taken` or `overlap_refused`), so a client can tell the causes apart without reading the message; a client treats a reason it does not
know as none. `POST /groups` takes an optional `on_overlap` (`supersede`, the default and today's behaviour, or `refuse`), and its answer lists
the groups it superseded in `superseded`. `mopm` reads the reason and prints what it printed before. See `spec/api/openapi.yaml` and
[staged sets](spec/staged-set.md).

### `mopm build` builds the package; path dependencies are importable; the macOS 14 REPL works

`mopm build` with no program builds what `[targets]` of `mopm.toml` declares, with the `mojo` of the environment: the library as
`target/build/<package name>.mojoc` (`mojo precompile`, the file `mopm pack --mojoc` takes) and each program as `target/build/<name>`,
linked as `mopm build <file>` links. `--out-dir <dir>` changes the directory and `--print-cmd` prints the commands. `mopm build`, with or
without a program, now passes `-I` for the path dependencies of the package (and their path dependencies), so `from dep import f`
finds a dependency written `{ path = "../dep" }`. On macOS 14 and older `mopm repl` sets `LLDB_DEBUGSERVER_PATH` to Xcode's debugserver,
because the one packaged with Mojo crashes there; `mopm repl --debugserver <path>` names one. `mopm new` now ignores `/target/`. See
[getting started](docs/getting-started.md).

### `mopm stage` packs native libraries

`mopm stage` no longer refuses a member that declares `[native.<id>]` libraries. It reads each static archive from
`<artifacts>/<subdir>/<name>.native/lib<id>.a` (beside the member's `.mojoc`) and packs it exactly as `mopm pack --native` does, so the
staged `.conda` is the one `pack` makes from the same files. A missing archive, or one that is not an `ar` archive, is refused with the
member named. See [Publishing a workspace as one group](docs/publishing-a-workspace.md).

### The registry records the source commit of a version

A commit may now carry `source_commit`, the git commit id the version was built from: 40 or 64 lowercase hex digits, in the commit of a single
publish and in each member of a group commit. The registry stores it once with the version and `GET /packages/{name}/{version}` returns it as
`source_commit`; a version committed without one, including every version published before this, has none. It is informational: the registry
checks the form and nothing else, does not verify it against the archive, the repository or the caller, and never compares or orders versions by
it. Any other value is `invalid_request`. A repeated group commit must repeat each member's value (otherwise it is another request,
`group_commit_refused`), and a repeated single commit that states another value is refused `version_exists`. The change is additive; `mopm` does
not send the field yet.

The specification no longer lists an embedded `manifest` on `VersionDetail`: the registry never served one. `GET /packages/{name}/{version}`
is unchanged. See `spec/api/openapi.yaml` and [staged sets](spec/staged-set.md).

### Claiming a package name

The registry service now answers `POST /packages/{name}/claim`, the operation the API contract has always described: a signed-in
account reserves a free name and becomes its owner. The answer carries `claim_expires_at`, 30 days out, the time after which a
claim with no published version lapses (the service does not free such a name yet). Reserved names (`name_reserved`), taken names (`name_taken`) and names that differ from an existing one only by
underscores or a trailing `s` (`name_too_similar`, overridden by `{"confirm_similar": true}`) are refused. A CI identity token cannot
claim. A claim is limited to 50 a day per account and 50 a day per token (`rate_limited`, with `Retry-After`). No CLI command changes.

### Publishing from GitHub Actions without a token

`mopm publish --oidc` (and `mopm publish --staged ... --oidc`) takes the registry token from the identity of the GitHub Actions job that runs
it, so no token has to be stored as a secret: inside a job with `permissions: id-token: write`, mopm asks GitHub for an identity token with
the registry's audience (`beta.mopm.dev` for `beta`), exchanges it at the registry for a token that can publish the one package version, and
keeps that token in memory only. Outside such a job the command stops before any request. The registry decides which repositories may
publish a package. See the section "Publishing from GitHub Actions without a token" of
[Publishing a workspace as one group](docs/publishing-a-workspace.md).

### Packing native dependencies to load

`mopm pack`, `mopm publish` and `mopm stage` no longer refuse a `[native-dependencies]` entry with `mode = "load"`: a package that opens a
system library at run time (such as `lz4 = { version = ">=1.9.3", mode = "load" }`) now lists the conda package that provides it in
`depends`, so installing the package installs the library. An entry with `mode = "link"` or `kind = "static"` is still refused, with a
message that says which. See [configuration](docs/configuration.md).

### Group publish (dark)

Publishing a workspace as one group: the registry validates every member before anything is visible, and the members appear in its API
together or not at all. The service side is deployed and switched off on `beta`, `gamma` and `prod`; until an operator enables it for an
account, `mopm publish --staged` stops before it uploads anything and says that the registry has no group publish. Publishing one package
with `mopm publish` is unchanged. See [Publishing a workspace as one group](docs/publishing-a-workspace.md).

- `mopm stage --workspace-root <dir> [<package>...] --artifacts <dir> --compiler <mojo version> --out <dir> --registry <prod|gamma|beta|url>`
  packs the members of a workspace in dependency order and checks each version against the registry. It reads no token and writes
  nothing to the registry.
- `mopm publish --staged <dir> --registry <prod|gamma|beta|url> [--config-dir <dir>] [--wait <seconds>] [--timeout <seconds>] [--retries <n>] [--dry-run] [--oidc] [--no-commit | --abort]` publishes a staged set
  through one group. `--no-commit` uploads every file and stops with the group open (exit 0, outcome `staged`, nothing readable);
  the same command without it, in the same directory, commits that group, and `--abort` ends it. A rerun after a failure resumes the same group (`state.json`); `report.json` says what each member came to; a 429
  that names a long wait stops the run and is never retried into the limit. Every request has a time limit (`--timeout`, 30 seconds
  by default, for the connection and then for the server on any read or write), and a PUT or a poll that fails on the connection, times
  out or is answered 500, 502, 503 or 504 is repeated up to `--retries` times (3 by default) with jittered waits; any other 4xx is final.
- `mopm yank --group <id> --registry <prod|gamma|beta|url> --reason <text> [--config-dir <dir>] [--wait <seconds>]` yanks every version a group published, and `--unyank` restores
  the ones that yank changed.

The readmes of a group's members travel in the body of its commit request, and the registry's function takes a request of
at most 6 MiB with the body escaped into it. mopm holds that body to its own cutoff, a little under the limit and counted
conservatively, and refuses a set over it, naming the largest readmes: `mopm stage` after asking the registry about the
members and before it writes anything, and `mopm publish --staged` (with `--dry-run` or `--no-commit` too) before it sends
any request. The commit sends the readmes as that check read them.

Two things to know. The command line reads the registry's files, which are released in steps after the commit, so an install that runs
during the release of a group can see some of its members (dependencies first); the API shows all or none. And a group yank is not one
flip: members are yanked one by one, and only a group that is `visible` can be yanked.
