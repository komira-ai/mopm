import { flipGroup, type FlipOutcome } from '../../src/publish/group-chain';
import { yankRows, type YankRowsOutcome } from '../../src/publish/group-yank';
import { parseIndexMessage, processIndexMessage, type IndexerDeps } from '../../src/publish/indexer';
import { MemoryInvalidator } from '../../src/publish/memory';
import type { QueueMessage } from '../../src/publish/ports';
import type { FlipGroupMessage, IndexQueueMessage, YankGroupMessage } from '../../src/publish/types';
import type { GroupEnv } from './group-env';

/** A message of the chain as it ran: which queue carried it, and what it said. */
export type Ran =
  | { queue: 'index'; message: IndexQueueMessage; raw: QueueMessage }
  | { queue: 'group'; message: FlipGroupMessage; raw: QueueMessage; outcome: FlipOutcome }
  /** The rows of a group yank or unyank (src/publish/group-yank.ts), which the group queue also carries. */
  | { queue: 'yank'; message: YankGroupMessage; raw: QueueMessage; outcome: YankRowsOutcome };

/**
 * The messages that follow a group's commit, run the way the two Lambdas run them: the index writer takes the index queue, the
 * group validator's flip takes the group queue. The queues are the environment's (FIFO fakes that honour dedup ids), so a message
 * a test takes off a queue and does not run is a message the queue lost.
 */
export class Chain {
  readonly invalidator = new MemoryInvalidator();
  readonly ensured = new Set<string>();
  readonly log: Array<Record<string, unknown>> = [];

  constructor(readonly env: GroupEnv) {}

  /** The deps of the index writer on the environment's ports, group chain included. */
  indexerDeps(over: Partial<IndexerDeps> = {}): IndexerDeps {
    return {
      registry: this.env.rig.store,
      groups: this.env.rig.store,
      publishes: this.env.publishes,
      objects: this.env.objects,
      invalidator: this.invalidator,
      indexQueue: this.env.indexQueue,
      groupQueue: this.env.groupQueue,
      now: this.env.clock.now,
      log: (l) => this.log.push(l),
      ensured: this.ensured,
      ...over,
    };
  }

  /** Run one message of the index queue. */
  async runIndex(raw: QueueMessage, over: Partial<IndexerDeps> = {}): Promise<IndexQueueMessage> {
    const message = parseIndexMessage(JSON.parse(raw.body));
    if (!message) throw new Error(`the index writer was given a message it does not understand: ${raw.body}`);
    await processIndexMessage(this.indexerDeps(over), message);
    return message;
  }

  /** Run one message of the group queue, which after a commit is only ever the flip. */
  async runFlip(raw: QueueMessage): Promise<FlipGroupMessage & { outcome: FlipOutcome }> {
    const message = JSON.parse(raw.body) as FlipGroupMessage;
    if (message.type !== 'flip_group') throw new Error(`the group queue carried ${raw.body}`);
    const outcome = await flipGroup({ groups: this.env.rig.store, indexQueue: this.env.indexQueue, groupQueue: this.env.groupQueue, now: this.env.clock.now, log: (l) => this.log.push(l) }, message);
    return { ...message, outcome };
  }

  /** Run one `yank_group` message of the group queue, the way the group validator's Lambda does. */
  async runYank(raw: QueueMessage): Promise<YankGroupMessage & { outcome: YankRowsOutcome }> {
    const message = JSON.parse(raw.body) as YankGroupMessage;
    if (message.type !== 'yank_group') throw new Error(`the group queue carried ${raw.body}`);
    const outcome = await yankRows({ groups: this.env.rig.store, indexQueue: this.env.indexQueue, groupQueue: this.env.groupQueue, now: this.env.clock.now, log: (l) => this.log.push(l) }, message);
    return { ...message, outcome };
  }

  /** The next message of the chain (the index queue first), run; undefined when both queues are empty. */
  async step(): Promise<Ran | undefined> {
    const index = this.env.indexQueue.take();
    if (index) return { queue: 'index', message: await this.runIndex(index), raw: index };
    const flip = this.env.groupQueue.take();
    if (flip && (JSON.parse(flip.body) as { type: string }).type === 'yank_group') {
      const ran = await this.runYank(flip);
      const { outcome, ...message } = ran;
      return { queue: 'yank', message, raw: flip, outcome };
    }
    if (flip) {
      const ran = await this.runFlip(flip);
      return { queue: 'group', message: { type: 'flip_group', group_id: ran.group_id, attempt: ran.attempt, resend: ran.resend }, raw: flip, outcome: ran.outcome };
    }
    return undefined;
  }

  /** Run messages until both queues are empty; `after` runs after each one. Returns what ran, in order. */
  async drain(after?: (ran: Ran) => Promise<void> | void, limit = 200): Promise<Ran[]> {
    const out: Ran[] = [];
    for (let ran = await this.step(); ran; ran = await this.step()) {
      out.push(ran);
      if (out.length > limit) throw new Error(`the chain did not end in ${limit} messages`);
      await after?.(ran);
    }
    return out;
  }
}

/** What a message of the chain was for, in a few words: `repodata linux-64`, `index base`, `flip`. */
export function label(r: Ran): string {
  if (r.queue === 'group') return 'flip';
  if (r.queue === 'yank') return `rows ${r.message.op}`;
  const m = r.message;
  if (m.type === 'index') return `repodata ${m.subdir}`;
  if (m.type === 'index_pkg') return `index ${m.name}`;
  return 'takedowns';
}
