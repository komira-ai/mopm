// The tutorial's gate: who is signed in, and a sandbox for a signed-in user (docs/design/tutorial-sign-in.md, "The
// endpoint" and section 7).
//
// The routes are on the site's own host (/api/v2/auth/web/..., /api/v2/tutorial/sandbox, section 2.1), whatever the
// read API's base is, because the session cookie is host-only: every call is same-origin with `credentials:
// 'same-origin'`, and every POST carries the session's CSRF value in `X-Mopm-CSRF`. fetch is injected: tests and
// pages built before the API exists use `replayGate`, which answers the contract examples
// (tests/contract/api-v2/web-auth.json and tutorial-sandbox.json) through the same decoding.
//
// Every answer is decoded at run time. An error envelope keeps its code when the code is one of the endpoint's table;
// anything else (another code, a body that is not an envelope, such as a CDN's HTML 5xx, an unexpected status, an
// answer that does not decode, no answer at all) is `tutorial_unavailable`, which the page shows as "try again".

import type { SafeHref } from '../doc.js';
import { internalHref } from '../links.js';
import { DOC_SLUG, isCanonicalName, isNamespace, isVersion } from '../routes.js';

/** The error codes of the endpoint's table, each a different thing for the page to do. */
export const GATE_ERROR_CODES = ['session_required', 'csrf_failed', 'invalid_request', 'tutorial_unavailable'] as const;
export type GateErrorCode = (typeof GATE_ERROR_CODES)[number];

export interface GateError {
  error: GateErrorCode;
}

/** A signed-in session: the login, the CSRF value for this session's POSTs, and when the session ends. */
export interface SignedIn {
  signed_in: true;
  login: string;
  csrf: string;
  expires_at: string;
}

/** `GET /api/v2/auth/web/session`: signed in, or signed out. */
export type Session = SignedIn | { signed_in: false };

/** `POST /api/v2/tutorial/sandbox`'s 201: what the browser needs to reach its sandbox, until `expires_at`. */
export interface SandboxGrant {
  sandbox_id: string;
  access_token: string;
  envd_version: string;
  domain: string;
  expires_at: string;
}

export interface TutorialGate {
  /** The session; an error only when the answer was neither a session nor `session_required`. */
  session(): Promise<Session | GateError>;
  /**
   * A new sandbox, with the CSRF value of the last `session()` answer (asked for first when there is none). On
   * `csrf_failed` the page asks `session()` again and retries once.
   */
  sandbox(): Promise<SandboxGrant | GateError>;
  /** The sign-in link that brings the browser back to `returnTo`, a page path of the site; throws for anything else. */
  signInHref(returnTo: string): SafeHref;
  /** Ends this browser's session. A browser that was already signed out counts as signed out. */
  signOut(): Promise<{ signed_out: true } | GateError>;
}

export type GateFetch = (url: string, init: RequestInit) => Promise<Response>;

/** The timer the request deadline runs on (as api.ts's): tests pass a manual one. */
export interface GateTimers {
  set(fn: () => void, ms: number): unknown;
  clear(handle: unknown): void;
}

const REAL_TIMERS: GateTimers = {
  set: (fn, ms) => setTimeout(fn, ms),
  clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/** The edge's origin read timeout (section 2.1): past it the edge answers for the API, so the page stops waiting too. */
export const GATE_TIMEOUT_MS = 30_000;

export const SESSION_PATH = '/api/v2/auth/web/session';
export const LOGOUT_PATH = '/api/v2/auth/web/logout';
export const SANDBOX_PATH = '/api/v2/tutorial/sandbox';
export const START_PATH = '/api/v2/auth/web/start';
export const CSRF_HEADER = 'X-Mopm-CSRF';

// ---- decoding ---------------------------------------------------------------------------------------------------

/** base64url of a SHA-256, unpadded (section 2): 43 characters. */
const CSRF = /^[A-Za-z0-9_-]{43}$/;
/** An RFC 3339 UTC time as the API writes it, e.g. 2026-11-26T12:00:00.000Z. */
const UTC_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?Z$/;
/** A sandbox id is one DNS label of the sandbox's address (`49983-<sandbox_id>.<domain>`). */
const LABEL = /^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$/;
/** The sandbox's base domain: two or more lower-case DNS labels. */
const DOMAIN = /^[a-z0-9]+(-[a-z0-9]+)*(\.[a-z0-9]+(-[a-z0-9]+)*)+$/;

type Obj = Record<string, unknown>;

function object(v: unknown): Obj | null {
  return typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Obj) : null;
}

function matching(o: Obj, k: string, re: RegExp): string | null {
  const v = o[k];
  return typeof v === 'string' && re.test(v) ? v : null;
}

