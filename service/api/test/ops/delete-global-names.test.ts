import { authTablesFor, DynamoAuthStore } from '../../src/auth/dynamo-auth-store';
import { MemoryAuthStore } from '../../src/auth/memory-auth-store';
import type { AuthStore } from '../../src/auth/types';
import { indexKey } from '../../src/index-files';
import { main, PROBE_NAME, realDeps, stageChecks } from '../../src/ops/delete-global-names/main';
import { digestOf, listStage, parseDeleteArgs, runDelete, withoutName, type DeleteArgs, type DeleteDeps, type StageChecks } from '../../src/ops/delete-global-names/tool';
import type { HttpFn } from '../../src/publish/aws';
import { MemoryObjectStore } from '../../src/publish/memory';
import { buildRepodata, buildRepodataJson } from '../../src/repodata';
import type { VersionRecord } from '../../src/types';
import { zstdFrame } from '../../src/zstd';
import { FakeAuthDoc } from '../auth-fake-doc';
import { RIGS, type Rig } from '../group-rig';
import { hex, rec } from '../helpers';

/**
 * The held tool that deletes the global names (src/ops/delete-global-names, docs/design/namespaces.md section 12.4), against
 * fake stores: both registry adapters (memory, and DynamoDB over the in-process client), both auth adapters, an in-memory
 * bucket and a recording invalidator. Nothing here reaches a stage. Each test says what it proves.
 */

const BUILD = 'mojo1.0.0_0';
const conda = (subdir: string, name: string, version: string) => `${subdir}/mojo-${name}-${version}-${BUILD}.conda`;
const BASE = { bucket: 'channel', distribution: 'DIST', configUrl: 'https://api.example.invalid/index/config.json' };
const PASSING: StageChecks = { index_versions: [1, 2], v1_refuses_flat_creation: true };

describe('the flags', () => {
  const ok = ['--stage=beta', '--bucket=b', '--distribution=d', '--config-url=https://x.invalid/index/config.json'];
  test('are parsed: a dry run unless --apply names a digest', () => {
    expect(parseDeleteArgs(ok)).toEqual({ stage: 'beta', bucket: 'b', distribution: 'd', configUrl: 'https://x.invalid/index/config.json' });
    expect(parseDeleteArgs([...ok, '--region=eu-west-1', `--apply=${'a'.repeat(64)}`])).toEqual({
      stage: 'beta',
      bucket: 'b',
      distribution: 'd',
      configUrl: 'https://x.invalid/index/config.json',
      region: 'eu-west-1',
      apply: 'a'.repeat(64),
    });
  });

  test('every mistake is an error that says what is wrong', () => {
    for (const [argv, why] of [
      [[], '--stage is beta, gamma or prod'],
      [['--stage=dev', ...ok.slice(1)], '--stage is beta, gamma or prod'],
      [ok.slice(0, 1), '--bucket is required'],
      [[ok[0]!, ok[1]!, ok[3]!], '--distribution is required'],
      [ok.slice(0, 3), '--config-url is required'],
      [[...ok, 'prod'], 'not a flag with a value: prod'],
      [[...ok, '--apply'], 'not a flag with a value: --apply'],
      [[...ok, '--apply=abc'], '--apply takes the 64 hex digits'],
      [[...ok, '--force=1'], 'unknown flag --force'],
      [[...ok, '--stage=prod'], '--stage is given twice'],
    ] as Array<[string[], string]>) {
      expect(() => parseDeleteArgs(argv)).toThrow(why);
    }
  });
});

describe('withoutName', () => {
  test('drops the name from both package tables and from removed, and keeps every other entry byte for byte', () => {
    const before = {
      info: { subdir: 'linux-64' },
      packages: { 'mojo-json-0.0.1-x.tar.bz2': { name: 'mojo-json' }, 'mojo-jsonx-1-x.tar.bz2': { name: 'mojo-jsonx' } },
      'packages.conda': { 'mojo-json-0.1.0-x.conda': { name: 'mojo-json' }, 'mojo-json_ext-0.1.0-x.conda': { name: 'mojo-json_ext' } },
      removed: ['mojo-json-0.2.0-x.conda', 'mojo-json_ext-0.0.1-x.conda'],
    };
    expect(JSON.parse(withoutName(Buffer.from(JSON.stringify(before)), 'json')!)).toEqual({
      info: { subdir: 'linux-64' },
      packages: { 'mojo-jsonx-1-x.tar.bz2': { name: 'mojo-jsonx' } },
      'packages.conda': { 'mojo-json_ext-0.1.0-x.conda': { name: 'mojo-json_ext' } },
      removed: ['mojo-json_ext-0.0.1-x.conda'],
    });
  });

  test('a repodata that does not list the name, or has none of the tables, gives undefined: nothing to write', () => {
    expect(withoutName(Buffer.from(buildRepodataJson('noarch', [rec({ name: 'other', version: '1.0.0' })])), 'json')).toBeUndefined();
    expect(withoutName(Buffer.from('{"info":{"subdir":"noarch"}}'), 'json')).toBeUndefined();
    // Only `removed` names it: still a change.
    expect(withoutName(Buffer.from('{"removed":["mojo-json-1-x.conda"]}'), 'json')).toBe('{"removed":[]}');
  });
});

