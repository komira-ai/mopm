# Owner namespaces (proposed)

**Proposed, not implemented.** No released mopm or registry reads or serves anything on this page, and no test reads
it (`//:contract` checks only `spec/*.schema.json` and `spec/api/openapi.yaml`). It is the spec text that
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
  `src/core/manifest.zig`) nor `mopm`, `mojo`, `max`, `modular`, `std` or `stdlib`. The client and the registry both
  refuse those.
- The **conda name** of `<namespace>/<name>` is `mojo-<namespace>.<name>`.
- Lower case only, one spelling. Nothing normalises a namespace; `Komira-AI` is refused, with the lower-case form in
  the message.
- Reserved namespaces, never created: those matching `^(noarch|(linux|osx|win|freebsd|zos|wasi|emscripten)-[a-z0-9]+)$`
  (the shape of a conda subdir), and `index`, `quarantine`, `native-mirror`.

## mopm-toml.md

Replaces, under `[package]`, the dependency tables and `[targets]`:

- `[package] name` is a full name: `name = "komira-ai/parquet"`. Its import name is the name Mojo code imports.
- `[targets] lib` defaults to `src/<import name>`. A `path` whose last component is not the import name is an error
  naming both.
- The keys of `[dependencies]` and `[dev-dependencies]` are full names, quoted because they hold `/`:
  `"komira-ai/json" = "0.1"`. A path dependency's key equals the `[package] name` at the path.
- A name without a namespace is an error naming the key and giving the full form:
  `dependency 'json' has no namespace: write it "<namespace>/json" = "0.1"`;
  `package name 'json' has no namespace: write name = "<namespace>/json"`, where mopm puts the user namespace stored
  by `mopm login` in place of `<namespace>` when it has one.
- `[native-dependencies]` keys are unchanged (conda names).
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
- The channel root `https://conda.<site>/` keeps its four subdirs, each with an empty valid `repodata.json`.
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

`/api/v2`, served beside `/api/v1`, on the same host. Operations that never name a package (`/health`, `/auth/device`,
`/auth/device/poll`, `/me/tokens` listing and revoking, `/publishes/{publish_id}`) behave the same at both prefixes.
Path parameters `{namespace}` (`Namespace`) and `{name}` (`Name`) replace v1's `{name}`.

| v1 operation | v2 |
|---|---|
| `searchPackages` `GET /packages` | same path; `q` is a name prefix, or `<namespace>/` with an optional name prefix; `PackageSummary.name` is `FullName` |
| `getPackage` `GET /packages/{name}` | `GET /packages/{namespace}/{name}`; `PackageInfo` has `namespace` (`NamespaceInfo`) instead of `owners` |
| `claimPackage` `POST /packages/{name}/claim` | `createPackage` `PUT /packages/{namespace}/{name}`, no body; 201 created, 200 already exists |
| `listVersions` | `GET /packages/{namespace}/{name}/versions` |
| `listOwners`, `inviteOwner`, `removeOwner` | removed |
| `listInvitations`, `acceptInvitation` | removed |
| `getVersion`, `beginUpload`, `commitPublish`, `setYanked` | under `/packages/{namespace}/{name}/{version}` |
| `getMe` `GET /me` | `MeV2` |
| `createToken` `POST /me/tokens` | `packages` items are `FullName`; one may name a package not yet created, in a namespace the caller can write |
| `exchangeOidcToken` | `name` and `packages[].name` are `FullName`; matched to the publishers of the namespace; mints a token, creates nothing |
| `createGroup`, `getGroup`, `commitGroup`, `abortGroup`, `yankGroup` | members' `name` are `FullName` |
| (new) `createNamespace` `POST /namespaces` | `{ "namespace": Namespace }`, fresh session; creates an organization namespace, or binds a new App installation to a frozen one whose GitHub id it matches; 201 or 200 `NamespaceInfo` |
| (new) `getNamespace` `GET /namespaces/{namespace}` | public; `NamespaceInfo` |

`createPackage` checks the right to write the namespace before it answers: a session of an account that can write it,
an API token with `publish` whose `packages` names the full name, or a trusted publisher's token minted for it.

New schemas:

```yaml
NamespaceInfo:
  type: object
  required: [namespace, kind, github_id, login, frozen]
  properties:
    namespace: { $ref: "#/components/schemas/Namespace" }
    kind: { type: string, enum: [user, org] }
    github_id: { type: integer, minimum: 1 }
    login: { type: string, minLength: 1, description: The GitHub login the account has now; differs from namespace after a rename. }
    frozen: { type: boolean, description: True when no App installation of this GitHub id is bound; reads work, writes are refused. }
MeV2:
  type: object
  required: [github_id, handle, namespaces]
  properties:
    github_id: { type: integer, minimum: 1 }
    handle: { type: string, minLength: 1 }
    namespaces:
      type: array
      items:
        type: object
        required: [namespace, kind, role, packages]
        properties:
          namespace: { $ref: "#/components/schemas/Namespace" }
          kind: { type: string, enum: [user, org] }
          role:
            description: owner for a user namespace of the caller; GitHub's admin or member for an organization namespace.
            type: string
            enum: [owner, admin, member]
          packages: { type: array, items: { $ref: "#/components/schemas/FullName" } }
    unavailable_namespace:
      description: The caller's GitHub login when it cannot be the caller's namespace (another account holds it, it is reserved, or it is outside the grammar). Absent otherwise.
      type: string
```

Who may write: in a `user` namespace, the account bound to it; in an `org` namespace, an account that passes the
membership check of `docs/design/namespaces.md` section 2.2 (from the bound installation and the ids to the current
logins, then `GET /orgs/{org}/memberships/{login}` with the response's `user.id` equal to the account's, `state:
active`, role `admin` or `member`; a pass is reused for at most 5 minutes, a refusal never); `createNamespace` needs
role `admin`, checked without reuse. A trusted publisher of a namespace may write in it; its `repository_owner_id`
equals the namespace's `github_id`.

New error codes (additive to `ErrorCode` and `x-mopm-errors`):

```yaml
invalid_namespace:     { status: 400, message: "'{namespace}' is not a valid namespace.", hint: "A namespace is a GitHub login in lower case: letters, digits and single hyphens, at most 39 characters." }
not_namespace_member:  { status: 403, message: "You cannot write in '{namespace}'.", hint: "Ask an owner of the GitHub organization for membership." }
namespace_unverified:  { status: 403, message: "'{namespace}' cannot be verified on GitHub: {detail}.", hint: "An owner of the organization installs the mopm registry GitHub App, then an admin runs the namespace creation again." }
namespace_reserved:    { status: 403, message: "'{namespace}' is reserved.", hint: "Publish in an organization's namespace." }
namespace_not_found:   { status: 404, message: "There is no namespace '{namespace}'.", hint: "A user's namespace is made at their first 'mopm login'; an organization's by one of its admins." }
```

`/api/v1` once v2 is served: `claimPackage`, and `exchangeOidcToken` for a package that does not exist, answer
`name_reserved` with the hint "package names are in namespaces now; update mopm". Every other v1 operation is
unchanged.

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
