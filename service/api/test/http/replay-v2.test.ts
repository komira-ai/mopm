import {
  followsTemplate,
  loadV2Cases,
  OPAQUE,
  replayV2,
  specCatalogue,
  specOperations,
  specRejectionCodes,
  type Recipe,
} from './replay-v2';
import { RECIPES } from './replay-v2-recipes';

// Replays the v2 contract cases (tests/contract/api-v2, the cases //:contract checks against spec/api/openapi-v2.yaml) against the
// router of /api/v2, on memory ports and a fixed clock. A case carries a request and an answer but not the registry's state, so
// each one has a recipe (replay-v2-recipes.ts) that builds the state it describes.
// What a pass proves: for that state the router answers with the case's status and exactly its body (error text included, so the
// catalogue templates cannot drift), except for the values it makes at random, which are compared by shape (OPAQUE). What it does
// not prove: the cases are examples, not the whole input space, and a case file's request is not checked against the schema here
// (//:contract does that). Also checked here, on GitHub's runners where //:contract is not run: every operation of the spec has a
// passing success case, every error code and rejection code a case, and every error case follows the catalogue.

/**
 * Operations this router does not serve: the website's sign-in and tutorial sandbox, served by the website's Rust functions behind
 * the site's /api/* behaviour. Their cases (tests/contract/api-v2/web-auth.json, tutorial-sandbox.json) are excluded by operationId
 * rather than by case name, so a case added to those files needs no entry here.
 */
const NOT_THE_ROUTERS = new Set(['startWebLogin', 'completeWebLogin', 'getWebSession', 'webLogout', 'createTutorialSandbox']);
const NOT_PRODUCED_REASON = 'served by the website\'s Rust functions, not this router';

/** Valid cases the handler cannot produce, by case name, with the reason. */
// Every other valid case is produced by the handler: name_taken and name_too_similar, the two codes only v1's claim answered, are
// not in /api/v2's catalogue.
const NOT_PRODUCED_V2: Record<string, string> = {};

const ops = new Map(specOperations().map((o) => [o.operationId, o]));
const catalogue = specCatalogue();
const cases = loadV2Cases();
const valid = cases.filter((c) => (c.expect ?? 'valid') === 'valid');
for (const c of valid) if (NOT_THE_ROUTERS.has(c.operationId)) NOT_PRODUCED_V2[c.name] = NOT_PRODUCED_REASON;

describe('the v2 contract cases are the spec\'s', () => {
  test('the spec was read: its operations, its error table and its rejection codes', () => {
    expect(ops.size).toBe(33);
    expect(Object.keys(catalogue).length).toBe(48);
    expect(specRejectionCodes()).toHaveLength(7);
    expect(cases.length).toBeGreaterThan(100);
  });

  test('case names are unique', () => {
    const names = cases.map((c) => c.name);
    expect(names.filter((n, i) => names.indexOf(n) !== i)).toEqual([]);
  });

  test('every operationId of the cases is an operation of the spec', () => {
    expect(cases.filter((c) => !ops.has(c.operationId)).map((c) => c.name)).toEqual([]);
  });

  test('every operation of the spec has a passing success case (a redirect counts: any status below 400)', () => {
    const ok = new Set(valid.filter((c) => c.response.status < 400).map((c) => c.operationId));
    expect([...ops.keys()].filter((id) => !ok.has(id))).toEqual([]);
  });

  test('every error code of x-mopm-errors has a case', () => {
    const seen = new Set(valid.filter((c) => c.response.status >= 400).map((c) => c.response.body?.error?.code));
    expect(Object.keys(catalogue).filter((code) => !seen.has(code))).toEqual([]);
  });

  test('every rejection code has a case', () => {
    const seen = new Set(valid.map((c) => c.response.body?.rejection_code));
    expect(specRejectionCodes().filter((code) => !seen.has(code))).toEqual([]);
  });

  test.each(valid.filter((c) => c.response.status >= 400).map((c) => [c.name, c] as const))('%s: the status, message and hint follow the catalogue', (_n, c) => {
    const error = c.response.body.error;
    const entry = catalogue[error.code];
    expect(entry).toBeDefined();
    expect(c.response.status).toBe(entry!.status);
    expect(followsTemplate(entry!.message, error.message)).toBe(true);
    expect(followsTemplate(entry!.hint, error.hint)).toBe(true);
    if (error.code === 'rate_limited') expect(c.response.headers?.['retry-after']).toBeDefined();
  });

  test('the collections case says what the registry says', () => {
    const c = cases.find((x) => x.name === 'error name_reserved: a module of the Mojo standard library')!;
    expect(c.response.body.error).toEqual({
      code: 'name_reserved',
      message: "'collections' is a module of the Mojo standard library (std.collections).",
      hint: 'Choose another name.',
    });
  });
});

