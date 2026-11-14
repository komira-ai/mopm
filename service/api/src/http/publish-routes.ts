import { AuthError } from '../auth/errors';
import { invalidNamespace, type Authenticator, type Principal } from '../auth';
import { namespaceProblem } from '../auth/namespaces';
import { NAME_PATTERN } from '../names';
import { errorView, flatCreationRefused } from '../publish/catalogue';
import type { ClaimService } from '../publish/claim';
import { PublishError, invalidRequest } from '../publish/errors';
import type { Flags } from '../publish/ports';
import type { ApiVersion, GroupRequest, GroupService } from '../publish/group-service';
import { actorOf, type PublishService } from '../publish/service';
import { RegistryError } from '../errors';
import type { HttpRequest, HttpResponse } from './router';
import { errorViewV2 } from './v2-catalogue';
import type { V2Deps } from './v2-routes';

/** What the publish operations need: who is calling, what they may do, and whether uploads are allowed at all. */
export interface PublishApi {
  auth: Authenticator;
  service: PublishService;
  flags: Flags;
  /** The group routes. Absent: they are not routes of this deployment, and the router answers route_not_found. */
  groups?: GroupService;
  /** Kept for the wiring that still builds it. `POST /packages/{name}/claim` no longer creates, so the route does not use it. */
  claims?: ClaimService;
}

const PREFIXES: Record<ApiVersion, string> = { v1: '/api/v1', v2: '/api/v2' };

function respond(statusCode: number, requestId: string, body: unknown, extra: Record<string, string> = {}): HttpResponse {
  return {
    statusCode,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-mopm-request-id': requestId, ...extra },
    body: JSON.stringify(body),
  };
}

function failure(err: unknown, requestId: string, api: ApiVersion): HttpResponse {
  const v = api === 'v2' ? errorViewV2(err) : errorView(err);
  if (v.body.error.code === 'internal_error') {
    console.error(JSON.stringify({ level: 'error', requestId, error: String((err as Error)?.stack ?? err) }));
  }
  return respond(v.status, requestId, v.body, v.retryAfter !== undefined ? { 'retry-after': String(v.retryAfter) } : {});
}

interface Target {
  api: ApiVersion;
  /** The decoded segments after the prefix. Under /api/v2 a package path `packages/{namespace}/{name}/{version}/{op}` reads `packages/{namespace}/{name}` joined: the full name is one element. */
  seg: string[];
  /** Under /api/v2, the two parts of the full name a package path names, to be checked. */
  parts?: { namespace: string; name: string };
}

function target(path: string): Target | undefined {
  const api: ApiVersion | undefined = path.startsWith(`${PREFIXES.v1}/`) ? 'v1' : path.startsWith(`${PREFIXES.v2}/`) ? 'v2' : undefined;
  if (!api) return undefined;
  let seg: string[];
  try {
    seg = path.slice(PREFIXES[api].length).split('/').filter(Boolean).map(decodeURIComponent);
  } catch {
    return undefined;
  }
  if (api === 'v1' || seg[0] !== 'packages') return { api, seg };
  // Every package operation of v2 this file serves has five segments; a package path of any other length is not one of them.
  if (seg.length !== 5) return undefined;
  return { api, seg: ['packages', `${seg[1]}/${seg[2]}`, seg[3]!, seg[4]!], parts: { namespace: seg[1]!, name: seg[2]! } };
}

/** The names a path may carry: a flat name under /api/v1 (a full name sent encoded is not one), a namespace and a name of their grammars under /api/v2. */
function checkPathName(t: Target, name: string): void {
  if (t.parts) {
    if (namespaceProblem(t.parts.namespace) === 'invalid') throw invalidNamespace(t.parts.namespace);
    if (!NAME_PATTERN.test(t.parts.name)) throw new RegistryError('invalid_name', `'${t.parts.name}' is not a valid package name.`, { name: t.parts.name });
  } else if (name.includes('/')) {
    throw new RegistryError('invalid_name', `'${name}' is not a valid package name.`, { name });
  }
}

function jsonBody(req: HttpRequest): unknown {
  if (req.body === undefined || req.body === '') throw invalidRequest('the body is not a JSON object');
  try {
    return JSON.parse(req.body);
  } catch {
    throw invalidRequest('the body is not valid JSON');
  }
}

