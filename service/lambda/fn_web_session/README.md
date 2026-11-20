# fn_web_session

The website's `web-session` Lambda (`docs/design/tutorial-sign-in.md`, sections 2, 2.1 and 5): the two routes API Gateway sends it,
built from `mopm_web`'s pieces. The library holds everything; `src/main.rs` calls `fn_web_session::runtime::main` and nothing else
(the executable is `fn_web_session`, `bootstrap` in the deployment package).

| route | answer |
|---|---|
| `GET /api/v2/auth/web/session` | 200 `{"csrf", "expires_at", "login"}` (`login` is the account's handle, `csrf` is `mopm_core::csrf::csrf_value` of the session token, `expires_at` is the row's); `Cache-Control: no-store`, `x-mopm-request-id` |
| `POST /api/v2/auth/web/logout` | 204, no body, one `Set-Cookie` that clears `__Host-mopm_session`; the session's own `tokens` row gets `revoked_at` |
| any other path, or another method on those two | 404 `route_not_found` (the v2 API's answer for both; it has no `method_not_allowed`) |

Errors are `mopm_web`'s envelope: 401 `session_required` (no usable session, or the request did not come through the site's
distribution), 400 `invalid_request` for an `Authorization` header, 403 `csrf_failed` on a logout, 500 `internal_error` for a store
fault.

## Order

1. The route is chosen from the path and the method, before any check (a request to another route is 404 whatever it carries).
2. `SessionAuth` (`mopm_web::session`): the edge header, no `Authorization`, one session cookie, for a `POST` the CSRF checks
   (the `Origin` is the stage's `site_origin`), then the row by the token's hash and its account.
3. A logout revokes that row only (`revoke_token` by its hash, at the clock's time). Another session of the account, its CLI
   sessions and its API tokens are not touched. A second logout with the same cookie is 401: `SessionAuth` refuses a revoked row.
4. The answer goes through `mopm_web::apigw`: `from_apigw` (a body that is not base64 is 400), the handler, `to_apigw` (a response
   HTTP cannot carry is the fixed `internal_error` 500).

Each answer is logged (`tracing`, JSON lines): method, path, status and, for an error, its code and message. The message says which
check refused and never holds the token; a cookie, a header or a body is never logged.

## Modules

| module | what |
|---|---|
| `handler` | `WebSessionHandler<S, C>`: `answer(&WebRequest)` (the routes) and `handle_event(ApiGatewayV2httpRequest)` (the event entry) |
| `startup` | `cold_start`: function name, then `StageSettings::load` (the `stage_settings` item of `mopm-<stage>-config`), then `EdgeCheck::load` (`mopm/<stage>/edge-origin`), then the handler. Failures are `SetupError`, by name |
| `clock` | `SystemClock`, the one clock the process has |
| `runtime` | `serve` and `main`: `AWS_LAMBDA_FUNCTION_NAME` (the one variable read), `aws_config::load_defaults` (honours `AWS_REGION`, the `AWS_*` credentials and `AWS_ENDPOINT_URL[_<SERVICE>]`), the DynamoDB and Secrets Manager clients, `lambda_runtime::run`. A failed cold start is logged and the process exits non-zero, as does the runtime loop returning |

The function's role needs `GetItem` and `UpdateItem` on `tokens`, `GetItem` on `users` and `config`
(`service/lambda/testing/tests/fixtures/web_session_grants.json`, which the API stack's test also holds); the flow tests run on a fake
DynamoDB that enforces exactly those.

## Tests

| where | what |
|---|---|
| `src/handler_tests.rs` | the routes against the memory auth store and a fixed clock: the answer byte for byte, every refusal, a logout that revokes one row only, the 404s, store faults, the event entry |
| `src/startup_tests.rs` | the stack's `stage_settings` item (`service/lambda/web/tests/fixtures/stage_settings_item.json`) read through the DynamoDB adapter into its settings; a missing item, a missing secret and an empty secret refused by name |
| `src/flow_tests.rs` | the whole flow on real SDK calls against a fake DynamoDB with the role's grants and a fake Secrets Manager; the fixture rows (`tests/fixtures/web_session_*.json`) are what the DynamoDB adapter writes |
| `tests/runtime_test.rs` | the process entry against a fake Lambda runtime API: a session, a logout and a session again, the posted bytes exactly; then the exit with a failure when the runtime API is gone |
| `tests/runtime_cold_start_test.rs`, `tests/runtime_setup_test.rs`, `tests/main_test.rs` | a stage without its settings item, a malformed function name, and the executable run as a process: each exits with a failure without a poll of the runtime API |

Each file of `tests/` that sets the process's environment holds one test. Everything is on loopback with ports from the system.
