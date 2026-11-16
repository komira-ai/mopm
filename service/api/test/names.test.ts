import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { BUILTINS, condaNameOf, importNameProblem, isFullName, KEYWORDS, NAME_PATTERN, RESERVED_NAMES, splitFullName, STD_MODULES } from '../src/names';

const REPO = resolve(__dirname, '../../..');
const TOOLCHAIN = resolve(REPO, 'toolchain');
const NAMES_ZIG = resolve(REPO, 'src/core/names.zig');

/** The non-blank, non-comment lines of a text file. */
const dataLines = (text: string): string[] =>
  text
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l !== '' && !l.startsWith('#'));

/** The string literals of `const <name> = [_][]const u8{ ... };` in names.zig, in file order. */
function zigStrings(source: string, name: string): string[] {
  const m = new RegExp(`const ${name} = \\[_\\]\\[\\]const u8\\{([^}]*)\\};`).exec(source);
  if (!m) throw new Error(`src/core/names.zig has no array \`${name}\``);
  return [...m[1]!.matchAll(/"([^"]*)"/g)].map((x) => x[1]!);
}

describe('the lists of src/names.ts are the lists the command line uses', () => {
  const zig = readFileSync(NAMES_ZIG, 'utf8');

  test('STD_MODULES is the union of toolchain/mojo-<version>.std-modules.txt over toolchain/versions.txt', () => {
    const versions = dataLines(readFileSync(resolve(TOOLCHAIN, 'versions.txt'), 'utf8'));
    expect(versions.length).toBeGreaterThan(0);
    const union = new Set<string>();
    for (const v of versions) {
      const file = resolve(TOOLCHAIN, `mojo-${v}.std-modules.txt`);
      if (!existsSync(file)) throw new Error(`toolchain/versions.txt lists Mojo ${v} but ${file} does not exist`);
      const modules = dataLines(readFileSync(file, 'utf8'));
      expect(modules.length).toBeGreaterThan(0);
      for (const m of modules) union.add(m);
    }
    expect([...STD_MODULES].sort()).toEqual([...union].sort());
    expect(new Set(STD_MODULES).size).toBe(STD_MODULES.length);
  });

  test('KEYWORDS equals the keywords array of src/core/names.zig', () => {
    expect(zigStrings(zig, 'keywords').length).toBeGreaterThan(40);
    expect([...KEYWORDS].sort()).toEqual(zigStrings(zig, 'keywords').sort());
  });

  test('BUILTINS equals the builtins array of src/core/names.zig', () => {
    expect(zigStrings(zig, 'builtins').length).toBeGreaterThan(20);
    expect([...BUILTINS].sort()).toEqual(zigStrings(zig, 'builtins').sort());
  });

  test('RESERVED_NAMES equals reserved_names of src/core/names.zig', () => {
    expect([...RESERVED_NAMES].sort()).toEqual(zigStrings(zig, 'reserved_names').sort());
  });

  test('the Zig reader fails loudly when an array is missing', () => {
    expect(() => zigStrings(zig, 'no_such_list')).toThrow('has no array `no_such_list`');
  });

  test('every listed name is itself a valid name, so a refusal is about the word and not its spelling', () => {
    for (const n of [...KEYWORDS, ...BUILTINS, ...STD_MODULES, ...RESERVED_NAMES]) expect(NAME_PATTERN.test(n)).toBe(true);
  });
});

describe('splitFullName', () => {
  test('splits a full name at its one slash', () => {
    expect(splitFullName('komira-ai/json')).toEqual({ namespace: 'komira-ai', name: 'json' });
    expect(splitFullName('a/b1')).toEqual({ namespace: 'a', name: 'b1' });
    expect(splitFullName('0-9/x_y')).toEqual({ namespace: '0-9', name: 'x_y' });
  });

  test('a namespace of 39 characters is accepted, one of 40 is not', () => {
    expect(splitFullName(`${'a'.repeat(39)}/json`)).toEqual({ namespace: 'a'.repeat(39), name: 'json' });
    expect(splitFullName(`${'a'.repeat(40)}/json`)).toBeUndefined();
  });

  test('a name of 64 characters is accepted, one of 65 is not, and one of 1 is not', () => {
    expect(splitFullName(`ns/a${'b'.repeat(63)}`)).toEqual({ namespace: 'ns', name: `a${'b'.repeat(63)}` });
    expect(splitFullName(`ns/a${'b'.repeat(64)}`)).toBeUndefined();
    expect(splitFullName('ns/a')).toBeUndefined();
  });

  test('refuses a namespace with a double hyphen, a leading or trailing hyphen, upper case or an underscore', () => {
    for (const bad of ['a--b/json', '-a/json', 'a-/json', 'Komira-AI/json', 'komira_ai/json', 'a.b/json']) expect(splitFullName(bad)).toBeUndefined();
  });

  test('refuses a name in upper case, with a hyphen or starting with a digit or underscore', () => {
    for (const bad of ['ns/Json', 'ns/js-on', 'ns/1json', 'ns/_json']) expect(splitFullName(bad)).toBeUndefined();
  });

  test('refuses a string with no slash, two slashes or an empty part', () => {
    for (const bad of ['json', 'a/b/json', 'a/json/', '/json', 'ns/', '/', '']) expect(splitFullName(bad)).toBeUndefined();
  });

  test('isFullName agrees', () => {
    expect(isFullName('komira-ai/json')).toBe(true);
    expect(isFullName('json')).toBe(false);
  });
});

describe('condaNameOf', () => {
  test('a full name is mojo-<namespace>.<name>', () => {
    expect(condaNameOf('komira-ai/json')).toBe('mojo-komira-ai.json');
  });

  test('a flat name is mojo-<name>', () => {
    expect(condaNameOf('kci_alpha')).toBe('mojo-kci_alpha');
  });
});

describe('importNameProblem', () => {
  test('a module of the standard library is named as one, with the std path', () => {
    expect(importNameProblem('collections')).toBe('a module of the Mojo standard library (std.collections)');
    expect(importNameProblem('os')).toBe('a module of the Mojo standard library (std.os)');
  });

  test('a name that is both a builtin and a standard library module is refused as the module: the standard library wins', () => {
    expect(BUILTINS).toContain('iter');
    expect(STD_MODULES).toContain('iter');
    expect(importNameProblem('iter')).toBe('a module of the Mojo standard library (std.iter)');
  });

  test('a keyword, a builtin and a reserved name are "reserved"', () => {
    expect(importNameProblem('fn')).toBe('reserved');
    expect(importNameProblem('print')).toBe('reserved');
    expect(importNameProblem('mopm')).toBe('reserved');
    expect(importNameProblem('std')).toBe('reserved');
    expect(importNameProblem('max')).toBe('reserved');
  });

  test('an ordinary name is accepted', () => {
    expect(importNameProblem('json')).toBeUndefined();
    expect(importNameProblem('http_client')).toBeUndefined();
  });
});
