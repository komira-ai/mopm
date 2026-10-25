import { GithubJwtVerifier, mintToken, OidcExchange, type CiPublisher } from '../../src/auth';
import type { PublishConfig } from '../../src/publish/config';
import { flagsFor } from '../../src/publish/wiring';
import { groupIdFor } from '../../src/publish/group-service';
import { quarantineKeyFor } from '../../src/publish/group-keys';
import { actorOf } from '../../src/publish/service';
import { RIGS, type Rig } from '../group-rig';
import { goodClaims, newKey, signJwt } from '../auth-helpers';
import { Chain } from './group-chain-env';
import { errorCode, GroupEnv, json, type MemberBody } from './group-env';
import { FakeDoc } from './fake-doc';
import { pkg, type Pkg } from './harness';

// A CI identity that the beta stage trusts by configuration creates a group, commits it and yanks it, with the beta groups
// policy wired as the API function wires it (flagsFor over MOPM_GROUPS_POLICY). What these prove: the identity's token creates a
// group only for packages its own token covers and its identity owns, as one stable actor whichever token it holds; every other
// caller (another CI identity, an account, a registered-publisher token) is refused with nothing written; the lifecycle after
// the create (commit, validator, chain, yank) works for the group and for no other caller. What they do not: real GitHub tokens,
// API Gateway or the deployed stage (service/infra/stacks pins which stages carry the policy).

const key = newKey('k1');
const OWNER = 'gh-repo:1376408823';
const ACTOR = `ci:${OWNER}`;
const OTHER_OWNER = 'gh-repo:999';
const OTHER_ACTOR = `ci:${OTHER_OWNER}`;
const POLICY = JSON.stringify({ mode: 'allow', actors: [ACTOR] });
const PUBLISHER: CiPublisher = {
  repository_id: '1376408823',
  repository_owner_id: '305577347',
  workflow: '.github/workflows/release.yml',
  ref: 'refs/heads/main',
  events: ['push', 'workflow_dispatch'],
  environment: 'beta',
};
const REASON = 'the release is broken';

const memberOf = (p: Pkg): MemberBody => ({ name: p.name, version: p.version, files: [{ subdir: p.subdir, filename: p.filename, sha256: p.sha256, size: p.bytes.length }] });

