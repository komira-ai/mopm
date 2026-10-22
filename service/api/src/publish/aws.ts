import { createHash } from 'node:crypto';
import type { Invalidator, ObjectStore, PresignedPut, Presigner, Queue, QueueMessage } from './ports';
import { credentialsFromEnv, presignUrl, signRequest } from './sigv4';
import type { AwsCredentials } from './sigv4';

/**
 * The AWS side of the publish ports, over plain HTTPS with SigV4 (./sigv4.ts) so the Lambda bundle needs only
 * what the Node.js runtime has. Nothing here runs in the unit tests against AWS: they run against a fake `HttpFn`
 * that checks the requests (the method, the signed headers, the body), and the signing itself has known-answer
 * tests. The first real exercise is the stage deployment.
 */
export interface HttpResponse {
  status: number;
  headers: { get(name: string): string | null };
  text(): Promise<string>;
  arrayBuffer(): Promise<ArrayBuffer>;
}
export type HttpFn = (url: string, init: { method: string; headers: Record<string, string>; body?: Buffer | string }) => Promise<HttpResponse>;

export const defaultHttp: HttpFn = (url, init) => (globalThis.fetch as unknown as HttpFn)(url, init);

export interface AwsOptions {
  region: string;
  credentials?: () => AwsCredentials;
  http?: HttpFn;
  now?: () => Date;
}

class AwsError extends Error {
  constructor(
    readonly service: string,
    readonly status: number,
    detail: string,
  ) {
    super(`${service} answered ${status}: ${detail.slice(0, 300)}`);
  }
}

// --- S3 -------------------------------------------------------------------------------------------------------

const b64 = (hex: string) => Buffer.from(hex, 'hex').toString('base64');

export class S3Channel implements ObjectStore {
  private readonly host: string;
  private readonly http: HttpFn;
  private readonly creds: () => AwsCredentials;
  private readonly now: () => Date;
  constructor(
    bucket: string,
    private readonly o: AwsOptions,
  ) {
    this.host = `${bucket}.s3.${o.region}.amazonaws.com`;
    this.http = o.http ?? defaultHttp;
    this.creds = o.credentials ?? (() => credentialsFromEnv());
    this.now = o.now ?? (() => new Date());
  }

  private request(method: string, key: string, headers: Record<string, string> = {}, body?: Buffer) {
    const path = `/${key}`;
    const signed = signRequest({ method, host: this.host, path, headers, body, region: this.o.region, service: 's3', creds: this.creds(), now: this.now(), s3: true });
    return this.http(`https://${this.host}${encodePath(path)}`, { method, headers: signed, ...(body ? { body } : {}) });
  }

  /** Without s3:ListBucket a missing key answers 403, so 403 and 404 both mean "not there" for a read. */
  private absent = (status: number) => status === 404 || status === 403;

  async head(key: string) {
    const r = await this.request('HEAD', key);
    if (this.absent(r.status)) return undefined;
    if (r.status !== 200) throw new AwsError('s3', r.status, `HEAD ${key}`);
    return { size: Number(r.headers.get('content-length')) };
  }

  async get(key: string) {
    const r = await this.request('GET', key);
    if (this.absent(r.status)) return undefined;
    if (r.status !== 200) throw new AwsError('s3', r.status, await r.text());
    return Buffer.from(await r.arrayBuffer());
  }

  async put(key: string, body: Buffer, opts: { contentType: string; cacheControl?: string; createOnly?: boolean }) {
    const headers: Record<string, string> = {
      'content-type': opts.contentType,
      'x-amz-checksum-sha256': createHash('sha256').update(body).digest('base64'),
    };
    if (opts.cacheControl) headers['cache-control'] = opts.cacheControl;
    if (opts.createOnly) headers['if-none-match'] = '*';
    const r = await this.request('PUT', key, headers, body);
    if (r.status === 412) return 'exists' as const;
    if (r.status !== 200) throw new AwsError('s3', r.status, await r.text());
    return 'created' as const;
  }

  async delete(key: string) {
    const r = await this.request('DELETE', key);
    if (r.status !== 204 && r.status !== 200 && r.status !== 404) throw new AwsError('s3', r.status, await r.text());
  }
}

