// Test helper: runs buildSite on a small stand-in for tsc's browser output (the real one exists only after
// `npm run build`, and the tests run before it), with the real stylesheet and the real repository docs. The stand-in's
// tutorial/runner.js imports only a small module of its own, not e2b, so the tutorial bundle esbuild makes of it is
// small; realBrowserFiles() is the whole of src/ as tsc would write it, for the tests of the real bundle.
import { cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'fs';
import { dirname, join, relative, sep } from 'path';
import { ModuleKind, ScriptTarget, transpileModule } from 'typescript';
import { buildSite } from '../tools/build';

const SITE = join(__dirname, '..');
export const REPO_ROOT = join(SITE, '..');
const SCRATCH = join(SITE, 'build', 'test-scratch');

export const BROWSER_FILES: Record<string, string> = {
  'main.js': "import { a } from './a.js';\nimport('./lazy/b.js');\nexport const m = a;\n",
  'a.js': "import { c } from './lazy/c.js';\nexport const a = c;\n",
  'lazy/b.js': 'export const b = 2;\n',
  'lazy/c.js': 'export const c = 3;\n',
  'unused.js': 'export const u = 4;\n',
  'tutorial/runner.js': "import { r } from './r.js';\nexport const runner = r;\n",
  'tutorial/r.js': 'export const r = 5;\n',
  'tutorial/node-stub.js': '"use strict";\n',
};

/** Every module of src/ as tsc -p tsconfig.browser.json writes it (types erased, ES2022 modules), by path under it. */
export function realBrowserFiles(): Record<string, string> {
  const src = join(SITE, 'src');
  const out: Record<string, string> = {};
  const walk = (d: string): void => {
    for (const f of readdirSync(d)) {
      const p = join(d, f);
      if (statSync(p).isDirectory()) walk(p);
      else if (f.endsWith('.ts')) {
        const js = transpileModule(readFileSync(p, 'utf8'), { compilerOptions: { module: ModuleKind.ES2022, target: ScriptTarget.ES2022, removeComments: true } });
        out[relative(src, p).split(sep).join('/').replace(/\.ts$/, '.js')] = js.outputText;
      }
    }
  };
  walk(src);
  return out;
}

export interface Fixture {
  root: string;
  browserDir: string;
  staticDir: string;
  outDir: string;
  build(): { id: string; files: string[]; tutorialBytes: number };
}

/** A fresh directory with a browser output and a copy of static/; `files` overrides or adds browser files. */
export function fixture(files: Record<string, string> = {}): Fixture {
  mkdirSync(SCRATCH, { recursive: true });
  const root = mkdtempSync(join(SCRATCH, 'b-'));
  const browserDir = join(root, 'browser');
  const staticDir = join(root, 'static');
  const outDir = join(root, 'dist');
  for (const [p, s] of Object.entries({ ...BROWSER_FILES, ...files })) {
    mkdirSync(dirname(join(browserDir, p)), { recursive: true });
    writeFileSync(join(browserDir, p), s);
  }
  cpSync(join(SITE, 'static'), staticDir, { recursive: true });
  return { root, browserDir, staticDir, outDir, build: () => buildSite({ browserDir, staticDir, repoRoot: REPO_ROOT, outDir }) };
}

export function cleanup(f: Fixture): void {
  rmSync(f.root, { recursive: true, force: true });
}