describe.each(RIGS)('the deletion: %s', (label, make) => {
  let rig: Rig;
  let auth: AuthStore;
  let bucket: MemoryObjectStore;
  let ops: string[];
  let out: Array<Record<string, unknown>>;
  let checks: StageChecks;
  let failAt: string | undefined;
  let onOp: ((op: string) => Promise<void>) | undefined;

  const record = async (op: string) => {
    ops.push(op);
    await onOp?.(op);
    if (op === failAt) throw new Error(`stopped at ${op}`);
  };

  const deps = (): DeleteDeps => ({
    registry: {
      listPackageNames: () => rig.store.listPackageNames(),
      listVersions: (n) => rig.store.listVersions(n),
      listOwners: (n) => rig.store.listOwners(n),
      appendAudit: async (e) => {
        await record(`audit ${e.name}`);
        await rig.store.appendAudit(e);
      },
      removeOwner: async (n, id) => {
        await record(`owner ${n} ${id}`);
        await rig.store.removeOwner(n, id);
      },
      deleteVersionRow: async (n, v) => {
        await record(`version ${n} ${v}`);
        await rig.store.deleteVersionRow(n, v);
      },
      deletePackageRow: async (n) => {
        await record(`package ${n}`);
        await rig.store.deletePackageRow(n);
      },
    },
    publishers: {
      listTrustedPublishers: (n) => auth.listTrustedPublishers(n),
      removeTrustedPublisher: async (n, id) => {
        await record(`publisher ${n} ${id}`);
        await auth.removeTrustedPublisher(n, id);
      },
    },
    bucket: {
      list: (p) => bucket.list(p),
      head: (k) => bucket.head(k),
      get: (k) => bucket.get(k),
      put: async (k, b, o) => {
        await record(`put ${k}`);
        return bucket.put(k, b, o);
      },
      delete: async (k) => {
        await record(`delete ${k}`);
        await bucket.delete(k);
      },
    },
    invalidator: { invalidate: async (paths, ref) => record(`invalidate ${ref} ${paths.join(',')}`) },
    checks: async () => checks,
    now: () => new Date('2026-11-14T12:00:00Z'),
    out: (l) => out.push(l),
  });

  const run = (over: Partial<DeleteArgs> = {}) => runDelete({ stage: 'beta', ...BASE, ...over }, deps());
  const dryRunDigest = async (over: Partial<DeleteArgs> = {}) => {
    out = [];
    expect(await run(over)).toBe(0);
    return out.find((l) => l.kind === 'digest')!.digest as string;
  };

  /** One version row, with its files in the bucket. */
  async function version(name: string, v: string, subdirs: string[], over: Partial<VersionRecord> = {}) {
    const files = subdirs.map((subdir) => ({ subdir, filename: conda(subdir, name, v).split('/')[1]!, sha256: hex('a'), size: 3, url: `https://conda.example.invalid/${conda(subdir, name, v)}` }));
    rig.writeRow(rec({ name, version: v, build: BUILD, files, ...over }));
    for (const s of subdirs) await bucket.put(conda(s, name, v), Buffer.from('abc'), { contentType: 'application/octet-stream' });
  }

  /** The root repodata of every subdir the rows name, as the index writer would build it. */
  async function writeRepodata() {
    const rows = (await Promise.all((await rig.store.listPackageNames()).map((n) => rig.store.listVersions(n)))).flat();
    for (const subdir of ['linux-64', 'linux-aarch64', 'noarch', 'osx-arm64', 'win-64']) {
      const files = buildRepodata(subdir, rows.filter((r) => !r.name.includes('/')));
      await bucket.put(`${subdir}/repodata.json`, files.json, { contentType: 'application/json' });
      await bucket.put(`${subdir}/repodata.json.zst`, files.zst, { contentType: 'application/zstd' });
    }
  }

  /**
   * The stage: two flat packages (`json`, with a yanked version and two subdirs; `http_client`, with a file in a subdir that
   * is not one of version 1's), a kci package, a namespaced package with its own channel and index files, files and an
   * index file of a flat name with no rows (`orphan`), and keys at the root that are no flat package's file.
   */
  beforeEach(async () => {
    rig = make();
    auth = label === 'memory' ? new MemoryAuthStore() : new DynamoAuthStore(new FakeAuthDoc({ pageSize: 2 }), authTablesFor('t'));
    bucket = new MemoryObjectStore();
    ops = [];
    out = [];
    checks = PASSING;
    failAt = undefined;
    onOp = undefined;
    for (const name of ['json', 'http_client', 'kci_api', 'komira-ai/json']) {
      await rig.store.createPackage({ name, state: 'active', created_at: '2026-11-01T00:00:00Z' });
    }
    await version('json', '0.1.0', ['linux-64', 'osx-arm64']);
    await version('json', '0.2.0', ['linux-64'], { state: 'yanked', yank_reason: 'broken' });
    await version('http_client', '1.0.0', ['linux-64', 'win-64']);
    await version('kci_api', '0.1.337', ['linux-64']);
    rig.writeRow(rec({ name: 'komira-ai/json', version: '0.1.0', files: [] }));
    for (const [name, id] of [['json', 7], ['http_client', 7], ['http_client', 9], ['kci_api', 7]] as Array<[string, number]>) {
      await rig.store.addOwner({ name, github_id: id, handle: `user${id}`, added_at: '2026-11-01T00:00:00Z' });
    }
    for (const name of ['json', 'kci_api']) {
      await auth.addTrustedPublisher({ id: 'tp_1', name, repository_id: '11', repository_owner_id: '12', workflow: '.github/workflows/release.yml', added_by: 7, added_at: '2026-11-01T00:00:00Z' });
    }
    for (const name of ['json', 'http_client', 'kci_api', 'orphan']) await bucket.put(indexKey(name), Buffer.from('{}\n'), { contentType: 'application/x-ndjson' });
    for (const key of [
      'noarch/mojo-orphan-1.0.0-mojo1.0.0_0.conda',
      'komira-ai/linux-64/mojo-komira-ai.json-0.1.0-mojo1.0.0_0.conda',
      'index/v2/ko/mi/komira-ai/json',
      'index/takedowns.json',
      'index/ab/cd/xyz',
      'linux-64/mojo-Bad-1.0.0-x.conda',
      'linux-64/mojo-json-0.1.0-x.tar.bz2',
    ]) {
      await bucket.put(key, Buffer.from('xy'), { contentType: 'application/octet-stream' });
    }
    await writeRepodata();
    ops = [];
  });

  /** Everything the tool could change, to compare before and after. */
  async function state() {
    const names = await rig.store.listPackageNames();
    const all = [...new Set([...names, 'json', 'http_client', 'kci_api', 'orphan'])].sort();
    return {
      names,
      objects: [...bucket.objects.entries()].map(([k, v]) => `${k} ${v.body.toString('base64')}`).sort(),
      rows: await Promise.all(all.map(async (n) => [n, (await rig.store.listVersions(n)).map((r) => r.version), (await rig.store.listOwners(n)).map((o) => o.github_id), (await auth.listTrustedPublishers(n)).map((p) => p.id)])),
      audit: await Promise.all(all.map((n) => rig.store.listAudit(n))),
    };
  }

  const repodataNames = async (subdir: string) => {
    const doc = JSON.parse((await bucket.get(`${subdir}/repodata.json`))!.toString()) as { 'packages.conda': Record<string, { name: string }>; removed: string[] };
    return { conda: Object.values(doc['packages.conda']).map((e) => e.name).sort(), removed: doc.removed };
  };

  describe('the dry run', () => {
    test('lists every flat name with its rows, files and index file, keeps kci_ names out, ignores namespaced names and other keys, and changes nothing', async () => {
      const before = await state();
      expect(await run()).toBe(0);
      expect(ops).toEqual([]);
      expect(await state()).toEqual(before);
      expect(out.filter((l) => l.kind === 'name')).toEqual([
        {
          kind: 'name',
          name: 'http_client',
          package: true,
          versions: ['1.0.0 published'],
          owners: ['user7', 'user9'],
          publishers: [],
          objects: 2,
          bytes: 6,
          index: 'index/ht/tp/http_client',
        },
        {
          kind: 'name',
          name: 'json',
          package: true,
          versions: ['0.1.0 published', '0.2.0 yanked'],
          owners: ['user7'],
          publishers: ['tp_1'],
          objects: 3,
          bytes: 9,
          index: 'index/js/on/json',
        },
        { kind: 'name', name: 'orphan', package: false, versions: [], owners: [], publishers: [], objects: 1, bytes: 2, index: 'index/or/ph/orphan' },
      ]);
      expect(out.filter((l) => l.kind !== 'name')).toEqual([
        { kind: 'kept', name: 'kci_api', reason: 'kci_ packages are kept' },
        { kind: 'checks', ...PASSING },
        { kind: 'totals', stage: 'beta', names: 3, packages: 2, versions: 3, owners: 3, publishers: 1, objects: 6, bytes: 17, index_files: 3, kept: 1 },
        { kind: 'digest', digest: expect.stringMatching(/^[0-9a-f]{64}$/), dry_run: true },
      ]);
    });

    test('the digest is the same for the same stage and data, and differs for another stage', async () => {
      const d1 = await dryRunDigest();
      expect(await dryRunDigest()).toBe(d1);
      expect(await dryRunDigest({ stage: 'gamma' })).not.toBe(d1);
      expect(digestOf(await listStage('beta', deps()))).toBe(d1);
    });

    test('runs whatever the stage checks say, and reports them', async () => {
      checks = { index_versions: [1], v1_refuses_flat_creation: false };
      expect(await run()).toBe(0);
      expect(out.find((l) => l.kind === 'checks')).toEqual({ kind: 'checks', index_versions: [1], v1_refuses_flat_creation: false });
    });
  });

  describe('apply', () => {
    test('deletes each flat name in the order of the design: audit, index and repodata, files, rows, the package row last', async () => {
      const digest = await dryRunDigest();
      out = [];
      expect(await run({ apply: digest })).toBe(0);
      const ref = (n: string) => `delete_global-${n}-${digest.slice(0, 16)}`;
      expect(ops).toEqual([
        'audit http_client',
        'delete index/ht/tp/http_client',
        'put linux-64/repodata.json',
        'put linux-64/repodata.json.zst',
        'put win-64/repodata.json',
        'put win-64/repodata.json.zst',
        'delete linux-64/mojo-http_client-1.0.0-mojo1.0.0_0.conda',
        'delete win-64/mojo-http_client-1.0.0-mojo1.0.0_0.conda',
        `invalidate ${ref('http_client')} /index/ht/tp/http_client,/linux-64/repodata.json,/linux-64/repodata.json.zst,/win-64/repodata.json,/win-64/repodata.json.zst,/linux-64/mojo-http_client-1.0.0-mojo1.0.0_0.conda,/win-64/mojo-http_client-1.0.0-mojo1.0.0_0.conda`,
        'version http_client 1.0.0',
        'owner http_client 7',
        'owner http_client 9',
        'package http_client',
        'audit json',
        'delete index/js/on/json',
        'put linux-64/repodata.json',
        'put linux-64/repodata.json.zst',
        'put osx-arm64/repodata.json',
        'put osx-arm64/repodata.json.zst',
        'delete linux-64/mojo-json-0.1.0-mojo1.0.0_0.conda',
        'delete linux-64/mojo-json-0.2.0-mojo1.0.0_0.conda',
        'delete osx-arm64/mojo-json-0.1.0-mojo1.0.0_0.conda',
        `invalidate ${ref('json')} /index/js/on/json,/linux-64/repodata.json,/linux-64/repodata.json.zst,/osx-arm64/repodata.json,/osx-arm64/repodata.json.zst,/linux-64/mojo-json-0.1.0-mojo1.0.0_0.conda,/linux-64/mojo-json-0.2.0-mojo1.0.0_0.conda,/osx-arm64/mojo-json-0.1.0-mojo1.0.0_0.conda`,
        'version json 0.1.0',
        'version json 0.2.0',
        'owner json 7',
        'publisher json tp_1',
        'package json',
        // No rows and a repodata that never listed it: the index file and the file, nothing else.
        'audit orphan',
        'delete index/or/ph/orphan',
        'delete noarch/mojo-orphan-1.0.0-mojo1.0.0_0.conda',
        `invalidate ${ref('orphan')} /index/or/ph/orphan,/noarch/mojo-orphan-1.0.0-mojo1.0.0_0.conda`,
      ]);
      expect(out[out.length - 1]).toEqual({ kind: 'done', stage: 'beta', names: 3, digest });
      expect(out.filter((l) => l.kind === 'deleted').map((l) => l.name)).toEqual(['http_client', 'json', 'orphan']);
    });

    test('leaves the kci_ package, the namespaced package and every other key as they were, and the audit log keeps a delete_global record', async () => {
      const digest = await dryRunDigest();
      expect(await run({ apply: digest })).toBe(0);
      expect(await rig.store.listPackageNames()).toEqual(['kci_api', 'komira-ai/json']);
      for (const n of ['json', 'http_client']) {
        expect(await rig.store.listVersions(n)).toEqual([]);
        expect(await rig.store.listOwners(n)).toEqual([]);
        expect(await auth.listTrustedPublishers(n)).toEqual([]);
      }
      expect((await rig.store.listVersions('kci_api')).map((r) => r.version)).toEqual(['0.1.337']);
      expect((await rig.store.listOwners('kci_api')).map((o) => o.github_id)).toEqual([7]);
      expect((await auth.listTrustedPublishers('kci_api')).map((p) => p.id)).toEqual(['tp_1']);
      expect(bucket.keys().filter((k) => !k.includes('repodata.json'))).toEqual([
        'index/ab/cd/xyz',
        'index/kc/i_/kci_api',
        'index/takedowns.json',
        'index/v2/ko/mi/komira-ai/json',
        'komira-ai/linux-64/mojo-komira-ai.json-0.1.0-mojo1.0.0_0.conda',
        'linux-64/mojo-Bad-1.0.0-x.conda',
        'linux-64/mojo-json-0.1.0-x.tar.bz2',
        'linux-64/mojo-kci_api-0.1.337-mojo1.0.0_0.conda',
      ]);
      expect(await repodataNames('linux-64')).toEqual({ conda: ['mojo-kci_api'], removed: [] });
      expect(await repodataNames('osx-arm64')).toEqual({ conda: [], removed: [] });
      // The .zst is the same bytes as the JSON it sits beside.
      expect(await bucket.get('linux-64/repodata.json.zst')).toEqual(zstdFrame((await bucket.get('linux-64/repodata.json'))!));
      const audit = await rig.store.listAudit('json');
      expect(audit[audit.length - 1]).toEqual({
        name: 'json',
        ts: '2026-11-14T12:00:00.000Z',
        id: `delete_global_${digest.slice(0, 16)}`,
        actor: 'operator',
        action: 'delete_global',
        detail: { stage: 'beta', digest, versions: '2', objects: '3' },
      });
    });

    test('a run with nothing left lists nothing, and applying that listing does nothing and succeeds', async () => {
      expect(await run({ apply: await dryRunDigest() })).toBe(0);
      const digest = await dryRunDigest();
      expect(out.find((l) => l.kind === 'totals')).toMatchObject({ names: 0, versions: 0, objects: 0, kept: 1 });
      ops = [];
      out = [];
      expect(await run({ apply: digest })).toBe(0);
      expect(ops).toEqual([]);
      expect(out).toEqual([{ kind: 'done', stage: 'beta', names: 0, digest }]);
    });

    test('a subdir whose root repodata is missing is skipped: no repodata is written for it', async () => {
      await bucket.delete('win-64/repodata.json');
      ops = [];
      expect(await run({ apply: await dryRunDigest() })).toBe(0);
      expect(ops.filter((o) => o.startsWith('put win-64'))).toEqual([]);
      expect(ops).toContain('delete win-64/mojo-http_client-1.0.0-mojo1.0.0_0.conda');
    });
  });

  describe('the digest refusal', () => {
    const refusedUnchanged = async (digest: string, over: Partial<DeleteArgs> = {}) => {
      const before = await state();
      ops = [];
      out = [];
      expect(await run({ apply: digest, ...over })).toBe(2);
      expect(ops).toEqual([]);
      expect(await state()).toEqual(before);
      expect(out).toEqual([{ kind: 'refused', reason: "the listing is not the dry run's: run the dry run again and read it", expected: digest, listed: expect.stringMatching(/^[0-9a-f]{64}$/) }]);
    };

    test('a version published after the dry run stops it, and nothing is deleted', async () => {
      const digest = await dryRunDigest();
      await version('json', '0.3.0', ['noarch']);
      await refusedUnchanged(digest);
    });

    test('a flat package created after the dry run stops it', async () => {
      const digest = await dryRunDigest();
      await rig.store.createPackage({ name: 'late', state: 'claimed', created_at: '2026-11-14T00:00:00Z' });
      await refusedUnchanged(digest);
    });

    test('a file put at the root, or an owner added, after the dry run stops it', async () => {
      const digest = await dryRunDigest();
      await bucket.put('noarch/mojo-json-0.0.9-mojo1.0.0_0.conda', Buffer.from('z'), { contentType: 'application/octet-stream' });
      await refusedUnchanged(digest);
      await bucket.delete('noarch/mojo-json-0.0.9-mojo1.0.0_0.conda');
      await rig.store.addOwner({ name: 'json', github_id: 8, handle: 'user8', added_at: '2026-11-14T00:00:00Z' });
      await refusedUnchanged(digest);
    });

    test("another stage's digest is refused, though the data is the same", async () => {
      await refusedUnchanged(await dryRunDigest({ stage: 'gamma' }), { stage: 'beta' });
    });

    test('a change to a kept kci_ package or a namespaced one does not change the digest', async () => {
      const digest = await dryRunDigest();
      await version('kci_api', '0.1.338', ['linux-64']);
      await version('komira-ai/json', '0.2.0', []);
      expect(await dryRunDigest()).toBe(digest);
    });
  });

  describe('the stage checks', () => {
    test.each([
      ['index version 2 is not served', { index_versions: [1], v1_refuses_flat_creation: true }],
      ['/api/v1 still creates flat names', { index_versions: [1, 2], v1_refuses_flat_creation: false }],
    ])('%s: refused, and nothing is deleted', async (_why, failing) => {
      const digest = await dryRunDigest();
      checks = failing;
      const before = await state();
      ops = [];
      out = [];
      expect(await run({ apply: digest })).toBe(2);
      expect(ops).toEqual([]);
      expect(await state()).toEqual(before);
      expect(out).toEqual([{ kind: 'refused', reason: 'the stage does not serve namespaces yet: index version 2 and a /api/v1 that refuses flat names come first', ...failing }]);
    });
  });

  describe('a run stopped part way', () => {
    test('stopped among the files: the next dry run lists what is left of the name, and its apply finishes the work', async () => {
      failAt = 'delete osx-arm64/mojo-json-0.1.0-mojo1.0.0_0.conda';
      await expect(run({ apply: await dryRunDigest() })).rejects.toThrow('stopped at delete osx-arm64/mojo-json-0.1.0-mojo1.0.0_0.conda');
      failAt = undefined;
      expect(await rig.store.listPackageNames()).toEqual(['json', 'kci_api', 'komira-ai/json']);
      const digest = await dryRunDigest();
      expect(out.filter((l) => l.kind === 'name')).toEqual([
        { kind: 'name', name: 'json', package: true, versions: ['0.1.0 published', '0.2.0 yanked'], owners: ['user7'], publishers: ['tp_1'], objects: 1, bytes: 3, index: null },
        { kind: 'name', name: 'orphan', package: false, versions: [], owners: [], publishers: [], objects: 1, bytes: 2, index: 'index/or/ph/orphan' },
      ]);
      ops = [];
      expect(await run({ apply: digest })).toBe(0);
      // The repodata is already without the name: only the file that was left goes.
      expect(ops.filter((o) => o.includes(' json') || o.includes('-json-'))).toEqual([
        'audit json',
        'delete osx-arm64/mojo-json-0.1.0-mojo1.0.0_0.conda',
        `invalidate delete_global-json-${digest.slice(0, 16)} /osx-arm64/mojo-json-0.1.0-mojo1.0.0_0.conda`,
        'version json 0.1.0',
        'version json 0.2.0',
        'owner json 7',
        'publisher json tp_1',
        'package json',
      ]);
      expect(await rig.store.listPackageNames()).toEqual(['kci_api', 'komira-ai/json']);
    });

    test('stopped just before the package row: the next run lists the bare package row and deletes it', async () => {
      failAt = 'package json';
      await expect(run({ apply: await dryRunDigest() })).rejects.toThrow('stopped at package json');
      failAt = undefined;
      const digest = await dryRunDigest();
      expect(out.filter((l) => l.kind === 'name')).toEqual([
        { kind: 'name', name: 'json', package: true, versions: [], owners: [], publishers: [], objects: 0, bytes: 0, index: null },
        { kind: 'name', name: 'orphan', package: false, versions: [], owners: [], publishers: [], objects: 1, bytes: 2, index: 'index/or/ph/orphan' },
      ]);
      ops = [];
      expect(await run({ apply: digest })).toBe(0);
      expect(ops.slice(0, 2)).toEqual(['audit json', 'package json']);
      expect(await rig.store.listPackageNames()).toEqual(['kci_api', 'komira-ai/json']);
    });

    test('a version that appears while the rows are deleted stops the run before the package row goes, and the next run deletes it', async () => {
      onOp = async (op) => {
        if (op === 'version json 0.2.0') await version('json', '0.3.0', ['noarch']);
      };
      expect(await run({ apply: await dryRunDigest() })).toBe(2);
      onOp = undefined;
      expect(out[out.length - 1]).toEqual({ kind: 'refused', name: 'json', reason: 'versions appeared after the listing; the package row is kept: run the dry run again', versions: ['0.3.0'] });
      expect(ops).not.toContain('package json');
      expect(ops).not.toContain('audit orphan');
      expect(await rig.store.listPackageNames()).toContain('json');
      expect(await run({ apply: await dryRunDigest() })).toBe(0);
      expect(await rig.store.listPackageNames()).toEqual(['kci_api', 'komira-ai/json']);
      expect(bucket.keys('noarch/mojo-')).toEqual([]);
    });
  });
});

