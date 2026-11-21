# The readers before builds (main at 8b8a8cc), vendored for the builds compatibility test

The readers of the last command line before a version could be published with several builds, one per Mojo compiler, byte for
byte, so that `//:compat_pre_builds` (tests/drivers/compat_pre_builds_test.zig, also run by `zig build test`) can hold the
previous reader to what this release writes: a version's index line and API body with `builds`, and a package's metadata with
`source_sha256`. Nothing here is edited: do not change a file in `core/`.

The commit is the last one of main before that change (`git show 8b8a8cc:src/core/<f>`); no release tag was cut from it, but a
command line built from it reads `builds`-less data exactly as the release before this one does, and it is what a user who has not
updated yet runs.

- `core/resolve.zig`: the sparse-index reader (`parseIndex`) and the resolver (`resolve`), which pick the one build a line has
  (its top-level `build`, `requires_mojo` and `files`) and ignore every key they do not read.
- `core/metadata.zig`: the reader of a package's `<name>.mopm.json`, which ignores unknown keys.
- `core/registry_v2.zig`: the generated registry client; `decode` reads an answer with `ignore_unknown_fields`.
- `core/http.zig`, `core/native_link.zig`, `core/names.zig`, `core/semver.zig`, `core/testroot.zig` and
  `core/toolchain/std-modules.txt`: what the three above import, transitively (every `@import` and `@embedFile`, those inside
  `test` blocks included, since Zig reads every file an `@import` names). They import nothing outside this directory but `std`,
  so they build as one module (tests/compat/prev_pre_builds.zig) in Buck2 and in `zig build` alike.

`SHA256SUMS`: lines `<sha256>  <repo-relative path>`, one for every file under `core/`, sorted. The test checks every file against
its line before it runs anything, and that no file under `core/` is missing from the list. By hand, from the repository root:
`sha256sum -c tests/compat/pre_builds/SHA256SUMS`.

## To regenerate

A file `src/core/<f>` of the commit is `core/<f>` here. To add a file the test needs, copy it from the commit the same way with
everything it imports, and add its line (`sha256sum`) to SHA256SUMS in sorted order. A later baseline is vendored in a directory
of its own, not by editing this one.
