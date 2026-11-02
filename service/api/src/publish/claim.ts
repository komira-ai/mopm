import { randomBytes } from 'node:crypto';
import { AuthError, NAME_PATTERN, type AuthStore } from '../auth';
import { RegistryError } from '../errors';
import type { Store } from '../store';
import type { PackageRecord } from '../types';
import type { PublishConfig } from './config';
import { invalidRequest, PublishError } from './errors';
import type { Flags, PublishStore } from './ports';

/** Names nobody may claim (the contract's `name_reserved`). */
export const RESERVED_NAMES: ReadonlySet<string> = new Set(['mopm', 'mojo', 'max', 'modular', 'std', 'stdlib']);

/** A claim with no published version lapses after this long (spec/api/openapi.yaml, claimPackage). */
export const CLAIM_TTL_MS = 30 * 24 * 3600_000;

/**
 * Whether a claim has lapsed at `at`: only a package still `claimed` with a recorded expiry can. An `active` package (it has a
 * published version) never lapses, and neither does one with no expiry (a package a CI publisher created). Nothing frees a lapsed
 * name yet; whatever does must ask this.
 */
export const claimLapsed = (p: Pick<PackageRecord, 'state' | 'claim_expires_at'>, at: Date): boolean =>
  p.state === 'claimed' && p.claim_expires_at !== undefined && Date.parse(p.claim_expires_at) <= at.getTime();

/** How many names one read of the search index returns while looking for a similar one. */
const SIMILAR_PAGE = 100;

export interface ClaimDeps {
  registry: Store;
  /** Only the owner's handle is read, from the account the token belongs to. */
  users: Pick<AuthStore, 'getUser'>;
  /** The rate counters (the table the publish limits use). */
  publishes: Pick<PublishStore, 'hit'>;
  config: Pick<PublishConfig, 'claimRatePerAccountPerDay' | 'claimRatePerTokenPerDay'>;
  /** The per-account override of the daily limit (the `claim_limits` item of the config table). Absent: every account has the config's limits. */
  flags?: Pick<Flags, 'claimLimitFor'>;
  now?: () => Date;
  newId?: () => string;
}

/** Who claims: the account the token belongs to, and the token itself (each has its own daily counter). */
export interface Claimant {
  githubId: number;
  tokenId: string;
}

export interface ClaimResult {
  name: string;
  state: 'claimed';
  claim_expires_at: string;
}

/** To the second, as the contract's examples write a timestamp (`2026-11-12T12:00:00Z`). */
const rfc3339 = (d: Date) => `${d.toISOString().slice(0, 19)}Z`;

const squash = (name: string) => name.replace(/_/g, '');

/** Equal once underscores are dropped, or the same but for one trailing `s`. */
export function tooSimilar(a: string, b: string): boolean {
  const x = squash(a);
  const y = squash(b);
  return x === y || x === `${y}s` || y === `${x}s`;
}

/** The request body of a claim: absent, or an object whose only member of meaning is the boolean `confirm_similar`. */
function parseClaim(body: unknown): { confirmSimilar: boolean } {
  if (body === undefined) return { confirmSimilar: false };
  if (typeof body !== 'object' || body === null || Array.isArray(body)) throw invalidRequest('the body is not a JSON object');
  const c = (body as Record<string, unknown>).confirm_similar;
  if (c !== undefined && typeof c !== 'boolean') throw invalidRequest("'confirm_similar' must be a boolean");
  return { confirmSimilar: c === true };
}

/**
 * `POST /packages/{name}/claim` (spec/api/openapi.yaml, claimPackage): reserve a free name for the account. Who may call it
 * (a user token) is decided by the route; everything the registry decides happens here, on ports.
 */
export class ClaimService {
  private readonly now: () => Date;
  private readonly newId: () => string;
  constructor(private readonly d: ClaimDeps) {
    this.now = d.now ?? (() => new Date());
    this.newId = d.newId ?? (() => randomBytes(16).toString('hex'));
  }

