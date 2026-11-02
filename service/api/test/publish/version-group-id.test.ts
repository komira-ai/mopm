import { RIGS, type Rig } from '../group-rig';
import { Chain } from './group-chain-env';
import { errorCode, GroupEnv, json } from './group-env';
import { Scenario } from './group-scenario';
import { Harness, pkg } from './harness';

/**
 * GET /packages/{name}/{version} (spec/api/openapi.yaml: `VersionDetail.group_id`) names the group that published the version, and
 * says nothing of a group for a version a single publish made. Each test says what it proves.
 */

const REASON = 'the release is broken';

describe.each(RIGS)('the group_id of a version published by a group: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  let chain: Chain;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
    chain = new Chain(env);
  });
  const detail = (name: string) => env.call('GET', `/api/v1/packages/${name}/1.0.0`);
  /** A group that has committed and whose chain has run to the end. */
  async function visible(): Promise<Scenario> {
    const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
    expect(await s.runAll()).toEqual(['committed']);
    await chain.drain();
    expect((await s.header())!.status).toBe('visible');
    return s;
  }

  test('a version a visible group published shows the group id; the rest of the answer is as it was', async () => {
    const s = await visible();
    for (const p of s.pkgs) {
      const r = await detail(p.name);
      expect(r.statusCode).toBe(200);
      expect(json(r)).toMatchObject({ name: p.name, version: '1.0.0', state: 'published', group_id: s.gid, manifest_sha256: p.manifest });
    }
  });

  test('a member of a group that has committed but not yet become visible shows the group id too', async () => {
    const s = await new Scenario(env, [{ name: 'alpha' }]).start();
    expect(await s.runAll()).toEqual(['committed']);
    const r = await detail('alpha');
    expect(r.statusCode).toBe(200);
    expect(json(r).group_id).toBe(s.gid);
  });

  test('a member that is still pending is not found, whatever stage the group is in, and the answer names no group', async () => {
    const s = await new Scenario(env, [{ name: 'alpha' }]).create();
    for (const stage of ['open', 'validating']) {
      if (stage === 'validating') {
        await s.upload();
        expect((await s.commit()).statusCode).toBe(202);
      }
      const r = await detail('alpha');
      expect([r.statusCode, errorCode(r)]).toEqual([404, 'version_not_found']);
      expect(r.body).not.toContain(s.gid);
    }
  });

  test('a yanked member and a restored one still show the group id (a per-version yank, and the group\'s yank and unyank)', async () => {
    const s = await visible();
    const group = (body: unknown) => env.call('PUT', `/api/v1/groups/${s.gid}/yank`, s.token, body);
    expect((await group({ yanked: true, reason: REASON })).statusCode).toBe(202);
    await chain.drain();
    for (const p of s.pkgs) expect(json(await detail(p.name))).toMatchObject({ state: 'yanked', group_id: s.gid });
    expect((await group({ yanked: false })).statusCode).toBe(202);
    await chain.drain();
    for (const p of s.pkgs) expect(json(await detail(p.name))).toMatchObject({ state: 'published', group_id: s.gid });
    const one = await env.call('PUT', '/api/v1/packages/alpha/1.0.0/yank', s.token, { yanked: true, reason: REASON });
    expect(one.statusCode).toBe(200);
    expect(json(await detail('alpha'))).toMatchObject({ state: 'yanked', group_id: s.gid });
  });
});

describe('a version a single publish made', () => {
  test('has no group_id key at all', async () => {
    const h = new Harness();
    const me = await h.account(1, 'octo', ['demo']);
    await h.publish(me.token, pkg({ name: 'demo', version: '1.0.0', subdir: 'noarch' }));
    await h.runValidator();
    await h.runIndexer();
    const r = await h.call('GET', '/api/v1/packages/demo/1.0.0');
    expect(r.statusCode).toBe(200);
    expect(json(r).state).toBe('published');
    expect(Object.keys(json(r))).not.toContain('group_id');
  });
});
