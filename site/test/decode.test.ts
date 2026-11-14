// T7: decoding follows the additive-only rules: an unknown enum value becomes 'unknown', unknown fields are ignored,
// yank_reason may be absent or null, any subdir is accepted, and a missing required field is an error.
import { DecodeError, decodeHealth, decodePackageInfo, decodePackageList, decodeVersionDetail } from '../src/decode';
import { validReadCases } from './fixtures';

const bodyOf = (op: string, pred: (b: Record<string, unknown>) => boolean = () => true): Record<string, unknown> => {
  const c = validReadCases().find((x) => x.operationId === op && pred(x.response.body as Record<string, unknown>));
  if (!c) throw new Error(`no ${op} fixture`);
  return structuredClone(c.response.body) as Record<string, unknown>;
};

test('an unknown version state decodes as unknown, keeping the raw value', () => {
  const v = bodyOf('getVersion');
  v.state = 'quarantined';
  const d = decodeVersionDetail(v);
  expect(d.state).toBe('unknown');
  expect(d.state_raw).toBe('quarantined');
  const p = bodyOf('getPackage');
  (p.versions as Record<string, unknown>[])[0].state = 'pending';
  p.state = 'frozen';
  const dp = decodePackageInfo(p);
  expect(dp.state).toBe('unknown');
  expect(dp.versions[0]).toMatchObject({ state: 'unknown', state_raw: 'pending' });
});

test('unknown health stage, status and provenance kind decode as unknown', () => {
  expect(decodeHealth({ status: 'degraded', stage: 'dev', api_version: 'v1', read_only: false })).toEqual({
    status: 'unknown', stage: 'unknown', api_version: 'v1', read_only: false,
  });
  const v = bodyOf('getVersion');
  v.provenance = { kind: 'sigstore' };
  expect(decodeVersionDetail(v).provenance.kind).toBe('unknown');
});

test('extra fields are ignored and not copied', () => {
  const v = bodyOf('getVersion');
  v.future_field = { x: 1 };
  (v.files as Record<string, unknown>[])[0].extra = 'y';
  const d = decodeVersionDetail(v) as unknown as Record<string, unknown>;
  expect(d).not.toHaveProperty('future_field');
  expect((d.files as Record<string, unknown>[])[0]).not.toHaveProperty('extra');
});

test('yank_reason may be absent, null or a string', () => {
  const v = bodyOf('getVersion');
  delete v.yank_reason;
  expect(decodeVersionDetail(v)).not.toHaveProperty('yank_reason');
  v.yank_reason = null;
  expect(decodeVersionDetail(v).yank_reason).toBeNull();
  v.yank_reason = 'bad build';
  expect(decodeVersionDetail(v).yank_reason).toBe('bad build');
  const p = bodyOf('getPackage');
  const dp = decodePackageInfo(p);
  expect(dp.versions[0]).not.toHaveProperty('yank_reason');
  expect(dp.versions[1].yank_reason).toBe('wrong license text');
});

test('a file with a subdir this build does not know is accepted as is', () => {
  const v = bodyOf('getVersion');
  (v.files as Record<string, unknown>[])[0].subdir = 'linux-riscv64';
  expect(decodeVersionDetail(v).files[0].subdir).toBe('linux-riscv64');
});

test('the display metadata decodes when present and stays absent otherwise', () => {
  const p = bodyOf('getPackage');
  expect(decodePackageInfo(p)).not.toHaveProperty('readme');
  Object.assign(p, { homepage: 'https://mopm.dev/x', keywords: ['http', 'net'], readme: '# hi' });
  expect(decodePackageInfo(p)).toMatchObject({ homepage: 'https://mopm.dev/x', keywords: ['http', 'net'], readme: '# hi' });
  Object.assign(p, { keywords: 'http', readme: 7 });
  const d = decodePackageInfo(p);
  expect(d).not.toHaveProperty('keywords');
  expect(d).not.toHaveProperty('readme');
});

test.each([
  ['getVersion', 'files'],
  ['getVersion', 'manifest_sha256'],
  ['getVersion', 'provenance'],
  ['getPackage', 'latest'],
  ['getPackage', 'namespace'],
  ['getPackage', 'versions'],
  ['searchPackages', 'next_cursor'],
] as const)('%s without %s is an error', (op, field) => {
  const b = bodyOf(op);
  delete b[field];
  const decode = { getVersion: decodeVersionDetail, getPackage: decodePackageInfo, searchPackages: decodePackageList }[op];
  expect(() => decode(b)).toThrow(DecodeError);
});

test('a mistyped required field is an error', () => {
  const v = bodyOf('getVersion');
  (v.files as Record<string, unknown>[])[0].size = '123';
  expect(() => decodeVersionDetail(v)).toThrow(/files\[0\]\.size/);
  expect(() => decodeHealth({ status: 'ok', stage: 'prod', api_version: 'v1', read_only: 'no' })).toThrow(DecodeError);
  expect(() => decodePackageList(null)).toThrow(DecodeError);
  expect(() => decodePackageList([])).toThrow(DecodeError);
});

