# mopm_auth

Who a request is, and how a caller becomes someone: the logic of `service/api/src/auth` in Rust, over the ports of
`mopm_ports`. It does no routing (that is the Lambda's) and no storage (that is `mopm_aws`'s).

| module | what | TypeScript |
|---|---|---|
| `tokens` | mint a token (hash and prefix stored, secret shown once), `TokenService` (create, list, revoke API tokens), `Authenticator` (an `Authorization` header to a `Principal`; the four security schemes `userToken`, `freshSession`, `publishToken`, `yankToken`) | `tokens.ts` |
| `device_login` | the CLI's login over GitHub's OAuth device flow: `start`, `poll` | `device-login.ts` |
| `github` | GitHub's three calls (`HttpGitHub`), behind the `GitHubApi` trait | `github.ts` |
| `oidc` | the exchange of a GitHub Actions identity token for a 15 minute publish token: `JwtVerifier`, the key set (`JwksSource`, `HttpJwks`), trusted-publisher matching, `OidcExchange` | `oidc.ts` |
| `http` | the one outbound HTTP client (hyper, rustls on AWS-LC, system roots): https only, no redirects, a deadline, a body cap | `fetch` |
| `system` | the real clock and the operating system's random source | |
| `js` | the JavaScript behaviours an answer depends on: `trim`/`\s`, `length` in UTF-16 units, the sort order of strings, `Number.isInteger` | |

Errors are `mopm_core`'s `RegistryError` (a code, a status, a message, the values of its template) inside the
ports' `PortError`, so a route answers a domain refusal and logs a fault. Time is a `Clock` and randomness an `Rng`
(ports), so a test fixes both.

## The CI identity token

`JwtVerifier::verify` does, in this order, what the TypeScript does, with the same message at each step:

1. the token is non-empty, at most 8192 UTF-16 units, three dot-separated parts, the first two base64url of JSON
   (`malformed token`);
2. `alg` is exactly `RS256` (`unsupported algorithm`). **The algorithm is ours and is never read from the token**:
   `none`, `HS256` keyed with the public key (the key-confusion attack), `RS384`, `PS256`, `ES256` and every other
   spelling are refused here, before any key is looked up or fetched;
3. `kid` is a non-empty string (`missing key id`); the key is the issuer's published key of that `kid`
   (`unknown signing key`). Nothing the token carries is used as a key: `jwk`, `jku`, `x5u` and `x5c` of its header
   are not read;
4. the signature, RSA PKCS#1 v1.5 with SHA-256, by `jsonwebtoken` on its pure-Rust backend (`bad signature`);
5. `iss`, `aud` (a string or a list), `exp`, `nbf`, `iat` with 60 seconds of leeway, and the four claims the trust
   decision needs (`wrong issuer`, `wrong audience`, `missing expiry`, `token expired`, `token not yet valid`,
   `missing issued-at`, `token issued in the future`, `missing claim <name>`).

The claim rules are ours rather than `jsonwebtoken`'s `Validation` because the messages, their order and the
boundary at the leeway are the API's. The key set is cached ten minutes; an unknown `kid` causes one refetch, and no
second one inside a minute, so forged `kid`s cannot make the registry fetch once per request.

## What is different from the TypeScript

Each of these is a decision, and each has a test.

* **An unparsable time fails closed.** A stored `expires_at` that does not parse is expired (JavaScript's `NaN`
  comparison would call it not expired). Stored times are written by this code, so this is a guard, not a path.
* **GitHub answering something that is not JSON is `unavailable`** (503); the TypeScript lets the parse error escape as a 500.
* **GitHub's device-code answer** must carry `expires_in` and `interval` as whole non-negative numbers; the TypeScript
  accepts any number.
* **A token or signature that is base64url with non-canonical trailing bits** is refused (`malformed token` or
  `bad signature`); Node's decoder is lenient. GitHub does not produce them.
* **`localeCompare`** in the token list's order is a byte comparison here. The keys are ISO timestamps and ids made
  of lower case hexadecimal and `_`, for which the two agree.
* The request bodies are typed (`CreateTokenInput`), so a wrong JSON type is the route's parse error, not one of this
  crate's messages. A fractional `expires_in_days` still reaches this crate and is refused with the same message.

## Tests

`tokens_tests` and `device_login_tests` and `oidc_tests` port the three TypeScript test files case by case, over
the memory stores of `mopm_testing`. GitHub is a scripted server on loopback and the real HTTP client talks to it,
so the form bodies, headers and status handling are held with the login logic. The CI tokens are signed with real RSA
keys (two fixed test keys in `test_keys.rs`, which protect nothing) and checked by the real verifier.
