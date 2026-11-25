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
// The command a page leads with is mopm's own: 'mopm add <namespace>/<name>' (src/cli/install_cmd.zig) writes the
// dependency line and locks it, as `cargo add` does; on a version page it is 'mopm add <namespace>/<name>@=<version>',
// the '<package>@<requirement>' spelling docs/configuration.md gives, which writes that exact pin. A page served by a
// stage other than prod adds that stage's '--registry' (docs/configuration.md): the page shows that stage's registry.
//
// A version's files are in its namespace's conda channel, 'https://conda.<site>/<namespace>/' (spec/channel.md); the
// version page links each file there, and nowhere else.

import { type FullName, fullName, isCanonicalName, isNamespace, isVersion } from './routes.js';
import type { Stage } from './host.js';
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

/**
 * The `mopm add` command for `f`: with `requirement` ('=1.2.3') written as '<full name>@<requirement>', without one
 * mopm picks the newest version that fits; `registry` adds '--registry <stage>'. Null when the name is outside the
 * grammar, or the requirement is not a version mopm can name (both are written into a shell command).
 */
export function addCommand(f: FullName, requirement: { pin: string } | null, registry: Exclude<Stage, 'prod'> | null): string | null {
  if (!valid(f)) return null;
  if (requirement !== null && manifestRefusal(requirement.pin) !== null) return null;
  const spec = requirement === null ? fullName(f) : `${fullName(f)}@=${requirement.pin}`;
  return registry === null ? `mopm add ${spec}` : `mopm add ${spec} --registry ${registry}`;
}

/** A namespace's conda channel under a stage's channel root (host.ts condaBase, which ends in '/'). */
export function namespaceChannel(base: string, namespace: string): string {
  return `${base}${namespace}/`;
}
