// The read-only check, after each deploy, that a package page on the stage shows none of komira's `mojo-hidden` test
// lines (the readme-e2e job of .github/workflows/e2e.yml).
//
//   node build/tools/tools/readme-e2e.js --stage beta|gamma|prod --site https://<site host> --dist <dir> [--summary <file>]
//
// It loads the page the way a browser does, without a browser: the prerendered shell the site host serves for the
// package's address (`/packages/<namespace>/<name>`, app.html with the page script), then the view the page script
// builds there, made by the site's own code: src/app.ts's appView, through src/api.ts's client on the site's own
// `/api/v2` (the distribution sends it to the stage's API), into a StringDoc. The readme in that view is the API's readme
// field rendered by src/markdown/, as src/views/package.ts does on the page. The check fails when the readme's text
// (what a reader sees: the section's text content) holds `mojo-hidden`.
//
// The renderer it runs is this commit's, so the check first holds the stage to this commit's site: --dist is this
// commit's build (`npm run build`), and the shell the stage serves must load the same `/assets/<id>/main.js` as its
// app.html does. The id is a hash of the modules' contents, so an equal id means the browser runs the same renderer
// as this check; a stage that serves another build fails, as it would otherwise test code the readers do not get.
// It is TypeScript, not Zig like the other e2e drivers, because the code under test is the site's TypeScript.
//
// The package: komira-ai/json on prod, whose readme (komira's src/komira_json/README.md) hides its test lines in
// `<!-- mojo-hidden ... -->`; on beta and gamma, zz-e2e/zz_e2e_app, which the group-e2e job of the same workflow
// publishes with one such line in its readme (tests/drivers/group_e2e.zig, readmeOf). It reads the package as an earlier
// run left it: this job does not wait for that one.
//
// A check that cannot prove anything SKIPs, loudly (a SKIP line, a warning annotation and the reason in the job summary),
// and the job stays green: the package is not on beta or gamma (group-e2e has not published it there), or the API's
// readme is missing, holds no `mojo-hidden`, or is over the page's 64 KiB limit (the page then shows a note instead).
// prod must hold komira-ai/json: its absence there is a failure. Anything else that goes wrong is a failure: a shell
// that is not the app shell, an API answer other than the package (after five tries of a transient one), a page with
// no readme section for a readme it was sent. Every problem is reported, so one red run names all of them.
//
// Read-only: GETs with no token, no cookie and no credential.

import { appendFileSync, readFileSync } from 'fs';
import { join } from 'path';
import { client, type Client, type FetchFn, type Result, TIMEOUT_MS, type Timers } from '../src/api';
import { appView } from '../src/app';
import { type Doc, type SElement, type SNode, StringDoc } from '../src/doc';
import { API_BASE, type Stage } from '../src/host';
import { type FullName, fullName, packagePath } from '../src/routes';
import type { PackageInfo } from '../src/types';
import type { View } from '../src/views/common';
import { README_MAX_BYTES } from '../src/views/package';

/** The text a readme must never show: komira's marker of a test-only line. */
export const MARKER = 'mojo-hidden';

export const STAGES: readonly Stage[] = ['beta', 'gamma', 'prod'];

/** The package each stage's check reads, and whether the stage must hold it. */
export const TARGETS: Readonly<Record<Stage, { pkg: FullName; required: boolean }>> = {
  prod: { pkg: { namespace: 'komira-ai', name: 'json' }, required: true },
  beta: { pkg: { namespace: 'zz-e2e', name: 'zz_e2e_app' }, required: false },
  gamma: { pkg: { namespace: 'zz-e2e', name: 'zz_e2e_app' }, required: false },
};

/** Tries of a request whose answer is transient (no answer, 429, 5xx), and the wait between two tries. */
export const TRIES = 5;
export const RETRY_WAIT_MS = 5_000;

export const USAGE = 'usage: readme-e2e --stage beta|gamma|prod --site https://<site host> --dist <dir> [--summary <file>]';

export interface Flags {
  stage: Stage;
  /** The site's origin, e.g. 'https://beta.mopm.dev'. */
  origin: string;
  hostname: string;
  /** This commit's site build (dist/), whose app.html names the page script the stage must serve. */
  dist: string;
  summary: string | null;
}

