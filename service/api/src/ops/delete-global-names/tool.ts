import { createHash } from 'node:crypto';
import type { AuthStore } from '../../auth/types';
import { canonicalJson } from '../../canonical-json';
import { indexKey } from '../../index-files';
import type { Invalidator, ListableObjectStore } from '../../publish/ports';
import type { RowDeleter, Store } from '../../store';
import { SUBDIRS_V1 } from '../../types';
import { zstdFrame } from '../../zstd';

/**
 * The held tool that deletes the global (flat) package names once every package lives in a namespace
 * (docs/design/namespaces.md, section 12.4). An operator runs it per stage, beta, then gamma, then prod, each after
 * reading its dry run (service/docs/runbook.md, "Deleting the global names").
 *
 * - A dry run unless `--apply=<digest>` is given. It lists the work from the stage itself (never from a file): every
 *   package whose name has no namespace, with its versions, owners and trusted publishers, the channel objects under each
 *   subdir at the bucket's root (`<subdir>/mojo-<name>-*.conda`) and the version 1 index file. It prints them per name,
 *   the totals and a digest of the whole listing.
 * - `--apply=<digest>` lists again and refuses unless the digest is the dry run's, and refuses unless the stage serves
 *   index version 2 and `/api/v1` refuses to create a flat name. It never forces and never retries: a step that fails stops
 *   the run.
 * - Per name, in this order: a `delete_global` audit record (the audit log is append-only and keeps the history); the
 *   name out of the version 1 index and out of the root repodata; its channel objects; its version, owner and publisher
 *   rows; its package row last. A run that stops part way leaves the package row, so the next dry run lists the name
 *   again; it also lists by bucket prefix, so a name whose package row is gone but whose files are not is finished too.
 * - Names that start with `kci_` are kept: listed as kept, never touched, never part of the digest.
 *
 * Nothing here reads the environment: every setting is a flag (the AWS credentials are the SDK's standard variables).
 */

/** Names kept whatever their namespace: the kci packages stay as they are. */
export const KEPT_PREFIX = 'kci_';

/** The audit action of a deletion. */
export const AUDIT_ACTION = 'delete_global';

/** The flat name grammar (spec/index.md). A name with a namespace has a `/` and never matches. */
const FLAT_NAME = /^[a-z][a-z0-9_]{1,63}$/;
/** A flat package's file at the bucket's root, after its `<subdir>/`: `mojo-<name>-<version>-<build>.conda`. */
const ROOT_FILE = /^mojo-([a-z][a-z0-9_]{1,63})-[^/]+\.conda$/;

const REPODATA_CACHE = 'public, max-age=60';

export type Stage = 'beta' | 'gamma' | 'prod';
export const STAGES: readonly Stage[] = ['beta', 'gamma', 'prod'];

export interface DeleteArgs {
  stage: Stage;
  /** The channel bucket's name. */
  bucket: string;
  /** The channel's CloudFront distribution id, for the invalidations. */
  distribution: string;
  /** The stage's `/index/config.json` URL. */
  configUrl: string;
  region?: string;
  /** The digest of the dry run to apply. Absent: a dry run. */
  apply?: string;
}

const USAGE =
  'usage: delete-global-names --stage=<beta|gamma|prod> --bucket=<channel bucket> --distribution=<cloudfront id> --config-url=<url of /index/config.json> [--region=<region>] [--apply=<digest>]';
const DIGEST = /^[0-9a-f]{64}$/;

