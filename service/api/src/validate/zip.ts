import { inflateRawSync } from 'node:zlib';
import { fail } from './codes';
import type { Limits } from './limits';

/**
 * A strict reader for the outer zip of a .conda. It reads the central directory, cross-checks every
 * local header against it, refuses overlapping entries (the "quine" zip bomb), encryption, zip64,
 * multi-disk archives and any method but stored and deflate, and checks the CRC-32 of what it returns.
 * A .conda is at most 100 MB, so zip64 is never needed.
 */
export interface ZipEntry {
  name: string;
  data: Buffer;
}

const EOCD_SIG = 0x06054b50;
const CEN_SIG = 0x02014b50;
const LOC_SIG = 0x04034b50;

let crcTable: Uint32Array | undefined;
export function crc32(buf: Uint8Array): number {
  if (!crcTable) {
    crcTable = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      crcTable[n] = c >>> 0;
    }
  }
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

export function readZip(buf: Buffer, limits: Limits, maxEntryBytes: number): ZipEntry[] {
  const bad = (m: string): never => fail('archive_corrupt', `zip: ${m}`);
  // End of central directory: the last signature whose comment length reaches exactly the end of file.
  let eocd = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 22 - 0xffff); i--) {
    if (buf.readUInt32LE(i) === EOCD_SIG && i + 22 + buf.readUInt16LE(i + 20) === buf.length) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return bad('no end of central directory');
  const disk = buf.readUInt16LE(eocd + 4);
  const cdDisk = buf.readUInt16LE(eocd + 6);
  const nHere = buf.readUInt16LE(eocd + 8);
  const nTotal = buf.readUInt16LE(eocd + 10);
  const cdSize = buf.readUInt32LE(eocd + 12);
  const cdOff = buf.readUInt32LE(eocd + 16);
  if (disk !== 0 || cdDisk !== 0 || nHere !== nTotal) return bad('multi-disk archives are not accepted');
  if (nTotal === 0xffff || cdSize === 0xffffffff || cdOff === 0xffffffff) return bad('zip64 is not accepted');
  if (nTotal > 16) return bad(`too many entries (${nTotal})`);
  if (cdOff + cdSize > eocd) return bad('central directory out of bounds');

  const out: ZipEntry[] = [];
  const spans: Array<[number, number]> = [];
  const names = new Set<string>();
  let total = 0;
  let p = cdOff;
  const dec = new TextDecoder('utf-8', { fatal: true });
  for (let i = 0; i < nTotal; i++) {
    if (p + 46 > cdOff + cdSize || buf.readUInt32LE(p) !== CEN_SIG) return bad('bad central directory entry');
    const flags = buf.readUInt16LE(p + 8);
    const method = buf.readUInt16LE(p + 10);
    const crc = buf.readUInt32LE(p + 16);
    const csize = buf.readUInt32LE(p + 20);
    const usize = buf.readUInt32LE(p + 24);
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    const diskStart = buf.readUInt16LE(p + 34);
    const lho = buf.readUInt32LE(p + 42);
    if (p + 46 + nameLen + extraLen + commentLen > cdOff + cdSize) return bad('central directory entry overruns');
    const nameBytes = buf.subarray(p + 46, p + 46 + nameLen);
    let name: string;
    try {
      name = dec.decode(nameBytes);
    } catch {
      return bad('entry name is not UTF-8');
    }
    p += 46 + nameLen + extraLen + commentLen;
    if (flags & 0x1 || flags & 0x40) return bad(`entry '${name}' is encrypted`);
    if (diskStart !== 0) return bad('multi-disk archives are not accepted');
    if (csize === 0xffffffff || usize === 0xffffffff || lho === 0xffffffff) return bad('zip64 is not accepted');
    if (method !== 0 && method !== 8) return bad(`entry '${name}' uses compression method ${method}`);
    if (method === 0 && csize !== usize) return bad(`stored entry '${name}' has unequal sizes`);
    if (names.has(name)) return bad(`duplicate entry '${name}'`);
    names.add(name);
    if (usize > maxEntryBytes) fail('file_too_large', `zip entry '${name}' is ${usize} bytes`, name);
    total += usize;
    if (total > limits.maxUnpackedBytes) fail('unpacked_too_large', 'zip entries together are too large');
    if (usize > limits.ratioFloorBytes && usize > limits.maxRatio * Math.max(1, csize)) {
      fail('compression_ratio', `zip entry '${name}' expands more than ${limits.maxRatio} times`, name);
    }

    if (lho + 30 > cdOff || buf.readUInt32LE(lho) !== LOC_SIG) return bad(`entry '${name}' has a bad local header`);
    const lNameLen = buf.readUInt16LE(lho + 26);
    const lExtraLen = buf.readUInt16LE(lho + 28);
    const dataStart = lho + 30 + lNameLen + lExtraLen;
    const dataEnd = dataStart + csize;
    if (dataEnd > cdOff) return bad(`entry '${name}' overruns the file`);
    if (!buf.subarray(lho + 30, lho + 30 + lNameLen).equals(nameBytes)) return bad(`entry '${name}' local header names a different file`);
    spans.push([lho, dataEnd]);

    const raw = buf.subarray(dataStart, dataEnd);
    let data: Buffer;
    if (method === 0) data = raw;
    else {
      try {
        data = inflateRawSync(raw, { maxOutputLength: Math.max(1, usize) });
      } catch {
        return bad(`entry '${name}' does not inflate to its declared size`);
      }
    }
    if (data.length !== usize) return bad(`entry '${name}' is not its declared size`);
    if (crc32(data) !== crc) return bad(`entry '${name}' fails its CRC-32`);
    out.push({ name, data });
  }
  spans.sort((a, b) => a[0] - b[0]);
  for (let i = 1; i < spans.length; i++) if (spans[i][0] < spans[i - 1][1] - 1000000) return bad('entries overlap');
  return out;
}
