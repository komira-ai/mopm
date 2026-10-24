import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';
import { Authenticator, authTablesFor, DynamoAuthStore } from '../auth';
import { DynamoStore, tablesFor } from '../dynamo-store';
import { S3Channel, S3Presigner, SqsFifoQueue } from './aws';
import { publishConfigFromEnv } from './config';
import { DynamoPublishStore, publishTablesFor } from './dynamo-publish-store';
import { AnyFlag, DynamoFlags, StaticFlags } from './flags';
import type { Flags } from './ports';
import { GroupService } from './group-service';
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
  const groupQueueUrl = env.MOPM_GROUP_QUEUE_URL;
  if (!bucket || !queueUrl) return undefined;
  const region = regionOf(env);
  const t = publishTablesFor(stage);
  const registry = new DynamoStore(doc, tablesFor(stage));
  const publishes = new DynamoPublishStore(doc, t);
  const objects = new S3Channel(bucket, { region });
  const presigner = new S3Presigner(bucket, { region });
  const config = publishConfigFromEnv(env);
  const service = new PublishService({
    registry,
    // A single publish may take over the number of a group that is dead.
    groups: registry,
    publishes,
    objects,
    presigner,
    validateQueue: new SqsFifoQueue(queueUrl, { region }),
    // Yank and unyank ask the index writer to rewrite repodata; without the queue they answer `unavailable`.
    ...(indexQueueUrl ? { indexQueue: new SqsFifoQueue(indexQueueUrl, { region }) } : {}),
    config,
  });
  // The group routes exist, and answer route_not_found until the `groups_enabled` item of the config table admits the caller.
  // A commit queues the group's validation on the group queue; without the queue it answers `unavailable`.
  const groups = new GroupService({ registry, publishes, objects, presigner, config, ...(groupQueueUrl ? { groupQueue: new SqsFifoQueue(groupQueueUrl, { region }) } : {}) });
  return { auth: new Authenticator({ store: new DynamoAuthStore(doc, authTablesFor(stage)) }), service, flags, groups };
}
