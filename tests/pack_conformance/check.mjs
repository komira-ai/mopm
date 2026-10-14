// Conformance of `mopm pack` with the registry's package validator.
//
//   node tests/pack_conformance/check.mjs <mopm> <service/api/dist>
//
// Packs a small package with the built `mopm pack`, and runs the validator the
// registry runs on uploads (service/api/src/validate, compiled to <dist>) on
// each file. A packer that disagrees with the registry about the zip, the
// tars, the zstd frames, index.json, <name>.mopm.json or the file name turns
// the first checks red. The planted defects after them show the validator is
// not vacuous: each must be refused with the one rule named here. A second
// package ships a native library and depends on a native (system) library; the
// validator must accept it with its native facts, and refuse it once the
// allow-list lacks the dependency, the metadata stops declaring the library, or
// the declared file is not in the archive.
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const [mopm, dist] = process.argv.slice(2);
if (!mopm || !dist) {
  console.error('usage: node check.mjs <mopm> <service/api/dist>');
  process.exit(2);
}
const require = createRequire(import.meta.url);
const { validatePackage } = require(resolve(dist, 'validate/index.js'));

let failures = 0;
const check = (name, ok, detail = '') => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok ? '' : `: ${detail}`}`);
  if (!ok) failures++;
};
const sha256 = (b) => createHash('sha256').update(b).digest('hex');

const work = mkdtempSync(join(process.env.RUNNER_TEMP || tmpdir(), 'mopm-pack-'));
mkdirSync(join(work, 'pkg'));
writeFileSync(
  join(work, 'pkg', 'mopm.toml'),
  '[package]\nname = "confdemo"\nversion = "1.2.3"\n\n[toolchain]\nmojo = "1.0.0"\n\n[dependencies]\nconfdep = "^1.2"\nother_dep = ">=0.3, <0.5"\n',
);
// Bytes only: the validator does not open a .mojoc.
const mojoc = Buffer.alloc(300000);
for (let i = 0; i < mojoc.length; i++) mojoc[i] = (i * 31 + (i >> 7)) & 0xff;
writeFileSync(join(work, 'pkg', 'confdemo.mojoc'), mojoc);

const out = execFileSync(
  mopm,
  ['pack', '--compiler', '1.0.0', '--mojoc', join(work, 'pkg', 'confdemo.mojoc'), '--mojoc', `linux-64=${join(work, 'pkg', 'confdemo.mojoc')}`,
    '--manifest', join(work, 'pkg', 'mopm.toml'), '-o', join(work, 'dist')],
  { encoding: 'utf8' },
);
const packed = [...out.matchAll(/packed (\S+)\n  sha256 ([0-9a-f]{64})\n  size (\d+)\n  manifest_sha256 ([0-9a-f]{64})/g)].map((m) => ({
  path: m[1], sha256: m[2], size: Number(m[3]), manifestSha256: m[4],
}));
check('pack printed two files', packed.length === 2, out);

const filename = 'mojo-confdemo-1.2.3-mojo1.0.0_0.conda';
const expectation = (subdir, extra = {}) => ({ name: 'confdemo', version: '1.2.3', subdir, filename, ...extra });

for (const p of packed) {
  const subdir = p.path.split('/').slice(-2)[0];
  const bytes = readFileSync(p.path);
  check(`${subdir}: the printed sha256 and size are the file's`, sha256(bytes) === p.sha256 && bytes.length === p.size);
  const v = validatePackage(bytes, expectation(subdir, { sha256: p.sha256, manifestSha256: p.manifestSha256 }));
  check(`${subdir}: the validator accepts the package`, v.ok === true, JSON.stringify(v));
  if (v.ok) {
    check(`${subdir}: facts agree`,
      v.facts.compiler === '1.0.0' && v.facts.build === 'mojo1.0.0_0' && v.facts.subdir === subdir &&
        JSON.stringify(v.facts.mojoDeps) === JSON.stringify(['mojo-confdep', 'mojo-other_dep']) &&
        v.facts.manifestSha256 === p.manifestSha256 &&
        JSON.stringify(v.facts.files.map((f) => f.path).sort()) ===
          JSON.stringify(['info/index.json', 'lib/mojo/confdemo.mojoc', 'lib/mojo/confdemo.mopm.json']) &&
        v.facts.files.find((f) => f.path === 'lib/mojo/confdemo.mojoc').size === mojoc.length,
      JSON.stringify(v.facts));
  }
}

