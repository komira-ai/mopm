// The lesson runner (src/tutorial/runner.ts) driving the pinned e2b SDK, as the browser runs it, against a fake of E2B's
// in-sandbox agent (envd) on 127.0.0.1 with a port the system picks. The SDK reaches the agent through its own fetch seam:
// in a browser it calls the global `fetch`, late-bound, for every request. Here that global records each request, checks
// it is addressed to the grant's sandbox (`https://49983-<sandbox_id>.<domain>`), and carries it to the fake over
// loopback. What is asserted:
//  - the client is built from the grant alone: every request carries `X-Access-Token` with the grant's token and no API
//    key (`X-API-Key`) or `Authorization`, even with E2B_API_KEY set where the SDK reads it;
//  - the edited files are written in one upload into the lesson's directory, then the command runs there;
//  - exit 0 and a non-zero exit (the SDK's CommandExitError) both give the exit code and the output;
//  - the agent's proxy saying the sandbox was not found (on the write or the run) is `{kind: 'SandboxNotRunning'}`, and
//    its port not open is `{kind: 'SandboxUnreachable'}` (page.ts's RunnerError);
//  - any other failure (a refused token) is thrown as the SDK's own error;
//  - a lesson id outside the lesson grammar is refused when the runner is built, a file path or command by the run,
//    before any request.
import { createServer, request as httpRequest, type IncomingMessage, type Server, type ServerResponse } from 'http';
import type { AddressInfo } from 'net';
import { Readable } from 'stream';
import type * as Runner from '../src/tutorial/runner';
import type { SandboxGrant } from '../src/tutorial/gate';
import { load } from './fixtures';

// e2b decides once, when it loads, which runtime it is in: a browser has `window` and no Node `process.release`. Load it
// (and the runner, which imports it) as the browser's, then put the process back.
const release = process.release;
Object.defineProperty(process, 'release', { value: { name: 'browser' }, configurable: true });
(globalThis as { window?: unknown }).window = globalThis;
const { e2bRunner, lessonDir, LESSONS_DIR, RUN_TIMEOUT_MS, sandboxOf } = require('../src/tutorial/runner') as typeof Runner;
const e2b = require('e2b') as typeof import('e2b');
Object.defineProperty(process, 'release', { value: release, configurable: true });
delete (globalThis as { window?: unknown }).window;

const GRANT = load('tutorial-sandbox').find((c) => c.operationId === 'createTutorialSandbox' && c.response.status === 201)?.response.body as SandboxGrant;
const agentOf = (g: SandboxGrant): string => `https://49983-${g.sandbox_id}.${g.domain}`;
const AGENT = agentOf(GRANT);
/** The origin the seam lets through: the agent of the grant a test runs with. */
let agent = AGENT;
/** Where the SDK would read a team key from; set so the test shows it is never sent. */
const KEY = 'e2b_0000000000000000000000000000000000000000';

// ---- the fake agent ----------------------------------------------------------------------------------------------

interface Seen {
  method: string;
  url: string;
  headers: Record<string, string>;
}

/** What the fake answers: each route a function of the request, so a test sets one route's failure. */
interface Script {
  files: (res: ServerResponse, written: { path: string; content: string }[]) => void;
  start: (res: ServerResponse, start: { cmd: string; args: string[]; cwd?: string }) => void;
}

/** A Connect streaming frame: a flags byte, a big-endian length, the JSON message. */
function frame(msg: unknown, flags = 0): Buffer {
  const body = Buffer.from(JSON.stringify(msg));
  const head = Buffer.alloc(5);
  head.writeUInt8(flags, 0);
  head.writeUInt32BE(body.length, 1);
  return Buffer.concat([head, body]);
}

const b64 = (s: string): string => Buffer.from(s).toString('base64');

/** process.Process/Start's answer for a command that wrote `stdout` and `stderr` and exited with `code`. */
function exited(code: number, stdout: string, stderr: string): Script['start'] {
  return (res) => {
    res.writeHead(200, { 'content-type': 'application/connect+json' });
    res.write(frame({ event: { start: { pid: 7 } } }));
    if (stdout !== '') res.write(frame({ event: { data: { stdout: b64(stdout) } } }));
    if (stderr !== '') res.write(frame({ event: { data: { stderr: b64(stderr) } } }));
    res.write(frame({ event: { end: { exitCode: code, exited: true, status: `exit status ${code}` } } }));
    res.end(frame({}, 2));
  };
}

