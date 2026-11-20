import { spawnSync } from 'child_process';
import { readdirSync, rmSync, statSync } from 'fs';
import { join } from 'path';
import { describe as describeSteps, installCommand, steps, templateDefinition } from '../src/definition';
import { listLessons, readBase, releaseOf } from '../src/inputs';
import { fixtureRepo, REPO_ROOT } from './fixture';

const SHA = '0123456789abcdef'.repeat(4);

/** The definition of a repository, as the command builds it with a release of its VERSION's base. */
function definitionOf(root: string, patch: number) {
  const version = releaseOf(readBase(root), `${readBase(root)}.${patch}`);
  return templateDefinition({ repoRoot: root, lessons: listLessons(root), mopm: { version, sha256: SHA } });
}

/** The lesson ids the definition copies to /home/user/lessons/<id>/. */
async function copiedLessons(root: string): Promise<string[]> {
  const { steps: all } = await steps(definitionOf(root, 1));
  return all.filter((s) => s.type === 'COPY' && s.args[1].startsWith('/home/user/lessons/')).map((s) => s.args[1].split('/')[4]);
}

test('the whole definition, step by step', async () => {
  const repo = fixtureRepo('0.3', ['hello', 'structs-2']);
  expect(await steps(definitionOf(repo.root, 7))).toEqual({
    fromImage: 'e2bdev/base',
    steps: [
      { type: 'RUN', args: [installCommand({ version: '0.3.7', sha256: SHA }), 'root'] },
      { type: 'COPY', args: ['tutorial/lessons/hello/project', '/home/user/lessons/hello/', 'user', ''] },
      { type: 'WORKDIR', args: ['/home/user/lessons/hello'] },
      { type: 'RUN', args: ['mopm sync --locked --cache /home/user/.cache/mopm/pkgs', 'user'] },
      { type: 'COPY', args: ['tutorial/lessons/structs-2/project', '/home/user/lessons/structs-2/', 'user', ''] },
      { type: 'WORKDIR', args: ['/home/user/lessons/structs-2'] },
      { type: 'RUN', args: ['mopm sync --locked --cache /home/user/.cache/mopm/pkgs', 'user'] },
      { type: 'WORKDIR', args: ['/home/user'] },
      { type: 'USER', args: ['user'] },
    ],
  });
});

test('every lesson under tutorial/lessons is in the definition, a new one appears and a removed one goes', async () => {
  const repo = fixtureRepo('0.0', ['hello']);
  expect(await copiedLessons(repo.root)).toEqual(['hello']);
  repo.addLesson('loops');
  expect(await copiedLessons(repo.root)).toEqual(['hello', 'loops']);
  rmSync(join(repo.root, 'tutorial/lessons/hello'), { recursive: true });
  expect(await copiedLessons(repo.root)).toEqual(['loops']);
});

test('the mopm version follows VERSION: a release of another base cannot be put in', async () => {
  const repo = fixtureRepo('0.0', ['hello']);
  const install = async () => (await steps(definitionOf(repo.root, 4))).steps[0].args[0];
  expect(await install()).toBe(installCommand({ version: '0.0.4', sha256: SHA }));
  repo.write('VERSION', '2.5\n');
  expect(await install()).toBe(installCommand({ version: '2.5.4', sha256: SHA }));
  expect(() => releaseOf(readBase(repo.root), '0.0.4')).toThrow('mopm 0.0.4 is not a release of 2.5, the base in VERSION');
});

