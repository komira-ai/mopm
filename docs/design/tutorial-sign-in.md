# Sign-in for mopm.dev and the interactive tutorial

Status: proposal, for the CEO's review before any implementation. It changes what users see (a sign-in, a tutorial
that runs code) and the public interface (new `/api/v2` routes and error codes, a cookie, one optional field on `GET
/api/v2/me`). No code changes in this PR. **Unverified** marks what no code, doc or run has confirmed; every size, time
and price is an estimate until the PR that names it measures it.

The CEO asked for a login on mopm.dev, and for the interactive tutorial to be open only to people who are signed in.
This note designs the smallest sign-in that does that, and the place where the tutorial's code runs. The sign-in is
the GitHub web login that [mopm-dev.md](mopm-dev.md) section 4 and its [appendix C](mopm-dev-appendix.md#c-web-login)
already designed, cut down to what the tutorial needs and moved to `/api/v2`. What is new here is the gate (section 3)
and the runner (section 4): today nothing in the service can run code.

## Decisions at a glance

| area | decision |
|---|---|
| Identity provider | GitHub only, an OAuth web flow with S256 PKCE and `scope=read:user`, through each stage's existing OAuth app (section 1). The account is the one the CLI's device login already creates, keyed by GitHub numeric id. No second provider. |
| Session | `__Host-mopm_session`: `Secure; HttpOnly; Path=/; SameSite=Lax`, 7 days absolute, no sliding renewal. The value is an opaque session token whose SHA-256 is a row in the existing `tokens` table. Sign-out revokes that row and clears the cookie (section 2). |
| Topology | CloudFront serves `/api/*` on the site host, so the cookie is first-party and never reaches `api.<site>`; no credentialed CORS (mopm-dev.md 4.1, its open Q3, answered here as a prerequisite). |
| The gate | The server enforces it on the one costly thing, running code: `POST /api/v2/tutorial/runs` accepts only a valid session cookie with its CSRF header. The tutorial pages check `GET /api/v2/me` and show "Sign in with GitHub" instead of the editor when it answers 401. The lesson text is not secret: it lives in this public repository (section 3, Q-T1). |
| Where code runs | A container-image Lambda, the runner, in a VPC subnet with no route out and no DNS, with an IAM role worth almost nothing. One run per execution environment: process limits, a 12 s wall clock, capped output, then the environment is thrown away (section 4). |
| What a user may run | Only the tutorial's own lessons: `mopm run` or `mopm test` in a lesson project whose editable files the user changed. No dependency the lesson does not already have, no network, no shell (section 4.2). |
| Abuse and spend bounds | 1 run in flight per user, 100 runs per user per UTC day, 5,000 runs per UTC day for everyone, the runner's concurrency capped at 10. Every run counts once it starts. Worst case about 9 US dollars a day (section 5). |
| Stored about a user | Nothing new on the account: the existing `users` row (numeric id, login, two timestamps, the two-factor flag). New rows: a 10-minute login transaction, the 7-day session token, and per-day run counters. Code and output are never stored; one log line per run holds counts, not content (section 6). |
| Stub for the tutorial's author | The wire contract lands first (protos, contract examples), then a local preview server that serves the built site and fakes those routes, so the tutorial pages are built and tested against the real contract before any of the service exists (section 8, tu-P1, tu-S1). |

## What exists today

- The site is static: plain TypeScript, no framework, one CloudFront distribution with a private S3 bucket as its only
  origin (`service/infra/stacks/lib/site-stack.ts`). An edge router (a CloudFront Function generated from
  `site/src/routes.ts`) maps `/`, `/search`, `/packages/...` and `/docs/...` to files; nothing else. The site reads
  `https://api.<site>/api/v2` with `credentials: 'omit'` (`site/src/api.ts`, `site/src/host.ts`). There is no cookie, no
  browser storage and no sign-in anywhere in `site/`.
- The page CSP is `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src
  https://<api host>; ... require-trusted-types-for 'script'; trusted-types 'none'` (`site-stack.ts`). The API's CORS
  allows only the site's origin, only `GET`, `HEAD` and `OPTIONS`, and no credentials (`api-stack.ts`).
- Sign-in exists for the CLI only: the GitHub device flow of one OAuth app per stage, `scope=read:user`
  (`service/api/src/auth/device-login.ts`). The registry reads `GET https://api.github.com/user` once, applies the
  two-factor rule (`MOPM_REQUIRE_2FA`, on by default, fails closed), upserts the user, creates the user namespace and
  discards the GitHub token. The app's secret `mopm/<stage>/github-oauth` holds `client_id` and `client_secret`; the
  code reads only `client_id` (`service/api/src/http/oauth-secret.ts`). No callback URL is configured or used.
- A request is authenticated only by `Authorization: Bearer mopm_...`; the token's SHA-256 is the key of the `tokens`
  table, which has a TTL on `expires_at` and an index by GitHub id (`service/api/src/auth/tokens.ts`,
  `service/infra/stacks/lib/data-stack.ts`). A device-login session lives 30 days and cannot publish or yank. Nothing
  revokes a session token today, and the handler role may not delete rows, so revoking means setting `revoked_at`.
- Rate limits: per-account and per-token counters per UTC day for uploads, claims and groups (`rl#...` rows,
  `service/api/src/publish/service.ts`), and a gateway throttle on the index routes only. No WAF, no per-IP limit.
- Compute: Node.js Lambdas running fixed bundled code, and the Rust crates under `service/lambda`, which nothing
  deploys yet. No container, image, VPC or runner exists. A Mojo 1.0.0 toolchain closure for `linux-64` is 52
  packages and about 229 MiB compressed (`src/core/toolchain/mojo-1.0.0-linux-64.json`), fetched from conda-forge and
  Modular's channel. Mojo has no WebAssembly target, so nothing about it can run in the browser.
- [mopm-dev.md](mopm-dev.md) section 4 designs the web login (PRs 4a, 4b, 5) under `/api/v1` and recommends building it
  in Rust after the API's port (its Q9). Its Q3, the API on the site host, is open.

## 1. Identity: GitHub, through the existing OAuth app

GitHub is the one provider because the account already is a GitHub account: namespaces are GitHub logins, users are
keyed by GitHub numeric id, trusted publishing is a GitHub Actions identity. A second provider would be a second
account model with nothing to own. Email links would need mail sending and an account table keyed by address.

The web flow is appendix C.1, unchanged except for paths: `GET /api/v2/auth/web/start?return_to=` stores a 10-minute
`web_logins` row (state hash, PKCE verifier, `return_to`) and sets `__Host-mopm_login`, then redirects to GitHub with
`scope=read:user`, a 256-bit `state`, an S256 challenge, the exact `redirect_uri` and `prompt=select_account`. `GET
/api/v2/auth/web/callback` consumes the row once, checks `state`, exchanges the code with the client secret and the
verifier, reads `GET /user`, applies the same two-factor rule, upserts the same user and creates the same user
namespace as the device login, mints the session and redirects to `return_to`. The GitHub token is discarded there.
Failures redirect to `/tutorial?error=<code>` from a fixed list (`access_denied`, `two_factor_required`,
`login_expired`, `unavailable`), and the page says what to do.

Each stage's OAuth app keeps its device flow and gains the callback `https://<site>/api/v2/auth/web/callback`. GitHub
OAuth apps have one callback URL and accept a `redirect_uri` equal to it or below it; the registry always sends it
exactly. Only the web-auth function reads `client_secret`; the comment in `oauth-secret.ts` that says it is never read
changes for that function alone. The secret is already in each stage's secret (the held `oauth-secret` script writes
both fields); whether it is current on each stage is **unverified** and is the operator step tu-O1.

