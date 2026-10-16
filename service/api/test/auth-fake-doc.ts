import * as fs from 'fs';
import * as path from 'path';
import { DeleteCommand, GetCommand, PutCommand, QueryCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';

type Item = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

export interface Grant {
  actions: string[];
  indexes?: string[];
}
/**
 * What the Lambda's role may do on the auth tables, by table (without the `mopm-<stage>-` prefix). The stacks test
 * (service/infra/stacks/test/api.test.ts) asserts that AUTH_GRANTS in api-stack.ts equals this file, so the adapter
 * tests run under exactly the permissions the deployed role has. There is no other grant list: the double must never be
 * broader than the role (auth-fake-grants.test.ts).
 */
export const LAMBDA_GRANTS: Record<string, Grant> = JSON.parse(
  fs.readFileSync(path.join(__dirname, 'fixtures/lambda-auth-grants.json'), 'utf8'),
);
interface TableDef {
  pk: string;
  sk?: string;
  ttl?: string;
  gsis?: Record<string, { pk: string; sk?: string }>;
}
/** Mirrors service/infra/stacks/lib/data-stack.ts (keys, TTL attribute, indexes). */
const DEFS: Record<string, TableDef> = {
  users: { pk: 'github_id' },
  tokens: { pk: 'token_hash', ttl: 'expires_at', gsis: { by_github_id: { pk: 'github_id', sk: 'id' } } },
  device_logins: { pk: 'id', ttl: 'expires_at' },
  trusted_publishers: { pk: 'name', sk: 'publisher' },
  owners: { pk: 'name', sk: 'github_id', gsis: { by_github_id: { pk: 'github_id', sk: 'name' } } },
};

const KEYWORDS = new Set(['SET', 'REMOVE', 'AND', 'attribute_exists', 'attribute_not_exists']);
const denied = () => Object.assign(new Error('not authorized'), { name: 'AccessDeniedException' });
const validation = (m: string) => Object.assign(new Error(m), { name: 'ValidationException' });
const conditionFailed = () => Object.assign(new Error('The conditional request failed'), { name: 'ConditionalCheckFailedException' });

/**
 * An in-process stand-in for DynamoDBDocumentClient.send, no network, for the auth adapter. It is strict where
 * DynamoDB is, so a mistake the real service would reject fails here:
 * - every attribute name in an expression is an alias (`#x`): a bare name (a reserved word like `name`) is refused,
 *   and so is an alias or value that no expression uses;
 * - key attributes, and index key attributes, must be strings; the TTL attribute must be a number;
 * - a strongly consistent read of an index is refused;
 * - with `grants`, a command the role is not allowed to make answers AccessDeniedException (DeleteItem is never
 *   granted; table and index are separate resources).
 * Supports Get, Put, Update (SET, REMOVE), Delete, Query (table or index; key condition `#a = :a [AND #b = :b]`),
 * paged `pageSize` items at a time. Conditions: attribute_exists, attribute_not_exists, joined by AND.
 */
export class FakeAuthDoc {
  tables = new Map<string, Map<string, Item>>();
  commands: string[] = [];
  constructor(
    private readonly o: { stage?: string; grants?: Record<string, Grant>; pageSize?: number; yields?: number } = {},
  ) {
    for (const t of Object.keys(DEFS)) this.tables.set(this.full(t), new Map());
  }
  private full = (t: string) => `mopm-${this.o.stage ?? 't'}-${t}`;
  private short = (full: string) => full.replace(/^mopm-[a-z]+-/, '');
  private def(table: string): TableDef {
    const d = DEFS[this.short(table)];
    if (!d) throw new Error(`fake: no table ${table}`);
    return d;
  }
  private rows(table: string) {
    return this.tables.get(table)!;
  }
  private keyOf(d: TableDef, item: Item) {
    return `${item[d.pk]}\u0000${d.sk ? item[d.sk] : ''}`;
  }

  private authorize(action: string, table: string, index?: string) {
    const g = this.o.grants;
    if (!g) return;
    const grant = g[this.short(table)];
    if (!grant || !grant.actions.includes(action)) throw denied();
    if (index !== undefined && !(grant.indexes ?? []).includes(index)) throw denied();
  }

  private checkItem(d: TableDef, item: Item) {
    for (const k of [d.pk, d.sk, ...Object.values(d.gsis ?? {}).flatMap((g) => [g.pk, g.sk])]) {
      if (k && item[k] !== undefined && typeof item[k] !== 'string') throw validation(`key attribute ${k} must be a string`);
    }
    if (item[d.pk] === undefined || (d.sk && item[d.sk] === undefined)) throw validation('the item lacks its key');
    if (d.ttl && item[d.ttl] !== undefined && typeof item[d.ttl] !== 'number') throw validation(`TTL attribute ${d.ttl} must be a number`);
  }

  /** Every `#alias` and `:value` of the expressions is used, every name in them is an alias or a keyword. */
  private checkExpressions(c: { exprs: (string | undefined)[]; names?: Record<string, string>; values?: Record<string, unknown> }) {
    const text = c.exprs.filter(Boolean).join(' ');
    const bare = text.replace(/[#:]\w+/g, ' ').match(/[A-Za-z_]\w*/g) ?? [];
    for (const w of bare) if (!KEYWORDS.has(w)) throw validation(`Attribute name is a reserved keyword or not aliased: ${w}`);
    for (const n of Object.keys(c.names ?? {})) if (!new RegExp(`${n}\\b`).test(text)) throw validation(`unused ExpressionAttributeNames ${n}`);
    for (const v of Object.keys(c.values ?? {})) if (!new RegExp(`${v}\\b`).test(text)) throw validation(`unused ExpressionAttributeValues ${v}`);
  }

  private holds(cond: string | undefined, names: Record<string, string> = {}, existing?: Item): boolean {
    if (!cond) return true;
    return cond.split(' AND ').every((raw) => {
      const clause = raw.trim();
      let m = /^attribute_not_exists\((#\w+)\)$/.exec(clause);
      if (m) return !(existing && names[m[1]!]! in existing);
      m = /^attribute_exists\((#\w+)\)$/.exec(clause);
      if (m) return !!existing && names[m[1]!]! in existing;
      throw new Error(`fake: unsupported condition ${clause}`);
    });
  }

  async send(cmd: any): Promise<any> {
    for (let i = 0; i < (this.o.yields ?? 2); i++) await Promise.resolve();
    this.commands.push(cmd.constructor.name);
    if (cmd instanceof GetCommand) {
      const { TableName, Key } = cmd.input;
      this.authorize('dynamodb:GetItem', TableName!);
      const d = this.def(TableName!);
      return { Item: structuredClone(this.rows(TableName!).get(this.keyOf(d, Key!))) };
    }
    if (cmd instanceof PutCommand) {
      const { TableName, Item, ConditionExpression, ExpressionAttributeNames, ExpressionAttributeValues } = cmd.input;
      this.authorize('dynamodb:PutItem', TableName!);
      const d = this.def(TableName!);
      this.checkExpressions({ exprs: [ConditionExpression], names: ExpressionAttributeNames, values: ExpressionAttributeValues });
      this.checkItem(d, Item!);
      const key = this.keyOf(d, Item!);
      if (!this.holds(ConditionExpression, ExpressionAttributeNames, this.rows(TableName!).get(key))) throw conditionFailed();
      this.rows(TableName!).set(key, structuredClone(Item!));
      return {};
    }
    if (cmd instanceof UpdateCommand) {
      const { TableName, Key, UpdateExpression, ConditionExpression, ExpressionAttributeNames: n = {}, ExpressionAttributeValues: v = {} } = cmd.input;
      this.authorize('dynamodb:UpdateItem', TableName!);
      const d = this.def(TableName!);
      this.checkExpressions({ exprs: [UpdateExpression, ConditionExpression], names: n, values: v });
      const key = this.keyOf(d, Key!);
      const existing = this.rows(TableName!).get(key);
      if (!this.holds(ConditionExpression, n, existing)) throw conditionFailed();
      const m = /^SET (.+?)(?: REMOVE (.+))?$/.exec(UpdateExpression!) ?? /^()REMOVE (.+)$/.exec(UpdateExpression!);
      if (!m) throw new Error(`fake: unsupported update ${UpdateExpression}`);
      const next: Item = existing ? structuredClone(existing) : { ...Key! };
      for (const part of (m[1] ?? '').split(',').filter((x) => x.trim())) {
        const a = /^\s*(#\w+) = (:\w+)\s*$/.exec(part);
        if (!a) throw new Error(`fake: unsupported SET ${part}`);
        next[n[a[1]!]!] = structuredClone(v[a[2]!]);
      }
      for (const part of (m[2] ?? '').split(',').filter((x) => x.trim())) delete next[n[part.trim()]!];
      this.checkItem(d, next);
      this.rows(TableName!).set(key, next);
      return {};
    }
    if (cmd instanceof DeleteCommand) {
      const { TableName, Key } = cmd.input;
      this.authorize('dynamodb:DeleteItem', TableName!);
      this.rows(TableName!).delete(this.keyOf(this.def(TableName!), Key!));
      return {};
    }
    if (cmd instanceof QueryCommand) {
      const { TableName, IndexName, KeyConditionExpression, ExpressionAttributeNames: n = {}, ExpressionAttributeValues: v = {}, ExclusiveStartKey, ConsistentRead } = cmd.input;
      this.authorize('dynamodb:Query', TableName!, IndexName);
      const d = this.def(TableName!);
      this.checkExpressions({ exprs: [KeyConditionExpression], names: n, values: v });
      const idx = IndexName ? d.gsis?.[IndexName] : undefined;
      if (IndexName && !idx) throw validation(`no index ${IndexName}`);
      if (idx && ConsistentRead) throw validation('Consistent reads are not supported on global secondary indexes');
      const pk = idx ? idx.pk : d.pk;
      const sk = idx ? idx.sk : d.sk;
      const conds = KeyConditionExpression!.split(' AND ').map((c) => {
        const m = /^(#\w+) = (:\w+)$/.exec(c.trim());
        if (!m) throw new Error(`fake: unsupported key condition ${c}`);
        return [n[m[1]!]!, v[m[2]!]] as const;
      });
      if (conds[0]![0] !== pk) throw validation('Query condition missed key schema element');
      if (conds.length === 2 && conds[1]![0] !== sk) throw validation('Query condition missed key schema element');
      const order = (i: Item) => `${i[pk]}\u0000${sk ? i[sk] ?? '' : ''}\u0000${this.keyOf(d, i)}`;
      const all = [...this.rows(TableName!).values()]
        .filter((i) => conds.every(([a, val]) => i[a] === val) && (!idx || (i[idx.pk] !== undefined && (!idx.sk || i[idx.sk] !== undefined))))
        .sort((a, b) => (order(a) < order(b) ? -1 : 1));
      const size = this.o.pageSize ?? 2;
      const from = ExclusiveStartKey ? all.findIndex((i) => order(i) === order(ExclusiveStartKey as Item)) + 1 : 0;
      const slice = all.slice(from, from + size);
      const last = slice[slice.length - 1];
      const more = from + size < all.length;
      return { Items: structuredClone(slice), LastEvaluatedKey: more && last ? structuredClone(last) : undefined };
    }
    throw new Error(`fake: unsupported command ${cmd.constructor.name}`);
  }

  /** Test aid: put a row without any permission or shape check (for state the Lambda cannot write). */
  seed(table: string, item: Item) {
    this.rows(this.full(table)).set(this.keyOf(this.def(this.full(table)), item), structuredClone(item));
  }
  /** Test aid: every row of a table. */
  dump(table: string): Item[] {
    return [...this.rows(this.full(table)).values()].map((i) => structuredClone(i));
  }
}
