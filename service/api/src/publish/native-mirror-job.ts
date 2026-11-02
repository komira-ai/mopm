import { Decompress } from 'fzstd';
import { CONDA_NAME, encodeMirror, MIRROR_KEY, MIRROR_SUBDIRS } from '../validate/native-mirror';
import type { ObjectStore } from './ports';

/**
 * The scheduled job that writes the conda-forge name mirror (src/validate/native-mirror.ts). For each subdir it reads conda-forge's
 * shard index (`repodata_shards.msgpack.zst`, CEP 16; 0.3 to 1 MB), takes the names the index lists, and writes the union as one
 * gzip object with the time of the run. All or nothing: a subdir that cannot be read, or that lists implausibly few names, fails the
 * job and leaves the previous object in place, which then ages into a "stale" warning instead of being replaced by a partial list.
 */
export const CONDA_FORGE_BASE = 'https://conda.anaconda.org/conda-forge';
/** The smallest name count a subdir may list (conda-forge has thousands per subdir): a guard against writing a list a parser mis-read. */
export const MIN_NAMES_PER_SUBDIR = 1000;
const MAX_INDEX_COMPRESSED = 16 * 1024 * 1024;
const MAX_INDEX_RAW = 64 * 1024 * 1024;

export type FetchBytes = (url: string) => Promise<Buffer>;

export const fetchBytes: FetchBytes = async (url) => {
  const r = await fetch(url, { signal: AbortSignal.timeout(60_000) });
  if (r.status !== 200) throw new Error(`${url} answered ${r.status}`);
  const len = Number(r.headers.get('content-length') ?? '0');
  if (len > MAX_INDEX_COMPRESSED) throw new Error(`${url} is ${len} bytes; the limit is ${MAX_INDEX_COMPRESSED}`);
  const b = Buffer.from(await r.arrayBuffer());
  if (b.length > MAX_INDEX_COMPRESSED) throw new Error(`${url} is ${b.length} bytes; the limit is ${MAX_INDEX_COMPRESSED}`);
  return b;
};

// --- the part of MessagePack the shard index needs ------------------------------------------------------------------

class Reader {
  o = 0;
  constructor(private readonly b: Buffer) {}
  private need(n: number): void {
    if (n < 0 || this.o + n > this.b.length) throw new Error('the shard index is cut short');
  }
  u8(): number {
    this.need(1);
    return this.b[this.o++]!;
  }
  u16(): number {
    this.need(2);
    const v = this.b.readUInt16BE(this.o);
    this.o += 2;
    return v;
  }
  u32(): number {
    this.need(4);
    const v = this.b.readUInt32BE(this.o);
    this.o += 4;
    return v;
  }
  skip(n: number): void {
    this.need(n);
    this.o += n;
  }
  str(n: number): string {
    this.need(n);
    const s = this.b.toString('utf8', this.o, this.o + n);
    this.o += n;
    return s;
  }
}

/** The length of a string, or -1 when the next value is not a string (the position is then unchanged). */
function strLen(r: Reader): number {
  const at = r.o;
  const t = r.u8();
  if (t >= 0xa0 && t <= 0xbf) return t & 0x1f;
  if (t === 0xd9) return r.u8();
  if (t === 0xda) return r.u16();
  if (t === 0xdb) return r.u32();
  r.o = at;
  return -1;
}

/** The entry count of a map, or -1 when the next value is not a map (the position is then unchanged). */
function mapLen(r: Reader): number {
  const at = r.o;
  const t = r.u8();
  if (t >= 0x80 && t <= 0x8f) return t & 0x0f;
  if (t === 0xde) return r.u16();
  if (t === 0xdf) return r.u32();
  r.o = at;
  return -1;
}

