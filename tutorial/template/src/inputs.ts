// The two inputs of the template that come from the repository: the lessons under tutorial/lessons, and the base
// MAJOR.MINOR of the mopm release, read from the VERSION file the release tooling reads (RELEASING.md, "How the
// version is computed"). Nothing here is a second copy of either.
import { existsSync, readdirSync, readFileSync, statSync } from 'fs';
import { join } from 'path';

/** A lesson id, as tutorial/README.md defines it: lower-case letters and digits in words joined by single hyphens. */
const LESSON_ID = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

/** The files `mopm sync --locked` needs in a lesson's project: the manifest and the lock `mopm lock` wrote. */
const PROJECT_FILES = ['mopm.toml', 'mopm.lock'];

/**
 * The ids of the lessons under `<repoRoot>/tutorial/lessons`, sorted, so the definition is the same on every machine.
 * Each entry must be a directory with a valid id and a project/ holding mopm.toml and mopm.lock. Anything else is
 * refused with an error naming it rather than skipped, so a lesson can never silently drop out of the template.
 */
export function listLessons(repoRoot: string): string[] {
  const dir = join(repoRoot, 'tutorial', 'lessons');
  if (!existsSync(dir)) throw new Error(`no lessons: ${dir} does not exist`);
  const ids = readdirSync(dir).sort();
  for (const id of ids) {
    const lesson = join(dir, id);
    if (!statSync(lesson).isDirectory()) throw new Error(`tutorial/lessons/${id} is not a directory`);
    if (!LESSON_ID.test(id)) {
      throw new Error(`tutorial/lessons/${id}: a lesson id is lower-case letters and digits in words joined by single hyphens`);
    }
    for (const f of PROJECT_FILES) {
      if (!existsSync(join(lesson, 'project', f))) throw new Error(`tutorial/lessons/${id}/project/${f} is missing`);
    }
  }
  if (ids.length === 0) throw new Error(`no lessons: ${dir} is empty`);
  return ids;
}

/** The base of the mopm release, `MAJOR.MINOR`, from `<repoRoot>/VERSION`. */
export function readBase(repoRoot: string): string {
  const text = readFileSync(join(repoRoot, 'VERSION'), 'utf8').trim();
  if (!/^\d+\.\d+$/.test(text)) throw new Error(`VERSION holds '${text}', not MAJOR.MINOR`);
  return text;
}

/**
 * Checks that `version` (X.Y.Z, or a tag vX.Y.Z) is a release of `base`, and returns it without the `v`.
 * The release tooling numbers releases `v<base>.<patch>`, so only those belong to this repository's VERSION.
 */
export function releaseOf(base: string, version: string): string {
  const v = version.startsWith('v') ? version.slice(1) : version;
  const m = /^(\d+\.\d+)\.\d+$/.exec(v);
  if (!m) throw new Error(`'${version}' is not a mopm release version (X.Y.Z)`);
  if (m[1] !== base) throw new Error(`mopm ${v} is not a release of ${base}, the base in VERSION`);
  return v;
}
