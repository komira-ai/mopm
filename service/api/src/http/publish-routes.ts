import { AuthError } from '../auth/errors';
import type { Authenticator, Principal } from '../auth';
import { errorView } from '../publish/catalogue';
import type { ClaimService } from '../publish/claim';
import { PublishError, invalidRequest } from '../publish/errors';
import type { Flags } from '../publish/ports';
import type { GroupRequest, GroupService } from '../publish/group-service';
import { actorOf, type PublishService } from '../publish/service';
import { RegistryError } from '../errors';
import type { HttpRequest, HttpResponse } from './router';

/** What the publish operations need: who is calling, what they may do, and whether uploads are allowed at all. */
export interface PublishApi {
  auth: Authenticator;
  service: PublishService;
  flags: Flags;
  /** The group routes. Absent: they are not routes of this deployment, and the router answers route_not_found. */
  groups?: GroupService;
  /** The claim route. Absent: it is not a route of this deployment, and the router answers route_not_found. */
  claims?: ClaimService;
}

const PREFIX = '/api/v1';

function respond(statusCode: number, requestId: string, body: unknown, extra: Record<string, string> = {}): HttpResponse {
  return {
    statusCode,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-mopm-request-id': requestId, ...extra },
    body: JSON.stringify(body),
  };
}

function failure(err: unknown, requestId: string): HttpResponse {
  const v = errorView(err);
  if (v.body.error.code === 'internal_error') {
    console.error(JSON.stringify({ level: 'error', requestId, error: String((err as Error)?.stack ?? err) }));
  }
  return respond(v.status, requestId, v.body, v.retryAfter !== undefined ? { 'retry-after': String(v.retryAfter) } : {});
}

function segments(path: string): string[] | undefined {
  if (!path.startsWith(`${PREFIX}/`)) return undefined;
  try {
    return path.slice(PREFIX.length).split('/').filter(Boolean).map(decodeURIComponent);
  } catch {
    return undefined;
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

/** The body of a claim is optional: none is `undefined`, anything else must be JSON (the service says what shape it needs). */
function optionalJsonBody(req: HttpRequest): unknown {
  if (req.body === undefined || req.body === '') return undefined;
  try {
    return JSON.parse(req.body);
  } catch {
    throw invalidRequest('the body is not valid JSON');
  }
}

/**
 * The four publish operations: PUT /packages/{name}/{version}/yank, POST /packages/{name}/{version}/files, POST /packages/{name}/{version}/publish
 * and GET /publishes/{publish_id}; and, when the deployment has a GroupService, POST /groups, GET /groups/{group_id} and
 * DELETE /groups/{group_id}, POST /groups/{group_id}/commit and PUT /groups/{group_id}/yank; and, when it has a ClaimService,
 * POST /packages/{name}/claim (a user token, not a publish token: the package does not exist yet). Returns undefined for any other request, which the read router then handles.
 *
 * Order of checks: read-only mode first (a read-only registry says so to everyone, signed in or not), then the
 * token, then the scope for this package and version, then the request itself.
 */
export async function routePublish(req: HttpRequest, api: PublishApi, requestId: string): Promise<HttpResponse | undefined> {
  const seg = segments(req.path);
  if (!seg) return undefined;
  const isBegin = req.method === 'POST' && seg.length === 4 && seg[0] === 'packages' && seg[3] === 'files';
  const isCommit = req.method === 'POST' && seg.length === 4 && seg[0] === 'packages' && seg[3] === 'publish';
  const isStatus = req.method === 'GET' && seg.length === 2 && seg[0] === 'publishes';
  const isYank = req.method === 'PUT' && seg.length === 4 && seg[0] === 'packages' && seg[3] === 'yank';
  const isGroupCreate = api.groups !== undefined && req.method === 'POST' && seg.length === 1 && seg[0] === 'groups';
  const isGroupGet = api.groups !== undefined && req.method === 'GET' && seg.length === 2 && seg[0] === 'groups';
  const isGroupAbort = api.groups !== undefined && req.method === 'DELETE' && seg.length === 2 && seg[0] === 'groups';
  const isGroupCommit = api.groups !== undefined && req.method === 'POST' && seg.length === 3 && seg[0] === 'groups' && seg[2] === 'commit';
  const isGroupYank = api.groups !== undefined && req.method === 'PUT' && seg.length === 3 && seg[0] === 'groups' && seg[2] === 'yank';
  const isClaim = api.claims !== undefined && req.method === 'POST' && seg.length === 3 && seg[0] === 'packages' && seg[2] === 'claim';
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

    // A claim creates a package: read-only mode refuses it, then the token (any live token of a user: a CI token is nobody's),
    // then the request. Not gated by the groups switch.
    if (isClaim) {
      await refuseIfReadOnly();
      const githubId = api.auth.userToken(await api.auth.authenticate(authorization));
      return respond(201, requestId, await api.claims!.claim(githubId, seg[1]!, optionalJsonBody(req)));
    }

    // Reading and aborting a group stay available when read-only mode is on and when groups are not enabled: they only
    // look at, or end, a group that exists.
    if (isGroupGet || isGroupAbort) {
      const principal = await api.auth.authenticate(authorization);
      requirePublishScope(principal);
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
      return respond(done.started ? 202 : 200, requestId, done.body);
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
      const parsed = groups.parse(jsonBody(req));
      authorizeGroup(api.auth, principal, parsed);
      const made = await groups.create(principal, parsed);
      return respond(made.created ? 201 : 200, requestId, made.body);
    }

    if (isStatus) {
      const principal = await api.auth.authenticate(authorization);
      requirePublishScope(principal);
      return respond(200, requestId, await api.service.status(principal, seg[1]!));
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
    return failure(err, requestId);
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

/** A group is created with an API token that has `publish` for every member's package (a CI identity token is valid for one version of one package). The first member it does not cover is named. */
function authorizeGroup(auth: Authenticator, p: Principal, req: GroupRequest): void {
  for (const m of req.members) {
    if (p.kind !== 'api') throw new AuthError('scope_missing', `The token does not have the 'publish' scope for '${m.name}'.`, { scope: 'publish', name: m.name });
    auth.publishToken(p, m.name, m.version);
  }
}

/** Status is readable by the caller who made the publish: a token that can publish (an API or CI token). */
function requirePublishScope(p: Principal): void {
  if ((p.kind === 'api' || p.kind === 'oidc') && p.scopes.includes('publish')) return;
  throw new AuthError('scope_missing', "The token does not have the 'publish' scope for 'this publish'.", { scope: 'publish', name: 'this publish' });
}