/** The flags as DeleteArgs. Throws an Error that says what is wrong. No positional arguments: every setting is a flag. */
export function parseDeleteArgs(argv: readonly string[]): DeleteArgs {
  const flags = new Map<string, string>();
  for (const a of argv) {
    const m = /^--([a-z-]+)=(.+)$/.exec(a);
    if (!m) throw new Error(`${USAGE}\nnot a flag with a value: ${a}`);
    if (flags.has(m[1]!)) throw new Error(`${USAGE}\n--${m[1]} is given twice`);
    flags.set(m[1]!, m[2]!);
  }
  const known = new Set(['stage', 'bucket', 'distribution', 'config-url', 'region', 'apply']);
  for (const k of flags.keys()) if (!known.has(k)) throw new Error(`${USAGE}\nunknown flag --${k}`);
  const stage = flags.get('stage') as Stage | undefined;
  if (!stage || !STAGES.includes(stage)) throw new Error(`${USAGE}\n--stage is beta, gamma or prod`);
  for (const k of ['bucket', 'distribution', 'config-url']) if (!flags.has(k)) throw new Error(`${USAGE}\n--${k} is required`);
  const apply = flags.get('apply');
  if (apply !== undefined && !DIGEST.test(apply)) throw new Error(`${USAGE}\n--apply takes the 64 hex digits of a dry run's digest`);
  const region = flags.get('region');
  return {
    stage,
    bucket: flags.get('bucket')!,
    distribution: flags.get('distribution')!,
    configUrl: flags.get('config-url')!,
    ...(region ? { region } : {}),
    ...(apply ? { apply } : {}),
  };
}

/** What the stage says about the move to namespaces: both must hold before anything is deleted. */
export interface StageChecks {
  /** The index versions `/index/config.json` lists (`index_versions`, else `[index_version]`). */
  index_versions: number[];
  /** Whether `/api/v1` refuses to create a flat name (`name_reserved`). */
  v1_refuses_flat_creation: boolean;
}

export interface DeleteDeps {
  registry: Pick<Store, 'listPackageNames' | 'listVersions' | 'listOwners' | 'removeOwner' | 'appendAudit'> & RowDeleter;
  publishers: Pick<AuthStore, 'listTrustedPublishers' | 'removeTrustedPublisher'>;
  bucket: ListableObjectStore;
  invalidator: Invalidator;
  checks(): Promise<StageChecks>;
  now?: () => Date;
  /** One JSON line each. */
  out: (line: Record<string, unknown>) => void;
}

/** Everything of one flat name the tool deletes, as listed from the stage. */
export interface NameListing {
  name: string;
  /** Whether the package row exists. */
  package: boolean;
  /** Oldest to newest; `files` are `<subdir>/<file name>`, sorted. */
  versions: Array<{ version: string; canonical: string; state: string; files: string[] }>;
  owners: Array<{ github_id: number; handle: string }>;
  /** In the auth store's order (the DynamoDB adapter's is by id). */
  publishers: Array<{ id: string; repository_id: string; workflow: string }>;
  /** The name's `.conda` files at the bucket's root. */
  objects: Array<{ key: string; size: number }>;
  /** The version 1 index file's key, when it exists. */
  index?: string;
}

export interface Listing {
  stage: Stage;
  names: NameListing[];
  /** Flat names that start with KEPT_PREFIX: listed so the operator sees them, never deleted. */
  kept: string[];
}

/**
 * Read the work list from the stage. The names are the flat package rows, the flat names of the `.conda` files at the
 * bucket's root (in the four subdirs of version 1 and any other subdir a row names) and the version 1 index files; then
 * each name's rows and objects. Deterministic for one stage: names, subdirs and keys are in code-unit order (the default
 * sort of strings, independent of the locale), and rows in the order the store gives them.
 */
export async function listStage(stage: Stage, d: DeleteDeps): Promise<Listing> {
  const fromRows = (await d.registry.listPackageNames()).filter((n) => FLAT_NAME.test(n));
  const rows = new Map<string, NameListing['versions']>();
  for (const name of fromRows) rows.set(name, await versionsOf(d, name));
  const subdirs = new Set<string>(SUBDIRS_V1);
  for (const vs of rows.values()) for (const v of vs) for (const f of v.files) subdirs.add(f.split('/')[0]!);

  const objects = new Map<string, NameListing['objects']>();
  for (const subdir of [...subdirs].sort()) {
    for (const o of await d.bucket.list(`${subdir}/mojo-`)) {
      const m = ROOT_FILE.exec(o.key.slice(subdir.length + 1));
      if (m) objects.set(m[1]!, [...(objects.get(m[1]!) ?? []), { key: o.key, size: o.size }]);
    }
  }
  const indexed = new Set<string>();
  for (const o of await d.bucket.list('index/')) {
    const parts = o.key.split('/');
    if (parts.length === 4 && FLAT_NAME.test(parts[3]!) && indexKey(parts[3]!) === o.key) indexed.add(parts[3]!);
  }

  const all = [...new Set([...fromRows, ...objects.keys(), ...indexed])].sort();
  const kept = all.filter((n) => n.startsWith(KEPT_PREFIX));
  const names: NameListing[] = [];
  for (const name of all.filter((n) => !n.startsWith(KEPT_PREFIX))) {
    const versions = rows.get(name) ?? (await versionsOf(d, name));
    names.push({
      name,
      package: rows.has(name),
      versions,
      owners: (await d.registry.listOwners(name)).map((o) => ({ github_id: o.github_id, handle: o.handle })),
      publishers: (await d.publishers.listTrustedPublishers(name)).map((p) => ({ id: p.id, repository_id: p.repository_id, workflow: p.workflow })),
      objects: objects.get(name) ?? [],
      ...(indexed.has(name) ? { index: indexKey(name) } : {}),
    });
  }
  return { stage, names, kept };
}

