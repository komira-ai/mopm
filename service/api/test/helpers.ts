import { DeleteCommand, GetCommand, PutCommand, QueryCommand, ScanCommand, TransactWriteCommand } from '@aws-sdk/lib-dynamodb';
import { canonicalVersion } from '../src/version';

const safeCanonical = (v: string) => {
  try {
    return canonicalVersion(v);
  } catch {
    return v; // deliberately invalid versions are used to test refusal
  }
};
import type { AuditEntry, VersionRecord } from '../src/types';

export const hex = (c: string) => c.repeat(64);

export function rec(over: Partial<VersionRecord> & { name: string; version: string }): VersionRecord {
  const build = over.build ?? 'mojo1.0.0_0';
  return {
    canonical: safeCanonical(over.version),
    build,
    state: 'published',
    published_at: '2026-10-13T12:00:00Z',
    requires_mojo: '==1.0.0',
    deps: [],
    native: [],
    files: [
      {
        subdir: 'linux-64',
        filename: `mojo-${over.name}-${over.version}-${build}.conda`,
        sha256: hex('a'),
        size: 1000,
        url: `https://conda.example.invalid/linux-64/mojo-${over.name}-${over.version}-${build}.conda`,
      },
    ],
    manifest_sha256: hex('f'),
    rev: 0,
    ...over,
  };
}

let seq = 0;
export const audit = (name: string, action: string, version?: string): AuditEntry => ({
  name,
  ts: '2026-10-13T12:00:00Z',
  id: `id${String(++seq).padStart(6, '0')}`,
  actor: 'test',
  action,
  version,
});

type Item = Record<string, any>;
interface KeyDef {
  pk: string;
  sk?: string;
}

const KEYS: Record<string, KeyDef> = {
  'mopm-t-packages': { pk: 'name' },
  'mopm-t-versions': { pk: 'name', sk: 'version' },
  'mopm-t-owners': { pk: 'name', sk: 'github_id' },
  'mopm-t-audit': { pk: 'name', sk: 'ts_seq' },
  // The publish pipeline's table (single-attribute key); the store reads the group items in it.
  'mopm-t-publishes': { pk: 'publish_id' },
};

/**
 * The one global secondary index the adapter reads, written out as the stack defines it (service/infra/stacks/lib/data-stack.ts,
 * pinned there by data.test.ts). Deliberately literals, not SEARCH_INDEX: store.test.ts asserts the adapter's constant equals this.
 */
const INDEXES: Record<string, Record<string, { pk: string; sk: string; projected: readonly string[] }>> = {
  'mopm-t-packages': { by_search_bucket: { pk: 'search_bucket', sk: 'name', projected: ['description', 'state', 'created_at'] } },
  // The sweeper's sparse index of groups that are not over (the stacks' data stack defines it): the table's own key is always projected too.
  'mopm-t-publishes': { by_sweep: { pk: 'sweep_pk', sk: 'sweep_at', projected: ['publish_id', 'status', 'attempt', 'actor', 'rev', 'progress_at', 'deadline_at', 'resend'] } },
};

/**
 * An in-process stand-in for DynamoDBDocumentClient.send, with no network. It implements what the
 * adapter uses: Get, Put, Delete, Query and Scan (paged, `pageSize` items at a time), and
 * TransactWrite (all conditions checked, then all writes, atomically). Query also runs on the packages search
 * index: `#b = :b` with an optional `AND begins_with(#n, :p)` on the sort key, a sparse index (rows without the
 * key attribute are absent), `Limit`, `ExclusiveStartKey`, and the index's projection (only its keys and projected
 * attributes come back). Conditions: `attribute_exists(#x)`,
 * `attribute_not_exists(#x)` and `#x = :v`, joined by AND. Anything else throws, so a new expression
 * in the adapter fails loudly here instead of being silently accepted.
 *
 * Every call first yields `yields` event-loop turns, so concurrent callers interleave before the atomic
 * section, like requests in flight to a real table.
 */
export class FakeDocClient {
  tables = new Map<string, Map<string, Item>>();
  calls: string[] = [];
  /** Every command's input, in order, so a test can assert exactly what was asked of DynamoDB. */
  inputs: any[] = [];
  constructor(
    private pageSize = 2,
    private yields = 4,
  ) {
    for (const t of Object.keys(KEYS)) this.tables.set(t, new Map());
  }

  private keyOf(table: string, item: Item): string {
    const k = KEYS[table]!;
    return `${item[k.pk]}\u0000${k.sk ? item[k.sk] : ''}`;
  }
  private table(name: string) {
    const t = this.tables.get(name);
    if (!t) throw new Error(`fake: no table ${name}`);
    return t;
  }

