import { mkdirSync, rmSync } from 'fs';
import { join } from 'path';
import { listLessons, readBase, releaseOf } from '../src/inputs';
import { fixtureRepo } from './fixture';

describe('listLessons', () => {
  test('every lesson directory, sorted, and a new one appears', () => {
    const repo = fixtureRepo('0.0', ['b-two', 'a1']);
    expect(listLessons(repo.root)).toEqual(['a1', 'b-two']);
    repo.addLesson('c');
    expect(listLessons(repo.root)).toEqual(['a1', 'b-two', 'c']);
  });

  test('a removed lesson is gone', () => {
    const repo = fixtureRepo('0.0', ['a', 'b']);
    rmSync(join(repo.root, 'tutorial/lessons/a'), { recursive: true });
    expect(listLessons(repo.root)).toEqual(['b']);
  });

  test('a file under tutorial/lessons is refused, not skipped', () => {
    const repo = fixtureRepo('0.0', ['a']);
    repo.write('tutorial/lessons/notes.txt', 'x');
    expect(() => listLessons(repo.root)).toThrow('tutorial/lessons/notes.txt is not a directory');
  });

  test.each(['Hello', 'a--b', '-a', 'a-', 'a_b', 'a.b'])('the id %s is refused', (id) => {
    const repo = fixtureRepo('0.0', [id]);
    expect(() => listLessons(repo.root)).toThrow(
      `tutorial/lessons/${id}: a lesson id is lower-case letters and digits in words joined by single hyphens`,
    );
  });

  test.each(['mopm.toml', 'mopm.lock'])('a project without %s is refused', (f) => {
    const repo = fixtureRepo('0.0', ['a']);
    rmSync(join(repo.root, 'tutorial/lessons/a/project', f));
    expect(() => listLessons(repo.root)).toThrow(`tutorial/lessons/a/project/${f} is missing`);
  });

  test('a lesson without project/ is refused', () => {
    const repo = fixtureRepo('0.0', []);
    mkdirSync(join(repo.root, 'tutorial/lessons/a'));
    expect(() => listLessons(repo.root)).toThrow('tutorial/lessons/a/project/mopm.toml is missing');
  });

  test('no lessons at all is refused', () => {
    const repo = fixtureRepo('0.0', []);
    expect(() => listLessons(repo.root)).toThrow(`no lessons: ${join(repo.root, 'tutorial', 'lessons')} is empty`);
    rmSync(join(repo.root, 'tutorial'), { recursive: true });
    expect(() => listLessons(repo.root)).toThrow(`no lessons: ${join(repo.root, 'tutorial', 'lessons')} does not exist`);
  });
});

describe('readBase', () => {
  test('MAJOR.MINOR, with the newline trimmed', () => {
    expect(readBase(fixtureRepo('0.0', []).root)).toBe('0.0');
    expect(readBase(fixtureRepo('12.34', []).root)).toBe('12.34');
  });

  test.each(['0.0.1', '1', 'v0.0', ''])('VERSION holding %j is refused', (v) => {
    expect(() => readBase(fixtureRepo(v, []).root)).toThrow(`VERSION holds '${v}', not MAJOR.MINOR`);
  });
});

describe('releaseOf', () => {
  test('a release of the base, with or without the v', () => {
    expect(releaseOf('0.3', '0.3.7')).toBe('0.3.7');
    expect(releaseOf('0.3', 'v0.3.17')).toBe('0.3.17');
  });

  test('a release of another base is refused', () => {
    expect(() => releaseOf('0.3', '0.4.1')).toThrow('mopm 0.4.1 is not a release of 0.3, the base in VERSION');
    expect(() => releaseOf('0.3', '0.30.1')).toThrow('mopm 0.30.1 is not a release of 0.3, the base in VERSION');
  });

  test.each(['0.3', '0.3.7-rc1', '0.3.x', 'latest', '0.3.7; rm -r /', ''])('%j is not a version', (v) => {
    expect(() => releaseOf('0.3', v)).toThrow(`'${v}' is not a mopm release version (X.Y.Z)`);
  });
});