async function versionsOf(d: DeleteDeps, name: string): Promise<NameListing['versions']> {
  return (await d.registry.listVersions(name)).map((r) => ({
    version: r.version,
    canonical: r.canonical,
    state: r.state,
    files: r.files.map((f) => `${f.subdir}/${f.filename}`).sort(),
  }));
}

/** The sha256 of the canonical JSON of the stage and its work list: kept names are not part of it. */
export const digestOf = (l: Listing): string => createHash('sha256').update(canonicalJson({ stage: l.stage, names: l.names })).digest('hex');

/** The subdirs whose root repodata may list the name: those its rows name and those its files are in. */
const subdirsOf = (n: NameListing): string[] =>
  [...new Set([...n.versions.flatMap((v) => v.files), ...n.objects.map((o) => o.key)].map((k) => k.split('/')[0]!))].sort();

/** Exit status: 0 done (or the dry run printed), 2 refused (nothing was deleted by this run since the refusal), 1 failed (main). */
export async function runDelete(args: DeleteArgs, d: DeleteDeps): Promise<number> {
  const listing = await listStage(args.stage, d);
  const digest = digestOf(listing);
  if (args.apply === undefined) return dryRun(listing, digest, d);
  if (args.apply !== digest) {
    d.out({ kind: 'refused', reason: 'the listing is not the dry run\'s: run the dry run again and read it', expected: args.apply, listed: digest });
    return 2;
  }
  const checks = await d.checks();
  if (!checks.index_versions.includes(2) || !checks.v1_refuses_flat_creation) {
    d.out({ kind: 'refused', reason: 'the stage does not serve namespaces yet: index version 2 and a /api/v1 that refuses flat names come first', ...checks });
    return 2;
  }
  const at = (d.now ?? (() => new Date()))().toISOString();
  for (const n of listing.names) {
    const code = await deleteName(n, args.stage, digest, at, d);
    if (code !== 0) return code;
  }
  d.out({ kind: 'done', stage: args.stage, names: listing.names.length, digest });
  return 0;
}

async function dryRun(l: Listing, digest: string, d: DeleteDeps): Promise<number> {
  for (const n of l.names) {
    d.out({
      kind: 'name',
      name: n.name,
      package: n.package,
      versions: n.versions.map((v) => `${v.version} ${v.state}`),
      owners: n.owners.map((o) => o.handle),
      publishers: n.publishers.map((p) => p.id),
      objects: n.objects.length,
      bytes: n.objects.reduce((s, o) => s + o.size, 0),
      index: n.index ?? null,
    });
  }
  for (const name of l.kept) d.out({ kind: 'kept', name, reason: `${KEPT_PREFIX} packages are kept` });
  d.out({ kind: 'checks', ...(await d.checks()) });
  const sum = (f: (n: NameListing) => number) => l.names.reduce((s, n) => s + f(n), 0);
  d.out({
    kind: 'totals',
    stage: l.stage,
    names: l.names.length,
    packages: sum((n) => (n.package ? 1 : 0)),
    versions: sum((n) => n.versions.length),
    owners: sum((n) => n.owners.length),
    publishers: sum((n) => n.publishers.length),
    objects: sum((n) => n.objects.length),
    bytes: sum((n) => n.objects.reduce((s, o) => s + o.size, 0)),
    index_files: sum((n) => (n.index ? 1 : 0)),
    kept: l.kept.length,
  });
  d.out({ kind: 'digest', digest, dry_run: true });
  return 0;
}

