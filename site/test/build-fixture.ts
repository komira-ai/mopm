// Test helper: runs buildSite on a small stand-in for tsc's browser output (the real one exists only after
// `npm run build`, and the tests run before it), with the real stylesheet, the real repository docs and, unless a test
// gives its own (lessonTree), the real lessons.
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
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
};

export interface Fixture {
  root: string;
  browserDir: string;
  staticDir: string;
  lessonsDir: string;
  outDir: string;
  heldDir: string;
  build(): { id: string; files: string[]; held: string[] };
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
