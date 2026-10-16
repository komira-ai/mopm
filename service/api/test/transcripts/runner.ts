import {
  Authenticator,
  DeviceLogin,
  GithubJwtVerifier,
  HttpGitHubApi,
  OidcExchange,
  TokenService,
} from '../../src/auth';
import type { AuthServices } from '../../src/http/auth-routes';
import { route, type HttpRequest, type RouterDeps, type Stage } from '../../src/http/router';
import { MemoryStore } from '../../src/memory-store';
import type { PublishConfig } from '../../src/publish/config';
import type { Store } from '../../src/store';
import { fakeGitHub } from '../auth-helpers';
import { Harness } from '../publish/harness';
import { applySeed, readSeed } from '../seeds/load';

/** One scenario file (fixtures/transcripts/scenarios/*.json); the formats are described in README.md next to this file. */
export interface Scenario {
  description: string;
  world: World;
  steps: Step[];
}
export interface World {
  stage?: Stage;
  version?: string;
  commit?: string;
  seeds?: string[];
  clock?: string;
  /** Wire the login, token and CI-exchange routes. */
  auth?: boolean;
  /** Wire begin-upload, commit, status and yank. */
  publish?: boolean;
  read_only?: boolean;
  limits?: Partial<PublishConfig>;
  github?: { poll_script?: Array<Record<string, unknown>>; user?: Record<string, unknown>; user_status?: number };
  require_2fa?: boolean;
  /** The registry store fails every call (an internal error on every read). */
  faults?: { store?: boolean };
}
export type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
export interface ReqSpec {
  method: string;
  path: string;
  query?: Record<string, string>;
  headers?: Record<string, string>;
  /** Shorthand for headers.authorization = `Bearer <token>`. */
  token?: string;
  /** The raw body, or `{"$repeat": [text, n]}` for text repeated n times. */
  body?: string | { $repeat: [string, number] };
  /** The body as JSON, written compactly. */
  json?: Json;
}
export type Step =
  | { request: ReqSpec; expect?: { status: number; code?: string } }
  | { set: { read_only?: boolean; flags_broken?: boolean; clock?: string; advance_s?: number } }
  | { put_object: { upload_id: string; content: string } };

export interface RecordedStep {
  request?: { method: string; path: string; query: Record<string, string>; headers: Record<string, string>; body?: string };
  response?: { status: number; headers: Array<[string, string]>; body: string };
  set?: Json;
  put_object?: { upload_id: string; content: string };
}
export interface Transcript {
  description: string;
  world: World;
  steps: RecordedStep[];
}

/**
 * The transcript random source, so that identifiers and secrets are the same on every run and in every
 * implementation: the k-th call (from 0) of randomBytes(n) returns the bytes (k*167 + j*29 + 11) mod 256, j from 0 to n-1.
 */
export function installTranscriptRandom(): () => void {
  // The real module object (not a namespace copy), so the code under test sees the replacement.
  const crypto = require('node:crypto'); // eslint-disable-line @typescript-eslint/no-require-imports
  const original = crypto.randomBytes;
  let k = 0;
  crypto.randomBytes = (n: number) => {
    const out = Buffer.alloc(n);
    for (let j = 0; j < n; j++) out[j] = (k * 167 + j * 29 + 11) % 256;
    k++;
    return out;
  };
  return () => {
    crypto.randomBytes = original;
  };
}

const failingStore = (): Store =>
  new Proxy({} as Store, {
    get: () => async () => {
      throw new Error('store fault');
    },
  });

function dig(v: unknown, path: string): unknown {
  let cur: any = v; // eslint-disable-line @typescript-eslint/no-explicit-any
  for (const part of path.split('.')) cur = cur?.[/^[0-9]+$/.test(part) ? Number(part) : part];
  return cur;
}

/** `{{N.path}}`: member `path` of the JSON body of the N-th request's response (counting requests only). */
function fill<T>(v: T, responses: unknown[]): T {
  if (typeof v === 'string') {
    return v.replace(/\{\{(\d+)\.([^}]+)\}\}/g, (_m, n: string, p: string) => {
      const x = dig(responses[Number(n)], p);
      if (typeof x !== 'string' && typeof x !== 'number') throw new Error(`template {{${n}.${p}}} is not a string or number`);
      return String(x);
    }) as unknown as T;
  }
  if (Array.isArray(v)) return v.map((x) => fill(x, responses)) as unknown as T;
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, fill(x, responses)])) as unknown as T;
  return v;
}