## 2. The session

- **Cookie**: `__Host-mopm_session=<token>; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=604800`. `__Host-` makes it
  host-only, so it never reaches `api.<site>`, `conda.<site>` or another stage (beta and gamma are subdomains of the
  prod site). Only that exact name is read; a request with two of them is refused.
- **Value**: a session token in today's format (`mopm_` and 40 base32 characters) with `kind: 'session'`, name `web
  login`, 7 days absolute from sign-in. It is a row in `tokens` like the CLI's session, so the one authenticator checks
  both, and revocation is the existing `revoked_at`. No signing key is introduced. The CLI session's 30 days is not
  changed.
- **Where it is accepted**: `GET /api/v2/me`, `POST /api/v2/auth/web/logout` and `POST /api/v2/tutorial/runs`, and
  only on requests that carry the header the site distribution adds (its value a stage secret, appendix C.1). Never on
  publish, yank, token or namespace routes. An `Authorization` header that is present wins and, when invalid, is
  refused, never retried with the cookie.
- **CSRF**: every cookie-authenticated `POST` needs the exact site `Origin`, `Sec-Fetch-Site: same-origin`,
  `Content-Type: application/json` when it has a body, and `X-Mopm-CSRF`, which is base64url(SHA-256("mopm-csrf\0" +
  session token)). `GET /api/v2/me` returns it as the new optional field `csrf` when the caller used the cookie, with
  `session_expires_at`. Nothing new is stored for it.
- **Sign-out**: the header's "Sign out" sends `POST /api/v2/auth/web/logout`, which sets `revoked_at` on this
  session's row, clears the cookie (`Max-Age=0`) and answers 204. It does not touch the CLI's sessions or API tokens.
  Signing in again revokes the session the browser held before. "Sign out everywhere", the session list and the account
  page stay in mopm-dev.md (PR 4a's remainder, PR 5); the tutorial does not need them.
- **Expiry in the page**: after 7 days, or after sign-out in another tab, a run answers `session_required` (401) and
  the page shows the sign-in card again with the user's code kept in the editor (section 7).

## 3. The gate

The gate sits where it costs us something to let a stranger through, and where it can be enforced: the run endpoint.

- **Server**: `POST /api/v2/tutorial/runs` refuses without a valid session cookie (`session_required`, 401), with a
  bad CSRF check (`csrf_failed`, 403), and from an account the quota has stopped (section 5). This is the only place
  that decides who may use the tutorial, and the only one that needs to be right.
- **Pages**: `/tutorial` (the list of lessons) and `/tutorial/<lesson>` are served by one new shell page through the
  edge router. The page calls `GET /api/v2/me`. Signed in, it shows the lesson with its editor, Run and Test buttons
  and the user's login with "Sign out". Signed out, it shows the lesson's title and summary and a "Sign in with
  GitHub" link to `/api/v2/auth/web/start?return_to=/tutorial/<lesson>`, and no editor. The page cannot check the
  cookie itself (it is HttpOnly), and the edge cannot validate a session (a CloudFront Function has no store access),
  so the pages ask the API.
- **Lesson text is not gated on the server.** The lessons are files in this public repository (`tutorial/`), so hiding
  them behind a session would protect nothing. The page shows a lesson's body only when signed in, as the CEO asked,
  but anyone can read the same text on GitHub (Q-T1).
- **The CLI and scripts**: the run endpoint does not accept bearer tokens, so the device login's session cannot drive
  it from a script; the cookie, the distribution's header and the CSRF header together mean a run starts from the site.
  A signed-in user can still copy their cookie into a script; the quotas bound that (section 5).

## 4. Where the tutorial's code runs

### 4.1 The runner: a container-image Lambda with no network

Mojo cannot run in a browser (no WebAssembly target), so code runs on our side. The runner is one Lambda function from
a container image (`linux-x86_64`), separate from every registry function.

- **Image**: a pinned `provided.al2023` base (by digest); the runner bootstrap; one mopm release binary pinned by
  version and sha256; and each lesson's project, synced at image build with `mopm sync`, so the Mojo toolchain and the
  lesson's dependencies are in the image, read-only, checked against `mopm.lock`'s sha256s. A run downloads nothing.
  The image is about 1 to 1.5 GB unpacked (**unverified**; a zip Lambda's 250 MB limit rules a zip out, an image may
  be 10 GB). CDK builds it at deploy (`DockerImageCode.fromImageAsset`) into the CDK bootstrap repository the deploy
  role already uses; no new registry and no PR job builds it.
- **Network**: the function sits in its own VPC's isolated subnets: no internet gateway route, no NAT, no VPC
  endpoints, a security group with no egress rule, and the VPC's DNS resolution off (`enableDnsSupport: false`),
  because the VPC resolver answers public names even with no route out and would be a channel for data. What stays
  reachable is loopback inside the environment, among it the Lambda runtime API, through which a program can at most
  answer its own invocation (section 4.2 treats that answer as untrusted).
- **Credentials**: Lambda puts the role's credentials in the runtime's environment, and the user's process runs as the
  same user and can read them from `/proc`. With no route and no DNS they have nowhere to go, and the role is written
  by hand to be worth little if they did: `logs:CreateLogStream` and `logs:PutLogEvents` on the runner's own log group,
  and the network-interface actions Lambda needs to attach to the VPC (`ec2:CreateNetworkInterface`,
  `ec2:DescribeNetworkInterfaces`, `ec2:DeleteNetworkInterface` and the two address actions), nothing else.
- **Size**: 4096 MB memory (about 2.3 vCPU), 1 GiB of `/tmp`, a function timeout of 16 s, and a reserved concurrency of
  10, which is also its cap. Lambda refuses a reservation that leaves an account's unreserved pool under 10 (the
  reason `api-stack.ts` reserves none for the API), so each stage's account needs a concurrency limit of at least 20
  (**unverified** per stage; tu-O1 checks it and asks for an increase where it is lower).
- **Caller**: the tutorial function (section 5) invokes the runner synchronously with `lambda:InvokeFunction`; the
  runner has no URL, no route and no trigger of its own.

### 4.2 What a run may do

A run request is `{lesson, action, files}`: `lesson` is a lesson id from the image's manifest, `action` is `run` or
`test`, `files` replaces the lesson's editable files, each named in the lesson's `lesson.json` (`editable`). Anything
else is refused with `invalid_request`: an unknown lesson, a path the lesson does not list as editable, more than 8
files, more than 64 KiB of source in total, a file that is not UTF-8 or contains a NUL.

**One run per execution environment.** The user's program runs as the same user as the bootstrap, so inside one
environment nothing separates them: the program can read the bootstrap's memory, write anywhere in `/tmp`, leave
processes, or answer the runtime API itself. The design does not try to clean an environment for the next user;
it never gives one to a next user. The bootstrap:

1. At start, before taking an invocation, empties `/tmp` and checks in `/proc` that no process other than itself and
   its ancestors exists; if either fails it exits, and Lambda reports an init error rather than run anything there.
2. Takes one invocation. Copies the lesson's project into `/tmp/run` and writes the user's files over the editable
   ones. The synced environment stays in the image and is linked, not copied (**unverified** that mopm accepts a
   linked, read-only environment; tu-R1 checks it, and the fallback is an environment copy per run, slower but the
   same result).
3. Starts `mopm run` or `mopm test` for the lesson in a new process group, with an environment built from an allowlist
   (`PATH`, `HOME` set to the run directory, `LANG`; no `AWS_*` variable), standard input closed, and limits set in the
   child before exec: CPU time 12 s, 256 processes and threads for the user (the limit counts the bootstrap's too; **unverified** that
   the Mojo build fits under it), files at most 16 MiB, 256 open files, no core dumps. The wall clock
   is 12 s for build and run together.
4. Keeps at most 64 KiB of standard output and 64 KiB of standard error, then drops the rest and marks the result
   truncated.
5. On exit, on the wall clock or when an output cap is hit, kills the process group and answers `{verdict, exit_code,
   stdout, stderr, truncated, duration_ms}`, `verdict` one of `ok`, `failed`, `timeout`, `killed` (a signal, such as
   the CPU limit), `oom`.
6. Exits. Lambda then shuts that environment down and starts a new one for the next invocation, which begins again at
   step 1 (**unverified** that Lambda never hands a later invocation the same `/tmp` and processes after the runtime
   exits; step 1 fails closed if it does, and tu-R2 checks it on beta).

So every run is a cold start (section 5 counts it). Memory is bounded by the function's 4096 MB; a run that exhausts
it ends the environment and the tutorial function reports `oom`. A program that kills the bootstrap, hangs past the
function timeout or forges its own answer gets an error or a wrong answer for its own run only, and that run is
counted (section 5).

### 4.3 Rejected

- **In the browser**: Mojo has no WebAssembly target; a remote compile with only a WebAssembly result would still need
  this runner.
- **Cleaning a warm environment between users**: a program running as the bootstrap's user can outrun a `/proc` sweep
  with a fork loop and write anywhere in `/tmp`; there is no process namespace or cgroup in Lambda to make the sweep
  complete. One run per environment costs a cold start and removes the question.
- **A Fargate task per user session**: a task with a 1.5 GB image starts in tens of seconds (**unverified**), needs
  routing from the API to the task and a reaper for idle ones, and costs while idle. Its isolation is better (one task
  per user); it is the fallback if section 4.2's step 6 turns out not to hold.
- **EC2 with Firecracker or gVisor**: hosts, patching and capacity to run ourselves.
- **GitHub Codespaces or the user's own machine**: no gate on our side and no interactive page; the getting-started
  guide already covers the user's own machine.

## 5. The run endpoint, quotas and spend

`POST /api/v2/tutorial/runs` is served by a new tutorial function in `service/api` (TypeScript, Q-T2), with a 28 s
timeout under API Gateway's 30 s. In order:

1. Cookie session and CSRF (section 2); refuses `session_required` or `csrf_failed`.
2. Body grammar and size (section 4.2); refuses `invalid_request`.
3. Quotas, in a new `tutorial_quota` table (pk `key`, TTL `expires_at`, pay per request), as one DynamoDB transaction
   over three items, each with its condition, so that a refusal writes nothing:
   - `inflight#<github_id>`: written with this run's id and `started_at` only if absent or its `started_at` is more
     than 60 s old (compared in the condition, not left to TTL, which deletes late); else `run_in_progress` (409).
   - `user#<github_id>#<UTC day>`: incremented only if under 100; else `tutorial_quota_exceeded` (429, `Retry-After`
     until the next UTC day).
   - `all#<UTC day>`: incremented only if under 5,000; else `tutorial_busy` (503, `Retry-After` until the next UTC
     day).
