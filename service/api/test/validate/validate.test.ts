import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import fc from 'fast-check';
import { DEFAULT_LIMITS } from '../../src/validate/limits';
import { validatePackage, RULE_TO_REJECTION } from '../../src/validate';
import type { PublishExpectation, RejectionCode, RuleCode, ValidatorOptions, Verdict } from '../../src/validate';
import { METADATA_SCHEMA_VERSION, NATIVE_KINDS, NATIVE_MODES, SONAME_PATTERN } from '../../src/validate/metadata';
import { buildConda, buildTarBz2, bzip2, tar, zip, zst, zstdRleBomb } from './builder';
import type { Built, Spec } from './builder';

const sha = (b: Uint8Array) => createHash('sha256').update(b).digest('hex');

function check(b: Built, over: Partial<PublishExpectation> = {}, opts: ValidatorOptions = {}): Verdict {
  return validatePackage(b.bytes, { ...b.req, ...over }, opts);
}

/** Assert refusal with this exact rule and the contract code it maps to. */
function refused(v: Verdict, rule: RuleCode, rejection?: RejectionCode): void {
  expect(v.ok).toBe(false);
  if (v.ok) return;
  expect({ rule: v.rule, rejection: v.rejection_code, message: v.message }).toEqual({
    rule,
    rejection: rejection ?? RULE_TO_REJECTION[rule],
    message: expect.any(String),
  });
}

const refusedBuild = (over: Partial<Spec>, rule: RuleCode, opts: ValidatorOptions = {}) => refused(check(buildConda(over), {}, opts), rule);

const REQ = { name: 'demo', version: '1.0.0', subdir: 'noarch', filename: 'mojo-demo-1.0.0-mojo1.0.0_0.conda' };
const BZ_REQ = { ...REQ, filename: 'mojo-demo-1.0.0-mojo1.0.0_0.tar.bz2' };
const BOTH = { allowedFormats: ['conda', 'tar.bz2'] } as const;

describe('a valid package', () => {
  test('is accepted, and the verdict carries the facts the registry needs', () => {
    const b = buildConda();
    const v = check(b, { sha256: sha(b.bytes) });
    expect(v.ok).toBe(true);
    if (!v.ok) return;
    expect(v.facts).toMatchObject({
      format: 'conda',
      name: 'demo',
      version: '1.0.0',
      build: 'mojo1.0.0_0',
      compiler: '1.0.0',
      subdir: 'noarch',
      mojoDeps: [],
    });
    expect(v.facts.files.map((f) => f.path).sort()).toEqual([
      'info/index.json',
      'info/licenses/LICENSE',
      'lib/mojo/demo.mojoc',
      'lib/mojo/demo.mopm.json',
    ]);
  });

  test('with a native library, a mojo dependency and directory entries', () => {
    const b = buildConda({
      mopm: { deps: [{ name: 'json', range: '>=1' }], native: [{ id: 'foo', soname: 'libfoo.so.1', file: '../libfoo.so.1.2' }] },
      index: { depends: ['mojo-compiler ==1.0.0', 'mojo-json >=1'] },
      pkgExtra: [
        { path: 'lib/', type: '5' },
        { path: 'lib/mojo/', type: '5' },
        { path: 'lib/libfoo.so.1.2', data: 'ELF' },
      ],
      infoExtra: [
        { path: 'info/licenses/', type: '5' },
        { path: 'info/about.json', data: '{}' },
      ],
    });
    const v = check(b);
    expect(v).toMatchObject({ ok: true });
    if (v.ok) expect(v.facts.mojoDeps).toEqual(['mojo-json']);
  });

  test('with kind both, a shared and a static file', () => {
    const b = buildConda({
      mopm: { native: [{ id: 'bar', soname: 'libbar.so', kind: 'both', file: '../libbar.so', static_file: '../libbar.a' }] },
      pkgExtra: [
        { path: 'lib/libbar.so', data: 'x' },
        { path: 'lib/libbar.a', data: 'y' },
      ],
    });
    expect(check(b).ok).toBe(true);
  });

  test('an allow-listed native dependency in depends is accepted, and refused when the list is empty', () => {
    const b = buildConda({ index: { depends: ['mojo-compiler ==1.0.0', 'openssl >=3'] } });
    expect(check(b, {}, { allowedNativeDeps: new Set(['openssl']) }).ok).toBe(true);
    refused(check(b), 'dependency_not_allowed');
  });

  test('a .tar.bz2 is accepted only when the formats allow it', () => {
    const b = buildTarBz2();
    expect(check(b, {}, BOTH)).toMatchObject({ ok: true, facts: { format: 'tar.bz2' } });
    refused(check(b), 'format_not_allowed');
  });
});

