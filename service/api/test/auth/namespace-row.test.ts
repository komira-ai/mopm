// The user namespace row a Rust web login writes (service/lambda/aws/tests/fixtures/namespace_user_row.json; mopm_aws's
// test holds DynamoNamespaceStore's PutItem to `item`) is the row this DynamoNamespaceStore writes for the same login, and
// this adapter reads it back as that account's user namespace. Both languages create and read one `namespaces` table.
import * as fs from 'node:fs';
import * as path from 'node:path';
import { GetCommand, PutCommand } from '@aws-sdk/lib-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import { DynamoNamespaceStore } from '../../src/auth/dynamo-namespace-store';
import { ensureUserNamespace } from '../../src/auth/namespaces';

const FIXTURE = path.join(__dirname, '../../../lambda/aws/tests/fixtures/namespace_user_row.json');
const DOC = JSON.parse(fs.readFileSync(FIXTURE, 'utf8')) as {
  github_id: number;
  login: string;
  now: string;
  item: Record<string, unknown>;
};

/** A document client over one optional stored row: it answers GetItem from it, accepts PutItem, and records every command. */
class OneRow {
  sent: unknown[] = [];
  constructor(private readonly row?: Record<string, unknown>) {}
  async send(command: unknown) {
    this.sent.push(command);
    if (command instanceof GetCommand) return this.row ? { Item: this.row } : {};
    if (command instanceof PutCommand) return {};
    throw new Error(`unexpected command ${(command as object).constructor.name}`);
  }
}

const store = (doc: OneRow) => new DynamoNamespaceStore(doc, 'mopm-t-namespaces', 'mopm-t-namespace_members');

test('the golden login on an empty table writes the golden row, conditional on the key being absent', async () => {
  const doc = new OneRow();
  expect(await ensureUserNamespace(store(doc), DOC.github_id, DOC.login, DOC.now)).toEqual({ status: 'created', namespace: 'alice-dev' });
  const puts = doc.sent.filter((c): c is PutCommand => c instanceof PutCommand);
  expect(puts).toHaveLength(1);
  expect(puts[0].input.TableName).toBe('mopm-t-namespaces');
  expect(marshall(puts[0].input.Item as Record<string, unknown>)).toEqual(DOC.item);
  expect(puts[0].input.ConditionExpression).toBe('attribute_not_exists(#n)');
  expect(puts[0].input.ExpressionAttributeNames).toEqual({ '#n': 'namespace' });
});

test('the golden row reads back as the user namespace of its account, and as taken for any other', async () => {
  const doc = new OneRow(unmarshall(DOC.item as Parameters<typeof unmarshall>[0]));
  expect(await store(doc).getNamespace('alice-dev')).toEqual({ namespace: 'alice-dev', kind: 'user', github_id: DOC.github_id, created_at: DOC.now });
  expect(await ensureUserNamespace(store(doc), DOC.github_id, DOC.login, DOC.now)).toEqual({ status: 'held', namespace: 'alice-dev' });
  expect(await ensureUserNamespace(store(doc), DOC.github_id + 1, DOC.login, DOC.now)).toEqual({ status: 'taken', namespace: 'alice-dev' });
  expect(doc.sent.some((c) => c instanceof PutCommand)).toBe(false);
});
