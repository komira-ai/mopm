import { createHash } from 'node:crypto';
import { indexKey, TAKEDOWNS_KEY, TAKEDOWNS_V2_KEY } from '../index-files';

/**
 * The reader of the static sparse index (spec/index.md): `GET /index/<aa>/<bb>/<name>` and `GET /index/takedowns.json`
 * (version 1, flat names), `GET /index/v2/<aa>/<bb>/<namespace>/<name>` and `GET /index/v2/takedowns.json` (version 2,
 * full names) answer with the bytes stored under the same key of the channel bucket. (`/index/config.json` is not here: it is built
 * from code by the API router and is never an object.)
 */
export interface IndexObjects {
  /** The bytes, or undefined ONLY when the key does not exist. Any other failure (a refusal included) must throw. */
  get(key: string): Promise<Buffer | undefined>;
}

export interface IndexRequest {
  method: string;
  /** The raw path as the gateway received it, still percent-encoded. */
  path: string;
}

export interface IndexResponse {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
  isBase64Encoded?: boolean;
}

const FILE = /^\/index\/([a-z0-9_]{2})\/([a-z0-9_]{2})\/([a-z][a-z0-9_]{1,63})$/;
// The directories of version 2 are the namespace's first four characters, so they may hold a `-`.
const FILE_V2 = /^\/index\/v2\/([a-z0-9_-]{2})\/([a-z0-9_-]{2})\/([a-z0-9-]{1,39})\/([a-z][a-z0-9_]{1,63})$/;
export const TAKEDOWNS_PATH = '/index/takedowns.json';
export const TAKEDOWNS_V2_PATH = '/index/v2/takedowns.json';

/**
 * The key a request path names, or undefined. The name must be a package name (a full name for `/index/v2/`) and the two
 * directories must be the ones derived from it. The key is recomputed from the validated name, never copied from the request. Raw, undecoded: an
 * encoded dot or slash does not match the character classes, so it is refused rather than interpreted.
 */
export function keyOfPath(path: string): { key: string; contentType: string } | undefined {
  if (path === TAKEDOWNS_PATH) return { key: TAKEDOWNS_KEY, contentType: 'application/json' };
  if (path === TAKEDOWNS_V2_PATH) return { key: TAKEDOWNS_V2_KEY, contentType: 'application/json' };
  const v2 = FILE_V2.exec(path);
  if (v2) {
    const [, aa, bb, namespace, name] = v2 as unknown as [string, string, string, string, string];
    // indexKey validates the whole full name (the namespace grammar and length) and derives the directories.
    let key: string;
    try {
      key = indexKey(`${namespace}/${name}`);
    } catch {
      return undefined;
    }
    return key === `index/v2/${aa}/${bb}/${namespace}/${name}` ? { key, contentType: 'application/x-ndjson' } : undefined;
  }
  const m = FILE.exec(path);
  if (!m) return undefined;
  const [, aa, bb, name] = m as unknown as [string, string, string, string];
  const key = indexKey(name);
  return key === `index/${aa}/${bb}/${name}` ? { key, contentType: 'application/x-ndjson' } : undefined;
}

function reply(statusCode: number, requestId: string, headers: Record<string, string>, body: string, isBase64Encoded = false): IndexResponse {
  return { statusCode, headers: { 'x-mopm-request-id': requestId, ...headers }, body, ...(isBase64Encoded ? { isBase64Encoded } : {}) };
}

const failure = (statusCode: number, requestId: string, code: string, message: string) =>
  reply(statusCode, requestId, { 'content-type': 'application/json', 'cache-control': 'no-store' }, JSON.stringify({ error: { code, message } }));

/** Handle one request. Never throws. 404 means the index has no such file; any other trouble reaching the bucket is 502. */
export async function readIndex(objects: IndexObjects, req: IndexRequest, requestId: string): Promise<IndexResponse> {
  const target = req.method === 'GET' ? keyOfPath(req.path) : undefined;
  if (!target) return failure(404, requestId, 'not_in_index', 'no such file in the index');
  let bytes: Buffer | undefined;
  try {
    bytes = await objects.get(target.key);
  } catch (err) {
    console.error(JSON.stringify({ level: 'error', requestId, key: target.key, error: String((err as Error)?.message ?? err) }));
    return failure(502, requestId, 'index_unavailable', 'the index could not be read');
  }
  if (bytes === undefined) return failure(404, requestId, 'not_in_index', 'no such file in the index');
  // Bytes that are not valid UTF-8 would be altered by a string body, so those (never written today) go as base64.
  const text = bytes.toString('utf8');
  const plain = Buffer.from(text, 'utf8').equals(bytes);
  return reply(
    200,
    requestId,
    {
      'content-type': target.contentType,
      'cache-control': 'public, max-age=60',
      etag: `"${createHash('sha256').update(bytes).digest('hex')}"`,
    },
    plain ? text : bytes.toString('base64'),
    !plain,
  );
}
