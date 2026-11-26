// The readme check run after each deploy (tools/readme-e2e.ts), against a fake site: an injected fetch answers the
// package address with the real app shell (tools/layout.ts's renderPage of tools/pages.ts's appShell) and /api/v2 with
// the contract's package answer, carrying komira-ai/json's readme as komira holds it (fixtures/komira-json-readme.md,
// five `mojo-hidden` lines). What it holds: the site's own renderer shows none of them and the check passes; a renderer
// that keeps a comment as text, as the parser did before komira-ai/mopm#408, makes it fail and name the marker; each
// skip and each failure has its exact line; transient answers are tried five times, others once; the requests are two
// GETs, nothing else; the workflow job runs the program as this file runs it, on a stage host the page has an API for.
import { readFileSync, rmSync } from 'fs';
import { join } from 'path';
import type { Client } from '../src/api';
import { appView } from '../src/app';
import { type Doc, h, type SNode, StringDoc } from '../src/doc';
import { apiBase } from '../src/host';
import type { View } from '../src/views/common';
import { renderPage } from '../tools/layout';
import { appShell, notFoundPage } from '../tools/pages';
import {
  check, defaultDeps, type Deps, entryOf, excerpt, type Flags, main, MARKER, parseFlags, readmeNode, type Render, RETRY_WAIT_MS, runIfMain,
  shellProblems, STAGES, TARGETS, textContent, TRIES, USAGE,
} from '../tools/readme-e2e';
import { REPO_ROOT, scratch } from './build-fixture';
import { load } from './fixtures';

const KOMIRA_README = readFileSync(join(__dirname, 'fixtures', 'komira-json-readme.md'), 'utf8');
const ASSETS = { base: '/assets/0a1b2c3d/', entry: 'main.js', preload: [] };
const SHELL = renderPage(appShell(), ASSETS);
const ENTRY = '/assets/0a1b2c3d/main.js';
/** This commit's build as the check reads it: dist/app.html is SHELL. */
const BUILD: Record<string, string> = { [join('dist', 'app.html')]: SHELL };
const PACKAGE_INFO = (() => {
  const c = load('packages').find((x) => x.name === 'package info');
  if (c === undefined) throw new Error("no contract case 'package info'");
  return c.response.body as Record<string, unknown>;
})();

// ---- the fake site ------------------------------------------------------------------------------------------------

type Answer = { status: number; body: string; type?: string } | 'no answer';

const html = (body: string, status = 200): Answer => ({ status, body, type: 'text/html; charset=utf-8' });
const json = (body: unknown, status = 200): Answer => ({ status, body: JSON.stringify(body), type: 'application/json' });
const envelope = (code: string, status: number): Answer => json({ error: { code, message: `the registry says ${code}` } }, status);
const pkg = (readme: string | undefined, name = 'komira-ai/json'): Answer => {
  const body: Record<string, unknown> = { ...PACKAGE_INFO, name };
  if (readme !== undefined) body.readme = readme;
  return json(body);
};

/** A site whose addresses answer in turn from their lists (the last answer repeats); every request is recorded. */
function fakeSite(routes: Record<string, Answer[]>): { fetch: Deps['fetch']; calls: string[] } {
  const calls: string[] = [];
  const served = new Map<string, number>();
  const fetch: Deps['fetch'] = async (url, init) => {
    calls.push(`${init.method} ${url}`);
    if (init.signal?.aborted === true) throw new Error('aborted');
    const list = routes[url];
    if (list === undefined) throw new Error(`the fake site has no ${url}`);
    const i = served.get(url) ?? 0;
    served.set(url, i + 1);
    const a = list[Math.min(i, list.length - 1)];
    if (a === 'no answer') throw new TypeError('fetch failed');
    return new Response(a.body, { status: a.status, headers: a.type === undefined ? {} : { 'content-type': a.type } });
  };
  return { fetch, calls };
}

