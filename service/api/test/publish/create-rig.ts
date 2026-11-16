import { Authenticator, HttpGitHubApi, MemoryAuthStore, MemoryNamespaceStore, mintToken, NamespaceAccess, OrgMembers, OrgRegistration } from '../../src/auth';
import type { NamespaceRecord, TokenScope } from '../../src/auth';
import type { AuthServices } from '../../src/http/auth-routes';
import type { RouterDeps } from '../../src/http/router';
import { route } from '../../src/http/router';
import type { V2Deps } from '../../src/http/v2-routes';
import { MemoryStore } from '../../src/memory-store';
import { DEFAULT_PUBLISH_CONFIG, type PublishConfig } from '../../src/publish/config';
import { CreateService } from '../../src/publish/create';
import { MemoryPublishStore } from '../../src/publish/memory';
import { fakeGitHub, TestClock } from '../auth-helpers';
import { MutableFlags } from './harness';

export const ALICE = 1001;
export const BOB = 1002;
export const CAROL = 2001; // a member of komira-ai
export const DAVE = 2002; // an owner of komira-ai
export const ERIN = 2003; // not in komira-ai
export const ORG = 77;

const NS_USER = (namespace: string, github_id: number): NamespaceRecord => ({ namespace, kind: 'user', github_id, created_at: '2026-10-01T00:00:00.000Z' });

/** Registry, auth, namespaces with their member table and the create service, all on memory ports with a hand-moved clock. */
export function createRig(opts: { config?: Partial<PublishConfig>; registry?: MemoryStore } = {}) {
  const clock = new TestClock();
  const registry = opts.registry ?? new MemoryStore();
  const authStore = new MemoryAuthStore();
  const publishes = new MemoryPublishStore();
  const flags = new MutableFlags();
  const namespaces = new MemoryNamespaceStore();
  const access = new NamespaceAccess({ namespaces, users: authStore });
  const members = new OrgMembers({ namespaces, access, users: authStore, now: clock.now });
  // The GitHub of a device flow; its recorded calls show whether anything asked GitHub.
  const gh = fakeGitHub();
  const registration = new OrgRegistration({ store: authStore, namespaces, github: new HttpGitHubApi('Iv1.testclientid', gh.fetchFn), now: clock.now });
  const authn = new Authenticator({ store: authStore, now: clock.now });
  const config = { ...DEFAULT_PUBLISH_CONFIG, ...opts.config };
  const logs: Array<Record<string, unknown>> = [];
  let ids = 0;
  const creates = new CreateService({
    registry,
    auth: authn,
    access,
    publishes,
    config,
    flags,
    now: clock.now,
    newId: () => `id${String(++ids).padStart(4, '0')}`,
    log: (l) => logs.push(l),
  });
  const v2: V2Deps = { access, namespaces, members, creates };
  const services = { authn, registration: async () => registration } as AuthServices;
  const deps: RouterDeps = { store: registry, stage: 'beta', version: 't', commit: 't', readOnly: false, auth: services, v2 };

  const seed = async () => {
    await authStore.upsertUser(ALICE, 'Alice', clock.now().toISOString());
    await authStore.upsertUser(BOB, 'bob', clock.now().toISOString());
    await namespaces.createNamespace(NS_USER('alice', ALICE));
    await namespaces.createNamespace(NS_USER('bob', BOB));
    const at = '2026-10-01T00:00:00.000Z';
    await namespaces.createOrgNamespace(
      { namespace: 'komira-ai', kind: 'org', github_id: ORG, created_at: at, created_by: DAVE },
      { namespace: 'komira-ai', github_id: DAVE, role: 'owner', added_by: DAVE, added_at: at },
    );
    await namespaces.setMember({ namespace: 'komira-ai', github_id: CAROL, role: 'member', added_by: DAVE, added_at: at });
  };

  const mint = async (kind: 'session' | 'api' | 'oidc', f: { github_id?: number; scopes?: TokenScope[]; packages?: string[]; ci_namespace?: string; ci_owner?: string; fresh?: boolean }) => {
    const t = clock.now();
    const m = await mintToken(authStore, {
      kind,
      github_id: f.github_id,
      name: 'test',
      scopes: f.scopes ?? [],
      packages: f.packages ?? [],
      all_current: false,
      ci_namespace: f.ci_namespace,
      ci_owner: f.ci_owner,
      fresh_until: f.fresh === false ? new Date(t.getTime() - 1000).toISOString() : new Date(t.getTime() + 15 * 60_000).toISOString(),
      created_at: t.toISOString(),
      expires_at: new Date(t.getTime() + 86_400_000).toISOString(),
    });
    return `Bearer ${m.secret}`;
  };
  const session = (github_id: number, fresh = true) => mint('session', { github_id, fresh });
  const api = (github_id: number, packages: string[], scopes: TokenScope[] = ['publish']) => mint('api', { github_id, packages, scopes });
  const ci = (ci_namespace: string, packages: string[], extra: { ci_owner?: string; scopes?: TokenScope[] } = {}) =>
    mint('oidc', { ci_namespace, packages, scopes: extra.scopes ?? ['publish'], ci_owner: extra.ci_owner });

  const call = (method: string, path: string, authorization?: string, body?: string) =>
    route({ method, path, query: {}, headers: authorization ? { authorization } : {}, body }, deps, 'req-1');

  return { clock, authn, registry, authStore, publishes, flags, namespaces, gh, access, creates, deps, config, logs, seed, session, api, ci, call };
}

export type Rig = ReturnType<typeof createRig>;
