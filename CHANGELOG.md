# Changelog

User-visible changes, newest first. Releases are cut automatically (RELEASING.md); the notes of a GitHub release list its files and
checksums, and this file says what changed. The details of a command are on its page of the documentation.

## Unreleased

### `mopm stage` packs native libraries

`mopm stage` no longer refuses a member that declares `[native.<id>]` libraries. It reads each static archive from
`<artifacts>/<subdir>/<name>.native/lib<id>.a` (beside the member's `.mojoc`) and packs it exactly as `mopm pack --native` does, so the
staged `.conda` is the one `pack` makes from the same files. A missing archive, or one that is not an `ar` archive, is refused with the
member named. See [Publishing a workspace as one group](docs/publishing-a-workspace.md).

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
- `mopm publish --staged <dir> --registry <prod|gamma|beta|url> [--config-dir <dir>] [--wait <seconds>] [--timeout <seconds>] [--retries <n>] [--dry-run] [--oidc]` publishes a staged set
  through one group. A rerun after a failure resumes the same group (`state.json`); `report.json` says what each member came to; a 429
  that names a long wait stops the run and is never retried into the limit. Every request has a time limit (`--timeout`, 30 seconds
  by default, for the connection and then for the server on any read or write), and a PUT or a poll that fails on the connection, times
  out or is answered 500, 502, 503 or 504 is repeated up to `--retries` times (3 by default) with jittered waits; any other 4xx is final.
- `mopm yank --group <id> --registry <prod|gamma|beta|url> --reason <text> [--config-dir <dir>] [--wait <seconds>]` yanks every version a group published, and `--unyank` restores
  the ones that yank changed.

Two things to know. The command line reads the registry's files, which are released in steps after the commit, so an install that runs
during the release of a group can see some of its members (dependencies first); the API shows all or none. And a group yank is not one
flip: members are yanked one by one, and only a group that is `visible` can be yanked.
