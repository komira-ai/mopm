import { gunzipSync, gzipSync } from 'node:zlib';

/**
 * The conda-forge name mirror: the names of every package conda-forge lists for the platforms the registry publishes for
 * (the union over linux-64, linux-aarch64, osx-arm64 and noarch), written by a scheduled job and read by the validators to
 * warn about a native dependency whose name conda-forge does not list (docs/design/any-conda-forge-native.md, section 1, check b).
 * It informs and never gates: a name missing from it, a mirror that is old and a mirror that cannot be read all end in a warning.
 *
 * One object, a gzip of text: a header line `# mopm native-name mirror v1 generated=<RFC 3339>`, then one name per line, sorted.
 * The time is inside the object so that the names and the time they were read at can never come from two different writes.
 */
export const MIRROR_KEY = 'native-mirror/conda-forge-names.gz';
/** The subdirs the union covers: where a package of the registry can be installed. */
export const MIRROR_SUBDIRS = ['linux-64', 'linux-aarch64', 'osx-arm64', 'noarch'] as const;
/** A mirror older than this is reported as stale (the name list may be up to a day old; older lists only warn). */
export const MIRROR_MAX_AGE_MS = 24 * 60 * 60 * 1000;
/** Upper bound of the decompressed text a reader accepts; the union is about 450 kB today. */
export const MIRROR_MAX_TEXT_BYTES = 16 * 1024 * 1024;

const HEADER = /^# mopm native-name mirror v1 generated=(\S+)$/;

export interface NativeMirror {
  names: ReadonlySet<string>;
  generatedAt: Date;
}

/** A conda package name: lower-case letters, digits, `.`, `_` and `-`, starting with a letter or digit. */
export const CONDA_NAME = /^[a-z0-9][a-z0-9._-]{0,127}$/;

/** The object the job writes. Deterministic for equal input (the gzip header carries no time). */
export function encodeMirror(names: Iterable<string>, generatedAt: Date): Buffer {
  const sorted = [...new Set(names)].filter((n) => CONDA_NAME.test(n)).sort();
  const text = `# mopm native-name mirror v1 generated=${generatedAt.toISOString()}\n${sorted.map((n) => `${n}\n`).join('')}`;
  return gzipSync(Buffer.from(text, 'utf8'), { level: 9 });
}

/** Read the object. Throws on anything that is not what `encodeMirror` writes (the caller treats that as "no mirror"). */
export function decodeMirror(gz: Uint8Array): NativeMirror {
  const text = gunzipSync(gz, { maxOutputLength: MIRROR_MAX_TEXT_BYTES }).toString('utf8');
  const lines = text.split('\n');
  const m = HEADER.exec(lines[0] ?? '');
  if (!m) throw new Error('the mirror has no header line');
  const at = new Date(m[1]!);
  if (Number.isNaN(at.getTime())) throw new Error('the mirror header has no valid time');
  const names = new Set<string>();
  for (const l of lines.slice(1)) if (l !== '') names.add(l);
  return { names, generatedAt: at };
}
