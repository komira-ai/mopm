import { RIGS } from '../group-rig';
import { errorCode, GroupEnv, json } from './group-env';
import { Scenario } from './group-scenario';
import { Harness, pkg } from './harness';

/**
 * `source_commit` of a commit request (src/publish/source-commit.ts): the git commit the publisher says the version was built
 * from. Optional, typed, written once with the version, served by getVersion, never verified. Each test says what it proves.
 */

const SHA1 = 'a'.repeat(40);
const SHA256 = '0123456789abcdef'.repeat(4);
const OTHER = 'b'.repeat(40);

/** Each value the field refuses, and why a reader would think it fine. */
const INVALID: Array<[string, unknown]> = [
  ['uppercase hex', 'A'.repeat(40)],
  ['mixed case hex', `${'a'.repeat(39)}A`],
  ['39 digits', 'a'.repeat(39)],
  ['41 digits', 'a'.repeat(41)],
  ['63 digits', 'a'.repeat(63)],
  ['65 digits', 'a'.repeat(65)],
  ['a short id', 'abc1234'],
  ['an empty string', ''],
  ['a non-hex character', `${'a'.repeat(39)}g`],
  ['surrounding space', ` ${'a'.repeat(40)}`],
  ['a trailing newline', `${'a'.repeat(40)}\n`],
  ['a number', 1234],
  ['an object', { sha: SHA1 }],
  ['an array', [SHA1]],
  ['a boolean', true],
  ['null', null],
];

async function single(extra: Record<string, unknown>) {
  const h = new Harness();
  const me = await h.account(1, 'a', ['demo']);
  const p = pkg({ name: 'demo', version: '1.0.0' });
  const u = await h.upload(me.token, p);
  const res = await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], p.manifest, extra);
  return { h, me, p, u, res };
}
const served = async (h: Harness) => JSON.parse((await h.call('GET', '/api/v1/packages/demo/1.0.0')).body) as Record<string, unknown>;

describe('source_commit on the commit of a single publish', () => {
  test.each([['40 digits', SHA1], ['64 digits', SHA256]])('%s is stored on the version and served by getVersion', async (_n, value) => {
    const { h, res } = await single({ source_commit: value });
    expect(res.statusCode).toBe(202);
    await h.runValidator();
    await h.runIndexer();
    expect(await h.registry.getVersion('demo', '1.0.0')).toMatchObject({ state: 'published', source_commit: value });
    expect((await served(h)).source_commit).toBe(value);
  });

  test('a commit without it publishes a version without it: the key is absent from the row and from getVersion', async () => {
    const { h, res } = await single({});
    expect(res.statusCode).toBe(202);
    await h.runValidator();
    expect(await h.registry.getVersion('demo', '1.0.0')).not.toHaveProperty('source_commit');
    expect(await served(h)).not.toHaveProperty('source_commit');
  });

  test.each(INVALID)('%s is refused 400 invalid_request and nothing is queued', async (_why, value) => {
    const { h, res } = await single({ source_commit: value });
    expect(res.statusCode).toBe(400);
    expect(errorCode(res)).toBe('invalid_request');
    expect(JSON.parse(res.body).error.message).toContain('source_commit');
    expect(h.validateQueue.take()).toBeUndefined();
  });

  test('yank and unyank leave the stored value as it was, in the row and in getVersion', async () => {
    const { h } = await single({ source_commit: SHA1 });
    await h.runValidator();
    await h.runIndexer();
    const yank = await h.token(1, ['demo'], ['publish', 'yank']);
    expect((await h.call('PUT', '/api/v1/packages/demo/1.0.0/yank', yank, { yanked: true, reason: 'broken build' })).statusCode).toBe(200);
    expect(await h.registry.getVersion('demo', '1.0.0')).toMatchObject({ state: 'yanked', source_commit: SHA1 });
    expect((await served(h)).source_commit).toBe(SHA1);
    expect((await h.call('PUT', '/api/v1/packages/demo/1.0.0/yank', yank, { yanked: false })).statusCode).toBe(200);
    expect(await h.registry.getVersion('demo', '1.0.0')).toMatchObject({ state: 'published', source_commit: SHA1 });
    expect((await served(h)).source_commit).toBe(SHA1);
  });

  test('the registry does not check the value against anything: a commit that is in no repository is stored as it is', async () => {
    const { h } = await single({ source_commit: '0'.repeat(40) });
    await h.runValidator();
    expect((await served(h)).source_commit).toBe('0'.repeat(40));
  });

  test('the same commit again with the same value resumes the publish; with another value, or none, it is refused and the stored value stays', async () => {
    const { h, me, p, u, res } = await single({ source_commit: SHA1 });
    const id = JSON.parse(res.body).publish_id;
    const again = await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], p.manifest, { source_commit: SHA1 });
    expect(again.statusCode).toBe(202);
    expect(JSON.parse(again.body).publish_id).toBe(id);
    for (const extra of [{ source_commit: OTHER }, {}]) {
      const r = await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], p.manifest, extra);
      expect(r.statusCode).toBe(409);
      expect(errorCode(r)).toBe('version_exists');
    }
    await h.runValidator();
    expect((await served(h)).source_commit).toBe(SHA1);
  });

  test('a commit without a value, repeated with one, is refused: the version is written without it, once', async () => {
    const { h, me, p, u } = await single({});
    const r = await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], p.manifest, { source_commit: SHA1 });
    expect(errorCode(r)).toBe('version_exists');
    await h.runValidator();
    expect(await served(h)).not.toHaveProperty('source_commit');
  });
});

