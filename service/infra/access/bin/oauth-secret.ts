#!/usr/bin/env node
// Held, human-run: see BOOTSTRAP.md ("GitHub OAuth app"). From service/infra/access, after `npm ci`:
//   npx ts-node --prefer-ts-exts bin/oauth-secret.ts --stage beta --profile <profile> --client-id <id> [--apply]
// The client secret is read from stdin (hidden prompt on a terminal), never from a flag.
import * as path from 'path';
import { realHost } from '../lib/held';
import { oauthSecret } from '../lib/oauth-secret';
import { readSecret } from '../lib/read-secret';

process.exitCode = oauthSecret(process.argv.slice(2), realHost(path.resolve(__dirname, '..')), { readSecret });
