# fn_web_login

The website's sign-in function, `web-login` (`docs/design/tutorial-sign-in.md`, sections 1, 2, 2.1, 5 and 6): a Rust Lambda
(custom runtime `provided.al2023`) behind two routes of the HTTP API on the site host.

| route | what it does |
|---|---|
| `GET /api/v2/auth/web/start?return_to=` | for a top-level navigation only: stores a login transaction, sets `__Host-mopm_login`, sends the browser to GitHub (`302`) |
| `GET /api/v2/auth/web/callback?code&state` | takes the transaction once, exchanges the code, reads the GitHub account, makes the user, its user namespace and a session as the device login does, sets `__Host-mopm_session`, sends the browser back to the site (`303`) |

Any other path or method is `invalid_request` (400): `route_not_found` is in no table of the website's routes
(`WEB_CATALOGUE`), and a code outside that table would be answered as `internal_error`.

## What it decides

* **The edge check comes first**, on every route (`mopm_web::edge`): no request without the stage's `x-mopm-edge` value reads a
  store. The refusal is the `session_required` envelope (401) on both routes.
* **start**: exactly one each of `Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document` and `Sec-Fetch-Site: none` or
  `same-origin`, spelled so; anything else is `invalid_request` (400) and stores nothing. `return_to` is `validate_return_to`'s
  (fallback `/tutorial`, also when absent or sent twice). The transaction id, the `state` and the PKCE verifier are 32 random bytes
  each, base64url; the row is `{id: sha256(txn), state_hash: sha256(state), code_verifier, return_to, expires_at: now + 600 s}`.
  The authorize URL carries `client_id`, the stage settings' `redirect_uri` exactly (never built from `Host`, `Forwarded` or
  `X-Forwarded-*`), `scope=read:user`, `state`, the S256 `code_challenge` and `prompt=select_account`. A store that fails sends
  the browser to `/tutorial?error=unavailable` (`303`, no cookie): a navigation never gets JSON for a fault.
* **callback**: every answer but the edge refusal clears the login cookie. A failure is `303` to `<site_origin>/tutorial?error=<code>`,
  `Referrer-Policy: no-referrer`, no session; the code is `access_denied`, `two_factor_required`, `login_expired` or `unavailable`:
  * GitHub's `?error=access_denied` is `access_denied`, any other `?error=` is `unavailable`; no store is asked;
  * the login cookie (exactly one) and `code` and `state` (exactly one each) are needed, else `login_expired`;
  * the row is taken once (`consume`: a replay, an expired row and an unknown id are `login_expired`, a store fault is
    `unavailable`); `state`'s hash is compared with the row's in constant time, and a wrong one burns the row (`login_expired`);
  * the token exchange (`access_denied` is `access_denied`, `bad_verification_code` is `login_expired`, any other error, status,
    answer that is not the expected JSON, or no answer is `unavailable`), then `GET /user` (anything but a 200 with the account
    is `unavailable`); GitHub's token is used for that one request and dropped, never stored or logged;
  * the two-factor rule (the stage's `require_two_factor`): off is `two_factor_required` and nothing is stored;
  * `upsert_user`, then `ensure_user_namespace` (no namespace does not stop the login), as `auth/device-login.ts` does: the rows
    are held equal to the TypeScript ones by `tests/fixtures/device_login_rows.json`;
  * the session the browser held (exactly one `__Host-mopm_session` that is a token) is revoked, then the new one is stored:
    `kind: session`, name `web login`, `fresh_until` = `created_at`, seven days. A store that fails is `unavailable`.
  * success is `303` to `<site_origin>` + the row's `return_to`, `Set-Cookie` of the clearing login cookie and the session,
    `Referrer-Policy: no-referrer`, `Cache-Control: no-store`.

## The log

One line per request, JSON, `INFO`: `message` (`web login start`, `web login callback`, or `web login request` for any other
route), `request_id`, `outcome` (`redirected`, `signed_in`, or the refusal's code), and for a refusal `reason` (a fixed text naming
the check); a callback adds `github_id` once GitHub has said whose account it is. The client secret, the code, the verifier, the
`state`, the transaction id, GitHub's token, the session token and the edge value are in no line (the tests assert every line by
exact equality and look for each of those values in the whole log).

## Start

At cold start, once: the `stage_settings` item of `mopm-<stage>-config` (`redirect_uri`, `site_origin`, `require_two_factor`), the
secret `mopm/<stage>/edge-origin`, the secret `mopm/<stage>/github-oauth` (`{"client_id", "client_secret"}`; the id must match
`^[A-Za-z0-9._-]{4,100}$` as the TypeScript device flow requires, the secret must not be empty), and the system's root certificates
for HTTPS to GitHub. Anything missing or invalid fails the start by name, without the secret's content. The only environment
variable the function reads is `AWS_LAMBDA_FUNCTION_NAME` (`mopm-<stage>-<function>`); the AWS SDK reads its own (credentials,
region, endpoint).

## Layout

| file | what |
|---|---|
| `src/main.rs` | forwards to `run` |
| `src/runtime.rs` | the clock, the OS randomness, the config table over DynamoDB, `cold_start`, the log, `run` |
| `src/handler.rs` | API Gateway event in and out, the edge check, the route, the log line |
| `src/start.rs`, `src/callback.rs` | the two routes, over the ports (`login::WebLogin`) |
| `src/github.rs` | the authorize URL, the code exchange, `GET /user`, over `HttpClient` |
| `src/oauth.rs` | the OAuth app's secret |
| `src/outcome.rs` | the failure codes |
| `tests/process.rs`, `e2e_test.zig` | the executable against a fake Lambda runtime API, DynamoDB and Secrets Manager (Cargo, Buck2) |

## Tests

`cargo test -p fn_web_login` runs everything on loopback: a fake GitHub (`mopm_testing::fake_github`), a fake DynamoDB held to the
function role's grants (`tests/fixtures/role_grants.json`: a call the role lacks is a fault, so a sign-in that finishes needs
nothing more, and no `DeleteItem` is made), the memory secrets, and a fixed clock. `tests/process.rs` runs the built executable
(`CARGO_BIN_EXE_web_login`); it passes `LLVM_PROFILE_FILE` on to the child when a coverage run sets it, so that `run` and `main` count.

## Deploying

The stack creates the function only when its zip is given (`rustZipDir`); nothing creates it on a stage until the zips deploy
(the promote workflow's job). Its deploy needs the stage's `mopm/<stage>/github-oauth` to hold a current `client_secret` (the
operator step tu-O1): without one the cold start fails by name and the function never answers a request.