describe('what the publisher declared', () => {
  test('sha256 of the archive', () => {
    const b = buildConda();
    expect(check(b, { sha256: sha(b.bytes) }).ok).toBe(true);
    refused(check(b, { sha256: '0'.repeat(64) }), 'sha256_mismatch');
  });
  test('manifest_sha256 must be the hash of the embedded metadata', () => {
    const text = JSON.stringify({ schema: 1, name: 'demo', version: '1.0.0' });
    const b = buildConda({ mopm: text });
    expect(check(b, { manifestSha256: sha(Buffer.from(text)) }).ok).toBe(true);
    refused(check(b, { manifestSha256: '1'.repeat(64) }), 'manifest_sha256_mismatch');
  });
  test('filename', () => {
    const b = buildConda();
    refused(check(b, { filename: 'mojo-demo-1.0.0-mojo9.9.9_0.conda' }), 'filename_mismatch');
    refused(check(b, { filename: 'mojo-demo-1.0.1-mojo1.0.0_0.conda' }), 'filename_mismatch');
  });
  test('name, version and subdir of the request against the archive', () => {
    const b = buildConda();
    refused(check(b, { name: 'other', filename: 'mojo-other-1.0.0-mojo1.0.0_0.conda' }), 'layout_not_allowed');
    refused(check(b, { version: '2.0.0', filename: 'mojo-demo-2.0.0-mojo1.0.0_0.conda' }), 'version_mismatch');
    refused(check(b, { subdir: 'linux-64' }), 'subdir_mismatch');
  });
  test('the metadata name and version must be the published ones', () => {
    refusedBuild({ mopm: { name: 'other' } }, 'name_mismatch');
    refusedBuild({ mopm: { version: '1.0.1' } }, 'version_mismatch');
    refusedBuild({ index: { name: 'mojo-other' } }, 'name_mismatch');
    refusedBuild({ index: { version: '1.0.1' } }, 'version_mismatch');
  });
  test('versions compare under conda ordering, so 1.0 and 1.0.0 are the same', () => {
    expect(check(buildConda({ mopm: { version: '1.0' } })).ok).toBe(true);
  });
});

