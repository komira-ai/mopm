// The install lines a package or version page shows.
//
// A registry version is MAJOR.MINOR.PATCH (spec Version, routes.ts VERSION). mopm's requirement grammar
// (src/core/semver.zig) takes that spelling as written, with each part a u64, so a version with a part over 2^64-1
// gets no mopm.toml line (manifestRefusal says why), and neither does a string outside the grammar. A bare version is
// a caret requirement, so the package page writes the latest version as published (its lower bound is kept); a
// version page pins it with '='. 'mopm add' (src/cli/install_cmd.zig) writes such a line, so the page says so next to it.
// A dependency key is a full name, '<namespace>/<name>', and TOML needs quotes around a key holding '/'
// (spec/proposed/namespaces.md, section 3), so the line is '"komira-ai/json" = "0.1.0"'.
//
// The conda channel works for any conda client (spec/channel.md): one channel per namespace,
// 'https://conda.<site>/<namespace>/', where the package '<namespace>/<name>' is 'mojo-<namespace>.<name>'. A pixi
// project adds the channel and then the package, so the pixi lines are those commands; a version whose dependencies are
// in other namespaces needs their channels too, and its page adds one line for each.

import { type FullName, fullName, isCanonicalName, isNamespace, isVersion, splitFullName } from './routes.js';
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

/** Whether the site may write `f` into a command or a TOML key: both parts in the grammar (no quote, space or newline). */
function valid(f: FullName): boolean {
  return isNamespace(f.namespace) && isCanonicalName(f.name);
}

function dependencies(f: FullName, requirement: string): string {
  return `[dependencies]\n"${fullName(f)}" = "${requirement}"`;
}

/** The package page's mopm.toml lines for `latest`, or null when there is no latest or mopm cannot name it. */
export function manifestSnippet(f: FullName, latest: string | null): string | null {
  if (!valid(f) || latest === null || manifestRefusal(latest) !== null) return null;
  return dependencies(f, latest);
}

/** A version page's mopm.toml lines pinning exactly that version ('=1.2.3'); only a published version gets one. */
export function pinnedSnippet(f: FullName, version: string, state: VersionState): string | null {
  if (state !== 'published' || !valid(f) || manifestRefusal(version) !== null) return null;
  return dependencies(f, `=${version}`);
}

/** The conda package name of a mopm package: 'mojo-<namespace>.<name>' (spec/channel.md, Package naming). */
export function condaName(f: FullName): string {
  return `mojo-${f.namespace}.${f.name}`;
}

/** A namespace's conda channel under a stage's channel root (host.ts condaBase, which ends in '/'). */
export function namespaceChannel(base: string, namespace: string): string {
  return `${base}${namespace}/`;
}

/** The pixi command that adds a namespace's channel to the current pixi workspace (pixi 0.79). */
export function channelAddCommand(channel: string): string {
  return `pixi workspace channel add ${channel}`;
}

/**
 * The channels a version's dependencies need besides the package's own: the namespaces of `deps` (full names; one outside
 * the grammar is skipped, as the page shows it as text), each once, sorted, `own` left out.
 */
export function otherChannels(base: string, own: string, deps: readonly string[]): string[] {
  const out = new Set<string>();
  for (const d of deps) {
    const f = splitFullName(d);
    if (f !== null && f.namespace !== own) out.add(f.namespace);
  }
  return [...out].sort().map((ns) => namespaceChannel(base, ns));
}

/**
 * The pixi commands spec/channel.md documents for `f`, one per line: add its namespace's channel, then the channel of
 * each other namespace `deps` names (a version's direct dependencies), then add the package. Null when the name is outside
 * the grammar.
 */
export function pixiCommands(base: string, f: FullName, deps: readonly string[] = []): string[] | null {
  if (!valid(f)) return null;
  const channels = [namespaceChannel(base, f.namespace), ...otherChannels(base, f.namespace, deps)];
  return [...channels.map(channelAddCommand), `pixi add ${condaName(f)}`];
}
