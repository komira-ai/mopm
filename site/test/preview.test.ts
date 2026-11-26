// The local preview (tools/preview.ts), run as a real server on 127.0.0.1 with a port the system picks, and asked over
// loopback. E2B is a fake fetch, the clock and the deadline's timer are injected, and the site build is a small tree
// in the test scratch directory. What it holds: each scenario's answers to the three routes, equal to the contract's
// status and body; the sandbox route's checks in the real route's order; the create body sent to E2B, field for field
// section 4's; no call to E2B without a key; the key and the access token in no line it prints; the site's files with
// the site's headers, and nothing outside dist/.
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'fs';
import { request as httpRequest } from 'http';
import { dirname, join, resolve } from 'path';
import {
  type E2bFetch, E2B_CREATE_URL, E2B_DEADLINE_MS, type MainDeps, PREVIEW_CONNECT_SRC, PREVIEW_CSRF, type Preview,
  type PreviewOptions, REAL_TIMERS, type Scenario, SCENARIOS, type Timers, USAGE, decodeE2bSandbox, defaultDeps, main,
  distFor, pageFile, parseFlags, runIfMain, startPreview,
} from '../tools/preview';
import { securityHeaders } from '../tools/headers';
import { type ContractCase, load } from './fixtures';

const CASES = [...load('web-auth'), ...load('tutorial-sandbox')];
const named = (name: string): ContractCase => {
  const c = CASES.find((x) => x.name === name);
  if (c === undefined) throw new Error(`no contract case '${name}'`);
  return c;
};
const SESSION_REQUIRED = named('a sandbox request from a signed-out browser is refused as session_required');
const CSRF_FAILED = named('a sandbox request with a wrong CSRF value is refused as csrf_failed');
const WITH_BODY = named('a sandbox request with a body is refused as invalid_request');
const WITH_AUTHORIZATION = named('a sandbox request with an Authorization header is refused as invalid_request');
const UNAVAILABLE = named('a sandbox request while E2B does not answer is refused as tutorial_unavailable with Retry-After');
const GRANT = named('a signed-in user gets a sandbox and what the browser needs to reach it');
const SESSION = named('the signed-in user, with the CSRF value of the session');
const SESSION_AUTHORIZATION = named('the session with an Authorization header is refused as invalid_request');
const LOGOUT_SIGNED_OUT = named('sign out of a signed-out browser is refused as session_required');
const LOGOUT_CSRF = named('sign out with a wrong CSRF value is refused as csrf_failed');

// The request time of the contract's grant example (its expires_at is 30 minutes later).
const NOW = new Date('2026-11-19T12:00:00.000Z');
const REQUEST_ID = 'req-7f3a2c19d0e4';
// Built at run time: a fixed key-shaped literal would be a secret pattern in the tree.
const KEY = ['e2b', 'test', 'key'].join('-');

// ---- the site build -------------------------------------------------------------------------------------------------

const SCRATCH = join(__dirname, '..', 'build', 'test-scratch');
const PAGES: Record<string, string> = {
  'index.html': '<!doctype html><title>home</title>',
  'app.html': '<!doctype html><title>app</title>',
  '404.html': '<!doctype html><title>not found</title>',
  'docs/index.html': '<!doctype html><title>docs</title>',
  'docs/why/index.html': '<!doctype html><title>why</title>',
  'assets/0123456789abcdef/main.js': 'export {};\n',
  'assets/0123456789abcdef/site.css': 'body{}\n',
  'install.sh': '#!/bin/sh\n',
  'notes.bin': 'x',
  'empty/keep.txt': 'x',
};

let root: string;
let dist: string;
beforeAll(() => {
  mkdirSync(SCRATCH, { recursive: true });
  root = mkdtempSync(join(SCRATCH, 'preview-'));
  dist = join(root, 'dist');
  for (const [p, s] of Object.entries(PAGES)) {
    mkdirSync(dirname(join(dist, p)), { recursive: true });
    writeFileSync(join(dist, p), s);
  }
  // Outside dist/: never served.
  writeFileSync(join(root, 'secret.txt'), 'outside');
});
afterAll(() => rmSync(root, { recursive: true, force: true }));

// ---- the server and its fakes ---------------------------------------------------------------------------------------

interface Sent {
  url: string;
  init: Parameters<E2bFetch>[1];
}

interface Setup {
  preview: Preview;
  e2b: Sent[];
  logs: string[];
  fire: () => void;
  timers: { ms: number; cleared: boolean }[];
}

const E2B_OK = { sandboxID: 'i8x3k2p9q1v7m4n6s5t0', envdAccessToken: 'e2b-example-access-token', envdVersion: '0.4.2', domain: 'e2b.app' };

