import { indexKey } from '../../src/index-files';

const CREDS = { AWS_ACCESS_KEY_ID: 'AKIDEXAMPLE', AWS_SECRET_ACCESS_KEY: 'example-secret', AWS_REGION: 'us-east-1' };
const event = (rawPath: string, method = 'GET') => ({ rawPath, requestContext: { requestId: 'r-1', http: { method } } });

/** Loads the handler afresh (a container keeps its configuration), with `fetch` replaced by a scripted S3. */
async function load(env: Record<string, string>, reply: (url: string) => { status: number; body?: string }, dropRegion = false) {
  jest.resetModules();
  const saved = { ...process.env };
  Object.assign(process.env, CREDS, env);
  if (dropRegion) delete process.env.AWS_REGION;
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

  test('without AWS_REGION the bucket is addressed in us-east-1', async () => {
    const t = await load({ MOPM_CHANNEL_BUCKET: 'chan' }, () => ({ status: 200, body: 'x\n' }), true);
    try {
      expect((await t.handler(event('/index/ht/tp/http_client'))).statusCode).toBe(200);
      expect(t.urls[0]).toContain('chan.s3.us-east-1.amazonaws.com');
    } finally {
      t.restore();
    }
  });

  test('S3 404 is 404; any other S3 failure is 502', async () => {
    for (const [status, want] of [[404, 404], [400, 502], [500, 502]] as const) {
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

  const KEY = indexKey('http_client');
  const listOf = (...keys: string[]) => ({ status: 200, body: `<ListBucketResult>${keys.map((k) => `<Contents><Key>${k}</Key></Contents>`).join('')}</ListBucketResult>` });
  const s3 = (list: { status: number; body?: string }) => (url: string) => (url.includes('list-type=2') ? list : { status: 403, body: '<Error>AccessDenied</Error>' });

  test('S3 403 and an empty listing for the exact key (a never-published package) is 404', async () => {
    const t = await load({ MOPM_CHANNEL_BUCKET: 'chan' }, s3(listOf()));
    try {
      expect((await t.handler(event('/index/ht/tp/http_client'))).statusCode).toBe(404);
      expect(t.urls[1]).toContain('prefix=' + encodeURIComponent(KEY));
      expect(t.urls[1]).toContain('max-keys=1');
    } finally {
      t.restore();
    }
  });

  test('S3 403 and a listing with the exact key (present but forbidden) is 502, logged', async () => {
    const t = await load({ MOPM_CHANNEL_BUCKET: 'chan' }, s3(listOf(KEY)));
    const spy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      expect((await t.handler(event('/index/ht/tp/http_client'))).statusCode).toBe(502);
      expect(spy).toHaveBeenCalledTimes(1);
    } finally {
      spy.mockRestore();
      t.restore();
    }
  });

  test('S3 403 and a listing with only a longer name under the same prefix is 404', async () => {
    const t = await load({ MOPM_CHANNEL_BUCKET: 'chan' }, s3(listOf(`${KEY}2`)));
    try {
      expect((await t.handler(event('/index/ht/tp/http_client'))).statusCode).toBe(404);
    } finally {
      t.restore();
    }
  });

  test('S3 403 and a failing listing is 502, logged', async () => {
    const t = await load({ MOPM_CHANNEL_BUCKET: 'chan' }, s3({ status: 500, body: '<Error/>' }));
    const spy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      expect((await t.handler(event('/index/ht/tp/http_client'))).statusCode).toBe(502);
      expect(spy).toHaveBeenCalledTimes(1);
    } finally {
      spy.mockRestore();
      t.restore();
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
