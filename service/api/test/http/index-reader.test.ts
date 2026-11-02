import { createHash } from 'node:crypto';
import { buildPackageIndex, buildTakedowns, indexKey } from '../../src/index-files';
import { keyOfPath, readIndex, type IndexObjects } from '../../src/http/index-reader';
import { ALL_FIXTURE_ROWS, FIXTURE_PACKAGES } from '../fixtures/index-registry';

/** A bucket of objects; `fail` makes a key answer like S3 does when it refuses or breaks. */
function bucket(files: Record<string, string | Buffer>, fail: Record<string, Error> = {}) {
  const asked: string[] = [];
  const objects: IndexObjects = {
    async get(key) {
      asked.push(key);
      if (fail[key]) throw fail[key];
      const f = files[key];
      return f === undefined ? undefined : Buffer.from(f);
    },
  };
  return { objects, asked };
}

const NAMES = Object.keys(FIXTURE_PACKAGES);
const stored = () => Object.fromEntries(NAMES.map((n) => [indexKey(n), buildPackageIndex(n, FIXTURE_PACKAGES[n]!)!]));
const get = (b: ReturnType<typeof bucket>, path: string, method = 'GET') => readIndex(b.objects, { method, path }, 'req-1');
const pathOf = (name: string) => `/${indexKey(name)}`;

describe('a stored file is served as it was stored', () => {
  test.each(NAMES)('%s: the response body is the exact bytes the builder wrote', async (name) => {
    const b = bucket(stored());
    const res = await get(b, pathOf(name));
    expect(res.statusCode).toBe(200);
    expect(res.isBase64Encoded).toBeUndefined();
    expect(res.body).toBe(buildPackageIndex(name, FIXTURE_PACKAGES[name]!));
    expect(res.body.endsWith('\n')).toBe(true);
    expect(b.asked).toEqual([indexKey(name)]);
  });

  test('takedowns.json is served from its key, byte for byte', async () => {
    const text = buildTakedowns(ALL_FIXTURE_ROWS);
    const b = bucket({ 'index/takedowns.json': text });
    const res = await get(b, '/index/takedowns.json');
    expect(res.statusCode).toBe(200);
    expect(res.body).toBe(text);
    expect(res.headers['content-type']).toBe('application/json');
  });

  test('bytes that are not valid UTF-8 are not altered: they go out base64-encoded', async () => {
    const raw = Buffer.from([0x7b, 0xff, 0xfe, 0x7d, 0x0a]);
    const res = await get(bucket({ [indexKey('http_client')]: raw }), pathOf('http_client'));
    expect(res.statusCode).toBe(200);
    expect(res.isBase64Encoded).toBe(true);
    expect(Buffer.from(res.body, 'base64').equals(raw)).toBe(true);
  });
});

describe('headers', () => {
  test('a package file is NDJSON, cacheable for a minute, with a strong etag of its bytes and the request id', async () => {
    const name = NAMES[0]!;
    const res = await get(bucket(stored()), pathOf(name));
    expect(res.headers['content-type']).toBe('application/x-ndjson');
    expect(res.headers['cache-control']).toBe('public, max-age=60');
    expect(res.headers.etag).toBe(`"${createHash('sha256').update(res.body).digest('hex')}"`);
    expect(res.headers['x-mopm-request-id']).toBe('req-1');
  });

  test('the etag changes when the bytes change', async () => {
    const a = await get(bucket({ [indexKey('http_client')]: 'a\n' }), pathOf('http_client'));
    const b = await get(bucket({ [indexKey('http_client')]: 'b\n' }), pathOf('http_client'));
    expect(a.headers.etag).not.toBe(b.headers.etag);
  });

  test('an error is JSON and is never cached', async () => {
    for (const res of [await get(bucket({}), pathOf('http_client')), await get(bucket({}, { [indexKey('http_client')]: new Error('x') }), pathOf('http_client'))]) {
      expect(res.headers['content-type']).toBe('application/json');
      expect(res.headers['cache-control']).toBe('no-store');
      expect(res.headers['x-mopm-request-id']).toBe('req-1');
    }
  });
});

