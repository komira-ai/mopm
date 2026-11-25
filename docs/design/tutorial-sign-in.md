# Sign-in for mopm.dev and sandboxes for the interactive tutorial

Status: proposal, revised after the CEO's rulings (see "Questions for the CEO"). It changes what users see (a sign-in,
a tutorial that runs code) and the public interface (new `/api/v2` routes and error codes, a cookie). No code changes
in this PR. **Unverified** marks what no code, doc or run has confirmed; every time and size is an estimate unless
section 4.1 marks it measured, or until the task that names it measures it. E2B facts cite E2B's documentation ("Sources" at the end) or the published `e2b` npm
package, version 2.64.0, the version current when this was written.

The interactive tutorial runs code in a browser-facing sandbox on [E2B](https://e2b.dev). Our service does two things
only: it signs the user in with GitHub, and it hands a signed-in user a sandbox of their own. The tutorial page then
talks to that sandbox directly with E2B's JavaScript SDK. The team's E2B API key never leaves our service, because
with it any signed-in user could create sandboxes with the network on.

## For the tutorial's author: what to build against

The guide to building the tutorial's pages against this, with type-checked code for an editor and a terminal over the
sandbox's token, is [`docs/tutorial-author-guide.md`](../tutorial-author-guide.md).

### The endpoint

`POST /api/v2/tutorial/sandbox` on the site's own host (`https://mopm.dev`, `https://beta.mopm.dev`, ...; section 2.1).
It creates one E2B sandbox for the signed-in user, with internet access disabled, and returns what the browser needs to
reach it.

Request:

```http
POST /api/v2/tutorial/sandbox
Cookie: __Host-mopm_session=...        (sent by the browser; use credentials: 'same-origin')
X-Mopm-CSRF: <csrf from GET /api/v2/auth/web/session>
Origin, Sec-Fetch-Site: same-origin    (set by the browser)
(no body)
```

The CSRF value comes from `GET /api/v2/auth/web/session`, which answers `200 {"login", "csrf", "expires_at"}` when
signed in and `401 session_required` when not (section 2).

Response, `201 Created`, `Cache-Control: no-store` (example values):

```json
{
  "sandbox_id": "i8x3k2p9q1v7m4n6s5t0",
  "access_token": "<opaque, issued by E2B for this sandbox only>",
  "envd_version": "0.4.2",
  "domain": "e2b.app",
  "expires_at": "2026-11-20T10:30:00Z"
}
```

| field | meaning |
|---|---|
| `sandbox_id` | E2B's id of the sandbox (`sandboxID` in E2B's create answer) |
| `access_token` | E2B's per-sandbox access token (`envdAccessToken`): it opens this one sandbox and nothing else (section 4) |
| `envd_version` | the version of E2B's in-sandbox agent; the SDK needs it to pick its protocol |
| `domain` | the base domain of the sandbox's address; the SDK reaches `https://49983-<sandbox_id>.<domain>` |
| `expires_at` | when E2B ends the sandbox (30 minutes after creation, section 4); after it, ask for a new one |

Errors are the API's usual envelope, `{"error": {"code", "message", "hint"}}` with an `x-mopm-request-id` header:

| status | `code` | when | what the page does |
|---|---|---|---|
| 401 | `session_required` | no session cookie, or it is expired or revoked | show "Sign in with GitHub to run this lesson"; keep the code in the editor |
| 403 | `csrf_failed` | `X-Mopm-CSRF`, `Origin` or `Sec-Fetch-Site` is wrong | fetch the session again (another tab may have signed in again) and retry once; then "Reload the page." |
| 400 | `invalid_request` | a request body, or an `Authorization` header | a bug in the page: "Something went wrong. Reload the page." |
| 503 | `tutorial_unavailable` | E2B refused the sandbox or did not answer in 8 s; `Retry-After: 30` | "The sandbox service did not answer. Try again in a minute." |
| any 5xx, not JSON | | CloudFront or API Gateway answered (for example a 504 page) | the same as `tutorial_unavailable` |

There is no limit to refuse with: a signed-in user may ask for as many sandboxes as they like (section 4).

After the grant, errors come from the E2B SDK in the browser (e2b 2.64.0):

- `CommandExitError` is the program's own non-zero exit. Show the exit code; it is not an error of the page.
- `SandboxNotRunningError` (killed or timed out) or `SandboxUnreachableError` means the sandbox is gone. Ask the
  endpoint for a new one and run again, once.
- `SandboxNotFoundError` comes only from E2B's platform API, which the page never calls. `NotFoundError` is a missing
  file or command.

### The frontend, in about 20 lines

```ts
import { Sandbox, CommandExitError, SandboxNotRunningError, SandboxUnreachableError } from 'e2b' // pinned (section 7)

let sbx: Sandbox | null = null, until = 0                  // one sandbox per page, reused until near expires_at
async function sandbox(csrf: string): Promise<Sandbox> {   // csrf from GET /api/v2/auth/web/session
  if (sbx && Date.now() < until - 60_000) return sbx
  const r = await fetch('/api/v2/tutorial/sandbox', { method: 'POST', credentials: 'same-origin', headers: { 'X-Mopm-CSRF': csrf } })
  if (!r.ok) throw new Error(await r.json().then((b) => b.error.code, () => 'tutorial_unavailable')) // the error table
  const g = await r.json()
  // Sandbox.connect() needs the team API key; the constructor takes only this sandbox's token (section 4).
  sbx = new Sandbox({ sandboxId: g.sandbox_id, sandboxDomain: g.domain, envdVersion: g.envd_version, envdAccessToken: g.access_token })
  until = Date.parse(g.expires_at)
  return sbx
}

export async function runLesson(csrf: string, code: string, show: (t: string) => void, again = true): Promise<number> {
  const s = await sandbox(csrf)
  try {
    await s.files.write('/home/user/lessons/hello/src/main.mojo', code)
    await s.commands.run('mopm run', { cwd: '/home/user/lessons/hello', timeoutMs: 20_000, onStdout: show, onStderr: show })
    return 0
  } catch (e) {
    if (e instanceof CommandExitError) return e.exitCode   // the program failed, not the page
    if (again && (e instanceof SandboxNotRunningError || e instanceof SandboxUnreachableError)) { sbx = null; return runLesson(csrf, code, show, false) }
    throw e
  }
}
```

The snippet was type-checked (`tsc` 5.9.3, `strict`) against `e2b` 2.64.0's published types; a misspelled
constructor field fails that check. It is the minimum. The real page (tu-S2) keeps the grant in memory only, never in
`localStorage`. It maps every error code to the table's message, and on `csrf_failed` it fetches the session again and
retries once. For E2B's `base` template, replace `mopm run` with a command the template has, such as `echo`. A client
built the same way (the constructor, `commands.run`, `files.write`), bundled with esbuild and served from a loopback
origin under the site's CSP, ran `echo` and wrote and read a file in a live beta sandbox from a browser, and E2B's
agent allows any origin (measured, section 4.1). The constructor is exported and typed
public, but E2B's SDK comments mark it `@internal` and E2B has not confirmed it as supported (section 4).

### Running it locally against the stub

tu-S1's preview server (`site/tools/preview.ts`) serves the built site on `127.0.0.1` and plays our side of the
contract:

```sh
cd site && npm ci --ignore-scripts --no-audit --no-fund && npm run build
npm run preview -- --scenario signed-out          # the session and sandbox routes answer session_required
npm run preview -- --scenario signed-in           # a fake session; with no key, the sandbox route answers tutorial_unavailable
E2B_API_KEY=<a key from your own E2B account> \
  npm run preview -- --scenario signed-in --e2b-template base   # creates real sandboxes, internet off
```

