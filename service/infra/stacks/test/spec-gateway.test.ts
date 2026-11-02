import * as fs from 'fs';
import * as path from 'path';
import { AUTH_ROUTES, CLAIM_ROUTES, PUBLISH_ROUTES, READ_ROUTES } from '../lib/api-stack';

/**
 * Every operation of spec/api/openapi.yaml (each path with each method) is routed at the gateway or is on the list of operations that
 * are not served yet. A route the gateway lacks never reaches the handler: `mopm whoami` called GET /api/v1/me, which the router could
 * not serve and the gateway did not route. This is the gateway half; service/api/test/http/spec-routes.test.ts is the router half and
 * lists the same operations as not served. Operations are compared as `METHOD /api/v1/<path>`.
 */

const SPEC = path.resolve(__dirname, '../../../../spec/api/openapi.yaml');

/** Not served yet (no router branch, no gateway route): ownership invitations and owner management. Remove an entry with its branch and route. */
const NOT_SERVED_YET = [
  'GET /api/v1/me/invitations',
  'POST /api/v1/me/invitations/{invitation_id}/accept',
  'PUT /api/v1/packages/{name}/owners',
  'DELETE /api/v1/packages/{name}/owners/{github_id}',
];

function specOperations(): string[] {
  const out: string[] = [];
  let inPaths = false;
  let current: string | undefined;
  for (const line of fs.readFileSync(SPEC, 'utf8').split('\n')) {
    if (/^\S/.test(line)) inPaths = line.startsWith('paths:');
    if (!inPaths) continue;
    const p = /^  (\/\S*):\s*$/.exec(line);
    if (p) current = p[1];
    const m = /^    (get|post|put|delete|patch):\s*$/.exec(line);
    if (m && current) out.push(`${m[1]!.toUpperCase()} /api/v1${current}`);
  }
  return out;
}

const routed = new Set([
  ...READ_ROUTES.map((p) => `GET ${p}`),
  ...[...PUBLISH_ROUTES, ...CLAIM_ROUTES, ...AUTH_ROUTES].map((r) => `${r.method} ${r.path}`),
]);

describe('the gateway routes every operation of the spec', () => {
  const ops = specOperations();

  test('the spec is read (an empty list proves nothing), and every not-served entry is an operation of the spec', () => {
    expect(ops.length).toBeGreaterThanOrEqual(25);
    expect(ops).toContain('GET /api/v1/me');
    for (const o of NOT_SERVED_YET) expect(ops).toContain(o);
  });

  test.each(ops.filter((o) => !NOT_SERVED_YET.includes(o)))('%s is a gateway route', (op) => {
    expect(routed.has(op)).toBe(true);
  });

  test.each(NOT_SERVED_YET)('%s has no gateway route yet (routed now: take it off the list)', (op) => {
    expect(routed.has(op)).toBe(false);
  });
});
