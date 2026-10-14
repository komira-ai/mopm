import { RegistryError } from './errors';

/**
 * Versions follow the grammar of `Version` in spec/api/openapi.yaml: digits separated by dots, with an
 * optional pre-release suffix (a, b, rc or dev and a number). Equality is conda equality (spec/channel.md:
 * "two versions that are equal under conda ordering are the same version"), so `1.0` and `1.0.0` are one version.
 */
const GRAMMAR = /^((?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))*)(?:(a|b|rc|dev)(0|[1-9][0-9]*))?$/;

/** The sort key of a version is stored in DynamoDB (1024 byte limit); the spec sets no length, so this is ours. */
export const MAX_VERSION_LENGTH = 128;

export type PreKind = 'dev' | 'a' | 'b' | 'rc';
const PRE_RANK: Record<PreKind, number> = { dev: 0, a: 1, b: 2, rc: 3 };
const FINAL_RANK = 4;

export interface ParsedVersion {
  /** Release segments with trailing zeros removed (at least one segment stays). */
  release: bigint[];
  pre?: { kind: PreKind; n: bigint };
  /** Equal versions have equal canonical strings: `1.0`, `1.0.0` and `1` are all `1`. */
  canonical: string;
}

export function parseVersion(input: string): ParsedVersion {
  const m = input.length <= MAX_VERSION_LENGTH ? GRAMMAR.exec(input) : null;
  if (!m) {
    throw new RegistryError('invalid_version', `'${input}' is not a valid version.`, { version: input });
  }
  const release = m[1]!.split('.').map((s) => BigInt(s));
  while (release.length > 1 && release[release.length - 1] === 0n) release.pop();
  const pre = m[2] ? { kind: m[2] as PreKind, n: BigInt(m[3]!) } : undefined;
  const canonical = release.join('.') + (pre ? `${pre.kind}${pre.n}` : '');
  return { release, pre, canonical };
}

export const isValidVersion = (s: string): boolean => {
  try {
    parseVersion(s);
    return true;
  } catch {
    return false;
  }
};

/** The key two equivalent spellings share. Throws invalid_version. */
export const canonicalVersion = (s: string): string => parseVersion(s).canonical;

export function compareParsed(a: ParsedVersion, b: ParsedVersion): number {
  const n = Math.max(a.release.length, b.release.length);
  for (let i = 0; i < n; i++) {
    const x = a.release[i] ?? 0n;
    const y = b.release[i] ?? 0n;
    if (x !== y) return x < y ? -1 : 1;
  }
  const ra = a.pre ? PRE_RANK[a.pre.kind] : FINAL_RANK;
  const rb = b.pre ? PRE_RANK[b.pre.kind] : FINAL_RANK;
  if (ra !== rb) return ra < rb ? -1 : 1;
  if (a.pre && b.pre && a.pre.n !== b.pre.n) return a.pre.n < b.pre.n ? -1 : 1;
  return 0;
}

/** Conda ordering: dev < a < b < rc < release; missing trailing segments count as zero. */
export const compareVersions = (a: string, b: string): number => compareParsed(parseVersion(a), parseVersion(b));

export const versionsEquivalent = (a: string, b: string): boolean => compareVersions(a, b) === 0;
