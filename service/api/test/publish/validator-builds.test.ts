import { createHash } from 'node:crypto';
import { buildsOf } from '../../src/builds';
import { Rejected, checkAddedBuild, fillFrom, validateArchives } from '../../src/publish/validator';
import type { VersionRecord } from '../../src/types';
import { validatePackage } from '../../src/validate';
import type { PackageFacts } from '../../src/validate';
import { buildFile, buildRow, rec } from '../helpers';
import { buildConda, type Spec } from '../validate/builder';

const NAME = 'komira-ai/json';
const SOURCE = '5'.repeat(64);

/** The archive of one build for one platform, validated, and the facts the validator took from it. */
function built(over: Partial<Spec> = {}) {
  const b = buildConda({ name: NAME, version: '1.0.0', mopm: { source_sha256: SOURCE }, ...over });
  const verdict = validatePackage(b.bytes, b.req);
  if (!verdict.ok) throw new Error(`the fixture archive is refused: ${verdict.message}`);
  return { bytes: b.bytes, req: b.req, facts: verdict.facts };
}
const factsOf = (over: Partial<Spec> = {}): PackageFacts => built(over).facts;

/** An object store holding `list` under the keys `q/<index>`, and the file entries that name them, as begin-upload declares them. */
function archives(list: Array<ReturnType<typeof built>>) {
  const objects = new Map(list.map((a, i) => [`q/${i}`, a.bytes]));
  return {
    objects: { get: async (key: string) => objects.get(key) },
    files: list.map((a, i) => ({ key: `q/${i}`, subdir: a.req.subdir, filename: a.req.filename, sha256: createHash('sha256').update(a.bytes).digest('hex') })),
  };
}

const run = (list: Array<ReturnType<typeof built>>) => {
  const a = archives(list);
  return validateArchives(a.objects, undefined, { name: NAME, version: '1.0.0' }, a.files);
};

const rejection = async (p: Promise<unknown>): Promise<Rejected> => {
  try {
    await p;
  } catch (e) {
    expect(e).toBeInstanceOf(Rejected);
    return e as Rejected;
  }
  throw new Error('expected a rejection');
};

describe('validateArchives: the files of a version need not be one build', () => {
  test('files built with different compilers, one per platform, are accepted: the facts come back in the order of the files', async () => {
    const facts = await run([built({ subdir: 'linux-64', compiler: '1.1.0' }), built({ subdir: 'osx-arm64', compiler: '1.0.0' })]);
    expect(facts.map((f) => [f.subdir, f.build])).toEqual([
      ['linux-64', 'mojo1.1.0_0'],
      ['osx-arm64', 'mojo1.0.0_0'],
    ]);
  });

  test('two builds for one platform are accepted', async () => {
    const facts = await run([built({ subdir: 'noarch', compiler: '1.0.0' }), built({ subdir: 'noarch', compiler: '1.1.0' })]);
    expect(facts.map((f) => f.build)).toEqual(['mojo1.0.0_0', 'mojo1.1.0_0']);
  });

  test('files that disagree on the system libraries they require are manifest_invalid, naming both files', async () => {
    const e = await rejection(run([built({ subdir: 'linux-64' }), built({ subdir: 'osx-arm64', compiler: '1.1.0', index: { depends: ['mojo-compiler ==1.1.0', 'lz4-c >=1.9.3'] } })]));
    expect(e.code).toBe('manifest_invalid');
    expect(e.message).toBe('mojo-komira-ai.json-1.0.0-mojo1.1.0_0.conda disagrees with mojo-komira-ai.json-1.0.0-mojo1.0.0_0.conda on dependencies, native libraries or manifest');
  });

  test('files that disagree on the manifest (the dependencies it declares) are manifest_invalid', async () => {
    const e = await rejection(run([built({ subdir: 'linux-64' }), built({ subdir: 'osx-arm64', compiler: '1.1.0', mopm: { source_sha256: SOURCE, deps: [{ name: 'komira-ai/other', range: '>=1' }] }, index: { depends: ['mojo-compiler ==1.1.0', 'mojo-komira-ai.other >=1'] } })]));
    expect(e).toMatchObject({ code: 'manifest_invalid', message: 'mojo-komira-ai.json-1.0.0-mojo1.1.0_0.conda disagrees with mojo-komira-ai.json-1.0.0-mojo1.0.0_0.conda on dependencies, native libraries or manifest' });
  });

  test('two files that are the same build for the same platform are manifest_invalid, naming both', async () => {
    const a = built({ subdir: 'linux-64' });
    const e = await rejection(run([a, a]));
    expect(e).toMatchObject({ code: 'manifest_invalid', message: 'mojo-komira-ai.json-1.0.0-mojo1.0.0_0.conda and mojo-komira-ai.json-1.0.0-mojo1.0.0_0.conda are both the mojo1.0.0_0 build for linux-64' });
  });

  test('the same build on two platforms is not a repeat', async () => {
    expect(await run([built({ subdir: 'linux-64' }), built({ subdir: 'osx-arm64' })])).toHaveLength(2);
  });

  test('an archive that is missing from quarantine is archive_invalid', async () => {
    const e = await rejection(validateArchives({ get: async () => undefined }, undefined, { name: NAME, version: '1.0.0' }, [{ key: 'k', subdir: 'noarch', filename: 'f.conda', sha256: '' }]));
    expect(e).toMatchObject({ code: 'archive_invalid', message: 'the upload of f.conda is missing from quarantine' });
  });
});

