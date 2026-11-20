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
- **Site.** The site stack serves the site build (`site/dist`; deploy.yml builds it before `cdk deploy`, and synth
  refuses to run without it). Hashed assets are uploaded first and never pruned, then the pages, pruned and invalidated
  (`/*`), so a rollback is a deploy of the earlier commit: its pages find their assets still in the bucket (which is
  also versioned). A CloudFront Function, generated from the site's route grammar and the build's file list, routes app
  and docs paths, redirects non-normalised package names and answers anything that is no file of the build with the
  404 page and status 404. `/api/*` on the site host goes to the stage's API with an `x-mopm-edge` origin header from
  the generated secret `mopm/<stage>/edge-origin`. What it serves and why: `site/README.md`, "How it is served".
- **Health endpoint.** `/api/v1/health` reports `stage`, `version` and `commit` (`-c commit=<git sha>`), so the e2e
  workflow can prove the deployed commit equals the one it was asked to test.
- **conda-forge name mirror.** A scheduled function (`publish/native-mirror-lambda`, every 6 hours) reads conda-forge's shard index
  for linux-64, linux-aarch64, osx-arm64 and noarch and writes the union of the package names, gzip, with the time of the run, to
  `native-mirror/conda-forge-names.gz` in the channel bucket. The validators (single and group) read that one object, once per
  container, to warn a publisher about a native dependency whose name conda-forge does not list; a missing, unreadable or
  more-than-a-day-old object is a warning too and never a refusal. Only the job writes the key and only the two validators read
  it; CloudFront cannot serve it. If the job fails the old object stays and the alarm `mopm-<stage>-native-mirror-failed` fires.
  The first deploy has no object, so publishes warn "could not be read" until the first run (invoke the function once, or wait up
  to 6 hours).
- **Rust functions.** `RustFunction` (`lib/rust-function.ts`) is one Rust Lambda: `provided.al2023` on x86_64, named
  `mopm-<stage>-<function>`, code from `<rustZipDir>/<function>.zip`, no environment variable, and a role of its own with only
  the grants it is given, GetItem of the config table's `stage_settings` item, and writing to its own log group. Given
  `rustZipDir`, the API stack writes the `stage_settings` item (`lib/stage-settings.ts`) and declares three functions:
  `web-login` (`<rustZipDir>/web-login.zip`), on GET `/api/v2/auth/web/start` and `/api/v2/auth/web/callback`, with the grants of
  `service/lambda/fn_web_login/tests/fixtures/role_grants.json` and GetSecretValue on the stage's OAuth app and edge-origin
  secrets; `web-session` (`<rustZipDir>/web-session.zip`), on GET `/api/v2/auth/web/session` and POST `/api/v2/auth/web/logout`,
  with GetItem and UpdateItem on `tokens`, GetItem on `users` and GetSecretValue on the stage's edge-origin secret; and
  `tutorial-sandbox` (`<rustZipDir>/tutorial-sandbox.zip`), on POST `/api/v2/tutorial/sandbox`, with GetItem and UpdateItem on
  `tokens`, GetItem on `users` (the grants of `service/lambda/fn_tutorial_sandbox/tests/fixtures/grants.json`, which its tests
  run under) and GetSecretValue on the edge-origin and E2B secrets. The E2B secret `mopm/<stage>/e2b` is created with it
  (`CfnSecret`: no value, nothing generated), with a resource policy of one Deny of GetSecretValue to every principal but that
  function's role. No deploy passes `rustZipDir` yet, so a deploy
  changes nothing in the API stack. The data stack has the `web_logins` table the sign-in uses.
- **Quarantine.** The channel bucket is served through CloudFront with an origin access control; an explicit deny
  keeps `quarantine/*` unreachable through the distribution.
- **Auth routes.** The same Lambda also serves login (`/auth/device`, `/auth/device/poll`), API tokens (`/me/tokens`) and
  the CI exchange (`/auth/oidc/exchange`). Login needs the stage's GitHub OAuth app in the secret
  `mopm/<stage>/github-oauth` (`service/infra/access/BOOTSTRAP.md`, "GitHub OAuth app"); without it those routes answer
  503 `unavailable` and the read API is unaffected. The data stack gained the `device_logins` table and a by-account
  index on `tokens` (CloudFormation allows one index change per table per update, so a second index goes in a later
  deploy). Nothing in the Lambda deletes rows: the tables deny DeleteItem to its role, a finished device login is marked
  consumed, and DynamoDB TTL removes expired rows later (typically within two days), so expiry is decided in code.
  A login also makes the account's user namespace in the `namespaces` table (keyed by the namespace, with a
  `by_github_id` index; created together with its index, so it is one deploy): a PutItem conditional on the key being
  absent, so the role can create a namespace and never remove one or change its GitHub id (docs/design/namespaces.md).
  Registering an organization namespace and every member change are TransactWriteItems of PutItems: the namespace row
  (conditional on its member revision) and the member row in `namespace_members` (keyed by namespace and member id, with
  a `by_member` index). A removed member is a row written back as removed, since the tables deny DeleteItem. Nothing asks
  GitHub about an organization after the registration, so the role reads no GitHub App secret.