// Planted defects: the package is right and the claim about it is wrong (or a byte is).
const noarch = packed.find((p) => p.path.includes('/noarch/'));
const bytes = readFileSync(noarch.path);
const refused = (name, archive, expected, rule, rejection, options = {}) => {
  const v = validatePackage(archive, expected, options);
  check(`planted: ${name} is refused as ${rule}`, v.ok === false && v.rule === rule && v.rejection_code === rejection, JSON.stringify(v));
};
refused('a version that is not the metadata\'s', bytes, expectation('noarch', { version: '1.2.4' }), 'version_mismatch', 'manifest_invalid');
refused('a subdir that is not the index\'s', bytes, expectation('linux-64'), 'subdir_mismatch', 'manifest_invalid');
refused('another package name', bytes, { ...expectation('noarch'), name: 'otherdemo', filename: 'mojo-otherdemo-1.2.3-mojo1.0.0_0.conda' }, 'layout_not_allowed', 'path_not_allowed');
refused('a file name with another compiler', bytes, expectation('noarch', { filename: 'mojo-confdemo-1.2.3-mojo1.0.1_0.conda' }), 'filename_mismatch', 'filename_mismatch');
refused('a wrong manifest_sha256', bytes, expectation('noarch', { manifestSha256: '0'.repeat(64) }), 'manifest_sha256_mismatch', 'sha256_mismatch');
refused('a wrong sha256', bytes, expectation('noarch', { sha256: '0'.repeat(64) }), 'sha256_mismatch', 'sha256_mismatch');
const flipped = Buffer.from(bytes);
flipped[50] ^= 0xff; // inside metadata.json: the zip CRC-32 no longer holds
refused('a flipped byte', flipped, expectation('noarch'), 'archive_corrupt', 'archive_invalid');

