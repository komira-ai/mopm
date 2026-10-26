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

## Addendum: a CI identity that acts for an account, on prod

Status: accepted for prod (the CEO approved acting as the owner account, an open-group slot hold with an abort job, and a hash-pinned
local test of the staged files plus a smoke test after the commit, with no download route). Touches: the CI publisher row
(`acts_for`), the OIDC exchange, the principal and its audit marks, the loader's stage gate, the prod API function's environment.

### Context

The beta identity owns the packages it creates (`ci_owner`). On prod the packages already belong to a person: they are claimed by an
account with that account's login, and the registry's one groups switch (`groups_enabled`) names that account. A beta-style row on prod
would have given new names to a repository identity instead, and would have refused every name the account had already claimed.

### Decision

1. **A row may carry `acts_for`: a GitHub account id.** For such a row the `packages` form of the exchange verifies the same pins as
   beta (repository id, owner id, workflow file, `job_workflow_ref`, ref, event, environment, audience) and mints a token whose principal
   is that account (`github_id`), scoped to exactly the listed packages and versions, ten minutes, one exchange per CI `jti`. The token
   has no `ci_owner`, so everything downstream treats it as the account: the actor is `u:<id>`, `requireOwner` reads the owner rows, the
   groups switch and the per-account budgets apply, and a group made by the token is the group the account would make for the same set.
2. **It creates nothing.** Every name must already be claimed by the account: an unclaimed name is `package_not_found`, anyone else's
   (or a CI-owned) package is `not_owner`, and both are decided before the CI token is spent or a token is minted. No `ci_claim`
   audit entry, no `ci_owner`.
3. **Less than a login.** The token is kind `oidc`: it cannot claim a name, mint or revoke tokens, or pass as a fresh session, and it is
   not listed among the account's tokens or counted against their limit.
4. **Marked.** The token records the CI identity it came through (`acts_via`). The group header, the upload and publish records and the
   audit entries of create, reserve, stage, commit request, abort and yank request carry `via` = `ci:gh-repo:<repository_id>`; an
   account's own request carries none. The actor stays `u:<id>` on purpose: the group id, the per-actor list of open groups and the
   groups policy are the account's, which is what lets one group be created by CI and continued by CI tokens of later jobs.
5. **Prod loads only such rows.** `parseCiPublishers` accepts a value on beta (any row) and on prod only when every row carries
   `acts_for`; every other stage, and a prod row without it, stops the function from starting. The stack sets the variable on prod
   (`PROD_CI_PUBLISHERS`, environment `prod`, `push` only) and not on gamma; beta's row is unchanged. No groups policy is set on prod: the
   `groups_enabled` item stays the human switch.

### Consequences

- **The account's authority is lent to one workflow.** Anyone who can push to `komira-ai/komira` main and approve the `prod`
  environment can publish new versions of every package the account owns, in the `packages` and versions they ask for. The pins and
  the environment are the whole gate; the audit mark is how a later reader tells it from the account.
- **The audience on prod is the bare domain `mopm.dev`** (the existing prod table); the environment, not the audience, separates the
  prod identity from a beta one, so a token from the `beta` environment is refused.
- **A job that dies between stage and commit holds the account's open-group slot** until the group's deadline; the release workflow
  aborts it with a fresh exchange. Accepted.
- **Removing the trust is a deploy without the row** (runbook: "Prod trusts a CI identity that acts for an account"). Tokens already
  minted live out their ten minutes. `groups_enabled` is the way to stop groups at once, for the human account too.
- The template diff between gamma and prod gains exactly one difference: the API function's `CI_PUBLISHERS` variable.
