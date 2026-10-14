# mopm stacks (beta, gamma, prod)

CDK stacks per stage: channel (S3 + CloudFront conda channel), data (DynamoDB), publish (FIFO queues, validator and index-writer Lambdas), api (HTTP API + Lambda), site.
Account ids come from the CDK environment at deploy time and are never committed. Tests build their dummy account at runtime.

## Runbook notes

- **Tearing down beta or gamma.** The channel bucket and the DynamoDB tables carry a delete-deny that exempts only
  named roles (`mopm-<stage>-takedown`, plus `mopm-<stage>-cleanup` on beta and gamma). The stack does not create
  those roles; the access stack does. A non-empty beta or gamma bucket can be destroyed only by a session
  assuming the cleanup role. Without it, `cdk destroy` fails on the bucket policy.
- **DynamoDB resource policy is unproven.** The table resource policy is a raw property override that nothing
  validates against CloudFormation. The first beta deploy is the proof: if CloudFormation rejects the `Resource`
  or `Principal` form, the data stack fails there and the policy shape needs adjusting.
- **API host.** The API is served at `api.<site host>` (three hosts beyond the site and conda hosts, with their
  own certificates and DNS records). Routing `/api/*` through CloudFront on the site host is the alternative;
  this is a pending CEO decision.
- **Health endpoint.** `/api/v1/health` reports `stage`, `version` and `commit` (`-c commit=<git sha>`), so the e2e
  workflow can prove the deployed commit equals the one it was asked to test.
- **Quarantine.** The channel bucket is served through CloudFront with an origin access control; an explicit deny
  keeps `quarantine/*` unreachable through the distribution.
- **Auth routes.** The same Lambda also serves login (`/auth/device`, `/auth/device/poll`), API tokens (`/me/tokens`) and
  the CI exchange (`/auth/oidc/exchange`). Login needs the stage's GitHub OAuth app in the secret
  `mopm/<stage>/github-oauth` (`service/infra/access/BOOTSTRAP.md`, "GitHub OAuth app"); without it those routes answer
  503 `unavailable` and the read API is unaffected. The data stack gained the `device_logins` table and a by-account
  index on `tokens` (CloudFormation allows one index change per table per update, so a second index goes in a later
  deploy). Nothing in the Lambda deletes rows: the tables deny DeleteItem to its role, a finished device login is marked
  consumed, and DynamoDB TTL removes expired rows later (typically within two days), so expiry is decided in code.
