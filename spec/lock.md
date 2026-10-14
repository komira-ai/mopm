# mopm.lock

`mopm.lock` records the exact packages a project resolved to, so that the same
bytes are installed on every machine and in CI. It is JSON, written by mopm,
committed, and never edited by hand. The schema is `lock.schema.json`.

The lock states only what mopm needs to fetch and verify: where each file
comes from, which bytes it must be, and which Mojo version it was built
with. It does not duplicate package metadata; that stays in the installed
`<name>.mopm.json`.

```json
{
  "lock_version": 1,
  "toolchain": { "mojo": "1.0.0" },
  "channels": ["https://conda.mopm.dev/"],
  "packages": [
    {
      "name": "http_client",
      "version": "0.4.0",
      "build": "mojo1.0.0_0",
      "subdir": "linux-64",
      "channel": "https://conda.mopm.dev/",
      "url": "https://conda.mopm.dev/linux-64/mojo-http_client-0.4.0-mojo1.0.0_0.conda",
      "sha256": "<64 hex digits>",
      "size": 123456,
      "mojo": "1.0.0",
      "deps": ["http_core"],
      "native": [{ "id": "crypto", "soname": "libcrypto_native.so.1", "sha256": "<64 hex digits>" }]
    }
  ]
}
```

## Fields

- `lock_version`: 1. A higher value is refused with "update mopm".
- `toolchain.mojo`: the Mojo version the project is locked to
  (`[toolchain]` in `mopm.toml`).
- `channels`: the channels packages may come from. This is the root project's
  set and nothing else.
- `packages[]`, one entry per package per subdir:
  - `name`: the mopm name. The conda name is `mojo-<name>`.
  - `version`, `build`, `subdir`: identify the file.
  - `channel`: the channel the file comes from, with a trailing slash.
  - `url`: the file URL.
  - `sha256`, `size`: the bytes. `mopm install` verifies both before use.
  - `mojo`: the Mojo version the package was built with. A `.mojoc` is tied to
    one compiler, so it must equal `toolchain.mojo`.
  - `deps`: names of direct Mojo dependencies, each present in `packages`.
  - `native`: native libraries the package ships (`id`, `soname`, optional
    `sha256` of the library file), copied from the package metadata so that
    link planning can run from the lock alone.

## Rules the schema cannot express

`tests/contract/validate.py` checks these on the example locks. The CLI must
check them on every read. A violation is an error, not a warning.

1. `packages` is sorted by `name`, then `version`, then `subdir` (each compared
   as a plain byte string, not in version order), with no two entries equal
   in all three. This keeps diffs small and the file
   reproducible.
2. Every `channel` is in `channels`. A lock entry whose channel the root
   project does not list is refused. Only the root project's manifest may add
   channels; a dependency's manifest cannot.
3. `url` is exactly `<channel><subdir>/mojo-<name>-<version>-<build>.conda`.
4. `mojo` of every entry equals `toolchain.mojo`.
5. Every name in `deps` appears in `packages`.
6. A package name comes from at most one channel. The same name on a second
   configured channel is a hard error: it is the shape of a dependency
   confusion attack.
7. No two packages declare the same `soname` in `native`.

## Install and update behaviour (what the lock promises)

- `mopm sync --locked` installs exactly the lock and fails if it would change
  it. It does not read the index.
- Every download is verified against `sha256` and `size`. When the sparse
  index is reachable, `mopm` also compares the index's values with the lock's
  and names both on a mismatch.
- A locked version that was yanked still installs, with a warning that gives
  the reason. A locked version that was taken down fails to install, and the
  error shows the tombstone reason from the index.

## Versioning

`lock_version` changes only for incompatible changes. New optional keys can
be added within version 1; readers ignore keys they do not know.