/** Runs a scenario; returns what happened, and the expectations the scenario author wrote that did not hold. */
export async function runScenario(sc: Scenario): Promise<{ transcript: Transcript; unmet: string[] }> {
  const w = sc.world;
  const registry = new MemoryStore();
  const h = new Harness(w.limits ?? {}, registry);
  if (w.clock) h.clock.t = Date.parse(w.clock);
  h.flags.ro = w.read_only ?? false;
  for (const name of w.seeds ?? []) await applySeed(readSeed(name), { registry, auth: h.authStore, publishes: h.publishes });

  const github = fakeGitHub({
    ...(w.github?.poll_script ? { pollScript: [...w.github.poll_script] } : {}),
    ...(w.github?.user ? { user: w.github.user } : {}),
    ...(w.github?.user_status ? { userStatus: w.github.user_status } : {}),
  });
  const owned = async (id: number) => {
    const out: string[] = [];
    for (const n of await registry.listPackageNames()) if ((await registry.listOwners(n)).some((o) => o.github_id === id)) out.push(n);
    return out;
  };
  const auth: AuthServices | undefined = w.auth
    ? {
        authn: new Authenticator({ store: h.authStore, now: h.clock.now }),
        tokens: new TokenService({ store: h.authStore, ownedPackages: owned, now: h.clock.now }),
        oidc: new OidcExchange({
          store: h.authStore,
          now: h.clock.now,
          verifier: new GithubJwtVerifier({ audiences: ['mopm.dev'], now: h.clock.now, jwks: async () => ({ keys: [] }) }),
        }),
        devices: async () => new DeviceLogin({ store: h.authStore, github: new HttpGitHubApi('Iv1.testclientid', github.fetchFn), now: h.clock.now, require2fa: w.require_2fa }),
      }
    : undefined;
  const deps: RouterDeps = {
    ...h.deps,
    store: w.faults?.store ? failingStore() : registry,
    stage: w.stage ?? 'beta',
    version: w.version ?? 'test',
    commit: w.commit ?? 'test',
    ...(auth ? { auth } : {}),
  };
  if (!w.publish) delete deps.publish;

  const restoreRandom = installTranscriptRandom();
  const quiet = jest.spyOn(console, 'error').mockImplementation(() => undefined);
  const responses: unknown[] = [];
  const steps: RecordedStep[] = [];
  const unmet: string[] = [];
  try {
    for (const step of sc.steps) {
      if ('set' in step) {
        const s = step.set;
        if (s.read_only !== undefined) h.flags.ro = s.read_only;
        if (s.flags_broken !== undefined) h.flags.broken = s.flags_broken;
        if (s.clock !== undefined) h.clock.t = Date.parse(s.clock);
        if (s.advance_s !== undefined) h.clock.advance(s.advance_s * 1000);
        steps.push({ set: s as unknown as Json });
        continue;
      }
      if ('put_object' in step) {
        const p = fill(step.put_object, responses);
        const rec = await h.publishes.getUpload(p.upload_id);
        if (!rec) throw new Error(`put_object: no upload ${p.upload_id}`);
        await h.objects.put(rec.key, Buffer.from(p.content, 'utf8'), { contentType: 'application/octet-stream' });
        steps.push({ put_object: p });
        continue;
      }
      const spec = fill(step.request, responses);
      const body =
        spec.json !== undefined ? JSON.stringify(spec.json) : typeof spec.body === 'object' && spec.body !== null ? spec.body.$repeat[0].repeat(spec.body.$repeat[1]) : spec.body;
      const headers = { ...(spec.token ? { authorization: `Bearer ${spec.token}` } : {}), ...(spec.headers ?? {}) };
      const req: HttpRequest = { method: spec.method, path: spec.path, query: spec.query ?? {}, headers, ...(body !== undefined ? { body } : {}) };
      // What lambda.ts does before it routes: the switch is read per request; if it cannot be read, health reports the deployment's own value (false).
      let readOnly = false;
      try {
        readOnly = await h.flags.readOnly();
      } catch {
        readOnly = false;
      }
      const res = await route(req, { ...deps, readOnly }, `req-${responses.length + 1}`);
      let parsed: unknown;
      try {
        parsed = res.body ? JSON.parse(res.body) : undefined;
      } catch {
        parsed = undefined;
      }
      steps.push({
        request: { method: req.method, path: req.path, query: req.query as Record<string, string>, headers, ...(body !== undefined ? { body } : {}) },
        response: { status: res.statusCode, headers: Object.entries(res.headers), body: res.body },
      });
      if (step.expect) {
        const code = (parsed as { error?: { code?: string } } | undefined)?.error?.code;
        if (res.statusCode !== step.expect.status || (step.expect.code !== undefined && code !== step.expect.code)) {
          unmet.push(`request ${responses.length} (${req.method} ${req.path}): wanted ${step.expect.status}${step.expect.code ? ' ' + step.expect.code : ''}, got ${res.statusCode}${code ? ' ' + code : ''}`);
        }
      }
      responses.push(parsed);
    }
  } finally {
    quiet.mockRestore();
    restoreRandom();
  }
  return { transcript: { description: sc.description, world: sc.world, steps }, unmet };
}
