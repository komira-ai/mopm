#!/usr/bin/env node
// Held, human-run: see README.md. From service/infra/dns, after `npm ci`:
//   npx ts-node --prefer-ts-exts bin/dns-cli.ts --stage beta --account <id> --profile <profile> [--apply]
// (bin/dns.ts is the CDK app itself; cdk.json points at it.)
import * as path from 'path';
import { dnsCli } from '../lib/dns-cli';
import { realHost } from '../lib/held';

process.exitCode = dnsCli(process.argv.slice(2), realHost(path.resolve(__dirname, '..')));
