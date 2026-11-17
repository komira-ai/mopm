import { namespaceProblem } from './namespaces';

/** The events a CI identity may exchange from (the same set as ALLOWED_EVENTS in oidc.ts, which tests pin equal). */
export const CI_EVENTS: readonly string[] = ['push', 'workflow_dispatch'];

/**
 * Repository-level CI publishers: a CI identity the deployment itself trusts, as configuration in the code that
 * deploys it (the `CI_PUBLISHERS` environment variable of the API function), not as rows a package owner registers.
 * Only the beta stage may carry one, plus prod for rows that carry `acts_for` (a CI identity that publishes AS a named account,
 * owning nothing itself) or `namespace` (a CI identity that publishes in an owner namespace through `/api/v2`): gamma keeps the human
 * step, a row with neither on prod is refused, and `parseCiPublishers` refuses to load a policy on any other stage, whatever the
 * infrastructure says. Beta accepts either or neither.
 */
export const CI_PUBLISHERS_ENV = 'CI_PUBLISHERS';
/** The stage that may trust any CI identity by configuration. */
export const CI_PUBLISHER_STAGE = 'beta';
/** The stage that may trust a CI identity only as one that acts for an account or publishes in a namespace (rows with `acts_for` or `namespace`). */
export const CI_ACTS_FOR_STAGE = 'prod';
/** The most publishers a deployment may name. */
export const MAX_CI_PUBLISHERS = 8;

export interface CiPublisher {
  /** GitHub's numeric repository id (a renamed or re-created repository does not match), as a decimal string. */
  repository_id: string;
  /** GitHub's numeric id of the repository's owner. */
  repository_owner_id: string;
  /** Workflow file path in the repository, e.g. `.github/workflows/release.yml`. */
  workflow: string;
  /** The exact git ref the job runs on, e.g. `refs/heads/main`. No pattern. */
  ref: string;
  /**
   * The exact `job_workflow_ref` claim: `<owner>/<repo>/<workflow>@<ref>`, written out in full (the row holds ids, not names, so
   * the name cannot be derived). It must end in `/<workflow>@<ref>` of this same row. Unlike `workflow_ref`, which names the
   * workflow that was triggered, `job_workflow_ref` names the file the running job is defined in: a job of a reusable workflow
   * (`workflow_call`) carries the called file here, so a different file, ref or repository called from the right workflow does not match.
   */
  job_workflow_ref: string;
  /** The events that may exchange: a non-empty subset of `push` and `workflow_dispatch`. */
  events: string[];
  /** The deployment environment the job runs in. Required. */
  environment: string;
  /**
   * Optional: GitHub's numeric id of an account this identity ACTS FOR, as a decimal string. The exchange then mints a token whose
   * principal is that account (actor `u:<id>`, ownership checked against the package's owner rows), good for exactly the listed
   * packages and versions. Such a row creates no package and sets no `ci_owner`: every name must already be claimed by the account.
   * The token records the CI identity it came through (`acts_via`), so its publishes are distinguishable from the account's own.
   */
  acts_for?: string;
  /**
   * Optional: an owner namespace this identity publishes in through `/api/v2`'s `packages` exchange. The row's `repository_owner_id`
   * must be the namespace's GitHub id (checked at exchange). Such a row creates nothing; it cannot also carry `acts_for`, and it does
   * not serve `/api/v1`'s exchange (the same repository's row without a namespace, if there is one, does).
   */
  namespace?: string;
}

/** The owner identity a repository's publisher holds on the packages it creates: `PackageRecord.ci_owner`. */
export const ciOwnerOf = (repository_id: string): string => `gh-repo:${repository_id}`;

/**
 * The actor a CI identity is in audit rows, upload and group records, the per-actor group list and the groups policy:
 * `ci:gh-repo:<repository_id>`. It names the identity, not a token, so every token the identity gets in later jobs is the same actor.
 */
export const ciActorOf = (ci_owner: string): string => `ci:${ci_owner}`;

const KEYS = ['repository_id', 'repository_owner_id', 'workflow', 'ref', 'job_workflow_ref', 'events', 'environment', 'acts_for', 'namespace'] as const;
const JOB_WORKFLOW_REF = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\/\.github\/workflows\/[A-Za-z0-9._-]+\.ya?ml@refs\/(heads|tags)\/[A-Za-z0-9._\/-]+$/;
const DIGITS = /^[1-9][0-9]{0,19}$/;
const REF = /^refs\/(heads|tags)\/[A-Za-z0-9._\/-]+$/;
const WORKFLOW = /^\.github\/workflows\/[A-Za-z0-9._-]+\.ya?ml$/;
const ENVIRONMENT = /^[A-Za-z0-9._-]{1,64}$/;

