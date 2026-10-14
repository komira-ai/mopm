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
