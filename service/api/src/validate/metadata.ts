import { posix } from 'node:path';
import { fail } from './codes';
import { canonicalVersion, isValidVersion } from '../version';
import { CONDA_NAME, MIRROR_MAX_AGE_MS } from './native-mirror';
import type { NativeMirror } from './native-mirror';

/** Constants drawn from spec/package-metadata.schema.json; a test fails if the schema file drifts from them. */
export const METADATA_SCHEMA_VERSION = 1;
export const SONAME_PATTERN = /^lib[^./]+\..+$/;
/** An exclusivity group is compared exactly, so it has no edge space and no control character (tab, newline and DEL included). */
export const EXCLUSIVE_PATTERN = /^[^ \u0000-\u001f\u007f](?:[^\u0000-\u001f\u007f]*[^ \u0000-\u001f\u007f])?$/;
export const NATIVE_KINDS = ['shared', 'static', 'both'] as const;
export const NATIVE_MODES = ['link', 'load'] as const;

export interface NativeDecl {
  id: string;
  soname: string;
  kind: (typeof NATIVE_KINDS)[number];
  mode: (typeof NATIVE_MODES)[number];
  /** Archive paths this declaration claims (resolved against lib/mojo/), e.g. lib/libfoo.so.1. */
  paths: string[];
  sharedPath?: string;
  staticPath?: string;
}

export interface Mopm {
  name: string;
  version?: string;
  deps: Array<{ name: string; range?: string }>;
  native: NativeDecl[];
}

const td = new TextDecoder('utf-8', { fatal: true });

export function parseJsonObject(buf: Buffer, what: string, rule: 'manifest_json' | 'index_invalid'): Record<string, unknown> {
  let v: unknown;
  try {
    v = JSON.parse(td.decode(buf));
  } catch {
    return fail(rule, `${what} is not valid UTF-8 JSON`);
  }
  if (typeof v !== 'object' || v === null || Array.isArray(v)) return fail(rule, `${what} is not a JSON object`);
  return v as Record<string, unknown>;
}

const isStr = (v: unknown): v is string => typeof v === 'string';
const bad = (m: string): never => fail('manifest_schema', `<name>.mopm.json: ${m}`);

/** Validate `<name>.mopm.json` against spec/package-metadata.schema.json (hand-written; the schema is small). */
export function checkMopm(o: Record<string, unknown>): Mopm {
  if (o.schema !== METADATA_SCHEMA_VERSION) return bad(`'schema' must be ${METADATA_SCHEMA_VERSION}`);
  if (!isStr(o.name) || o.name.length < 1) return bad("'name' must be a non-empty string");
  if (o.version !== undefined && !isStr(o.version)) return bad("'version' must be a string");
  if (o.version !== undefined && !isValidVersion(o.version as string)) {
    return bad(`'version' '${String(o.version)}' is not MAJOR.MINOR.PATCH (three numbers, no suffix)`);
  }
  const deps: Mopm['deps'] = [];
  if (o.deps !== undefined) {
    if (!Array.isArray(o.deps)) return bad("'deps' must be an array");
    for (const d of o.deps as unknown[]) {
      if (typeof d !== 'object' || d === null || Array.isArray(d)) return bad("'deps' items must be objects");
      const r = d as Record<string, unknown>;
      if (!isStr(r.name) || r.name.length < 1) return bad("a dependency needs a non-empty 'name'");
      if (r.range !== undefined && !isStr(r.range)) return bad("a dependency 'range' must be a string");
      if (r.path !== undefined && !isStr(r.path)) return bad("a dependency 'path' must be a string");
      // Cargo's rule: a path is only for development; what is published must say which versions of the dependency work.
      if (r.path !== undefined && r.range === undefined) {
        return bad(`dependency '${r.name}' has a path but no version; a published package depends on a version, so add one next to the path`);
      }
      deps.push({ name: r.name, range: r.range as string | undefined });
    }
  }
  const native: NativeDecl[] = [];
  if (o.native !== undefined) {
    if (!Array.isArray(o.native)) return bad("'native' must be an array");
    for (const n of o.native as unknown[]) {
      if (typeof n !== 'object' || n === null || Array.isArray(n)) return bad("'native' items must be objects");
      const r = n as Record<string, unknown>;
      if (!isStr(r.id) || r.id.length < 1) return bad("a native library needs a non-empty 'id'");
      if (!isStr(r.soname) || !SONAME_PATTERN.test(r.soname)) return bad(`native '${String(r.id)}': 'soname' must look like lib<name>.<suffix>`);
      const kind = r.kind ?? 'shared';
      const mode = r.mode ?? 'link';
      if (!(NATIVE_KINDS as readonly unknown[]).includes(kind)) return bad(`native '${r.id}': 'kind' must be shared, static or both`);
      if (!(NATIVE_MODES as readonly unknown[]).includes(mode)) return bad(`native '${r.id}': 'mode' must be link or load`);
      if (r.file !== undefined && !isStr(r.file)) return bad(`native '${r.id}': 'file' must be a string`);
      if (r.static_file !== undefined && !isStr(r.static_file)) return bad(`native '${r.id}': 'static_file' must be a string`);
      if (r.needs !== undefined && (!Array.isArray(r.needs) || !(r.needs as unknown[]).every(isStr))) {
        return bad(`native '${r.id}': 'needs' must be an array of strings`);
      }
      if (r.exclusive !== undefined && (!isStr(r.exclusive) || !EXCLUSIVE_PATTERN.test(r.exclusive))) {
        return bad(`native '${r.id}': 'exclusive' must be a non-empty string with no leading or trailing space and no control character`);
      }
      if ((kind === 'shared' || kind === 'both') && r.file === undefined) return bad(`native '${r.id}': kind ${String(kind)} needs 'file'`);
      if ((kind === 'static' || kind === 'both') && r.static_file === undefined) return bad(`native '${r.id}': kind ${String(kind)} needs 'static_file'`);
      const paths: string[] = [];
      const resolvedBy: Record<string, string> = {};
      for (const [field, rel] of [['file', r.file], ['static_file', r.static_file]] as const) {
        if (rel === undefined) continue;
        const resolved = posix.normalize(posix.join('lib/mojo', rel as string));
        // Native libraries live directly in lib/: one level, no climbing out, no absolute paths.
        if ((rel as string).startsWith('/') || !/^lib\/[^/]+$/.test(resolved)) {
          return fail('native_path', `native '${r.id}': '${String(rel)}' does not resolve to a file directly under lib/`);
        }
        paths.push(resolved);
        resolvedBy[field] = resolved;
      }
      native.push({ id: r.id, soname: r.soname, kind: kind as NativeDecl['kind'], mode: mode as NativeDecl['mode'], paths, sharedPath: resolvedBy.file, staticPath: resolvedBy.static_file });
    }
  }
  return { name: o.name, version: o.version as string | undefined, deps, native };
}

