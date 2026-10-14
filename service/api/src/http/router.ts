import { RegistryError, HTTP_STATUS } from '../errors';
import type { Store } from '../store';
import type { PackageRecord, VersionRecord } from '../types';
import { compareVersions, parseVersion } from '../version';
import { AuthError } from '../auth/errors';
import { routeAuth, type AuthServices } from './auth-routes';
import { render } from './catalogue';
import { templateFor } from './auth-catalogue';

export type Stage = 'beta' | 'gamma' | 'prod';

export interface HttpRequest {
  method: string;
  /** The raw path, e.g. `/api/v1/packages/http_client`. */
  path: string;
  query: Record<string, string | undefined>;
  /** Request headers by lower-case name. Only `authorization` is read. */
  headers?: Record<string, string | undefined>;
  /** The raw request body, for the operations that take one. */
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
}

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
  const entry = templateFor(code);
  if (!entry) return errorResponse(requestId, 'internal_error', HTTP_STATUS.internal_error, {});
  return respond(status, requestId, {
    error: { code, message: render(entry.message, detail), hint: render(entry.hint, detail) },
  });
}

const bad = (detail: string) => new RegistryError('invalid_request', detail, { detail });

// --- cursors: opaque to clients; base64url of a small JSON object that names what it continues ---------------

type Cursor = { k: 'name'; after: string } | { k: 'updated'; ts: string; after: string } | { k: 'version'; after: string };

const encodeCursor = (c: Cursor) => Buffer.from(JSON.stringify(c), 'utf8').toString('base64url');

function decodeCursor(raw: string, kind: Cursor['k']): Cursor {
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

function parseLimit(raw: string | undefined): number {
  if (raw === undefined) return DEFAULT_LIMIT;
  if (!/^[0-9]+$/.test(raw)) throw bad('limit must be an integer from 1 to 100');
  const n = Number(raw);
  if (n < 1 || n > MAX_LIMIT) throw bad('limit must be an integer from 1 to 100');
  return n;
}

// --- projections ------------------------------------------------------------------------------------------

/** `pending` is internal: a reserved number whose files are not committed. It is never listed. */
const visible = (vs: VersionRecord[]) => vs.filter((v) => v.state !== 'pending');
const newestFirst = (vs: VersionRecord[]) => [...vs].sort((a, b) => compareVersions(b.version, a.version));

function versionSummary(v: VersionRecord) {
  return {
    version: v.version,
    state: v.state,
    published_at: v.published_at,
    ...(v.state === 'yanked' && v.yank_reason !== undefined ? { yank_reason: v.yank_reason } : {}),
  };
}

/** Newest published, non-prerelease version, or null (spec: PackageSummary.latest). */
function latestOf(vs: VersionRecord[]): string | null {
  const candidates = vs.filter((v) => v.state === 'published' && parseVersion(v.version).pre === undefined);
  return candidates.length ? newestFirst(candidates)[0]!.version : null;
}

/** The newest publication time, or the claim time when nothing is published. */
const updatedAt = (p: PackageRecord, vs: VersionRecord[]) =>
  vs.reduce((m, v) => (v.published_at > m ? v.published_at : m), p.created_at);

function packageSummary(p: PackageRecord, vs: VersionRecord[]) {
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

const getHealth = (deps: RouterDeps) => ({
  status: 'ok',
  stage: deps.stage,
  api_version: 'v1',
  read_only: deps.readOnly,
  // Additive fields (the contract allows them): what e2e reads to prove which release is deployed.
  version: deps.version,
  commit: deps.commit,
});

async function getPackage(deps: RouterDeps, name: string) {
  const p = await requirePackage(deps, name);
  const [owners, all] = await Promise.all([deps.store.listOwners(p.name), deps.store.listVersions(p.name)]);
  const vs = visible(all);
  return {
    name: p.name,
    state: p.state,
    owners: owners.map((o) => ({ github_id: o.github_id, handle: o.handle })),
    latest: latestOf(vs),
    repository: p.repository ?? null,
    license: p.license ?? null,
    description: p.description ?? null,
    created_at: p.created_at,
    versions: newestFirst(vs).map(versionSummary),
  };
}

async function listVersions(deps: RouterDeps, name: string, query: HttpRequest['query']) {
  const limit = parseLimit(query.limit);
  const after = query.cursor === undefined ? undefined : decodeCursor(query.cursor, 'version');
  const p = await requirePackage(deps, name);
  let vs = newestFirst(visible(await deps.store.listVersions(p.name)));
  if (after) vs = vs.filter((v) => compareVersions(v.version, after.after) < 0);
  const page = vs.slice(0, limit);
  return {
    versions: page.map(versionSummary),
    next_cursor: vs.length > limit ? encodeCursor({ k: 'version', after: page[page.length - 1]!.version }) : null,
  };
}

async function searchPackages(deps: RouterDeps, query: HttpRequest['query']) {
  const limit = parseLimit(query.limit);
  const sort = query.sort ?? 'name';
  if (sort !== 'name' && sort !== 'updated') throw bad("sort must be 'name' or 'updated'");
  const q = query.q === undefined ? '' : query.q;
  if (q.length > 64) throw bad('q is longer than 64 characters');
  const prefix = normaliseQuery(q);
  const after = query.cursor === undefined ? undefined : decodeCursor(query.cursor, sort);

  let names: string[];
  try {
    names = await deps.store.listPackageNames();
  } catch (err) {
    // The Lambda's role may only GetItem and Query (read-only by design); listing every package name needs a
    // Scan or an index the data stack does not have yet. Say so honestly rather than answer 500.
    if ((err as { name?: string }).name === 'AccessDeniedException') throw new RegistryError('unavailable', 'search is not available', {});
    throw err;
  }
  names = names.filter((n) => n.startsWith(prefix)).sort();

  const load = async (name: string) => {
    const p = await deps.store.getPackage(name);
    if (!p) return undefined;
    return packageSummary(p, visible(await deps.store.listVersions(name)));
  };

  if (sort === 'name') {
    if (after) names = names.filter((n) => n > after.after);
    const page = names.slice(0, limit);
    const packages = (await Promise.all(page.map(load))).filter((x) => x !== undefined);
    return {
      packages,
      next_cursor: names.length > limit ? encodeCursor({ k: 'name', after: page[page.length - 1]! }) : null,
    };
  }

  // sort=updated needs every match's newest publication time. In memory for now (see the follow-up in the PR).
  let all = (await Promise.all(names.map(load))).filter((x) => x !== undefined);
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

function segments(path: string): string[] | undefined {
  if (path !== PREFIX && !path.startsWith(`${PREFIX}/`)) return undefined;
  try {
    return path.slice(PREFIX.length).split('/').filter(Boolean).map(decodeURIComponent);
  } catch {
    return undefined;
  }
}

/** Handle one request. Never throws: every failure is an error body from the contract's catalogue. */
export async function route(req: HttpRequest, deps: RouterDeps, requestId: string): Promise<HttpResponse> {
  try {
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
    }
    // The gateway routes only the operations below, so this is unreachable there; the catalogue has no
    // "no such endpoint" code, so the generic 400 is the closest stable answer.
    throw bad('no such operation');
  } catch (err) {
    if ((err instanceof RegistryError || err instanceof AuthError) && templateFor(err.code)) {
      return errorResponse(requestId, err.code, err.status, err.detail);
    }
    console.error(JSON.stringify({ level: 'error', requestId, error: String((err as Error)?.stack ?? err) }));
    return errorResponse(requestId, 'internal_error', HTTP_STATUS.internal_error, {});
  }
}
