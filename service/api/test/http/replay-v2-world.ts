import {
  Authenticator,
  DeviceLogin,
  GithubJwtVerifier,
  HttpGitHubApi,
  HttpGitHubAppApi,
  MemoryMembershipPassStore,
  MemoryNamespaceStore,
  NamespaceAccess,
  OidcExchange,
  OrgMembership,
  TokenService,
  mintToken,
  type CiPublisher,
  type NamespaceRecord,
  type TokenScope,
  type TrustedPublisher,
} from '../../src/auth';
import type { PackageRecord } from '../../src/types';
import type { AuthServices } from '../../src/http/auth-routes';
import { packagesInFrom } from '../../src/http/lambda';
import { route, type HttpRequest, type HttpResponse, type RouterDeps, type Stage } from '../../src/http/router';
import type { V2Deps } from '../../src/http/v2-routes';
import { TokenServiceV2 } from '../../src/auth/tokens-v2';
import { Metrics } from '../../src/metrics';
import { CreateService } from '../../src/publish/create';
import { GroupService } from '../../src/publish/group-service';
import { MemoryPresigner, MemoryQueue } from '../../src/publish/memory';
import { fakeGitHub, goodClaims, newKey, signJwt } from '../auth-helpers';
import { APP_ID, APP_PRIVATE_KEY, fakeGitHubApp } from '../github-app-fake';
import { Harness } from '../publish/harness';

// The registry as /api/v2 sees it, on memory ports, for the replay of tests/contract/api-v2: the router with its auth, publish,
// group and namespace services, a fake GitHub (device login) and a fake GitHub App (organizations), and a clock that only the
// recipes move. The fixed state every recipe starts from is `seedWorld`; a recipe adds what its case describes.

/** The instant every recipe starts at. */
export const START = Date.parse('2026-11-14T12:00:00Z');

/** Accounts. ALICE owns the user namespace `alice` and is an admin of `komira-ai`; BOB owns `bob`; CAROL is a member of `komira-ai`. */
export const ALICE = 1001;
export const BOB = 1002;
export const CAROL = 2001;
export const DAVE = 2002; // an admin of komira-ai, with no user namespace
export const ERIN = 2003; // in no organization; her login `alice` is held by ALICE
export const OCTO = 4242; // the account of the fake device login
/** Organizations: `komira-ai` has the App installed, `frozen-org` has not, `acme-labs` is not a namespace yet but has the App installed. */
export const ORG = 77;
export const INST = 5555;
export const FROZEN_ORG = 88;
export const NEW_ORG = 99;
export const NEW_INST = 6666;

/** The CI identity of the publisher of `komira-ai`. */
export const CI_REPO = '111';
export const CI_WORKFLOW = '.github/workflows/release.yml';
const CI_KEY = newKey('replay-v2');

const at = () => new Date(START).toISOString();

const CONFIGURED: CiPublisher = {
  repository_id: CI_REPO,
  repository_owner_id: String(ORG),
  workflow: CI_WORKFLOW,
  ref: 'refs/heads/main',
  job_workflow_ref: `komira-ai/tools/${CI_WORKFLOW}@refs/heads/main`,
  events: ['push'],
  environment: 'prod',
  namespace: 'komira-ai',
};

export interface WorldOptions {
  stage?: Stage;
  readOnly?: boolean;
  /** No GitHub App wiring: createNamespace is `unavailable`. */
  app?: boolean;
}

export type World = Awaited<ReturnType<typeof buildWorld>>;