/** The command line, or what is wrong with it. */
export function parseFlags(argv: readonly string[]): Flags | { error: string } {
  const seen = new Map<string, string>();
  for (let i = 0; i < argv.length; i += 2) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (flag !== '--stage' && flag !== '--site' && flag !== '--dist' && flag !== '--summary') return { error: `unknown argument '${flag}'` };
    if (value === undefined || value.startsWith('--')) return { error: `${flag} needs a value` };
    if (seen.has(flag)) return { error: `${flag} given twice` };
    seen.set(flag, value);
  }
  const stage = seen.get('--stage');
  const site = seen.get('--site');
  if (stage === undefined) return { error: '--stage is required' };
  if (!(STAGES as readonly string[]).includes(stage)) return { error: `unknown stage '${stage}'` };
  if (site === undefined) return { error: '--site is required' };
  let url: URL;
  try {
    url = new URL(site);
  } catch {
    return { error: `--site '${site}' is not a URL` };
  }
  // http only for a loopback site (a local preview); a stage's site is https.
  const loopback = url.hostname === '127.0.0.1' || url.hostname === 'localhost';
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback)) return { error: `--site '${site}' is not an https URL` };
  if (url.pathname !== '/' || url.search !== '' || url.hash !== '' || url.username !== '' || url.password !== '') {
    return { error: `--site '${site}' must be an origin, with no path, query or credentials` };
  }
  const dist = seen.get('--dist');
  if (dist === undefined) return { error: '--dist is required' };
  return { stage: stage as Stage, origin: url.origin, hostname: url.hostname, dist, summary: seen.get('--summary') ?? null };
}

/** What the page builds for an address: src/app.ts's appView, or a stand-in in a test. */
export type Render = <N>(doc: Doc<N>, pathname: string, search: string, api: Client | null, host: string) => Promise<View<N>>;

export interface Deps {
  /** A GET of an absolute URL. */
  fetch: (url: string, init: { method: 'GET'; signal?: AbortSignal | null }) => Promise<Response>;
  wait: (ms: number) => Promise<void>;
  /** The timer of the client's deadline on each API request (src/api.ts, TIMEOUT_MS). */
  timers: Timers;
  out: (line: string) => void;
  err: (line: string) => void;
  appendSummary: (file: string, text: string) => void;
  /** A UTF-8 file of this commit's build. */
  readFile: (path: string) => string;
  render: Render;
}

const TRANSIENT_KINDS: ReadonlySet<string> = new Set(['network', 'timeout', 'busy']);

/** A transient failure, worth another try: no answer, a timeout, 429 or 503 (busy), or a 5xx. */
function transient(r: { kind: string; status?: number }): boolean {
  return TRANSIENT_KINDS.has(r.kind) || (r.kind === 'server' && Number(r.status) >= 500);
}

/** The text a reader sees in a node: its text content, as the DOM's textContent gives it. */
export function textContent(n: SNode): string {
  return 'tag' in n ? n.children.map(textContent).join('') : n.text;
}

/** The first `<section class="readme">` in the view's nodes, depth first. */
export function readmeNode(nodes: readonly SNode[]): SElement | null {
  for (const n of nodes) {
    if (!('tag' in n)) continue;
    if (n.tag === 'section' && n.attrs.some(([k, v]) => k === 'class' && v.split(' ').includes('readme'))) return n;
    const inner = readmeNode(n.children);
    if (inner !== null) return inner;
  }
  return null;
}

/**
 * The text around the first marker (40 characters before it, 60 after), quoted, for the failure line. A page's text has
 * no line breaks between blocks (textContent joins them), so a window, not a line.
 */
export function excerpt(text: string): string {
  const at = text.indexOf(MARKER);
  const from = Math.max(0, at - 40);
  const to = Math.min(text.length, at + MARKER.length + 60);
  return JSON.stringify(`${from > 0 ? '...' : ''}${text.slice(from, to)}${to < text.length ? '...' : ''}`);
}

function count(text: string): number {
  return text.split(MARKER).length - 1;
}

const SHELL_SCRIPT = /<script type="module" src="(\/assets\/[0-9a-f]+\/main\.js)"><\/script>/;

/** The page script a page loads, `/assets/<id>/main.js`, or null. */
export function entryOf(html: string): string | null {
  const m = SHELL_SCRIPT.exec(html);
  return m === null ? null : m[1];
}

