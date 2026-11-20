#!/usr/bin/env node
// Held, human-run: see BOOTSTRAP.md ("E2B API key"). From service/infra/access, after `npm ci`:
//   npx ts-node --prefer-ts-exts bin/e2b-secret.ts --stage beta --profile <profile> [--apply]
// The key is read from stdin (hidden prompt on a terminal), never from a flag.
import * as path from 'path';
import { realHost } from '../lib/held';
import { e2bSecret } from '../lib/e2b-secret';
import { readE2bKey } from '../lib/read-secret';

process.exitCode = e2bSecret(process.argv.slice(2), realHost(path.resolve(__dirname, '..')), { readKey: readE2bKey });