  async claim(who: Claimant, name: string, body: unknown): Promise<ClaimResult> {
    const { githubId } = who;
    if (!NAME_PATTERN.test(name)) throw new RegistryError('invalid_name', `'${name}' is not a valid package name.`, { name });
    const { confirmSimilar } = parseClaim(body);
    if (RESERVED_NAMES.has(name)) throw new RegistryError('name_reserved', `'${name}' is reserved.`, { name });
    const taken = new RegistryError('name_taken', `'${name}' is already taken.`, { name });
    if (await this.d.registry.getPackage(name)) throw taken;
    const user = await this.d.users.getUser(githubId);
    // A live token whose account has no row: nothing to name as the owner.
    if (!user) throw new AuthError('token_unknown', 'The token is not recognised.');
    if (!confirmSimilar) {
      const other = await this.similarTo(name);
      if (other !== undefined) throw new RegistryError('name_too_similar', `'${name}' is too similar to '${other}'.`, { name, other });
    }
    const at = this.now();
    const created = rfc3339(at);
    const expires = rfc3339(new Date(at.getTime() + CLAIM_TTL_MS));
    // Only a claim that is about to be written is charged (a refused name costs reads only and no quota), and a write that
    // then fails gives its charge back, so the counters count the names reserved.
    const refund = await this.charge(who, at);
    try {
      // All or nothing: a concurrent claim of the same name loses here with name_taken, and leaves nothing behind.
      await this.d.registry.claimPackage(
        { name, state: 'claimed', created_at: created, claim_expires_at: expires },
        { name, github_id: githubId, handle: user.handle, added_at: created },
        { name, ts: created, id: `a_${this.newId()}`, actor: `u:${githubId}`, action: 'claim' },
      );
    } catch (err) {
      await refund();
      throw err;
    }
    return { name, state: 'claimed', claim_expires_at: expires };
  }

  /**
   * One hit on the counter of the token and then on that of the account, for the UTC day of `now`; over either limit nothing
   * stays charged and the claim is `rate_limited` with Retry-After to midnight. Returns the way to give the charge back.
   */
  private async charge(who: Claimant, now: Date): Promise<() => Promise<void>> {
    const cfg = await this.limitsFor(who);
    const day = now.toISOString().slice(0, 10);
    const midnight = Date.parse(`${day}T00:00:00Z`) + 86_400_000;
    const retryAfter = Math.max(1, Math.ceil((midnight - now.getTime()) / 1000));
    const expiresAt = Math.floor(midnight / 1000) + 86_400;
    const hits: Array<[string, number]> = [
      [`rl#ct#${who.tokenId}#${day}`, cfg.claimRatePerTokenPerDay],
      [`rl#cu#${who.githubId}#${day}`, cfg.claimRatePerAccountPerDay],
    ];
    const charged: Array<[string, number]> = [];
    const giveBack = async () => {
      for (const [key, limit] of charged) await this.d.publishes.hit(key, limit, expiresAt, -1).catch(() => undefined);
    };
    for (const [key, limit] of hits) {
      if (!(await this.d.publishes.hit(key, limit, expiresAt)).ok) {
        await giveBack();
        throw new PublishError('rate_limited', 'Too many requests.', { retry_after: String(retryAfter) }, retryAfter);
      }
      charged.push([key, limit]);
    }
    return giveBack;
  }

  /**
   * The daily limits of this account: the config's, or the one the account's `claim_limits` entry sets (for the account and each of
   * its tokens). A config that cannot be read keeps the config's limits: the default is the stricter side.
   */
  private async limitsFor(who: Claimant): Promise<{ claimRatePerAccountPerDay: number; claimRatePerTokenPerDay: number }> {
    const cfg = this.d.config;
    const n = await this.d.flags?.claimLimitFor(`u:${who.githubId}`).catch(() => undefined);
    return n === undefined ? cfg : { claimRatePerAccountPerDay: n, claimRatePerTokenPerDay: n };
  }

  /**
   * An existing name this one is too similar to. A similar name keeps the first letter (only underscores and a trailing `s`
   * differ), so the search index is read for that letter only. The index is eventually consistent: a name claimed a moment ago
   * may not be seen yet.
   */
  private async similarTo(name: string): Promise<string | undefined> {
    for (let after: string | undefined; ; ) {
      const page = await this.d.registry.searchPackages(name.slice(0, 1), after, SIMILAR_PAGE);
      const hit = page.find((p) => tooSimilar(name, p.name));
      if (hit) return hit.name;
      if (page.length < SIMILAR_PAGE) return undefined;
      after = page[page.length - 1]!.name;
    }
  }
}
