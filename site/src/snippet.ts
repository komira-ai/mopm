// The install lines a package or version page shows.
//
// A mopm.toml requirement is shown only for a version spelling the manifest can name: mopm's requirement grammar
// (src/core/semver.zig) takes at most three numeric parts, each a u64, and no conda-style suffix, so '1.2.3.4',
// '1.0rc1' and a part over 2^64-1 get no line (manifestRefusal says which). A bare version is a caret requirement, so
// the package page writes the latest version as published (its lower bound is kept). A version page pins it with '='
// on all three parts: semver.zig compares only the parts a comparator has, so '=1.2' would match every 1.2.x, while
// '=1.2.0' names the one version (the registry's '1.2' is conda-equal to '1.2.0'). mopm does not fetch registry
// dependencies yet ('mopm add' and 'mopm sync' are planned), so the page says so next to the line. The conda channel
// works for any conda client today (spec/channel.md): the package is 'mojo-<name>' there.

import { isCanonicalName } from './routes.js';
import type { VersionState } from './types.js';

/** The shape of a version the mopm.toml requirement grammar accepts: one to three numeric parts. */
export const MANIFEST_VERSION = /^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,2}$/;

/** semver.zig parses each part as a u64. */
export const PART_MAX = 18446744073709551615n;

/** Why mopm.toml cannot name this registry version, or null when it can. */
export function manifestRefusal(version: string): 'parts' | 'suffix' | 'too-large' | null {
  if (MANIFEST_VERSION.test(version)) {
    return version.split('.').every((p) => BigInt(p) <= PART_MAX) ? null : 'too-large';
  }
  if (/[a-z]/.test(version)) return 'suffix';
  return 'parts';
}

/** A sentence saying why `version` has no mopm.toml line ('The latest version, 1.0rc1, ...' with a subject). */
export function refusalSentence(subject: string, version: string): string | null {
  switch (manifestRefusal(version)) {
    case null:
      return null;
    case 'suffix':
      return `${subject} has a conda pre-release suffix, which a mopm.toml requirement cannot name.`;
    case 'too-large':
      return `${subject} has a part larger than a mopm.toml requirement allows (2^64-1).`;
    case 'parts':
      return `${subject} has more than three numeric parts, which a mopm.toml requirement cannot name.`;
  }
}

function dependencies(name: string, requirement: string): string {
  return `[dependencies]\n${name} = "${requirement}"`;
}

/** The package page's mopm.toml lines for `latest`, or null when there is no latest or mopm cannot name it. */
export function manifestSnippet(name: string, latest: string | null): string | null {
  if (!isCanonicalName(name) || latest === null || manifestRefusal(latest) !== null) return null;
  return dependencies(name, latest);
}

/**
 * A version page's mopm.toml lines pinning exactly that version, written with all three parts ('1.2' as '=1.2.0');
 * only a published version gets one.
 */
export function pinnedSnippet(name: string, version: string, state: VersionState): string | null {
  if (state !== 'published' || !isCanonicalName(name) || manifestRefusal(version) !== null) return null;
  const parts = version.split('.');
  while (parts.length < 3) parts.push('0');
  return dependencies(name, `=${parts.join('.')}`);
}

/** The conda package name of a mopm package. */
export function condaName(name: string): string {
  return `mojo-${name}`;
}

/** The pixi command spec/channel.md documents, for a project that lists the channel. */
export function pixiCommand(name: string): string | null {
  return isCanonicalName(name) ? `pixi add ${condaName(name)}` : null;
}
