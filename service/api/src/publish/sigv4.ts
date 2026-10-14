import { createHash, createHmac } from 'node:crypto';

/**
 * AWS Signature Version 4, just enough for the publish pipeline: a presigned S3 PUT URL and header-signed
 * requests to S3, SQS and CloudFront. It is written against node:crypto so the Lambda bundle needs no
 * dependency that is not in the Node.js runtime. Known-answer tests (AWS's published examples) pin it.
 *
 * Scope: paths are URI-encoded once, which is S3's rule and is also right for the other paths used here
 * (`/` and a CloudFront path of unreserved characters).
 */
export interface AwsCredentials {
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken?: string;
}

/** The Lambda runtime provides credentials in the environment. */
export function credentialsFromEnv(env: Record<string, string | undefined> = process.env): AwsCredentials {
  const accessKeyId = env.AWS_ACCESS_KEY_ID;
  const secretAccessKey = env.AWS_SECRET_ACCESS_KEY;
  if (!accessKeyId || !secretAccessKey) throw new Error('no AWS credentials in the environment');
  return { accessKeyId, secretAccessKey, ...(env.AWS_SESSION_TOKEN ? { sessionToken: env.AWS_SESSION_TOKEN } : {}) };
}

const sha256Hex = (b: Buffer | string) => createHash('sha256').update(b).digest('hex');
const hmac = (key: Buffer | string, data: string) => createHmac('sha256', key).update(data).digest();

/** RFC 3986 percent-encoding as SigV4 defines it: only A-Z a-z 0-9 - _ . ~ stay; `/` stays when asked. */
export function uriEncode(s: string, keepSlash = false): string {
  let out = '';
  for (const byte of Buffer.from(s, 'utf8')) {
    const c = String.fromCharCode(byte);
    if (/[A-Za-z0-9\-_.~]/.test(c) || (keepSlash && c === '/')) out += c;
    else out += `%${byte.toString(16).toUpperCase().padStart(2, '0')}`;
  }
  return out;
}

/** `20130524T000000Z` */
export const amzDate = (d: Date) => d.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');

function signingKey(secret: string, date8: string, region: string, service: string): Buffer {
  return hmac(hmac(hmac(hmac(`AWS4${secret}`, date8), region), service), 'aws4_request');
}

type Query = ReadonlyArray<readonly [string, string]>;

function canonicalQuery(query: Query): string {
  return query
    .map(([k, v]) => [uriEncode(k), uriEncode(v)] as const)
    .sort((a, b) => (a[0] === b[0] ? (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0) : a[0] < b[0] ? -1 : 1))
    .map(([k, v]) => `${k}=${v}`)
    .join('&');
}

function canonical(method: string, path: string, query: Query, headers: Record<string, string>, payloadHash: string) {
  const names = Object.keys(headers).map((n) => n.toLowerCase()).sort();
  const lower: Record<string, string> = {};
  for (const [k, v] of Object.entries(headers)) lower[k.toLowerCase()] = v.trim().replace(/\s+/g, ' ');
  const signedHeaders = names.join(';');
  const text = [
    method,
    uriEncode(path, true),
    canonicalQuery(query),
    names.map((n) => `${n}:${lower[n]}\n`).join(''),
    signedHeaders,
    payloadHash,
  ].join('\n');
  return { text, signedHeaders };
}

function signature(creds: AwsCredentials, now: Date, region: string, service: string, canonicalText: string): string {
  const stamp = amzDate(now);
  const date8 = stamp.slice(0, 8);
  const scope = `${date8}/${region}/${service}/aws4_request`;
  const sts = ['AWS4-HMAC-SHA256', stamp, scope, sha256Hex(canonicalText)].join('\n');
  return createHmac('sha256', signingKey(creds.secretAccessKey, date8, region, service)).update(sts).digest('hex');
}

export interface PresignInput {
  method: string;
  host: string;
  path: string;
  region: string;
  service: string;
  creds: AwsCredentials;
  now: Date;
  expiresSeconds: number;
  /** Headers besides `host` the caller must send exactly as signed (e.g. content-length, x-amz-checksum-sha256). */
  signedHeaders?: Record<string, string>;
}

/** A query-string presigned URL (payload `UNSIGNED-PAYLOAD`). Returns the URL with the signature last. */
export function presignUrl(i: PresignInput): string {
  const stamp = amzDate(i.now);
  const date8 = stamp.slice(0, 8);
  const headers: Record<string, string> = { host: i.host, ...(i.signedHeaders ?? {}) };
  const names = Object.keys(headers).map((n) => n.toLowerCase()).sort().join(';');
  const query: Array<[string, string]> = [
    ['X-Amz-Algorithm', 'AWS4-HMAC-SHA256'],
    ['X-Amz-Credential', `${i.creds.accessKeyId}/${date8}/${i.region}/${i.service}/aws4_request`],
    ['X-Amz-Date', stamp],
    ['X-Amz-Expires', String(i.expiresSeconds)],
    ['X-Amz-SignedHeaders', names],
  ];
  if (i.creds.sessionToken) query.push(['X-Amz-Security-Token', i.creds.sessionToken]);
  const c = canonical(i.method, i.path, query, headers, 'UNSIGNED-PAYLOAD');
  const sig = signature(i.creds, i.now, i.region, i.service, c.text);
  return `https://${i.host}${uriEncode(i.path, true)}?${canonicalQuery(query)}&X-Amz-Signature=${sig}`;
}

export interface SignInput {
  method: string;
  host: string;
  path: string;
  query?: Query;
  /** Headers to send and sign (besides host, x-amz-date, the session token and, for S3, x-amz-content-sha256). */
  headers?: Record<string, string>;
  body?: Buffer | string;
  region: string;
  service: string;
  creds: AwsCredentials;
  now: Date;
  /** S3 wants x-amz-content-sha256 on every request. */
  s3?: boolean;
}

/** The headers to send for a header-signed request (`host` is left to the HTTP client). */
export function signRequest(i: SignInput): Record<string, string> {
  const stamp = amzDate(i.now);
  const payloadHash = sha256Hex(i.body ?? '');
  const send: Record<string, string> = { ...(i.headers ?? {}), 'x-amz-date': stamp };
  if (i.creds.sessionToken) send['x-amz-security-token'] = i.creds.sessionToken;
  if (i.s3) send['x-amz-content-sha256'] = payloadHash;
  const c = canonical(i.method, i.path, i.query ?? [], { ...send, host: i.host }, payloadHash);
  const sig = signature(i.creds, i.now, i.region, i.service, c.text);
  const scope = `${stamp.slice(0, 8)}/${i.region}/${i.service}/aws4_request`;
  send.authorization = `AWS4-HMAC-SHA256 Credential=${i.creds.accessKeyId}/${scope}, SignedHeaders=${c.signedHeaders}, Signature=${sig}`;
  return send;
}
