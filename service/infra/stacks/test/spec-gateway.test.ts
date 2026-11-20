import * as fs from 'fs';
import * as path from 'path';
import { Template } from 'aws-cdk-lib/assertions';
import { AUTH_ROUTES, CLAIM_ROUTES, PUBLISH_ROUTES, READ_ROUTES, V2_ROUTES } from '../lib/api-stack';
import { STAGES } from '../lib/config';
import { RUST_ZIP_STUB_DIR, build } from './util';

/**
 * Every operation of spec/api/openapi.yaml (each path with each method) is routed at the gateway or is on the list of operations that
 * are not served yet. A route the gateway lacks never reaches the handler: `mopm whoami` called GET /api/v1/me, which the router could
 * not serve and the gateway did not route. This is the gateway half; service/api/test/http/spec-routes.test.ts is the router half and
 * lists the same operations as not served. Operations are compared as `METHOD /api/v1/<path>`.
 */

const SPEC = path.resolve(__dirname, '../../../../spec/api/openapi.yaml');
const SPEC_V2 = path.resolve(__dirname, '../../../../spec/api/openapi-v2.yaml');

/** Not served yet (no router branch, no gateway route): ownership invitations and owner management. Remove an entry with its branch and route. */
const NOT_SERVED_YET = [
  'GET /api/v1/me/invitations',
  'POST /api/v1/me/invitations/{invitation_id}/accept',
  'PUT /api/v1/packages/{name}/owners',
  'DELETE /api/v1/packages/{name}/owners/{github_id}',
];

/**
 * Operations of the /api/v2 spec that are not the TypeScript Lambda's: the website's sign-in and tutorial sandbox. They are served
 * by the website's own functions behind the site's /api/* behaviour. This gateway has no route for them in the default build; with
 * `rustZipDir` it routes each to its Rust function (web-login, web-session, tutorial-sandbox), never to the TypeScript Lambda.
 * Remove an entry when the TypeScript Lambda serves it.
 */
const NOT_THE_TS_LAMBDA_V2 = [
  'GET /api/v2/auth/web/start',
  'GET /api/v2/auth/web/callback',
  'GET /api/v2/auth/web/session',
  'POST /api/v2/auth/web/logout',
  'POST /api/v2/tutorial/sandbox',
];

function specOperations(file: string = SPEC, prefix = '/api/v1'): string[] {
  const out: string[] = [];
  let inPaths = false;
  let current: string | undefined;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (/^\S/.test(line)) inPaths = line.startsWith('paths:');
    if (!inPaths) continue;
    const p = /^  (\/\S*):\s*$/.exec(line);
    if (p) current = p[1];
    const m = /^    (get|post|put|delete|patch):\s*$/.exec(line);
    if (m && current) out.push(`${m[1]!.toUpperCase()} ${prefix}${current}`);
  }
  return out;
}

