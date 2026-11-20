import { existsSync } from 'fs';
import { join } from 'path';
import { Template, TemplateBase } from 'e2b';
import type { BuildOptions, LogEntry } from 'e2b';
import { Deps, LATEST_RELEASE_URL, latestRelease, main, realDeps, releaseSha256, USAGE } from '../src/cli';
import { installCommand } from '../src/definition';
import { fixtureRepo, REPO_ROOT } from './fixture';

const KEY = 'e2b_0123456789abcdef0123456789abcdef';
const SHA = 'ab'.repeat(32);
const OTHER_SHA = 'cd'.repeat(32);

type Answer = Awaited<ReturnType<Deps['fetch']>>;

/** An answer of the fake fetch. */
function answer(status: number, body: string): Answer {
  return { ok: status >= 200 && status < 300, status, json: async () => JSON.parse(body), text: async () => body };
}

/** The release's SHA256SUMS: the linux-x86_64 file and two others, in release order. */
function sums(version: string, sha = SHA): string {
  return [
    `${OTHER_SHA}  mopm-${version}-linux-aarch64.tar.gz`,
    `${sha}  mopm-${version}-linux-x86_64.tar.gz`,
    `${OTHER_SHA}  mopm-${version}-macos-arm64.tar.gz`,
    '',
  ].join('\n');
}

const SUMS_URL = (v: string) => `https://github.com/komira-ai/mopm/releases/download/v${v}/SHA256SUMS`;

/** GitHub as the build sees it: the latest release is v0.3.9, and every release has its SHA256SUMS. */
function github(urls: Record<string, Answer> = {}): (url: string) => Answer {
  return (url) => {
    if (url in urls) return urls[url];
    if (url === LATEST_RELEASE_URL) return answer(200, JSON.stringify({ tag_name: 'v0.3.9' }));
    const m = /\/v(\d+\.\d+\.\d+)\/SHA256SUMS$/.exec(url);
    return m ? answer(200, sums(m[1])) : answer(404, '');
  };
}

interface Run {
  code: number;
  out: string[];
  err: string[];
  fetched: string[];
  built: { name: string; options: Omit<BuildOptions, 'alias'> }[];
}

/** Runs main against a fixture repository with fakes; the fakes record every call. */
async function run(argv: string[], over: Partial<Deps> & { site?: (url: string) => Answer } = {}, root = fixtureRepo('0.3', ['hello', 'loops']).root): Promise<Run> {
  const r: Run = { code: -1, out: [], err: [], fetched: [], built: [] };
  const site = over.site ?? github();
  const deps: Deps = {
    repoRoot: root,
    env: { E2B_API_KEY: KEY },
    out: (l) => r.out.push(l),
    err: (l) => r.err.push(l),
    fetch: async (url) => {
      r.fetched.push(url);
      return site(url);
    },
    build: async (_t, name, options) => {
      r.built.push({ name, options });
      return { alias: name, name, tags: [], templateId: 'tpl123', buildId: 'b456' };
    },
    ...over,
  };
  r.code = await main(argv, deps);
  return r;
}

/** No line of the run carries the key. */
function expectNoKey(r: Run) {
  for (const line of [...r.out, ...r.err]) expect(line).not.toContain(KEY);
}

/** The printed steps for the two fixture lessons with mopm `version` and `sha256`. */
function stepLines(version: string, sha256: string): string[] {
  return [
    'steps:',
    '  FROM e2bdev/base',
    `  RUN ${installCommand({ version, sha256 })} (as root)`,
    '  COPY tutorial/lessons/hello/project /home/user/lessons/hello/ (owner user)',
    '  WORKDIR /home/user/lessons/hello',
    '  RUN mopm sync --locked --cache /home/user/.cache/mopm/pkgs (as user)',
    '  COPY tutorial/lessons/loops/project /home/user/lessons/loops/ (owner user)',
    '  WORKDIR /home/user/lessons/loops',
    '  RUN mopm sync --locked --cache /home/user/.cache/mopm/pkgs (as user)',
    '  WORKDIR /home/user',
    '  USER user',
  ];
}

