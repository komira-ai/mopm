import { CliCredentialsStackSynthesizer, Duration, Stack, StackProps } from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';
import * as c from './contract';

export interface GithubAccessStackProps extends StackProps {
  readonly stage: c.Stage;
  /** owner/name of the repository the OIDC `sub` is bound to. Defaults to the one public repository. */
  readonly repo?: string;
  /** Numeric id of the repository owner (immutable subject). Defaults to the public repository's. */
  readonly ownerId?: string;
  /** Numeric id of the repository (immutable subject). Defaults to the public repository's. */
  readonly repoId?: string;
  /** Regions whose CDK bootstrap roles the deploy role may assume. */
  readonly regions: string[];
}

const ACCOUNT_ID = /^\d{12}$/;

export class GithubAccessStack extends Stack {
  public readonly deployRole: iam.Role;
  public readonly e2eRole: iam.Role;

  constructor(scope: Construct, id: string, props: GithubAccessStackProps) {
    // Deployed once by a human admin with their own credentials, so it does not depend on
    // (and must not run through) the CDK bootstrap roles it grants access to.
    super(scope, id, { synthesizer: new CliCredentialsStackSynthesizer(), ...props });
    const { stage, regions } = props;
    const repo = props.repo ?? c.REPO;
    const account = props.env?.account;
    const region = props.env?.region;
    if (!account || !ACCOUNT_ID.test(account) || !region) {
      throw new Error('env.account (12 digits) and env.region must be concrete, not tokens');
    }
    if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) throw new Error(`bad repo '${repo}'`);
    const ownerId = props.ownerId ?? c.GITHUB_OWNER_ID;
    const repoId = props.repoId ?? c.GITHUB_REPO_ID;
    if (!/^[1-9]\d*$/.test(ownerId) || !/^[1-9]\d*$/.test(repoId)) throw new Error('owner and repo ids must be numeric');
    if (regions.length === 0) throw new Error('regions must not be empty');

    const provider = new iam.OpenIdConnectProvider(this, 'GithubOidc', {
      url: c.GITHUB_OIDC_URL,
      clientIds: [c.OIDC_AUDIENCE],
    });

    // sub = repo:<owner>@<ownerId>/<name>@<repoId>:environment:<stage>:job_workflow_ref:<repo>/<file>@<ref>
    // The repo segment is the immutable form (use_immutable_subject); GitHub documents job_workflow_ref
    // with names, not ids. This requires the repo's OIDC subject template to be
    // ["repo","context","job_workflow_ref"] (see BOOTSTRAP.md, step 0 confirms the exact string).
    const prefix = c.immutableSubjectPrefix(repo, ownerId, repoId);
    const subFor = (workflowFile: string) =>
      `${prefix}:environment:${stage}:job_workflow_ref:${repo}/${workflowFile}@${c.WORKFLOW_REF}`;

    const trust = (workflowFile: string) =>
      new iam.FederatedPrincipal(
        provider.openIdConnectProviderArn,
        {
          StringEquals: {
            [`${c.GITHUB_OIDC_HOST}:aud`]: c.OIDC_AUDIENCE,
            [`${c.GITHUB_OIDC_HOST}:sub`]: subFor(workflowFile),
          },
        },
        'sts:AssumeRoleWithWebIdentity',
      );

    // ---- deploy role: may only assume the CDK bootstrap roles of this account.
    this.deployRole = new iam.Role(this, 'DeployRole', {
      roleName: c.deployRoleName(stage),
      description: `GitHub deploy workflow for mopm ${stage}; can only assume CDK bootstrap roles`,
      assumedBy: trust(c.DEPLOY_WORKFLOW),
      maxSessionDuration: Duration.hours(1),
    });
    const cdkRoles = regions.flatMap((r) =>
      c.CDK_BOOTSTRAP_ROLE_KINDS.map(
        (k) => `arn:aws:iam::${account}:role/cdk-${c.CDK_QUALIFIER}-${k}-${account}-${r}`,
      ),
    );
    this.deployRole.addToPolicy(
      new iam.PolicyStatement({ effect: iam.Effect.ALLOW, actions: ['sts:AssumeRole'], resources: cdkRoles }),
    );

    // ---- e2e role: black-box tests only.
    this.e2eRole = new iam.Role(this, 'E2eRole', {
      roleName: c.e2eRoleName(stage),
      description: `GitHub e2e workflow for mopm ${stage}; read-only plus e2e_* cleanup on disposable stages`,
      assumedBy: trust(c.E2E_WORKFLOW),
      maxSessionDuration: Duration.hours(1),
    });
    const bucket = c.channelBucketName(stage, account);
    this.e2eRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'ReadTestIdentity',
        actions: ['secretsmanager:GetSecretValue'],
        // Secrets Manager appends '-' plus six characters to the name.
        resources: [`arn:aws:secretsmanager:${region}:${account}:secret:${c.testIdentitySecretName(stage)}-??????`],
      }),
    );
    this.e2eRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'IndexOracleRead',
        actions: ['s3:GetObject'],
        resources: [`arn:aws:s3:::${bucket}/*`],
      }),
    );
    this.e2eRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'IndexOracleList',
        actions: ['s3:ListBucket'],
        resources: [`arn:aws:s3:::${bucket}`],
      }),
    );
    if (c.isDisposable(stage)) {
      // Cleanup (design 17e): delete e2e_* rows and bytes. Never on prod.
      this.e2eRole.addToPolicy(
        new iam.PolicyStatement({
          sid: 'CleanupRows',
          actions: ['dynamodb:Query', 'dynamodb:DeleteItem'],
          resources: c.CLEANUP_TABLES.map(
            (t) => `arn:aws:dynamodb:${region}:${account}:table/${c.tableName(stage, t)}`,
          ),
          conditions: {
            'ForAllValues:StringLike': { 'dynamodb:LeadingKeys': [`${c.E2E_NAME_PREFIX}*`] },
          },
        }),
      );
      this.e2eRole.addToPolicy(
        new iam.PolicyStatement({
          sid: 'CleanupBytes',
          actions: ['s3:DeleteObject'],
          resources: [`arn:aws:s3:::${bucket}/files/${c.E2E_NAME_PREFIX}*`],
        }),
      );
    }
  }
}
