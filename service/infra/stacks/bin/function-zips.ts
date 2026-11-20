#!/usr/bin/env node
// Usage: function-zips check-zips --zip-dir <dir>
//        function-zips check-deployed --stage <stage> --zip-dir <dir> --account <id> --region <region>
// The logic is lib/function-zips.ts. The AWS CLI starts from the job's credentials (the deploy role); check-deployed assumes the
// stage's CDK lookup role with them and hands its credentials to the `aws lambda` calls alone.
import { execFileSync } from 'child_process';
import * as fs from 'fs';
import { main } from '../lib/function-zips';

process.exitCode = main(process.argv.slice(2), {
  aws: (args, env) => execFileSync('aws', args, { encoding: 'utf8', env: { ...process.env, ...env } }),
  readFile: (file) => fs.readFileSync(file),
  out: console.log,
  err: console.error,
});
