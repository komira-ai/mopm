import { DynamoStore, tablesFor } from '../../src/dynamo-store';
import { route } from '../../src/http/router';
import { rec } from '../helpers';

/**
 * Additive attributes on a stored row must not change what the read API answers.
 *
 * Why it matters: a later implementation (or a later version of this one) may store more attributes in the same
 * rows, for instance one build record per compiler on a version, while a function of this version still serves
 * reads from the same tables during a rollout or a rollback. The DynamoDB adapters pass unknown attributes through
 * to the record they build (pinned in fixtures/wire/store.json), so what keeps them off the wire of the API is the
 * router's projections. This test holds that: the same five read requests, once over rows as written today and
 * once over the same rows with extra attributes, answer with identical bytes.
 *
 * Mutant planted to see it red: a router projection that spreads the stored record (`...p` in getPackage).
 */

const PACKAGE = { name: 'http_client', state: 'active', created_at: '2026-10-01T09:00:00Z', description: 'HTTP/1.1 client', search_bucket: 'all' };
const EXTRA = { builds: [{ fingerprint: 'f', platform: 'linux-64' }], mojo_lines: ['1.0'], source_rev: 'abc', future_field: 1 };

function versionItem(extra: object) {
  const { canonical, version, ...rest } = rec({ name: 'http_client', version: '0.4.0', published_by: 'octocat' });
  return { ...rest, version: canonical, version_spelling: version, ...extra };
}

/** Rows by table, answered the way the adapters ask for them. */
function doc(extra: object) {
  const pkg = { ...PACKAGE, ...extra };
  const ver = versionItem(extra);
  const owner = { name: 'http_client', github_id: '583231', github_id_num: 583231, handle: 'octocat', added_at: '2026-10-01T09:00:00Z', ...extra };
  return {
    async send(cmd: { constructor: { name: string }; input: { TableName: string } }) {
      const op = cmd.constructor.name;
      const table = cmd.input.TableName.replace('mopm-beta-', '');
      if (op === 'GetCommand' && table === 'packages') return { Item: pkg };
      if (op === 'GetCommand' && table === 'versions') return { Item: ver };
      if (op === 'QueryCommand' && table === 'versions') return { Items: [ver] };
      if (op === 'QueryCommand' && table === 'owners') return { Items: [owner] };
      if (op === 'QueryCommand' && table === 'packages') return { Items: [pkg] };
      throw new Error(`unexpected ${op} on ${table}`);
    },
  };
}

const REQUESTS: Array<[string, Record<string, string>]> = [
  ['/api/v1/packages/http_client', {}],
  ['/api/v1/packages/http_client/versions', {}],
  ['/api/v1/packages/http_client/0.4.0', {}],
  ['/api/v1/packages/http_client/owners', {}],
  ['/api/v1/packages', { q: 'http' }],
];

async function answers(extra: object) {
  const deps = { store: new DynamoStore(doc(extra), tablesFor('beta')), stage: 'beta' as const, version: 'v', commit: 'c', readOnly: false };
  const out: Array<[number, string]> = [];
  for (const [path, query] of REQUESTS) {
    const res = await route({ method: 'GET', path, query }, deps, 'req-1');
    out.push([res.statusCode, res.body]);
  }
  return out;
}

describe('additive attributes on stored rows', () => {
  test('the read API answers with the same bytes with and without them', async () => {
    const plain = await answers({});
    expect(plain.map(([status]) => status)).toEqual([200, 200, 200, 200, 200]);
    expect(await answers(EXTRA)).toEqual(plain);
  });
});
