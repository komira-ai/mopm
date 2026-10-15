import * as fs from 'fs';
import { createHash } from 'node:crypto';
import * as path from 'path';

/**
 * Characterisation of the three Lambda entry points (`http/lambda.ts`, `publish/validator-lambda.ts`,
 * `publish/indexer-lambda.ts`) and the `configure()` each one runs on a cold start.
 *
 * What it pins: not the routes (router.test.ts does) but the seam around them, which is the part another
 * implementation of these functions has to reproduce: how an API Gateway payload (v2) or an SQS event becomes a
 * request or a message, what environment a cold start needs and what it refuses, what is kept between
 * invocations of one container, what a failure does (the message returns to the queue, or it is dropped), and
 * which DynamoDB commands and AWS HTTPS requests go out. Each case is one JSON file in
 * `fixtures/handlers/`: environment, scripted DynamoDB replies, the event(s), and what must come out. The
 * files hold no TypeScript, so a second implementation can replay them. The events follow the AWS payload
 * formats; they are hand-written, not captured from a deployed stage.
 *
 * How the process is isolated: the DynamoDB document client is replaced by a scripted fake (the only
 * thing in `wiring.ts` that touches the SDK) and `globalThis.fetch` by a recorder, because the
 * publish adapters speak SigV4 over plain HTTPS. The signature, which carries the time, is not part of what is
 * recorded; the clock is fixed per invocation. Each case loads the handler module afresh (module state is the
 * container) and restores the environment afterwards.
 *
 * A failing case prints the actual outcome in full (`ACTUAL` below the diff): that is how a golden is made.
 */

const DIR = path.join(__dirname, '..', 'fixtures', 'handlers');
const LAMBDA_MODULE = {
  api: '../../src/http/lambda',
  validator: '../../src/publish/validator-lambda',
  indexer: '../../src/publish/indexer-lambda',
} as const;
// The credentials the SigV4 adapters read from the environment of a real Lambda: invented, from the AWS documentation's style.
const TEST_CREDENTIALS = { AWS_ACCESS_KEY_ID: 'AKIDEXAMPLE', AWS_SECRET_ACCESS_KEY: 'example-secret' };
const DEFAULT_CLOCK = '2026-10-01T00:00:00.000Z';
const KEPT_HEADERS = ['content-type', 'cache-control', 'if-none-match', 'x-amz-target'];

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
interface DynamoRule {
  op: string;
  table: string;
  /** Only for a command with this Key. */
  key?: Json;
  respond?: Json;
  throw?: string;
  message?: string;
}
interface HttpRule {
  url_contains: string;
  method?: string;
  status: number;
  body?: string;
}
interface Invocation {
  /** Replaces the case's environment for this invocation (a container keeps what it configured on the first). */
  env?: Record<string, string>;
  clock?: string;
  /** An event object, or a path relative to fixtures/handlers. */
  event: Json | string;
  expect: {
    returns?: Json;
    rejects?: { name: string; message?: string };
  };
}
interface Case {
  description: string;
  lambda: keyof typeof LAMBDA_MODULE;
  env: Record<string, string>;
  dynamo?: DynamoRule[];
  aws_http?: HttpRule[];
  invocations: Invocation[];
  expect: { dynamo: Json[]; aws_http: Json[]; logs: Json[] };
}

class ScriptedDoc {
  calls: Json[] = [];
  constructor(private readonly rules: DynamoRule[]) {}
  async send(cmd: { constructor: { name: string }; input: Record<string, any> }): Promise<any> { // eslint-disable-line @typescript-eslint/no-explicit-any
    const op = cmd.constructor.name.replace(/Command$/, '');
    const i = cmd.input;
    this.calls.push(
      JSON.parse(
        JSON.stringify({
          op,
          table: i.TableName,
          index: i.IndexName,
          key: i.Key,
          values: op === 'Query' ? i.ExpressionAttributeValues : undefined,
          condition: i.ConditionExpression,
          item: op === 'Put' ? i.Item : undefined,
        }),
      ),
    );
    const rule = this.rules.find((r) => r.op === op && r.table === i.TableName && (r.key === undefined || JSON.stringify(r.key) === JSON.stringify(i.Key)));
    if (rule?.throw) throw Object.assign(new Error(rule.message ?? rule.throw), { name: rule.throw });
    if (rule?.respond !== undefined) return structuredClone(rule.respond);
    return op === 'Query' || op === 'Scan' ? { Items: [] } : {};
  }
}

