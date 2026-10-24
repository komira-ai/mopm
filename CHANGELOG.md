# Changelog

User-visible changes, newest first. Releases are cut automatically (RELEASING.md); the notes of a GitHub release list its files and
checksums, and this file says what changed. The details of a command are on its page of the documentation.

## Unreleased

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

Two things to know. The command line reads the registry's files, which are released in steps after the commit, so an install that runs
during the release of a group can see some of its members (dependencies first); the API shows all or none. And a group yank is not one
flip: members are yanked one by one, and only a group that is `visible` can be yanked.
