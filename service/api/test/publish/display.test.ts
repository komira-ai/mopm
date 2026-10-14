import { README_MAX_BYTES } from '../../src/types';
import { Harness, pkg } from './harness';

const err = (r: { body: string }) => JSON.parse(r.body).error as { code: string; message: string };

async function commitWith(extra: Record<string, unknown>) {
  const h = new Harness();
  const me = await h.account(1, 'a', ['demo']);
  const p = pkg({ name: 'demo', version: '1.0.0' });
  const u = await h.upload(me.token, p);
  const res = await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], p.manifest, extra);
  return { h, me, p, res };
}

describe('display metadata on the commit request', () => {
  const full = {
    description: 'HTTP/1.1 client',
    license: 'MIT OR Apache-2.0',
    repository: 'https://github.com/example/demo',
    homepage: 'http://example.com/demo',
    keywords: ['http', 'client', 'a+b.c_d-e'],
    readme: '# demo\n\nHello, é.\n',
  };

  test('is stored on the version when it is published, and the read API serves it', async () => {
    const { h, me, p, res } = await commitWith(full);
    expect(res.statusCode).toBe(202);
    await h.runValidator();
    await h.runIndexer();
    expect((await h.status(me.token, JSON.parse(res.body).publish_id)).body.status).toBe('published');
    expect(await h.registry.getVersion('demo', '1.0.0')).toMatchObject({ state: 'published', ...full });
    const served = JSON.parse((await h.call('GET', `/api/v1/packages/demo/${p.version}`)).body);
    expect(served).toMatchObject(full);
    // The package page carries the readme of the latest version.
    expect(JSON.parse((await h.call('GET', '/api/v1/packages/demo')).body)).toMatchObject({ readme: full.readme });
  });

  test('a commit without any of the fields (an older client) publishes a version without them', async () => {
    const { h, res } = await commitWith({});
    expect(res.statusCode).toBe(202);
    await h.runValidator();
    const v = (await h.registry.getVersion('demo', '1.0.0'))!;
    expect(v.state).toBe('published');
    for (const k of ['description', 'license', 'repository', 'homepage', 'keywords', 'readme']) expect(v).not.toHaveProperty(k);
  });

  test('the readme cap is 65536 BYTES of UTF-8: 65536 ASCII bytes fit, one more does not', async () => {
    expect((await commitWith({ readme: 'x'.repeat(README_MAX_BYTES) })).res.statusCode).toBe(202);
    const over = (await commitWith({ readme: 'x'.repeat(README_MAX_BYTES + 1) })).res;
    expect(over.statusCode).toBe(400);
    expect(err(over)).toMatchObject({ code: 'invalid_request', message: expect.stringContaining('65536 bytes') });
  });

  test('the readme cap counts bytes, not characters: 32768 two-byte characters fit, 32769 are 65538 bytes and do not', async () => {
    expect((await commitWith({ readme: 'é'.repeat(README_MAX_BYTES / 2) })).res.statusCode).toBe(202);
    // 32769 characters is far below 65536 characters, so a character count would let it through.
    const over = (await commitWith({ readme: 'é'.repeat(README_MAX_BYTES / 2 + 1) })).res;
    expect(over.statusCode).toBe(400);
    expect(err(over).code).toBe('invalid_request');
  });

  test('the old 512 KiB readme is no longer accepted', async () => {
    expect((await commitWith({ readme: 'x'.repeat(100_000) })).res.statusCode).toBe(400);
  });

  test.each([
    ['an empty description', { description: '' }],
    ['a description over 512 characters', { description: 'x'.repeat(513) }],
    ['a description with a line break', { description: 'a\nb' }],
    ['a non-string description', { description: 3 }],
    ['a license over 128 characters', { license: 'x'.repeat(129) }],
    ['a repository that is not https', { repository: 'http://example.com/r' }],
    ['a repository that is not a URL', { repository: 'not a url' }],
    ['a repository over 2048 characters', { repository: `https://example.com/${'x'.repeat(2048)}` }],
    ['a homepage with another scheme', { homepage: 'ftp://example.com' }],
    ['more than 10 keywords', { keywords: Array.from({ length: 11 }, (_, i) => `k${i}`) }],
    ['a repeated keyword', { keywords: ['a', 'a'] }],
    ['an empty keyword', { keywords: [''] }],
    ['a keyword over 32 characters', { keywords: ['x'.repeat(33)] }],
    ['a keyword with a space', { keywords: ['a b'] }],
    ['keywords that are not an array', { keywords: 'a' }],
    ['a null readme', { readme: null }],
  ])('refused with invalid_request: %s', async (_n, extra) => {
    const { res } = await commitWith(extra);
    expect([res.statusCode, err(res).code]).toEqual([400, 'invalid_request']);
  });

  test('a refused commit uses nothing: the same uploads can be committed again with valid fields', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const u = await h.upload(me.token, p);
    expect((await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], p.manifest, { license: 'x'.repeat(200) })).statusCode).toBe(400);
    expect((await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], p.manifest, { license: 'MIT' })).statusCode).toBe(202);
  });
});