describe('fillFrom: build and requires_mojo are the primary build\'s', () => {
  const declared = (a: PackageFacts) => ({ subdir: a.subdir, filename: `mojo-komira-ai.json-1.0.0-${a.build}.conda`, sha256: '1'.repeat(64), size: 10 });
  const fill = (facts: PackageFacts[]) =>
    fillFrom('https://conda.example.invalid/', new Date('2026-11-21T10:00:00Z'), NAME, { version: '1.0.0', published_by: 'octocat' }, facts.map(declared), facts);

  test('the lowest compiler gives the build, whatever the order of the files', () => {
    const hi = factsOf({ subdir: 'linux-64', compiler: '1.10.0' });
    const lo = factsOf({ subdir: 'osx-arm64', compiler: '1.2.0' });
    for (const facts of [[hi, lo], [lo, hi]]) {
      expect(fill(facts)).toMatchObject({ build: 'mojo1.2.0_0', requires_mojo: '==1.2.0' });
    }
  });

  test('a single build is that build, and the files keep the order they were declared in', () => {
    const a = factsOf({ subdir: 'linux-64', compiler: '1.0.0' });
    const b = factsOf({ subdir: 'osx-arm64', compiler: '1.0.0' });
    const out = fill([a, b]);
    expect(out).toMatchObject({ build: 'mojo1.0.0_0', requires_mojo: '==1.0.0', manifest_sha256: a.manifestSha256, published_by: 'octocat', published_at: '2026-11-21T10:00:00.000Z' });
    expect(out.files!.map((f) => f.subdir)).toEqual(['linux-64', 'osx-arm64']);
  });

  test('the filled files carry the urls of the channel, and every build\'s file is among them', () => {
    const out = fill([factsOf({ subdir: 'linux-64', compiler: '1.1.0' }), factsOf({ subdir: 'linux-64', compiler: '1.0.0' })]);
    expect(out.files!.map((f) => f.url)).toEqual([
      'https://conda.example.invalid/komira-ai/linux-64/mojo-komira-ai.json-1.0.0-mojo1.1.0_0.conda',
      'https://conda.example.invalid/komira-ai/linux-64/mojo-komira-ai.json-1.0.0-mojo1.0.0_0.conda',
    ]);
  });
});

