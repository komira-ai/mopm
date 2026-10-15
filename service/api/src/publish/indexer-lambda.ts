import { DynamoStore, tablesFor } from '../dynamo-store';
import { CloudFrontInvalidator, S3Channel } from './aws';
import { DynamoPublishStore, publishTablesFor } from './dynamo-publish-store';
import { indexSubdir, type IndexerDeps } from './indexer';
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
    ensured: new Set<string>(),
  };
}

/** SQS (FIFO, group = subdir, batch size 1) -> the index writer. Errors are rethrown: retry, then the DLQ and its alarm. */
export const handler = async (event: SqsEvent): Promise<void> => {
  deps = configure();
  for (const r of event.Records) {
    const msg = JSON.parse(r.body) as { type?: string; subdir?: string; publish_id?: string };
    if (msg.type !== 'index' || typeof msg.subdir !== 'string') {
      console.error(JSON.stringify({ level: 'error', msg: 'unrecognised message dropped', messageId: r.messageId }));
      continue;
    }
    await indexSubdir(deps, { type: 'index', subdir: msg.subdir, ...(typeof msg.publish_id === 'string' ? { publish_id: msg.publish_id } : {}) });
    console.log(JSON.stringify({ level: 'info', msg: 'index', subdir: msg.subdir, publish_id: msg.publish_id }));
  }
};