4. Invokes the runner. The run is counted from here on, whatever happens: the user's program can make the runner
   fail (section 4.2), so a runner failure is never refunded. The one refund is a Lambda throttle, where the runner
   never started: the counters are decremented and the answer is `tutorial_busy` (503, `Retry-After: 30`). A Lambda
   out-of-memory error is verdict `oom`; any other runner error is `unavailable`.
5. Clears the in-flight marker with an update conditioned on this run's id (the tables' resource policy refuses
   `DeleteItem` to the handler roles, and a late run must not clear a newer marker), and answers the runner's result
   and `{runs_today, runs_per_day}`.

The gateway route has its own throttle, rate 5 a second and burst 10, as the index routes have one today. The limits
are stack settings passed to the tutorial function as the existing ones are (`MOPM_RATE_PER_ACCOUNT_DAY` and the
like), defaults as above; changing one is an edit and a deploy.

Spend, at us-east-1 list prices for x86_64 Lambda (about 0.0000167 US dollars per GB-second, init time billed,
**unverified** at the time of the PR). A run costs at most the runner's init (up to 10 s) and its 16 s timeout at 4
GB, 104 GB-s, plus the tutorial function waiting up to 28 s at 256 MB, 7 GB-s: 111 GB-s, about 0.0019 dollars. Every
run is counted before it starts, so the global cap makes the worst day 5,000 runs, about 9.30 dollars, about 280
dollars over 30 days. The reserved concurrency (10 at once) only limits how fast that day is used up. One user's worst
day is 100 runs, about 0.19 dollars. A typical run, a lesson program of a few lines, takes a few seconds plus the cold
start (**unverified**: neither the image's cold start nor the build time of a small Mojo program on 2.3 vCPU is
measured; tu-R2 measures both). The VPC has no NAT gateway, so it adds no hourly cost. Image storage is about 1.5 GB in
the bootstrap repository.

