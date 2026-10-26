import * as fs from 'fs';
import * as path from 'path';
import { MemoryStore } from '../../src/memory-store';
import type { Store } from '../../src/store';
import { applySeed, readSeed } from '../seeds/load';
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

/** The state a case describes is a seed file (fixtures/seeds/<name>.json): data, so other implementations load the same one. */
const seeded = (name: string) => (s: MemoryStore) => applySeed(readSeed(name), { registry: s });

// Optional in the contract and not emitted: the embedded manifest and the rendered readme (the store holds neither).
const detailOmits = ['manifest', 'readme_html'];

const failingStore = (): Store =>
  new Proxy({} as Store, { get: () => async () => { throw new Error('dynamodb exploded'); } });

/** Ask for the first page with limit 1 and continue from its cursor, keeping the case's own other parameters. */
const continueFromFirstPage: Recipe['prepare'] = async (req, send) => {
  const first = JSON.parse((await send({ ...req, query: { limit: '1' } })).body);
  return { ...req, query: { ...req.query, cursor: first.next_cursor } };
};

const RECIPES: Record<string, Recipe> = {
  // tests/contract/api/meta.json
  'prod is up': { stage: 'prod', extraKeys: ['version', 'commit', 'impl'] },
  'beta in read-only mode': { stage: 'beta', readOnly: true, extraKeys: ['version', 'commit', 'impl'] },
  // This implementation says 'ts', and the fixture does: the member is compared, not removed.
  'prod is up and says which implementation answered': { stage: 'prod', extraKeys: ['version', 'commit'] },
  // tests/contract/api/packages.json
  'search by prefix': {
    seed: seeded('search_prefix_http'),
    // The fixture's page holds one package although it asks for 20: the state has two matches, so ask for one.
    prepare: async (req) => ({ ...req, query: { ...req.query, limit: '1' } }),
  },
  'search, last page, claimed package with no version': {
    seed: seeded('search_two_claimed'),
    prepare: continueFromFirstPage,
  },
  'package info': {
    seed: seeded('http_client_two_versions'),
    omitExpected: ['display_name'], // optional in the contract; the store has no display name to give
  },
  'list versions': {
    seed: seeded('http_client_one_version'),
  },
  // tests/contract/api/errors.json
  'error invalid_request': {},
  'error invalid_name': {},
  'error package_not_found': {},
  'error internal_error': { store: failingStore },
  'error invalid_version': {},
  'error version_not_found': { seed: seeded('http_client_no_versions') },
  // The case's operation (getHealth) only carries it; the request is a path the API does not have.
  'error route_not_found': { prepare: async (req) => ({ ...req, path: '/api/v1/no_such_operation' }) },
  'version detail with the mopm.toml display fields': {
    seed: seeded('version_detail_display_fields'),
    omitExpected: detailOmits,
  },
  'package info with homepage, keywords and the latest readme': {
    seed: seeded('http_client_display_fields'),
    omitExpected: ['display_name'],
  },
  'version detail': { seed: seeded('version_detail_published'), omitExpected: detailOmits },
  'yanked version keeps its files and says why': { seed: seeded('version_detail_yanked'), omitExpected: detailOmits },
  'tombstoned version has no url': { seed: seeded('version_detail_tombstoned'), omitExpected: detailOmits },
  // tests/contract/api/owners.json
  'list owners': { seed: seeded('http_client_two_versions') },
};

// service/api/test/fixtures/api-read.json: cases of the same shape that pin things the shared fixtures do not.
const LOCAL_RECIPES: Record<string, Recipe> = {
  'versions are newest first by conda ordering': { seed: seeded('ordering_demo') },
  'package info: latest skips yanked, tombstoned and pending versions, tombstone shown as such': { seed: seeded('ordering_demo_with_owner') },
  'versions of a package that does not exist': {},
  'search by prefix is normalised and ordered by name': {
    seed: seeded('search_five_claimed'),
  },
  'a limit above 100 is refused': {},
};

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

// Can-fail proof: the same harness, against routers with one known defect each, must report a mismatch.
describe('the replay goes red on a known defect', () => {
  const find = (cs: Case[], name: string) => cs.find((c) => c.name === name)!;
  const versionsOrder = find(localCases, 'versions are newest first by conda ordering');
  const notFound = find(contractCases, 'error package_not_found');

  test('versions listed oldest first (the exact order fixture)', async () => {
    const variant: Router = async (req, deps, id) => {
      const res = await route(req, deps, id);
      const body = JSON.parse(res.body);
      if (body.versions) body.versions.reverse();
      return { ...res, body: JSON.stringify(body) };
    };
    expect(await replay(versionsOrder, LOCAL_RECIPES[versionsOrder.name]!, route as Router)).toEqual([]);
    expect((await replay(versionsOrder, LOCAL_RECIPES[versionsOrder.name]!, variant)).length).toBeGreaterThan(0);
  });

  test('a missing package answered 200 with an empty list (the 404 package_not_found fixture)', async () => {
    const variant: Router = async (_req, _deps, id) => ({
      statusCode: 200,
      headers: { 'x-mopm-request-id': id },
      body: JSON.stringify({ versions: [], next_cursor: null }),
    });
    expect(await replay(notFound, RECIPES[notFound.name]!, route as Router)).toEqual([]);
    expect((await replay(notFound, RECIPES[notFound.name]!, variant)).length).toBeGreaterThan(0);
  });

  test('a tombstoned version that still shows its url (the tombstone fixture)', async () => {
    const c = find(contractCases, 'tombstoned version has no url');
    const variant: Router = async (req, deps, id) => {
      const res = await route(req, deps, id);
      const body = JSON.parse(res.body);
      body.files = body.files.map((f: any) => ({ ...f, url: 'https://conda.mopm.dev/leak' }));
      return { ...res, body: JSON.stringify(body) };
    };
    expect(await replay(c, RECIPES[c.name]!, route as Router)).toEqual([]);
    expect((await replay(c, RECIPES[c.name]!, variant)).length).toBeGreaterThan(0);
  });

  test('an unknown route answered with the old generic 400 (the route_not_found fixture)', async () => {
    const c = find(contractCases, 'error route_not_found');
    const variant: Router = async (req, deps, id) => {
      const res = await route(req, deps, id);
      return res.statusCode === 404 ? { ...res, statusCode: 400, body: res.body.replace('route_not_found', 'invalid_request') } : res;
    };
    expect(await replay(c, RECIPES[c.name]!, route as Router)).toEqual([]);
    expect((await replay(c, RECIPES[c.name]!, variant)).length).toBeGreaterThan(0);
  });

  test('owners listed with their added_at (the list owners fixture has id and handle only)', async () => {
    const c = find(contractCases, 'list owners');
    const variant: Router = async (req, deps, id) => {
      const res = await route(req, deps, id);
      const body = JSON.parse(res.body);
      body.owners = body.owners.map((o: any) => ({ ...o, added_at: 'x' }));
      return { ...res, body: JSON.stringify(body) };
    };
    expect((await replay(c, RECIPES[c.name]!, variant)).length).toBeGreaterThan(0);
  });

  test('a changed error message (catalogue drift)', async () => {
    const variant: Router = async (req, deps, id) => {
      const res = await route(req, deps, id);
      return { ...res, body: res.body.replace('There is no package', 'No such package') };
    };
    expect((await replay(notFound, RECIPES[notFound.name]!, variant)).length).toBeGreaterThan(0);
  });
});
