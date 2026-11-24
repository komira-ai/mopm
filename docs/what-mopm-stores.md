# What mopm.dev stores

This page says what mopm.dev keeps when you sign in with GitHub and run a lesson of the interactive tutorial, and for how long. It also says what E2B, the company whose servers run the lessons' code, sees, and what stays in your browser. Reading the docs and searching packages needs no sign-in.

## In short

- **Your account**: your GitHub numeric id and login, the times you first and last signed in, and whether GitHub reported two-factor authentication as on. mopm.dev never asks GitHub for your email address.
- **Your session**: a hash of the session token, which ends 7 days after you sign in, or when you sign out.
- **A sign-in in progress**: kept for 10 minutes.
- **Logs**: one line per request to the sign-in and sandbox routes, kept for one month. No log line holds your code, your output, a token or your IP address.
- **Your code and output** go from your browser to E2B and never through mopm.dev. E2B sees your files, your commands, their output and your IP address.
- **Your browser** keeps the session cookie and your draft of the lesson's files.

## Signing in with GitHub

Sign-in uses GitHub's OAuth web flow with the scope `read:user`, which gives read access to your GitHub profile and nothing else. mopm.dev reads one thing with it, `GET https://api.github.com/user`, and keeps three fields of the answer: your numeric id, your login and whether two-factor authentication is on. Then it discards GitHub's access token; it is never stored or logged. mopm.dev requires two-factor authentication on the GitHub account: a sign-in is refused when GitHub does not report it as on, and no account is stored for it.

GitHub itself records that you authorized the mopm OAuth app, under [GitHub's privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

The account is the same one `mopm login` creates on the command line: the same rows, keyed by the same GitHub id.

## What the service stores

| where | what | how long |
|---|---|---|
| `users` table | your GitHub numeric id, your GitHub login (`handle`), when the account was created (`created_at`) and when you last signed in (`last_login_at`), and whether GitHub reported two-factor authentication as on | no expiry |
| `namespaces` table | your user namespace: your login in lower case, your GitHub id and when it was created. A sign-in creates it the first time, as `mopm login` does, when your login can be a namespace (it is not reserved or taken). | no expiry |
| `tokens` table | your session: the SHA-256 of the session token (never the token itself), its first 11 characters (`mopm_` and six more), the kind `session`, the name `web login`, your GitHub id, when it was created, when it expires, the empty lists of scopes and packages an API token would have, when it was last used (written at most once every 60 seconds while you use the tutorial) and, once you sign out, when it was revoked | 7 days |
| `web_logins` table | a sign-in in progress: the SHA-256 of its id, the SHA-256 of the `state` sent to GitHub, the PKCE code verifier, the page to return to, when it expires and when it was used | 10 minutes |
| logs | one line per request to the sign-in and sandbox routes, described under "The log lines" below | one month |

"How long" is the time after which a row stops working: the service checks the expiry on every request, so an expired session or sign-in is refused at once. DynamoDB then deletes the row through its time-to-live setting, which AWS says usually happens within a few days of the expiry ([DynamoDB TTL](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html)). No code of the service deletes a row of these tables: signing out marks the session revoked, and the row stays, unusable, until its 7 days are over.

Every table has point-in-time recovery on, so DynamoDB keeps a deleted row restorable for a further 35 days, AWS's window, which mopm.dev does not change ([point-in-time recovery](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/PointInTimeRecovery.html)). The tables are encrypted at rest.

The service never stores the GitHub access token, your email address or your IP address. The functions do not read the address a request comes from, the API has no access log, and the site's CloudFront distribution has no access log either.

## The log lines

The sandbox route writes one line for each request. When it creates a sandbox the line is:

```json
{"event":"tutorial_sandbox","github_id":4242,"outcome":"created","request_id":"req-7f3a2c19d0e4","sandbox_id":"i8x3k2p9q1v7m4n6s5t0"}
```

`github_id` is your GitHub numeric id, `request_id` is the id of the request, and `sandbox_id` is E2B's id of the sandbox. When the route refuses or fails, the line has the `outcome` (`refused`, `unavailable` or `error`), a `reason` (an error code such as `csrf_failed`, or a class such as `e2b_timeout`) and the `request_id`, and no GitHub id or sandbox id.

The sign-in routes write one line per request: the route, the request id, the outcome (`redirected`, `signed_in` or the reason a sign-in failed, such as `login_expired`) and, once GitHub has said whose account it is, your GitHub id. That id is in the line for a refused sign-in too, for example one refused for `two_factor_required`. The session routes (reading the session, signing out) write the method, the path and the status, and for a refusal the error code and its message.

No line holds the session token, a cookie, the CSRF value, the sandbox's access token, the E2B key, GitHub's token, your code, your output or your IP address. AWS Lambda adds its own lines around each request (start, end and a report of the duration and memory used), which name Lambda's own request id.

The request id is also sent back to your browser in the `x-mopm-request-id` header, and to E2B as the sandbox's metadata (`mopm_request`, with `mopm_stage`, the name of the site's stage), so a question about one run can be matched to its line. mopm.dev sends E2B no GitHub id, login or email address.