/** Step over one value of any type the index uses; an extension type or nesting past 16 levels is an error. */
function skipValue(r: Reader, depth = 0): void {
  if (depth > 16) throw new Error('the shard index nests too deeply');
  const t = r.u8();
  if (t <= 0x7f || t >= 0xe0 || t === 0xc0 || t === 0xc2 || t === 0xc3) return;
  if (t >= 0xa0 && t <= 0xbf) return r.skip(t & 0x1f);
  if (t >= 0x80 && t <= 0x8f) return skipEntries(r, (t & 0x0f) * 2, depth);
  if (t >= 0x90 && t <= 0x9f) return skipEntries(r, t & 0x0f, depth);
  switch (t) {
    case 0xc4: case 0xd9: return r.skip(r.u8());
    case 0xc5: case 0xda: return r.skip(r.u16());
    case 0xc6: case 0xdb: return r.skip(r.u32());
    case 0xca: case 0xce: case 0xd2: return r.skip(4);
    case 0xcb: case 0xcf: case 0xd3: return r.skip(8);
    case 0xcc: case 0xd0: return r.skip(1);
    case 0xcd: case 0xd1: return r.skip(2);
    case 0xdc: return skipEntries(r, r.u16(), depth);
    case 0xdd: return skipEntries(r, r.u32(), depth);
    case 0xde: return skipEntries(r, r.u16() * 2, depth);
    case 0xdf: return skipEntries(r, r.u32() * 2, depth);
    default: throw new Error(`the shard index holds a MessagePack type (0x${t.toString(16)}) this reader does not know`);
  }
}
function skipEntries(r: Reader, n: number, depth: number): void {
  for (let i = 0; i < n; i++) skipValue(r, depth + 1);
}

/** The package names of a decoded shard index: the keys of its top-level `shards` map. Throws when the index has none. */
export function shardNames(index: Buffer): string[] {
  const r = new Reader(index);
  const top = mapLen(r);
  if (top < 0) throw new Error('the shard index is not a MessagePack map');
  for (let i = 0; i < top; i++) {
    const kl = strLen(r);
    if (kl < 0) throw new Error('the shard index has a key that is not a string');
    const key = r.str(kl);
    if (key !== 'shards') {
      skipValue(r);
      continue;
    }
    const n = mapLen(r);
    if (n < 0) throw new Error("the shard index's 'shards' is not a map");
    const names: string[] = [];
    for (let j = 0; j < n; j++) {
      const l = strLen(r);
      if (l < 0) throw new Error('the shard index lists a name that is not a string');
      names.push(r.str(l));
      skipValue(r);
    }
    return names;
  }
  throw new Error("the shard index has no 'shards'");
}

function unzstd(b: Buffer): Buffer {
  const parts: Buffer[] = [];
  let total = 0;
  const d = new Decompress((chunk) => {
    total += chunk.length;
    if (total > MAX_INDEX_RAW) throw new Error(`the shard index unpacks past ${MAX_INDEX_RAW} bytes`);
    parts.push(Buffer.from(chunk));
  });
  d.push(b, true);
  return Buffer.concat(parts);
}

/** The names conda-forge lists for one subdir. */
export async function namesOf(fetchFn: FetchBytes, subdir: string): Promise<string[]> {
  const url = `${CONDA_FORGE_BASE}/${subdir}/repodata_shards.msgpack.zst`;
  const names = shardNames(unzstd(await fetchFn(url))).filter((n) => CONDA_NAME.test(n));
  if (names.length < MIN_NAMES_PER_SUBDIR) {
    throw new Error(`${subdir}: the shard index lists ${names.length} usable names; fewer than ${MIN_NAMES_PER_SUBDIR} is not a conda-forge subdir, so nothing is written`);
  }
  return names;
}

/** One run of the job: read every subdir, then write the union. Throws (writing nothing) when any subdir fails. */
export async function runNativeMirrorJob(d: { objects: Pick<ObjectStore, 'put'>; fetchBytes?: FetchBytes; now?: () => Date; log?: (l: Record<string, unknown>) => void }): Promise<{ names: number }> {
  const log = d.log ?? ((l) => console.log(JSON.stringify(l)));
  const fetchFn = d.fetchBytes ?? fetchBytes;
  const all = new Set<string>();
  for (const subdir of MIRROR_SUBDIRS) {
    const names = await namesOf(fetchFn, subdir);
    log({ level: 'info', msg: 'native mirror: subdir read', subdir, names: names.length });
    for (const n of names) all.add(n);
  }
  const body = encodeMirror(all, (d.now ?? (() => new Date()))());
  await d.objects.put(MIRROR_KEY, body, { contentType: 'application/gzip', cacheControl: 'no-cache' });
  log({ level: 'info', msg: 'native mirror: written', key: MIRROR_KEY, names: all.size, bytes: body.length });
  return { names: all.size };
}