const bad = (detail: string) => new Error(`${CI_PUBLISHERS_ENV} is not valid: ${detail}`);

/**
 * The CI publishers named by the environment value. Absent or empty: none. Present on any stage but beta and prod: an error,
 * so the function does not start (a mistake in infrastructure cannot turn the trust on elsewhere). On prod every row must carry
 * `acts_for` or `namespace`; a row with neither is an error there. A row with both is an error on every stage. A repository is
 * named at most once without a namespace and at most once per namespace. Malformed: an error naming what is wrong, never a partial list.
 */
export function parseCiPublishers(stage: string, raw: string | undefined): CiPublisher[] {
  if (raw === undefined || raw === '') return [];
  if (stage !== CI_PUBLISHER_STAGE && stage !== CI_ACTS_FOR_STAGE) {
    throw new Error(`${CI_PUBLISHERS_ENV} may be set on the ${CI_PUBLISHER_STAGE} stage only (or ${CI_ACTS_FOR_STAGE}, for rows that act for an account or publish in a namespace); this is ${stage}`);
  }
  let v: unknown;
  try {
    v = JSON.parse(raw);
  } catch {
    throw bad('not JSON');
  }
  if (!Array.isArray(v) || v.length < 1 || v.length > MAX_CI_PUBLISHERS) throw bad(`a JSON array of 1 to ${MAX_CI_PUBLISHERS} publishers`);
  const out: CiPublisher[] = [];
  for (const [i, e] of v.entries()) {
    if (typeof e !== 'object' || e === null || Array.isArray(e)) throw bad(`entry ${i} is not an object`);
    const o = e as Record<string, unknown>;
    for (const k of Object.keys(o)) if (!(KEYS as readonly string[]).includes(k)) throw bad(`entry ${i} has an unknown key '${k}'`);
    const str = (k: (typeof KEYS)[number], re: RegExp): string => {
      const x = o[k];
      if (typeof x !== 'string' || !re.test(x)) throw bad(`entry ${i}: '${k}' is missing or malformed`);
      return x;
    };
    const events = o.events;
    if (!Array.isArray(events) || events.length < 1 || new Set(events).size !== events.length || !events.every((x) => typeof x === 'string' && CI_EVENTS.includes(x))) {
      throw bad(`entry ${i}: 'events' is a non-empty list of ${CI_EVENTS.join(' and ')}`);
    }
    const workflow = str('workflow', WORKFLOW);
    const ref = str('ref', REF);
    const job_workflow_ref = str('job_workflow_ref', JOB_WORKFLOW_REF);
    if (!job_workflow_ref.endsWith(`/${workflow}@${ref}`)) throw bad(`entry ${i}: 'job_workflow_ref' must end in '/<workflow>@<ref>' of the same entry`);
    if (o.acts_for !== undefined && o.namespace !== undefined) throw bad(`entry ${i}: 'acts_for' and 'namespace' are exclusive`);
    if (stage !== CI_PUBLISHER_STAGE && o.acts_for === undefined && o.namespace === undefined) {
      throw bad(`entry ${i}: the ${stage} stage trusts only rows that carry 'acts_for' or 'namespace'; this row has neither`);
    }
    if (o.namespace !== undefined && (typeof o.namespace !== 'string' || namespaceProblem(o.namespace) !== undefined)) {
      throw bad(`entry ${i}: 'namespace' is missing or malformed`);
    }
    out.push({
      ...(o.acts_for === undefined ? {} : { acts_for: str('acts_for', DIGITS) }),
      ...(o.namespace === undefined ? {} : { namespace: o.namespace as string }),
      repository_id: str('repository_id', DIGITS),
      repository_owner_id: str('repository_owner_id', DIGITS),
      workflow,
      ref,
      job_workflow_ref,
      events: [...(events as string[])],
      environment: str('environment', ENVIRONMENT),
    });
  }
  // A repository may hold one row that serves `/api/v1` (no namespace) and one row per namespace it publishes in through `/api/v2`,
  // so a release can move into a namespace without a window in which neither exchange trusts it. Two rows of one repository that serve
  // the same exchange would make the match depend on their order, so they are refused.
  if (new Set(out.map((p) => `${p.repository_id}\0${p.namespace ?? ''}`)).size !== out.length) {
    throw bad('a repository is named twice for the same namespace, or twice without one');
  }
  return out;
}