It prints its address (`http://127.0.0.1:<port>/tutorial`, the port picked by the system). That address shows the
tutorial page once tu-S2's build writes `dist/tutorial.html` (signed out: the lesson text and the sign-in card, no
editor), and the site's 404 page when the build wrote no tutorial page. In the `signed-in`
scenario, `GET /api/v2/auth/web/session` answers a fixed login and CSRF value. `POST /api/v2/tutorial/sandbox` makes the
same checks as the real route (the CSRF header, `Origin`, `Sec-Fetch-Site`, no body). With `E2B_API_KEY` set, it sends
E2B the same create body as the Rust function (section 4): the same JSON, from a second, TypeScript implementation
that tu-S1's tests hold equal to section 4. Your page code is therefore the same against the
stub and against prod. Other scenarios: `csrf-failed`, `unavailable`, `session-expired` (the session route answers 200,
then the sandbox route answers 401). The preview sends the site's CSP, so a CSP problem shows up locally.

Running code needs a real sandbox, so the success path needs a key. Get it from your own E2B account (E2B's Hobby
plan). Without a key, the scenarios cover every other state of the page, and tu-S2's tests use a fake runner in place of
the SDK. E2B's `base` template has no Mojo toolchain, so before tu-X2's template exists, wire the page with commands
such as `echo` or `python3 -c`. The key is read from the environment, as E2B's own tools read it. That is the one
setting that is not a flag, because it is secret material (S2). The preview never writes it anywhere.

In tests, `replayGate` of `site/src/tutorial/gate.ts` answers the contract examples through the real client, which is
enough to build every state of the page except a real run.

## Decisions at a glance

| area | decision |
|---|---|
| Identity provider | GitHub only, an OAuth web flow with S256 PKCE and `scope=read:user`, through each stage's existing OAuth app (section 1). The account is the one the CLI's device login already creates, keyed by GitHub numeric id, with the same two-factor rule. |
| Session | `__Host-mopm_session`: `Secure; HttpOnly; Path=/; SameSite=Lax`, 7 days absolute, no sliding renewal. The value is an opaque session token whose SHA-256 is a row in the existing `tokens` table. Sign-out revokes that row and clears the cookie (section 2). |
| Topology | The site's CloudFront distribution gains an `/api/*` behaviour whose origin is the stage's API Gateway, so the cookie is first-party and never reaches `api.<site>`; no credentialed CORS (section 2.1, tu-I1). |
| The gate | Only on getting a sandbox: `POST /api/v2/tutorial/sandbox` needs a valid session cookie and its CSRF header. Lesson text stays public; the pages show the editor and Run only when signed in (section 3). |
| Where code runs | An E2B sandbox per page, created by our service with internet access disabled. The browser gets that sandbox's access token and talks to it directly with E2B's JavaScript SDK. The team API key stays in Secrets Manager, readable by one function only (section 4). |
| Limits | None. A sandbox's 30-minute timeout is E2B's cleanup of an abandoned sandbox, not a limit: the page asks for a new one whenever it needs it (section 4). |
| Language | Three new Rust Lambdas behind the existing API Gateway: `web-login` (start, callback), `web-session` (session, sign-out), `tutorial-sandbox`. They share the `tokens`, `users` and `namespaces` tables with the TypeScript functions, which are not changed (section 5). |
| Stored about a user | Nothing new on the account. New rows: a 10-minute login transaction and the 7-day session. One log line per sandbox created. Code and output never pass through our service (section 6). |
| Stub for the tutorial's author | The wire contract lands first, then a local preview server that serves the built site, fakes our routes and, with the author's own E2B key, creates real sandboxes the way the function does (tu-P1, tu-S1). |

## What exists today

- The site is static: plain TypeScript compiled by `tsc` to ES modules, no framework, no bundler, no runtime
  dependencies (`site/README.md`, rule 1; it has since one exception, the `e2b` bundle of section 7). One CloudFront distribution has a private S3 bucket as its only origin and
  one default behaviour (`service/infra/stacks/lib/site-stack.ts`). An edge router (a CloudFront Function generated from
  `site/src/routes.ts`) maps `/`, `/search`, `/packages/...` and `/docs/...` to files. The site reads
  `https://api.<site>/api/v2` with `credentials: 'omit'` (`site/src/api.ts`, `site/src/host.ts`). There is no cookie,
  no browser storage and no sign-in in `site/`. Missing keys map to `/404.html` distribution-wide.
- The page CSP is `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src
  https://<api host>; ... require-trusted-types-for 'script'; trusted-types 'none'`. The API's CORS allows only the
  site's origin, only `GET`, `HEAD` and `OPTIONS`, and no credentials (`api-stack.ts`).
- Sign-in exists for the CLI only: the GitHub device flow of one OAuth app per stage, `scope=read:user`
  (`service/api/src/auth/device-login.ts`). The registry reads `GET https://api.github.com/user` once, applies the
  two-factor rule (`MOPM_REQUIRE_2FA`, on by default, fails closed), upserts the user, creates the user namespace and
  discards the GitHub token. The secret `mopm/<stage>/github-oauth` holds `client_id` and `client_secret`; the code
  reads only `client_id` (`service/api/src/http/oauth-secret.ts`). No callback URL is configured or used.
- A request is authenticated only by `Authorization: Bearer mopm_...`. The token's SHA-256 is the key of the `tokens`
  table, which has a TTL on `expires_at` and an index by GitHub id. A device-login session lives 30 days, is fresh for 15
  minutes and cannot publish or yank. Nothing revokes a session today. The tables' resource policy refuses `DeleteItem`
  to the handler roles, so revoking means setting `revoked_at`.
- The registry API is Node.js Lambdas (`service/api`). The Rust port has its foundation and no deployed function:
  `mopm_core` (pure rules, the error catalogue), `mopm_ports` (the `AuthStore` over users, tokens and device logins;
  `SecretReader`; `Clock`, `Rng`), `mopm_aws` (`DynamoAuthStore`, writing the TypeScript adapters' rows, tested against a
  fake DynamoDB that enforces the roles' grants; `SecretsManagerReader`), `mopm_testing` (memory stores, the port
  contracts), and `tools/lambda` (`lambda_zip`, the custom-runtime package with its sha256 sums, and a canary handler on
  `lambda_runtime`). There is no outbound HTTP client and no namespace store in Rust yet.
- Nothing in the service runs code, and nothing calls a third-party service other than GitHub.

## 1. Identity: GitHub, through the existing OAuth app

GitHub is the one provider because the account already is a GitHub account: namespaces are GitHub logins, users are
keyed by GitHub numeric id, and trusted publishing is a GitHub Actions identity. A second provider would be a second
account model with nothing to own.

The web flow is [mopm-dev.md](mopm-dev.md) section 4's, [appendix C.1](mopm-dev-appendix.md#c-web-login), with these
paths:

- **`GET /api/v2/auth/web/start?return_to=`**
  - Refuses unless `Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document`, and `Sec-Fetch-Site` is `none` or
    `same-origin`.
  - Checks `return_to`: it starts with `/` but not `//` or `/\`, has no control characters or backslashes, is at most
    256 characters and is in the site's route grammar. Otherwise it becomes `/tutorial`; appendix C.1 says `/account`,
    a page this design does not build.
  - Stores a `web_logins` row `{id: sha256(txn), state_hash, code_verifier, return_to, expires_at: now + 600 s}`.
  - Sets `__Host-mopm_login=<txn>` (`Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=600`). It is `Lax` because the
    callback is a top-level navigation from github.com, which a `Strict` cookie would miss.
  - Redirects to GitHub with `scope=read:user`, a 256-bit `state`, an S256 challenge, the exact `redirect_uri` from the
    stage settings (section 5) and `prompt=select_account`.
- **`GET /api/v2/auth/web/callback?code&state`**
  - Consumes the row once (a conditional update on `consumed_at`) and compares the state hash in constant time.
  - Exchanges the code with the client secret and the verifier, reads `GET /user` and applies the two-factor rule.
  - Upserts the user and creates the user namespace exactly as the device login does, then discards the GitHub token.
  - Mints the session (section 2), revokes the session the browser held before and clears the login cookie.
  - Answers 303 to the site origin from the stage settings plus `return_to`, with `Referrer-Policy: no-referrer` and
    `Cache-Control: no-store`. Appendix C.1 says 302 for start and 303 here; both stay.
- **Failures** answer 303 to `/tutorial?error=<code>`, the code from a fixed list: `access_denied`,
  `two_factor_required`, `login_expired`, `unavailable`. The page explains each one and, for `two_factor_required`,
  links to GitHub's instructions.

Each stage's OAuth app keeps its device flow and gains the callback `https://<site>/api/v2/auth/web/callback`. GitHub
accepts a `redirect_uri` equal to the app's callback URL or below it, and the registry always sends it exactly. Only
`web-login` reads `client_secret`. Whether each stage's secret holds a current one is **unverified**; checking it is the
operator step tu-O1.