const open: Preview[] = [];
afterEach(async () => {
  await Promise.all(open.splice(0).map((p) => p.close()));
});

async function start(over: Partial<PreviewOptions> & { answer?: () => Promise<Response> } = {}): Promise<Setup> {
  const e2b: Sent[] = [];
  const logs: string[] = [];
  const timers: { ms: number; cleared: boolean; fn: () => void }[] = [];
  const manual: Timers = {
    set: (fn, ms) => {
      timers.push({ ms, cleared: false, fn });
      return timers.length - 1;
    },
    clear: (h) => {
      timers[h as number].cleared = true;
    },
  };
  const answer = over.answer ?? (async () => new Response(JSON.stringify(E2B_OK), { status: 201 }));
  const preview = await startPreview({
    scenario: 'signed-in',
    e2bTemplate: 'base',
    e2bKey: KEY,
    distDir: dist,
    fetch: async (url, init) => {
      e2b.push({ url, init });
      return answer();
    },
    now: () => NOW,
    requestId: () => REQUEST_ID,
    timers: manual,
    log: (line) => logs.push(line),
    ...over,
  });
  open.push(preview);
  return { preview, e2b, logs, timers, fire: () => timers[timers.length - 1].fn() };
}

interface Got {
  status: number;
  headers: Record<string, string | string[] | undefined>;
  text: string;
}

function send(p: Preview, path: string, opts: { method?: string; headers?: Record<string, string>; body?: string } = {}): Promise<Got> {
  return new Promise((done, fail) => {
    const req = httpRequest(
      { host: '127.0.0.1', port: p.port, path, method: opts.method ?? 'GET', headers: opts.headers ?? {} },
      (res) => {
        const chunks: Buffer[] = [];
        res.on('data', (c: Buffer) => chunks.push(c));
        res.on('end', () => done({ status: res.statusCode ?? 0, headers: res.headers, text: Buffer.concat(chunks).toString('utf8') }));
      },
    );
    req.on('error', fail);
    if (opts.body !== undefined) req.write(opts.body);
    req.end();
  });
}

/** What a page of the preview sends with a sandbox or sign-out POST: the browser's headers and the session's value. */
function pageHeaders(p: Preview, over: Record<string, string> = {}): Record<string, string> {
  return { origin: `http://127.0.0.1:${p.port}`, 'sec-fetch-site': 'same-origin', 'x-mopm-csrf': PREVIEW_CSRF, ...over };
}

const post = (p: Preview, path: string, over: Record<string, string> = {}, body?: string) =>
  send(p, path, { method: 'POST', headers: pageHeaders(p, over), body });
const sandbox = (p: Preview, over: Record<string, string> = {}, body?: string) => post(p, '/api/v2/tutorial/sandbox', over, body);
const session = (p: Preview, headers: Record<string, string> = {}) => send(p, '/api/v2/auth/web/session', { headers });
const logout = (p: Preview, over: Record<string, string> = {}) => post(p, '/api/v2/auth/web/logout', over);

/** The answer is the contract case's: its status, its body, and its Retry-After when it has one. */
function expectCase(got: Got, c: ContractCase): void {
  expect([got.status, JSON.parse(got.text)]).toEqual([c.response.status, c.response.body]);
  expect(got.headers['retry-after']).toBe(c.response.headers['retry-after']);
}

// ---- the command line -------------------------------------------------------------------------------------------------

describe('flags', () => {
  test.each(SCENARIOS)('--scenario %s, with the base template unless one is named', (s) => {
    expect(parseFlags(['--scenario', s])).toEqual({ scenario: s, e2bTemplate: 'base' });
    expect(parseFlags(['--e2b-template', 'mopm-tutorial', '--scenario', s])).toEqual({ scenario: s, e2bTemplate: 'mopm-tutorial' });
  });

  test.each([
    [[], '--scenario is required'],
    [['--e2b-template', 'base'], '--scenario is required'],
    [['--scenario'], '--scenario needs a value'],
    [['--scenario', '--e2b-template', 'base'], '--scenario needs a value'],
    [['--scenario', 'signed-in', '--scenario', 'signed-out'], '--scenario given twice'],
    [['--scenario', 'signed-in', '--e2b-template', 'a', '--e2b-template', 'b'], '--e2b-template given twice'],
    [['--scenario', 'admin'], "unknown scenario 'admin'"],
    [['--scenario=signed-in'], "unknown argument '--scenario=signed-in'"],
    [['signed-in'], "unknown argument 'signed-in'"],
    [['--scenario', 'signed-in', '--e2b-template', 'a b'], "'a b' is not a template id"],
    [['--scenario', 'signed-in', '--e2b-template', '-x'], "'-x' is not a template id"],
    [['--scenario', 'signed-in', '--e2b-template', 'x'.repeat(129)], `'${'x'.repeat(129)}' is not a template id`],
  ])('%j: %s', (argv, error) => {
    expect(parseFlags(argv)).toEqual({ error });
  });
});

