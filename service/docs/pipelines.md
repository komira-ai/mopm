# Pipelines

Workflows live in `.github/workflows/`. The repository is public; read
[`docs/security/public-deploy.md`](../../docs/security/public-deploy.md) for the settings the
design depends on.

| file | runs on | purpose |
|---|---|---|
| `deploy.yml` | `workflow_call`, `workflow_dispatch` | `cdk deploy` of `service/infra/stacks` to one stage. Credentials only from `refs/heads/main`. |
| `e2e.yml` | `workflow_call`, `workflow_dispatch` | Smoke/e2e against one stage, with the e2e role. Same ref rule. |
| `promote.yml` | push to `main` touching `service/**`, `workflow_dispatch` | beta deploy, e2e, gamma deploy, e2e, prod deploy, prod smoke, all at one commit SHA. |
| `service-ci.yml` | pull request, push to `main` | Typecheck, tests and synth of the stacks; typecheck, tests and `bootstrap.sh` checks of the access stack. Read-only, no id-token. |
| `hygiene.yml` | pull request, push to `main` | `hygiene`: secret, key, token and account-id scan, trigger and id-token rules. `workflows`: SHA pins, permissions, `run:` scripts, the promotion `needs:` chain. |

Stage settings with no secrets and no account ids are in `service/config/<stage>.json`; a test
keeps them equal to what the stacks deploy. The account id, region and role ARNs come from GitHub
environment variables (`AWS_ACCOUNT_ID`, `AWS_REGION`, `DEPLOY_ROLE_ARN`, `E2E_ROLE_ARN`) set on the
`beta`, `gamma` and `prod` environments. Nothing here holds a credential: jobs request a GitHub OIDC
token (audience `sts.amazonaws.com`) and call `aws sts assume-role-with-web-identity`; the session
credentials are masked and live only in the job.

## Why two workflow files give different permissions

Both `deploy.yml` and `e2e.yml` run with `environment: <stage>`, so the default OIDC `sub` claim
is identical for them. To separate "may change infrastructure" from "may only run tests" the
repository's subject template includes `job_workflow_ref`, so the `sub` becomes
`repo:komira-ai/mopm:environment:<stage>:job_workflow_ref:komira-ai/mopm/.github/workflows/<file>@refs/heads/main`.
For a reusable workflow `job_workflow_ref` names the called file, so `promote.yml` calling
`deploy.yml` presents `deploy.yml`.

The trust policies (owned by `service/infra/access`) use `StringEquals` on `aud` and `sub`: the
deploy role trusts only the `deploy.yml` subject of its stage; the e2e role only the `e2e.yml` subject.
A change to `e2e.yml` cannot obtain the deploy role, and no branch other than `main` can obtain either.

## Promotion

`promote.yml` runs on `main` (or by hand) at one commit. Each stage's deploy reports the SHA it
deployed; each e2e `needs:` its deploy and each next deploy `needs:` the previous e2e, so a red e2e
stops the chain. The e2e step requires `/api/v1/health` to report `stage` and a `commit` equal to
that SHA. A `concurrency` group prevents two promotions interleaving. `workflows` in `hygiene.yml`
fails if the chain, the called files or the stages in `promote.yml` change, or if a promotion job gains an
`if:` or `continue-on-error`.

## Settings made outside this repository

Not enforced by any file here (full list in `docs/security/public-deploy.md`): branch protection on
`main`, code-owner review, the environments' required reviewers and branch policy, the OIDC `sub`
template, fork-run approval, the Actions allowlist.

## Dependency installs

`deploy.yml` installs with `npm ci --ignore-scripts` before any AWS credential exists. That needs
`package-lock.json`; CI generates it and uploads it as the `stacks-package-lock` artifact, to be reviewed
and committed. Until it is committed, `deploy.yml` fails at install, which is the safe direction.
