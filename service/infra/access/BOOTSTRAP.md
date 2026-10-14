# Access bootstrap (once per stage account)

A human admin does this once per stage (`beta`, `gamma`, `prod`) with their own credentials.
Nothing in CI holds standing access: after this, GitHub Actions assumes `mopm-<stage>-deploy`
through OIDC for at most one hour, and that role can only assume the CDK bootstrap roles.
This repository is public: account ids, role ARNs and regions are never committed; they are GitHub
environment variables, and the admin passes them to the script as flags. The full list of GitHub
settings this design relies on, and the attack each closes, is `docs/security/public-deploy.md`.

## What the access stack creates

- the GitHub OIDC provider (a native `AWS::IAM::OIDCProvider`, no Lambda or custom resource; `token.actions.githubusercontent.com`, audience `sts.amazonaws.com`);
- `mopm-<stage>-deploy`: trusted only for `deploy.yml` on `main` in the `<stage>` environment;
  permission: `sts:AssumeRole` on this account's `cdk-hnb659fds-*` roles, nothing else;
- `mopm-<stage>-e2e`: trusted only for `e2e.yml` on `main` in the `<stage>` environment;
  `secretsmanager:GetSecretValue` on one secret (`mopm/<stage>/e2e/test-identity-*`), read on the
  channel bucket, `e2e_*` cleanup on beta and gamma only (nothing that writes on prod).

## Trust condition (documented format)