describe.each(RIGS)('source_commit on the commit of a group: %s', (_label, make) => {
  let env: GroupEnv;
  beforeEach(() => {
    env = new GroupEnv(make());
  });
  const withValues = (s: Scenario, values: Record<string, unknown>) => ({
    members: s.pkgs.map((p) => ({ name: p.name, manifest_sha256: p.manifest, ...(p.name in values ? { source_commit: values[p.name] } : {}) })),
  });
  const get = async (name: string) => json(await env.call('GET', `/api/v1/packages/${name}/1.0.0`));

  test('a member\'s 40 or 64 digit value lands on that member\'s version only, and a member without one has none', async () => {
    const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }, { name: 'gamma' }]).create();
    await s.upload();
    expect((await s.commit(withValues(s, { alpha: SHA1, beta: SHA256 }))).statusCode).toBe(202);
    expect(await s.runAll()).toEqual(['committed']);
    expect((await get('alpha')).source_commit).toBe(SHA1);
    expect((await get('beta')).source_commit).toBe(SHA256);
    expect(await get('gamma')).not.toHaveProperty('source_commit');
    expect(await s.row('alpha')).toMatchObject({ source_commit: SHA1 });
    expect(await s.row('gamma')).not.toHaveProperty('source_commit');
  });

  test('a group without any value publishes versions without it', async () => {
    const s = await new Scenario(env, [{ name: 'alpha' }]).start();
    expect(await s.runAll()).toEqual(['committed']);
    expect(await get('alpha')).not.toHaveProperty('source_commit');
  });

  test.each(INVALID)('%s on a member is refused 400 invalid_request, naming the member, and the group stays open', async (_why, value) => {
    const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
    await s.upload();
    const r = await s.commit(withValues(s, { beta: value }));
    expect(r.statusCode).toBe(400);
    expect(errorCode(r)).toBe('invalid_request');
    expect(json(r).error.message).toContain("'source_commit' of 'beta'");
    expect((await s.header())!.status).toBe('open');
    expect(env.groupQueue.sent).toEqual([]);
  });

  test('the same request again is accepted; a request that differs only in a member\'s value is refused group_commit_refused', async () => {
    const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
    await s.upload();
    expect((await s.commit(withValues(s, { alpha: SHA1 }))).statusCode).toBe(202);
    expect((await s.commit(withValues(s, { alpha: SHA1 }))).statusCode).toBe(202);
    for (const values of [{ alpha: OTHER }, {}, { alpha: SHA1, beta: SHA1 }]) {
      const r = await s.commit(withValues(s, values));
      expect(r.statusCode).toBe(409);
      expect(errorCode(r)).toBe('group_commit_refused');
    }
    expect(await s.runAll()).toEqual(['committed']);
    expect((await get('alpha')).source_commit).toBe(SHA1);
    expect(await get('beta')).not.toHaveProperty('source_commit');
  });
});
