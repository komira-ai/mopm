# The previous release (v0.0.108), vendored for the namespaces cross-version test

The code of the release tagged `v0.0.108`, the last release before package names moved into namespaces, byte for byte, so that
`//:compat_namespaces` (tests/drivers/compat_namespaces_test.zig, also run by `zig build test`) can hold every row of the table in
docs/design/namespaces.md, section 11: the previous release reading what this one writes, and this one reading what the previous
one writes. Nothing here is edited: do not change a file in `core/`, `fake/` or `lock/`.

- `core/`: the files of `src/core` at the tag that the readers the test calls reach, transitively (every `@import` and
  `@embedFile`, those inside `test` blocks included, since Zig reads every file an `@import` names): `manifest`, `lock`,
  `metadata`, `registry`, `resolve`, `unit_graph`, `overlay`, `ci_oidc`, `http` and what they import.
- `fake/`: the files of `registry/fake` at the tag that `api`, `files` and `state` reach: the previous fake registry's handler.
- `lock/valid/`: `tests/contract/examples/lock/valid` at the tag, the locks the previous release documented as valid (all of
  version 1).

Unlike tests/compat/v0.0.104, nothing is read from the live tree: `src/core` and `registry/fake` have changed too much since the
tag, and a fully vendored tree builds as one module (tests/compat/prev_v0_0_108.zig) in Buck2 and in `zig build` alike, with no
layout step. The core imports nothing but its own files and `std`; the command line's own readers (`src/cli`) are not vendored,
because they import the core as the module `mopm_core`, a name the current core holds in the same build.

`SHA256SUMS`: lines `<sha256>  <repo-relative path>`, one for every file under `core/`, `fake/` and `lock/`, sorted. The test checks
every file against its line before it runs anything, and that no file under those directories is missing from the list. By hand,
from the repository root: `sha256sum -c tests/compat/v0.0.108/SHA256SUMS`.

## To regenerate

A file `src/core/<f>` of the tag is `core/<f>` here (`git show v0.0.108:src/core/<f>`), `registry/fake/<f>` is `fake/<f>`, and
`tests/contract/examples/lock/valid/<f>` is `lock/valid/<f>`. To add a file the test needs, copy it from the tag the same way
with everything it imports, and add its line (`sha256sum`) to SHA256SUMS in sorted order. A later release is vendored in a
directory of its own (`tests/compat/v0.0.<n>`), not by editing this one.
