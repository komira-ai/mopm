import { createHash } from 'node:crypto';
import { bunzip2 } from './bzip2';
import { Collector } from './collector';
import { fail, RULE_TO_REJECTION, ValidationFailure } from './codes';
import type { RejectionCode, RuleCode } from './codes';
import { checkCollisions, classify } from './layout';
import type { Role } from './layout';
import { DEFAULT_LIMITS } from './limits';
import type { Limits } from './limits';
import { checkDepends, checkIndex, checkMopm, checkNativeNames, parseJsonObject, sameVersion } from './metadata';
import type { Mopm } from './metadata';
import { readTar } from './tar';
import type { Budget, TarEntry } from './tar';
import { unzstd } from './zstd-read';
import { readZip } from './zip';

export { DEFAULT_LIMITS } from './limits';
export type { Limits } from './limits';
export { RULE_TO_REJECTION } from './codes';
export type { RejectionCode, RuleCode } from './codes';

export type PackageFormat = 'conda' | 'tar.bz2';

/** What the publisher declared (begin-upload and commit); the archive must agree with every field. */
export interface PublishExpectation {
  name: string;
  version: string;
  subdir: string;
  filename: string;
  /** Hex sha256 declared at begin-upload. Checked when given. */
  sha256?: string;
  /** Hex sha256 declared at commit, taken to be of the bytes of `lib/mojo/<name>.mopm.json`. Checked when given. */
  manifestSha256?: string;
}

export interface ValidatorOptions {
  limits?: Partial<Limits>;
  /** Archive formats accepted. The channel publishes only `.conda`, so that is the default. */
  allowedFormats?: readonly PackageFormat[];
  /** Native library ids that may appear in `depends` (the maintained allow-list). Default: none. */
  allowedNativeDeps?: ReadonlySet<string>;
}

export interface PackageFacts {
  format: PackageFormat;
  name: string;
  version: string;
  build: string;
  compiler: string;
  subdir: string;
  /** Names of the `mojo-*` packages depended on, sorted, with the `mojo-` prefix. */
  mojoDeps: string[];
  metadata: Mopm;
  manifestSha256: string;
  files: Array<{ path: string; size: number }>;
  unpackedBytes: number;
}

export type Verdict =
  | { ok: true; facts: PackageFacts }
  | { ok: false; rejection_code: RejectionCode; rule: RuleCode; message: string; path?: string };

const ZIP_MAGIC = [0x50, 0x4b, 0x03, 0x04];
const BZIP2_MAGIC = [0x42, 0x5a, 0x68];
const sha256Hex = (b: Uint8Array) => createHash('sha256').update(b).digest('hex');
const startsWith = (b: Uint8Array, magic: number[]) => magic.every((m, i) => b[i] === m);

/**
 * Validate an uploaded package archive before it is committed. Pure: bytes in, verdict out, no I/O.
 * It never throws for a bad archive; a hostile or malformed one yields `{ok: false}` with a stable code.
 * (A defect in this code itself is not blamed on the archive: it propagates, for the caller to log as
 * an internal error.)
 */
export function validatePackage(archive: Uint8Array, expected: PublishExpectation, options: ValidatorOptions = {}): Verdict {
  const limits: Limits = { ...DEFAULT_LIMITS, ...options.limits };
  try {
    const buf = Buffer.from(archive.buffer, archive.byteOffset, archive.byteLength);
    return { ok: true, facts: run(buf, expected, options, limits) };
  } catch (e) {
    if (e instanceof ValidationFailure) {
      return { ok: false, rejection_code: RULE_TO_REJECTION[e.rule], rule: e.rule, message: e.message, path: e.path };
    }
    if (e instanceof RangeError) {
      return { ok: false, rejection_code: 'archive_invalid', rule: 'archive_corrupt', message: 'the archive is structurally damaged' };
    }
    throw e;
  }
}

