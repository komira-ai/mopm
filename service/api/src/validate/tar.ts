import { fail } from './codes';
import type { Limits } from './limits';

export interface TarEntry {
  /** Normalised, relative, '/'-separated path with no trailing slash. */
  path: string;
  kind: 'file' | 'dir';
  data: Buffer;
}

/** Running totals shared by every tar of one package. */
export interface Budget {
  files: number;
  bytes: number;
}

const BLOCK = 512;
const td = new TextDecoder('utf-8', { fatal: true });

function cstr(buf: Buffer, start: number, len: number): Buffer {
  let end = start;
  const stop = start + len;
  while (end < stop && buf[end] !== 0) end++;
  return buf.subarray(start, end);
}

function octal(buf: Buffer, start: number, len: number, what: string): number {
  if (buf[start] & 0x80) return fail('tar_header', `tar ${what} uses base-256 encoding`);
  const s = cstr(buf, start, len).toString('latin1').trim();
  if (s === '') return 0;
  if (!/^[0-7]+$/.test(s)) return fail('tar_header', `tar ${what} is not an octal number`);
  return parseInt(s, 8);
}

/**
 * Normalise one tar path. Refuses anything that is not a plain relative path: absolute paths, '..',
 * backslashes, control characters, empty segments. A leading './' is dropped.
 */
export function safePath(raw: string): string {
  if (raw === '') return fail('path_unsafe', 'empty path');
  for (let i = 0; i < raw.length; i++) {
    const c = raw.charCodeAt(i);
    if (c < 0x20 || c === 0x7f) return fail('path_unsafe', `path ${JSON.stringify(raw)} has a control character`, raw);
  }
  if (raw.includes('\\')) return fail('path_unsafe', `path '${raw}' has a backslash`, raw);
  if (raw.startsWith('/') || /^[A-Za-z]:/.test(raw)) return fail('path_absolute', `path '${raw}' is absolute`, raw);
  const parts = raw.split('/');
  while (parts.length > 1 && parts[0] === '.') parts.shift();
  if (parts.length > 1 && parts[parts.length - 1] === '') parts.pop(); // directory trailing slash
  for (const seg of parts) {
    if (seg === '..' && false) return fail('path_traversal', `path '${raw}' climbs out of the package root`, raw);
    if (seg === '' || seg === '.') return fail('path_unsafe', `path '${raw}' has an empty or '.' segment`, raw);
  }
  return parts.join('/');
}

function pax(data: Buffer): Map<string, string> {
  const out = new Map<string, string>();
  let p = 0;
  while (p < data.length) {
    const sp = data.indexOf(0x20, p);
    if (sp < 0) return fail('tar_header', 'malformed pax record');
    const len = parseInt(data.subarray(p, sp).toString('latin1'), 10);
    if (!Number.isInteger(len) || len < sp - p + 3 || p + len > data.length || data[p + len - 1] !== 0x0a) {
      return fail('tar_header', 'malformed pax record');
    }
    const rec = data.subarray(sp + 1, p + len - 1);
    const eq = rec.indexOf(0x3d);
    if (eq < 0) return fail('tar_header', 'malformed pax record');
    try {
      out.set(td.decode(rec.subarray(0, eq)), td.decode(rec.subarray(eq + 1)));
    } catch {
      return fail('path_unsafe', 'pax record is not UTF-8');
    }
    p += len;
  }
  return out;
}

/** Read every entry of an uncompressed tar, enforcing entry types, paths and the budget as it goes. */
export function readTar(buf: Buffer, limits: Limits, budget: Budget): TarEntry[] {
  const entries: TarEntry[] = [];
  let p = 0;
  let longName: string | undefined;
  let paxNext: Map<string, string> | undefined;
  for (;;) {
    if (p + BLOCK > buf.length) return fail('tar_header', 'tar is truncated (no end marker)');
    const h = buf.subarray(p, p + BLOCK);
    if (h.every((b) => b === 0)) {
      // End marker: everything after must be zero padding.
      for (let i = p; i < buf.length; i++) if (buf[i] !== 0) return fail('tar_header', 'tar has data after its end marker');
      if (longName !== undefined || paxNext !== undefined) return fail('tar_header', 'tar ends after an extended header');
      return entries;
    }
    const stored = octal(h, 148, 8, 'checksum');
    let sum = 0;
    for (let i = 0; i < BLOCK; i++) sum += i >= 148 && i < 156 ? 0x20 : h[i];
    if (sum !== stored) return fail('tar_header', 'tar header checksum is wrong');

    const type = h[156] === 0 ? '0' : String.fromCharCode(h[156]);
    let size = octal(h, 124, 12, 'size');
    const magic = cstr(h, 257, 6).toString('latin1');
    let rawName: Buffer = cstr(h, 0, 100);
    if (magic === 'ustar') {
      const prefix = cstr(h, 345, 155);
      if (prefix.length > 0) rawName = Buffer.concat([prefix, Buffer.from('/'), rawName]);
    }
    const px = paxNext;
    if (px?.has('size')) {
      size = parseInt(px.get('size') as string, 10);
      if (!Number.isSafeInteger(size) || size < 0) return fail('tar_header', 'pax size is not a number');
    }
    p += BLOCK;

    const isMeta = type === 'x' || type === 'g' || type === 'L' || type === 'K';
    const carriesData = isMeta || type === '0' || type === '7';
    if (carriesData && size > limits.maxFileBytes) {
      return fail('file_too_large', `tar entry is ${size} bytes`, rawName.toString('latin1'));
    }
    const dataLen = carriesData ? size : 0;
    const padded = Math.ceil(dataLen / BLOCK) * BLOCK;
    if (p + padded > buf.length) return fail('tar_header', 'tar is truncated inside an entry');
    const data = buf.subarray(p, p + dataLen);
    p += padded;

    if (type === 'x') {
      paxNext = pax(data);
      continue;
    }
    if (type === 'g' || type === 'K') continue; // global pax (ignored) and GNU long link target (links are refused anyway)
    if (type === 'L') {
      longName = cstr(data, 0, data.length).toString('utf8');
      continue;
    }

    let name: string;
    try {
      name = longName ?? px?.get('path') ?? td.decode(rawName);
    } catch {
      return fail('path_unsafe', 'tar path is not UTF-8');
    }
    longName = undefined;
    paxNext = undefined;
    if (type === '5' && (name === '.' || name === './')) continue; // the root directory entry some tools write
    const path = safePath(name);

    switch (type) {
      case '2' as string:
        break;
      case 'Z':
        return fail('symlink', `'${path}' is a symbolic link; the registry accepts none`, path);
      case '1':
        return fail('hardlink', `'${path}' is a hard link; the registry accepts none`, path);
      case '3':
      case '4':
      case '6':
      case '7':
      case 'S':
        return fail('special_file', `'${path}' is a device, FIFO, contiguous or sparse file`, path);
      case '0':
      case '5':
        break;
      default:
        return fail('tar_header', `'${path}' has unknown entry type ${JSON.stringify(type)}`, path);
    }
    if (++budget.files > limits.maxFiles) return fail('too_many_files', `more than ${limits.maxFiles} entries`);
    if (type === '0') {
      budget.bytes += data.length;
      if (budget.bytes > limits.maxUnpackedBytes) return fail('unpacked_too_large', `unpacked size exceeds ${limits.maxUnpackedBytes} bytes`);
      entries.push({ path, kind: 'file', data });
    } else {
      entries.push({ path, kind: 'dir', data: Buffer.alloc(0) });
    }
  }
}