describe('the stage checks over HTTP', () => {
  function http(config: { status: number; body: string }, claim: { status: number; body: string }) {
    const seen: Array<{ url: string; method: string; body?: unknown; auth?: string }> = [];
    const fn: HttpFn = async (url, init) => {
      seen.push({ url, method: init.method, body: init.body, auth: init.headers.authorization });
      const r = seen.length === 1 ? config : claim;
      return { status: r.status, headers: { get: () => null }, text: async () => r.body, arrayBuffer: async () => new ArrayBuffer(0) };
    };
    return { fn, seen };
  }
  const CONFIG = (extra: Record<string, unknown>) => ({ status: 200, body: JSON.stringify({ index_version: 1, api_url: 'https://api.example.invalid/api/v1', ...extra }) });
  const RESERVED = { status: 403, body: JSON.stringify({ error: { code: 'name_reserved', message: 'm', hint: 'h' } }) };

  test('reads index_versions from config.json and asks /api/v1 to claim the probe name with no token', async () => {
    const h = http(CONFIG({ index_versions: [1, 2] }), RESERVED);
    expect(await stageChecks(BASE.configUrl, h.fn)).toEqual({ index_versions: [1, 2], v1_refuses_flat_creation: true });
    expect(h.seen).toEqual([
      { url: BASE.configUrl, method: 'GET', body: undefined, auth: undefined },
      { url: `https://api.example.invalid/api/v1/packages/${PROBE_NAME}/claim`, method: 'POST', body: '{}', auth: undefined },
    ]);
  });

  test('without index_versions the one index_version counts; without either, none; a trailing slash on api_url is dropped', async () => {
    expect((await stageChecks(BASE.configUrl, http(CONFIG({}), RESERVED).fn)).index_versions).toEqual([1]);
    const bare = http({ status: 200, body: JSON.stringify({ api_url: 'https://api.example.invalid/api/v1/' }) }, RESERVED);
    expect(await stageChecks(BASE.configUrl, bare.fn)).toEqual({ index_versions: [], v1_refuses_flat_creation: true });
    expect(bare.seen[1]!.url).toBe(`https://api.example.invalid/api/v1/packages/${PROBE_NAME}/claim`);
  });

  test.each([
    ['401 (the token is checked first)', { status: 401, body: JSON.stringify({ error: { code: 'unauthorized' } }) }],
    ['403 with another code', { status: 403, body: JSON.stringify({ error: { code: 'forbidden' } }) }],
    ['403 that is not JSON', { status: 403, body: '<html>' }],
    ['403 with no error object', { status: 403, body: '{}' }],
    ['200 (it created nothing: no token)', { status: 200, body: '{}' }],
  ])('any answer but 403 name_reserved counts as not refused: %s', async (_why, claim) => {
    expect((await stageChecks(BASE.configUrl, http(CONFIG({ index_versions: [1, 2] }), claim).fn)).v1_refuses_flat_creation).toBe(false);
  });

  test('a config.json that is not served, or names no api_url, is an error', async () => {
    await expect(stageChecks(BASE.configUrl, http({ status: 404, body: '' }, RESERVED).fn)).rejects.toThrow(`${BASE.configUrl} answered 404`);
    await expect(stageChecks(BASE.configUrl, http({ status: 200, body: '{"index_version":1}' }, RESERVED).fn)).rejects.toThrow(`${BASE.configUrl} names no api_url`);
  });
});

