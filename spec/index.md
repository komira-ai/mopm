# The static sparse index

`mopm` resolves, searches and cross-checks locks from a small static index,
so that reading the registry needs no token and no running service. The
index is separate from conda repodata (`channel.md`): repodata is what conda
solvers read; the index carries what mopm needs on top (yank reasons,
tombstones, provenance, native library facts) in a form that is cheap to fetch
for one package.

The index is served from the API host (`https://<stage host>/index/...`).
Its schemas are in this directory.

## Files (v1)

| path | content | schema |
|---|---|---|
| `/index/config.json` | stage, URLs, `index_version`, minimum CLI version | `index-config.schema.json` |
| `/index/<aa>/<bb>/<name>` | one package, newline-delimited JSON | `index-record.schema.json` per line |
| `/index/takedowns.json` | public log of removed versions | `takedowns.schema.json` |

`config.json` is read first. A CLI that does not know `index_version` refuses
the index with a message that says to update mopm. `min_cli_version` is the
oldest CLI the registry still supports; an older CLI says so and stops.
`read_only: true` means the stage refuses new uploads; reading still works.

`api_url` and `channel_url` are `https` URLs, with one exception: loopback
`http` (`http://127.0.0.1:<port>`, `http://[::1]:<port>`,
`http://localhost:<port>`, port 1-65535 required) is accepted for local and
test registries only. `api_url` must end in `/api/v1`; `channel_url` is a base
URL ending in `/` (a loopback channel may be served under any path, such as
`/channel/`). Clients must refuse `http` for any non-loopback host.

### Path of a package

For the normalised name `name`: `aa` is its first two characters; `bb` is its
third and fourth characters, padded on the right with `_` when the name is
shorter than four. Examples: `http_client` is `ht/tp/http_client`; `tls` is
`tl/s_/tls`; `ab` is `ab/__/ab`. The path is derived from the name, never
parsed back. This keeps directories small.

### A package file

UTF-8, one JSON object per line, `\n` line endings, no blank lines. Each line
describes one version, ordered from oldest to newest by conda version
ordering. The file is regenerated whole from the registry's source of truth
and is written deterministically (sorted keys, no timestamps other than
`published_at`). A line:

```json
{"v":1,"name":"http_client","version":"0.4.0","build":"mojo1.0.0_0","state":"published","published_at":"2026-10-13T12:00:00Z","requires_mojo":"==1.0.0","deps":[{"name":"http_core","range":">=1.2,<2"}],"native":[],"files":[{"subdir":"linux-64","filename":"mojo-http_client-0.4.0-mojo1.0.0_0.conda","sha256":"...","size":123456,"url":"https://conda.mopm.dev/linux-64/mojo-http_client-0.4.0-mojo1.0.0_0.conda"}],"manifest_sha256":"..."}
```

(`...` stands for a 64-character hex digest.)

Rules a reader applies:

- `v` is the record version. A record with a `v` the reader does not know is
  an error, not a skipped line. Unknown keys are ignored.
- All lines of a file have the same `name`, and no `version` repeats (equal
  under conda ordering counts as repeating).
- `state` is `published`, `yanked` (then `yank_reason` is present) or
  `tombstoned` (then `tombstone` is present and `files[].url` is absent: the
  bytes are gone but the sha256 stays so a lock can be explained).
- `files[].sha256` and `size` are the values a lock pins and an install
  verifies. They must equal the values in the channel's `repodata.json` and in
  the API's `getVersion`.
- A dropped or truncated line is detected by the reader: the last line must
  end with `\n`.

## Versioning

Additive only, like the API (`api/openapi.yaml`): new optional keys can appear
in a record at any time; a change that would break a reader gets a new `v`
and a new `index_version`, served beside the old one for as long as released
CLIs need it.