  private check(cond: string | undefined, names: Record<string, string> = {}, values: Record<string, any> = {}, existing?: Item): boolean {
    if (!cond) return true;
    return cond.split(' AND ').every((raw) => {
      const clause = raw.trim();
      let m = /^attribute_not_exists\((#\w+)\)$/.exec(clause);
      if (m) return !(existing && names[m[1]!]! in existing);
      m = /^attribute_exists\((#\w+)\)$/.exec(clause);
      if (m) return !!existing && names[m[1]!]! in existing;
      const eq = /^(#\w+) = (:\w+)$/.exec(clause);
      if (eq) return !!existing && existing[names[eq[1]!]!] === values[eq[2]!];
      throw new Error(`fake: unsupported condition ${clause}`);
    });
  }

  async send(cmd: any): Promise<any> {
    for (let i = 0; i < this.yields; i++) await Promise.resolve();
    this.calls.push(cmd.constructor.name);
    this.inputs.push(structuredClone(cmd.input));
    if (cmd instanceof GetCommand) {
      const { TableName, Key } = cmd.input;
      const item = this.table(TableName!).get(this.keyOf(TableName!, Key!));
      return { Item: item && structuredClone(item) };
    }
    if (cmd instanceof PutCommand) {
      const { TableName, Item, ConditionExpression, ExpressionAttributeNames, ExpressionAttributeValues } = cmd.input;
      const t = this.table(TableName!);
      const key = this.keyOf(TableName!, Item!);
      if (!this.check(ConditionExpression, ExpressionAttributeNames, ExpressionAttributeValues, t.get(key))) {
        throw Object.assign(new Error('The conditional request failed'), { name: 'ConditionalCheckFailedException' });
      }
      t.set(key, structuredClone(Item!));
      return {};
    }
    if (cmd instanceof DeleteCommand) {
      const { TableName, Key, ConditionExpression, ExpressionAttributeNames } = cmd.input;
      const t = this.table(TableName!);
      const key = this.keyOf(TableName!, Key!);
      if (!this.check(ConditionExpression, ExpressionAttributeNames, undefined, t.get(key))) {
        throw Object.assign(new Error('The conditional request failed'), { name: 'ConditionalCheckFailedException' });
      }
      t.delete(key);
      return {};
    }
    if (cmd instanceof TransactWriteCommand) {
      const items = cmd.input.TransactItems!;
      const reasons = items.map((it) => {
        const p = it.Put!;
        const ok = this.check(p.ConditionExpression, p.ExpressionAttributeNames, p.ExpressionAttributeValues, this.table(p.TableName!).get(this.keyOf(p.TableName!, p.Item!)));
        return { Code: ok ? 'None' : 'ConditionalCheckFailed' };
      });
      if (reasons.some((r) => r.Code !== 'None')) {
        throw Object.assign(new Error('Transaction cancelled'), { name: 'TransactionCanceledException', CancellationReasons: reasons });
      }
      for (const it of items) this.table(it.Put!.TableName!).set(this.keyOf(it.Put!.TableName!, it.Put!.Item!), structuredClone(it.Put!.Item!));
      return {};
    }
    if (cmd instanceof QueryCommand && cmd.input.IndexName) return this.queryIndex(cmd.input);
    if (cmd instanceof QueryCommand) {
      const { TableName, ExpressionAttributeValues, ExclusiveStartKey } = cmd.input;
      const k = KEYS[TableName!]!;
      const pkValue = ExpressionAttributeValues![':n'];
      const all = [...this.table(TableName!).values()].filter((i) => i[k.pk] === pkValue);
      return this.page(TableName!, all, ExclusiveStartKey);
    }
    if (cmd instanceof ScanCommand) {
      const { TableName, ExclusiveStartKey } = cmd.input;
      return this.page(TableName!, [...this.table(TableName!).values()], ExclusiveStartKey);
    }
    throw new Error(`fake: unsupported command ${cmd.constructor.name}`);
  }

  private queryIndex(input: any) {
    const { TableName, IndexName, KeyConditionExpression, ExpressionAttributeNames: n = {}, ExpressionAttributeValues: v = {}, Limit, ExclusiveStartKey } = input;
    const ix = INDEXES[TableName]?.[IndexName];
    if (!ix) throw new Error(`fake: no index ${IndexName} on ${TableName}`);
    const m = /^(#\w+) = (:\w+)(?: AND begins_with\((#\w+), (:\w+)\))?$/.exec(KeyConditionExpression);
    if (!m) throw new Error(`fake: unsupported key condition ${KeyConditionExpression}`);
    if (n[m[1]!] !== ix.pk) throw new Error(`fake: the partition key of ${IndexName} is ${ix.pk}, not ${n[m[1]!]}`);
    if (m[3] && n[m[3]] !== ix.sk) throw new Error(`fake: begins_with must be on the sort key ${ix.sk}`);
    if (m[4] !== undefined && (typeof v[m[4]] !== 'string' || v[m[4]] === '')) throw new Error('fake: DynamoDB refuses an empty or non-string begins_with operand');
    if (!Number.isInteger(Limit) || Limit < 1) throw new Error('fake: Limit must be a positive integer');
    const bucket = v[m[2]!];
    const prefix = m[4] ? (v[m[4]] as string) : '';
    if (ExclusiveStartKey) {
      if (ExclusiveStartKey[ix.pk] !== bucket || typeof ExclusiveStartKey[ix.sk] !== 'string' || !ExclusiveStartKey[ix.sk].startsWith(prefix)) {
        throw new Error('fake: the starting key is outside the query boundaries');
      }
    }
    // Items with the same sort value are ordered by the table's own key, and a page boundary names it too, as DynamoDB's does.
    const tableKey = KEYS[TableName]!;
    const order = (a: Item, b: Item) => {
      if (a[ix.sk] !== b[ix.sk]) return a[ix.sk] < b[ix.sk] ? -1 : 1;
      const [ka, kb] = [this.keyOf(TableName, a), this.keyOf(TableName, b)];
      return ka < kb ? -1 : ka > kb ? 1 : 0;
    };
    const rows = [...this.table(TableName).values()].filter((i) => i[ix.pk] === bucket && ix.sk in i && (i[ix.sk] as string).startsWith(prefix)).sort(order);
    const from = ExclusiveStartKey ? rows.findIndex((i) => order(i, ExclusiveStartKey) > 0) : 0;
    const rest = from < 0 ? [] : rows.slice(from);
    const take = Math.min(Limit, this.pageSize);
    const slice = rest.slice(0, take);
    const keep = new Set([ix.pk, ix.sk, ...ix.projected]);
    const last = slice[slice.length - 1];
    return {
      Items: slice.map((i) => Object.fromEntries(Object.entries(structuredClone(i)).filter(([k]) => keep.has(k)))),
      // A page ended by Limit or by size reports where to continue, as DynamoDB does.
      LastEvaluatedKey: rest.length > take && last ? { [ix.pk]: last[ix.pk], [ix.sk]: last[ix.sk], [tableKey.pk]: last[tableKey.pk], ...(tableKey.sk ? { [tableKey.sk]: last[tableKey.sk] } : {}) } : undefined,
    };
  }

  private page(table: string, items: Item[], start?: Item) {
    const k = KEYS[table]!;
    const sorted = items.sort((a, b) => (this.keyOf(table, a) < this.keyOf(table, b) ? -1 : 1));
    const from = start ? sorted.findIndex((i) => this.keyOf(table, i) === this.keyOf(table, start)) + 1 : 0;
    const slice = sorted.slice(from, from + this.pageSize);
    const more = from + this.pageSize < sorted.length;
    const last = slice[slice.length - 1];
    return {
      Items: structuredClone(slice),
      LastEvaluatedKey: more && last ? { [k.pk]: last[k.pk], ...(k.sk ? { [k.sk]: last[k.sk] } : {}) } : undefined,
    };
  }
}

/**
 * The variant for the race proof: create-once done as read-then-write, with no condition. It looks
 * right in a single-threaded test and loses the race.
 */
export class NaiveCreate {
  constructor(private doc: FakeDocClient) {}
  async createVersion(r: VersionRecord): Promise<'created' | 'exists'> {
    const key = { name: r.name, version: canonicalVersion(r.version) };
    const got = await this.doc.send(new GetCommand({ TableName: 'mopm-t-versions', Key: key }));
    if (got.Item) return 'exists';
    await this.doc.send(new PutCommand({ TableName: 'mopm-t-versions', Item: { ...r, ...key } }));
    return 'created';
  }
}

/** Run the same writer over the records in several orders and report whether all outputs are identical. */
export function isDeterministic<R>(write: (records: R[]) => string, records: R[]): boolean {
  const orders = [records, [...records].reverse(), rotate(records, 1), rotate(records, 2)];
  const outs = new Set(orders.map(write));
  return outs.size === 1 && write(records) === write(records);
}
const rotate = <T>(a: T[], n: number) => (a.length ? [...a.slice(n % a.length), ...a.slice(0, n % a.length)] : a);