This repository uses GitHub's immutable subject claims (`use_immutable_subject` true, `sub_claim_prefix`
`repo:komira-ai@305577347/mopm@1418104703`, i.e. `repo:<owner>@<owner id>/<repo>@<repo id>`; the ids
are public and live in `lib/contract.ts`). GitHub documents the immutable format as
`repo:OWNER@OWNER-ID/REPO@REPO-ID:ref:refs/heads/BRANCH`, says the repo segment of a customised
template always carries the ids ("You can't remove these IDs from the immutable format"), and says to
update cloud trust policies to match (GitHub docs, "OpenID Connect reference",
https://docs.github.com/en/actions/reference/security/oidc). With `include_claim_keys`
`["repo","context","job_workflow_ref"]` the stack therefore trusts
`repo:komira-ai@305577347/mopm@1418104703:environment:<stage>:job_workflow_ref:komira-ai/mopm/.github/workflows/<file>@refs/heads/main`.

The docs give no complete example of this exact combination, and their `job_workflow_ref` examples
use names, not ids. The stack keeps `job_workflow_ref` in its documented name form. That is an
inference, so step 0 below prints the real claims before anything is bootstrapped; if the printed
`sub` differs, change `subFor` in `lib/github-access-stack.ts` and its test to match, nothing else.
AWS documents the condition keys as `token.actions.githubusercontent.com:aud` and `...:sub` (IAM
docs, "Create a role for OpenID Connect federation"). Both are `StringEquals`, no wildcards. The
`job_workflow_ref` includes `@refs/heads/main`, so a branch other than `main` cannot assume the roles.

## Step 0: confirm the exact `sub` (before any bootstrap)

Run the `oidc-subject-check` workflow on `main` (Actions tab, "Run workflow"). It holds no AWS access and
uses no secrets or environment secrets. It has two jobs: `claims-no-environment` and
`claims-environment-beta` (runs inside the `beta` environment, so the `environment:beta` form is shown).
Each prints only the `sub`, `job_workflow_ref`, `environment` and `repository_id` claims, never the token.
Compare the beta job's `sub` with
`repo:komira-ai@305577347/mopm@1418104703:environment:beta:job_workflow_ref:komira-ai/mopm/.github/workflows/<file>@refs/heads/main`
(the `job_workflow_ref` of this check is `oidc-subject-check.yml`; the deploy and e2e files differ only there).
Stop and fix the stack if the prefix, the ids or the `job_workflow_ref` form differ.

## Step 1: DNS (once, before any stack deploys)

The service stacks look up the Route 53 zone of their stage by name, so the zones must exist first. Follow
`service/infra/dns/README.md` in order: zone in prod, GoDaddy nameservers, zones in beta and gamma, delegation
from prod, `dig` verification. It needs no `cdk bootstrap`, so it can run before the per-stage steps below.

## Step 2: access, per stage

Run from a checkout of this repo. Preview first (the script prints and executes nothing without `--apply`):

```sh
service/infra/access/bootstrap.sh --stage beta --account <12-digit id> --region <region> --profile <your profile>
service/infra/access/bootstrap.sh --stage beta --account <id> --region <region> --profile <your profile> --apply
```

It does, in order:
1. creates the managed policy `mopm-<stage>-cfn-exec` from `cfn-exec-policy.template.json` (name-scoped to
   `mopm-<stage>-*`, denies on the access roles, the OIDC provider and the bootstrap roles; not AdministratorAccess);
2. `cdk bootstrap aws://<account>/<region> --cloudformation-execution-policies arn:aws:iam::<account>:policy/mopm-<stage>-cfn-exec`;
3. `cdk deploy mopm-<stage>-access` (context flags `stage`, `account`, `region`; the trusted repository is fixed to `komira-ai/mopm` in `lib/contract.ts`).

### Why the access stack bypasses the scoped execution role

Step 3 deploys with the admin's own credentials (the stack uses `CliCredentialsStackSynthesizer`), not
through the bootstrap deploy role and `cdk-hnb659fds-cfn-exec-role`. This is deliberate: the scoped policy from
step 1 denies `iam:CreateOpenIDConnectProvider` and `iam:*` on `mopm-<stage>-deploy`, `mopm-<stage>-e2e`, the
`cdk-hnb659fds-*` roles and the OIDC provider, so that later (automated) deploys can never touch the access
layer. The access stack is exactly those resources, so through that role it would be denied and roll back.
The deny statements stay unchanged; only a human with their own credentials creates or changes the access stack.
The OIDC provider carries no thumbprint list: AWS no longer requires thumbprints for GitHub's provider
(it validates against its trusted root CAs) and the CloudFormation property is optional.

Skip the OIDC provider if the account already has one for GitHub (only one may exist per account and URL).

## GitHub settings (once)

1. Customise the subject claim for the repo (needs repo admin):
   ```sh
   gh api -X PUT repos/komira-ai/mopm/actions/oidc/customization/sub \
     -F use_default=false -f 'include_claim_keys[]=repo' -f 'include_claim_keys[]=context' -f 'include_claim_keys[]=job_workflow_ref'
   ```
   (`PUT /repos/{owner}/{repo}/actions/oidc/customization/sub`). Verify with the matching `GET`.
2. Create environments `beta`, `gamma`, `prod` (Settings, Environments). On all three add
   required reviewers (and prevent self-review). On all three set deployment branches to "Selected
   branches": `main` only. The roles' trust policies repeat both limits (environment and
   `refs/heads/main` in `job_workflow_ref`), so a loosened GitHub setting alone does not open a role.
3. In each environment store, as **secrets**: `AWS_ACCOUNT_ID` and `AWS_REGION`. Nothing else is stored:
   the workflows build the role ARNs (`arn:aws:iam::<id>:role/mopm-<stage>-deploy` and `-e2e`) inside
   the job and mask them.

## Verification

Run `deploy.yml` on `main` for `beta`: `aws sts get-caller-identity` must show the deploy role. The same
workflow from another branch must fail at the environment's branch policy, and if that were
loosened, at `AssumeRoleWithWebIdentity`.

## Known residual risk

The CloudFormation execution policy lets a deploy create stage roles and write inline policies on them (`iam:PutRolePolicy` on `mopm-<stage>-*`). Managed-policy attachment is limited by `iam:PolicyARN`, but inline policies are not boundable without a permissions boundary. Anyone who can run the deploy workflow on `main` can therefore widen a stage role. Accepted for now: the deploy role only assumes from `main` in the stage environment, which carries the review gate. Revisit with a permissions boundary.
