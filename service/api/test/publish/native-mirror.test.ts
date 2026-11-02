import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { MemoryObjectStore } from '../../src/publish/memory';
import { MirrorReader } from '../../src/publish/native-mirror-reader';
import { fetchBytes as realFetch, namesOf, runNativeMirrorJob, shardNames, MIN_NAMES_PER_SUBDIR } from '../../src/publish/native-mirror-job';
import type { FetchBytes } from '../../src/publish/native-mirror-job';
import { decodeMirror, encodeMirror, MIRROR_KEY, MIRROR_MAX_AGE_MS } from '../../src/validate/native-mirror';
import type { NativeMirror } from '../../src/validate/native-mirror';
import { zstdFrame } from '../../src/zstd';
import { Harness, pkg } from './harness';

const NOW = new Date('2026-11-01T12:00:00Z');
const quiet = () => undefined;
const GZ = { contentType: 'application/gzip' };

describe('the reader of the mirror (one Lambda container)', () => {
  const store = async (at: Date, names = ['zstd']) => {
    const s = new MemoryObjectStore();
    await s.put(MIRROR_KEY, encodeMirror(names, at), GZ);
    return s;
  };

  test('reads the object once while it is fresh, and answers from memory after', async () => {
    const s = await store(new Date(NOW.getTime() - 3_600_000));
    let gets = 0;
    const get = s.get.bind(s);
    s.get = async (k: string) => (gets++, get(k));
    const r = new MirrorReader(s, { now: () => NOW, log: quiet });
    expect([...(await r.read())!.names]).toEqual(['zstd']);
    await r.read();
    await r.read();
    expect(gets).toBe(1);
  });

  test('a missing object answers undefined, and the next read tries again', async () => {
    const s = new MemoryObjectStore();
    const r = new MirrorReader(s, { now: () => NOW, log: quiet });
    expect(await r.read()).toBeUndefined();
    await s.put(MIRROR_KEY, encodeMirror(['zstd'], NOW), GZ);
    expect([...(await r.read())!.names]).toEqual(['zstd']);
  });

  test('an unreadable object, a store that throws and a store that never answers each answer undefined', async () => {
    const garbage = new MemoryObjectStore();
    await garbage.put(MIRROR_KEY, Buffer.from('garbage'), GZ);
    expect(await new MirrorReader(garbage, { now: () => NOW, log: quiet }).read()).toBeUndefined();
    const throws = { get: async (): Promise<Buffer | undefined> => { throw new Error('boom'); } };
    expect(await new MirrorReader(throws, { now: () => NOW, log: quiet }).read()).toBeUndefined();
    const never = { get: (): Promise<Buffer | undefined> => new Promise(() => undefined) };
    expect(await new MirrorReader(never, { now: () => NOW, timeoutMs: 5, log: quiet }).read()).toBeUndefined();
  });

  test('a copy that has gone stale is read again; when the object cannot be read then, the old copy is what the validator gets', async () => {
    const s = await store(new Date(NOW.getTime() - 1000));
    let clock = NOW;
    const r = new MirrorReader(s, { now: () => clock, log: quiet });
    expect(await r.read()).toBeDefined();
    await s.put(MIRROR_KEY, encodeMirror(['zstd', 'newer'], new Date(NOW.getTime() + MIRROR_MAX_AGE_MS)), GZ);
    clock = new Date(NOW.getTime() + MIRROR_MAX_AGE_MS + 5000);
    expect([...(await r.read())!.names].sort()).toEqual(['newer', 'zstd']);
    await s.put(MIRROR_KEY, Buffer.from('garbage'), GZ);
    clock = new Date(clock.getTime() + 2 * MIRROR_MAX_AGE_MS);
    expect([...(await r.read())!.names].sort()).toEqual(['newer', 'zstd']);
  });
});

// --- the job ---------------------------------------------------------------------------------------------------------

