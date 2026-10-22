import { DynamoStore, tablesFor } from '../dynamo-store';
import { CloudFrontInvalidator, S3Channel, SqsFifoQueue } from './aws';
import { DynamoPublishStore, publishTablesFor } from './dynamo-publish-store';
import { parseIndexMessage, processIndexMessage, type IndexerDeps } from './indexer';
import { documentClient, regionOf, required, stageOf } from './wiring';

interface SqsEvent {
  Records: Array<{ messageId: string; body: string }>;
}

let deps: IndexerDeps | undefined;

function configure(): IndexerDeps {
  const env = process.env;
  const stage = stageOf(env);
  const doc = documentClient();
  const region = regionOf(env);
  return {
    registry: new DynamoStore(doc, tablesFor(stage)),
    publishes: new DynamoPublishStore(doc, publishTablesFor(stage)),
    objects: new S3Channel(required(env, 'MOPM_CHANNEL_BUCKET'), { region }),
    invalidator: new CloudFrontInvalidator(required(env, 'MOPM_DISTRIBUTION_ID'), { region }),
    indexQueue: new SqsFifoQueue(required(env, 'MOPM_INDEX_QUEUE_URL'), { region }),
    ensured: new Set<string>(),
  };
}

/**
 * SQS (FIFO, group = subdir, `pkg:<name>` or `takedowns`, batch size 1) -> the index writer. Errors are rethrown:
 * retry, then the DLQ and its alarm. A message of no known kind is logged and dropped.
 */
export const handler = async (event: SqsEvent): Promise<void> => {
  deps ??= configure();
  for (const r of event.Records) {
    const msg = parseIndexMessage(JSON.parse(r.body));
    if (!msg) {
      console.error(JSON.stringify({ level: 'error', msg: 'unrecognised message dropped', messageId: r.messageId }));
      continue;
    }
    await processIndexMessage(deps, msg);
    if (msg.type === 'index') console.log(JSON.stringify({ level: 'info', msg: 'index', subdir: msg.subdir, publish_id: msg.publish_id }));
    else if (msg.type === 'index_pkg') console.log(JSON.stringify({ level: 'info', msg: 'index_pkg', name: msg.name, rev: msg.rev, publish_id: msg.publish_id }));
    else console.log(JSON.stringify({ level: 'info', msg: 'index_takedowns' }));
  }
};
