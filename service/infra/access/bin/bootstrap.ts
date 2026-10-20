#!/usr/bin/env node
// Held, human-run: see BOOTSTRAP.md. From service/infra/access, after `npm ci`:
//   npx ts-node --prefer-ts-exts bin/bootstrap.ts --stage beta --account <id> --region <region> --profile <profile> [--apply]
import * as path from 'path';
import { bootstrap } from '../lib/bootstrap';
import { realHost } from '../lib/held';

const root = path.resolve(__dirname, '..');
process.exitCode = bootstrap(process.argv.slice(2), realHost(root), { templatePath: path.join(root, 'cfn-exec-policy.template.json') });