describe('size caps', () => {
  test('the default caps are pinned', () => {
    const msg = 'CEO decision 2026-10-14: a package is at most 100 MB; change only with a CEO decision';
    expect([msg, DEFAULT_LIMITS.maxArchiveBytes]).toEqual([msg, 100_000_000]);
    expect([msg, DEFAULT_LIMITS.maxUnpackedBytes]).toEqual([msg, 512 * 1024 * 1024]);
    expect(DEFAULT_LIMITS.maxFileBytes).toBeLessThanOrEqual(DEFAULT_LIMITS.maxUnpackedBytes);
  });
  test('at the default cap: 100,000,000 bytes is not refused for size, 100,000,001 is', () => {
    const big = Buffer.alloc(100_000_001);
    const exp = { name: 'demo', version: '1.0.0', subdir: 'noarch', filename: 'mojo-demo-1.0.0-mojo1.0.0_0.conda' };
    const at = validatePackage(big.subarray(0, 100_000_000), exp, {});
    if (!at.ok) expect(at.rule).not.toBe('archive_too_large');
    const over = validatePackage(big, exp, {});
    refused(over, 'archive_too_large', 'limit_exceeded');
  });
  test('archive size', () => {
    const b = buildConda();
    refused(check(b, {}, { limits: { maxArchiveBytes: b.bytes.length - 1 } }), 'archive_too_large');
    expect(check(b, {}, { limits: { maxArchiveBytes: b.bytes.length } }).ok).toBe(true);
  });
  test('per-file size', () => {
    const b = buildConda();
    expect(check(b, {}, { limits: { maxFileBytes: 1000 } }).ok).toBe(true);
    refused(check(b, {}, { limits: { maxFileBytes: 10 } }), 'file_too_large');
  });
  test('unpacked total', () => {
    const b = buildConda();
    refused(check(b, {}, { limits: { maxUnpackedBytes: 40 } }), 'unpacked_too_large');
  });
  test('file count', () => {
    const b = buildConda();
    refused(check(b, {}, { limits: { maxFiles: 3 } }), 'too_many_files');
    expect(check(b, {}, { limits: { maxFiles: 4 } }).ok).toBe(true);
  });
  test('metadata size', () => {
    refusedBuild({ mopm: { description: 'x'.repeat(500) } }, 'manifest_too_large', { limits: { maxMetadataBytes: 200 } });
  });
  test('a zip entry that deflates to a huge run of zeros is a bomb (ratio)', () => {
    const bomb = zip([{ name: 'metadata.json', data: Buffer.alloc(4 * 1024 * 1024), deflate: true }]);
    refused(validatePackage(bomb, REQ), 'compression_ratio');
  });
  test('a zstd stream of RLE blocks is a bomb, stopped long before it is fully expanded', () => {
    const big = zstdRleBomb(0x41, 300 * 1024 * 1024);
    expect(big.length).toBeLessThan(10000);
    refused(check(buildConda({ compress: () => big })), 'compression_ratio');
  });
  test('the same stream is stopped by the unpacked cap when the ratio guard is off', () => {
    const b = buildConda({ compress: () => zstdRleBomb(0x41, 8 * 1024 * 1024) });
    refused(check(b, {}, { limits: { maxRatio: 1e9, maxUnpackedBytes: 1024 * 1024 } }), 'unpacked_too_large');
  });
  test('a bzip2 bomb', () => {
    const bz = bzip2(tar([{ path: 'lib/mojo/demo.mojoc', data: Buffer.alloc(8 * 1024 * 1024) }]));
    expect(bz.length).toBeLessThan(1000);
    refused(validatePackage(bz, BZ_REQ, { allowedFormats: ['tar.bz2'] }), 'compression_ratio');
  });
});

/** One raw tar member (header and padded data) with an arbitrary type flag, for hand-built tars. */
function tarOne(path: string, type: string, data: Buffer): Buffer {
  const t = tar([{ path, type: '0', data }]);
  const hdr = Buffer.from(t.subarray(0, 512));
  hdr.write(type, 156, 1, 'latin1');
  hdr.fill(0x20, 148, 156);
  let sum = 0;
  for (const b of hdr) sum += b;
  hdr.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'latin1');
  return Buffer.concat([hdr, t.subarray(512, 512 + Math.ceil(data.length / 512) * 512)]);
}

/** A pax record "<len> key=value\n" where len counts its own digits. */
function paxRecord(key: string, value: string): string {
  const rest = ` ${key}=${value}\n`;
  let n = rest.length + 1;
  while (String(n).length + rest.length !== n) n = String(n).length + rest.length;
  return `${n}${rest}`;
}

