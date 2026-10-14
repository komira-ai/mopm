import { GetCommand } from '@aws-sdk/lib-dynamodb';
import type { DocClient } from '../dynamo-store';
import type { Flags } from './ports';

/** A flag fixed at construction (tests, and the MOPM_READ_ONLY environment switch). */
export class StaticFlags implements Flags {
  constructor(private readonly ro: boolean) {}
  async readOnly() {
    return this.ro;
  }
}

/**
 * The runtime read-only switch: the item `{key: 'read_only', value: true}` in the stage's `config` table, set and
 * cleared by an operator with a single put-item (service/docs/runbook.md). The result is cached for a few
 * seconds so a read does not cost a DynamoDB call per request. A failed read throws: writers fail closed.
 */
export class DynamoFlags implements Flags {
  private cached?: { at: number; value: boolean };
  constructor(
    private readonly doc: DocClient,
    private readonly table: string,
    private readonly cacheMs = 5000,
    private readonly now: () => number = Date.now,
  ) {}
  async readOnly(): Promise<boolean> {
    const t = this.now();
    if (this.cached && t - this.cached.at < this.cacheMs) return this.cached.value;
    const r = await this.doc.send(new GetCommand({ TableName: this.table, Key: { key: 'read_only' }, ConsistentRead: true }));
    const value = r.Item?.value === true;
    this.cached = { at: t, value };
    return value;
  }
}

/** Either switch makes the registry read-only. */
export class AnyFlag implements Flags {
  constructor(private readonly flags: Flags[]) {}
  async readOnly() {
    for (const f of this.flags) if (await f.readOnly()) return true;
    return false;
  }
}
