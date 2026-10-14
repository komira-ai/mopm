// Infra contract (piece P4b) for the names this stack must agree on with the
// service stacks (P10). Everything here is derived from the stage and the
// account; nothing is read from the environment.

export const STAGES = ['beta', 'gamma', 'prod'] as const;
export type Stage = (typeof STAGES)[number];

export function assertStage(s: string): Stage {
  if (!(STAGES as readonly string[]).includes(s)) {
    throw new Error(`stage must be one of ${STAGES.join(', ')}; got '${s}'`);
  }
  return s as Stage;
}

/** Only beta and gamma are disposable. Prod is the only durable registry. */
export const isDisposable = (stage: Stage): boolean => stage !== 'prod';

/** CDK bootstrap qualifier (the CDK default). */
export const CDK_QUALIFIER = 'hnb659fds';

/** The four roles `cdk bootstrap` creates and the CDK CLI assumes. */
export const CDK_BOOTSTRAP_ROLE_KINDS = [
  'deploy-role',
  'file-publishing-role',
  'image-publishing-role',
  'lookup-role',
] as const;

export const GITHUB_OIDC_URL = 'https://token.actions.githubusercontent.com';
export const GITHUB_OIDC_HOST = 'token.actions.githubusercontent.com';
export const OIDC_AUDIENCE = 'sts.amazonaws.com';

/** The one repository whose workflows may assume the roles. Every trust condition is bound to it. */
export const REPO = 'komira-ai/mopm';
/**
 * Immutable numeric ids of the owner and the repository (public, not secret). The repository's OIDC
 * subject uses the immutable format (`use_immutable_subject`), whose repo segment is
 * `repo:<owner>@<owner id>/<name>@<repo id>`; see BOOTSTRAP.md.
 */
export const GITHUB_OWNER_ID = '305577347';
export const GITHUB_REPO_ID = '1418104703';

/** `repo:<owner>@<ownerId>/<name>@<repoId>`: the sub prefix GitHub emits for an immutable-subject repository. */
export function immutableSubjectPrefix(repo: string, ownerId: string, repoId: string): string {
  const [owner, name] = repo.split('/');
  return `repo:${owner}@${ownerId}/${name}@${repoId}`;
}

/** Workflow files (in REPO, on main) allowed to assume each role. */
export const DEPLOY_WORKFLOW = '.github/workflows/deploy.yml';
export const E2E_WORKFLOW = '.github/workflows/e2e.yml';
export const WORKFLOW_REF = 'refs/heads/main';

export const deployRoleName = (s: Stage) => `mopm-${s}-deploy`;
export const e2eRoleName = (s: Stage) => `mopm-${s}-e2e`;

/** Service resource names the e2e role may touch (created by the P10 stacks). */
export const channelBucketName = (s: Stage, account: string) => `mopm-${s}-channel-${account}`;
export const tableName = (s: Stage, table: string) => `mopm-${s}-${table}`;
/** Secrets Manager name of the single test-identity secret (AWS appends -XXXXXX). */
export const testIdentitySecretName = (s: Stage) => `mopm/${s}/e2e/test-identity`;

/** Tables the cleanup may delete e2e rows from. Never `audit`, `tokens` or `users`. */
export const CLEANUP_TABLES = ['packages', 'versions', 'owners'] as const;
/** Every e2e package name starts with this (design 17e); S3 keys are files/<name>/... */
export const E2E_NAME_PREFIX = 'e2e_';
