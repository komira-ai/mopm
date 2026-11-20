# fn_tutorial_sandbox

The `tutorial-sandbox` Lambda (`docs/design/tutorial-sign-in.md`, sections 4 and 5): `POST /api/v2/tutorial/sandbox` gives a
signed-in browser a sandbox on E2B and what it needs to reach it. A Rust function on the custom runtime
(`provided.al2023`); the library holds all the logic, and `src/main.rs` only forwards to it.

| file | what |
|---|---|
| `src/handler.rs` | `Function`: the checks in order, the E2B call, the answer and its log line; the API Gateway adapter |
| `src/start.rs` | the cold start: stage, settings, edge secret, E2B key; the two AWS clients |
| `src/key.rs` | the E2B key: read at the cold start, kept once it is there, read again until then |
| `src/log.rs` | the four log lines |
| `src/args.rs` | the command line (one flag) |
| `src/clock.rs` | the system's time, shared |
| `tests/fixtures/grants.json` | what the function's role may call, as the fake DynamoDB's grants; the stack's jest test holds the role to it |
| `tests/run.rs` | `run` against one loopback server that plays the Lambda runtime API and the AWS endpoint |
| `e2e_test.zig` | the built executable against the same kind of server (the `:e2e_test` target) |

## What it answers

The checks run in this order; the first refusal answers, and all of them run before any call to E2B.

1. The route: any path but `/api/v2/tutorial/sandbox`, or any method but `POST`, is 400 `invalid_request` ("no such route"). The
   function is routed for this one route, so this only guards against a mis-routing.
2. `mopm_web::SessionAuth::session_for_post`: the edge header (401 `session_required`), no `Authorization` header (400
   `invalid_request`), one session cookie (401), the CSRF checks (403 `csrf_failed`), the session row and its account (401), and the
   touch of the row. A store that fails is 500 `internal_error`.
3. A body is 400 `invalid_request` ("the request takes no body").
4. A stage whose settings name no template is 503 `tutorial_unavailable`.
5. No E2B key (see below) is 503 `tutorial_unavailable`.

Then `mopm_e2b::create_sandbox`. Success is **201** with `x-mopm-request-id`, `cache-control: no-store` and
`content-type: application/json`, and the body

```json
{"access_token":"...","domain":"e2b.app","envd_version":"...","expires_at":"2026-11-20T10:30:00Z","sandbox_id":"..."}
```