export async function buildWorld(opts: WorldOptions = {}) {
  const h = new Harness();
  h.clock.t = START;
  const now = h.clock.now;
  const gh = fakeGitHubApp(now);
  const device = fakeGitHub();
  const namespaces = new MemoryNamespaceStore();
  const app = new HttpGitHubAppApi({ appId: APP_ID, privateKey: APP_PRIVATE_KEY }, now, gh.fetchFn);
  const membership = opts.app === false ? undefined : new OrgMembership({ app, passes: new MemoryMembershipPassStore(), now });
  const access = new NamespaceAccess({ namespaces, users: h.authStore, ...(membership ? { membership } : {}) });
  h.namespaces = access;
  const v2: V2Deps = { access, namespaces, ...(membership ? { membership } : {}) };
  h.v2 = v2;
  h.build();
  h.flags.groupsAll = true;
  // The group routes with the group queue a commit and a yank send to (the harness builds none).
  h.deps.publish!.groups = new GroupService({
    registry: h.registry,
    namespaces: access,
    publishes: h.publishes,
    objects: h.objects,
    presigner: new MemoryPresigner(),
    config: h.config,
    groupQueue: new MemoryQueue(),
    now,
    metrics: new Metrics(() => undefined),
  });

  const authn = new Authenticator({ store: h.authStore, now });
  let createdIds = 0;
  v2.creates = new CreateService({
    registry: h.registry,
    auth: authn,
    access,
    publishes: h.publishes,
    config: h.config,
    flags: h.flags,
    now,
    newId: () => `id${String(++createdIds).padStart(4, '0')}`,
  });
  v2.tokens = new TokenServiceV2({ store: h.authStore, access, packagesIn: packagesInFrom(h.registry), now });
  const verifier = new GithubJwtVerifier({ audiences: ['mopm.dev'], now, jwks: async () => ({ keys: [CI_KEY.jwk] }) });
  const services: AuthServices = {
    authn,
    tokens: new TokenService({ store: h.authStore, ownedPackages: async () => [], now }),
    oidc: new OidcExchange({ store: h.authStore, verifier, now, registry: h.registry, namespaces, ciPublishers: [CONFIGURED] }),
    devices: async () => new DeviceLogin({ store: h.authStore, namespaces, github: new HttpGitHubApi('Iv1.testclientid', device.fetchFn), now }),
  };
  const deps: RouterDeps = { ...h.deps, stage: opts.stage ?? 'beta', version: 'test', commit: 'test', readOnly: opts.readOnly ?? false, auth: services, v2 };

  const send = (req: HttpRequest): Promise<HttpResponse> => route(req, deps, 'req-replay');

  const mint = async (
    kind: 'session' | 'api' | 'oidc',
    f: { github_id?: number; scopes?: TokenScope[]; packages?: string[]; ci_namespace?: string; fresh?: boolean; ttlMs?: number; version?: string; createdAt?: string },
  ): Promise<{ bearer: string; id: string }> => {
    const t = h.clock.now();
    const m = await mintToken(h.authStore, {
      kind,
      github_id: f.github_id,
      name: kind === 'session' ? 'login (mopm 0.1.0)' : 'replay',
      scopes: f.scopes ?? [],
      packages: f.packages ?? [],
      all_current: false,
      ...(f.ci_namespace ? { ci_namespace: f.ci_namespace } : {}),
      ...(f.version ? { version: f.version, versions: Object.fromEntries((f.packages ?? []).map((n) => [n, f.version!])) } : {}),
      ...(kind === 'session' ? { fresh_until: new Date(t.getTime() + (f.fresh === false ? -1000 : 15 * 60_000)).toISOString() } : {}),
      // Tokens listed together get distinct times: the list orders by created_at, then by the random id.
      created_at: f.createdAt ?? t.toISOString(),
      expires_at: new Date(t.getTime() + (f.ttlMs ?? 30 * 86_400_000)).toISOString(),
    });
    return { bearer: `Bearer ${m.secret}`, id: m.record.id };
  };
  /** The bearer value of a login session (fresh for fifteen minutes unless `fresh` is false). */
  const session = async (github_id: number, fresh = true) => (await mint('session', { github_id, fresh })).bearer;
  const api = async (github_id: number, packages: string[], scopes: TokenScope[] = ['publish']) => (await mint('api', { github_id, packages, scopes })).bearer;
  /** A CI token of a publisher of `namespace`, minted for exactly these full names at one version. */
  const ci = async (ci_namespace: string, packages: string[], version = '1.0.0') =>
    (await mint('oidc', { scopes: ['publish'], packages, ci_namespace, version, ttlMs: 600_000 })).bearer;
  /** A signed CI identity token of the publisher of `komira-ai`, as GitHub issues it for the workflow on main. */
  const jwt = (over: Record<string, unknown> = {}) =>
    signJwt(
      CI_KEY,
      goodClaims(h.clock, {
        repository_id: CI_REPO,
        repository_owner_id: String(ORG),
        job_workflow_ref: `komira-ai/tools/${CI_WORKFLOW}@refs/heads/main`,
        environment: 'prod',
        ...over,
      }),
    );

  /** The fixed state: accounts, namespaces, the fake App's installations and memberships. No package yet. */
  const seed = async () => {
    const orgs = [{ github_id: ORG, login: 'komira-ai', role: 'admin' as const }];
    await h.authStore.upsertUser(ALICE, 'Alice', at(), true, orgs);
    await h.authStore.upsertUser(BOB, 'bob', at(), true);
    await h.authStore.upsertUser(CAROL, 'carol', at(), true, [{ github_id: ORG, login: 'komira-ai', role: 'member' }]);
    await h.authStore.upsertUser(DAVE, 'dave', at(), true, orgs);
    await h.authStore.upsertUser(ERIN, 'alice', at(), true);
    const rows: NamespaceRecord[] = [
      { namespace: 'alice', kind: 'user', github_id: ALICE, created_at: at() },
      { namespace: 'bob', kind: 'user', github_id: BOB, created_at: at() },
      { namespace: 'komira-ai', kind: 'org', github_id: ORG, created_at: at(), installation_id: INST },
      { namespace: 'frozen-org', kind: 'org', github_id: FROZEN_ORG, created_at: at() },
    ];
    for (const r of rows) await namespaces.createNamespace(r);
    gh.install(INST, { id: ORG, login: 'komira-ai' });
    gh.user(ALICE, 'alice').member('komira-ai', 'alice', ALICE, 'admin');
    gh.user(CAROL, 'carol').member('komira-ai', 'carol', CAROL, 'member');
    gh.user(DAVE, 'dave').member('komira-ai', 'dave', DAVE, 'admin');
    gh.user(ERIN, 'erin');
    const publisher: TrustedPublisher = {
      id: 'tp1',
      name: 'komira-ai/',
      repository_id: CI_REPO,
      repository_owner_id: String(ORG),
      workflow: CI_WORKFLOW,
      environment: 'prod',
      added_by: ALICE,
      added_at: at(),
    };
    await h.authStore.addTrustedPublisher(publisher);
  };

  /** A package row, as a create leaves it (`claimed`) or after a publish (`active`). */
  const makePackage = (name: string, state: 'claimed' | 'active' = 'claimed', extra: Partial<PackageRecord> = {}) =>
    h.registry.createPackage({ name, state, created_at: at(), ...extra });

  /** What a recipe's setup made that the request has to name: the uploads begun and the publish committed. */
  const ids: { uploads: string[]; publish?: string } = { uploads: [] };
  const world = { ids, h, gh, device, namespaces, access, v2, deps, authn, services, send, mint, session, api, ci, jwt, seed, makePackage, clock: h.clock };
  await seed();
  return world;
}