describe('the entry point', () => {
  const argv = ['--stage=beta', '--bucket=b', '--distribution=d', '--config-url=https://x.invalid/index/config.json'];
  const empty = (lines: Array<Record<string, unknown>>): DeleteDeps => ({
    registry: { listPackageNames: async () => [], listVersions: async () => [], listOwners: async () => [], removeOwner: async () => undefined, appendAudit: async () => undefined, deleteVersionRow: async () => undefined, deletePackageRow: async () => undefined },
    publishers: { listTrustedPublishers: async () => [], removeTrustedPublisher: async () => undefined },
    bucket: new MemoryObjectStore(),
    invalidator: { invalidate: async () => undefined },
    checks: async () => PASSING,
    out: (l) => lines.push(l),
  });

  test('runs the dry run with the adapters it is given, and exits 0', async () => {
    const lines: Array<Record<string, unknown>> = [];
    expect(await main(argv, () => empty(lines))).toBe(0);
    expect(lines.map((l) => l.kind)).toEqual(['checks', 'totals', 'digest']);
  });

  test('applies the digest of its own dry run with the clock of the machine when none is given', async () => {
    const lines: Array<Record<string, unknown>> = [];
    expect(await main(argv, () => empty(lines))).toBe(0);
    const digest = lines.find((l) => l.kind === 'digest')!.digest as string;
    lines.length = 0;
    expect(await main([...argv, `--apply=${digest}`], () => empty(lines))).toBe(0);
    expect(lines).toEqual([{ kind: 'done', stage: 'beta', names: 0, digest }]);
  });

  test('a flag mistake or a failing adapter is a message on stderr and exit status 1', async () => {
    const err = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      expect(await main(['--stage=dev'], () => empty([]))).toBe(1);
      expect(err.mock.calls[0]![0]).toContain('--stage is beta, gamma or prod');
      expect(await main(argv, () => ({ ...empty([]), checks: async () => Promise.reject(new Error('config.json answered 500')) }))).toBe(1);
      expect(err.mock.calls[1]![0]).toBe('config.json answered 500');
      expect(await main(argv, () => ({ ...empty([]), checks: async () => Promise.reject('plain') }))).toBe(1);
      expect(err.mock.calls[2]![0]).toBe('plain');
      // With no adapters given it would build the stage's own; a flag mistake stops it before that.
      expect(await main(['--bucket=b'])).toBe(1);
      expect(err.mock.calls[3]![0]).toContain('--stage is beta, gamma or prod');
    } finally {
      err.mockRestore();
    }
  });

  test('realDeps builds the stage adapters from the flags without calling anything, and prints JSON lines', () => {
    const log = jest.spyOn(console, 'log').mockImplementation(() => undefined);
    try {
      const d = realDeps({ stage: 'gamma', bucket: 'b', distribution: 'd', configUrl: 'https://x.invalid/index/config.json', region: 'eu-west-1' });
      expect(Object.keys(d).sort()).toEqual(['bucket', 'checks', 'invalidator', 'out', 'publishers', 'registry']);
      d.out({ kind: 'x' });
      expect(log).toHaveBeenCalledWith('{"kind":"x"}');
      expect(realDeps({ stage: 'beta', bucket: 'b', distribution: 'd', configUrl: 'u' }).bucket).toBeDefined();
    } finally {
      log.mockRestore();
    }
  });

  test("realDeps' stage checks read the --config-url it was given, over the process's fetch", async () => {
    const urls: string[] = [];
    const fetchSpy = jest.spyOn(globalThis, 'fetch').mockImplementation((async (url: string) => {
      urls.push(url);
      const body = urls.length === 1 ? JSON.stringify({ index_versions: [1, 2], api_url: 'https://api.example.invalid/api/v1' }) : JSON.stringify({ error: { code: 'name_reserved' } });
      return { status: urls.length === 1 ? 200 : 403, headers: { get: () => null }, text: async () => body, arrayBuffer: async () => new ArrayBuffer(0) };
    }) as unknown as typeof fetch);
    try {
      const d = realDeps({ stage: 'beta', bucket: 'b', distribution: 'd', configUrl: 'https://api.example.invalid/index/config.json' });
      expect(await d.checks()).toEqual(PASSING);
      expect(urls).toEqual(['https://api.example.invalid/index/config.json', `https://api.example.invalid/api/v1/packages/${PROBE_NAME}/claim`]);
    } finally {
      fetchSpy.mockRestore();
    }
  });
});

describe('the bundle entry', () => {
  test('passes the process arguments to main and exits with its status', async () => {
    let exited: (code: unknown) => void = () => undefined;
    const exitCalled = new Promise<unknown>((resolve) => {
      exited = resolve;
    });
    const exit = jest.spyOn(process, 'exit').mockImplementation(((code?: unknown) => {
      exited(code);
    }) as never);
    const err = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    const argv = process.argv;
    try {
      process.argv = ['node', 'bin.js', '--stage=dev'];
      await jest.isolateModulesAsync(async () => {
        await import('../../src/ops/delete-global-names/bin');
        await exitCalled;
      });
      expect(exit).toHaveBeenCalledWith(1);
      expect(err.mock.calls[0]![0]).toContain('--stage is beta, gamma or prod');
    } finally {
      process.argv = argv;
      exit.mockRestore();
      err.mockRestore();
    }
  });
});