function time(o: Obj, k: string): string | null {
  const v = matching(o, k, UTC_TIME);
  return v !== null && Number.isFinite(Date.parse(v)) ? v : null;
}

/** A 200 of the session route, or null when it is not one (a missing or malformed field). */
export function decodeSession(v: unknown): SignedIn | null {
  const o = object(v);
  if (o === null) return null;
  const login = typeof o.login === 'string' && o.login !== '' ? o.login : null;
  const csrf = matching(o, 'csrf', CSRF);
  const expires = time(o, 'expires_at');
  if (login === null || csrf === null || expires === null) return null;
  return { signed_in: true, login, csrf, expires_at: expires };
}

/** A 201 of the sandbox route, or null when it is not one. */
export function decodeGrant(v: unknown): SandboxGrant | null {
  const o = object(v);
  if (o === null) return null;
  const sandboxId = matching(o, 'sandbox_id', LABEL);
  const token = typeof o.access_token === 'string' && o.access_token !== '' ? o.access_token : null;
  const envd = typeof o.envd_version === 'string' && o.envd_version !== '' ? o.envd_version : null;
  const domain = matching(o, 'domain', DOMAIN);
  const expires = time(o, 'expires_at');
  if (sandboxId === null || token === null || envd === null || domain === null || expires === null) return null;
  return { sandbox_id: sandboxId, access_token: token, envd_version: envd, domain, expires_at: expires };
}

/** The table's code of an error answer's body, or `tutorial_unavailable` for anything else. */
export function errorCode(body: string): GateErrorCode {
  let v: unknown;
  try {
    v = JSON.parse(body);
  } catch {
    return 'tutorial_unavailable';
  }
  const code = object(object(v)?.error)?.code;
  return (GATE_ERROR_CODES as readonly unknown[]).includes(code) ? (code as GateErrorCode) : 'tutorial_unavailable';
}

// ---- return_to ---------------------------------------------------------------------------------------------------

/** The longest `return_to` the start route keeps (mopm_core return_to.rs RETURN_TO_MAX). */
export const RETURN_TO_MAX = 256;
/** A lesson id (section 7). */
export const LESSON = /^[a-z0-9]+(-[a-z0-9]+)*$/;

/**
 * Whether the start route keeps `p` as its `return_to` (mopm_core return_to.rs, the same grammar): a page of the
 * site, `/`, `/search`, `/packages/<namespace>/<name>[/<version>]`, `/docs[/[<slug>[/]]]` or `/tutorial[/<lesson>]`,
 * at most 256 characters, with no query, fragment, control character or backslash. Anything else the route would
 * replace with `/tutorial`, so a page asking for it has a bug.
 */
export function isReturnPath(p: string): boolean {
  if (!p.startsWith('/') || [...p].length > RETURN_TO_MAX || /[\u0000-\u001f\u007f-\u009f\\]/.test(p)) return false;
  const parts = p.split('/').slice(1);
  const [a, b, c, d] = parts;
  switch (parts.length) {
    case 1:
      return a === '' || a === 'search' || a === 'tutorial' || a === 'docs';
    case 2:
      return (a === 'tutorial' && LESSON.test(b)) || (a === 'docs' && (b === '' || DOC_SLUG.test(b)));
    case 3:
      return (a === 'docs' && DOC_SLUG.test(b) && c === '') || (a === 'packages' && isNamespace(b) && isCanonicalName(c));
    case 4:
      return a === 'packages' && isNamespace(b) && isCanonicalName(c) && isVersion(d);
    default:
      return false;
  }
}

/** `/api/v2/auth/web/start?return_to=<returnTo>`; throws when `returnTo` is not a page path of the site. */
export function signInHref(returnTo: string): SafeHref {
  if (!isReturnPath(returnTo)) throw new Error(`signInHref: '${returnTo}' is not a page of the site`);
  return internalHref(`${START_PATH}?return_to=${encodeURIComponent(returnTo)}`);
}

// ---- the real gate ----------------------------------------------------------------------------------------------

interface Answer {
  status: number;
  body: string;
}

