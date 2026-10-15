import * as fs from 'fs';
import { builtinModules } from 'node:module';
import * as path from 'path';
import * as ts from 'typescript';

/**
 * What each Lambda entry point of this package needs from `node_modules` at run time, against what the deployed
 * bundle holds.
 *
 * The bundle is the output of `tsc -p tsconfig.build.json` (`dist/`), uploaded as it is (api-stack.ts and
 * publish-stack.ts: `Code.fromAsset(dist)`; deploy.yml builds it with `npm run build` and nothing else). It has no
 * `node_modules`. The Node.js 20 Lambda runtime provides the AWS SDK for JavaScript v3 and Node's own modules;
 * every other package an entry point requires is missing at run time and the function fails when it loads.
 *
 * This test follows the `require` calls of each entry point's compiled code (the same transpilation `tsc` does, per
 * file) through the package's own files and lists the packages that are neither Node built-ins nor the AWS SDK.
 *
 * KNOWN DEFECT, pinned here so the validator corpus is read for what it is: the validator Lambda requires `fzstd`
 * (src/validate/zstd-read.ts, to read the zstd streams of a .conda), which is not in the bundle. Read statically,
 * its cold start fails with "Cannot find module 'fzstd'", so every validate message would go to the dead-letter
 * queue; no archive has ever been validated by the deployed function that this repository knows of. The corpus
 * (tests/validator_corpus) therefore records the behaviour of the TypeScript validator as the source tree has it,
 * which is what a Rust port must match, and not necessarily what the deployed bundle does. When the bundle gets
 * the package (or the dependency goes), this test changes to expect an empty list for the validator.
 */

const SRC = path.resolve(__dirname, '../../src');
const RUNTIME_PROVIDED = (spec: string) => spec.startsWith('node:') || builtinModules.includes(spec) || spec.startsWith('@aws-sdk/');

function compiledRequires(file: string): string[] {
  const out = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true },
    fileName: file,
  }).outputText;
  return [...out.matchAll(/\brequire\("([^"]+)"\)/g)].map((m) => m[1]!);
}

function resolveRelative(from: string, spec: string): string {
  const base = path.resolve(path.dirname(from), spec);
  for (const c of [`${base}.ts`, path.join(base, 'index.ts')]) if (fs.existsSync(c)) return c;
  throw new Error(`${spec} (from ${from}) is not a file of this package`);
}

/** The packages an entry point requires that the runtime does not provide, sorted. */
function missingAtRuntime(entry: string): string[] {
  const seen = new Set<string>();
  const missing = new Set<string>();
  const walk = (file: string) => {
    if (seen.has(file)) return;
    seen.add(file);
    for (const spec of compiledRequires(file)) {
      if (spec.startsWith('.')) walk(resolveRelative(file, spec));
      else if (!RUNTIME_PROVIDED(spec)) missing.add(spec);
    }
  };
  walk(path.join(SRC, entry));
  return [...missing].sort();
}

describe('what the Lambda bundle lacks at run time', () => {
  test('the API function needs nothing the runtime does not provide', () => {
    expect(missingAtRuntime('http/lambda.ts')).toEqual([]);
  });

  test('the index writer needs nothing the runtime does not provide', () => {
    expect(missingAtRuntime('publish/indexer-lambda.ts')).toEqual([]);
  });

  test('the validator requires fzstd, which the bundle does not contain (known defect, see the comment above)', () => {
    expect(missingAtRuntime('publish/validator-lambda.ts')).toEqual(['fzstd']);
  });

  test('the walk sees what it should: the validator reaches the zstd reader through the validate package', () => {
    // A walk that found nothing would pass the first two tests for the wrong reason.
    const seen: string[] = [];
    const walk = (file: string) => {
      if (seen.includes(file)) return;
      seen.push(file);
      for (const spec of compiledRequires(file)) if (spec.startsWith('.')) walk(resolveRelative(file, spec));
    };
    walk(path.join(SRC, 'publish/validator-lambda.ts'));
    const rel = seen.map((f) => path.relative(SRC, f));
    expect(rel).toEqual(expect.arrayContaining(['publish/validator.ts', 'validate/index.ts', 'validate/zstd-read.ts', 'publish/wiring.ts']));
    expect(seen.length).toBeGreaterThan(15);
  });
});