The abuse this bounds: mining or other CPU use (CPU limit, 12 s wall clock, quota, and no network or DNS to send the
result anywhere); spam or attacks from our addresses (no network); filling the disk (16 MiB per file, 1 GiB `/tmp`,
the environment discarded after the run); fork bombs (256 processes and threads, then the environment is discarded); huge output
(64 KiB per stream); crashing the runner on purpose (the run still counts); many accounts at once (the global
cap: they can use up a day's runs, at a bounded cost, and the rest of the site is unaffected); one account in a loop
(1 in flight, 100 a day). The two-factor rule at sign-in raises the cost of throwaway GitHub accounts a little. If the
global cap is hit by abuse, the operator lowers `all#` or the per-user limit; no further machinery is built ahead of
that (Q-T4).

## 6. What is stored

| where | what | how long |
|---|---|---|
| `users` (existing) | GitHub numeric id, login as `handle`, `created_at`, `last_login_at`, the two-factor flag. Nothing new. | as today |
| `namespaces` (existing) | the user namespace, created at the first sign-in as the CLI's login does | as today |
| `tokens` (existing) | the session: SHA-256 of the token, prefix, `kind: session`, name `web login`, GitHub id, `created_at`, `expires_at`, `last_used_at`, `revoked_at` | TTL at 7 days |
| `web_logins` (new) | the login transaction: SHA-256 of its id, SHA-256 of `state`, the PKCE verifier, `return_to`, `consumed_at` | TTL at 10 minutes |
| `tutorial_quota` (new) | run counters and the in-flight marker, keyed by GitHub id and UTC day | TTL at 2 days |
| logs (existing retention, one month) | one line per run: request id, GitHub id, lesson, action, verdict, duration, bytes in and out | one month |
| the browser | the cookie; the user's edited files and the last lesson opened, in `localStorage` under `mopm.tutorial.1`, never sent except in a run | until cleared |

Never stored: the user's code, the program's output, the GitHub token, the email address, the IP address (the API
does not log it), the avatar (the page loads it from the numeric id at GitHub when the CSP allows it, otherwise shows
the login). The site distribution's standard logs stay off.

## 7. The tutorial pages

- New shell page `tutorial.html`, PageKind `tutorial`, an area stylesheet `tutorial.css` within the 16 KiB area
  budget; routes `/tutorial` and `/tutorial/<lesson>` (`^[a-z0-9]+(-[a-z0-9]+)*$`) in `site/src/routes.ts`, and from
  there in the edge router.
- The editor is a `<textarea>` per editable file: no editor library, since the site has no runtime dependencies. The
  output is text nodes in a `<pre>`; control characters, bidi and invisible characters are shown as markers, as the
  copied-example rule in appendix C.2 does.
- A `TutorialGate` port (`site/src/tutorial/gate.ts`): `session()` (`{signed_in: true, login, csrf, expires_at}` or
  `{signed_in: false}`), `run(request)`, `signInHref(returnTo)` (a `SafeHref`), `signOut()`. The real one calls
  the routes of section 2 and 5 with `credentials: 'same-origin'`; tests use a fake that replays the contract
  examples. All of the page's logic is tested through it.
- The page states, beside Run: "Runs in a sandbox with no network, 12 seconds at most, 100 runs a day. Your code is
  not stored." Every refusal code of section 5 has its own message, and `session_required` keeps the code in the
  editor.
- Lessons are `tutorial/lessons/<id>/` in this repository: `lesson.md` (the text, rendered by the site's restricted
  Markdown renderer), `lesson.json` (title, summary, order, editable files, actions) and `project/` (a mopm project
  with its `mopm.toml` and `mopm.lock`). The site build reads `lesson.md` and `lesson.json`; the runner image copies
  `project/` and the editable list. One checked-in schema, `spec/tutorial-lesson.schema.json`, is the contract between
  the two.
- The header gains "Tutorial" and, on the tutorial pages only, the signed-in login with "Sign out" (other pages stay
  free of API calls they do not need).

## 8. Implementation tasks and order

S is under 200 lines, M under 600, L more. Task ids are prefixed `tu-` so they read apart from rule ids. Each names the
behaviour its tests assert; every test is hermetic (fakes for GitHub, the stores and the runner's invoker; a loopback
listener on port 0 where an HTTP server is needed).

Contract first, so the tutorial can be built against it:

- tu-P1 (M) The wire contract: in `spec/api/mopm/registry/v2/*.proto`, the rpcs `StartWebLogin`, `CompleteWebLogin`,
  `WebLogout` and `RunTutorial`, the optional `csrf` and `session_expires_at` on `MeV2`, and the error codes
  `session_required`, `csrf_failed`, `run_in_progress`, `tutorial_quota_exceeded`, `tutorial_busy`; `spec/api/openapi-v2.yaml`
  and the generated types from `tools/api_gen.zig`; contract examples `tests/contract/api-v2/tutorial.json` and
  `web-auth.json` (signed in, signed out, each refusal, each verdict, a truncated output); `spec/tutorial-lesson.schema.json`.
  Additive only. Tests: the generator's check that the checked-in outputs equal its output; the schema accepts the
  example lesson and refuses an editable path outside `project/`, a missing action, an id out of grammar.
- tu-S1 (M) The stub gate: `site/src/tutorial/gate.ts` with the real client and the replaying fake, and
  `site/tools/preview.ts`, which serves `dist/` on 127.0.0.1 (port 0, printed) and answers `/api/v2/me`,
  `/api/v2/auth/web/*` and `/api/v2/tutorial/runs` from the contract examples, with the scenario chosen by a flag
  (`--signed-out`, `--quota`, `--timeout`, ...); `site/src/host.ts` maps `127.0.0.1` and `localhost` to a relative API
  base. Nothing of it reaches a deployed stage. Tests: the client decodes every contract example and maps every error
  code; the preview server answers each scenario; an unknown host still gets no API.
- tu-S2 (L) The tutorial pages and the first lessons (section 7), against tu-S1 only. Not routed by the edge router, so
  nothing is visible on any stage. Tests through the fake gate: signed out shows the sign-in link with the right
  `return_to` and no editor; signed in shows the editor and the login; each verdict and each refusal renders its
  message; `session_required` keeps the edited code; truncated output says so; control and bidi characters show as
  markers; the draft survives a reload through `localStorage` and the page works when `localStorage` throws; every
  lesson in `tutorial/` validates against the schema and its editable files exist.

Sign-in (the subset of mopm-dev.md PRs 4a and 4b the tutorial needs, at `/api/v2`):

- tu-A1 (M) Cookie plumbing: the Lambda event's `cookies`, `HttpResponse` cookies and redirects, the cookie
  authenticator for session tokens (one exact name, two refused, `Authorization` wins and never falls back), the
  distribution-header check, the CSRF derivation and checks, `csrf` and `session_expires_at` on `GET /api/v2/me`,
  `POST /api/v2/auth/web/logout`. Tests against the memory and DynamoDB stores: a valid cookie reads `/me`; expired,
  revoked, unknown, duplicated cookies and a missing distribution header are 401; a bad `Origin`, `Sec-Fetch-Site`,
  content type or CSRF value is 403; a present invalid bearer is refused even with a valid cookie; the cookie is not
  accepted on publish, yank, token and namespace routes; logout revokes only its own session and clears the cookie.
- tu-A2 (M) Web OAuth: `start` and `callback` in their own function, the only one that reads `client_secret`; the
  `web_logins` table. Tests against a fake GitHub: a full sign-in sets the cookie and redirects to `return_to`; a
  replayed callback, a wrong `state`, an expired row, a missing login cookie, a cross-site `start` (each
  `Sec-Fetch-*` case) and every bad `return_to` of appendix C.1 are refused or fall back as C.1 says; two-factor off is
  `two_factor_required` and stores nothing; GitHub's `access_denied` and a GitHub outage map to their codes; the GitHub
  token is not stored; signing in revokes the previous session; the user row and namespace equal those the device
  login creates for the same GitHub user.
- tu-I1 (M) The site distribution's `/api/*` behaviour (mopm-dev.md 4.1, Q3): origin the stage's API domain, all
  methods, caching off, the origin header secret, the JSON response headers policy; the distribution-wide 403 and 404
  error responses replaced by the edge router's 404; `apiBase()` relative and the CSP's `connect-src 'self'`. Tests in
  the stack and site-router tests: the behaviour and policy exist with those values; `/api/v2/...` reaches the API
  and a JSON 404 stays JSON; an unknown page still gets the 404 page.
- tu-O1 (operator) On each stage: set the OAuth app's callback URL to `https://<site>/api/v2/auth/web/callback`, and
  check with the held `oauth-secret` script's dry run that the stage secret holds a current `client_secret`; check
  that the account's Lambda concurrency limit is at least 20, and ask AWS for an increase where it is not. Before
  tu-A2 and tu-R2 deploy. Needs the owner's hands.

Runner:

- tu-R1 (M) The runner bootstrap, in Zig beside the CLI's process code: the Lambda runtime loop, request validation
  against the lesson manifest, the run directory, the child's environment allowlist and limits (set between fork and
  exec, which Zig does without unsafe code), output caps, the start check and the one-run-then-exit of section 4.2.
  Tests with a fake runtime API on a loopback listener and small fake child programs instead of mopm: each verdict;
  the bootstrap answers once and exits, and never asks the runtime API for a second invocation; a leftover file in
  `/tmp` is removed at start, and a leftover process (or a `/tmp` it cannot empty) makes the start fail before any
  invocation is taken; output over 64 KiB is cut and marked; a non-editable path, too many files, too large a body,
  non-UTF-8 and NUL are refused; the child sees only the allowlisted environment and no `AWS_*` variable.