// --- A package with a native library and a native dependency
const crcTable = new Uint32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc32 = (b) => {
  let c = 0xffffffff;
  for (let i = 0; i < b.length; i++) c = crcTable[(c ^ b[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
// A copy of a .conda with `edit` applied, in place, to the bytes of its pkg-*.tar.zst entry, and that
// entry's CRC-32 repaired in both zip headers. The packer stores everything, so the tar's text is there
// to be found, and `edit` must keep every length.
const editPkgEntry = (conda, edit) => {
  const b = Buffer.from(conda);
  const eocd = b.length - 22; // the packer writes no zip comment
  let p = b.readUInt32LE(eocd + 16);
  for (let i = 0, n = b.readUInt16LE(eocd + 10); i < n; i++) {
    const nameLen = b.readUInt16LE(p + 28);
    const lho = b.readUInt32LE(p + 42);
    if (b.toString('latin1', p + 46, p + 46 + nameLen).startsWith('pkg-')) {
      const data = b.subarray(lho + 30 + nameLen, lho + 30 + nameLen + b.readUInt32LE(p + 20));
      edit(data);
      b.writeUInt32LE(crc32(data), p + 16);
      b.writeUInt32LE(crc32(data), lho + 14);
      return b;
    }
    p += 46 + nameLen;
  }
  throw new Error('no pkg-*.tar.zst entry');
};
// Overwrite every `from` in data[start, end) with `to` (same length); returns how many.
const overwrite = (data, from, to, start = 0, end = data.length) => {
  if (from.length !== to.length) throw new Error('lengths differ');
  let count = 0;
  for (let at = data.indexOf(from, start); at >= 0 && at + from.length <= end; at = data.indexOf(from, at + 1)) {
    data.write(to, at, 'latin1');
    count++;
  }
  return count;
};

mkdirSync(join(work, 'nat'));
writeFileSync(
  join(work, 'nat', 'mopm.toml'),
  '[package]\nname = "natdemo"\nversion = "2.0.1"\n\n[toolchain]\nmojo = "1.0.0"\n\n[native.confnative]\nkind = "shared"\n\n[native-dependencies]\nconfsys = ">=1.0"\n',
);
writeFileSync(join(work, 'nat', 'natdemo.mojoc'), mojoc.subarray(0, 5000));
const solib = Buffer.alloc(70000);
for (let i = 0; i < solib.length; i++) solib[i] = (i * 17 + (i >> 5)) & 0xff;
writeFileSync(join(work, 'nat', 'libconfnat.so.1'), solib);
const natOut = execFileSync(
  mopm,
  ['pack', '--compiler', '1.0.0', '--mojoc', `linux-64=${join(work, 'nat', 'natdemo.mojoc')}`, '--native', `linux-64:confnative=${join(work, 'nat', 'libconfnat.so.1')}`,
    '--manifest', join(work, 'nat', 'mopm.toml'), '-o', join(work, 'natdist')],
  { encoding: 'utf8' },
);
const natPacked = natOut.match(/packed (\S+)\n  sha256 ([0-9a-f]{64})\n  size (\d+)\n  manifest_sha256 ([0-9a-f]{64})/);
check('pack printed the native package', natPacked !== null, natOut);
if (natPacked) {
  const natBytes = readFileSync(natPacked[1]);
  const natExpected = (extra = {}) => ({ name: 'natdemo', version: '2.0.1', subdir: 'linux-64', filename: 'mojo-natdemo-2.0.1-mojo1.0.0_0.conda', ...extra });
  const allow = { allowedNativeDeps: new Set(['confsys']) };
  const v = validatePackage(natBytes, natExpected({ sha256: natPacked[2], manifestSha256: natPacked[4] }), allow);
  check('native: the validator accepts a package with a native library and an allow-listed native dependency', v.ok === true, JSON.stringify(v));
  if (v.ok) {
    const decl = v.facts.metadata.native;
    check('native: the declared library agrees with the packed one',
      decl.length === 1 && decl[0].id === 'confnative' && decl[0].soname === 'libconfnat.so.1' && decl[0].kind === 'shared' &&
        decl[0].mode === 'link' && JSON.stringify(decl[0].paths) === JSON.stringify(['lib/libconfnat.so.1']),
      JSON.stringify(decl));
    check('native: the library is in the archive at its declared path with its full size, and mojo deps stay empty',
      JSON.stringify(v.facts.files.map((f) => f.path).sort()) ===
        JSON.stringify(['info/index.json', 'lib/libconfnat.so.1', 'lib/mojo/natdemo.mojoc', 'lib/mojo/natdemo.mopm.json']) &&
        v.facts.files.find((f) => f.path === 'lib/libconfnat.so.1').size === solib.length && v.facts.mojoDeps.length === 0,
      JSON.stringify(v.facts.files));
  }
  // The packer put 'confsys >=1.0' in depends; the registry's list decides, and it does not list it here.
  refused('a native dependency that is not on the allow-list', natBytes, natExpected(), 'dependency_not_allowed', 'dependency_not_allowed');
  refused('a native dependency when only other ids are allow-listed', natBytes, natExpected(), 'dependency_not_allowed', 'dependency_not_allowed',
    { allowedNativeDeps: new Set(['someotherlib']) });
  // The metadata stops declaring the library ("native" -> "nativx"); lib/libconfnat.so.1 is still in the archive.
  const undeclared = editPkgEntry(natBytes, (d) => {
    if (overwrite(d, '"native":[', '"nativx":[') !== 1) throw new Error('metadata key not found once');
  });
  refused('a lib/ file the metadata does not declare', undeclared, natExpected(), 'native_undeclared', 'path_not_allowed', allow);
  // The metadata names another file (file and soname together, so only the file's absence is wrong).
  const missing = editPkgEntry(natBytes, (d) => {
    const start = d.indexOf('"native":[');
    const end = d.indexOf('],"schema"', start);
    if (start < 0 || end < 0 || overwrite(d, 'libconfnat.so.1', 'libconfnaX.so.1', start, end) !== 2) throw new Error('metadata names not found twice');
  });
  refused('a declared native library whose file is not in the archive', missing, natExpected(), 'native_missing', 'manifest_invalid', allow);
}

console.log(failures === 0 ? 'pack conformance OK' : `${failures} failure(s)`);
process.exit(failures === 0 ? 0 : 1);
