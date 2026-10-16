import type { MemoryStore } from '../../src/memory-store';
import type { VersionRecord } from '../../src/types';
import { audit, rec } from '../helpers';

/**
 * The state builders the replay tests used before the seeds were files (http/replay.test.ts, as of the commit that
 * moved them). They are kept for one purpose: seeds.test.ts loads each seed file and the builder it was made from
 * into a fresh store and requires the same contents, so the conversion cannot have changed a value. They are not
 * used by any other test, and go with the TypeScript tests.
 */
const octocat = { name: 'http_client', github_id: 583231, handle: 'octocat', added_at: '2026-10-01T09:00:00Z' };

async function httpClient(s: MemoryStore) {
  await s.createPackage({ name: 'http_client', state: 'active', created_at: '2026-10-01T09:00:00Z', repository: 'https://github.com/example/http_client', license: 'Apache-2.0', description: 'HTTP/1.1 client' });
  await s.addOwner(octocat);
  await s.createVersion(rec({ name: 'http_client', version: '0.3.0', state: 'yanked', yank_reason: 'crashes on empty body', published_at: '2026-10-05T08:00:00Z' }), audit('http_client', 'publish', '0.3.0'));
  await s.createVersion(rec({ name: 'http_client', version: '0.4.0', published_at: '2026-10-13T12:00:00Z' }), audit('http_client', 'publish', '0.4.0'));
}

const versionDetail = (state: 'published' | 'yanked' | 'tombstoned', extra: Partial<VersionRecord> = {}) => async (s: MemoryStore) => {
  await s.createPackage({ name: 'http_client', state: 'active', created_at: '2026-10-01T09:00:00Z' });
  await s.createVersion(
    rec({
      name: 'http_client',
      version: '0.4.0',
      state,
      published_by: 'octocat',
      deps: [{ name: 'http_core', range: '>=1.2,<2' }],
      native: [{ id: 'crypto', soname: 'libcrypto_native.so.1' }],
      files: [
        {
          subdir: 'linux-64',
          filename: 'mojo-http_client-0.4.0-mojo1.0.0_0.conda',
          sha256: '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
          size: 123456,
          url: 'https://conda.mopm.dev/linux-64/mojo-http_client-0.4.0-mojo1.0.0_0.conda',
        },
      ],
      manifest_sha256: '2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae',
      provenance: {
        kind: 'oidc',
        repository: 'https://github.com/example/http_client',
        workflow_ref: 'example/http_client/.github/workflows/release.yml@refs/tags/v0.4.0',
      },
      ...(state === 'yanked' ? { yank_reason: 'crashes on empty body' } : {}),
      ...(state === 'tombstoned' ? { tombstone: { reason_code: 'malware', date: '2026-10-14' } } : {}),
      ...extra,
    }),
    audit('http_client', 'publish', '0.4.0'),
  );
};

function orderingDemo(withOwner = false) {
  return async (s: MemoryStore) => {
    await s.createPackage({ name: 'ordering_demo', state: 'active', created_at: '2026-10-01T09:00:00Z' });
    if (withOwner) await s.addOwner({ name: 'ordering_demo', github_id: 583231, handle: 'octocat', added_at: '2026-10-01T09:00:00Z' });
    const add = (version: string, over: object) => s.createVersion(rec({ name: 'ordering_demo', version, ...over }), audit('ordering_demo', 'publish', version));
    await add('1.9.0', { state: 'tombstoned', tombstone: { reason_code: 'malware', date: '2026-10-11' }, published_at: '2026-10-07T00:00:00Z' });
    await add('1.20.0', { published_at: '2026-10-09T00:00:00Z' });
    await add('1.2.0', { published_at: '2026-10-06T00:00:00Z' });
    await add('2.0.0', { published_at: '2026-10-10T00:00:00Z' });
    await add('1.10.0', { state: 'yanked', yank_reason: 'broken wheel', published_at: '2026-10-08T00:00:00Z' });
    await s.createVersion(rec({ name: 'ordering_demo', version: '3.0.0', state: 'pending', published_at: '2026-10-12T00:00:00Z' }), audit('ordering_demo', 'reserve', '3.0.0'));
  };
}

/** Seed file name -> the builder it was made from. */
export const LEGACY: Record<string, (s: MemoryStore) => Promise<void>> = {
  http_client_two_versions: httpClient,
  http_client_one_version: async (s) => {
    await s.createPackage({ name: 'http_client', state: 'active', created_at: '2026-10-01T09:00:00Z' });
    await s.createVersion(rec({ name: 'http_client', version: '0.4.0', published_at: '2026-10-13T12:00:00Z' }), audit('http_client', 'publish', '0.4.0'));
  },
  http_client_no_versions: async (s) => {
    await s.createPackage({ name: 'http_client', state: 'active', created_at: '2026-10-01T09:00:00Z' });
  },
  http_client_display_fields: async (s) => {
    await s.createPackage({ name: 'http_client', state: 'active', created_at: '2026-10-01T09:00:00Z', repository: 'https://github.com/example/http_client', license: 'Apache-2.0', description: 'HTTP/1.1 client', homepage: 'https://example.com/http_client', keywords: ['http', 'client'] });
    await s.addOwner(octocat);
    await s.createVersion(rec({ name: 'http_client', version: '0.3.0', state: 'yanked', yank_reason: 'crashes on empty body', published_at: '2026-10-05T08:00:00Z', readme: 'old' }), audit('http_client', 'publish', '0.3.0'));
    await s.createVersion(rec({ name: 'http_client', version: '0.4.0', published_at: '2026-10-13T12:00:00Z', readme: '# http_client\n' }), audit('http_client', 'publish', '0.4.0'));
  },
  search_prefix_http: async (s) => {
    await s.createPackage({ name: 'http_client', state: 'active', created_at: '2026-10-01T09:00:00Z', description: 'HTTP/1.1 client' });
    await s.createVersion(rec({ name: 'http_client', version: '0.4.0', published_at: '2026-10-13T12:00:00Z' }), audit('http_client', 'publish', '0.4.0'));
    await s.createPackage({ name: 'http_server', state: 'claimed', created_at: '2026-10-02T09:00:00Z' });
    await s.createPackage({ name: 'other', state: 'claimed', created_at: '2026-10-02T09:00:00Z' });
  },
  search_two_claimed: async (s) => {
    await s.createPackage({ name: 'aa_first', state: 'claimed', created_at: '2026-10-13T12:00:00Z' });
    await s.createPackage({ name: 'tls', state: 'claimed', created_at: '2026-10-13T12:00:00Z' });
  },
  search_five_claimed: async (s) => {
    for (const [n, d] of [['http_server', '03'], ['http_core', '02'], ['http_client', '01'], ['httpx', '04'], ['zlib', '05']] as const) {
      await s.createPackage({ name: n, state: 'claimed', created_at: `2026-10-${d}T09:00:00Z` });
    }
  },
  version_detail_published: versionDetail('published'),
  version_detail_yanked: versionDetail('yanked'),
  version_detail_tombstoned: versionDetail('tombstoned'),
  version_detail_display_fields: versionDetail('published', {
    description: 'HTTP/1.1 client',
    license: 'Apache-2.0',
    repository: 'https://github.com/example/http_client',
    homepage: 'https://example.com/http_client',
    keywords: ['http', 'client'],
    readme: '# http_client\n\nAn HTTP client.\n',
  }),
  ordering_demo: orderingDemo(),
  ordering_demo_with_owner: orderingDemo(true),
};
