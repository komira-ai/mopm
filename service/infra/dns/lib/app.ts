import { App, Stack } from 'aws-cdk-lib';
import { REGION, Stage, assertStage, parseNameServers } from './config';
import { DelegationStack } from './delegation-stack';
import { ZoneStack } from './zone-stack';

export interface DnsOptions {
  stage: Stage;
  /** Account of the stage being deployed. Comes from the -c account flag; never from a file. */
  account: string;
  /** Prod only: deploy the delegation stack instead of the zone stack. */
  delegate: boolean;
  betaNameServers?: unknown;
  gammaNameServers?: unknown;
  /** Synth tests only: skips the hosted zone lookup. Never set at real deploys. */
  hostedZoneId?: string;
}

export function createDnsStack(app: App, o: DnsOptions): Stack {
  if (!/^\d{12}$/.test(o.account)) throw new Error('account must be 12 digits (-c account=...)');
  const env = { account: o.account, region: REGION };
  if (!o.delegate) return new ZoneStack(app, o.stage, { env });

  if (o.stage !== 'prod') throw new Error('delegation is deployed in the prod account only (-c stage=prod)');
  const children = {
    beta: parseNameServers('betaNameServers', o.betaNameServers),
    gamma: parseNameServers('gammaNameServers', o.gammaNameServers),
  };
  return new DelegationStack(app, children, { env }, o.hostedZoneId);
}

export function createFromContext(app: App): Stack {
  const ctx = (k: string) => app.node.tryGetContext(k);
  const hostedZoneId = ctx('hostedZoneId');
  return createDnsStack(app, {
    stage: assertStage(String(ctx('stage') ?? '')),
    account: String(ctx('account') ?? ''),
    delegate: String(ctx('delegate') ?? '') === 'true',
    betaNameServers: ctx('betaNameServers'),
    gammaNameServers: ctx('gammaNameServers'),
    ...(hostedZoneId ? { hostedZoneId: String(hostedZoneId) } : {}),
  });
}