/** MessagePack as conda-forge's shard index writes it: {info: {subdir}, shards: {name: 32-byte hash}, version: 1}. */
function shardIndex(names: string[], opts: { bigMap?: boolean } = {}): Buffer {
  const str = (s: string) => {
    const b = Buffer.from(s);
    return Buffer.concat([b.length < 32 ? Buffer.from([0xa0 | b.length]) : Buffer.from([0xd9, b.length]), b]);
  };
  const bin = Buffer.concat([Buffer.from([0xc4, 32]), Buffer.alloc(32, 7)]);
  const header = (n: number) => (opts.bigMap || n > 15 ? Buffer.from([0xde, n >> 8, n & 0xff]) : Buffer.from([0x80 | n]));
  const shards = Buffer.concat([str('shards'), header(names.length), ...names.flatMap((n) => [str(n), bin])]);
  const info = Buffer.concat([str('info'), Buffer.from([0x82]), str('subdir'), str('linux-64'), str('base_url'), str('')]);
  const ver = Buffer.concat([str('version'), Buffer.from([0x01])]);
  return Buffer.concat([Buffer.from([0x83]), info, shards, ver]);
}
const names = (prefix: string, n: number) => Array.from({ length: n }, (_, i) => `${prefix}${i}`);
const served = (bySubdir: Record<string, string[]>): FetchBytes => async (url) => {
  const m = /conda-forge\/([^/]+)\/repodata_shards\.msgpack\.zst$/.exec(url);
  const list = m && bySubdir[m[1]!];
  if (!list) throw new Error(`${url} answered 404`);
  return zstdFrame(shardIndex(list, { bigMap: true }));
};
const FULL = { 'linux-64': ['zstd', ...names('a', 1200)], 'linux-aarch64': ['zstd', ...names('b', 1200)], 'osx-arm64': ['lz4-c', ...names('c', 1200)], noarch: ['pip', ...names('d', 1200)] };

describe('reading a shard index', () => {
  test('the names are the keys of the shards map, whatever the info map before them holds', () => {
    expect(shardNames(shardIndex(['zstd', 'lz4-c']))).toEqual(['zstd', 'lz4-c']);
  });

  test('a map of more than 15 entries (map16) and a name of 32 bytes or more (str8) read the same way', () => {
    const many = [...names('p', 40), `long-${'x'.repeat(40)}`];
    expect(shardNames(shardIndex(many))).toEqual(many);
  });

  test('an index with no shards, a cut index and one that is not a map are errors', () => {
    expect(() => shardNames(Buffer.from([0x81, 0xa1, 0x61, 0x01]))).toThrow("no 'shards'");
    expect(() => shardNames(shardIndex(['zstd', 'lz4-c']).subarray(0, 60))).toThrow('cut short');
    expect(() => shardNames(Buffer.from([0x01]))).toThrow('not a MessagePack map');
  });
});

