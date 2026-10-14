#!/usr/bin/env node
import { App } from 'aws-cdk-lib';
import { GithubAccessStack } from '../lib/github-access-stack';
import { assertStage } from '../lib/contract';

// Configuration is context (-c key=value), never environment variables.
// Account ids and regions are supplied by the admin at deploy time.
const app = new App();
const need = (k: string): string => {
  const v = app.node.tryGetContext(k);
  if (typeof v !== 'string' || v === '') throw new Error(`missing context -c ${k}=...`);
  return v;
};
const stage = assertStage(need('stage'));
const account = need('account');
const region = need('region');
const regions = String(app.node.tryGetContext('regions') ?? region).split(',');
new GithubAccessStack(app, `mopm-${stage}-access`, {
  stage,
  regions,
  env: { account, region },
});
