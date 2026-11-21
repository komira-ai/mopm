# The tutorial's front end: a guide for its author

This guide is for whoever builds the interactive tutorial's pages at `mopm.dev/tutorial`: a lesson's text beside an
editor and a terminal, both working on a real Linux machine with mopm and Mojo installed. It assumes you know
TypeScript and the browser, and nothing of this repository.

What is already decided and built, in one paragraph: the user signs in with GitHub on the site. Your page asks our
service for a sandbox, and our service creates one on [E2B](https://e2b.dev) with the internet turned off and answers
with that sandbox's address and its access token. From then on your page talks to the sandbox directly with E2B's
JavaScript SDK (`e2b`, pinned at 2.64.0). Our service never sees the user's code or output, and the E2B key that
creates sandboxes never reaches the browser. The design, with every reason, is
[`docs/design/tutorial-sign-in.md`](design/tutorial-sign-in.md); this guide gives the short form and the code.

Every E2B fact here cites E2B's documentation or the types of `e2b` 2.64.0. **Unverified** marks what neither says and
no run has shown, with what would settle it.

## 1. Start in ten minutes

You need Node.js 24 (the repository pins 24.21.0 in `tools/node/pins.toml`) and a clone of this repository.

```sh
cd site
npm ci --ignore-scripts --no-audit --no-fund
npm run build                                    # writes dist/, the site as it is deployed
npm run preview -- --scenario signed-out
```

The preview prints its address, `http://127.0.0.1:<port>/tutorial`; the system picks the port. It serves `dist/` with
the site's real security headers and plays our side of the sign-in and sandbox routes (`site/tools/preview.ts`;
`site/README.md`, "Preview"). Stop it with Ctrl-C and start it again with another scenario:

| scenario | `GET /api/v2/auth/web/session` | `POST /api/v2/tutorial/sandbox` |
|---|---|---|
| `signed-out` | 401 `session_required` | 401 `session_required` |
| `signed-in` | 200, login `alice` and a fixed CSRF value | without a key: 503 `tutorial_unavailable` ("The preview has no E2B_API_KEY"); with one: 201, a real sandbox |
| `csrf-failed` | 200 | 403 `csrf_failed` (sign-out too) |
| `unavailable` | 200 | 503 `tutorial_unavailable`, `Retry-After: 30` |
| `session-expired` | 200 | 401 `session_required` |

The tutorial page is what you are building: the preview serves `/tutorial` from `dist/tutorial.html` when the site's
build wrote one, and the site's 404 page otherwise. Without the page, see the routes from the browser's console on
any page of the preview (the home page at `http://127.0.0.1:<port>/` will do):

```js
const s = await (await fetch('/api/v2/auth/web/session')).json(); s
await (await fetch('/api/v2/tutorial/sandbox', { method: 'POST', headers: { 'X-Mopm-CSRF': s.csrf } })).json()
```

The first line shows the session (or, in `signed-out`, the `session_required` envelope); the second asks for a
sandbox and shows what the table says.

**Real sandboxes, with your own E2B key.** Make an account at E2B (its Hobby plan is enough), create an API key in
its console, and start the preview with it. The key is read from the environment, the way E2B's own tools read it,
and the preview never prints or writes it:

```sh
read -rs E2B_API_KEY && export E2B_API_KEY       # paste the key; it is not echoed
npm run preview -- --scenario signed-in --e2b-template base
```

Now the second console line answers a grant (`sandbox_id`, `access_token`, `envd_version`, `domain`, `expires_at`). The
preview created that sandbox in your E2B account with the same create call as our service (internet off, 30 minutes;
section 6). E2B's `base` template has no mopm or Mojo, so use commands like `echo` or `python3 -c` until you build the
tutorial's template into your account (section 5).

To see that the access token alone drives the sandbox, with no API key, paste the grant into Node's prompt in
`tutorial/template`, the one package of the repository that already depends on `e2b` (it needs Node.js 22.19 or later):

```sh
cd tutorial/template && npm ci --ignore-scripts --no-audit --no-fund && env -u E2B_API_KEY node
```

```js
const { Sandbox } = require('e2b')
const g = /* paste the grant's JSON here */
const s = new Sandbox({ sandboxId: g.sandbox_id, sandboxDomain: g.domain, envdVersion: g.envd_version, envdAccessToken: g.access_token })
await s.commands.run('echo hello from $(hostname)')
```