interface Run {
  deps: Deps;
  out: string[];
  err: string[];
  waits: number[];
  summaries: [string, string][];
}

const NEVER: Deps['timers'] = { set: () => 0, clear: () => undefined };

function run(site: { fetch: Deps['fetch'] }, over: Partial<Deps> = {}): Run {
  const r: Run = { deps: undefined as unknown as Deps, out: [], err: [], waits: [], summaries: [] };
  r.deps = {
    fetch: site.fetch,
    wait: async (ms) => {
      r.waits.push(ms);
    },
    timers: NEVER,
    out: (l) => r.out.push(l),
    err: (l) => r.err.push(l),
    appendSummary: (file, text) => r.summaries.push([file, text]),
    readFile: (path) => {
      const text = BUILD[path];
      if (text === undefined) throw new Error(`ENOENT: ${path}`);
      return text;
    },
    render: appView,
    ...over,
  };
  return r;
}

const PROD: Flags = { stage: 'prod', origin: 'https://mopm.dev', hostname: 'mopm.dev', dist: 'dist', summary: null };
const BETA: Flags = { stage: 'beta', origin: 'https://beta.mopm.dev', hostname: 'beta.mopm.dev', dist: 'dist', summary: null };
const PROD_PAGE = 'https://mopm.dev/packages/komira-ai/json';
const PROD_API = 'https://mopm.dev/api/v2/packages/komira-ai/json';
const BETA_PAGE = 'https://beta.mopm.dev/packages/zz-e2e/zz_e2e_app';
const BETA_API = 'https://beta.mopm.dev/api/v2/packages/zz-e2e/zz_e2e_app';

const SHELL_OK = "ok: /packages/komira-ai/json is the app shell, with this commit's /assets/0a1b2c3d/main.js";
const BETA_SHELL_OK = "ok: /packages/zz-e2e/zz_e2e_app is the app shell, with this commit's /assets/0a1b2c3d/main.js";
const PROD_PASS = 'ok: the readme of komira-ai/json holds 5 mojo-hidden line(s); the page shows none of them';

const prodSite = (api: Answer[], page: Answer[] = [html(SHELL)]) => fakeSite({ [PROD_PAGE]: page, [PROD_API]: api });

/**
 * The page as the parser before komira-ai/mopm#408 made it: an HTML comment was raw HTML, kept as text. The site's own
 * appView, sent the readme with each `<!--` escaped (`\<!--`), so the renderer keeps every comment as text.
 */
const commentAsText: Render = <N>(doc: Doc<N>, pathname: string, search: string, api: Client | null, host: string): Promise<View<N>> => {
  const keep: Client | null = api === null ? null : {
    ...api,
    getPackage: async (f) => {
      const r = await api.getPackage(f);
      return r.kind === 'ok' && r.value.readme !== undefined ? { ...r, value: { ...r.value, readme: r.value.readme.replace(/<!--/g, '\\<!--') } } : r;
    },
  };
  return appView(doc, pathname, search, keep, host);
};

// ---- the check ----------------------------------------------------------------------------------------------------