- tu-R2 (M) The runner's image and infrastructure: the image definition (pinned base digest, the mopm binary by version
  and sha256, `mopm sync` per lesson), the function (4096 MB, 16 s, 1 GiB `/tmp`, reserved concurrency 10), the VPC
  with isolated subnets, no egress and DNS support off, the hand-written role of section 4.1. Stack tests: no NAT, no
  internet gateway route, no endpoint, no egress rule, `enableDnsSupport` false, the role's policy equal to exactly the
  actions and resources of 4.1, no trigger or URL, the reservation. Measured by hand on beta and written in the PR: the
  cold-start and run times of each lesson, the image size, that a `connect` to an outside address and a DNS lookup of
  an outside name both fail, and that the environment after a runtime exit has an empty `/tmp` and no old process
  (section 4.2 step 6). If that last one fails, the runner moves to the Fargate fallback (4.3) before tu-S3; if the
  cold start and run do not fit the 16 s timeout, tu-A3 becomes start-and-poll (decision 15).
- tu-A3 (M) `POST /api/v2/tutorial/runs` (section 5): the tutorial function, the `tutorial_quota` table, the gateway
  throttle, the invoke grant on the runner and nothing else. Tests against the memory and DynamoDB stores and a fake
  invoker: no session, bad CSRF and bad bodies are refused before any count; the 101st run of a day is
  `tutorial_quota_exceeded` with `Retry-After` to the next UTC day and changes no item; the 5,001st run is
  `tutorial_busy` and changes no item; a second run while one is in flight is `run_in_progress`, and a marker whose
  `started_at` is more than 60 s old does not block; a runner failure, a timeout and an out-of-memory still count; a
  runner throttle is `tutorial_busy` and is refunded; a late run does not clear a newer run's marker; nothing calls
  `DeleteItem`; a runner out-of-memory is verdict `oom`, any other runner error is `unavailable`; the log line has the
  counts and no code or output (asserted by exact equality).