describe('main', () => {
  function deps(over: Partial<MainDeps> = {}): MainDeps & { outLines: string[]; errLines: string[] } {
    const outLines: string[] = [];
    const errLines: string[] = [];
    return {
      e2bKey: undefined,
      distDir: dist,
      fetch: async () => {
        throw new Error('E2B is not called here');
      },
      out: (l) => outLines.push(l),
      err: (l) => errLines.push(l),
      now: () => NOW,
      requestId: () => REQUEST_ID,
      timers: REAL_TIMERS,
      outLines,
      errLines,
      ...over,
    };
  }

  test('a bad command line: status 2, the problem and the usage, and no server', async () => {
    const d = deps();
    expect(await main(['--scenario', 'nope'], d)).toEqual({ status: 2 });
    expect(d.errLines).toEqual(["preview: unknown scenario 'nope'", USAGE]);
    expect(d.outLines).toEqual([]);
  });

  test('no site build: status 1, and what to run', async () => {
    const d = deps({ distDir: join(root, 'missing') });
    expect(await main(['--scenario', 'signed-in'], d)).toEqual({ status: 1 });
    expect(d.errLines).toEqual([`preview: no site build in ${join(root, 'missing')}; run 'npm run build' first`]);
  });

  test.each([
    [['--scenario', 'signed-in'], undefined, 'preview: no E2B_API_KEY, so the sandbox route answers tutorial_unavailable'],
    [['--scenario', 'signed-in'], '', 'preview: no E2B_API_KEY, so the sandbox route answers tutorial_unavailable'],
    [['--scenario', 'signed-in', '--e2b-template', 'base'], KEY, 'preview: sandboxes are created on E2B from template base, internet access off'],
    [['--scenario', 'unavailable'], KEY, 'preview: the sandbox route answers as the scenario says; E2B is not called'],
  ])('%j with key %j: prints the address and what the sandbox route does, never the key', async (argv, key, line) => {
    const d = deps({ e2bKey: key });
    const r = await main(argv, d);
    expect(r.status).toBe(0);
    const p = r.preview as Preview;
    open.push(p);
    expect(p.url).toBe(`http://127.0.0.1:${p.port}/tutorial`);
    expect(p.port).toBeGreaterThan(0);
    expect(d.outLines).toEqual([`preview: ${p.url} (scenario ${argv[1]})`, line]);
    expect(d.errLines).toEqual([]);
    expect((await send(p, '/')).text).toBe(PAGES['index.html']);
  });

  test('the key reaches E2B and no line printed', async () => {
    const sent: Sent[] = [];
    const d = deps({
      e2bKey: KEY,
      fetch: async (url, init) => {
        sent.push({ url, init });
        return new Response(JSON.stringify(E2B_OK), { status: 201 });
      },
    });
    const p = (await main(['--scenario', 'signed-in'], d)).preview as Preview;
    open.push(p);
    expect((await sandbox(p)).status).toBe(201);
    expect(sent.map((s) => s.init.headers['X-API-Key'])).toEqual([KEY]);
    for (const line of [...d.outLines, ...d.errLines]) {
      expect(line).not.toContain(KEY);
      expect(line).not.toContain(E2B_OK.envdAccessToken);
    }
    expect(d.errLines).toEqual(['preview: sandbox i8x3k2p9q1v7m4n6s5t0 created from template base, ends 2026-11-19T12:30:00.000Z']);
  });

  test('runIfMain: nothing when imported; as the program, the exit status of a failed start', async () => {
    const proc: { argv: string[]; exitCode?: number | string } = { argv: ['node', 'preview.js', '--scenario', 'nope'] };
    expect(runIfMain(false, proc, () => deps())).toBeNull();
    expect(await runIfMain(true, proc, () => deps())).toEqual({ status: 2 });
    expect(proc.exitCode).toBe(2);
    const ok: { argv: string[]; exitCode?: number | string } = { argv: ['node', 'preview.js', '--scenario', 'signed-out'] };
    const r = await runIfMain(true, ok, () => deps());
    open.push(r?.preview as Preview);
    expect([r?.status, ok.exitCode]).toEqual([0, undefined]);
  });

  test('defaultDeps: the key from E2B_API_KEY only, site/dist, the global fetch, request ids of the API form', () => {
    const before = process.env.E2B_API_KEY;
    try {
      process.env.E2B_API_KEY = KEY;
      expect(defaultDeps().e2bKey).toBe(KEY);
      delete process.env.E2B_API_KEY;
      expect(defaultDeps().e2bKey).toBeUndefined();
    } finally {
      if (before === undefined) delete process.env.E2B_API_KEY;
      else process.env.E2B_API_KEY = before;
    }
    const d = defaultDeps();
    const site = resolve(__dirname, '..');
    expect(distFor(join(site, 'build', 'tools', 'tools'))).toBe(join(site, 'dist'));
    expect(d.distDir).toBe(distFor(join(site, 'tools')));
    // test/setup.ts makes the global fetch throw: the default fetch is the global one.
    expect(() => d.fetch(E2B_CREATE_URL, { method: 'POST', headers: {}, body: '', redirect: 'error', signal: new AbortController().signal })).toThrow('network call in a test');
    expect(d.requestId()).toMatch(/^req-[0-9a-f]{12}$/);
    expect(d.requestId()).not.toBe(d.requestId());
    expect(d.now()).toBeInstanceOf(Date);
    d.timers.clear(d.timers.set(() => undefined, 60_000));
    const out = jest.spyOn(process.stdout, 'write').mockImplementation(() => true);
    const err = jest.spyOn(process.stderr, 'write').mockImplementation(() => true);
    try {
      d.out('a');
      d.err('b');
      expect(out).toHaveBeenCalledWith('a\n');
      expect(err).toHaveBeenCalledWith('b\n');
    } finally {
      out.mockRestore();
      err.mockRestore();
    }
  });
});

