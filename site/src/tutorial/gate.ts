// The tutorial's gate: who is signed in, and a sandbox for a signed-in user (docs/design/tutorial-sign-in.md, "The
// endpoint" and section 7).
//
// The session, the sign-in link and sign-out are the site's (../session.ts, which the header uses on every page); this
// module adds the sandbox route, /api/v2/tutorial/sandbox, on the same terms: same-origin with `credentials:
// 'same-origin'`, the session's CSRF value in `X-Mopm-CSRF`, every answer decoded at run time, and anything that is not
// one of the table's codes `tutorial_unavailable`. fetch is injected: tests and pages built before the API exists use
// `replayGate`, which answers the contract examples (tests/contract/api-v2/web-auth.json and tutorial-sandbox.json)
// through the same decoding. Its names of the session module are re-exported here, so the tutorial imports one module.

import type { SafeHref } from '../doc.js';
import {
  errorCode, type GateError, type GateFetch, type GateTimers, json, LOGOUT_PATH, matching, object, SESSION_PATH, type Session,
  signInHref, time, webSession,
} from '../session.js';

export {
  CSRF_HEADER, decodeSession, errorCode, GATE_ERROR_CODES, GATE_TIMEOUT_MS, type GateError, type GateErrorCode, type GateFetch,
  type GateTimers, isReturnPath, LESSON, LOGOUT_PATH, RETURN_TO_MAX, SESSION_PATH, type Session, type SignedIn, signInHref,
  START_PATH,
} from '../session.js';

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

export const SANDBOX_PATH = '/api/v2/tutorial/sandbox';

// ---- decoding ---------------------------------------------------------------------------------------------------

/** A sandbox id is one DNS label of the sandbox's address (`49983-<sandbox_id>.<domain>`). */
const LABEL = /^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$/;
/** The sandbox's base domain: two or more lower-case DNS labels. */
const DOMAIN = /^[a-z0-9]+(-[a-z0-9]+)*(\.[a-z0-9]+(-[a-z0-9]+)*)+$/;

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

// ---- the real gate ----------------------------------------------------------------------------------------------

/** The gate over the site's own routes: the session client's session and sign-out, and the sandbox route. */
export function httpGate(fetchFn: GateFetch, timeoutMs?: number, timers?: GateTimers): TutorialGate {
  const web = webSession(fetchFn, timeoutMs, timers);
  const unavailable: GateError = { error: 'tutorial_unavailable' };
  return {
    session: web.session,
    async sandbox() {
      const value = await web.csrfValue();
      if (typeof value !== 'string') return value;
      const a = await web.call('POST', SANDBOX_PATH, value);
      if (a === null) return unavailable;
      if (a.status === 201) return decodeGrant(json(a.body)) ?? unavailable;
      const code = errorCode(a.body);
      if (code === 'session_required') web.forgetCsrf();
      return { error: code };
    },
    signInHref,
    signOut: web.signOut,
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
