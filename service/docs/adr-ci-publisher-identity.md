# ADR: a CI publisher identity that the beta stage trusts by configuration

Status: accepted for the beta stage. Gamma and prod do not have it.

Touches: auth (the OIDC exchange), ownership (`PackageRecord.ci_owner`, `requireOwner`), infrastructure (the API function's
environment and one table grant).

## Context

A repository's CI should be able to publish its packages to a registry without a person logging in, minting a token and storing it
as a secret. The service already exchanges a GitHub Actions identity token for a ten minute publish token, but only for a
*trusted publisher that a package's owner registered*, and only for a package that already exists. Nothing in the deployed
service creates a package (the claim route is a separate change), and nothing registers a publisher. So a repository that has no
account owner behind it cannot publish its first package at all.

## Decision

1. **The deployment can name a CI publisher.** The API function reads `CI_PUBLISHERS`, a JSON array of at most eight entries:
   `repository_id`, `repository_owner_id` (GitHub's numeric ids, as strings), `workflow` (a file under `.github/workflows/`), `ref` (one
   exact ref), `events` (a subset of `push` and `workflow_dispatch`) and `environment`. Every field is required and every field is
   matched exactly; names never match, ids do. The code validates the value whole or refuses it.
2. **Beta only, twice.** The CDK stack sets `CI_PUBLISHERS` when the stage is `beta` and never otherwise; and the service refuses to
   start when the variable is present on any other stage (`parseCiPublishers`), so a mistake in the infrastructure cannot turn the
   trust on at gamma or prod. Tests pin both: the gamma and prod templates carry neither the variable nor the grant, and the loader
   throws for them.
3. **Identity and ownership.** The identity is `gh-repo:<repository_id>`. A package it creates is `claimed` and carries
   `ci_owner` with that identity; it has no account owner row. `requireOwner` for a CI token compares the token's identity with the
   package's `ci_owner`; it no longer returns success for every CI token. A package an account owns, or another identity owns, is
   refused (`not_owner`); a package with a `ci_owner` is refused to account tokens (no owner rows) and to tokens minted for a
   registered trusted publisher.
4. **The exchange takes the packages.** `POST /auth/oidc/exchange` accepts `{jwt, packages: [{name, version}, ...]}` (one to 100)
   next to the existing `{jwt, name, version}`. For the new form the exchange verifies the token (audience of the stage, exactly one
   exchange per token, `ref` and event checked), matches it to the configured publisher, checks every named package is unclaimed or already
   the identity's, then creates the missing ones and mints a ten minute token that is good for exactly those packages at exactly
   those versions, acting as the identity. Names owned by someone else make the whole request fail before anything is created or the
   token is spent.
5. **One grant.** Creating a package is a conditional PutItem on the packages table. Beta's function gets it (`CiCreatePackages`);
   gamma and prod do not.

## Consequences

- A merge that changes `BETA_CI_PUBLISHERS` in `service/infra/stacks/lib/api-stack.ts` is the whole act of changing who beta trusts.
  The deploy of beta by the promote workflow applies it; there is no console step and no stored secret. This is a second way to
  decide trust next to registering a publisher, and a static value cannot be switched off at runtime: removing it takes a deploy.
- Gamma and prod are unchanged: nothing there reads the variable, no function there may create a package, and the new request form
  answers `oidc_not_trusted` there. Whether and how they trust a CI identity stays a human decision, taken later.
- The exchange form is an extension that the OpenAPI document does not describe yet. It is added to the document when a client
  other than the repository's own job uses it, or when it reaches a stage beyond beta.
- A package a CI identity created is findable and publishable like any other, but it has no owners to list: `GET /packages/{name}`
  returns an empty `owners`.
- Unchanged and out of scope: groups (a group needs an account token today), yanking beyond the exact version a token was minted for,
  and removing or transferring a CI-owned package.

## Alternatives considered

- Seed owner rows for the repository (a synthetic account): pollutes the by-account index and needs a write outside the service.
- A repository variable or secret that switches trust on: a GitHub setting write; a checked-in value needs none.
- Trust on every stage from the same value: rejected; the human step at gamma and prod stays.