/**
 * What is wrong with the shell the site host served for the package's address; empty when it is the app shell that loads
 * `entry`, the page script of this commit's build.
 */
export function shellProblems(status: number, contentType: string | null, body: string, entry: string): string[] {
  if (status !== 200) return [`the package address answered HTTP ${status} (the app shell expected)`];
  const out: string[] = [];
  if (contentType === null || !contentType.toLowerCase().startsWith('text/html')) out.push(`the package address has content-type ${contentType ?? '(none)'}`);
  if (!body.includes('<body data-page="app">')) out.push('the package address is not the app shell (no <body data-page="app">)');
  if (!body.includes('<main id="main"')) out.push('the app shell has no <main id="main"> for the page script to fill');
  const served = entryOf(body);
  if (served === null) out.push('the app shell loads no /assets/<id>/main.js module');
  else if (served !== entry) out.push(`the app shell loads ${served}, and this commit's build loads ${entry}: the stage serves another build of the site`);
  if (body.includes(MARKER)) out.push(`the app shell itself holds ${MARKER}: ${excerpt(body)}`);
  return out;
}

export type Outcome = { kind: 'pass' } | { kind: 'skip'; reason: string } | { kind: 'fail' };

export interface Report {
  outcome: Outcome;
  /** Every line printed, in order. */
  lines: string[];
}

