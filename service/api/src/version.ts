import { RegistryError } from './errors';

/**
 * A version is MAJOR.MINOR.PATCH: exactly three numbers separated by dots, no leading zeros, nothing else (the CEO's
 * rule: no pre-release or local-version machinery). The grammar is `Version` in spec/api/openapi.yaml. A shorter
 * (`1.0`) or longer (`1.0.0.0`) spelling is refused, so one version has one spelling and equality is string equality.
 */
const GRAMMAR = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;

/** The sort key of a version is stored in DynamoDB (1024 byte limit); the spec sets no length, so this is ours. */
export const MAX_VERSION_LENGTH = 128;

export interface ParsedVersion {
  /** [major, minor, patch] */
  release: bigint[];
  /** The version itself: one version has one spelling. */
  canonical: string;
}

export function parseVersion(input: string): ParsedVersion {
  const m = input.length <= MAX_VERSION_LENGTH ? GRAMMAR.exec(input) : null;
  if (!m) {
    throw new RegistryError('invalid_version', `'${input}' is not a valid version.`, { version: input });
  }
  return { release: [BigInt(m[1]!), BigInt(m[2]!), BigInt(m[3]!)], canonical: input };
}

export const isValidVersion = (s: string): boolean => {
  try {
    parseVersion(s);
    return true;
  } catch {
    return false;
  }
};

/** The key a version is stored under (its only spelling). Throws invalid_version. */
export const canonicalVersion = (s: string): string => parseVersion(s).canonical;

export function compareParsed(a: ParsedVersion, b: ParsedVersion): number {
  for (let i = 0; i < 3; i++) {
    const x = a.release[i]!;
    const y = b.release[i]!;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}

/** Numeric order of major, then minor, then patch. */
export const compareVersions = (a: string, b: string): number => compareParsed(parseVersion(a), parseVersion(b));

export const versionsEquivalent = (a: string, b: string): boolean => compareVersions(a, b) === 0;