## 2. The session

- **Cookie**: `__Host-mopm_session=<token>; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=604800`. `__Host-` makes it
  host-only, so it never reaches `api.<site>`, `conda.<site>` or another stage (beta and gamma are subdomains of the
  prod site). Only that exact name is read, and a request with two of them is refused.
- **Value**: a session token in today's format (`mopm_` and 40 base32 characters), `kind: session`, name `web login`.
  It lasts 7 days absolute, and its `fresh_until` equals its creation time, so the TypeScript token routes never treat
  it as a fresh session (it could not create an API token even if it left the cookie). It is a row in `tokens`, like the
  CLI's session, and is revoked with the existing `revoked_at`. No signing key is introduced.
- **Where it is accepted**: `GET /api/v2/auth/web/session`, `POST /api/v2/auth/web/logout` and
  `POST /api/v2/tutorial/sandbox`, and only on requests that carry the header the site distribution adds (section 2.1).
  The TypeScript functions do not read cookies at all, so publish, yank, token and namespace routes cannot be reached
  with one. An `Authorization` header on these three routes is refused (`invalid_request`), never combined with the
  cookie.
- **CSRF**: every cookie-authenticated `POST` needs:
  - the exact site `Origin`;
  - `Sec-Fetch-Site: same-origin`;
  - `Content-Type: application/json` when it has a body;
  - `X-Mopm-CSRF` equal to base64url(SHA-256("mopm-csrf\0" + session token)).

  `GET /api/v2/auth/web/session` returns `{login, csrf, expires_at}`, or 401 `session_required`. Nothing new is stored
  for it.
- **Sign-out**: "Sign out" in the header of every page (section 7) and on the tutorial page sends `POST /api/v2/auth/web/logout`. It sets `revoked_at` on this
  session's row, clears the cookie (`Max-Age=0`) and answers 204. The CLI's sessions and API tokens are untouched. "Sign
  out everywhere", the session list and the account page stay in mopm-dev.md (PRs 4a, 5). Signing out does not end a
  sandbox the page already holds; it ends at its `expires_at` (section 4).
- **Expiry in the page**: after 7 days, or after sign-out in another tab, the sandbox route answers `session_required`.
  The page then shows the sign-in card and keeps the user's code in the editor.

### 2.1 The API on the site host

Ruled by the CEO: yes. tu-I1 adds to the site distribution a behaviour for `/api/*`:

- **Origin**: the stage's API Gateway custom domain (`api.<site>`), HTTPS only.
- **Requests**: all methods, the managed `CachingDisabled` cache policy, and an origin request policy that forwards
  every viewer header except `Host`, every cookie and the query string.
- **Timeout**: an origin read timeout of 30 s, set explicitly.
- **Origin header**: a custom origin header `x-mopm-edge`, whose value is a per-stage secret. CloudFront sets a
  configured origin custom header itself, replacing any header of that name the viewer sent.
  - The new Rust functions refuse every request without the right value, on all five routes, start and callback
    included, so none of them is reachable straight at `api.<site>`.
  - The header is defence in depth, not the boundary: its value is readable by anyone allowed
    `cloudfront:GetDistributionConfig` on the stage's account. What keeps the cookie off `api.<site>` is that
    `__Host-` makes it host-only, so the browser never sends it there.
- **Response headers**: the behaviour gets its own response headers policy (`nosniff`, `no-referrer`, HSTS,
  `Content-Security-Policy: default-src 'none'; sandbox; frame-ancestors 'none'`).

The same PR makes these changes too:

- The distribution-wide 403 and 404 error responses give way to the edge router answering the 404 page for unknown
  pages; otherwise API errors would turn into HTML.
- The site's `apiBase()` becomes the relative `/api/v2`.
- The page CSP's `connect-src` becomes `'self' https://*.<E2B domain>` (the second source for the sandboxes, section 4).

`api.<site>` stays as it is for the CLI and CI.

The origin header's value lives in Secrets Manager (`mopm/<stage>/edge-origin`, generated at creation) and reaches the
distribution as a dynamic reference at deploy, so it is never committed. That CloudFormation resolves a Secrets Manager
reference in a CloudFront origin custom header is **unverified**; if it does not, tu-I1 sets the value from a held step.
After every deploy, e2e.yml's read-only sign-in checks (`tests/drivers/signin_e2e.zig`) send the sign-in start through the
site, where it must reach GitHub's authorize address with the login cookie, and straight at `api.<site>`, where it must be
refused: a stage whose distribution does not deliver the edge value, or whose OAuth secret or settings are missing, fails them.

## 3. The gate

The gate sits where letting a stranger through costs us something: getting a sandbox.

- **Server**: `POST /api/v2/tutorial/sandbox` refuses without a valid session cookie (`session_required`, 401) or with a
  bad CSRF check (`csrf_failed`, 403). This is the only place that decides who may get a sandbox, and therefore who may
  run code.
- **Pages**: `/tutorial` (the list of lessons) and `/tutorial/<lesson>` are public and show the lesson text to
  everyone, as the CEO ruled (Q-T1). The page calls `GET /api/v2/auth/web/session`.
  - Signed in, it shows the editor, Run and Test, the login and "Sign out".
  - Signed out, it shows "Sign in with GitHub to run this lesson" where the editor would be, linking to
    `/api/v2/auth/web/start?return_to=/tutorial/<lesson>`.
- **Scripts**: the sandbox route accepts no bearer token, so the CLI's session cannot drive it. A signed-in user can
  copy their own cookie into a script and ask for sandboxes. The rulings set no limit on that; section 4 says what it
  gives them and what it costs.

## 4. The sandbox on E2B

**Creating it**, inside `tutorial-sandbox`, after the gate. The function sends E2B's documented create call,
`POST https://api.e2b.app/v2/sandboxes`, authenticated by `X-API-Key` (E2B, "Create sandbox (v2)"), with this body:

```json
{
  "templateID": "<the stage's tutorial template>",
  "timeout": 1800,
  "allow_internet_access": false,
  "autoPause": false,
  "network": { "allowPublicTraffic": false },
  "metadata": { "mopm_stage": "<stage>", "mopm_request": "<our request id>" }
}
```

- `allow_internet_access: false` turns the internet off, as the CEO ruled. E2B documents it as equivalent to setting `network.denyOut`
  to `['0.0.0.0/0']` (E2B, "Internet access" and "Create sandbox (v2)"). The only
  call that changes a running sandbox's network is the platform API's `PUT /sandboxes/{sandboxID}/network`, which needs
  the team key (e2b 2.64.0, `updateNetwork`). The browser's token cannot reach it.
- `network.allowPublicTraffic: false` means the sandbox's own URLs accept traffic only with its traffic access token
  (E2B, "Create sandbox (v2)"), which we never hand out. Without it, a program the user starts could serve pages to
  anyone at an `e2b.app` address. Under this setting E2B's in-sandbox agent stays reachable with the access token
  alone, while a user port without the traffic token gets 403 (measured, section 4.1), so the field stays.
