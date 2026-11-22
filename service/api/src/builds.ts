import { RegistryError } from './errors';
import { condaNameOf } from './names';
import type { FileRef, VersionRecord } from './types';
import { canonicalVersion } from './version';

/**
 * The builds of a version: one per Mojo compiler (spec/channel.md, "Builds"). A build is the files of a version built
 * with one compiler; its build string is `mojo<compiler>_0`, which is also the end of each of its file names
 * (`mojo-<namespace>.<name>-<version>-<build>.conda`), so the build of a stored file is read off its name.
 *
 * How the registry stores them. A version's row (key: the version) holds the builds it was published with. A build
 * added later is a row of its own, keyed `<version>+<build>` (`buildRowKey`): created once, like a version, so two
 * publishes of one build of one version race to one winner and a file is never replaced. The reads of the store fold
 * those rows into their version (`foldBuilds`), so every reader sees one record per version whose `files` are those of
 * every build; the top-level `build` and `requires_mojo` are the primary build's (`primaryBuild`), which is what a
 * reader that predates builds understands. Pure.
 */

/** `mojo<compiler>_0`, the compiler in group 1. */
export const BUILD_PATTERN = /^mojo([0-9]+(?:\.[0-9]+)*)_0$/;

/** The compiler of a build string (`mojo1.1.0_0` -> `1.1.0`), or undefined for anything else. */
export function compilerOf(build: string): string | undefined {
  return BUILD_PATTERN.exec(build)?.[1];
}

/** `==<compiler>`: the requirement on the compiler a build states (`requires_mojo`). */
export const requiresMojoOf = (build: string): string => `==${compilerOf(build) ?? build}`;

/**
 * Numeric order of two compilers, part by part (`1.2.0` < `1.10.0`); a shorter one that is a prefix sorts first. Builds
 * that are not `mojo<compiler>_0` (none are stored) sort after, by text.
 */
export function compareBuilds(a: string, b: string): number {
  const x = compilerOf(a);
  const y = compilerOf(b);
  if (x === undefined || y === undefined) return x === undefined && y === undefined ? (a < b ? -1 : a > b ? 1 : 0) : x === undefined ? 1 : -1;
  const xs = x.split('.').map(BigInt);
  const ys = y.split('.').map(BigInt);
  for (let i = 0; i < Math.max(xs.length, ys.length); i++) {
    if (i >= xs.length) return -1;
    if (i >= ys.length) return 1;
    if (xs[i] !== ys[i]) return xs[i]! < ys[i]! ? -1 : 1;
  }
  return 0;
}

/** The build a file of `name` `version` belongs to: what its name has after `<conda name>-<version>-`, before `.conda`. */
export function buildOfFile(name: string, version: string, filename: string): string | undefined {
  const stem = `${condaNameOf(name)}-${version}-`;
  if (!filename.startsWith(stem) || !filename.endsWith('.conda')) return undefined;
  const build = filename.slice(stem.length, -'.conda'.length);
  return BUILD_PATTERN.test(build) ? build : undefined;
}

/** The key of the row of a build added to a version later. */
export const buildRowKey = (canonical: string, build: string): string => `${canonical}+${build}`;

/**
 * The row key a store reads or writes: a version (`1.0.0`, any valid spelling, checked) or a build row's key
 * (`1.0.0+mojo1.1.0_0`). Throws invalid_version for anything else. The API's routes never take a build row's key: they
 * check the version with `canonicalVersion` first.
 */
export function rowKeyOf(key: string): string {
  const plus = key.indexOf('+');
  if (plus < 0) return canonicalVersion(key);
  const build = key.slice(plus + 1);
  const canonical = canonicalVersion(key.slice(0, plus));
  if (!BUILD_PATTERN.test(build)) canonicalVersion(key); // throws invalid_version, naming the whole key
  return buildRowKey(canonical, build);
}

/** The version a row key belongs to, and the build when it is a build row's. */
export function splitRowKey(key: string): { canonical: string; build?: string } {
  const plus = key.indexOf('+');
  return plus < 0 ? { canonical: key } : { canonical: key.slice(0, plus), build: key.slice(plus + 1) };
}

/** A row that holds a build added to a version after the version was published. */
export const isBuildRow = (r: Pick<VersionRecord, 'canonical'>): boolean => r.canonical.includes('+');

