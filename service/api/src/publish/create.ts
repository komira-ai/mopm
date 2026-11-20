import { randomBytes } from 'node:crypto';
import { AuthError, ciActorOf, namespaceProblem, type Authenticator, type Principal } from '../auth';
import { invalidNamespace, type NamespaceAccess } from '../auth/namespace-access';
import { RegistryError } from '../errors';
import { importNameProblem, NAME_PATTERN } from '../names';
import type { Store } from '../store';
import type { PublishConfig } from './config';
import { PublishError } from './errors';
import type { Flags, PublishStore } from './ports';

export interface CreateDeps {
  registry: Store;
  auth: Pick<Authenticator, 'authenticate'>;
  access: Pick<NamespaceAccess, 'require' | 'requireCi'>;
  /** The rate counters (the table the publish limits use). */
  publishes: Pick<PublishStore, 'hit'>;
  config: Pick<PublishConfig, 'claimRatePerAccountPerDay' | 'claimRatePerTokenPerDay'>;
  /** The read-only switch and the per-actor override of the daily limit (the `claim_limits` item). */
  flags: Pick<Flags, 'readOnly' | 'claimLimitFor'>;
  now?: () => Date;
  newId?: () => string;
  /** Where a switch that cannot be read is logged. */
  log?: (line: Record<string, unknown>) => void;
}

const missingScope = (name: string) => new AuthError('scope_missing', `The token does not have the 'publish' scope for '${name}'.`, { scope: 'publish', name });

/**
 * `PUT /api/v2/packages/{namespace}/{name}` (createPackage, docs/design/namespaces.md section 8): create a package in a
 * namespace the caller can write. The package is a row of the packages table named by its full name, `claimed`, with no
 * owner row and no expiry: the namespace is the owner.
 */
export class CreateService {
  private readonly now: () => Date;
  private readonly newId: () => string;
  constructor(private readonly d: CreateDeps) {
    this.now = d.now ?? (() => new Date());
    this.newId = d.newId ?? (() => randomBytes(16).toString('hex'));
  }

  /**
   * Order of checks: read-only mode (a switch that cannot be read refuses too); the token; the grammar of the namespace and
   * of the name; the token naming the package; the right to write the namespace; an existing package (answered whatever
   * the name rules now say); the import name rules; the daily limit; the write. A concurrent create that loses is
   * `{created: false}`, like one that finds the package.
   */
  async create(authorization: string | undefined, namespace: string, name: string): Promise<{ created: boolean }> {
    await this.refuseIfReadOnly();
    const p = await this.d.auth.authenticate(authorization);
    if (namespaceProblem(namespace) === 'invalid') throw invalidNamespace(namespace);
    if (!NAME_PATTERN.test(name)) throw new RegistryError('invalid_name', `'${name}' is not a valid package name.`, { name });
    const full = `${namespace}/${name}`;
    const account = this.requireNamed(p, namespace, full);

    // A CI token's right is the namespace publisher it was minted for (the namespace must exist);
    // an account's is its right in the namespace now.
    if (account === undefined) await this.d.access.requireCi(namespace);
    else await this.d.access.require(namespace, account);

    if (await this.d.registry.getPackage(full)) return { created: false };
    const what = importNameProblem(name);
    if (what !== undefined) throw new RegistryError('name_reserved', `'${name}' is ${what}.`, { name, what });

    const at = this.now();
    const refund = await this.charge(p, namespace, at);
    try {
      await this.d.registry.createPackage({ name: full, state: 'claimed', created_at: at.toISOString() });
    } catch (err) {
      await refund();
      if (err instanceof RegistryError && err.code === 'name_taken') return { created: false };
      throw err;
    }
    await this.d.registry.appendAudit({ name: full, ts: at.toISOString(), id: `a_${this.newId()}`, actor: this.actorOf(p, namespace), action: 'create' });
    return { created: true };
  }

  private async refuseIfReadOnly(): Promise<void> {
    let readOnly: boolean;
    try {
      readOnly = await this.d.flags.readOnly();
    } catch (err) {
      // Writers fail closed: if the switch cannot be read, nothing is accepted.
      this.d.log?.({ level: 'error', msg: 'read-only switch unreadable', error: String(err) });
      throw new PublishError('unavailable', 'The registry is temporarily unavailable.');
    }
    if (readOnly) throw new PublishError('read_only_mode', 'The registry is read-only right now; new uploads are refused.');
  }

  /**
   * The token must name the package: a session always; an API token with `publish` for it; a CI token with `publish` or
   * `stage` minted for this namespace and name. A stage token may create because a group is staged only once its packages
   * exist, and an empty package publishes nothing (an API token stays `publish`-only). Answers the account's id, or
   * undefined for a CI token.
   */
  private requireNamed(p: Principal, namespace: string, full: string): number | undefined {
    const publish = p.scopes.includes('publish');
    if (p.github_id !== undefined && (p.kind === 'session' || (p.kind === 'api' && publish && p.packages.includes(full)))) return p.github_id;
    const ciMay = publish || p.scopes.includes('stage');
    if (p.kind === 'oidc' && ciMay && p.ci_namespace === namespace && p.packages.includes(full)) return undefined;
    throw missingScope(full);
  }

  private actorOf(p: Principal, namespace: string): string {
    if (p.kind !== 'oidc') return `u:${p.github_id}`;
    return p.ci_owner !== undefined ? ciActorOf(p.ci_owner) : `ci:ns:${namespace}`;
  }

  /**
   * One hit on the counter of the token and then on that of the account (a CI token: of its namespace), for the UTC day
   * of `at`; over either limit nothing stays charged and the create is `rate_limited` with Retry-After to midnight.
   * Returns the way to give the charge back.
   */
  private async charge(p: Principal, namespace: string, at: Date): Promise<() => Promise<void>> {
    const who = p.kind === 'oidc' ? { key: `ns:${namespace}`, actor: `ci:ns:${namespace}` } : { key: String(p.github_id), actor: `u:${p.github_id}` };
    const cfg = await this.limitsFor(who.actor);
    const day = at.toISOString().slice(0, 10);
    const midnight = Date.parse(`${day}T00:00:00Z`) + 86_400_000;
    const retryAfter = Math.max(1, Math.ceil((midnight - at.getTime()) / 1000));
    const expiresAt = Math.floor(midnight / 1000) + 86_400;
    const hits: Array<[string, number]> = [
      [`rl#ct#${p.token_id}#${day}`, cfg.claimRatePerTokenPerDay],
      [`rl#cu#${who.key}#${day}`, cfg.claimRatePerAccountPerDay],
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

  /** The limits of this actor: the config's, or the one its `claim_limits` entry sets. A config that cannot be read keeps the config's. */
  private async limitsFor(actor: string): Promise<{ claimRatePerAccountPerDay: number; claimRatePerTokenPerDay: number }> {
    const n = await this.d.flags.claimLimitFor(actor).catch(() => undefined);
    return n === undefined ? this.d.config : { claimRatePerAccountPerDay: n, claimRatePerTokenPerDay: n };
  }
}
