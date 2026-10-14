import { fail, ValidationFailure } from './codes';
import type { Collector } from './collector';

/**
 * A bzip2 decoder that streams its output into a Collector, so the caps apply while it runs.
 * Block CRCs are not checked: the publish pins the archive's sha256, and every structure the decoder
 * relies on (tables, selectors, block size, end marker) is range-checked. The obsolete "randomised"
 * block mode is refused.
 */
const BLOCK_MAGIC_HI = 0x314159;
const BLOCK_MAGIC_LO = 0x265359;
const END_MAGIC_HI = 0x177245;
const END_MAGIC_LO = 0x385090;
const MAX_CODE_LEN = 20;
const GROUP_SIZE = 50;

class Bits {
  private pos = 0;
  private buf = 0;
  private cnt = 0;
  constructor(private readonly data: Uint8Array) {}
  read(n: number): number {
    while (this.cnt < n) {
      if (this.pos >= this.data.length) throw new Error('eof');
      this.buf = ((this.buf << 8) | this.data[this.pos++]) >>> 0;
      this.cnt += 8;
      if (this.cnt > 32) throw new Error('internal');
    }
    this.cnt -= n;
    const v = (this.buf >>> this.cnt) & ((1 << n) - 1);
    this.buf &= (1 << this.cnt) - 1;
    return v;
  }
  bit(): number {
    return this.read(1);
  }
  alignByte(): void {
    this.cnt -= this.cnt % 8;
    this.buf &= this.cnt === 0 ? 0 : (1 << this.cnt) - 1;
  }
  get atEnd(): boolean {
    return this.cnt === 0 && this.pos >= this.data.length;
  }
}

interface Table {
  minLen: number;
  maxLen: number;
  limit: Int32Array;
  base: Int32Array;
  perm: Int32Array;
}

function buildTable(lens: Uint8Array, alphaSize: number): Table {
  let minLen = 32;
  let maxLen = 0;
  for (let i = 0; i < alphaSize; i++) {
    if (lens[i] > maxLen) maxLen = lens[i];
    if (lens[i] < minLen) minLen = lens[i];
  }
  const perm = new Int32Array(alphaSize);
  let pp = 0;
  for (let i = minLen; i <= maxLen; i++) for (let j = 0; j < alphaSize; j++) if (lens[j] === i) perm[pp++] = j;
  const base = new Int32Array(MAX_CODE_LEN + 2);
  const limit = new Int32Array(MAX_CODE_LEN + 2);
  for (let i = 0; i < alphaSize; i++) base[lens[i] + 1]++;
  for (let i = 1; i < base.length; i++) base[i] += base[i - 1];
  let vec = 0;
  for (let i = minLen; i <= maxLen; i++) {
    vec += base[i + 1] - base[i];
    limit[i] = vec - 1;
    vec <<= 1;
  }
  for (let i = minLen + 1; i <= maxLen; i++) base[i] = ((limit[i - 1] + 1) << 1) - base[i];
  return { minLen, maxLen, limit, base, perm };
}

class Writer {
  private buf = new Uint8Array(65536);
  private n = 0;
  constructor(private readonly out: Collector) {}
  put(b: number): void {
    if (this.n === this.buf.length) this.flush();
    this.buf[this.n++] = b;
  }
  flush(): void {
    if (this.n > 0) {
      this.out.push(this.buf.slice(0, this.n));
      this.n = 0;
    }
  }
}

export function bunzip2(data: Uint8Array, out: Collector, what: string): void {
  try {
    const bits = new Bits(data);
    const w = new Writer(out);
    let streams = 0;
    // One or more concatenated streams; trailing zero padding after the last is tolerated.
    while (!bits.atEnd) {
      if (streams > 0 && data.length > 0) {
        // A further stream must start with BZh; anything else here is trailing garbage.
        const save = bits.read(8);
        if (save === 0) continue;
        if (save !== 0x42) fail('archive_corrupt', `${what} has trailing data after the bzip2 stream`);
      } else if (bits.read(8) !== 0x42) fail('archive_corrupt', `${what} is not bzip2`);
      if (bits.read(8) !== 0x5a || bits.read(8) !== 0x68) fail('archive_corrupt', `${what} is not bzip2`);
      const level = bits.read(8) - 0x30;
      if (level < 1 || level > 9) fail('archive_corrupt', `${what} has a bad bzip2 block size`);
      decodeStream(bits, w, level * 100000, what);
      bits.alignByte();
      streams++;
    }
    if (streams === 0) fail('archive_corrupt', `${what} is empty`);
    w.flush();
  } catch (e) {
    if (e instanceof ValidationFailure) throw e;
    fail('archive_corrupt', `${what} is not valid bzip2`);
  }
}

function decodeStream(bits: Bits, w: Writer, blockMax: number, what: string): void {
  const tt = new Uint32Array(blockMax);
  for (;;) {
    const hi = bits.read(24);
    const lo = bits.read(24);
    if (hi === END_MAGIC_HI && lo === END_MAGIC_LO) {
      bits.read(16);
      bits.read(16); // combined CRC, not checked
      return;
    }
    if (hi !== BLOCK_MAGIC_HI || lo !== BLOCK_MAGIC_LO) fail('archive_corrupt', `${what} has a bad bzip2 block header`);
    bits.read(16);
    bits.read(16); // block CRC, not checked
    decodeBlock(bits, w, tt, blockMax, what);
  }
}

