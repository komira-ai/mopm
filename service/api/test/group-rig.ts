import { GetCommand } from '@aws-sdk/lib-dynamodb';
import { DynamoStore, tablesFor } from '../src/dynamo-store';
import { headerKey, type FunnelOptions } from '../src/group';
import type { GroupStore } from '../src/group-store';
import { MemoryStore } from '../src/memory-store';
import { Metrics } from '../src/metrics';
import type { RawVersionPort } from '../src/raw-port';
import type { Store } from '../src/store';
import type { VersionRecord } from '../src/types';
import { audit, FakeDocClient, rec } from './helpers';

/**
 * Both store adapters behind one handle, with what the group tests need that the Store port does not offer: write a
 * row exactly as given (the stored form, group fields included), put a group item, see which group items were read,
 * run code just before a group item is read (to interleave a writer with a paused reader) and make group reads fail.
 */
export interface Rig {
  label: string;
  store: Store & GroupStore & { raw: RawVersionPort };
  /** The fake DynamoDB client under the store (the DynamoDB rig only): to see exactly what was sent, and to interleave writers. */
  doc?: FakeDocClient;
  /** Log lines of the funnel (errors, with the group id). */
  logs: Array<Record<string, unknown>>;
  /** The embedded-metric lines the funnel emitted. */
  lines: Array<Record<string, unknown>>;
  /** Replace or create a version row as it is to be stored. */
  writeRow(r: VersionRecord): void;
  /** Put an item of the `publishes` table (`grp#...` or `grpm#...`), keyed by its first argument. */
  putGroupItem(key: string, item: Record<string, unknown>): void;
  /** Keys of the group items read so far, in order. */
  groupReads(): string[];
  /** Run `fn` before every group item read (null removes it). */
  beforeGroupRead(fn: ((key: string) => Promise<void> | void) | null): void;
  /** Make every group item read fail with `err` (undefined: stop failing). */
  failGroupReads(err: Error | undefined): void;
  /** Claim a package name, so the package list and search see it. */
  claim(name: string): Promise<void>;
  /** The names of the metrics emitted, flattened. */
  metricNames(): string[];
  /** The latest value of a metric, summed over all lines. */
  metricTotal(name: string): number;
}

type Hook = ((key: string) => Promise<void> | void) | null;

function common(label: string, store: Rig['store'], logs: Rig['logs'], lines: Rig['lines']): Pick<Rig, 'label' | 'store' | 'logs' | 'lines' | 'claim' | 'metricNames' | 'metricTotal'> {
  return {
    label,
    store,
    logs,
    lines,
    claim: (name) => store.createPackage({ name, state: 'active', created_at: '2026-10-13T00:00:00Z' }),
    metricNames: () => lines.flatMap((l) => (l._aws as { CloudWatchMetrics: Array<{ Metrics: Array<{ Name: string }> }> }).CloudWatchMetrics.flatMap((c) => c.Metrics.map((m) => m.Name))),
    metricTotal: (name) => lines.reduce((n, l) => n + (typeof l[name] === 'number' ? (l[name] as number) : 0), 0),
  };
}

export function memoryRig(opts: FunnelOptions = {}): Rig {
  const logs: Rig['logs'] = [];
  const lines: Rig['lines'] = [];
  const store = new MemoryStore(undefined, { log: (l) => logs.push(l), metrics: new Metrics((l) => lines.push(l)), ...opts });
  let hook: Hook = null;
  const header = store.groups.header.bind(store.groups);
  const members = store.groups.members.bind(store.groups);
  store.groups.header = async (gid) => {
    await hook?.(`grp#${gid}`);
    return header(gid);
  };
  store.groups.members = async (gid) => {
    await hook?.(`grpm#${gid}`);
    return members(gid);
  };
  return {
    ...common('memory', store, logs, lines),
    writeRow: (r) => (store as unknown as { versions: Map<string, VersionRecord> }).versions.set(`${r.name}\0${r.canonical}`, structuredClone(r)),
    putGroupItem: (key, item) => store.groups.put(key, item),
    groupReads: () => [...store.groups.reads],
    beforeGroupRead: (fn) => {
      hook = fn;
    },
    failGroupReads: (err) => {
      store.groups.failure = err;
    },
  };
}

