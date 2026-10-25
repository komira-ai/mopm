# Changelog

User-visible changes, newest first. Releases are cut automatically (RELEASING.md); the notes of a GitHub release list its files and
checksums, and this file says what changed. The details of a command are on its page of the documentation.

## Unreleased

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
- `mopm publish --staged <dir> --registry <prod|gamma|beta|url> [--config-dir <dir>] [--wait <seconds>] [--dry-run]` publishes a staged set
  through one group. A rerun after a failure resumes the same group (`state.json`); `report.json` says what each member came to; a 429
  stops the run and is never retried.
- `mopm yank --group <id> --registry <prod|gamma|beta|url> --reason <text> [--config-dir <dir>] [--wait <seconds>]` yanks every version a group published, and `--unyank` restores
  the ones that yank changed.

The readmes of a group's members travel in the body of its commit request, which is at most 5 MiB. `mopm stage` and `mopm publish --staged`
add up that body before they write or send anything and, when the readmes make it too large, stop and name the largest ones.

Two things to know. The command line reads the registry's files, which are released in steps after the commit, so an install that runs
during the release of a group can see some of its members (dependencies first); the API shows all or none. And a group yank is not one
flip: members are yanked one by one, and only a group that is `visible` can be yanked.
