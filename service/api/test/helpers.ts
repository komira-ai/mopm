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
};

/**
 * An in-process stand-in for DynamoDBDocumentClient.send, with no network. It implements what the
 * adapter uses: Get, Put, Delete, Query and Scan (paged, `pageSize` items at a time), and
 * TransactWrite (all conditions checked, then all writes, atomically). Conditions: `attribute_exists(#x)`,
 * `attribute_not_exists(#x)` and `#x = :v`, joined by AND. Anything else throws, so a new expression
 * in the adapter fails loudly here instead of being silently accepted.
 *
 * Every call first yields `yields` event-loop turns, so concurrent callers interleave before the atomic
 * section, like requests in flight to a real table.
 */
export class FakeDocClient {
  tables = new Map<string, Map<string, Item>>();
  calls: string[] = [];
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
 * The mutant for the race proof: create-once done as read-then-write, with no condition. It looks
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