describe('archive safety', () => {
  test.each([
    ['an absolute path', '/etc/passwd', 'path_absolute'],
    ['a Windows drive path', 'C:/Windows/x', 'path_absolute'],
    ['a parent directory', '../evil', 'path_traversal'],
    ['a parent directory in the middle', 'lib/mojo/../../evil', 'path_traversal'],
    ['a backslash', 'lib\\mojo\\x', 'path_unsafe'],
    ['a control character', 'lib/mojo/a\u0001b', 'path_unsafe'],
    ['an empty segment', 'lib//x', 'path_unsafe'],
  ] as const)('%s', (_n, path, rule) => {
    refusedBuild({ pkgExtra: [{ path, data: 'x' }] }, rule);
  });

  test('a symlink that escapes the root', () => {
    refusedBuild({ pkgExtra: [{ path: 'lib/mojo/link', type: '2', link: '../../../../etc/shadow' }] }, 'symlink');
  });
  test('a symlink that stays inside is refused too (the contract accepts none)', () => {
    refusedBuild({ pkgExtra: [{ path: 'lib/libfoo.so', type: '2', link: 'libfoo.so.1' }] }, 'symlink');
  });
  test('a hardlink', () => {
    refusedBuild({ pkgExtra: [{ path: 'lib/mojo/h', type: '1', link: 'lib/mojo/demo.mojoc' }] }, 'hardlink');
  });
  test.each(['3', '4', '6'])('a special file of type %s', (type) => {
    refusedBuild({ pkgExtra: [{ path: 'lib/mojo/dev', type }] }, 'special_file');
  });
  test('a repeated path', () => {
    refusedBuild({ pkgExtra: [{ path: 'lib/mojo/demo.mojoc', data: 'second' }] }, 'duplicate_path');
  });
  test('two names equal after Unicode normalisation (NFC versus NFD)', () => {
    refusedBuild(
      {
        infoExtra: [
          { path: 'info/licenses/caf\u00e9', data: 'a' },
          { path: 'info/licenses/cafe\u0301', data: 'b' },
        ],
      },
      'unicode_collision',
    );
  });
  test('two names equal under a compatibility form (ligature) or under case folding', () => {
    refusedBuild(
      {
        infoExtra: [
          { path: 'info/licenses/\ufb01le', data: 'a' },
          { path: 'info/licenses/file', data: 'b' },
        ],
      },
      'unicode_collision',
    );
    refusedBuild(
      {
        infoExtra: [
          { path: 'info/licenses/NOTICE', data: 'a' },
          { path: 'info/licenses/notice', data: 'b' },
        ],
      },
      'unicode_collision',
    );
  });
  test('a name in one tar that collides with a name in the other', () => {
    refusedBuild({ pkgExtra: [{ path: 'Info/index.json', data: '{}' }] }, 'unicode_collision');
  });
  test('a path carried in a pax header is checked like any other', () => {
    const members = Buffer.concat([
      tarOne('pax', 'x', Buffer.from(paxRecord('path', '../../outside'))),
      tarOne('lib/mojo/placeholder', '0', Buffer.from('x')),
      Buffer.alloc(1024),
    ]);
    refusedBuild({ pkgTar: () => members }, 'path_traversal');
  });
  test('a pax path that is fine is honoured (the member keeps the long name)', () => {
    const members = Buffer.concat([
      tarOne('pax', 'x', Buffer.from(paxRecord('path', 'lib/mojo/demo.mojoc'))),
      tarOne('short', '0', Buffer.from('MOJOC')),
      tarOne('lib/mojo/demo.mopm.json', '0', Buffer.from(JSON.stringify({ schema: 1, name: 'demo' }))),
      Buffer.alloc(1024),
    ]);
    expect(check(buildConda({ pkgTar: () => members })).ok).toBe(true);
  });
});

describe('layout allow-list', () => {
  test.each([
    ['bin/', 'bin/tool', 'bin_dir'],
    ['Scripts', 'Scripts/tool.exe', 'bin_dir'],
    ['a pre-link script in bin', 'bin/.pre-link.sh', 'link_script'],
    ['a post-link script', 'lib/mojo/demo-post-link.sh', 'link_script'],
    ['a pre-unlink script', 'lib/mojo/.pre-unlink.bat', 'link_script'],
    ['link.json', 'info/link.json', 'link_script'],
    ['activate.d', 'etc/conda/activate.d/x.sh', 'link_script'],
    ['a root file', 'README.md', 'layout_not_allowed'],
    ['a python file under lib', 'lib/evil.py', 'layout_not_allowed'],
    ['another package mojoc', 'lib/mojo/other.mojoc', 'layout_not_allowed'],
    ['a file in a lib subdirectory', 'lib/sub/libx.so', 'layout_not_allowed'],
    ['share', 'share/doc/x', 'layout_not_allowed'],
    ['an unknown info file', 'info/recipe/meta.yaml', 'layout_not_allowed'],
    ['a library name that is not one', 'lib/libfoo.so.1-evil', 'layout_not_allowed'],
  ] as const)('%s: %s', (_n, path, rule) => {
    const over: Partial<Spec> = path.startsWith('info/') ? { infoExtra: [{ path, data: 'x' }] } : { pkgExtra: [{ path, data: 'x' }] };
    refusedBuild(over, rule);
  });

  test('a directory outside the layout', () => {
    refusedBuild({ pkgExtra: [{ path: 'share', type: '5' }] }, 'layout_not_allowed');
  });
  test('a native library the metadata does not declare', () => {
    refusedBuild({ pkgExtra: [{ path: 'lib/libx.so', data: 'ELF' }] }, 'native_undeclared');
    refusedBuild({ pkgExtra: [{ path: 'lib/libx.dylib', data: 'x' }] }, 'native_undeclared');
    refusedBuild({ pkgExtra: [{ path: 'lib/libx.a', data: 'x' }] }, 'native_undeclared');
  });
  test('a declared native library that is missing', () => {
    refusedBuild({ mopm: { native: [{ id: 'foo', soname: 'libfoo.so', file: '../libfoo.so' }] } }, 'native_missing');
  });
  test('a declared file whose name does not fit its soname', () => {
    refusedBuild(
      { mopm: { native: [{ id: 'foo', soname: 'libfoo.so.1', file: '../libother.so' }] }, pkgExtra: [{ path: 'lib/libother.so', data: 'x' }] },
      'native_path',
    );
  });
  test.each(['../../etc/libfoo.so', '/lib/libfoo.so', '../sub/libfoo.so', 'libfoo.so'])(
    'a native path that does not resolve to lib/<file>: %s',
    (file) => {
      refusedBuild({ mopm: { native: [{ id: 'foo', soname: 'libfoo.so', file }] }, pkgExtra: [{ path: 'lib/libfoo.so', data: 'x' }] }, 'native_path');
    },
  );
  test('an info file in the pkg tar, and a lib file in the info tar', () => {
    refusedBuild({ pkgExtra: [{ path: 'info/about.json', data: '{}' }] }, 'conda_layout');
    refusedBuild({ infoExtra: [{ path: 'lib/mojo/extra', data: '{}' }] }, 'conda_layout');
  });
});

