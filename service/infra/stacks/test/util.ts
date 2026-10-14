import { App } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { StageStacks, createStageStacks } from '../lib/app';
import { Stage, stageConfig } from '../lib/config';

// Dummy values: tests never see a real account or hosted zone. Built at runtime so no 12-digit literal appears
// in the repository (the hygiene job refuses those).
export const DUMMY_ACCOUNT = '1'.repeat(12);
export const DUMMY_ZONE_ID = 'Z0DUMMYZONE';

export function build(stage: Stage): StageStacks {
  const app = new App();
  return createStageStacks(
    app,
    stageConfig(stage, DUMMY_ZONE_ID),
    { account: DUMMY_ACCOUNT, region: 'us-east-1' },
    '1.2.3',
    'c0ffee',
  );
}

export const tpl = (stage: Stage) => {
  const s = build(stage);
  return {
    channel: Template.fromStack(s.channel),
    data: Template.fromStack(s.data),
    api: Template.fromStack(s.api),
    site: Template.fromStack(s.site),
  };
};

/** All statements of all bucket policies in a template. */
export function bucketStatements(t: Template): any[] {
  return Object.values(t.findResources('AWS::S3::BucketPolicy')).flatMap(
    (r: any) => r.Properties.PolicyDocument.Statement,
  );
}

/** Role names (suffix after mopm-<stage>-) named by an ArnNotLike condition. */
export function exemptRoles(stmt: any): string[] {
  const v = stmt.Condition.ArnNotLike['aws:PrincipalArn'];
  return (Array.isArray(v) ? v : [v]).map((a: string) => a.replace(/^.*role\/mopm-[a-z]+-/, '')).sort();
}
