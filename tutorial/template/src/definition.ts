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

/** The installer of this commit, which checks the release's sha256 against its SHA256SUMS before installing. */
export const INSTALLER = 'site/static/install.sh';
const INSTALLER_IN_IMAGE = '/opt/mopm-install/install.sh';

/**
 * mopm's shared download cache in the sandbox (src/cli/sync_cache.zig: `$HOME/.cache/mopm/pkgs`), named
 * explicitly so the toolchain lands in the sandbox user's home whatever HOME the build step runs with.
 */
export const MOPM_CACHE = `${SANDBOX_HOME}/.cache/mopm/pkgs`;

/** What the template is made of. `mopmVersion` is X.Y.Z, already checked against VERSION (inputs.ts `releaseOf`). */
export interface TemplateInputs {
  /** The repository root: every `copy` source is relative to it, and nothing outside it is uploaded. */
  repoRoot: string;
  /** Lesson ids, from `listLessons`. */
  lessons: string[];
  mopmVersion: string;
}

/**
 * The template definition. Steps, in order:
 * 1. E2B's base image (`e2bdev/base`, Debian with curl, tar and coreutils, which the installer needs).
 * 2. The installer, run as root with MOPM_VERSION set, puts the release's binary at /usr/local/bin/mopm.
 * 3. For each lesson: its project/ is copied to /home/user/lessons/<id>/, owned by the sandbox user, and
 *    `mopm sync --locked` runs there as that user, which installs the pinned Mojo toolchain and the locked
 *    packages into the lesson's .mopm/env. It runs in the final place because mopm's environment records the
 *    project's absolute path.
 * 4. The sandbox user and its home become the sandbox's defaults.
 */
export function templateDefinition(inputs: TemplateInputs): TemplateBuilder {
  let t = Template({
    fileContextPath: inputs.repoRoot,
    // A lesson's .mopm/ is what `mopm sync` writes on the operator's machine: never uploaded, the template syncs its own.
    fileIgnorePatterns: ['**/.mopm'],
  })
    .fromBaseImage()
    .copy(INSTALLER, INSTALLER_IN_IMAGE, { user: 'root', mode: 0o755 })
    .runCmd(
      `MOPM_VERSION=${inputs.mopmVersion} MOPM_HOME=/usr/local sh ${INSTALLER_IN_IMAGE} && rm ${INSTALLER_IN_IMAGE}`,
      { user: 'root' },
    );
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
