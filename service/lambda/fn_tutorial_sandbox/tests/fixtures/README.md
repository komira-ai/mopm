Test fixtures of `fn_tutorial_sandbox`.

| file | what |
|---|---|
| `grants.json` | the function's DynamoDB grants: the Rust tests run the function over the fake DynamoDB restricted to them, and the stack test (`service/infra/stacks/test/tutorial-sandbox.test.ts`) holds the function's role to them |
| `e2e_root.pem` | a test CA, a copy of `service/lambda/aws/tests/fixtures/ca.pem`: `e2e_test.zig` gives it to the binary as its root certificates (`SSL_CERT_FILE`), because the build's workers have none. Nothing connects to a server it signed. |
