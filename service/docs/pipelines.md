# Pipelines

Workflows live in `.github/workflows/`. The repository is public; read
[`docs/security/public-deploy.md`](../../docs/security/public-deploy.md) for the settings the
design depends on.

| file | runs on | purpose |
|---|---|---|
| `deploy.yml` | `workflow_call`, `workflow_dispatch` | `cdk deploy` of `service/infra/stacks` to one stage. Credentials only from `refs/heads/main`. |
| `e2e.yml` | `workflow_call`, `workflow_dispatch` | Smoke/e2e against one stage, with the e2e role. Same ref rule. |
| `promote.yml` | push to `main` (paths `service/**` and the three workflows it uses) and `workflow_dispatch`; automatic, no manual approval | beta deploy, e2e, gamma deploy, e2e, prod deploy, prod smoke, all at one commit SHA. |
| `service-ci.yml` | pull request, push to `main` | Typecheck, tests and synth of the stacks; `npm ci` of both packages (the same install the deploy runs, so a missing or stale `package-lock.json` fails on a pull request); typecheck, tests and `bootstrap.sh` checks of the access stack. Read-only, no id-token. |
| `oidc-subject-check.yml` | `workflow_dispatch` | Step 0 of the bootstrap: prints the `sub`, `job_workflow_ref`, `environment` and `repository_id` claims, once without an environment and once in `beta`. No AWS, no secrets. The only other file allowed `id-token`. |
| `farm.yml` (`//:hygiene`, `//:workflows`, `//:lint_selftest`) | pull request | `//:hygiene`: secret, key, token and account-id scan, trigger and id-token rules. `//:workflows`: SHA pins, permissions, `run:` scripts, the promotion `needs:` chain. `//:lint_selftest`: both lints against known-bad fixtures. Zig tests built on the farm. |

Stage settings with no secrets and no account ids are in `service/config/<stage>.json`; a test
keeps them equal to what the stacks deploy. The account id, region and role ARNs come from GitHub
environment secrets (`AWS_ACCOUNT_ID`, `AWS_REGION`) set on the
`beta`, `gamma` and `prod` environments; the role ARNs are built from them in the job. Nothing here holds a credential: jobs request a GitHub OIDC
token (audience `sts.amazonaws.com`) and call `aws sts assume-role-with-web-identity`; the session
credentials are masked and live only in the job.

## Why two workflow files give different permissions

Both `deploy.yml` and `e2e.yml` run with `environment: <stage>`, so the default OIDC `sub` claim
is identical for them. To separate "may change infrastructure" from "may only run tests" the
repository's subject template includes `job_workflow_ref`, so the `sub` becomes
`repo:komira-ai@305577347/mopm@1418104703:environment:<stage>:job_workflow_ref:komira-ai/mopm/.github/workflows/<file>@refs/heads/main`
(the repository uses immutable subject claims, so the repo segment carries the owner and repo ids; see
`service/infra/access/BOOTSTRAP.md`, step 0, which prints the real claims).
For a reusable workflow `job_workflow_ref` names the called file, so `promote.yml` calling
`deploy.yml` presents `deploy.yml`.

The trust policies (owned by `service/infra/access`) use `StringEquals` on `aud` and `sub`: the
deploy role trusts only the `deploy.yml` subject of its stage; the e2e role only the `e2e.yml` subject.
A change to `e2e.yml` cannot obtain the deploy role, and no branch other than `main` can obtain either.

## Promotion

`promote.yml` runs automatically on every merge to `main` that touches `service/**`, `promote.yml`, `deploy.yml` or `e2e.yml`, and by hand (`workflow_dispatch`) from `main`. Deployments are automatic and need no manual approval (CEO decision 2026-10-14); the gates are the beta and gamma e2e suites and the prod smoke, and the environments keep their `main`-only branch policy. The called workflows refuse any other ref. Each stage's deploy reports the SHA it
deployed; each e2e `needs:` its deploy and each next deploy `needs:` the previous e2e, so a red e2e
stops the chain. The e2e step requires `/api/v1/health` to report `stage` and a `commit` equal to
that SHA. A `concurrency` group (`cancel-in-progress: false`) queues pushes so two promotions never deploy one stage at once. `//:workflows`
fails if the triggers are anything but `push` (branches `main`) and `workflow_dispatch`, if the concurrency group is missing or cancels in progress, or if the chain, the called files or the stages in `promote.yml` change, or if a promotion job gains an
`if:` or `continue-on-error`.

Every job in `promote.yml` that calls `deploy.yml` or `e2e.yml` sets `secrets: inherit`. The called jobs
read `AWS_ACCOUNT_ID` and `AWS_REGION` from their stage's environment secrets (the repository has no
repository-level secrets), and a reusable workflow sees only the secrets its caller passes; without it
they arrive empty and the role step stops with "secrets AWS_ACCOUNT_ID and AWS_REGION must be set". A
direct `workflow_dispatch` of `deploy.yml` does not need it. See GitHub's "Reusing workflows" and the
workflow syntax reference for `jobs.<job_id>.secrets`. `//:workflows` requires it on every reusable
call in `promote.yml` and rejects `secrets: inherit` in any other workflow; `//:lint_selftest` has a
promote fixture without it that must fail.

## Settings made outside this repository

Not enforced by any file here (full list in `docs/security/public-deploy.md`): branch protection on
`main`, code-owner review, the environments' branch policy, the OIDC `sub`
template, fork-run approval, the Actions allowlist.

## Dependency installs

`deploy.yml` installs with `npm ci --ignore-scripts` before any AWS credential exists. That needs
`package-lock.json`; CI generates it and uploads it as the `stacks-package-lock` artifact, to be reviewed
and committed. Until it is committed, `deploy.yml` fails at install, which is the safe direction.
