import { DynamoStore, tablesFor } from '../dynamo-store';
import { SqsQueueDepth } from '../publish/aws';
import { documentClient, regionOf } from '../publish/wiring';
import { parseOpsArgs, runOps, type OpsArgs, type OpsDeps } from './group-ops';

/**
 * The entry point of the operator's tool (see group-ops.ts), bundled to dist/ops/group-ops-main.js. It builds the real
 * adapters from the flags and the AWS credentials of the environment, and nothing else: the behaviour is in group-ops.ts,
 * which is what the tests run.
 */

/** The stage's queues, by the names the stacks give them (service/infra/stacks/lib/config.ts). */
export const QUEUES = ['validate', 'index', 'group', 'validate-dlq', 'index-dlq', 'group-dlq'];

/** The adapters for a stage. */
export function realDeps(args: OpsArgs): OpsDeps {
  if (args.stage !== 'beta' && args.stage !== 'gamma' && args.stage !== 'prod') throw new Error('--stage is beta, gamma or prod');
  const stage = args.stage;
  const depth = new SqsQueueDepth({ region: args.region ?? regionOf({}) });
  return {
    groups: new DynamoStore(documentClient(), tablesFor(stage)),
    queueDepth: () => Promise.all(QUEUES.map((q) => depth.depth(`mopm-${stage}-${q}.fifo`))),
    out: (line) => console.log(JSON.stringify(line)),
  };
}

/** Parse, run, and turn a failure into a message and a status. `build` makes the adapters (the tests give fakes). */
export async function main(argv: readonly string[], build: (args: OpsArgs) => OpsDeps = realDeps): Promise<number> {
  try {
    const args = parseOpsArgs(argv);
    return await runOps(args, build(args));
  } catch (err) {
    console.error(String((err as Error)?.message ?? err));
    return 1;
  }
}
