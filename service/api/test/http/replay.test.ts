import * as fs from 'fs';
import * as path from 'path';
import { MemoryStore } from '../../src/memory-store';
import type { Store } from '../../src/store';
import { audit, rec } from '../helpers';
import {
  CONTRACT_DIR,
  LOCAL_FIXTURES,
  NOT_PRODUCED_BY_HANDLER,
  OPERATIONS,
  loadCases,
  replay,
  route,
  type Case,
  type Recipe,
  type Router,
} from './replay';

// Replays the registry contract fixtures (tests/contract/api, the same files the fake registry is replayed
// against) for the read operations against the router, with an in-memory store. A fixture carries a request and
// an answer but not the registry's state, so each case has a recipe that builds the state it describes.
// What a pass proves: for that state the router answers with the fixture's status and exactly its body (error
// text included, so the catalogue templates cannot drift). What it cannot prove: the cases are examples, not
// the whole input space; router.test.ts covers ordering, paging and the edges.

const octocat = { name: 'http_client', github_id: 583231, handle: 'octocat', added_at: '2026-10-01T09:00:00Z' };

async function httpClient(s: MemoryStore) {
  await s.createPackage({ name: 'http_client', state: 'active', created_at: '2026-10-01T09:00:00Z', repository: 'https://github.com/example/http_client', license: 'Apache-2.0', description: 'HTTP/1.1 client' });
  await s.addOwner(octocat);
  await s.createVersion(rec({ name: 'http_client', version: '0.3.0', state: 'yanked', yank_reason: 'crashes on empty body', published_at: '2026-10-05T08:00:00Z' }), audit('http_client', 'publish', '0.3.0'));
  await s.createVersion(rec({ name: 'http_client', version: '0.4.0', published_at: '2026-10-13T12:00:00Z' }), audit('http_client', 'publish', '0.4.0'));
}

const failingStore = (): Store =>
  new Proxy({} as Store, { get: () => async () => { throw new Error('dynamodb exploded'); } });

/** Ask for the first page with limit 1 and continue from its cursor, keeping the case's own other parameters. */
const continueFromFirstPage: Recipe['prepare'] = async (req, send) => {
  const first = JSON.parse((await send({ ...req, query: { limit: '1' } })).body);
  return { ...req, query: { ...req.query, cursor: first.next_cursor } };
};

const RECIPES: Record<string, Recipe> = {
  // tests/contract/api/meta.json
  'prod is up': { stage: 'prod', extraKeys: ['version', 'commit'] },
  'beta in read-only mode': { stage: 'beta', readOnly: true, extraKeys: ['version', 'commit'] },
  // tests/contract/api/packages.json
  'search by prefix': {
    seed: async (s) => {
      await s.createPackage({ name: 'http_client', state: 'active', created_at: '2026-10-01T09:00:00Z', description: 'HTTP/1.1 client' });
      await s.createVersion(rec({ name: 'http_client', version: '0.4.0', published_at: '2026-10-13T12:00:00Z' }), audit('http_client', 'publish', '0.4.0'));
      await s.createPackage({ name: 'http_server', state: 'claimed', created_at: '2026-10-02T09:00:00Z' });
      await s.createPackage({ name: 'other', state: 'claimed', created_at: '2026-10-02T09:00:00Z' });
    },
    // The fixture's page holds one package although it asks for 20: the state has two matches, so ask for one.
    prepare: async (req) => ({ ...req, query: { ...req.query, limit: '1' } }),
  },
  'search, last page, claimed package with no version': {
    seed: async (s) => {
      await s.createPackage({ name: 'aa_first', state: 'claimed', created_at: '2026-10-13T12:00:00Z' });
      await s.createPackage({ name: 'tls', state: 'claimed', created_at: '2026-10-13T12:00:00Z' });
    },
    prepare: continueFromFirstPage,
  },
  'package info': {
    seed: httpClient,
    omitExpected: ['display_name'], // optional in the contract; the store has no display name to give
  },
  'list versions': {
    seed: async (s) => {
      await s.createPackage({ name: 'http_client', state: 'active', created_at: '2026-10-01T09:00:00Z' });
      await s.createVersion(rec({ name: 'http_client', version: '0.4.0', published_at: '2026-10-13T12:00:00Z' }), audit('http_client', 'publish', '0.4.0'));
    },
  },
  // tests/contract/api/errors.json
  'error invalid_request': {},
  'error invalid_name': {},
  'error package_not_found': {},
  'error internal_error': { store: failingStore },
};

