# Owner namespaces (proposed)

**Proposed, not implemented.** No released mopm or registry reads or serves anything on this page except what the
sections below say is live, and no test reads it (`//:contract` checks only `spec/*.schema.json`,
`spec/api/openapi.yaml` and `spec/api/openapi-v2.yaml`). It is the spec text that
`docs/design/namespaces.md` implies, one section per live spec it changes. Each section moves into its live file (and
the schema fragments into the `.schema.json` files) in the task that implements it; until then the live files describe
what the code does.

## Names (all specs)

```json
{
  "Namespace": { "type": "string", "minLength": 1, "maxLength": 39, "pattern": "^[a-z0-9]+(-[a-z0-9]+)*$" },
  "Name":      { "type": "string", "pattern": "^[a-z][a-z0-9_]{1,63}$" },
  "FullName":  { "type": "string", "maxLength": 104, "pattern": "^[a-z0-9]+(-[a-z0-9]+)*/[a-z][a-z0-9_]{1,63}$" },
  "CondaName": { "type": "string", "pattern": "^mojo-[a-z0-9]+(-[a-z0-9]+)*\\.[a-z][a-z0-9_]{1,63}$" }
}
```

- A **full name** is `<namespace>/<name>`. The namespace is at most 39 characters (a GitHub login); a reader checks
  that length as well as the pattern.
- The **import name** is the name, the part after `/`. It is not a Mojo keyword or builtin (the lists in
  `src/core/names.zig`), nor `mopm`, `mojo`, `max`, `modular`, `std` or `stdlib`, nor a top-level module of the Mojo
  standard library. The client refuses those (`spec/mopm-toml.md`, "Names"); the registry is to refuse them too.
- The **standard library's modules** are those of every Mojo version in `toolchain/versions.txt`, one file per version,
  `toolchain/mojo-<version>.std-modules.txt`, read from the `lib/mojo/std.mojoc` of that version's pinned
  `mojo-compiler` package (`mopm-closure --std-modules`). For Mojo 1.0.0: `algorithm`, `atomic`, `base64`, `benchmark`,
  `bit`, `builtin`, `collections`, `compile`, `complex`, `documentation`, `ffi`, `format`, `gpu`, `hashlib`, `io`,
  `iter`, `itertools`, `logger`, `math`, `memory`, `origin`, `os`, `pathlib`, `prelude`, `pwd`, `python`, `random`,
  `reflection`, `runtime`, `stat`, `subprocess`, `sys`, `tempfile`, `testing`, `time`, `traits`, `utils`. The registry
  is to refuse creating a package with such an import name; the client refuses it as `[package] name` and warns when a
  dependency key has it (live in `spec/mopm-toml.md`).
- The **conda name** of `<namespace>/<name>` is `mojo-<namespace>.<name>`.
- Lower case only, one spelling. Nothing normalises a namespace; `Komira-AI` is refused, with the lower-case form in
  the message.
- Reserved namespaces, never created: those matching `^(noarch|(linux|osx|win|freebsd|zos|wasi|emscripten)-[a-z0-9]+)$`
  (the shape of a conda subdir), and `index`, `quarantine`, `native-mirror`.

## mopm-toml.md

The names of `[package]`, `[dependencies]` and `[dev-dependencies]`, the refusal of a name without a namespace, the
import-name rules and the library directory rule are live in `spec/mopm-toml.md` ("Names", "`[targets]`"). What is left:

- In the refusal of a name without a namespace, mopm puts the user namespace stored by `mopm login` in place of
  `<namespace>` when it has one.
- New rule (under "Rules"): two packages in one dependency closure (the root, path packages and registry packages, from
  `[dependencies]` and `[dev-dependencies]`) may not have the same import name. There is no rename.

## package-metadata.schema.json

`schema` 2. Changed properties; everything else is schema 1's.

```json
{
  "schema": { "const": 2 },
  "name": { "$ref": "#/$defs/FullName" },
  "deps": { "type": "array", "items": { "type": "object", "required": ["name"],
            "properties": { "name": { "$ref": "#/$defs/FullName" }, "range": { "type": "string" } } } }
}
```

The file stays at `lib/mojo/<import name>.mopm.json`, beside `lib/mojo/<import name>.mojoc`. A reader refuses a
`schema` it does not know, so a mopm without namespaces refuses schema 2.

## channel.md

- Layout: one channel per namespace, `https://conda.<site>/<namespace>/`, with the four subdirs and the files of
  "Layout (v1)" below it. A namespace channel holds only that namespace's packages.
- The channel root `https://conda.<site>/` keeps its four subdirs, each with a valid `repodata.json` that holds only
  the packages kept under flat names (on mopm.dev, the `kci_*` packages).
- Package naming: the conda package name is `mojo-<namespace>.<name>`; the file is
  `mojo-<namespace>.<name>-<version>-<build>.conda`. `pixi workspace channel add https://conda.mopm.dev/komira-ai/`
  then `pixi add mojo-komira-ai.json` installs `komira-ai/json`.
- `depends`: another mopm package is `mojo-<namespace>.<name> <range>`. A conda client finds it in the channels its user
  lists; a package whose closure spans namespaces needs every one of those channels.
- Inside a package: `lib/mojo/<import name>.mojoc` and `lib/mojo/<import name>.mopm.json` (schema 2, whose `name` is
  the full name).

## index.md, index-record.schema.json, index-config.schema.json, takedowns.schema.json

Version 2 is served beside version 1.

| path | content |
|---|---|
| `/index/config.json` | as today, plus the optional keys below |
| `/index/v2/<aa>/<bb>/<namespace>/<name>` | one package, newline-delimited JSON, record `v` 2 |
| `/index/v2/takedowns.json` | the public log of removed versions, with full names |