function run(buf: Buffer, expected: PublishExpectation, options: ValidatorOptions, limits: Limits): PackageFacts {
  // 1. Size and declared hash.
  if (buf.length === 0) fail('not_an_archive', 'the upload is empty');
  if (buf.length > limits.maxArchiveBytes) {
    fail('archive_too_large', `the archive is ${buf.length} bytes; the limit is ${limits.maxArchiveBytes}`);
  }
  if (expected.sha256 !== undefined && sha256Hex(buf) !== expected.sha256.toLowerCase()) {
    fail('sha256_mismatch', 'the archive does not hash to the sha256 declared at begin-upload');
  }

  // 2. Which format it really is: the bytes decide, the name must agree.
  let format: PackageFormat;
  if (startsWith(buf, ZIP_MAGIC)) format = 'conda';
  else if (startsWith(buf, BZIP2_MAGIC)) format = 'tar.bz2';
  else return fail('not_an_archive', 'the upload is neither a .conda (zip) nor a .tar.bz2 archive');
  if (!expected.filename.endsWith(`.${format}`)) {
    fail('not_an_archive', `the bytes are a ${format} archive but the file is named '${expected.filename}'`);
  }
  if (!(options.allowedFormats ?? ['conda']).includes(format)) fail('format_not_allowed', `.${format} packages are not accepted`);

  // 3. Unpack with every cap live.
  const budget: Budget = { files: 0, bytes: 0 };
  const entries: TarEntry[] = [];
  const slack = limits.maxFiles * 2048 + 65536; // tar headers and padding on top of file bytes
  const tarOf = (compressed: Buffer, what: string, unpack: (c: Buffer, out: Collector, what: string) => void): TarEntry[] => {
    const out = new Collector(limits.maxUnpackedBytes - budget.bytes + slack, compressed.length, limits, what);
    unpack(compressed, out, what);
    return readTar(out.result(), limits, budget);
  };
  if (format === 'conda') {
    const zip = readZip(buf, limits, limits.maxUnpackedBytes + slack);
    const meta = zip.filter((z) => z.name === 'metadata.json');
    const pkg = zip.filter((z) => /^pkg-.+\.tar\.zst$/.test(z.name));
    const info = zip.filter((z) => /^info-.+\.tar\.zst$/.test(z.name));
    if (zip.length !== 3 || meta.length !== 1 || pkg.length !== 1 || info.length !== 1) {
      fail('conda_layout', 'a .conda holds exactly metadata.json, one pkg-*.tar.zst and one info-*.tar.zst');
    }
    let cm: Record<string, unknown> | null | undefined;
    try {
      cm = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(meta[0].data)) as Record<string, unknown> | null;
    } catch {
      cm = undefined;
    }
    if (cm === undefined || cm === null || cm.conda_pkg_format_version !== 2) {
      fail('conda_layout', 'metadata.json must be an object with conda_pkg_format_version 2');
    }
    const infoEntries = tarOf(info[0].data, info[0].name, unzstd);
    for (const e of infoEntries) {
      if (e.path.split('/', 1)[0] !== 'info') fail('conda_layout', `'${e.path}' is in the info tar but not under info/`, e.path);
    }
    const pkgEntries = tarOf(pkg[0].data, pkg[0].name, unzstd);
    for (const e of pkgEntries) {
      if (e.path.split('/', 1)[0] === 'info') fail('conda_layout', `'${e.path}' is in the pkg tar but under info/`, e.path);
    }
    entries.push(...infoEntries, ...pkgEntries);
  } else {
    entries.push(...tarOf(buf, 'the archive', bunzip2));
  }

  // 4. Names: collisions, then the layout allow-list.
  checkCollisions(entries);
  const roles = new Map<string, Role>();
  const byPath = new Map<string, TarEntry>();
  for (const e of entries) {
    roles.set(e.path, classify(e, expected.name));
    byPath.set(e.path, e);
  }
  const mojoc = byPath.get(`lib/mojo/${expected.name}.mojoc`);
  const mopmEntry = byPath.get(`lib/mojo/${expected.name}.mopm.json`);
  const indexEntry = byPath.get('info/index.json');
  if (!mojoc) fail('mojoc_missing', `lib/mojo/${expected.name}.mojoc is missing`);
  if (!mopmEntry) fail('manifest_missing', `lib/mojo/${expected.name}.mopm.json is missing`);
  if (!indexEntry) fail('index_missing', 'info/index.json is missing');
  const mopmFile = mopmEntry as TarEntry;
  const indexFile = indexEntry as TarEntry;
  for (const f of [mopmFile, indexFile]) {
    if (f.data.length > limits.maxMetadataBytes) fail('manifest_too_large', `'${f.path}' is ${f.data.length} bytes`, f.path);
  }

  // 5. Metadata consistency.
  const manifestSha256 = sha256Hex(mopmFile.data);
  if (expected.manifestSha256 !== undefined && manifestSha256 !== expected.manifestSha256.toLowerCase()) {
    fail('manifest_sha256_mismatch', 'the embedded metadata does not hash to the manifest_sha256 declared at commit');
  }
  const mopm = checkMopm(parseJsonObject(mopmFile.data, mopmFile.path, 'manifest_json'));
  if (mopm.name !== expected.name) fail('name_mismatch', `metadata name '${mopm.name}' is not the published name '${expected.name}'`);
  if (mopm.version !== undefined && !sameVersion(mopm.version, expected.version)) {
    fail('version_mismatch', `metadata version '${mopm.version}' is not the published version '${expected.version}'`);
  }
  const idx = checkIndex(parseJsonObject(indexFile.data, indexFile.path, 'index_invalid'));
  if (idx.name !== `mojo-${expected.name}`) fail('name_mismatch', `info/index.json name '${idx.name}' is not 'mojo-${expected.name}'`);
  if (!sameVersion(idx.version, expected.version)) {
    fail('version_mismatch', `info/index.json version '${idx.version}' is not the published version '${expected.version}'`);
  }
  if (idx.subdir !== expected.subdir) fail('subdir_mismatch', `info/index.json subdir '${idx.subdir}' is not '${expected.subdir}'`);
  const mojoDeps = checkDepends(idx, mopm, { allowedNativeDeps: options.allowedNativeDeps ?? new Set() });
  const wantFile = `mojo-${expected.name}-${expected.version}-${idx.build}.${format}`;
  if (expected.filename !== wantFile) {
    fail('filename_mismatch', `the file is named '${expected.filename}' but its metadata says '${wantFile}'`);
  }

  // 6. Native libraries: every declared file present, every library file declared.
  const claimed = new Set<string>();
  const ids = new Set<string>();
  for (const n of mopm.native) {
    if (ids.has(n.id)) fail('manifest_schema', `native id '${n.id}' is declared twice`);
    ids.add(n.id);
    checkNativeNames(n);
    for (const p of n.paths) {
      if (roles.get(p) !== 'native') fail('native_missing', `native '${n.id}' declares '${p}', which the package does not contain`, p);
      claimed.add(p);
    }
  }
  for (const [p, r] of roles) {
    if (r === 'native' && !claimed.has(p)) fail('native_undeclared', `'${p}' is a native library the metadata does not declare`, p);
  }

  return {
    format,
    name: expected.name,
    version: expected.version,
    build: idx.build,
    compiler: idx.compiler,
    subdir: idx.subdir,
    mojoDeps,
    metadata: mopm,
    manifestSha256,
    files: entries.filter((e) => e.kind === 'file').map((e) => ({ path: e.path, size: e.data.length })),
    unpackedBytes: budget.bytes,
  };
}
