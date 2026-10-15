// What a failed API call means to a page.
//
// The page branches on the error envelope's `code` (spec: `{"error":{"code","message","hint"}}`). A code this build
// does not know, and an answer that is not an envelope (the gateway's own 404 for an unrouted path, say), fall back to
// the generic failure of the status class. `retry-after` is not readable from a page (the API's CORS exposes only
// x-mopm-request-id), so a busy registry gets a generic "try again shortly".

export type ErrorKind = 'notFound' | 'invalid' | 'busy' | 'server' | 'network' | 'timeout';

export interface ApiError {
  kind: ErrorKind;
  /** A sentence for the page. */
  message: string;
  /** The envelope's code, when the answer was an envelope. */
  code?: string;
  /** The envelope's own message and hint (server text: display as text only). */
  detail?: string;
  hint?: string;
  status?: number;
  requestId: string | null;
}

const BY_CODE: Readonly<Record<string, ErrorKind>> = Object.freeze(
  Object.assign(Object.create(null) as Record<string, ErrorKind>, {
    invalid_request: 'invalid',
    invalid_name: 'invalid',
    invalid_version: 'invalid',
    package_not_found: 'notFound',
    version_not_found: 'notFound',
    route_not_found: 'notFound',
    rate_limited: 'busy',
    unavailable: 'busy',
    read_only_mode: 'busy',
    internal_error: 'server',
  }),
);

const MESSAGES: Readonly<Record<ErrorKind, string>> = {
  notFound: 'Not found.',
  invalid: 'The registry did not accept this request.',
  busy: 'The registry is busy; try again shortly.',
  server: 'The registry had a problem answering this request.',
  network: 'The registry could not be reached. Check your connection and try again.',
  timeout: 'The registry took too long to answer. Try again.',
};

/** The kind a status means when the answer carries no code this build knows. */
export function kindOfStatus(status: number): ErrorKind {
  if (status === 404) return 'notFound';
  if (status === 429 || status === 503) return 'busy';
  if (status >= 400 && status < 500) return 'invalid';
  return 'server';
}

interface Envelope {
  code: string;
  message: string;
  hint?: string;
}

function envelope(body: string): Envelope | null {
  let v: unknown;
  try {
    v = JSON.parse(body);
  } catch {
    return null;
  }
  if (typeof v !== 'object' || v === null) return null;
  const e = (v as Record<string, unknown>).error;
  if (typeof e !== 'object' || e === null) return null;
  const { code, message, hint } = e as Record<string, unknown>;
  if (typeof code !== 'string' || typeof message !== 'string') return null;
  return typeof hint === 'string' ? { code, message, hint } : { code, message };
}

/** Maps a non-2xx answer to an ApiError. */
export function fromResponse(status: number, body: string, requestId: string | null): ApiError {
  const env = envelope(body);
  const kind = env && Object.hasOwn(BY_CODE, env.code) ? BY_CODE[env.code] : kindOfStatus(status);
  const err: ApiError = { kind, message: MESSAGES[kind], status, requestId };
  if (env) {
    err.code = env.code;
    err.detail = env.message;
    if (env.hint) err.hint = env.hint;
  }
  return err;
}

/** A 2xx answer whose body this build cannot read. */
export function unreadable(status: number, requestId: string | null): ApiError {
  return { kind: 'server', message: 'The registry sent an answer this page cannot read.', status, requestId };
}

export function networkError(): ApiError {
  return { kind: 'network', message: MESSAGES.network, requestId: null };
}

export function timeoutError(): ApiError {
  return { kind: 'timeout', message: MESSAGES.timeout, requestId: null };
}