## Your code runs on E2B

The tutorial runs your code in a sandbox on [E2B](https://e2b.dev), a separate company. When you click Run:

1. The page asks mopm.dev for a sandbox (`POST /api/v2/tutorial/sandbox`). The request has no body: the route refuses one, so your code is not in it.
2. mopm.dev creates a sandbox on E2B with internet access off and answers the sandbox's id and its access token, which opens that one sandbox and nothing else.
3. The page writes your files into the sandbox and runs the lesson's command there, talking to E2B directly, and reads the output from E2B.

So your code and its output go from your browser to E2B and back, and never through mopm.dev. In one sentence: your code runs on E2B's servers, which see your IP address; mopm.dev does not see or store your code.

**What E2B sees**: the files you write and run, the commands, their output, and, because your browser connects to E2B, your IP address and your browser's request headers on each call, as any site your browser connects to does. From mopm.dev it gets the stage name and the request id, and nothing that names you. What E2B keeps, and for how long, is set by [E2B's terms](https://e2b.dev/terms) and [E2B's privacy policy](https://e2b.dev/privacy).

E2B ends the sandbox 30 minutes after it was created; the page asks for a new one when it needs one and writes your files into it again. The sandbox cannot reach the internet. The key that creates sandboxes stays in mopm.dev's service and never reaches the browser.

## What your browser keeps

| what | where | how long |
|---|---|---|
| `__Host-mopm_session`, the session token | a cookie: `Secure` (sent over HTTPS only), `HttpOnly` (the page's scripts cannot read it), `SameSite=Lax`, for the site's own host only | 7 days, or until you sign out |
| `__Host-mopm_login`, the id of a sign-in in progress | a cookie with the same attributes, set when you click sign-in and cleared when GitHub sends you back | 10 minutes |
| `mopm.tutorial.1`, your draft: the last lesson you opened and the files you edited, by lesson | the browser's `localStorage` for the site | until you clear the site's data |
| the sandbox's id and access token | the page's memory only, never written to storage | until the page is closed or reloaded, or the sandbox ends |

The draft is written when you open a lesson (the last lesson you opened), signed in or not, and each time you edit a file. It is never sent to mopm.dev; its files go to E2B when you run them. A browser that refuses storage (a private window, storage blocked or full) runs the tutorial without a draft.

The site sets no other cookie and uses no other browser storage.

## Signing out

Signing out (`POST /api/v2/auth/web/logout`, which the tutorial page sends) marks this browser's session revoked and clears its cookie. From then on the session opens nothing, though its row stays until its 7 days are over. Signing in again revokes the session the browser held before. Your other browsers, and the command line's sessions and API tokens, are not signed out.

A sandbox you already have keeps running until E2B ends it, at most 30 minutes after it was created. Signing out leaves the draft in place: to remove it, clear the site's data in your browser's settings.