const encodePath = (path: string) => path.split('/').map((s) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`)).join('/');

/**
 * A presigned PUT pinned to one exact Content-Length and one sha256: both headers are part of the signature, so
 * S3 itself refuses any other bytes (a wrong length is a signature mismatch; a wrong body is BadDigest). The URL
 * is signed with the API Lambda's role credentials and works for as long as its session does.
 */
export class S3Presigner implements Presigner {
  private readonly host: string;
  private readonly creds: () => AwsCredentials;
  constructor(
    bucket: string,
    private readonly o: Pick<AwsOptions, 'region' | 'credentials'>,
  ) {
    this.host = `${bucket}.s3.${o.region}.amazonaws.com`;
    this.creds = o.credentials ?? (() => credentialsFromEnv());
  }

  presignPut(key: string, p: { size: number; sha256: string; expiresInSeconds: number; now: Date }): PresignedPut {
    const headers = { 'content-length': String(p.size), 'x-amz-checksum-sha256': b64(p.sha256) };
    const url = presignUrl({
      method: 'PUT',
      host: this.host,
      path: `/${key}`,
      region: this.o.region,
      service: 's3',
      creds: this.creds(),
      now: p.now,
      expiresSeconds: p.expiresInSeconds,
      signedHeaders: headers,
    });
    return { url, headers };
  }
}

// --- SQS ------------------------------------------------------------------------------------------------------

/** SendMessage over the SQS JSON protocol (`AmazonSQS.SendMessage`). */
export class SqsFifoQueue implements Queue {
  private readonly host: string;
  private readonly http: HttpFn;
  private readonly creds: () => AwsCredentials;
  private readonly now: () => Date;
  constructor(
    private readonly queueUrl: string,
    private readonly o: AwsOptions,
  ) {
    this.host = `sqs.${o.region}.amazonaws.com`;
    this.http = o.http ?? defaultHttp;
    this.creds = o.credentials ?? (() => credentialsFromEnv());
    this.now = o.now ?? (() => new Date());
  }

  async send(m: QueueMessage): Promise<void> {
    const body = JSON.stringify({ QueueUrl: this.queueUrl, MessageBody: m.body, MessageGroupId: m.groupId, MessageDeduplicationId: m.dedupId });
    const headers = signRequest({
      method: 'POST',
      host: this.host,
      path: '/',
      headers: { 'content-type': 'application/x-amz-json-1.0', 'x-amz-target': 'AmazonSQS.SendMessage' },
      body,
      region: this.o.region,
      service: 'sqs',
      creds: this.creds(),
      now: this.now(),
    });
    const r = await this.http(`https://${this.host}/`, { method: 'POST', headers, body });
    if (r.status !== 200) throw new AwsError('sqs', r.status, await r.text());
  }
}

/**
 * The depth of a queue, for the operator's tool (src/ops/group-ops.ts): `GetQueueUrl` by name, then `GetQueueAttributes`.
 * Messages waiting, and messages being worked on (in flight): a queue is empty when both are 0.
 */
export class SqsQueueDepth {
  private readonly host: string;
  private readonly http: HttpFn;
  private readonly creds: () => AwsCredentials;
  private readonly now: () => Date;
  constructor(private readonly o: AwsOptions) {
    this.host = `sqs.${o.region}.amazonaws.com`;
    this.http = o.http ?? defaultHttp;
    this.creds = o.credentials ?? (() => credentialsFromEnv());
    this.now = o.now ?? (() => new Date());
  }

  private async call(target: string, payload: Record<string, unknown>): Promise<Record<string, any>> { // eslint-disable-line @typescript-eslint/no-explicit-any
    const body = JSON.stringify(payload);
    const headers = signRequest({
      method: 'POST',
      host: this.host,
      path: '/',
      headers: { 'content-type': 'application/x-amz-json-1.0', 'x-amz-target': `AmazonSQS.${target}` },
      body,
      region: this.o.region,
      service: 'sqs',
      creds: this.creds(),
      now: this.now(),
    });
    const r = await this.http(`https://${this.host}/`, { method: 'POST', headers, body });
    const text = await r.text();
    if (r.status !== 200) throw new AwsError('sqs', r.status, text);
    return JSON.parse(text) as Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
  }

  async depth(queueName: string): Promise<{ queue: string; visible: number; in_flight: number }> {
    const url = (await this.call('GetQueueUrl', { QueueName: queueName })).QueueUrl as string;
    const attrs = (await this.call('GetQueueAttributes', { QueueUrl: url, AttributeNames: ['ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible'] })).Attributes as Record<string, string>;
    return { queue: queueName, visible: Number(attrs.ApproximateNumberOfMessages ?? 0), in_flight: Number(attrs.ApproximateNumberOfMessagesNotVisible ?? 0) };
  }
}

// --- CloudFront -----------------------------------------------------------------------------------------------

/** CreateInvalidation on one distribution. The caller reference makes a repeat of the same batch harmless. */
export class CloudFrontInvalidator implements Invalidator {
  private readonly http: HttpFn;
  private readonly creds: () => AwsCredentials;
  private readonly now: () => Date;
  constructor(
    private readonly distributionId: string,
    o: AwsOptions,
  ) {
    this.http = o.http ?? defaultHttp;
    this.creds = o.credentials ?? (() => credentialsFromEnv());
    this.now = o.now ?? (() => new Date());
  }

  async invalidate(paths: string[], reference: string): Promise<void> {
    const xml =
      '<?xml version="1.0" encoding="UTF-8"?>' +
      '<InvalidationBatch xmlns="http://cloudfront.amazonaws.com/doc/2020-05-31/">' +
      `<Paths><Quantity>${paths.length}</Quantity><Items>${paths.map((p) => `<Path>${escapeXml(p)}</Path>`).join('')}</Items></Paths>` +
      `<CallerReference>${escapeXml(reference)}</CallerReference></InvalidationBatch>`;
    const path = `/2020-05-31/distribution/${this.distributionId}/invalidation`;
    const host = 'cloudfront.amazonaws.com';
    // CloudFront is a global service signed in us-east-1.
    const headers = signRequest({ method: 'POST', host, path, headers: { 'content-type': 'text/xml' }, body: xml, region: 'us-east-1', service: 'cloudfront', creds: this.creds(), now: this.now() });
    const r = await this.http(`https://${host}${path}`, { method: 'POST', headers, body: xml });
    if (r.status !== 201 && r.status !== 200) throw new AwsError('cloudfront', r.status, await r.text());
  }
}

const escapeXml = (s: string) => s.replace(/[<>&'"]/g, (c) => `&#${c.charCodeAt(0)};`);