/** The gate over the site's own routes. */
export function httpGate(fetchFn: GateFetch, timeoutMs: number = GATE_TIMEOUT_MS, timers: GateTimers = REAL_TIMERS): TutorialGate {
  let csrf: string | null = null;

  /** One same-origin call; null when there was no complete answer (network failure or the deadline). */
  async function call(method: 'GET' | 'POST', path: string, csrfValue: string | null): Promise<Answer | null> {
    const ctl = new AbortController();
    const timer = timers.set(() => ctl.abort(), timeoutMs);
    try {
      const init: RequestInit = { method, mode: 'same-origin', credentials: 'same-origin', cache: 'no-store', signal: ctl.signal };
      if (csrfValue !== null) init.headers = { [CSRF_HEADER]: csrfValue };
      const res = await fetchFn(path, init);
      return { status: res.status, body: await res.text() };
    } catch {
      return null;
    } finally {
      timers.clear(timer);
    }
  }

  function json(body: string): unknown {
    try {
      return JSON.parse(body);
    } catch {
      return undefined;
    }
  }

  const unavailable: GateError = { error: 'tutorial_unavailable' };

  async function session(): Promise<Session | GateError> {
    const a = await call('GET', SESSION_PATH, null);
    if (a === null) return unavailable;
    if (a.status === 200) {
      const s = decodeSession(json(a.body));
      if (s === null) return unavailable;
      csrf = s.csrf;
      return s;
    }
    const code = errorCode(a.body);
    if (code === 'session_required') {
      csrf = null;
      return { signed_in: false };
    }
    return { error: code };
  }

  /** The CSRF value to send, from the last session answer or a new one. */
  async function csrfValue(): Promise<string | GateError> {
    if (csrf !== null) return csrf;
    const s = await session();
    if ('error' in s) return s;
    return s.signed_in ? s.csrf : { error: 'session_required' };
  }

  return {
    session,
    async sandbox() {
      const value = await csrfValue();
      if (typeof value !== 'string') return value;
      const a = await call('POST', SANDBOX_PATH, value);
      if (a === null) return unavailable;
      if (a.status === 201) return decodeGrant(json(a.body)) ?? unavailable;
      const code = errorCode(a.body);
      if (code === 'session_required') csrf = null;
      return { error: code };
    },
    signInHref,
    async signOut() {
      const value = await csrfValue();
      if (typeof value !== 'string') return value.error === 'session_required' ? { signed_out: true } : value;
      const a = await call('POST', LOGOUT_PATH, value);
      if (a === null) return unavailable;
      const code = a.status === 204 ? null : errorCode(a.body);
      if (code === null || code === 'session_required') {
        csrf = null;
        return { signed_out: true };
      }
      return { error: code };
    },
  };
}

// ---- the replaying fake -----------------------------------------------------------------------------------------

/** A recorded answer, as a contract case's `response` holds it: a JSON `body`, or a raw `text` body (an HTML 5xx). */
export interface RecordedAnswer {
  status: number;
  headers?: Record<string, string>;
  body?: unknown;
  text?: string;
}

/** The operations of the contract the gate calls, by their operationId. */
export type GateOperation = 'getWebSession' | 'webLogout' | 'createTutorialSandbox';

/** The answers each operation gives, in order; the last one repeats. */
export type ReplayScript = Partial<Record<GateOperation, readonly RecordedAnswer[]>>;

export interface ReplayedRequest {
  /** The operation the route is, or undefined for a route that is none of the three. */
  operation: GateOperation | undefined;
  method: string;
  url: string;
  init: RequestInit;
}

/** Which operation a request is, by `<method> <path>`. */
const OPERATIONS: ReadonlyMap<string, GateOperation> = new Map([
  [`GET ${SESSION_PATH}`, 'getWebSession'],
  [`POST ${LOGOUT_PATH}`, 'webLogout'],
  [`POST ${SANDBOX_PATH}`, 'createTutorialSandbox'],
]);

/**
 * A gate over a fetch that replays recorded answers (the contract examples, or any answer a test needs): the real
 * gate's requests and decoding, no network. `requests` lists what it was asked, in order. A route with no recorded
 * answer is answered 501 with no envelope, so it reads as `tutorial_unavailable`.
 */
export function replayGate(script: ReplayScript): TutorialGate & { requests: ReplayedRequest[] } {
  const requests: ReplayedRequest[] = [];
  const next = new Map<string, number>();
  const fetchFn: GateFetch = async (url, init) => {
    // The real gate always names its method.
    const method = String(init.method);
    const op = OPERATIONS.get(`${method} ${url}`);
    requests.push({ operation: op, method, url, init });
    const key = String(op);
    const answers = (script as Readonly<Record<string, readonly RecordedAnswer[] | undefined>>)[key];
    if (answers === undefined || answers.length === 0) return new Response('no recorded answer', { status: 501 });
    const i = next.get(key) ?? 0;
    next.set(key, i + 1);
    const a = answers[Math.min(i, answers.length - 1)];
    const body = a.text !== undefined ? a.text : a.body === undefined ? null : JSON.stringify(a.body);
    return new Response(body, { status: a.status, headers: a.headers });
  };
  return Object.assign(httpGate(fetchFn), { requests });
}
