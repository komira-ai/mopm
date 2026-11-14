import { AuthError, type NamespaceAccess, type NamespaceStore, type OrgMembership } from '../auth';
import type { TokenServiceV2 } from '../auth/tokens-v2';
import { RegistryError } from '../errors';
import type { CreateService } from '../publish/create';
import { jsonBody, MAX_EXCHANGE_BODY_BYTES, routeAuth, STORE_NOT_READY } from './auth-routes';
import type { HttpRequest, HttpResponse, RouterDeps } from './router';
import { getHealth } from './router';
import { routePublish } from './publish-routes';
import { errorViewV2 } from './v2-catalogue';
import { createNamespaceV2 } from './v2-namespaces';
import { getNamespaceV2, getPackageV2, getVersionV2, listVersionsV2, searchPackagesV2 } from './v2-reads';

/**
 * `/api/v2` (docs/design/namespaces.md section 8; spec/api/openapi-v2.yaml): every operation that takes or returns a
 * package name takes a full name `<namespace>/<name>`, the path parameters are `{namespace}/{name}`, and the operations
 * that never name a package are v1's. Served beside `/api/v1` by the same function.
 */

export const V2_PREFIX = '/api/v2';

/** What `/api/v2` needs besides the v1 services. Absent from RouterDeps: every v2 path answers `unavailable`. */
export interface V2Deps {
  /** Who may write in a namespace, and `NamespaceInfo`. */
  access: NamespaceAccess;
  namespaces: NamespaceStore;
  /** `createNamespace` binds the App's installation. Absent (no GitHub App configured): it answers `unavailable`. */
  membership?: OrgMembership;
  /** `createPackage` (`PUT`). Absent (no publish wiring): it answers `unavailable`. */
  creates?: CreateService;
  /** `getMe` (`MeV2`) and `createToken` with full names. Absent: those answer `unavailable`. */
  tokens?: TokenServiceV2;
}

function respond(statusCode: number, requestId: string, body?: unknown, extra: Record<string, string> = {}): HttpResponse {
  return {
    statusCode,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-mopm-request-id': requestId, ...extra },
    body: body === undefined ? '' : JSON.stringify(body),
  };
}

function failure(err: unknown, requestId: string): HttpResponse {
  const v = errorViewV2(err);
  if (v.body.error.code === 'internal_error') {
    console.error(JSON.stringify({ level: 'error', requestId, error: String((err as Error)?.stack ?? err) }));
  }
  return respond(v.status, requestId, v.body, v.retryAfter !== undefined ? { 'retry-after': String(v.retryAfter) } : {});
}

/** The segments after /api/v2, decoded; undefined for a path outside it or one that does not decode. */
export function segmentsV2(path: string): string[] | undefined {
  if (path !== V2_PREFIX && !path.startsWith(`${V2_PREFIX}/`)) return undefined;
  try {
    return path.slice(V2_PREFIX.length).split('/').filter(Boolean).map(decodeURIComponent);
  } catch {
    return undefined;
  }
}

const unavailable = () => new AuthError('unavailable', 'The registry is temporarily unavailable.');
const notFound = () => new RegistryError('route_not_found', 'There is no such operation.');