`aa` is the namespace's first two characters and `bb` its third and fourth, padded on the right with `_` when it is
shorter than four: `komira-ai/json` is `/index/v2/ko/mi/komira-ai/json`; `ab/x1` is `/index/v2/ab/__/ab/x1`.

`config.json`, two optional keys (a reader that does not know them ignores them):

```json
{
  "index_versions": { "type": "array", "items": { "type": "integer", "minimum": 1 }, "minItems": 1, "uniqueItems": true },
  "api_v2_url": { "type": "string", "format": "uri" }
}
```

`index_versions` lists every index version served, sorted; when absent it is `[index_version]`. `api_v2_url` follows
the rules of `api_url` and ends in `/api/v2`. A namespace's channel is `channel_url` followed by `<namespace>/`. A
client that reads version 2 refuses a registry whose `index_versions` lacks 2, naming the registry.

A record, version 2:

```json
{"v":2,"name":"komira-ai/json","version":"0.1.0","build":"mojo1.0.0_0","state":"published","published_at":"2026-11-13T12:00:00Z","requires_mojo":"==1.0.0","deps":[{"name":"komira-ai/encoding","range":"0.1"}],"native":[],"files":[{"subdir":"linux-64","filename":"mojo-komira-ai.json-0.1.0-mojo1.0.0_0.conda","sha256":"...","size":123456,"url":"https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.json-0.1.0-mojo1.0.0_0.conda"}],"manifest_sha256":"..."}
```

Schema changes from record version 1: `v` const 2; `name` and `deps[].name` are `FullName`; `files[].filename` is
`^mojo-[a-z0-9]+(-[a-z0-9]+)*\.[a-z][a-z0-9_]{1,63}-[0-9][0-9a-z.]*-[A-Za-z0-9_.]+\.conda$`, its conda name the
record's; `files[].url` is `<channel_url><namespace>/<subdir>/<filename>`. Every line of a file has the same `name`,
equal to the file's `<namespace>/<name>`. Takedown entries: `name` is `FullName`.

## lock.md, lock.schema.json

`lock_version` 3: the shape of version 2 for every project (a `[toolchain] mojo` project has a one-element `mojo`).

```json
{
  "lock_version": 3,
  "mojo": ["1.0.0"],
  "toolchain": { "1.0.0": { "linux-64": "<64 hex digits>" } },
  "channels": ["https://conda.mopm.dev/"],
  "packages": [
    {
      "name": "komira-ai/json",
      "version": "0.1.0",
      "subdir": "linux-64",
      "channel": "https://conda.mopm.dev/komira-ai/",
      "artifacts": {
        "1.0.0": { "build": "mojo1.0.0_0", "url": "https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.json-0.1.0-mojo1.0.0_0.conda", "sha256": "<64 hex digits>", "size": 1000 }
      },
      "deps": ["komira-ai/encoding"]
    }
  ]
}
```

- `channels` is the root project's set of channel roots, as today.
- `packages[].name` and `deps` items are `FullName`.
- Rules that change: rule 2, every `channel` is a listed root followed by the entry's namespace and `/`; rule 3, each
  artifact's `url` is `<channel><subdir>/mojo-<namespace>.<name>-<version>-<build>.conda`; rule 5, every full name in
  `deps` is the `name` of an entry; rule 6, a full name comes from at most one root.
- New rule 10: no two entries whose full names differ have the same import name. The error names each full name and
  the shortest dependency path from the root to it.
- Versions 1 and 2 are read and reported as stale: `mopm lock` rewrites them; `mopm sync --locked` refuses with
  `mopm.lock predates namespaces (lock_version <n>); run 'mopm lock'`.

## api/openapi.yaml

Live in `spec/api/openapi-v2.yaml` (ns-R3): `/api/v2`, its operations, schemas and error catalogue (`service/api` tests hold
the catalogue to `V2_CATALOGUE`, and every operation to a router branch and a gateway route). What is not yet live is the
state of `/api/v1` once v2 is served: `claimPackage`, and `exchangeOidcToken` for a package that does not exist, answer
`name_reserved` with the hint "package names are in namespaces now; update mopm" (said in the descriptions of
`spec/api/openapi.yaml`). Every other v1 operation is unchanged. Flat names that remain after the deletion (on mopm.dev,
the `kci_*` packages) are served by v1 and the version 1 index as before.

## unit-graph.md

Format 6.

- A unit id is `<full name>@<version>#mojo<M>/<mode>[:<file>]`, for example `komira-ai/json@0.1.0#mojo1.0.0/lib`. A
  reader splits at the first `@`.
- A native unit is `native:<full name>/<id>`; the id follows the last `/`.
- A unit's `package` is the full name. A new field `import` is the import name. Outputs are `<import>.mojoc`.
- The refusal of two libraries of one name is by import name.

## staged-set.md

`plan.json` `version` 2.

- Members' `name` are full names.
- Files stay at `<dir>/<subdir>/<file>.conda`; their names carry the namespace (`mojo-<namespace>.<name>-...`).
- The group's `set` digest is over members sorted by full name.
- A version 1 `plan.json` is refused, naming the file; the set is staged again.
- `mopm stage --artifacts <dir>`: `<dir>/<subdir>/<namespace>/<name>.mojoc`, natives at
  `<dir>/<subdir>/<namespace>/<name>.native/lib<id>.a`.

## Credentials

`<config dir>/credentials.json` gains one optional key per registry, `namespace`: the user namespace `mopm login`
received. `mopm new` and `mopm init` default to it.

## Unchanged

The version grammar, version requirements, `[native-dependencies]`, `[native.<id>]`, the build string, the subdirs,
yank and takedown states, the error shape, the token format and the device login.
