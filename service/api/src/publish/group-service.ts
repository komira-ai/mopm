import { createHash } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import type { Principal } from '../auth';
import { NAME_PATTERN } from '../auth';
import { AuthError } from '../auth/errors';
import { RegistryError, versionExists } from '../errors';
import { API_VIEW, type GroupMembers } from '../group';
import { bitmapHas, bitmapSet, memberAuditId, type GroupRecord, type GroupStore } from '../group-store';
import { Metrics } from '../metrics';
import type { Store } from '../store';
import type { AuditEntry, VersionRecord } from '../types';
import { canonicalVersion } from '../version';
import type { PublishConfig } from './config';
import { groupConflict, groupNotFound, groupNotOpen, invalidRequest, PublishError } from './errors';
import { ended, expireIfDue, groupAudit, isDead } from './group-lifecycle';
import type { ActorGroup, ObjectStore, Presigner, PublishStore } from './ports';
import { actorOf, liveBytes, parseFileFacts, requireOwner } from './service';
import type { UploadRecord } from './types';

/**
 * The group routes' logic: POST /groups, GET /groups/{id} and DELETE /groups/{id} (spec/api/openapi.yaml: createGroup,
 * getGroup, abortGroup). A group is a set of versions, one per package, declared up front and published together
 * (design: group publish). This change creates, shows and aborts a group; nothing here validates, commits or publishes
 * one, and the routes are off unless the `groups_enabled` item of the config table admits the caller (src/publish/flags.ts).
 *
 * Creation, in order:
 *   1. every member's package must exist and the caller must own it (the first that fails refuses the whole group, by name);
 *   2. the group's id is a hash of the actor and the declared set, so the same request is the same group;
 *   3. an existing group is resumed (open), returned as it is (validating, committed, visible), refused (failed), or
 *      reopened with the next attempt (expired, aborted, rejected, superseded);
 *   4. a new or reopened group takes a place among the actor's open groups, is checked against the rows it will reserve,
 *      charges the group rate counter once for the attempt, supersedes the actor's own open groups that share a member,
 *      and writes its member list and header;
 *   5. only then are the members' rows reserved, sixteen at a time, within a time budget; the header's `reserved`
 *      checkpoint records how far it got, and the same request continues from there.
 * A row therefore never exists without a header.
 */

type GroupRegistry = Store & GroupStore;

export interface GroupServiceDeps {
  registry: GroupRegistry;
  publishes: PublishStore;
  /** Only `head` is used: a file already in quarantine needs no upload URL. */
  objects: Pick<ObjectStore, 'head'>;
  presigner: Presigner;
  config: PublishConfig;
  now?: () => Date;
  /** Milliseconds on a monotonic clock, for the creation budget. */
  clock?: () => number;
  metrics?: Metrics;
}

// --- the request ---------------------------------------------------------------------------------------------------

export interface GroupFileRequest {
  subdir: string;
  filename: string;
  sha256: string;
  size: number;
}
export interface GroupMemberRequest {
  name: string;
  version: string;
  canonical: string;
  /** Sorted by subdir and file name. */
  files: GroupFileRequest[];
}
/** The declared set, members sorted by package name. */
export interface GroupRequest {
  members: GroupMemberRequest[];
}

const MAX_FILES_PER_MEMBER = 20;
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);
const fileKey = (f: Pick<GroupFileRequest, 'subdir' | 'filename'>) => `${f.subdir}/${f.filename}`;