/** Handle one request under /api/v2, or answer undefined for a path outside it. Never throws. */
export async function routeV2(req: HttpRequest, deps: RouterDeps, requestId: string): Promise<HttpResponse | undefined> {
  const seg = segmentsV2(req.path);
  if (!seg) return undefined;
  try {
    // The publish operations (begin, commit, yank, status, groups) parse their own path and answer their own errors.
    if (deps.publish) {
      const published = await routePublish(req, deps.publish, requestId, deps.v2);
      if (published) return published;
    }
    const { method } = req;
    const authorization = req.headers?.authorization;
    const v2 = deps.v2;
    const auth = deps.auth;
    const needV2 = (): V2Deps => {
      if (!v2) throw unavailable();
      return v2;
    };
    const needAuth = () => {
      if (!auth) throw unavailable();
      return auth;
    };
    const guarded = async <T>(op: () => Promise<T>): Promise<T> => {
      try {
        return await op();
      } catch (err) {
        if (STORE_NOT_READY.has((err as { name?: string })?.name ?? '')) {
          console.error(JSON.stringify({ level: 'error', message: 'auth store not ready', error: (err as { name?: string }).name }));
          throw unavailable();
        }
        throw err;
      }
    };

    // Operations that never name a package: v1's handlers (device login, listing and revoking tokens).
    const shared =
      (method === 'POST' && seg.length === 2 && seg[0] === 'auth' && seg[1] === 'device') ||
      (method === 'POST' && seg.length === 3 && seg[0] === 'auth' && seg[1] === 'device' && seg[2] === 'poll') ||
      (method === 'GET' && seg.length === 2 && seg[0] === 'me' && seg[1] === 'tokens') ||
      (method === 'DELETE' && seg.length === 3 && seg[0] === 'me' && seg[1] === 'tokens');
    if (shared) {
      const r = await routeAuth({ method, seg, authorization, body: req.body }, auth);
      return respond(r!.status, requestId, r!.body);
    }

    if (method === 'GET' && seg.length === 1 && seg[0] === 'health') return respond(200, requestId, getHealth(deps, 'v2'));

    if (method === 'POST' && seg.length === 3 && seg[0] === 'auth' && seg[1] === 'oidc' && seg[2] === 'exchange') {
      const a = needAuth();
      return respond(200, requestId, await guarded(() => a.oidc.exchangeV2(jsonBody(req.body, MAX_EXCHANGE_BODY_BYTES))));
    }
    if (method === 'GET' && seg.length === 1 && seg[0] === 'me') {
      const a = needAuth();
      const tokens = needV2().tokens ?? (() => { throw unavailable(); })(); // prettier-ignore
      return respond(200, requestId, await guarded(async () => tokens.me(a.authn.userToken(await a.authn.authenticate(authorization)))));
    }
    if (method === 'POST' && seg.length === 2 && seg[0] === 'me' && seg[1] === 'tokens') {
      const a = needAuth();
      const tokens = needV2().tokens ?? (() => { throw unavailable(); })(); // prettier-ignore
      const t = await guarded(async () => tokens.create(a.authn.freshSession(await a.authn.authenticate(authorization)), jsonBody(req.body) as never));
      // The one response that carries the secret.
      return respond(201, requestId, { id: t.id, name: t.name, token: t.token, scopes: t.scopes, packages: t.packages, expires_at: t.expires_at });
    }

    if (seg[0] === 'namespaces') {
      if (method === 'POST' && seg.length === 1) {
        const r = await guarded(() => createNamespaceV2(needAuth(), needV2(), authorization, req.body));
        return respond(r.status, requestId, r.body);
      }
      if (method === 'GET' && seg.length === 2) return respond(200, requestId, await guarded(() => getNamespaceV2(needV2(), seg[1]!)));
      throw notFound();
    }

    if (seg[0] === 'packages') {
      if (method === 'GET' && seg.length === 1) return respond(200, requestId, await searchPackagesV2(deps, req.query));
      if (method === 'GET' && seg.length === 3) return respond(200, requestId, await guarded(() => getPackageV2(deps, needV2(), seg[1]!, seg[2]!)));
      if (method === 'PUT' && seg.length === 3) {
        const v = needV2();
        if (!v.creates) throw unavailable();
        const creates = v.creates;
        const made = await guarded(() => creates.create(authorization, seg[1]!, seg[2]!));
        return respond(made.created ? 201 : 200, requestId, await guarded(() => getPackageV2(deps, v, seg[1]!, seg[2]!)));
      }
      if (method === 'GET' && seg.length === 4 && seg[3] === 'versions') return respond(200, requestId, await listVersionsV2(deps, seg[1]!, seg[2]!, req.query));
      if (method === 'GET' && seg.length === 4) return respond(200, requestId, await getVersionV2(deps, seg[1]!, seg[2]!, seg[3]!));
    }
    // The gateway routes only the operations above, so this is reached only by a request that cannot come through it.
    throw notFound();
  } catch (err) {
    return failure(err, requestId);
  }
}