describe('a path that is not a file of the index is 404 and never reaches the bucket', () => {
  const good = pathOf('http_client'); // /index/ht/tp/http_client
  test.each([
    ['nothing after /index/', '/index/'],
    ['/index alone', '/index'],
    ['a 3-segment path', '/index/ht/tp'],
    ['a 5-segment path', `${good}/extra`],
    ['a trailing slash', `${good}/`],
    ['a double slash', '/index/ht//tp/http_client'],
    ['a leading double slash', `/${good}`],
    ['an upper-case name', '/index/ht/tp/Http_client'],
    ['an upper-case directory', '/index/HT/tp/http_client'],
    ['a prefix that is not the name\'s (aa)', '/index/zz/tp/http_client'],
    ['a prefix that is not the name\'s (bb)', '/index/ht/zz/http_client'],
    ['swapped directories', '/index/tp/ht/http_client'],
    ['dot-dot', '/index/ht/tp/../http_client'],
    ['dot-dot to the quarantine', '/index/../quarantine/x'],
    ['dot-dot to the repodata', '/index/ht/tp/../../../noarch/repodata.json'],
    ['an encoded dot-dot', '/index/%2e%2e/quarantine/x'],
    ['an upper-case encoded dot-dot', '/index/%2E%2E/tp/http_client'],
    ['an encoded slash in the name', '/index/ht/tp/http%2Fclient'],
    ['an encoded slash for the directory', '/index/ht%2Ftp/http_client'],
    ['an encoded name', '/index/ht/tp/http%5Fclient'],
    ['a name starting with a digit', '/index/1a/bc/1abc'],
    ['a one-character name', '/index/a_/__/a'],
    ['a name of 65 characters', `/index/aa/aa/a${'a'.repeat(64)}`],
    ['a dash in the name', '/index/ht/tp/http-client'],
    ['a dot in the name', '/index/ht/tp/http.client'],
    ['the config path (built by the API, not stored)', '/index/config.json'],
    ['takedowns with a suffix', '/index/takedowns.json/x'],
    ['takedowns in another case', '/index/Takedowns.json'],
    ['a query-looking suffix', `${good}?x=1`],
    ['the quarantine', '/quarantine/abc/file'],
    ['a repodata path', '/noarch/repodata.json'],
  ])('%s', async (_, path) => {
    const b = bucket(stored());
    const res = await get(b, path);
    expect(res.statusCode).toBe(404);
    expect(JSON.parse(res.body).error.code).toBe('not_in_index');
    expect(b.asked).toEqual([]);
  });

  test.each(['POST', 'PUT', 'DELETE', 'PATCH'])('%s of a good path is 404 without a read', async (method) => {
    const b = bucket(stored());
    expect((await get(b, good, method)).statusCode).toBe(404);
    expect(b.asked).toEqual([]);
  });

  test('names of 2 and 3 characters map to the padded directories', async () => {
    expect(keyOfPath('/index/ab/__/ab')?.key).toBe('index/ab/__/ab');
    expect(keyOfPath('/index/ab/c_/abc')?.key).toBe('index/ab/c_/abc');
    expect(keyOfPath('/index/ab/__/abc')).toBeUndefined();
    expect(keyOfPath('/index/ab/cd/abcd')?.key).toBe('index/ab/cd/abcd');
    expect(keyOfPath('/index/ab/cd/abcde')?.key).toBe('index/ab/cd/abcde');
  });

  test('the key read is the one derived from the name: a request cannot name another key', async () => {
    for (const name of NAMES) {
      const b = bucket(stored());
      await get(b, pathOf(name));
      expect(b.asked).toEqual([indexKey(name)]);
    }
  });
});

describe('what S3 answers', () => {
  const name = 'http_client';
  test('a key that is not there is 404', async () => {
    const res = await get(bucket({}), pathOf(name));
    expect(res.statusCode).toBe(404);
    expect(JSON.parse(res.body).error.code).toBe('not_in_index');
  });

  test('a well-formed name nobody published is 404', async () => {
    expect((await get(bucket(stored()), pathOf('no_such_package'))).statusCode).toBe(404);
  });

  test('takedowns.json missing is 404', async () => {
    expect((await get(bucket({}), '/index/takedowns.json')).statusCode).toBe(404);
  });

  test('S3 refusing a key that exists (403) is 502, not 404', async () => {
    const key = indexKey(name);
    const errors: string[] = [];
    const spy = jest.spyOn(console, 'error').mockImplementation((m) => void errors.push(String(m)));
    try {
      const res = await get(bucket(stored(), { [key]: new Error('s3 answered 403: AccessDenied') }), pathOf(name));
      expect(res.statusCode).toBe(502);
      expect(JSON.parse(res.body).error.code).toBe('index_unavailable');
      expect(errors.join('\n')).toContain('AccessDenied');
      expect(errors.join('\n')).toContain(key);
    } finally {
      spy.mockRestore();
    }
  });

  test.each(['s3 answered 500: InternalError', 's3 answered 503: SlowDown', 's3 answered 400: bad request', 'connect ETIMEDOUT', 'no AWS credentials in the environment'])(
    'any other failure (%s) is 502',
    async (message) => {
      const spy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
      try {
        for (const path of [pathOf(name), '/index/takedowns.json']) {
          const key = path.slice(1);
          const res = await get(bucket(stored(), { [key]: new Error(message) }), path);
          expect(res.statusCode).toBe(502);
          expect(res.body).not.toContain(message);
        }
      } finally {
        spy.mockRestore();
      }
    },
  );

  test('a failure that is not an Error is still 502', async () => {
    const spy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      const objects: IndexObjects = { get: () => Promise.reject('boom') };
      expect((await readIndex(objects, { method: 'GET', path: pathOf(name) }, 'r')).statusCode).toBe(502);
    } finally {
      spy.mockRestore();
    }
  });
});