// ---- the scenarios -----------------------------------------------------------------------------------------------------

describe('each scenario', () => {
  test('signed-out: the session, sign-out and sandbox routes answer session_required; E2B is not called', async () => {
    const { preview: p, e2b } = await start({ scenario: 'signed-out' });
    expectCase(await session(p), named('the session of a signed-out browser is refused as session_required'));
    expectCase(await logout(p), LOGOUT_SIGNED_OUT);
    expectCase(await sandbox(p), SESSION_REQUIRED);
    expect(e2b).toEqual([]);
  });

  test.each(['signed-in', 'csrf-failed', 'unavailable', 'session-expired'] as Scenario[])(
    '%s: the session route answers the fixed login and CSRF value, for 7 days from now',
    async (scenario) => {
      const { preview: p } = await start({ scenario });
      const got = await session(p);
      expect(got.status).toBe(200);
      const body = JSON.parse(got.text);
      expect(body).toEqual({ login: 'alice', csrf: PREVIEW_CSRF, expires_at: '2026-11-26T12:00:00.000Z' });
      // The contract's example login and value, so the gate decodes it as it decodes the contract.
      expect({ login: body.login, csrf: body.csrf }).toEqual({
        login: (SESSION.response.body as { login: string }).login,
        csrf: (SESSION.response.body as { csrf: string }).csrf,
      });
    },
  );

  test('signed-in with a key: a grant from E2B\'s answer, equal to the contract\'s example', async () => {
    const { preview: p } = await start();
    const got = await sandbox(p);
    expect([got.status, JSON.parse(got.text)]).toEqual([201, GRANT.response.body]);
  });

  test('signed-in without a key: tutorial_unavailable with Retry-After, and E2B is never called', async () => {
    const { preview: p, e2b } = await start({ e2bKey: null });
    const got = await sandbox(p);
    expect([got.status, got.headers['retry-after']]).toEqual([503, '30']);
    expect(JSON.parse(got.text)).toEqual({
      error: {
        code: 'tutorial_unavailable',
        message: 'The preview has no E2B_API_KEY, so it creates no sandboxes.',
        hint: 'Start the preview with E2B_API_KEY set to a key of your own E2B account.',
      },
    });
    expect(e2b).toEqual([]);
  });

  test('csrf-failed: the sandbox route and sign-out answer csrf_failed even with the right value; E2B is not called', async () => {
    const { preview: p, e2b } = await start({ scenario: 'csrf-failed' });
    expectCase(await sandbox(p), CSRF_FAILED);
    expectCase(await logout(p), LOGOUT_CSRF);
    expect(e2b).toEqual([]);
  });

  test('unavailable: the sandbox route answers tutorial_unavailable with Retry-After 30; E2B is not called', async () => {
    const { preview: p, e2b } = await start({ scenario: 'unavailable' });
    expectCase(await sandbox(p), UNAVAILABLE);
    expect(e2b).toEqual([]);
  });

  test('session-expired: the session route answers 200, then the sandbox route 401', async () => {
    const { preview: p, e2b } = await start({ scenario: 'session-expired' });
    expect((await session(p)).status).toBe(200);
    expectCase(await sandbox(p), SESSION_REQUIRED);
    expectCase(await logout(p), LOGOUT_SIGNED_OUT);
    expect(e2b).toEqual([]);
  });

  test('sign-out answers 204 and ends the session: the session and sandbox routes then answer session_required', async () => {
    const { preview: p } = await start({ scenario: 'unavailable' });
    const out = await logout(p);
    expect([out.status, out.text, out.headers['content-type']]).toEqual([204, '', undefined]);
    expect((await session(p)).status).toBe(401);
    expectCase(await sandbox(p), SESSION_REQUIRED);
    expectCase(await logout(p), LOGOUT_SIGNED_OUT);
  });
});

