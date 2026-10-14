// The install lines a package or version page shows.
//
// A mopm.toml requirement is shown only for a version spelling the manifest can name: mopm's requirement grammar
// (src/core/semver.zig) takes at most three numeric parts and no conda-style suffix, so '1.2.3.4' and '1.0rc1' get no
// line. A bare version is a caret requirement, so the package page writes the latest version as published (its lower
// bound is kept); a version page pins it with '='. mopm does not fetch registry dependencies yet ('mopm add' and
// 'mopm sync' are planned), so the page says so next to the line. The conda channel works for any conda client today
// (spec/channel.md): the package is 'mojo-<name>' there.

import { isCanonicalName } from './routes.js';
import type { VersionState } from './types.js';

/** A version the mopm.toml requirement grammar accepts as written: one to three numeric parts. */
export const MANIFEST_VERSION = /^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,2}$/;

function dependencies(name: string, requirement: string): string {
  return `[dependencies]\n${name} = "${requirement}"`;
}

/** The package page's mopm.toml lines for `latest`, or null when there is no latest or mopm cannot name it. */
export function manifestSnippet(name: string, latest: string | null): string | null {
  if (!isCanonicalName(name) || latest === null || !MANIFEST_VERSION.test(latest)) return null;
  return dependencies(name, latest);
}

/** A version page's mopm.toml lines pinning exactly that version; only a published version gets one. */
export function pinnedSnippet(name: string, version: string, state: VersionState): string | null {
  if (state !== 'published' || !isCanonicalName(name) || !MANIFEST_VERSION.test(version)) return null;
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
