// Test helper: runs buildSite on a small stand-in for tsc's browser output (the real one exists only after
// `npm run build`, and the tests run before it), with the real stylesheet, the real repository docs and, unless a test
// gives its own (lessonTree), the real lessons. The stand-in's tutorial/runner.js imports only a small module of its
// own, not e2b, so the tutorial bundle esbuild makes of it is small; realBrowserFiles() is the whole of src/ as tsc
// would write it, for the tests of the real bundle.
import { cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'fs';
import { dirname, join, relative, sep } from 'path';
import { ModuleKind, ScriptTarget, transpileModule } from 'typescript';
import { buildSite } from '../tools/build';

const SITE = join(__dirname, '..');
export const REPO_ROOT = join(SITE, '..');
export const LESSONS_DIR = join(REPO_ROOT, 'tutorial', 'lessons');
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
  lessonsDir: string;
  outDir: string;
  heldDir: string;
  build(): { id: string; files: string[]; held: string[]; tutorialBytes: number };
}

/** A fresh scratch directory under site/build/test-scratch. */
export function scratch(prefix: string): string {
  mkdirSync(SCRATCH, { recursive: true });
  return mkdtempSync(join(SCRATCH, prefix));
}

/** A fresh directory with a browser output and a copy of static/; `files` overrides or adds browser files. */
export function fixture(files: Record<string, string> = {}, lessonsDir: string = LESSONS_DIR): Fixture {
  const root = scratch('b-');
  const browserDir = join(root, 'browser');
  const staticDir = join(root, 'static');
  const outDir = join(root, 'dist');
  const heldDir = join(root, 'held');
  for (const [p, s] of Object.entries({ ...BROWSER_FILES, ...files })) {
    mkdirSync(dirname(join(browserDir, p)), { recursive: true });
    writeFileSync(join(browserDir, p), s);
  }
  cpSync(join(SITE, 'static'), staticDir, { recursive: true });
  return {
    root,
    browserDir,
    staticDir,
    lessonsDir,
    outDir,
    heldDir,
    build: () => buildSite({ browserDir, staticDir, repoRoot: REPO_ROOT, lessonsDir, outDir, heldDir }),
  };
}

/** One lesson of a lessonTree: lesson.json (an object, or text as it is), lesson.md, and the files under project/. */
export interface LessonFiles {
  json?: object | string;
  md?: string;
  project?: string[];
}

/** A valid lesson.json, for tests to change one field of. */
export function lessonJson(order: number, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    title: `Lesson ${order}`,
    summary: `What lesson ${order} teaches.`,
    order,
    editable: ['src/main.mojo'],
    actions: { run: 'mopm run src/main.mojo' },
    ...extra,
  };
}

/**
 * A scratch tutorial/lessons with these lessons, by id: a lesson leaves out lesson.json or lesson.md when its field is
 * undefined. The result is the directory; its parent is the scratch directory to remove.
 */
export function lessonTree(lessons: Record<string, LessonFiles>): string {
  const dir = join(scratch('l-'), 'lessons');
  mkdirSync(dir);
  for (const [id, l] of Object.entries(lessons)) {
    const d = join(dir, id);
    mkdirSync(d);
    if (l.json !== undefined) writeFileSync(join(d, 'lesson.json'), typeof l.json === 'string' ? l.json : JSON.stringify(l.json));
    if (l.md !== undefined) writeFileSync(join(d, 'lesson.md'), l.md);
    for (const p of l.project ?? []) {
      mkdirSync(dirname(join(d, 'project', p)), { recursive: true });
      writeFileSync(join(d, 'project', p), `# ${p}\n`);
    }
  }
  return dir;
}

/** A valid lesson for lessonTree. */
export function goodLesson(order: number, extra: Record<string, unknown> = {}): LessonFiles {
  return { json: lessonJson(order, extra), md: `Lesson ${order}'s text.\n`, project: ['src/main.mojo'] };
}

export function cleanup(f: Fixture): void {
  rmSync(f.root, { recursive: true, force: true });
}
