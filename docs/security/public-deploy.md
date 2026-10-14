# Deploying from a public repository

This repository is public, and it also deploys the registry service (`service/`) to AWS
accounts through GitHub Actions. Anyone can read the workflows and open a pull request.
This page lists what the design relies on, split into what the repository enforces by
itself and the GitHub settings only the repository owner can make. **Nothing in the second
list is enforced by files in this repository**: until the owner has set it, treat the
corresponding row as open.

## What the repository enforces

| Control | Where | Closes |
|---|---|---|
| Credential-minting jobs (`id-token: write`) exist only in `deploy.yml`, `e2e.yml` and `promote.yml`, which trigger only on `push` to `main`, `workflow_dispatch` and `workflow_call` | `hygiene` job | A pull request, or a workflow added later, obtaining an OIDC token |
| A `guard` job fails anything but `refs/heads/main` and any event but `push` / `workflow_dispatch`; the credential job needs it and repeats the ref test | `deploy.yml`, `e2e.yml`; `workflows` job checks the shape | A manual run from a feature branch deploying unreviewed code |
| No `_target` variant of the pull-request trigger, no `workflow_run`, no `issue_comment` anywhere; no `secrets: inherit` | `hygiene`, `workflows` jobs | The classic "privileged trigger runs attacker code" injection |
| Top-level permissions are read-only in every workflow; `write` appears only as `id-token` in the three files above | `workflows` job | A compromised step escalating the repository token |
| Only GitHub-owned actions, pinned by full commit SHA | `workflows` job | A moved tag or third-party action stealing credentials |
| `run:` scripts never interpolate `${{ ... }}`; stage and event fields enter through `env:` | `workflows` job | Script injection from inputs or event data |
| No AWS keys, account ids, ARNs carrying an account id, private keys, tokens, JWTs in any tracked file | `hygiene` job | Leaking secrets or account identity into a public tree |
| Role trust is `StringEquals` on `aud` and on a `sub` that names this repository, the stage environment, the exact workflow file and `refs/heads/main` | `service/infra/access`, asserted by its tests | Another repository, branch, environment or workflow file assuming a stage role |
| The deploy role can only assume the CDK bootstrap roles of its account; the e2e role reads one secret and the channel bucket, with `e2e_*` cleanup on beta and gamma only | `service/infra/access` | A hijacked e2e run changing infrastructure |
| The CloudFormation execution policy is scoped to `mopm-<stage>-*`, has no `kms:*`, conditions role-policy attachment, and denies edits to the access roles, OIDC provider and bootstrap roles | `cfn-exec-policy.template.json` | A deploy widening its own access |
| The access bootstrap is a held script: dry run unless `--apply`, flags only, the admin's own credentials | `service/infra/access/bootstrap.sh` | Standing CI access to IAM |
| Account id, region and role ARNs are GitHub environment variables, never files | workflows, `hygiene` job | Account identity in a public tree |

## Settings only the repository owner can make

Each row says what to set and the attack it closes. Settings 1 to 3 matter most: a push to
`main` starts a beta deploy.

| # | Setting (Settings page) | Value | Closes |
|---|---|---|---|
| 1 | Branches: ruleset or protection on `main` | Require a pull request; at least one approval; require review from Code Owners; dismiss stale approvals; require approval of the most recent push; require status checks `hygiene`, `workflows`, `stacks`, `access` and the `ci` tests, with branches up to date; block force pushes and deletion; no bypass list; apply to administrators | Direct pushes and unreviewed merges, which would deploy; weakening a check in the same change that needs it |
| 2 | `.github/CODEOWNERS` | Replace the placeholder handle with the CEO's handle or a team; owners for `/.github/`, `/service/`, `/docs/security/` | A contributor editing workflows, trust policies or the lint scripts with only an ordinary review. The scripts under `.github/scripts/` run from the pull request's own head, so only review protects them |
| 3 | Environments: `beta`, `gamma`, `prod` | Deployment branches: selected branches, `main` only. Required reviewers on `gamma` and `prod` (and on `beta` if wanted); prevent self-review; disable administrator bypass. Variables (not secrets): `AWS_ACCOUNT_ID`, `AWS_REGION`, `DEPLOY_ROLE_ARN`, `E2E_ROLE_ARN` | A run from another branch reading stage variables or presenting the stage environment; promoting to gamma or prod without a human |
| 4 | Actions, General: fork pull request workflows | Require approval for all outside contributors (not only first-time); do not send write tokens or secrets to fork workflows | Fork pull requests spending minutes, or probing the runner, before a maintainer looks |
| 5 | Actions, General: workflow permissions | Read repository contents only; leave "Allow GitHub Actions to create and approve pull requests" off | A workflow approving or merging its own pull request; a token with write by default |
| 6 | Actions, General: allowed actions | Allow actions created by GitHub only; require actions to be pinned to a full-length commit SHA | A third-party action, or a moved tag, running with credentials |
| 7 | Code security: secret scanning and push protection | Both on (include validity checks) | A credential committed by accident staying in history |
| 8 | Code security: Dependabot | Alerts and version updates for `github-actions` and `npm` (`service/infra/stacks`, `service/infra/access`) | Stale pinned actions and vulnerable CDK dependencies |
| 9 | Code security: private vulnerability reporting | On (`SECURITY.md` points to it) | Public disclosure of an unfixed hole |
| 10 | Actions, Runners | GitHub-hosted runners only; register no self-hosted runner | A persistent runner kept by a hostile pull request |
| 11 | OIDC subject claim: `PUT /repos/komira-ai/mopm/actions/oidc/customization/sub` with `use_default=false` and `include_claim_keys` = `repo`, `context`, `job_workflow_ref` | Set once, before the first deploy; verify with the matching `GET` | Without it the `sub` is the same for `deploy.yml` and `e2e.yml`, so a test job could assume the deploy role. With it, the roles trust one workflow file each |
| 12 | Organization: who may create repositories and teams | Do not delete or rename `komira-ai/mopm` while the roles exist | The role trust names the repository. A repository re-created under the same name would match the same `sub`. Delete the stage access stacks first |

## Order of operations

1. Set 1 to 10 on the repository (the owner).
2. Set 11 (the OIDC subject template).
3. Per stage, an administrator runs `service/infra/access/bootstrap.sh` with their own
   credentials (dry run first; see `service/infra/access/BOOTSTRAP.md`).
4. Create the three environments (setting 3) and store the four variables on each.
5. Merge. The push to `main` runs `promote.yml`; `gamma` and `prod` wait for a reviewer.

## Known limits

- **Variables are not secrets.** `vars.*` values are printed in the step header of public
  logs. The workflows mask the role ARN and account id once their step starts, but the
  value in that first header is visible. AWS does not treat an account id as secret. If the
  owner wants them hidden, store them as environment secrets and change `vars.` to `secrets.`.
- **Inline role policies.** The deploy can write inline policies on `mopm-<stage>-*` roles,
  which a permissions boundary would bound. Recorded in `BOOTSTRAP.md`; the guard is the
  reviewed `main` plus the environment reviewers.
- **Lockfiles.** Direct dependencies are pinned to exact versions; the lockfiles are generated by
  CI and committed after review. `deploy.yml` uses `npm ci --ignore-scripts`.
- **`sub` carries no `ref`.** With the template above the branch is enforced by
  `job_workflow_ref` (`@refs/heads/main`) and the environment's branch policy, not by a
  separate `ref` claim. Both are set; losing either alone does not open a role.
- **The lint runs from the pull request.** A pull request can edit the checks that judge
  it; setting 2 and the required reviewer are what stop that.
