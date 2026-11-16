import { AuthError, type NamespaceAccess, type NamespaceStore, type OrgMembers } from '../auth';
import type { TokenServiceV2 } from '../auth/tokens-v2';
import { RegistryError } from '../errors';
import { matchRoute, type CreateTokenRequest, type CreateTokenResponse, type OperationId, type TokenScope } from '../gen/registry-v2';
import type { CreateService } from '../publish/create';
import { jsonBody, MAX_EXCHANGE_BODY_BYTES, routeAuth, STORE_NOT_READY } from './auth-routes';
import type { HttpRequest, HttpResponse, RouterDeps } from './router';
import { getHealth } from './router';
import { routePublish } from './publish-routes';
import { errorViewV2 } from './v2-catalogue';
import { createNamespaceV2, listMembersV2, pollNamespaceV2, removeMemberV2, setMemberV2 } from './v2-namespaces';
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
  /** `listMembers`, `setMember` and `removeMember`. Absent: they answer `unavailable`. */
  members?: OrgMembers;
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

    // The gateway routes only the operations of the generated route table; anything else (and the publish operations when
    // there is no publish wiring) cannot come through it.
    const matched = matchRoute(method, seg);
    if (!matched) throw notFound();
    const params = matched.params as Record<string, string>;

    switch (matched.route.operationId as OperationId) {
      // Operations that never name a package: v1's handlers (device login, listing and revoking tokens).
      case 'startDeviceLogin':
      case 'pollDeviceLogin':
      case 'listTokens':
      case 'revokeToken': {
        const r = await routeAuth({ method, seg, authorization, body: req.body }, auth);
        return respond(r!.status, requestId, r!.body);
      }
      case 'getHealth':
        return respond(200, requestId, getHealth(deps, 'v2'));
      case 'exchangeOidcToken': {
        const a = needAuth();
        return respond(200, requestId, await guarded(() => a.oidc.exchangeV2(jsonBody(req.body, MAX_EXCHANGE_BODY_BYTES))));
      }
      case 'getMe': {
        const a = needAuth();
        const tokens = needV2().tokens ?? (() => { throw unavailable(); })(); // prettier-ignore
        return respond(200, requestId, await guarded(async () => tokens.me(a.authn.userToken(await a.authn.authenticate(authorization)))));
      }
      case 'createToken': {
        const a = needAuth();
        const tokens = needV2().tokens ?? (() => { throw unavailable(); })(); // prettier-ignore
        const t = await guarded(async () => tokens.create(a.authn.freshSession(await a.authn.authenticate(authorization)), jsonBody(req.body) as Partial<CreateTokenRequest>));
        // The one response that carries the secret.
        const created: CreateTokenResponse = { id: t.id, name: t.name, token: t.token, scopes: t.scopes as TokenScope[], packages: t.packages, expires_at: t.expires_at };
        return respond(201, requestId, created);
      }
      case 'createNamespace': {
        const r = await guarded(() => createNamespaceV2(needAuth(), authorization, req.body));
        return respond(r.status, requestId, r.body);
      }
      // `poll` is a reserved namespace: a POST to it is this operation, a GET is a read of the namespace of that name.
      case 'pollNamespace': {
        const r = await guarded(() => pollNamespaceV2(needAuth(), needV2(), authorization, req.body));
        return respond(r.status, requestId, r.body);
      }
      case 'getNamespace':
        return respond(200, requestId, await guarded(() => getNamespaceV2(needV2(), params.namespace!)));
      case 'listMembers': {
        const r = await guarded(() => listMembersV2(needAuth(), needV2(), authorization, params.namespace!));
        return respond(r.status, requestId, r.body);
      }
      case 'setMember': {
        const r = await guarded(() => setMemberV2(needAuth(), needV2(), authorization, params.namespace!, params.user!, req.body));
        return respond(r.status, requestId, r.body);
      }
      case 'removeMember': {
        const r = await guarded(() => removeMemberV2(needAuth(), needV2(), authorization, params.namespace!, params.user!));
        return respond(r.status, requestId, r.body);
      }
      case 'searchPackages':
        return respond(200, requestId, await searchPackagesV2(deps, req.query));
      case 'getPackage':
        return respond(200, requestId, await guarded(() => getPackageV2(deps, needV2(), params.namespace!, params.name!)));
      case 'createPackage': {
        const v = needV2();
        if (!v.creates) throw unavailable();
        const creates = v.creates;
        const made = await guarded(() => creates.create(authorization, params.namespace!, params.name!));
        return respond(made.created ? 201 : 200, requestId, await guarded(() => getPackageV2(deps, v, params.namespace!, params.name!)));
      }
      case 'listVersions':
        return respond(200, requestId, await listVersionsV2(deps, params.namespace!, params.name!, req.query));
      case 'getVersion':
        return respond(200, requestId, await getVersionV2(deps, params.namespace!, params.name!, params.version!));
      default:
        // The publish operations: routePublish answered them above when there is publish wiring.
        throw notFound();
    }
  } catch (err) {
    return failure(err, requestId);
  }
}