// ---- the sandbox route's checks ----------------------------------------------------------------------------------------

describe("the sandbox route's checks, as the real route's", () => {
  test.each([
    ['a wrong CSRF value', { 'x-mopm-csrf': `${PREVIEW_CSRF.slice(0, 42)}x` }],
    ['an Origin of another site', { origin: 'http://evil.example' }],
    ['an Origin with another port', { origin: 'http://127.0.0.1:1' }],
    ['an https Origin', { origin: 'https://127.0.0.1' }],
    ['Sec-Fetch-Site: cross-site', { 'sec-fetch-site': 'cross-site' }],
    ['Sec-Fetch-Site: same-site', { 'sec-fetch-site': 'same-site' }],
    ['Sec-Fetch-Site: none', { 'sec-fetch-site': 'none' }],
  ])('%s: 403 csrf_failed, and E2B is not called', async (_, over) => {
    const { preview: p, e2b } = await start();
    expectCase(await sandbox(p, over), CSRF_FAILED);
    expectCase(await logout(p, over), LOGOUT_CSRF);
    expect(e2b).toEqual([]);
  });

  test.each(['x-mopm-csrf', 'origin', 'sec-fetch-site'])('no %s header: 403 csrf_failed', async (header) => {
    const { preview: p, e2b } = await start();
    const headers = pageHeaders(p);
    delete headers[header];
    expectCase(await send(p, '/api/v2/tutorial/sandbox', { method: 'POST', headers }), CSRF_FAILED);
    expect(e2b).toEqual([]);
  });

  test('an Origin of the other loopback name than the Host the page was loaded from: 403 csrf_failed', async () => {
    const { preview: p } = await start();
    expectCase(await sandbox(p, { origin: `http://localhost:${p.port}` }), CSRF_FAILED);
  });

  test('a page loaded from localhost passes with its own origin', async () => {
    const { preview: p } = await start();
    const got = await sandbox(p, { host: `localhost:${p.port}`, origin: `http://localhost:${p.port}` });
    expect(got.status).toBe(201);
  });

  test.each([
    ['a JSON body', JSON.stringify({ template: 'base' })],
    ['one byte', 'x'],
  ])('%s: 400 invalid_request, and E2B is not called', async (_, body) => {
    const { preview: p, e2b } = await start();
    expectCase(await sandbox(p, { 'content-type': 'application/json' }, body), WITH_BODY);
    expect(e2b).toEqual([]);
  });

  test('an Authorization header: 400 invalid_request, on the session route too', async () => {
    const { preview: p, e2b } = await start();
    expectCase(await sandbox(p, { authorization: 'Bearer x' }), WITH_AUTHORIZATION);
    expectCase(await session(p, { authorization: 'Bearer x' }), SESSION_AUTHORIZATION);
    expect(e2b).toEqual([]);
  });

  test('the order: Authorization before the session, the session before the CSRF checks, those before the body', async () => {
    const out = await start({ scenario: 'signed-out' });
    expectCase(await sandbox(out.preview, { authorization: 'Bearer x', 'x-mopm-csrf': 'wrong' }, 'x'), WITH_AUTHORIZATION);
    expectCase(await sandbox(out.preview, { 'x-mopm-csrf': 'wrong' }, 'x'), SESSION_REQUIRED);
    const inn = await start();
    expectCase(await sandbox(inn.preview, { 'x-mopm-csrf': 'wrong' }, 'x'), CSRF_FAILED);
  });
});

// ---- E2B ----------------------------------------------------------------------------------------------------------------

