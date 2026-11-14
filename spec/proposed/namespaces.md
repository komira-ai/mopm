# Owner namespaces (proposed)

**Proposed, not implemented.** No released mopm or registry reads or serves anything left on this page, and no test reads
it (`//:contract` checks only `spec/*.schema.json` and `spec/api/openapi.yaml`). It is the spec text that
`docs/design/namespaces.md` implies. What the command line does is live in the specs and documents named under "Live
already"; only the names the registry also takes ("Names (all specs)", which the live specs repeat for the client) and the registry's API remain here, and they move into `spec/api/openapi.yaml` in the registry's task
that serves it.

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

## Live already

The names of `[package]`, `[dependencies]` and `[dev-dependencies]`, the refusal of a name without a namespace (worded with
the stored namespace for `[package] name`), the import-name rules, the library directory rule and the rule of one package
per import name in a closure are live in `spec/mopm-toml.md` ("Names", "`[targets]`", "Rules"). The index (version 2,
`config.json`'s `index_versions` and `api_v2_url`), the channel (one per namespace, conda name
`mojo-<namespace>.<name>`), package metadata schema 2, the lock (`lock_version` 3), the unit graph (format 6) and the
staged set's `plan.json` version 2, its `--artifacts` layout and the creation of each package before a new group are live in
`spec/index.md`, `spec/channel.md`, `spec/package-metadata.schema.json`, `spec/lock.md`, `spec/unit-graph.md` and
`spec/staged-set.md`, with their schemas. The optional `namespace` of a registry's entry in `credentials.json` is described in
`docs/configuration.md`.

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

`createPackage` answers `name_reserved` (403) for an import name that is a module of the Mojo standard library, with
the message `'{name}' is a module of the Mojo standard library (std.{name}).` and the hint `Choose another name.`.

`/api/v1` once v2 is served: `claimPackage`, and `exchangeOidcToken` for a package that does not exist, answer
`name_reserved` with the hint "package names are in namespaces now; update mopm". Every other v1 operation is
unchanged. Flat names that remain after the deletion (on mopm.dev, the `kci_*` packages) are served by v1 and the
version 1 index as before.

## Unchanged

The version grammar, version requirements, `[native-dependencies]`, `[native.<id>]`, the build string, the subdirs,
yank and takedown states, the error shape, the token format and the device login.
