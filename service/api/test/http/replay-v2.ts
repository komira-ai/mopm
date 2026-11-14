import * as fs from 'fs';
import * as path from 'path';
import { isDeepStrictEqual } from 'util';
import type { HttpRequest, HttpResponse } from '../../src/http/router';
import type { Case } from './replay';
import { buildWorld, type World, type WorldOptions } from './replay-v2-world';

export const CONTRACT_V2_DIR = path.resolve(__dirname, '../../../../tests/contract/api-v2');
const SPEC_V2 = path.resolve(__dirname, '../../../../spec/api/openapi-v2.yaml');
const SPEC_LINES = fs.readFileSync(SPEC_V2, 'utf8').split('\n');

// ---- the spec, read the way the other tests read it (the lines of the file, no YAML library) ------------------------------

export interface SpecOperation {
  operationId: string;
  method: string;
  /** The path template under /api/v2, e.g. `/packages/{namespace}/{name}`. */
  path: string;
}

/** Every operation of `paths:` in spec/api/openapi-v2.yaml. */
export function specOperations(): SpecOperation[] {
  const out: SpecOperation[] = [];
  let inPaths = false;
  let p = '';
  let method = '';
  for (const l of SPEC_LINES) {
    if (/^\S/.test(l)) inPaths = l.startsWith('paths:');
    if (!inPaths) continue;
    const pm = /^ {2}(\/\S*):\s*$/.exec(l);
    if (pm) p = pm[1]!;
    const mm = /^ {4}(get|put|post|delete|patch):\s*$/.exec(l);
    if (mm) method = mm[1]!.toUpperCase();
    const om = /^ {6}operationId: (\w+)\s*$/.exec(l);
    if (om) out.push({ operationId: om[1]!, method, path: p });
  }
  return out;
}

export interface CatalogueEntry {
  status: number;
  message: string;
  hint: string;
}

/** The `x-mopm-errors` table: code to status, message template and hint template. */
export function specCatalogue(): Record<string, CatalogueEntry> {
  const out: Record<string, CatalogueEntry> = {};
  const line = /^ {2}(\w+):\s+\{ status: (\d+), message: ("(?:[^"\\]|\\.)*"), hint: ("(?:[^"\\]|\\.)*") \}\s*$/;
  let inTable = false;
  for (const l of SPEC_LINES) {
    if (/^\S/.test(l)) inTable = l.startsWith('x-mopm-errors:');
    const m = inTable ? line.exec(l) : null;
    if (m) out[m[1]!] = { status: Number(m[2]), message: JSON.parse(m[3]!), hint: JSON.parse(m[4]!) };
  }
  return out;
}

/** The `RejectionCode` enum of the spec. */
export function specRejectionCodes(): string[] {
  const out: string[] = [];
  let inEnum = false;
  for (const l of SPEC_LINES) {
    if (/^ {4}\w+:/.test(l)) inEnum = l === '    RejectionCode:';
    const m = inEnum ? /^ {8}- (\w+)\s*$/.exec(l) : null;
    if (m) out.push(m[1]!);
  }
  return out;
}

const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/**
 * Whether `s` follows `template`: each `{placeholder}` stands for one or more characters of a line (tests/drivers/contract.zig,
 * followsTemplate).
 */
export function followsTemplate(template: string, s: string): boolean {
  const re = new RegExp(`^${template.split(/\{[a-z0-9_]+\}/).map(escapeRe).join('.+')}$`);
  return re.test(s);
}

// ---- the cases ------------------------------------------------------------------------------------------------------------

export const loadV2Cases = (): Array<Case & { file: string }> =>
  fs
    .readdirSync(CONTRACT_V2_DIR)
    .filter((f) => f.endsWith('.json'))
    .sort()
    .flatMap((f) => (JSON.parse(fs.readFileSync(path.join(CONTRACT_V2_DIR, f), 'utf8')).cases as Case[]).map((c) => ({ ...c, file: f })));

// ---- values the service makes at random ------------------------------------------------------------------------------------

/**
 * Values the service cannot reproduce: a secret, an id, a code, a cursor. A field of one of these names is compared by shape
 * only: the answer's value and the case's value must both be a string of the shape; the case's value then stands for both. Any
 * other field, and a value of the wrong shape, is compared as it is. `example` is the value a case file shows.
 */
export const OPAQUE: Record<string, { shape: RegExp; example: string }> = {
  /** A bearer token: `createToken`, the device login, the CI exchange. */
  token: { shape: /^mopm_[a-z2-7]{32,64}$/, example: 'mopm_q7x2kmzr5vhd3wnf6ytj4bcpaesg2uli' },
  /** The id of a token (`createToken`, `listTokens`). */
  id: { shape: /^tok_[0-9a-f]{24}$/, example: 'tok_7f3a2c19d0e45b68a1c3d7e2' },
  /** The code the CLI polls with. */
  device_code: { shape: /^dev_[0-9a-f]{48}$/, example: 'dev_5d8c1b7a93e24f60a1c3b8d4e7f20915a6c3d8e1b4f70293' },
  /** The cursor of a page: opaque. */
  next_cursor: { shape: /^[A-Za-z0-9_-]{8,512}$/, example: 'eyJrIjoibmFtZSIsImFmdGVyIjoiYWxpY2UvanNvbiJ9' },
  /** The id of an upload: the URL to PUT to names it, so that field follows its id (see `normalise`). */
  upload_id: { shape: /^upl_[0-9a-z]{32}$/, example: 'upl_4f1d9c27b8a5e3604d7c1b92a8e5f3d6' },
  /** The id of a publish: its `status_url` follows it. */
  publish_id: { shape: /^pub_[0-9a-f]{32}$/, example: 'pub_64a675c4d38aa322a79abeb12d75a025' },
};