(keys in this order; a null `domain` from E2B is the stage's `e2b_domain`; `expires_at` is the time the request was sent plus the
stage's `sandbox_timeout_s`). Every way E2B fails to give a usable sandbox is 503 `tutorial_unavailable` with `retry-after: 30`.
There is no limit, counter or per-user cap of any kind: a user gets a new sandbox from this route as often as they like, and E2B's
own plan limits are `tutorial_unavailable`.

The Lambda adapter is `mopm_web::apigw`: an event that does not make a request (a body that is not base64) is `invalid_request`,
and an answer API Gateway cannot carry is a plain 500 `internal_error` (`fallback_internal_error`).

## The log

Exactly one line per request on stdout, a JSON object with its keys in this order. Nothing else is printed (no tracing subscriber
is installed). No line holds the E2B key, the sandbox's access token, the session token, the CSRF value or a cookie.

```
{"event":"tutorial_sandbox","github_id":<number>,"outcome":"created","request_id":"<id>","sandbox_id":"<E2B's id>"}
{"event":"tutorial_sandbox","outcome":"unavailable","reason":"<class>","request_id":"<id>"}
{"event":"tutorial_sandbox","outcome":"refused","reason":"<error code>","request_id":"<id>"}
{"event":"tutorial_sandbox","outcome":"error","reason":"internal_error","request_id":"<id>"}
```

`refused` is a 400, 401 or 403 (`reason` is the answer's error code). The reason classes of `unavailable`:

| reason | cause |
|---|---|
| `template_missing` | the stage settings name no `e2b_template_id` |
| `secret_missing` | the E2B secret does not exist, has no value yet, or holds no string |
| `secret_empty` | the secret is the empty string, or its `api_key` is empty |
| `secret_malformed` | the secret is not a JSON object with a string `api_key` |
| `secret_read_failed` | Secrets Manager failed |
| `e2b_status_<code>` | E2B answered that status (`e2b_status_429`, `e2b_status_500`, ...) |
| `e2b_timeout`, `e2b_no_connection`, `e2b_tls` | E2B gave no answer |
| `e2b_client` | the HTTP client failed in another way |
| `e2b_malformed`, `e2b_missing_field` | E2B's answer is not a sandbox |
| `e2b_no_access_token` | the sandbox has no access token (it is refused: see section 4 of the design note) |
| `clock_out_of_range` | the sandbox's end is past the last representable time |

## Cold start

1. The stage, from `AWS_LAMBDA_FUNCTION_NAME` (`mopm-<stage>-<function>`).
2. The stage settings: the item `stage_settings` of `mopm-<stage>-config` (`mopm_web::settings::StageSettings`).
3. The edge secret `mopm/<stage>/edge-origin`.
4. The E2B secret `mopm/<stage>/e2b`, a JSON object `{"api_key": "<key>"}`, once.

A failure of 1 to 3 fails the start, by name (the process exits with the error, and nothing answers), and so does a
`sandbox_timeout_s` above `u32::MAX`, the type of E2B's `timeout`: a wrong setting, like any other, whether or not the stage
names a template. A key that is present is
kept for the life of the process. A key that is absent, empty, malformed or unreadable does not fail the start and is not kept:
the next request that passes the checks above reads it again, so the operator writing the key takes effect without a redeploy.

The AWS clients are built without `aws-config`: the region from `AWS_REGION` and static credentials from `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY` and, when set, `AWS_SESSION_TOKEN` (Lambda sets all of them). The SDK's retries are off: a failed read is
that request's `tutorial_unavailable` or `internal_error`, and a failed cold start is run again by Lambda. No other environment
variable is read.

## The flag

`--aws-endpoint-url <url>` (optional) points the DynamoDB and Secrets Manager clients at one endpoint; the end-to-end test uses it.
Lambda passes no argument. Any other argument, the flag without a value, or the flag twice fails the start.

## Tests

All hermetic: fakes on `127.0.0.1` port 0, a fixed clock, no sleeps and no timing assertions. The function always runs over a fake
DynamoDB restricted to `tests/fixtures/grants.json` (so the grants suffice), seeded with a `stage_settings` item made from the one the stack writes
(`mopm_web`'s `tests/fixtures/stage_settings_item.json`, the item the stack's test holds its writer to) with the beta test
values set over it (template `mopm-tutorial-beta`, 1800 s, `e2b.app`, two-factor on), so its shape is the stack's, a fake Secrets Manager, the fake E2B API (plain HTTP, through a
small test client: the production client refuses `http://`) or a scripted client.

| test file | behaviour |
|---|---|
| `src/handler_tests.rs` | each refusal answers its exact status and body and E2B sees no request; the create body is the design note's, the key is only in `x-api-key`; the 201 answer, headers and log line; a null domain and the end of the sandbox; two requests both succeed; every error case of `tests/contract/api-v2/tutorial-sandbox.json` |
| `src/unavailable_tests.rs` | each way of failing is 503 with `retry-after: 30`, the exact body and the exact log line; E2B is not called when the cause is ours; the key written later is picked up, a present key is read once |
| `src/start_tests.rs` | the command line, the environment, cold-start failures by name, the stores' failures, the API Gateway adapter's paths |
| `tests/run.rs` | `run` starts, answers one event and posts the answer to the runtime |
| `e2e_test.zig` | the release executable, run against a loopback runtime API and AWS endpoint |

Every answer and log line a test reads is also checked, by `Rig::send`, for the E2B key, the access token (except in the 201
body), the session token, the CSRF value and the edge value.
