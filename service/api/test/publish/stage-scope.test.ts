import { GithubJwtVerifier, OidcExchange, type CiPublisher } from '../../src/auth';
import { quarantineKeyFor } from '../../src/publish/group-keys';
import { RIGS, type Rig } from '../group-rig';
import { goodClaims, newKey, signJwt } from '../auth-helpers';
import { flagsFor } from '../../src/publish/wiring';
import { Chain } from './group-chain-env';
import { errorCode, GroupEnv, json, type MemberBody } from './group-env';
import { FakeDoc } from './fake-doc';
import { pkg, type Pkg } from './harness';

// The `stage` token scope, through the HTTP routes on both registry adapters. What these prove: a stage token may create, read and abort
// a group; it may not commit one, publish a single version, or yank (one version or a group), each refused as scope_missing with
// nothing changed; a publish token does all of it as before; a stage token reserves only what its owner owns and its list names, and a
// CI exchange asked for the stage purpose mints a token that is stage-only and pinned like the publish one. What they do not: real
// GitHub tokens or the deployed stage.

const REASON = 'the release is broken';
const memberOf = (p: Pkg): MemberBody => ({ name: p.name, version: p.version, files: [{ subdir: p.subdir, filename: p.filename, sha256: p.sha256, size: p.bytes.length }] });

