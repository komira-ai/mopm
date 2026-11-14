import { validatePackage } from '../../src/validate';
import type { PublishExpectation, RuleCode, ValidatorOptions, Verdict } from '../../src/validate';
import { buildConda } from './builder';
import type { Built, Spec } from './builder';

const check = (b: Built, over: Partial<PublishExpectation> = {}, opts: ValidatorOptions = {}): Verdict => validatePackage(b.bytes, { ...b.req, ...over }, opts);

function refusal(v: Verdict, rule: RuleCode): string {
  expect(v.ok).toBe(false);
  if (v.ok) throw new Error('accepted');
  expect(v.rule).toBe(rule);
  return v.message;
}

const FULL = 'acme/demo';
const full = (over: Partial<Spec> = {}): Built => buildConda({ name: FULL, ...over });

describe('a package of a full name', () => {
  test('is accepted: conda name, import-name paths, schema 2 and full-name dependencies', () => {
    const b = full({
      mopm: { deps: [{ name: 'other-org/json', range: '>=1' }] },
      index: { depends: ['mojo-compiler ==1.0.0', 'mojo-other-org.json >=1'] },
    });
    expect(b.req.filename).toBe('mojo-acme.demo-1.0.0-mojo1.0.0_0.conda');
    const v = check(b);
    expect(v.ok).toBe(true);
    if (!v.ok) return;
    expect(v.facts).toMatchObject({ name: FULL, mojoDeps: ['mojo-other-org.json'], metadata: { name: FULL, deps: [{ name: 'other-org/json', range: '>=1' }] } });
    expect(v.facts.files.map((f) => f.path).sort()).toEqual(['info/index.json', 'info/licenses/LICENSE', 'lib/mojo/demo.mojoc', 'lib/mojo/demo.mopm.json']);
  });

  test('a package with no dependencies is accepted', () => {
    expect(check(full()).ok).toBe(true);
  });

  test('paths under the full name instead of the import name are refused', () => {
    const b = full({ drop: ['lib/mojo/demo.mojoc', 'lib/mojo/demo.mopm.json'], pkgExtra: [{ path: 'lib/mojo/acme/demo.mojoc', data: 'x' }] });
    refusal(check(b), 'layout_not_allowed');
  });

  test('a missing import-name archive is named by its path', () => {
    expect(refusal(check(full({ drop: ['lib/mojo/demo.mojoc'] })), 'mojoc_missing')).toBe('lib/mojo/demo.mojoc is missing');
    expect(refusal(check(full({ drop: ['lib/mojo/demo.mopm.json'] })), 'manifest_missing')).toBe('lib/mojo/demo.mopm.json is missing');
  });

  test('a flat conda name in info/index.json is refused naming the conda name', () => {
    expect(refusal(check(full({ index: { name: 'mojo-demo' } })), 'name_mismatch')).toBe("info/index.json name 'mojo-demo' is not 'mojo-acme.demo'");
  });

  test('a file named for the flat name or the slash form is refused', () => {
    refusal(check(full(), { filename: 'mojo-demo-1.0.0-mojo1.0.0_0.conda' }), 'filename_mismatch');
    refusal(check(full(), { filename: 'mojo-acme-demo-1.0.0-mojo1.0.0_0.conda' }), 'filename_mismatch');
  });

  test('schema 1 metadata is refused, naming schema 2', () => {
    expect(refusal(check(full({ mopm: { schema: 1 } })), 'manifest_schema')).toBe("<name>.mopm.json: 'schema' must be 2");
  });

  test('a metadata name that is not the full name is refused', () => {
    refusal(check(full({ mopm: { name: 'demo' } })), 'name_mismatch');
  });

  test('a dependency name that is not a full name is refused in schema 2', () => {
    const msg = refusal(check(full({ mopm: { deps: [{ name: 'json' }] }, index: { depends: ['mojo-compiler ==1.0.0', 'mojo-json'] } })), 'manifest_schema');
    expect(msg).toBe("<name>.mopm.json: dependency 'json' is not a full name <namespace>/<name>");
  });

  test('depends naming a conda package of another namespace that deps does not declare is refused', () => {
    const b = full({ mopm: { deps: [{ name: 'other-org/json' }] }, index: { depends: ['mojo-compiler ==1.0.0', 'mojo-third.json'] } });
    refusal(check(b), 'deps_mismatch');
  });

  test('depends naming the flat mojo-x for a full-name dependency is refused', () => {
    const b = full({ mopm: { deps: [{ name: 'other-org/json' }] }, index: { depends: ['mojo-compiler ==1.0.0', 'mojo-json'] } });
    refusal(check(b), 'deps_mismatch');
  });

  test('a declared full-name dependency missing from depends is refused', () => {
    refusal(check(full({ mopm: { deps: [{ name: 'other-org/json' }] } })), 'deps_mismatch');
  });
});

describe('a package of a flat name', () => {
  test('schema 2 metadata is refused, naming schema 1', () => {
    const b = buildConda({ mopm: { schema: 2 } });
    expect(refusal(check(b), 'manifest_schema')).toBe("<name>.mopm.json: 'schema' must be 1");
  });
});
