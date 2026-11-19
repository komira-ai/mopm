# Sign-in for mopm.dev and the interactive tutorial

Status: proposal, revised after the CEO's rulings on its first version (see "Questions for the CEO"). It changes what
users see (a sign-in, a tutorial that runs code) and the public interface (new `/api/v2` routes and error codes, a
cookie). No code changes in this PR. **Unverified** marks what no code, doc or run has confirmed; every size, time and
price is an estimate until the PR that names it measures it.

The CEO asked for a login on mopm.dev, and for the interactive tutorial to be open only to people who are signed in.
The tutorial runs code on a hosted sandbox service that we pay for; the login exists so that this compute is spent on
the tutorial's users. This note designs the smallest sign-in that does it, the one endpoint that runs code for a
signed-in user, and the bounds that stop runaway use without users noticing them. The sign-in is the GitHub web login
of [mopm-dev.md](mopm-dev.md) section 4 and [appendix C](mopm-dev-appendix.md#c-web-login), cut down to what the
tutorial needs, moved to `/api/v2`, and built as Rust Lambdas: the first functions of the registry's Rust port.

## Decisions at a glance

| area | decision |
|---|---|
| Identity provider | GitHub only, an OAuth web flow with S256 PKCE and `scope=read:user`, through each stage's existing OAuth app (section 1). The account is the one the CLI's device login already creates, keyed by GitHub numeric id, with the same two-factor rule. |
| Session | `__Host-mopm_session`: `Secure; HttpOnly; Path=/; SameSite=Lax`, 7 days absolute, no sliding renewal. The value is an opaque session token whose SHA-256 is a row in the existing `tokens` table. Sign-out revokes that row and clears the cookie (section 2). |
| Topology | The site's CloudFront distribution gains an `/api/*` behaviour whose origin is the stage's API Gateway, so the cookie is first-party and never reaches `api.<site>`; no credentialed CORS (section 2.1, task tu-I1). |
| The gate | On running code only: `POST /api/v2/tutorial/runs` needs a valid session cookie and its CSRF header. Lesson text stays public, as it is in this repository; the pages show the editor and Run only when signed in (section 3). |
| Where code runs | A hosted sandbox provider, a parameter of this design (`<provider>`, named by the tutorial's author), called with an API key that only the run function can read. The browser never sees the key and never talks to the provider (section 4). |
| Language | Three new Rust Lambdas behind the existing API Gateway: `web-login` (start, callback), `web-session` (session, sign-out), `tutorial-run`. They share the `tokens`, `users` and `namespaces` tables with the TypeScript functions, which are not changed. Nothing here is written in TypeScript to be ported later (section 5). |
| Bounds | No per-user daily cap. Two runs in flight per user; a per-run time and size limit; a global daily spend ceiling with alerts to the operator at 50 % and 90 % and a friendly refusal only once it is reached; per-user run counts kept, not enforced, so abuse is visible and a cap can be added later (section 6). |
| Stored about a user | Nothing new on the account. New rows: a 10-minute login transaction, the 7-day session, the in-flight marker, a per-user-day usage row and the day's spend. Code and output are not stored by us; the provider sees the code of a run and no identity (section 7). |
| Stub for the tutorial's author | The wire contract lands first (protos, contract examples), then a local preview server that serves the built site and fakes those routes, so the tutorial pages are built and tested against the real contract before any function exists (section 9, tu-P1, tu-S1). |

## What exists today

- The site is static: plain TypeScript, no framework, one CloudFront distribution with a private S3 bucket as its only
  origin and one default behaviour (`service/infra/stacks/lib/site-stack.ts`). An edge router (a CloudFront Function
  generated from `site/src/routes.ts`) maps `/`, `/search`, `/packages/...` and `/docs/...` to files. The site reads
  `https://api.<site>/api/v2` with `credentials: 'omit'` (`site/src/api.ts`, `site/src/host.ts`). There is no cookie, no
  browser storage and no sign-in in `site/`. Missing keys map to `/404.html` distribution-wide.
- The page CSP is `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src
  https://<api host>; ... require-trusted-types-for 'script'; trusted-types 'none'`. The API's CORS allows only the
  site's origin, only `GET`, `HEAD` and `OPTIONS`, and no credentials (`api-stack.ts`).
- Sign-in exists for the CLI only: the GitHub device flow of one OAuth app per stage, `scope=read:user`
  (`service/api/src/auth/device-login.ts`). The registry reads `GET https://api.github.com/user` once, applies the
  two-factor rule (`MOPM_REQUIRE_2FA`, on by default, fails closed), upserts the user, creates the user namespace and
  discards the GitHub token. The secret `mopm/<stage>/github-oauth` holds `client_id` and `client_secret`; the code
  reads only `client_id` (`service/api/src/http/oauth-secret.ts`). No callback URL is configured or used.
- A request is authenticated only by `Authorization: Bearer mopm_...`; the token's SHA-256 is the key of the `tokens`
  table, with a TTL on `expires_at` and an index by GitHub id. A device-login session lives 30 days, is fresh for 15
  minutes and cannot publish or yank. Nothing revokes a session today; the tables' resource policy refuses `DeleteItem`
  to the handler roles, so revoking means setting `revoked_at`.
- The registry API is Node.js Lambdas (`service/api`). The Rust port has its foundation and no deployed function:
  `mopm_core` (pure rules, the error catalogue), `mopm_ports` (the `AuthStore` over users, tokens and device logins;
  `SecretReader`; `Clock`, `Rng`), `mopm_aws` (`DynamoAuthStore`, writing the TypeScript adapters' rows, tested against a
  fake DynamoDB that enforces the roles' grants; `SecretsManagerReader`), `mopm_testing` (memory stores, the port
  contracts), and `tools/lambda` (`lambda_zip`, the custom-runtime package with its sha256 sums, and a canary handler on
  `lambda_runtime`). There is no outbound HTTP client and no namespace store in Rust yet.
- Rate limits: per-account and per-token counters per UTC day for uploads, claims and groups (`rl#...` rows), and a
  gateway throttle on the index routes. Alarms exist on the publish pipeline (`publish-stack.ts`) but none has an
  action: nothing notifies anyone.
- Nothing in the service can run code, and nothing calls a third-party service other than GitHub.

## 1. Identity: GitHub, through the existing OAuth app

GitHub is the one provider because the account already is a GitHub account: namespaces are GitHub logins, users are
keyed by GitHub numeric id, trusted publishing is a GitHub Actions identity. A second provider would be a second
account model with nothing to own.

The web flow is appendix C.1 with these paths:

- `GET /api/v2/auth/web/start?return_to=` refuses unless `Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document` and
  `Sec-Fetch-Site` `none` or `same-origin`; checks `return_to` (starts with `/` but not `//` or `/\`, no control
  characters or backslashes, at most 256 characters, in the site's route grammar; otherwise `/tutorial`, where appendix C.1 says `/account`, a page this design does
  not build); stores a
  `web_logins` row `{id: sha256(txn), state_hash, code_verifier, return_to, expires_at: now + 600 s}`; sets
  `__Host-mopm_login=<txn>` (`Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=600`: `Lax`, because the callback is a
  top-level navigation from github.com, which a `Strict` cookie would miss); and redirects to GitHub with `scope=read:user`, a 256-bit `state`, an S256
  challenge, the exact `redirect_uri` from the stage settings (section 5) and `prompt=select_account`.
- `GET /api/v2/auth/web/callback?code&state` consumes the row once (a conditional update on `consumed_at`), compares the
  state hash in constant time, exchanges the code with the client secret and the verifier, reads `GET /user`, applies
  the two-factor rule, upserts the user and creates the user namespace exactly as the device login does, discards the
  GitHub token, mints the session (section 2), revokes the session the browser held before, clears the login cookie
  and answers 303 (appendix C.1 says 302 for start and 303 here; both stay) to the site origin from the stage settings
  plus `return_to`, with `Referrer-Policy: no-referrer` and
  `Cache-Control: no-store`.
- Failures answer 303 to `/tutorial?error=<code>` from a fixed list (`access_denied`, `two_factor_required`,
  `login_expired`, `unavailable`); the page explains each one and, for `two_factor_required`, links to GitHub's
  instructions.

Each stage's OAuth app keeps its device flow and gains the callback `https://<site>/api/v2/auth/web/callback`; GitHub
accepts a `redirect_uri` equal to the app's callback URL or below it, and the registry always sends it exactly. Only
`web-login` reads `client_secret`; whether each stage's secret holds a current one is **unverified** and is the operator
step tu-O1.

## 2. The session

- **Cookie**: `__Host-mopm_session=<token>; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=604800`. `__Host-` makes it
  host-only, so it never reaches `api.<site>`, `conda.<site>` or another stage (beta and gamma are subdomains of the
  prod site). Only that exact name is read; a request with two of them is refused.
- **Value**: a session token in today's format (`mopm_` and 40 base32 characters), `kind: session`, name `web login`,
  7 days absolute, and `fresh_until` equal to its creation time, so the TypeScript token routes never treat it as a
  fresh session (it could not create an API token even if it left the cookie). It is a row in `tokens` like the CLI's
  session; revocation is the existing `revoked_at`. No signing key is introduced.
- **Where it is accepted**: `GET /api/v2/auth/web/session`, `POST /api/v2/auth/web/logout` and `POST
  /api/v2/tutorial/runs`, and only on requests that carry the header the site distribution adds (section 2.1). The
  TypeScript functions do not read cookies at all, so publish, yank, token and namespace routes cannot be reached with
  one. An `Authorization` header on these three routes is refused (`invalid_request`), never combined with the cookie.
- **CSRF**: every cookie-authenticated `POST` needs the exact site `Origin`, `Sec-Fetch-Site: same-origin`,
  `Content-Type: application/json` when it has a body, and `X-Mopm-CSRF`, base64url(SHA-256("mopm-csrf\0" + session
  token)). `GET /api/v2/auth/web/session` returns `{login, csrf, expires_at}`, or 401 `session_required`. Nothing new is
  stored for it.
- **Sign-out**: the tutorial page's "Sign out" sends `POST /api/v2/auth/web/logout`, which sets `revoked_at` on this
  session's row, clears the cookie (`Max-Age=0`) and answers 204. The CLI's sessions and API tokens are untouched.
  "Sign out everywhere", the session list and the account page stay in mopm-dev.md (PRs 4a, 5).
- **Expiry in the page**: after 7 days, or after sign-out in another tab, a run answers `session_required` and the page
  shows the sign-in card with the user's code kept in the editor (section 8).

### 2.1 The API on the site host

Ruled by the CEO: yes. tu-I1 adds to the site distribution a behaviour for `/api/*` whose origin is the stage's API
Gateway custom domain (`api.<site>`, HTTPS only), with all methods, the managed `CachingDisabled` cache policy, an
origin request policy that forwards every viewer header except `Host`, every cookie and the query string, an origin
read timeout of 30 s set explicitly, and a custom origin header `x-mopm-edge` whose value is a per-stage secret.
CloudFront sets a configured origin custom header itself, replacing any header of that name the viewer sent. The new Rust
functions refuse every request without the right value, on all five routes, start and callback included, so none of them
is reachable straight at `api.<site>`. The header is defence in depth, not the boundary: its value is readable by
anyone allowed `cloudfront:GetDistributionConfig` on the stage's account. What keeps the cookie off `api.<site>` is
that `__Host-` makes it host-only, so the browser never sends it there. The behaviour gets its own response headers policy (`nosniff`, `no-referrer`, HSTS, `Content-Security-Policy:
default-src 'none'; sandbox; frame-ancestors 'none'`). In the same PR the distribution-wide 403 and 404 error responses
give way to the edge router answering the 404 page for unknown pages (else API errors would turn into HTML), the site's
`apiBase()` becomes the relative `/api/v2`, and the page CSP's `connect-src` becomes `'self'`. `api.<site>` stays as it
is for the CLI and CI.

The origin header's value lives in Secrets Manager (`mopm/<stage>/edge-origin`, generated at creation) and reaches the
distribution as a dynamic reference at deploy, so it is never committed (**unverified** that CloudFormation resolves a
Secrets Manager reference in a CloudFront origin custom header; if not, tu-I1 sets it from a held step).

## 3. The gate

The gate sits where letting a stranger through costs us something: running code.

- **Server**: `POST /api/v2/tutorial/runs` refuses without a valid session cookie (`session_required`, 401) or with a
  bad CSRF check (`csrf_failed`, 403). This is the only place that decides who may run code.
- **Pages**: `/tutorial` (the list of lessons) and `/tutorial/<lesson>` are public and show the lesson text to
  everyone, as the CEO ruled (Q-T1). The page calls `GET /api/v2/auth/web/session`: signed in, it shows the editor, Run
  and Test, the login and "Sign out"; signed out, it shows "Sign in with GitHub to run this lesson" linking to
  `/api/v2/auth/web/start?return_to=/tutorial/<lesson>` where the editor would be.
- **Scripts**: the run endpoint accepts no bearer token, so the CLI's session cannot drive it. A signed-in user can copy
  their own cookie into a script; the in-flight limit and the spend ceiling bound that, and the per-user usage rows
  show it (section 6).

## 4. Where the tutorial's code runs: a hosted sandbox provider

The tutorial's author has been working with a hosted sandbox service; its name comes from them, so this design takes it
as a parameter, `<provider>`. The registry calls it for the user; the browser never sees the provider.

**What the provider must offer** (tu-X1 checks the named one against this list before its adapter is written):

1. An HTTPS API authenticated by an API key.
2. A sandbox (VM or container) started from a template or image we define, so mopm, the Mojo toolchain and each lesson's
   synced project are already inside and a run downloads nothing (the Mojo 1.0.0 closure for `linux-64` is about 229 MiB
   compressed, `src/core/toolchain/mojo-1.0.0-linux-64.json`, too slow to fetch per run).
3. Writing files into a sandbox and running a command in it with a timeout, returning exit code, standard output and
   standard error.
4. A fresh sandbox per run, destroyed afterwards, or one the caller can destroy, with nothing shared between sandboxes.
5. CPU and memory set by the caller, and a maximum lifetime enforced by the provider even if we never call back.
6. Outbound network turned off for the sandbox. If the provider cannot do this, the CEO decides whether to accept it
   (Q-T6); our bounds still hold, but the sandbox could reach the internet for its 20 seconds.
7. A price per sandbox-second (or per CPU-second and GB-second) we can multiply out, and preferably a spend limit on the
   provider's side as a second wall.

**A run**, inside `tutorial-run`, after the gate and the bounds of section 6:

1. Validate the request `{lesson, action, files}` against the lesson manifest compiled into the function: `lesson` is a
   known lesson id, `action` is `run` or `test`, every path in `files` is one of the lesson's `editable` files, at most 8
   files and 64 KiB in total, UTF-8 with no NUL. Else `invalid_request`, naming the file or the limit.
2. Create a sandbox from the stage's template (2 vCPU, 4 GiB, network off, a provider-side lifetime of 60 s), write the
   files into the lesson's project, and run `mopm run` or `mopm test` there with a 20 s timeout for build and run
   together.
3. Keep at most 64 KiB of standard output and 64 KiB of standard error; drop the rest and mark the result truncated.
4. Destroy the sandbox, whatever happened, and answer `{verdict, exit_code, stdout, stderr, truncated, duration_ms}`,
   `verdict` one of `ok`, `failed`, `timeout`, `oom` (when the provider reports it), `killed`.

The run is synchronous: the function's timeout is 28 s, under API Gateway's 30 s, which leaves about 8 s for creating and
destroying the sandbox (**unverified** for the named provider; tu-X1 measures it, and if it does not fit, the run
becomes start-and-poll, which holds a result for minutes and comes back to the CEO because section 7 says no output is
stored).

**The key**: `mopm/<stage>/tutorial-sandbox`, a Secrets Manager secret holding `{api_key, template}` for the provider,
written by a held operator script like the OAuth secret's. Its resource policy has one explicit `Deny` of
`secretsmanager:GetSecretValue` with the condition `ArnNotEquals aws:PrincipalArn` the `tutorial-run` role (not
`NotPrincipal`, which misreads assumed-role sessions), so no other function, and no deploy or e2e role, can read it,
whatever its own policy says. Writing the value (`PutSecretValue`, the held script) and CloudFormation's management of
the secret are not denied. The function reads
it at cold start and keeps it in memory; it never logs it and never returns it.

**What the provider sees**: the lesson id, the user's files and the output; a run carries our request id and no GitHub
id, login or address. The page says so beside Run ("Your code runs on <provider>'s sandbox and is not stored by us"),
and the privacy page of tu-S3 names the provider.

The lesson projects are `tutorial/lessons/<id>/project/` in this repository; the template is built from them and the
pinned mopm release (tu-X2). Building and registering a template with the provider is an operator step on each stage
until tu-X2 shows whether the provider's API lets the deploy pipeline do it.

## 5. The functions: the first Rust Lambdas

The new functions are Rust, each its own Lambda (custom runtime `provided.al2023`, x86_64, packed by `lambda_zip`),
routed by the existing HTTP API next to the TypeScript integrations:

| function | routes | can touch |
|---|---|---|
| `web-login` | `GET /api/v2/auth/web/start`, `GET /api/v2/auth/web/callback` | `client_secret` of `mopm/<stage>/github-oauth`; `web_logins`; `users` and `namespaces` (upsert, as the device login); `tokens` (put, revoke) |
| `web-session` | `GET /api/v2/auth/web/session`, `POST /api/v2/auth/web/logout` | `tokens` (get, touch, revoke); `users` (get) |
| `tutorial-run` | `POST /api/v2/tutorial/runs` | `tokens` (get, touch); `users` (get); `tutorial_usage`; `mopm/<stage>/tutorial-sandbox`; HTTPS to the provider |

Each role grants exactly that, and the fake DynamoDB of `mopm_testing` enforces the grants in tests as it does for the
auth grants today. The TypeScript functions keep every route they have and read and write the same `tokens`, `users`
and `namespaces` rows; `mopm_aws`'s adapters already write the TypeScript adapters' rows, and their tests hold the shapes
equal, so the two languages share the tables safely. When the rest of the port comes, these functions are already
done; nothing here is rewritten.

What the Rust tree gains, each in the crate where its kind already lives:

- `mopm_core`: token minting and hashing (`mopm_` + base32, SHA-256, the prefix), ported from `tokens.ts` and held to
  its outputs; the CSRF derivation; the `return_to` grammar; the lesson manifest and request validation; the new error
  codes in the catalogue.
- `mopm_ports`: `HttpClient` (one request, one response, bytes and headers); `NamespaceStore` (the user namespace at
  login); `WebLoginStore`; `TutorialUsageStore` (section 6); `Sandbox` (create, write, run, destroy).
- `mopm_aws`: the DynamoDB adapters of the new stores and of namespaces; an `HttpClient` on `hyper` and `rustls` with
  the workspace's AWS-LC, so every outbound TLS connection uses the pinned stack.
- `mopm_testing`: memory stores, a fake GitHub and a fake sandbox, both scripted servers on loopback like `fake_http`.
- `service/lambda/web` (`mopm_web`): cookies, the session authenticator over `AuthStore`, the edge-header and CSRF
  checks, responses with `Set-Cookie` and redirects, the error envelope.
- `service/lambda/sandbox_<provider>`: the adapter of the named provider, behind `Sandbox`.
- `service/lambda/fn_web_login`, `fn_web_session`, `fn_tutorial_run`: the three binaries, each a `main.rs` that only
  wires its library to `lambda_runtime`.

**Stage settings**: the redirect URI, the site origin, the two-factor rule, the provider's price and the spend ceiling
are one item, `stage_settings`, in the stage's existing `config` table, written by the stack at deploy and read by each
function at cold start. The only environment variable a function reads is Lambda's own `AWS_LAMBDA_FUNCTION_NAME`
(`mopm-<stage>-<function>`), a platform-set marker that names the stage and so the tables (S2). The TypeScript
functions keep their environment variables; moving them is not this note's work.

New third-party crates (`hyper`, `hyper-util`, `hyper-rustls`, `http-body-util`) come from crates.io under MIT or
Apache-2.0 and land with `buildrules sync`'s outputs (R11).

**Deploying them**: `promote.yml` gains one job before the beta deploy that builds the three zips on the farm with
their named targets and hands them to every stage's deploy as one artifact; each deploy compares the function's
`CodeSha256` with the zip's sums file, so beta, gamma and prod run the same bytes. This is the deploy pipeline, not a
PR check (B9).

## 6. Bounds: no daily cap for users, a spend ceiling for us

The CEO ruled out per-user daily caps. What stays is what stops runaway use and that a normal user never meets:

| bound | value | refusal (status, code, message) |
|---|---|---|
| runs in flight per user | 2 | 409 `run_in_progress`: "You already have two runs going. When one finishes, run again." |
| a run's size | 8 files, 64 KiB | 400 `invalid_request`: names the file or the limit |
| a run's time | 20 s for build and run; the provider's sandbox lifetime 60 s | not a refusal: verdict `timeout`, "Your program ran for more than 20 seconds and was stopped." |
| the day's spend, all users together | a stage setting (section 5), proposed 20 US dollars (Q-T5) | 503 `tutorial_busy`, `Retry-After` to 00:00 UTC: "The tutorial has used up today's sandbox time. Runs start again at 00:00 UTC. Your code is saved in this browser." |
| the route, all users together | gateway throttle 50 a second, burst 100 | 429 from the gateway; the page says "Too many runs at once on mopm.dev. Try again in a few seconds." |
| the provider fails | | 503 `tutorial_unavailable`: "The sandbox did not answer. Try again in a minute." |

Every refusal has its own message in the page, and none of them loses the user's code.

**How the bounds are kept**, in `tutorial_usage` (pk `key`, TTL `expires_at`, pay per request):

- `inflight#<github_id>`: `{n, updated_at}`. A run starts if `n < 2`, adding one; or, if `updated_at` is more than
  60 s old (no run lasts longer, so such a marker was left by a killed function), it sets `n` to 1 outright. Both are
  conditions of the same write, compared in the condition rather than left to TTL, which deletes late. It subtracts one
  when it ends, never below zero.
- `spend#<UTC day>`: micro-dollars. A run starts only if the day's spend plus the run's maximum cost (60 s at the
  sandbox's price) stays under the ceiling, and adds that maximum; when the run ends it subtracts the difference to
  the actual cost (the sandbox's lifetime from create to destroy, times the price), on the row of the day the run
  started, whose key it keeps from start to end. The ceiling therefore cannot be passed, even by many runs at once or
  by a run that crosses 00:00 UTC.
- `user#<github_id>#<UTC day>`: runs, sandbox milliseconds, refusals. Counted, never enforced; kept 35 days. Adding a
  cap later is one more condition in the same transaction, if the numbers ever call for it.

The start writes `inflight#` and `spend#` (and counts in `user#`) in one DynamoDB transaction, so a refusal writes
nothing. The end is one update per item, conditioned so that it cannot drive `n` below zero. A provider failure before
the sandbox started releases the run's whole reserved cost; after it started, the actual lifetime is charged, because
the provider charges it.

**Alerts**: each run writes one log line in CloudWatch's embedded metric format with the day's spend, and two alarms
watch it, at 50 % and 90 % of the ceiling, plus one when a run is refused at the ceiling. They notify a new SNS topic,
`mopm-<stage>-alerts`, whose email subscription the operator adds by hand (tu-O1), so no address is committed. The
existing alarms can use the same topic later; this note does not change them.

**Seeing abuse**: the per-run log line has the request id, GitHub id, lesson, action, verdict, sandbox milliseconds,
cost and byte counts, never code or output. The runbook gains a saved Logs Insights query for the top users by runs and
by cost over a day, next to a read of the `user#` rows.

**What it costs at worst**: the ceiling. A run costs at most its 60 s sandbox lifetime at the provider's price, plus
about 0.0001 US dollars of Lambda time (28 s at 128 MB, **unverified** that 128 MB is enough for the function). Per-run
and per-day figures for the named provider go into tu-X1.

## 7. What is stored

| where | what | how long |
|---|---|---|
| `users` (existing) | GitHub numeric id, login as `handle`, `created_at`, `last_login_at`, the two-factor flag. Nothing new. | as today |
| `namespaces` (existing) | the user namespace, created at the first sign-in, as the CLI's login does | as today |
| `tokens` (existing) | the session: SHA-256 of the token, prefix, `kind: session`, name `web login`, GitHub id, `created_at`, `fresh_until`, `expires_at`, `last_used_at`, `revoked_at` | TTL at 7 days |
| `web_logins` (new) | the login transaction: SHA-256 of its id, SHA-256 of `state`, the PKCE verifier, `return_to`, `consumed_at` | TTL at 10 minutes |
| `tutorial_usage` (new) | the in-flight marker; per user and UTC day: runs, sandbox milliseconds, refusals; per UTC day: spend | 1 day, 35 days, 35 days |
| logs (existing retention, one month) | one line per run: request id, GitHub id, lesson, action, verdict, sandbox milliseconds, cost, bytes in and out | one month |
| `<provider>` | the run's files and output, for the sandbox's life; whatever the provider's own logs keep | the provider's terms |
| the browser | the cookie; edited files and the last lesson opened in `localStorage` under `mopm.tutorial.1`, sent only in a run | until cleared |

We never store the user's code or output, the GitHub token, the email address, or the IP address (the API has no
access log and the functions do not read the source address). The site distribution's standard logs stay off.

## 8. The tutorial pages

- New shell page `tutorial.html`, PageKind `tutorial`, an area stylesheet `tutorial.css` within the 16 KiB area budget;
  routes `/tutorial` and `/tutorial/<lesson>` (`^[a-z0-9]+(-[a-z0-9]+)*$`) in `site/src/routes.ts`, and from there in
  the edge router.
- Lesson text is prerendered from `tutorial/lessons/<id>/lesson.md` by the site's restricted Markdown renderer, so it
  works without scripts and without a session.
- The editor is a `<textarea>` per editable file: no editor library, since the site has no runtime dependencies. Output
  is text nodes in a `<pre>`; control, bidi and invisible characters show as markers, as appendix C.2's copied-example
  rule does.
- A `TutorialGate` port (`site/src/tutorial/gate.ts`): `session()` (`{signed_in: true, login, csrf, expires_at}` or
  `{signed_in: false}`), `run(request)`, `signInHref(returnTo)` (a `SafeHref`), `signOut()`. The real one calls the
  routes of sections 2 and 4 with `credentials: 'same-origin'`; tests use a fake that replays the contract examples.
- Beside Run: "Runs in a sandbox on <provider>, 20 seconds at most. Your code is not stored by us." Every refusal of
  section 6 has its message; `session_required` keeps the code in the editor.
- Lessons are `tutorial/lessons/<id>/`: `lesson.md`, `lesson.json` (title, summary, order, editable files, actions) and
  `project/` (a mopm project with `mopm.toml` and `mopm.lock`). The site build reads the first two, `tutorial-run`
  compiles `lesson.json`'s editable lists in, the template build takes `project/`. One schema,
  `spec/tutorial-lesson.schema.json`, is the contract between them.
- An answer that is not the API's JSON (CloudFront's 504 page after 30 s, the gateway's 429 body) is mapped by its
  status: 504 and 5xx to "The sandbox did not answer. Try again in a minute.", 429 to the throttle message of section 6.
- The header gains "Tutorial"; the login and "Sign out" show on the tutorial pages only, so other pages make no call
  they do not need.

## 9. Implementation tasks and order

S is under 200 lines, M under 600, L more. Task ids are prefixed `tu-` so they read apart from rule ids. Each names the
behaviour its tests assert. Every test is hermetic: fakes for GitHub, the stores, the provider and the clock; a loopback
listener on port 0 where an HTTP server is needed.

Contract first, so the tutorial can be built against it:

- tu-P1 (M) The wire contract: in `spec/api/mopm/registry/v2/*.proto`, the rpcs `StartWebLogin`, `CompleteWebLogin`,
  `GetWebSession`, `WebLogout` and `RunTutorial`, and the error codes `session_required`, `csrf_failed`,
  `run_in_progress`, `tutorial_busy`, `tutorial_unavailable`; `spec/api/openapi-v2.yaml` and the generated outputs of
  `tools/api_gen.zig`; contract examples `tests/contract/api-v2/web-auth.json` and `tutorial.json` (signed in, signed
  out, each refusal, each verdict, a truncated output); `spec/tutorial-lesson.schema.json`. Additive only. Tests: the
  generator's check that checked-in outputs equal its output; the schema accepts the example lesson and refuses an
  editable path outside `project/`, a missing action and an id out of grammar.
- tu-S1 (M) The stub gate: `site/src/tutorial/gate.ts` with the real client and the replaying fake, and
  `site/tools/preview.ts`, which serves `dist/` on 127.0.0.1 (port 0, printed) and answers `/api/v2/auth/web/*` and
  `/api/v2/tutorial/runs` from the contract examples, the scenario chosen by a flag (`--signed-out`, `--busy`,
  `--timeout`, ...); `site/src/host.ts` maps `127.0.0.1` and `localhost` to the relative API base. Nothing of it reaches
  a deployed stage. Tests: the client decodes every contract example and maps every error code; the preview server
  answers each scenario; an unknown host still gets no API.
- tu-S2 (L) The tutorial pages and the first lessons (section 8), against tu-S1 only; not routed by the edge router, so
  nothing shows on any stage. Tests through the fake gate: signed out shows the lesson and the sign-in link with the
  right `return_to` and no editor; signed in shows the editor and the login; each verdict and each refusal renders its
  message; `session_required` keeps the edited code; truncated output says so; control and bidi characters show as
  markers; the draft survives a reload through `localStorage` and the page works when `localStorage` throws; every
  lesson in `tutorial/` validates against the schema and its editable files exist.

The Rust foundation:

- tu-F1 (M) `mopm_core` token minting and hashing, CSRF derivation, `return_to` grammar, lesson validation, the new
  error codes; `mopm_ports` `HttpClient`, `NamespaceStore`, `WebLoginStore`, `TutorialUsageStore`, `Sandbox`;
  `mopm_testing` memory stores, fake GitHub, fake sandbox and the contract cases of each new port. Tests: tokens equal
  `tokens.ts`'s for the same random bytes (format, hash, prefix) and the TypeScript authenticator accepts a row the Rust
  wrote; every `return_to` case of appendix C.1, with section 1's `/tutorial` fallback; each validation refusal; the memory stores pass their port contracts,
  including two concurrent starts against an `inflight#` at `n = 1` (one wins) and a spend reservation that would pass
  the ceiling (refused, nothing written).
- tu-F2 (M) `mopm_aws`: the DynamoDB adapters of the new stores and of namespaces, and the `hyper`/`rustls`
  `HttpClient`, with the new crates and `buildrules sync`'s outputs. Tests: the same port contracts against the fake
  DynamoDB, with the rows asserted as DynamoDB JSON and the namespace row equal to the TypeScript adapter's; nothing
  calls `DeleteItem`; the client against `fake_http` over TLS with a test certificate, and a refused certificate.
- tu-F3 (S) `promote.yml` builds the function zips once per commit and every deploy checks `CodeSha256` against the
  sums. Tests: the workflow lint's fixtures for the new job (the chain and the called files as `//:workflows` checks
  them), and a fixture whose deploy skips the check fails.

Sign-in:

- tu-A1 (M) `mopm_web` and `fn_web_session`: cookies (one exact name, two refused), the edge-header check, the session
  authenticator, CSRF, `GET /api/v2/auth/web/session`, `POST /api/v2/auth/web/logout`. Infra: the function, its routes
  and grants. Tests against the memory and fake DynamoDB stores: a valid cookie answers the session; expired, revoked,
  unknown and duplicated cookies and a missing edge header are 401; a bad `Origin`, `Sec-Fetch-Site`, content type or
  CSRF value is 403; an `Authorization` header is refused; logout revokes only its own session and clears the cookie;
  the role's grants are exactly the table of section 5.
- tu-A2 (M) `fn_web_login`: start and callback, the `web_logins` table, `client_secret` read in this function only.
  Tests against the fake GitHub: a full sign-in sets the cookie and redirects to `return_to`; the login cookie and the session cookie carry
  exactly the attributes of sections 1 and 2 (`SameSite=Lax` on both); a request without the edge header, or with a
  wrong one, is refused on start and callback; a replayed callback, a
  wrong `state`, an expired row, a missing login cookie, a cross-site start (each `Sec-Fetch-*` case) and every bad
  `return_to` are refused or fall back as section 1 says; two-factor off is `two_factor_required` and stores nothing;
  `access_denied` and a GitHub outage map to their codes; the GitHub token is not stored; signing in revokes the
  previous session; the session's `fresh_until` equals its creation; the user and namespace rows equal those the
  TypeScript device login writes for the same GitHub user.
- tu-I1 (M) The site distribution's `/api/*` behaviour as section 2.1 says, the `edge-origin` secret, the 404 handling,
  the relative `apiBase()` and `connect-src 'self'`. Tests in the stack and site-router tests: the behaviour, its
  policies, the origin header and the 30 s origin read timeout exist with those values; existing pages and their
  headers are unchanged apart from `connect-src`; `/api/v2/...` is routed to the API origin and a JSON 404 stays
  JSON; an unknown page still gets the 404 page; the page CSP has `connect-src 'self'`.

The run:

- tu-X1 (S, with the tutorial's author) The named provider against section 4's list, its prices and its create, run
  and destroy times, written into this note's section 4 as a short amendment. No code.
- tu-X2 (M) `sandbox_<provider>`: the `Sandbox` adapter, and the template built from `tutorial/lessons/*/project` and the
  pinned mopm release. Tests against a scripted fake of the provider's API on loopback: create, write, run and destroy
  send what the provider's API documents; the key is sent only in its header and appears in no log or error; destroy
  runs after a failed run and after a timeout; a provider error maps to `tutorial_unavailable`; output over 64 KiB is
  cut and marked.
- tu-A3 (M) `fn_tutorial_run`: the run of section 4 and the bounds of section 6; the `tutorial_usage` table, the
  `tutorial-sandbox` secret with its resource policy, the gateway throttle, the alarms and the SNS topic. Tests against
  the memory and fake DynamoDB stores, the fake sandbox and a fixed clock: no session, bad CSRF and bad bodies are
  refused before any write; a third run while two are in flight is `run_in_progress`, and a marker 60 s old does not
  block, and resets to `n = 1`; a run whose reservation would pass the ceiling is `tutorial_busy` with `Retry-After` to 00:00 UTC and writes
  nothing; the day boundary starts a new spend row; the actual cost replaces the reservation at the end; a provider
  failure before create releases the whole reservation; the `user#` row counts runs, milliseconds and refusals and never
  refuses; the log line has the fields of section 6 and no code or output (asserted by exact equality); the stack test
  shows the secret's policy has the `Deny` of section 4 with this function's role as the only exception, that a policy
  without that `Deny` fails the test, that neither other new function's role has any grant on the secret, and that the
  alarms at 50 % and 90 % notify the topic; a run that starts before 00:00 UTC and ends after settles on the start
  day's row; two stale runs leave a marker at `n = 2` that a run 60 s later resets to 1.

Operator:

- tu-O1 (operator) On each stage: the OAuth app's callback URL; check with the held `oauth-secret` script's dry run that
  the secret holds a current `client_secret`; write `mopm/<stage>/tutorial-sandbox` with the provider's key and template
  (a held script beside `oauth-secret`, added in tu-A3); subscribe the operator's address to `mopm-<stage>-alerts`.
  Before tu-A2 and tu-A3 deploy. Needs the owner's hands.

Go-live:

- tu-S3 (S) The edge router routes `/tutorial` and `/tutorial/<lesson>`; the header's "Tutorial" link; the docs page
  "What mopm.dev stores", from section 7, naming the provider. Tests: the route fixtures (`site/test/fixtures/routes.json`)
  and the site-router test; the layout test for the header. This is the step users see.

Order: tu-P1 first. tu-S1 after tu-P1; tu-S2 after tu-S1, and in parallel with everything below. tu-F1, tu-I1 and tu-X1
start at once; tu-F2 after tu-F1; tu-F3 after tu-F2. tu-A1 after tu-F2 and tu-F3; tu-A2 after tu-A1, deployed after
tu-O1. tu-X2 after tu-X1 and tu-F2. tu-A3 after tu-A1 and tu-X2, deployed after tu-O1. tu-S3 after tu-S2, with tu-A2,
tu-A3 and tu-I1 deployed to prod. Deploys stay automatic from main. The new routes answer only requests that carry the
distribution's header and no page links to them before tu-S3, so the sign-in and the tutorial appear only then. tu-I1
is different: once deployed it changes what every visitor gets (every API read of the site goes through the site host,
the CSP's `connect-src`, the 404 handling), so it is the one change before tu-S3 that users can notice if it is wrong.
Its stack and site-router tests hold the existing pages, a missing page and the site's reads to what they are today;
reverting it is one revert, since nothing else depends on it until tu-A1's routes are used.

## Decisions

1. GitHub is the only identity provider: the account model is already GitHub's numeric id.
2. The web login is mopm-dev.md's design; only the paths move to `/api/v2`, which the site now reads.
3. The tutorial needs only start, callback, session and sign-out; the session list, sign-out everywhere and the account
   page stay in mopm-dev.md, so the tutorial does not wait for them.
4. The session is an opaque token in the existing `tokens` table, not a signed cookie: one row format for both
   languages, revocation already works, no key to rotate.
5. 7 days absolute and no sliding renewal, as mopm-dev.md says; the CLI's 30 days is left alone.
6. The web session's `fresh_until` is its creation time, so a leaked cookie value cannot create an API token on the
   TypeScript routes.
7. A new route, `GET /api/v2/auth/web/session`, answers who is signed in, instead of making the TypeScript `GET /me`
   accept the cookie: the TypeScript side stays cookie-free and unchanged, and an API Gateway route has one
   integration.
8. Three Rust functions, split by what each may touch, so only `web-login` reads the OAuth secret and only
   `tutorial-run` reads the provider's key.
9. The run endpoint takes the cookie only, not bearer tokens, so code runs from the site.
10. The provider is a parameter with a list of required capabilities; the adapter waits for its name, and everything
    else is built and tested against the fake sandbox.
11. Users run lesson projects with edited files, not arbitrary projects: the template holds every dependency, and
    validation is a list of paths.
12. The spend ceiling reserves each run's maximum cost before it starts and settles the actual after, so the ceiling
    holds under concurrency.
13. Two runs in flight, not one: a double click or Run then Test is not refused.
14. Per-user counts are kept and not enforced, as the CEO ruled; a cap later is one condition on a row that already
    exists.
15. Alerts go to a new SNS topic with a subscription added by the operator, so no address is committed.
16. A synchronous run: one request, one answer, nothing stored; start-and-poll only if the named provider is too slow.
17. Draft code and progress stay in the browser's `localStorage`; nothing about tutorial progress is stored by us.
18. The local preview server is the stub gate: the same site code against the same contract.
19. Lessons live in `tutorial/` at the root, read by the site build, the run function and the template build, with
    one schema.
20. The function zips are built once per commit in the deploy pipeline and checked by sha256 at each stage, so the
    same bytes reach prod.

## Questions for the CEO

Answered:

- **Q-T1, the lesson text**: stays public; only running code is gated.
- **Q-T2, language**: Rust, as new Lambdas behind the same API Gateway sharing the tables with the TypeScript functions;
  the first piece of the port, with no TypeScript version.
- **Q-T3, two-factor**: kept for web sign-in, as for the CLI.
- **Q-T4, limits**: no per-user daily cap; one or two runs in flight; a global daily spend ceiling with an alert; per-user
  metrics to add a cap later. This note uses two in flight.
- **Where code runs**: a hosted sandbox provider with an API key held by the server; our own Lambda runner is dropped.
- **The API on the site host**: yes; tu-I1 adds the `/api/*` behaviour to the API Gateway origin.

Open:

- **Q-T5, the daily spend ceiling**: proposed 20 US dollars a day on prod, 2 on beta and gamma. **Recommend: start
  there**, and read the 50 % alerts for the first weeks.
- **Q-T6, the sandbox's network**: if the named provider cannot turn outbound network off, accept it or choose another
  provider. **Recommend: require it** (section 4, item 6); without it a run can reach the internet for 20 seconds from an
  address the provider gives it.
- **Q-T7, the provider's name**: from the tutorial's author; tu-X1 checks it against section 4 and amends this note.
