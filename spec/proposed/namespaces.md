# Owner namespaces (proposed)

**Proposed, not implemented.** No released mopm or registry reads or serves anything on this page except what the
sections below say is live, and no test reads it (`//:contract` checks only `spec/*.schema.json`,
`spec/api/openapi.yaml` and `spec/api/openapi-v2.yaml`). It is the spec text that `docs/design/namespaces.md` implies.
What the command line does is live in the specs and documents named under "Live already", and the registry's `/api/v2`
in `spec/api/openapi-v2.yaml`; what remains here is the names the registry also takes ("Names (all specs)", which the
live specs repeat for the client) and the state of `/api/v1` once v2 is served.

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
  (the shape of a conda subdir), and `index`, `quarantine`, `native-mirror`, `poll`.

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

## Organization namespaces and their members

Live in `spec/api/openapi-v2.yaml`; the command line side (`mopm org`) is the text below.

GitHub is asked about an organization once, when a user registers it. `mopm org create <org>` needs a stored login. It
calls `createNamespace` (`POST /namespaces`), which refuses a namespace outside the grammar (`invalid_namespace`), a reserved
one (`namespace_reserved`) and one already held by any account (`namespace_taken`), and a caller that holds no user namespace (`user_not_found`: it could not be named as a member), and otherwise starts a GitHub device flow
for the scope `read:org` and answers 202 with the code to enter. The command prints where to open and the code, then polls
`pollNamespace` (`POST /namespaces/poll`, the same pause and deadline as the login) until the answer is `created` (the
namespace and its GitHub organization id; the caller is its first owner), `denied` or `expired`. The registry accepts the
approval only when the GitHub account that approved is the logged-in account (`github_account_mismatch`) and is an active admin
of the GitHub organization whose current login in lower case is the namespace (`not_org_admin` for every other answer of GitHub,
including an organization that restricts OAuth apps). The GitHub token is used for that one read and discarded. After that
nothing is checked against GitHub: members are kept in mopm, and a write in `<org>/*` reads only that list, so a removed
member is refused at once.

Members are named by mopm username, the user namespace of the account (its lower-case GitHub login, made at its first login):

```text
mopm org create <org>
mopm org add <org> <user> [--owner]      PUT    /namespaces/<org>/members/<user>   {"role": "member" | "owner"}
mopm org remove <org> <user>             DELETE /namespaces/<org>/members/<user>
mopm org list <org>                      GET    /namespaces/<org>/members
```

- Roles: `owner` adds and removes members and changes roles; `owner` and `member` both create packages and publish.
- `add` sets the role: without `--owner` it makes an owner a member. It answers 201 for a new member and 200 for a change.
- The only owner cannot be demoted or removed (`last_owner`); an owner may remove themselves while another owner remains.
- A name that is no user namespace is `user_not_found`; an account that is not a member is `member_not_found`; a caller who
  is a member but not an owner is `not_namespace_owner`, and one who is neither is `not_namespace_member`.
- A renamed organization keeps its old namespace, its id and its members; registering its new login makes a second, separate
  namespace.

## api/openapi.yaml

Live in `spec/api/openapi-v2.yaml` (ns-R3): `/api/v2`, its operations, schemas and error catalogue (`service/api` tests hold
the catalogue to `V2_CATALOGUE`, and every operation to a router branch and a gateway route). What is not yet live is the
state of `/api/v1` once v2 is served: `claimPackage`, and `exchangeOidcToken` for a package that does not exist, answer
`name_reserved` with the hint "package names are in namespaces now; update mopm" (said in the descriptions of
`spec/api/openapi.yaml`). Every other v1 operation is unchanged. Flat names that remain after the deletion (on mopm.dev,
the `kci_*` packages) are served by v1 and the version 1 index as before.

## Unchanged

The version grammar, version requirements, `[native-dependencies]`, `[native.<id>]`, the build string, the subdirs,
yank and takedown states, the error shape, the token format and the device login.