describe('the create call to E2B', () => {
  test("is section 4's: the URL, the key header, and the body field for field, internet access off", async () => {
    const { preview: p, e2b } = await start({ e2bTemplate: 'mopm-tutorial' });
    await sandbox(p);
    expect(e2b).toHaveLength(1);
    const [{ url, init }] = e2b;
    expect(url).toBe('https://api.e2b.app/v2/sandboxes');
    expect(init.method).toBe('POST');
    expect(init.redirect).toBe('error');
    expect(init.headers).toEqual({ 'X-API-Key': KEY, 'Content-Type': 'application/json' });
    expect(JSON.parse(init.body)).toEqual({
      templateID: 'mopm-tutorial',
      timeout: 1800,
      allow_internet_access: false,
      autoPause: false,
      network: { allowPublicTraffic: false },
      metadata: { mopm_stage: 'preview', mopm_request: REQUEST_ID },
    });
    // The serialised order is section 4's too.
    expect(Object.keys(JSON.parse(init.body))).toEqual(['templateID', 'timeout', 'allow_internet_access', 'autoPause', 'network', 'metadata']);
    expect(init.body).toContain('"allow_internet_access":false');
  });

  test('a null or missing domain is e2b.app; another domain is kept', async () => {
    for (const [domain, want] of [[null, 'e2b.app'], [undefined, 'e2b.app'], ['sandbox.example', 'sandbox.example']] as const) {
      const { preview: p } = await start({ answer: async () => new Response(JSON.stringify({ ...E2B_OK, domain }), { status: 201 }) });
      expect(JSON.parse((await sandbox(p)).text).domain).toBe(want);
    }
  });

  test('expires_at is the time the request was sent plus 1800 s, whatever the clock says after', async () => {
    let t = NOW.getTime();
    const { preview: p } = await start({
      now: () => new Date(t),
      answer: async () => {
        t += 5_000;
        return new Response(JSON.stringify(E2B_OK), { status: 201 });
      },
    });
    expect(JSON.parse((await sandbox(p)).text).expires_at).toBe('2026-11-19T12:30:00.000Z');
  });

  test.each([
    ['E2B refuses (429)', async () => new Response('{"message":"rate limited"}', { status: 429 })],
    ['E2B refuses the key (401)', async () => new Response('{"message":"invalid key"}', { status: 401 })],
    ['E2B fails (500)', async () => new Response('oops', { status: 500 })],
    ['an answer that is not JSON', async () => new Response('<html>', { status: 201 })],
    ['an answer without envdAccessToken', async () => new Response(JSON.stringify({ ...E2B_OK, envdAccessToken: undefined }), { status: 201 })],
    ['an empty envdAccessToken', async () => new Response(JSON.stringify({ ...E2B_OK, envdAccessToken: '' }), { status: 201 })],
    ['an answer without sandboxID', async () => new Response(JSON.stringify({ ...E2B_OK, sandboxID: undefined }), { status: 201 })],
    ['an answer that is an array', async () => new Response('[]', { status: 201 })],
    ['no answer (the fetch fails)', async () => Promise.reject(new TypeError('fetch failed'))],
  ])('%s: 503 tutorial_unavailable with Retry-After, and a log line with no key or token', async (_, answer) => {
    const { preview: p, logs } = await start({ answer });
    expectCase(await sandbox(p), UNAVAILABLE);
    expect(logs).toHaveLength(1);
    expect(logs[0]).toMatch(/answered tutorial_unavailable$/);
    for (const l of logs) {
      expect(l).not.toContain(KEY);
      expect(l).not.toContain(E2B_OK.envdAccessToken);
    }
  });

  test('the 8 s deadline: no answer by then is tutorial_unavailable, and the timer is cleared either way', async () => {
    const s = await start({ answer: () => new Promise<Response>(() => undefined) });
    const pending = sandbox(s.preview);
    while (s.timers.length === 0) await new Promise((r) => setImmediate(r));
    expect(s.timers.map((t) => t.ms)).toEqual([E2B_DEADLINE_MS]);
    expect(E2B_DEADLINE_MS).toBe(8_000);
    s.fire();
    expectCase(await pending, UNAVAILABLE);
    expect(s.e2b[0].init.signal.aborted).toBe(true);
    expect(s.timers.map((t) => t.cleared)).toEqual([true]);
    const ok = await start();
    await sandbox(ok.preview);
    expect(ok.timers.map((t) => [t.ms, t.cleared])).toEqual([[E2B_DEADLINE_MS, true]]);
  });

  test('a body cut off by the deadline is tutorial_unavailable too', async () => {
    const s = await start({
      answer: async () => ({ status: 201, text: () => new Promise<string>(() => undefined) }) as unknown as Response,
    });
    const pending = sandbox(s.preview);
    while (s.e2b.length === 0) await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    s.fire();
    expectCase(await pending, UNAVAILABLE);
  });

  test('decodeE2bSandbox refuses what is not an object, and keeps only the four fields', () => {
    expect(decodeE2bSandbox(null)).toBeNull();
    expect(decodeE2bSandbox('x')).toBeNull();
    expect(decodeE2bSandbox({ ...E2B_OK, envdVersion: 4 })).toBeNull();
    expect(decodeE2bSandbox({ ...E2B_OK, domain: '' })).toBeNull();
    expect(decodeE2bSandbox({ ...E2B_OK, trafficAccessToken: 't', alias: 'base' })).toEqual(E2B_OK);
  });
});