describe('the mirror job', () => {
  test('writes one object holding the union of the four subdirs and the time of the run', async () => {
    const objects = new MemoryObjectStore();
    const r = await runNativeMirrorJob({ objects, fetchBytes: served(FULL), now: () => NOW, log: quiet });
    expect(r.names).toBe(3 + 4 * 1200); // zstd is listed by two subdirs; lz4-c, pip and zstd are the three named ones
    const o = objects.objects.get(MIRROR_KEY)!;
    expect(o.cacheControl).toBe('no-cache');
    const m = decodeMirror(o.body);
    expect(m.generatedAt.toISOString()).toBe(NOW.toISOString());
    for (const n of ['zstd', 'lz4-c', 'pip', 'a0', 'b0', 'c0', 'd1199']) expect(m.names.has(n)).toBe(true);
    expect(objects.log).toEqual([`put ${MIRROR_KEY}`]);
  });

  test('is read back by the reader the validators use, and it is gzip', async () => {
    const objects = new MemoryObjectStore();
    await runNativeMirrorJob({ objects, fetchBytes: served(FULL), now: () => NOW, log: quiet });
    expect([...objects.objects.get(MIRROR_KEY)!.body.subarray(0, 2)]).toEqual([0x1f, 0x8b]);
    expect((await new MirrorReader(objects, { now: () => NOW, log: quiet }).read())!.names.has('pip')).toBe(true);
  });

  test('a subdir that cannot be read fails the job and writes nothing, so the old object stays', async () => {
    const objects = new MemoryObjectStore();
    await objects.put(MIRROR_KEY, encodeMirror(['old'], new Date('2026-10-30T00:00:00Z')), GZ);
    const three: Record<string, string[]> = { ...FULL };
    delete three.noarch;
    await expect(runNativeMirrorJob({ objects, fetchBytes: served(three), now: () => NOW, log: quiet })).rejects.toThrow('noarch');
    expect(objects.log).toEqual([`put ${MIRROR_KEY}`]); // the seeding put only
    expect([...decodeMirror(objects.objects.get(MIRROR_KEY)!.body).names]).toEqual(['old']);
  });

  test('a subdir that lists too few names fails the job: a parse that lost its names must not replace a good list', async () => {
    const objects = new MemoryObjectStore();
    const few = { ...FULL, noarch: names('d', MIN_NAMES_PER_SUBDIR - 1) };
    await expect(runNativeMirrorJob({ objects, fetchBytes: served(few), now: () => NOW, log: quiet })).rejects.toThrow('noarch');
    expect(objects.objects.size).toBe(0);
  });

  test('a body that is not zstd fails the job, and a name that is not a conda name is left out', async () => {
    const objects = new MemoryObjectStore();
    const notZstd: FetchBytes = async () => Buffer.from('<html>');
    await expect(runNativeMirrorJob({ objects, fetchBytes: notZstd, now: () => NOW, log: quiet })).rejects.toThrow();
    expect(objects.objects.size).toBe(0);
    const odd = { ...FULL, 'linux-64': ['Not A Name', ...names('a', 1200)] };
    await runNativeMirrorJob({ objects, fetchBytes: served(odd), now: () => NOW, log: quiet });
    expect(decodeMirror(objects.objects.get(MIRROR_KEY)!.body).names.has('Not A Name')).toBe(false);
  });

  test('the default fetch refuses a status other than 200', async () => {
    const real = globalThis.fetch;
    globalThis.fetch = (async () => new Response('x', { status: 503 })) as typeof fetch;
    try {
      await expect(realFetch('https://example.invalid/x')).rejects.toThrow('503');
      await expect(namesOf(realFetch, 'linux-64')).rejects.toThrow('503');
    } finally {
      globalThis.fetch = real;
    }
  });
});

// --- the publish: warnings reach the publisher in the status -----------------------------------------------------------

async function publishWith(depends: string[], mirror: () => Promise<NativeMirror | undefined>) {
  const h = new Harness();
  h.validatorDeps.nativeMirror = mirror;
  const me = await h.account(1, 'a', ['demo']);
  const p = pkg({ name: 'demo', index: { depends: ['mojo-compiler ==1.0.0', ...depends] } });
  const u = await h.upload(me.token, p);
  const res = await h.commit(me.token, p.name, p.version, [u.upload_id!], p.manifest, {});
  expect(res.statusCode).toBe(202);
  await h.runValidator();
  return { h, me, id: JSON.parse(res.body).publish_id as string };
}
/** Made an hour before the harness's clock (test/auth-helpers.ts), so it is fresh to the validator. */
const mirror = (list: string[]) => async () => decodeMirror(encodeMirror(list, new Date('2026-10-14T11:00:00Z')));

describe('the status of a publish', () => {
  test('carries the warnings of the validator: an unknown native name is published and named', async () => {
    const { h, me, id } = await publishWith(['libpgn >=1', 'zstd'], mirror(['zstd']));
    const s = await h.status(me.token, id);
    expect(s.body.warnings).toHaveLength(1);
    expect(s.body.warnings[0]).toContain("'libpgn'");
    expect((await h.registry.getVersion('demo', '1.0.0'))!.state).toBe('published');
  });

  test('has no warnings member when there is nothing to say', async () => {
    const { h, me, id } = await publishWith(['zstd'], mirror(['zstd']));
    const s = await h.status(me.token, id);
    expect('warnings' in s.body).toBe(false);
    expect((await h.registry.getVersion('demo', '1.0.0'))!.state).toBe('published');
  });

  test('a mirror that cannot be read, or a reader that throws, is a warning and not a failure', async () => {
    for (const m of [async () => undefined, async (): Promise<NativeMirror> => { throw new Error('s3 down'); }]) {
      const { h, me, id } = await publishWith(['zstd'], m);
      const s = await h.status(me.token, id);
      expect(s.body.warnings).toHaveLength(1);
      expect(s.body.warnings[0]).toContain('could not be read');
      expect((await h.registry.getVersion('demo', '1.0.0'))!.state).toBe('published');
    }
  });

  test('a malformed name is a rejection, with the code the contract lists, and no warnings', async () => {
    const { h, me, id } = await publishWith(['LZ4-C'], mirror(['zstd']));
    const s = await h.status(me.token, id);
    expect(s.body).toMatchObject({ status: 'rejected', rejection_code: 'dependency_not_allowed' });
    expect('warnings' in s.body).toBe(false);
  });
});

