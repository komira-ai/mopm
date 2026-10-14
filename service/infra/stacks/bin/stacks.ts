#!/usr/bin/env node
// Usage: cdk synth|deploy -c stage=beta|gamma|prod [-c version=<release>] [-c hostedZoneId=<dummy, synth only>]
// The account comes from the CDK environment (CDK_DEFAULT_ACCOUNT) at deploy time; it is never in a file.
import { App } from 'aws-cdk-lib';
import { createStageStacks } from '../lib/app';
import { REGION, assertStage, stageConfig } from '../lib/config';

const app = new App();
const stage = assertStage(String(app.node.tryGetContext('stage') ?? ''));
const account = process.env.CDK_DEFAULT_ACCOUNT;
if (!account) {
  throw new Error('CDK_DEFAULT_ACCOUNT is not set; the account is provided by the CDK environment at deploy time');
}
const zoneId = app.node.tryGetContext('hostedZoneId');
const version = String(app.node.tryGetContext('version') ?? 'dev');
createStageStacks(app, stageConfig(stage, zoneId ? String(zoneId) : undefined), { account, region: REGION }, version);
