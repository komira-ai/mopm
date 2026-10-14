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
  expect(dp.versions[1].yank_reason).toBe('crashes on empty body');
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
