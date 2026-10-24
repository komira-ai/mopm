import * as fs from 'fs';
import * as path from 'path';
import { CASE_NAMES } from './group-surfaces';

/**
 * Structural guards: they fail when a new way to read version rows appears that the leak table does not know, or
 * when a file reads the `versions` table or the raw port without going through the store. They are scans of the
 * source text and of the inventory, not type guarantees; each rule is also run over a source it must refuse, so
 * a rule that stopped matching would fail here.
 */

const SRC = path.resolve(__dirname, '..', 'src');
const INVENTORY = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'group-inventory.json'), 'utf8')) as {
  routes: Array<{ route: string; case?: string; no_version_rows?: string }>;
  non_routes: Array<{ name: string; case: string }>;
  readers: Record<string, string[]>;
};

function sources(dir = SRC, prefix = ''): Record<string, string> {
  const out: Record<string, string> = {};
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) Object.assign(out, sources(path.join(dir, e.name), `${prefix}${e.name}/`));
    else if (e.name.endsWith('.ts')) out[`${prefix}${e.name}`] = fs.readFileSync(path.join(dir, e.name), 'utf8');
  }
  return out;
}

/** The store adapters: the only files that may name the `versions` table or send a command against it. */
const ADAPTERS = ['dynamo-store.ts', 'memory-store.ts'];
/** The only files that may use the raw port: the port itself, the group module and the adapters. */
const RAW_PORT_USERS = ['raw-port.ts', 'group.ts', ...ADAPTERS];
/** Every file that imports the DynamoDB SDK. A new one must be added here on purpose, which is a review of what it reads. */
const DYNAMO_USERS = ['auth/dynamo-auth-store.ts', 'auth/owned-packages.ts', 'dynamo-store.ts', 'publish/dynamo-publish-store.ts', 'publish/flags.ts', 'publish/wiring.ts'];
/** Files that define reads rather than use them. */
const READ_DEFINITIONS = ['store.ts', 'group.ts', ...ADAPTERS];

