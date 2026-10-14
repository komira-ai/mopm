import { DynamoStore, tablesFor } from '../dynamo-store';
import { documentClient, flagsFor, publishApiFor, stageOf } from '../publish/wiring';
import type { Flags } from '../publish/ports';
import { route, type RouterDeps, type Stage } from './router';

/** The part of an API Gateway HTTP API (payload format 2.0) event the router needs. */
interface GatewayEvent {
  rawPath: string;
  queryStringParameters?: Record<string, string | undefined> | null;
  headers?: Record<string, string | undefined> | null;
  body?: string | null;
  isBase64Encoded?: boolean;
  requestContext: { requestId: string; http: { method: string } };
}

interface Configured {
  deps: RouterDeps;
  flags: Flags;
  envReadOnly: boolean;
}

let configured: Configured | undefined;

function configure(): Configured {
  const stage = stageOf(process.env) as Stage;
  const doc = documentClient();
  const flags = flagsFor(process.env, doc, stage);
  const envReadOnly = process.env.MOPM_READ_ONLY === 'true';
  return {
    deps: {
      store: new DynamoStore(doc, tablesFor(stage)),
      stage,
      version: process.env.MOPM_VERSION ?? 'dev',
      commit: process.env.MOPM_COMMIT ?? 'dev',
      readOnly: envReadOnly,
      publish: publishApiFor(process.env, doc, stage, flags),
    },
    flags,
    envReadOnly,
  };
}

export const handler = async (event: GatewayEvent) => {
  configured ??= configure();
  const c = configured;
  // /health reports the switch. If it cannot be read, health still answers, with the deployment's own value.
  let readOnly = c.envReadOnly;
  try {
    readOnly = await c.flags.readOnly();
  } catch (err) {
    console.error(JSON.stringify({ level: 'error', msg: 'read-only switch unreadable', error: String(err) }));
  }
  const body = event.body ? (event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf8') : event.body) : undefined;
  return route(
    {
      method: event.requestContext.http.method,
      path: event.rawPath,
      query: event.queryStringParameters ?? {},
      headers: event.headers ?? {},
      body,
    },
    { ...c.deps, readOnly },
    event.requestContext.requestId,
  );
};
