import { execFileSync } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { App } from 'aws-cdk-lib';
import { createStageStacks } from '../lib/app';
import { stageConfig } from '../lib/config';
import { DUMMY_ACCOUNT, DUMMY_ZONE_ID, SITE_STUB_DIR, requireApiBundle } from './util';

/**
 * Every Lambda function of the service must load from the directory CDK uploads for it, with nothing but what that
 * directory holds (and Node, and the AWS SDK, which the Lambda runtime provides).
 *
 * The test synthesizes the real stacks over the real handler bundle (service/api/dist, built by `npm run build`
 * as deploy.yml builds it), reads each function's handler and code asset out of the synthesized cloud assembly
 * (`asset.<hash>` next to the templates: the bytes `cdk deploy` zips and uploads), and in a fresh Node process
 * with an empty environment, started in an empty scratch directory that has no `node_modules` anywhere above it,
 * `require`s the handler's module. The only modules the process may get from outside the asset are Node's own and
 * `@aws-sdk/*` (replaced by a stub, because the runtime provides the real one). A package the asset lacks is
 * `Cannot find module`, as it is on Lambda.
 *
 * Why not read the imports: the question is what the deployed bytes need, and only loading them answers it.
 */

const STUB = `
const Module = require('module');
const load = Module._load;
const stub = new Proxy(function () {}, {
  get: (t, k) => (k === '__esModule' ? false : stub),
  apply: () => stub,
  construct: () => stub,
});
Module._load = function (request, parent, isMain) {
  if (request.startsWith('@aws-sdk/')) return stub;
  return load.call(this, request, parent, isMain);
};
`;

const LOADER = `
const m = require(require('path').join(process.env.ASSET_DIR, process.env.MODULE_FILE));
if (typeof m[process.env.EXPORT_NAME] !== 'function') throw new Error(process.env.MODULE_FILE + ' does not export a function ' + process.env.EXPORT_NAME);
`;

jest.setTimeout(120_000);

let scratch: string;
let stubFile: string;

beforeAll(() => {
  scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'mopm-bundle-'));
  stubFile = path.join(scratch, 'aws-sdk-stub.js');
  fs.writeFileSync(stubFile, STUB);
});

/** Load `moduleFile` from `assetDir` in a bare process; throws with the process's stderr when it cannot. */
function loadFrom(assetDir: string, moduleFile: string, exportName: string): void {
  const cwd = fs.mkdtempSync(path.join(scratch, 'cwd-'));
  try {
    execFileSync(process.execPath, ['--require', stubFile, '--eval', LOADER], {
      cwd,
      env: { ASSET_DIR: assetDir, MODULE_FILE: moduleFile, EXPORT_NAME: exportName },
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 60_000,
    });
  } catch (e: any) {
    throw new Error(`${moduleFile} does not load from ${assetDir}:\n${String(e.stderr ?? e.message).split('\n').slice(0, 8).join('\n')}`);
  }
}

interface Deployed {
  handler: string;
  assetDir: string;
}

let synthesized: Deployed[] | undefined;

function deployedFunctions(): Deployed[] {
  synthesized ??= synthesize();
  return synthesized;
}

function synthesize(): Deployed[] {
  requireApiBundle();
  const outdir = fs.mkdtempSync(path.join(scratch, 'cdk-out-'));
  const app = new App({ outdir });
  const stacks = createStageStacks(
    app,
    stageConfig('beta', DUMMY_ZONE_ID),
    { account: DUMMY_ACCOUNT, region: 'us-east-1' },
    '1.2.3',
    'c0ffee',
    undefined, // the real bundle, DEFAULT_HANDLER_DIR
    SITE_STUB_DIR,
  );
  const assembly = app.synth();
  const out: Deployed[] = [];
  for (const stack of [stacks.api, stacks.publish]) {
    const template = assembly.getStackArtifact(stack.artifactId).template;
    for (const r of Object.values<any>(template.Resources)) {
      if (r.Type !== 'AWS::Lambda::Function') continue;
      const key: string = r.Properties.Code.S3Key; // `<asset hash>.zip`
      const assetDir = path.join(outdir, `asset.${key.replace(/\.zip$/, '')}`);
      expect(fs.statSync(assetDir).isDirectory()).toBe(true);
      out.push({ handler: r.Properties.Handler, assetDir });
    }
  }
  return out;
}

describe('the deployed Lambda assets', () => {
  test('control: a package outside the asset is not found, so the check below can fail', () => {
    const dir = fs.mkdtempSync(path.join(scratch, 'control-'));
    // `typescript` is installed in this package and in service/api; the process must not see either.
    fs.writeFileSync(path.join(dir, 'probe.js'), "require('typescript'); exports.handler = () => 0;\n");
    expect(() => loadFrom(dir, 'probe.js', 'handler')).toThrow(/Cannot find module 'typescript'/);
  });

  test('control: a module that needs only Node and the AWS SDK loads', () => {
    const dir = fs.mkdtempSync(path.join(scratch, 'control-'));
    fs.writeFileSync(
      path.join(dir, 'ok.js'),
      "const { DynamoDBClient } = require('@aws-sdk/client-dynamodb'); require('node:crypto'); new DynamoDBClient({}); exports.handler = () => 0;\n",
    );
    loadFrom(dir, 'ok.js', 'handler');
  });

  test('the six functions are the API, the index reader, the validator, the index writer, the group validator and the group sweeper', () => {
    expect(
      deployedFunctions()
        .map((f) => f.handler)
        .sort(),
    ).toEqual([
      'http/index-lambda.handler',
      'http/lambda.handler',
      'publish/group-validator-lambda.handler',
      'publish/indexer-lambda.handler',
      'publish/sweeper-lambda.handler',
      'publish/validator-lambda.handler',
    ]);
  });

  test.each([
    'http/lambda.handler',
    'http/index-lambda.handler',
    'publish/validator-lambda.handler',
    'publish/indexer-lambda.handler',
    'publish/group-validator-lambda.handler',
    'publish/sweeper-lambda.handler',
  ])(
    '%s loads from the asset CDK uploads, with no node_modules in reach',
    (handler) => {
      const f = deployedFunctions().find((d) => d.handler === handler);
      expect(f).toBeDefined();
      const dot = handler.lastIndexOf('.');
      loadFrom(f!.assetDir, handler.slice(0, dot), handler.slice(dot + 1));
    },
  );
});

afterAll(() => {
  // Scratch is under the OS temp directory and unique to this run; nothing else points at it.
  fs.rmSync(scratch, { recursive: true, force: true });
});
