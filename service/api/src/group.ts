import { RegistryError } from './errors';
import { Metrics, type Metric } from './metrics';
import type { RawVersionPort } from './raw-port';
import { byVersion } from './store';
import type { VersionRecord } from './types';

/**
 * Group-aware reads of version rows: the one place that decides what a reader sees of a row that belongs to a group.
 *
 * A version published as part of a group is stored as a `pending` row tagged with `group_id`, and the writer stamps it
 * with `staged_attempt` in the same write that fills it. A small header item of the group, in the `publishes` table
 * under `grp#<group id>`, carries `committed_at`: the one bit a reader needs. The store shows a staged row as
 * `published` only when
 *
 *   - the group's header has `committed_at`,
 *   - the row names that group, and
 *   - the row's `staged_attempt` equals the header's `attempt`.
 *
 * A reader that forgets the rule hides a member; it never shows half a group. Rows without a `group_id` (every row
 * written before groups exist) are returned untouched and cost no read of the header.
 *
 * Only this module and the store adapters may use the raw port (RawVersionPort); test/group-guards.test.ts scans
 * the sources for any other file that does.
 */

// --- what the group's items hold, as far as a reader needs them ----------------------------------------------

/** `publishes` key of a group's header. */
export const headerKey = (gid: string) => `grp#${gid}`;
/** `publishes` key of a group's member list. Written once, never changed. */
export const membersKey = (gid: string) => `grpm#${gid}`;

export interface GroupHeader {
  status: string;
  /** The attempt a staged row must carry to count. -1 when the item holds none, which no row carries. */
  attempt: number;
  /** Set once, never unset: the commit marker. Readers test its presence, not the status name. */
  committed_at?: string;
  /** Member indexes (into the member list) in dependency order. */
  write_order?: number[];
  /** Subdirs whose repodata may list the group's members (the build view). */
  repodata_released?: string[];
  /** Positions in `write_order` whose package index may list the group's member (the build view). */
  index_released?: number[];
}

export interface GroupMember {
  name: string;
  version: string;
  canonical: string;
  subdirs: string[];
}
export interface GroupMembers {
  members: GroupMember[];
}

type Item = Record<string, unknown>;
const strings = (v: unknown): string[] | undefined => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : undefined);
const numbers = (v: unknown): number[] | undefined => (Array.isArray(v) ? v.filter((x): x is number => typeof x === 'number') : undefined);

/** A header item as a GroupHeader. Lenient on purpose: an item that is not understood shows nothing (no `committed_at`, no matching attempt). */
export function parseHeader(item: Item): GroupHeader {
  const committed = typeof item.committed_at === 'string' && item.committed_at !== '' ? { committed_at: item.committed_at } : {};
  const order = numbers(item.write_order);
  const repodata = strings(item.repodata_released);
  const index = numbers(item.index_released);
  return {
    status: typeof item.status === 'string' ? item.status : '',
    attempt: typeof item.attempt === 'number' ? item.attempt : -1,
    ...committed,
    ...(order ? { write_order: order } : {}),
    ...(repodata ? { repodata_released: repodata } : {}),
    ...(index ? { index_released: index } : {}),
  };
}

export function parseMembers(item: Item): GroupMembers {
  const list = Array.isArray(item.members) ? item.members : [];
  const members: GroupMember[] = [];
  for (const m of list as Item[]) {
    if (m && typeof m.name === 'string' && typeof m.canonical === 'string') {
      members.push({ name: m.name, version: typeof m.version === 'string' ? m.version : m.canonical, canonical: m.canonical, subdirs: strings(m.subdirs) ?? [] });
    }
  }
  return { members };
}

/** Reads a group's items. Both reads are consistent. Errors propagate: an unknown answer is never "hidden". */
export interface GroupReader {
  header(gid: string): Promise<GroupHeader | undefined>;
  members(gid: string): Promise<GroupMembers | undefined>;
}

// --- views -----------------------------------------------------------------------------------------------------

/**
 * Who is reading. `api`: the routes, quota, yank, the single paths. `build`: the builders of the channel's files,
 * which also wait for the release gates the group's chain sets on its header, so that a file never runs ahead of
 * what it depends on.
 */
export type View =
  | { kind: 'api' }
  /** The repodata of one subdir, built over every package. */
  | { kind: 'build'; gate: 'repodata'; subdir: string }
  /** One package's sparse-index file. */
  | { kind: 'build'; gate: 'index' }
  /** `index/takedowns.json`: tombstones only, so a group member is never released into it. */
  | { kind: 'build'; gate: 'takedowns' };

export const API_VIEW: View = { kind: 'api' };
export const repodataView = (subdir: string): View => ({ kind: 'build', gate: 'repodata', subdir });
export const INDEX_VIEW: View = { kind: 'build', gate: 'index' };
export const TAKEDOWNS_VIEW: View = { kind: 'build', gate: 'takedowns' };

