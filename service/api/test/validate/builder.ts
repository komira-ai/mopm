import { execFileSync } from 'node:child_process';
import { deflateRawSync } from 'node:zlib';
import { crc32 } from '../../src/validate/zip';
import { zstdFrame } from '../../src/zstd';
import type { PublishExpectation } from '../../src/validate';

/** Test-side archive writers. Nothing here is a committed binary: every archive is generated per test. */

export interface TarItem {
  path: string;
  /** '0' file (default), '5' dir, '1' hardlink, '2' symlink, '3' char device, '4' block device, '6' fifo. */
  type?: string;
  data?: Buffer | string;
  link?: string;
}

const pad = (n: number) => (512 - (n % 512)) % 512;

function octalField(v: number, len: number): Buffer {
  return Buffer.from(v.toString(8).padStart(len - 1, '0') + '\0', 'latin1');
}

export function tarHeader(path: string, type: string, size: number, link = ''): Buffer {
  const h = Buffer.alloc(512);
  h.write(path, 0, 100, 'utf8');
  octalField(0o644, 8).copy(h, 100);
  octalField(0, 8).copy(h, 108);
  octalField(0, 8).copy(h, 116);
  octalField(size, 12).copy(h, 124);
  octalField(0, 12).copy(h, 136);
  h.fill(0x20, 148, 156);
  h.write(type, 156, 1, 'latin1');
  h.write(link, 157, 100, 'utf8');
  h.write('ustar\0', 257, 6, 'latin1');
  h.write('00', 263, 2, 'latin1');
  let sum = 0;
  for (const b of h) sum += b;
  h.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'latin1');
  return h;
}

export function tar(items: TarItem[], opts: { badChecksum?: boolean; truncate?: number } = {}): Buffer {
  const parts: Buffer[] = [];
  for (const it of items) {
    const data = Buffer.from(it.data ?? '');
    const type = it.type ?? '0';
    const withData = type === '0';
    const path = it.path.length > 100 ? it.path.slice(-100) : it.path;
    parts.push(tarHeader(path, type, withData ? data.length : 0, it.link ?? ''));
    if (withData) parts.push(data, Buffer.alloc(pad(data.length)));
  }
  parts.push(Buffer.alloc(1024));
  let out = Buffer.concat(parts);
  if (opts.badChecksum) out[148] = 0x39;
  if (opts.truncate !== undefined) out = out.subarray(0, opts.truncate);
  return out;
}

/** A zstd frame of raw (stored) blocks: valid, decodable, not compressed. */
export const zst = (b: Buffer) => zstdFrame(b);

/** A zstd frame that expands `total` bytes of `byte` from a few bytes per 128 KiB: a real decompression bomb. */
export function zstdRleBomb(byte: number, total: number): Buffer {
  const blocks = Math.ceil(total / 131072);
  const parts: Buffer[] = [Buffer.from([0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x38])];
  for (let i = 0; i < blocks; i++) {
    const size = Math.min(131072, total - i * 131072);
    const header = (i === blocks - 1 ? 1 : 0) | (1 << 1) | (size << 3);
    parts.push(Buffer.from([header & 0xff, (header >>> 8) & 0xff, (header >>> 16) & 0xff, byte]));
  }
  return Buffer.concat(parts);
}

export function bzip2(data: Buffer): Buffer {
  return execFileSync('bzip2', ['-c'], { input: data, maxBuffer: 64 * 1024 * 1024 });
}

export interface ZipItem {
  name: string;
  data: Buffer;
  deflate?: boolean;
  crc?: number;
  flags?: number;
}

export function zip(items: ZipItem[]): Buffer {
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let off = 0;
  for (const it of items) {
    const name = Buffer.from(it.name);
    const body = it.deflate ? deflateRawSync(it.data) : it.data;
    const method = it.deflate ? 8 : 0;
    const crc = it.crc ?? crc32(it.data);
    const flags = it.flags ?? 0;
    const lh = Buffer.alloc(30);
    lh.writeUInt32LE(0x04034b50, 0);
    lh.writeUInt16LE(20, 4);
    lh.writeUInt16LE(flags, 6);
    lh.writeUInt16LE(method, 8);
    lh.writeUInt16LE(0x21, 12);
    lh.writeUInt32LE(crc, 14);
    lh.writeUInt32LE(body.length, 18);
    lh.writeUInt32LE(it.data.length, 22);
    lh.writeUInt16LE(name.length, 26);
    const local = Buffer.concat([lh, name, body]);
    const ch = Buffer.alloc(46);
    ch.writeUInt32LE(0x02014b50, 0);
    ch.writeUInt16LE(20, 4);
    ch.writeUInt16LE(20, 6);
    ch.writeUInt16LE(flags, 8);
    ch.writeUInt16LE(method, 10);
    ch.writeUInt16LE(0x21, 14);
    ch.writeUInt32LE(crc, 16);
    ch.writeUInt32LE(body.length, 20);
    ch.writeUInt32LE(it.data.length, 24);
    ch.writeUInt16LE(name.length, 28);
    ch.writeUInt32LE(off, 42);
    centrals.push(Buffer.concat([ch, name]));
    locals.push(local);
    off += local.length;
  }
  const cd = Buffer.concat(centrals);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(items.length, 8);
  eocd.writeUInt16LE(items.length, 10);
  eocd.writeUInt32LE(cd.length, 12);
  eocd.writeUInt32LE(off, 16);
  return Buffer.concat([...locals, cd, eocd]);
}

