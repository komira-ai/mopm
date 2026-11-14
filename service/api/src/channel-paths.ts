import { NAMESPACE_MAX_LENGTH, NAMESPACE_PATTERN } from './auth/namespaces';
import { splitFullName } from './names';
import { SUBDIRS_V1, type Subdir } from './types';

/**
 * Where a package's files and repodata live in the channel bucket (spec/channel.md, docs/design/namespaces.md section 5).
 *
 * The bucket holds one conda channel per namespace, `<namespace>/<subdir>/...`, and the channel root, `<subdir>/...`,
 * which lists only the packages kept under flat names. A "repodata directory" is the one place a subdir's repodata of one
 * channel is written: `<subdir>` at the root, `<namespace>/<subdir>` in a namespace. It is what an `index` message's
 * `subdir` field holds, what a publish's `remaining_subdirs` and a group's `repodata_released` list, and the FIFO group of
 * its writers, so that the writers of one channel's subdir run one at a time and two namespaces never wait on each other.
 * A message or a stored list written before namespaces holds plain subdirs, which name the root: the same meaning.
 *
 * Everything here is derived from the name, never parsed back from a key, except `parseRepodataDir`, which reads a
 * directory back from a queue message and refuses anything this module would not have written.
 */

/** A repodata directory read back: the namespace (absent at the root) and the conda subdir. */
export interface RepodataDir {
  namespace?: string;
  subdir: Subdir;
}

/** The namespace of a full name, or undefined for a flat name (the channel root). */
export const channelNamespaceOf = (name: string): string | undefined => splitFullName(name)?.namespace;

/** The repodata directory of a package's files in `subdir`: `<subdir>` for a flat name, `<namespace>/<subdir>` for a full one. */
export function repodataDirOf(name: string, subdir: Subdir): string {
  const namespace = channelNamespaceOf(name);
  return namespace === undefined ? subdir : `${namespace}/${subdir}`;
}

/** The repodata directory of `subdir` in a channel: the root when `namespace` is undefined. */
export const repodataDir = (namespace: string | undefined, subdir: Subdir): string => (namespace === undefined ? subdir : `${namespace}/${subdir}`);

/**
 * A repodata directory from a queue message or a stored list, or undefined when it is not one: a known subdir, or a
 * namespace of the grammar, one `/` and a known subdir. A namespace is not checked against the reserved list: the
 * registry never creates a reserved one, so none has packages, and a rebuild of an empty channel writes empty files.
 */
export function parseRepodataDir(dir: string): RepodataDir | undefined {
  const slash = dir.indexOf('/');
  if (slash < 0) return SUBDIRS_V1.includes(dir) ? { subdir: dir } : undefined;
  const namespace = dir.slice(0, slash);
  const subdir = dir.slice(slash + 1);
  if (namespace.length > NAMESPACE_MAX_LENGTH || !NAMESPACE_PATTERN.test(namespace) || !SUBDIRS_V1.includes(subdir)) return undefined;
  return { namespace, subdir };
}

/** Whether a package belongs to the channel of `namespace` (the root when undefined): full names of that namespace, or flat names. */
export const inChannel = (name: string, namespace: string | undefined): boolean => channelNamespaceOf(name) === namespace;

/** The bucket key of a package file: `<repodata dir>/<filename>`. */
export const channelFileKey = (name: string, subdir: Subdir, filename: string): string => `${repodataDirOf(name, subdir)}/${filename}`;

/** The public URL of a package file, from the stage's channel URL (with or without its trailing `/`). */
export const channelFileUrl = (channelUrl: string, name: string, subdir: Subdir, filename: string): string =>
  `${channelUrl.replace(/\/+$/, '')}/${channelFileKey(name, subdir, filename)}`;

/** The repodata directories a package's files are in, sorted (code-unit order, so one channel's dirs are together). */
export const repodataDirsOf = (name: string, subdirs: Iterable<Subdir>): string[] => [...new Set([...subdirs].map((s) => repodataDirOf(name, s)))].sort();
