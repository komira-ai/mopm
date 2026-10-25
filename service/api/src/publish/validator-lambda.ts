import { DynamoStore, tablesFor } from '../dynamo-store';
import { DEPLOYED_VALIDATOR_OPTIONS } from '../validate/native-deps';
import { S3Channel, SqsFifoQueue } from './aws';
import { publishConfigFromEnv } from './config';
import { DynamoPublishStore, publishTablesFor } from './dynamo-publish-store';
import { validatePublish, type ValidatorDeps } from './validator';
import { documentClient, regionOf, required, stageOf } from './wiring';

/** The part of an SQS event the handler reads. */
interface SqsEvent {
  Records: Array<{ messageId: string; body: string }>;
}

let deps: ValidatorDeps | undefined;

function configure(): ValidatorDeps {
  const env = process.env;
  const stage = stageOf(env);
  const doc = documentClient();
  const region = regionOf(env);
  return {
    registry: new DynamoStore(doc, tablesFor(stage)),
    publishes: new DynamoPublishStore(doc, publishTablesFor(stage)),
    objects: new S3Channel(required(env, 'MOPM_CHANNEL_BUCKET'), { region }),
    indexQueue: new SqsFifoQueue(required(env, 'MOPM_INDEX_QUEUE_URL'), { region }),
    config: publishConfigFromEnv(env),
    channelUrl: required(env, 'MOPM_CHANNEL_URL'),
    validatorOptions: DEPLOYED_VALIDATOR_OPTIONS,
  };
}

/**
 * SQS (FIFO, batch size 1) -> validator. Any error is rethrown so the message returns to the queue; after the
 * queue's receive limit it goes to the dead-letter queue, which has an alarm.
 */
export const handler = async (event: SqsEvent): Promise<void> => {
  deps ??= configure();
  for (const r of event.Records) {
    const msg = JSON.parse(r.body) as { type?: string; publish_id?: string };
    if (msg.type !== 'validate' || typeof msg.publish_id !== 'string') {
      console.error(JSON.stringify({ level: 'error', msg: 'unrecognised message dropped', messageId: r.messageId }));
      continue;
    }
    const outcome = await validatePublish(deps, msg.publish_id);
    console.log(JSON.stringify({ level: 'info', msg: 'validate', publish_id: msg.publish_id, outcome }));
  }
};