export interface Spec {
  name: string;
  version: string;
  subdir: string;
  compiler: string;
  /** Extra items appended to the pkg tar / info tar. */
  pkgExtra: TarItem[];
  infoExtra: TarItem[];
  /** Paths removed from the defaults. */
  drop: string[];
  mopm: Record<string, unknown> | string;
  index: Record<string, unknown> | string;
  condaMeta: string;
  /** Replace the tar bytes wholesale (to inject a malformed tar). */
  pkgTar: (t: Buffer) => Buffer;
  infoTar: (t: Buffer) => Buffer;
  /** Wrap tar bytes into the compressed stream (default: a raw-block zstd frame). */
  compress: (t: Buffer) => Buffer;
  filename: string;
}

export const MOJOC = Buffer.from('MOJOC-BYTES-0123456789');

export function defaults(over: Partial<Spec> = {}): Spec {
  const s: Spec = {
    name: 'demo',
    version: '1.0.0',
    subdir: 'noarch',
    compiler: '1.0.0',
    pkgExtra: [],
    infoExtra: [],
    drop: [],
    mopm: {},
    index: {},
    condaMeta: '{"conda_pkg_format_version": 2}',
    pkgTar: (t) => t,
    infoTar: (t) => t,
    compress: zst,
    filename: '',
    ...over,
  };
  return s;
}

export function mopmDefault(s: Spec): Record<string, unknown> {
  return { schema: 1, name: s.name, version: s.version, deps: [], native: [] };
}

export function indexDefault(s: Spec): Record<string, unknown> {
  return {
    name: `mojo-${s.name}`,
    version: s.version,
    build: `mojo${s.compiler}_0`,
    build_number: 0,
    subdir: s.subdir,
    depends: [`mojo-compiler ==${s.compiler}`],
  };
}


/** The default files of a valid package, as [pkg items, info items]. */
export function files(s: Spec): [TarItem[], TarItem[]] {
  const mopm = typeof s.mopm === 'string' ? s.mopm : JSON.stringify({ ...mopmDefault(s), ...s.mopm });
  const index = typeof s.index === 'string' ? s.index : JSON.stringify({ ...indexDefault(s), ...s.index });
  const pkg: TarItem[] = [
    { path: `lib/mojo/${s.name}.mojoc`, data: MOJOC },
    { path: `lib/mojo/${s.name}.mopm.json`, data: mopm },
  ];
  const info: TarItem[] = [
    { path: 'info/index.json', data: index },
    { path: 'info/licenses/LICENSE', data: 'Apache-2.0' },
  ];
  const keep = (i: TarItem) => !s.drop.includes(i.path);
  return [[...pkg.filter(keep), ...s.pkgExtra], [...info.filter(keep), ...s.infoExtra]];
}

export interface Built {
  bytes: Buffer;
  req: PublishExpectation;
}

/** Build a .conda for `spec`; `req` is the matching, correct publish request. */
export function buildConda(over: Partial<Spec> = {}): Built {
  const s = defaults(over);
  const [pkg, info] = files(s);
  const build = `mojo${s.compiler}_0`;
  const filename = s.filename || `mojo-${s.name}-${s.version}-${build}.conda`;
  const bytes = zip([
    { name: 'metadata.json', data: Buffer.from(s.condaMeta) },
    { name: `info-${s.name}-${s.version}-${build}.tar.zst`, data: s.compress(s.infoTar(tar(info))) },
    { name: `pkg-${s.name}-${s.version}-${build}.tar.zst`, data: s.compress(s.pkgTar(tar(pkg))) },
  ]);
  return { bytes, req: { name: s.name, version: s.version, subdir: s.subdir, filename } };
}

/** Build a .tar.bz2 (one tar holding info/ and lib/) with the system bzip2. */
export function buildTarBz2(over: Partial<Spec> = {}): Built {
  const s = defaults(over);
  const [pkg, info] = files(s);
  const build = `mojo${s.compiler}_0`;
  const filename = s.filename || `mojo-${s.name}-${s.version}-${build}.tar.bz2`;
  return { bytes: bzip2(tar([...info, ...pkg])), req: { name: s.name, version: s.version, subdir: s.subdir, filename } };
}

