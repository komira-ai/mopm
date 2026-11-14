# The static sparse index

`mopm` resolves, searches and cross-checks locks from a small static index,
so that reading the registry needs no token and no running service. The
index is separate from conda repodata (`channel.md`): repodata is what conda
solvers read; the index carries what mopm needs on top (yank reasons,
tombstones, provenance, native library facts) in a form that is cheap to fetch
for one package.

The index is served from the API host (`https://api.<site>/index/...`, for
example `https://api.mopm.dev/index/config.json`).
Its schemas are in this directory.

## Files (version 2)

This mopm reads version 2. The schemas in this directory describe version 2;
version 1 is described under "Version 1" below, as what a registry still
serves for older clients.

| path | content | schema |
|---|---|---|
| `/index/config.json` | stage, URLs, `index_version`, `index_versions`, minimum CLI version | `index-config.schema.json` |
| `/index/v2/<aa>/<bb>/<namespace>/<name>` | one package, newline-delimited JSON, record `v` 2 | `index-record.schema.json` per line |
| `/index/v2/takedowns.json` | public log of removed versions, with full names | `takedowns.schema.json` |

`config.json` is read first. A CLI that does not know `index_version` refuses
the index with a message that says to update mopm. `min_cli_version` is the
oldest CLI the registry still supports; an older CLI says so and stops.
`read_only: true` means the stage refuses new uploads; reading still works.

`config.json` has two optional keys beside the version 1 ones (a reader that
does not know them ignores them):

- `index_versions`: every index version served, sorted, for example `[1, 2]`;
  when absent it is `[index_version]`. A client that reads version 2 refuses a
  registry whose `index_versions` lacks 2, naming the registry.
- `api_v2_url`: the API root of version 2, ending in `/api/v2`, on the rules
  of `api_url` below.

A namespace's channel is `channel_url` followed by `<namespace>/`
(`channel.md`).

`api_url`, `api_v2_url` and `channel_url` are `https` URLs, with one exception: loopback
`http` (`http://127.0.0.1:<port>`, `http://[::1]:<port>`,
`http://localhost:<port>`, port 1-65535 required) is accepted for local and
test registries only. `api_url` must end in `/api/v1` and `api_v2_url` in
`/api/v2`; `channel_url` is a base
URL ending in `/` (a loopback channel may be served under any path, such as
`/channel/`). Clients must refuse `http` for any non-loopback host.

### Path of a package

A package is named by its full name `<namespace>/<name>` (`mopm-toml.md`, "Names";
rules: the namespace is a lower-case GitHub login of at most 39 characters,
the name is `^[a-z][a-z0-9_]{1,63}$`). `aa` is the namespace's first two
characters; `bb` is its third and fourth characters, padded on the right with
`_` when the namespace is shorter than four. Examples: `komira-ai/json` is
`/index/v2/ko/mi/komira-ai/json`; `ab/x1` is `/index/v2/ab/__/ab/x1`. The path
is derived from the full name, never parsed back. This keeps directories small.

### A package file

UTF-8, one JSON object per line, `\n` line endings, no blank lines. Each line
describes one version, ordered from oldest to newest by version
(`MAJOR.MINOR.PATCH`, compared numerically part by part). The file is
regenerated whole from the registry's source of truth and is written deterministically (sorted keys, no timestamps other than
`published_at`). A line:

```json
{"v":2,"name":"komira-ai/http_client","version":"0.4.0","build":"mojo1.0.0_0","state":"published","published_at":"2026-11-13T12:00:00Z","requires_mojo":"==1.0.0","deps":[{"name":"komira-ai/http_core","range":">=1.2,<2"}],"native":[],"files":[{"subdir":"linux-64","filename":"mojo-komira-ai.http_client-0.4.0-mojo1.0.0_0.conda","sha256":"...","size":123456,"url":"https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.http_client-0.4.0-mojo1.0.0_0.conda"}],"manifest_sha256":"..."}
```

(`...` stands for a 64-character hex digest.)

Rules a reader applies:

- `v` is the record version, 2 in a version 2 file. A record with a `v` the
  reader does not know (a `v` 1 line in a version 2 file included) is an error,
  not a skipped line. Unknown keys are ignored.
- All lines of a file have the same `name`, the full name `<namespace>/<name>`
  of the file's path, and no `version` repeats. `deps[].name` is a full name
  too: one package is one full name, and two full names are two packages even
  when their import names are equal.
- A file of `files[]` is named `mojo-<namespace>.<name>-<version>-<build>.conda`
  after the conda name of the record's `name` (`channel.md`, "Package
  naming"), and its `url` is `<channel_url><namespace>/<subdir>/<filename>`.
  A reader refuses a file named otherwise.
- `state` is `published`, `yanked` (then `yank_reason` is present) or
  `tombstoned` (then `tombstone` is present and `files[].url` is absent: the
  bytes are gone but the sha256 stays so a lock can be explained).
- `deps[].range` is the cargo-syntax version requirement copied verbatim from
  the dependency's entry in `mopm.toml` (`Version requirements` in
  `mopm-toml.md`: `"1.2"`, `">=1.2, <1.5"`, `"~1.2"`), not a conda spec. It
  is absent when the dependency named no requirement. mopm resolves with
  these ranges. The `depends` of the conda `repodata.json`
  (`channel.md`) are generated separately, from the validated package, for
  conda clients; mopm's resolver never reads them, and the two are not
  compared for syntax. A dependency that had only a `path` in `mopm.toml`
  cannot be published, so no record carries one.
- `files[].sha256` and `size` are the values a lock pins and an install
  verifies. They must equal the values in the channel's `repodata.json` and in
  the API's `getVersion`.
- A dropped or truncated line is detected by the reader: the last line must
  end with `\n`.

### Takedowns

`/index/v2/takedowns.json` is `{"index_version":2,"takedowns":[...]}`; each
entry's `name` is a full name, and `version`, `reason_code`, `sha256` and
`date` are as in version 1.

## Version 1

A registry still serves version 1 beside version 2 for released CLIs that
read only it (`index_versions` lists both). This mopm does not read it. It
has the same rules with these differences:

| path | content |
|---|---|
| `/index/<aa>/<bb>/<name>` | one package, newline-delimited JSON, record `v` 1 |
| `/index/takedowns.json` | public log of removed versions, `index_version` 1 |

- `<name>` is a name without a namespace; `aa` and `bb` are its first four
  characters, padded on the right with `_` (`http_client` is
  `ht/tp/http_client`; `tls` is `tl/s_/tls`; `ab` is `ab/__/ab`).
- A record has `"v":1`, a flat `name` and `deps[].name` (`^[a-z][a-z0-9_]{1,63}$`),
  `files[].filename` `mojo-<name>-<version>-<build>.conda` and `files[].url`
  `<channel_url><subdir>/<filename>`.
- Packages that remain under flat names (on mopm.dev, the `kci_*` packages) are
  served only here.

## Versioning

Additive only, like the API (`api/openapi.yaml`): new optional keys can appear
in a record at any time; a change that would break a reader gets a new `v`
and a new `index_version`, served beside the old one for as long as released
CLIs need it. Version 2 is that change for namespaces: a reader of version 1
cannot read a version 2 file and the other way round, so `index_versions`
names what a registry serves.
