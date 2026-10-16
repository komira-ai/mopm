import fc from 'fast-check';
import { readFileSync } from 'fs';
import { join } from 'path';
import { decompress } from 'fzstd';
import { canonicalJson } from '../src/canonical-json';
import { applyEvent } from '../src/state';
import { buildRepodata, buildRepodataJson } from '../src/repodata';
import type { FileRef, VersionRecord, VersionState } from '../src/types';
import { zstdFrame } from '../src/zstd';
import { GOLDEN_RECORDS } from './fixtures/golden-records';
import { hex, isDeterministic, rec } from './helpers';

const fixture = (name: string) => readFileSync(join(__dirname, 'fixtures', name), 'utf8');

describe('golden repodata', () => {
  test.each(['linux-64', 'osx-arm64', 'noarch'])('%s matches the checked-in bytes', (subdir) => {
    expect(buildRepodataJson(subdir, GOLDEN_RECORDS)).toBe(fixture(`repodata.${subdir}.json`));
  });

  test('the zst file decodes to exactly the json bytes', () => {
    const { json, zst } = buildRepodata('linux-64', GOLDEN_RECORDS);
    expect(Buffer.from(decompress(zst)).equals(json)).toBe(true);
  });

  test('yanked and tombstoned entries are under removed, pending ones appear nowhere', () => {
    const text = buildRepodataJson('linux-64', GOLDEN_RECORDS);
    const doc = JSON.parse(text);
    expect(Object.keys(doc['packages.conda'])).toEqual(['mojo-http_client-0.4.0-mojo1.0.0_0.conda', 'mojo-http_core-1.2.0-mojo1.0.0_0.conda']);
    expect(doc.removed).toEqual(['mojo-http_client-0.3.0-mojo1.0.0_0.conda', 'mojo-tls-1.0.0-mojo1.0.0_0.conda']);
    expect(text.match(/mojo-tls/g)).toHaveLength(1); // only in removed
    expect(text).not.toContain('mojo-fresh');
    expect(doc.packages).toEqual({});
  });

  test('an empty subdir is a valid empty repodata', () => {
    expect(JSON.parse(buildRepodataJson('linux-aarch64', []))).toEqual({
      info: { subdir: 'linux-aarch64' },
      packages: {},
      'packages.conda': {},
      removed: [],
    });
  });

  test('entries carry only the promised keys', () => {
    const doc = JSON.parse(buildRepodataJson('linux-64', GOLDEN_RECORDS));
    for (const e of Object.values<Record<string, unknown>>(doc['packages.conda'])) {
      expect(Object.keys(e)).toEqual(['build', 'build_number', 'depends', 'name', 'sha256', 'size', 'subdir', 'version']);
      expect(e.build_number).toBe(0);
    }
  });

  test('the same file name twice is a bug in the caller, not silently merged', () => {
    expect(() => buildRepodataJson('linux-64', [rec({ name: 'p', version: '1.0.0' }), rec({ name: 'p', version: '1.0.0' })])).toThrow(/twice/);
  });
});

describe('canonicalJson', () => {
  test('sorts keys at every depth and drops undefined', () => {
    expect(canonicalJson({ b: 1, a: { d: [{ z: 1, y: 2 }], c: undefined } })).toBe('{"a":{"d":[{"y":2,"z":1}]},"b":1}');
  });
  test.each([1.5, NaN, Infinity, 2 ** 60])('refuses the number %s (only safe integers have one stable spelling)', (n) => {
    expect(() => canonicalJson({ n })).toThrow(/safe integer/);
  });
});

describe('zstd frame', () => {
  test.each([0, 1, 100, 131071, 131072, 131073, 300000])('round-trips %i bytes', (n) => {
    const data = Buffer.from(Array.from({ length: n }, (_, i) => (i * 31 + 7) & 0xff));
    const frame = zstdFrame(data);
    expect(frame.subarray(0, 4)).toEqual(Buffer.from([0x28, 0xb5, 0x2f, 0xfd]));
    expect(Buffer.from(decompress(frame)).equals(data)).toBe(true);
  });
  test('is a pure function of its input', () => {
    const d = Buffer.from('hello');
    expect(zstdFrame(d).equals(zstdFrame(Buffer.from('hello')))).toBe(true);
  });
});

// ---- determinism: a can-fail proof, then properties ----------------------------------------------

/** The mutant: iterates input order and never sorts, so the bytes depend on the order records arrive in. */
function nonDeterministicWriter(subdir: string, records: readonly VersionRecord[]): string {
  const conda: Record<string, unknown> = {};
  const removed: string[] = [];
  for (const r of records) {
    for (const f of r.files) {
      if (f.subdir !== subdir) continue;
      if (r.state === 'yanked') removed.push(f.filename);
      else if (r.state === 'published') conda[f.filename] = { name: `mojo-${r.name}`, version: r.version, sha256: f.sha256, size: f.size };
    }
  }
  return JSON.stringify({ info: { subdir }, packages: {}, 'packages.conda': conda, removed });
}

describe('the determinism check can fail', () => {
  const records = GOLDEN_RECORDS;

  test('the real writer passes it', () => {
    expect(isDeterministic((rs) => buildRepodataJson('linux-64', rs), records)).toBe(true);
  });

  test('a writer that depends on input order fails it', () => {
    expect(isDeterministic((rs) => nonDeterministicWriter('linux-64', rs), records)).toBe(false);
  });

  test('a writer that stamps the time fails it', () => {
    let tick = 0;
    const stamped = (rs: VersionRecord[]) => buildRepodataJson('linux-64', rs) + `#${tick++}`;
    expect(isDeterministic(stamped, records)).toBe(false);
  });
});