// ---- the API's other answers -----------------------------------------------------------------------------------------

describe('API answers', () => {
  test("carry the API behaviour's headers, no-store, and the request id", async () => {
    const { preview: p } = await start();
    const got = await session(p);
    expect(got.headers).toEqual(
      expect.objectContaining({
        'content-type': 'application/json',
        'cache-control': 'no-store',
        'x-mopm-request-id': REQUEST_ID,
        'content-security-policy': "default-src 'none'; sandbox; frame-ancestors 'none'",
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'no-referrer',
        'strict-transport-security': 'max-age=63072000; includeSubDomains',
      }),
    );
  });

  test.each([
    ['GET', '/api/v2/health'],
    ['GET', '/api/v2/tutorial/sandbox'],
    ['POST', '/api/v2/auth/web/session'],
    ['GET', '/api/v2/auth/web/start?return_to=/tutorial'],
    ['GET', '/api'],
  ])('%s %s: 404 route_not_found', async (method, path) => {
    const { preview: p } = await start();
    const got = await send(p, path, { method });
    expect([got.status, JSON.parse(got.text).error.code]).toEqual([404, 'route_not_found']);
  });

  test('a query string does not change the route', async () => {
    const { preview: p } = await start();
    expect((await send(p, '/api/v2/auth/web/session?x=1')).status).toBe(200);
  });

  test('a header Node keeps as a list (Set-Cookie) is read as one value, and the request still passes', async () => {
    const { preview: p } = await start();
    const got = await send(p, '/api/v2/tutorial/sandbox', { method: 'POST', headers: { ...pageHeaders(p), 'set-cookie': 'a=1' } });
    expect(got.status).toBe(201);
  });
});

// ---- the site's files ---------------------------------------------------------------------------------------------------