/**
 * The four publish operations: PUT /packages/{name}/{version}/yank, POST /packages/{name}/{version}/files, POST /packages/{name}/{version}/publish
 * and GET /publishes/{publish_id}; and, when the deployment has a GroupService, POST /groups, GET /groups/{group_id} and
 * DELETE /groups/{group_id}, POST /groups/{group_id}/commit and PUT /groups/{group_id}/yank. The same operations are served under
 * /api/v2 with the package in two path segments, `/packages/{namespace}/{name}/{version}/...`, full names in the group members, and
 * errors rendered from the v2 catalogue; `v2` is the wiring of /api/v2 (absent: every v2 path here answers `unavailable`). Under /api/v1,
 * POST /packages/{name}/claim creates nothing any more: it answers the refusal that tells the caller to update mopm, before any other
 * check. Returns undefined for any other request, which the read router then handles.
 *
 * Order of checks: read-only mode first (a read-only registry says so to everyone, signed in or not), then the
 * token, then the scope for this package and version, then the request itself.
 */
export async function routePublish(req: HttpRequest, api: PublishApi, requestId: string, v2?: V2Deps): Promise<HttpResponse | undefined> {
  const t = target(req.path);
  if (!t) return undefined;
  const { seg } = t;
  const ver = t.api;
  const isBegin = req.method === 'POST' && seg.length === 4 && seg[0] === 'packages' && seg[3] === 'files';
  const isCommit = req.method === 'POST' && seg.length === 4 && seg[0] === 'packages' && seg[3] === 'publish';
  const isStatus = req.method === 'GET' && seg.length === 2 && seg[0] === 'publishes';
  const isYank = req.method === 'PUT' && seg.length === 4 && seg[0] === 'packages' && seg[3] === 'yank';
  const isGroupCreate = api.groups !== undefined && req.method === 'POST' && seg.length === 1 && seg[0] === 'groups';
  const isGroupGet = api.groups !== undefined && req.method === 'GET' && seg.length === 2 && seg[0] === 'groups';
  const isGroupAbort = api.groups !== undefined && req.method === 'DELETE' && seg.length === 2 && seg[0] === 'groups';
  const isGroupCommit = api.groups !== undefined && req.method === 'POST' && seg.length === 3 && seg[0] === 'groups' && seg[2] === 'commit';
  const isGroupYank = api.groups !== undefined && req.method === 'PUT' && seg.length === 3 && seg[0] === 'groups' && seg[2] === 'yank';
  const isClaim = ver === 'v1' && req.method === 'POST' && seg.length === 3 && seg[0] === 'packages' && seg[2] === 'claim';
  if (!isBegin && !isCommit && !isStatus && !isYank && !isClaim && !isGroupCreate && !isGroupGet && !isGroupAbort && !isGroupCommit && !isGroupYank) return undefined;

  const refuseIfReadOnly = async () => {
    let readOnly: boolean;
    try {
      readOnly = await api.flags.readOnly();
    } catch (err) {
      // Writers fail closed: if the switch cannot be read, nothing is accepted.
      console.error(JSON.stringify({ level: 'error', requestId, msg: 'read-only switch unreadable', error: String(err) }));
      throw new PublishError('unavailable', 'The registry is temporarily unavailable.');
    }
    if (readOnly) throw new PublishError('read_only_mode', 'The registry is read-only right now; new uploads are refused.');
  };

  try {
    const authorization = req.headers?.authorization;

    // A claim would create a flat package, and names are in namespaces now: it is refused first of all, before read-only mode
    // and the token, so that every released mopm gets the hint to update whatever its token or the registry's mode.
    if (isClaim) throw flatCreationRefused(seg[1]!);

    // Under /api/v2 without the namespace wiring, nothing here can be decided.
    if (ver === 'v2' && !v2) throw new AuthError('unavailable', 'The registry is temporarily unavailable.');
    if (seg[0] === 'packages') checkPathName(t, seg[1]!);

    // Reading and aborting a group stay available when read-only mode is on and when groups are not enabled: they only
    // look at, or end, a group that exists.
    if (isGroupGet || isGroupAbort) {
      const principal = await api.auth.authenticate(authorization);
      requireStageScope(principal);
      const groups = api.groups!;
      return respond(200, requestId, isGroupGet ? await groups.get(principal, seg[1]!) : await groups.abort(principal, seg[1]!));
    }

    // Committing a group is a write (read-only mode refuses it) but not a create: a group that exists is finished whatever the
    // groups switch says. The group's own checks say who may see it.
    if (isGroupCommit) {
      await refuseIfReadOnly();
      const principal = await api.auth.authenticate(authorization);
      requirePublishScope(principal);
      const done = await api.groups!.commit(principal, seg[1]!, jsonBody(req));
      return respond(done.started ? 202 : 200, requestId, ver === 'v2' ? { ...done.body, status_url: done.body.status_url.replace(PREFIXES.v1, PREFIXES.v2) } : done.body);
    }

    // Yanking or unyanking a group is a write (read-only mode refuses it, unlike a single version's yank) and not a create: a group that
    // exists is yanked whatever the groups switch says. The token must be allowed to yank every member.
    if (isGroupYank) {
      await refuseIfReadOnly();
      const principal = await api.auth.authenticate(authorization);
      const done = await api.groups!.setYanked(principal, seg[1]!, jsonBody(req), (members) => {
        for (const m of members.members) authorizeYank(api.auth, principal, m.name, m.version);
      });
      return respond(done.started ? 202 : 200, requestId, done.body);
    }

    if (isGroupCreate) {
      await refuseIfReadOnly();
      const principal = await api.auth.authenticate(authorization);
      let enabled: boolean;
      try {
        enabled = await api.flags.groupsFor(actorOf(principal));
      } catch (err) {
        console.error(JSON.stringify({ level: 'error', requestId, msg: 'groups switch unreadable', error: String(err) }));
        throw new PublishError('unavailable', 'The registry is temporarily unavailable.');
      }
      // Off, the operation does not exist as far as the caller can tell.
      if (!enabled) throw new RegistryError('route_not_found', 'There is no such operation.');
      const groups = api.groups!;
      const parsed = groups.parse(jsonBody(req), ver);
      authorizeGroup(api.auth, principal, parsed);
      const made = await groups.create(principal, parsed);
      return respond(made.created ? 201 : 200, requestId, made.body);
    }

    if (isStatus) {
      const principal = await api.auth.authenticate(authorization);
      requirePublishScope(principal);
      const status = await api.service.status(principal, seg[1]!);
      // A publish is seen by the API its package's name belongs to: a flat name by v1, a full name by v2.
      if ((status.name.includes('/') ? 'v2' : 'v1') !== ver) throw new PublishError('publish_not_found', 'There is no such publish.');
      return respond(200, requestId, status);
    }

    if (isYank) {
      // Not gated by read-only mode: a yank changes no files and is what an owner reaches for in an incident (the fake does the same).
      const principal = await api.auth.authenticate(authorization);
      authorizeYank(api.auth, principal, seg[1]!, seg[2]!);
      return respond(200, requestId, await api.service.setYanked(principal, seg[1]!, seg[2]!, jsonBody(req)));
    }

    await refuseIfReadOnly();

    const name = seg[1]!;
    const version = seg[2]!;
    const principal = await api.auth.authenticate(authorization);
    api.auth.publishToken(principal, name, version);
    const body = jsonBody(req);
    if (isBegin) return respond(200, requestId, await api.service.begin(principal, name, version, body));
    return respond(202, requestId, await api.service.commit(principal, name, version, body));
  } catch (err) {
    return failure(err, requestId, ver);
  }
}

