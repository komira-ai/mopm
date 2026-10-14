import { GetCommand, PutCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';

type Item = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

/**
 * An in-process stand-in for DynamoDBDocumentClient.send, with no network, for the publish pipeline's tables
 * (single-attribute keys). Get, Put and Update; conditions `attribute_exists(#x)`, `attribute_not_exists(#x)` and
 * `#x = :v` joined by AND; updates of the form `SET #a = :a, #b = :b`. Anything else throws, so a new expression in
 * an adapter fails loudly here. Like the real client without removeUndefinedValues, a Put with an `undefined`
 * member is refused. Every call first yields, so concurrent callers interleave before the atomic section.
 */
export class FakeDoc {
  tables = new Map<string, Map<string, Item>>();
  sent: string[] = [];
  constructor(
    private readonly keys: Record<string, string>,
    private readonly yields = 3,
  ) {
    for (const t of Object.keys(keys)) this.tables.set(t, new Map());
  }

  table(name: string): Map<string, Item> {
    const t = this.tables.get(name);
    if (!t) throw new Error(`fake: no table ${name}`);
    return t;
  }

  private check(cond: string | undefined, names: Record<string, string> = {}, values: Record<string, any> = {}, existing?: Item): boolean { // eslint-disable-line @typescript-eslint/no-explicit-any
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

  private static noUndefined(v: unknown, path = 'item'): void {
    if (v === undefined) throw new Error(`fake: ${path} is undefined (the document client refuses undefined members)`);
    if (v && typeof v === 'object') for (const [k, x] of Object.entries(v)) FakeDoc.noUndefined(x, `${path}.${k}`);
  }

  async send(cmd: any): Promise<any> { // eslint-disable-line @typescript-eslint/no-explicit-any
    for (let i = 0; i < this.yields; i++) await Promise.resolve();
    this.sent.push(cmd.constructor.name);
    if (cmd instanceof GetCommand) {
      const { TableName, Key } = cmd.input;
      const attr = this.keys[TableName!]!;
      const item = this.table(TableName!).get(String(Key![attr]));
      return { Item: item && structuredClone(item) };
    }
    if (cmd instanceof PutCommand) {
      const { TableName, Item, ConditionExpression, ExpressionAttributeNames, ExpressionAttributeValues } = cmd.input;
      FakeDoc.noUndefined(Item);
      const t = this.table(TableName!);
      const key = String(Item![this.keys[TableName!]!]);
      if (!this.check(ConditionExpression, ExpressionAttributeNames, ExpressionAttributeValues, t.get(key))) {
        throw Object.assign(new Error('The conditional request failed'), { name: 'ConditionalCheckFailedException' });
      }
      t.set(key, structuredClone(Item!));
      return {};
    }
    if (cmd instanceof UpdateCommand) {
      const { TableName, Key, UpdateExpression, ConditionExpression, ExpressionAttributeNames, ExpressionAttributeValues } = cmd.input;
      const t = this.table(TableName!);
      const key = String(Key![this.keys[TableName!]!]);
      const existing = t.get(key);
      if (!this.check(ConditionExpression, ExpressionAttributeNames, ExpressionAttributeValues, existing)) {
        throw Object.assign(new Error('The conditional request failed'), { name: 'ConditionalCheckFailedException' });
      }
      const m = /^SET (.+)$/.exec(UpdateExpression ?? '');
      if (!m) throw new Error(`fake: unsupported update ${UpdateExpression}`);
      const item = existing ?? { [this.keys[TableName!]!]: key };
      for (const part of m[1]!.split(', ')) {
        const a = /^(#\w+) = (:\w+)$/.exec(part.trim());
        if (!a) throw new Error(`fake: unsupported assignment ${part}`);
        item[ExpressionAttributeNames![a[1]!]!] = ExpressionAttributeValues![a[2]!];
      }
      t.set(key, item);
      return {};
    }
    throw new Error(`fake: unsupported command ${cmd.constructor.name}`);
  }
}