/** The answer of E2B's proxy in front of the agent: a plain 502 with its message. */
const proxy = (message: string) => (res: ServerResponse) => {
  res.writeHead(502, { 'content-type': 'text/plain' });
  res.end(message);
};

const WROTE: Script['files'] = (res, written) => {
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify(written.map((f) => ({ name: f.path.split('/').pop(), type: 'file', path: f.path }))));
};

let server: Server;
let port = 0;
let script: Script;
let seen: Seen[] = [];
let written: { path: string; content: string }[] = [];
let started: { cmd: string; args: string[]; cwd?: string }[] = [];

function body(req: IncomingMessage): Promise<Buffer> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    req.on('data', (c: Buffer) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
  });
}

async function serve(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const raw = await body(req);
  const url = new URL(req.url ?? '/', 'http://agent');
  if (req.method === 'POST' && url.pathname === '/files') {
    // The SDK's upload is multipart, each part named after its path; the query names no path for several files.
    const form = await new Response(new Uint8Array(raw), { headers: { 'content-type': req.headers['content-type'] ?? '' } }).formData();
    const files = await Promise.all(form.getAll('file').map(async (f) => ({ path: (f as File).name, content: await (f as File).text() })));
    written.push(...files);
    return script.files(res, files);
  }
  if (req.method === 'POST' && url.pathname === '/process.Process/Start') {
    const msg = JSON.parse(raw.subarray(5).toString('utf8')) as { process: { cmd: string; args: string[]; cwd?: string } };
    started.push(msg.process);
    return script.start(res, msg.process);
  }
  // The health probe the SDK runs after a request fails at the connection level: the agent is up.
  if (req.method === 'GET' && url.pathname === '/health') {
    res.writeHead(204);
    return void res.end();
  }
  res.writeHead(404, { 'content-type': 'text/plain' });
  res.end(`no route ${req.method} ${url.pathname}`);
}

/** The SDK's fetch seam: record the request, check its address, and carry it to the fake over loopback. */
async function seam(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const req = new Request(input, init);
  const headers: Record<string, string> = {};
  req.headers.forEach((v, k) => (headers[k] = v));
  seen.push({ method: req.method, url: req.url, headers });
  const url = new URL(req.url);
  if (url.origin !== agent) throw new TypeError(`request to ${url.origin}, not the grant's sandbox`);
  const payload = req.method === 'GET' ? undefined : Buffer.from(await req.arrayBuffer());
  return new Promise((resolve, reject) => {
    const out = httpRequest({ host: '127.0.0.1', port, method: req.method, path: url.pathname + url.search, headers }, (res) => {
      const h = new Headers();
      for (const [k, v] of Object.entries(res.headers)) if (typeof v === 'string') h.set(k, v);
      const status = res.statusCode ?? 500;
      resolve(new Response(status === 204 ? null : (Readable.toWeb(res) as ReadableStream), { status, headers: h }));
    });
    out.on('error', reject);
    out.end(payload);
  });
}

const savedFetch = globalThis.fetch;
const savedKey = process.env.E2B_API_KEY;
// The SDK's own address overrides (a debug agent on localhost, another sandbox URL or domain) stay unset here.
const OVERRIDES = ['E2B_DEBUG', 'E2B_SANDBOX_URL', 'E2B_DOMAIN', 'E2B_API_URL'] as const;
const savedOverrides = OVERRIDES.map((k) => process.env[k]);

beforeAll(async () => {
  server = createServer((req, res) => void serve(req, res));
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  port = (server.address() as AddressInfo).port;
  globalThis.fetch = seam as typeof fetch;
  process.env.E2B_API_KEY = KEY;
  for (const k of OVERRIDES) delete process.env[k];
});

