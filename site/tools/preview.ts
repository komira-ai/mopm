// `npm run preview`: the built site (dist/) on 127.0.0.1, with the site's security headers, plus our side of the
// tutorial's contract (docs/design/tutorial-sign-in.md, "Running it locally against the stub"): the session, sign-out
// and sandbox routes, answered as the scenario named on the command line says.
//
//   npm run preview -- --scenario signed-out|signed-in|csrf-failed|unavailable|session-expired [--e2b-template base]
//
// It is a local tool for writing the tutorial pages, run from site/ after `npm run build`. It is compiled to
// build/tools and never copied to dist/ (tools/build.ts ships only src/main.ts and what it imports).
//
// The sandbox route makes the real route's checks, in its order: no Authorization header (400 invalid_request), a
// session (401 session_required), the CSRF value, the exact Origin and `Sec-Fetch-Site: same-origin` (403
// csrf_failed), and no body (400 invalid_request). With E2B_API_KEY in the environment, the signed-in scenario then
// creates a real sandbox: the same create call, with the same body, as section 4 has the function send, through an
// injected fetch. The key is the one setting read from the environment because it is secret material; it is sent to
// E2B only, and never printed, logged or written.

import { randomBytes } from 'crypto';
import { createServer, type IncomingMessage, type ServerResponse } from 'http';
import { existsSync, readFileSync, statSync } from 'fs';
import { extname, join, resolve, sep } from 'path';
import { parseRoute } from '../src/routes';
import { LESSON } from '../src/tutorial/gate';
import { securityHeaders } from './headers';

// ---- scenarios and flags ------------------------------------------------------------------------------------------

export const SCENARIOS = ['signed-out', 'signed-in', 'csrf-failed', 'unavailable', 'session-expired'] as const;
export type Scenario = (typeof SCENARIOS)[number];

export const DEFAULT_TEMPLATE = 'base';

export interface Flags {
  scenario: Scenario;
  e2bTemplate: string;
}

export const USAGE =
  'usage: npm run preview -- --scenario signed-out|signed-in|csrf-failed|unavailable|session-expired [--e2b-template <template id>]';

/** The command line, or what is wrong with it. */
export function parseFlags(argv: readonly string[]): Flags | { error: string } {
  let scenario: string | null = null;
  let template: string | null = null;
  for (let i = 0; i < argv.length; i += 2) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (flag !== '--scenario' && flag !== '--e2b-template') return { error: `unknown argument '${flag}'` };
    if (value === undefined || value.startsWith('--')) return { error: `${flag} needs a value` };
    if (flag === '--scenario') {
      if (scenario !== null) return { error: '--scenario given twice' };
      scenario = value;
    } else {
      if (template !== null) return { error: '--e2b-template given twice' };
      template = value;
    }
  }
  if (scenario === null) return { error: '--scenario is required' };
  if (!(SCENARIOS as readonly string[]).includes(scenario)) return { error: `unknown scenario '${scenario}'` };
  // A template id goes into a JSON body only; still, refuse what no E2B template id looks like.
  if (template !== null && !/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/.test(template)) {
    return { error: `'${template}' is not a template id` };
  }
  return { scenario: scenario as Scenario, e2bTemplate: template ?? DEFAULT_TEMPLATE };
}

// ---- the fake session ---------------------------------------------------------------------------------------------

/** The fixed session of the signed-in scenarios: the contract's example login and CSRF value (web-auth.json). */
export const PREVIEW_LOGIN = 'alice';
export const PREVIEW_CSRF = 'mopm-csrf-example-value-0123456789abcdefghi';
/** A web session lasts 7 days (section 2). */
export const SESSION_SECONDS = 7 * 24 * 60 * 60;

// ---- E2B ----------------------------------------------------------------------------------------------------------