describe('checkAddedBuild', () => {
  /** The published version, as the store lists it: built with Mojo 1.0.0 from the source `SOURCE`. */
  const base = (over: Partial<VersionRecord> = {}): VersionRecord => {
    const f = factsOf({ subdir: 'linux-64', compiler: '1.0.0' });
    return rec({
      name: NAME,
      version: '1.0.0',
      build: 'mojo1.0.0_0',
      requires_mojo: '==1.0.0',
      manifest_sha256: f.manifestSha256,
      native_depends: f.nativeDepends,
      files: [buildFile(NAME, '1.0.0', 'mojo1.0.0_0')],
      ...over,
    });
  };
  const added = (over: Partial<Spec> = {}) => [factsOf({ subdir: 'linux-64', compiler: '1.1.0', ...over })];
  const message = (fn: () => void) => {
    try {
      fn();
    } catch (e) {
      expect(e).toBeInstanceOf(Rejected);
      expect((e as Rejected).code).toBe('manifest_invalid');
      return (e as Rejected).message;
    }
    throw new Error('expected a rejection');
  };

  test('a new build from the same source, with the same system libraries, is accepted: one platform or several', () => {
    expect(() => checkAddedBuild(base(), added())).not.toThrow();
    expect(() => checkAddedBuild(base(), [...added(), ...added({ subdir: 'osx-arm64' })])).not.toThrow();
  });

  test('a build lower than the version\'s own is accepted too', () => {
    expect(() => checkAddedBuild(base({ build: 'mojo1.2.0_0', files: [buildFile(NAME, '1.0.0', 'mojo1.2.0_0')] }), added({ compiler: '1.1.0' }))).not.toThrow();
  });

  test('files of two builds in one publish are refused: one build is added per publish', () => {
    expect(message(() => checkAddedBuild(base(), [factsOf({ subdir: 'linux-64', compiler: '1.1.0' }), factsOf({ subdir: 'osx-arm64', compiler: '1.2.0' })]))).toBe(
      'a build added to a version is one build per publish, and these files are of mojo1.1.0_0, mojo1.2.0_0',
    );
  });

  test('a build the version already has is refused: a published file is never replaced', () => {
    expect(message(() => checkAddedBuild(base(), added({ compiler: '1.0.0', subdir: 'osx-arm64' })))).toBe('komira-ai/json 1.0.0 already has the mojo1.0.0_0 build; a published file is never replaced');
    // Also a build that an earlier add brought.
    const [folded] = [{ ...base(), files: [...base().files, ...buildRow(NAME, '1.0.0', 'mojo1.1.0_0').files] }];
    expect(message(() => checkAddedBuild(folded!, added()))).toContain('already has the mojo1.1.0_0 build');
    expect(buildsOf(folded!).map((b) => b.build)).toEqual(['mojo1.0.0_0', 'mojo1.1.0_0']);
  });

  test('a build with another manifest is refused, naming both hashes and saying the build must come from the same source', () => {
    const other = added({ mopm: { source_sha256: '6'.repeat(64) } });
    const m = message(() => checkAddedBuild(base(), other));
    expect(m).toBe(
      `the linux-64 file has manifest ${other[0]!.manifestSha256} but komira-ai/json 1.0.0 has ${base().manifest_sha256}: a build added to a version must come from the same source: the same <import>.mopm.json, including source_sha256`,
    );
  });

  test('a version whose metadata has no source digest can get no added build', () => {
    const plain = (compiler: string) => factsOf({ subdir: 'linux-64', compiler, mopm: {} });
    const old = base({ manifest_sha256: plain('1.0.0').manifestSha256 });
    expect(message(() => checkAddedBuild(old, [plain('1.1.0')]))).toBe('komira-ai/json 1.0.0 carries no source digest, so no build can be added to it: publish a new version');
  });

  test('a build that requires other system libraries than the version is refused, naming both lists', () => {
    const more = added({ index: { depends: ['mojo-compiler ==1.1.0', 'lz4-c >=1.9.3'] } });
    expect(message(() => checkAddedBuild(base(), more))).toBe('the linux-64 file requires the system libraries [lz4-c >=1.9.3] but komira-ai/json 1.0.0 requires []');
    const withLib = base({ native_depends: ['lz4-c >=1.9.3'] });
    expect(message(() => checkAddedBuild(withLib, added()))).toBe('the linux-64 file requires the system libraries [] but komira-ai/json 1.0.0 requires [lz4-c >=1.9.3]');
    // A row written before the field existed requires none.
    const { native_depends: _n, ...legacy } = base();
    expect(() => checkAddedBuild(legacy as VersionRecord, added())).not.toThrow();
  });

  test('no file at all has nothing to refuse', () => {
    expect(() => checkAddedBuild(base(), [])).not.toThrow();
  });
});