// --- every MessagePack type the index may hold before or between its names ---------------------------------------------------

const b = (...n: number[]) => Buffer.from(n);
const u = (n: number, width: number) => { const x = Buffer.alloc(width); x.writeUIntBE(n, 0, width); return x; };
const cat = (...p: Buffer[]) => Buffer.concat(p);
const mstr = (t: string) => cat(b(0xa0 | t.length), Buffer.from(t));
/** An index whose `info` map holds `value` and whose shards map holds one name, in front of which the value is skipped. */
const withInfo = (value: Buffer, names = ['zstd']) =>
  cat(b(0x82), mstr('info'), value, mstr('shards'), b(0x80 | names.length), ...names.flatMap((n) => [mstr(n), b(0xc0)]));

describe('skipping the values of a shard index', () => {
  const skippable: Array<[string, Buffer]> = [
    ['nil', b(0xc0)], ['false', b(0xc2)], ['true', b(0xc3)], ['a positive fixint', b(0x05)], ['a negative fixint', b(0xe1)],
    ['uint8', b(0xcc, 1)], ['uint16', cat(b(0xcd), u(1, 2))], ['uint32', cat(b(0xce), u(1, 4))], ['uint64', cat(b(0xcf), u(1, 6), b(0, 0))],
    ['int8', b(0xd0, 1)], ['int16', cat(b(0xd1), u(1, 2))], ['int32', cat(b(0xd2), u(1, 4))], ['int64', cat(b(0xd3), u(1, 6), b(0, 0))],
    ['float32', cat(b(0xca), u(1, 4))], ['float64', cat(b(0xcb), u(1, 6), b(0, 0))],
    ['a fixstr', mstr('abc')], ['str8', cat(b(0xd9, 3), Buffer.from('abc'))], ['str16', cat(b(0xda), u(3, 2), Buffer.from('abc'))], ['str32', cat(b(0xdb), u(3, 4), Buffer.from('abc'))],
    ['bin8', cat(b(0xc4, 2), b(1, 2))], ['bin16', cat(b(0xc5), u(2, 2), b(1, 2))], ['bin32', cat(b(0xc6), u(2, 4), b(1, 2))],
    ['a fixarray', cat(b(0x92, 1), b(0xc0))], ['array16', cat(b(0xdc), u(2, 2), b(1, 2))], ['array32', cat(b(0xdd), u(2, 4), b(1, 2))],
    ['a fixmap', cat(b(0x81), mstr('k'), b(1))], ['map16', cat(b(0xde), u(1, 2), mstr('k'), b(1))], ['map32', cat(b(0xdf), u(1, 4), mstr('k'), b(1))],
  ];
  test.each(skippable)('%s in info is stepped over, and the names after it are read', (_t, value) => {
    expect(shardNames(withInfo(value))).toEqual(['zstd']);
  });

  test('a name in str16 and in str32 form, and a shards map in map32 form, are read', () => {
    const idx = cat(b(0x81), mstr('shards'), b(0xdf), u(2, 4), cat(b(0xda), u(4, 2), Buffer.from('zstd')), b(0xc0), cat(b(0xdb), u(5, 4), Buffer.from('lz4-c')), b(0xc0));
    expect(shardNames(idx)).toEqual(['zstd', 'lz4-c']);
  });

  test('an extension type, nesting past 16 levels, a non-string key and a non-string or non-map shards are errors', () => {
    expect(() => shardNames(withInfo(b(0xd4, 1, 0)))).toThrow('MessagePack type');
    expect(() => shardNames(withInfo(cat(...Array.from({ length: 20 }, () => b(0x91)), b(0xc0))))).toThrow('nests too deeply');
    expect(() => shardNames(cat(b(0x81), b(0x01), b(0x01)))).toThrow('key that is not a string');
    expect(() => shardNames(cat(b(0x81), mstr('shards'), b(0x01)))).toThrow("'shards' is not a map");
    expect(() => shardNames(cat(b(0x81), mstr('shards'), b(0x81), b(0x01), b(0xc0)))).toThrow('name that is not a string');
  });
});

