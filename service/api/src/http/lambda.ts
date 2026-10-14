import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';
import { DynamoStore, tablesFor } from '../dynamo-store';
import { route, type RouterDeps, type Stage } from './router';

/** The part of an API Gateway HTTP API (payload format 2.0) event the router needs. */
interface GatewayEvent {
  rawPath: string;
  queryStringParameters?: Record<string, string | undefined> | null;
  requestContext: { requestId: string; http: { method: string } };
}

let deps: RouterDeps | undefined;

function configure(): RouterDeps {
  const stage = process.env.MOPM_STAGE as Stage;
  if (stage !== 'beta' && stage !== 'gamma' && stage !== 'prod') throw new Error('MOPM_STAGE is not a stage');
  return {
    store: new DynamoStore(DynamoDBDocumentClient.from(new DynamoDBClient({})), tablesFor(stage)),
    stage,
    version: process.env.MOPM_VERSION ?? 'dev',
    commit: process.env.MOPM_COMMIT ?? 'dev',
    readOnly: process.env.MOPM_READ_ONLY === 'true',
  };
}

export const handler = async (event: GatewayEvent) => {
  deps ??= configure();
  return route(
    { method: event.requestContext.http.method, path: event.rawPath, query: event.queryStringParameters ?? {} },
    deps,
    event.requestContext.requestId,
  );
};