export const E2B_CREATE_URL = 'https://api.e2b.app/v2/sandboxes';
/** A null `domain` in E2B's answer is the stage's E2B domain setting (section 4). */
export const E2B_DOMAIN = 'e2b.app';
/** The sandbox timeout, in seconds (section 4). */
export const SANDBOX_TIMEOUT_SECONDS = 1800;
/** How long the route waits for E2B before answering tutorial_unavailable (section 4). */
export const E2B_DEADLINE_MS = 8_000;
/** The stage name the preview puts in a sandbox's metadata. */
export const PREVIEW_STAGE = 'preview';

/** Section 4's create body, field for field. */
export function e2bCreateBody(templateId: string, requestId: string): unknown {
  return {
    templateID: templateId,
    timeout: SANDBOX_TIMEOUT_SECONDS,
    allow_internet_access: false,
    autoPause: false,
    network: { allowPublicTraffic: false },
    metadata: { mopm_stage: PREVIEW_STAGE, mopm_request: requestId },
  };
}

export type E2bFetch = (url: string, init: { method: string; headers: Record<string, string>; body: string; signal: AbortSignal }) => Promise<Response>;

/** The deadline's timer (as api.ts's): tests fire it by hand. */
export interface Timers {
  set(fn: () => void, ms: number): unknown;
  clear(handle: unknown): void;
}

export const REAL_TIMERS: Timers = {
  set: (fn, ms) => setTimeout(fn, ms),
  clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

interface E2bSandbox {
  sandboxID: string;
  envdAccessToken: string;
  envdVersion: string;
  domain: string;
}

/** E2B's create answer, or null when it lacks what the browser needs (an answer without a token is refused, section 4). */
export function decodeE2bSandbox(v: unknown): E2bSandbox | null {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  const nonEmpty = (k: string): string | null => (typeof o[k] === 'string' && o[k] !== '' ? (o[k] as string) : null);
  const sandboxID = nonEmpty('sandboxID');
  const envdAccessToken = nonEmpty('envdAccessToken');
  const envdVersion = nonEmpty('envdVersion');
  const domain = o.domain === null || o.domain === undefined ? E2B_DOMAIN : nonEmpty('domain');
  if (sandboxID === null || envdAccessToken === null || envdVersion === null || domain === null) return null;
  return { sandboxID, envdAccessToken, envdVersion, domain };
}

// ---- requests and answers -----------------------------------------------------------------------------------------

export interface PreviewRequest {
  method: string;
  /** The request target as sent, path and query. */
  url: string;
  /** Header names in lower case; a header sent twice is joined by ', ' (Node's IncomingMessage.headers, flattened). */
  headers: Readonly<Record<string, string | undefined>>;
  /** How many body bytes came (the routes take none; the bytes themselves are not kept). */
  bodyLength: number;
}

export interface PreviewResponse {
  status: number;
  headers: Record<string, string>;
  body: Buffer;
}

export interface PreviewOptions {
  scenario: Scenario;
  e2bTemplate: string;
  /** E2B_API_KEY, or null: then the signed-in scenario's sandbox route answers tutorial_unavailable. */
  e2bKey: string | null;
  /** The built site. */
  distDir: string;
  /** The port the server listens on: the page's origin is http://127.0.0.1:<port> or http://localhost:<port>. */
  port: number;
  fetch: E2bFetch;
  now: () => Date;
  requestId: () => string;
  timers: Timers;
  /** One line about a sandbox the preview created (its id and expiry; never the token or the key). */
  log: (line: string) => void;
}

/** The connect-src the preview's pages get: the API on their own origin, and E2B's sandboxes (section 2.1). */
export const PREVIEW_CONNECT_SRC = `'self' https://*.${E2B_DOMAIN}`;


/** The response headers of the API's routes on the site host (section 2.1), an answer never cached, and its id. */
function apiHeaders(requestId: string): Record<string, string> {
  const site = securityHeaders(PREVIEW_CONNECT_SRC);
  return {
    'content-security-policy': "default-src 'none'; sandbox; frame-ancestors 'none'",
    'strict-transport-security': site['strict-transport-security'],
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
    'cache-control': 'no-store',
    'x-mopm-request-id': requestId,
  };
}

interface Refusal {
  status: number;
  code: string;
  message: string;
  hint: string;
}

const CHECK_REQUEST = 'Check the request against the API documentation; update mopm if it is old.';
const RETRY_AFTER_SECONDS = 30;

/** The refusals the preview answers with: the contract's status, code, message and hint (web-auth.json, tutorial-sandbox.json). */
export const REFUSALS = {
  sessionRequired: {
    status: 401,
    code: 'session_required',
    message: 'You are not signed in to the website.',
    hint: 'Sign in with GitHub, then try again.',
  },
  csrfFailed: {
    status: 403,
    code: 'csrf_failed',
    message: 'The request did not come from a page of the website.',
    hint: 'Reload the page and try again.',
  },
  authorization: {
    status: 400,
    code: 'invalid_request',
    message: "The request is not valid: the website's routes take no Authorization header.",
    hint: CHECK_REQUEST,
  },
  body: { status: 400, code: 'invalid_request', message: 'The request is not valid: the request takes no body.', hint: CHECK_REQUEST },
  unavailable: {
    status: 503,
    code: 'tutorial_unavailable',
    message: 'The sandbox service did not answer.',
    hint: 'Wait 30 seconds and try again; the Retry-After header says how long.',
  },
  noKey: {
    status: 503,
    code: 'tutorial_unavailable',
    message: 'The preview has no E2B_API_KEY, so it creates no sandboxes.',
    hint: 'Start the preview with E2B_API_KEY set to a key of your own E2B account.',
  },
  routeNotFound: { status: 404, code: 'route_not_found', message: 'There is no such operation.', hint: CHECK_REQUEST },
} as const satisfies Record<string, Refusal>;

function jsonAnswer(status: number, requestId: string, body: unknown, extra: Record<string, string> = {}): PreviewResponse {
  return {
    status,
    headers: { ...apiHeaders(requestId), 'content-type': 'application/json', ...extra },
    body: Buffer.from(JSON.stringify(body)),
  };
}

function refuse(r: Refusal, requestId: string): PreviewResponse {
  const extra: Record<string, string> = r.status === 503 ? { 'retry-after': String(RETRY_AFTER_SECONDS) } : {};
  return jsonAnswer(r.status, requestId, { error: { code: r.code, message: r.message, hint: r.hint } }, extra);
}

// ---- the site's files ---------------------------------------------------------------------------------------------

const CONTENT_TYPES: Readonly<Record<string, string>> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.sh': 'text/plain; charset=utf-8',
};

