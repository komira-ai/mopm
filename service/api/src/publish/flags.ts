import { GetCommand } from '@aws-sdk/lib-dynamodb';
import type { DocClient } from '../dynamo-store';
import type { Flags } from './ports';

/**
 * Who may create a group (the `groups_enabled` item of the config table). Group creation is off unless this says
 * otherwise.
 *
 *   off    nobody (the default, and what an absent, unreadable-as-a-value or unknown item means)
 *   allow  the actors listed in `actors`
 *   all    everybody
 *
 * `deny` lists actors that are refused in any mode: the kill switch for one actor.
 */
export type GroupsPolicy = { mode: 'off' } | { mode: 'allow'; actors: string[]; deny: string[] } | { mode: 'all'; deny: string[] };

export const GROUPS_OFF: GroupsPolicy = { mode: 'off' };

const strings = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : []);

/** The policy an item of the config table says. Anything that is not understood is `off`: creation fails closed. */
export function parseGroupsPolicy(item: Record<string, unknown> | undefined): GroupsPolicy {
  if (!item) return GROUPS_OFF;
  if (item.mode === 'allow') return { mode: 'allow', actors: strings(item.actors), deny: strings(item.deny) };
  if (item.mode === 'all') return { mode: 'all', deny: strings(item.deny) };
  return GROUPS_OFF;
}

/** The environment variable that carries the static groups policy of a deployment. The loader refuses it on any stage but beta. */
export const GROUPS_POLICY_ENV = 'MOPM_GROUPS_POLICY';
/** The one stage that may carry a static groups policy. */
export const GROUPS_POLICY_STAGE = 'beta';
/** The most actors a static policy may name. */
export const MAX_STATIC_GROUP_ACTORS = 8;
const CI_ACTOR = /^ci:gh-repo:[1-9][0-9]{0,19}$/;

/**
 * The static groups policy named by `MOPM_GROUPS_POLICY`: config as code, for the beta stage only. Absent or empty: `off`. Present on
 * any stage but beta: an error, so the function does not start (a mistake in infrastructure cannot turn groups on at gamma or prod).
 * The only form is `{"mode":"allow","actors":["ci:gh-repo:<repository id>", ...]}`: one to eight CI identities, never `all`, never
 * an account, no other key. Anything else is an error naming what is wrong, never a partial policy.
 *
 * It is ORed with the `groups_enabled` item of the config table (AnyFlag), and an item's `deny` does not override it: stopping a
 * static policy takes a deploy.
 */
export function parseStaticGroupsPolicy(stage: string, raw: string | undefined): GroupsPolicy {
  if (raw === undefined || raw === '') return GROUPS_OFF;
  if (stage !== GROUPS_POLICY_STAGE) throw new Error(`${GROUPS_POLICY_ENV} may be set on the ${GROUPS_POLICY_STAGE} stage only; this is ${stage}`);
  const bad = (detail: string) => new Error(`${GROUPS_POLICY_ENV} is not valid: ${detail}`);
  let v: unknown;
  try {
    v = JSON.parse(raw);
  } catch {
    throw bad('not JSON');
  }
  if (typeof v !== 'object' || v === null || Array.isArray(v)) throw bad('not an object');
  const o = v as Record<string, unknown>;
  for (const k of Object.keys(o)) if (k !== 'mode' && k !== 'actors') throw bad(`unknown key '${k}'`);
  if (o.mode !== 'allow') throw bad("'mode' must be 'allow'");
  const actors = o.actors;
  if (!Array.isArray(actors) || actors.length < 1 || actors.length > MAX_STATIC_GROUP_ACTORS) throw bad(`'actors' is a list of 1 to ${MAX_STATIC_GROUP_ACTORS} CI actors`);
  if (!actors.every((a) => typeof a === 'string' && CI_ACTOR.test(a))) throw bad("every actor is 'ci:gh-repo:<repository id>'");
  if (new Set(actors).size !== actors.length) throw bad('an actor is named twice');
  return { mode: 'allow', actors: [...(actors as string[])], deny: [] };
}

export function policyAllows(policy: GroupsPolicy, actor: string): boolean {
  if (policy.mode === 'off') return false;
  if (policy.deny.includes(actor)) return false;
  return policy.mode === 'all' || policy.actors.includes(actor);
}

/** A flag fixed at construction (tests, and the MOPM_READ_ONLY environment switch). Groups are off unless a policy is given. */
export class StaticFlags implements Flags {
  constructor(
    private readonly ro: boolean,
    private readonly groups: GroupsPolicy = GROUPS_OFF,
  ) {}
  async readOnly() {
    return this.ro;
  }
  async groupsFor(actor: string) {
    return policyAllows(this.groups, actor);
  }
}

/**
 * The runtime switches, items of the stage's `config` table, set and cleared by an operator with a single put-item
 * (service/docs/runbook.md): `{key: 'read_only', value: true}` and `{key: 'groups_enabled', mode: 'allow', actors: ['u:1']}`.
 * Each result is cached for a few seconds so a request does not cost a DynamoDB call. A failed read throws: writers fail closed.
 */
export class DynamoFlags implements Flags {
  private cached?: { at: number; value: boolean };
  private cachedGroups?: { at: number; value: GroupsPolicy };
  constructor(
    private readonly doc: DocClient,
    private readonly table: string,
    private readonly cacheMs = 5000,
    private readonly now: () => number = Date.now,
  ) {}
  async readOnly(): Promise<boolean> {
    const t = this.now();
    if (this.cached && t - this.cached.at < this.cacheMs) return this.cached.value;
    const r = await this.doc.send(new GetCommand({ TableName: this.table, Key: { key: 'read_only' }, ConsistentRead: true }));
    const value = r.Item?.value === true;
    this.cached = { at: t, value };
    return value;
  }
  async groupsFor(actor: string): Promise<boolean> {
    const t = this.now();
    if (this.cachedGroups && t - this.cachedGroups.at < this.cacheMs) return policyAllows(this.cachedGroups.value, actor);
    const r = await this.doc.send(new GetCommand({ TableName: this.table, Key: { key: 'groups_enabled' }, ConsistentRead: true }));
    const value = parseGroupsPolicy(r.Item as Record<string, unknown> | undefined);
    this.cachedGroups = { at: t, value };
    return policyAllows(value, actor);
  }
}

/** Either switch makes the registry read-only. For groups, any one of them admitting the actor is enough (a static policy that says nothing is `off`). */
export class AnyFlag implements Flags {
  constructor(private readonly flags: Flags[]) {}
  async readOnly() {
    for (const f of this.flags) if (await f.readOnly()) return true;
    return false;
  }
  async groupsFor(actor: string) {
    for (const f of this.flags) if (await f.groupsFor(actor)) return true;
    return false;
  }
}
