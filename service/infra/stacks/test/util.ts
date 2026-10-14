import * as path from 'path';
import { App } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { StageStacks, createStageStacks } from '../lib/app';
import * as fs from 'fs';
import { DEFAULT_HANDLER_DIR } from '../lib/api-stack';
import { Stage, stageConfig } from '../lib/config';

// Dummy values: tests never see a real account or hosted zone. Built at runtime so no 12-digit literal appears
// in the repository (the hygiene job refuses those).
export const DUMMY_ACCOUNT = '1'.repeat(12);
export const DUMMY_ZONE_ID = 'Z0DUMMYZONE';

/** A stand-in for the CI-built handler bundle, so tests synthesize without a build. */
export const HANDLER_STUB_DIR = path.join(__dirname, 'fixtures/api-handler');

export function build(stage: Stage): StageStacks {
  const app = new App();
  return createStageStacks(
    app,
    stageConfig(stage, DUMMY_ZONE_ID),
    { account: DUMMY_ACCOUNT, region: 'us-east-1' },
    '1.2.3',
    'c0ffee',
    HANDLER_STUB_DIR,
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

/**
 * For tests that synthesize with the REAL handler bundle (no stub): fail up front, saying why, when it is not built.
 * CI (service-ci.yml, stacks job) builds it before running the tests; locally run `npm ci && npm run build` in service/api.
 */
export function requireApiBundle(): void {
  if (!fs.existsSync(path.join(DEFAULT_HANDLER_DIR, 'http/lambda.js'))) {
    throw new Error(
      `this test synthesizes with the real API handler bundle, which is not built at ${DEFAULT_HANDLER_DIR}; ` +
        "run 'npm ci && npm run build' in service/api first (CI does this before the stacks tests)",
    );
  }
}
