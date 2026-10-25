import { randomBytes } from 'node:crypto';
import { AuthError, NAME_PATTERN, type AuthStore } from '../auth';
import { RegistryError } from '../errors';
import type { Store } from '../store';
import { invalidRequest } from './errors';

/** Names nobody may claim (the contract's `name_reserved`). */
export const RESERVED_NAMES: ReadonlySet<string> = new Set(['mopm', 'mojo', 'max', 'modular', 'std', 'stdlib']);

/** A claim with no published version lapses after this long (spec/api/openapi.yaml, claimPackage). */
export const CLAIM_TTL_MS = 30 * 24 * 3600_000;

/** How many names one read of the search index returns while looking for a similar one. */
const SIMILAR_PAGE = 100;

export interface ClaimDeps {
  registry: Store;
  /** Only the owner's handle is read, from the account the token belongs to. */
  users: Pick<AuthStore, 'getUser'>;
  now?: () => Date;
  newId?: () => string;
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

  async claim(githubId: number, name: string, body: unknown): Promise<ClaimResult> {
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
    // All or nothing: a concurrent claim of the same name loses here with name_taken, and leaves nothing behind.
    await this.d.registry.claimPackage(
      { name, state: 'claimed', created_at: created, claim_expires_at: expires },
      { name, github_id: githubId, handle: user.handle, added_at: created },
      { name, ts: created, id: `a_${this.newId()}`, actor: `u:${githubId}`, action: 'claim' },
    );
    return { name, state: 'claimed', claim_expires_at: expires };
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