function released(r: VersionRecord, h: GroupHeader, view: Extract<View, { kind: 'build' }>, members: GroupMembers | undefined): boolean {
  switch (view.gate) {
    case 'repodata':
      return (h.repodata_released ?? []).includes(view.subdir);
    case 'index': {
      const member = members?.members.findIndex((m) => m.name === r.name && m.canonical === r.canonical) ?? -1;
      if (member < 0) return false;
      const position = (h.write_order ?? []).indexOf(member);
      return position >= 0 && (h.index_released ?? []).includes(position);
    }
    case 'takedowns':
      return false;
  }
}

/**
 * What one row shows to a reader, given its group's header (undefined when there is none). Pure.
 *
 * A row that is not `pending` is returned as stored: a flipped row ignores its group. A `pending` row with a group is
 * shown as `published` (at the commit time, `rev` unchanged) only when the header is committed and the row carries
 * its attempt; otherwise it stays `pending`, which every reader hides.
 */
export function project(r: VersionRecord, h: GroupHeader | undefined, view: View = API_VIEW, members?: GroupMembers): VersionRecord {
  if (r.group_id === undefined || r.state !== 'pending') return r;
  if (h === undefined || h.committed_at === undefined || r.staged_attempt !== h.attempt) return r;
  if (view.kind === 'build' && !released(r, h, view, members)) return r;
  return { ...r, state: 'published', published_at: h.committed_at };
}

// --- the funnel --------------------------------------------------------------------------------------------------

/** A group that committed, and a row of it that a build or read cannot account for. Builders fail on this, so the hop retries and dead-letters. */
export class GroupInvariantError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'GroupInvariantError';
  }
}

export interface FunnelOptions {
  metrics?: Metrics;
  log?: (line: Record<string, unknown>) => void;
  /** Member lists kept per container (they never change). */
  membersCacheSize?: number;
  /** Settled group ids kept per container. */
  settledCacheSize?: number;
}

class Stats {
  headerReads = 0;
  headerCacheHits = 0;
  membersReads = 0;
  pass2 = 0;
  pass2b = 0;
  invariants = 0;
  headerless = 0;
  throttles = 0;
  get active() {
    return this.headerReads + this.headerCacheHits + this.membersReads + this.pass2 + this.pass2b + this.invariants + this.headerless + this.throttles > 0;
  }
}

interface GroupState {
  header?: GroupHeader;
  /** The header says `visible`: every member is flipped, so the group is read as stored. */
  settled: boolean;
  /** Committed and not yet settled: the group's members are projected. */
  live: boolean;
  /** The round in which the commit was first observed. A package read before that may predate the group's rows. */
  liveRound: number;
  members?: GroupMembers;
}

/** Packages (and headers) read at once. A search page used to read up to 100 packages at once; this keeps it close, below the SDK's 50 sockets. */
const CONCURRENCY = 25;
const MAX_ROUNDS = 5;
const THROTTLES = new Set(['ProvisionedThroughputExceededException', 'ThrottlingException', 'RequestLimitExceeded', 'ThrottlingError']);
const unavailable = () => new RegistryError('unavailable', 'The registry is temporarily unavailable.');
const defaultLog = (l: Record<string, unknown>) => console.error(JSON.stringify(l));

export class VersionFunnel {
  private readonly metrics: Metrics;
  private readonly log: (line: Record<string, unknown>) => void;
  /** Group ids whose header said `visible`: committed and flipped for good, so never read again by this container. */
  private readonly settled = new Set<string>();
  /** Immutable member lists, least recently used first. */
  private readonly memberLists = new Map<string, GroupMembers>();
  private readonly membersCacheSize: number;
  private readonly settledCacheSize: number;

  constructor(
    private readonly raw: RawVersionPort,
    private readonly groups: GroupReader,
    opts: FunnelOptions = {},
  ) {
    this.metrics = opts.metrics ?? new Metrics();
    this.log = opts.log ?? defaultLog;
    this.membersCacheSize = opts.membersCacheSize ?? 64;
    this.settledCacheSize = opts.settledCacheSize ?? 4096;
  }

