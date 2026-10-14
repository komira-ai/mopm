import * as fs from 'fs';
import * as path from 'path';
import { isDeepStrictEqual } from 'util';
import { MemoryStore } from '../../src/memory-store';
import type { Store } from '../../src/store';
import { route, type HttpRequest, type HttpResponse, type RouterDeps, type Stage } from '../../src/http/router';

/** One case of tests/contract/api/*.json (see tests/contract/README.md). */
export interface Case {
  name: string;
  operationId: string;
  request: { path?: Record<string, string>; query?: Record<string, unknown>; body?: unknown; auth?: string };
  response: { status: number; headers?: Record<string, string>; body?: any }; // eslint-disable-line @typescript-eslint/no-explicit-any
  expect?: 'valid' | 'invalid';
  malformed_request?: boolean;
}

export type Router = (req: HttpRequest, deps: RouterDeps, requestId: string) => Promise<HttpResponse>;

export const CONTRACT_DIR = path.resolve(__dirname, '../../../../tests/contract/api');
export const LOCAL_FIXTURES = path.resolve(__dirname, '../fixtures/api-read.json');

export const loadCases = (file: string): Case[] => JSON.parse(fs.readFileSync(file, 'utf8')).cases;

/** The operations this package serves, as method and path template under /api/v1. */
export const OPERATIONS: Record<string, string> = {
  getHealth: '/health',
  searchPackages: '/packages',
  getPackage: '/packages/{name}',
  listVersions: '/packages/{name}/versions',
};

/** Cases the handler never produces: the gateway or an upstream limit answers them, not this code. */
export const NOT_PRODUCED_BY_HANDLER = new Set(['error rate_limited', 'error unavailable']);

export interface Recipe {
  stage?: Stage;
  readOnly?: boolean;
  /** Build the state the case describes. */
  seed?: (s: MemoryStore) => Promise<void>;
  /** Replace the store (a store that fails, for internal_error). */
  store?: () => Store;
  /** Rewrite the request, e.g. to ask the router for a real cursor first (cursors are opaque, fixtures cannot carry one). */
  prepare?: (req: HttpRequest, send: (r: HttpRequest) => Promise<HttpResponse>) => Promise<HttpRequest>;
  /** Top-level response keys this implementation adds on purpose (additive fields the contract allows). */
  extraKeys?: string[];
  /** Top-level keys of the fixture that are optional in the contract and not emitted. */
  omitExpected?: string[];
}

const withPath = (tpl: string, params: Record<string, string> = {}) =>
  tpl.replace(/\{(\w+)\}/g, (_m, k: string) => encodeURIComponent(params[k] ?? ''));

const stringifyQuery = (q: Record<string, unknown> = {}) =>
  Object.fromEntries(Object.entries(q).map(([k, v]) => [k, String(v)]));

/**
 * Replay one case against a router. Returns the mismatches (empty when the answer is the case's answer):
 * status, request id header, and the whole body, deep-equal. An opaque `next_cursor` is compared as
 * "null stays null, a string stays a string".
 */
export async function replay(c: Case, recipe: Recipe, router: Router): Promise<string[]> {
  const store = recipe.store ? recipe.store() : new MemoryStore();
  if (recipe.seed) await recipe.seed(store as MemoryStore);
  const deps: RouterDeps = { store, stage: recipe.stage ?? 'beta', version: 'test', commit: 'test', readOnly: recipe.readOnly ?? false };
  const send = (r: HttpRequest) => router(r, deps, 'req-test');
  let req: HttpRequest = {
    method: 'GET',
    path: `/api/v1${withPath(OPERATIONS[c.operationId]!, c.request.path)}`,
    query: stringifyQuery(c.request.query),
  };
  if (recipe.prepare) req = await recipe.prepare(req, send);
  const res = await send(req);

  const problems: string[] = [];
  if (res.statusCode !== c.response.status) problems.push(`status ${res.statusCode}, want ${c.response.status}`);
  if (!res.headers['x-mopm-request-id']) problems.push('missing x-mopm-request-id');
  const actual = JSON.parse(res.body);
  for (const k of recipe.extraKeys ?? []) delete actual[k];
  // A JSON round trip, not structuredClone: under jest the latter yields objects of another realm, which isDeepStrictEqual rejects.
  const expected = JSON.parse(JSON.stringify(c.response.body));
  for (const k of recipe.omitExpected ?? []) delete expected[k];
  if (expected && 'next_cursor' in expected && typeof expected.next_cursor === 'string' && typeof actual.next_cursor === 'string') {
    actual.next_cursor = expected.next_cursor;
  }
  if (!isDeepStrictEqual(actual, expected)) problems.push(`body ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`);
  return problems;
}

export { route };
