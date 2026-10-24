import * as fs from 'fs';
import * as path from 'path';
import { Readable } from 'node:stream';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';
import { marshall } from '@aws-sdk/util-dynamodb';
import { DynamoAuthStore, authTablesFor, ownedPackagesFrom } from '../../src/auth';
import { DynamoStore, tablesFor } from '../../src/dynamo-store';
import { DynamoPublishStore, publishTablesFor } from '../../src/publish/dynamo-publish-store';
import { DynamoFlags } from '../../src/publish/flags';

/**
 * The storage wire form: what the TypeScript adapters send to DynamoDB, byte for byte as JSON, so that another
 * implementation of the same adapters can be held to the same requests.
 *
 * How: the adapters run on the real `DynamoDBDocumentClient` (same options as `wiring.ts`) over the real
 * `DynamoDBClient`, whose HTTP handler is replaced by a recorder. What it records is the body the SDK serialises
 * (`{"S":..}` / `{"N":..}` attribute values included) and the operation (`X-Amz-Target`). Nothing else of the
 * request is kept: the signature and the time are not part of the wire form. The one value the SDK invents,
 * `ClientRequestToken` of a transaction, is checked to be a UUID and replaced by `<uuid>`.
 *
 * Each file in `fixtures/wire/` is a list of steps: an adapter method, its arguments (plain JSON), the replies
 * DynamoDB gives, and what must come out (the requests, the returned value or the error). A reply's `Item`,
 * `Items`, `LastEvaluatedKey` and `Attributes` are written as plain documents and marshalled by the harness with
 * the SDK's own `marshall`, so the files stay readable. `error` makes the reply a DynamoDB error of that name
 * (HTTP 400), with `reasons` as the cancellation reasons of a transaction.
 *
 * What it does not prove: that DynamoDB accepts the requests (no test here touches the real service), or that
 * a reply the harness invents is one DynamoDB would give.
 *
 * A failing file prints the actual steps in full (`ACTUAL`); that is how a golden is made.
 */

const DIR = path.join(__dirname, '..', 'fixtures', 'wire');
const FILES = ['auth.json', 'flags.json', 'group.json', 'publish.json', 'store.json'];
const FIXED_NOW = '2026-10-01T00:00:00.000Z';

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
interface Reply {
  status?: number;
  body?: { [k: string]: Json };
  error?: string;
  reasons?: string[];
}
interface Step {
  adapter: 'store' | 'auth' | 'publish' | 'flags' | 'owned';
  method: string;
  args: Json[];
  replies?: Reply[];
  expect?: { requests: Json[]; returns?: Json; throws?: { name: string; code?: string } };
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** A reply as the wire carries it. */
function wireReply(r: Reply): { status: number; body: unknown } {
  if (r.error !== undefined) {
    return {
      status: 400,
      body: {
        __type: `com.amazonaws.dynamodb.v20120810#${r.error}`,
        message: 'synthetic',
        ...(r.reasons ? { CancellationReasons: r.reasons.map((Code) => ({ Code })) } : {}),
      },
    };
  }
  const body: Record<string, unknown> = { ...(r.body ?? {}) };
  for (const k of ['Item', 'LastEvaluatedKey', 'Attributes']) if (body[k] !== undefined) body[k] = marshall(body[k] as Record<string, unknown>);
  if (Array.isArray(body.Items)) body.Items = (body.Items as Record<string, unknown>[]).map((i) => marshall(i));
  return { status: r.status ?? 200, body };
}

class Recorder {
  requests: Json[] = [];
  replies: Reply[] = [];
  // The parts of the SDK's request-handler interface that are not `handle`.
  httpHandlerConfigs = () => ({});
  updateHttpClientConfig = () => undefined;
  destroy = () => undefined;
  metadata = { handlerProtocol: 'http/1.1' };
  handle = async (req: { headers: Record<string, string>; body: string }) => {
    const target = String(req.headers['x-amz-target'] ?? req.headers['X-Amz-Target']).split('.').pop()!;
    const body = JSON.parse(String(req.body));
    if (target === 'TransactWriteItems') {
      // A transaction the adapter gives no token gets a UUID from the SDK, which differs on every run. The group commit
      // sets its own: 32 hex characters, the same for the same group and attempt, so it stays in the golden as it is.
      const token = String(body.ClientRequestToken);
      expect(token).toMatch(/^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{32})$/);
      if (UUID.test(token)) body.ClientRequestToken = '<uuid>';
    }
    this.requests.push({ target, body });
    const r = wireReply(this.replies.shift() ?? {});
    return {
      response: {
        statusCode: r.status,
        headers: { 'content-type': 'application/x-amz-json-1.0' },
        body: Readable.from([Buffer.from(JSON.stringify(r.body))]),
      },
    };
  };
}