- `timeout: 1800` and `autoPause: false`: E2B ends the sandbox 30 minutes after creation, and kills rather than pauses
  it (E2B, "Create sandbox (v2)": `timeout` is in seconds, default 300; `autoPause` defaults to false). **This is
  cleanup, not a limit.** Its only job is to end a sandbox whose tab was closed: the browser cannot extend or kill a
  sandbox, because both calls need the team key. A user who is still working gets a new sandbox from the same route,
  as often as they like. The editor holds their files and the page writes them again before each run, so a new sandbox
  loses nothing but the previous process's state. 30 minutes sits inside E2B's longest run of 1 hour on the Hobby plan
  and 24 hours on Pro (E2B, "Sandbox lifecycle"). The value is a stage setting.
- `metadata` holds our stage and request id, and no GitHub id, login or address.
- E2B answers `sandboxID`, `envdAccessToken`, `envdVersion` and `domain` (E2B, "Create sandbox (v2)"). The function
  returns them as section "The endpoint" says. A null `domain` becomes the stage's E2B domain setting (`e2b.app`).
  `expires_at` is the time the function sent the request plus the timeout, so it is never later than E2B's own end.
- An answer without `envdAccessToken` is refused (`tutorial_unavailable`, logged). E2B says every sandbox is created
  with secure access from SDK 2.0.0 on, and that "passing `secure: false` does not disable secure access" from 2.51.0
  (E2B, "Secured access"). A missing token would mean a template whose agent predates secure access, and anyone who
  knew its id could control that sandbox.
- E2B refuses (its concurrency limit for our plan, an outage) or does not answer in 8 s: 503 `tutorial_unavailable`.
  The function's timeout is 10 s. The beta team's limit is 10 sandboxes at once (E2B's 429 names it), and a create
  took 150 to 684 ms, median 226 ms, over 25 creates (measured, section 4.1), far inside the 8 s.

**The per-sandbox token keeps the team key off the browser.** E2B issues it at creation. Every call to the sandbox's
agent carries it as `X-Access-Token`, and E2B's agent API accepts that token as its credential (E2B, "Secured access";
the envd API reference). What it opens:

| with the sandbox's access token (the browser holds it) | needs the team API key (our function only) |
|---|---|
| this sandbox's files: read, write, list | creating any sandbox, with any network setting |
| running commands and terminals in this sandbox, with their output | changing a sandbox's network (`PUT /sandboxes/{id}/network`) |
| nothing in any other sandbox | extending, pausing, resuming or killing a sandbox; listing the team's sandboxes |
| | connecting to a sandbox by id (`POST /v2/sandboxes/{id}/connect`, E2B, "Connect to sandbox") |
| | building and deleting templates |

The token dies with its sandbox. If it leaks, for example through a flaw in the page, the holder controls that one
sandbox, with the internet off, until its `expires_at`. The internet stays off for code running as root inside the
sandbox, also after root flushes the firewall and rewrites the route and resolver. No application data came back from
any address tried (`1.1.1.1`, `8.8.8.8`, `example.com`), and a canary server outside logged no request (measured,
section 4.1). A TCP connect from inside appears to succeed to any address, because E2B's side of the sandbox completes
every handshake, so the page and the template must not take a connect as a sign of network access.

**What E2B lacks, and the closest option.** E2B has the per-sandbox token the CEO's ruling asks for. What it does not
have is a *documented* SDK call that starts from the token alone:

- The documented `Sandbox.create` and `Sandbox.connect` both call E2B's platform API with the team key (E2B, "Connect to
  sandbox").
- The `Sandbox` class constructor takes `{sandboxId, sandboxDomain, envdVersion, envdAccessToken}` and builds a client
  that talks only to the sandbox's agent. It sends the token as `X-Access-Token` and needs no API key. In e2b 2.64.0
  it is exported and typed public, but its comment marks it `@internal` and says to use `Sandbox.create` instead.

So:

1. The page uses the constructor, as the snippet does, with `e2b` pinned exactly. tu-S2's type check of that call
   makes an upgrade that changes it fail the site build, not prod.
2. If E2B removes or changes it, the page talks to the agent's documented API directly with the same token (the envd
   API reference). The response of our endpoint does not change.
3. E2B has not confirmed that the constructor, or a token-only `connect`, is supported (section 4.1); the beta run
   shows it working with `e2b` 2.64.0. The fallback of point 2 stays the plan if an upgrade breaks it.

**The key**: `mopm/<stage>/e2b`, a Secrets Manager secret holding `{api_key}`, written by a held operator script (tu-O2) like
the OAuth secret's.

- Its resource policy has one explicit `Deny` of `secretsmanager:GetSecretValue`, with the condition
  `ArnNotEquals aws:PrincipalArn` the `tutorial-sandbox` role. It uses that condition rather than `NotPrincipal`, which
  misreads assumed-role sessions. So no other function, and no deploy or e2e role, can read the secret, whatever its
  own policy says.
- Writing the value (`PutSecretValue`, the held script) and CloudFormation's management of the secret are not denied.
- The function reads the secret at cold start and keeps it in memory. It never logs it and never returns it.

**What E2B sees**: everything the user types and runs, and the output. Because the browser now talks to E2B directly,
E2B also sees the user's IP address and browser, as any site the browser connects to does. It sees no GitHub id or
login from us. The page says so beside Run: "Your code runs on E2B's servers, which see your IP address. mopm.dev
does not see or store your code." The "What mopm.dev stores" page of tu-S3 says the same.

**The template**: lessons are `tutorial/lessons/<id>/project/` in this repository. The stage's template is built from
them and the pinned mopm release, so mopm, the Mojo toolchain and every lesson's synced project are already inside, and
a run downloads nothing. Nothing can be downloaded anyway with the internet off. The Mojo 1.0.0 closure for `linux-64`
is about 229 MiB compressed (`src/core/toolchain/mojo-1.0.0-linux-64.json`). The template definition follows E2B's
template format (E2B, "Template quickstart"). Building it needs the team key, so it is an operator step (tu-O2) that
writes the resulting template id into the stage settings.

**No limits.** As ruled, this note adds none. E2B's own plan limits, such as its concurrency limit for our team,
still apply, and E2B refusing a sandbox is `tutorial_unavailable`. The beta team's plan allows 10 sandboxes at once
(section 4.1), so on that plan the eleventh concurrent tutorial user gets `tutorial_unavailable`; the plan prod uses is a
follow-up (section 4.1).

### 4.1 What the check found (tu-X1)

The checks ran against the beta E2B team with its key. They used E2B's `base` template, `e2b` 2.64.0 (the latest on
npm when checked) and envd 0.10.2 as E2B reported it. The client was Node 20.19.4 and headless Google Chrome
158.0.8127.36. Every sandbox had section 4's create body with `timeout` 300 instead of 1800 and was killed after use.
The team's list of running sandboxes was empty afterwards. Each row says whether its result was measured or is inferred,
and how.

