import * as fs from 'fs';
import * as path from 'path';
import { STAGES, tableName } from '../lib/config';
import { tpl } from './util';

/**
 * The class of bug behind "token creation answers 500 once deployed": a DynamoDB call the code makes that the API
 * role's synthesized IAM policy does not allow, while the in-process test double did.
 *
 * The oracle for what the code calls is the set of recorded wire goldens (service/api/test/fixtures/wire/*.json): the
 * requests each storage adapter sends, as the SDK serialises them, including the owners index query of
 * ownedPackagesFrom. The oracle for what is allowed is the policy CDK synthesizes, read from the template, not from the
 * constants in api-stack.ts. Every call must be covered, with table and index each their own resource, or be listed in
 * NOT_ROUTED below, with the reason. The list is itself checked, so it cannot go stale.
 *
 * What it does not prove: that a route reaches an adapter method (a golden for a method no route calls is why
 * NOT_ROUTED exists), or that IAM and DynamoDB behave as modelled here (no AWS call is made).
 */

const WIRE_DIR = path.resolve(__dirname, '../../../api/test/fixtures/wire');
const WIRE_STAGE = 'beta'; // the stage name inside the goldens' table names

/** Adapter calls recorded in the goldens that no route of the API handler makes, hence not granted. Key: `<action> <table>`. */
const NOT_ROUTED: Record<string, string> = {
  'dynamodb:PutItem trusted_publishers': 'no route registers a trusted publisher',
  'dynamodb:DeleteItem trusted_publishers': 'a real delete; the table policy denies it to this role',
  'dynamodb:PutItem owners': 'addOwner: package claim is not routed',
  'dynamodb:DeleteItem owners': 'removeOwner: no route; a real delete',
  'dynamodb:PutItem packages': 'createPackage: package claim is not routed',
  'dynamodb:Scan packages': 'listPackageNames: used by the index writer, never by a route; the API role gets no Scan',
};

interface Call {
  action: string;
  table: string; // without the stage prefix
  index?: string;
  via: string;
}

const TX: Record<string, string> = { Put: 'PutItem', Update: 'UpdateItem', Delete: 'DeleteItem', ConditionCheck: 'ConditionCheckItem' };

function loadCalls(): Call[] {
  const prefix = `mopm-${WIRE_STAGE}-`;
  const short = (full: string, via: string) => {
    if (!full.startsWith(prefix)) throw new Error(`${via}: table ${full} does not start with ${prefix}`);
    return full.slice(prefix.length);
  };
  const out: Call[] = [];
  for (const file of fs.readdirSync(WIRE_DIR).filter((f) => f.endsWith('.json')).sort()) {
    const steps = JSON.parse(fs.readFileSync(path.join(WIRE_DIR, file), 'utf8')) as any[];
    for (const step of steps) {
      const via = `${file} ${step.adapter}.${step.method}`;
      for (const req of step.expect?.requests ?? []) {
        if (req.target === 'TransactWriteItems') {
          for (const item of req.body.TransactItems as any[]) {
            for (const [op, v] of Object.entries(item) as [string, any][]) {
              out.push({ action: `dynamodb:${TX[op] ?? op}`, table: short(v.TableName, via), via });
            }
          }
        } else {
          out.push({ action: `dynamodb:${req.target}`, table: short(req.body.TableName, via), index: req.body.IndexName, via });
        }
      }
    }
  }
  return out;
}

const keyOf = (c: Call) => `${c.action} ${c.table}${c.index ? `/index/${c.index}` : ''}`;
const acts = (s: any): string[] => ([] as string[]).concat(s.Action);