describe('the dry run (the default)', () => {
  test('prints the plan, makes no network call and builds nothing, even with the key set', async () => {
    const r = await run(['--stage', 'beta', '--name', 'mopm-tutorial-beta']);
    expect(r.code).toBe(0);
    expect(r.fetched).toEqual([]);
    expect(r.built).toEqual([]);
    expect(r.err).toEqual([]);
    expect(r.out).toEqual([
      'dry run: nothing is built and nothing is sent (add --build to build)',
      'stage: beta',
      'name: mopm-tutorial-beta',
      'mopm: 0.3.<latest> (the latest release, looked up when --build runs; it must be a release of 0.3 (VERSION))',
      'sha256 of mopm-0.3.<latest>-linux-x86_64.tar.gz: <sha256 from SHA256SUMS> (read from the release when --build runs)',
      'lessons: hello, loops',
      ...stepLines('0.3.<latest>', '<sha256 from SHA256SUMS>'),
    ]);
    expectNoKey(r);
  });

  test('with --mopm-version, the plan names that release, still with no network call', async () => {
    const r = await run(['--mopm-version', 'v0.3.9', '--stage', 'prod', '--name', 'mopm_tutorial']);
    expect(r.code).toBe(0);
    expect(r.fetched).toEqual([]);
    expect(r.out).toEqual([
      'dry run: nothing is built and nothing is sent (add --build to build)',
      'stage: prod',
      'name: mopm_tutorial',
      'mopm: 0.3.9 (--mopm-version, a release of 0.3 (VERSION))',
      'sha256 of mopm-0.3.9-linux-x86_64.tar.gz: <sha256 from SHA256SUMS> (read from the release when --build runs)',
      'lessons: hello, loops',
      ...stepLines('0.3.9', '<sha256 from SHA256SUMS>'),
    ]);
  });

  test('--mopm-version of another base than VERSION is refused', async () => {
    const r = await run(['--stage', 'beta', '--name', 'n', '--mopm-version', '0.2.9']);
    expect(r.code).toBe(1);
    expect(r.out).toEqual([]);
    expect(r.err).toEqual(['build.ts: mopm 0.2.9 is not a release of 0.3, the base in VERSION']);
  });

  test('a broken lesson tree fails before anything is printed', async () => {
    const repo = fixtureRepo('0.3', ['Bad']);
    const r = await run(['--stage', 'beta', '--name', 'n'], {}, repo.root);
    expect(r.code).toBe(1);
    expect(r.out).toEqual([]);
    expect(r.err).toEqual(['build.ts: tutorial/lessons/Bad: a lesson id is lower-case letters and digits in words joined by single hyphens']);
  });
});

describe('the flags', () => {
  test.each([
    [['--stage', 'staging', '--name', 'n'], "unknown stage 'staging'; the stages are beta, gamma, prod"],
    [['--stage', 'Beta', '--name', 'n'], "unknown stage 'Beta'; the stages are beta, gamma, prod"],
    [['--name', 'n'], '--stage is required'],
    [['--stage', 'beta'], '--name is required'],
    [['--stage', 'beta', '--name', 'Has Space'], "'Has Space' is not a template name (lower-case letters, digits, '-' and '_')"],
    [['--stage', 'beta', '--name', '-x'], "'-x' is not a template name (lower-case letters, digits, '-' and '_')"],
    [['--stage', 'beta', '--name', 'n', '--dry-run'], "unknown argument '--dry-run'"],
    [['--stage', 'beta', '--stage', 'prod', '--name', 'n'], '--stage is given twice'],
    [['--stage', 'beta', '--name'], '--name needs a value'],
    [['--stage', '', '--name', 'n'], '--stage needs a value'],
    [[], '--stage is required'],
  ])('%j is refused as a usage error', async (argv, msg) => {
    const r = await run(argv);
    expect(r.code).toBe(2);
    expect(r.out).toEqual([]);
    expect(r.err).toEqual([`build.ts: ${msg}`, USAGE]);
    expect(r.fetched).toEqual([]);
    expect(r.built).toEqual([]);
  });
});

