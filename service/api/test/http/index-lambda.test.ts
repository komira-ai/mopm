import { indexKey } from '../../src/index-files';

const CREDS = { AWS_ACCESS_KEY_ID: 'AKIDEXAMPLE', AWS_SECRET_ACCESS_KEY: 'example-secret', AWS_REGION: 'us-east-1' };
const event = (rawPath: string, method = 'GET') => ({ rawPath, requestContext: { requestId: 'r-1', http: { method } } });

/** Loads the handler afresh (a container keeps its configuration), with `fetch` replaced by a scripted S3. */
async function load(env: Record<string, string>, reply: (url: string) => { status: number; body?: string }) {
  jest.resetModules();
  const saved = { ...process.env };
  Object.assign(process.env, CREDS, env);
  const urls: string[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (url: string) => {
    urls.push(url);
    const r = reply(url);
    const body = Buffer.from(r.body ?? '');
    return {
      status: r.status,
      headers: { get: () => null },
      text: async () => body.toString('utf8'),
      arrayBuffer: async () => body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength),
    };
  }) as unknown as typeof fetch;
  const mod = await import('../../src/http/index-lambda');
  return {
    handler: mod.handler,
    urls,
    restore: () => {
      globalThis.fetch = realFetch;
      for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k];
      Object.assign(process.env, saved);
    },
  };
}

describe('the reader function', () => {
  test('reads the key of the validated name from the channel bucket and returns its bytes', async () => {
    const t = await load({ MOPM_CHANNEL_BUCKET: 'chan' }, () => ({ status: 200, body: '{"v":1}\n' }));
    try {
      const res = await t.handler(event('/index/ht/tp/http_client'));
      expect(res.statusCode).toBe(200);
      expect(res.body).toBe('{"v":1}\n');
      expect(t.urls).toEqual([`https://chan.s3.us-east-1.amazonaws.com/${indexKey('http_client')}`]);
    } finally {
      t.restore();
    }
  });

  test('S3 404 is 404; S3 403 is 502', async () => {
    for (const [status, want] of [[404, 404], [403, 502], [500, 502]] as const) {
      const t = await load({ MOPM_CHANNEL_BUCKET: 'chan' }, () => ({ status, body: '<Error/>' }));
      const spy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
      try {
        expect((await t.handler(event('/index/ht/tp/http_client'))).statusCode).toBe(want);
      } finally {
        spy.mockRestore();
        t.restore();
      }
    }
  });

  test('a path that is not a file never calls S3', async () => {
    const t = await load({ MOPM_CHANNEL_BUCKET: 'chan' }, () => ({ status: 200, body: 'x' }));
    try {
      expect((await t.handler(event('/index/%2e%2e/x'))).statusCode).toBe(404);
      expect(t.urls).toEqual([]);
    } finally {
      t.restore();
    }
  });

  test('without the bucket name the function refuses to start', async () => {
    const saved = process.env.MOPM_CHANNEL_BUCKET;
    delete process.env.MOPM_CHANNEL_BUCKET;
    const t = await load({}, () => ({ status: 200 }));
    try {
      await expect(t.handler(event('/index/ht/tp/http_client'))).rejects.toThrow('MOPM_CHANNEL_BUCKET is not set');
    } finally {
      t.restore();
      if (saved !== undefined) process.env.MOPM_CHANNEL_BUCKET = saved;
    }
  });
});
