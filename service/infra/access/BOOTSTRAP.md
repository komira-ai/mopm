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
   `mopm-<stage>-*`, denies on the access roles, the OIDC provider and the bootstrap roles; not AdministratorAccess).
   Resumable: if the policy exists with an identical document it is skipped; if it exists with a different one the
   script stops with a message and changes nothing, unless you pass `--update-policy` (see "Changing the execution policy");
2. `cdk bootstrap aws://<account>/<region> --cloudformation-execution-policies arn:aws:iam::<account>:policy/mopm-<stage>-cfn-exec -c stage=<stage> -c account=<account> -c region=<region>`;
3. `cdk diff mopm-<stage>-access` (same context), always, printed before anything is deployed;
4. `cdk deploy mopm-<stage>-access` (same context; the trusted repository is fixed to `komira-ai/mopm` in `lib/contract.ts`)
   with `--require-approval broadening`, so CDK asks before IAM or security-group broadening. In a non-interactive shell
   pass `--approve-iam` (`--require-approval never`), only after a human has reviewed the diff printed in step 3.

Lesson from the beta run: `cdk bootstrap` also loads the app (`bin/access.ts`), which throws `missing context -c stage=...`
without the context flags, so all three `-c` values go on every cdk command. The first run had to be finished by hand
(bootstrap with the flags, `cdk diff`, `cdk deploy ... --require-approval never` after reviewing the IAM diff); the script
now does that, and a re-run after a partial failure skips the policy it already created.

## Changing the execution policy (all stages)

`cfn-exec-policy.template.json` is what CloudFormation may do when it deploys the service stacks (as
`cdk-hnb659fds-cfn-exec-role`). Placeholders: `{{STAGE}}`, `{{ACCOUNT}}`, `{{ZONE}}` (`beta.mopm.dev`, `gamma.mopm.dev`,
`mopm.dev`), filled in by `bootstrap.sh`. The policy is a managed policy attached to the exec role by ARN, so a new default
version takes effect for the next deploy without another `cdk bootstrap`.

1. Change the template in a pull request. `service/infra/stacks/test/cfn-exec-coverage.test.ts` synthesizes the beta, gamma and
   prod stacks and fails if the rendered policy lacks an action some resource needs (or a resource type is not in its reviewed
   map). When you add a resource type to a stack, add its row to `REQUIRED` there, with the actions CloudFormation performs.
   Never loosen the two Deny statements; the test pins them.
