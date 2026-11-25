// A package's versions grouped by release line, for the package page: one row per line, the full list on its own page.
//
// A release line is what a caret requirement stays inside (docs/design/mopm-dev.md, section 1.5, `lines`): a major
// from 1 up, and below 1.0.0 each 0.MINOR, since semver lets a 0.x minor break. 0.0.x is one line. A line is shown by
// its highest published version, a release before a pre-release; a line with nothing published (every version yanked,
// tombstoned or in a state the page does not know) by its highest version, whose state the row then shows.
//
// The registry's grammar is MAJOR.MINOR.PATCH (routes.ts VERSION), but every string comes from the API, so this reads
// semver 2.0.0's full grammar: a pre-release sorts below its release (1.0.0-rc.1 < 1.0.0) and build metadata does not
// change the order. A string outside that grammar belongs to no line; each is a row of its own after every line, in
// the API's order. Numbers are compared as digit strings, so a part longer than a JavaScript number keeps its order.
//
// Pure: no DOM, no clock, no globals.

import type { VersionSummary } from './types.js';

/** A version string read by semver 2.0.0's grammar. */
export interface Semver {
  major: string;
  minor: string;
  patch: string;
  /** The pre-release identifiers ('rc.1' is ['rc', '1']); empty for a release. */
  pre: readonly string[];
}

const NUM = '(0|[1-9][0-9]*)';
const PRE_ID = '(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)';
const BUILD_ID = '[0-9A-Za-z-]+';
/** semver.org's grammar: MAJOR.MINOR.PATCH, then an optional -pre-release and +build. */
export const SEMVER = new RegExp(`^${NUM}\\.${NUM}\\.${NUM}(?:-(${PRE_ID}(?:\\.${PRE_ID})*))?(?:\\+${BUILD_ID}(?:\\.${BUILD_ID})*)?$`);

/** `s` read as semver, or null when it is outside the grammar. */
export function parseSemver(s: string): Semver | null {
  const m = SEMVER.exec(s);
  if (m === null) return null;
  return { major: m[1], minor: m[2], patch: m[3], pre: m[4] === undefined ? [] : m[4].split('.') };
}

/** Two digit strings without leading zeros, by value. */
function compareNum(a: string, b: string): number {
  if (a.length !== b.length) return a.length - b.length;
  return a < b ? -1 : a > b ? 1 : 0;
}

const DIGITS = /^[0-9]+$/;

/** Two pre-release identifiers: numbers by value, below any alphanumeric one; those in ASCII order. */
function compareId(a: string, b: string): number {
  const an = DIGITS.test(a);
  const bn = DIGITS.test(b);
  if (an && bn) return compareNum(a, b);
  if (an !== bn) return an ? -1 : 1;
  return a < b ? -1 : a > b ? 1 : 0;
}

/** Semver precedence: negative when `a` is lower, 0 when the two are equal (build metadata is not compared). */
export function compareSemver(a: Semver, b: Semver): number {
  const core = compareNum(a.major, b.major) || compareNum(a.minor, b.minor) || compareNum(a.patch, b.patch);
  if (core !== 0) return core;
  // A release is above its pre-releases.
  if (a.pre.length === 0 || b.pre.length === 0) return b.pre.length - a.pre.length;
  for (let i = 0; i < Math.min(a.pre.length, b.pre.length); i++) {
    const c = compareId(a.pre[i], b.pre[i]);
    if (c !== 0) return c;
  }
  return a.pre.length - b.pre.length;
}

/** The release line of a version: '2.x' for a major from 1 up, '0.4.x' below 1.0.0. */
export function lineOf(v: Semver): string {
  return v.major === '0' ? `0.${v.minor}.x` : `${v.major}.x`;
}

/** One row of the package page's versions section. */
export interface ReleaseLine {
  /** '2.x', '0.4.x', or null for a version outside the grammar (a row of its own). */
  line: string | null;
  /** The version that shows the line: its highest published one, or its highest when none is published. */
  shown: VersionSummary;
  /** How many versions the line holds, in any state; 1 for a version outside the grammar. */
  count: number;
}

interface Parsed {
  v: VersionSummary;
  s: Semver;
}

/**
 * Which of two versions of one line shows it: published first; between two published ones a release before a
 * pre-release; then the higher. Between two that are not published only the higher counts, so a line with nothing
 * published shows its highest version.
 */
function better(a: Parsed, b: Parsed): boolean {
  const ap = a.v.state === 'published';
  const bp = b.v.state === 'published';
  if (ap !== bp) return ap;
  const ar = a.s.pre.length === 0;
  const br = b.s.pre.length === 0;
  if (ap && ar !== br) return ar;
  return compareSemver(a.s, b.s) > 0;
}

/**
 * The release lines of `versions`, newest line first, then each version outside the grammar in the order given. Two
 * versions the same in precedence (they differ only in build metadata) keep the order given, the first winning.
 */
export function releaseLines(versions: readonly VersionSummary[]): ReleaseLine[] {
  const groups = new Map<string, { best: Parsed; top: Semver; count: number }>();
  const other: ReleaseLine[] = [];
  for (const v of versions) {
    const s = parseSemver(v.version);
    if (s === null) {
      other.push({ line: null, shown: v, count: 1 });
      continue;
    }
    const key = lineOf(s);
    const g = groups.get(key);
    if (g === undefined) {
      groups.set(key, { best: { v, s }, top: s, count: 1 });
      continue;
    }
    g.count += 1;
    if (better({ v, s }, g.best)) g.best = { v, s };
    if (compareSemver(s, g.top) > 0) g.top = s;
  }
  // Lines in the order of their highest versions; two lines never tie, as their major (or 0.minor) differs.
  const lines = [...groups.entries()]
    .sort(([, a], [, b]) => compareSemver(b.top, a.top))
    .map(([line, g]) => ({ line, shown: g.best.v, count: g.count }));
  return [...lines, ...other];
}
