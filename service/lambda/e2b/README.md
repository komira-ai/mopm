# mopm_e2b

E2B's create call for the tutorial sandbox (`docs/design/tutorial-sign-in.md` section 4), over `mopm_ports`'
`HttpClient`. A library, not a port: E2B is the one provider, and the tests run against `mopm_testing`'s fake E2B API.

`create_sandbox(http, api_key, settings, request_id, clock) -> Result<Grant, E2bError>`:

- sends `POST {settings.api_base}/v2/sandboxes` (`https://api.e2b.app` unless a test points it at its fake) with the
  team key in `X-API-Key`, an 8 s request timeout (`REQUEST_TIMEOUT`; the function's own timeout is 10 s) and this body:

  ```json
  {
    "templateID": "<settings.template_id>",
    "timeout": 1800,
    "allow_internet_access": false,
    "autoPause": false,
    "network": { "allowPublicTraffic": false },
    "metadata": { "mopm_stage": "<settings.stage>", "mopm_request": "<request_id>" }
  }
  ```

  `timeout` is `settings.timeout_s` (default 1800). The metadata names no user.
- reads a 2xx answer as `Grant { sandbox_id, access_token, envd_version, domain, expires_at }` from `sandboxID`,
  `envdAccessToken`, `envdVersion` and `domain`. A null, absent or empty `domain` is `settings.e2b_domain` (default
  `e2b.app`). `expires_at` is the clock's time, read once just before the request is sent, plus `timeout_s`, as RFC
  3339 UTC to the second (the fraction dropped).
- answers `E2bError::Unavailable` (the route's 503 `tutorial_unavailable`) for a non-2xx status, no answer (timeout,
  connection, TLS), a client fault, a body that is not a sandbox's JSON, a missing or empty `sandboxID`, `envdVersion`
  or `envdAccessToken`, and a clock so late the end cannot be represented (then nothing is sent). The reason
  (`Unavailable`) is for the log; it never carries a header or body of the exchange, and a decode error keeps only its
  line and column, because serde_json's own text can quote the answer.

`ApiKey` and `AccessToken` print as `ApiKey(<redacted>)` and `AccessToken(<redacted>)` in `Debug` and have no
`Display`; the route hands the token to the browser with `AccessToken::expose`.

Nothing else of E2B's API is here: no pause, kill, extend or connect, which the tutorial does not use.
