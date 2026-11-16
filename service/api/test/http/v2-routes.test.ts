import { AuthError, MemoryAuthStore, MemoryNamespaceStore, NamespaceAccess } from '../../src/auth';
import { route, type HttpRequest, type RouterDeps } from '../../src/http/router';
import { errorViewV2 } from '../../src/http/v2-catalogue';
import { segmentsV2 } from '../../src/http/v2-routes';
import { RegistryError } from '../../src/errors';
import { MemoryStore } from '../../src/memory-store';
import { PublishError } from '../../src/publish/errors';
import { audit, rec } from '../helpers';

// The dispatch of /api/v2 through route(): what each operation answers when the service behind it is not wired, when a
// store is not ready, for a path or method the gateway never routes, and for the operations shared with v1.

const access = () => new NamespaceAccess({ namespaces: new MemoryNamespaceStore(), users: new MemoryAuthStore() });
const base = (over: Partial<RouterDeps> = {}): RouterDeps => ({ store: new MemoryStore(), stage: 'beta', version: 'v', commit: 'c', readOnly: false, ...over });
const withV2 = (v2: Partial<NonNullable<RouterDeps['v2']>> = {}, over: Partial<RouterDeps> = {}): RouterDeps =>
  base({ v2: { access: access(), namespaces: new MemoryNamespaceStore(), ...v2 }, ...over });

async function call(deps: RouterDeps, method: string, path: string, over: Partial<HttpRequest> = {}) {
  const res = await route({ method, path, query: {}, ...over }, deps, 'req-v2');
  return { res, body: res.body === '' ? undefined : JSON.parse(res.body) };
}

const UNAVAILABLE = errorViewV2(new AuthError('unavailable', 'x'));
const NOT_FOUND = errorViewV2(new RegistryError('route_not_found', 'x'));
const notReady = (name: string) => Object.assign(new Error('table missing'), { name });
const auth = (over: Record<string, unknown> = {}) =>
  ({
    authn: { authenticate: async () => ({}), userToken: () => 1, freshSession: () => 1 },
    tokens: { list: async () => [], revoke: async () => undefined },
    oidc: { exchangeV2: async () => ({}) },
    devices: async () => ({ start: async () => ({ ok: true }), poll: async () => ({ ok: true }) }),
    ...over,
  }) as never;

describe('segmentsV2', () => {
  test('a path outside /api/v2 and one that does not decode have no segments; the rest are decoded', () => {
    expect(segmentsV2('/api/v1/health')).toBeUndefined();
    expect(segmentsV2('/api/v20/health')).toBeUndefined();
    expect(segmentsV2('/api/v2/packages/%E0%A4%A')).toBeUndefined();
    expect(segmentsV2('/api/v2')).toEqual([]);
    expect(segmentsV2('/api/v2/packages/komira-ai/a%2Db')).toEqual(['packages', 'komira-ai', 'a-b']);
  });

  test('a v2 path that does not decode is left to the v1 router, which does not know it', async () => {
    const { res } = await call(withV2(), 'GET', '/api/v2/packages/%E0%A4%A');
    expect(res.statusCode).toBe(404);
  });
});