const hexArb = fc.constantFrom(...'0123456789abcdef'.split('')).map((c) => hex(c));
const nameArb = fc.constantFrom('alpha', 'beta', 'gamma', 'delta', 'http_core', 'http_client', 'tls');
const versionArb = fc.tuple(fc.nat(9), fc.nat(9), fc.nat(9)).map((p) => p.join('.'));
const stateArb = fc.constantFrom<VersionState>('pending', 'published', 'published', 'yanked', 'tombstoned');
const subdirArb = fc.constantFrom('linux-64', 'osx-arm64', 'noarch');

const recordArb: fc.Arbitrary<VersionRecord> = fc
  .record({
    name: nameArb,
    version: versionArb,
    state: stateArb,
    sha: hexArb,
    size: fc.integer({ min: 1, max: 5_000_000 }),
    subdirs: fc.uniqueArray(subdirArb, { minLength: 1, maxLength: 3 }),
    deps: fc.uniqueArray(fc.record({ name: nameArb, range: fc.option(fc.constantFrom('>=1', '>=1.2,<2', '==3.0'), { nil: undefined }) }), {
      selector: (d) => d.name,
      maxLength: 3,
    }),
    native: fc.uniqueArray(fc.constantFrom('openssl', 'zlib', 'libffi'), { maxLength: 2 }),
  })
  .map(({ name, version, state, sha, size, subdirs, deps, native }) => {
    const files: FileRef[] = subdirs.map((subdir) => ({ subdir, filename: `mojo-${name}-${version}-${subdir}.conda`, sha256: sha, size }));
    return rec({ name, version, state, files, deps, native: native.map((id) => ({ id, soname: `lib${id}.so` })), ...(state === 'yanked' ? { yank_reason: 'r' } : {}) });
  });

/** A set of records with at most one record per (name, canonical version), as the store guarantees. */
const recordsArb = fc.array(recordArb, { maxLength: 12 }).map((rs) => [...new Map(rs.map((r) => [`${r.name}@${r.canonical}`, r])).values()]);

describe('index writer properties', () => {
  test('building twice from the same records gives identical bytes (json and zst)', () => {
    fc.assert(
      fc.property(recordsArb, subdirArb, (records, subdir) => {
        const a = buildRepodata(subdir, records);
        const b = buildRepodata(subdir, structuredClone(records));
        return a.json.equals(b.json) && a.zst.equals(b.zst);
      }),
    );
  });

  test('the order of the input records does not change the output', () => {
    const shuffledArb = recordsArb.chain((rs) =>
      fc.tuple(fc.constant(rs), fc.shuffledSubarray(rs, { minLength: rs.length, maxLength: rs.length })),
    );
    fc.assert(
      fc.property(shuffledArb, subdirArb, ([records, shuffled], subdir) => {
        return buildRepodataJson(subdir, shuffled) === buildRepodataJson(subdir, records);
      }),
    );
  });

  test('the zst always decodes to the json', () => {
    fc.assert(
      fc.property(recordsArb, subdirArb, (records, subdir) => {
        const { json, zst } = buildRepodata(subdir, records);
        return Buffer.from(decompress(zst)).equals(json);
      }),
    );
  });

  test('publishing then yanking a package moves it from packages.conda to removed; unyank restores the bytes', () => {
    fc.assert(
      fc.property(recordsArb, recordArb, subdirArb, (others, extra, subdir) => {
        const base = others.filter((r) => !(r.name === extra.name && r.canonical === extra.canonical));
        const published = applyEvent({ ...extra, state: 'pending' }, { type: 'publish' });
        const names = published.files.filter((f) => f.subdir === subdir).map((f) => f.filename);
        const doc = (rs: VersionRecord[]) => JSON.parse(buildRepodataJson(subdir, rs));

        const withIt = doc([...base, published]);
        const yanked = applyEvent(published, { type: 'yank', reason: 'bad' });
        const afterYank = doc([...base, yanked]);
        const restored = applyEvent(yanked, { type: 'unyank' });

        return (
          names.every((n) => n in withIt['packages.conda'] && !withIt.removed.includes(n)) &&
          names.every((n) => !(n in afterYank['packages.conda']) && afterYank.removed.includes(n)) &&
          buildRepodataJson(subdir, [...base, restored]) === buildRepodataJson(subdir, [...base, published])
        );
      }),
    );
  });

  test('a tombstoned package never appears in packages or packages.conda, only in removed', () => {
    fc.assert(
      fc.property(recordsArb, subdirArb, (records, subdir) => {
        const doc = JSON.parse(buildRepodataJson(subdir, records));
        return records
          .filter((r) => r.state === 'tombstoned')
          .flatMap((r) => r.files.filter((f) => f.subdir === subdir).map((f) => f.filename))
          .every((n) => !(n in doc['packages.conda']) && !(n in doc.packages) && doc.removed.includes(n));
      }),
    );
  });

  test('only published records are listed, in any state mix', () => {
    fc.assert(
      fc.property(recordsArb, subdirArb, (records, subdir) => {
        const doc = JSON.parse(buildRepodataJson(subdir, records));
        const want = new Set<string>();
        const gone = new Set<string>();
        for (const r of records) {
          for (const f of r.files) {
            if (f.subdir !== subdir) continue;
            if (r.state === 'published') want.add(f.filename);
            if (r.state === 'yanked' || r.state === 'tombstoned') gone.add(f.filename);
          }
        }
        return (
          Object.keys(doc['packages.conda']).sort().join() === [...want].sort().join() &&
          doc.removed.join() === [...gone].sort().join() &&
          doc.removed.every((n: string) => !(n in doc['packages.conda']))
        );
      }),
    );
  });
});