/** The request body as a GroupRequest, or invalid_request (and the errors a single begin raises for a file). */
export function parseGroupRequest(config: PublishConfig, body: unknown): GroupRequest {
  if (!isObject(body)) throw invalidRequest('the body is not a JSON object');
  const { members } = body;
  if (!Array.isArray(members) || members.length < 1) throw invalidRequest("'members' lists at least one member");
  if (members.length > config.groupMaxMembers) throw invalidRequest(`a group has at most ${config.groupMaxMembers} members`);
  const names = new Set<string>();
  const out: GroupMemberRequest[] = [];
  let bytes = 0;
  for (const m of members) {
    if (!isObject(m)) throw invalidRequest('a member is not a JSON object');
    const { name, version, files } = m;
    if (typeof name !== 'string' || typeof version !== 'string') throw invalidRequest("a member needs a 'name' and a 'version', both strings");
    if (!NAME_PATTERN.test(name)) throw new RegistryError('invalid_name', `'${name}' is not a valid package name.`, { name });
    const canonical = canonicalVersion(version); // throws invalid_version
    if (names.has(name)) throw invalidRequest(`'${name}' appears twice: a group has one version of each package`);
    names.add(name);
    if (!Array.isArray(files) || files.length < 1 || files.length > MAX_FILES_PER_MEMBER) {
      throw invalidRequest(`'files' of '${name}' holds 1 to ${MAX_FILES_PER_MEMBER} files`);
    }
    const seen = new Set<string>();
    const facts = files.map((f) => {
      const one = parseFileFacts(config, name, version, f);
      if (seen.has(fileKey(one))) throw invalidRequest(`'${name}' lists the file ${fileKey(one)} twice`);
      seen.add(fileKey(one));
      bytes += one.size;
      return one;
    });
    out.push({ name, version, canonical, files: facts.sort((a, b) => (fileKey(a) < fileKey(b) ? -1 : 1)) });
  }
  if (bytes > config.groupMaxBytes) throw invalidRequest(`the files total ${bytes} bytes; a group holds at most ${config.groupMaxBytes}`);
  return { members: out.sort((a, b) => (a.name < b.name ? -1 : 1)) };
}

/**
 * Deterministic: the same actor declaring the same set gets the same id, whatever the order of the members and files in
 * the request. A different set, or another actor, is another group.
 */
export function groupIdFor(actor: string, req: GroupRequest): string {
  const set = req.members.map((m) => [m.name, m.canonical, m.files.map((f) => [f.subdir, f.filename, f.sha256, f.size])]);
  return `grp_${createHash('sha256').update(JSON.stringify([actor, set])).digest('hex').slice(0, 32)}`;
}
export const GROUP_ID = /^grp_[0-9a-f]{32}$/;

const uploadIdFor = (gid: string, m: GroupMemberRequest, f: GroupFileRequest) =>
  `upl_g${createHash('sha256').update(JSON.stringify([gid, m.name, m.canonical, f.subdir, f.filename, f.sha256])).digest('hex').slice(0, 31)}`;

// --- the answers ---------------------------------------------------------------------------------------------------

export interface GroupFileBody {
  subdir: string;
  filename: string;
  upload_id: string;
  /** The bytes are already in quarantine: nothing to upload. */
  uploaded: boolean;
  put_url?: string;
  put_headers?: Record<string, string>;
  expires_at?: string;
}
export interface GroupMemberBody {
  name: string;
  version: string;
  /** `new`: this call reserved the number. `join`: it was already reserved for this group, or taken over. `skip_identical`: the group has no more to do for it. */
  action: 'new' | 'join' | 'skip_identical';
  files: GroupFileBody[];
}
export interface GroupCreateBody {
  group_id: string;
  status: string;
  attempt: number;
  deadline_at: string;
  /** Present when the call ran out of time: how many members are answered. The same request continues. */
  reserving?: { done: number; total: number };
  members: GroupMemberBody[];
}
export interface GroupStatusBody {
  group_id: string;
  status: string;
  attempt: number;
  created_at: string;
  deadline_at: string;
  committed_at?: string;
  member_count: number;
  members: Array<{ name: string; version: string; state: 'pending' | 'reserved' | 'staged' | 'published' }>;
}

/** The row a member reserves: pending, the declared files (no urls), named by the group. */
function reservedRow(gid: string, m: GroupMemberRequest, handle: string, at: string): VersionRecord {
  return {
    name: m.name,
    version: m.version,
    canonical: m.canonical,
    build: '',
    state: 'pending',
    published_at: at,
    published_by: handle,
    requires_mojo: '',
    deps: [],
    native: [],
    files: m.files.map((f) => ({ subdir: f.subdir, filename: f.filename, sha256: f.sha256, size: f.size })),
    // As a single's reservation: the sha256 of the first declared file is what version_exists reports for this number.
    manifest_sha256: m.files[0]!.sha256,
    group_id: gid,
    rev: 0,
  };
}

