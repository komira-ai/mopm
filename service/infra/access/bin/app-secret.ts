#!/usr/bin/env node
// Held, human-run: see BOOTSTRAP.md ("GitHub App"). From service/infra/access, after `npm ci`:
//   npx ts-node --prefer-ts-exts bin/app-secret.ts --stage beta --profile <profile> --app-id <id> --key-file <key.pem> [--apply]
// The private key is read from the named file only with --apply, never from a flag value.
import * as fs from 'fs';
import * as path from 'path';
import { realHost } from '../lib/held';
import { appSecret } from '../lib/app-secret';

process.exitCode = appSecret(process.argv.slice(2), realHost(path.resolve(__dirname, '..')), { readKey: (f) => fs.readFileSync(f, 'utf8') });
