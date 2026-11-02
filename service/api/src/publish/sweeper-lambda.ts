import { DynamoStore, tablesFor } from '../dynamo-store';
import { SqsFifoQueue } from './aws';
import { sweepGroups, type SweeperDeps } from './group-sweeper';
import { documentClient, regionOf, required, stageOf } from './wiring';

let deps: SweeperDeps | undefined;

function configure(): SweeperDeps {
  const env = process.env;
  const doc = documentClient();
  return {
    groups: new DynamoStore(doc, tablesFor(stageOf(env))),
    groupQueue: new SqsFifoQueue(required(env, 'MOPM_GROUP_QUEUE_URL'), { region: regionOf(env) }),
    indexQueue: new SqsFifoQueue(required(env, 'MOPM_INDEX_QUEUE_URL'), { region: regionOf(env) }),
  };
}

/** The schedule (every five minutes) -> the group sweeper. An error is rethrown: the next run tries again, and a failing run shows in the function's errors. */
export const handler = async (): Promise<void> => {
  deps ??= configure();
  const r = await sweepGroups(deps);
  console.log(JSON.stringify({ level: 'info', msg: 'sweep', validating: r.validating, committed: r.committed, resent: r.resent, gave_up: r.gaveUp, oldest_seconds: r.oldestSeconds }));
};