describe.each(RIGS)('a CI identity and groups on the beta configuration: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  let chain: Chain;
  let oidc: OidcExchange;
  let widgets: Pkg;
  let gadgets: Pkg;

  /** The wiring of the beta function: the real flags over the policy variable and an empty config table, the exchange with the configured publisher. */
  function build(config: Partial<PublishConfig> = {}, policy: string | null = POLICY) {
    rig = make();
    env = new GroupEnv(rig, config);
    chain = new Chain(env);
    env.deps.publish!.flags = flagsFor(policy === null ? {} : { MOPM_GROUPS_POLICY: policy }, new FakeDoc({ 'mopm-beta-config': 'key' }) as never, 'beta');
    oidc = new OidcExchange({
      store: env.authStore,
      verifier: new GithubJwtVerifier({ audiences: ['beta.mopm.dev'], now: env.clock.now, jwks: async () => ({ keys: [key.jwk] }) }),
      now: env.clock.now,
      ciPublishers: [PUBLISHER],
      registry: rig.store,
    });
  }
  beforeEach(() => {
    build();
    widgets = pkg({ name: 'widgets', subdir: 'noarch' });
    gadgets = pkg({ name: 'gadgets', subdir: 'noarch' });
  });

  /** A token of the configured identity from a real exchange: it creates the packages it names and is good for exactly them at those versions. */
  async function exchange(pkgs: Pkg[]): Promise<string> {
    const jwt = signJwt(
      key,
      goodClaims(env.clock, {
        aud: 'beta.mopm.dev',
        repository: 'komira-ai/komira',
        repository_id: '1376408823',
        repository_owner_id: '305577347',
        workflow_ref: 'komira-ai/komira/.github/workflows/release.yml@refs/heads/main',
        environment: 'beta',
      }),
    );
    return (await oidc.exchange({ jwt, packages: pkgs.map((p) => ({ name: p.name, version: p.version })) })).token;
  }

  /** A token as the exchange would mint it for `owner` but for whatever scope the test needs (a package someone else owns, say). */
  async function minted(owner: string | undefined, scope: Array<[string, string]>): Promise<string> {
    const t = env.clock.now();
    const m = await mintToken(env.authStore, {
      kind: 'oidc',
      name: 'ci',
      scopes: ['publish'],
      packages: scope.map(([n]) => n),
      all_current: false,
      ...(owner !== undefined ? { versions: Object.fromEntries(scope), ci_owner: owner } : { version: scope[0]![1] }),
      created_at: t.toISOString(),
      expires_at: new Date(t.getTime() + 600_000).toISOString(),
    });
    return m.secret;
  }

  /** create, PUT every file into (fake) quarantine, commit: returns the group id. */
  async function start(token: string, pkgs: Pkg[]): Promise<string> {
    const r = await env.create(token, pkgs.map(memberOf));
    expect(r.statusCode).toBe(201);
    const created = json(r);
    for (const p of pkgs) {
      const m = created.members.find((x: { name: string }) => x.name === p.name);
      await env.objects.put(quarantineKeyFor(m.files[0].upload_id, m.files[0].filename), p.bytes, { contentType: 'application/octet-stream' });
    }
    const c = await env.call('POST', `/api/v1/groups/${created.group_id}/commit`, token, { members: pkgs.map((p) => ({ name: p.name, manifest_sha256: p.manifest })) });
    expect(c.statusCode).toBe(202);
    return created.group_id as string;
  }
  const visible = async (token: string, pkgs: Pkg[]): Promise<string> => {
    const gid = await start(token, pkgs);
    expect(await env.runGroupJobs()).toEqual(['committed']);
    await chain.drain();
    expect((await rig.store.getGroup(gid))?.status).toBe('visible');
    return gid;
  };
  const yank = (gid: string, token: string, body: unknown = { yanked: true, reason: REASON }) => env.call('PUT', `/api/v1/groups/${gid}/yank`, token, body);

  /** Nothing of the group was written: no header, no place on the actor's list, no row of any member, no group audit entry. */
  async function nothingCreated(pkgs: Pkg[], actor: string) {
    expect(await rig.store.getGroup(groupIdFor(actor, env.groups.parse({ members: pkgs.map(memberOf) })))).toBeUndefined();
    expect(await env.publishes.getActorGroups(actor)).toBeUndefined();
    for (const p of pkgs) {
      expect(await rig.store.raw.rawGet(p.name, p.version)).toBeUndefined();
      expect((await rig.store.listAudit(p.name)).filter((a) => a.action.startsWith('group_'))).toEqual([]);
    }
  }

  describe('inside its scope, on its own packages', () => {
    test('create, upload, commit, validate and flip end to end: the group is visible, every record names the one identity', async () => {
      const token = await exchange([widgets, gadgets]);
      const gid = await visible(token, [widgets, gadgets]);

      const h = (await rig.store.getGroup(gid))!;
      expect(h.actor).toBe(ACTOR);
      for (const p of [widgets, gadgets]) {
        expect(await rig.store.getPackage(p.name)).toMatchObject({ state: 'claimed', ci_owner: OWNER });
        expect(await rig.store.listOwners(p.name)).toEqual([]);
        expect(await rig.store.getVersion(p.name, p.version)).toMatchObject({ state: 'published', published_by: OWNER });
        const trail = (await rig.store.listAudit(p.name)).map((a) => [a.action, a.actor]);
        expect(trail).toContainEqual(['ci_claim', OWNER]);
        expect(trail).toContainEqual(['group_reserve', ACTOR]);
        expect(trail).toContainEqual(['group_flip', 'system']);
      }
      expect((await env.publishes.getActorGroups(ACTOR))?.groups.map((g) => g.id)).toContain(gid);
    });

    test('the identity is one actor whichever token it holds: a later token reads the group and the same request is the same group', async () => {
      const first = await exchange([widgets, gadgets]);
      const gid = await visible(first, [widgets, gadgets]);
      const later = await exchange([widgets, gadgets]);
      const got = await env.get(later, gid);
      expect(got.statusCode).toBe(200);
      expect(json(got)).toMatchObject({ group_id: gid, status: 'visible', member_count: 2 });
      // the same request from another token is the group that exists, not a second one
      const again = await env.create(later, [widgets, gadgets].map(memberOf));
      expect([again.statusCode, json(again).group_id]).toEqual([200, gid]);
    });

    test('yank --group by the identity: the intent, the rows and the audit name the identity, and the versions are yanked', async () => {
      const gid = await visible(await exchange([widgets, gadgets]), [widgets, gadgets]);
      const later = await exchange([widgets, gadgets]);
      const r = await yank(gid, later);
      expect(r.statusCode).toBe(202);
      await chain.drain();
      const h = (await rig.store.getGroup(gid))!;
      expect(h.yank).toMatchObject({ state: 'yanked', reason: REASON, by: ACTOR });
      for (const p of [widgets, gadgets]) {
        expect((await rig.store.getVersion(p.name, p.version))?.state).toBe('yanked');
        const trail = (await rig.store.listAudit(p.name)).map((a) => [a.action, a.actor]);
        expect(trail).toContainEqual(['group_yank', ACTOR]);
      }
      const back = await yank(gid, later, { yanked: false });
      expect(back.statusCode).toBe(202);
      await chain.drain();
      expect((await rig.store.getVersion('widgets', widgets.version))?.state).toBe('published');
    });

    test('the identity aborts its own open group', async () => {
      const token = await exchange([widgets]);
      const made = await env.create(token, [memberOf(widgets)]);
      expect(made.statusCode).toBe(201);
      const gone = await env.abort(await exchange([widgets]), json(made).group_id);
      expect(json(gone).status).toBe('aborted');
    });
  });

  describe('outside what it may do: refused, and nothing is created', () => {
    test('a member outside the token scope (a package the exchange did not name) is scope_missing naming it', async () => {
      const token = await exchange([widgets]);
      const r = await env.create(token, [memberOf(widgets), memberOf(gadgets)]);
      expect([r.statusCode, errorCode(r)]).toEqual([403, 'scope_missing']);
      expect(json(r).error.message).toContain("'gadgets'");
      await nothingCreated([widgets, gadgets], ACTOR);
      expect(await rig.store.getPackage('gadgets')).toBeUndefined();
    });

    test('a member at a version the token was not minted for is scope_missing', async () => {
      const token = await exchange([widgets]);
      const newer = pkg({ name: 'widgets', version: '2.0.0', subdir: 'noarch' });
      const r = await env.create(token, [memberOf(newer)]);
      expect([r.statusCode, errorCode(r)]).toEqual([403, 'scope_missing']);
      await nothingCreated([newer], ACTOR);
    });

    test('a member that an account owns is not_owner, though the token names it; the identity\'s own member is not reserved either', async () => {
      await env.own(7, 'someone', ['gadgets']);
      const token = await minted(OWNER, [['widgets', widgets.version], ['gadgets', gadgets.version]]);
      await exchange([widgets]);
      const r = await env.create(token, [memberOf(widgets), memberOf(gadgets)]);
      expect([r.statusCode, errorCode(r)]).toEqual([403, 'not_owner']);
      await nothingCreated([widgets, gadgets], ACTOR);
    });

    test('a member that another CI identity owns is not_owner', async () => {
      await rig.store.createPackage({ name: 'gadgets', state: 'claimed', created_at: env.clock.now().toISOString(), ci_owner: OTHER_OWNER });
      const token = await minted(OWNER, [['widgets', widgets.version], ['gadgets', gadgets.version]]);
      await exchange([widgets]);
      const r = await env.create(token, [memberOf(widgets), memberOf(gadgets)]);
      expect([r.statusCode, errorCode(r)]).toEqual([403, 'not_owner']);
      await nothingCreated([widgets, gadgets], ACTOR);
    });

    test('another CI identity is not on the allow list: the operation does not exist for it, and nothing is created', async () => {
      await rig.store.createPackage({ name: 'widgets', state: 'claimed', created_at: env.clock.now().toISOString(), ci_owner: OTHER_OWNER });
      const token = await minted(OTHER_OWNER, [['widgets', widgets.version]]);
      const r = await env.create(token, [memberOf(widgets)]);
      expect([r.statusCode, errorCode(r)]).toEqual([404, 'route_not_found']);
      await nothingCreated([widgets], OTHER_ACTOR);
    });

    test('an account without the allow list is refused as before, whatever it owns', async () => {
      const token = await env.token(1, ['widgets']);
      await env.own(1, 'octocat', ['widgets']);
      const r = await env.create(token, [memberOf(widgets)]);
      expect([r.statusCode, errorCode(r)]).toEqual([404, 'route_not_found']);
      await nothingCreated([widgets], 'u:1');
    });

    test('the beta function without the policy variable admits nobody, not even the configured identity', async () => {
      build({}, null);
      const token = await exchange([widgets]);
      const r = await env.create(token, [memberOf(widgets)]);
      expect([r.statusCode, errorCode(r)]).toEqual([404, 'route_not_found']);
      await nothingCreated([widgets], ACTOR);
    });

    test('a token minted for a package\'s registered trusted publisher (no identity) is scope_missing even when the groups switch admits it', async () => {
      await env.own(1, 'octocat', ['widgets']);
      const token = await minted(undefined, [['widgets', widgets.version]]);
      env.deps.publish!.flags = { readOnly: async () => false, groupsFor: async () => true };
      const r = await env.create(token, [memberOf(widgets)]);
      expect([r.statusCode, errorCode(r)]).toEqual([403, 'scope_missing']);
    });
  });

  describe('the lifecycle is the identity\'s own', () => {
    test('another CI identity cannot see, abort, commit or yank the identity\'s group: group_not_found, and the group is unchanged', async () => {
      const gid = await visible(await exchange([widgets, gadgets]), [widgets, gadgets]);
      const before = await rig.store.getGroup(gid);
      const other = await minted(OTHER_OWNER, [['widgets', widgets.version], ['gadgets', gadgets.version]]);
      for (const r of [
        await env.get(other, gid),
        await env.abort(other, gid),
        await yank(gid, other),
        await env.call('POST', `/api/v1/groups/${gid}/commit`, other, { members: [] }),
      ]) {
        expect([r.statusCode, errorCode(r)]).toEqual([404, 'group_not_found']);
      }
      expect(await rig.store.getGroup(gid)).toEqual(before);
    });

    test('an account that owns none of the packages cannot yank the identity\'s group', async () => {
      const gid = await visible(await exchange([widgets, gadgets]), [widgets, gadgets]);
      const stranger = await env.token(1, ['widgets', 'gadgets']);
      const r = await yank(gid, stranger);
      expect([r.statusCode, errorCode(r)]).toEqual([404, 'group_not_found']);
      expect((await rig.store.getGroup(gid))?.yank).toBeUndefined();
    });

    test('the identity cannot yank a group of an account, even for packages its token names', async () => {
      // the account's group is made with the switch open to everybody: this test is about who may yank it, not who may create
      env.deps.publish!.flags = { readOnly: async () => false, groupsFor: async () => true };
      const me = await env.account(1, 'octocat', ['widgets']);
      const gid = await visible(me, [widgets]);
      const ci = await minted(OWNER, [['widgets', widgets.version]]);
      const r = await yank(gid, ci);
      expect([r.statusCode, errorCode(r)]).toEqual([404, 'group_not_found']);
      expect((await rig.store.getGroup(gid))?.yank).toBeUndefined();
    });

    test('the token that created the group yanks only members it covers: a token for one member of two is scope_missing and yanks nothing', async () => {
      const gid = await visible(await exchange([widgets, gadgets]), [widgets, gadgets]);
      const narrow = await exchange([widgets]);
      const r = await yank(gid, narrow);
      expect([r.statusCode, errorCode(r)]).toEqual([403, 'scope_missing']);
      expect((await rig.store.getGroup(gid))?.yank).toBeUndefined();
    });
  });

  describe('the daily budget is the identity\'s, not one token\'s', () => {
    test('a new token of the same identity does not start a new count: the second group is rate_limited', async () => {
      build({ groupRatePerAccountPerDay: 1 });
      const first = await exchange([widgets]);
      const made = await env.create(first, [memberOf(widgets)]);
      expect(made.statusCode).toBe(201);
      expect((await env.abort(first, json(made).group_id)).statusCode).toBe(200);
      const second = await exchange([gadgets]);
      const r = await env.create(second, [memberOf(gadgets)]);
      expect([r.statusCode, errorCode(r)]).toEqual([429, 'rate_limited']);
      // no header and no row; the place taken on the actor's list was given back (only the aborted first group is on it)
      expect(await rig.store.getGroup(groupIdFor(ACTOR, env.groups.parse({ members: [memberOf(gadgets)] })))).toBeUndefined();
      expect(await rig.store.raw.rawGet('gadgets', gadgets.version)).toBeUndefined();
      expect((await env.publishes.getActorGroups(ACTOR))?.groups.map((g) => g.id)).toEqual([json(made).group_id]);
    });
  });
});

describe('actorOf', () => {
  const base = { token_id: 'tok_1', scopes: ['publish' as const], packages: [] };
  test('an account is u:<id>; a configured CI publisher is its identity whichever token; any other CI token is its own', () => {
    expect(actorOf({ ...base, kind: 'api', github_id: 5 })).toBe('u:5');
    expect(actorOf({ ...base, kind: 'oidc', ci_owner: OWNER })).toBe(ACTOR);
    expect(actorOf({ ...base, token_id: 'tok_2', kind: 'oidc', ci_owner: OWNER })).toBe(ACTOR);
    expect(actorOf({ ...base, kind: 'oidc' })).toBe('ci:tok_1');
  });
  test('an account is never taken for an identity, and a non-CI token never claims one', () => {
    expect(actorOf({ ...base, kind: 'oidc', github_id: 5, ci_owner: OWNER })).toBe('u:5');
    expect(actorOf({ ...base, kind: 'api', ci_owner: OWNER })).toBe('ci:tok_1');
  });
});
