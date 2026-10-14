# Pipelines

Workflows live in `.github/workflows/`:

| file | purpose |
|---|---|
| `deploy.yml` | `cdk deploy` of `service/infra/stacks` to one stage. Reusable (`workflow_call`) and manual (`workflow_dispatch`). |
| `e2e.yml` | Smoke/e2e against one stage. Reusable and manual. |
| `promote.yml` | beta deploy, e2e, gamma deploy, e2e, prod deploy, prod smoke, all at one commit SHA. |
| `lint.yml` | On PR: `bash -n` of every `run:` script, action pin check, account-id/secret scan. |

Stage settings with no secrets and no account ids are in `service/config/<stage>.json`.
The account id, region and role ARNs come from GitHub environment variables
(`AWS_ACCOUNT_ID`, `AWS_REGION`, `DEPLOY_ROLE_ARN`, `E2E_ROLE_ARN`) set on the
`beta`, `gamma` and `prod` environments. Nothing here holds a credential: jobs
request a GitHub OIDC token (audience `sts.amazonaws.com`) and call
`aws sts assume-role-with-web-identity`; the session credentials are masked and
live only in the job.

## Why two workflow files give different permissions

Both `deploy.yml` and `e2e.yml` run with `environment: <stage>`, so the standard
OIDC `sub` claim (`repo:ORG/REPO:environment:<stage>`) is identical for them.
An environment alone therefore cannot separate "may change infrastructure" from
"may only run tests". To separate them the repository's OIDC subject claim
template is customized to include `job_workflow_ref`, so the `sub` becomes
`repo:ORG/REPO:environment:<stage>:job_workflow_ref:ORG/REPO/.github/workflows/<file>@<ref>`.
For a reusable workflow `job_workflow_ref` names the called file, not the caller,
so `promote.yml` calling `deploy.yml` still presents `deploy.yml`.

The trust policies then use `StringEquals` on `sub`:

- the deploy role trusts only the `deploy.yml` subject for its stage;
- the e2e role trusts only the `e2e.yml` subject for its stage, and its IAM
  policy is limited to what the tests need (no CloudFormation, no IAM).

A change to `e2e.yml` cannot obtain the deploy role, and a deploy-time step
cannot be smuggled into e2e. Pin the ref in the trust policy to `refs/heads/main`
so a branch cannot mint either identity. (Whether `job_workflow_ref` works as a
plain IAM condition key is unproven; the custom `sub` is the fallback chosen.)
The access stack owns the roles and the trust policies.

## Promotion

`promote.yml` runs on `main` (or manually) at one commit. Each stage's deploy
reports the SHA it deployed; each e2e `needs:` its deploy, and each next deploy
`needs:` the previous e2e, so a red e2e stops the chain. `gamma` and `prod`
environments require a reviewer's approval, so those deploys wait for approval. A
`concurrency` group prevents two promotions interleaving.

## Settings made outside this repo

Nothing in this repository enforces these; check them in the GitHub and AWS
consoles (or the held bootstrap) before trusting a promotion:

- the `gamma` and `prod` environments' required reviewers;
- the repository's OIDC `sub` claim template (it must include `job_workflow_ref`);
- the role trust policies in `service/infra/access`, including the `refs/heads/main` pin.

`deploy.yml` and `e2e.yml` also have `workflow_dispatch`. That is safe only if
the role trust is pinned to `refs/heads/main`; confirm it with the access stack.
`lint.yml` checks that `promote.yml` keeps its `needs:` chain and has no job-level
`if:` or `continue-on-error`, but it cannot check the settings above.

The e2e smoke test requires `/api/v1/health` to report `stage` and `commit`; the
commit must equal the SHA the promote run deployed. The service must return it.

## CI triggers

`lint.yml` runs on pull requests and pushes to `main` only, to keep private-repo
minutes down. A branch push without a PR gets no check.

## Cost notes

The repository is private: keep to Linux runners. The macOS e2e job exists but is
disabled (`if: false`) because macOS minutes cost ten times Linux minutes.

## Not yet runnable

Deploy and e2e need the environments, roles and `service/infra/stacks`; until those exist
only `lint.yml` runs.