afterAll(async () => {
  globalThis.fetch = savedFetch;
  if (savedKey === undefined) delete process.env.E2B_API_KEY;
  else process.env.E2B_API_KEY = savedKey;
  OVERRIDES.forEach((k, i) => (savedOverrides[i] === undefined ? delete process.env[k] : (process.env[k] = savedOverrides[i])));
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

beforeEach(() => {
  agent = AGENT;
  script = { files: WROTE, start: exited(0, 'Hello, world!\n', '') };
  seen = [];
  written = [];
  started = [];
});

const FILES = [
  { path: 'src/main.mojo', text: 'def main():\n    print("Hello, world!")\n' },
  { path: 'mopm.toml', text: '[package]\nname = "hello"\n' },
];
const DIR = `${LESSONS_DIR}/hello`;

// ---- the tests ---------------------------------------------------------------------------------------------------

describe('a run', () => {
  test('writes the files in one upload into the lesson directory, runs the command there, and gives exit 0 with the output', async () => {
    const r = await e2bRunner('hello').run(GRANT, FILES, 'mopm run src/main.mojo');
    expect(r).toEqual({ exit_code: 0, stdout: 'Hello, world!\n', stderr: '' });
    expect(written).toEqual([
      { path: `${DIR}/src/main.mojo`, content: FILES[0].text },
      { path: `${DIR}/mopm.toml`, content: FILES[1].text },
    ]);
    expect(started).toEqual([{ cmd: '/bin/bash', args: ['-l', '-c', 'mopm run src/main.mojo'], cwd: DIR }]);
    // The upload first, then the command: the run sees the edited files.
    expect(seen.map((s) => `${s.method} ${new URL(s.url).pathname}`)).toEqual(['POST /files', 'POST /process.Process/Start']);
  });

  test('every request goes to the grant\'s sandbox with its access token, and none carries an API key or Authorization', async () => {
    await e2bRunner('hello').run(GRANT, FILES, 'mopm test');
    expect(seen.length).toBe(2);
    for (const s of seen) {
      expect(new URL(s.url).origin).toBe(AGENT);
      expect(s.headers['x-access-token']).toBe(GRANT.access_token);
      expect(s.headers['e2b-sandbox-id']).toBe(GRANT.sandbox_id);
      expect(Object.keys(s.headers).filter((k) => k === 'x-api-key' || k === 'authorization')).toEqual([]);
      expect(Object.values(s.headers).filter((v) => v.includes(KEY))).toEqual([]);
    }
    expect(process.env.E2B_API_KEY).toBe(KEY);
  });

  test('the client is the constructor over the grant: its id and domain, nothing else', () => {
    const s = sandboxOf(GRANT);
    expect(s).toBeInstanceOf(e2b.Sandbox);
    expect([s.sandboxId, s.sandboxDomain]).toEqual([GRANT.sandbox_id, GRANT.domain]);
  });

  test('a grant on another domain: the client and every request use that domain, not the SDK\'s default', async () => {
    const other: SandboxGrant = { ...GRANT, sandbox_id: 'z9y8x7w6v5u4t3s2r1q0', domain: 'sbx.example.test' };
    agent = agentOf(other);
    expect(sandboxOf(other).sandboxDomain).toBe('sbx.example.test');
    expect(await e2bRunner('hello').run(other, FILES, 'mopm run src/main.mojo')).toEqual({ exit_code: 0, stdout: 'Hello, world!\n', stderr: '' });
    expect(seen.map((s) => new URL(s.url).origin)).toEqual([agent, agent]);
    expect(seen.map((s) => s.headers['e2b-sandbox-id'])).toEqual([other.sandbox_id, other.sandbox_id]);
  });

  test('a non-zero exit is the program\'s: its code and output, not an error', async () => {
    script.start = exited(3, 'partial\n', 'error: no main\n');
    expect(await e2bRunner('hello').run(GRANT, FILES, 'mopm run src/main.mojo')).toEqual({ exit_code: 3, stdout: 'partial\n', stderr: 'error: no main\n' });
  });

  test('no files: nothing is uploaded and the command still runs', async () => {
    expect(await e2bRunner('hello').run(GRANT, [], 'mopm run src/main.mojo')).toEqual({ exit_code: 0, stdout: 'Hello, world!\n', stderr: '' });
    expect(seen.map((s) => new URL(s.url).pathname)).toEqual(['/process.Process/Start']);
  });

  test('the command timeout is passed to the agent', async () => {
    await e2bRunner('hello').run(GRANT, FILES, 'mopm run src/main.mojo');
    const start = seen.find((s) => s.url.endsWith('/process.Process/Start'));
    expect(start?.headers['connect-timeout-ms']).toBe(String(RUN_TIMEOUT_MS));
  });
});

describe('a sandbox that is gone', () => {
  const GONE = `The sandbox ${GRANT.sandbox_id} was not found`;
  const CLOSED = `The sandbox ${GRANT.sandbox_id} is running but port is not open`;

  test('not found on the run: SandboxNotRunning', async () => {
    script.start = proxy(GONE);
    expect(await e2bRunner('hello').run(GRANT, FILES, 'mopm run src/main.mojo')).toEqual({ kind: 'SandboxNotRunning' });
  });

  test('not found on the upload: SandboxNotRunning, and the command is not run', async () => {
    script.files = proxy(GONE);
    expect(await e2bRunner('hello').run(GRANT, FILES, 'mopm run src/main.mojo')).toEqual({ kind: 'SandboxNotRunning' });
    expect(started).toEqual([]);
  });

  test('its port not open: SandboxUnreachable', async () => {
    script.start = proxy(CLOSED);
    expect(await e2bRunner('hello').run(GRANT, FILES, 'mopm run src/main.mojo')).toEqual({ kind: 'SandboxUnreachable' });
  });

  test('its port not open on the upload: SandboxUnreachable', async () => {
    script.files = proxy(CLOSED);
    expect(await e2bRunner('hello').run(GRANT, FILES, 'mopm run src/main.mojo')).toEqual({ kind: 'SandboxUnreachable' });
  });
});

describe('any other failure is thrown as the SDK raised it', () => {
  test('a refused token on the upload: the SDK\'s AuthenticationError', async () => {
    script.files = (res) => {
      res.writeHead(401, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ code: 401, message: 'invalid access token' }));
    };
    const r = e2bRunner('hello').run(GRANT, FILES, 'mopm run src/main.mojo');
    await expect(r).rejects.toBeInstanceOf(e2b.AuthenticationError);
    await expect(r).rejects.toThrow('invalid access token');
    expect(started).toEqual([]);
  });
});