/** Drop the name's entries from one root repodata: its `mojo-<name>` packages and its `removed` file names. Undefined when none. */
export function withoutName(repodata: Buffer, name: string): string | undefined {
  const doc = JSON.parse(repodata.toString('utf8')) as Record<string, unknown>;
  const pkg = `mojo-${name}`;
  let changed = false;
  for (const table of ['packages', 'packages.conda']) {
    const entries = doc[table] as Record<string, { name?: string }> | undefined;
    if (!entries) continue;
    for (const [file, e] of Object.entries(entries)) {
      if (e?.name === pkg) {
        delete entries[file];
        changed = true;
      }
    }
  }
  const removed = doc.removed as string[] | undefined;
  if (removed) {
    const kept = removed.filter((f) => !f.startsWith(`${pkg}-`));
    if (kept.length !== removed.length) {
      doc.removed = kept;
      changed = true;
    }
  }
  return changed ? canonicalJson(doc) : undefined;
}

async function deleteName(n: NameListing, stage: Stage, digest: string, at: string, d: DeleteDeps): Promise<number> {
  const step = (s: string, extra: Record<string, unknown> = {}) => d.out({ kind: 'step', name: n.name, step: s, ...extra });

  // 1. The audit record first: whatever happens next, the log says who started deleting the name and from which listing.
  await d.registry.appendAudit({
    name: n.name,
    ts: at,
    id: `${AUDIT_ACTION}_${digest.slice(0, 16)}`,
    actor: 'operator',
    action: AUDIT_ACTION,
    detail: { stage, digest, versions: String(n.versions.length), objects: String(n.objects.length) },
  });
  step('audit');

  // 2. Out of the version 1 index and the root repodata, so no reader is sent to a file about to go.
  const paths: string[] = [];
  if (n.index) {
    await d.bucket.delete(n.index);
    paths.push(`/${n.index}`);
  }
  for (const subdir of subdirsOf(n)) {
    const key = `${subdir}/repodata.json`;
    const cur = await d.bucket.get(key);
    const next = cur && withoutName(cur, n.name);
    if (next === undefined) continue;
    const json = Buffer.from(next, 'utf8');
    await d.bucket.put(key, json, { contentType: 'application/json', cacheControl: REPODATA_CACHE });
    await d.bucket.put(`${key}.zst`, zstdFrame(json), { contentType: 'application/zstd', cacheControl: REPODATA_CACHE });
    paths.push(`/${key}`, `/${key}.zst`);
  }
  step('index', { index: n.index ?? null, repodata: paths.filter((p) => p.endsWith('/repodata.json')).map((p) => p.slice(1)) });

  // 3. The channel objects. The bucket is versioned: each delete leaves the bytes as a non-current version.
  for (const o of n.objects) {
    await d.bucket.delete(o.key);
    paths.push(`/${o.key}`);
  }
  if (paths.length) await d.invalidator.invalidate(paths, `${AUDIT_ACTION}-${n.name}-${digest.slice(0, 16)}`);
  step('objects', { deleted: n.objects.length });

  // 4. The rows. A version that appeared after the listing stops the run before the package row goes.
  for (const v of n.versions) await d.registry.deleteVersionRow(n.name, v.canonical);
  for (const o of n.owners) await d.registry.removeOwner(n.name, o.github_id);
  for (const p of n.publishers) await d.publishers.removeTrustedPublisher(n.name, p.id);
  step('rows', { versions: n.versions.length, owners: n.owners.length, publishers: n.publishers.length });
  const left = await d.registry.listVersions(n.name);
  if (left.length) {
    d.out({ kind: 'refused', name: n.name, reason: 'versions appeared after the listing; the package row is kept: run the dry run again', versions: left.map((r) => r.version) });
    return 2;
  }

  // 5. The package row last: until it goes, the name is on the next run's work list.
  if (n.package) await d.registry.deletePackageRow(n.name);
  d.out({ kind: 'deleted', name: n.name });
  return 0;
}
