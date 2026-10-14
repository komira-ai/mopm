import { createHash, createHmac } from 'node:crypto';
import { S3Presigner } from '../../src/publish/aws';
import { amzDate, credentialsFromEnv, presignUrl, signRequest, uriEncode } from '../../src/publish/sigv4';

// Known-answer tests. The expected values are AWS's published examples, not outputs of this code:
//  - S3 "Authenticating Requests: Using Query Parameters" (GET /test.txt on examplebucket)
//  - the SigV4 test suite case "get-vanilla"
const DOC_CREDS = { accessKeyId: 'AKIAIOSFODNN7EXAMPLE', secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY' };
const SUITE_CREDS = { accessKeyId: 'AKIDEXAMPLE', secretAccessKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY' };

describe('SigV4 known answers', () => {
  test('S3 presigned GET from the AWS documentation', () => {
    const url = presignUrl({
      method: 'GET',
      host: 'examplebucket.s3.amazonaws.com',
      path: '/test.txt',
      region: 'us-east-1',
      service: 's3',
      creds: DOC_CREDS,
      now: new Date('2013-05-24T00:00:00Z'),
      expiresSeconds: 86400,
    });
    expect(url).toBe(
      'https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256' +
        '&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request' +
        '&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host' +
        '&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404',
    );
  });

  test('header-signed GET: the SigV4 test suite case get-vanilla', () => {
    const h = signRequest({
      method: 'GET',
      host: 'example.amazonaws.com',
      path: '/',
      region: 'us-east-1',
      service: 'service',
      creds: SUITE_CREDS,
      now: new Date('2015-08-30T12:36:00Z'),
    });
    expect(h.authorization).toBe(
      'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, ' +
        'Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31',
    );
    expect(h['x-amz-date']).toBe('20150830T123600Z');
    expect(h.host).toBeUndefined(); // the HTTP client sets Host; it is signed but not sent
  });

  test('a signature changes with every input it covers', () => {
    const base = { method: 'GET', host: 'h.example', path: '/a', region: 'us-east-1', service: 's3', creds: DOC_CREDS, now: new Date('2026-10-14T12:00:00Z'), body: 'x' };
    const sig = (over: Record<string, unknown>) => signRequest({ ...base, ...over } as Parameters<typeof signRequest>[0]).authorization;
    const ref = sig({});
    expect(sig({})).toBe(ref);
    for (const over of [{ method: 'PUT' }, { host: 'g.example' }, { path: '/b' }, { region: 'eu-west-1' }, { service: 'sqs' }, { now: new Date('2026-10-14T12:00:01Z') }, { body: 'y' }, { headers: { 'x-extra': '1' } }, { query: [['a', 'b']] }]) {
      expect(sig(over)).not.toBe(ref);
    }
  });

  test('the session token is sent and signed', () => {
    const h = signRequest({ method: 'POST', host: 'h.example', path: '/', region: 'us-east-1', service: 'sqs', creds: { ...DOC_CREDS, sessionToken: 'TOK' }, now: new Date('2026-10-14T12:00:00Z') });
    expect(h['x-amz-security-token']).toBe('TOK');
    expect(h.authorization).toContain('SignedHeaders=host;x-amz-date;x-amz-security-token');
  });

  test('uriEncode: unreserved characters stay, everything else is %XX in upper case, slash only when asked', () => {
    expect(uriEncode('AZaz09-_.~')).toBe('AZaz09-_.~');
    expect(uriEncode('a b/c+d=é')).toBe('a%20b%2Fc%2Bd%3D%C3%A9');
    expect(uriEncode('a/b', true)).toBe('a/b');
  });

  test('amzDate and credentials from the environment', () => {
    expect(amzDate(new Date('2013-05-24T00:00:00.123Z'))).toBe('20130524T000000Z');
    expect(credentialsFromEnv({ AWS_ACCESS_KEY_ID: 'a', AWS_SECRET_ACCESS_KEY: 'b', AWS_SESSION_TOKEN: 'c' })).toEqual({ accessKeyId: 'a', secretAccessKey: 'b', sessionToken: 'c' });
    expect(() => credentialsFromEnv({})).toThrow('no AWS credentials');
  });
});

/** A second, straight-line implementation of the query-string signature of a PUT, to check the presigner against. */
function verifyPresignedPut(url: string, creds: { accessKeyId: string; secretAccessKey: string }, headers: Record<string, string>): boolean {
  const u = new URL(url);
  const params = [...u.searchParams.entries()].filter(([k]) => k !== 'X-Amz-Signature');
  const given = u.searchParams.get('X-Amz-Signature')!;
  const enc = (s: string) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
  const query = params
    .map(([k, v]) => `${enc(k)}=${enc(v)}`)
    .sort()
    .join('&');
  const signed = u.searchParams.get('X-Amz-SignedHeaders')!.split(';');
  const all: Record<string, string> = { host: u.host, ...headers };
  const canonical = ['PUT', u.pathname, query, signed.map((n) => `${n}:${all[n]}\n`).join(''), signed.join(';'), 'UNSIGNED-PAYLOAD'].join('\n');
  const stamp = u.searchParams.get('X-Amz-Date')!;
  const scope = `${stamp.slice(0, 8)}/us-east-1/s3/aws4_request`;
  const sts = ['AWS4-HMAC-SHA256', stamp, scope, createHash('sha256').update(canonical).digest('hex')].join('\n');
  let key: Buffer | string = `AWS4${creds.secretAccessKey}`;
  for (const part of [stamp.slice(0, 8), 'us-east-1', 's3', 'aws4_request']) key = createHmac('sha256', key).update(part).digest();
  return createHmac('sha256', key).update(sts).digest('hex') === given;
}

describe('the presigned upload URL', () => {
  const creds = { accessKeyId: 'AKIDTEST', secretAccessKey: 'secret/key+material' };
  const presigner = new S3Presigner('mopm-beta-channel-bucket', { region: 'us-east-1', credentials: () => creds });
  const now = new Date('2026-10-14T12:00:00Z');
  const sha = 'ab'.repeat(32);
  const put = (over: Partial<{ size: number; sha256: string; key: string }> = {}) =>
    presigner.presignPut(over.key ?? 'quarantine/upl_1/mojo-demo-1.0.0-mojo1.0.0_0.conda', { size: over.size ?? 1234, sha256: over.sha256 ?? sha, expiresInSeconds: 300, now });

  test('pins the exact length and the sha256 in the signature, on the quarantine key, for five minutes', () => {
    const p = put();
    const u = new URL(p.url);
    expect(u.host).toBe('mopm-beta-channel-bucket.s3.us-east-1.amazonaws.com');
    expect(u.pathname).toBe('/quarantine/upl_1/mojo-demo-1.0.0-mojo1.0.0_0.conda');
    expect(u.searchParams.get('X-Amz-Expires')).toBe('300');
    expect(u.searchParams.get('X-Amz-SignedHeaders')).toBe('content-length;host;x-amz-checksum-sha256');
    expect(p.headers).toEqual({ 'content-length': '1234', 'x-amz-checksum-sha256': Buffer.from(sha, 'hex').toString('base64') });
    expect(verifyPresignedPut(p.url, creds, p.headers)).toBe(true);
  });

  test('a signature made for other bytes does not verify for these: length, checksum and key are all bound', () => {
    const p = put();
    expect(verifyPresignedPut(p.url, creds, { ...p.headers, 'content-length': '1235' })).toBe(false);
    expect(verifyPresignedPut(p.url, creds, { ...p.headers, 'x-amz-checksum-sha256': Buffer.from('cd'.repeat(32), 'hex').toString('base64') })).toBe(false);
    expect(put({ size: 1235 }).url).not.toBe(p.url);
    expect(put({ sha256: 'cd'.repeat(32) }).url).not.toBe(p.url);
    expect(put({ key: 'quarantine/upl_2/x.conda' }).url).not.toBe(p.url);
    expect(verifyPresignedPut(put({ size: 1235 }).url, creds, p.headers)).toBe(false);
  });

  test('a session token is part of the URL (and the signature)', () => {
    const withToken = new S3Presigner('b', { region: 'us-east-1', credentials: () => ({ ...creds, sessionToken: 'SESSION' }) });
    const p = withToken.presignPut('quarantine/u/f.conda', { size: 5, sha256: sha, expiresInSeconds: 300, now });
    expect(new URL(p.url).searchParams.get('X-Amz-Security-Token')).toBe('SESSION');
  });
});
