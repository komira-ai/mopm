import * as fs from 'fs';
import * as path from 'path';
import { AuthError, Authenticator, MemoryAuthStore, OidcExchange, TokenService, type NamespaceAccess, type NamespaceStore } from '../../src/auth';
import { route, type HttpRequest, type RouterDeps } from '../../src/http/router';
import { MemoryStore } from '../../src/memory-store';
import type { Flags } from '../../src/publish/ports';
import type { PublishApi } from '../../src/http/publish-routes';
import type { GroupService } from '../../src/publish/group-service';
import type { ClaimService } from '../../src/publish/claim';
import type { PublishService } from '../../src/publish/service';
import type { CreateService } from '../../src/publish/create';
import type { TokenServiceV2 } from '../../src/auth/tokens-v2';
import type { V2Deps } from '../../src/http/v2-routes';

// Every operation of spec/api/openapi.yaml (each path with each method) is either reached by the router or is on the list of
// operations that are not served yet. This is the router half; infra/stacks/test/spec-gateway.test.ts is the gateway half (the same
// operations must be routed at API Gateway, or the request never gets here). What it catches: a spec operation that has no router
// branch (the CLI's `mopm whoami` called GET /me, which only the fake registry served), or an operation served now that is
// still listed as not served. What it cannot: whether a branch behaves as the spec says (the tests of each route do that).
//
// "Reached" means the router answers anything but route_not_found. The deps below wire every optional service (auth, publish,
// groups, claims) with stubs that no request reaches: the requests carry no token, so each protected operation stops at
// token_missing, and a path with no branch falls through to route_not_found.

const SPEC = path.resolve(__dirname, '../../../../spec/api/openapi.yaml');
const SPEC_V2 = path.resolve(__dirname, '../../../../spec/api/openapi-v2.yaml');

/**
 * The operations the registry does not serve yet: ownership invitations and owner management. The router answers them
 * route_not_found and the gateway has no route for them. When one is implemented, remove it here, in the same commit as its router
 * branch and gateway route (infra/stacks/test/spec-gateway.test.ts lists the same four).
 */
const NOT_SERVED_YET = [
  'GET /me/invitations',
  'POST /me/invitations/{invitation_id}/accept',
  'PUT /packages/{name}/owners',
  'DELETE /packages/{name}/owners/{github_id}',
];

/** `METHOD /path` of every operation under `paths:` of the spec (the file has no YAML parser here; the layout is regular). */
function specOperations(file: string = SPEC): string[] {
  const out: string[] = [];
  let inPaths = false;
  let current: string | undefined;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (/^\S/.test(line)) inPaths = line.startsWith('paths:');
    if (!inPaths) continue;
    const p = /^  (\/\S*):\s*$/.exec(line);
    if (p) current = p[1];
    const m = /^    (get|post|put|delete|patch):\s*$/.exec(line);
    if (m && current) out.push(`${m[1]!.toUpperCase()} ${current}`);
  }
  return out;
}

const SAMPLE: Record<string, string> = { namespace: 'komira-ai', name: 'alpha', version: '1.0.0' };
const concrete = (p: string) => p.replace(/\{(\w+)\}/g, (_, k: string) => SAMPLE[k] ?? 'x1');

const unavailable = async (): Promise<never> => {
  throw new AuthError('unavailable', 'stub');
};

function deps(withV2 = false): RouterDeps {
  const store = new MemoryAuthStore();
  const authn = new Authenticator({ store });
  const flags: Flags = { readOnly: async () => false, groupsFor: async () => true, claimLimitFor: async () => undefined };
  const publish: PublishApi = { auth: authn, service: {} as PublishService, flags, groups: {} as GroupService, claims: {} as ClaimService };
  return {
    store: new MemoryStore(),
    stage: 'beta',
    version: 'v',
    commit: 'c',
    readOnly: false,
    auth: { authn, tokens: new TokenService({ store, ownedPackages: async () => [] }), oidc: { exchange: unavailable } as unknown as OidcExchange, devices: unavailable, registration: unavailable },
    publish,
    ...(withV2 ? { v2: v2Stubs() } : {}),
  };
}

