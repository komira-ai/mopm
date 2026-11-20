# mopm_web

What the website's three functions share (`web-login`, `web-session`, `tutorial-sandbox`;
`docs/design/tutorial-sign-in.md`, sections 2, 2.1 and 5). It is a library: it routes nothing and deploys
nothing. Each function's binary wires these pieces to `lambda_runtime`.

| module | what | held by |
|---|---|---|
| `request`, `response` | `WebRequest {method, path, query, headers, cookies, body, request_id}` (header names without case; a header or query parameter sent twice has no single value) and `WebResponse {status, headers, set_cookies, body}`. Every response carries `x-mopm-request-id` and `Cache-Control: no-store` | unit tests |
| `apigw` | `from_apigw` / `to_apigw`: API Gateway's HTTP API event (payload 2.0). Cookies come from the event's `cookies` array and any `cookie` header; a base64 body is decoded | event round trips: a `GET` with two cookies and a query, a `POST` with a body, a base64 body |
| `cookie` | `__Host-mopm_session` (`Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=604800`), `__Host-mopm_login` (`...; Max-Age=600`) and their clearing forms (`Max-Age=0`); no `Domain`. Read by exact name; two of one name are refused | the exact `Set-Cookie` strings |
| `edge` | `EdgeCheck`: `x-mopm-edge` equal to the secret `mopm/<stage>/edge-origin`, read once at cold start, compared in constant time | unit tests |
| `csrf` | `CsrfCheck`: the exact site `Origin`, `Sec-Fetch-Site: same-origin`, `Content-Type: application/json` when there is a body, `X-Mopm-CSRF` equal to `mopm_core::csrf::csrf_value` | one test per check |
| `session` | `SessionAuth`: the order below | the memory auth store, recorded, and a fixed clock |
| `envelope` | `session_required`, `csrf_failed`, `invalid_request` for `Authorization`, `tutorial_unavailable` with `Retry-After`; `error_response` renders `{"error": {"code", "message", "hint"}}` from `mopm_core`'s `WEB_CATALOGUE` | every error of `tests/contract/api-v2/web-auth.json` and `tutorial-sandbox.json`, byte for byte |
| `settings` | the stage from `AWS_LAMBDA_FUNCTION_NAME` (`mopm-<stage>-<function>`, the one environment variable read); `StageSettings` from the `config` table's `stage_settings` item, through the `ConfigTable` trait | unit tests, malformed names and items |

## The order of the checks

`SessionAuth::session` (a `GET`) and `SessionAuth::session_for_post` answer the first refusal of:

1. `x-mopm-edge` is the stage's value: `session_required` (401) otherwise.
2. No `Authorization` header: `invalid_request` (400) otherwise.
3. Exactly one `__Host-mopm_session`, in the token grammar: `session_required` otherwise.
4. A `POST` only: the CSRF checks, in the order above: `csrf_failed` (403).
5. The `tokens` row by the token's SHA-256: present, `kind: session`, not revoked, not expired (`expires_at` after
   now), and its account in `users`: `session_required` otherwise.
6. `last_used_at` is written when it is absent or a minute old (the TypeScript `Authenticator`'s rule).

Steps 1 to 4 read no store. A store that fails is `internal_error` (500).

**Why the edge refusal is `session_required`.** The design's tests for this crate say "a missing edge header [is]
401", and `session_required` is the website's one 401 code (`spec/api/openapi-v2.yaml`). It is also true: a request that
did not come through the site's distribution cannot carry the session, because the `__Host-` cookie is never sent to
`api.<site>`. The answer says nothing about the header. The same code is used on all five routes, start and callback
included.

## The `stage_settings` item

```json
{ "key": "stage_settings",
  "redirect_uri": "https://mopm.dev/api/v2/auth/web/callback",
  "site_origin": "https://mopm.dev",
  "require_2fa": true,
  "e2b_template_id": "<template id, when named>",
  "e2b_domain": "e2b.app",
  "sandbox_timeout_s": 1800 }
```

Every field is required except `e2b_template_id`, which the stack leaves out until the stage names a template (the sandbox
function then answers `tutorial_unavailable`; present and empty is refused). `site_origin` is `https://` and a lower-case host with no path, `redirect_uri` is a path
under it, the E2B fields are not empty when present and the timeout is more than zero; anything else fails the cold start by name.
Other fields are ignored, so a newer stack's item still loads. `ConfigTable` has the memory implementation here
(`BTreeMap<String, serde_json::Value>`); the DynamoDB one lives in the first function that reads it (`fn_tutorial_sandbox`).