Go-live:

- tu-S3 (S) The edge router routes `/tutorial` and `/tutorial/<lesson>`; the header's "Tutorial" link; the docs page
  "What mopm.dev stores", from section 6. Tests: the route fixtures (`site/test/fixtures/routes.json`) and the
  site-router test; the layout test for the header. This is the step users see.

Order: tu-P1 first. tu-S1 after tu-P1; tu-S2 after tu-S1 and goes on in parallel with everything below. tu-A1, tu-I1
and tu-R1 after tu-P1, in any order; tu-A2 after tu-A1, deployed after tu-O1; tu-R2 after tu-R1; tu-A3 after tu-A1 and
tu-R2. tu-S3 after tu-S2, and after tu-A2, tu-A3 and tu-I1 are deployed to prod. Deploys stay automatic from main;
nothing reachable by users changes before tu-S3, since the new routes answer only requests that carry the site
distribution's header and no page links to them.

## Decisions

1. GitHub is the only identity provider: the account model is already GitHub's numeric id, and a second provider has
   nothing to own.
2. The web login is mopm-dev.md's design, not a new one; only the paths move from `/api/v1` to `/api/v2`, which the site
   and the namespaces work now use.
3. The tutorial needs only start, callback, logout and `/me`; the session list, sign-out everywhere and the account
   page stay in mopm-dev.md's PRs, so the tutorial does not wait for them.
