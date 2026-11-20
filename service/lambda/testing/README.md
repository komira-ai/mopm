# mopm_testing

Test support for the ports; no function links it.

* `memory_store`, `memory_auth`, `memory_publish`: the in-memory implementations. Each method takes its lock, checks and
  writes, and never awaits while holding it, so it is atomic, which is what the DynamoDB adapters get from conditions.
  `MemoryObjectStore`, `MemoryPresigner` (pins length and base64 sha256 like a real signature), `FakeS3Upload` (what S3 does
  with the PUT), `MemoryQueue` (FIFO dedup), `MemoryInvalidator`, `StaticFlags`.
* `store_cases`, `auth_cases`, `publish_cases` and the macros `store_contract_tests!`, `auth_contract_tests!`,
  `publish_contract_tests!`: the contract of each port, ported from `service/api/test/store.test.ts`,
  `auth-store.test.ts` and `publish/dynamo.test.ts`, one `#[tokio::test]` per scenario on a fresh store. The memory stores
  run them here; `mopm_aws` runs the same ones against its adapters.
* `fake_http`: a scripted HTTP server on 127.0.0.1, port 0. `FakeHttp::start` answers a list of replies in order (the last
  repeats); `FakeHttp::with_handler` answers each request with what a function decides: a `Reply`, `Answer::Drop` (the
  connection closes unanswered) or `Answer::Hang` (nothing, until the server is dropped). Every request is recorded in
  full (`Seen`: method, target, headers, body, with `json()` and `form()`); `wait_for_requests(n)` returns once `n` are.
* `fake_github`: GitHub for the web sign-in, on `fake_http`. `FakeGitHub::start(OAuthApp)`; `authorize(url, user)` and
  `deny(url)` play the browser's step and answer the callback URL; `add_grant(Grant)` adds a code bound to a verifier;
  `POST /login/oauth/access_token` gives a token only for the app's client id and secret and the code's verifier, else
  GitHub's error; `GET /user` answers the token's `GitHubUser`; `set_outage(Some(Outage::Status(502) | Drop | Hang))`.
* `fake_e2b`: E2B's `POST /v2/sandboxes`, on `fake_http`. `FakeE2b::start(api_key, script)`: a wrong or missing
  `X-API-Key` is 401, another route 404, and each create takes the next `CreateAnswer` (`Created(Sandbox)`, with
  `null_domain()` and `without_access_token()` variants; `concurrency_limit()`; `server_error(status)`; `Hang`).
* `env`: `FixedClock`, `SeededRng`. `records`: `rec` and `audit` of `test/helpers.ts`.
* `seed`: a store's contents before a request as one JSON document (`packages`, `versions`, `owners`, `audit`), strict
  about unknown members and duplicates, so a scenario is data that the TS tests can load as well.

Not here yet: the fake DynamoDB that enforces `lambda-auth-grants.json` (it belongs with the adapters that need it, `mopm_aws`).
