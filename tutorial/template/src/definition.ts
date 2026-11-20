// The tutorial's E2B sandbox template, in E2B's template format: the `Template()` builder of the `e2b` package
// (pinned exactly in package.json). E2B, "Template quickstart" (https://docs.e2b.dev/template/quickstart):
// "E2B templates allow you to define custom sandboxes." and "The template name is the identifier that can be used
// to create a new Sandbox." E2B, "User and workdir" (https://docs.e2b.dev/template/user-and-workdir): "The default
// user in the template is `user` with the `/home/user` (home directory) as the working directory." and "The last set
// user and workdir in the template is then persisted as a default to the sandbox execution."
//
// What it holds (docs/design/tutorial-sign-in.md, section 4, "The template"): mopm, the Mojo toolchain and every
// lesson's synced project, so a run in the sandbox downloads nothing (the sandbox has no internet).
import { Template, TemplateBuilder } from 'e2b';

/** The sandbox's default user and its home, as E2B defines them (above). */
export const SANDBOX_USER = 'user';
export const SANDBOX_HOME = '/home/user';

/** Where the lessons go in the sandbox (tutorial/README.md): `/home/user/lessons/<id>/`. */
export const LESSONS_DIR = `${SANDBOX_HOME}/lessons`;

/** The release file the sandbox runs (E2B sandboxes are linux x86_64), as RELEASING.md names the release assets. */
export function releaseAsset(version: string): string {
  return `mopm-${version}-linux-x86_64.tar.gz`;
}

/** Where the release's files are downloaded from. */
export function releaseUrl(version: string, file: string): string {
  return `https://github.com/komira-ai/mopm/releases/download/v${version}/${file}`;
}

/** Where the download is unpacked during the build; removed by the same step. */
const UNPACK_DIR = '/opt/mopm-install';

/**
 * mopm's shared download cache in the sandbox (src/cli/sync_cache.zig: `$HOME/.cache/mopm/pkgs`), named
 * explicitly so the toolchain lands in the sandbox user's home whatever HOME the build step runs with.
 */
export const MOPM_CACHE = `${SANDBOX_HOME}/.cache/mopm/pkgs`;

/** The mopm release the template installs. */
export interface MopmRelease {
  /** X.Y.Z, already checked against VERSION (inputs.ts `releaseOf`). */
  version: string;
  /** The sha256 of `releaseAsset(version)`, as the release's SHA256SUMS lists it (cli.ts `releaseSha256`). */
  sha256: string;
}

/** What the template is made of. */
export interface TemplateInputs {
  /** The repository root: every `copy` source is relative to it, and nothing outside it is uploaded. */
  repoRoot: string;
  /** Lesson ids, from `listLessons`. */
  lessons: string[];
  mopm: MopmRelease;
}

/** The files and directories under the repository root that are never uploaded (E2B's `.dockerignore` syntax): a
 * lesson's `.mopm/` is what `mopm sync` writes on the operator's machine, and the template syncs its own. */
export const FILE_IGNORE_PATTERNS = ['**/.mopm'];

/**
 * The step that installs mopm, as root: download the release file, check it against the pinned sha256, put its
 * binary at /usr/local/bin/mopm (on every user's PATH), check that it reports the version, and remove the download.
 * The version and sha256 are in the command itself, so E2B's step cache can never keep another release.
 */
export function installCommand(mopm: MopmRelease): string {
  const asset = releaseAsset(mopm.version);
  const top = asset.slice(0, -'.tar.gz'.length);
  return [
    `mkdir -p ${UNPACK_DIR}`,
    `curl -fsSL --retry 3 -o ${UNPACK_DIR}/${asset} ${releaseUrl(mopm.version, asset)}`,
    `echo "${mopm.sha256}  ${UNPACK_DIR}/${asset}" | sha256sum -c -`,
    `tar -xzf ${UNPACK_DIR}/${asset} -C ${UNPACK_DIR}`,
    `install -m 0755 ${UNPACK_DIR}/${top}/mopm /usr/local/bin/mopm`,
    `rm -r ${UNPACK_DIR}`,
    `test "$(mopm --version)" = "mopm ${mopm.version}"`,
  ].join(' && ');
}

/**
 * The template definition. Steps, in order:
 * 1. E2B's base image (`e2bdev/base`, Debian with curl, tar and coreutils, which the install step needs).
 * 2. The install step (`installCommand`), as root: the release's binary at /usr/local/bin/mopm, sha256-checked.
 * 3. For each lesson: its project/ is copied to /home/user/lessons/<id>/, owned by the sandbox user, and
 *    `mopm sync --locked` runs there as that user, which installs the pinned Mojo toolchain and the locked
 *    packages into the lesson's .mopm/env. It runs in the final place because mopm's environment records the
 *    project's absolute path.
 * 4. The sandbox user and its home become the sandbox's defaults.
 */
export function templateDefinition(inputs: TemplateInputs): TemplateBuilder {
  let t = Template({ fileContextPath: inputs.repoRoot, fileIgnorePatterns: FILE_IGNORE_PATTERNS })
    .fromBaseImage()
    .runCmd(installCommand(inputs.mopm), { user: 'root' });
  for (const id of inputs.lessons) {
    const dir = `${LESSONS_DIR}/${id}`;
    t = t
      .copy(`tutorial/lessons/${id}/project`, `${dir}/`, { user: SANDBOX_USER })
      .setWorkdir(dir)
      .runCmd(`mopm sync --locked --cache ${MOPM_CACHE}`, { user: SANDBOX_USER });
  }
  return t.setWorkdir(SANDBOX_HOME).setUser(SANDBOX_USER);
}

/** One step of the definition, as E2B serialises it (`Template.toJSON`). */
export interface Step {
  type: string;
  args: string[];
}

/** The definition's base image and steps, as E2B serialises them, without reading any file (no hashes). */
export async function steps(t: TemplateBuilder): Promise<{ fromImage: string; steps: Step[] }> {
  const json = JSON.parse(await Template.toJSON(t, false)) as { fromImage: string; steps: Step[] };
  return { fromImage: json.fromImage, steps: json.steps.map((s) => ({ type: s.type, args: s.args })) };
}

/** The steps as lines a person reads in the dry run: E2B's Dockerfile form, with the user of each COPY and RUN. */
export async function describe(t: TemplateBuilder): Promise<string[]> {
  const { fromImage, steps: all } = await steps(t);
  const lines = [`FROM ${fromImage}`];
  for (const s of all) {
    if (s.type === 'COPY') lines.push(`COPY ${s.args[0]} ${s.args[1]} (owner ${s.args[2]})`);
    else if (s.type === 'RUN') lines.push(`RUN ${s.args[0]} (as ${s.args[1]})`);
    else lines.push(`${s.type} ${s.args.join(' ')}`);
  }
  return lines;
}