describe('the site', () => {
  const PAGE_HEADERS: Record<string, string> = { ...securityHeaders(PREVIEW_CONNECT_SRC), 'cache-control': 'no-store' };

  test("pages have the site's security headers, with a connect-src of the page's own origin and E2B's sandboxes", async () => {
    const { preview: p } = await start();
    const got = await send(p, '/');
    expect([got.status, got.text]).toEqual([200, PAGES['index.html']]);
    expect(got.headers).toEqual(expect.objectContaining({ ...PAGE_HEADERS, 'content-type': 'text/html; charset=utf-8' }));
    expect(got.headers['content-security-policy']).toBe(
      "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self' https://*.e2b.app; " +
        "base-uri 'none'; form-action 'self'; frame-ancestors 'none'; object-src 'none'; require-trusted-types-for 'script'; " +
        "trusted-types 'none'",
    );
  });

  test.each([
    ['/', 200, 'index.html', 'text/html; charset=utf-8'],
    ['/?q=1', 200, 'index.html', 'text/html; charset=utf-8'],
    ['/search', 200, 'app.html', 'text/html; charset=utf-8'],
    ['/packages/komira-ai/http_client', 200, 'app.html', 'text/html; charset=utf-8'],
    ['/packages/komira-ai/http_client/1.0.0', 200, 'app.html', 'text/html; charset=utf-8'],
    ['/docs', 200, 'docs/index.html', 'text/html; charset=utf-8'],
    ['/docs/', 200, 'docs/index.html', 'text/html; charset=utf-8'],
    ['/docs/why/', 200, 'docs/why/index.html', 'text/html; charset=utf-8'],
    ['/assets/0123456789abcdef/main.js', 200, 'assets/0123456789abcdef/main.js', 'text/javascript; charset=utf-8'],
    ['/assets/0123456789abcdef/site.css', 200, 'assets/0123456789abcdef/site.css', 'text/css; charset=utf-8'],
    ['/install.sh', 200, 'install.sh', 'text/plain; charset=utf-8'],
    ['/notes.bin', 200, 'notes.bin', 'application/octet-stream'],
    ['/tutorial', 404, '404.html', 'text/html; charset=utf-8'],
    ['/nope', 404, '404.html', 'text/html; charset=utf-8'],
    ['/empty', 404, '404.html', 'text/html; charset=utf-8'],
    ['/packages/komira-ai/http__client', 404, '404.html', 'text/html; charset=utf-8'],
    ['/../secret.txt', 404, '404.html', 'text/html; charset=utf-8'],
    ['/%2e%2e/secret.txt', 404, '404.html', 'text/html; charset=utf-8'],
    ['/assets/%2e%2e/%2e%2e/secret.txt', 404, '404.html', 'text/html; charset=utf-8'],
    ['/./index.html', 404, '404.html', 'text/html; charset=utf-8'],
    ['/%5c..%5csecret.txt', 404, '404.html', 'text/html; charset=utf-8'],
    ['/index.html%00', 404, '404.html', 'text/html; charset=utf-8'],
    ['/%E0%A4%A', 404, '404.html', 'text/html; charset=utf-8'],
  ])('%s: %i, %s as %s', async (path, status, file, type) => {
    const { preview: p } = await start();
    const got = await send(p, path);
    expect([got.status, got.text, got.headers['content-type']]).toEqual([status, PAGES[file], type]);
    expect(got.headers['content-security-policy']).toBe(PAGE_HEADERS['content-security-policy']);
  });

  test("the tutorial routes are the build's tutorial pages, as the edge router serves them", async () => {
    const pages = { 'tutorial/index.html': '<!doctype html><title>tutorial</title>', 'tutorial/hello/index.html': '<!doctype html><title>hello</title>' };
    for (const [p, text] of Object.entries(pages)) {
      mkdirSync(dirname(join(dist, p)), { recursive: true });
      writeFileSync(join(dist, p), text);
    }
    try {
      const { preview: p } = await start();
      for (const [path, file] of [
        ['/tutorial', 'tutorial/index.html'],
        ['/tutorial/hello', 'tutorial/hello/index.html'],
        ['/tutorial/index.html', 'tutorial/index.html'],
        ['/tutorial/hello/index.html', 'tutorial/hello/index.html'],
      ] as const) {
        const got = await send(p, path);
        expect([path, got.status, got.text]).toEqual([path, 200, pages[file]]);
      }
      for (const path of ['/tutorial/', '/tutorial/hello/', '/tutorial/Hello', '/tutorial/hello/x', '/tutorial/no-such-lesson', '/tutorial/hello-world-2']) {
        expect([path, (await send(p, path)).status]).toEqual([path, 404]);
      }
    } finally {
      rmSync(join(dist, 'tutorial'), { recursive: true, force: true });
    }
  });

  test('HEAD has the headers and no body; other methods on a page: 405', async () => {
    const { preview: p } = await start();
    const head = await send(p, '/', { method: 'HEAD' });
    expect([head.status, head.text, head.headers['content-type'], head.headers['content-length']]).toEqual([
      200,
      '',
      'text/html; charset=utf-8',
      String(PAGES['index.html'].length),
    ]);
    const put = await send(p, '/', { method: 'PUT' });
    expect([put.status, put.headers.allow, put.text]).toEqual([405, 'GET, HEAD', 'GET or HEAD only\n']);
  });

  test('a Host other than its own two names is not answered (a page elsewhere resolving its name to 127.0.0.1)', async () => {
    const { preview: p, e2b } = await start();
    for (const host of ['evil.example', `evil.example:${p.port}`, '127.0.0.1', `127.0.0.2:${p.port}`]) {
      const got = await sandbox(p, { host, origin: `http://${host}` });
      expect([host, got.status, got.text]).toEqual([host, 421, `ask http://127.0.0.1:${p.port}/\n`]);
    }
    expect(e2b).toEqual([]);
  });

  test('a build that went away under the server: 500, and the server keeps answering', async () => {
    const gone = mkdtempSync(join(SCRATCH, 'gone-'));
    try {
      const { preview: p } = await start({ distDir: gone });
      const got = await send(p, '/nope');
      expect([got.status, got.text]).toEqual([500, 'the preview could not read the site build; run it again after npm run build\n']);
      expect((await session(p)).status).toBe(200);
    } finally {
      rmSync(gone, { recursive: true, force: true });
    }
  });

  test('a request target that is not a path: 400', async () => {
    const { preview: p } = await start();
    expect((await send(p, '//evil.example/x')).status).toBe(400);
    expect((await send(p, '*', { method: 'OPTIONS' })).status).toBe(400);
  });

  test('pageFile: a directory without an index, a dot segment and a NUL are no file', () => {
    expect(pageFile(dist, '/empty')).toBeNull();
    expect(pageFile(dist, '/docs/why')).toBe(join('docs/why', 'index.html'));
    expect(pageFile(dist, '/a/../index.html')).toBeNull();
    expect(pageFile(dist, '/index.html\u0000')).toBeNull();
    expect(pageFile(dist, '/install.sh')).toBe('install.sh');
    // An absolute path after the first '/' resolves outside dist/ (the server refuses '//' before this).
    expect(pageFile(dist, `/${join(root, 'secret.txt')}`)).toBeNull();
  });
});
