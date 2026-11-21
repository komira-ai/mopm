import { readFileSync } from 'fs';
import { join } from 'path';
import { MemoryAuthStore, MemoryNamespaceStore, NamespaceAccess } from '../src/auth';
import { canonicalJson } from '../src/canonical-json';
import { headerKey } from '../src/group';
import { route, type RouterDeps } from '../src/http/router';
import { buildPackageIndex } from '../src/index-files';
import { MemoryStore } from '../src/memory-store';
import { Metrics } from '../src/metrics';
import { buildRepodataJson } from '../src/repodata';
import type { VersionRecord } from '../src/types';
import { audit } from './helpers';

// A version published before builds were listed, as the registry served it then: one index line of a full name and the answer of
// getVersion of /api/v2 for the same version (test/fixtures/prod-json-0.1.387.*). The version body is kept without its `readme`
// field (a package's README, which has nothing to do with builds). The row below is what the store holds for that version, rebuilt
// from the two files. What these tests prove: serving such a version now changes nothing a reader of the old shape reads, and adds
// `builds` with the one build the top level already described.

const fixture = (f: string) => readFileSync(join(__dirname, 'fixtures', f), 'utf8');
const INDEX_LINE = fixture('prod-json-0.1.387.index.line');
const VERSION_BODY = JSON.parse(fixture('prod-json-0.1.387.version.json'));
const NAME = 'komira-ai/json';

const ROW: VersionRecord = {
  name: NAME,
  version: '0.1.387',
  canonical: '0.1.387',
  build: 'mojo1.0.0_0',
  state: 'published',
  published_at: VERSION_BODY.published_at,
  published_by: VERSION_BODY.published_by,
  requires_mojo: VERSION_BODY.requires_mojo,
  deps: VERSION_BODY.deps,
  native: VERSION_BODY.native,
  files: VERSION_BODY.files,
  manifest_sha256: VERSION_BODY.manifest_sha256,
  group_id: VERSION_BODY.group_id,
  rev: 2,
};

/** The store of a registry that holds the version: its group has finished (`visible`), as a group that published long ago has. */
async function holding(): Promise<MemoryStore> {
  const store = new MemoryStore(undefined, { metrics: new Metrics(() => {}) });
  store.groups.put(headerKey(ROW.group_id!), { status: 'visible', attempt: 1, committed_at: ROW.published_at });
  await store.createVersion(ROW, audit(NAME, 'publish', ROW.version));
  return store;
}

describe('a version published before builds were listed', () => {
  test('the index line is the line served before, byte for byte, plus builds with the one build the top level describes', () => {
    const line = buildPackageIndex(NAME, [ROW])!;
    const parsed = JSON.parse(line);
    expect(parsed.builds).toEqual([{ build: parsed.build, requires_mojo: parsed.requires_mojo, files: parsed.files }]);
    const { builds: _builds, ...old } = parsed;
    expect(canonicalJson(old) + '\n').toBe(INDEX_LINE);
    expect(parsed).toEqual({ ...JSON.parse(INDEX_LINE), builds: [{ build: 'mojo1.0.0_0', requires_mojo: '==1.0.0', files: JSON.parse(INDEX_LINE).files }] });
  });

  test('the same through the store: the row, folded as listVersions gives it, makes the same line', async () => {
    const store = await holding();
    const listed = (await store.listVersions(NAME)) as VersionRecord[];
    expect(JSON.parse(buildPackageIndex(NAME, listed)!)).toEqual(JSON.parse(buildPackageIndex(NAME, [ROW])!));
  });

  test('getVersion of /api/v2 is the body served before plus builds with that one build', async () => {
    const store = await holding();
    const namespaces = new MemoryNamespaceStore();
    await namespaces.createNamespace({ namespace: 'komira-ai', kind: 'org', github_id: 100, created_at: '2026-10-14T12:00:00Z' });
    const deps: RouterDeps = { store, stage: 'prod', version: 'v', commit: 'c', readOnly: false, v2: { access: new NamespaceAccess({ namespaces, users: new MemoryAuthStore() }), namespaces } };
    await store.createPackage({ name: NAME, state: 'active', created_at: '2026-10-01T00:00:00Z' });
    const res = await route({ method: 'GET', path: '/api/v2/packages/komira-ai/json/0.1.387', query: {} }, deps, 'req-1');
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    expect(body).toEqual({ ...VERSION_BODY, builds: [{ build: 'mojo1.0.0_0', requires_mojo: '==1.0.0', files: VERSION_BODY.files }] });
    expect({ requires_mojo: body.requires_mojo, files: body.files }).toEqual({ requires_mojo: VERSION_BODY.requires_mojo, files: VERSION_BODY.files });
  });

  test('the repodata entry of its file is what it was: its build, and the compiler of that build', () => {
    const doc = JSON.parse(buildRepodataJson('linux-64', [ROW]));
    expect(doc['packages.conda']).toEqual({
      'mojo-komira-ai.json-0.1.387-mojo1.0.0_0.conda': {
        build: 'mojo1.0.0_0',
        build_number: 0,
        depends: ['mojo-compiler ==1.0.0'],
        name: 'mojo-komira-ai.json',
        sha256: '3a4db3a9e53ea51f5099ca3c03a0139c4c557b67dd33d06a6e67709202aa2750',
        size: 122401,
        subdir: 'linux-64',
        version: '0.1.387',
      },
    });
    expect(doc.removed).toEqual([]);
  });
});