describe('services that are not wired answer unavailable', () => {
  test.each([
    ['createNamespace', 'POST', '/api/v2/namespaces', 'no auth', () => withV2()],
    ['createNamespace', 'POST', '/api/v2/namespaces', 'the client id secret absent', () => base({ auth: auth({ registration: async () => { throw new AuthError('unavailable', 'x'); } }) })], // prettier-ignore
    ['pollNamespace', 'POST', '/api/v2/namespaces/poll', 'no auth', () => withV2()],
    ['pollNamespace', 'POST', '/api/v2/namespaces/poll', 'no v2 deps', () => base({ auth: auth() })],
    ['listMembers', 'GET', '/api/v2/namespaces/komira-ai/members', 'no auth', () => withV2()],
    ['listMembers', 'GET', '/api/v2/namespaces/komira-ai/members', 'no members service', () => withV2({}, { auth: auth() })],
    ['setMember', 'PUT', '/api/v2/namespaces/komira-ai/members/bob', 'no auth', () => withV2()],
    ['setMember', 'PUT', '/api/v2/namespaces/komira-ai/members/bob', 'no members service', () => withV2({}, { auth: auth() })],
    ['removeMember', 'DELETE', '/api/v2/namespaces/komira-ai/members/bob', 'no auth', () => withV2()],
    ['removeMember', 'DELETE', '/api/v2/namespaces/komira-ai/members/bob', 'no members service', () => withV2({}, { auth: auth() })],
    ['getNamespace', 'GET', '/api/v2/namespaces/alice', 'no v2 deps', () => base()],
    ['getPackage', 'GET', '/api/v2/packages/alice/pkg', 'no v2 deps', () => base()],
    ['createPackage', 'PUT', '/api/v2/packages/alice/pkg', 'no v2 deps', () => base()],
    ['createPackage', 'PUT', '/api/v2/packages/alice/pkg', 'no creates service', () => withV2()],
    ['getMe', 'GET', '/api/v2/me', 'no auth', () => withV2()],
    ['getMe', 'GET', '/api/v2/me', 'no tokens service', () => withV2({}, { auth: auth() })],
    ['getMe', 'GET', '/api/v2/me', 'no v2 deps', () => base({ auth: auth() })],
    ['createToken', 'POST', '/api/v2/me/tokens', 'no auth', () => withV2()],
    ['createToken', 'POST', '/api/v2/me/tokens', 'no tokens service', () => withV2({}, { auth: auth() })],
    ['exchange', 'POST', '/api/v2/auth/oidc/exchange', 'no auth', () => withV2()],
    ['device login', 'POST', '/api/v2/auth/device', 'no auth', () => withV2()],
    ['device poll', 'POST', '/api/v2/auth/device/poll', 'no auth', () => withV2()],
    ['list tokens', 'GET', '/api/v2/me/tokens', 'no auth', () => withV2()],
    ['revoke token', 'DELETE', '/api/v2/me/tokens/abc', 'no auth', () => withV2()],
  ])('%s (%s %s) with %s', async (_op, method, path, _why, deps) => {
    const { res, body } = await call(deps(), method, path, { body: '{}', headers: { authorization: 'Bearer t' } });
    expect(res.statusCode).toBe(UNAVAILABLE.status);
    expect(body).toEqual(UNAVAILABLE.body);
  });
});

describe('a store that is not ready answers unavailable', () => {
  test.each(['ResourceNotFoundException', 'AccessDeniedException', 'UnrecognizedClientException'])('%s from the exchange', async (name) => {
    const boom = async () => {
      throw notReady(name);
    };
    const deps = withV2({}, { auth: auth({ oidc: { exchangeV2: boom } }) });
    const { res, body } = await call(deps, 'POST', '/api/v2/auth/oidc/exchange', { body: '{}' });
    expect([res.statusCode, body]).toEqual([UNAVAILABLE.status, UNAVAILABLE.body]);
  });

  test('from getMe, createToken, getNamespace and createPackage', async () => {
    const quiet = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      const boom = async () => {
        throw notReady('ResourceNotFoundException');
      };
      const deps = withV2(
        { tokens: { me: boom, create: boom } as never, creates: { create: boom } as never, access: { find: boom } as never },
        { auth: auth() },
      );
      for (const [method, path] of [
        ['GET', '/api/v2/me'],
        ['POST', '/api/v2/me/tokens'],
        ['GET', '/api/v2/namespaces/alice'],
        ['PUT', '/api/v2/packages/alice/pkg'],
      ] as const) {
        const { res, body } = await call(deps, method, path, { body: '{}' });
        expect([path, res.statusCode, body]).toEqual([path, UNAVAILABLE.status, UNAVAILABLE.body]);
      }
    } finally {
      quiet.mockRestore();
    }
  });

  test('any other failure is internal_error, not unavailable', async () => {
    const quiet = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      const boom = async () => {
        throw new Error('boom');
      };
      const deps = withV2({}, { auth: auth({ oidc: { exchangeV2: boom } }) });
      const { res, body } = await call(deps, 'POST', '/api/v2/auth/oidc/exchange', { body: '{}' });
      expect([res.statusCode, body.error.code]).toEqual([500, 'internal_error']);
    } finally {
      quiet.mockRestore();
    }
  });
});

