# mopm specifications

This directory is the contract between the `mopm` command line tool and the
hosted registry at mopm.dev. The CLI is tested against a local fake registry
that implements this contract; the hosted registry is tested against the same
contract. Nothing here describes the registry's internals.

| file | what it fixes |
|---|---|
| `mopm-toml.md` | the `mopm.toml` manifest authors write (draft) |
| `package-metadata.schema.json` | `<name>.mopm.json`, embedded in every package |
| `api/openapi.yaml` | the HTTP API under `/api/v1`: login, tokens, publish, yank, owners, packages, search, health; the error catalogue; auth schemes; the additive-only versioning rule |
| `channel.md` | the conda channel at `conda.<site>`: layout, naming, immutability and yank as clients see them |
| `index.md`, `index-record.schema.json`, `index-config.schema.json`, `takedowns.schema.json` | the static sparse index the CLI reads |
| `lock.md`, `lock.schema.json` | `mopm.lock`, the resolved closure |

## How the pieces fit

```text
 author                                   consumer
   |  mopm publish                           |  mopm add / sync
   v                                         v
 API  /api/v1  --(commit)-->  channel  <--(install, verify sha256)
 (openapi.yaml)               conda.<site>              ^
        |                     (channel.md)                |
        +--(regenerates)--> sparse index --(resolve)------+
                            (index.md)        |
                                              v
                                          mopm.lock (lock.md)
```

1. `mopm publish` asks the API to begin an upload per file, uploads the bytes,
   and commits. The registry validates, writes the file into the channel, and
   regenerates repodata and the sparse index.
2. `mopm add` reads the sparse index to find versions, writes the choice into
   `mopm.lock` with the sha256 and size from the index, and installs from the
   channel.
3. `mopm sync --locked` reads only the lock and verifies every download.
4. `pixi` and other conda tools read only the channel.

## Versioning

Everything here is additive-only once a CLI release depends on it:

- API: `/api/v1` gains optional fields, endpoints, enum values and error
  codes; it never removes or retypes anything. A breaking change is
  `/api/v2`, served beside `/api/v1`.
- Index: `index_version` in `config.json` and `v` in each record.
- Lock: `lock_version`.
- Metadata: `schema` in `<name>.mopm.json`.

Readers ignore unknown keys and refuse a higher version number than they know.

## Tests

`tests/contract/` holds example requests and responses for every API
operation, example index files and locks, and `validate.py`, which CI runs:

- the OpenAPI document is valid OpenAPI 3.1;
- every example request and response is valid against it, and counter-examples
  (marked `"expect": "invalid"`) are rejected, so the check can fail;
- the error catalogue is consistent: every `ErrorCode` has a status, message
  and hint, and every example error uses the catalogued status;
- every operation has at least one example;
- example index records, configs, takedown logs and locks validate against
  their schemas, and locks satisfy the rules in `lock.md`.

See `tests/contract/README.md`.