/** A member reserved for the group could not be taken. Internal: the create aborts the group and answers group_conflict. */
class Taken extends Error {}

const BATCH = 16;
/** A group on an actor's list that has no header yet is a create still writing it, for this long; after that it is a create that died. */
const IN_FLIGHT_MS = 120_000;
const dayOf = (d: Date) => d.toISOString().slice(0, 10);

/** `at` plus `hours`, as a time. Throws when either is not one: a header is never written with a deadline that is not a time. */
export function deadlineFor(at: Date, hours: number): string {
  const t = at.getTime() + hours * 3_600_000;
  if (!Number.isFinite(t)) throw new RegistryError('internal_error', 'The clock gave no time.');
  return new Date(t).toISOString();
}

export class GroupService {
  private readonly now: () => Date;
  private readonly clock: () => number;
  private readonly metrics: Metrics;
  constructor(private readonly d: GroupServiceDeps) {
    this.now = d.now ?? (() => new Date());
    this.clock = d.clock ?? (() => performance.now());
    this.metrics = d.metrics ?? new Metrics();
  }

  parse(body: unknown): GroupRequest {
    return parseGroupRequest(this.d.config, body);
  }

  // --- create ---------------------------------------------------------------------------------------------

  /** `created` is true when this call made the group or opened it again (the route answers 201), false for a resume or a group that is past that. */
  async create(p: Principal, req: GroupRequest): Promise<{ created: boolean; body: GroupCreateBody }> {
    const reg = this.d.registry;
    const actor = actorOf(p);
    const started = this.clock();
    const handle = await this.requireOwners(p, req);
    const gid = groupIdFor(actor, req);
    const now = this.now();

    let header = await reg.getGroup(gid);
    if (header) header = await expireIfDue(reg, header, now);
    if (header && (header.status === 'validating' || header.status === 'committed' || header.status === 'visible')) {
      return { created: false, body: this.unchanged(header, req) };
    }
    if (header?.status === 'failed') {
      throw groupConflict(`group ${gid} failed after its files were copied, and its version numbers are burned; publish a new version of each package`);
    }

    let created = false;
    let pre: { dead: Set<string>; mine: Set<number> } = { dead: new Set(), mine: new Set() };
    if (header === undefined || isDead(header.status)) {
      // The deadline first: a header is never written with one that is not a time, and nothing is written before it is known to be.
      const deadline = deadlineFor(now, this.d.config.groupDeadlineHours);
      this.rateFits(p, req);
      const slot = await this.takeSlot(actor, gid, req, now);
      try {
        pre = await this.preflight(gid, req, new Set(slot.supersede), now);
        const refund = await this.charge(p, req, now);
        await this.supersede(actor, slot.supersede, now);
        const opened = await this.open(actor, gid, req, header, deadline, now);
        header = opened.header;
        created = opened.created;
        // Another create of the same request wrote the header (or reopened the group) first: that one is the attempt that is charged.
        if (!created) await refund();
      } catch (err) {
        // The place was taken for a group that will not exist: give it back, so it does not count against the cap.
        await this.releaseSlot(actor, gid).catch(() => undefined);
        throw err;
      }
      if (header.status !== 'open') return { created: false, body: this.unchanged(header, req) };
    } else {
      // An open group, asked for again: continue where the checkpoint says.
      pre = await this.preflight(gid, req, new Set(), now);
    }

    const reserved = await this.reserveAll(p, handle, header, req, pre, started);
    const total = req.members.length;
    return {
      created,
      body: {
        group_id: gid,
        status: reserved.header.status,
        attempt: reserved.header.attempt,
        deadline_at: reserved.header.deadline_at,
        ...(reserved.members.length < total ? { reserving: { done: reserved.members.length, total } } : {}),
        members: reserved.members,
      },
    };
  }

