// The held build command of the tutorial's template (README.md): `build.ts` forwards to `main` here.
// It is an operator step, never run in CI: by default a dry run that prints the plan and makes no network call;
// with --build it builds the template on E2B with the team key and prints the new template id.
import { join } from 'path';
import { Template } from 'e2b';
import type { BuildInfo, BuildOptions, LogEntry, TemplateBuilder } from 'e2b';
import { describe, templateDefinition } from './definition';
import { listLessons, readBase, releaseOf } from './inputs';

/** The stages, as service/infra/stacks/lib/config.ts names them. */
export const STAGES = ['beta', 'gamma', 'prod'] as const;

/** A template name E2B accepts and a person can read: lower-case letters, digits, `-` and `_`, starting with a letter or digit. */
const NAME = /^[a-z0-9][a-z0-9_-]*$/;

/** Where the newest mopm release is looked up: GitHub's "latest release" (drafts and pre-releases excluded), as install.sh does. */
export const LATEST_RELEASE_URL = 'https://api.github.com/repos/komira-ai/mopm/releases/latest';

/** What `main` touches outside itself. Tests pass fakes; `realDeps` passes the real ones. */
export interface Deps {
  repoRoot: string;
  /** The environment, read for E2B_API_KEY only (the provider's own credential variable), and only with --build. */
  env: Record<string, string | undefined>;
  out: (line: string) => void;
  err: (line: string) => void;
  /** Called only with --build and no --mopm-version. */
  fetch: (url: string, init: { headers: Record<string, string> }) => Promise<{ ok: boolean; status: number; json(): Promise<unknown> }>;
  /** E2B's `Template.build`, called only with --build. */
  build: (t: TemplateBuilder, name: string, options: Omit<BuildOptions, 'alias'>) => Promise<BuildInfo>;
}

export const USAGE = 'usage: build.ts --stage <beta|gamma|prod> --name <template name> [--mopm-version <X.Y.Z>] [--build]';

interface Args {
  stage: string;
  name: string;
  mopmVersion?: string;
  build: boolean;
}

/** Parses the flags; throws a message for the usage error. */
export function parseArgs(argv: string[]): Args {
  const values: Record<string, string> = {};
  let build = false;
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (flag === '--build') {
      build = true;
      continue;
    }
    if (flag !== '--stage' && flag !== '--name' && flag !== '--mopm-version') throw new Error(`unknown argument '${flag}'`);
    if (flag in values) throw new Error(`${flag} is given twice`);
    const value = argv[++i];
    if (value === undefined || value === '') throw new Error(`${flag} needs a value`);
    values[flag] = value;
  }
  const stage = values['--stage'];
  const name = values['--name'];
  if (stage === undefined) throw new Error('--stage is required');
  if (!(STAGES as readonly string[]).includes(stage)) throw new Error(`unknown stage '${stage}'; the stages are ${STAGES.join(', ')}`);
  if (name === undefined) throw new Error('--name is required');
  if (!NAME.test(name)) throw new Error(`'${name}' is not a template name (lower-case letters, digits, '-' and '_')`);
  return { stage, name, mopmVersion: values['--mopm-version'], build };
}

/** The newest published mopm release, from GitHub's latest-release answer (its `tag_name`). */
export async function latestRelease(fetch: Deps['fetch']): Promise<string> {
  const res = await fetch(LATEST_RELEASE_URL, { headers: { accept: 'application/vnd.github+json' } });
  if (!res.ok) throw new Error(`could not look up the latest mopm release: ${LATEST_RELEASE_URL} answered ${res.status}`);
  const body = (await res.json()) as { tag_name?: unknown } | null;
  const tag = body?.tag_name;
  if (typeof tag !== 'string') throw new Error(`could not look up the latest mopm release: ${LATEST_RELEASE_URL} named no tag`);
  return tag;
}

/** Replaces every occurrence of the key in `text`, so no line this command prints can carry it. */
function redactor(key: string | undefined): (text: string) => string {
  return (text) => (key ? text.split(key).join('<redacted>') : text);
}

function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/** Runs the command; returns the exit code (0 done, 1 failed, 2 usage). */
export async function main(argv: string[], deps: Deps): Promise<number> {
  let args: Args;
  try {
    args = parseArgs(argv);
  } catch (e) {
    deps.err(`build.ts: ${message(e)}`);
    deps.err(USAGE);
    return 2;
  }
  const key = args.build ? deps.env.E2B_API_KEY : undefined;
  const redact = redactor(key);
  try {
    if (args.build && !key) throw new Error('--build needs the team key in E2B_API_KEY');
    const base = readBase(deps.repoRoot);
    const lessons = listLessons(deps.repoRoot);
    let mopm: string;
    let mopmNote: string;
    if (args.mopmVersion !== undefined) {
      mopm = releaseOf(base, args.mopmVersion);
      mopmNote = `--mopm-version, a release of ${base} (VERSION)`;
    } else if (args.build) {
      mopm = releaseOf(base, await latestRelease(deps.fetch));
      mopmNote = `the latest release, which is of ${base} (VERSION)`;
    } else {
      mopm = `${base}.<latest>`;
      mopmNote = `the latest release, looked up when --build runs; it must be a release of ${base} (VERSION)`;
    }
    const template = templateDefinition({ repoRoot: deps.repoRoot, lessons, mopmVersion: mopm });
    deps.out(args.build ? 'building the template on E2B' : 'dry run: nothing is built and nothing is sent (add --build to build)');
    deps.out(`stage: ${args.stage}`);
    deps.out(`name: ${args.name}`);
    deps.out(`mopm: ${mopm} (${mopmNote})`);
    deps.out(`lessons: ${lessons.join(', ')}`);
    deps.out('steps:');
    for (const line of await describe(template)) deps.out(`  ${line}`);
    if (!args.build) return 0;
    const info = await deps.build(template, args.name, {
      apiKey: key,
      onBuildLogs: (entry: LogEntry) => deps.out(redact(`e2b: ${entry.level} ${entry.message}`)),
    });
    deps.out(`template id: ${info.templateId}`);
    deps.out(`build id: ${info.buildId}`);
    deps.out(`next: set ${info.templateId} as the ${args.stage} stage's tutorial template id in its settings`);
    return 0;
  } catch (e) {
    deps.err(redact(`build.ts: ${message(e)}`));
    return 1;
  }
}

/** The real dependencies: this checkout, the process's environment and streams, Node's fetch and E2B's build. */
export function realDeps(): Deps {
  return {
    repoRoot: join(__dirname, '..', '..', '..'),
    env: process.env,
    out: (line) => process.stdout.write(`${line}\n`),
    err: (line) => process.stderr.write(`${line}\n`),
    fetch: (url, init) => fetch(url, init),
    build: (t, name, options) => Template.build(t, name, options),
  };
}