describe('the lesson grammar, checked before any request', () => {
  test.each([
    ['a lesson id with a capital', 'Hello', 'not a lesson id: "Hello"'],
    ['a lesson id that climbs', '../x', 'not a lesson id: "../x"'],
    ['a lesson id over 64 characters', 'a'.repeat(65), `not a lesson id: "${'a'.repeat(65)}"`],
  ])('%s: building the runner is a RangeError', (_, lesson, message) => {
    expect(() => e2bRunner(lesson)).toThrow(new RangeError(message));
  });

  test.each([
    ['an absolute file path', 'hello', [{ path: '/etc/passwd', text: '' }], 'mopm run src/main.mojo', 'not a lesson file path: "/etc/passwd"'],
    ['a file path that climbs', 'hello', [{ path: 'src/../../x', text: '' }], 'mopm run src/main.mojo', 'not a lesson file path: "src/../../x"'],
    ['an empty file path', 'hello', [{ path: '', text: '' }], 'mopm run src/main.mojo', 'not a lesson file path: ""'],
    ['a file path over 255 characters', 'hello', [{ path: 'a'.repeat(256), text: '' }], 'mopm run src/main.mojo', `not a lesson file path: "${'a'.repeat(256)}"`],
    ['a command a shell would read', 'hello', FILES, 'mopm run src/main.mojo; curl x', 'not a lesson command: "mopm run src/main.mojo; curl x"'],
    ['mopm run with no program', 'hello', FILES, 'mopm run', 'not a lesson command: "mopm run"'],
    ['a command that is not mopm run or mopm test', 'hello', FILES, 'mopm sync', 'not a lesson command: "mopm sync"'],
    ['a command over 200 characters', 'hello', FILES, `mopm test ${'a'.repeat(191)}`, `not a lesson command: "mopm test ${'a'.repeat(191)}"`],
  ])('%s is a RangeError', async (_, lesson, files, command, message) => {
    const r = e2bRunner(lesson).run(GRANT, files, command);
    await expect(r).rejects.toThrow(new RangeError(message));
    expect(seen).toEqual([]);
  });

  test('the longest accepted id, path and command run', async () => {
    const id = 'a'.repeat(64);
    const path = 'a'.repeat(255);
    const command = `mopm test ${'a'.repeat(190)}`;
    expect(command.length).toBe(200);
    expect(await e2bRunner(id).run(GRANT, [{ path, text: 'x' }], command)).toEqual({ exit_code: 0, stdout: 'Hello, world!\n', stderr: '' });
    expect(written).toEqual([{ path: `${LESSONS_DIR}/${id}/${path}`, content: 'x' }]);
  });

  test('a dotfile path and mopm test with no arguments are lesson grammar', async () => {
    await e2bRunner('hello').run(GRANT, [{ path: '.mopm/x', text: '' }], 'mopm test');
    expect(written.map((w) => w.path)).toEqual([`${DIR}/.mopm/x`]);
  });

  test('lessonDir is the lesson\'s directory under LESSONS_DIR', () => {
    expect(lessonDir('hello-2')).toBe('/home/user/lessons/hello-2');
    expect(() => lessonDir('hello--2')).toThrow(RangeError);
  });
});
