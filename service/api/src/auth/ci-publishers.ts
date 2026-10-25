/** The events a CI identity may exchange from (the same set as ALLOWED_EVENTS in oidc.ts, which tests pin equal). */
export const CI_EVENTS: readonly string[] = ['push', 'workflow_dispatch'];

/**
 * Repository-level CI publishers: a CI identity the deployment itself trusts, as configuration in the code that
 * deploys it (the `CI_PUBLISHERS` environment variable of the API function), not as rows a package owner registers.
 * Only the beta stage may carry one: gamma and prod keep the human step, and `parseCiPublishers` refuses to load a
 * policy on any other stage, whatever the infrastructure says.
 */
export const CI_PUBLISHERS_ENV = 'CI_PUBLISHERS';
/** The one stage that may trust a CI identity by configuration. */
export const CI_PUBLISHER_STAGE = 'beta';
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
}

/** The owner identity a repository's publisher holds on the packages it creates: `PackageRecord.ci_owner`. */
export const ciOwnerOf = (repository_id: string): string => `gh-repo:${repository_id}`;

/**
 * The actor a CI identity is in audit rows, upload and group records, the per-actor group list and the groups policy:
 * `ci:gh-repo:<repository_id>`. It names the identity, not a token, so every token the identity gets in later jobs is the same actor.
 */
export const ciActorOf = (ci_owner: string): string => `ci:${ci_owner}`;

const KEYS = ['repository_id', 'repository_owner_id', 'workflow', 'ref', 'job_workflow_ref', 'events', 'environment'] as const;
const JOB_WORKFLOW_REF = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\/\.github\/workflows\/[A-Za-z0-9._-]+\.ya?ml@refs\/(heads|tags)\/[A-Za-z0-9._\/-]+$/;
const DIGITS = /^[1-9][0-9]{0,19}$/;
const REF = /^refs\/(heads|tags)\/[A-Za-z0-9._\/-]+$/;
const WORKFLOW = /^\.github\/workflows\/[A-Za-z0-9._-]+\.ya?ml$/;
const ENVIRONMENT = /^[A-Za-z0-9._-]{1,64}$/;

const bad = (detail: string) => new Error(`${CI_PUBLISHERS_ENV} is not valid: ${detail}`);

/**
 * The CI publishers named by the environment value. Absent or empty: none. Present on any stage but beta: an error,
 * so the function does not start (a mistake in infrastructure cannot turn the trust on elsewhere). Malformed: an
 * error naming what is wrong, never a partial list.
 */
export function parseCiPublishers(stage: string, raw: string | undefined): CiPublisher[] {
  if (raw === undefined || raw === '') return [];
  if (stage !== CI_PUBLISHER_STAGE) {
    throw new Error(`${CI_PUBLISHERS_ENV} may be set on the ${CI_PUBLISHER_STAGE} stage only; this is ${stage}`);
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
    out.push({
      repository_id: str('repository_id', DIGITS),
      repository_owner_id: str('repository_owner_id', DIGITS),
      workflow,
      ref,
      job_workflow_ref,
      events: [...(events as string[])],
      environment: str('environment', ENVIRONMENT),
    });
  }
  if (new Set(out.map((p) => p.repository_id)).size !== out.length) throw bad('a repository is named twice');
  return out;
}
