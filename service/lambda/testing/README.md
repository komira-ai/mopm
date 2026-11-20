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
  ones against its DynamoDB adapters.
* `scripted_http`: `ScriptedHttp`, an `HttpClient` in memory that answers from a script (responses, or an `HttpError`
  such as a timeout, returned at once) and records every request as sent.
* `env`: `FixedClock`, `SeededRng`. `records`: `rec` and `audit` of `test/helpers.ts`.
* `seed`: a store's contents before a request as one JSON document (`packages`, `versions`, `owners`, `audit`), strict
  about unknown members and duplicates, so a scenario is data that the TS tests can load as well.
* `fake_dynamo`: a DynamoDB on loopback for `mopm_aws`'s adapters, with the data stack's tables and `web_logins`, the
  web sign-in's table (`docs/design/tutorial-sign-in.md`, section 6). It enforces a role's grants when given them: `lambda-auth-grants.json` of the
  TypeScript API, or `FakeConfig::web_login`, the web sign-in function's grants on its two own tables
  (`tests/fixtures/web_login_grants.json`: put and update on `web_logins`, get and put on `namespaces`, no delete; every
  other table denied).
* `fake_http`: a scripted HTTP server on loopback for the adapters of the other AWS services.