  /** The header of a new group, or of a dead one opened again with the next attempt (the member list and the old attempt's other checkpoints are reset). */
  private async open(actor: string, gid: string, req: GroupRequest, dead: GroupRecord | undefined, deadline: string, now: Date): Promise<{ header: GroupRecord; created: boolean }> {
    const reg = this.d.registry;
    const at = now.toISOString();
    if (dead === undefined) {
      const made = await reg.createGroup(
        {
          group_id: gid,
          status: 'open',
          attempt: 1,
          rev: 0,
          actor,
          member_count: req.members.length,
          created_at: at,
          deadline_at: deadline,
          progress_at: at,
          reserved: '',
          validated: '',
          staged: '',
          copied: '',
          flipped: '',
          resend: 0,
          sweep_pk: 'active',
          sweep_at: at,
        },
        membersOf(req),
        groupAudit(gid, `a_${gid}_create_1`, 'group_create', at, actor),
      );
      return { header: made.header, created: made.created };
    }
    const attempt = dead.attempt + 1;
    // Set by the last run of the function: the run that wrote the header, or one that found it already reopened.
    let wrote = false;
    const after = await reg.updateGroup(
      gid,
      (cur) => {
        wrote = isDead(cur.status);
        if (!wrote) return undefined;
        const { cursor: _c, yank: _y, repodata_released: _r, index_released: _i, write_order: _w, expires_at: _e, ...rest } = cur;
        return { ...rest, status: 'open', attempt: cur.attempt + 1, deadline_at: deadline, progress_at: at, reserved: '', validated: '', staged: '', copied: '', flipped: '', resend: 0, sweep_pk: 'active', sweep_at: at };
      },
      groupAudit(gid, `a_${gid}_reopen_${attempt}`, 'group_reopen', at, actor, { attempt: String(attempt) }),
    );
    const header = after ?? dead;
    return { header, created: wrote };
  }

  /** What every member needs once the group is past reserving: nothing. */
  private unchanged(h: GroupRecord, req: GroupRequest): GroupCreateBody {
    return {
      group_id: h.group_id,
      status: h.status,
      attempt: h.attempt,
      deadline_at: h.deadline_at,
      members: req.members.map((m) => ({ name: m.name, version: m.version, action: 'skip_identical', files: [] })),
    };
  }

  /** Every member's package exists and the caller owns it. The first member (in name order) that fails refuses the whole group. Returns the caller's handle. */
  private async requireOwners(p: Principal, req: GroupRequest): Promise<string> {
    // A group is created by an account's token: a CI identity token is valid for one version of one package.
    if (p.github_id === undefined) {
      const name = req.members[0]!.name;
      throw new AuthError('scope_missing', `The token does not have the 'publish' scope for '${name}'.`, { scope: 'publish', name });
    }
    let handle = '';
    for (let i = 0; i < req.members.length; i += BATCH) {
      const batch = req.members.slice(i, i + BATCH);
      const results = await Promise.allSettled(batch.map((m) => requireOwner(this.d.registry, p, m.name)));
      for (const r of results) {
        if (r.status === 'rejected') throw r.reason;
        handle = r.value;
      }
    }
    return handle;
  }

  /**
   * Take a place among the actor's open groups. The actor's list holds the groups it may have open; each is read, a group
   * past its deadline is expired, and only those still `open` count (and a group with no header yet, if it was put on the
   * list a moment ago: a create still writing it). A group of the actor's that shares a member with this one will be
   * superseded, so it does not count against the cap, and at most `groupSupersedeMax` may be. The list is written back
   * with a compare-and-set, so two creates of one actor cannot both take the last place.
   */
  private async takeSlot(actor: string, gid: string, req: GroupRequest, now: Date): Promise<{ supersede: string[] }> {
    const cfg = this.d.config;
    const reg = this.d.registry;
    const wanted = new Set(req.members.map((m) => `${m.name}\0${m.canonical}`));
    for (let attempt = 0; attempt < 5; attempt++) {
      const list = await this.d.publishes.getActorGroups(actor);
      const kept: ActorGroup[] = [];
      const overlapping: string[] = [];
      let open = 0;
      for (const e of list?.groups ?? []) {
        if (e.id === gid) continue;
        const h = await reg.getGroup(e.id);
        if (!h) {
          if (now.getTime() - Date.parse(e.at) < IN_FLIGHT_MS) {
            kept.push(e);
            open++;
          }
          continue;
        }
        const current = await expireIfDue(reg, h, now);
        if (current.status !== 'open') continue;
        kept.push(e);
        open++;
        const ms = await reg.getGroupMembers(e.id);
        if (ms?.members.some((m) => wanted.has(`${m.name}\0${m.canonical}`))) overlapping.push(e.id);
      }
      if (overlapping.length > cfg.groupSupersedeMax) {
        throw groupConflict(`it shares versions with ${overlapping.length} of your open groups, and one create supersedes at most ${cfg.groupSupersedeMax}; abort some first`);
      }
      if (open - overlapping.length >= cfg.groupOpenPerActor) {
        throw groupConflict(`you already have ${open - overlapping.length} open groups, and at most ${cfg.groupOpenPerActor} may be open; abort one first`);
      }
      // The superseded groups stay on the list until they are seen to have ended: a create that stops before superseding them can still find them.
      if (await this.d.publishes.putActorGroups(actor, [...kept, { id: gid, at: now.toISOString() }], list?.rev)) return { supersede: overlapping };
    }
    throw new PublishError('unavailable', 'The registry is temporarily unavailable.');
  }

