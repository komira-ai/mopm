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
   exact ref), `job_workflow_ref` (the token's claim of that name, written out in full and ending in the entry's own
   `/<workflow>@<ref>`), `events` (a subset of `push` and `workflow_dispatch`; the code allows both, a deployment lists what it
   trusts) and `environment`. Every field is required and every field is matched exactly; names never match, ids do. The code
   validates the value whole or refuses it. Beta trusts the komira release workflow on `push` only, never a manual run, and pins
   `job_workflow_ref` as well as `workflow_ref`: `workflow_ref` names the workflow that was triggered and `job_workflow_ref` the file
   the running job is defined in, so a reusable workflow called from the right file (or `release.yml` called by another) does not match.
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
5. **One grant.** Creating a package is a conditional PutItem on the packages table. It is the grant the claim route already has on
   every stage (`ClaimPackages`), so the CI exchange adds no grant of its own; what only beta has is the `CI_PUBLISHERS` variable.
   Gamma and prod have no variable, so they refuse the `packages` form of the exchange.

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
- Groups are the addendum below (they needed an account token before it). Unchanged and out of scope: yanking a single version beyond
  the exact version a token was minted for, and removing or transferring a CI-owned package.

## Alternatives considered

- Seed owner rows for the repository (a synthetic account): pollutes the by-account index and needs a write outside the service.
- A repository variable or secret that switches trust on: a GitHub setting write; a checked-in value needs none.
- Trust on every stage from the same value: rejected; the human step at gamma and prod stays.

## Addendum: the identity creates groups, and beta says so in code

Touches: auth and ownership (`actorOf`, the group create check), groups (create, read, abort, commit, yank), infrastructure (a second
beta-only environment variable).

### Decision

1. **The identity's token creates a group.** `POST /groups` accepts, next to an account's API token, the token of a configured CI
   publisher (an `oidc` token that carries `ci_owner`). Every member must be covered by the token (the package and the exact version it
   was minted for) and owned by the identity (`PackageRecord.ci_owner`, the check single publishes already make); the first member that is
   not refuses the whole request (`scope_missing` or `not_owner`) before anything is written. A CI token without an identity (one minted
   for a package's registered trusted publisher) still creates no group.
2. **One actor per identity.** The actor of a configured CI publisher's token is `ci:gh-repo:<repository_id>`, whichever token it holds;
   an account is `u:<github id>` as before; any other CI token keeps `ci:<token id>`. The actor is what the group's header, the audit rows
   of its members, the upload records, the per-actor list of open groups and the policy name, so a later job's token reads, commits,
   aborts and yanks the group an earlier job's token created, and another identity or an account cannot (`group_not_found`). `yank
   --group` also needs the token to cover every member and the identity to own every member now. The daily group budget is counted per
   identity (a new token every job would otherwise start a new count).
3. **A static policy, beta only.** `MOPM_GROUPS_POLICY` is `{"mode":"allow","actors":["ci:gh-repo:<repository_id>", ...]}`: one to eight CI
   actors, no `all`, no account, no `deny`, no other key. The stack sets it when the stage is `beta` (`BETA_GROUPS_POLICY`, derived from
   the same constant as the trusted publisher) and never otherwise, and the runtime refuses to start on any other stage when the
   variable is present (`parseStaticGroupsPolicy`, called by `flagsFor`). The existing flags read the static policy and the `groups_enabled`
   item and either admitting the actor is enough.

### Consequences

- **A static policy cannot be switched off at runtime.** It is ORed with the config table's item and a `deny` in the item does not
  override it, so on beta `groups_enabled` `off` does not stop the identity. Stopping it takes a deploy (remove the policy). This is
  accepted for beta, which is disposable; gamma and prod have no such policy and keep the human flip.
- The template diff between beta and gamma is exactly two environment variables of the API function: `CI_PUBLISHERS` and
  `MOPM_GROUPS_POLICY`. The test that pins it fails on a third.
- The upload and publish records of a configured identity now carry the identity's actor instead of a per-token one: the status of
  a publish is readable by any token of the same identity, which is the intent (one job starts a publish, another may poll it).
- Unchanged: the exchange, the single-version publish path, ownership of accounts, and what gamma and prod do.