function decodeBlock(bits: Bits, w: Writer, tt: Uint32Array, blockMax: number, what: string): void {
  if (bits.bit() !== 0) fail('archive_corrupt', `${what} uses obsolete randomised bzip2 blocks`);
  const origPtr = bits.read(24);

  // Symbol map: which byte values occur.
  const used16 = bits.read(16);
  const seqToUnseq: number[] = [];
  for (let i = 0; i < 16; i++) {
    if (used16 & (0x8000 >> i)) {
      const m = bits.read(16);
      for (let j = 0; j < 16; j++) if (m & (0x8000 >> j)) seqToUnseq.push(i * 16 + j);
    }
  }
  if (seqToUnseq.length === 0) fail('archive_corrupt', `${what} has an empty bzip2 symbol map`);
  const alphaSize = seqToUnseq.length + 2;
  const eob = seqToUnseq.length + 1;

  const nGroups = bits.read(3);
  if (nGroups < 2 || nGroups > 6) fail('archive_corrupt', `${what} has bad bzip2 table count`);
  const nSelectors = bits.read(15);
  if (nSelectors < 1) fail('archive_corrupt', `${what} has no bzip2 selectors`);
  const mtfSel = Array.from({ length: nGroups }, (_, i) => i);
  const selectors = new Uint8Array(nSelectors);
  for (let i = 0; i < nSelectors; i++) {
    let j = 0;
    while (bits.bit() === 1) {
      j++;
      if (j >= nGroups) fail('archive_corrupt', `${what} has a bad bzip2 selector`);
    }
    const v = mtfSel[j];
    for (; j > 0; j--) mtfSel[j] = mtfSel[j - 1];
    mtfSel[0] = v;
    selectors[i] = v;
  }

  const tables: Table[] = [];
  for (let t = 0; t < nGroups; t++) {
    const lens = new Uint8Array(alphaSize);
    let cur = bits.read(5);
    for (let i = 0; i < alphaSize; i++) {
      for (;;) {
        if (cur < 1 || cur > MAX_CODE_LEN) fail('archive_corrupt', `${what} has a bad bzip2 code length`);
        if (bits.bit() === 0) break;
        cur += bits.bit() === 0 ? 1 : -1;
      }
      lens[i] = cur;
    }
    tables.push(buildTable(lens, alphaSize));
  }

  // Huffman + MTF + zero-run decode into tt (low 8 bits hold the byte).
  const mtf = Uint8Array.from(seqToUnseq.map((_, i) => i));
  const counts = new Int32Array(256);
  let n = 0;
  let groupLeft = 0;
  let selIdx = 0;
  let table: Table = tables[0];
  let runLen = 0;
  let runPos = 1;
  for (;;) {
    if (groupLeft === 0) {
      if (selIdx >= nSelectors) fail('archive_corrupt', `${what} ran out of bzip2 selectors`);
      table = tables[selectors[selIdx++]];
      groupLeft = GROUP_SIZE;
    }
    groupLeft--;
    let zn = table.minLen;
    let zvec = bits.read(zn);
    while (zvec > table.limit[zn]) {
      zn++;
      if (zn > table.maxLen) fail('archive_corrupt', `${what} has a bad bzip2 code`);
      zvec = (zvec << 1) | bits.bit();
    }
    const idx = zvec - table.base[zn];
    if (idx < 0 || idx >= alphaSize) fail('archive_corrupt', `${what} has a bad bzip2 code`);
    const sym = table.perm[idx];

    if (sym <= 1) {
      // RUNA / RUNB: bijective base-2 run length of the front byte.
      runLen += runPos << sym;
      runPos <<= 1;
      if (runLen > blockMax) fail('archive_corrupt', `${what} has an oversized bzip2 run`);
      continue;
    }
    if (runLen > 0) {
      const b = seqToUnseq[mtf[0]];
      if (n + runLen > blockMax) fail('archive_corrupt', `${what} overflows a bzip2 block`);
      counts[b] += runLen;
      while (runLen > 0) {
        tt[n++] = b;
        runLen--;
      }
      runPos = 1;
    }
    if (sym === eob) break;
    // MTF position sym-1.
    const pos = sym - 1;
    const v = mtf[pos];
    for (let k = pos; k > 0; k--) mtf[k] = mtf[k - 1];
    mtf[0] = v;
    const b = seqToUnseq[v];
    if (n >= blockMax) fail('archive_corrupt', `${what} overflows a bzip2 block`);
    counts[b]++;
    tt[n++] = b;
  }
  if (origPtr >= n && n > 0) fail('archive_corrupt', `${what} has a bad bzip2 origin pointer`);
  if (n === 0) return;

  // Inverse BWT.
  const cf = new Int32Array(256);
  let sum = 0;
  for (let i = 0; i < 256; i++) {
    cf[i] = sum;
    sum += counts[i];
  }
  for (let i = 0; i < n; i++) {
    const b = tt[i] & 0xff;
    tt[cf[b]++] |= i << 8;
  }
  let p = tt[origPtr] >>> 8;

  // Undo the first-stage run-length encoding (4 equal bytes, then a repeat count).
  let prev = -1;
  let same = 0;
  for (let i = 0; i < n; i++) {
    const e = tt[p];
    const b = e & 0xff;
    p = e >>> 8;
    if (same === 4) {
      for (let r = 0; r < b; r++) w.put(prev);
      same = 0;
      prev = -1;
      continue;
    }
    if (b === prev) same++;
    else {
      same = 1;
      prev = b;
    }
    w.put(b);
  }
}