describe('metadata consistency', () => {
  test('missing files', () => {
    refusedBuild({ drop: ['lib/mojo/demo.mojoc'] }, 'mojoc_missing');
    refusedBuild({ drop: ['lib/mojo/demo.mopm.json'] }, 'manifest_missing');
    refusedBuild({ drop: ['info/index.json'] }, 'index_missing');
  });
  test('the metadata is not JSON, or not an object', () => {
    refusedBuild({ mopm: 'not json' }, 'manifest_json');
    refusedBuild({ mopm: '[1,2]' }, 'manifest_json');
    refusedBuild({ index: '{' }, 'index_invalid');
  });
  const bad: Array<[string, unknown]> = [
    ['a higher schema', { schema: 2, name: 'demo' }],
    ['no schema', { name: 'demo' }],
    ['no name', { schema: 1 }],
    ['an empty name', { schema: 1, name: '' }],
    ['a numeric version', { schema: 1, name: 'demo', version: 1 }],
    ['deps that are not an array', { schema: 1, name: 'demo', deps: {} }],
    ['a dep without a name', { schema: 1, name: 'demo', deps: [{}] }],
    ['a bad soname', { schema: 1, name: 'demo', native: [{ id: 'a', soname: 'foo.so', file: '../foo.so' }] }],
    ['a shared library without file', { schema: 1, name: 'demo', native: [{ id: 'a', soname: 'libfoo.so' }] }],
    ['a static library without static_file', { schema: 1, name: 'demo', native: [{ id: 'a', soname: 'libfoo.so', kind: 'static' }] }],
    ['a bad kind', { schema: 1, name: 'demo', native: [{ id: 'a', soname: 'libfoo.so', kind: 'weird', file: '../libfoo.so' }] }],
    ['a bad mode', { schema: 1, name: 'demo', native: [{ id: 'a', soname: 'libfoo.so', mode: 'x', file: '../libfoo.so' }] }],
    ['needs that is not strings', { schema: 1, name: 'demo', native: [{ id: 'a', soname: 'libfoo.so', file: '../libfoo.so', needs: [1] }] }],
  ];
  test.each(bad)('schema: %s', (_n, mopm) => {
    refusedBuild({ mopm: JSON.stringify(mopm) }, 'manifest_schema');
  });
  test('the same native id twice', () => {
    refusedBuild(
      {
        mopm: {
          native: [
            { id: 'a', soname: 'libfoo.so', file: '../libfoo.so' },
            { id: 'a', soname: 'libbar.so', file: '../libbar.so' },
          ],
        },
        pkgExtra: [
          { path: 'lib/libfoo.so', data: 'x' },
          { path: 'lib/libbar.so', data: 'x' },
        ],
      },
      'manifest_schema',
    );
  });
  const badIndex: Array<[string, Record<string, unknown>]> = [
    ['a build that is not mojo<compiler>_0', { build: 'py39_0' }],
    ['a nonzero build number', { build_number: 1 }],
    ['depends that is not a list', { depends: 'mojo-compiler ==1.0.0' }],
    ['a subdir that is not a string', { subdir: 5 }],
  ];
  test.each(badIndex)('info/index.json: %s', (_n, index) => {
    refusedBuild({ index }, 'index_invalid');
  });
  test('depends must name the compiler, exactly once, equal to the build string', () => {
    refusedBuild({ index: { depends: [] } }, 'compiler_missing');
    refusedBuild({ index: { depends: ['mojo-json'] }, mopm: { deps: [{ name: 'json' }] } }, 'compiler_missing');
    refusedBuild({ index: { depends: ['mojo-compiler ==1.0.1'] } }, 'compiler_mismatch');
    refusedBuild({ index: { depends: ['mojo-compiler >=1.0.0'] } }, 'compiler_mismatch');
    refusedBuild({ index: { depends: ['mojo-compiler ==1.0.0', 'mojo-compiler ==1.0.0'] } }, 'compiler_mismatch');
  });
  test('depends are mojo packages, the compiler and allow-listed libraries, and match the metadata deps', () => {
    refusedBuild({ index: { depends: ['mojo-compiler ==1.0.0', 'python >=3'] } }, 'dependency_not_allowed');
    refusedBuild({ index: { depends: ['mojo-compiler ==1.0.0', 'mojo-'] } }, 'dependency_not_allowed');
    refusedBuild({ index: { depends: ['mojo-compiler ==1.0.0', 'mojo-json'] } }, 'deps_mismatch');
    refusedBuild({ mopm: { deps: [{ name: 'json' }] } }, 'deps_mismatch');
  });
});

