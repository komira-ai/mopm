/**
 * Package names (docs/design/namespaces.md, section 1): the flat names of `/api/v1`, the full names `<namespace>/<name>`
 * of `/api/v2`, and the import names the registry refuses.
 *
 * A full name is a namespace (a GitHub login in lower case), one `/`, and a name of the flat grammar. The import name is
 * the part after `/`. The two parts never mix: a namespace has `-` and never `_`; a name has `_` and never `-`.
 */
import { NAMESPACE_MAX_LENGTH, NAMESPACE_PATTERN } from './auth/namespaces';

/** A flat name, and the name part of a full name. */
export const NAME_PATTERN = /^[a-z][a-z0-9_]{1,63}$/;

export interface FullName {
  namespace: string;
  /** The import name. */
  name: string;
}

/** `<namespace>/<name>` split, or undefined when the string is not a full name (either part out of its grammar). */
export function splitFullName(s: string): FullName | undefined {
  const slash = s.indexOf('/');
  if (slash < 0) return undefined;
  const namespace = s.slice(0, slash);
  const name = s.slice(slash + 1);
  if (namespace.length > NAMESPACE_MAX_LENGTH || !NAMESPACE_PATTERN.test(namespace) || !NAME_PATTERN.test(name)) return undefined;
  return { namespace, name };
}

export const isFullName = (s: string): boolean => splitFullName(s) !== undefined;

/** The conda package name (spec/proposed/namespaces.md, "Names"): `mojo-<name>` for a flat name, `mojo-<namespace>.<name>` for a full one. */
export function condaNameOf(name: string): string {
  const f = splitFullName(name);
  return f === undefined ? `mojo-${name}` : `mojo-${f.namespace}.${f.name}`;
}

/** Names nobody may take as an import name (the contract's `name_reserved`). */
export const RESERVED_NAMES: ReadonlySet<string> = new Set(['mopm', 'mojo', 'max', 'modular', 'std', 'stdlib']);

/** Mojo's keywords: a package of one of these names cannot be imported. The same list as `src/core/names.zig` (a test holds them equal). */
export const KEYWORDS: readonly string[] = [
  'alias', 'and', 'as', 'assert', 'async', 'await', 'borrowed', 'break',
  'class', 'comptime', 'continue', 'def', 'deinit', 'del', 'elif', 'else',
  'except', 'finally', 'fn', 'for', 'from', 'global', 'if', 'import',
  'in', 'inout', 'is', 'lambda', 'let', 'mut', 'nonlocal', 'not',
  'or', 'out', 'owned', 'pass', 'raise', 'raises', 'read', 'ref',
  'return', 'self', 'struct', 'trait', 'try', 'var', 'while', 'with',
  'yield',
]; // prettier-ignore

/** The builtins a package of that name would shadow when imported. The same list as `src/core/names.zig`. */
export const BUILTINS: readonly string[] = [
  'abs', 'all', 'any', 'bool', 'chr', 'divmod', 'enumerate', 'float',
  'hash', 'input', 'int', 'isinstance', 'iter', 'len', 'list', 'max',
  'min', 'next', 'ord', 'pow', 'print', 'range', 'repr', 'reversed',
  'round', 'sorted', 'str', 'sum', 'type', 'zip',
]; // prettier-ignore

/**
 * The top-level modules of the Mojo standard library: the union over every Mojo version of `toolchain/versions.txt` of
 * `toolchain/mojo-<version>.std-modules.txt` (section 1.1). A unit test holds this list to that union, so a Mojo version
 * that adds a module fails the test until the module is added here.
 */
export const STD_MODULES: readonly string[] = [
  'algorithm', 'atomic', 'base64', 'benchmark', 'bit', 'builtin', 'collections', 'compile',
  'complex', 'documentation', 'ffi', 'format', 'gpu', 'hashlib', 'io', 'iter',
  'itertools', 'logger', 'math', 'memory', 'origin', 'os', 'pathlib', 'prelude',
  'pwd', 'python', 'random', 'reflection', 'runtime', 'stat', 'subprocess', 'sys',
  'tempfile', 'testing', 'time', 'traits', 'utils',
]; // prettier-ignore

const KEYWORD_SET = new Set(KEYWORDS);
const BUILTIN_SET = new Set(BUILTINS);
const STD_SET = new Set(STD_MODULES);

/**
 * Why `name` may not be an import name, as the `{what}` of `name_reserved` (`'{name}' is {what}.`), or undefined when it
 * may be one. A name of the flat grammar is assumed; the grammar is checked first, by the caller.
 */
export function importNameProblem(name: string): string | undefined {
  if (STD_SET.has(name)) return `a module of the Mojo standard library (std.${name})`;
  if (RESERVED_NAMES.has(name) || KEYWORD_SET.has(name) || BUILTIN_SET.has(name)) return 'reserved';
  return undefined;
}
