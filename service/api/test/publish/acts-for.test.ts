import { Authenticator, GithubJwtVerifier, OidcExchange, type CiPublisher } from '../../src/auth';
import { headerKey } from '../../src/group';
import { actorOf, viaOf } from '../../src/publish/service';
import { quarantineKeyFor } from '../../src/publish/group-keys';
import { groupIdFor } from '../../src/publish/group-service';
import { RIGS, type Rig } from '../group-rig';
import { goodClaims, newKey, signJwt } from '../auth-helpers';
import { Chain } from './group-chain-env';
import { errorCode, GroupEnv, json, type MemberBody } from './group-env';
import { pkg, type Pkg } from './harness';

// The prod CI identity that ACTS FOR an account (a CI publisher row with `acts_for`): the exchange mints a token whose principal is
// the account, the account's owner rows decide what it may touch, the account's groups switch decides whether it may make a group,
// and every record it writes says it came through CI. What these prove: the good prod identity publishes and groups a package the
// account owns, as the account, and leaves a mark on every record; a package of anyone else's, a CI-owned one and an unclaimed name
// are refused with nothing created and the CI token unspent; every claim pin (repository, workflow, ref, event, environment,
// audience) refuses; the token cannot do what an account's session can (claim, tokens). What they do not: real GitHub tokens,
// DynamoDB wire behaviour (the rigs cover the adapter), the deployed stage (service/infra/stacks pins the prod row).

const key = newKey('k1');
const ACCOUNT = 15257031;
const HANDLE = 'asuresh8';
const ACTOR = `u:${ACCOUNT}`;
const VIA = 'ci:gh-repo:1376408823';
const PUBLISHER: CiPublisher = {
  repository_id: '1376408823',
  repository_owner_id: '305577347',
  workflow: '.github/workflows/release.yml',
  ref: 'refs/heads/main',
  job_workflow_ref: 'komira-ai/komira/.github/workflows/release.yml@refs/heads/main',
  events: ['push'],
  environment: 'prod',
  acts_for: String(ACCOUNT),
};
const REASON = 'the release is broken';

const memberOf = (p: Pkg): MemberBody => ({ name: p.name, version: p.version, files: [{ subdir: p.subdir, filename: p.filename, sha256: p.sha256, size: p.bytes.length }] });