describe('replay tests/contract/api-v2', () => {
  test('every valid case has a recipe or is named as not produced by the handler, and every recipe is for a case', () => {
    const names = new Set(valid.map((c) => c.name));
    expect(valid.filter((c) => !(c.name in RECIPES) && !(c.name in NOT_PRODUCED_V2)).map((c) => c.name)).toEqual([]);
    expect(Object.keys(RECIPES).filter((n) => !names.has(n))).toEqual([]);
    expect(Object.keys(NOT_PRODUCED_V2).filter((n) => !names.has(n) || n in RECIPES)).toEqual([]);
  });

  beforeEach(() => {
    // A failing store is logged by the router; the log is not what is asserted.
    jest.spyOn(console, 'error').mockImplementation(() => undefined);
  });
  afterEach(() => jest.restoreAllMocks());

  test.each(valid.filter((c) => c.name in RECIPES).map((c) => [c.name, c] as const))('%s', async (_n, c) => {
    expect(await replayV2(c, RECIPES[c.name]!, ops)).toEqual([]);
  });
});

// Can-fail proof: the same comparison, against cases with one known defect each, must report a mismatch.
describe('the replay goes red on a known defect', () => {
  const find = (name: string) => JSON.parse(JSON.stringify(cases.find((c) => c.name === name)!)) as (typeof cases)[number];
  const red = async (name: string, change: (c: ReturnType<typeof find>) => void, recipe: Recipe = RECIPES[name]!) => {
    const c = find(name);
    expect(await replayV2(c, recipe, ops)).toEqual([]);
    change(c);
    return replayV2(c, recipe, ops);
  };

  beforeEach(() => {
    jest.spyOn(console, 'error').mockImplementation(() => undefined);
  });
  afterEach(() => jest.restoreAllMocks());

  test('a package answered with another namespace', async () => {
    expect((await red('package info', (c) => (c.response.body.namespace.namespace = 'alice'))).join()).toContain('body');
  });

  test('a status the router does not answer', async () => {
    expect(await red('create a package', (c) => (c.response.status = 200))).toContain('status 201, want 200');
  });

  test('a changed error message (catalogue drift)', async () => {
    const problems = await red('error name_reserved: a keyword', (c) => (c.response.body.error.message = "'fn' is a keyword."));
    expect(problems.join()).toContain("'fn' is reserved.");
  });

  test('a Retry-After the router does not send', async () => {
    expect(await red('error rate_limited', (c) => (c.response.headers!['retry-after'] = '60'))).toEqual(['retry-after 43200, want 60']);
  });

  test('a secret that is not shaped like a token is not taken for an opaque value', async () => {
    const problems = await red('create a token for full names', (c) => (c.response.body.token = 'secret'));
    expect(problems.join()).toContain('"token":"mopm_');
  });

  test('an upload URL that names another upload than the answer\'s id', async () => {
    const problems = await red('create a group', (c) => {
      const f = c.response.body.members[0].files[0];
      f.put_url = f.put_url.replace(f.upload_id, OPAQUE.upload_id!.example);
    });
    expect(problems.join()).toContain('body');
  });

  test('a case whose security scheme its recipe gives no token for', async () => {
    await expect(replayV2(find('whoami of an organization member'), {}, ops)).rejects.toThrow('userToken');
  });
});

describe('followsTemplate reads a placeholder as one or more characters of a line', () => {
  test.each([
    ["'{name}' is {what}.", "'fn' is reserved.", true],
    ["'{name}' is {what}.", "'' is reserved.", false],
    ["'{name}' is {what}.", "'fn' is reserved", false],
    ["'{name}' is {what}.", "'fn' is\nreserved.", false],
    ['No placeholder.', 'No placeholder.', true],
    ['No placeholder.', 'No placeholder!', false],
    ['Wait {retry_after} seconds.', 'Wait 43200 seconds.', true],
  ])('%s against %s', (template, text, ok) => {
    expect(followsTemplate(template, text)).toBe(ok);
  });
});