  /** Take the group back off the actor's list (best effort: an entry left behind with no header is dropped after IN_FLIGHT_MS). */
  private async releaseSlot(actor: string, gid: string): Promise<void> {
    for (let attempt = 0; attempt < 3; attempt++) {
      const list = await this.d.publishes.getActorGroups(actor);
      if (!list || !list.groups.some((e) => e.id === gid)) return;
      if (await this.d.publishes.putActorGroups(actor, list.groups.filter((e) => e.id !== gid), list.rev)) return;
    }
  }

  /**
   * Read the rows the members will reserve, and refuse before anything is written when a number cannot be had or a package
   * is full. Returns which members already have their row for this group and the groups whose rows may be taken over (dead
   * ones, and the ones about to be superseded).
   */
  private async preflight(gid: string, req: GroupRequest, superseding: Set<string>, now: Date): Promise<{ mine: Set<number>; dead: Set<string> }> {
    const reg = this.d.registry;
    const quota = this.d.config.projectQuotaBytes;
    const rows = await reg.versionsOf(
      req.members.map((m) => m.name),
      API_VIEW,
    );
    const mine = new Set<number>();
    const dead = new Set<string>(superseding);
    const headers = new Map<string, GroupRecord | undefined>();
    const headerOf = async (id: string) => {
      if (!headers.has(id)) {
        const h = await reg.getGroup(id);
        headers.set(id, h && (await expireIfDue(reg, h, now)));
      }
      return headers.get(id);
    };
    let pendingMax = 0;
    for (const [idx, m] of req.members.entries()) {
      const pkg = rows.get(m.name) ?? [];
      pendingMax = Math.max(pendingMax, pkg.filter((r) => r.state === 'pending').length);
      const add = m.files.reduce((n, f) => n + f.size, 0);
      const used = liveBytes(pkg);
      if (used + add > quota) {
        const remaining = String(Math.max(0, quota - used));
        throw new PublishError('limit_exceeded', `Adding this file would put '${m.name}' over its storage limit of ${quota} bytes; ${remaining} bytes are left.`, { name: m.name, limit: String(quota), remaining });
      }
      const row = pkg.find((r) => r.canonical === m.canonical);
      if (!row) continue;
      const sha = row.files[0]?.sha256 ?? row.manifest_sha256;
      if (row.state !== 'pending') throw versionExists(m.name, m.version, sha);
      if (row.group_id === gid) {
        mine.add(idx);
      } else if (row.group_id !== undefined) {
        const h = await headerOf(row.group_id);
        if (!h) throw groupConflict(`${m.name} ${m.version} belongs to group ${row.group_id}, which has no header and so cannot be taken over`);
        if (isDead(h.status)) dead.add(row.group_id);
        else if (!dead.has(row.group_id)) throw groupConflict(`${m.name} ${m.version} is held by group ${row.group_id}, which is ${h.status}`);
      } else if ((await this.d.publishes.versionHolder(m.name, m.canonical)) !== undefined) {
        throw versionExists(m.name, m.version, sha);
      }
    }
    this.metrics.emit([{ name: 'group_pending_rows_per_package_max', value: pendingMax }]);
    return { mine, dead };
  }

