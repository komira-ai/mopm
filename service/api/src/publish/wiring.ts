import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';
import { Authenticator, authTablesFor, DynamoAuthStore } from '../auth';
import { DynamoStore, tablesFor } from '../dynamo-store';
import { S3Channel, S3Presigner, SqsFifoQueue } from './aws';
import { publishConfigFromEnv } from './config';
import { DynamoPublishStore, publishTablesFor } from './dynamo-publish-store';
import { AnyFlag, DynamoFlags, StaticFlags } from './flags';
import type { Flags } from './ports';
import { PublishService } from './service';

type Env = Record<string, string | undefined>;

export function required(env: Env, name: string): string {
  const v = env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

/** One document client for a Lambda container. `undefined` members are dropped, as the stores expect. */
export const documentClient = () => DynamoDBDocumentClient.from(new DynamoDBClient({}), { marshallOptions: { removeUndefinedValues: true } });

export function stageOf(env: Env): string {
  const stage = required(env, 'MOPM_STAGE');
  if (stage !== 'beta' && stage !== 'gamma' && stage !== 'prod') throw new Error('MOPM_STAGE is not a stage');
  return stage;
}

export const regionOf = (env: Env) => env.AWS_REGION ?? 'us-east-1';

/** The read-only switch: the environment value of the deployment, or the runtime item in the config table. */
export function flagsFor(env: Env, doc: ReturnType<typeof documentClient>, stage: string): Flags {
  return new AnyFlag([new StaticFlags(env.MOPM_READ_ONLY === 'true'), new DynamoFlags(doc, publishTablesFor(stage).config)]);
}

/** The API Lambda's publish side, or undefined when the deployment has no upload bucket and queue (a stub). */
export function publishApiFor(env: Env, doc: ReturnType<typeof documentClient>, stage: string, flags: Flags) {
  const bucket = env.MOPM_CHANNEL_BUCKET;
  const queueUrl = env.MOPM_VALIDATE_QUEUE_URL;
  const indexQueueUrl = env.MOPM_INDEX_QUEUE_URL;
  if (!bucket || !queueUrl) return undefined;
  const region = regionOf(env);
  const t = publishTablesFor(stage);
  const service = new PublishService({
    registry: new DynamoStore(doc, tablesFor(stage)),
    publishes: new DynamoPublishStore(doc, t),
    objects: new S3Channel(bucket, { region }),
    presigner: new S3Presigner(bucket, { region }),
    validateQueue: new SqsFifoQueue(queueUrl, { region }),
    // Yank and unyank ask the index writer to rewrite repodata; without the queue they answer `unavailable`.
    ...(indexQueueUrl ? { indexQueue: new SqsFifoQueue(indexQueueUrl, { region }) } : {}),
    config: publishConfigFromEnv(env),
  });
  return { auth: new Authenticator({ store: new DynamoAuthStore(doc, authTablesFor(stage)) }), service, flags };
}
