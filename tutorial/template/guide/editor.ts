// tutorial/template/guide/editor.ts
// The editor's side of the sandbox: list a lesson's files, open one, save the editor's files, and read the whole
// project back (to carry files made in the terminal over to a new sandbox).
import { FileType, NotFoundError, type Sandbox } from 'e2b';

/** Where the template puts each lesson (LESSONS_DIR of tutorial/template/src/definition.ts). */
export const LESSONS_DIR = '/home/user/lessons';

/** The lesson's directory in the sandbox: its project/, synced. */
export function lessonDir(id: string): string {
  return `${LESSONS_DIR}/${id}`;
}

/** Never listed: the lesson's synced environment (`mopm sync` writes it; thousands of files). */
const SKIPPED = new Set(['.mopm']);

/** A file of the lesson, by its path relative to the lesson's directory. */
export interface ProjectEntry {
  path: string;
  size: number;
}

export interface ProjectFile {
  path: string;
  text: string;
}

/** The lesson's files below `dir`, at most `maxDepth` directories deep, sorted by path. Symlinks are left out. */
export async function listProject(s: Sandbox, dir: string, maxDepth = 6): Promise<ProjectEntry[]> {
  const out: ProjectEntry[] = [];
  const walk = async (at: string, rel: string, depth: number): Promise<void> => {
    for (const e of await s.files.list(at, { depth: 1 })) {
      if (SKIPPED.has(e.name)) continue;
      const path = rel === '' ? e.name : `${rel}/${e.name}`;
      if (e.type === FileType.FILE) out.push({ path, size: e.size });
      else if (e.type === FileType.DIR && depth > 1) await walk(e.path, path, depth - 1);
    }
  };
  await walk(dir, '', maxDepth);
  // Paths are unique, so two entries never compare equal.
  return out.sort((a, b) => (a.path < b.path ? -1 : 1));
}

/** One file's text, or null when it does not exist (deleted in the terminal, or a new sandbox without it). */
export async function openFile(s: Sandbox, dir: string, path: string): Promise<string | null> {
  try {
    return await s.files.read(`${dir}/${path}`);
  } catch (e) {
    if (e instanceof NotFoundError) return null;
    throw e;
  }
}

/** Writes the files in one request; missing directories are created. */
export async function saveFiles(s: Sandbox, dir: string, files: readonly ProjectFile[]): Promise<void> {
  if (files.length === 0) return;
  await s.files.write(files.map((f) => ({ path: `${dir}/${f.path}`, data: f.text })));
}

/** Every file of the project up to `maxBytes` each, as text: what to write into the next sandbox. */
export async function readProject(s: Sandbox, dir: string, maxBytes = 256 * 1024): Promise<ProjectFile[]> {
  const out: ProjectFile[] = [];
  for (const e of await listProject(s, dir)) {
    if (e.size > maxBytes) continue;
    const text = await openFile(s, dir, e.path);
    if (text !== null) out.push({ path: e.path, text });
  }
  return out;
}