  /** A group with more files than a day's counter can ever hold is refused outright: a rate limit would not clear. */
  private rateFits(p: Principal, req: GroupRequest): void {
    const cfg = this.d.config;
    const files = req.members.reduce((n, m) => n + m.files.length, 0);
    const limit = Math.min(cfg.groupRatePerTokenPerDay, ...(p.github_id !== undefined ? [cfg.groupRatePerAccountPerDay] : []));
    if (files > limit) throw invalidRequest(`a group of ${files} files is more than the ${limit} files a day that groups may create`);
  }

  /**
   * Charge the group counters for the attempt: one hit of the size of the group's file count, on the counter of the token
   * and then on that of the account. They are not the singles' counters, so a group never uses up the singles' budget.
   * Returns the way to give the charge back: two identical creates at once both charge before either has written the
   * header, and the one that did not write it gives its charge back, so an attempt is charged once.
   */
  private async charge(p: Principal, req: GroupRequest, now: Date): Promise<() => Promise<void>> {
    const cfg = this.d.config;
    const files = req.members.reduce((n, m) => n + m.files.length, 0);
    const day = dayOf(now);
    const midnight = Date.parse(`${day}T00:00:00Z`) + 86_400_000;
    const retryAfter = Math.max(1, Math.ceil((midnight - now.getTime()) / 1000));
    const expiresAt = Math.floor(midnight / 1000) + 86_400;
    const hits: Array<[string, number]> = [[`rl#gt#${p.token_id}#${day}`, cfg.groupRatePerTokenPerDay]];
    if (p.github_id !== undefined) hits.push([`rl#gu#${p.github_id}#${day}`, cfg.groupRatePerAccountPerDay]);
    for (const [key, limit] of hits) {
      if (!(await this.d.publishes.hit(key, limit, expiresAt, files)).ok) {
        throw new PublishError('rate_limited', 'Too many requests.', { retry_after: String(retryAfter) }, retryAfter);
      }
    }
    // A hit of minus `files` always fits under the limit. Best effort: a failure leaves the attempt charged, as it was.
    return async () => {
      for (const [key, limit] of hits) await this.d.publishes.hit(key, limit, expiresAt, -files).catch(() => undefined);
    };
  }

  /** Supersede the actor's own open groups that share a member. A group that began validating meanwhile is never superseded: that refuses the create. */
  private async supersede(actor: string, ids: readonly string[], now: Date): Promise<void> {
    const at = now.toISOString();
    for (const id of ids) {
      const after = await this.d.registry.updateGroup(
        id,
        (cur) => (cur.status === 'open' ? ended(cur, 'superseded', at) : undefined),
        groupAudit(id, `a_${id}_supersede`, 'group_supersede', at, actor),
      );
      if (after && !isDead(after.status)) throw groupConflict(`your group ${id} is ${after.status} and shares a version with this one`);
    }
  }