2. After merge, per stage, with that stage's admin credentials (beta first, then gamma, then prod):
   ```sh
   service/infra/access/bootstrap.sh --stage <stage> --account <id> --region <region> --profile <profile> --update-policy --policy-only
   service/infra/access/bootstrap.sh --stage <stage> --account <id> --region <region> --profile <profile> --update-policy --policy-only --apply
   ```
   The first command is a dry run: it makes read-only IAM calls, prints the diff (current default version against the
   template, rendered for the stage) and the commands. The second runs them: when the policy already has 5 versions (IAM's limit)
   it first deletes the oldest non-default one, then `aws iam create-policy-version --set-as-default`. `--policy-only` stops
   before `cdk bootstrap`, `cdk diff` and the access-stack deploy; leave it out only when those should run too.
   If the policy is identical nothing happens, so the command is safe to repeat. Without `--update-policy` a differing policy
   still stops the script.
3. Re-run the failed deploy workflow for the stage.

Route 53 permissions: CloudFormation creates the alias records and the ACM DNS-validation records in the stage zone with the exec
role's credentials. The zone id is not known at render time, so record changes are allowed on `hostedzone/*` of the account and
limited by the condition keys `route53:ChangeResourceRecordSetsNormalizedRecordNames` (`<zone>` and `*.<zone>`, as
`ForAllValues:StringLike`) and `route53:ChangeResourceRecordSetsRecordTypes` (`A`, `AAAA`, `CNAME`), documented at
https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/specifying-rrset-conditions.html. Each stage account holds only its own zone;
the prod account's zone also holds the NS delegations of beta and gamma, which the record-type limit keeps out of reach. Zone creation
and deletion are not granted. Known limit: `iam:UpdateAssumeRolePolicy` stays denied, so a deploy cannot change the trust policy of an
existing role (it can create one); such a change needs an admin.

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

## GitHub OAuth app (once per stage)

Login (`mopm login`, the OAuth device flow) needs one GitHub OAuth app per stage, so a beta login can never produce a
prod session. The CEO creates the app and stores its credentials; the API reads them from Secrets Manager at runtime
(`mopm/<stage>/github-oauth`, JSON `{"client_id", "client_secret"}`), never from a file, a flag or an environment
variable, and never writes them to a log. Until the secret exists the login routes answer `503 unavailable` and
everything else (the read API, token management, CI exchange) is unaffected, so automatic deployments stay green.

1. In GitHub: the `komira-ai` organization, Settings, Developer settings, OAuth Apps, New OAuth App. One app per stage:

   | Setting | beta | gamma | prod |
   |---|---|---|---|
   | Application name | `mopm (beta)` | `mopm (gamma)` | `mopm` |
   | Homepage URL | `https://beta.mopm.dev` | `https://gamma.mopm.dev` | `https://mopm.dev` |
   | Authorization callback URL | `https://beta.mopm.dev/` | `https://gamma.mopm.dev/` | `https://mopm.dev/` |
   | Enable Device Flow | checked | checked | checked |

   The callback URL is required by GitHub's form but the device flow never uses it (the API has no callback route).
   The API asks for the `read:user` scope only. Do not tick anything else.
2. On the app's page, "Generate a new client secret". GitHub shows it once.
3. Store both with the held script, run with that stage's admin credentials. Preview first; nothing is read or called
   without `--apply`. The client secret is read from standard input (hidden prompt on a terminal), never from a flag:
   ```sh
   service/infra/access/oauth-secret.sh --stage beta --profile <your profile> --client-id <client id>
   service/infra/access/oauth-secret.sh --stage beta --profile <your profile> --client-id <client id> --apply
   ```
   It creates the secret, or stores a new version when it exists (rotation: generate a new client secret in GitHub, run
   it again). The API picks the new value up within five minutes, with no redeploy. A client-secret rotation does not
   end existing sessions.
4. Check on beta first: `curl -sS -X POST https://api.beta.mopm.dev/api/v1/auth/device -H 'content-type: application/json'
   -d '{"client":"check"}'` must answer with a `user_code` and a GitHub `verification_uri` (a `503` means the secret is
   missing or unreadable; the API logs only the reason). The API requires the account to have two-factor authentication on (`MOPM_REQUIRE_2FA`, default on, set by `require2fa` on the
   API stack) and fails closed if GitHub does not show that field for a `read:user` token: confirm on beta with a real
   account before relying on it in prod (`service/api/src/auth/github.ts` says why).

The Lambda role may read exactly this one secret (`secretsmanager:GetSecretValue` on `mopm/<stage>/github-oauth-??????`,
the six characters being the suffix Secrets Manager adds to every ARN) and use the auth tables as listed in
`AUTH_GRANTS` in `service/infra/stacks/lib/api-stack.ts`; the stacks tests pin both. The secret is created by hand, not
by CloudFormation, so no stack holds its value. It uses the account's default Secrets Manager key, which the Lambda
role can use without a separate grant.

## Verification

Run `deploy.yml` on `main` for `beta`: `aws sts get-caller-identity` must show the deploy role. The same
workflow from another branch must fail at the environment's branch policy, and if that were
loosened, at `AssumeRoleWithWebIdentity`.

## Known residual risk

The CloudFormation execution policy lets a deploy create stage roles and write inline policies on them (`iam:PutRolePolicy` on `mopm-<stage>-*`). Managed-policy attachment is limited by `iam:PolicyARN`, but inline policies are not boundable without a permissions boundary. Anyone who can run the deploy workflow on `main` can therefore widen a stage role. Accepted for now: the deploy role only assumes from `main` in the stage environment, which carries the review gate. Revisit with a permissions boundary.
