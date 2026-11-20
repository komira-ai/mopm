// guide/editor.ts, the author's guide's editor snippet (docs/tutorial-author-guide.md), against a fake of the SDK's
// files module: listing skips the synced environment and symlinks and stops at the depth limit, a missing file reads
// as null, saving is one request, and reading the project back skips large files.
import { FileNotFoundError, FileType, SandboxNotRunningError, type EntryInfo, type Sandbox } from 'e2b';
import { lessonDir, listProject, LESSONS_DIR, openFile, readProject, saveFiles } from '../guide/editor';

type Tree = { [name: string]: string | Tree | { link: string } };

function entry(dir: string, name: string, type: FileType, size: number): EntryInfo {
  return { name, type, path: `${dir}/${name}`, size, mode: 0o644, permissions: 'rw-r--r--', owner: 'user', group: 'user' };
}

/** A sandbox whose files module serves `tree` under `root` and records what it was asked. */
function fakeFiles(root: string, tree: Tree) {
  const listed: string[] = [];
  const written: unknown[] = [];
  const at = (path: string): string | Tree | { link: string } | undefined => {
    if (path === root) return tree;
    if (!path.startsWith(`${root}/`)) return undefined;
    let node: string | Tree | { link: string } | undefined = tree;
    for (const part of path.slice(root.length + 1).split('/')) {
      node = typeof node === 'object' && !('link' in node) ? (node as Tree)[part] : undefined;
    }
    return node;
  };
  const files = {
    async list(path: string, opts: { depth: number }): Promise<EntryInfo[]> {
      expect(opts).toEqual({ depth: 1 });
      listed.push(path);
      const node = at(path) as Tree;
      return Object.keys(node).map((name) => {
        const v = node[name];
        if (typeof v === 'string') return entry(path, name, FileType.FILE, v.length);
        if ('link' in v) return entry(path, name, FileType.SYMLINK, 0);
        return entry(path, name, FileType.DIR, 4096);
      });
    },
    async read(path: string): Promise<string> {
      const node = at(path);
      if (typeof node !== 'string') throw new FileNotFoundError(`${path} not found`);
      return node;
    },
    async write(entries: unknown): Promise<unknown> {
      written.push(entries);
      return [];
    },
  };
  return { sandbox: { files } as unknown as Sandbox, listed, written };
}

const DIR = lessonDir('hello');

const PROJECT: Tree = {
  'mopm.toml': '[package]\n',
  'mopm.lock': '{}\n',
  '.mopm': { env: { 'big.so': 'x'.repeat(10) } },
  src: { 'main.mojo': 'def main():\n    print("hi")\n', deep: { a: { b: { 'c.mojo': 'c' } } } },
  latest: { link: 'src' },
};

test('the lesson directory is where the template puts the lesson', () => {
  expect(LESSONS_DIR).toBe('/home/user/lessons');
  expect(DIR).toBe('/home/user/lessons/hello');
});

describe('listProject', () => {
  test('lists files by relative path, sorted, without .mopm or symlinks', async () => {
    const f = fakeFiles(DIR, PROJECT);
    expect((await listProject(f.sandbox, DIR)).map((e) => e.path)).toEqual([
      'mopm.lock',
      'mopm.toml',
      'src/deep/a/b/c.mojo',
      'src/main.mojo',
    ]);
    expect(f.listed).not.toContain(`${DIR}/.mopm`);
  });

  test('stops descending at maxDepth', async () => {
    const f = fakeFiles(DIR, PROJECT);
    expect((await listProject(f.sandbox, DIR, 2)).map((e) => e.path)).toEqual(['mopm.lock', 'mopm.toml', 'src/main.mojo']);
    expect(f.listed).toEqual([DIR, `${DIR}/src`]);
  });

  test('gives each file its size', async () => {
    const f = fakeFiles(DIR, { 'a.txt': 'abc' });
    expect(await listProject(f.sandbox, DIR)).toEqual([{ path: 'a.txt', size: 3 }]);
  });
});

describe('openFile', () => {
  test('reads a file by its relative path', async () => {
    const f = fakeFiles(DIR, PROJECT);
    expect(await openFile(f.sandbox, DIR, 'src/main.mojo')).toBe('def main():\n    print("hi")\n');
  });

  test('a missing file is null', async () => {
    const f = fakeFiles(DIR, PROJECT);
    expect(await openFile(f.sandbox, DIR, 'src/gone.mojo')).toBeNull();
  });

  test('any other error is thrown', async () => {
    const sandbox = {
      files: {
        read: async () => {
          throw new SandboxNotRunningError('gone');
        },
      },
    } as unknown as Sandbox;
    await expect(openFile(sandbox, DIR, 'src/main.mojo')).rejects.toBeInstanceOf(SandboxNotRunningError);
  });
});

describe('saveFiles', () => {
  test('writes every file in one request, at its path in the lesson', async () => {
    const f = fakeFiles(DIR, {});
    await saveFiles(f.sandbox, DIR, [
      { path: 'src/main.mojo', text: 'def main():\n    pass\n' },
      { path: 'notes.txt', text: '' },
    ]);
    expect(f.written).toEqual([
      [
        { path: `${DIR}/src/main.mojo`, data: 'def main():\n    pass\n' },
        { path: `${DIR}/notes.txt`, data: '' },
      ],
    ]);
  });

  test('nothing to save makes no request', async () => {
    const f = fakeFiles(DIR, {});
    await saveFiles(f.sandbox, DIR, []);
    expect(f.written).toEqual([]);
  });
});

describe('readProject', () => {
  test('reads every listed file up to maxBytes, skipping larger ones', async () => {
    const f = fakeFiles(DIR, { 'small.txt': 'ab', 'large.txt': 'abcd', 'edge.txt': 'abc' });
    expect(await readProject(f.sandbox, DIR, 3)).toEqual([
      { path: 'edge.txt', text: 'abc' },
      { path: 'small.txt', text: 'ab' },
    ]);
  });

  test('a file removed between the listing and the read is left out', async () => {
    const f = fakeFiles(DIR, { 'a.txt': 'a', 'b.txt': 'b' });
    const files = (f.sandbox as unknown as { files: { read: (p: string) => Promise<string> } }).files;
    const read = files.read;
    files.read = async (p: string) => {
      if (p.endsWith('/a.txt')) throw new FileNotFoundError('deleted');
      return read(p);
    };
    expect(await readProject(f.sandbox, DIR)).toEqual([{ path: 'b.txt', text: 'b' }]);
  });
});