/**
 * The key a store files a record under: the canonical version of an ordinary row, and the row key of a build row (its
 * `canonical`, which must be `<version>+<build>` of the record's own `version`). Throws invalid_version.
 */
export function keyOfRecord(r: Pick<VersionRecord, 'canonical' | 'version'>): string {
  if (!isBuildRow(r)) return canonicalVersion(r.version);
  const key = rowKeyOf(r.canonical);
  if (splitRowKey(key).canonical !== canonicalVersion(r.version)) {
    throw new RegistryError('invalid_version', `'${r.canonical}' is not a row of version '${r.version}'.`, { version: r.canonical });
  }
  return key;
}

/** How an error names a row: the version, and for a build row also its build (`1.0.0 (build mojo1.1.0_0)`). */
export function rowLabel(r: Pick<VersionRecord, 'canonical' | 'version'>): string {
  const { build } = splitRowKey(r.canonical);
  return build === undefined ? r.version : `${r.version} (build ${build})`;
}

export interface Build {
  build: string;
  requires_mojo: string;
  /** Sorted by subdir, then file name. */
  files: FileRef[];
}

const byFile = (a: FileRef, b: FileRef) => (a.subdir < b.subdir ? -1 : a.subdir > b.subdir ? 1 : a.filename < b.filename ? -1 : a.filename > b.filename ? 1 : 0);

type BuildSource = Pick<VersionRecord, 'name' | 'version' | 'build' | 'files'> & Partial<Pick<VersionRecord, 'requires_mojo'>>;

/**
 * The builds of a version record, sorted by compiler. A file whose name names no build (none is stored: the publish
 * checks every name) counts as the record's own `build`. The record's own build states the record's own
 * `requires_mojo` when it has one; every other build states `==<its compiler>`.
 */
export function buildsOf(r: BuildSource): Build[] {
  const by = new Map<string, FileRef[]>();
  for (const f of r.files) {
    const b = buildOfFile(r.name, r.version, f.filename) ?? r.build;
    by.set(b, [...(by.get(b) ?? []), f]);
  }
  return [...by.entries()]
    .sort(([a], [b]) => compareBuilds(a, b))
    .map(([build, files]) => ({
      build,
      requires_mojo: build === r.build && r.requires_mojo !== undefined ? r.requires_mojo : requiresMojoOf(build),
      files: [...files].sort(byFile),
    }));
}

/** The build with the lowest compiler, which the top-level `build`, `requires_mojo` and the index's `files` show; undefined for a record with no files. */
export function primaryBuild(r: BuildSource): Build | undefined {
  return buildsOf(r)[0];
}

/**
 * The records a reader sees: each version's row with the build rows of that version folded in. A build row counts
 * when it is `published` as the reader sees it (a member of a committed group is); a pending one (not yet committed),
 * a burned one (a rejected add) and one without its version's row are left out. The folded record is the version's
 * row with the build rows' files added and its `build` and `requires_mojo` set to the primary build's; its state is
 * the version's, so a yanked or taken-down version takes its added builds with it (a taken-down version's files lose
 * their `url`). `rev` is the sum, so a change to any of the rows changes it. Rows that are not build rows come back as
 * given, in the order given.
 */
export function foldBuilds(rows: readonly VersionRecord[]): VersionRecord[] {
  const added = new Map<string, VersionRecord[]>();
  for (const r of rows) {
    if (!isBuildRow(r) || r.state !== 'published') continue;
    const { canonical } = splitRowKey(r.canonical);
    added.set(canonical, [...(added.get(canonical) ?? []), r]);
  }
  const out: VersionRecord[] = [];
  for (const r of rows) {
    if (isBuildRow(r)) continue;
    const extra = added.get(r.canonical);
    if (extra === undefined || r.state === 'pending') {
      out.push(r);
      continue;
    }
    const gone = r.state === 'tombstoned';
    const files = [...r.files, ...extra.flatMap((b) => b.files.map((f) => (gone ? withoutUrl(f) : f)))];
    const folded: VersionRecord = { ...r, files, rev: extra.reduce((n, b) => n + b.rev, r.rev) };
    const primary = primaryBuild(folded);
    out.push(primary === undefined ? folded : { ...folded, build: primary.build, requires_mojo: primary.requires_mojo });
  }
  return out;
}

function withoutUrl(f: FileRef): FileRef {
  const { url: _url, ...rest } = f;
  return rest;
}