describe('operations the gateway does not route', () => {
  test.each([
    ['GET', '/api/v2'],
    ['GET', '/api/v2/unknown'],
    ['POST', '/api/v2/health'],
    ['GET', '/api/v2/namespaces'],
    ['PUT', '/api/v2/namespaces/alice'],
    ['GET', '/api/v2/namespaces/alice/extra'],
    ['DELETE', '/api/v2/packages/alice/pkg'],
    ['GET', '/api/v2/packages/alice'],
    ['POST', '/api/v2/packages/alice/p/1.0.0/extra'],
    ['GET', '/api/v2/me/other'],
    // The publish operations, when the service has no publish wiring (deps.publish absent).
    ['POST', '/api/v2/packages/alice/p/1.0.0/files'],
    ['POST', '/api/v2/packages/alice/p/1.0.0/publish'],
    ['PUT', '/api/v2/packages/alice/p/1.0.0/yank'],
    ['GET', '/api/v2/publishes/pub1'],
    ['POST', '/api/v2/groups'],
    ['GET', '/api/v2/groups/g1'],
    ['DELETE', '/api/v2/groups/g1'],
    ['POST', '/api/v2/groups/g1/commit'],
    ['PUT', '/api/v2/groups/g1/yank'],
  ])('%s %s is route_not_found', async (method, path) => {
    const { res, body } = await call(withV2(), method, path);
    expect([res.statusCode, body]).toEqual([NOT_FOUND.status, NOT_FOUND.body]);
  });
});

describe('the operations shared with v1 under /api/v2', () => {
  test('device login and poll are served by the v1 handlers and a failure is rendered by the v2 catalogue', async () => {
    const devices = async () => ({
      start: async () => ({ user_code: 'ABCD' }),
      poll: async () => {
        throw new AuthError('stale_session', 'pending');
      },
    });
    const deps = withV2({}, { auth: auth({ devices }) });
    const started = await call(deps, 'POST', '/api/v2/auth/device', { body: '{"client":"mopm"}' });
    expect([started.res.statusCode, started.body]).toEqual([200, { user_code: 'ABCD' }]);
    const polled = await call(deps, 'POST', '/api/v2/auth/device/poll', { body: '{"device_code":"d"}' });
    const expected = errorViewV2(new AuthError('stale_session', 'pending'));
    expect([polled.res.statusCode, polled.body]).toEqual([expected.status, expected.body]);
  });

  test('listing tokens answers the list, and revoking one answers 204 with an empty body', async () => {
    const deps = withV2({}, { auth: auth({ tokens: { list: async () => [{ id: 't1' }], revoke: async () => undefined } }) });
    const listed = await call(deps, 'GET', '/api/v2/me/tokens', { headers: { authorization: 'Bearer t' } });
    expect([listed.res.statusCode, listed.body]).toEqual([200, { tokens: [{ id: 't1' }] }]);
    const revoked = await call(deps, 'DELETE', '/api/v2/me/tokens/t1', { headers: { authorization: 'Bearer t' } });
    expect([revoked.res.statusCode, revoked.res.body]).toEqual([204, '']);
  });

  test('a rejected token on a shared operation is rendered with the v2 catalogue', async () => {
    const reject = async () => {
      throw new AuthError('token_unknown', 'x');
    };
    const deps = withV2({}, { auth: auth({ authn: { authenticate: reject } }) });
    const { res, body } = await call(deps, 'GET', '/api/v2/me/tokens');
    const expected = errorViewV2(new AuthError('token_unknown', 'x'));
    expect([res.statusCode, body]).toEqual([expected.status, expected.body]);
  });
});

