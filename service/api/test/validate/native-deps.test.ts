import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { validatePackage, RULE_TO_REJECTION } from '../../src/validate';
import type { Verdict } from '../../src/validate';
import { DEPLOYED_VALIDATOR_OPTIONS, NATIVE_DEP_ALLOWLIST } from '../../src/validate/native-deps';
import { buildConda } from './builder';

const verdictFor = (dep: string): Verdict => {
  const b = buildConda({ index: { depends: ['mojo-compiler ==1.0.0', dep] } });
  return validatePackage(b.bytes, b.req, DEPLOYED_VALIDATOR_OPTIONS);
};

/** The conda package names `condaPackageFor` in pack (src/core/conda.zig) can map a native dependency to. */
function packMapOutputs(): string[] {
  const zig = readFileSync(join(__dirname, '../../../../src/core/conda.zig'), 'utf8');
  const body = /pub fn condaPackageFor[\s\S]*?const known = \[_\]\[2\]\[\]const u8\{([\s\S]*?)\};/.exec(zig);
  if (!body) throw new Error('condaPackageFor and its map were not found in src/core/conda.zig');
  const out = [...body[1]!.matchAll(/\.\{\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\}/g)].map((m) => m[2]!);
  if (out.length === 0) throw new Error('the map in condaPackageFor has no entries');
  return [...new Set(out)].sort();
}

describe('the native library allow-list of the deployed validators', () => {
  test('a package depending on lz4-c with a version range is accepted', () => {
    expect(verdictFor('lz4-c >=1.9.3,<2').ok).toBe(true);
  });

  test.each([...NATIVE_DEP_ALLOWLIST])('%s is accepted, bare and with a range', (name) => {
    expect(verdictFor(name).ok).toBe(true);
    expect(verdictFor(`${name} >=1,<99`).ok).toBe(true);
  });

  test('the id of a native library the package ships is not a dependency: naming it in depends is refused', () => {
    const b = buildConda({
      mopm: { native: [{ id: 'komira_libc_posix', soname: 'libkomira_libc_posix.a', kind: 'static', mode: 'link', static_file: '../libkomira_libc_posix.a' }] },
      pkgExtra: [{ path: 'lib/libkomira_libc_posix.a', data: '!<arch>\n' }],
      index: { depends: ['mojo-compiler ==1.0.0', 'komira_libc_posix'] },
    });
    const v = validatePackage(b.bytes, b.req, DEPLOYED_VALIDATOR_OPTIONS);
    expect(v.ok).toBe(false);
    if (!v.ok) expect(v.rule).toBe('dependency_not_allowed');
  });

  test('the facts name the loaded libraries of depends and not the libraries the package ships', () => {
    const shipped = {
      mopm: { native: [{ id: 'komira_libc_posix', soname: 'libkomira_libc_posix.a', kind: 'static', mode: 'link', static_file: '../libkomira_libc_posix.a' }] },
      pkgExtra: [{ path: 'lib/libkomira_libc_posix.a', data: '!<arch>\n' }],
    };
    const none = buildConda(shipped);
    const a = validatePackage(none.bytes, none.req, DEPLOYED_VALIDATOR_OPTIONS);
    expect(a.ok && a.facts.nativeDepends).toEqual([]);
    const both = buildConda({ ...shipped, index: { depends: ['zstd  >=1', 'mojo-compiler ==1.0.0', 'lz4-c'] } });
    const c = validatePackage(both.bytes, both.req, DEPLOYED_VALIDATOR_OPTIONS);
    expect(c.ok && c.facts.nativeDepends).toEqual(['lz4-c', 'zstd >=1']);
  });

  test.each(['openssl', 'python >=3', 'lz4 >=1', 'liblz4', 'zlib', 'lz4-c-extra', 'LZ4-C', 'aws-lc', 'sqlite', 'brotli', 'libbrotlienc', 'libbrotlicommon', 'libsnappy', 's2n'])('%s is refused with dependency_not_allowed', (dep) => {
    const v = verdictFor(dep);
    expect(v.ok).toBe(false);
    if (v.ok) return;
    expect(v.rule).toBe('dependency_not_allowed');
    expect(v.rejection_code).toBe(RULE_TO_REJECTION.dependency_not_allowed);
  });

  test('the library default stays empty, so only the deployed options allow native libraries', () => {
    const b = buildConda({ index: { depends: ['mojo-compiler ==1.0.0', 'lz4-c >=1.9.3,<2'] } });
    const v = validatePackage(b.bytes, b.req);
    expect(v.ok).toBe(false);
  });

  test('every conda name the pack map can emit is on the allow-list, and nothing else is', () => {
    expect(packMapOutputs()).toEqual([...NATIVE_DEP_ALLOWLIST].sort());
  });

  test('both deployed validators are wired with the deployed options', () => {
    for (const f of ['validator-lambda.ts', 'group-validator-lambda.ts']) {
      const src = readFileSync(join(__dirname, '../../src/publish', f), 'utf8');
      expect(src).toContain('validatorOptions: DEPLOYED_VALIDATOR_OPTIONS');
    }
  });
});