  /**
   * Reserve the members' rows in batches of sixteen, and answer each member with its files and upload URLs. After every
   * batch the header's `reserved` checkpoint is written; when the budget is spent the members not yet answered are left
   * for the next call. A number taken from under the group in the meantime aborts the group and refuses the call.
   */
  private async reserveAll(p: Principal, handle: string, start: GroupRecord, req: GroupRequest, pre: { dead: Set<string>; mine: Set<number> }, started: number) {
    const reg = this.d.registry;
    const gid = start.group_id;
    let header = start;
    const out: GroupMemberBody[] = [];
    const total = req.members.length;
    let progressed = false;
    while (out.length < total) {
      const from = out.length;
      const indexes = Array.from({ length: Math.min(BATCH, total - from) }, (_, k) => from + k);
      // Wait for the whole batch, whatever happens to a member: a row that is still being written must not be written after the group has been ended.
      const settled = await Promise.allSettled(indexes.map((i) => this.member(p, handle, header, i, req.members[i]!, pre)));
      const failed = settled.find((s): s is PromiseRejectedResult => s.status === 'rejected');
      const results = settled.flatMap((s) => (s.status === 'fulfilled' ? [s.value] : []));
      const marks = results.filter((r) => r.marks).map((r) => r.idx);
      if (marks.length > 0) header = await this.checkpoint(gid, marks, header);
      if (failed) {
        if (!(failed.reason instanceof Taken)) throw failed.reason;
        const at = this.now().toISOString();
        await reg.updateGroup(gid, (cur) => (cur.status === 'open' ? ended(cur, 'aborted', at) : undefined), groupAudit(gid, `a_${gid}_abort_${header.attempt}`, 'group_abort', at, actorOf(p), { reason: 'a version number was taken' }));
        throw groupConflict(failed.reason.message);
      }
      for (const r of results) out.push(r.body);
      if (marks.length > 0) progressed = true;
      // The call stops when its time is spent, but never before it has moved the checkpoint: a group whose first members
      // took the whole budget to check would otherwise never get past them.
      if (out.length < total && progressed && this.clock() - started >= this.d.config.groupCreateBudgetMs) break;
    }
    return { header, members: out };
  }

  /** Record in the header's `reserved` bitmap that these members' rows are the group's. Merges with what is there; an ended group is left as it is. */
  private async checkpoint(gid: string, marks: readonly number[], header: GroupRecord): Promise<GroupRecord> {
    const at = this.now().toISOString();
    const after = await this.d.registry.updateGroup(gid, (cur) => {
      if (cur.status !== 'open') return undefined;
      let reserved = cur.reserved;
      for (const i of marks) reserved = bitmapSet(reserved, i);
      return reserved === cur.reserved ? undefined : { ...cur, reserved, progress_at: at };
    });
    return after ?? header;
  }

  private async member(p: Principal, handle: string, header: GroupRecord, idx: number, m: GroupMemberRequest, pre: { dead: Set<string>; mine: Set<number> }) {
    const gid = header.group_id;
    const has = bitmapHas(header.reserved, idx);
    let action: 'new' | 'join' = 'join';
    if (!has && !pre.mine.has(idx)) {
      const at = this.now().toISOString();
      const audit: AuditEntry = {
        name: m.name,
        ts: at,
        id: `${memberAuditId(gid, idx)}_${header.attempt}`,
        actor: actorOf(p),
        action: 'group_reserve',
        version: m.version,
        detail: { group_id: gid },
      };
      // Free for the group: the row of a single's reservation that nobody committed, or of a group that is over.
      const out = await this.d.registry.adoptVersion(reservedRow(gid, m, handle, at), audit, (cur) => cur.group_id === undefined || pre.dead.has(cur.group_id));
      if (out.outcome === 'created') action = 'new';
      else if (out.outcome === 'taken' && out.existing.group_id === gid && out.existing.state === 'pending') action = 'join';
      else if (out.outcome !== 'adopted') throw new Taken(`${m.name} ${m.version} was taken by another publish while the group was being created`);
    }
    return { idx, marks: !has, body: { name: m.name, version: m.version, action, files: await this.files(p, gid, m) } };
  }

  /** The upload of each file: a record that is the same on every call (so a resume finds it), and a fresh URL unless the bytes are already in quarantine. */
  private async files(p: Principal, gid: string, m: GroupMemberRequest): Promise<GroupFileBody[]> {
    const cfg = this.d.config;
    const now = this.now();
    return Promise.all(
      m.files.map(async (f) => {
        const uploadId = uploadIdFor(gid, m, f);
        const key = `quarantine/${uploadId}/${f.filename}`;
        if (!(await this.d.publishes.getUpload(uploadId))) {
          const rec: UploadRecord = {
            upload_id: uploadId,
            name: m.name,
            version: m.version,
            canonical: m.canonical,
            subdir: f.subdir,
            filename: f.filename,
            sha256: f.sha256,
            size: f.size,
            key,
            actor: actorOf(p),
            created_at: now.toISOString(),
            url_expires_at: new Date(now.getTime() + cfg.uploadUrlTtlSeconds * 1000).toISOString(),
            expires_at: Math.floor(now.getTime() / 1000) + cfg.uploadRecordTtlSeconds,
          };
          try {
            await this.d.publishes.putUpload(rec);
          } catch (err) {
            // Written by an identical request that was running at the same time: the same record.
            if (!(await this.d.publishes.getUpload(uploadId))) throw err;
          }
        }
        const stat = await this.d.objects.head(key);
        const base = { subdir: f.subdir, filename: f.filename, upload_id: uploadId };
        if (stat && stat.size === f.size) return { ...base, uploaded: true };
        const signed = this.d.presigner.presignPut(key, { size: f.size, sha256: f.sha256, expiresInSeconds: cfg.uploadUrlTtlSeconds, now });
        return { ...base, uploaded: false, put_url: signed.url, put_headers: signed.headers, expires_at: new Date(now.getTime() + cfg.uploadUrlTtlSeconds * 1000).toISOString() };
      }),
    );
  }

