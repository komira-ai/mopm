import { AuthError } from '../auth/errors';
import type { Authenticator, Principal } from '../auth';
import { errorView } from '../publish/catalogue';
import { PublishError, invalidRequest } from '../publish/errors';
import type { Flags } from '../publish/ports';
import type { PublishService } from '../publish/service';
import type { HttpRequest, HttpResponse } from './router';

/** What the publish operations need: who is calling, what they may do, and whether uploads are allowed at all. */
export interface PublishApi {
  auth: Authenticator;
  service: PublishService;
  flags: Flags;
}

const PREFIX = '/api/v1';

function respond(statusCode: number, requestId: string, body: unknown, extra: Record<string, string> = {}): HttpResponse {
  return {
    statusCode,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-mopm-request-id': requestId, ...extra },
    body: JSON.stringify(body),
  };
}

function failure(err: unknown, requestId: string): HttpResponse {
  const v = errorView(err);
  if (v.body.error.code === 'internal_error') {
    console.error(JSON.stringify({ level: 'error', requestId, error: String((err as Error)?.stack ?? err) }));
  }
  return respond(v.status, requestId, v.body, v.retryAfter !== undefined ? { 'retry-after': String(v.retryAfter) } : {});
}

function segments(path: string): string[] | undefined {
  if (!path.startsWith(`${PREFIX}/`)) return undefined;
  try {
    return path.slice(PREFIX.length).split('/').filter(Boolean).map(decodeURIComponent);
  } catch {
    return undefined;
  }
}

function jsonBody(req: HttpRequest): unknown {
  if (req.body === undefined || req.body === '') throw invalidRequest('the body is not a JSON object');
  try {
    return JSON.parse(req.body);
  } catch {
    throw invalidRequest('the body is not valid JSON');
  }
}

/**
 * The four publish operations: PUT /packages/{name}/{version}/yank, POST /packages/{name}/{version}/files, POST /packages/{name}/{version}/publish
 * and GET /publishes/{publish_id}. Returns undefined for any other request, which the read router then handles.
 *
 * Order of checks: read-only mode first (a read-only registry says so to everyone, signed in or not), then the
 * token, then the scope for this package and version, then the request itself.
 */
export async function routePublish(req: HttpRequest, api: PublishApi, requestId: string): Promise<HttpResponse | undefined> {
  const seg = segments(req.path);
  if (!seg) return undefined;
  const isBegin = req.method === 'POST' && seg.length === 4 && seg[0] === 'packages' && seg[3] === 'files';
  const isCommit = req.method === 'POST' && seg.length === 4 && seg[0] === 'packages' && seg[3] === 'publish';
  const isStatus = req.method === 'GET' && seg.length === 2 && seg[0] === 'publishes';
  const isYank = req.method === 'PUT' && seg.length === 4 && seg[0] === 'packages' && seg[3] === 'yank';
  if (!isBegin && !isCommit && !isStatus && !isYank) return undefined;

  try {
    const authorization = req.headers?.authorization;
    if (isStatus) {
      const principal = await api.auth.authenticate(authorization);
      requirePublishScope(principal);
      return respond(200, requestId, await api.service.status(principal, seg[1]!));
    }

    if (isYank) {
      // Not gated by read-only mode: a yank changes no files and is what an owner reaches for in an incident (the fake does the same).
      const principal = await api.auth.authenticate(authorization);
      authorizeYank(api.auth, principal, seg[1]!, seg[2]!);
      return respond(200, requestId, await api.service.setYanked(principal, seg[1]!, seg[2]!, jsonBody(req)));
    }

    let readOnly: boolean;
    try {
      readOnly = await api.flags.readOnly();
    } catch (err) {
      // Writers fail closed: if the switch cannot be read, nothing is accepted.
      console.error(JSON.stringify({ level: 'error', requestId, msg: 'read-only switch unreadable', error: String(err) }));
      throw new PublishError('unavailable', 'The registry is temporarily unavailable.');
    }
    if (readOnly) throw new PublishError('read_only_mode', 'The registry is read-only right now; new uploads are refused.');

    const name = seg[1]!;
    const version = seg[2]!;
    const principal = await api.auth.authenticate(authorization);
    api.auth.publishToken(principal, name, version);
    const body = jsonBody(req);
    if (isBegin) return respond(200, requestId, await api.service.begin(principal, name, version, body));
    return respond(202, requestId, await api.service.commit(principal, name, version, body));
  } catch (err) {
    return failure(err, requestId);
  }
}

/** `yankToken` or `publishToken` (spec: setYanked): an API token with `yank` or `publish`, or a CI token for exactly this version. */
function authorizeYank(auth: Authenticator, p: Principal, name: string, version: string): void {
  try {
    auth.yankToken(p, name);
  } catch (err) {
    if (!(err instanceof AuthError) || err.code !== 'scope_missing') throw err;
    auth.publishToken(p, name, version);
  }
}

/** Status is readable by the caller who made the publish: a token that can publish (an API or CI token). */
function requirePublishScope(p: Principal): void {
  if ((p.kind === 'api' || p.kind === 'oidc') && p.scopes.includes('publish')) return;
  throw new AuthError('scope_missing', "The token does not have the 'publish' scope for 'this publish'.", { scope: 'publish', name: 'this publish' });
}
