# Changelog

User-visible changes, newest first. Releases are cut automatically (RELEASING.md); the notes of a GitHub release list its files and
checksums, and this file says what changed. The details of a command are on its page of the documentation.

## Unreleased

### A package can publish programs, and `mopm run --bin` runs one

Additive. A package lists programs in `[targets] bins`; `mopm pack`, `mopm publish` and `mopm stage` now put the source of each (the `.mojo` file the entry names) in the package at `lib/mojo/<package>.bins/<name>.mojo`, and refuse a name that is not lower case letters, digits and underscores, a name listed twice, a path outside the package directory or not ending in `.mojo`, and an unreadable or empty file. No executable is packed: the registry still refuses `bin/`, and the program is built by the Mojo of the machine that runs it. The registry's validators (TypeScript and Rust) accept exactly those paths and no other file below `lib/mojo/<package>.bins/`. `mopm run --bin <package>:<program>` runs the program of an installed package with the environment's packages importable; it refuses a package that is not installed and a program the package does not ship. A package with no `bins` packs to the same bytes as before. See [configuration](docs/configuration.md), "Programs in a published package".

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

Two things to know. The command line reads the registry's files, which are released in steps after the commit, so an install that runs
during the release of a group can see some of its members (dependencies first); the API shows all or none. And a group yank is not one
flip: members are yanked one by one, and only a group that is `visible` can be yanked.
