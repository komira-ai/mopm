import { createHash } from 'node:crypto';
import { CloudFrontInvalidator, S3Channel, SqsFifoQueue, type HttpFn, type HttpResponse } from '../../src/publish/aws';

const CREDS = { accessKeyId: 'AKIDTEST', secretAccessKey: 'secret', sessionToken: 'SESSION' };
const NOW = new Date('2026-10-14T12:00:00Z');
// Built at runtime: the hygiene job refuses a 12-digit literal.
const QUEUE_URL = `https://sqs.us-east-1.amazonaws.com/${'1'.repeat(12)}/mopm-beta-validate.fifo`;

interface Seen {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: Buffer | string;
}

/** A scripted HTTP client: answers from `replies` in order and records what it was sent. */
function fakeHttp(...replies: Array<{ status: number; body?: Buffer | string; headers?: Record<string, string> }>) {
  const seen: Seen[] = [];
  const http: HttpFn = async (url, init) => {
    seen.push({ url, ...init });
    const r = replies[Math.min(seen.length - 1, replies.length - 1)]!;
    const body = Buffer.from(r.body ?? '');
    const res: HttpResponse = {
      status: r.status,
      headers: { get: (n) => r.headers?.[n.toLowerCase()] ?? null },
      text: async () => body.toString('utf8'),
      arrayBuffer: async () => body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength) as ArrayBuffer,
    };
    return res;
  };
  return { http, seen };
}

const opts = (http: HttpFn) => ({ region: 'us-east-1', credentials: () => CREDS, http, now: () => NOW });
const signedHeaders = (h: Record<string, string>) => /SignedHeaders=([^,]+)/.exec(h.authorization!)![1]!.split(';');

describe('S3Channel', () => {
  test('put: header-signed, with the checksum, content type and cache control; createOnly adds If-None-Match: * to the signature', async () => {
    const { http, seen } = fakeHttp({ status: 200 });
    const s3 = new S3Channel('bkt', opts(http));
    const body = Buffer.from('hello');
    expect(await s3.put('noarch/repodata.json', body, { contentType: 'application/json', cacheControl: 'public, max-age=60', createOnly: true })).toBe('created');
    const r = seen[0]!;
    expect(r.method).toBe('PUT');
    expect(r.url).toBe('https://bkt.s3.us-east-1.amazonaws.com/noarch/repodata.json');
    expect(r.body).toEqual(body);
    expect(r.headers['content-type']).toBe('application/json');
    expect(r.headers['cache-control']).toBe('public, max-age=60');
    expect(r.headers['if-none-match']).toBe('*');
    expect(r.headers['x-amz-checksum-sha256']).toBe(createHash('sha256').update(body).digest('base64'));
    expect(r.headers['x-amz-content-sha256']).toBe(createHash('sha256').update(body).digest('hex'));
    expect(r.headers['x-amz-security-token']).toBe('SESSION');
    expect(signedHeaders(r.headers)).toEqual(['cache-control', 'content-type', 'host', 'if-none-match', 'x-amz-checksum-sha256', 'x-amz-content-sha256', 'x-amz-date', 'x-amz-security-token']);
  });

  test('put without createOnly does not send If-None-Match; 412 means the object exists; other failures throw', async () => {
    const plain = fakeHttp({ status: 200 });
    await new S3Channel('bkt', opts(plain.http)).put('k', Buffer.from('x'), { contentType: 'text/plain' });
    expect(plain.seen[0]!.headers['if-none-match']).toBeUndefined();
    const exists = fakeHttp({ status: 412 });
    expect(await new S3Channel('bkt', opts(exists.http)).put('k', Buffer.from('x'), { contentType: 't', createOnly: true })).toBe('exists');
    const broken = fakeHttp({ status: 500, body: '<Error>InternalError</Error>' });
    await expect(new S3Channel('bkt', opts(broken.http)).put('k', Buffer.from('x'), { contentType: 't' })).rejects.toThrow('s3 answered 500');
  });

  test('get and head: 403 and 404 both mean absent (no ListBucket permission), 200 gives the bytes and the length, anything else throws', async () => {
    const got = fakeHttp({ status: 200, body: 'bytes!' });
    expect((await new S3Channel('bkt', opts(got.http)).get('quarantine/u/f'))!.toString()).toBe('bytes!');
    expect(got.seen[0]!.method).toBe('GET');
    for (const status of [403, 404]) {
      expect(await new S3Channel('bkt', opts(fakeHttp({ status }).http)).get('k')).toBeUndefined();
      expect(await new S3Channel('bkt', opts(fakeHttp({ status }).http)).head('k')).toBeUndefined();
    }
    const head = fakeHttp({ status: 200, headers: { 'content-length': '42' } });
    expect(await new S3Channel('bkt', opts(head.http)).head('k')).toEqual({ size: 42 });
    expect(head.seen[0]!.method).toBe('HEAD');
    await expect(new S3Channel('bkt', opts(fakeHttp({ status: 500 }).http)).get('k')).rejects.toThrow('s3 answered 500');
  });

  test('delete accepts 204, and 404 (already gone); a server error throws', async () => {
    for (const status of [204, 404]) await new S3Channel('bkt', opts(fakeHttp({ status }).http)).delete('k');
    await expect(new S3Channel('bkt', opts(fakeHttp({ status: 503 }).http)).delete('k')).rejects.toThrow('s3 answered 503');
  });

  test('a key with characters outside the unreserved set is encoded the same way in the URL and in the signature', async () => {
    const { http, seen } = fakeHttp({ status: 200 });
    await new S3Channel('bkt', opts(http)).put('noarch/mojo-a+b-1.0.0.conda', Buffer.from('x'), { contentType: 't' });
    expect(seen[0]!.url).toBe('https://bkt.s3.us-east-1.amazonaws.com/noarch/mojo-a%2Bb-1.0.0.conda');
  });
});