describe('readme-e2e: the package page of each stage', () => {
  test('prod: the site renders komira-ai/json without its five mojo-hidden lines, in two GETs', async () => {
    const site = prodSite([pkg(KOMIRA_README)]);
    const r = run(site);
    const report = await check(PROD, r.deps);
    expect(report).toEqual({ outcome: { kind: 'pass' }, lines: [SHELL_OK, PROD_PASS] });
    expect(site.calls).toEqual([`GET ${PROD_PAGE}`, `GET ${PROD_API}`]);
    expect(r.out).toEqual([SHELL_OK, PROD_PASS]);
    expect(r.err).toEqual([]);
    expect(r.waits).toEqual([]);
    expect(await main(['--stage', 'prod', '--site', 'https://mopm.dev', '--dist', 'dist'], run(prodSite([pkg(KOMIRA_README)])).deps)).toBe(0);
  });

  test('a page that shows the comments as text, as before komira-ai/mopm#408, fails and names the marker', async () => {
    const r = run(prodSite([pkg(KOMIRA_README)]), { render: commentAsText });
    const report = await check(PROD, r.deps);
    expect(report.outcome).toEqual({ kind: 'fail' });
    expect(report.lines).toHaveLength(2);
    expect(report.lines[0]).toBe(SHELL_OK);
    expect(report.lines[1]).toMatch(/^FAIL: the page of komira-ai\/json shows mojo-hidden 5 time\(s\) in its readme, first in "/);
    expect(report.lines[1]).toContain('<!-- mojo-hidden from std.testing import');
    expect(r.err).toEqual([report.lines[1]]);
    expect(await main(['--stage', 'prod', '--site', 'https://mopm.dev', '--dist', 'dist'], run(prodSite([pkg(KOMIRA_README)]), { render: commentAsText }).deps)).toBe(1);
  });

  test('a readme section that shows the marker once fails with the count and the text around it', async () => {
    const one: Render = async <N>(doc: Doc<N>, pathname: string, search: string, api: Client | null) => {
      await api?.getPackage(TARGETS.prod.pkg);
      return { title: 'x', nodes: [h(doc, 'section', { class: 'readme' }, h(doc, 'h2', null, 'Readme'), h(doc, 'p', null, `x ${MARKER} y`))] };
    };
    const report = await check(PROD, run(prodSite([pkg(KOMIRA_README)]), { render: one }).deps);
    expect(report.lines).toEqual([SHELL_OK, 'FAIL: the page of komira-ai/json shows mojo-hidden 1 time(s) in its readme, first in "Readmex mojo-hidden y"']);
  });

  test('beta: the fixture package of group-e2e passes when its readme holds the hidden line', async () => {
    const readme = '# zz_e2e_app\n\nInstall it, then:\n\n<!-- mojo-hidden from std.testing import assert_equal -->\n```mojo\nfrom zz_e2e_app import total\n```\n';
    const site = fakeSite({ [BETA_PAGE]: [html(SHELL)], [BETA_API]: [pkg(readme, 'zz-e2e/zz_e2e_app')] });
    const report = await check(BETA, run(site).deps);
    expect(report).toEqual({
      outcome: { kind: 'pass' },
      lines: [BETA_SHELL_OK, 'ok: the readme of zz-e2e/zz_e2e_app holds 1 mojo-hidden line(s); the page shows none of them'],
    });
    expect(site.calls).toEqual([`GET ${BETA_PAGE}`, `GET ${BETA_API}`]);
  });

  test('beta without the fixture package skips, loudly, and the program ends 0', async () => {
    const reason = 'beta holds no zz-e2e/zz_e2e_app (the group-e2e job publishes it); there is no readme to check';
    const site = () => fakeSite({ [BETA_PAGE]: [html(SHELL)], [BETA_API]: [envelope('package_not_found', 404)] });
    const r = run(site());
    const report = await check({ ...BETA, summary: 'summary.md' }, r.deps);
    expect(report).toEqual({ outcome: { kind: 'skip', reason }, lines: [BETA_SHELL_OK, `SKIP: ${reason}`] });
    expect(r.out).toEqual([BETA_SHELL_OK, `SKIP: ${reason}`, `::warning title=Readme check skipped::${reason}`]);
    expect(r.summaries).toEqual([
      ['summary.md', `### Readme check on beta: SKIPPED\n\n- ${BETA_SHELL_OK}\n- SKIP: ${reason}\n`],
    ]);
    expect(r.waits).toEqual([]);
    expect(await main(['--stage', 'beta', '--site', 'https://beta.mopm.dev', '--dist', 'dist'], run(site()).deps)).toBe(0);
  });

  test('prod must hold komira-ai/json: a 404, with or without an error envelope, fails', async () => {
    for (const [answer, said] of [
      [envelope('package_not_found', 404), 'HTTP 404 package_not_found'],
      [{ status: 404, body: 'Not Found', type: 'text/plain' }, 'HTTP 404'],
    ] as [Answer, string][]) {
      const report = await check(PROD, run(prodSite([answer])).deps);
      expect(report).toEqual({ outcome: { kind: 'fail' }, lines: [SHELL_OK, `FAIL: prod must hold komira-ai/json; /api/v2/packages/komira-ai/json: ${said}`] });
    }
  });

  test('each readme that cannot prove anything skips with its reason', async () => {
    const big = `<!-- mojo-hidden x -->\n${'a'.repeat(65_536)}\n`;
    for (const [readme, reason] of [
      [undefined, 'komira-ai/json on prod has no readme; there is nothing to check'],
      [' \n\t\n', 'komira-ai/json on prod has no readme; there is nothing to check'],
      ['# json\n\nNo hidden lines here.\n', 'the readme of komira-ai/json on prod holds no mojo-hidden line, so this run proves nothing'],
      [big, 'the readme of komira-ai/json on prod is over 65536 bytes, so the page shows a note instead of it'],
    ] as [string | undefined, string][]) {
      const report = await check(PROD, run(prodSite([pkg(readme)])).deps);
      expect(report).toEqual({ outcome: { kind: 'skip', reason }, lines: [SHELL_OK, `SKIP: ${reason}`] });
    }
  });

  test('a transient API answer is tried five times, 5 s apart, and then fails with its status and code', async () => {
    const r = run(prodSite([envelope('unavailable', 503)]));
    const report = await check(PROD, r.deps);
    expect(report).toEqual({
      outcome: { kind: 'fail' },
      lines: [SHELL_OK, 'FAIL: /api/v2/packages/komira-ai/json: HTTP 503 unavailable after 5 tries: The registry is busy; try again shortly.'],
    });
    expect(r.waits).toEqual(Array(TRIES - 1).fill(RETRY_WAIT_MS));
  });

  test('a transient API answer followed by the package passes, after as many waits as failed tries', async () => {
    const site = prodSite([envelope('internal_error', 500), { status: 502, body: 'Bad Gateway' }, pkg(KOMIRA_README)]);
    const r = run(site);
    expect((await check(PROD, r.deps)).lines).toEqual([SHELL_OK, PROD_PASS]);
    expect(r.waits).toEqual([RETRY_WAIT_MS, RETRY_WAIT_MS]);
    expect(site.calls.filter((c) => c === `GET ${PROD_API}`)).toHaveLength(3);
  });

  test('no answer, or a deadline reached on every try, fails as no answer after five tries', async () => {
    const none = run(prodSite(['no answer']));
    expect((await check(PROD, none.deps)).lines).toEqual([
      SHELL_OK,
      'FAIL: /api/v2/packages/komira-ai/json: no answer after 5 tries: The registry could not be reached. Check your connection and try again.',
    ]);
    // A deadline timer that fires as soon as it is set: the client aborts each request and reports a timeout.
    const fire: Deps['timers'] = { set: (fn) => (fn(), 0), clear: () => undefined };
    const late = prodSite([pkg(KOMIRA_README)]);
    const r = run(late, { timers: fire });
    expect((await check(PROD, r.deps)).lines).toEqual([
      SHELL_OK,
      'FAIL: /api/v2/packages/komira-ai/json: no answer after 5 tries: The registry took too long to answer. Try again.',
    ]);
    expect(late.calls.filter((c) => c === `GET ${PROD_API}`)).toHaveLength(TRIES);
  });

  test('an answer that is not transient is not asked again: a refused name, an unreadable body', async () => {
    for (const [answer, line] of [
      [envelope('invalid_name', 400), 'FAIL: /api/v2/packages/komira-ai/json: HTTP 400 invalid_name: The registry did not accept this request.'],
      [json({ name: 'komira-ai/json' }), 'FAIL: /api/v2/packages/komira-ai/json: HTTP 200: The registry sent an answer this page cannot read.'],
    ] as [Answer, string][]) {
      const r = run(prodSite([answer]));
      expect((await check(PROD, r.deps)).lines).toEqual([SHELL_OK, line]);
      expect(r.waits).toEqual([]);
    }
  });

  test('a page that asks for no package, or shows no readme section for a readme it was sent, fails', async () => {
    const noCall: Render = async () => ({ title: 'x', nodes: [] });
    expect((await check(PROD, run(prodSite([pkg(KOMIRA_README)]), { render: noCall }).deps)).lines).toEqual([
      SHELL_OK,
      'FAIL: the page at /packages/komira-ai/json asked the API for no package (not a package view)',
    ]);
    const noSection: Render = async <N>(doc: Doc<N>, pathname: string, search: string, api: Client | null) => {
      await api?.getPackage(TARGETS.prod.pkg);
      return { title: 'x', nodes: [h(doc, 'section', { class: 'versions' }, 'Versions')] };
    };
    expect((await check(PROD, run(prodSite([pkg(KOMIRA_README)]), { render: noSection }).deps)).lines).toEqual([
      SHELL_OK,
      'FAIL: the page of komira-ai/json shows no readme section, though the API sent a readme',
    ]);
  });

  test('a wrong shell fails and the readme is still checked, so one run names every problem', async () => {
    const r = run(prodSite([pkg(KOMIRA_README)], [html(renderPage(notFoundPage(), ASSETS), 404)]));
    const report = await check({ ...PROD, summary: 's.md' }, r.deps);
    expect(report).toEqual({ outcome: { kind: 'fail' }, lines: ['FAIL: the package address answered HTTP 404 (the app shell expected)', PROD_PASS] });
    expect(r.summaries).toEqual([['s.md', `### Readme check on prod: FAILED\n\n- FAIL: the package address answered HTTP 404 (the app shell expected)\n- ${PROD_PASS}\n`]]);
  });

  test("the stage must serve this commit's page script; a build that cannot be read, or names none, fails", async () => {
    const other = run(prodSite([pkg(KOMIRA_README)], [html(SHELL.replace(ENTRY, '/assets/ffff/main.js'))]));
    expect((await check(PROD, other.deps)).lines).toEqual([
      "FAIL: the app shell loads /assets/ffff/main.js, and this commit's build loads /assets/0a1b2c3d/main.js: the stage serves another build of the site",
      PROD_PASS,
    ]);
    const unbuilt = run(prodSite([pkg(KOMIRA_README)]));
    expect((await check({ ...PROD, dist: 'nowhere' }, unbuilt.deps)).lines).toEqual([
      `FAIL: ${join('nowhere', 'app.html')} cannot be read; build the site first (npm run build)`,
      PROD_PASS,
    ]);
    const noScript = run(prodSite([pkg(KOMIRA_README)]), { readFile: () => '<html></html>' });
    expect((await check(PROD, noScript.deps)).lines).toEqual([`FAIL: ${join('dist', 'app.html')} loads no /assets/<id>/main.js module`, PROD_PASS]);
  });

  test('the shell is tried five times on no answer, 429 or a 5xx; the last answer is judged', async () => {
    const none = run(prodSite([pkg(KOMIRA_README)], ['no answer']));
    expect((await check(PROD, none.deps)).lines).toEqual(['FAIL: /packages/komira-ai/json: no answer from https://mopm.dev in 5 tries', PROD_PASS]);
    expect(none.waits).toEqual(Array(TRIES - 1).fill(RETRY_WAIT_MS));
    const bad = run(prodSite([pkg(KOMIRA_README)], [html('down', 502)]));
    expect((await check(PROD, bad.deps)).lines).toEqual(['FAIL: the package address answered HTTP 502 (the app shell expected)', PROD_PASS]);
    const busy = run(prodSite([pkg(KOMIRA_README)], [html('slow down', 429), 'no answer', html(SHELL)]));
    expect(await check({ ...PROD, summary: 's.md' }, busy.deps)).toEqual({ outcome: { kind: 'pass' }, lines: [SHELL_OK, PROD_PASS] });
    expect(busy.waits).toEqual([RETRY_WAIT_MS, RETRY_WAIT_MS]);
    expect(busy.summaries).toEqual([['s.md', `### Readme check on prod: passed\n\n- ${SHELL_OK}\n- ${PROD_PASS}\n`]]);
  });
});

// ---- the parts ----------------------------------------------------------------------------------------------------

describe('readme-e2e: the shell, the text and the flags', () => {
  test('shellProblems: the real app shell is the app shell; every way it can be wrong is named', () => {
    expect(shellProblems(200, 'text/html; charset=utf-8', SHELL, ENTRY)).toEqual([]);
    expect(shellProblems(200, 'TEXT/HTML', SHELL, ENTRY)).toEqual([]);
    expect(shellProblems(301, 'text/html', SHELL, ENTRY)).toEqual(['the package address answered HTTP 301 (the app shell expected)']);
    expect(shellProblems(200, 'application/json', SHELL, ENTRY)).toEqual(['the package address has content-type application/json']);
    expect(shellProblems(200, null, SHELL, ENTRY)).toEqual(['the package address has content-type (none)']);
    expect(shellProblems(200, 'text/html', renderPage(notFoundPage(), ASSETS), ENTRY)).toEqual(['the package address is not the app shell (no <body data-page="app">)']);
    expect(shellProblems(200, 'text/html', '<html></html>', ENTRY)).toEqual([
      'the package address is not the app shell (no <body data-page="app">)',
      'the app shell has no <main id="main"> for the page script to fill',
      'the app shell loads no /assets/<id>/main.js module',
    ]);
    expect(shellProblems(200, 'text/html', SHELL, '/assets/ffff/main.js')).toEqual([
      "the app shell loads /assets/0a1b2c3d/main.js, and this commit's build loads /assets/ffff/main.js: the stage serves another build of the site",
    ]);
    expect(entryOf(SHELL)).toBe(ENTRY);
    expect(entryOf('<script src="/assets/0a1b2c3d/main.js"></script>')).toBeNull();
    const marked = SHELL.replace('</main>', `<p>${MARKER}</p></main>`);
    expect(shellProblems(200, 'text/html', marked, ENTRY)).toEqual([`the app shell itself holds mojo-hidden: ${excerpt(marked)}`]);
  });

  test('excerpt: 40 characters before the marker and 60 after, quoted, with ... where text was cut', () => {
    expect(excerpt(MARKER)).toBe('"mojo-hidden"');
    expect(excerpt(`${'x'.repeat(50)}${MARKER}${'y'.repeat(70)}`)).toBe(`"...${'x'.repeat(40)}${MARKER}${'y'.repeat(60)}..."`);
    expect(excerpt(`a "q"\n${MARKER}`)).toBe('"a \\"q\\"\\nmojo-hidden"');
  });

  test('readmeNode and textContent: the first section with class readme, at any depth, and its text', () => {
    const doc = new StringDoc();
    const readme = h(doc, 'section', { class: 'prose readme', id: 'r' }, h(doc, 'h2', null, 'Readme'), h(doc, 'p', null, 'one ', h(doc, 'code', null, 'two')));
    const nodes: SNode[] = [doc.text('lead'), h(doc, 'div', null, h(doc, 'section', { class: 'readmes' }, 'not it'), h(doc, 'div', null, readme))];
    expect(readmeNode(nodes)).toBe(readme);
    expect(textContent(readme)).toBe('Readmeone two');
    expect(readmeNode([h(doc, 'section', { 'aria-label': 'readme' }, 'x')])).toBeNull();
  });

  test('parseFlags: a stage, a site origin and an optional summary file; everything else is refused by name', () => {
    expect(parseFlags(['--stage', 'beta', '--site', 'https://beta.mopm.dev', '--dist', 'dist'])).toEqual(BETA);
    expect(parseFlags(['--site', 'https://mopm.dev/', '--dist', 'dist', '--stage', 'prod', '--summary', 'out.md'])).toEqual({ ...PROD, summary: 'out.md' });
    expect(parseFlags(['--stage', 'gamma', '--site', 'http://127.0.0.1:4173', '--dist', 'd'])).toEqual({ stage: 'gamma', origin: 'http://127.0.0.1:4173', hostname: '127.0.0.1', dist: 'd', summary: null });
    expect(parseFlags(['--stage', 'gamma', '--site', 'http://localhost:4173', '--dist', 'd'])).toEqual({ stage: 'gamma', origin: 'http://localhost:4173', hostname: 'localhost', dist: 'd', summary: null });
    const refused: [string[], string][] = [
      [['--stages', 'beta'], "unknown argument '--stages'"],
      [['--stage'], '--stage needs a value'],
      [['--stage', '--site'], '--stage needs a value'],
      [['--stage', 'beta', '--stage', 'prod'], '--stage given twice'],
      [['--site', 'https://mopm.dev'], '--stage is required'],
      [['--stage', 'dev', '--site', 'https://mopm.dev'], "unknown stage 'dev'"],
      [['--stage', 'prod'], '--site is required'],
      [['--stage', 'prod', '--site', 'https://mopm.dev'], '--dist is required'],
      [['--stage', 'prod', '--site', 'https://mopm.dev', '--dist'], '--dist needs a value'],
      [['--stage', 'prod', '--site', 'mopm.dev'], "--site 'mopm.dev' is not a URL"],
      [['--stage', 'prod', '--site', 'http://mopm.dev'], "--site 'http://mopm.dev' is not an https URL"],
      [['--stage', 'prod', '--site', 'ftp://127.0.0.1'], "--site 'ftp://127.0.0.1' is not an https URL"],
      [['--stage', 'prod', '--site', 'https://mopm.dev/packages'], "--site 'https://mopm.dev/packages' must be an origin, with no path, query or credentials"],
      [['--stage', 'prod', '--site', 'https://mopm.dev/?a=1'], "--site 'https://mopm.dev/?a=1' must be an origin, with no path, query or credentials"],
      [['--stage', 'prod', '--site', 'https://mopm.dev/#x'], "--site 'https://mopm.dev/#x' must be an origin, with no path, query or credentials"],
      [['--stage', 'prod', '--site', 'https://u@mopm.dev'], "--site 'https://u@mopm.dev' must be an origin, with no path, query or credentials"],
      [['--stage', 'prod', '--site', 'https://u:p@mopm.dev'], "--site 'https://u:p@mopm.dev' must be an origin, with no path, query or credentials"],
    ];
    for (const [argv, error] of refused) expect(parseFlags(argv)).toEqual({ error });
  });

  test('main: a bad command line prints the reason and the usage and ends 2, without a request', async () => {
    const site = fakeSite({});
    const r = run(site);
    expect(await main(['--stage', 'prod'], r.deps)).toBe(2);
    expect(r.err).toEqual(['readme-e2e: --site is required', USAGE]);
    expect(site.calls).toEqual([]);
  });

  test('runIfMain: nothing when imported; as the program, the exit status of a failure and none for a pass', async () => {
    const proc: { argv: string[]; exitCode?: number | string } = { argv: ['node', 'readme-e2e.js'] };
    expect(runIfMain(false, proc, () => run(fakeSite({})).deps)).toBeNull();
    expect(await runIfMain(true, proc, () => run(fakeSite({})).deps)).toBe(2);
    expect(proc.exitCode).toBe(2);
    const ok: { argv: string[]; exitCode?: number | string } = { argv: ['node', 'readme-e2e.js', '--stage', 'prod', '--site', 'https://mopm.dev', '--dist', 'dist'] };
    expect(await runIfMain(true, ok, () => run(prodSite([pkg(KOMIRA_README)])).deps)).toBe(0);
    expect(ok.exitCode).toBeUndefined();
  });

  test("defaultDeps: the global fetch, the real timers, the process's streams, the summary appended, the site's appView", async () => {
    const d = defaultDeps();
    expect(d.render).toBe(appView);
    // test/setup.ts's global fetch throws: the default fetch is that one.
    expect(() => d.fetch('https://mopm.dev/', { method: 'GET' })).toThrow('network call in a test');
    await expect(d.wait(0)).resolves.toBeUndefined();
    let fired = false;
    d.timers.clear(d.timers.set(() => (fired = true), 60_000));
    expect(fired).toBe(false);
    const stdout = jest.spyOn(process.stdout, 'write').mockImplementation(() => true);
    const stderr = jest.spyOn(process.stderr, 'write').mockImplementation(() => true);
    try {
      d.out('ok: a');
      d.err('FAIL: b');
      expect(stdout).toHaveBeenCalledWith('ok: a\n');
      expect(stderr).toHaveBeenCalledWith('FAIL: b\n');
    } finally {
      stdout.mockRestore();
      stderr.mockRestore();
    }
    const dir = scratch('readme-e2e-');
    try {
      const file = join(dir, 'summary.md');
      d.appendSummary(file, 'one\n');
      d.appendSummary(file, 'two\n');
      expect(readFileSync(file, 'utf8')).toBe('one\ntwo\n');
      expect(d.readFile(file)).toBe('one\ntwo\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// ---- the targets and the workflow ---------------------------------------------------------------------------------

describe('readme-e2e: what it reads on each stage, and the job that runs it', () => {
  test('each stage reads its package on its own site host, which the page has an API for', () => {
    expect(STAGES).toEqual(['beta', 'gamma', 'prod']);
    expect(TARGETS).toEqual({
      prod: { pkg: { namespace: 'komira-ai', name: 'json' }, required: true },
      beta: { pkg: { namespace: 'zz-e2e', name: 'zz_e2e_app' }, required: false },
      gamma: { pkg: { namespace: 'zz-e2e', name: 'zz_e2e_app' }, required: false },
    });
    for (const stage of STAGES) {
      const config = JSON.parse(readFileSync(join(REPO_ROOT, 'service', 'config', `${stage}.json`), 'utf8')) as { siteDomain: string };
      const flags = parseFlags(['--stage', stage, '--site', `https://${config.siteDomain}`, '--dist', 'dist']);
      expect('error' in flags).toBe(false);
      expect(apiBase(config.siteDomain)).toBe('/api/v2');
    }
  });

  test('the readme-e2e job of e2e.yml builds the tools and runs the check read-only, on main, for the stage', () => {
    const workflow = readFileSync(join(REPO_ROOT, '.github', 'workflows', 'e2e.yml'), 'utf8');
    const start = workflow.indexOf('\n  readme-e2e:\n');
    expect(start).toBeGreaterThan(0);
    const rest = workflow.slice(start + 1);
    // The job ends at the next line indented as a job key is (the next job, or the comment above it).
    const next = rest.slice(1).search(/\n {2}\S/);
    const job = next < 0 ? rest : rest.slice(0, next + 1);
    expect(job).toContain('    needs: guard\n');
    expect(job).toContain("    if: github.ref == 'refs/heads/main'\n");
    expect(job).toContain('    permissions:\n      contents: read\n    steps:\n');
    expect(job).not.toMatch(/secrets\.|id-token|environment:|continue-on-error|\|\| true/);
    expect(job).toContain('        working-directory: site\n        run: npm run build\n');
    expect(job).toContain(
      '        run: node build/tools/tools/readme-e2e.js --stage "$STAGE" --site "https://$(jq -r .siteDomain "../service/config/${STAGE}.json")" --dist dist --summary "$GITHUB_STEP_SUMMARY"\n',
    );
  });
});
