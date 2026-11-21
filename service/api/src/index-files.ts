import { buildsOf, type Build } from './builds';
import { canonicalJson } from './canonical-json';
import { splitFullName } from './names';
import { compareVersions } from './version';
import type { FileRef, VersionRecord } from './types';

/**
 * Pure builders for the static sparse index (spec/index.md): one package's NDJSON file, the takedown logs
 * and the per-stage config. Nothing here reads a store, a queue or a bucket; the caller passes rows in and
 * gets bytes out. Output is a function of the row contents alone: the order of the input rows does not
 * matter, keys are sorted, and nothing time-dependent is written.
 *
 * Two index versions are written side by side (spec/index.md, "Version 1"): version 1 holds the packages of flat
 * names (`/index/<aa>/<bb>/<name>`, records `v` 1), version 2 the packages of full names
 * (`/index/v2/<aa>/<bb>/<namespace>/<name>`, records `v` 2). A package is in exactly one of them, chosen by its name.
 */

/** The version of `config.json`'s `index_version`: 1, which released CLIs read. Version 2 is announced by `index_versions`. */
export const INDEX_VERSION = 1;
/** The index version of a package of full names. */
export const INDEX_VERSION_V2 = 2;
/** Every index version served, sorted (`config.json`'s `index_versions`). */
export const INDEX_VERSIONS: readonly number[] = [INDEX_VERSION, INDEX_VERSION_V2];
/** The oldest CLI the registry supports. A larger value would lock out released CLIs. */
export const MIN_CLI_VERSION = '0.0.1';

const NAME = /^[a-z][a-z0-9_]{1,63}$/;
const BY_FILE = (a: FileRef, b: FileRef) => cmp(a.subdir, b.subdir) || cmp(a.filename, b.filename);

/** Code-unit order, independent of the process locale. */
const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/** `aa/bb` of a sharded path: the first four characters of `s`, padded on the right with `_`. */
function shard(s: string): string {
  const padded = s.slice(0, 4).padEnd(4, '_');
  return `${padded.slice(0, 2)}/${padded.slice(2, 4)}`;
}

/**
 * The key, under the channel bucket, of a package's file: `index/<aa>/<bb>/<name>` for a flat name (version 1), and
 * `index/v2/<aa>/<bb>/<namespace>/<name>` for a full name (version 2, sharded by the namespace). Derived from the name,
 * never parsed back.
 */
export function indexKey(name: string): string {
  const full = splitFullName(name);
  if (full) return `index/v2/${shard(full.namespace)}/${full.namespace}/${full.name}`;
  if (!NAME.test(name)) throw new Error(`index: '${name}' is not a package name`);
  return `index/${shard(name)}/${name}`;
}

/** The index version a package's file and records are written in: 2 for a full name, 1 for a flat one. */
export const indexVersionOf = (name: string): number => (splitFullName(name) ? INDEX_VERSION_V2 : INDEX_VERSION);

/** The key of the version 1 takedown log (flat names). */
export const TAKEDOWNS_KEY = 'index/takedowns.json';
/** The key of the version 2 takedown log (full names). */
export const TAKEDOWNS_V2_KEY = 'index/v2/takedowns.json';

/** The key of the config file. Served from code, never written to the bucket. */
export const CONFIG_KEY = 'index/config.json';

function fileOf(r: VersionRecord, f: FileRef) {
  const tombstoned = r.state === 'tombstoned';
  if (!tombstoned && !f.url) throw new Error(`index: ${r.name} ${r.version}: file ${f.filename} has no url`);
  return {
    subdir: f.subdir,
    filename: f.filename,
    sha256: f.sha256,
    size: f.size,
    // The bytes of a tombstoned version are gone, so its record names no place to fetch them from.
    ...(tombstoned ? {} : { url: f.url }),
  };
}

/** A build as a line of the index shows it: its files in the order of a line's `files`. */
const buildEntry = (r: VersionRecord, b: Build) => ({
  build: b.build,
  requires_mojo: b.requires_mojo,
  files: b.files.map((f) => fileOf(r, f)),
});

/**
 * One record. `build`, `requires_mojo` and `files` are the primary build's (the lowest compiler), which a reader that
 * predates `builds` understands; a line of a full name (`v` 2) also lists every build in `builds`, sorted by compiler,
 * whatever their number. The rest is the version's, shared by every build. A flat name (`v` 1) has no `builds`.
 */
function recordOf(r: VersionRecord) {
  if (r.state === 'yanked' && !r.yank_reason) throw new Error(`index: ${r.name} ${r.version}: yanked without a reason`);
  if (r.state === 'tombstoned' && !r.tombstone) throw new Error(`index: ${r.name} ${r.version}: tombstoned without a tombstone`);
  const v = indexVersionOf(r.name);
  const builds = buildsOf(r);
  const primary = builds[0]!; // only an indexed row (one with files) is written, so it has a build
  return {
    v,
    name: r.name,
    version: r.version,
    build: primary.build,
    state: r.state,
    ...(r.state === 'yanked' ? { yank_reason: r.yank_reason } : {}),
    ...(r.state === 'tombstoned' ? { tombstone: { reason_code: r.tombstone!.reason_code, date: r.tombstone!.date } } : {}),
    published_at: r.published_at,
    requires_mojo: primary.requires_mojo,
    deps: r.deps.map((d) => (d.range === undefined ? { name: d.name } : { name: d.name, range: d.range })),
    native: r.native.map((n) => ({ id: n.id, soname: n.soname })),
    files: primary.files.map((f) => fileOf(r, f)),
    ...(v === INDEX_VERSION_V2 ? { builds: builds.map((b) => buildEntry(r, b)) } : {}),
    manifest_sha256: r.manifest_sha256,
    provenance: r.provenance ?? { kind: 'none' },
  };
}

