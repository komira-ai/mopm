// Conformance of `mopm pack` with the registry's package validator.
//
//   node tests/pack_conformance/check.mjs <mopm> <service/api/dist-validate>
//
// Packs a small package with the built `mopm pack`, and runs the validator the
// registry runs on uploads (service/api/src/validate, bundled by `npm run build:validate-lib` to <dist>) on
// each file. A packer that disagrees with the registry about the zip, the
// tars, the zstd frames, index.json, <name>.mopm.json or the file name turns
// the first checks red. The planted defects after them show the validator is
// not vacuous: each must be refused with the one rule named here.
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const [mopm, dist] = process.argv.slice(2);
if (!mopm || !dist) {
  console.error('usage: node check.mjs <mopm> <service/api/dist-validate>');
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
          JSON.stringify(['info/index.json', 'info/paths.json', 'lib/mojo/confdemo.mojoc', 'lib/mojo/confdemo.mopm.json']) &&
        v.facts.files.find((f) => f.path === 'lib/mojo/confdemo.mojoc').size === mojoc.length,
      JSON.stringify(v.facts));
  }
}

// Planted defects: the package is right and the claim about it is wrong (or a byte is).
const noarch = packed.find((p) => p.path.includes('/noarch/'));
const bytes = readFileSync(noarch.path);
const refused = (name, archive, expected, rule, rejection) => {
  const v = validatePackage(archive, expected);
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

// A package that ships a static archive per platform: one .conda per subdir, each with lib/lib<stem>.a, the same
// <name>.mopm.json (so one manifest_sha256), and the platform's facts in info/about.json. The validator must accept
// both files, list the archive among the files, and see no native id among the dependencies.
mkdirSync(join(work, 'nat', 'linux'), { recursive: true });
mkdirSync(join(work, 'nat', 'osx'), { recursive: true });
writeFileSync(
  join(work, 'nat', 'mopm.toml'),
  '[package]\nname = "natdemo"\nversion = "2.4.0"\n\n[toolchain]\nmojo = "1.0.0"\n\n[native.nat_sys]\nkind = "static"\nneeds = ["libz.a"]\nexclusive = "libnat"\n',
);
writeFileSync(join(work, 'nat', 'natdemo.mojoc'), mojoc);
writeFileSync(join(work, 'nat', 'linux', 'libnat_sys.a'), '!<arch>\nlinux members\n');
writeFileSync(join(work, 'nat', 'osx', 'libnat_sys.a'), '!<arch>\nosx members\n');
const natOut = execFileSync(
  mopm,
  ['pack', '--compiler', '1.0.0',
    '--mojoc', `linux-64=${join(work, 'nat', 'natdemo.mojoc')}`, '--mojoc', `osx-arm64=${join(work, 'nat', 'natdemo.mojoc')}`,
    '--native', `nat_sys=linux-64:${join(work, 'nat', 'linux', 'libnat_sys.a')}`, '--native', `nat_sys=osx-arm64:${join(work, 'nat', 'osx', 'libnat_sys.a')}`,
    '--manifest', join(work, 'nat', 'mopm.toml'), '-o', join(work, 'natdist')],
  { encoding: 'utf8' },
);
const natPacked = [...natOut.matchAll(/packed (\S+)\n  sha256 ([0-9a-f]{64})\n  size (\d+)\n  manifest_sha256 ([0-9a-f]{64})/g)].map((m) => ({
  path: m[1], sha256: m[2], size: Number(m[3]), manifestSha256: m[4],
}));
check('native: pack printed two files', natPacked.length === 2, natOut);
check('native: both files carry the same metadata (one manifest_sha256)', natPacked.length === 2 && natPacked[0].manifestSha256 === natPacked[1].manifestSha256);
const natFile = 'mojo-natdemo-2.4.0-mojo1.0.0_0.conda';
for (const p of natPacked) {
  const subdir = p.path.split('/').slice(-2)[0];
  const nbytes = readFileSync(p.path);
  const v = validatePackage(nbytes, { name: 'natdemo', version: '2.4.0', subdir, filename: natFile, sha256: p.sha256, manifestSha256: p.manifestSha256 });
  check(`native ${subdir}: the validator accepts the package`, v.ok === true, JSON.stringify(v));
  if (v.ok) {
    check(`native ${subdir}: the archive is a file of the package, and no native id is a dependency`,
      JSON.stringify(v.facts.files.map((f) => f.path).sort()) ===
        JSON.stringify(['info/about.json', 'info/index.json', 'info/paths.json', 'lib/libnat_sys.a', 'lib/mojo/natdemo.mojoc', 'lib/mojo/natdemo.mopm.json']) &&
        JSON.stringify(v.facts.mojoDeps) === JSON.stringify([]),
      JSON.stringify(v.facts));
  }
}
if (natPacked.length === 2) {
  // Planted: a version that is not the metadata's is refused for a package with an archive as for any other.
  const nbytes = readFileSync(natPacked[0].path);
  refused('native: a version that is not the metadata\'s', nbytes, { name: 'natdemo', version: '2.4.1', subdir: natPacked[0].path.split('/').slice(-2)[0], filename: 'mojo-natdemo-2.4.1-mojo1.0.0_0.conda' }, 'version_mismatch', 'manifest_invalid');
}

console.log(failures === 0 ? 'pack conformance OK' : `${failures} failure(s)`);
process.exit(failures === 0 ? 0 : 1);
