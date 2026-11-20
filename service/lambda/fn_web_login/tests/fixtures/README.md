Fixtures of `fn_web_login`'s tests.

| file | what |
|---|---|
| `device_login_rows.json` | the `users` and `namespaces` items the TypeScript device login writes for one GitHub user at one time, on empty tables; the Rust sign-in must write the same (`src/callback_tests.rs`; `service/api/test/auth/device-login-rows.test.ts` for the TypeScript side) |
| `role_grants.json` | the DynamoDB actions the function's role has, per table, in the format of `mopm_testing`'s `Grants::parse`; the tests run the fake DynamoDB under exactly these (the stack test holds the role to them) |
| `ca.pem` | a test CA (the certificate of `service/lambda/aws/tests/fixtures/ca.pem`, no key), the one root certificate the executable trusts in `tests/process.rs`; `e2e_test.zig` carries the same text |
