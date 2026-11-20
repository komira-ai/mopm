// Test helper: a small stand-in for the repository, in a fresh directory under this package's build/test-scratch
// (gitignored): VERSION and tutorial/lessons/<id>/project with mopm.toml, mopm.lock and a source file.
import { mkdirSync, mkdtempSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';

const SCRATCH = join(__dirname, '..', 'build', 'test-scratch');

/** The real repository root (this package is tutorial/template; under Buck2 the files read are staged as `data`). */
export const REPO_ROOT = join(__dirname, '..', '..', '..');

export interface Repo {
  root: string;
  write(path: string, text: string): void;
  addLesson(id: string): void;
}

export function fixtureRepo(version: string, lessons: string[]): Repo {
  mkdirSync(SCRATCH, { recursive: true });
  const root = mkdtempSync(join(SCRATCH, 'r-'));
  const write = (path: string, text: string) => {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), text);
  };
  const addLesson = (id: string) => {
    write(`tutorial/lessons/${id}/lesson.json`, '{}\n');
    write(`tutorial/lessons/${id}/project/mopm.toml`, `[package]\nname = "tutorial/${id}"\n`);
    write(`tutorial/lessons/${id}/project/mopm.lock`, '{}\n');
    write(`tutorial/lessons/${id}/project/src/main.mojo`, 'def main():\n    print("hi")\n');
  };
  write('VERSION', `${version}\n`);
  mkdirSync(join(root, 'tutorial', 'lessons'), { recursive: true });
  lessons.forEach(addLesson);
  return { root, write, addLesson };
}