/** The services of /api/v2, as stubs no request reaches: the requests carry no token, so each protected operation stops before them. */
function v2Stubs(): V2Deps {
  return { access: {} as NamespaceAccess, namespaces: {} as NamespaceStore, creates: {} as CreateService, tokens: {} as TokenServiceV2 };
}

async function answer(op: string, prefix = '/api/v1'): Promise<{ status: number; code?: string }> {
  const [method, p] = op.split(' ') as [string, string];
  const req: HttpRequest = { method, path: `${prefix}${concrete(p)}`, query: {}, headers: {}, ...(method === 'GET' || method === 'DELETE' ? {} : { body: '{}' }) };
  const res = await route(req, deps(prefix === '/api/v2'), 'req-spec');
  return { status: res.statusCode, code: res.body ? JSON.parse(res.body).error?.code : undefined };
}

describe('the router serves every operation of the spec', () => {
  const ops = specOperations();
  const served = ops.filter((o) => !NOT_SERVED_YET.includes(o));

  test('the spec is read (an empty list proves nothing), and every not-served entry is an operation of the spec', () => {
    expect(ops.length).toBeGreaterThanOrEqual(25);
    expect(ops).toContain('GET /me');
    expect(ops).toContain('GET /me/tokens');
    expect(ops).toContain('PUT /packages/{name}/{version}/yank');
    for (const o of NOT_SERVED_YET) expect(ops).toContain(o);
  });

  test.each(served)('%s reaches a handler', async (op) => {
    expect(await answer(op)).not.toMatchObject({ code: 'route_not_found' });
  });

  test.each(NOT_SERVED_YET)('%s is still not served (served now: take it off the list, and add its gateway route)', async (op) => {
    expect(await answer(op)).toEqual({ status: 404, code: 'route_not_found' });
  });

  test('the check can fail: a path that is not an operation is route_not_found', async () => {
    expect(await answer('GET /me/nobody')).toEqual({ status: 404, code: 'route_not_found' });
    expect(await answer('POST /me')).toEqual({ status: 404, code: 'route_not_found' });
  });
});

// The v2 half: every operation of spec/api/openapi-v2.yaml is reached under /api/v2 and nothing in it is listed as not served.
describe('the router serves every operation of the /api/v2 spec', () => {
  const ops = specOperations(SPEC_V2);

  test('the spec is read (an empty list proves nothing), and it names the v2 operations and none of the owner model', () => {
    expect(ops.length).toBeGreaterThanOrEqual(20);
    expect(ops).toContain('PUT /packages/{namespace}/{name}');
    expect(ops).toContain('POST /namespaces');
    expect(ops).toContain('GET /namespaces/{namespace}');
    expect(ops).toContain('PUT /packages/{namespace}/{name}/{version}/yank');
    expect(ops.filter((o) => /owners|invitations|claim/.test(o))).toEqual([]);
  });

  test.each(ops)('%s reaches a handler', async (op) => {
    expect(await answer(op, '/api/v2')).not.toMatchObject({ code: 'route_not_found' });
  });

  test('the check can fail: v1 paths with a flat name, and the removed owner and claim operations, are route_not_found', async () => {
    expect(await answer('GET /packages/{name}', '/api/v2')).toEqual({ status: 404, code: 'route_not_found' });
    expect(await answer('POST /packages/{namespace}/{name}/claim', '/api/v2')).toEqual({ status: 404, code: 'route_not_found' });
    expect(await answer('PUT /packages/{namespace}/{name}/owners', '/api/v2')).toEqual({ status: 404, code: 'route_not_found' });
    expect(await answer('DELETE /packages/{namespace}/{name}/owners/{github_id}', '/api/v2')).toEqual({ status: 404, code: 'route_not_found' });
    expect(await answer('GET /me/invitations', '/api/v2')).toEqual({ status: 404, code: 'route_not_found' });
  });
});