  /** One version as the API shows it. A row without a group costs no more than the raw read. */
  async getOne(name: string, version: string): Promise<VersionRecord | undefined> {
    let row = await this.raw.rawGet(name, version);
    // A row that is not pending ignores its group, and one without a group has none: no header is read for either.
    if (!row || row.group_id === undefined || row.state !== 'pending') return row;
    const gid = row.group_id;
    const stats = new Stats();
    try {
      if (this.settled.has(gid)) {
        stats.headerCacheHits++;
        return row;
      }
      const header = await this.guarded('header', stats, () => this.groups.header(gid));
      stats.headerReads++;
      if (header === undefined) {
        this.headerless(stats, gid);
        return row;
      }
      if (header.committed_at === undefined) return row;
      if (header.status === 'visible') {
        this.remember(gid);
        return row;
      }
      if (row.staged_attempt !== header.attempt) {
        // The row was read before it was stamped, or it is not this attempt's: read it again, after the commit was seen.
        stats.pass2b++;
        row = (await this.raw.rawGet(name, version)) ?? row;
        if (row.state !== 'pending') return row;
        if (row.staged_attempt !== header.attempt) {
          this.invariant(stats, gid, `${name} ${row.version} is pending with attempt ${String(row.staged_attempt)} in a group committed at attempt ${header.attempt}`);
          return row;
        }
      }
      return project(row, header, API_VIEW);
    } finally {
      this.report(stats);
    }
  }

  /**
   * The rows of every named package as `view` shows them, each package's oldest to newest by conda ordering. The
   * result has an entry for each name asked for, and for builders of repodata also one for the package of every
   * member of a committed group (a package claimed after the caller listed the names).
   *
   *  1. Read the packages' rows.
   *  2. Read the header of every group any row names (once per call; a group this container knows to be settled
   *     is not read). A group without `committed_at` stays hidden as a whole.
   *  3. For a committed group, read its member list (immutable) and check that every member whose package is
   *     read is there with the group's id; read again (after the commit was seen) any package that is not
   *     there, or whose row is still pending with another attempt than the header's. Builders of repodata also
   *     read the packages of members they had not read.
   *  4. A committed group that still has a missing or unmatched member after that is an invariant violation: an
   *     API read hides the group for this call, a builder throws.
   *
   * The ordering argument: a group's rows are acknowledged, filled and stamped before its commit, and step 3
   * starts after the commit was observed, so it sees every row. A reader that missed every row of a group in
   * step 1 correctly shows none of it. Package existence in a search page is not covered (its index is eventually
   * consistent); this is about version rows of the packages named.
   */
  async versionsOf(names: readonly string[], view: View): Promise<Map<string, VersionRecord[]>> {
    const stats = new Stats();
    try {
      return await this.run(names, view, stats);
    } finally {
      this.report(stats);
    }
  }

  private async run(names: readonly string[], view: View, stats: Stats): Promise<Map<string, VersionRecord[]>> {
    const rows = new Map<string, VersionRecord[]>();
    /** The round after which a package's rows were read: -1 for the first read of the caller's names. */
    const readIn = new Map<string, number>();
    const read = async (packages: readonly string[], round: number) => {
      for (let i = 0; i < packages.length; i += CONCURRENCY) {
        const batch = packages.slice(i, i + CONCURRENCY);
        const got = await Promise.all(batch.map((n) => this.raw.rawQuery(n)));
        batch.forEach((n, j) => {
          rows.set(n, got[j]!);
          readIn.set(n, round);
        });
      }
    };
    await read([...new Set(names)], -1);

    const builder = view.kind === 'build';
    // Only the repodata builders read every package; a package the caller could not list yet must be brought in.
    const widen = view.kind === 'build' && view.gate === 'repodata';
    const groups = new Map<string, GroupState>();

    for (let round = 0; round < MAX_ROUNDS; round++) {
      const unknown = new Set<string>();
      for (const rs of rows.values()) for (const r of rs) if (r.group_id !== undefined && !groups.has(r.group_id)) unknown.add(r.group_id);
      await this.loadHeaders([...unknown], groups, round, stats);

      const again = new Set<string>();
      for (const [gid, g] of groups) {
        if (!g.live) continue;
        g.members ??= await this.membersOf(gid, stats);
        if (g.members === undefined) continue;
        for (const m of g.members.members) {
          const pkg = rows.get(m.name);
          if (pkg === undefined) {
            if (widen) {
              again.add(m.name);
              stats.pass2++;
            }
            continue;
          }
          if (readIn.get(m.name)! >= g.liveRound) continue; // read after the commit was seen: it is as fresh as a read gets
          const row = pkg.find((r) => r.canonical === m.canonical);
          if (row === undefined || row.group_id !== gid) {
            again.add(m.name);
            stats.pass2++;
          } else if (row.state === 'pending' && row.staged_attempt !== g.header!.attempt) {
            again.add(m.name);
            stats.pass2b++;
          }
        }
      }
      // Nothing to read again: no new rows can bring in a group this round has not seen.
      if (again.size === 0) break;
      await read([...again], round);
    }

    const hidden = new Set<string>();
    for (const [gid, g] of groups) {
      if (!g.live) continue;
      const why = this.violation(gid, g, rows);
      if (why === undefined) continue;
      this.invariant(stats, gid, why);
      if (builder) throw new GroupInvariantError(why);
      hidden.add(gid);
    }

    const out = new Map<string, VersionRecord[]>();
    for (const [name, rs] of rows) {
      out.set(
        name,
        rs
          .map((r) => {
            const g = r.group_id === undefined ? undefined : groups.get(r.group_id);
            return g === undefined || !g.live || hidden.has(r.group_id!) ? r : project(r, g.header, view, g.members);
          })
          .sort(byVersion),
      );
    }
    return out;
  }

