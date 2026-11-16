import { RegistryError, HTTP_STATUS } from '../errors';
import { API_VIEW } from '../group';
import type { Store } from '../store';
import { README_MAX_BYTES, type PackageRecord, type PackageSummaryRecord, type VersionRecord } from '../types';
import { canonicalVersion, compareVersions } from '../version';
import { AuthError } from '../auth/errors';
import { routeAuth, type AuthServices } from './auth-routes';
import { render } from './catalogue';
import { templateFor } from './auth-catalogue';
import { routePublish, type PublishApi } from './publish-routes';
import { buildIndexConfig } from '../index-files';
import { flatCreationHint } from '../publish/catalogue';
import { createHash } from 'node:crypto';
import { routeV2, type V2Deps } from './v2-routes';

export type Stage = 'beta' | 'gamma' | 'prod';

export interface HttpRequest {
  method: string;
  /** The raw path, e.g. `/api/v1/packages/http_client`. */
  path: string;
  query: Record<string, string | undefined>;
  /** Lower-case names. Only `authorization` is read (login, tokens and the publish operations). */
  headers?: Record<string, string | undefined>;
  /** The raw (decoded) request body, for the operations that take one. */
  body?: string;
}

export interface HttpResponse {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

export interface RouterDeps {
  store: Store;
  stage: Stage;
  /** Release version and git commit, reported by /health so e2e can prove what is deployed. */
  version: string;
  commit: string;
  readOnly: boolean;
  /** Login, tokens and CI exchange. Absent: those paths answer `unavailable` and everything else is unchanged. */
  auth?: AuthServices;
  /** The publish operations (begin, commit, status). Absent: the router serves reads only. */
  publish?: PublishApi;
  /** The hosts `GET /index/config.json` names (from the stage's configuration). Absent: that path answers 404. */
  indexConfig?: { apiDomain: string; channelDomain: string };
  /** What `/api/v2` needs besides the services above (src/http/v2-routes.ts). Absent: every v2 path answers `unavailable`. */
  v2?: V2Deps;
}

export const INDEX_CONFIG_PATH = '/index/config.json';

const PREFIX = '/api/v1';
const NAME = /^[a-z][a-z0-9_]{1,63}$/;
const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 100;

/** Same rule as the contract: lowercase, runs of `-`, `.` and `_` collapse to one `_`. */
export const normaliseQuery = (q: string) => q.toLowerCase().replace(/[-._]+/g, '_');

function respond(statusCode: number, requestId: string, body?: unknown): HttpResponse {
  return {
    statusCode,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-mopm-request-id': requestId },
    body: body === undefined ? '' : JSON.stringify(body),
  };
}

function errorResponse(requestId: string, code: string, status: number, detail: Record<string, string>): HttpResponse {
  // Both callers pass a code the catalogue holds (the catch below checks it first).
  const entry = templateFor(code)!;
  return respond(status, requestId, {
    error: { code, message: render(entry.message, detail), hint: flatCreationHint(code, detail) ?? render(entry.hint, detail) },
  });
}

export const bad = (detail: string) => new RegistryError('invalid_request', detail, { detail });

// --- cursors: opaque to clients; base64url of a small JSON object that names what it continues ---------------

export type Cursor = { k: 'name'; after: string } | { k: 'updated'; ts: string; after: string } | { k: 'version'; after: string };

export const encodeCursor = (c: Cursor) => Buffer.from(JSON.stringify(c), 'utf8').toString('base64url');

export function decodeCursor(raw: string, kind: Cursor['k']): Cursor {
  const unknown = bad('cursor is not recognised');
  if (raw.length > 512) throw unknown;
  let c: any; // eslint-disable-line @typescript-eslint/no-explicit-any
  try {
    c = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
  } catch {
    throw unknown;
  }
  const ok =
    c && typeof c === 'object' && c.k === kind && typeof c.after === 'string' && (kind !== 'updated' || typeof c.ts === 'string');
  if (!ok) throw unknown;
  return c as Cursor;
}

export function parseLimit(raw: string | undefined): number {
  if (raw === undefined) return DEFAULT_LIMIT;
  if (!/^[0-9]+$/.test(raw)) throw bad('limit must be an integer from 1 to 100');
  const n = Number(raw);
  if (n < 1 || n > MAX_LIMIT) throw bad('limit must be an integer from 1 to 100');
  return n;
}

// --- projections ------------------------------------------------------------------------------------------

/** `pending` is internal: a reserved number whose files are not committed. It is never listed. */
export const visible = (vs: VersionRecord[]) => vs.filter((v) => v.state !== 'pending');
export const newestFirst = (vs: VersionRecord[]) => [...vs].sort((a, b) => compareVersions(b.version, a.version));

export function versionSummary(v: VersionRecord) {
  return {
    version: v.version,
    state: v.state,
    published_at: v.published_at,
    ...(v.state === 'yanked' && v.yank_reason !== undefined ? { yank_reason: v.yank_reason } : {}),
  };
}

/**
 * The optional display metadata (spec: VersionDetail, PackageInfo): a field is present only when it is stored.
 * A readme over the cap is dropped rather than truncated mid-character; the publish pipeline refuses such a readme,
 * so this is a guard for a row written some other way.
 */
export function displayMetadata(r: Partial<Pick<VersionRecord, 'description' | 'license' | 'repository' | 'homepage' | 'keywords' | 'readme'>>) {
  return {
    ...(r.description === undefined ? {} : { description: r.description }),
    ...(r.license === undefined ? {} : { license: r.license }),
    ...(r.repository === undefined ? {} : { repository: r.repository }),
    ...(r.homepage === undefined ? {} : { homepage: r.homepage }),
    ...(r.keywords === undefined ? {} : { keywords: r.keywords }),
    ...(r.readme === undefined || Buffer.byteLength(r.readme, 'utf8') > README_MAX_BYTES ? {} : { readme: r.readme }),
  };
}

/** Newest published version, or null (spec: PackageSummary.latest). */
export function latestOf(vs: VersionRecord[]): string | null {
  const candidates = vs.filter((v) => v.state === 'published');
  return candidates.length ? newestFirst(candidates)[0]!.version : null;
}

/** The newest publication time, or the claim time when nothing is published. */
const updatedAt = (p: PackageSummaryRecord, vs: VersionRecord[]) =>
  vs.reduce((m, v) => (v.published_at > m ? v.published_at : m), p.created_at);

export function readmeOf(vs: VersionRecord[]): string | undefined {
  const latest = latestOf(vs);
  const v = latest === null ? undefined : vs.find((x) => x.version === latest);
  return v === undefined ? undefined : displayMetadata({ readme: v.readme }).readme;
}

export function packageSummary(p: PackageSummaryRecord, vs: VersionRecord[]) {
  return { name: p.name, latest: latestOf(vs), description: p.description ?? null, updated_at: updatedAt(p, vs) };
}

// --- operations ---------------------------------------------------------------------------------------------

function validName(name: string): string {
  if (!NAME.test(name)) throw new RegistryError('invalid_name', `'${name}' is not a valid package name.`, { name });
  return name;
}

async function requirePackage(deps: RouterDeps, name: string): Promise<PackageRecord> {
  const p = await deps.store.getPackage(validName(name));
  if (!p) throw new RegistryError('package_not_found', `There is no package '${name}'.`, { name });
  return p;
}

/** `getHealth`, the same at both prefixes but for `api_version`. */
export const getHealth = (deps: RouterDeps, api_version: 'v1' | 'v2' = 'v1') => ({
  status: 'ok',
  stage: deps.stage,
  api_version,
  read_only: deps.readOnly,
  // Additive fields (the contract allows them): what e2e reads to prove which release is deployed.
  version: deps.version,
  commit: deps.commit,
  // Which implementation answered. This file is the TypeScript one; e2e compares it with the stage's expected implementation.
  impl: 'ts',
  // The optional features this registry serves: a member's readme may travel as an uploaded object.
  features: ['group_readme_objects'],
});

/**
 * `PackageInfo` but for who holds the package: `owners` (v1) or `namespace` (v2) goes after `state`, which is the only
 * difference between the two bodies.
 */
export async function packageInfo(deps: RouterDeps, p: PackageRecord, holder: () => Promise<Record<string, unknown>>) {
  const [who, all] = await Promise.all([holder(), deps.store.listVersions(p.name)]);
  const vs = visible(all);
  return {
    name: p.name,
    state: p.state,
    ...who,
    latest: latestOf(vs),
    repository: p.repository ?? null,
    license: p.license ?? null,
    description: p.description ?? null,
    ...(p.homepage === undefined ? {} : { homepage: p.homepage }),
    ...(p.keywords === undefined ? {} : { keywords: p.keywords }),
    // The readme of the latest version, when it has one.
    ...(readmeOf(vs) === undefined ? {} : { readme: readmeOf(vs) }),
    created_at: p.created_at,
    versions: newestFirst(vs).map(versionSummary),
  };
}

async function getPackage(deps: RouterDeps, name: string) {
  const p = await requirePackage(deps, name);
  const owners = async () => ({ owners: (await deps.store.listOwners(p.name)).map((o) => ({ github_id: o.github_id, handle: o.handle })) });
  return packageInfo(deps, p, owners);
}

async function listVersions(deps: RouterDeps, name: string, query: HttpRequest['query']) {
  return versionPage(deps, query, () => requirePackage(deps, name));
}

/** The page of `listVersions`: the limit and cursor are checked before the package is read. */
export async function versionPage(deps: RouterDeps, query: HttpRequest['query'], find: () => Promise<PackageRecord>) {
  const limit = parseLimit(query.limit);
  const after = query.cursor === undefined ? undefined : decodeCursor(query.cursor, 'version');
  const p = await find();
  let vs = newestFirst(visible(await deps.store.listVersions(p.name)));
  if (after) vs = vs.filter((v) => compareVersions(v.version, after.after) < 0);
  const page = vs.slice(0, limit);
  return {
    versions: page.map(versionSummary),
    next_cursor: vs.length > limit ? encodeCursor({ k: 'version', after: page[page.length - 1]!.version }) : null,
  };
}

/** `sort=updated` ranks every match by its newest publication, so it reads them all; beyond this many it refuses. */
export const MAX_UPDATED_SCAN = 1000;
export const SEARCH_PAGE = 100;

/** One read for the whole page, so that a group's members are all shown or all hidden (src/group.ts). */
export async function summarise(deps: RouterDeps, ps: PackageSummaryRecord[]) {
  const byName = await deps.store.versionsOf(
    ps.map((p) => p.name),
    API_VIEW,
  );
  return ps.map((p) => packageSummary(p, visible(byName.get(p.name)!)));
}

/** A row of the name index that `/api/v1` lists: a full name (`<namespace>/<name>`) belongs to `/api/v2`. */
const isFlat = (p: PackageSummaryRecord) => !p.name.includes('/');

/**
 * Up to `want` flat packages of the index from `prefix`, after `after`. A full name is skipped, so a page may take
 * several reads to fill.
 */
async function flatSearch(deps: RouterDeps, prefix: string, after: string | undefined, want: number) {
  const found: PackageSummaryRecord[] = [];
  // No flat name has a `/`: nothing to read.
  if (prefix.includes('/')) return found;
  const size = Math.min(want, SEARCH_PAGE);
  for (let last = after; found.length < want; ) {
    const chunk = await deps.store.searchPackages(prefix, last, size);
    for (const p of chunk) if (isFlat(p) && found.length < want) found.push(p);
    if (chunk.length < size) break;
    last = chunk[chunk.length - 1]!.name;
  }
  return found;
}

async function searchPackages(deps: RouterDeps, query: HttpRequest['query']) {
  const limit = parseLimit(query.limit);
  const sort = query.sort ?? 'name';
  if (sort !== 'name' && sort !== 'updated') throw bad("sort must be 'name' or 'updated'");
  const q = query.q === undefined ? '' : query.q;
  if (q.length > 64) throw bad('q is longer than 64 characters');
  const prefix = normaliseQuery(q);
  const after = query.cursor === undefined ? undefined : decodeCursor(query.cursor, sort);

  if (sort === 'name') {
    // A name cursor continues the index at that name; one that does not start with this query's prefix is for
    // another query and would be outside the index range.
    if (after && !after.after.startsWith(prefix)) throw bad('cursor does not belong to this query');
    // One more than the page, to know whether there is a next page.
    const found = await flatSearch(deps, prefix, after?.after, limit + 1);
    const page = found.slice(0, limit);
    return {
      packages: await summarise(deps, page),
      next_cursor: found.length > limit ? encodeCursor({ k: 'name', after: page[page.length - 1]!.name }) : null,
    };
  }

  // sort=updated needs every match's newest publication time (there is no index on it yet).
  const matches = await flatSearch(deps, prefix, undefined, MAX_UPDATED_SCAN + 1);
  if (matches.length > MAX_UPDATED_SCAN) throw bad(`sort=updated needs a longer q: more than ${MAX_UPDATED_SCAN} packages match`);
  return updatedPage(await summarise(deps, matches), limit, after);
}

/** The page of `sort=updated`: newest publication first, name order within a time, continuing after the cursor. */
export function updatedPage(summaries: ReturnType<typeof packageSummary>[], limit: number, after: Cursor | undefined) {
  let all = summaries;
  all.sort((a, b) => (a.updated_at === b.updated_at ? (a.name < b.name ? -1 : 1) : a.updated_at < b.updated_at ? 1 : -1));
  if (after && after.k === 'updated') {
    all = all.filter((s) => s.updated_at < after.ts || (s.updated_at === after.ts && s.name > after.after));
  }
  const page = all.slice(0, limit);
  const last = page[page.length - 1];
  return {
    packages: page,
    next_cursor: all.length > limit && last ? encodeCursor({ k: 'updated', ts: last.updated_at, after: last.name }) : null,
  };
}

async function listOwners(deps: RouterDeps, name: string) {
  const p = await requirePackage(deps, name);
  return { owners: (await deps.store.listOwners(p.name)).map((o) => ({ github_id: o.github_id, handle: o.handle })) };
}

/** The full record of one version (spec: VersionDetail). A pending version is not visible; any equivalent spelling finds it. */
async function getVersion(deps: RouterDeps, name: string, version: string) {
  validName(name);
  canonicalVersion(version); // throws invalid_version before anything is read
  const p = await requirePackage(deps, name);
  return versionDetail(deps, p, version);
}

/** The version row of `p`, as `VersionDetail`; `version_not_found` for a missing or pending one. */
export async function versionDetail(deps: RouterDeps, p: PackageRecord, version: string) {
  const v = await deps.store.getVersion(p.name, version);
  if (!v || v.state === 'pending') throw new RegistryError('version_not_found', `'${p.name}' has no version '${version}'.`, { name: p.name, version });
  return {
    name: v.name,
    version: v.version,
    state: v.state,
    yank_reason: v.state === 'yanked' ? (v.yank_reason ?? null) : null,
    ...(v.tombstone ? { tombstone: v.tombstone } : {}),
    published_at: v.published_at,
    ...(v.published_by === undefined ? {} : { published_by: v.published_by }),
    requires_mojo: v.requires_mojo,
    deps: v.deps,
    native: v.native,
    // A tombstoned version keeps each file's sha256 but not its url, whatever the row still holds.
    files: v.files.map((f) => {
      const { url, ...rest } = f;
      return v.state === 'tombstoned' || url === undefined ? rest : { ...rest, url };
    }),
    manifest_sha256: v.manifest_sha256,
    // Present when a group published the version; absent for a single publish.
    ...(v.group_id !== undefined ? { group_id: v.group_id } : {}),
    ...displayMetadata(v),
    // Informational: what the publisher said at commit, never checked by the registry. Absent on a version published without one.
    ...(v.source_commit === undefined ? {} : { source_commit: v.source_commit }),
    provenance: v.provenance ?? { kind: 'none' },
  };
}

function segments(path: string): string[] | undefined {
  if (path !== PREFIX && !path.startsWith(`${PREFIX}/`)) return undefined;
  try {
    return path.slice(PREFIX.length).split('/').filter(Boolean).map(decodeURIComponent);
  } catch {
    return undefined;
  }
}

/** `/index/config.json`, built from the stage's configuration and the live read-only switch. Nothing is read from a bucket. */
function indexConfig(deps: RouterDeps, requestId: string): HttpResponse {
  if (!deps.indexConfig) throw new RegistryError('route_not_found', 'no such operation');
  const body = buildIndexConfig({ stage: deps.stage, ...deps.indexConfig, readOnly: deps.readOnly });
  return {
    statusCode: 200,
    headers: {
      'content-type': 'application/json',
      'cache-control': 'public, max-age=60',
      etag: `"${createHash('sha256').update(body).digest('hex')}"`,
      'x-mopm-request-id': requestId,
    },
    body,
  };
}

/** Handle one request. Never throws: every failure is an error body from the contract's catalogue. */
export async function route(req: HttpRequest, deps: RouterDeps, requestId: string): Promise<HttpResponse> {
  try {
    if (req.path === INDEX_CONFIG_PATH && req.method === 'GET') return indexConfig(deps, requestId);
    const v2 = await routeV2(req, deps, requestId);
    if (v2) return v2;
    if (deps.publish) {
      const published = await routePublish(req, deps.publish, requestId);
      if (published) return published;
    }
    const seg = segments(req.path);
    if (seg) {
      const authed = await routeAuth({ method: req.method, seg, authorization: req.headers?.authorization, body: req.body }, deps.auth);
      if (authed) return respond(authed.status, requestId, authed.body);
    }
    if (seg && req.method === 'GET') {
      if (seg.length === 1 && seg[0] === 'health') return respond(200, requestId, getHealth(deps));
      if (seg.length === 1 && seg[0] === 'packages') return respond(200, requestId, await searchPackages(deps, req.query));
      if (seg.length === 2 && seg[0] === 'packages') return respond(200, requestId, await getPackage(deps, seg[1]!));
      if (seg.length === 3 && seg[0] === 'packages' && seg[2] === 'versions') {
        return respond(200, requestId, await listVersions(deps, seg[1]!, req.query));
      }
      if (seg.length === 3 && seg[0] === 'packages' && seg[2] === 'owners') {
        return respond(200, requestId, await listOwners(deps, seg[1]!));
      }
      // `claim` is a literal segment of another operation (POST), never a version (spec: versions start with a digit).
      if (seg.length === 3 && seg[0] === 'packages' && seg[2] !== 'claim') {
        return respond(200, requestId, await getVersion(deps, seg[1]!, seg[2]!));
      }
    }
    // The gateway routes only the operations above, so this is reached only by a request that cannot come through it.
    throw new RegistryError('route_not_found', 'no such operation');
  } catch (err) {
    if ((err instanceof RegistryError || err instanceof AuthError) && templateFor(err.code)) {
      return errorResponse(requestId, err.code, err.status, err.detail);
    }
    console.error(JSON.stringify({ level: 'error', requestId, error: String((err as Error)?.stack ?? err) }));
    return errorResponse(requestId, 'internal_error', HTTP_STATUS.internal_error, {});
  }
}