describe('not a package archive', () => {
  test('an arbitrary blob renamed .conda', () => {
    refused(validatePackage(Buffer.from('this is not an archive at all, just text'.repeat(40)), REQ), 'not_an_archive');
    refused(validatePackage(Buffer.alloc(4096, 0x41), REQ), 'not_an_archive');
    refused(validatePackage(Buffer.from([0xde, 0xad, 0xbe, 0xef, 1, 2, 3]), REQ), 'not_an_archive');
  });
  test('an empty upload', () => {
    refused(validatePackage(Buffer.alloc(0), REQ), 'not_an_archive');
  });
  test('a valid .tar.bz2 named .conda, and a valid .conda named .tar.bz2', () => {
    refused(validatePackage(buildTarBz2().bytes, REQ, BOTH), 'not_an_archive');
    refused(validatePackage(buildConda().bytes, BZ_REQ, BOTH), 'not_an_archive');
  });
  test('a zip signature followed by junk', () => {
    const buf = Buffer.concat([Buffer.from([0x50, 0x4b, 0x03, 0x04]), Buffer.alloc(200, 7)]);
    refused(validatePackage(buf, REQ), 'archive_corrupt');
  });
  test('a bzip2 signature followed by junk', () => {
    const buf = Buffer.concat([Buffer.from('BZh9'), Buffer.alloc(200, 7)]);
    refused(validatePackage(buf, BZ_REQ, { allowedFormats: ['tar.bz2'] }), 'archive_corrupt');
  });
  test('a truncated .conda', () => {
    const b = buildConda();
    refused(check({ ...b, bytes: b.bytes.subarray(0, b.bytes.length - 40) }), 'archive_corrupt');
  });
  test('a zip with a wrong CRC', () => {
    refused(validatePackage(zip([{ name: 'metadata.json', data: Buffer.from('{}'), crc: 1 }]), REQ), 'archive_corrupt');
  });
  test('an encrypted zip entry', () => {
    refused(validatePackage(zip([{ name: 'metadata.json', data: Buffer.from('{}'), flags: 1 }]), REQ), 'archive_corrupt');
  });
  test('a zip that repeats an entry name', () => {
    const d = Buffer.from('{}');
    refused(validatePackage(zip([{ name: 'metadata.json', data: d }, { name: 'metadata.json', data: d }]), REQ), 'archive_corrupt');
  });
  test('a .conda with the wrong members, or a wrong metadata.json', () => {
    const meta = Buffer.from('{"conda_pkg_format_version":2}');
    refused(validatePackage(zip([{ name: 'metadata.json', data: meta }]), REQ), 'conda_layout');
    const extra = zip([
      { name: 'metadata.json', data: meta },
      { name: 'pkg-a.tar.zst', data: zst(tar([])) },
      { name: 'info-a.tar.zst', data: zst(tar([])) },
      { name: 'evil.sh', data: Buffer.from('echo hi') },
    ]);
    refused(validatePackage(extra, REQ), 'conda_layout');
    refusedBuild({ condaMeta: '{"conda_pkg_format_version": 1}' }, 'conda_layout');
    refusedBuild({ condaMeta: 'null' }, 'conda_layout');
  });
  test('a tar that is damaged', () => {
    refusedBuild({ pkgTar: () => tar([{ path: 'lib/mojo/demo.mojoc', data: 'x' }], { badChecksum: true }) }, 'tar_header');
    refusedBuild({ pkgTar: () => tar([{ path: 'lib/mojo/demo.mojoc', data: 'x'.repeat(2000) }], { truncate: 1000 }) }, 'tar_header');
    refusedBuild({ pkgTar: (t) => Buffer.concat([t, Buffer.from('trailing garbage')]) }, 'tar_header');
  });
  test('compressed members that are not zstd', () => {
    refusedBuild({ compress: () => Buffer.from('not zstd at all, no way') }, 'archive_corrupt');
  });
});

