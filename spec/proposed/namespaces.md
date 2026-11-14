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

Live in `spec/api/openapi-v2.yaml` (ns-R3): `/api/v2`, its operations, schemas and error catalogue (`service/api` tests hold
the catalogue to `V2_CATALOGUE`, and every operation to a router branch and a gateway route). What is not yet live is the
state of `/api/v1` once v2 is served: `claimPackage`, and `exchangeOidcToken` for a package that does not exist, answer
`name_reserved` with the hint "package names are in namespaces now; update mopm" (said in the descriptions of
`spec/api/openapi.yaml`). Every other v1 operation is unchanged. Flat names that remain after the deletion (on mopm.dev,
the `kci_*` packages) are served by v1 and the version 1 index as before.

## Unchanged

The version grammar, version requirements, `[native-dependencies]`, `[native.<id>]`, the build string, the subdirs,
yank and takedown states, the error shape, the token format and the device login.