In Node the SDK reaches the sandbox through E2B's gateway, `https://sandbox.<domain>`, naming the sandbox in a header; in
a browser it uses the sandbox's own address, `https://49983-<sandbox_id>.<domain>` (`ConnectionConfig` in `e2b`
2.64.0). So this shows the token is enough, not that the browser path works: that is checked in a page (section 4).

The preview's answers in each scenario are tested by `site/test/preview.test.ts` on every pull request. The page in a
browser against a real sandbox on beta is the design's task tu-X1, done with the operator.

## 2. The contract in one page

The design's section "For the tutorial's author: what to build against" is the full contract, and
`tests/contract/api-v2/web-auth.json` and `tutorial-sandbox.json` hold an example of every answer. The site already has
the client: `site/src/tutorial/gate.ts`. Use `httpGate(fetch)` in the page and `replayGate(...)` in tests; both decode
every answer and reduce every error to one of four codes.

| call | answers |
|---|---|
| `gate.session()`, `GET /api/v2/auth/web/session` | `{signed_in: true, login, csrf, expires_at}` or `{signed_in: false}` |
| `gate.signInHref('/tutorial/<lesson>')` | the link for "Sign in with GitHub"; GitHub brings the user back to that page |
| `gate.sandbox()`, `POST /api/v2/tutorial/sandbox` | the grant below, or an error code |
| `gate.signOut()`, `POST /api/v2/auth/web/logout` | signed out; a sandbox already held runs on until its `expires_at` |

The grant: `sandbox_id` and `domain` say where the sandbox is (`https://49983-<sandbox_id>.<domain>` is its agent),
`access_token` opens that sandbox and no other, `envd_version` tells the SDK which protocol the agent speaks, and
`expires_at` is the request's time plus the sandbox's timeout, never later than E2B's own end. Keep the grant in memory only, never in `localStorage`.

| code | when | what the page does |
|---|---|---|
| `session_required` | not signed in, or the session ended (7 days, or a sign-out in another tab) | show the sign-in card; keep the user's code in the editor |
| `csrf_failed` | the CSRF value is stale | ask `gate.session()` again and retry once (`askForSandbox` below); then "Reload the page." |
| `invalid_request` | a bug in the page | "Something went wrong. Reload the page." |
| `tutorial_unavailable` | E2B refused or did not answer, or anything the client could not read | "The sandbox service did not answer. Try again in a minute." |

There is no limit on sandboxes: ask whenever the page needs one. The page holds one sandbox at a time, and replaces it a
minute before its `expires_at` or when the SDK says it is gone:

```ts
// tutorial/template/guide/sandbox.ts
// The page's sandbox: the grant of POST /api/v2/tutorial/sandbox as an e2b `Sandbox` that reaches that one sandbox
// with its access token, and renewed before the grant's expires_at or when the sandbox turns out to be gone.
import { Sandbox, SandboxNotRunningError, SandboxUnreachableError } from 'e2b';

/** The 201 of POST /api/v2/tutorial/sandbox (`SandboxGrant` of site/src/tutorial/gate.ts). */
export interface SandboxGrant {
  sandbox_id: string;
  access_token: string;
  envd_version: string;
  domain: string;
  expires_at: string;
}

/** What the gate's `sandbox()` answers: a grant, or a code of the endpoint's error table. */
export type GrantAnswer = SandboxGrant | { error: string };

/** The endpoint refused a sandbox; `code` is the error table's code, which picks the page's message. */
export class GrantRefused extends Error {
  constructor(readonly code: string) {
    super(`the sandbox endpoint answered ${code}`);
    this.name = 'GrantRefused';
  }
}

/** The gate's `sandbox()`, asked once more after a fresh `session()` when the answer is `csrf_failed`. */
export async function askForSandbox(gate: {
  session(): Promise<unknown>;
  sandbox(): Promise<GrantAnswer>;
}): Promise<GrantAnswer> {
  const a = await gate.sandbox();
  if (!('error' in a) || a.error !== 'csrf_failed') return a;
  await gate.session();
  return gate.sandbox();
}

/** A client of the grant's sandbox. It carries the sandbox's own token only: no API key reaches the page. */
export function connect(g: SandboxGrant): Sandbox {
  return new Sandbox({
    sandboxId: g.sandbox_id,
    sandboxDomain: g.domain,
    envdVersion: g.envd_version,
    envdAccessToken: g.access_token,
  });
}

/** Whether an SDK error means the sandbox is gone or out of reach: the page then needs a new one. */
export function sandboxGone(e: unknown): boolean {
  return e instanceof SandboxNotRunningError || e instanceof SandboxUnreachableError;
}

/** A grant this close to its expires_at is replaced before use, so no call starts on a sandbox about to end. */
export const RENEW_BEFORE_MS = 60_000;

/** One sandbox per page, asked for when first needed and replaced when it ends. */
export class PageSandbox {
  private held: { sandbox: Sandbox; until: number } | null = null;
  private pending: Promise<Sandbox> | null = null;

  constructor(
    private readonly ask: () => Promise<GrantAnswer>,
    private readonly now: () => number = Date.now,
    private readonly open: (g: SandboxGrant) => Sandbox = connect,
  ) {}

  /** The sandbox; a new one when none is held or it ends within RENEW_BEFORE_MS. Throws GrantRefused. */
  get(): Promise<Sandbox> {
    const h = this.held;
    if (h !== null && this.now() < h.until - RENEW_BEFORE_MS) return Promise.resolve(h.sandbox);
    // Callers that ask at the same time share one request, so the page never holds two sandboxes.
    this.pending ??= this.renew().finally(() => {
      this.pending = null;
    });
    return this.pending;
  }

  /** When the held sandbox ends (ms since the epoch), or null when none is held. */
  expiresAt(): number | null {
    return this.held === null ? null : this.held.until;
  }

  /** Forgets the sandbox, so the next `get()` asks for a new one. */
  drop(): void {
    this.held = null;
  }

  /**
   * Runs `f` on the sandbox. When the sandbox turns out to be gone, runs `f` once more on a new one. A new sandbox
   * starts from the template, so `f` writes what it needs (the editor's files) before it runs anything.
   */
  async use<T>(f: (s: Sandbox) => Promise<T>): Promise<T> {
    try {
      return await f(await this.get());
    } catch (e) {
      if (!sandboxGone(e)) throw e;
      this.drop();
      return f(await this.get());
    }
  }

  private async renew(): Promise<Sandbox> {
    this.held = null;
    const a = await this.ask();
    if ('error' in a) throw new GrantRefused(a.error);
    this.held = { sandbox: this.open(a), until: Date.parse(a.expires_at) };
    return this.held.sandbox;
  }
}
```