describe('--build', () => {
  test('looks up the latest release and its sha256, builds with the key and prints the template id; logs are redacted', async () => {
    const names: string[] = [];
    const r = await run(['--stage', 'gamma', '--name', 'mopm-tutorial-gamma', '--build'], {
      build: async (_t, name, options) => {
        names.push(name);
        options.onBuildLogs?.({ level: 'info', message: `using key ${KEY}`, timestamp: new Date(0) } as LogEntry);
        return { alias: name, name, tags: [], templateId: 'tpl123', buildId: 'b456' };
      },
    });
    expect(names).toEqual(['mopm-tutorial-gamma']);
    expect(r.code).toBe(0);
    expect(r.fetched).toEqual([LATEST_RELEASE_URL, SUMS_URL('0.3.9')]);
    expect(r.err).toEqual([]);
    expect(r.out).toEqual([
      'building the template on E2B',
      'stage: gamma',
      'name: mopm-tutorial-gamma',
      'mopm: 0.3.9 (the latest release, which is of 0.3 (VERSION))',
      `sha256 of mopm-0.3.9-linux-x86_64.tar.gz: ${SHA} (from ${SUMS_URL('0.3.9')})`,
      'lessons: hello, loops',
      ...stepLines('0.3.9', SHA),
      'e2b: info using key <redacted>',
      'template id: tpl123',
      'build id: b456',
      "next: set tpl123 as the gamma stage's tutorial template id in its settings",
    ]);
    expectNoKey(r);
  });

  test('passes the key to E2B as apiKey and the template under its name; --mopm-version skips the latest lookup', async () => {
    const r = await run(['--stage', 'beta', '--name', 'mopm-tutorial-beta', '--build', '--mopm-version', '0.3.2']);
    expect(r.code).toBe(0);
    expect(r.fetched).toEqual([SUMS_URL('0.3.2')]);
    expect(r.built).toHaveLength(1);
    expect(r.built[0].name).toBe('mopm-tutorial-beta');
    expect(r.built[0].options.apiKey).toBe(KEY);
    expect(r.out).toContain(`  RUN ${installCommand({ version: '0.3.2', sha256: SHA })} (as root)`);
  });

  test.each([{}, { E2B_API_KEY: '' }])('without the key (env %j) it refuses before any network call', async (env) => {
    const r = await run(['--stage', 'beta', '--name', 'n', '--build'], { env });
    expect(r.code).toBe(1);
    expect(r.out).toEqual([]);
    expect(r.err).toEqual(['build.ts: --build needs the team key in E2B_API_KEY']);
    expect(r.fetched).toEqual([]);
    expect(r.built).toEqual([]);
  });

  test('a latest release of another base than VERSION is refused and nothing is built', async () => {
    const r = await run(['--stage', 'beta', '--name', 'n', '--build'], {
      site: github({ [LATEST_RELEASE_URL]: answer(200, JSON.stringify({ tag_name: 'v0.4.1' })) }),
    });
    expect(r.code).toBe(1);
    expect(r.err).toEqual(['build.ts: mopm 0.4.1 is not a release of 0.3, the base in VERSION']);
    expect(r.built).toEqual([]);
  });

  test('a release whose SHA256SUMS cannot be read is not built', async () => {
    const r = await run(['--stage', 'beta', '--name', 'n', '--build'], { site: github({ [SUMS_URL('0.3.9')]: answer(404, 'Not Found') }) });
    expect(r.code).toBe(1);
    expect(r.out).toEqual([]);
    expect(r.err).toEqual([`build.ts: could not read ${SUMS_URL('0.3.9')}: it answered 404`]);
    expect(r.built).toEqual([]);
  });

  test('an E2B error that quotes the key is printed with the key redacted, by exact equality', async () => {
    const r = await run(['--stage', 'beta', '--name', 'n', '--build'], {
      build: async () => {
        throw new Error(`401: invalid API key ${KEY} (${KEY})`);
      },
    });
    expect(r.code).toBe(1);
    expect(r.err).toEqual(['build.ts: 401: invalid API key <redacted> (<redacted>)']);
    expect(r.out.some((l) => l.startsWith('template id'))).toBe(false);
    expectNoKey(r);
  });

  test('a thrown value that is not an Error is printed as text', async () => {
    const r = await run(['--stage', 'beta', '--name', 'n', '--build'], {
      build: async () => {
        throw `refused ${KEY}`;
      },
    });
    expect(r.code).toBe(1);
    expect(r.err).toEqual(['build.ts: refused <redacted>']);
  });
});