describe('the verdict codes are the contract', () => {
  test('every rejection code a rule maps to is in the contract RejectionCode enum', () => {
    const yaml = readFileSync(join(__dirname, '../../../../spec/api/openapi.yaml'), 'utf8');
    const block = /RejectionCode:[\s\S]*?enum:\n((?:\s+- \w+\n)+)/.exec(yaml);
    expect(block).not.toBeNull();
    const allowed = new Set(
      (block as RegExpExecArray)[1]
        .split('\n')
        .map((l) => l.replace(/^\s+- /, ''))
        .filter(Boolean),
    );
    expect(allowed.size).toBeGreaterThanOrEqual(7);
    for (const [rule, code] of Object.entries(RULE_TO_REJECTION)) expect([rule, allowed.has(code)]).toEqual([rule, true]);
  });
  test('the constants the validator hand-codes match spec/package-metadata.schema.json', () => {
    const schema = JSON.parse(readFileSync(join(__dirname, '../../../../spec/package-metadata.schema.json'), 'utf8'));
    expect(schema.properties.schema.const).toBe(METADATA_SCHEMA_VERSION);
    expect(schema.required).toEqual(['schema', 'name']);
    const native = schema.properties.native.items;
    expect(native.required).toEqual(['id', 'soname']);
    expect(native.properties.kind.enum).toEqual([...NATIVE_KINDS]);
    expect(native.properties.mode.enum).toEqual([...NATIVE_MODES]);
    expect(new RegExp(native.properties.soname.pattern).source).toBe(SONAME_PATTERN.source);
    expect(Object.keys(native.properties).sort()).toEqual(['file', 'id', 'kind', 'mode', 'needs', 'soname', 'static_file']);
    expect(Object.keys(schema.properties).sort()).toEqual(['deps', 'name', 'native', 'schema', 'version']);
  });
});

describe('robustness: no input makes the validator throw', () => {
  test('random bytes behind a zip or bzip2 signature', () => {
    fc.assert(
      fc.property(fc.uint8Array({ maxLength: 600 }), fc.constantFrom('PK\x03\x04', 'BZh9', 'BZh1', ''), (bytes, sig) => {
        const buf = Buffer.concat([Buffer.from(sig, 'latin1'), Buffer.from(bytes)]);
        return validatePackage(buf, REQ).ok === false && validatePackage(buf, BZ_REQ, BOTH).ok === false;
      }),
      { numRuns: 300 },
    );
  });
  test('a valid archive with one byte changed is judged, never thrown on', () => {
    const b = buildConda();
    fc.assert(
      fc.property(fc.nat(b.bytes.length - 1), fc.integer({ min: 1, max: 255 }), (at, x) => {
        const copy = Buffer.from(b.bytes);
        copy[at] ^= x;
        return typeof validatePackage(copy, b.req).ok === 'boolean';
      }),
      { numRuns: 400 },
    );
  });
  test('a valid bzip2 archive cut anywhere is refused, never thrown on', () => {
    const t = buildTarBz2();
    fc.assert(
      fc.property(fc.nat(t.bytes.length - 2), (cut) => validatePackage(t.bytes.subarray(0, cut + 1), t.req, { allowedFormats: ['tar.bz2'] }).ok === false),
      { numRuns: 200 },
    );
  });
});
