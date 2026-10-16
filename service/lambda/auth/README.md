# mopm_auth

Who a request is, and how a caller becomes someone: the logic of `service/api/src/auth` in Rust, over the ports of
`mopm_ports`. It does no routing (that is the Lambda's) and no storage (that is `mopm_aws`'s).

| module | what | TypeScript |
|---|---|---|
| `tokens` | mint a token (hash and prefix stored, secret shown once), `TokenService` (create, list, revoke API tokens), `Authenticator` (an `Authorization` header to a `Principal`; the four security schemes `userToken`, `freshSession`, `publishToken`, `yankToken`) | `tokens.ts` |
| `device_login` | the CLI's login over GitHub's OAuth device flow: `start`, `poll` | `device-login.ts` |
| `github` | GitHub's three calls (`HttpGitHub`), behind the `GitHubApi` trait | `github.ts` |
| `http` | the one outbound HTTP client (hyper, rustls on AWS-LC, system roots): https only, no redirects, a deadline, a body cap | `fetch` |
| `system` | the real clock and the operating system's random source | |
| `js` | the JavaScript behaviours an answer depends on: `trim`/`\s`, `length` in UTF-16 units, the sort order of strings, `Number.isInteger` | |

Errors are `mopm_core`'s `RegistryError` (a code, a status, a message, the values of its template) inside the
ports' `PortError`, so a route answers a domain refusal and logs a fault. Time is a `Clock` and randomness an `Rng`
(ports), so a test fixes both.

## What is different from the TypeScript

Each of these is a decision, and each has a test.

* **An unparsable time fails closed.** A stored `expires_at` that does not parse is expired (JavaScript's `NaN`
  comparison would call it not expired). Stored times are written by this code, so this is a guard, not a path.
* **GitHub answering something that is not JSON is `unavailable`** (503); the TypeScript lets the parse error escape as a 500.
* **GitHub's device-code answer** must carry `expires_in` and `interval` as whole non-negative numbers; the TypeScript
  accepts any number.
* **`localeCompare`** in the token list's order is a byte comparison here. The keys are ISO timestamps and ids made
  of lower case hexadecimal and `_`, for which the two agree.
* The request bodies are typed (`CreateTokenInput`), so a wrong JSON type is the route's parse error, not one of this
  crate's messages. A fractional `expires_in_days` still reaches this crate and is refused with the same message.

## Tests

`tokens_tests` and `device_login_tests` port two of the TypeScript test files (`auth-tokens`, `auth-device`) case by
case, over the memory stores of `mopm_testing`. GitHub is a scripted server on loopback and the real HTTP client talks to it,
so the form bodies, headers and status handling are held with the login logic.