/** `yankToken` or `publishToken` (spec: setYanked): an API token with `yank` or `publish`, or a CI token for exactly this version. */
function authorizeYank(auth: Authenticator, p: Principal, name: string, version: string): void {
  try {
    auth.yankToken(p, name);
  } catch (err) {
    if (!(err instanceof AuthError) || err.code !== 'scope_missing') throw err;
    auth.publishToken(p, name, version);
  }
}

/**
 * A group is created with an API token that has `publish` (or `stage`) for every member's package, or with the token of a configured CI
 * publisher (`ci_owner`) minted for exactly every member's package and version. Any other CI token is valid for one version of one
 * package and creates no group. The first member the token does not cover is named.
 */
function authorizeGroup(auth: Authenticator, p: Principal, req: GroupRequest): void {
  const ci = p.kind === 'oidc' && (p.ci_owner !== undefined || p.acts_via !== undefined || p.ci_namespace !== undefined);
  for (const m of req.members) {
    if (p.kind !== 'api' && !ci) throw new AuthError('scope_missing', `The token does not have the 'publish' scope for '${m.name}'.`, { scope: 'publish', name: m.name });
    auth.stageToken(p, m.name, m.version);
  }
}

/** Reading or aborting a group: a token that may stage or publish (an API or CI token). Committing and yanking never come here. */
function requireStageScope(p: Principal): void {
  if ((p.kind === 'api' || p.kind === 'oidc') && (p.scopes.includes('publish') || p.scopes.includes('stage'))) return;
  throw new AuthError('scope_missing', "The token does not have the 'publish' scope for 'this publish'.", { scope: 'publish', name: 'this publish' });
}

/** Status is readable by the caller who made the publish: a token that can publish (an API or CI token). */
function requirePublishScope(p: Principal): void {
  if ((p.kind === 'api' || p.kind === 'oidc') && p.scopes.includes('publish')) return;
  throw new AuthError('scope_missing', "The token does not have the 'publish' scope for 'this publish'.", { scope: 'publish', name: 'this publish' });
}