In the page: `const page = new PageSandbox(() => askForSandbox(gate))`, then `await page.use(async (s) => ...)` for each
action. The constructor `new Sandbox({...})` in `connect` is the one SDK entry point that takes the token without an
API key. E2B's own "Agent payments" example builds the SDK client the same way from a sandbox's `envdAccessToken`
("attach the E2B SDK to the new sandbox with the returned `envdAccessToken`. The SDK talks to the sandbox directly",
<https://docs.e2b.dev/use-cases/agent-payments>), while the constructor's comment in `e2b` 2.64.0 marks it
`@internal` and says to use `Sandbox.create`. That is why `e2b` is pinned exactly and these files are type-checked
against it (section 8).

## 3. An editor

The editor's files belong to the browser: the draft lives in `localStorage` (`mopm.tutorial.1`, design section 6), and
the sandbox gets a copy before each run, because a new sandbox starts from the template and knows nothing of the last
one. The template puts each lesson's project at `/home/user/lessons/<id>/` and the files the lesson lets the user edit
are listed in its `lesson.json` (`editable`, paths relative to the project; `tutorial/README.md`).

```ts
// tutorial/template/guide/editor.ts
// The editor's side of the sandbox: list a lesson's files, open one, save the editor's files, and read the whole
// project back (to carry files made in the terminal over to a new sandbox).
import { FileType, NotFoundError, type Sandbox } from 'e2b';

/** Where the template puts each lesson (LESSONS_DIR of tutorial/template/src/definition.ts). */
export const LESSONS_DIR = '/home/user/lessons';

/** The lesson's directory in the sandbox: its project/, synced. */
export function lessonDir(id: string): string {
  return `${LESSONS_DIR}/${id}`;
}

/** Never listed: the lesson's synced environment (`mopm sync` writes it; thousands of files). */
const SKIPPED = new Set(['.mopm']);

/** A file of the lesson, by its path relative to the lesson's directory. */
export interface ProjectEntry {
  path: string;
  size: number;
}

export interface ProjectFile {
  path: string;
  text: string;
}

/** The lesson's files below `dir`, at most `maxDepth` directories deep, sorted by path. Symlinks are left out. */
export async function listProject(s: Sandbox, dir: string, maxDepth = 6): Promise<ProjectEntry[]> {
  const out: ProjectEntry[] = [];
  const walk = async (at: string, rel: string, depth: number): Promise<void> => {
    for (const e of await s.files.list(at, { depth: 1 })) {
      if (SKIPPED.has(e.name)) continue;
      const path = rel === '' ? e.name : `${rel}/${e.name}`;
      if (e.type === FileType.FILE) out.push({ path, size: e.size });
      else if (e.type === FileType.DIR && depth > 1) await walk(e.path, path, depth - 1);
    }
  };
  await walk(dir, '', maxDepth);
  // Paths are unique, so two entries never compare equal.
  return out.sort((a, b) => (a.path < b.path ? -1 : 1));
}

/** One file's text, or null when it does not exist (deleted in the terminal, or a new sandbox without it). */
export async function openFile(s: Sandbox, dir: string, path: string): Promise<string | null> {
  try {
    return await s.files.read(`${dir}/${path}`);
  } catch (e) {
    if (e instanceof NotFoundError) return null;
    throw e;
  }
}

/** Writes the files in one request; missing directories are created. */
export async function saveFiles(s: Sandbox, dir: string, files: readonly ProjectFile[]): Promise<void> {
  if (files.length === 0) return;
  await s.files.write(files.map((f) => ({ path: `${dir}/${f.path}`, data: f.text })));
}

/** Every file of the project up to `maxBytes` each, as text: what to write into the next sandbox. */
export async function readProject(s: Sandbox, dir: string, maxBytes = 256 * 1024): Promise<ProjectFile[]> {
  const out: ProjectFile[] = [];
  for (const e of await listProject(s, dir)) {
    if (e.size > maxBytes) continue;
    const text = await openFile(s, dir, e.path);
    if (text !== null) out.push({ path: e.path, text });
  }
  return out;
}
```

What these calls rest on, all on the sandbox's own agent with the access token (`e2b` 2.64.0, `Filesystem`):

- `files.list(path, {depth})` returns entries with `name`, `type` (`file`, `dir`, `symlink`), `path` and `size`.
  `listProject` lists one level at a time and never enters `.mopm/`, the lesson's synced environment, which holds the
  whole Mojo toolchain.
- `files.read(path)` returns text by default; a missing file is `FileNotFoundError`, a subclass of `NotFoundError`.
- `files.write([{path, data}, ...])` writes several files in one request. The SDK's comment: writing "creates the
  file", "overwrites the file" and "creates the necessary directories" (E2B, "Read & write",
  <https://docs.e2b.dev/filesystem/read-write>).
- Every call waits at most 60 s by default (`requestTimeoutMs`).

For files the user changes in the terminal, `files.watchDir(path, onEvent, {recursive: true})` reports changes, but
E2B says a watch stream is not guaranteed to be long-lived and the client should start a new one when it ends
(<https://docs.e2b.dev/filesystem/watch>). Re-listing when the user switches back to the editor is simpler.

E2B also offers pre-signed upload and download URLs "for unauthorized environments, like a browser"
(<https://docs.e2b.dev/filesystem/upload>). They are not needed here: the page already holds the token.

The editor widget itself is a `<textarea>` per editable file in the design (section 7), with no library. A code editor
library would be a new runtime dependency of the site and its own decision.

## 4. A terminal

**The widget: [xterm.js](https://xtermjs.org)** (`@xterm/xterm`, MIT), a terminal emulator for the browser, with its
`@xterm/addon-fit` to size it to its box. The site does not depend on them yet; the change that builds the page adds
both, pinned exactly, with the same written exception to the site's rule 1 as `e2b` (design section 7). The code
below needs only five members of xterm's `Terminal`, written as an interface so it type-checks without the dependency.
Read from `@xterm/xterm` 6.0.0's typings, they are `cols` and `rows`, `onData` (what the user types or pastes, as a
string), `onResize` (`{cols, rows}`) and `write(data: string | Uint8Array)`; the page's own type-check confirms the
match once it depends on xterm.js.

```ts
// tutorial/template/guide/terminal.ts
// A terminal in the page: a pseudo-terminal (bash) in the sandbox, wired to a terminal widget. Output goes to the
// widget, keystrokes and size changes go to the sandbox, and the page hears once how the terminal ended.
import { CommandExitError, SandboxNotRunningError, type CommandHandle, type Sandbox } from 'e2b';

export interface Disposable {
  dispose(): void;
}

/** What the terminal needs of a widget: the members of xterm.js's `Terminal` it uses. */
export interface TerminalWidget {
  readonly cols: number;
  readonly rows: number;
  onData(listener: (data: string) => void): Disposable;
  onResize(listener: (size: { cols: number; rows: number }) => void): Disposable;
  write(data: string | Uint8Array): void;
}

/** How a terminal ended; the page shows it and offers a new terminal. */
export type TerminalEnd =
  /** The shell exited (the user typed `exit`). The sandbox is still there. */
  | { kind: 'exited'; exitCode: number }
  /** The sandbox is gone (past its expires_at): a new terminal needs a new sandbox. */
  | { kind: 'sandbox-ended' }
  /** The connection could not be brought back. */
  | { kind: 'failed'; error: unknown };

export interface TerminalOptions {
  /** The shell's working directory, e.g. the lesson's directory. */
  cwd: string;
  /** Called once, unless the page closed the terminal itself. */
  onEnd(end: TerminalEnd): void;
  /** How many times a dropped connection is reattached before the terminal counts as failed. */
  maxReconnects?: number;
}

export interface TerminalSession {
  readonly pid: number;
  /** Stops listening to the widget and kills the shell. */
  close(): Promise<void>;
}

export async function openTerminal(s: Sandbox, term: TerminalWidget, o: TerminalOptions): Promise<TerminalSession> {
  const onData = (bytes: Uint8Array) => term.write(bytes);
  // timeoutMs 0: no limit on the session; the default would end the shell after 60 s.
  let handle: CommandHandle = await s.pty.create({ cols: term.cols, rows: term.rows, cwd: o.cwd, timeoutMs: 0, onData });
  const pid = handle.pid;
  const utf8 = new TextEncoder();
  let ended = false;
  let reconnects = o.maxReconnects ?? 3;

  // Each sendInput is its own request: chain them so keystrokes arrive in order. A failed send is dropped; if the
  // sandbox is gone, the end of the stream below says so.
  let input: Promise<void> = Promise.resolve();
  const listeners = [
    term.onData((data) => {
      if (ended) return;
      input = input.then(() => s.pty.sendInput(pid, utf8.encode(data))).catch(() => undefined);
    }),
    term.onResize((size) => {
      if (!ended) s.pty.resize(pid, size).catch(() => undefined);
    }),
  ];

  const finish = (end: TerminalEnd): void => {
    if (ended) return;
    ended = true;
    for (const l of listeners) l.dispose();
    o.onEnd(end);
  };

  const follow = async (): Promise<void> => {
    for (;;) {
      let dropped: unknown;
      try {
        await handle.wait(); // rejects with CommandExitError on a non-zero exit
        finish({ kind: 'exited', exitCode: 0 });
        return;
      } catch (e) {
        dropped = e;
      }
      if (dropped instanceof CommandExitError) {
        finish({ kind: 'exited', exitCode: dropped.exitCode });
        return;
      }
      if (dropped instanceof SandboxNotRunningError) {
        finish({ kind: 'sandbox-ended' });
        return;
      }
      // Anything else: the connection dropped, and the sandbox may still be running the shell. Reattach to it.
      if (ended || reconnects === 0) {
        finish({ kind: 'failed', error: dropped });
        return;
      }
      reconnects -= 1;
      try {
        handle = await s.pty.connect(pid, { onData, timeoutMs: 0 });
      } catch (again) {
        finish(again instanceof SandboxNotRunningError ? { kind: 'sandbox-ended' } : { kind: 'failed', error: again });
        return;
      }
    }
  };
  void follow();

  return {
    pid,
    async close() {
      if (ended) return;
      ended = true;
      for (const l of listeners) l.dispose();
      await handle.kill().catch(() => false);
    },
  };
}
```

In the page: create the `Terminal`, load the fit addon, `open` it in its element and `fit()` it, then
`openTerminal(await page.get(), term, {cwd: lessonDir(id), onEnd})`. Call `fit()` again when the element changes size
(a `ResizeObserver`); xterm then fires `onResize` and the pty follows. Load xterm's stylesheet,
`@xterm/xterm/css/xterm.css`, as a file of the site: the CSP allows styles from the site's own origin only.

**Which pty calls work with the access token alone.** All of them. In `e2b` 2.64.0 the `Pty` class sends every call
(`create`, `connect`, `sendInput`, `streamInput`, `resize`, `kill`) to the sandbox's agent through the client the
constructor builds, which adds the sandbox's `X-Access-Token` header to each request; none of them calls E2B's
platform API, which is what needs the API key. E2B documents the same calls on its "Interactive terminal (PTY)" page
(<https://docs.e2b.dev/sandbox/pty>).

| call | what the code uses it for | source |
|---|---|---|
| `pty.create({cols, rows, cwd, timeoutMs: 0, onData})` | starts `bash -i -l` with `TERM=xterm-256color`; `onData` gets the output as bytes | PTY page; `Pty.create` in 2.64.0 |
| `timeoutMs: 0` | "The default is 60 seconds. For interactive or long-running sessions, set `timeoutMs: 0`" | PTY page |
| `pty.sendInput(pid, bytes)` | keystrokes, UTF-8 encoded, one request each, chained so they keep their order | PTY page; `Pty.sendInput` |
| `pty.streamInput(pid)` | not used: "In browsers, this requires fetch request-body streaming support (Chromium over HTTP/2)" | `Pty.streamInput` in 2.64.0 |
| `pty.resize(pid, {cols, rows})` | the widget's size, in characters | PTY page |
| `pty.connect(pid, {onData, timeoutMs: 0})` | reattach after a dropped connection; the shell kept running | PTY page; "Sandbox lifetime" FAQ |
| `handle.wait()` | how the shell ended: resolves on exit 0, rejects with `CommandExitError` otherwise | `CommandHandle.wait` in 2.64.0 |
| `handle.kill()` | close the terminal (SIGKILL) | PTY page |

**When the connection drops or the sandbox ends.** E2B: "When a stream does drop, the SDK checks the sandbox for you.
If the sandbox was killed or reached its end of life, the error says so (`TimeoutError` in JavaScript, ...). Any other
connection error means the sandbox is still running and only the connection was lost, so reconnect"
(<https://docs.e2b.dev/faq/sandbox-lifetime>). In 2.64.0 the gone case is `SandboxNotRunningError`, a subclass of
`TimeoutError`; `SandboxUnreachableError` means the SDK could not tell. So `openTerminal` ends the terminal as
`sandbox-ended` on `SandboxNotRunningError`, and reattaches to the same shell, up to three times, on anything else.

At `expires_at` E2B ends the sandbox and everything in it. The page knows the time in advance:

- From `PageSandbox.expiresAt()`, show the time left in the terminal's last minutes ("This sandbox ends in 2 minutes.
  Your editor's files are kept.").
- On `sandbox-ended`, print a line in the widget and offer "New terminal": `page.drop()`, `await page.get()`, write the
  editor's files with `saveFiles`, and `openTerminal` again.
- Files the user made only in the terminal are lost with the sandbox. To keep them, call `readProject` in the last
  minute and write the result into the next sandbox too.

**Unverified**, and what settles each:

- Which error `wait()` rejects with at the moment the sandbox ends: `SandboxNotRunningError` by E2B's documentation and
  the SDK's error mapping, `SandboxUnreachableError` if the health probe gets no answer, in which case the reattach
  fails and the terminal ends as `sandbox-ended` or `failed`. Either way the page offers a new terminal. Settle it by
  leaving a terminal open past `expires_at` against the preview with your own key.
- That the SDK's calls to the sandbox work from a browser page on the site's origin under the site's CSP (CORS
  included), and with the sandbox's `allowPublicTraffic: false`. These are design task tu-X1's checks.
- That xterm.js 6.0.0 runs under the site's CSP. Two parts of it: `require-trusted-types-for 'script'` (its published
  `lib/` has no `innerHTML`, which suggests it does), and `style-src 'self'`, which is likely to break it: its
  `lib/xterm.js` creates `<style>` elements and fills them with CSS text for its dimensions and theme, and this CSP
  refuses inline styles. Loading `xterm.css` as a file does not cover those rules. If the preview shows a misdrawn
  terminal, the choice is a CSP change for the tutorial page or another renderer; add it to tu-X1's checks. The
  preview sends the site's CSP, so the first page that loads xterm.js shows which.

## 5. The image

The sandbox runs E2B's template for the tutorial, defined in this repository: `tutorial/template/src/definition.ts`,
with E2B's `Template()` builder (E2B, "Template quickstart", <https://docs.e2b.dev/template/quickstart>). Its steps:

1. E2B's base image (`e2bdev/base`, Debian).
2. mopm, the release of the repository's `VERSION`, downloaded from GitHub, checked against its sha256 and installed
   at `/usr/local/bin/mopm` (as root).
3. `/etc/profile.d/mopm-tutorial.sh` (as root), which turns the Mojo toolchain's telemetry off
   (`MODULAR_TELEMETRY_ENABLED=false`) for every command in the sandbox. With no internet the export can never be
   sent, and with it on every `mopm run` waited about 20 s after its output.
4. For each lesson under `tutorial/lessons/<id>/`: its `project/` copied to `/home/user/lessons/<id>/`, that directory
   and `/home/user/lessons` given to `user` (E2B's copy creates them as root), and `mopm sync --locked` run there as
   `user`, which installs the lesson's pinned Mojo toolchain and packages. The sandbox has no internet, so everything
   a run needs is installed here.
5. `user` and `/home/user` as the sandbox's user and working directory.

**Add a lesson**: a directory `tutorial/lessons/<id>/` with `lesson.md`, `lesson.json` and `project/`
(`tutorial/README.md` says what each holds). The template reads the lessons when it is built, so it needs no change;
`//:tutorial_lessons` checks the lesson on every pull request.

**Add a tool** (a program the lessons use): add a step to `templateDefinition` before the lessons, for example
`.aptInstall(['ripgrep'])` for a Debian package, or `.runCmd('<command>', { user: 'root' })` for anything else (E2B's
template SDK reference, <https://docs.e2b.dev/sdk-reference/js-sdk/v2.64.0/template>). Pin what you download, by version
and sha256, as the mopm step does. `tutorial/template/test/definition.test.ts` lists the steps, so update it in the
same pull request. A template build has its own limits: one hour per build and per command
(<https://docs.e2b.dev/faq/build-limits>), and on the Hobby plan 10 GiB of free disk in the built sandbox, on top of
the image (the same page). The Mojo toolchain is about 229 MiB compressed, the sum of the sizes in
`src/core/toolchain/mojo-1.0.0-linux-64.json` (design section 4).

**Who builds it.** Building needs the team's E2B key, so only an operator builds the stages' templates, never CI:
`npm run template -- --stage <stage> --name <name> --build` in `tutorial/template` (its `README.md`), after which the
template id goes into `tutorial.e2bTemplateId` of `service/config/<stage>.json`. Ask for a rebuild when your lesson or
tool lands.

You can build the same definition into **your own** E2B account to try a change before it lands: the same command with
your key, `--stage beta` and a name of your own (the stage only labels the build). The command prints the steps
without `--build`, so run that first. Then start the preview with `--e2b-template <your template's name>`: E2B's SDK
sends a template's name as its `templateID`, so the preview's create call accepts it. That E2B's build environment
reaches GitHub to download mopm is **unverified** until the first build: E2B's pages do not say whether a build has the
internet, and the template's install step needs it.

## 6. What the token cannot do, and the limits that shape the page

| | why | what the page does |
|---|---|---|
| **No internet inside the sandbox.** `pip install`, `curl` and a `mopm add` that needs the registry fail. | the create call sets `allow_internet_access: false`: "the sandbox cannot make outbound network connections" (<https://docs.e2b.dev/sandbox/internet-access>). The SDK's own calls do not need it. | lessons use only what the template holds; say so if a lesson's text suggests installing something |
| **30 minutes, then the sandbox is gone.** Killed, not paused: files, processes and the shell are lost. | `timeout: 1800`, `autoPause: false`; "A killed sandbox cannot be resumed, and its state is gone" (<https://docs.e2b.dev/faq/sandbox-lifetime>) | ask for a new sandbox (no limit); write the editor's files again (sections 3 and 4) |
| **It cannot extend, pause or kill its sandbox.** | `setTimeout`, `pause`, `kill` and `getInfo` call E2B's platform API with the API key (`e2b` 2.64.0); the page has none | nothing: a closed tab's sandbox ends at its `expires_at` |
| **It reaches no other sandbox.** | the token is issued for one sandbox (<https://docs.e2b.dev/sandbox/secured-access>); connecting to a sandbox by id needs the API key (design section 4) | one grant per sandbox; a new sandbox comes with a new token |
| **No web server the user starts can be opened in the browser.** | the sandbox is created with `allowPublicTraffic: false`: its URLs answer 403 without the traffic access token (<https://docs.e2b.dev/network/restrict-public-access>), which we never hand out | show program output in the terminal; `curl http://localhost:<port>` inside the sandbox still works |
| **Signing out does not end the sandbox.** | the sandbox is E2B's, not part of the session | drop the grant from memory on sign-out |

E2B sees everything the user types and runs, and the user's IP address; the page says so beside Run (design section
4). If E2B refuses sandboxes (its concurrency limit for our plan, an outage), the endpoint answers
`tutorial_unavailable`.

## 7. The hosted-IDE option: a decision for the CEO

The question: instead of an editor and a terminal in our page, run a web IDE (VS Code in the browser:
`openvscode-server` or `code-server`) inside the sandbox and show it in the page.

**What it needs.** A web IDE is a web server in the sandbox, reached at the sandbox's port URL,
`https://<port>-<sandbox_id>.<domain>` (`sandbox.getHost(port)`; <https://docs.e2b.dev/network/public-url>). Its
editor talks to its server over WebSockets. Our sandboxes are created with `allowPublicTraffic: false`, so every port
URL answers 403 unless the request carries the `e2b-traffic-access-token` header
(<https://docs.e2b.dev/network/restrict-public-access>). A browser cannot put that header on the requests an iframe or
a new tab makes, nor on a WebSocket's handshake. E2B documents the token as a header only; whether it accepts it any
other way (a query parameter, a cookie) is **unverified**, and E2B's answer settles it.

**What E2B offers.** Port URLs for any server in a sandbox, public by default or private with the traffic token as
above; WebSockets through them (E2B's SSH guide reaches a sandbox at `wss://8081-<sandbox-id>.e2b.app`,
<https://docs.e2b.dev/sandbox/ssh-access>); and a desktop template that streams a whole Linux desktop to the browser
over noVNC on port 6080 (<https://docs.e2b.dev/template/examples/desktop>). E2B's documentation has no page on running
VS Code or another web IDE in a sandbox.

| | A. Editor and terminal in our page (the design today) | B. Hosted IDE on a public port | C. Hosted IDE through our proxy |
|---|---|---|---|
| how | this guide: the SDK over the access token | the template gains a web IDE; the page starts it over the SDK with a secret it makes up for that sandbox (the IDE's own login), and shows the IDE's port URL | our service forwards the IDE's traffic and adds the traffic token |
| our endpoint | no change | `allowPublicTraffic` becomes `true` (one value of the create call, design section 4) | a new route that carries WebSockets for 30 minutes, plus the traffic token in the grant (an added field) |
| the site | no change beyond the planned `e2b` and xterm.js | CSP gains `frame-src https://*.<E2B domain>`, or the IDE opens in a new tab; a cross-site iframe needs its cookies, which browsers increasingly block | CSP gains our proxy's origin |
| security | as designed: no port a user's program opens is reachable from the internet; only the sandbox's agent answers, and only with the access token (that it still answers under `allowPublicTraffic: false` is tu-X1's check) | every port of every tutorial sandbox answers anyone who has its URL (E2B: "Treat a public URL like a credential"), so a user's program can serve pages from an `e2b.app` address for 30 minutes; the IDE's secret is all that guards its port | the user's code and output pass through our service, which decision 9 of the design rules out; our service carries the traffic |
| works today | yes, apart from tu-X1's checks | not until it is built, and whether the IDE runs offline (extensions baked into the template) is **unverified** | not until it is built |
| what the user gets | an editor (a textarea, or a code editor library later) and a full bash terminal | VS Code: tabs, search, extensions baked in | the same as B |

**Recommendation: A.** It works with the design as it stands, keeps every port a user's program opens closed to the internet,
and gives a learner what a lesson needs: edit a file, run it, use a shell. If lessons later need more of an IDE
(completion, go-to-definition), a code editor library in the page can reach a language server in the sandbox over the
same SDK, as a command with `stdin: true` (`commands.run`, `e2b` 2.64.0), with no public port; that is a sketch,
**unverified**. Choose B only if E2B confirms the traffic token can travel other than as a header (then the page gets
it as an added field of the grant, and the ports stay private), or if the CEO accepts public ports for tutorial
sandboxes. C is not recommended.

## 8. The code in this guide

The three files above are `tutorial/template/guide/sandbox.ts`, `editor.ts` and `terminal.ts`. They live in
`tutorial/template` because that package already pins `e2b` 2.64.0 exactly; the site gains `e2b` in the change
that builds the page. On every pull request that touches them:

- `npm run typecheck` (`//tutorial/template:typecheck`) type-checks them (`tsc` 5.9.3, `strict`) against the pinned
  `e2b`'s types, so an SDK upgrade that changes a call these files make fails the check;
- `test/guide-sandbox.test.ts`, `guide-editor.test.ts` and `guide-terminal.test.ts` run them against fakes of the SDK's
  files and pty modules (`//tutorial/template:test`, and the package's coverage floor);
- `test/guide-doc.test.ts` holds each code block of this guide equal to its file, and the files to importing only
  `e2b` and each other.

Copy them into `site/src/tutorial/` when the page is built; they import nothing from Node.
