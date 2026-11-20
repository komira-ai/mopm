# mopm_testing

Test support for the ports; no function links it.

* `memory_store`, `memory_auth`, `memory_publish`, `memory_namespaces`, `memory_web_login`: the in-memory implementations. Each method takes its lock, checks and
  writes, and never awaits while holding it, so it is atomic, which is what the DynamoDB adapters get from conditions.
  `MemoryObjectStore`, `MemoryPresigner` (pins length and base64 sha256 like a real signature), `FakeS3Upload` (what S3 does
  with the PUT), `MemoryQueue` (FIFO dedup), `MemoryInvalidator`, `StaticFlags`.
* `store_cases`, `auth_cases`, `publish_cases`, `namespace_cases`, `web_login_cases` and the macros
  `store_contract_tests!`, `auth_contract_tests!`, `publish_contract_tests!`, `namespace_contract_tests!`,
  `web_login_contract_tests!`: the contract of each port, ported from `service/api/test/store.test.ts`,
  `auth-store.test.ts`, `publish/dynamo.test.ts` and the login's part of `auth-namespaces.test.ts` (the web login's is
  new), one `#[tokio::test]` per scenario on a fresh store. The memory stores run them here; `mopm_aws` runs the same
  ones against its adapters (the store, auth and publish suites today; the namespace and web-login suites once their
  DynamoDB adapters exist).
* `scripted_http`: `ScriptedHttp`, an `HttpClient` in memory that answers from a script (responses, or an `HttpError`
  such as a timeout, returned at once) and records every request as sent.
* `env`: `FixedClock`, `SeededRng`. `records`: `rec` and `audit` of `test/helpers.ts`.
* `seed`: a store's contents before a request as one JSON document (`packages`, `versions`, `owners`, `audit`), strict
  about unknown members and duplicates, so a scenario is data that the TS tests can load as well.

Not here yet: the fake DynamoDB that enforces `lambda-auth-grants.json` (it belongs with the adapters that need it, `mopm_aws`).
