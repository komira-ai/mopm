// The API contract fixtures (tests/contract/api/*.json at the repo root): the same cases the contract check
// validates, so the site is tested against exactly what the API promises.

import { readFileSync } from 'fs';
import { join } from 'path';

export const CONTRACT_DIR = join(__dirname, '..', '..', 'tests', 'contract', 'api');

export interface ContractCase {
  name: string;
  operationId: string;
  request: {
    path?: Record<string, string | number>;
    query?: Record<string, string | number>;
  };
  response: { status: number; headers: Record<string, string>; body: unknown };
  /** Present ('invalid') only on cases the contract check must reject. */
  expect?: string;
  malformed_request?: boolean;
}

/** The read operations the site's client calls. */
export const READ_OPS = ['getHealth', 'searchPackages', 'getPackage', 'getVersion'] as const;
export type ReadOp = (typeof READ_OPS)[number];

export function load(file: 'packages' | 'owners' | 'meta' | 'errors'): ContractCase[] {
  const doc = JSON.parse(readFileSync(join(CONTRACT_DIR, `${file}.json`), 'utf8')) as { cases: ContractCase[] };
  return doc.cases;
}

export function allCases(): ContractCase[] {
  return (['packages', 'owners', 'meta', 'errors'] as const).flatMap(load);
}

/** Valid (no `expect` key) successful answers of the read operations. */
export function validReadCases(): (ContractCase & { operationId: ReadOp })[] {
  return allCases().filter(
    (c): c is ContractCase & { operationId: ReadOp } =>
      c.expect === undefined &&
      (READ_OPS as readonly string[]).includes(c.operationId) &&
      c.response.status >= 200 &&
      c.response.status < 300,
  );
}

/** Valid error answers (any operation): every one is a well-formed error envelope. */
export function validErrorCases(): ContractCase[] {
  return load('errors').filter((c) => c.expect === undefined);
}

/** A Response for a fixture answer. */
export function responseOf(c: ContractCase): Response {
  return new Response(JSON.stringify(c.response.body), { status: c.response.status, headers: c.response.headers });
}