export interface CondaIndex {
  name: string;
  version: string;
  build: string;
  compiler: string;
  subdir: string;
  depends: string[];
}

/** Validate the fields of info/index.json that the registry relies on. */
export function checkIndex(o: Record<string, unknown>): CondaIndex {
  const bad2 = (m: string): never => fail('index_invalid', `info/index.json: ${m}`);
  if (!isStr(o.name)) return bad2("'name' must be a string");
  if (!isStr(o.version)) return bad2("'version' must be a string");
  if (!isStr(o.build)) return bad2("'build' must be a string");
  if (!isStr(o.subdir)) return bad2("'subdir' must be a string");
  if (o.build_number !== 0) return bad2("'build_number' must be 0");
  const m = /^mojo(\d+(?:\.\d+)*)_0$/.exec(o.build);
  if (!m) return bad2("'build' must be mojo<compiler>_0");
  if (!Array.isArray(o.depends) || !(o.depends as unknown[]).every(isStr)) return bad2("'depends' must be an array of strings");
  return { name: o.name, version: o.version, build: o.build, compiler: m[1], subdir: o.subdir, depends: o.depends as string[] };
}

export interface DepOptions {
  /** The conda-forge name mirror, when it could be read; without it a native dependency's name cannot be checked, and that is a warning. */
  nativeMirror?: NativeMirror;
  now?: Date;
}

export interface DependsVerdict {
  /** The `mojo-*` packages `depends` names, sorted, with the prefix. */
  mojoDeps: string[];
  /** What the publisher should be told and what did not stop the publish: unknown native names, an old mirror, no mirror. */
  warnings: string[];
}

const SPEC_MAX = 256;
/** A conda version constraint as written in `depends`: digits, letters and the operators of `>=1.9,<2`, `1.2.*`, `1|2`, `~=1.4`. No quote, slash, semicolon, `$` or white space. */
const VERSION_TOKEN = /^[A-Za-z0-9.*+!_,|<>=~^-]{1,128}$/;
const BUILD_TOKEN = /^[A-Za-z0-9.*+_-]{1,64}$/;

/** The name of one `depends` entry when the entry is well formed (`name`, `name version` or `name version build`), else the reason it is not. */
function parseSpec(d: string): { name: string } | { bad: string } {
  if (d.length > SPEC_MAX) return { bad: `is longer than ${SPEC_MAX} characters` };
  const parts = d.split(/\s+/);
  if (parts[parts.length - 1] === '') parts.pop();
  const [name, version, build] = parts;
  if (name === undefined || !CONDA_NAME.test(name)) return { bad: 'does not start with a conda package name (lower-case letters, digits, ., _ and -)' };
  if (parts.length > 3) return { bad: 'has more than a name, a version and a build string' };
  if (version !== undefined && !VERSION_TOKEN.test(version)) return { bad: `has a version requirement '${version}' that is not one` };
  if (build !== undefined && !BUILD_TOKEN.test(build)) return { bad: `has a build string '${build}' that is not one` };
  return { name };
}