const routed = new Set([
  ...READ_ROUTES.map((p) => `GET ${p}`),
  ...[...PUBLISH_ROUTES, ...CLAIM_ROUTES, ...AUTH_ROUTES, ...V2_ROUTES].map((r) => `${r.method} ${r.path}`),
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

// The v2 half: every operation of spec/api/openapi-v2.yaml except the website's is a gateway route `METHOD /api/v2<path>`,
// and V2_ROUTES holds nothing else.
describe('the gateway routes every operation of the /api/v2 spec', () => {
  const ops = specOperations(SPEC_V2, '/api/v2');

  test('the spec is read (an empty list proves nothing)', () => {
    expect(ops.length).toBeGreaterThanOrEqual(20);
    expect(ops).toContain('PUT /api/v2/packages/{namespace}/{name}');
    expect(ops).toContain('POST /api/v2/namespaces');
    expect(ops).toContain('POST /api/v2/namespaces/poll');
    expect(ops).toContain('GET /api/v2/namespaces/{namespace}/members');
    expect(ops).toContain('PUT /api/v2/namespaces/{namespace}/members/{user}');
    expect(ops).toContain('DELETE /api/v2/namespaces/{namespace}/members/{user}');
    for (const o of NOT_THE_TS_LAMBDA_V2) expect(ops).toContain(o);
  });

  const served = ops.filter((o) => !NOT_THE_TS_LAMBDA_V2.includes(o));

  test.each(served)('%s is a gateway route', (op) => {
    expect(routed.has(op)).toBe(true);
  });

  test.each(NOT_THE_TS_LAMBDA_V2)('%s is the website\'s, so this gateway has no route for it (default build)', (op) => {
    expect(routed.has(op)).toBe(false);
  });

  test('V2_ROUTES lists exactly the operations of the spec the TypeScript Lambda serves, each once', () => {
    const listed = V2_ROUTES.map((r) => `${r.method} ${r.path}`);
    expect([...listed].sort()).toEqual([...served].sort());
    expect(new Set(listed).size).toBe(listed.length);
  });

  test('no v2 route names an operation of the retired owner model', () => {
    expect(V2_ROUTES.filter((r) => /owners|invitations|claim/.test(r.path))).toEqual([]);
  });
});

// With the Rust switch on, the sign-in operations are routed here to the web-login function, session and logout to the
// web-session function, and the sandbox to the tutorial-sandbox function.
describe.each(STAGES)('the gateway with the Rust functions on (%s)', (stage) => {
  const t = Template.fromStack(build(stage, { rustZipDir: RUST_ZIP_STUB_DIR }).api);
  const routes = Object.values(t.findResources('AWS::ApiGatewayV2::Route')) as any[];
  const keys = routes.map((r) => r.Properties.RouteKey as string);
  const targetOf = (key: string) => routes.find((r) => r.Properties.RouteKey === key).Properties.Target;

  test('session and logout route to the web-session function, not the TypeScript Lambda', () => {
    const integrations = t.findResources('AWS::ApiGatewayV2::Integration') as Record<string, any>;
    const webSession = Object.keys(t.findResources('AWS::Lambda::Function', { Properties: { FunctionName: `mopm-${stage}-web-session` } }));
    expect(webSession).toHaveLength(1);
    for (const key of ['GET /api/v2/auth/web/session', 'POST /api/v2/auth/web/logout']) {
      const integrationId = targetOf(key)['Fn::Join'][1].find((x: any) => x?.Ref)?.Ref as string;
      expect(integrations[integrationId].Properties.IntegrationUri).toEqual({ 'Fn::GetAtt': [webSession[0], 'Arn'] });
    }
  });

  test('start and callback route to the web-login function', () => {
    const integrations = t.findResources('AWS::ApiGatewayV2::Integration') as Record<string, any>;
    const webLogin = Object.keys(t.findResources('AWS::Lambda::Function', { Properties: { FunctionName: `mopm-${stage}-web-login` } }));
    expect(webLogin).toHaveLength(1);
    for (const key of ['GET /api/v2/auth/web/start', 'GET /api/v2/auth/web/callback']) {
      const integrationId = targetOf(key)['Fn::Join'][1].find((x: any) => x?.Ref)?.Ref as string;
      expect(integrations[integrationId].Properties.IntegrationUri).toEqual({ 'Fn::GetAtt': [webLogin[0], 'Arn'] });
    }
  });

  test('the sandbox routes to the tutorial-sandbox function', () => {
    const integrations = t.findResources('AWS::ApiGatewayV2::Integration') as Record<string, any>;
    const sandbox = Object.keys(t.findResources('AWS::Lambda::Function', { Properties: { FunctionName: `mopm-${stage}-tutorial-sandbox` } }));
    expect(sandbox).toHaveLength(1);
    expect(keys.filter((k) => k === 'POST /api/v2/tutorial/sandbox')).toHaveLength(1);
    const integrationId = targetOf('POST /api/v2/tutorial/sandbox')['Fn::Join'][1].find((x: any) => x?.Ref)?.Ref as string;
    expect(integrations[integrationId].Properties.IntegrationUri).toEqual({ 'Fn::GetAtt': [sandbox[0], 'Arn'] });
  });
});
