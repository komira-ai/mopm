#!/usr/bin/env node
// Usage:
//   cdk deploy mopm-dns-<stage>-zone -c stage=beta|gamma|prod -c account=<12 digits>
//   cdk deploy mopm-dns-prod-delegation -c stage=prod -c account=<prod account> -c delegate=true \
//       -c betaNameServers=<4 comma separated> -c gammaNameServers=<4 comma separated>
// Prefer `npm run dns-cli` (service/infra/dns/lib/dns-cli.ts), which passes these as flags. The account is never in a file.
import { App } from 'aws-cdk-lib';
import { createFromContext } from '../lib/app';

createFromContext(new App());