describe('errors and results', () => {
  test('a rate limit carries Retry-After; an unknown error is internal_error and leaks nothing', async () => {
    const quiet = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      const limited = withV2({
        creates: {
          create: async () => {
            throw new PublishError('rate_limited', 'slow', {}, 7);
          },
        } as never,
      });
      const a = await call(limited, 'PUT', '/api/v2/packages/alice/pkg');
      expect([a.res.statusCode, a.res.headers['retry-after'], a.body.error.code]).toEqual([429, '7', 'rate_limited']);
      const broken = withV2({
        creates: {
          create: async () => {
            throw new Error('secret table name');
          },
        } as never,
      });
      const b = await call(broken, 'PUT', '/api/v2/packages/alice/pkg');
      expect(b.res.statusCode).toBe(500);
      expect(b.res.body).not.toContain('secret table name');
    } finally {
      quiet.mockRestore();
    }
  });

  test('a value thrown under /api/v1 that is not an Error is internal_error too', async () => {
    const quiet = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      const store = Object.create(new MemoryStore(), {
        getPackage: {
          value: async () => {
            throw 'plain text';
          },
        },
      });
      const { res, body } = await call(base({ store }), 'GET', '/api/v1/packages/some_pkg');
      expect([res.statusCode, body.error.code]).toEqual([500, 'internal_error']);
    } finally {
      quiet.mockRestore();
    }
  });

  test('a value thrown that is not an Error (no name, no stack) is internal_error and is logged as it is', async () => {
    const logged: string[] = [];
    const quiet = jest.spyOn(console, 'error').mockImplementation((line: string) => void logged.push(line));
    try {
      for (const thrown of ['plain text', undefined]) {
        const deps = withV2({
          creates: {
            create: async () => {
              throw thrown;
            },
          } as never,
        });
        const { res, body } = await call(deps, 'PUT', '/api/v2/packages/alice/pkg');
        expect([res.statusCode, body.error.code]).toEqual([500, 'internal_error']);
      }
      expect(logged.map((l) => JSON.parse(l).error)).toEqual(['plain text', 'undefined']);
    } finally {
      quiet.mockRestore();
    }
  });

  test('sort=updated puts packages of the same time in name order, and a yanked version without a reason shows a null one', async () => {
    const store = new MemoryStore();
    const namespaces = new MemoryNamespaceStore();
    await namespaces.createNamespace({ namespace: 'alice', kind: 'user', github_id: 1, created_at: '2026-11-14T00:00:00Z' });
    for (const name of ['alice/ac', 'alice/aa', 'alice/ab']) await store.createPackage({ name, state: 'claimed', created_at: '2026-11-14T00:00:00Z' });
    const deps = withV2({ namespaces, access: new NamespaceAccess({ namespaces, users: new MemoryAuthStore() }) }, { store });
    const listed = await call(deps, 'GET', '/api/v2/packages', { query: { q: 'a', sort: 'updated' } });
    expect(listed.body.packages.map((p: { name: string }) => p.name)).toEqual(['alice/aa', 'alice/ab', 'alice/ac']);
    // The same when the index hands them over in the other order.
    const backwards = Object.create(store, { searchPackages: { value: async (...a: Parameters<MemoryStore['searchPackages']>) => (await store.searchPackages(...a)).reverse() } });
    const again = await call({ ...deps, store: backwards }, 'GET', '/api/v2/packages', { query: { q: 'a', sort: 'updated' } });
    expect(again.body.packages.map((p: { name: string }) => p.name)).toEqual(['alice/aa', 'alice/ab', 'alice/ac']);

    await store.createVersion(rec({ name: 'alice/aa', version: '1.0.0', state: 'yanked' }), audit('alice/aa', 'yank', '1.0.0'));
    const version = await call(deps, 'GET', '/api/v2/packages/alice/aa/1.0.0');
    expect([version.res.statusCode, version.body.state, version.body.yank_reason]).toEqual([200, 'yanked', null]);
  });

  test.each([
    [true, 201],
    [false, 200],
  ])('createPackage with created=%s answers %i and the package body', async (created, status) => {
    const store = new MemoryStore();
    const namespaces = new MemoryNamespaceStore();
    await namespaces.createNamespace({ namespace: 'alice', kind: 'user', github_id: 1, created_at: '2026-11-14T00:00:00Z' });
    await store.createPackage({ name: 'alice/pkg', state: 'claimed', created_at: '2026-11-14T00:00:00Z' });
    const deps = withV2({ namespaces, access: new NamespaceAccess({ namespaces, users: new MemoryAuthStore() }), creates: { create: async () => ({ created }) } as never }, { store });
    const { res, body } = await call(deps, 'PUT', '/api/v2/packages/alice/pkg');
    expect([res.statusCode, body.name, body.namespace.namespace]).toEqual([status, 'alice/pkg', 'alice']);
  });
});