describe('wire goldens', () => {
  const calls = loadCalls();

  test('the goldens are read (a harness that reads nothing proves nothing)', () => {
    expect(calls.length).toBeGreaterThan(50);
    expect(calls.map(keyOf)).toContain('dynamodb:Query owners/index/by_github_id');
    expect(calls.map(keyOf)).toContain('dynamodb:Query tokens/index/by_github_id');
  });

  // A group is written with conditional Puts and transactions of Puts, never with an update or a delete: the roles have
  // GetItem and PutItem on these tables, and the data stack denies delete (infra/stacks/lib/data-stack.ts).
  test('the group writers (group.json) call GetItem and PutItem only: no UpdateItem, no DeleteItem, no ConditionCheck, no Scan', () => {
    const group = calls.filter((c) => c.via.startsWith('group.json '));
    expect(group.map((c) => c.via.split(' ')[1]).filter((v, i, all) => all.indexOf(v) === i)).toEqual([
      'store.createGroup',
      'store.getGroup',
      'store.getGroupMembers',
      'store.updateGroup',
      'store.commitGroup',
      'store.adoptVersion',
      'store.applyGroupEvent',
      'publish.hit',
    ]);
    expect([...new Set(group.map((c) => c.action))].sort()).toEqual(['dynamodb:GetItem', 'dynamodb:PutItem']);
    expect([...new Set(group.map((c) => c.table))].sort()).toEqual(['audit', 'publishes', 'versions']);
  });

  describe.each(STAGES)('against the ApiStack %s policy', (stage) => {
    let cache: any[] | undefined;
    const allowed = (): any[] =>
      (cache ??= Object.values(tpl(stage).api.findResources('AWS::IAM::Policy'))
        .flatMap((r: any) => r.Properties.PolicyDocument.Statement as any[])
        .filter((s) => s.Effect === 'Allow'));
    /** A statement covers the call when it names the action and the table (or, for an index query, the index) as its own resource. */
    const covered = (c: Call, statements: any[]): boolean => {
      const tail = `table/${tableName(stage, c.table)}${c.index ? `/index/${c.index}` : ''}"`;
      return statements.some(
        (s) => acts(s).includes(c.action) && ([] as any[]).concat(s.Resource).some((r) => JSON.stringify(r).includes(tail)),
      );
    };

    test('every call is allowed, or listed in NOT_ROUTED', () => {
      const st = allowed();
      const refused = new Map<string, Set<string>>();
      for (const c of calls) {
        if (covered(c, st) || keyOf(c) in NOT_ROUTED || `${c.action} ${c.table}` in NOT_ROUTED) continue;
        refused.set(keyOf(c), (refused.get(keyOf(c)) ?? new Set()).add(c.via));
      }
      expect([...refused].map(([k, v]) => `${k}  <- ${[...v].join(', ')}`).sort()).toEqual([]);
    });

    // Yank and unyank read every row of the package (listVersions) to put its revision on the index job they queue, so
    // the API role needs this exact call, and no Scan: the writer's whole-registry read stays with the index writer.
    test('the package-revision read of a yank (a Query of the versions table) is allowed, and the API role still has no Scan', () => {
      const q = calls.find((c) => c.action === 'dynamodb:Query' && c.table === 'versions' && !c.index);
      expect(q).toBeDefined();
      expect(covered(q!, allowed())).toBe(true);
      expect(allowed().flatMap(acts).filter((a) => a === 'dynamodb:Scan')).toEqual([]);
    });

    test('NOT_ROUTED lists only calls the goldens make and the policy refuses', () => {
      const st = allowed();
      for (const k of Object.keys(NOT_ROUTED)) {
        const mine = calls.filter((c) => `${c.action} ${c.table}` === k);
        expect(mine.length).toBeGreaterThan(0);
        for (const c of mine) expect(covered(c, st)).toBe(false);
      }
    });

    test('can fail: with the owners index resource removed from the policy, the account-token query is not covered', () => {
      const q = calls.find((c) => c.table === 'owners' && c.index === 'by_github_id')!;
      expect(covered(q, allowed())).toBe(true);
      const stripped = allowed().map((s) => ({
        ...s,
        Resource: ([] as any[]).concat(s.Resource).filter((r) => !JSON.stringify(r).includes('/index/by_github_id"') || !JSON.stringify(r).includes('-owners/')),
      }));
      expect(covered(q, stripped)).toBe(false);
    });
  });
});