/**
 * The file of dist/ a path is answered with, relative, or null for the 404 page. As the edge router: `/` is the home
 * page, an app route the app shell, a directory its index.html; and the tutorial's routes (section 7) its shell page,
 * `tutorial.html`, once the tutorial pages build one. The router's redirects of names the registry would normalise are
 * not played.
 */
export function pageFile(distDir: string, path: string): string | null {
  const segments = path.split('/');
  if (segments.some((s) => s === '..' || s === '.') || /[\u0000\\]/.test(path)) return null;
  let rel: string;
  if (path === '/') rel = 'index.html';
  else if (path === '/tutorial' || (segments.length === 3 && segments[1] === 'tutorial' && LESSON.test(segments[2]))) {
    rel = 'tutorial.html';
  } else if (parseRoute(path) !== null) rel = 'app.html';
  else rel = path.slice(1);
  const full = resolve(distDir, rel);
  if (!full.startsWith(distDir + sep)) return null;
  if (!existsSync(full)) return null;
  if (statSync(full).isDirectory()) return existsSync(join(full, 'index.html')) ? join(rel, 'index.html') : null;
  return rel;
}

function fileAnswer(distDir: string, req: PreviewRequest, path: string): PreviewResponse {
  const headers = { ...securityHeaders(PREVIEW_CONNECT_SRC), 'cache-control': 'no-store' };
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return { status: 405, headers: { ...headers, allow: 'GET, HEAD', 'content-type': 'text/plain; charset=utf-8' }, body: Buffer.from('GET or HEAD only\n') };
  }
  let decoded: string | null;
  try {
    decoded = decodeURIComponent(path);
  } catch {
    decoded = null;
  }
  const rel = decoded === null ? null : pageFile(distDir, decoded);
  const status = rel === null ? 404 : 200;
  const file = rel ?? '404.html';
  const ext = extname(file);
  const body = readFileSync(join(distDir, file));
  return {
    status,
    headers: { ...headers, 'content-type': CONTENT_TYPES[ext] ?? 'application/octet-stream' },
    body: req.method === 'HEAD' ? Buffer.alloc(0) : body,
  };
}