describe.each(RIGS)('a CI identity that acts for an account: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  let chain: Chain;
  let oidc: OidcExchange;
  let widgets: Pkg;
  let gadgets: Pkg;

  function build(publishers: readonly CiPublisher[] | null = [PUBLISHER]) {
    rig = make();
    env = new GroupEnv(rig);
    chain = new Chain(env);
    oidc = new OidcExchange({
      store: env.authStore,
      verifier: new GithubJwtVerifier({ audiences: ['mopm.dev'], now: env.clock.now, jwks: async () => ({ keys: [key.jwk] }) }),
      now: env.clock.now,
      ...(publishers ? { ciPublishers: publishers, registry: rig.store } : {}),
    });
  }
  beforeEach(async () => {
    build();
    widgets = pkg({ name: 'widgets', subdir: 'noarch' });
    gadgets = pkg({ name: 'gadgets', subdir: 'noarch' });
    // The state of prod when the release runs: the account owns the names and the groups switch admits the account.
    await env.own(ACCOUNT, HANDLE, ['widgets', 'gadgets']);
    env.allow(ACCOUNT);
  });

  /** What GitHub issues to the komira release workflow on main, in the prod environment, for a push. */
  const jwt = (over: Record<string, unknown> = {}) =>
    signJwt(
      key,
      goodClaims(env.clock, {
        aud: 'mopm.dev',
        repository: 'komira-ai/komira',
        repository_id: '1376408823',
        repository_owner_id: '305577347',
        workflow_ref: 'komira-ai/komira/.github/workflows/release.yml@refs/heads/main',
        job_workflow_ref: 'komira-ai/komira/.github/workflows/release.yml@refs/heads/main',
        environment: 'prod',
        ...over,
      }),
    );
  const exchange = async (pkgs: Pkg[]): Promise<string> => (await oidc.exchange({ jwt: jwt(), packages: pkgs.map((p) => ({ name: p.name, version: p.version })) })).token;
  const ciTokens = () => env.authStore.dumpTokens().filter((t) => t.kind === 'oidc');

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
  async function visible(token: string, pkgs: Pkg[]): Promise<string> {
    const gid = await start(token, pkgs);
    expect(await env.runGroupJobs()).toEqual(['committed']);
    await chain.drain();
    expect((await rig.store.getGroup(gid))?.status).toBe('visible');
    return gid;
  }
  const yank = (gid: string, token: string, body: unknown = { yanked: true, reason: REASON }) => env.call('PUT', `/api/v1/groups/${gid}/yank`, token, body);

  async function nothingCreated(pkgs: Pkg[]) {
    expect(await rig.store.getGroup(groupIdFor(ACTOR, env.groups.parse({ members: pkgs.map(memberOf) })))).toBeUndefined();
    expect(await env.publishes.getActorGroups(ACTOR)).toBeUndefined();
    for (const p of pkgs) expect(await rig.store.raw.rawGet(p.name, p.version)).toBeUndefined();
  }

  describe('the good prod identity, on packages the account owns', () => {
    test('the token is the account: its principal has the account id, the CI identity as the mark, no ci_owner, and exactly the listed packages and versions', async () => {
      const token = await exchange([widgets, gadgets]);
      const principal = await new Authenticator({ store: env.authStore, now: env.clock.now }).authenticate(`Bearer ${token}`);
      expect(principal).toMatchObject({ kind: 'oidc', github_id: ACCOUNT, acts_via: 'gh-repo:1376408823', packages: ['widgets', 'gadgets'], versions: { widgets: widgets.version, gadgets: gadgets.version } });
      expect(principal.ci_owner).toBeUndefined();
      expect(actorOf(principal)).toBe(ACTOR);
      expect(viaOf(principal)).toBe(VIA);
      const [row] = ciTokens();
      expect(row!.expires_at).toBe(new Date(env.clock.t + 10 * 60_000).toISOString());
      expect(row!.ci_owner).toBeUndefined();
    });

    test('create, upload, commit, validate and flip end to end: the group is the account\'s, visible, and every record says it came through CI', async () => {
      const gid = await visible(await exchange([widgets, gadgets]), [widgets, gadgets]);
      const h = (await rig.store.getGroup(gid))!;
      expect(h).toMatchObject({ actor: ACTOR, via: VIA });
      expect(gid).toBe(groupIdFor(ACTOR, env.groups.parse({ members: [widgets, gadgets].map(memberOf) }))); // the id a human of this account would get
      for (const p of [widgets, gadgets]) {
        const rec = await rig.store.getPackage(p.name);
        expect(rec).toMatchObject({ state: 'active' });
        expect(rec?.ci_owner).toBeUndefined(); // no CI owner is ever set
        expect((await rig.store.listOwners(p.name)).map((o) => o.github_id)).toEqual([ACCOUNT]); // the account stays the one owner
        expect(await rig.store.getVersion(p.name, p.version)).toMatchObject({ state: 'published', published_by: HANDLE });
        const trail = await rig.store.listAudit(p.name);
        expect(trail.map((a) => a.action)).not.toContain('ci_claim');
        for (const action of ['group_reserve', 'group_stage']) {
          const a = trail.find((x) => x.action === action);
          expect(a).toMatchObject({ actor: ACTOR, detail: { via: VIA } });
        }
        for (const a of trail.filter((x) => x.action.startsWith('group_') && x.actor === ACTOR)) expect(a.detail?.via).toBe(VIA);
      }
      const trail = await rig.store.listAudit(headerKey(gid));
      expect(trail.find((a) => a.action === 'group_create')).toMatchObject({ actor: ACTOR, detail: { via: VIA } });
      expect(trail.find((a) => a.action === 'group_commit_request')).toMatchObject({ actor: ACTOR, detail: { via: VIA } });
    });

    test('the upload records of a group made through CI carry the mark', async () => {
      const made = await env.create(await exchange([widgets]), [memberOf(widgets)]);
      const id = json(made).members[0].files[0].upload_id as string;
      expect(await env.publishes.getUpload(id)).toMatchObject({ actor: ACTOR, via: VIA });
    });

    test('a publish by the account itself carries no mark (the mark is what tells the two apart)', async () => {
      const mine = await env.token(ACCOUNT, ['widgets', 'gadgets']);
      const gid = await visible(mine, [widgets, gadgets]);
      expect((await rig.store.getGroup(gid))?.via).toBeUndefined();
      for (const p of [widgets, gadgets]) {
        for (const a of await rig.store.listAudit(p.name)) expect(a.detail?.via).toBeUndefined();
      }
    });

    test('a single (non-group) publish works as the account and its begin-upload audit and upload record carry the mark', async () => {
      const token = await exchange([widgets]);
      const r = await env.begin(token, 'widgets', widgets.version);
      expect(r.statusCode).toBe(200);
      const trail = await rig.store.listAudit('widgets');
      expect(trail.find((a) => a.action === 'publish_begin')).toMatchObject({ actor: ACTOR, detail: { via: VIA } });
    });

    test('a later token of the same identity is the same actor: it reads the group, yanks it (the request is marked), and unyanks it', async () => {
      const gid = await visible(await exchange([widgets, gadgets]), [widgets, gadgets]);
      env.clock.advance(60_000);
      const later = await exchange([widgets, gadgets]);
      expect(json(await env.get(later, gid))).toMatchObject({ group_id: gid, status: 'visible' });
      const r = await yank(gid, later);
      expect(r.statusCode).toBe(202);
      await chain.drain();
      expect((await rig.store.getGroup(gid))?.yank).toMatchObject({ state: 'yanked', reason: REASON, by: ACTOR });
      const request = (await rig.store.listAudit(headerKey(gid))).find((a) => a.action === 'group_yank_request');
      expect(request).toMatchObject({ actor: ACTOR, detail: { via: VIA } });
      expect((await yank(gid, later, { yanked: false })).statusCode).toBe(202);
      await chain.drain();
      expect((await rig.store.getVersion('widgets', widgets.version))?.state).toBe('published');
    });

    test('the abort job: a fresh token aborts the account\'s open group, the place on the actor\'s list is freed, and the abort is marked', async () => {
      const first = await exchange([widgets]);
      const made = await env.create(first, [memberOf(widgets)]);
      expect(made.statusCode).toBe(201);
      env.clock.advance(11 * 60_000); // the first token has expired by the time the abort job runs
      expect((await env.get(first, json(made).group_id)).statusCode).toBe(401);
      const gone = await env.abort(await exchange([widgets]), json(made).group_id);
      expect(json(gone).status).toBe('aborted');
      const a = (await rig.store.listAudit(headerKey(json(made).group_id))).find((x) => x.action === 'group_abort');
      expect(a).toMatchObject({ actor: ACTOR, detail: { via: VIA } });
    });
  });

  describe('names that are not the account\'s are refused, and nothing is created or spent', () => {
    test('a package owned by someone else: not_owner (403); the free name beside it is not touched, no token is minted, the CI token is unspent', async () => {
      await env.own(7, 'someone', ['theirs']);
      const j = jwt();
      const r = await oidc.exchange({ jwt: j, packages: [{ name: 'widgets', version: '1.0.0' }, { name: 'theirs', version: '1.0.0' }] }).catch((e) => e);
      expect(r).toMatchObject({ code: 'not_owner', status: 403 });
      expect(ciTokens()).toEqual([]);
      expect((await rig.store.listOwners('theirs')).map((o) => o.github_id)).toEqual([7]);
      await expect(oidc.exchange({ jwt: j, packages: [{ name: 'widgets', version: '1.0.0' }] })).resolves.toBeDefined(); // the same CI token still works
    });

    test('a package the account has lost is refused (ownership is read at exchange and again at use, so a live token does not outlive it)', async () => {
      const token = await exchange([widgets]);
      await rig.store.removeOwner('widgets', ACCOUNT);
      const r = await env.create(token, [memberOf(widgets)]);
      expect([r.statusCode, errorCode(r)]).toEqual([403, 'not_owner']);
      await nothingCreated([widgets]);
      await expect(oidc.exchange({ jwt: jwt(), packages: [{ name: 'widgets', version: '1.0.0' }] })).rejects.toMatchObject({ code: 'not_owner' });
    });

    test('a package owned by a CI identity (a beta-style ci_owner): not_owner', async () => {
      await rig.store.createPackage({ name: 'cipkg', state: 'claimed', created_at: env.clock.now().toISOString(), ci_owner: 'gh-repo:1376408823' });
      await expect(oidc.exchange({ jwt: jwt(), packages: [{ name: 'cipkg', version: '1.0.0' }] })).rejects.toMatchObject({ code: 'not_owner', status: 403 });
      expect(ciTokens()).toEqual([]);
    });

    test('an unclaimed name: package_not_found (404) naming it, with the claim hint; it is not created, no token is minted, the CI token is unspent', async () => {
      const j = jwt();
      const e = await oidc.exchange({ jwt: j, packages: [{ name: 'widgets', version: '1.0.0' }, { name: 'unclaimed', version: '1.0.0' }] }).catch((x) => x);
      expect(e).toMatchObject({ code: 'package_not_found', status: 404, detail: { name: 'unclaimed' } });
      expect(String(e.message)).toContain("'unclaimed'");
      expect(await rig.store.getPackage('unclaimed')).toBeUndefined();
      expect(ciTokens()).toEqual([]);
      await expect(oidc.exchange({ jwt: j, packages: [{ name: 'widgets', version: '1.0.0' }] })).resolves.toBeDefined();
    });

    test('through the router the unclaimed name is a 404 package_not_found, not a 500', async () => {
      const { route } = await import('../../src/http/router');
      const auth = { authn: new Authenticator({ store: env.authStore, now: env.clock.now }), oidc } as never;
      const res = await route(
        { method: 'POST', path: '/api/v1/auth/oidc/exchange', query: {}, headers: {}, body: JSON.stringify({ jwt: jwt(), packages: [{ name: 'unclaimed', version: '1.0.0' }] }) },
        { store: rig.store, stage: 'prod', version: 't', commit: 't', readOnly: false, auth },
        'req-x',
      );
      expect([res.statusCode, JSON.parse(res.body).error.code]).toEqual([404, 'package_not_found']);
    });

    test('the token exchanged for one package refuses another at group create: scope_missing, and a version it was not minted for too', async () => {
      const token = await exchange([widgets]);
      const r = await env.create(token, [memberOf(widgets), memberOf(gadgets)]);
      expect([r.statusCode, errorCode(r)]).toEqual([403, 'scope_missing']);
      const newer = pkg({ name: 'widgets', version: '2.0.0', subdir: 'noarch' });
      const v = await env.create(token, [memberOf(newer)]);
      expect([v.statusCode, errorCode(v)]).toEqual([403, 'scope_missing']);
      await nothingCreated([widgets, gadgets]);
      await nothingCreated([newer]);
    });

    test('the files of a group are read by a token that covers every member and by no token that does not: the 404 carries no fact', async () => {
      const human = await env.token(ACCOUNT, ['widgets', 'gadgets']);
      const gid = json(await env.create(human, [memberOf(widgets), memberOf(gadgets)])).group_id as string;
      const wide = await exchange([widgets, gadgets]);
      const narrow = await exchange([widgets]);
      const factsOf = (p: Pkg) => [{ subdir: p.subdir, filename: p.filename, sha256: p.sha256, size: p.bytes.length, uploaded: false }];
      const seen = await env.get(wide, gid);
      expect(seen.statusCode).toBe(200);
      expect(json(seen).members.map((m: { name: string; files: unknown }) => [m.name, m.files])).toEqual([
        ['gadgets', factsOf(gadgets)],
        ['widgets', factsOf(widgets)],
      ]);
      const hidden = await env.get(narrow, gid);
      expect([hidden.statusCode, errorCode(hidden)]).toEqual([404, 'group_not_found']);
      expect(hidden.body).not.toContain(widgets.sha256);
      expect(hidden.body).not.toContain(gadgets.sha256);
    });

    test('the account\'s other groups are not found by the token: read, abort, commit and yank answer group_not_found for a group with a member outside the token, and the group is untouched', async () => {
      const human = await env.token(ACCOUNT, ['gadgets']);
      const made = await env.create(human, [memberOf(gadgets)]);
      expect(made.statusCode).toBe(201);
      const gid = json(made).group_id as string;
      const token = await exchange([widgets]);
      const answers = [
        await env.get(token, gid),
        await env.abort(token, gid),
        await env.call('POST', `/api/v1/groups/${gid}/commit`, token, { members: [] }),
        await env.call('PUT', `/api/v1/groups/${gid}/yank`, token, { yanked: true, reason: REASON }),
      ];
      expect(answers.map((r) => [r.statusCode, errorCode(r)])).toEqual([[404, 'group_not_found'], [404, 'group_not_found'], [404, 'group_not_found'], [404, 'group_not_found']]);
      const still = await env.get(human, gid);
      expect([still.statusCode, json(still).status]).toEqual([200, 'open']);
    });
  });

  describe('the account\'s groups switch applies unchanged', () => {
    test('with the account not on the allow list the operation does not exist for the CI token either, and nothing is created', async () => {
      env.flags.groupActors.clear();
      const r = await env.create(await exchange([widgets]), [memberOf(widgets)]);
      expect([r.statusCode, errorCode(r)]).toEqual([404, 'route_not_found']);
      await nothingCreated([widgets]);
    });

    test('with only another account on the allow list it is refused the same way', async () => {
      env.flags.groupActors.clear();
      env.allow(1);
      const r = await env.create(await exchange([widgets]), [memberOf(widgets)]);
      expect([r.statusCode, errorCode(r)]).toEqual([404, 'route_not_found']);
    });

    test('the CI identity\'s own actor (ci:gh-repo:...) on the allow list does not admit it: the actor is the account', async () => {
      env.flags.groupActors.clear();
      env.flags.groupActors.add(VIA);
      const r = await env.create(await exchange([widgets]), [memberOf(widgets)]);
      expect([r.statusCode, errorCode(r)]).toEqual([404, 'route_not_found']);
    });
  });

  describe('the token is not a login', () => {
    test('it cannot claim a name, mint or list tokens, or act as a user token', async () => {
      const token = await exchange([widgets]);
      const authn = new Authenticator({ store: env.authStore, now: env.clock.now });
      const principal = await authn.authenticate(`Bearer ${token}`);
      expect(() => authn.userToken(principal)).toThrow(expect.objectContaining({ code: 'scope_missing' }));
      expect(() => authn.freshSession(principal)).toThrow(expect.objectContaining({ code: 'scope_missing' }));
      // `userToken` is the check the claim route and the token routes make
      expect(() => authn.userToken(principal)).toThrow(expect.objectContaining({ code: 'scope_missing', status: 403 }));
    });

    test('it does not appear among the account\'s tokens, and does not count against its token limit', async () => {
      const { TokenService } = await import('../../src/auth');
      await exchange([widgets]);
      const tokens = new TokenService({ store: env.authStore, ownedPackages: async () => ['widgets'], now: env.clock.now });
      expect(await tokens.list(ACCOUNT)).toEqual([]);
    });
  });

  describe('only the configured identity is trusted, field by field', () => {
    const cases: Array<[string, Record<string, unknown>, string]> = [
      ['another repository_id', { repository_id: '1376408824' }, 'oidc_not_trusted'],
      ['another repository_owner_id', { repository_owner_id: '305577348' }, 'oidc_not_trusted'],
      ['another workflow file', { workflow_ref: 'komira-ai/komira/.github/workflows/other.yml@refs/heads/main' }, 'oidc_not_trusted'],
      ['a workflow of another repository with the right file name', { workflow_ref: 'evil/fork/.github/workflows/release.yml@refs/heads/main' }, 'oidc_not_trusted'],
      ['a reusable workflow of another file', { job_workflow_ref: 'komira-ai/komira/.github/workflows/other.yml@refs/heads/main' }, 'oidc_not_trusted'],
      ['release.yml at another ref', { job_workflow_ref: 'komira-ai/komira/.github/workflows/release.yml@refs/heads/feature' }, 'oidc_not_trusted'],
      ['no job_workflow_ref', { job_workflow_ref: undefined }, 'oidc_not_trusted'],
      ['a manual run (workflow_dispatch)', { event_name: 'workflow_dispatch' }, 'oidc_not_trusted'],
      ['a feature branch', { ref: 'refs/heads/feature' }, 'oidc_not_trusted'],
      ['a tag', { ref: 'refs/tags/v1' }, 'oidc_not_trusted'],
      ['a pull request merge ref', { ref: 'refs/pull/7/merge' }, 'oidc_not_trusted'],
      ['the beta environment', { environment: 'beta' }, 'oidc_not_trusted'],
      ['no environment', { environment: undefined }, 'oidc_not_trusted'],
      ['a pull_request event', { event_name: 'pull_request' }, 'oidc_not_trusted'],
      ['the beta audience', { aud: 'beta.mopm.dev' }, 'oidc_token_invalid'],
      ['the gamma audience', { aud: 'gamma.mopm.dev' }, 'oidc_token_invalid'],
      ['an audience of the API host', { aud: 'api.mopm.dev' }, 'oidc_token_invalid'],
    ];
    test.each(cases)('%s: refused (%s); no token is minted', async (_n, over, code) => {
      const e = await oidc.exchange({ jwt: jwt(over), packages: [{ name: 'widgets', version: '1.0.0' }] }).catch((x) => x);
      expect(e).toMatchObject({ code });
      expect(ciTokens()).toEqual([]);
    });

    test('a token is exchanged once', async () => {
      const j = jwt();
      await oidc.exchange({ jwt: j, packages: [{ name: 'widgets', version: '1.0.0' }] });
      await expect(oidc.exchange({ jwt: j, packages: [{ name: 'gadgets', version: '1.0.0' }] })).rejects.toMatchObject({ code: 'oidc_token_invalid' });
      expect(ciTokens()).toHaveLength(1);
    });

    test('a deployment with no configured publisher (gamma) refuses the packages form, whoever asks', async () => {
      build(null);
      await expect(oidc.exchange({ jwt: jwt(), packages: [{ name: 'widgets', version: '1.0.0' }] })).rejects.toMatchObject({ code: 'oidc_not_trusted' });
    });

    test('a row without acts_for still creates and owns the package itself (beta is unchanged), and an account-owned package is still refused to it', async () => {
      const { acts_for: _a, ...beta } = PUBLISHER;
      build([{ ...beta, environment: 'prod' }]);
      await env.own(ACCOUNT, HANDLE, ['widgets']);
      await expect(oidc.exchange({ jwt: jwt(), packages: [{ name: 'widgets', version: '1.0.0' }] })).rejects.toMatchObject({ code: 'not_owner' });
      const ok = await oidc.exchange({ jwt: jwt(), packages: [{ name: 'fresh', version: '1.0.0' }] });
      expect(ok.packages).toEqual([{ name: 'fresh', version: '1.0.0' }]);
      expect(await rig.store.getPackage('fresh')).toMatchObject({ ci_owner: 'gh-repo:1376408823' });
      const row = env.authStore.dumpTokens().find((t) => t.kind === 'oidc');
      expect(row).toMatchObject({ ci_owner: 'gh-repo:1376408823' });
      expect(row?.github_id).toBeUndefined();
      expect(row?.acts_via).toBeUndefined();
    });
  });
});

describe('viaOf', () => {
  const base = { token_id: 'tok_1', kind: 'oidc' as const, scopes: ['publish' as const], packages: [] };
  test('only a token that acts for an account has a mark, named for the CI identity; the actor is the account either way', () => {
    expect(viaOf({ ...base, github_id: 5, acts_via: 'gh-repo:9' })).toBe('ci:gh-repo:9');
    expect(actorOf({ ...base, github_id: 5, acts_via: 'gh-repo:9' })).toBe('u:5');
    expect(viaOf({ ...base, github_id: 5 })).toBeUndefined();
    expect(viaOf({ ...base, ci_owner: 'gh-repo:9' })).toBeUndefined();
  });
});
