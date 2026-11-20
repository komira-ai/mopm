# mopm_ports

The traits the registry's logic is written against, and the records they carry. No I/O here.

| module | what |
|---|---|
| `store` | `Store` (`store.ts`): packages, versions with their audit rows, owners, audit; the rules every adapter keeps (create-once versions, audit atomic with the change, rows never deleted) |
| `auth` | `AuthStore` (`auth/types.ts`): users, tokens (only the hash is stored), device logins, trusted publishers |
| `publish` | `ObjectStore`, `Presigner`, `Invalidator`, `Queue`, `Flags`, `PublishStore` (`publish/ports.ts`) |
| `namespaces` | `NamespaceStore` (`auth/namespaces.ts`): the user namespace a login creates or holds (`ensure_user_namespace`), the namespace grammar (`user_namespace_for`) and `NamespaceRecord` |
| `web_login` | `WebLoginStore`: the web sign-in's login transaction, stored by `start` and consumed once by `callback` (`WebLoginRecord`) |
| `http` | `HttpClient`: one outbound request, one response; a non-2xx status is an answer, no answer is `HttpError` (connect, timeout, TLS) |
| `types` | the auth and publish records and the queue body, as the TS registry stores and sends them (absent, never `null`) |
| `env` | `Clock`, `Rng`, and `iso_millis` (`toISOString`: three decimals and `Z`) |
| `error` | `PortError`: a domain error the registry answers with, an infrastructure fault, or an HTTP request that got no answer |

Methods are `fn ... -> impl Future<Output = PortResult<_>> + Send` (async fn in traits, no `async-trait`, no
boxing); an implementation writes `async fn`. Each store has a memory implementation (`mopm_testing`) and a DynamoDB one (`mopm_aws`), which is why they are
traits; the DynamoDB adapters of `NamespaceStore` and `WebLoginStore` and the `hyper` `HttpClient` are not written yet.