describe('the scheduled function', () => {
  test('reads the four shard indexes from conda-forge, and puts one object into the channel bucket with the signed request of the role', async () => {
    const real = globalThis.fetch;
    const keys = ['MOPM_CHANNEL_BUCKET', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_REGION'];
    const before = keys.map((k) => process.env[k]);
    const calls: Array<{ url: string; method: string }> = [];
    let put: Buffer | undefined;
    process.env.MOPM_CHANNEL_BUCKET = 'bkt';
    process.env.AWS_ACCESS_KEY_ID = 'AKIDEXAMPLE';
    process.env.AWS_SECRET_ACCESS_KEY = 'example-secret';
    process.env.AWS_REGION = 'us-east-1';
    globalThis.fetch = (async (url: string, init?: { method?: string; body?: Buffer }) => {
      calls.push({ url: String(url), method: init?.method ?? 'GET' });
      if (String(url).startsWith('https://conda.anaconda.org/conda-forge/')) {
        const sub = /conda-forge\/([^/]+)\//.exec(String(url))![1]!;
        const body = zstdFrame(shardIndex(FULL[sub as keyof typeof FULL]!, { bigMap: true }));
        return new Response(body, { status: 200, headers: { 'content-length': String(body.length) } });
      }
      put = Buffer.from(init!.body!);
      return new Response('', { status: 200 });
    }) as unknown as typeof fetch;
    try {
      const { handler } = await import('../../src/publish/native-mirror-lambda');
      await handler();
    } finally {
      globalThis.fetch = real;
      keys.forEach((k, i) => (before[i] === undefined ? delete process.env[k] : (process.env[k] = before[i])));
    }
    expect(calls.filter((c) => c.url.startsWith('https://conda.anaconda.org/')).map((c) => c.url.split('/').slice(-2).join('/')).sort()).toEqual([
      'linux-64/repodata_shards.msgpack.zst', 'linux-aarch64/repodata_shards.msgpack.zst', 'noarch/repodata_shards.msgpack.zst', 'osx-arm64/repodata_shards.msgpack.zst',
    ]);
    const writes = calls.filter((c) => c.method === 'PUT');
    expect(writes.map((c) => c.url)).toEqual([`https://bkt.s3.us-east-1.amazonaws.com/${MIRROR_KEY}`]);
    expect(decodeMirror(put!).names.has('pip')).toBe(true);
  });

  test('the default fetch refuses an answer that says it is larger than the limit', async () => {
    const real = globalThis.fetch;
    globalThis.fetch = (async () => new Response('x', { status: 200, headers: { 'content-length': String(64 * 1024 * 1024) } })) as unknown as typeof fetch;
    try {
      await expect(realFetch('https://example.invalid/x')).rejects.toThrow('the limit is');
    } finally {
      globalThis.fetch = real;
    }
  });

  test('the default fetch returns the body of a 200', async () => {
    const real = globalThis.fetch;
    globalThis.fetch = (async () => new Response('abc', { status: 200 })) as unknown as typeof fetch;
    try {
      expect((await realFetch('https://example.invalid/x')).toString()).toBe('abc');
    } finally {
      globalThis.fetch = real;
    }
  });
});

describe('the deployed functions', () => {
  test('both validators read the mirror through one reader of their channel bucket, and neither keeps a list of names', () => {
    for (const f of ['validator-lambda.ts', 'group-validator-lambda.ts']) {
      const src = readFileSync(join(__dirname, '../../src/publish', f), 'utf8');
      expect(src).toContain('new MirrorReader(objects)');
      expect(src).toContain('nativeMirror: () => mirror.read()');
      expect(src).not.toContain('validatorOptions');
    }
  });
});