const NAMES_VERSIONS_TABLE = /\btables\.versions\b|['"`]mopm-[^'"`]*versions|TableName:[^\n]*\bversions\b/;
const USES_RAW_PORT = /from\s+['"][^'"]*raw-port['"]|\braw(Get|Query)\b|\.raw\b/;
const IMPORTS_DYNAMO = /@aws-sdk\/(lib|client)-dynamodb/;
const GROUP_WRITER_CALL = /\.(createGroup|updateGroup|commitGroup|adoptVersion|adoptSingle|applyGroupEvent)\(/;
const COMMIT_OR_STAGE_CALL = /\.(commitGroup|applyGroupEvent)\(/;
const READS_VERSIONS = /\.(listVersions|getVersion|versionsOf)\(|\ballRecords\(/;

const filesMatching = (files: Record<string, string>, re: RegExp, except: readonly string[] = []) =>
  Object.keys(files)
    .filter((f) => !except.includes(f) && re.test(files[f]!))
    .sort();

describe('the sources', () => {
  const files = sources();

  test('the scan reads the package (a scan that finds no file proves nothing)', () => {
    expect(Object.keys(files)).toEqual(expect.arrayContaining(['dynamo-store.ts', 'group.ts', 'http/router.ts', 'publish/indexer.ts']));
    expect(Object.keys(files).length).toBeGreaterThan(30);
  });

  test('no file but the store adapters names the versions table', () => {
    expect(filesMatching(files, NAMES_VERSIONS_TABLE, ADAPTERS)).toEqual([]);
    expect(filesMatching(files, NAMES_VERSIONS_TABLE)).toEqual(['dynamo-store.ts']);
  });

  test('no file but the port, the group module and the adapters uses the raw port', () => {
    expect(filesMatching(files, USES_RAW_PORT, RAW_PORT_USERS)).toEqual([]);
    expect(filesMatching(files, USES_RAW_PORT)).toEqual([...RAW_PORT_USERS].sort());
  });

  test('the files that import the DynamoDB SDK are the reviewed ones', () => {
    expect(filesMatching(files, IMPORTS_DYNAMO)).toEqual([...DYNAMO_USERS].sort());
  });

  test('the files that read version rows are the ones the inventory lists, each with its leak cases', () => {
    expect(filesMatching(files, READS_VERSIONS, READ_DEFINITIONS)).toEqual(Object.keys(INVENTORY.readers).sort());
  });

  // The group routes create, read, abort and commit a group (the commit only moves it to validation and stores the request);
  // the single publish takes over a dead group's number; the group's validator stages, copies and commits; the chain that follows
  // a commit releases its gates, flips its members and makes it visible; the sweeper counts a resend in the header; the operator's
  // tool ends a group that is stuck; the group yank writes its intent and its steps on the header and yanks or restores the rows. Those
  // are the callers of the writers below, and each is listed on purpose: a new caller changes this list in the change that adds it.
  test('the callers of the writers of a group are the group service and its commit, lifecycle helper, chain, yank, validator and sweeper, the single publish and the operator tool', () => {
    expect(filesMatching(files, GROUP_WRITER_CALL)).toEqual([
      'ops/group-ops.ts',
      'publish/group-chain.ts',
      'publish/group-commit.ts',
      'publish/group-lifecycle.ts',
      'publish/group-service.ts',
      'publish/group-sweeper.ts',
      'publish/group-validator.ts',
      'publish/group-yank-request.ts',
      'publish/group-yank.ts',
      'publish/service.ts',
    ]);
    expect(filesMatching({ 'x.ts': 'await store.commitGroup(gid, args);', 'y.ts': 'registry.applyGroupEvent(n, v, ev, a)', 'z.ts': 'groups.adoptSingle(r, a, f)' }, GROUP_WRITER_CALL)).toEqual(['x.ts', 'y.ts', 'z.ts']);
    expect(filesMatching(files, /\bclass\s+\w+\s+implements\s+[^{]*\bGroupStore\b/)).toEqual([...ADAPTERS].sort());
  });

  // Only the group's validator commits a group or fills a member (stage), only the chain's flip publishes one (group_publish), and
  // only the validator and the operator's tool burn one, and only the group yank yanks or restores one (all through applyGroupEvent).
  test('only the group validator commits a group or fills a member, only the chain flips one, only the validator and the operator tool burn one, and only the group yank yanks or restores one', () => {
    expect(filesMatching(files, COMMIT_OR_STAGE_CALL)).toEqual(['ops/group-ops.ts', 'publish/group-chain.ts', 'publish/group-validator.ts', 'publish/group-yank.ts']);
    expect(filesMatching(files, /type:\s*'group_yank'/, ['state.ts'])).toEqual(['publish/group-yank.ts']);
    expect(filesMatching(files, /type:\s*'group_unyank'/, ['state.ts'])).toEqual(['publish/group-yank.ts']);
    expect(filesMatching(files, /\.commitGroup\(/)).toEqual(['publish/group-validator.ts']);
    expect(filesMatching(files, /type:\s*'stage'/, ['state.ts'])).toEqual(['publish/group-validator.ts']);
    expect(filesMatching(files, /type:\s*'group_publish'/, ['state.ts'])).toEqual(['publish/group-chain.ts']);
    expect(filesMatching(files, /type:\s*'group_burn'/, ['state.ts'])).toEqual(['ops/group-ops.ts', 'publish/group-validator.ts']);
    expect(filesMatching({ 'x.ts': 'await store.commitGroup(gid, args);', 'y.ts': 'registry.applyGroupEvent(n, v, ev, a)', 'z.ts': 'registry.adoptVersion(r, a, f)' }, COMMIT_OR_STAGE_CALL)).toEqual(['x.ts', 'y.ts']);
  });

  test('the rules refuse what they are for', () => {
    const bad: Record<string, string> = {
      'a.ts': 'const r = await doc.send(new GetCommand({ TableName: this.tables.versions, Key }));',
      'b.ts': "import type { RawVersionPort } from './raw-port';",
      'c.ts': 'const rows = await store.rawQuery(name);',
      'd.ts': "import { GetCommand } from '@aws-sdk/lib-dynamodb';",
      'e.ts': 'const vs = await registry.listVersions(name);',
      'f.ts': 'const all = await allRecords(registry, view);',
      'g.ts': "const t = `mopm-${stage}-versions`;",
    };
    expect(filesMatching(bad, NAMES_VERSIONS_TABLE)).toEqual(['a.ts', 'g.ts']);
    expect(filesMatching(bad, USES_RAW_PORT)).toEqual(['b.ts', 'c.ts']);
    expect(filesMatching(bad, IMPORTS_DYNAMO)).toEqual(['d.ts']);
    expect(filesMatching(bad, READS_VERSIONS)).toEqual(['e.ts', 'f.ts']);
    const fine: Record<string, string> = { 'h.ts': 'const x = tables.packages; // a rawness check\nconst y = store.getPackage(name);' };
    for (const re of [NAMES_VERSIONS_TABLE, USES_RAW_PORT, IMPORTS_DYNAMO, READS_VERSIONS]) expect(filesMatching(fine, re)).toEqual([]);
  });
});

describe('the inventory', () => {
  test('every route names a leak case, or says why it reads no version row', () => {
    for (const r of INVENTORY.routes) {
      expect((r.case === undefined) !== (r.no_version_rows === undefined)).toBe(true);
      if (r.case !== undefined) expect(CASE_NAMES).toContain(r.case);
      else expect(r.no_version_rows!.length).toBeGreaterThan(10);
    }
    expect(new Set(INVENTORY.routes.map((r) => r.route)).size).toBe(INVENTORY.routes.length);
  });

  test('every builder, queue helper and worker names a leak case that exists', () => {
    expect(INVENTORY.non_routes.length).toBeGreaterThanOrEqual(8);
    for (const n of INVENTORY.non_routes) expect(CASE_NAMES).toContain(n.case);
  });

  test('every reader file names leak cases that exist', () => {
    for (const [file, cases] of Object.entries(INVENTORY.readers)) {
      expect(fs.existsSync(path.join(SRC, file))).toBe(true);
      expect(cases.length).toBeGreaterThan(0);
      for (const c of cases) expect(CASE_NAMES).toContain(c);
    }
  });
});