  /** Why a committed group cannot be shown, or undefined when every member that was read is there and stamped. */
  private violation(gid: string, g: GroupState, rows: Map<string, VersionRecord[]>): string | undefined {
    if (g.members === undefined) return `group ${gid} is committed but its member list is missing`;
    for (const m of g.members.members) {
      const pkg = rows.get(m.name);
      if (pkg === undefined) continue;
      const row = pkg.find((r) => r.canonical === m.canonical);
      if (row === undefined || row.group_id !== gid) return `group ${gid} is committed but ${m.name} ${m.version} is not among its rows`;
      if (row.state === 'pending' && row.staged_attempt !== g.header!.attempt) {
        return `group ${gid} is committed at attempt ${g.header!.attempt} but ${m.name} ${m.version} is pending with attempt ${String(row.staged_attempt)}`;
      }
    }
    return undefined;
  }

  private async loadHeaders(gids: readonly string[], groups: Map<string, GroupState>, round: number, stats: Stats): Promise<void> {
    const toRead: string[] = [];
    for (const gid of gids) {
      if (this.settled.has(gid)) {
        stats.headerCacheHits++;
        groups.set(gid, { settled: true, live: false, liveRound: round });
      } else toRead.push(gid);
    }
    for (let i = 0; i < toRead.length; i += CONCURRENCY) {
      const batch = toRead.slice(i, i + CONCURRENCY);
      const got = await Promise.all(batch.map((gid) => this.guarded('header', stats, () => this.groups.header(gid))));
      stats.headerReads += batch.length;
      batch.forEach((gid, j) => {
        const header = got[j];
        if (header === undefined) {
          this.headerless(stats, gid);
          groups.set(gid, { settled: false, live: false, liveRound: round });
        } else if (header.committed_at === undefined) {
          groups.set(gid, { header, settled: false, live: false, liveRound: round });
        } else if (header.status === 'visible') {
          this.remember(gid);
          groups.set(gid, { header, settled: true, live: false, liveRound: round });
        } else {
          groups.set(gid, { header, settled: false, live: true, liveRound: round });
        }
      });
    }
  }

  private async membersOf(gid: string, stats: Stats): Promise<GroupMembers | undefined> {
    const cached = this.memberLists.get(gid);
    if (cached) {
      this.memberLists.delete(gid);
      this.memberLists.set(gid, cached);
      return cached;
    }
    const got = await this.guarded('member list', stats, () => this.groups.members(gid));
    stats.membersReads++;
    if (got === undefined) return undefined;
    this.memberLists.set(gid, got);
    if (this.memberLists.size > this.membersCacheSize) this.memberLists.delete(this.memberLists.keys().next().value!);
    return got;
  }

  private remember(gid: string): void {
    this.settled.add(gid);
    if (this.settled.size > this.settledCacheSize) this.settled.delete(this.settled.values().next().value!);
  }

  private async guarded<T>(what: string, stats: Stats, fn: () => Promise<T>): Promise<T> {
    try {
      return await fn();
    } catch (err) {
      if (THROTTLES.has((err as { name?: string })?.name ?? '')) stats.throttles++;
      this.log({ level: 'error', msg: `group ${what} unreadable`, error: String(err) });
      throw unavailable();
    }
  }

  private headerless(stats: Stats, gid: string): void {
    stats.headerless++;
    this.log({ level: 'error', msg: 'a version row names a group that has no header; its rows stay hidden', group_id: gid });
  }

  private invariant(stats: Stats, gid: string, why: string): void {
    stats.invariants++;
    this.log({ level: 'error', msg: `group invariant: ${why}`, group_id: gid });
  }

  private report(stats: Stats): void {
    if (!stats.active) return;
    const metrics: Metric[] = [
      { name: 'group_header_reads', value: stats.headerReads },
      { name: 'group_header_cache_hits', value: stats.headerCacheHits },
      { name: 'group_member_list_reads', value: stats.membersReads },
      { name: 'group_pass2', value: stats.pass2 },
      { name: 'group_pass2b', value: stats.pass2b },
      { name: 'group_invariant', value: stats.invariants },
      { name: 'group_header_missing', value: stats.headerless },
      { name: 'header_throttle', value: stats.throttles },
    ];
    this.metrics.emit(metrics);
  }
}
