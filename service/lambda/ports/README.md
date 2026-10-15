# mopm_ports

The traits the registry's logic is written against, and the records they carry. No I/O here.

| module | what |
|---|---|
| `store` | `Store` (`store.ts`): packages, versions with their audit rows, owners, audit; the rules every adapter keeps (create-once versions, audit atomic with the change, rows never deleted) |
| `auth` | `AuthStore` (`auth/types.ts`): users, tokens (only the hash is stored), device logins, trusted publishers |
| `publish` | `ObjectStore`, `Presigner`, `Invalidator`, `Queue`, `Flags`, `PublishStore` (`publish/ports.ts`) |
| `types` | the auth and publish records and the queue body, as the TS registry stores and sends them (absent, never `null`) |
| `env` | `Clock`, `Rng`, and `iso_millis` (`toISOString`: three decimals and `Z`) |
| `error` | `PortError`: a domain error the registry answers with, or an infrastructure fault |

Methods are `fn ... -> impl Future<Output = PortResult<_>> + Send` (async fn in traits, no `async-trait`, no
boxing); an implementation writes `async fn`. There are two implementations of each store (memory, DynamoDB), which is
why they are traits.