export function dynamoRig(opts: FunnelOptions = {}): Rig {
  const logs: Rig['logs'] = [];
  const lines: Rig['lines'] = [];
  const doc = new FakeDocClient();
  const store = new DynamoStore(doc, tablesFor('t'), { log: (l) => logs.push(l), metrics: new Metrics((l) => lines.push(l)), ...opts });
  let hook: Hook = null;
  let failure: Error | undefined;
  const send = doc.send.bind(doc);
  doc.send = async (cmd: { input?: { TableName?: string; Key?: { publish_id?: string } } }) => {
    if (cmd instanceof GetCommand && cmd.input?.TableName === 'mopm-t-publishes') {
      await hook?.(cmd.input.Key!.publish_id!);
      if (failure) throw failure;
    }
    return send(cmd);
  };
  return {
    ...common('dynamodb (fake client)', store, logs, lines),
    doc,
    writeRow: (r) => {
      const { canonical, version, ...rest } = r;
      doc.tables.get('mopm-t-versions')!.set(`${r.name}\u0000${canonical}`, { ...rest, version: canonical, version_spelling: version });
    },
    putGroupItem: (key, item) => {
      // The fake keys a single-attribute table by the key value and an empty sort part.
      doc.tables.get('mopm-t-publishes')!.set(`${key}\u0000`, { ...structuredClone(item), publish_id: key });
    },
    groupReads: () => doc.inputs.filter((i) => i.TableName === 'mopm-t-publishes' && i.Key).map((i) => i.Key.publish_id as string),
    beforeGroupRead: (fn) => {
      hook = fn;
    },
    failGroupReads: (err) => {
      failure = err;
    },
  };
}

export const RIGS: Array<[string, (opts?: FunnelOptions) => Rig]> = [
  ['memory', memoryRig],
  ['dynamodb (fake client)', dynamoRig],
];

// --- fixtures ----------------------------------------------------------------------------------------------------

export const COMMITTED_AT = '2026-10-14T09:00:00Z';

/** A group member row as the writer leaves it once staged: pending, filled, stamped with the attempt. */
export const staged = (name: string, gid: string, attempt = 1, over: Partial<VersionRecord> = {}): VersionRecord =>
  rec({ name, version: '1.0.0', state: 'pending', group_id: gid, staged_attempt: attempt, rev: 1, published_by: 'octocat', ...over });

/** A group member row as reserved: pending, named by the group, nothing filled, no stamp. */
export const reserved = (name: string, gid: string, over: Partial<VersionRecord> = {}): VersionRecord =>
  rec({ name, version: '1.0.0', state: 'pending', group_id: gid, rev: 0, build: '', requires_mojo: '', files: [], ...over });

/** A member row after the flip. */
export const flipped = (name: string, gid: string, attempt = 1): VersionRecord => rec({ name, version: '1.0.0', state: 'published', group_id: gid, staged_attempt: attempt, rev: 2, published_at: COMMITTED_AT });

export const header = (over: Record<string, unknown> = {}) => ({ status: 'committed', attempt: 1, committed_at: COMMITTED_AT, rev: 3, ...over });
/** A member is a package name (version 1.0.0) or a `[name, version]` pair. */
export type MemberSpec = string | [string, string];
export const memberList = (...ms: MemberSpec[]) => ({
  members: ms.map((m) => {
    const [name, version] = typeof m === 'string' ? [m, '1.0.0'] : m;
    return { name, version, canonical: version, subdirs: ['linux-64'] };
  }),
});

/** Put a group's header (none when null) and member list, and write the given rows. */
export function seedGroup(r: Rig, gid: string, h: Record<string, unknown> | null, names: MemberSpec[], rows: VersionRecord[]): void {
  if (h) r.putGroupItem(headerKey(gid), h);
  r.putGroupItem(`grpm#${gid}`, memberList(...names));
  for (const row of rows) r.writeRow(row);
}

export const auditOf = (name: string) => audit(name, 'seed', '1.0.0');