describe.each(RIGS)('the stage scope on an account token: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  let chain: Chain;
  let widgets: Pkg;
  let gadgets: Pkg;
  let publish: string;
  let stage: string;
  let pkgs: Pkg[];

  beforeEach(async () => {
    rig = make();
    env = new GroupEnv(rig);
    chain = new Chain(env);
    widgets = pkg({ name: 'widgets', subdir: 'noarch' });
    gadgets = pkg({ name: 'gadgets', subdir: 'noarch' });
    pkgs = [widgets, gadgets];
    publish = await env.account(1, 'alice', ['widgets', 'gadgets']);
    stage = await env.token(1, ['widgets', 'gadgets'], ['stage']);
  });

  /** Create with `token`, then put every file into quarantine as the client's uploads would. */
  async function staged(token: string): Promise<string> {
    const r = await env.create(token, pkgs.map(memberOf));
    expect(r.statusCode).toBe(201);
    const created = json(r);
    for (const p of pkgs) {
      const m = created.members.find((x: { name: string }) => x.name === p.name);
      await env.objects.put(quarantineKeyFor(m.files[0].upload_id, m.files[0].filename), p.bytes, { contentType: 'application/octet-stream' });
    }
    return created.group_id as string;
  }
  const commitBody = () => ({ members: pkgs.map((p) => ({ name: p.name, manifest_sha256: p.manifest })) });
  const commit = (gid: string, token: string) => env.call('POST', `/api/v1/groups/${gid}/commit`, token, commitBody());
  const status = async (gid: string) => json(await env.get(publish, gid)).status as string;
  async function visible(): Promise<string> {
    const gid = await staged(publish);
    expect((await commit(gid, publish)).statusCode).toBe(202);
    expect(await env.runGroupJobs()).toEqual(['committed']);
    await chain.drain();
    expect(await status(gid)).toBe('visible');
    return gid;
  }

  test('a stage token creates a group, reads it and aborts it', async () => {
    const gid = await staged(stage);
    const got = await env.get(stage, gid);
    expect(got.statusCode).toBe(200);
    expect(json(got)).toMatchObject({ group_id: gid, status: 'open' });
    const gone = await env.abort(stage, gid);
    expect(gone.statusCode).toBe(200);
    expect(await status(gid)).toBe('aborted');
  });

  test('a stage token reads and aborts the group a publish token created, and a publish token does the same to the stage one', async () => {
    const mine = await staged(publish);
    expect((await env.get(stage, mine)).statusCode).toBe(200);
    expect((await env.abort(stage, mine)).statusCode).toBe(200);
    const theirs = await staged(stage);
    expect((await env.get(publish, theirs)).statusCode).toBe(200);
    expect((await env.abort(publish, theirs)).statusCode).toBe(200);
  });

  test('a stage token cannot commit a group: scope_missing, the group stays open, and a publish token then commits it', async () => {
    const gid = await staged(stage);
    const refused = await commit(gid, stage);
    expect(refused.statusCode).toBe(403);
    expect(errorCode(refused)).toBe('scope_missing');
    expect(await status(gid)).toBe('open');
    expect(env.groupQueue.sent).toHaveLength(0);

    expect((await commit(gid, publish)).statusCode).toBe(202);
    expect(await env.runGroupJobs()).toEqual(['committed']);
    await chain.drain();
    expect(await status(gid)).toBe('visible');
  });

  test('a token with stage and yank still cannot commit', async () => {
    const both = await env.token(1, ['widgets', 'gadgets'], ['stage', 'yank']);
    const gid = await staged(both);
    expect(errorCode(await commit(gid, both))).toBe('scope_missing');
    expect(await status(gid)).toBe('open');
  });

  test('a stage token cannot begin or commit a single publish', async () => {
    for (const r of [await env.begin(stage, 'widgets'), await env.call('POST', '/api/v1/packages/widgets/1.0.0/publish', stage, { upload_ids: [] })]) {
      expect(r.statusCode).toBe(403);
      expect(errorCode(r)).toBe('scope_missing');
    }
    // the publish token is not refused on scope by the same route
    const ok = await env.begin(publish, 'widgets');
    expect(json(ok).error?.code).not.toBe('scope_missing');
  });

  test('a stage token cannot yank a group or a version; a publish token still can', async () => {
    const gid = await visible();
    const group = await env.call('PUT', `/api/v1/groups/${gid}/yank`, stage, { yanked: true, reason: REASON });
    expect([group.statusCode, errorCode(group)]).toEqual([403, 'scope_missing']);
    const single = await env.call('PUT', `/api/v1/packages/widgets/${widgets.version}/yank`, stage, { yanked: true, reason: REASON });
    expect([single.statusCode, errorCode(single)]).toEqual([403, 'scope_missing']);
    for (const p of pkgs) expect((await rig.store.getVersion(p.name, p.version))?.state).toBe('published');

    expect((await env.call('PUT', `/api/v1/groups/${gid}/yank`, publish, { yanked: true, reason: REASON })).statusCode).toBe(202);
    await chain.drain();
    for (const p of pkgs) expect((await rig.store.getVersion(p.name, p.version))?.state).toBe('yanked');
  });

  test('a token with stage and yank yanks a group: stage does not take the yank scope away', async () => {
    const gid = await visible();
    const both = await env.token(1, ['widgets', 'gadgets'], ['stage', 'yank']);
    expect((await env.call('PUT', `/api/v1/groups/${gid}/yank`, both, { yanked: true, reason: REASON })).statusCode).toBe(202);
  });

  test('a token with stage and yank yanks a single version', async () => {
    await visible();
    const both = await env.token(1, ['widgets', 'gadgets'], ['stage', 'yank']);
    const one = await env.call('PUT', `/api/v1/packages/widgets/${widgets.version}/yank`, both, { yanked: true, reason: REASON });
    expect(json(one).error?.code).not.toBe('scope_missing');
  });

  test('the publish token does everything it did before: create, read, commit, abort and yank', async () => {
    const aborted = await staged(publish);
    expect((await env.abort(publish, aborted)).statusCode).toBe(200);
    const gid = await visible();
    expect((await env.get(publish, gid)).statusCode).toBe(200);
    expect((await env.call('PUT', `/api/v1/groups/${gid}/yank`, publish, { yanked: true, reason: REASON })).statusCode).toBe(202);
  });

  test('a stage token reserves nothing it does not own: not_owner for another account, scope_missing for a package its list leaves out, and nothing is written', async () => {
    // account 3 owns nothing here
    const mallory = await env.token(3, ['widgets', 'gadgets'], ['stage']);
    env.allow(3);
    const notOwner = await env.create(mallory, pkgs.map(memberOf));
    expect([notOwner.statusCode, errorCode(notOwner)]).toEqual([403, 'not_owner']);

    const narrow = await env.token(1, ['widgets'], ['stage']);
    const left = await env.create(narrow, pkgs.map(memberOf));
    expect([left.statusCode, errorCode(left)]).toEqual([403, 'scope_missing']);
    expect(json(left).error.message).toContain("'gadgets'");

    const ghost = pkg({ name: 'ghost', subdir: 'noarch' });
    const ghostToken = await env.token(1, ['ghost'], ['stage']);
    const none = await env.create(ghostToken, [memberOf(ghost)]);
    expect(none.statusCode).toBe(404);
    expect(await rig.store.getPackage('ghost')).toBeUndefined();

    for (const p of pkgs) expect((await rig.store.listAudit(p.name)).filter((a) => a.action.startsWith('group_'))).toEqual([]);
    expect(await env.publishes.getActorGroups('u:3')).toBeUndefined();
  });

  test('a token with no stage, publish or yank scope for the group is refused at create, read and abort', async () => {
    const gid = await staged(publish);
    const yankOnly = await env.token(1, ['widgets', 'gadgets'], ['yank']);
    expect(errorCode(await env.create(yankOnly, pkgs.map(memberOf)))).toBe('scope_missing');
    expect(errorCode(await env.get(yankOnly, gid))).toBe('scope_missing');
    expect(errorCode(await env.abort(yankOnly, gid))).toBe('scope_missing');
  });
});

