import { DynamoStore, tablesFor } from '../dynamo-store';
import { S3Channel, SqsFifoQueue } from './aws';
import { publishConfigFromEnv } from './config';
import { DynamoPublishStore, publishTablesFor } from './dynamo-publish-store';
import { flipGroup } from './group-chain';
import { GROUP_ID } from './group-keys';
import { validateGroup, type GroupValidatorDeps } from './group-validator';
import { documentClient, regionOf, required, stageOf } from './wiring';

/** The part of an SQS event the handler reads. */
interface SqsEvent {
  Records: Array<{ messageId: string; body: string }>;
}

let deps: GroupValidatorDeps | undefined;
const isCount = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v) && v >= 0;

function configure(): GroupValidatorDeps {
  const env = process.env;
  const stage = stageOf(env);
  const doc = documentClient();
  const region = regionOf(env);
  return {
    registry: new DynamoStore(doc, tablesFor(stage)),
    publishes: new DynamoPublishStore(doc, publishTablesFor(stage)),
    objects: new S3Channel(required(env, 'MOPM_CHANNEL_BUCKET'), { region }),
    groupQueue: new SqsFifoQueue(required(env, 'MOPM_GROUP_QUEUE_URL'), { region }),
    indexQueue: new SqsFifoQueue(required(env, 'MOPM_INDEX_QUEUE_URL'), { region }),
    config: publishConfigFromEnv(env),
    channelUrl: required(env, 'MOPM_CHANNEL_URL'),
  };
}

/**
 * SQS (FIFO, batch size 1, the group queue) -> the group's validator. Any error is rethrown so the message returns to the
 * queue; after the queue's receive limit it goes to the dead-letter queue, which has an alarm. A message that is not a group
 * validation is logged and dropped, as the single validator does for one it does not know.
 */
export const handler = async (event: SqsEvent): Promise<void> => {
  deps ??= configure();
  for (const r of event.Records) {
    const msg = JSON.parse(r.body) as { type?: string; group_id?: unknown; attempt?: unknown; n?: unknown; resend?: unknown };
    if (msg.type === 'flip_group' && typeof msg.group_id === 'string' && GROUP_ID.test(msg.group_id) && isCount(msg.attempt) && isCount(msg.resend)) {
      const flip = { groups: deps.registry, indexQueue: deps.indexQueue, groupQueue: deps.groupQueue, now: () => new Date(), log: (l: Record<string, unknown>) => console.log(JSON.stringify(l)) };
      const outcome = await flipGroup(flip, { type: 'flip_group', group_id: msg.group_id, attempt: msg.attempt, resend: msg.resend });
      console.log(JSON.stringify({ level: 'info', msg: 'flip_group', group_id: msg.group_id, outcome }));
      continue;
    }
    if (msg.type !== 'validate_group' || typeof msg.group_id !== 'string' || typeof msg.attempt !== 'number') {
      console.error(JSON.stringify({ level: 'error', msg: 'unrecognised message dropped', messageId: r.messageId }));
      continue;
    }
    const outcome = await validateGroup(deps, { group_id: msg.group_id, attempt: msg.attempt, n: typeof msg.n === 'number' ? msg.n : 0 });
    console.log(JSON.stringify({ level: 'info', msg: 'validate_group', group_id: msg.group_id, outcome }));
  }
};