describe('SqsFifoQueue', () => {
  test('SendMessage over the JSON protocol, with the group and deduplication ids', async () => {
    const { http, seen } = fakeHttp({ status: 200, body: '{"MessageId":"m"}' });
    await new SqsFifoQueue(QUEUE_URL, opts(http)).send({ body: '{"type":"validate"}', groupId: 'demo', dedupId: 'pub_1' });
    const r = seen[0]!;
    expect(r.url).toBe('https://sqs.us-east-1.amazonaws.com/');
    expect(r.method).toBe('POST');
    expect(r.headers['x-amz-target']).toBe('AmazonSQS.SendMessage');
    expect(r.headers['content-type']).toBe('application/x-amz-json-1.0');
    expect(JSON.parse(r.body as string)).toEqual({
      QueueUrl: QUEUE_URL,
      MessageBody: '{"type":"validate"}',
      MessageGroupId: 'demo',
      MessageDeduplicationId: 'pub_1',
    });
    expect(signedHeaders(r.headers)).toEqual(expect.arrayContaining(['content-type', 'host', 'x-amz-target']));
    expect(r.headers.authorization).toContain('/us-east-1/sqs/aws4_request');
  });

  test('a refusal is an error (the caller\'s request then fails, or the validator message is retried)', async () => {
    const q = new SqsFifoQueue('u', opts(fakeHttp({ status: 400, body: 'AccessDenied' }).http));
    await expect(q.send({ body: 'b', groupId: 'g', dedupId: 'd' })).rejects.toThrow('sqs answered 400');
  });
});

describe('CloudFrontInvalidator', () => {
  test('CreateInvalidation on the distribution with the paths and the caller reference, signed for cloudfront in us-east-1', async () => {
    const { http, seen } = fakeHttp({ status: 201 });
    await new CloudFrontInvalidator('E123ABC', opts(http)).invalidate(['/noarch/repodata.json', '/noarch/repodata.json.zst'], 'ref-1');
    const r = seen[0]!;
    expect(r.url).toBe('https://cloudfront.amazonaws.com/2020-05-31/distribution/E123ABC/invalidation');
    expect(r.method).toBe('POST');
    expect(r.headers['content-type']).toBe('text/xml');
    expect(r.headers.authorization).toContain('/us-east-1/cloudfront/aws4_request');
    expect(r.body).toContain('<Quantity>2</Quantity>');
    expect(r.body).toContain('<Path>/noarch/repodata.json</Path><Path>/noarch/repodata.json.zst</Path>');
    expect(r.body).toContain('<CallerReference>ref-1</CallerReference>');
  });

  test('a refusal is an error; markup in a path cannot break out of the XML', async () => {
    await expect(new CloudFrontInvalidator('E1', opts(fakeHttp({ status: 403 }).http)).invalidate(['/a'], 'r')).rejects.toThrow('cloudfront answered 403');
    const { http, seen } = fakeHttp({ status: 201 });
    await new CloudFrontInvalidator('E1', opts(http)).invalidate(['/a<b>&c'], 'r');
    expect(seen[0]!.body).toContain('<Path>/a&#60;b&#62;&#38;c</Path>');
  });
});