test('a claimed package (no version yet) decodes with latest null and no versions', () => {
  // The contract fixtures hold no getPackage answer for a claimed package, so it is built from the active one with
  // the fields a claim changes. If decodePackageInfo required `latest` to be a string, this page would fail to load.
  const p = bodyOf('getPackage');
  Object.assign(p, { state: 'claimed', latest: null, versions: [], repository: null, license: null, description: null });
  const d = decodePackageInfo(p);
  expect(d).toMatchObject({ state: 'claimed', latest: null, versions: [], repository: null, license: null, description: null });
  expect(d.namespace).toEqual(p.namespace);
});

test("a package's version summaries keep a null yank_reason as null", () => {
  const p = bodyOf('getPackage');
  (p.versions as Record<string, unknown>[])[0].yank_reason = null;
  expect(decodePackageInfo(p).versions[0].yank_reason).toBeNull();
});

test('a mistyped optional field is treated as absent, yank_reason included', () => {
  const v = bodyOf('getVersion');
  Object.assign(v, { yank_reason: 5, keywords: [1, 'x'], readme: 7, tombstone: { reason_code: 1, date: 'd' }, homepage: false });
  (v.files as Record<string, unknown>[])[0].url = 42;
  const d = decodeVersionDetail(v);
  for (const k of ['yank_reason', 'keywords', 'readme', 'tombstone', 'homepage']) expect(d).not.toHaveProperty(k);
  expect(d.files[0]).not.toHaveProperty('url');
  const p = bodyOf('getPackage');
  (p.versions as Record<string, unknown>[])[0].yank_reason = { why: 'x' };
  p.keywords = ['ok', null];
  const dp = decodePackageInfo(p);
  expect(dp.versions[0]).not.toHaveProperty('yank_reason');
  expect(dp).not.toHaveProperty('keywords');
});

test("a version's display metadata decodes when present", () => {
  const v = bodyOf('getVersion');
  const meta = {
    description: 'An HTTP client.', license: 'Apache-2.0', repository: 'https://github.com/o/r',
    homepage: 'https://mopm.dev/h', keywords: ['http', 'net'], readme: '# http_client', published_by: 'octo',
  };
  Object.assign(v, meta);
  expect(decodeVersionDetail(v)).toMatchObject(meta);
});

describe('the namespace of a package (there are no owners in version 2)', () => {
  const pkg = () => bodyOf('getPackage', (b) => (b.namespace as { kind: string }).kind === 'org');
  const ns = (p: Record<string, unknown>) => p.namespace as Record<string, unknown>;

  test('decodes each field as sent, and the package name is the full name', () => {
    const p = pkg();
    const d = decodePackageInfo(p);
    expect(d.name).toBe('komira-ai/json');
    expect(d.namespace).toEqual({ namespace: 'komira-ai', kind: 'org', github_id: 77, login: 'komira-ai', frozen: false });
    expect(d).not.toHaveProperty('owners');
  });

  test('a user namespace whose login differs from the namespace keeps both', () => {
    const p = bodyOf('getPackage', (b) => (b.namespace as { kind: string }).kind === 'user');
    expect(decodePackageInfo(p).namespace).toMatchObject({ namespace: 'alice', kind: 'user', login: 'Alice', frozen: false });
  });

  test('a frozen namespace decodes as frozen', () => {
    const p = pkg();
    ns(p).frozen = true;
    expect(decodePackageInfo(p).namespace.frozen).toBe(true);
  });

  test.each(['org', 'user'] as const)('kind %s decodes as itself', (kind) => {
    const p = pkg();
    ns(p).kind = kind;
    expect(decodePackageInfo(p).namespace.kind).toBe(kind);
  });

  test.each(['team', 'bot', ''])('a kind this build does not know (%j) decodes as unknown', (kind) => {
    const p = pkg();
    ns(p).kind = kind;
    expect(decodePackageInfo(p).namespace.kind).toBe('unknown');
  });

  test.each(['namespace', 'kind', 'github_id', 'login', 'frozen'])('a namespace without %s is an error naming it', (field) => {
    const p = pkg();
    delete ns(p)[field];
    expect(() => decodePackageInfo(p)).toThrow(DecodeError);
    expect(() => decodePackageInfo(p)).toThrow(new RegExp(`namespace\\.${field}`));
  });

  test.each([
    ['namespace', 7],
    ['kind', 1],
    ['github_id', '77'],
    ['login', null],
    ['frozen', 'no'],
  ] as const)('a mistyped %s is an error', (field, value) => {
    const p = pkg();
    ns(p)[field] = value;
    expect(() => decodePackageInfo(p)).toThrow(DecodeError);
  });

  test.each([undefined, null, 'komira-ai', 5, [], [{ namespace: 'komira-ai' }]])('a package whose namespace is %j is an error', (v) => {
    const p = pkg();
    if (v === undefined) delete p.namespace;
    else p.namespace = v;
    expect(() => decodePackageInfo(p)).toThrow(DecodeError);
  });

  test('extra fields of the namespace are ignored and not copied', () => {
    const p = pkg();
    ns(p).plan = 'free';
    expect(decodePackageInfo(p).namespace).not.toHaveProperty('plan');
  });

  test('the version answers of the fixtures decode with a full name', () => {
    expect(decodeVersionDetail(bodyOf('getVersion')).name).toBe('komira-ai/json');
  });
});
