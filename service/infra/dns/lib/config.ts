// Zone names per stage. Nothing here is a secret or an account id.

export const STAGES = ['beta', 'gamma', 'prod'] as const;
export type Stage = (typeof STAGES)[number];

/** Route 53 is global but the stacks are created in one region; the same one the service stacks use. */
export const REGION = 'us-east-1';

export const ROOT_ZONE = 'mopm.dev';

/** The stages whose zones are delegated from the prod zone. */
export const CHILD_STAGES = ['beta', 'gamma'] as const;
export type ChildStage = (typeof CHILD_STAGES)[number];

export function assertStage(s: string): Stage {
  if (!(STAGES as readonly string[]).includes(s)) {
    throw new Error(`stage must be one of ${STAGES.join(', ')}; got '${s}'`);
  }
  return s as Stage;
}

export const zoneName = (stage: Stage): string => (stage === 'prod' ? ROOT_ZONE : `${stage}.${ROOT_ZONE}`);

export const zoneStackName = (stage: Stage): string => `mopm-dns-${stage}-zone`;
export const DELEGATION_STACK_NAME = 'mopm-dns-prod-delegation';

/** A Route 53 name server host, e.g. ns-123.awsdns-45.org (also .com, .net, .co.uk). */
const NS_RE = /^ns-\d{1,4}\.awsdns-\d{2}\.(?:org|com|net|co\.uk)$/;

/** Parse a comma-separated list of exactly four Route 53 name servers (trailing dots tolerated). */
export function parseNameServers(label: string, csv: unknown): string[] {
  const hosts = String(csv ?? '')
    .split(',')
    .map((h) => h.trim().replace(/\.$/, '').toLowerCase())
    .filter((h) => h.length > 0);
  if (hosts.length !== 4) {
    throw new Error(`${label}: expected exactly 4 name servers, got ${hosts.length}`);
  }
  for (const h of hosts) {
    if (!NS_RE.test(h)) throw new Error(`${label}: '${h}' is not a Route 53 name server host`);
  }
  if (new Set(hosts).size !== 4) throw new Error(`${label}: name servers must be distinct`);
  return hosts;
}
