import { existsSync } from 'fs';
import { join } from 'path';
import { Template, TemplateBase } from 'e2b';
import type { BuildOptions, LogEntry } from 'e2b';
import { Deps, LATEST_RELEASE_URL, latestRelease, main, realDeps, USAGE } from '../src/cli';
import { fixtureRepo, REPO_ROOT } from './fixture';

const KEY = 'e2b_0123456789abcdef0123456789abcdef';

interface Run {
  code: number;
  out: string[];
  err: string[];
  fetched: string[];
  built: { name: string; options: Omit<BuildOptions, 'alias'> }[];
}

/** Runs main against a fixture repository with fakes; the fakes record every call. */
async function run(argv: string[], over: Partial<Deps> = {}, root = fixtureRepo('0.3', ['hello', 'loops']).root): Promise<Run> {
  const r: Run = { code: -1, out: [], err: [], fetched: [], built: [] };
  const deps: Deps = {
    repoRoot: root,
    env: { E2B_API_KEY: KEY },
    out: (l) => r.out.push(l),
    err: (l) => r.err.push(l),
    fetch: async (url) => {
      r.fetched.push(url);
      return { ok: true, status: 200, json: async () => ({ tag_name: 'v0.3.9' }) };
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

const STEPS_09 = [
  'steps:',
  '  FROM e2bdev/base',
  '  COPY site/static/install.sh /opt/mopm-install/install.sh (owner root)',
  '  RUN MOPM_VERSION=0.3.9 MOPM_HOME=/usr/local sh /opt/mopm-install/install.sh && rm /opt/mopm-install/install.sh (as root)',
  '  COPY tutorial/lessons/hello/project /home/user/lessons/hello/ (owner user)',
  '  WORKDIR /home/user/lessons/hello',
  '  RUN mopm sync --locked --cache /home/user/.cache/mopm/pkgs (as user)',
  '  COPY tutorial/lessons/loops/project /home/user/lessons/loops/ (owner user)',
  '  WORKDIR /home/user/lessons/loops',
  '  RUN mopm sync --locked --cache /home/user/.cache/mopm/pkgs (as user)',
  '  WORKDIR /home/user',
  '  USER user',
];

describe('the dry run (the default)', () => {
  test('prints the plan, makes no network call and builds nothing, even with the key set', async () => {
    const r = await run(['--stage', 'beta', '--name', 'mopm-tutorial-beta']);
    expect(r.code).toBe(0);
    expect(r.fetched).toEqual([]);
    expect(r.built).toEqual([]);
    expect(r.err).toEqual([]);
    expect(r.out.slice(0, 6)).toEqual([
      'dry run: nothing is built and nothing is sent (add --build to build)',
      'stage: beta',
      'name: mopm-tutorial-beta',
      'mopm: 0.3.<latest> (the latest release, looked up when --build runs; it must be a release of 0.3 (VERSION))',
      'lessons: hello, loops',
      'steps:',
    ]);
    expect(r.out[8]).toBe('  RUN MOPM_VERSION=0.3.<latest> MOPM_HOME=/usr/local sh /opt/mopm-install/install.sh && rm /opt/mopm-install/install.sh (as root)');
    expect(r.out).toHaveLength(6 + STEPS_09.length - 1);
    expectNoKey(r);
  });

  test('with --mopm-version, the plan names that release', async () => {
    const r = await run(['--mopm-version', 'v0.3.9', '--stage', 'prod', '--name', 'mopm_tutorial']);
    expect(r.code).toBe(0);
    expect(r.fetched).toEqual([]);
    expect(r.out.slice(0, 5)).toEqual([
      'dry run: nothing is built and nothing is sent (add --build to build)',
      'stage: prod',
      'name: mopm_tutorial',
      'mopm: 0.3.9 (--mopm-version, a release of 0.3 (VERSION))',
      'lessons: hello, loops',
    ]);
    expect(r.out.slice(5)).toEqual(STEPS_09);
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
  test('looks up the latest release, builds with the key and prints the template id; logs are redacted', async () => {
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
    expect(r.fetched).toEqual([LATEST_RELEASE_URL]);
    expect(r.err).toEqual([]);
    expect(r.out.slice(0, 5)).toEqual([
      'building the template on E2B',
      'stage: gamma',
      'name: mopm-tutorial-gamma',
      'mopm: 0.3.9 (the latest release, which is of 0.3 (VERSION))',
      'lessons: hello, loops',
    ]);
    expect(r.out.slice(5, 5 + STEPS_09.length)).toEqual(STEPS_09);
    expect(r.out.slice(5 + STEPS_09.length)).toEqual([
      'e2b: info using key <redacted>',
      'template id: tpl123',
      'build id: b456',
      'next: set tpl123 as the gamma stage\'s tutorial template id in its settings',
    ]);
    expectNoKey(r);
  });

  test('passes the key to E2B as apiKey and the template under its name', async () => {
    const r = await run(['--stage', 'beta', '--name', 'mopm-tutorial-beta', '--build', '--mopm-version', '0.3.2']);
    expect(r.code).toBe(0);
    expect(r.fetched).toEqual([]);
    expect(r.built).toHaveLength(1);
    expect(r.built[0].name).toBe('mopm-tutorial-beta');
    expect(r.built[0].options.apiKey).toBe(KEY);
    expect(r.out).toContain('  RUN MOPM_VERSION=0.3.2 MOPM_HOME=/usr/local sh /opt/mopm-install/install.sh && rm /opt/mopm-install/install.sh (as root)');
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
      fetch: async () => ({ ok: true, status: 200, json: async () => ({ tag_name: 'v0.4.1' }) }),
    });
    expect(r.code).toBe(1);
    expect(r.err).toEqual(['build.ts: mopm 0.4.1 is not a release of 0.3, the base in VERSION']);
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
  const answer = (ok: boolean, status: number, body: unknown) => async () => ({ ok, status, json: async () => body });

  test('the tag of GitHub\'s latest release, asked for as JSON', async () => {
    const seen: unknown[] = [];
    const tag = await latestRelease(async (url, init) => {
      seen.push([url, init]);
      return { ok: true, status: 200, json: async () => ({ tag_name: 'v0.0.12' }) };
    });
    expect(tag).toBe('v0.0.12');
    expect(seen).toEqual([[LATEST_RELEASE_URL, { headers: { accept: 'application/vnd.github+json' } }]]);
  });

  test('an error status is refused', async () => {
    await expect(latestRelease(answer(false, 404, {}))).rejects.toThrow(
      `could not look up the latest mopm release: ${LATEST_RELEASE_URL} answered 404`,
    );
  });

  test.each([null, {}, { tag_name: 7 }])('an answer without a tag (%j) is refused', async (body) => {
    await expect(latestRelease(answer(true, 200, body))).rejects.toThrow(
      `could not look up the latest mopm release: ${LATEST_RELEASE_URL} named no tag`,
    );
  });
});

describe('realDeps', () => {
  afterEach(() => jest.restoreAllMocks());

  test('this checkout, the process environment, its streams, global fetch and E2B\'s Template.build', async () => {
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
