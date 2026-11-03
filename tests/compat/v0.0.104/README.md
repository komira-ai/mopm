# The previous release (v0.0.104), vendored

This directory is the code of the release tagged `v0.0.104` (commit d0b9020), copied byte for byte, so that tests can run the
previous release's command line against this registry and this command line against the previous release's registry
(`//:compat_v0_0_104`, tests/drivers/compat_v0_0_104_test.zig). Nothing here is edited: do not change a file in `fake/` or `cli/`.

- `fake/`: every non-test `.zig` file of `registry/fake` at the tag (the fake registry's request handler, and its `main.zig`).
- `cli/`: the files of `src/cli` at the tag that the release's `Publisher` (`group_publish.zig`) reaches: `group_plan.zig`,
  `group_stage_token.zig`, `publish_cmd.zig`, `registry_cmd.zig`, and `group_publish_test.zig` (imported by the others from inside
  `test` blocks, which are not analysed, but Zig reads every file an `@import` names, so the file must exist).
- `SHA256SUMS`: the sha256 of each file, taken from `git show v0.0.104:<path>`. The test checks every file against it before it
  runs anything, and that no file is missing from or extra to the list. `cd tests/compat/v0.0.104 && sha256sum -c SHA256SUMS`
  does the same by hand.

`src/core` is unchanged between the tag and this code (`git diff v0.0.104 -- src/core` is empty), so the old `cli/` files compile
against the current `mopm_core` module, which is what the `prev_cli` module in BUCK gives them. The fake registry has no
dependency. `tests/compat/prev_fake.zig` (written here, not vendored) wraps the vendored handler with the fixture to call it.

## To regenerate

For `fake/<f>`: `git show v0.0.104:registry/fake/<f> > tests/compat/v0.0.104/fake/<f>`; for `cli/<f>`:
`git show v0.0.104:src/cli/<f> > tests/compat/v0.0.104/cli/<f>`; then rewrite SHA256SUMS with the sha256 of the same `git show`
output. A later release is vendored in a directory of its own (`tests/compat/v0.0.<n>`), not by editing this one.