const sha256Hex = (b: Buffer) => createHash('sha256').update(b).digest('hex');

function recordedFetch(rules: HttpRule[], calls: Json[]) {
  return async (url: string, init: { method: string; headers: Record<string, string>; body?: Buffer | string }) => {
    const headers: Record<string, string> = {};
    for (const [k, v] of Object.entries(init.headers ?? {})) if (KEPT_HEADERS.includes(k.toLowerCase())) headers[k.toLowerCase()] = v;
    const body: Json | undefined =
      init.body === undefined ? undefined : typeof init.body === 'string' ? init.body : { sha256: sha256Hex(init.body) };
    calls.push(JSON.parse(JSON.stringify({ method: init.method, url, headers, body })));
    const rule = rules.find((r) => url.includes(r.url_contains) && (r.method === undefined || r.method === init.method));
    const status = rule?.status ?? (url.includes('cloudfront') ? 201 : init.method === 'DELETE' ? 204 : 200);
    return { status, headers: { get: () => null }, text: async () => rule?.body ?? '', arrayBuffer: async () => new ArrayBuffer(0) };
  };
}

function setEnv(env: Record<string, string>): void {
  for (const k of Object.keys(process.env)) if (k.startsWith('MOPM_') || k.startsWith('AWS_')) delete process.env[k];
  Object.assign(process.env, TEST_CREDENTIALS, env);
}

function loadHandler(lambda: keyof typeof LAMBDA_MODULE, doc: ScriptedDoc): (event: unknown) => Promise<unknown> {
  let handler: ((event: unknown) => Promise<unknown>) | undefined;
  jest.isolateModules(() => {
    jest.doMock('../../src/publish/wiring', () => ({ ...jest.requireActual('../../src/publish/wiring'), documentClient: () => doc }));
    handler = require(LAMBDA_MODULE[lambda]).handler; // eslint-disable-line @typescript-eslint/no-require-imports
  });
  return handler!;
}

const readCase = (file: string): Case => JSON.parse(fs.readFileSync(path.join(DIR, file), 'utf8'));
const readEvent = (e: Json | string): unknown => (typeof e === 'string' ? JSON.parse(fs.readFileSync(path.join(DIR, e), 'utf8')) : e);

async function run(c: Case) {
  const doc = new ScriptedDoc(c.dynamo ?? []);
  const http: Json[] = [];
  const logs: Json[] = [];
  const spyOn = (stream: 'log' | 'error') =>
    jest.spyOn(console, stream).mockImplementation(((...args: unknown[]) => {
      const line = args[0];
      let parsed: Json = String(line);
      try {
        parsed = JSON.parse(String(line));
      } catch {
        /* not JSON: kept as text */
      }
      logs.push({ stream, line: parsed });
    }) as never);
  const spies = [spyOn('log'), spyOn('error')];
  const savedEnv = { ...process.env };
  const savedFetch = (globalThis as any).fetch; // eslint-disable-line @typescript-eslint/no-explicit-any
  (globalThis as any).fetch = recordedFetch(c.aws_http ?? [], http); // eslint-disable-line @typescript-eslint/no-explicit-any
  jest.useFakeTimers({
    now: new Date(DEFAULT_CLOCK),
    doNotFake: ['hrtime', 'nextTick', 'performance', 'queueMicrotask', 'requestAnimationFrame', 'cancelAnimationFrame', 'requestIdleCallback', 'cancelIdleCallback', 'setImmediate', 'clearImmediate', 'setInterval', 'clearInterval', 'setTimeout', 'clearTimeout'],
  });
  try {
    setEnv(c.env);
    const handler = loadHandler(c.lambda, doc);
    const outcomes: Json[] = [];
    for (const inv of c.invocations) {
      jest.setSystemTime(new Date(inv.clock ?? DEFAULT_CLOCK));
      setEnv(inv.env ?? c.env);
      try {
        const r = await handler(readEvent(inv.event));
        outcomes.push({ returns: r === undefined ? null : JSON.parse(JSON.stringify(r)) });
      } catch (err) {
        outcomes.push({ rejects: { name: (err as Error).name, message: (err as Error).message } });
      }
    }
    return { outcomes, dynamo: doc.calls, aws_http: http, logs };
  } finally {
    jest.useRealTimers();
    jest.dontMock('../../src/publish/wiring');
    (globalThis as any).fetch = savedFetch; // eslint-disable-line @typescript-eslint/no-explicit-any
    for (const k of Object.keys(process.env)) delete process.env[k];
    Object.assign(process.env, savedEnv);
    for (const s of spies) s.mockRestore();
  }
}