test('the install step: the release file, checked against its sha256, its binary on PATH, the version checked', () => {
  expect(installCommand({ version: '0.3.7', sha256: SHA }).split(' && ')).toEqual([
    'mkdir -p /opt/mopm-install',
    'curl -fsSL --retry 3 -o /opt/mopm-install/mopm-0.3.7-linux-x86_64.tar.gz https://github.com/komira-ai/mopm/releases/download/v0.3.7/mopm-0.3.7-linux-x86_64.tar.gz',
    `echo "${SHA}  /opt/mopm-install/mopm-0.3.7-linux-x86_64.tar.gz" | sha256sum -c -`,
    'tar -xzf /opt/mopm-install/mopm-0.3.7-linux-x86_64.tar.gz -C /opt/mopm-install',
    'install -m 0755 /opt/mopm-install/mopm-0.3.7-linux-x86_64/mopm /usr/local/bin/mopm',
    'rm -r /opt/mopm-install',
    'test "$(mopm --version)" = "mopm 0.3.7"',
  ]);
});

test('this repository: the definition copies exactly the lesson directories of tutorial/lessons, with mopm of VERSION', async () => {
  const dirs = readdirSync(join(REPO_ROOT, 'tutorial/lessons'))
    .filter((d) => statSync(join(REPO_ROOT, 'tutorial/lessons', d)).isDirectory())
    .sort();
  expect(dirs.length).toBeGreaterThan(0);
  expect(await copiedLessons(REPO_ROOT)).toEqual(dirs);
  const base = readBase(REPO_ROOT);
  const install = (await steps(definitionOf(REPO_ROOT, 1))).steps[0].args[0];
  expect(install).toBe(installCommand({ version: `${base}.1`, sha256: SHA }));
});

test('the dry run lines: E2B Dockerfile form with the owner of each COPY and the user of each RUN', async () => {
  const repo = fixtureRepo('0.0', ['hello']);
  expect(await describeSteps(definitionOf(repo.root, 2))).toEqual([
    'FROM e2bdev/base',
    `RUN ${installCommand({ version: '0.0.2', sha256: SHA })} (as root)`,
    'COPY tutorial/lessons/hello/project /home/user/lessons/hello/ (owner user)',
    'WORKDIR /home/user/lessons/hello',
    'RUN mopm sync --locked --cache /home/user/.cache/mopm/pkgs (as user)',
    'WORKDIR /home/user',
    'USER user',
  ]);
});

/** E2B's own file selection for each COPY step (test/upload-hashes.ts, in a child Node process: see there why). */
function uploadHashes(root: string): { src: string; filesHash: string }[] {
  const r = spawnSync(process.execPath, ['-r', 'ts-node/register/transpile-only', join(__dirname, 'upload-hashes.ts'), root], {
    cwd: join(__dirname, '..'),
    encoding: 'utf8',
  });
  expect(r.stderr).toBe('');
  expect(r.status).toBe(0);
  return JSON.parse(r.stdout) as { src: string; filesHash: string }[];
}

test("E2B's upload: every project file is selected and a lesson's .mopm/ is not", () => {
  const repo = fixtureRepo('0.0', ['hello']);
  const before = uploadHashes(repo.root);
  expect(before.map((h) => h.src)).toEqual(['tutorial/lessons/hello/project']);
  expect(before[0].filesHash).toMatch(/^[0-9a-f]{64}$/);

  // What `mopm sync` writes in the project on the operator's machine: not selected, so the hash does not move.
  repo.write('tutorial/lessons/hello/project/.mopm/env/bin/mojo', 'a local toolchain');
  repo.write('tutorial/lessons/hello/project/.mopm/sync.lock', '');
  repo.write('tutorial/lessons/hello/project/src/.mopm/stray', 'x');
  expect(uploadHashes(repo.root)).toEqual(before);

  // A changed project file and a new one are selected.
  repo.write('tutorial/lessons/hello/project/src/main.mojo', 'def main():\n    print("changed")\n');
  const changed = uploadHashes(repo.root);
  expect(changed[0].filesHash).not.toBe(before[0].filesHash);
  repo.write('tutorial/lessons/hello/project/src/extra.mojo', 'fn f(): pass\n');
  expect(uploadHashes(repo.root)[0].filesHash).not.toBe(changed[0].filesHash);
});
