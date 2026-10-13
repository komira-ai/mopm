# registry

The hosted registry at mopm.dev is a separate service. It is not built from
this repository, and its internals are not described here.

What this repository holds is the **contract** the registry and the CLI both
test against:

- `spec/api/openapi.yaml`: the HTTP API under `/api/v1`, with the error
  catalogue and the additive-only versioning rule;
- `spec/channel.md`: the conda channel served at `conda.<stage>.mopm.dev`;
- `spec/index.md`: the static sparse index the CLI reads;
- `spec/lock.md`: `mopm.lock`;
- `tests/contract/`: example requests, responses, index files and locks,
  validated in CI.

Read `spec/README.md` first.

Stages: beta (`beta.mopm.dev`, `conda.beta.mopm.dev`), gamma
(`gamma.mopm.dev`, `conda.gamma.mopm.dev`) and prod (`mopm.dev`,
`conda.mopm.dev`). Beta and gamma are disposable.

## Local fake registry (planned, not written yet)

The CLI's end-to-end tests must not need the network or any account. For that
this repository will contain a fake registry, `src/fake_registry`, written in
Zig, built by `zig build` into the test tree only. It will serve the contract
from a temporary directory it creates and deletes per test run.

Everything below is **planned**. Nothing in this list exists yet.

It will implement:

1. Every operation in `spec/api/openapi.yaml`, with the exact response shapes
   and the exact error codes and HTTP statuses of the catalogue.
2. Login: the device flow with an auto-approve switch (no GitHub), producing a
   fresh session token; token create, list and revoke; bearer-token checks for
   each security scheme, including expiry, revocation and the fresh-session
   rule.
3. Publish: begin upload, a presigned-style upload URL served by the fake
   itself that rejects bytes whose sha256 or size differ from the declared
   ones, commit, and status polling through `pending`, `validating`,
   `indexing` and `published` or `rejected`.
4. Immutability: create-once per version, including the rule that equal
   conda versions are the same version; yank and unyank; owners, invitations
   and the last-owner rule; claim; name normalisation.
5. The static side, written deterministically into the temporary directory:
   the channel (`repodata.json`, `repodata.json.zst`, `current_repodata.json`,
   `.conda` files per subdir) and the sparse index (`config.json`, package
   files, `takedowns.json`).
6. Fault switches, set from the test through a control interface that is not
   part of the contract: stale session, rate limited with `Retry-After`,
   read-only mode, a flipped byte in a served file, a dropped index line, a
   taken-down version answering 410.
7. Contract self-check: every response the fake produces in the tests is
   validated against `spec/api/openapi.yaml` by the same validator CI uses.

It will not implement: real GitHub or OIDC verification (it accepts a fixed
test key), archive security analysis beyond name, sha256 and size checks,
sharded repodata, storage, caching, rate limiting by IP, or anything about the
hosted service's deployment.