/**
 * Whether a row appears in the index. Pending rows are only a reserved number. A rejected publish is
 * tombstoned with no files, and a record needs at least one file.
 */
export const isIndexed = (r: VersionRecord): boolean => r.state !== 'pending' && r.files.length > 0;

/**
 * The revision of a package as the index sees it: the sum of its rows' revision counters. Every change to a row
 * adds one and rows are never removed, so a later state of the package always has a larger number. A queue
 * message carries it so that the dedup id (`name:rev`) separates two changes of one package, whichever versions
 * they touch.
 */
export const packageRev = (rows: readonly VersionRecord[]): number => rows.reduce((n, r) => n + r.rev, 0);

/**
 * The NDJSON file of one package, from all its version records (one per version, builds folded in, as the store lists them): one line per indexed version, oldest first
 * (numeric), each line compact JSON with sorted keys, the whole ending in a newline. A version's files in
 * every subdir are listed in that one line. Returns undefined when no version is indexed: the service
 * answers 404 for such a package, and no file is written.
 */
export function buildPackageIndex(name: string, rows: readonly VersionRecord[]): string | undefined {
  indexKey(name);
  const seen = new Set<string>();
  const shown: VersionRecord[] = [];
  for (const r of rows) {
    if (r.name !== name) throw new Error(`index: row ${r.name} ${r.version} does not belong to ${name}`);
    if (seen.has(r.version)) throw new Error(`index: ${name} ${r.version} appears twice`);
    seen.add(r.version);
    if (isIndexed(r)) shown.push(r);
  }
  if (shown.length === 0) return undefined;
  shown.sort((a, b) => compareVersions(a.version, b.version));
  return shown.map((r) => canonicalJson(recordOf(r)) + '\n').join('');
}

/**
 * A takedown log from every record of the registry: one entry per tombstoned version that still has its files (the sha256
 * values a lock can be explained by), sorted by date, then name, then numeric version. Ends in a newline. With no takedown
 * it is the empty log, which is also the seed of a fresh stage.
 *
 * `version` picks the log: 1 (`index/takedowns.json`) lists the flat names, 2 (`index/v2/takedowns.json`) the full names;
 * each log holds only its own version's names, so each reader sees the names it can resolve. A record lists the sha256 of
 * every file of the version, whatever its build.
 */
export function buildTakedowns(rows: readonly VersionRecord[], version: number = INDEX_VERSION): string {
  if (version !== INDEX_VERSION && version !== INDEX_VERSION_V2) throw new Error(`index: no takedown log of version ${version}`);
  const list = rows
    .filter((r) => r.state === 'tombstoned' && r.files.length > 0 && indexVersionOf(r.name) === version)
    .map((r) => {
      if (!r.tombstone) throw new Error(`index: ${r.name} ${r.version}: tombstoned without a tombstone`);
      return {
        name: r.name,
        version: r.version,
        reason_code: r.tombstone.reason_code,
        sha256: [...r.files].sort(BY_FILE).map((f) => f.sha256),
        date: r.tombstone.date,
      };
    })
    .sort((a, b) => cmp(a.date, b.date) || cmp(a.name, b.name) || compareVersions(a.version, b.version));
  return canonicalJson({ index_version: version, takedowns: list }) + '\n';
}

export type IndexStage = 'beta' | 'gamma' | 'prod';

export interface IndexConfigInput {
  stage: IndexStage;
  /** Host of the API, e.g. `api.beta.mopm.dev` (no scheme, no path). */
  apiDomain: string;
  /** Host of the channel, e.g. `conda.beta.mopm.dev`. */
  channelDomain: string;
  /** The live read-only switch of the stage. */
  readOnly: boolean;
}

const HOST = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;

/**
 * `index/config.json` for one stage, from stage configuration. `api_url` ends in `/api/v1`, `api_v2_url` in `/api/v2`
 * and `channel_url` in `/` (clients join paths onto it; a namespace's channel is `channel_url` + `<namespace>/`).
 * `index_version` stays 1, which released CLIs read; `index_versions` lists both served versions. Ends in a newline.
 */
export function buildIndexConfig(c: IndexConfigInput): string {
  if (!['beta', 'gamma', 'prod'].includes(c.stage)) throw new Error(`index config: unknown stage '${c.stage}'`);
  for (const [what, host] of [['apiDomain', c.apiDomain], ['channelDomain', c.channelDomain]] as const) {
    if (!HOST.test(host)) throw new Error(`index config: ${what} '${host}' is not a bare host name`);
  }
  if (!c.channelDomain.startsWith('conda.')) throw new Error(`index config: channelDomain '${c.channelDomain}' must start with 'conda.'`);
  return (
    canonicalJson({
      index_version: INDEX_VERSION,
      index_versions: INDEX_VERSIONS,
      stage: c.stage,
      api_url: `https://${c.apiDomain}/api/v1`,
      api_v2_url: `https://${c.apiDomain}/api/v2`,
      channel_url: `https://${c.channelDomain}/`,
      min_cli_version: MIN_CLI_VERSION,
      read_only: c.readOnly,
    }) + '\n'
  );
}