function adapters(recorder: Recorder) {
  const client = new DynamoDBClient({
    region: 'us-east-1',
    credentials: { accessKeyId: 'AKIDEXAMPLE', secretAccessKey: 'example-secret' },
    maxAttempts: 1,
    requestHandler: recorder as never,
  });
  // As wiring.ts builds the production client.
  const doc = DynamoDBDocumentClient.from(client, { marshallOptions: { removeUndefinedValues: true } });
  return {
    store: new DynamoStore(doc, tablesFor('beta')),
    auth: new DynamoAuthStore(doc, authTablesFor('beta')),
    publish: new DynamoPublishStore(doc, publishTablesFor('beta')),
    flags: new DynamoFlags(doc, publishTablesFor('beta').config),
    owned: { call: ownedPackagesFrom(doc, 'mopm-beta-owners') },
  };
}

async function runSteps(steps: Step[]) {
  const out: Json[] = [];
  jest.useFakeTimers({
    now: new Date(FIXED_NOW),
    doNotFake: ['hrtime', 'nextTick', 'performance', 'queueMicrotask', 'requestAnimationFrame', 'cancelAnimationFrame', 'requestIdleCallback', 'cancelIdleCallback', 'setImmediate', 'clearImmediate', 'setInterval', 'clearInterval', 'setTimeout', 'clearTimeout'],
  });
  try {
    for (const s of steps) {
      const recorder = new Recorder();
      recorder.replies = [...(s.replies ?? [])];
      const target = (adapters(recorder) as Record<string, any>)[s.adapter]; // eslint-disable-line @typescript-eslint/no-explicit-any
      let result: Json;
      try {
        // `{"$set": {...}}` stands for the function updatePublish takes: the record with those members replaced.
        const args = structuredClone(s.args).map((a) => (a && typeof a === 'object' && !Array.isArray(a) && '$set' in a ? (cur: object) => ({ ...cur, ...(a as { $set: object }).$set }) : a));
        const v = await target[s.method](...args);
        result = { returns: v === undefined ? null : JSON.parse(JSON.stringify(v)) };
      } catch (err) {
        const e = err as { name?: string; code?: string; message?: string };
        result = { throws: { name: String(e.name), ...(e.code ? { code: e.code } : {}) } };
      }
      out.push({ requests: recorder.requests, ...(result as object) } as Json);
    }
  } finally {
    jest.useRealTimers();
  }
  return out;
}

describe('the storage wire form', () => {
  test('the fixture files are all here', () => {
    expect(fs.readdirSync(DIR).filter((f) => f.endsWith('.json')).sort()).toEqual(FILES);
  });

  test.each(FILES)('%s', async (file) => {
    const steps: Step[] = JSON.parse(fs.readFileSync(path.join(DIR, file), 'utf8'));
    const actual = await runSteps(steps);
    const want = steps.map((s) => s.expect);
    try {
      expect(actual).toEqual(want);
    } catch (err) {
      throw new Error(`${(err as Error).message}\n\nACTUAL ${file}:\n${JSON.stringify(actual, null, 2)}\nEND ACTUAL ${file}`);
    }
  });
});