4. The session is an opaque token in the existing `tokens` table, not a signed cookie: one authenticator, revocation
   already works, no key to rotate.
5. 7 days absolute and no sliding renewal, as mopm-dev.md says; the CLI's 30 days is left alone because the CLI is not
   the subject here.
6. Web sign-in applies the same two-factor rule and creates the same user and namespace as the device login: one
   account, whichever way the user signed in first.
7. The server-side gate is on runs only; lesson text is public in the repository, so gating it on the server would
   protect nothing (Q-T1 asks the CEO).
8. The run endpoint takes the cookie only, not bearer tokens, so the tutorial is used from the site, and the quota
   is per GitHub account either way.
9. The runner is a container-image Lambda: it is pay per use, scales to zero, is a function type the stacks already
   deploy, and the image holds the 229 MiB toolchain a zip cannot.
10. No network for user code: lessons need only what their project already synced, and no network removes most of the
    abuse a code runner invites.
11. Users run lesson projects with edited files, not arbitrary projects: the image can hold every dependency ahead of
    time, and validation is a list of paths.
12. The runner bootstrap is Zig: limits must be set in the child between fork and exec, which Rust only offers through
    `unsafe` (`pre_exec`), and Zig is this repository's language for the CLI and its tools.
13. The tutorial function is TypeScript in `service/api`, where the authenticator and stores it uses live today (Q-T2).
14. Quotas are counters in their own table, not in `publishes` beside the publish counters. The tutorial function's
    role has `GetItem` and `UpdateItem` on `tokens` (the authenticator records last use), `GetItem` on `users`,
    conditional writes on `tutorial_quota`, invoke on the runner, and nothing else.
