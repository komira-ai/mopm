import { fail } from './codes';
import type { TarEntry } from './tar';

/** What an entry of the package is, once it passed the allow-list. */
export type Role = 'mojoc' | 'mopm' | 'native' | 'info' | 'license' | 'dir';

const INFO_FILES = new Set(['info/index.json', 'info/paths.json', 'info/about.json', 'info/files', 'info/hash_input.json']);
const ALLOWED_DIRS = new Set(['lib', 'lib/mojo', 'info', 'info/licenses']);
/** Native library file names under lib/: lib<stem>.so[.N...], lib<stem>.dylib, lib<stem>.a (a static archive). */
export const NATIVE_FILE = /^lib\/lib[^/]+\.(?:so(?:\.\d+)*|dylib|a)$/;
const LINK_SCRIPT = /(?:^|[-_.])(?:pre-link|post-link|pre-unlink)\.(?:sh|bat)$/i;

/**
 * Refuse two entries whose names are the same file on some filesystem: byte-identical duplicates, and
 * paths that differ only by Unicode normalisation (NFC/NFD, compatibility forms) or letter case, which
 * fold together on macOS and Windows and let one entry shadow another there.
 */
export function checkCollisions(entries: readonly TarEntry[]): void {
  const seen = new Map<string, string>();
  for (const e of entries) {
    const key = e.path.toLowerCase();
    const prior = seen.get(key);
    if (prior === undefined) seen.set(key, e.path);
    else if (prior === e.path) fail('duplicate_path', `'${e.path}' appears more than once`, e.path);
    else fail('unicode_collision', `'${prior}' and '${e.path}' are the same name after Unicode normalisation or case folding`, e.path);
  }
}

/** Apply the layout allow-list to one entry. "This is a package registry, not file storage." */
export function classify(e: TarEntry, name: string): Role {
  const p = e.path;
  const base = p.slice(p.lastIndexOf('/') + 1);
  if (p === 'info/link.json' || p.startsWith('etc/conda/') || LINK_SCRIPT.test(base)) {
    return fail('link_script', `'${p}' is a link or activation script; packages may not run code at install time`, p);
  }
  const top = p.split('/', 1)[0];
  if (top === 'bin' || top === 'sbin' || top === 'Scripts') {
    return fail('bin_dir', `'${p}' is under ${top}/; packages may not ship executables`, p);
  }
  if (e.kind === 'dir') {
    if (ALLOWED_DIRS.has(p) || p.startsWith('info/licenses/')) return 'dir';
    return fail('layout_not_allowed', `directory '${p}' is outside the allowed layout`, p);
  }
  if (p === `lib/mojo/${name}.mojoc`) return 'mojoc';
  if (p === `lib/mojo/${name}.mopm.json`) return 'mopm';
  if (NATIVE_FILE.test(p)) return 'native';
  if (INFO_FILES.has(p)) return 'info';
  if (p.startsWith('info/licenses/')) return 'license';
  return fail('layout_not_allowed', `'${p}' is not an allowed path (allowed: lib/mojo/${name}.mojoc, lib/mojo/${name}.mopm.json, declared native libraries, info/ metadata, licence files)`, p);
}
