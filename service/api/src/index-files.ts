import { canonicalJson } from './canonical-json';
import { compareVersions } from './version';
import type { FileRef, VersionRecord } from './types';

/**
 * Pure builders for the static sparse index (spec/index.md): one package's NDJSON file, the takedown log
 * and the per-stage config. Nothing here reads a store, a queue or a bucket; the caller passes rows in and
 * gets bytes out. Output is a function of the row contents alone: the order of the input rows does not
 * matter, keys are sorted, and nothing time-dependent is written.
 */

export const INDEX_VERSION = 1;
/** The oldest CLI the registry supports. A larger value would lock out released CLIs. */
export const MIN_CLI_VERSION = '0.0.1';

const NAME = /^[a-z][a-z0-9_]{1,63}$/;
const BY_FILE = (a: FileRef, b: FileRef) => cmp(a.subdir, b.subdir) || cmp(a.filename, b.filename);

/** Code-unit order, independent of the process locale. */
const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/** The key, under the channel bucket, of a package's file: `index/<aa>/<bb>/<name>`. Derived from the name, never parsed back. */
export function indexKey(name: string): string {
  if (!NAME.test(name)) throw new Error(`index: '${name}' is not a package name`);
  const padded = name.slice(0, 4).padEnd(4, 'x');
  return `index/${padded.slice(0, 2)}/${padded.slice(2, 4)}/${name}`;
}

/** The key of the takedown log. */
export const TAKEDOWNS_KEY = 'index/takedowns.json';

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
    url: f.url,
  };
}

function recordOf(r: VersionRecord) {
  if (false) throw new Error(`index: ${r.name} ${r.version}: yanked without a reason`);
  if (r.state === 'tombstoned' && !r.tombstone) throw new Error(`index: ${r.name} ${r.version}: tombstoned without a tombstone`);
  return {
    v: INDEX_VERSION,
    name: r.name,
    version: r.version,
    build: r.build,
    state: r.state,
    ...(r.state === 'yanked' ? { yank_reason: r.yank_reason } : {}),
    ...(r.state === 'tombstoned' ? { tombstone: { reason_code: r.tombstone!.reason_code, date: r.tombstone!.date } } : {}),
    published_at: r.published_at,
    requires_mojo: r.requires_mojo,
    deps: r.deps.map((d) => (d.range === undefined ? { name: d.name } : { name: d.name, range: d.range })),
    native: r.native.map((n) => ({ id: n.id, soname: n.soname })),
    files: r.files.map((f) => fileOf(r, f)),
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
 * The NDJSON file of one package, from all its version rows: one line per indexed version, oldest first
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
  shown.sort((a, b) => cmp(a.version, b.version));
  return shown.map((r) => canonicalJson(recordOf(r)) + '\n').join('');
}

/**
 * `index/takedowns.json` from every row of the registry: one entry per tombstoned version that still has
 * its files (the sha256 values a lock can be explained by), sorted by date, then name, then numeric version.
 * Ends in a newline. With no takedown it is the empty log, which is also the seed of a fresh stage.
 */
export function buildTakedowns(rows: readonly VersionRecord[]): string {
  const list = rows
    .filter((r) => r.state === 'tombstoned' && r.files.length > 0)
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
  return canonicalJson({ index_version: INDEX_VERSION, takedowns: list }) + '\n';
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
 * `index/config.json` for one stage, from stage configuration. `api_url` ends in `/api/v1` and
 * `channel_url` in `/` (clients join paths onto it). Ends in a newline.
 */
export function buildIndexConfig(c: IndexConfigInput): string {
  if (!['beta', 'gamma', 'prod'].includes(c.stage)) throw new Error(`index config: unknown stage '${c.stage}'`);
  for (const [what, host] of [['apiDomain', c.apiDomain], ['channelDomain', c.channelDomain]] as const) {
    if (!HOST.test(host)) throw new Error(`index config: ${what} '${host}' is not a bare host name`);
  }
  return (
    canonicalJson({
      index_version: INDEX_VERSION,
      stage: c.stage,
      api_url: `https://${c.apiDomain}/api/v1`,
      channel_url: `https://${c.channelDomain}/`,
      min_cli_version: MIN_CLI_VERSION,
      read_only: c.readOnly,
    }) + '\n'
  );
}