// ---- the handler --------------------------------------------------------------------------------------------------

export const SESSION_ROUTE = '/api/v2/auth/web/session';
export const LOGOUT_ROUTE = '/api/v2/auth/web/logout';
export const SANDBOX_ROUTE = '/api/v2/tutorial/sandbox';

/**
 * The preview's answers, one request at a time. A scenario other than `signed-out` starts signed in; a sign-out ends
 * that for the life of the process (start it again to sign in again).
 */
export function previewHandler(o: PreviewOptions): (req: PreviewRequest) => Promise<PreviewResponse> {
  const hosts = [`127.0.0.1:${o.port}`, `localhost:${o.port}`];
  let signedIn = o.scenario !== 'signed-out';

  /** Whether a POST passes the CSRF checks of section 2: the session's value, the exact origin, same-origin fetch. */
  function sameSite(req: PreviewRequest): boolean {
    return (
      req.headers['x-mopm-csrf'] === PREVIEW_CSRF &&
      req.headers.origin === `http://${req.headers.host}` &&
      req.headers['sec-fetch-site'] === 'same-origin'
    );
  }

  /** The checks every cookie-authenticated POST makes, in the real route's order; null when the request passes. */
  function postChecks(req: PreviewRequest, id: string): PreviewResponse | null {
    if (req.headers.authorization !== undefined) return refuse(REFUSALS.authorization, id);
    if (!signedIn || o.scenario === 'session-expired') return refuse(REFUSALS.sessionRequired, id);
    if (o.scenario === 'csrf-failed' || !sameSite(req)) return refuse(REFUSALS.csrfFailed, id);
    if (req.bodyLength > 0) return refuse(REFUSALS.body, id);
    return null;
  }

  async function createSandbox(id: string): Promise<PreviewResponse> {
    if (o.e2bKey === null) return refuse(REFUSALS.noKey, id);
    const sent = o.now();
    const ctl = new AbortController();
    const deadline = new Promise<never>((_, reject) => {
      ctl.signal.addEventListener('abort', () => reject(new Error('E2B did not answer in time')));
    });
    const timer = o.timers.set(() => ctl.abort(), E2B_DEADLINE_MS);
    try {
      const res = await Promise.race([
        o.fetch(E2B_CREATE_URL, {
          method: 'POST',
          headers: { 'X-API-Key': o.e2bKey, 'Content-Type': 'application/json' },
          body: JSON.stringify(e2bCreateBody(o.e2bTemplate, id)),
          signal: ctl.signal,
        }),
        deadline,
      ]);
      const text = await Promise.race([res.text(), deadline]);
      if (res.status < 200 || res.status > 299) {
        o.log(`preview: E2B refused the sandbox (HTTP ${res.status}); answered tutorial_unavailable`);
        return refuse(REFUSALS.unavailable, id);
      }
      let parsed: unknown = null;
      try {
        parsed = JSON.parse(text);
      } catch {
        // not JSON: decodes as no sandbox below
      }
      const sandbox = decodeE2bSandbox(parsed);
      if (sandbox === null) {
        o.log('preview: E2B answered without a sandbox id, access token or envd version; answered tutorial_unavailable');
        return refuse(REFUSALS.unavailable, id);
      }
      const expires = new Date(sent.getTime() + SANDBOX_TIMEOUT_SECONDS * 1000).toISOString();
      o.log(`preview: sandbox ${sandbox.sandboxID} created from template ${o.e2bTemplate}, ends ${expires}`);
      return jsonAnswer(201, id, {
        sandbox_id: sandbox.sandboxID,
        access_token: sandbox.envdAccessToken,
        envd_version: sandbox.envdVersion,
        domain: sandbox.domain,
        expires_at: expires,
      });
    } catch {
      o.log('preview: E2B did not answer; answered tutorial_unavailable');
      return refuse(REFUSALS.unavailable, id);
    } finally {
      o.timers.clear(timer);
    }
  }

  async function api(req: PreviewRequest, path: string): Promise<PreviewResponse> {
    const id = o.requestId();
    const route = `${req.method} ${path}`;
    if (route === `GET ${SESSION_ROUTE}`) {
      if (req.headers.authorization !== undefined) return refuse(REFUSALS.authorization, id);
      if (!signedIn) return refuse(REFUSALS.sessionRequired, id);
      const expires = new Date(o.now().getTime() + SESSION_SECONDS * 1000).toISOString();
      return jsonAnswer(200, id, { login: PREVIEW_LOGIN, csrf: PREVIEW_CSRF, expires_at: expires });
    }
    if (route === `POST ${LOGOUT_ROUTE}`) {
      const refused = postChecks(req, id);
      if (refused !== null) return refused;
      signedIn = false;
      const headers = apiHeaders(id);
      return { status: 204, headers, body: Buffer.alloc(0) };
    }
    if (route === `POST ${SANDBOX_ROUTE}`) {
      const refused = postChecks(req, id);
      if (refused !== null) return refused;
      if (o.scenario === 'unavailable') return refuse(REFUSALS.unavailable, id);
      return createSandbox(id);
    }
    return refuse(REFUSALS.routeNotFound, id);
  }

  return async (req) => {
    // Only this server's own origin: a page elsewhere that resolves its name to 127.0.0.1 is not answered.
    if (req.headers.host === undefined || !hosts.includes(req.headers.host)) {
      return { status: 421, headers: { 'content-type': 'text/plain; charset=utf-8' }, body: Buffer.from(`ask http://127.0.0.1:${o.port}/\n`) };
    }
    if (!req.url.startsWith('/') || req.url.startsWith('//')) {
      return { status: 400, headers: { 'content-type': 'text/plain; charset=utf-8' }, body: Buffer.from('a path is required\n') };
    }
    const path = req.url.split(/[?#]/)[0];
    return path === '/api' || path.startsWith('/api/') ? api(req, path) : fileAnswer(o.distDir, req, path);
  };
}

// ---- the server ---------------------------------------------------------------------------------------------------

export interface Preview {
  /** The tutorial's address on this server, e.g. http://127.0.0.1:41234/tutorial. */
  url: string;
  port: number;
  close(): Promise<void>;
}

function flatten(headers: IncomingMessage['headers']): Record<string, string | undefined> {
  const out: Record<string, string | undefined> = {};
  for (const [k, v] of Object.entries(headers)) out[k] = Array.isArray(v) ? v.join(', ') : v;
  return out;
}

/** Listens on 127.0.0.1, on a port the system picks, and answers through previewHandler. */
export async function startPreview(o: Omit<PreviewOptions, 'port'>): Promise<Preview> {
  let handle: ((req: PreviewRequest) => Promise<PreviewResponse>) | null = null;
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    let bodyLength = 0;
    req.on('data', (chunk: Buffer) => {
      bodyLength += chunk.length;
    });
    req.on('end', () => {
      // A server's IncomingMessage always has a method and a URL.
      const request: PreviewRequest = { method: String(req.method), url: String(req.url), headers: flatten(req.headers), bodyLength };
      void (handle as (r: PreviewRequest) => Promise<PreviewResponse>)(request).then((a) => {
        res.writeHead(a.status, a.headers);
        res.end(a.body);
      });
    });
  });
  await new Promise<void>((done) => server.listen(0, '127.0.0.1', done));
  const port = (server.address() as { port: number }).port;
  handle = previewHandler({ ...o, port });
  return {
    url: `http://127.0.0.1:${port}/tutorial`,
    port,
    close: () => new Promise<void>((done) => server.close(() => done())),
  };
}

