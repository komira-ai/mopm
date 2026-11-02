import { createHash } from 'node:crypto';
import { readFileSync } from 'fs';
import { join } from 'path';
import { MemoryStore } from '../../src/memory-store';
import { route, type HttpRequest, type RouterDeps, type Stage } from '../../src/http/router';
import { validate } from '../json-schema';

const CONFIG = JSON.parse(readFileSync(join(__dirname, '../../../../spec/index-config.schema.json'), 'utf8'));

const HOSTS: Record<Stage, { apiDomain: string; channelDomain: string }> = {
  beta: { apiDomain: 'api.beta.mopm.dev', channelDomain: 'conda.beta.mopm.dev' },
  gamma: { apiDomain: 'api.gamma.mopm.dev', channelDomain: 'conda.gamma.mopm.dev' },
  prod: { apiDomain: 'api.mopm.dev', channelDomain: 'conda.mopm.dev' },
};

const deps = (stage: Stage, over: Partial<RouterDeps> = {}): RouterDeps => ({
  store: new MemoryStore(),
  stage,
  version: 'v',
  commit: 'c',
  readOnly: false,
  indexConfig: HOSTS[stage],
  ...over,
});
const call = (d: RouterDeps, req: Partial<HttpRequest> = {}) => route({ method: 'GET', path: '/index/config.json', query: {}, ...req }, d, 'req-9');

describe.each(['beta', 'gamma', 'prod'] as const)('GET /index/config.json on %s', (stage) => {
  test('is 200 JSON that the config schema accepts, for this stage', async () => {
    const res = await call(deps(stage));
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    expect(validate(CONFIG, body)).toEqual([]);
    expect(body.index_version).toBe(1);
    expect(body.stage).toBe(stage);
    expect(body.api_url).toBe(`https://${HOSTS[stage].apiDomain}/api/v1`);
    expect(body.channel_url).toBe(`https://${HOSTS[stage].channelDomain}/`);
    expect(body.min_cli_version).toBe('0.0.1');
    expect(body.read_only).toBe(false);
  });

  test('read_only is the live switch of the request', async () => {
    expect(JSON.parse((await call(deps(stage, { readOnly: true }))).body).read_only).toBe(true);
    expect(JSON.parse((await call(deps(stage, { readOnly: false }))).body).read_only).toBe(false);
  });
});

describe('the config response', () => {
  test('headers: JSON, cacheable for a minute, a strong etag of the body, the request id', async () => {
    const res = await call(deps('beta'));
    expect(res.headers['content-type']).toBe('application/json');
    expect(res.headers['cache-control']).toBe('public, max-age=60');
    expect(res.headers.etag).toBe(`"${createHash('sha256').update(res.body).digest('hex')}"`);
    expect(res.headers['x-mopm-request-id']).toBe('req-9');
    expect(res.body.endsWith('\n')).toBe(true);
  });

  test('needs no token: an unauthenticated request and one with a bad token both get the config', async () => {
    expect((await call(deps('beta'), { headers: {} })).statusCode).toBe(200);
    expect((await call(deps('beta'), { headers: { authorization: 'Bearer nope' } })).statusCode).toBe(200);
  });

  test('is served with the registry store untouched (it reads nothing)', async () => {
    const store = new MemoryStore();
    const touched: string[] = [];
    const spy = new Proxy(store, { get: (t, k, r) => (typeof (t as any)[k] === 'function' ? (...a: unknown[]) => (touched.push(String(k)), (t as any)[k](...a)) : Reflect.get(t, k, r)) });
    await call(deps('beta', { store: spy }));
    expect(touched).toEqual([]);
  });

  test('a stage that was not given its hosts answers 404, not a config with guessed hosts', async () => {
    const d = deps('beta');
    delete d.indexConfig;
    const res = await call(d);
    expect(res.statusCode).toBe(404);
    expect(JSON.parse(res.body).error.code).toBe('route_not_found');
  });

  test('hosts that are not bare host names are an internal error, never a malformed config', async () => {
    const spy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      const res = await call(deps('beta', { indexConfig: { apiDomain: 'https://api.beta.mopm.dev', channelDomain: 'conda.beta.mopm.dev' } }));
      expect(res.statusCode).toBe(500);
    } finally {
      spy.mockRestore();
    }
  });

  test.each(['POST', 'PUT', 'DELETE'])('%s is not the config', async (method) => {
    expect((await call(deps('beta'), { method })).statusCode).toBe(404);
  });

  test('other /index/ paths are not answered by the API function', async () => {
    for (const path of ['/index/takedowns.json', '/index/ht/tp/http_client', '/index/config.json/x', '/index/Config.json']) {
      expect((await call(deps('beta'), { path })).statusCode).toBe(404);
    }
  });

  test('the /api/v1 operations are unchanged next to it', async () => {
    const res = await call(deps('beta'), { path: '/api/v1/health' });
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body).stage).toBe('beta');
  });
});
