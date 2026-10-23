import type { VersionRecord } from '../../src/types';
import { validatePublish } from '../../src/publish/validator';
import { audit, rec } from '../helpers';
import { CASE_SINGLE_BEGIN, CASE_SINGLE_COMMIT, CASE_SINGLE_VALIDATOR, CASE_STATUS } from '../group-surfaces';
import { COMMITTED_AT, header, memberList } from '../group-rig';
import { Harness, pkg } from './harness';

/**
 * The single publish paths and the group's rows. A number a group holds is the group's: begin does not join it,
 * commit does not take it, the single validator does not fill, publish or burn it, whether the group has
 * committed or not, and whether it has a header or not. Each case runs against the three states a group's row can be in.
 */

type GroupState = 'staged, the group has not committed' | 'staged, the group has committed' | 'staged, and the group has no header';
const GROUP_STATES: GroupState[] = ['staged, the group has not committed', 'staged, the group has committed', 'staged, and the group has no header'];

function groupRow(): VersionRecord {
  return rec({ name: 'demo', version: '1.0.0', state: 'pending', group_id: 'g1', staged_attempt: 1, rev: 1, files: [], build: '', requires_mojo: '' });
}

function putGroup(h: Harness, state: GroupState) {
  if (state === 'staged, the group has not committed') h.registry.groups.put('grp#g1', { status: 'validating', attempt: 1 });
  if (state === 'staged, the group has committed') {
    h.registry.groups.put('grp#g1', header());
    h.registry.groups.put('grpm#g1', memberList('demo'));
  }
}

/** Replace a stored row without going through the store (the store does not let a single path do this on purpose). */
const overwrite = (h: Harness, row: VersionRecord) => (h.registry as unknown as { versions: Map<string, VersionRecord> }).versions.set(`${row.name}\0${row.canonical}`, structuredClone(row));

describe(CASE_SINGLE_BEGIN, () => {
  test.each(GROUP_STATES)('%s: begin answers version_exists and records no upload', async (state) => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await h.registry.createVersion(groupRow(), audit('demo', 'group_reserve', '1.0.0'));
    putGroup(h, state);
    const u = await h.upload(me.token, pkg({ name: 'demo', version: '1.0.0' }));
    expect(u.res.statusCode).toBe(409);
    expect(JSON.parse(u.res.body).error.code).toBe('version_exists');
    expect(h.publishes.uploads.size).toBe(0);
    expect(await h.registry.raw.rawGet('demo', '1.0.0')).toMatchObject({ group_id: 'g1', state: 'pending', rev: 1 });
  });

  test('a single pending number with no group is still joined by a second begin (the rule is about groups only)', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    expect((await h.upload(me.token, p)).res.statusCode).toBe(200);
    expect((await h.upload(me.token, p)).res.statusCode).toBe(200);
  });
});

describe(CASE_SINGLE_COMMIT, () => {
  test.each(GROUP_STATES)('%s: commit answers version_exists, takes no lock and creates no publish', async (state) => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const u = await h.upload(me.token, p);
    expect(u.res.statusCode).toBe(200);
    // The group reserves the number between the single's begin and commit.
    overwrite(h, { ...(await h.registry.raw.rawGet('demo', '1.0.0'))!, group_id: 'g1', staged_attempt: 1, rev: 1 });
    putGroup(h, state);
    const c = await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], p.manifest);
    expect(c.statusCode).toBe(409);
    expect(JSON.parse(c.body).error.code).toBe('version_exists');
    expect(h.publishes.publishes.size).toBe(0);
    expect(h.publishes.locks.size).toBe(0);
    expect(h.validateQueue.sent).toEqual([]);
    expect((await h.publishes.getUpload(u.upload_id!))!.used_by).toBeUndefined();
  });
});

describe(CASE_SINGLE_VALIDATOR, () => {
  test.each(GROUP_STATES)('%s: the validator throws, so the message is retried and dead-lettered, and touches nothing', async (state) => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const id = await h.publish(me.token, pkg({ name: 'demo', version: '1.0.0' }));
    overwrite(h, { ...(await h.registry.raw.rawGet('demo', '1.0.0'))!, group_id: 'g1', staged_attempt: 1, rev: 1 });
    putGroup(h, state);
    const before = await h.registry.raw.rawGet('demo', '1.0.0');
    await expect(validatePublish(h.validatorDeps, id)).rejects.toThrow('belongs to group g1');
    expect(await h.registry.raw.rawGet('demo', '1.0.0')).toEqual(before);
    expect([...h.objects.objects.keys()].filter((k) => !k.startsWith('quarantine/'))).toEqual([]);
    expect(await h.registry.listAudit('demo')).toHaveLength(1); // the begin's own row only
    expect(h.publishes.publishes.get(id)!.status).toBe('validating');
  });
});

describe(CASE_STATUS, () => {
  const record = (id: string) => ({
    publish_id: id,
    name: 'demo',
    version: '1.0.0',
    canonical: '1.0.0',
    actor: 'u:1',
    published_by: 'octocat',
    status: 'pending' as const,
    manifest_sha256: 'b'.repeat(64),
    files: [],
    remaining_subdirs: [],
    created_at: COMMITTED_AT,
    updated_at: COMMITTED_AT,
    rev: 0,
  });

  test.each(['grp#g1', 'grpm#g1', 'ver#demo#1.0.0', 'rl#u#1#2026-10-14', 'demo'])('%s is not a publish: 404 publish_not_found, even where the table holds a record under it for the caller', async (id) => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    h.publishes.publishes.set(id, record(id));
    const s = await h.status(me.token, encodeURIComponent(id));
    expect(s.statusCode).toBe(404);
    expect(s.body.error.code).toBe('publish_not_found');
  });

  test('a publish record is still read, by its pub_ id', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const id = await h.publish(me.token, pkg({ name: 'demo', version: '1.0.0' }));
    expect(id.startsWith('pub_')).toBe(true);
    const s = await h.status(me.token, id);
    expect(s.statusCode).toBe(200);
    expect(s.body).toMatchObject({ publish_id: id, name: 'demo', version: '1.0.0', status: 'pending' });
  });
});

describe('single publishes of rows without a group', () => {
  test('a whole publish, index and yank reads no group item', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await h.publish(me.token, pkg({ name: 'demo', version: '1.0.0' }));
    await h.runValidator();
    await h.runIndexer();
    expect((await h.call('PUT', '/api/v1/packages/demo/1.0.0/yank', me.token, { yanked: true, reason: 'x' })).statusCode).toBe(200);
    await h.runIndexer();
    expect((await h.call('GET', '/api/v1/packages/demo')).statusCode).toBe(200);
    expect((await h.call('GET', '/api/v1/packages', undefined)).statusCode).toBe(200);
    expect(h.registry.groups.reads).toEqual([]);
  });
});