/** What the case file says, in the shape `run` returns. A health golden lists the members it requires (`body_json`); extra members are the contract's additive rule. */
function expectedOf(c: Case) {
  return {
    outcomes: c.invocations.map((i) => i.expect),
    dynamo: c.expect.dynamo,
    aws_http: c.expect.aws_http,
    logs: c.expect.logs,
  };
}

function normalise(actual: Awaited<ReturnType<typeof run>>, c: Case) {
  const outcomes = actual.outcomes.map((o, n) => {
    const want = c.invocations[n]!.expect;
    const r = (o as any).returns; // eslint-disable-line @typescript-eslint/no-explicit-any
    if (r && want.returns && typeof want.returns === 'object' && !Array.isArray(want.returns) && 'body_json' in want.returns) {
      const parsed = JSON.parse(r.body);
      const keep = Object.keys((want.returns as any).body_json); // eslint-disable-line @typescript-eslint/no-explicit-any
      const { body: _b, ...rest } = r;
      return { returns: { ...rest, body_json: Object.fromEntries(keep.filter((k) => k in parsed).map((k) => [k, parsed[k]])) } };
    }
    const w = want.rejects;
    const rej = (o as any).rejects; // eslint-disable-line @typescript-eslint/no-explicit-any
    if (rej && w && w.message === undefined) return { rejects: { name: rej.name } };
    return o;
  });
  return { ...actual, outcomes };
}

const files = fs.readdirSync(DIR).filter((f) => f.endsWith('.json')).sort();

describe('lambda entry points on recorded events', () => {
  test('the case files are all here (a deleted case does not pass silently)', () => {
    expect(files).toEqual([
      'api_auth_unconfigured.json',
      'api_base64_body.json',
      'api_begin_flag_unreadable_fails_closed.json',
      'api_begin_read_only.json',
      'api_begin_without_token.json',
      'api_bad_stage.json',
      'api_cold_start_failure_is_retried.json',
      'api_configuration_is_kept.json',
      'api_health_defaults.json',
      'api_health_env_switch.json',
      'api_health_flag_cache.json',
      'api_health_flag_unreadable.json',
      'api_health_runtime_switch.json',
      'api_publish_unwired.json',
      'api_search_query.json',
      'api_unknown_package.json',
      'indexer_cloudfront_failure_is_rethrown.json',
      'indexer_publish_progress.json',
      'indexer_rebuild_keeps_ensured_set.json',
      'indexer_unknown_subdir.json',
      'indexer_unrecognised_dropped.json',
      'validator_cold_start_refusals.json',
      'validator_drops_unrecognised.json',
      'validator_error_stops_the_batch.json',
      'validator_malformed_body_rejects.json',
      'validator_published_is_skipped.json',
      'validator_records_in_order.json',
      'validator_resumes_indexing.json',
      'validator_unknown_publish.json',
    ].sort());
  });

  test.each(files)('%s', async (file) => {
    const c = readCase(file);
    const actual = normalise(await run(c), c);
    const want = expectedOf(c);
    try {
      expect(actual).toEqual(want);
    } catch (err) {
      throw new Error(`${(err as Error).message}\n\nACTUAL ${file}:\n${JSON.stringify(actual, null, 2)}\nEND ACTUAL ${file}`);
    }
  });
});