/**
 * Check `depends` of the index: the compiler exactly once and equal to the build string's compiler; every other entry a well-formed
 * conda requirement (the only refusal: malformed text must never reach a lock or a URL; a `mojo-` name is a Mojo package, never a
 * native one); the `mojo-*` set equal to `deps` of the
 * embedded metadata. Any well-formed native name is accepted. It warns (and does not refuse) about a name the conda-forge mirror does
 * not list, a mirror more than a day old, and a mirror that could not be read. Warnings are in the order of `depends`, the one about
 * the mirror first.
 */
export function checkDepends(idx: CondaIndex, mopm: Mopm, opt: DepOptions = {}): DependsVerdict {
  const compilers = idx.depends.filter((d) => d.split(/\s+/, 1)[0] === 'mojo-compiler');
  if (compilers.length === 0) return fail('compiler_missing', "info/index.json 'depends' has no 'mojo-compiler ==<exact>'");
  if (compilers.length > 1) return fail('compiler_mismatch', "info/index.json 'depends' names mojo-compiler more than once");
  if (compilers[0].replace(/\s+/g, ' ') !== `mojo-compiler ==${idx.compiler}`) {
    return fail('compiler_mismatch', `'${compilers[0]}' does not equal 'mojo-compiler ==${idx.compiler}' (the compiler in the build string)`);
  }
  const mojoDeps = new Set<string>();
  const natives: string[] = [];
  for (const d of idx.depends) {
    const dn = d.split(/\s+/, 1)[0];
    if (dn === 'mojo-compiler') continue;
    // A name that starts with `mojo-` is a Mojo package and is never a native one: it must be declared in the metadata's `deps`
    // (below), and the bare prefix is not a package.
    if (dn.startsWith('mojo-')) {
      if (dn.length === 5) return fail('dependency_not_allowed', `dependency '${d}' is not a Mojo package name`);
      mojoDeps.add(dn);
      continue;
    }
    const spec = parseSpec(d);
    if ('bad' in spec) return fail('dependency_not_allowed', `dependency '${d.slice(0, 80)}' ${spec.bad}`);
    natives.push(spec.name);
  }
  const declared = new Set(mopm.deps.map((x) => `mojo-${x.name}`));
  const same = declared.size === mojoDeps.size && [...declared].every((x) => mojoDeps.has(x));
  if (!same) {
    return fail('deps_mismatch', `info/index.json depends [${[...mojoDeps].sort().join(', ')}] differ from the metadata deps [${[...declared].sort().join(', ')}]`);
  }
  return { mojoDeps: [...mojoDeps].sort(), warnings: nativeWarnings(natives, opt) };
}

/** Check (b) of the design: is each native name one conda-forge lists? Only informs. */
function nativeWarnings(natives: string[], opt: DepOptions): string[] {
  if (natives.length === 0) return [];
  const mirror = opt.nativeMirror;
  if (!mirror) return ['the conda-forge name list could not be read, so the names of the native dependencies were not checked; the publish went through'];
  const out: string[] = [];
  const age = (opt.now ?? new Date()).getTime() - mirror.generatedAt.getTime();
  if (age > MIRROR_MAX_AGE_MS) {
    out.push(`the conda-forge name list is more than a day old (made ${mirror.generatedAt.toISOString()}), so a name it lacks may only be new; the publish went through`);
  }
  for (const n of [...new Set(natives)]) {
    if (!mirror.names.has(n)) out.push(`native dependency '${n}' is not a conda-forge package name as far as the registry's list knows; check the spelling (the publish went through)`);
  }
  return out;
}

/**
 * The requirements of `depends` that are neither the compiler nor a `mojo-*` package (after `checkDepends` accepted the
 * index, these are conda packages the package loads), with runs of white space as one space, sorted.
 */
export function nativeDependsOf(idx: CondaIndex): string[] {
  return idx.depends
    .filter((d) => {
      const dn = d.split(/\s+/, 1)[0];
      return dn !== 'mojo-compiler' && !dn.startsWith('mojo-');
    })
    .map((d) => d.replace(/\s+/g, ' ').replace(/ $/, ''))
    .sort();
}

/** Compare a version string from the archive to the one requested, under conda ordering. */
export function sameVersion(a: string, b: string): boolean {
  try {
    return canonicalVersion(a) === canonicalVersion(b);
  } catch {
    return false;
  }
}

/** The file naming rules relative to the declared soname. */
export function checkNativeNames(n: NativeDecl): void {
  const stem = n.soname.slice(0, n.soname.indexOf('.'));
  const baseOf = (p: string) => p.slice(p.lastIndexOf('/') + 1);
  if (n.sharedPath !== undefined) {
    const base = baseOf(n.sharedPath);
    const ok = base === n.soname || (/\.so(?:\.\d+)*$/.test(n.soname) && base.startsWith(`${n.soname}.`));
    if (!ok) fail('native_path', `native '${n.id}': file '${base}' does not fit soname '${n.soname}'`);
  }
  if (n.staticPath !== undefined) {
    const base = baseOf(n.staticPath);
    if (base !== `${stem}.a`) fail('native_path', `native '${n.id}': static_file '${base}' must be '${stem}.a'`);
  }
}