// service/api/test/fixtures/api-read.json: cases of the same shape that pin things the shared fixtures do not.
const LOCAL_RECIPES: Record<string, Recipe> = {
  'versions are newest first by conda ordering': { seed: orderingDemo() },
  'package info: latest skips yanked and pre-releases, tombstone shown as such': { seed: orderingDemo(true) },
  'versions of a package that does not exist': {},
  'search by prefix is normalised and ordered by name': {
    seed: async (s) => {
      for (const [n, d] of [['http_server', '03'], ['http_core', '02'], ['http_client', '01'], ['httpx', '04'], ['zlib', '05']] as const) {
        await s.createPackage({ name: n, state: 'claimed', created_at: `2026-10-${d}T09:00:00Z` });
      }
    },
  },
  'a limit above 100 is refused': {},
};

function orderingDemo(withOwner = false) {
  return async (s: MemoryStore) => {
    await s.createPackage({ name: 'ordering_demo', state: 'active', created_at: '2026-10-01T09:00:00Z' });
    if (withOwner) await s.addOwner({ name: 'ordering_demo', github_id: 583231, handle: 'octocat', added_at: '2026-10-01T09:00:00Z' });
    // Inserted in no particular order on purpose.
    const add = (version: string, over: object) => s.createVersion(rec({ name: 'ordering_demo', version, ...over }), audit('ordering_demo', 'publish', version));
    await add('1.9', { state: 'tombstoned', tombstone: { reason_code: 'malware', date: '2026-10-11' }, published_at: '2026-10-07T00:00:00Z' });
    await add('2.0rc1', { published_at: '2026-10-09T00:00:00Z' });
    await add('1.2', { published_at: '2026-10-06T00:00:00Z' });
    await add('2.0', { published_at: '2026-10-10T00:00:00Z' });
    await add('1.10.0', { state: 'yanked', yank_reason: 'broken wheel', published_at: '2026-10-08T00:00:00Z' });
    await s.createVersion(rec({ name: 'ordering_demo', version: '3.0', state: 'pending', published_at: '2026-10-12T00:00:00Z' }), audit('ordering_demo', 'reserve', '3.0'));
  };
}

const served = (cs: Case[]) => cs.filter((c) => c.operationId in OPERATIONS && (c.expect ?? 'valid') === 'valid');
const contractCases = fs
  .readdirSync(CONTRACT_DIR)
  .filter((f) => f.endsWith('.json'))
  .flatMap((f) => served(loadCases(path.join(CONTRACT_DIR, f))));
const localCases = served(loadCases(LOCAL_FIXTURES));

describe.each([
  ['tests/contract/api', contractCases, RECIPES],
  ['service/api/test/fixtures/api-read.json', localCases, LOCAL_RECIPES],
] as const)('replay %s', (_label, cases, recipes) => {
  test('every served valid case is replayed or named as not produced by the handler', () => {
    const missing = cases.filter((c) => !(c.name in recipes) && !NOT_PRODUCED_BY_HANDLER.has(c.name)).map((c) => c.name);
    expect(missing).toEqual([]);
    expect(cases.length).toBeGreaterThan(0);
  });

  test.each(cases.filter((c) => c.name in recipes).map((c) => [c.name, c] as const))('%s', async (_n, c) => {
    expect(await replay(c, recipes[c.name]!, route as Router)).toEqual([]);
  });
});

// Can-fail proof: the same harness, against routers with one planted defect each, must report a mismatch.
describe('the replay goes red on a planted defect', () => {
  const find = (cs: Case[], name: string) => cs.find((c) => c.name === name)!;
  const versionsOrder = find(localCases, 'versions are newest first by conda ordering');
  const notFound = find(contractCases, 'error package_not_found');

  test('versions listed oldest first (the exact order fixture)', async () => {
    const mutant: Router = async (req, deps, id) => {
      const res = await route(req, deps, id);
      const body = JSON.parse(res.body);
      if (body.versions) body.versions.reverse();
      return { ...res, body: JSON.stringify(body) };
    };
    expect(await replay(versionsOrder, LOCAL_RECIPES[versionsOrder.name]!, route as Router)).toEqual([]);
    expect((await replay(versionsOrder, LOCAL_RECIPES[versionsOrder.name]!, mutant)).length).toBeGreaterThan(0);
  });

  test('a missing package answered 200 with an empty list (the 404 package_not_found fixture)', async () => {
    const mutant: Router = async (_req, _deps, id) => ({
      statusCode: 200,
      headers: { 'x-mopm-request-id': id },
      body: JSON.stringify({ versions: [], next_cursor: null }),
    });
    expect(await replay(notFound, RECIPES[notFound.name]!, route as Router)).toEqual([]);
    expect((await replay(notFound, RECIPES[notFound.name]!, mutant)).length).toBeGreaterThan(0);
  });

  test('a changed error message (catalogue drift)', async () => {
    const mutant: Router = async (req, deps, id) => {
      const res = await route(req, deps, id);
      return { ...res, body: res.body.replace('There is no package', 'No such package') };
    };
    expect((await replay(notFound, RECIPES[notFound.name]!, mutant)).length).toBeGreaterThan(0);
  });
});