// ---- the command --------------------------------------------------------------------------------------------------

export interface MainDeps {
  /** E2B_API_KEY from the environment, if set. */
  e2bKey: string | undefined;
  distDir: string;
  fetch: E2bFetch;
  out(line: string): void;
  err(line: string): void;
  now(): Date;
  requestId(): string;
  timers: Timers;
}

/** site/dist, for this module's directory once compiled: site/build/tools/tools. */
export function distFor(moduleDir: string): string {
  return resolve(moduleDir, '..', '..', '..', 'dist');
}

/** What `npm run preview` runs with: the real environment's key, site/dist, the global fetch and the clock. */
export function defaultDeps(): MainDeps {
  return {
    // S2: the one setting read from the environment, because it is secret material (E2B's own tools read it there).
    e2bKey: process.env.E2B_API_KEY,
    distDir: distFor(__dirname),
    fetch: (url, init) => fetch(url, init),
    out: (line) => process.stdout.write(`${line}\n`),
    err: (line) => process.stderr.write(`${line}\n`),
    now: () => new Date(),
    requestId: () => `req-${randomBytes(6).toString('hex')}`,
    timers: REAL_TIMERS,
  };
}

/** Parses the command line and starts the preview; the exit status (2: a bad command line, 1: no build) or the server. */
export async function main(argv: readonly string[], d: MainDeps): Promise<{ status: number; preview?: Preview }> {
  const flags = parseFlags(argv);
  if ('error' in flags) {
    d.err(`preview: ${flags.error}`);
    d.err(USAGE);
    return { status: 2 };
  }
  if (!existsSync(join(d.distDir, 'index.html')) || !existsSync(join(d.distDir, '404.html'))) {
    d.err(`preview: no site build in ${d.distDir}; run 'npm run build' first`);
    return { status: 1 };
  }
  const key = d.e2bKey !== undefined && d.e2bKey !== '' ? d.e2bKey : null;
  const preview = await startPreview({
    scenario: flags.scenario,
    e2bTemplate: flags.e2bTemplate,
    e2bKey: key,
    distDir: resolve(d.distDir),
    fetch: d.fetch,
    now: d.now,
    requestId: d.requestId,
    timers: d.timers,
    log: d.err,
  });
  d.out(`preview: ${preview.url} (scenario ${flags.scenario})`);
  if (flags.scenario !== 'signed-in') d.out('preview: the sandbox route answers as the scenario says; E2B is not called');
  else if (key === null) d.out('preview: no E2B_API_KEY, so the sandbox route answers tutorial_unavailable');
  else d.out(`preview: sandboxes are created on E2B from template ${flags.e2bTemplate}, internet access off`);
  return { status: 0, preview };
}

/** Runs main when this module is the program (`node build/tools/tools/preview.js ...`), setting the exit status. */
export function runIfMain(
  isMain: boolean,
  proc: { argv: readonly string[]; exitCode?: number | string },
  deps: () => MainDeps,
): Promise<{ status: number; preview?: Preview }> | null {
  if (!isMain) return null;
  return main(proc.argv.slice(2), deps()).then((r) => {
    if (r.status !== 0) proc.exitCode = r.status;
    return r;
  });
}

void runIfMain(require.main === module, process, defaultDeps);