describe('latestRelease', () => {
  test("the tag of GitHub's latest release, asked for as JSON", async () => {
    const seen: unknown[] = [];
    const tag = await latestRelease(async (url, init) => {
      seen.push([url, init]);
      return answer(200, JSON.stringify({ tag_name: 'v0.0.12' }));
    });
    expect(tag).toBe('v0.0.12');
    expect(seen).toEqual([[LATEST_RELEASE_URL, { headers: { accept: 'application/vnd.github+json' } }]]);
  });

  test('an error status is refused', async () => {
    await expect(latestRelease(async () => answer(404, '{}'))).rejects.toThrow(
      `could not look up the latest mopm release: ${LATEST_RELEASE_URL} answered 404`,
    );
  });

  test.each(['null', '{}', '{"tag_name":7}'])('an answer without a tag (%s) is refused', async (body) => {
    await expect(latestRelease(async () => answer(200, body))).rejects.toThrow(
      `could not look up the latest mopm release: ${LATEST_RELEASE_URL} named no tag`,
    );
  });
});

describe('releaseSha256', () => {
  const read = (body: string) => releaseSha256(async () => answer(200, body), '0.3.9');
  const refused = `${SUMS_URL('0.3.9')} does not list mopm-0.3.9-linux-x86_64.tar.gz exactly once with a sha256`;

  test("the linux-x86_64 file's entry, from the release's own SHA256SUMS", async () => {
    const seen: string[] = [];
    const sha = await releaseSha256(async (url) => {
      seen.push(url);
      return answer(200, sums('0.3.9'));
    }, '0.3.9');
    expect(sha).toBe(SHA);
    expect(seen).toEqual([SUMS_URL('0.3.9')]);
  });

  test('an entry with CRLF line ends and surrounding space is read', async () => {
    expect(await read(` ${SHA}  mopm-0.3.9-linux-x86_64.tar.gz \r\n`)).toBe(SHA);
  });

  test.each([
    ['no entry for the file', `${OTHER_SHA}  mopm-0.3.9-linux-aarch64.tar.gz\n`],
    ['the file listed twice', `${SHA}  mopm-0.3.9-linux-x86_64.tar.gz\n${OTHER_SHA}  mopm-0.3.9-linux-x86_64.tar.gz\n`],
    ['an upper-case digest', `${SHA.toUpperCase()}  mopm-0.3.9-linux-x86_64.tar.gz\n`],
    ['a short digest', `${SHA.slice(2)}  mopm-0.3.9-linux-x86_64.tar.gz\n`],
    ['a digest with a non-hex character', `${SHA.slice(1)}g  mopm-0.3.9-linux-x86_64.tar.gz\n`],
    ['an entry for another version', sums('0.3.8')],
    ['an empty file', ''],
  ])('%s is refused', async (_why, body) => {
    await expect(read(body)).rejects.toThrow(refused);
  });

  test('an error status is refused', async () => {
    await expect(releaseSha256(async () => answer(500, ''), '0.3.9')).rejects.toThrow(`could not read ${SUMS_URL('0.3.9')}: it answered 500`);
  });
});

describe('realDeps', () => {
  afterEach(() => jest.restoreAllMocks());

  test("this checkout, the process environment, its streams, global fetch and E2B's Template.build", async () => {
    const d = realDeps();
    expect(d.repoRoot).toBe(REPO_ROOT);
    expect(existsSync(join(d.repoRoot, 'VERSION'))).toBe(true);
    expect(d.env).toBe(process.env);

    const out = jest.spyOn(process.stdout, 'write').mockImplementation(() => true);
    const err = jest.spyOn(process.stderr, 'write').mockImplementation(() => true);
    d.out('o');
    d.err('e');
    expect(out).toHaveBeenCalledWith('o\n');
    expect(err).toHaveBeenCalledWith('e\n');

    const response = new Response('{}');
    const fetch = jest.spyOn(globalThis, 'fetch').mockResolvedValue(response);
    expect(await d.fetch('https://example.invalid/x', { headers: { a: 'b' } })).toBe(response);
    expect(fetch).toHaveBeenCalledWith('https://example.invalid/x', { headers: { a: 'b' } });

    const info = { alias: 'n', name: 'n', tags: [], templateId: 't', buildId: 'b' };
    // Template is a proxy over TemplateBase that binds its static methods on each read: the spy goes on the class.
    const build = jest.spyOn(TemplateBase, 'build').mockResolvedValue(info);
    const t = Template().fromBaseImage();
    expect(await d.build(t, 'n', { apiKey: 'k' })).toBe(info);
    expect(build).toHaveBeenCalledWith(t, 'n', { apiKey: 'k' });
  });
});