/** The fields that carry an id of the same object in their text; they are compared after the id of the answer is replaced by the case's. */
const FOLLOWS_ID = ['put_url', 'status_url'];

/**
 * `actual` with every opaque value replaced by the case's own when both have the shape of the field (see OPAQUE), so the rest of
 * the comparison is exact. The text of `put_url` and `status_url` must hold the id of its own object: the answer's id in it is
 * replaced by the case's before the comparison, so a URL that names another id does not match.
 */
function normalise(actual: unknown, expected: unknown, key = ''): unknown {
  const opaque = OPAQUE[key];
  if (opaque && typeof actual === 'string' && typeof expected === 'string' && opaque.shape.test(actual) && opaque.shape.test(expected)) return expected;
  if (Array.isArray(actual) && Array.isArray(expected)) return actual.map((a, i) => normalise(a, expected[i], key));
  if (actual && expected && typeof actual === 'object' && typeof expected === 'object' && !Array.isArray(actual) && !Array.isArray(expected)) {
    const a = actual as Record<string, unknown>;
    const e = expected as Record<string, unknown>;
    const swaps: Array<[string, string]> = [];
    for (const k of ['publish_id', 'upload_id']) {
      if (typeof a[k] === 'string' && typeof e[k] === 'string' && OPAQUE[k]!.shape.test(a[k] as string) && OPAQUE[k]!.shape.test(e[k] as string)) swaps.push([a[k] as string, e[k] as string]);
    }
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(a)) {
      out[k] = FOLLOWS_ID.includes(k) && typeof v === 'string' ? swaps.reduce((t, [from, to]) => t.split(from).join(to), v) : normalise(v, e[k], k);
    }
    return out;
  }
  return actual;
}

// ---- recipes and the replay -------------------------------------------------------------------------------------------------

export type Send = (r: HttpRequest) => Promise<HttpResponse>;

export interface Recipe {
  world?: WorldOptions;
  /** Build the state the case describes, on top of the fixed one. */
  setup?: (w: World) => Promise<void>;
  /** The `Authorization` header value. A case that names a security scheme needs one; one that does not sends none unless this is given. */
  bearer?: (w: World) => Promise<string>;
  /** Rewrite the request after the case built it (a real id, a signed token, a cursor from a first page). */
  prepare?: (req: HttpRequest, w: World) => Promise<HttpRequest>;
  /** Top-level keys of the answer that this implementation adds on purpose and the case does not show. */
  extraKeys?: string[];
  /** The router is given a store that fails, for internal_error. */
  failingStore?: boolean;
}

const withPath = (tpl: string, params: Record<string, string> = {}) => tpl.replace(/\{(\w+)\}/g, (_m, k: string) => encodeURIComponent(params[k] ?? ''));

/** Build the world a case describes, send its request and answer what the router said. */
export async function execute(c: Case, recipe: Recipe, ops: Map<string, SpecOperation>): Promise<HttpResponse> {
  const op = ops.get(c.operationId);
  if (!op) throw new Error(`operationId ${c.operationId} is not in the spec`);
  const w = await buildWorld(recipe.world);
  if (recipe.failingStore) {
    w.deps.store = new Proxy({}, { get: () => async () => { throw new Error('dynamodb exploded'); } }) as never;
  }
  if (recipe.setup) await recipe.setup(w);
  const headers: Record<string, string> = {};
  if (recipe.bearer) headers.authorization = await recipe.bearer(w);
  else if (c.request.auth) throw new Error(`the case sends ${c.request.auth} and its recipe gives no bearer`);
  let req: HttpRequest = {
    method: op.method,
    path: `/api/v2${withPath(op.path, c.request.path)}`,
    query: Object.fromEntries(Object.entries(c.request.query ?? {}).map(([k, v]) => [k, String(v)])),
    headers,
    ...(c.request.body !== undefined ? { body: JSON.stringify(c.request.body) } : {}),
  };
  if (recipe.prepare) req = await recipe.prepare(req, w);
  return w.send(req);
}

/**
 * Replay one case against the router and return the mismatches (empty when the answer is the case's answer): status, the
 * request id header, `retry-after` when the case has one, and the whole body, deep-equal, after the shape comparison of OPAQUE.
 */
export async function replayV2(c: Case, recipe: Recipe, ops: Map<string, SpecOperation>): Promise<string[]> {
  const res = await execute(c, recipe, ops);
  const problems: string[] = [];
  if (res.statusCode !== c.response.status) problems.push(`status ${res.statusCode}, want ${c.response.status}`);
  if (!res.headers['x-mopm-request-id']) problems.push('missing x-mopm-request-id');
  const want = Object.entries(c.response.headers ?? {}).filter(([k]) => k.toLowerCase() === 'retry-after');
  for (const [k, v] of want) if (res.headers[k.toLowerCase()] !== v) problems.push(`${k} ${res.headers[k.toLowerCase()]}, want ${v}`);
  const actual = res.body === '' ? undefined : JSON.parse(res.body);
  for (const k of recipe.extraKeys ?? []) if (actual) delete actual[k];
  // A JSON round trip, not structuredClone: under jest the latter yields objects of another realm, which isDeepStrictEqual rejects.
  const expected = c.response.body === undefined ? undefined : JSON.parse(JSON.stringify(c.response.body));
  if (!isDeepStrictEqual(normalise(actual, expected), expected)) problems.push(`body ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`);
  return problems;
}
