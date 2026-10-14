// The install lines a package or version page shows.
//
// A registry version is MAJOR.MINOR.PATCH (spec Version, routes.ts VERSION). mopm's requirement grammar
// (src/core/semver.zig) takes that spelling as written, with each part a u64, so a version with a part over 2^64-1
// gets no mopm.toml line (manifestRefusal says why), and neither does a string outside the grammar. A bare version is
// a caret requirement, so the package page writes the latest version as published (its lower bound is kept); a
// version page pins it with '='. 'mopm add' is planned (src/cli/main.zig), so the page says so next to the line. The
// conda channel works for any conda client today (spec/channel.md): the package is 'mojo-<name>' there.

import { isCanonicalName, isVersion } from './routes.js';
import type { VersionState } from './types.js';

/** semver.zig parses each part as a u64. */
export const PART_MAX = 18446744073709551615n;

/** Why mopm.toml cannot name this version, or null when it can. */
export function manifestRefusal(version: string): 'not-a-version' | 'too-large' | null {
  if (!isVersion(version)) return 'not-a-version';
  return version.split('.').every((p) => BigInt(p) <= PART_MAX) ? null : 'too-large';
}

/** A sentence saying why `version` has no mopm.toml line ('The latest version, 1.2.3, ...' with a subject). */
export function refusalSentence(subject: string, version: string): string | null {
  switch (manifestRefusal(version)) {
    case null:
      return null;
    case 'too-large':
      return `${subject} has a part larger than a mopm.toml requirement allows (2^64-1).`;
    case 'not-a-version':
      return `${subject} is not a MAJOR.MINOR.PATCH version, which a mopm.toml requirement needs.`;
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

/** A version page's mopm.toml lines pinning exactly that version ('=1.2.3'); only a published version gets one. */
export function pinnedSnippet(name: string, version: string, state: VersionState): string | null {
  if (state !== 'published' || !isCanonicalName(name) || manifestRefusal(version) !== null) return null;
  return dependencies(name, `=${version}`);
}

/** The conda package name of a mopm package. */
export function condaName(name: string): string {
  return `mojo-${name}`;
}

/** The pixi command spec/channel.md documents, for a project that lists the channel. */
export function pixiCommand(name: string): string | null {
  return isCanonicalName(name) ? `pixi add ${condaName(name)}` : null;
}