const key = newKey('k1');
const OWNER = 'gh-repo:1376408823';
const OTHER_OWNER = 'gh-repo:999';
const POLICY = JSON.stringify({ mode: 'allow', actors: [`ci:${OWNER}`] });
const PUBLISHER: CiPublisher = {
  repository_id: '1376408823',
  repository_owner_id: '305577347',
  workflow: '.github/workflows/release.yml',
  ref: 'refs/heads/main',
  job_workflow_ref: 'komira-ai/komira/.github/workflows/release.yml@refs/heads/main',
  events: ['push'],
  environment: 'beta',
};

describe.each(RIGS)('the stage purpose of the CI exchange: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  let chain: Chain;
  let oidc: OidcExchange;
  let widgets: Pkg;
  let gadgets: Pkg;

  beforeEach(async () => {
    rig = make();
    env = new GroupEnv(rig);
    chain = new Chain(env);
    env.deps.publish!.flags = flagsFor({ MOPM_GROUPS_POLICY: POLICY }, new FakeDoc({ 'mopm-beta-config': 'key' }) as never, 'beta');
    oidc = new OidcExchange({
      store: env.authStore,
      verifier: new GithubJwtVerifier({ audiences: ['beta.mopm.dev'], now: env.clock.now, jwks: async () => ({ keys: [key.jwk] }) }),
      now: env.clock.now,
      ciPublishers: [PUBLISHER],
      registry: rig.store,
    });
    widgets = pkg({ name: 'widgets', subdir: 'noarch' });
    gadgets = pkg({ name: 'gadgets', subdir: 'noarch' });
  });

  const jwt = () =>
    signJwt(
      key,
      goodClaims(env.clock, {
        aud: 'beta.mopm.dev',
        repository: 'komira-ai/komira',
        repository_id: '1376408823',
        repository_owner_id: '305577347',
        workflow_ref: 'komira-ai/komira/.github/workflows/release.yml@refs/heads/main',
        job_workflow_ref: 'komira-ai/komira/.github/workflows/release.yml@refs/heads/main',
        environment: 'beta',
      }),
    );
  const exchange = async (pkgs: Pkg[], purpose?: string) =>
    oidc.exchange({ jwt: jwt(), packages: pkgs.map((p) => ({ name: p.name, version: p.version })), ...(purpose !== undefined ? { purpose } : {}) } as never);

  test('a stage exchange mints a stage-only token that creates, reads and aborts, and a publish exchange of the same set commits it', async () => {
    const minted = await exchange([widgets, gadgets], 'stage');
    expect(minted.token_kind).toBe('stage');
    const stage = minted.token;
    const made = await env.create(stage, [widgets, gadgets].map(memberOf));
    expect(made.statusCode).toBe(201);
    const gid = json(made).group_id as string;
    for (const p of [widgets, gadgets]) {
      const m = json(made).members.find((x: { name: string }) => x.name === p.name);
      await env.objects.put(quarantineKeyFor(m.files[0].upload_id, m.files[0].filename), p.bytes, { contentType: 'application/octet-stream' });
    }
    expect((await env.get(stage, gid)).statusCode).toBe(200);
    const body = { members: [widgets, gadgets].map((p) => ({ name: p.name, manifest_sha256: p.manifest })) };
    const refused = await env.call('POST', `/api/v1/groups/${gid}/commit`, stage, body);
    expect([refused.statusCode, errorCode(refused)]).toEqual([403, 'scope_missing']);
    expect(json(await env.get(stage, gid)).status).toBe('open');

    const publish = (await exchange([widgets, gadgets])).token;
    const done = await env.call('POST', `/api/v1/groups/${gid}/commit`, publish, body);
    expect(done.statusCode).toBe(202);
    expect(await env.runGroupJobs()).toEqual(['committed']);
    await chain.drain();
    expect((await rig.store.getGroup(gid))?.status).toBe('visible');

    const yank = await env.call('PUT', `/api/v1/groups/${gid}/yank`, stage, { yanked: true, reason: REASON });
    expect([yank.statusCode, errorCode(yank)]).toEqual([403, 'scope_missing']);
    const one = await env.call('PUT', `/api/v1/packages/widgets/${widgets.version}/yank`, stage, { yanked: true, reason: REASON });
    expect([one.statusCode, errorCode(one)]).toEqual([403, 'scope_missing']);
  });

  test('a stage token aborts the group it made', async () => {
    const stage = (await exchange([widgets, gadgets], 'stage')).token;
    const gid = json(await env.create(stage, [widgets, gadgets].map(memberOf))).group_id as string;
    expect((await env.abort(stage, gid)).statusCode).toBe(200);
    expect((await rig.store.getGroup(gid))?.status).toBe('aborted');
  });

  test('a stage token is pinned like a publish token: another version or another package is scope_missing', async () => {
    const stage = (await exchange([widgets], 'stage')).token;
    const other = pkg({ name: 'widgets', version: '2.0.0', subdir: 'noarch' });
    expect(errorCode(await env.create(stage, [memberOf(other)]))).toBe('scope_missing');
    expect(errorCode(await env.create(stage, [widgets, gadgets].map(memberOf)))).toBe('scope_missing');
  });

  test('a stage exchange cannot reserve a package another identity owns: not_owner, and no token is minted', async () => {
    await rig.store.createPackage({ name: 'widgets', state: 'claimed', created_at: env.clock.now().toISOString(), ci_owner: OTHER_OWNER });
    const before = env.authStore.dumpTokens().length;
    await expect(exchange([widgets, gadgets], 'stage')).rejects.toMatchObject({ code: 'not_owner' });
    expect(env.authStore.dumpTokens()).toHaveLength(before);
    expect(await rig.store.getPackage('gadgets')).toBeUndefined();
  });

  test('the default and an explicit publish purpose mint the same publish token', async () => {
    const a = await exchange([widgets]);
    const b = await exchange([widgets], 'publish');
    expect([a.token_kind, b.token_kind]).toEqual(['publish', 'publish']);
    const scopes = env.authStore.dumpTokens().map((t) => t.scopes);
    expect(scopes).toEqual([['publish'], ['publish']]);
  });
});
