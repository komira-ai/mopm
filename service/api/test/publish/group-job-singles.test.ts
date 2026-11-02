import { validatePublish } from '../../src/publish/validator';
import { RIGS } from '../group-rig';
import { GroupEnv, json } from './group-env';
import { pkg } from './harness';
import { Scenario } from './group-scenario';

/**
 * Single publishes and group jobs share the registry and the channel but not a queue: a group's validation runs on the group
 * queue, a single's on the validate queue. Both registry adapters. The tests say what they prove.
 */

describe.each(RIGS)('singles while a group job runs: %s', (_label, make) => {
  /** begin, PUT, commit of one single publish; returns the validate message it queued. */
  async function publishSingle(env: GroupEnv, token: string, p: ReturnType<typeof pkg>) {
    const begun = await env.call('POST', `/api/v1/packages/${p.name}/${p.version}/files`, token, { subdir: p.subdir, filename: p.filename, sha256: p.sha256, size: p.bytes.length });
    expect(begun.statusCode).toBe(200);
    const uploadId = json(begun).upload_id as string;
    await env.objects.put((await env.publishes.getUpload(uploadId))!.key, p.bytes, { contentType: 'application/octet-stream' });
    const committed = await env.call('POST', `/api/v1/packages/${p.name}/${p.version}/publish`, token, { upload_ids: [uploadId], manifest_sha256: p.manifest });
    expect(committed.statusCode).toBe(202);
  }
  const runSingle = (env: GroupEnv) => {
    const m = env.validateQueue.take()!;
    return validatePublish(
      { registry: env.rig.store, publishes: env.publishes, objects: env.objects, indexQueue: env.indexQueue, config: env.config, channelUrl: 'https://conda.example.invalid', now: env.clock.now, log: () => undefined },
      JSON.parse(m.body).publish_id,
    );
  };

  test('a single publish is validated and published while a group is half way through its job, on queues that never meet', async () => {
    const env = new GroupEnv(make(), { groupBudgetMs: 1000 });
    const group = await new Scenario(env, Array.from({ length: 4 }, (_x, i) => ({ name: `pkg${i}` }))).start();
    let t = 0;
    const over = { clock: () => (t += 600) };
    expect(await env.runGroupJob(over)).toBe('requeued');
    expect((await group.header())!.status).toBe('validating');

    // Another package, another account: a single publish end to end, with the group's continuation waiting on its own queue.
    const solo = pkg({ name: 'solo', version: '1.0.0', subdir: 'noarch' });
    const token = await env.account(5, 'solo-owner', ['solo']);
    await publishSingle(env, token, solo);
    expect(env.groupQueue.sent).toHaveLength(1);
    expect(env.validateQueue.sent).toHaveLength(1);
    expect(JSON.parse(env.groupQueue.sent[0]!.body).type).toBe('validate_group');
    expect(JSON.parse(env.validateQueue.sent[0]!.body).type).toBe('validate');
    expect(await runSingle(env)).toBe('processed');
    expect((await env.rig.store.getVersion('solo', '1.0.0'))!.state).toBe('published');
    // The group's job was not touched: its continuation is still there and its progress is as it was.
    expect(env.groupQueue.sent).toHaveLength(1);
    expect((await group.header())!.status).toBe('validating');

    expect((await env.runGroupJobs(over)).pop()).toBe('committed');
    expect((await group.header())!.committed_at).toBeDefined();
    expect(env.validateQueue.sent).toEqual([]);
  });

  test('a single publish of another version of a package the group holds is not in the group\'s way, and the group\'s totals count it', async () => {
    const env = new GroupEnv(make());
    const group = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
    const later = pkg({ name: 'alpha', version: '2.0.0', subdir: 'noarch' });
    await publishSingle(env, group.token, later);
    expect(await runSingle(env)).toBe('processed');
    expect((await env.rig.store.getVersion('alpha', '2.0.0'))!.state).toBe('published');
    expect(await group.runAll()).toEqual(['committed']);
    expect((await group.shown('alpha'))!.state).toBe('published');
    expect((await env.rig.store.listVersions('alpha')).map((v) => v.version)).toEqual(['1.0.0', '2.0.0']);
  });

  test('a single publish of the number a group holds is refused whatever stage the group is in, and a group job never touches a single\'s publish', async () => {
    const env = new GroupEnv(make());
    const group = await new Scenario(env, [{ name: 'alpha' }]).start();
    const clash = await env.begin(group.token, 'alpha');
    expect(clash.statusCode).toBe(409);
    expect(env.validateQueue.sent).toEqual([]);
    expect(await group.runAll()).toEqual(['committed']);
    expect((await env.begin(group.token, 'alpha')).statusCode).toBe(409);
    expect(env.validateQueue.sent).toEqual([]);
  });
});
