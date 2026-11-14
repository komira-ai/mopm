# The previous release (v0.0.104), vendored where it differs

The code of the release tagged `v0.0.104` (commit d0b9020), byte for byte, so that tests can run the previous release's command
line against this registry and this command line against the previous release's registry (`//:compat_v0_0_104`,
tests/drivers/compat_v0_0_104_test.zig). Nothing here is edited: do not change a file in `fake/` or `cli/`.

A file of the release that the live tree still holds byte for byte is not copied: the build reads it from the live tree. Only a
file that differs from the live tree is vendored here.

- Vendored `fake/`: the files of `registry/fake` at the tag that differ today: `api`, `auth`, `control`, `files`, `groups`, `main`,
  `packages`, `publish`, `state`.
- Vendored `cli/`: `group_plan`, `group_publish` (the release's `Publisher`) and `group_publish_test` (imported by the others from
  inside `test` blocks, which are not analysed, but Zig reads every file an `@import` names, so the file must exist).
- Read from the live tree: `registry/fake/{errors,resp,source_commit,token_scopes,util,versions}.zig` and
  `src/cli/{group_stage_token,publish_cmd,registry_cmd}.zig`.
- BUCK lays both out in one directory, as the release had them (`:prev_fake_tree`, `:prev_cli_tree`, tests/compat/tree.bzl), because
  Zig resolves a relative `@import` from the directory of the importing file. `prev_cli` and `prev_fake` are built from that.
- `SHA256SUMS`: lines `<sha256>  <repo-relative path>`, one for every file of the two modules, the sha256 being that of
  `git show v0.0.104:<path at the tag>`. A vendored file is named by its path here, a live one by its path in `registry/fake` or
  `src/cli`. The test checks every file against its line before it runs anything, and that no vendored file is missing from the
  list. If a live file changes, the test fails naming it: that is when to vendor the released copy (below) and move its line.
  By hand, from the repository root: `sha256sum -c tests/compat/v0.0.104/SHA256SUMS`.

`src/core` has changed since the tag (`git diff v0.0.104 -- src/core`: the installer `mopm sync` uses), but not in what the old
`cli/` files use, so they compile against the current `mopm_core` module, which is what the `prev_cli` module in BUCK gives them;
`//:compat_v0_0_104` fails to build when that stops being true. The fake registry has no
dependency. `tests/compat/prev_fake.zig` (written here, not vendored) wraps the released handler with the fixture to call it.

## To regenerate

Check a line: `git show v0.0.104:registry/fake/<f> | sha256sum` (for `src/cli/<f>`, the same with that path) is the hash of the line
for `registry/fake/<f>` or `tests/compat/v0.0.104/fake/<f>`.

To vendor a file the live tree no longer matches: `git show v0.0.104:registry/fake/<f> > tests/compat/v0.0.104/fake/<f>` (or
`src/cli/<f>` into `cli/`), change its line in SHA256SUMS to the vendored path, and move it from `_PREV_FAKE_LIVE` /
`_PREV_CLI_LIVE` in BUCK (and from `_COMPAT_DATA`'s live entries) to the glob. A later release is vendored in a directory of its
own (`tests/compat/v0.0.<n>`), not by editing this one.
