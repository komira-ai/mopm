import { readdirSync, rmSync, statSync } from 'fs';
import { join } from 'path';
import { describe as describeSteps, steps, templateDefinition } from '../src/definition';
import { listLessons, readBase, releaseOf } from '../src/inputs';
import { fixtureRepo, REPO_ROOT } from './fixture';

/** The definition of a repository, as the command builds it with a release of its VERSION's base. */
function definitionOf(root: string, patch: number) {
  return templateDefinition({ repoRoot: root, lessons: listLessons(root), mopmVersion: releaseOf(readBase(root), `${readBase(root)}.${patch}`) });
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
      { type: 'COPY', args: ['site/static/install.sh', '/opt/mopm-install/install.sh', 'root', '0755'] },
      { type: 'RUN', args: ['MOPM_VERSION=0.3.7 MOPM_HOME=/usr/local sh /opt/mopm-install/install.sh && rm /opt/mopm-install/install.sh', 'root'] },
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
  const install = async () => (await steps(definitionOf(repo.root, 4))).steps[1].args[0];
  expect(await install()).toMatch(/^MOPM_VERSION=0\.0\.4 /);
  repo.write('VERSION', '2.5\n');
  expect(await install()).toMatch(/^MOPM_VERSION=2\.5\.4 /);
  expect(() => releaseOf(readBase(repo.root), '0.0.4')).toThrow('mopm 0.0.4 is not a release of 2.5, the base in VERSION');
});

test('this repository: the definition copies exactly the lesson directories of tutorial/lessons, with mopm of VERSION', async () => {
  const dirs = readdirSync(join(REPO_ROOT, 'tutorial/lessons'))
    .filter((d) => statSync(join(REPO_ROOT, 'tutorial/lessons', d)).isDirectory())
    .sort();
  expect(dirs.length).toBeGreaterThan(0);
  expect(await copiedLessons(REPO_ROOT)).toEqual(dirs);
  const base = readBase(REPO_ROOT);
  const install = (await steps(definitionOf(REPO_ROOT, 1))).steps[1].args[0];
  expect(install.startsWith(`MOPM_VERSION=${base}.1 `)).toBe(true);
});

test('the dry run lines: E2B Dockerfile form with the owner of each COPY and the user of each RUN', async () => {
  const repo = fixtureRepo('0.0', ['hello']);
  expect(await describeSteps(definitionOf(repo.root, 2))).toEqual([
    'FROM e2bdev/base',
    'COPY site/static/install.sh /opt/mopm-install/install.sh (owner root)',
    'RUN MOPM_VERSION=0.0.2 MOPM_HOME=/usr/local sh /opt/mopm-install/install.sh && rm /opt/mopm-install/install.sh (as root)',
    'COPY tutorial/lessons/hello/project /home/user/lessons/hello/ (owner user)',
    'WORKDIR /home/user/lessons/hello',
    'RUN mopm sync --locked --cache /home/user/.cache/mopm/pkgs (as user)',
    'WORKDIR /home/user',
    'USER user',
  ]);
});
