// Test helper: runs buildSite on a small stand-in for tsc's browser output (the real one exists only after
// `npm run build`, and the tests run before it), with the real stylesheet and the real repository docs.
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
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
};

export interface Fixture {
  root: string;
  browserDir: string;
  staticDir: string;
  outDir: string;
  build(): { id: string; files: string[] };
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
