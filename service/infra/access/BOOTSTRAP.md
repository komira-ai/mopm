# Access bootstrap (once per stage account)

A human admin does this once per stage (`beta`, `gamma`, `prod`) with their own credentials.
Nothing in CI holds standing access: after this, GitHub Actions assumes `mopm-<stage>-deploy`
through OIDC for at most one hour, and that role can only assume the CDK bootstrap roles.
This repository is public: account ids, role ARNs and regions are never committed; they are GitHub
environment variables, and the admin passes them to the script as flags. The full list of GitHub
settings this design relies on, and the attack each closes, is `docs/security/public-deploy.md`.

## What the access stack creates

- the GitHub OIDC provider (`token.actions.githubusercontent.com`, audience `sts.amazonaws.com`);
- `mopm-<stage>-deploy`: trusted only for `deploy.yml` on `main` in the `<stage>` environment;
  permission: `sts:AssumeRole` on this account's `cdk-hnb659fds-*` roles, nothing else;
- `mopm-<stage>-e2e`: trusted only for `e2e.yml` on `main` in the `<stage>` environment;
  `secretsmanager:GetSecretValue` on one secret (`mopm/<stage>/e2e/test-identity-*`), read on the
  channel bucket, `e2e_*` cleanup on beta and gamma only (nothing that writes on prod).

## Trust condition (documented format)

GitHub documents the customised subject claim: with `include_claim_keys` set to
`["repo","context","job_workflow_ref"]` the `sub` is
`repo:<owner>/<repo>:environment:<environment>:job_workflow_ref:<owner>/<repo>/.github/workflows/<file>@<ref>`
(GitHub docs, "OpenID Connect reference", customizing the subject claim; example
`repo:octo-org/octo-repo:environment:prod:job_workflow_ref:octo-org/octo-automation/.github/workflows/oidc.yml@refs/heads/main`).
This matches the string the stack uses, so no deviation. `context` expands to `environment:<name>` for
jobs that use an environment. AWS documents the condition keys as `token.actions.githubusercontent.com:aud`
and `token.actions.githubusercontent.com:sub` (IAM docs, "Create a role for OpenID Connect federation" and
GitHub's "Configuring OpenID Connect in Amazon Web Services"). Both are `StringEquals`, no wildcards.
The `job_workflow_ref` includes `@refs/heads/main`, so a branch other than `main` cannot assume the roles.

## Steps per stage

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

Skip the OIDC provider if the account already has one for GitHub (only one may exist per account and URL).

## GitHub settings (once)

1. Customise the subject claim for the repo (needs repo admin):
   ```sh
   gh api -X PUT repos/komira-ai/mopm/actions/oidc/customization/sub \
     -F use_default=false -f 'include_claim_keys[]=repo' -f 'include_claim_keys[]=context' -f 'include_claim_keys[]=job_workflow_ref'
   ```
   (`PUT /repos/{owner}/{repo}/actions/oidc/customization/sub`). Verify with the matching `GET`.
2. Create environments `beta`, `gamma`, `prod` (Settings, Environments). On `gamma` and `prod` add
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
