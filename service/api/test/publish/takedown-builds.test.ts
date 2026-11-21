import { queueTakedownIndex } from '../../src/publish/takedown';
import { audit, buildFile, buildRow } from '../helpers';
import { Harness, pkg } from './harness';

const lines = (text: string): any[] => text.split('\n').slice(0, -1).map((l) => JSON.parse(l));

describe('the takedown of a version that has an added build', () => {
  test('the rebuilds cover the platform of the added build, and the index line and takedowns.json list every file of every build', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0', subdir: 'linux-64', compiler: '1.0.0' });
    const id = await h.publish(me.token, p);
    await h.runValidator();
    await h.runIndexer();
    expect((await h.status(me.token, id)).body.status).toBe('published');

    // A build for another Mojo, for another platform, added to the published version.
    const added = buildRow('demo', '1.0.0', 'mojo1.1.0_0', { files: [buildFile('demo', '1.0.0', 'mojo1.1.0_0', 'osx-arm64', 'b')] });
    await h.registry.createVersion(added, audit('demo', 'publish_add', '1.0.0'));
    await h.registry.updateVersion('demo', '1.0.0', { type: 'tombstone', reason_code: 'malware', date: '2026-11-12' }, audit('demo', 'takedown', '1.0.0'));

    await queueTakedownIndex({ registry: h.registry, indexQueue: h.indexQueue }, 'demo');
    expect(h.indexQueue.sent.map((m) => m.groupId).sort()).toEqual(expect.arrayContaining(['linux-64', 'osx-arm64', 'pkg:demo', 'takedowns']));
    await h.runIndexer();

    const [line] = lines(h.indexFile('demo')!);
    expect(line).toMatchObject({ version: '1.0.0', state: 'tombstoned', build: 'mojo1.0.0_0' });
    expect(line.files).toEqual([{ subdir: 'linux-64', filename: p.filename, sha256: p.sha256, size: p.bytes.length }]);
    expect(line).not.toHaveProperty('builds'); // a package of a flat name is index version 1
    expect(h.repodata('osx-arm64').removed).toEqual(['mojo-demo-1.0.0-mojo1.1.0_0.conda']);
    expect(h.repodata('linux-64').removed).toEqual([p.filename]);

    const log = JSON.parse(h.objects.objects.get('index/takedowns.json')!.body.toString('utf8'));
    expect(log.takedowns).toHaveLength(1);
    expect([...log.takedowns[0].sha256].sort()).toEqual([p.sha256, 'b'.repeat(64)].sort());
  });
});