| Claim | Result | How |
|---|---|---|
| The SDK bundles for the browser with esbuild | **Measured: not as is.** `esbuild` 0.24.0 with `--bundle --format=esm --platform=browser` stops with 6 errors. `e2b` 2.64.0's `dist/index.mjs` imports `node:fs`, `node:stream`, `node:crypto`, `node:os`, `node:path` and `node:url` at the top, and only its template builder uses them. Aliasing the six to an empty module builds with no warning. tu-S2 does that (section 7). | `esbuild entry.js --bundle --format=esm --platform=browser` exits 1. The same with `--alias:node:<module>=./stub.js` for each of the six exits 0. |
| Bundle size | **Measured:** 306,542 bytes minified and 93,316 bytes after `gzip -9`, for an entry that calls the constructor, `files.write` and `commands.run`. tu-S2 still sets the budget. | `--minify`, then `gzip -9 -c \| wc -c`. |
| The bundled constructor works from a page under the site's CSP | **Measured: yes.** The page was served from a loopback origin, the same kind of origin the preview server uses, with `default-src 'none'; script-src 'self'; require-trusted-types-for 'script'; connect-src 'self' https://*.e2b.app`. It got section 4's grant from a local route that held the key. It built the client from `{sandboxId, sandboxDomain, envdVersion, envdAccessToken}`, ran `echo` (exit 0, output read back), and wrote and read back a file in a live sandbox, with no CSP violation. A control page with `connect-src 'self'` recorded 4 `connect-src` violations, which shows the page does see violations. The bundle contains no `eval`, `new Function`, string timer, HTML sink or script-URL sink. | The page's `securitypolicyviolation` listener and its report, from both pages; `grep` of the bundle. |
| It works from the site's own origin | **Measured, by the agent's CORS answer:** E2B's agent answered a preflight from `Origin: https://mopm.dev` with 204 and `Access-Control-Allow-Origin: *`. It allowed exactly the headers the SDK sends (`authorization`, `connect-protocol-version`, `connect-timeout-ms`, `content-type`, `e2b-sandbox-id`, `e2b-sandbox-port`, `keepalive-ping-interval`, `x-access-token`). So the origin does not change the row above. The tutorial page itself does not exist yet (tu-S2), so its own run in the browser is that task's. | `OPTIONS` to the agent's `process.Process/Start` and `files` routes, and `GET /health`, each with that `Origin`. |
| The browser client talks only to the sandbox | **Measured:** in a browser the client's agent URL is `https://49983-<sandboxID>.e2b.app`, inside `connect-src`. It builds no platform-API client and sends no API key. Under Node the same SDK uses `https://sandbox.e2b.app` instead. | The page's report (`envdApiUrl`); the SDK's `getSandboxUrl`. |
| The agent works with the access token alone under `allowPublicTraffic: false` | **Measured: yes.** The sandbox was created with section 4's body. A Node client was given only the access token, with `E2B_API_KEY` removed from its environment. It ran `echo` (exit 0) and wrote and read back a file. In the same sandbox, a user port (8000) without the traffic token answered 403. In a control sandbox with the setting `true`, the same port answered 200. The field stays. | That run's report. |
| No internet for root inside the sandbox | **Measured: none.** Root inspected and flushed `iptables` (it held no rules) and `nft`, re-added the default route, and pointed `/etc/resolv.conf` at `1.1.1.1`. The checks ran both before and after these changes. None of these reached anything: an HTTP request to `1.1.1.1:80`, HTTPS to `https://1.1.1.1/`, a DNS query to `8.8.8.8` over UDP, a DNS lookup of `example.com`, and a request to a canary web server we ran in a second sandbox that had the internet on. They got 0 bytes, an aborted TLS handshake, a timeout, a timeout, and no request in the canary's log. In an internet-on control sandbox the same requests got an HTTP 301, an HTTPS answer (301), a 61-byte DNS answer, an answer for `example.com` and a request logged by the canary. A request from outside the sandboxes also reached the canary. **Note:** a TCP connect from inside appears to succeed to any address and port. That includes `192.0.2.1`, a documentation address nothing answers, and a closed port of `1.1.1.1`, with the internet on or off. E2B's side of the sandbox completes every handshake, so a connect is not evidence of egress. The first pass counted such connects as reaching the internet, and the follow-up above shows they do not. **Inferred:** the rule is enforced outside the guest, since nothing root changes inside it lets traffic out. | Two runs, the second with the canary and the controls. |
| Create time | **Measured:** min 150 ms, median 226 ms, max 684 ms over 25 sequential creates. Each was timed at the client, a workstation reaching E2B over the public internet (not the Lambda's network), from sending `POST /v2/sandboxes` to receiving its 201. Each sandbox was killed before the next create, and creates were 1.1 s apart. | That run's report; all 25 times are in the run's output. |
| Concurrency limit of our plan | **Measured: 10.** Creating sandboxes one every 1.1 s, the eleventh was refused with 429: "you have reached the maximum number of concurrent E2B sandboxes (10)". That matches E2B's Hobby plan (10 at once, 1 create per second; Pro is 100 at once, up to 1,100 with add-ons, 5 per second, E2B, "Billing"), so the beta team is on Hobby (inferred from the number). | That run's report. |
| The constructor's status, and a supported token-only `connect` | **Measured:** in `e2b` 2.64.0 the constructor's comment is "Use Sandbox.create to create a new Sandbox instead", with `@hidden @hide @internal @access protected`. E2B's docs show no token-only connect. E2B has not been asked and has not confirmed either as supported; the CSP row shows the constructor working with 2.64.0. | `dist/index.d.ts`; `https://registry.npmjs.org/e2b/latest`; E2B, "Connect to sandbox". |

Follow-ups, none of which changes code here:

- The prod E2B team's plan. On the beta team's plan, an eleventh tutorial user at the same moment gets
  `tutorial_unavailable`. Pro gives 100 at once. Choosing it is a product and spend decision for the CEO, and the
  rulings add no limits of our own.
- tu-S2 aliases the six `node:*` imports when it bundles the SDK (section 7).
- tu-S2's page and the template (tu-X2) never treat a successful TCP connect inside the sandbox as network access.

## 5. The functions: the first Rust Lambdas

The new functions are Rust, each its own Lambda (custom runtime `provided.al2023`, x86_64, packed by `lambda_zip`),
routed by the existing HTTP API next to the TypeScript integrations:

| function | routes | can touch |
|---|---|---|
| `web-login` | `GET /api/v2/auth/web/start`, `GET /api/v2/auth/web/callback` | `client_secret` of `mopm/<stage>/github-oauth`; `web_logins`; `users` and `namespaces` (upsert, as the device login does); `tokens` (put, revoke); HTTPS to GitHub |
| `web-session` | `GET /api/v2/auth/web/session`, `POST /api/v2/auth/web/logout` | `tokens` (get, touch, revoke); `users` (get) |
| `tutorial-sandbox` | `POST /api/v2/tutorial/sandbox` | `tokens` (get, touch); `users` (get); `mopm/<stage>/e2b`; HTTPS to `api.e2b.app` |

Each role grants exactly that, and the fake DynamoDB of `mopm_testing` enforces the grants in tests, as it does for the
auth grants today. The TypeScript functions keep every route they have and read and write the same `tokens`, `users`
and `namespaces` rows. `mopm_aws`'s adapters already write the TypeScript adapters' rows, and their tests hold the
shapes equal, so the two languages share the tables safely. When the rest of the port comes, these functions are
already done, and nothing here is rewritten.

What the Rust tree gains, each in the crate where its kind already lives:

- `mopm_core`: token minting and hashing (`mopm_` + base32, SHA-256, the prefix), ported from `tokens.ts` and held to
  its outputs; the CSRF derivation; the `return_to` grammar; the new error codes in the catalogue.
- `mopm_ports`: `HttpClient` (one request, one response, bytes and headers); `NamespaceStore` (the user namespace at
  login); `WebLoginStore`.
- `mopm_aws`: the DynamoDB adapters of `web_logins` and of namespaces; an `HttpClient` on `hyper` and `rustls` with the
  workspace's AWS-LC, so every outbound TLS connection uses the pinned stack.
- `mopm_testing`: memory stores, plus a fake GitHub and a fake E2B API, both scripted servers on loopback like
  `fake_http`.
- `service/lambda/web` (`mopm_web`): cookies, the session authenticator over `AuthStore`, the edge-header and CSRF
  checks, responses with `Set-Cookie` and redirects, the error envelope.
- `service/lambda/e2b` (`mopm_e2b`): the create request of section 4 and its answer, over `HttpClient`. It is a
  library, not a port: E2B is the one provider, and its tests run against the fake E2B API.
- `service/lambda/fn_web_login`, `fn_web_session`, `fn_tutorial_sandbox`: the three binaries, each a `main.rs` that only
  wires its library to `lambda_runtime`.

**Stage settings** are one item, `stage_settings`, in the stage's existing `config` table, written by the stack at
deploy and read by each function at cold start. It holds the redirect URI, the site origin, the two-factor rule, the
E2B template id, the E2B domain and the sandbox timeout. The only environment variable a function reads is Lambda's
own `AWS_LAMBDA_FUNCTION_NAME` (`mopm-<stage>-<function>`), a platform-set marker that names the stage and so the
tables (S2). The TypeScript functions keep their environment variables; moving them is not this note's work.

New third-party crates (`hyper`, `hyper-util`, `hyper-rustls`, `http-body-util`) come from crates.io under MIT or
Apache-2.0 and land with `buildrules sync`'s outputs (R11).

**Deploying them**: `promote.yml` gains one job before the beta deploy. It builds the three zips on the farm with their
named targets and hands them to every stage's deploy as one artifact. Each deploy compares the function's `CodeSha256`
with the zip's sums file, so beta, gamma and prod run the same bytes. This is the deploy pipeline, not a PR check (B9).

## 6. What is stored

| where | what | how long |
|---|---|---|
| `users` (existing) | GitHub numeric id, login as `handle`, `created_at`, `last_login_at`, the two-factor flag. Nothing new. | as today |
| `namespaces` (existing) | the user namespace, created at the first sign-in, as the CLI's login does | as today |
| `tokens` (existing) | the session: SHA-256 of the token, prefix, `kind: session`, name `web login`, GitHub id, `created_at`, `fresh_until`, `expires_at`, `last_used_at`, `revoked_at` | TTL at 7 days |
| `web_logins` (new) | the login transaction: SHA-256 of its id, SHA-256 of `state`, the PKCE verifier, `return_to`, `consumed_at` | TTL at 10 minutes |
| logs (existing retention, one month) | one line per sandbox created: request id, GitHub id, E2B sandbox id, outcome. Never the access token. | one month |
| E2B | the user's files, commands and output, for the sandbox's life; the user's IP address on each call; whatever E2B's own logs keep | E2B's terms |
| the browser | the cookie; edited files and the last lesson opened in `localStorage` under `mopm.tutorial.1`; the sandbox grant in memory only | until cleared; the grant until the page closes |

Our service never sees the user's code or output, because the browser sends them to E2B. It never stores the GitHub
token, the email address or the IP address: the API has no access log and the functions do not read the source
address. The site distribution's standard logs stay off.

## 7. The tutorial pages

- **Page and routes**: a new shell page `tutorial.html`, PageKind `tutorial`, and an area stylesheet `tutorial.css`
  within the 16 KiB area budget. Routes `/tutorial` and `/tutorial/<lesson>` (`^[a-z0-9]+(-[a-z0-9]+)*$`) go into
  `site/src/routes.ts`, and from there into the edge router.
- **Lesson text** is prerendered from `tutorial/lessons/<id>/lesson.md` by the site's restricted Markdown renderer, so
  it works without scripts and without a session.
  - The site build checks every lesson against the schema and its rules first (`site/tools/lessons.ts`), and fails on
    a bad one. It then writes `/tutorial` (the lessons in order) and `/tutorial/<lesson>` (the text under the title,
    the lesson's place and the runner's mount point) as `tutorial/index.html` and `tutorial/<lesson>/index.html`.
  - Until tu-S3 they are written to `site/build/held/`, not `dist/`. The edge router serves every file of `dist/` as
    it is, so pages in `dist/` would be reachable before their routes exist. tu-S3 writes them to `dist/`.
- **The E2B SDK** is the site's first runtime dependency. `site/README.md` rule 1 gains one written exception: `e2b`,
  pinned exactly, on the tutorial pages only.
  - A pinned `esbuild` dev dependency bundles `site/src/tutorial/main.ts` with it into one hashed asset, which only
    `tutorial.html` loads.
  - Every other page stays as it is: `tsc` output, no bundle, and `check-dist.ts` still checks the whole tree.
  - `e2b` 2.64.0 imports six `node:*` modules at the top of its bundle, so esbuild with `--platform=browser` fails
    until tu-S2 aliases them to an empty module; they are used only by the SDK's template builder (section 4.1).
  - The bundle is about 300 KB minified, 93 KB gzipped, for the constructor, `files.write` and `commands.run`
    (measured, section 4.1); tu-S2 sets its budget. It runs under `require-trusted-types-for 'script'` and
    `script-src 'self'` with no violation (measured in Chrome, section 4.1).
  - If an `e2b` upgrade breaks it, the fallback of section 4, point 2, applies: a small client of the agent's API in `src/tutorial/`,
    with no dependency.
- **The editor** is a `<textarea>` per editable file, with no editor library. Output is text nodes in a `<pre>`, and
  control, bidi and invisible characters show as markers, as appendix C.2's copied-example rule does.
- **A `TutorialGate` port** (`site/src/tutorial/gate.ts`, over the site's session client `site/src/session.ts`) has four members:
  - `session()` returns `{signed_in: true, login, csrf, expires_at}` or `{signed_in: false}`;
  - `sandbox()` returns the grant of "The endpoint" or an error code;
  - `signInHref(returnTo)` returns a `SafeHref`;
  - `signOut()`.

  The real one calls the routes with `credentials: 'same-origin'`; tests use a fake that replays the contract
  examples. A `LessonRunner` over the SDK (`site/src/tutorial/runner.ts`) writes the files and runs `mopm run` or
  `mopm test` in the lesson's directory. It holds one sandbox per page, asks for a new one when `expires_at` is less
  than a minute away, or when the SDK raises `SandboxNotRunningError` or `SandboxUnreachableError`. Tests replace it
with a fake.
- **Lessons** are `tutorial/lessons/<id>/`: `lesson.md`, `lesson.json` (title, summary, order, editable files, actions)
  and `project/` (a mopm project with `mopm.toml` and `mopm.lock`). The site build reads the first two and the template
  build takes `project/`. One schema, `spec/tutorial-lesson.schema.json`, is the contract between them.
- **The header** gains "Tutorial". It also carries the sign-in on every page: "Sign in with
  GitHub" (the start route, `return_to` the page's own path), and, once the session route says who is signed in, the
  login and "Sign out" (`site/src/account.ts`). The link is in the prerendered page; the signed-in state is filled in by
  the page script, so the cached pages are the same for everyone. Every page therefore makes the one session call. The
  session, the sign-in link and sign-out are `site/src/session.ts`, which the tutorial's gate builds on; the gate, with
  the sandbox route, stays out of the pages that are not the tutorial's.

## 8. Implementation tasks and order

S is under 200 lines, M under 600, L more. Task ids are prefixed `tu-` so they read apart from rule ids. Each names the
behaviour its tests assert. Every test is hermetic: fakes for GitHub, E2B, the stores and the clock, and a loopback
listener on port 0 where an HTTP server is needed.

Contract first, so the tutorial can be built against it:

- **tu-P1 (M) The wire contract.**
  - In `spec/api/mopm/registry/v2/*.proto`: the rpcs `StartWebLogin`, `CompleteWebLogin`, `GetWebSession`, `WebLogout`
    and `CreateTutorialSandbox`, and the error codes `session_required`, `csrf_failed`, `tutorial_unavailable`.
  - `spec/api/openapi-v2.yaml` and the generated outputs of `tools/api_gen.zig`.
  - Contract examples `tests/contract/api-v2/web-auth.json` and `tutorial-sandbox.json`: signed in, signed out, the
    grant, each error.
  - `spec/tutorial-lesson.schema.json`. All of it additive only.
  - Tests: the generator's check that checked-in outputs equal its output; the schema accepts the example lesson and
    refuses an editable path outside `project/`, a missing action and an id out of grammar.
- **tu-S1 (M) The stub**: `site/src/tutorial/gate.ts` (over the site's session client, now `site/src/session.ts`) with the real client and the replaying fake, and
  `site/tools/preview.ts` with an npm script `preview`.
  - The preview serves `dist/` on 127.0.0.1 (port 0, printed) with the site's headers and answers our routes per the
    `--scenario` flag, as "Running it locally" says; `--e2b-template` names the template it creates sandboxes from.
  - With `E2B_API_KEY` in its environment, it sends section 4's create body to E2B through an injected `fetch`.
  - `site/src/host.ts` maps `127.0.0.1` and `localhost` to the relative API base.
  - Nothing of it reaches a deployed stage.
  - Tests: the client decodes every contract example and maps every error code; the preview answers each scenario;
    its sandbox route checks CSRF, `Origin`, `Sec-Fetch-Site` and the empty body as the real route does; the create
    body it sends a fake E2B equals section 4's, with `allow_internet_access` false; without a key it never calls
    E2B; an unknown host still gets no API.
- **tu-S2 (L) The tutorial pages and the first lessons** (section 7), against tu-S1 only. They are not routed by the
  edge router, so nothing shows on any stage. Also: the `esbuild` bundle and the README rule-1 exception.
  - Tests through the fake gate and the fake runner:
    - signed out shows the lesson and the sign-in link with the right `return_to`, and no editor;
    - signed in shows the editor and the login;
    - each error code renders its message, and `session_required` keeps the edited code;
    - a `SandboxNotRunningError` or `SandboxUnreachableError` replaces the sandbox once and repeats the run, and a
      grant near `expires_at` is replaced before a run;
    - a non-zero exit shows its code;
    - control and bidi characters show as markers;
    - the draft survives a reload through `localStorage`, the page works when `localStorage` throws, and the grant
      is never written there;
    - the SDK call type-checks against the pinned `e2b`;
    - every lesson in `tutorial/` validates against the schema, and its editable files exist.

The Rust foundation:

- **tu-F1 (M)** `mopm_core`: token minting and hashing, the CSRF derivation, the `return_to` grammar and the new error
  codes. `mopm_ports`: `HttpClient`, `NamespaceStore`, `WebLoginStore`. `mopm_testing`: memory stores, a fake GitHub, a
  fake E2B API, and the contract cases of each new port.
  - Tests: tokens equal `tokens.ts`'s for the same random bytes (format, hash, prefix), and the TypeScript
    authenticator accepts a row the Rust wrote; every `return_to` case of appendix C.1, with section 1's `/tutorial`
    fallback; the memory stores pass their port contracts.
- **tu-F2 (M)** `mopm_aws`: the DynamoDB adapters of `web_logins` and of namespaces, and the `hyper`/`rustls`
  `HttpClient`, with the new crates and `buildrules sync`'s outputs.
  - Tests: the same port contracts against the fake DynamoDB, with the rows asserted as DynamoDB JSON and the
    namespace row equal to the TypeScript adapter's; nothing calls `DeleteItem`; the client against `fake_http` over
    TLS with a test certificate, and a refused certificate.
- **tu-F3 (S)** `promote.yml` builds the function zips once per commit, and every deploy checks `CodeSha256` against
  the sums.
  - Tests: the workflow lint's fixtures for the new job (the chain and the called files, as `//:workflows` checks
    them), and a fixture whose deploy skips the check fails.

Sign-in:

- **tu-A1 (M)** `mopm_web` and `fn_web_session`: cookies (one exact name, two refused), the edge-header check, the
  session authenticator, CSRF, `GET /api/v2/auth/web/session` and `POST /api/v2/auth/web/logout`. Infra: the function,
  its routes and grants.
  - Tests against the memory and fake DynamoDB stores:
    - a valid cookie answers the session;
    - expired, revoked, unknown and duplicated cookies, and a missing edge header, are 401;
    - a bad `Origin`, `Sec-Fetch-Site`, content type or CSRF value is 403;
    - an `Authorization` header is refused;
    - logout revokes only its own session and clears the cookie;
    - the role's grants are exactly the table of section 5.
- **tu-A2 (M)** `fn_web_login`: start and callback, the `web_logins` table, and `client_secret` read in this function
  only.
  - Tests against the fake GitHub:
    - a full sign-in sets the cookie and redirects to `return_to`;
    - the login cookie and the session cookie carry exactly the attributes of sections 1 and 2 (`SameSite=Lax` on
      both);
    - a request without the edge header, or with a wrong one, is refused on start and callback;
    - a replayed callback, a wrong `state`, an expired row, a missing login cookie, a cross-site start (each
      `Sec-Fetch-*` case) and every bad `return_to` are refused or fall back as section 1 says;
    - two-factor off is `two_factor_required` and stores nothing;
    - `access_denied` and a GitHub outage map to their codes;
    - the GitHub token is not stored;
    - signing in revokes the previous session;
    - the session's `fresh_until` equals its creation time;
    - the user and namespace rows equal those the TypeScript device login writes for the same GitHub user.
- **tu-I1 (M)** The site distribution's `/api/*` behaviour as section 2.1 says, the `edge-origin` secret, the 404
  handling, the relative `apiBase()`, and `connect-src 'self' https://*.<E2B domain>`.
  - Tests in the stack and site-router tests:
    - the behaviour, its policies, the origin header and the 30 s origin read timeout exist with those values;
    - existing pages and their headers are unchanged apart from `connect-src`;
    - `/api/v2/...` is routed to the API origin, and a JSON 404 stays JSON;
    - an unknown page still gets the 404 page;
    - the page CSP's `connect-src` is exactly those two sources.

The sandbox:

- **tu-X1 (S, with the tutorial's author)** Done: a check on beta with a beta E2B key, recorded in section 4.1; no code
  is merged. It settled:
  - the bundled SDK and the constructor work under the site's CSP, and E2B's agent allows any origin;
  - the agent works with `allowPublicTraffic: false`;
  - with `allow_internet_access: false`, a program run as root in the sandbox gets nothing back from the internet;
  - E2B's create time, and the beta team's concurrency limit (10);
  - whether E2B supports a token-only `connect`: not asked, and still open.
- **tu-X2 (M)** The E2B template definition, built from `tutorial/lessons/*/project` and the pinned mopm release, with
  its build documented as an operator step.
  - Tests: every lesson project in the template definition matches `tutorial/lessons`, and the mopm version in it is
    the pinned one.
- **tu-A3 (M)** `mopm_e2b` and `fn_tutorial_sandbox`: the route of section 4, the `e2b` secret with its resource
  policy, the function's grants, and the held script that writes the secret.
  - Tests against the memory and fake DynamoDB stores and the fake E2B API with a fixed clock:
    - no session, a bad CSRF check, a body and an `Authorization` header are refused before any call to E2B;
    - the create body equals section 4's exactly, `allow_internet_access` false included;
    - the key is sent only in `X-API-Key` and appears in no log line or error, the log line asserted by exact
      equality;
    - the answer maps to the grant, with a null domain filled in and `expires_at` equal to the request time plus the
      timeout;
    - an answer without `envdAccessToken`, an E2B error and no answer in 8 s are each `tutorial_unavailable`;
    - the stack test shows the secret's policy has section 4's `Deny`, with this function's role as the only
      exception;
    - a policy without that `Deny` fails the test;
    - neither other new function's role has any grant on the secret.

Operator:

- **tu-O1 (operator)** On each stage, before tu-A2 deploys; needs the owner's hands:
  - set the OAuth app's callback URL;
  - check that the secret holds a current `client_secret` with the read-only comparison of
    `service/infra/access/BOOTSTRAP.md` ("GitHub OAuth app", step 3a), and store a new one with the held `oauth-secret`
    script when it is absent or stale.
- **tu-O2 (operator)** On each stage, after tu-X2 and before tu-A3 deploys; needs the owner's hands:
  - write `mopm/<stage>/e2b` with the held script of tu-A3;
  - build the E2B template of tu-X2 and set its id in the stage settings.

Go-live:

- **tu-S3 (S)** The edge router routes `/tutorial` and `/tutorial/<lesson>`, and the build writes the tutorial's held
  pages to `dist/` (section 7); the header gets its "Tutorial" link; the
  docs page "What mopm.dev stores", from section 6, names E2B and what it sees. This is the step users see.
  - Tests: the route fixtures (`site/test/fixtures/routes.json`) and the site-router test; the layout test for the
    header.

**Order**:

- tu-P1 first. tu-S1 follows tu-P1, and tu-S2 follows tu-S1, in parallel with everything below.
- tu-F1, tu-I1 and tu-X1 start at once. tu-F2 follows tu-F1, and tu-F3 follows tu-F2.
- tu-O1 can be done at any time. tu-A1 follows tu-F2 and tu-F3. tu-A2 follows tu-A1 and deploys after tu-O1.
- tu-X2 follows tu-X1, and tu-O2 follows tu-X2. tu-A3 follows tu-A1 and tu-F2, and deploys after tu-O2.
- tu-S3 follows tu-S2, once tu-A2, tu-A3 and tu-I1 are deployed to prod.
- Deploys stay automatic from main.

Until tu-S3, nobody sees the tutorial: its routes answer only requests that carry the distribution's header, and no
page links to them. The sign-in is the exception: the header links it on every page (section 7, "The header"). A
refused sign-in lands on `/tutorial?error=<code>`, which is the 404 page until tu-S3; the header's script shows what
the code means above it.

tu-I1 is the exception. Once deployed, it changes what every visitor gets: every API read of the site goes through
the site host, and the CSP's `connect-src` and the 404 handling change. It is the one change before tu-S3 that users
can notice if it is wrong. Its stack and site-router tests hold the existing pages, a missing page and the site's reads
to what they are today. Reverting it is one revert, since nothing else depends on it until tu-A1's routes are used.

## Decisions

1. GitHub is the only identity provider: the account model is already GitHub's numeric id.
2. The web login is mopm-dev.md's design; only the paths move to `/api/v2`, which the site now reads.
3. The tutorial needs only start, callback, session and sign-out. The session list, sign-out everywhere and the account
   page stay in mopm-dev.md, so the tutorial does not wait for them.
4. The session is an opaque token in the existing `tokens` table, not a signed cookie: one row format for both
   languages, revocation already works, and there is no key to rotate.
5. The session lasts 7 days absolute with no sliding renewal, as mopm-dev.md says; the CLI's 30 days is left alone.
6. The web session's `fresh_until` is its creation time, so a leaked cookie value cannot create an API token on the
   TypeScript routes.
7. A new route, `GET /api/v2/auth/web/session`, answers who is signed in, instead of making the TypeScript `GET /me`
   accept the cookie. The TypeScript side stays cookie-free and unchanged, and an API Gateway route has one integration.
8. There are three Rust functions, split by what each may touch, so only `web-login` reads the OAuth secret and only
   `tutorial-sandbox` reads the E2B key.
9. The browser talks to E2B directly. Our service creates the sandbox and hands over only that sandbox's token, so it
   never carries code or output, and the team key, which could create sandboxes with the network on, stays server-side.
10. The sandbox route takes the cookie only, not bearer tokens, so sandboxes are for the site.
11. There are no usage limits, as ruled. The sandbox timeout is cleanup, and the page replaces an ended sandbox without
    the user doing anything.
12. One sandbox per page, created when the page first needs it, not one per run: a run is then one call from the
    browser to E2B.
13. The browser uses E2B's SDK through its token-taking constructor, pinned exactly, with the agent's documented API as
    the fallback. Our endpoint's answer is the same for both.
14. `allowPublicTraffic: false`, so a user's program cannot serve the internet from an `e2b.app` address.
15. Draft code and progress stay in the browser's `localStorage`. Nothing about tutorial progress is stored by us.
16. The local preview server is the stub: the same site code against the same contract, and with a developer's own E2B
    key, the same create request.
17. Lessons live in `tutorial/` at the root, read by the site build and the template build, with one schema.
18. The function zips are built once per commit in the deploy pipeline and checked by sha256 at each stage, so the
    same bytes reach prod.

## Questions for the CEO

Answered:

- **Q-T1, the lesson text**: stays public; only getting a sandbox is gated.
- **Q-T2, language**: Rust, as new Lambdas behind the same API Gateway sharing the tables with the TypeScript functions;
  the first piece of the port, with no TypeScript version.
- **Q-T3, two-factor**: kept for web sign-in, as for the CLI.
- **Q-T4, limits**: none. No spend ceiling, no per-user in-flight cap, no per-day rows; only E2B's timeout as cleanup.
- **Where code runs**: E2B; the browser connects to the sandbox directly with a per-sandbox token from our service.
- **The sandbox's network**: off (`allow_internet_access: false`).
- **The API on the site host**: yes; tu-I1 adds the `/api/*` behaviour to the API Gateway origin.

Open:

- **Q-T5, the sandbox timeout**: 30 minutes, after which the page quietly gets a new sandbox. **Recommend: start
  there.** Shorter ends abandoned sandboxes sooner, and longer keeps a running program's state across a long pause.

## Sources

E2B's documentation, read for this revision:

- "Secured access", <https://docs.e2b.dev/sandbox/secured-access>: the access token returned at creation, the
  `X-Access-Token` header, secure access by default from SDK 2.0.0 and always from 2.51.0.
- "Internet access", <https://docs.e2b.dev/sandbox/internet-access>: `allowInternetAccess` /
  `allow_internet_access`, and `allowPublicTraffic` as a create-only option.
- "Sandbox lifecycle", <https://docs.e2b.dev/sandbox/lifecycle>: `setTimeout`, and the longest run per plan.
- "Connect to sandbox", <https://docs.e2b.dev/api-reference/sandboxes/connect-to-sandbox>: connecting by id needs
  `X-API-Key`, and returns the access token. The page marks this path deprecated in favour of
  `POST /v2/sandboxes/{id}/connect`, which the SDK calls; that one needs the key too.
- "Create sandbox (v2)", <https://docs.e2b.dev/api-reference/sandboxes/create-sandbox-v2>: `POST /v2/sandboxes`, its
  body (`templateID`, `timeout` in seconds with default 300, `autoPause` with default false, `allow_internet_access`, `network.allowPublicTraffic`,
  `metadata`) and its answer (`sandboxID`, `envdAccessToken`, `envdVersion`, `domain`, `trafficAccessToken`).
- The envd API reference, <https://docs.e2b.dev/api-reference/envd/environment-variables>: the sandbox agent's
  endpoints, authenticated by the sandbox access token in `X-Access-Token`.
- "Template quickstart", <https://docs.e2b.dev/template/quickstart>: defining and building a template.
- "Restrict public access", <https://docs.e2b.dev/network/restrict-public-access>: `allowPublicTraffic`, the
  `e2b-traffic-access-token` header and the 403 without it; silent on the agent's port 49983.
- "Billing", <https://docs.e2b.dev/billing>: concurrent sandboxes, creation rate and longest run per plan.

The `e2b` npm package, version 2.64.0 (MIT): the `Sandbox` constructor and its `@internal` comment, `updateNetwork`,
the agent client sending `X-Access-Token`, and the errors `CommandExitError`, `SandboxNotRunningError` and
`SandboxUnreachableError`.