  // --- read and abort -------------------------------------------------------------------------------------

  async get(p: Principal, id: string): Promise<GroupStatusBody> {
    const { header, members } = await this.load(p, id);
    return statusBody(header, members);
  }

  /** Abort an open group (idempotent for one that is aborted). Its rows stay pending and free for any group or single to take. */
  async abort(p: Principal, id: string): Promise<GroupStatusBody> {
    const loaded = await this.load(p, id);
    const reg = this.d.registry;
    if (loaded.header.status === 'aborted') return statusBody(loaded.header, loaded.members);
    if (loaded.header.status !== 'open') throw groupNotOpen(id, loaded.header.status);
    const at = this.now().toISOString();
    const after = await reg.updateGroup(
      id,
      (cur) => (cur.status === 'open' ? ended(cur, 'aborted', at) : undefined),
      groupAudit(id, `a_${id}_abort_${loaded.header.attempt}`, 'group_abort', at, actorOf(p)),
    );
    if (!after || after.status !== 'aborted') throw groupNotOpen(id, after?.status ?? 'missing');
    return statusBody(after, loaded.members);
  }

  /** The group as the caller may see it: its creator, or an owner of every package in it. Anyone else gets group_not_found. */
  private async load(p: Principal, id: string): Promise<{ header: GroupRecord; members: GroupMembers }> {
    const reg = this.d.registry;
    if (!GROUP_ID.test(id)) throw groupNotFound();
    let header = await reg.getGroup(id);
    if (!header) throw groupNotFound();
    header = await expireIfDue(reg, header, this.now());
    const members = (await reg.getGroupMembers(id)) ?? { members: [] };
    if (header.actor !== actorOf(p) && !(await this.ownsAll(p, members))) throw groupNotFound();
    return { header, members };
  }

  private async ownsAll(p: Principal, members: GroupMembers): Promise<boolean> {
    if (p.github_id === undefined || members.members.length === 0) return false;
    for (let i = 0; i < members.members.length; i += BATCH) {
      const batch = members.members.slice(i, i + BATCH);
      const owned = await Promise.all(batch.map(async (m) => (await this.d.registry.listOwners(m.name)).some((o) => o.github_id === p.github_id)));
      if (owned.includes(false)) return false;
    }
    return true;
  }
}

function membersOf(req: GroupRequest): GroupMembers {
  return { members: req.members.map((m) => ({ name: m.name, version: m.version, canonical: m.canonical, subdirs: [...new Set(m.files.map((f) => f.subdir))].sort() })) };
}

function statusBody(h: GroupRecord, members: GroupMembers): GroupStatusBody {
  const state = (i: number) =>
    h.status === 'visible' || bitmapHas(h.flipped, i) ? 'published' : bitmapHas(h.staged, i) ? 'staged' : bitmapHas(h.reserved, i) ? 'reserved' : 'pending';
  return {
    group_id: h.group_id,
    status: h.status,
    attempt: h.attempt,
    created_at: h.created_at,
    deadline_at: h.deadline_at,
    ...(h.committed_at !== undefined ? { committed_at: h.committed_at } : {}),
    member_count: h.member_count,
    members: members.members.map((m, i) => ({ name: m.name, version: m.version, state: state(i) })),
  };
}
