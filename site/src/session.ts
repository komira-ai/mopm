// The website's session, on every page: who is signed in, the sign-in link and sign-out (docs/design/tutorial-sign-in.md,
// sections 1 and 2). The site header (account.ts) uses it alone; the tutorial's gate (tutorial/gate.ts) builds its
// sandbox call on it, so this module holds nothing of the tutorial's sandbox and no fake, and main.js can ship it.
//
// The routes are on the site's own host (/api/v2/auth/web/..., section 2.1), whatever the read API's base is, because
// the session cookie is host-only: every call is same-origin with `credentials: 'same-origin'`, and every POST carries
// the session's CSRF value in `X-Mopm-CSRF`. fetch is injected.
//
// Every answer is decoded at run time. An error envelope keeps its code when the code is one of the website routes'
// table; anything else (another code, a body that is not an envelope, such as a CDN's HTML 5xx, an unexpected status,
// an answer that does not decode, no answer at all) is `tutorial_unavailable`, which a page shows as "try again".

import type { SafeHref } from './doc.js';
import { internalHref } from './links.js';
import { DOC_SLUG, isCanonicalName, isNamespace, isVersion, LESSON, VERSIONS_SEGMENT } from './routes.js';

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
export const START_PATH = '/api/v2/auth/web/start';
export const CSRF_HEADER = 'X-Mopm-CSRF';

// ---- decoding ---------------------------------------------------------------------------------------------------

/** base64url of a SHA-256, unpadded (section 2): 43 characters. */
const CSRF = /^[A-Za-z0-9_-]{43}$/;
/** An RFC 3339 UTC time as the API writes it, e.g. 2026-11-26T12:00:00.000Z. */
const UTC_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?Z$/;

type Obj = Record<string, unknown>;

/** `v` as a plain object, or null for anything else (an array, null, a scalar). */
export function object(v: unknown): Obj | null {
  return typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Obj) : null;
}

/** The string field `k` of `o` when it matches `re`, else null. */
export function matching(o: Obj, k: string, re: RegExp): string | null {
  const v = o[k];
  return typeof v === 'string' && re.test(v) ? v : null;
}

/** The field `k` of `o` when it is a UTC time as the API writes it, else null. */
export function time(o: Obj, k: string): string | null {
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
/** A lesson id (section 7; src/routes.ts, which the edge router is generated from). */
export { LESSON };

/**
 * Whether the start route keeps `p` as its `return_to` (mopm_core return_to.rs, the same grammar): a page of the
 * site, `/`, `/search`, `/packages/<namespace>/<name>[/<version> or /versions]`, `/docs[/[<slug>[/]]]` or `/tutorial[/<lesson>]`,
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
      return a === 'packages' && isNamespace(b) && isCanonicalName(c) && (d === VERSIONS_SEGMENT || isVersion(d));
    default:
      return false;
  }
}

/** `/api/v2/auth/web/start?return_to=<returnTo>`; throws when `returnTo` is not a page path of the site. */
export function signInHref(returnTo: string): SafeHref {
  if (!isReturnPath(returnTo)) throw new Error(`signInHref: '${returnTo}' is not a page of the site`);
  return internalHref(`${START_PATH}?return_to=${encodeURIComponent(returnTo)}`);
}

// ---- the session client -----------------------------------------------------------------------------------------

/** A complete answer: its status and body. */
export interface Answer {
  status: number;
  body: string;
}

/** The session, sign-out, and what the tutorial's gate builds its POSTs from. */
export interface WebSession {
  /** The session; an error only when the answer was neither a session nor `session_required`. */
  session(): Promise<Session | GateError>;
  /** Ends this browser's session. A browser that was already signed out counts as signed out. */
  signOut(): Promise<{ signed_out: true } | GateError>;
  /** The CSRF value of the last `session()` answer, asked for first when there is none. */
  csrfValue(): Promise<string | GateError>;
  /** Forgets the CSRF value: a POST was answered `session_required`. */
  forgetCsrf(): void;
  /** One same-origin call, with `csrfValue` in the CSRF header when given; null when there was no complete answer. */
  call(method: 'GET' | 'POST', path: string, csrfValue: string | null): Promise<Answer | null>;
}

/** `body` parsed as JSON, or undefined when it is not JSON. */
export function json(body: string): unknown {
  try {
    return JSON.parse(body);
  } catch {
    return undefined;
  }
}

const UNAVAILABLE: GateError = { error: 'tutorial_unavailable' };

/** The session client over the site's own routes. */
export function webSession(fetchFn: GateFetch, timeoutMs: number = GATE_TIMEOUT_MS, timers: GateTimers = REAL_TIMERS): WebSession {
  let csrf: string | null = null;

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

  async function session(): Promise<Session | GateError> {
    const a = await call('GET', SESSION_PATH, null);
    if (a === null) return UNAVAILABLE;
    if (a.status === 200) {
      const s = decodeSession(json(a.body));
      if (s === null) return UNAVAILABLE;
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

  async function csrfValue(): Promise<string | GateError> {
    if (csrf !== null) return csrf;
    const s = await session();
    if ('error' in s) return s;
    return s.signed_in ? s.csrf : { error: 'session_required' };
  }

  return {
    session,
    csrfValue,
    call,
    forgetCsrf() {
      csrf = null;
    },
    async signOut() {
      const value = await csrfValue();
      if (typeof value !== 'string') return value.error === 'session_required' ? { signed_out: true } : value;
      const a = await call('POST', LOGOUT_PATH, value);
      if (a === null) return UNAVAILABLE;
      const code = a.status === 204 ? null : errorCode(a.body);
      if (code === null || code === 'session_required') {
        csrf = null;
        return { signed_out: true };
      }
      return { error: code };
    },
  };
}