15. A synchronous run (one request, one answer): the runner's init (at most 10 s) and its 16 s timeout fit the
    tutorial function's 28 s and API Gateway's 30 s. If tu-R2 measures cold start and run beyond that, the run becomes
    start-and-poll in tu-A3 with the same result shape, which means holding a result for a few minutes and goes back
    to the CEO since section 6 says no output is stored.
16. Draft code and progress stay in the browser's `localStorage`; nothing about tutorial progress is stored on our side.
17. The local preview server is the stub gate: the same site code, the same wire contract, fakes only behind the
    routes, so the tutorial needs no change when the real service arrives.
18. Lessons live in `tutorial/` at the root, as data read by the site build and the runner image, with one schema for
    both.
19. One run per execution environment, not cleaning between runs: inside one environment the program and the bootstrap
    are the same user, so no cleanup can be shown complete; throwing the environment away can.
20. Every run counts once the runner is invoked, failures included, because the user's program can make the runner
    fail on purpose; only a throttle, where nothing ran, is refunded.

## Questions for the CEO

- **Q-T1, the lesson text**: the page shows a lesson only to signed-in people, but the text is in the public repository,
  so only running code is enforced on the server. **Recommend: accept.** The alternative, a private store of lessons
  served through the API, adds a bucket and a route and still cannot stop a signed-in user from copying the text.
- **Q-T2, language and timing of the web login**: mopm-dev.md's Q9 recommends building the web login in Rust after the
  API's port. The tutorial needs it sooner. **Recommend: build tu-A1 to tu-A3 in TypeScript in `service/api` now,
  where the authenticator lives, and port them with the rest.**
- **Q-T3, two-factor**: the existing rule refuses a GitHub account without two-factor authentication, so such a user
  cannot open the tutorial. **Recommend: keep it**, one rule for every sign-in; the error page says how to turn it on.
- **Q-T4, limits**: 100 runs per user per day, 5,000 a day in all, 10 at once, 12 s per run: at most about 9 dollars a
  day. **Recommend: these defaults**, settings changed by an edit and a deploy.
- **mopm-dev.md Q3, the API on the site host**: the cookie needs it. **Recommend: yes**, as that note recommends; tu-I1
  builds it.