/** Runs the check against a stage's site. */
export async function check(flags: Flags, d: Deps): Promise<Report> {
  const lines: string[] = [];
  const failures: string[] = [];
  let skip: string | null = null;
  const ok = (s: string): void => {
    lines.push(`ok: ${s}`);
    d.out(`ok: ${s}`);
  };
  const fail = (s: string): void => {
    failures.push(s);
    lines.push(`FAIL: ${s}`);
    d.err(`FAIL: ${s}`);
  };
  const target = TARGETS[flags.stage];
  const name = fullName(target.pkg);
  const path = packagePath(target.pkg);

  // The shell: a GET with the tries of a transient answer; the last answer, or null when none came.
  const getShell = async (url: string): Promise<Response | null> => {
    let last: Response | null = null;
    for (let i = 1; i <= TRIES; i += 1) {
      if (i > 1) await d.wait(RETRY_WAIT_MS);
      try {
        last = await d.fetch(url, { method: 'GET' });
      } catch {
        last = null;
        continue;
      }
      if (last.status !== 429 && last.status < 500) return last;
    }
    return last;
  };

  // 1. This commit's page script, then the prerendered shell, which must load it.
  const appHtml = join(flags.dist, 'app.html');
  let entry: string | null = null;
  try {
    entry = entryOf(d.readFile(appHtml));
    if (entry === null) fail(`${appHtml} loads no /assets/<id>/main.js module`);
  } catch {
    fail(`${appHtml} cannot be read; build the site first (npm run build)`);
  }
  const shell = await getShell(flags.origin + path);
  if (shell === null) fail(`${path}: no answer from ${flags.origin} in ${TRIES} tries`);
  else if (entry !== null) {
    const problems = shellProblems(shell.status, shell.headers.get('content-type'), await shell.text(), entry);
    if (problems.length === 0) ok(`${path} is the app shell, with this commit's ${entry}`);
    for (const p of problems) fail(p);
  }

  // 2. The view the page script builds there: the site's client on the site's own /api/v2, the site's appView. The
  // page's fetch is same-origin and relative; here it is the same GET, made absolute against the site. A transient
  // answer is asked again, each try with the client's own deadline; the view is built from the last answer.
  const fetchFn: FetchFn = (url, init) => d.fetch(flags.origin + url, { method: 'GET', signal: init.signal });
  const base = client(fetchFn, API_BASE, TIMEOUT_MS, d.timers);
  let answer: Result<PackageInfo> | null = null;
  const api: Client = {
    ...base,
    getPackage: async (f) => {
      let r = await base.getPackage(f);
      for (let i = 2; i <= TRIES && r.kind !== 'ok' && transient(r); i += 1) {
        await d.wait(RETRY_WAIT_MS);
        r = await base.getPackage(f);
      }
      answer = r;
      return r;
    },
  };
  const view = await d.render(new StringDoc(), path, '', api, flags.hostname);
  const got = answer as Result<PackageInfo> | null;

  if (got === null) fail(`the page at ${path} asked the API for no package (not a package view)`);
  else if (got.kind !== 'ok') {
    const status = got.status === undefined ? 'no answer' : `HTTP ${got.status}`;
    const code = got.code === undefined ? '' : ` ${got.code}`;
    if (got.kind === 'notFound' && !target.required) {
      skip = `${flags.stage} holds no ${name} (the group-e2e job publishes it); there is no readme to check`;
    } else if (got.kind === 'notFound') {
      fail(`${flags.stage} must hold ${name}; ${API_BASE}${path}: ${status}${code}`);
    } else {
      const tries = transient(got) ? ` after ${TRIES} tries` : '';
      fail(`${API_BASE}${path}: ${status}${code}${tries}: ${got.message}`);
    }
  } else {
    const readme = got.value.readme;
    if (readme === undefined || readme.trim() === '') skip = `${name} on ${flags.stage} has no readme; there is nothing to check`;
    else if (!readme.includes(MARKER)) skip = `the readme of ${name} on ${flags.stage} holds no ${MARKER} line, so this run proves nothing`;
    else if (new TextEncoder().encode(readme).length > README_MAX_BYTES) {
      skip = `the readme of ${name} on ${flags.stage} is over ${README_MAX_BYTES} bytes, so the page shows a note instead of it`;
    } else {
      const section = readmeNode(view.nodes);
      if (section === null) fail(`the page of ${name} shows no readme section, though the API sent a readme`);
      else {
        const shown = textContent(section);
        const n = count(shown);
        if (n === 0) ok(`the readme of ${name} holds ${count(readme)} ${MARKER} line(s); the page shows none of them`);
        else fail(`the page of ${name} shows ${MARKER} ${n} time(s) in its readme, first in ${excerpt(shown)}`);
      }
    }
  }

  let outcome: Outcome;
  if (failures.length > 0) outcome = { kind: 'fail' };
  else if (skip !== null) {
    outcome = { kind: 'skip', reason: skip };
    lines.push(`SKIP: ${skip}`);
    d.out(`SKIP: ${skip}`);
    // A workflow command: GitHub shows it as a warning on the run. A newline would end the command early.
    d.out(`::warning title=Readme check skipped::${skip.replace(/[\r\n]/g, ' ')}`);
  } else outcome = { kind: 'pass' };

  if (flags.summary !== null) {
    const heading = outcome.kind === 'fail' ? 'FAILED' : outcome.kind === 'skip' ? 'SKIPPED' : 'passed';
    d.appendSummary(flags.summary, [`### Readme check on ${flags.stage}: ${heading}`, '', ...lines.map((l) => `- ${l}`), ''].join('\n'));
  }
  return { outcome, lines };
}

/** The program: 0 when the check passes or skips, 1 when it fails, 2 for a bad command line. */
export async function main(argv: readonly string[], d: Deps): Promise<number> {
  const flags = parseFlags(argv);
  if ('error' in flags) {
    d.err(`readme-e2e: ${flags.error}`);
    d.err(USAGE);
    return 2;
  }
  const r = await check(flags, d);
  return r.outcome.kind === 'fail' ? 1 : 0;
}

export function defaultDeps(): Deps {
  return {
    fetch: (url, init) => fetch(url, init),
    wait: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    timers: { set: (fn, ms) => setTimeout(fn, ms), clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>) },
    out: (line) => process.stdout.write(`${line}\n`),
    err: (line) => process.stderr.write(`${line}\n`),
    appendSummary: (file, text) => appendFileSync(file, text),
    readFile: (path) => readFileSync(path, 'utf8'),
    render: appView,
  };
}

/** Runs main when this module is the program (`node build/tools/tools/readme-e2e.js ...`), setting the exit status. */
export function runIfMain(isMain: boolean, proc: { argv: readonly string[]; exitCode?: number | string }, deps: () => Deps): Promise<number> | null {
  if (!isMain) return null;
  return main(proc.argv.slice(2), deps()).then((status) => {
    if (status !== 0) proc.exitCode = status;
    return status;
  });
}

void runIfMain(require.main === module, process, defaultDeps);
