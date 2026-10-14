import { createHash } from 'node:crypto';
import { Authenticator, MemoryAuthStore, mintToken } from '../../src/auth';
import type { PublishApi } from '../../src/http/publish-routes';
import { route, type HttpResponse, type RouterDeps } from '../../src/http/router';
import { MemoryStore } from '../../src/memory-store';
import { DEFAULT_PUBLISH_CONFIG, type PublishConfig } from '../../src/publish/config';
import { indexSubdir, type IndexerDeps } from '../../src/publish/indexer';
import { FakeS3Upload, MemoryInvalidator, MemoryObjectStore, MemoryPresigner, MemoryPublishStore, MemoryQueue } from '../../src/publish/memory';
import type { Flags } from '../../src/publish/ports';
import { PublishService } from '../../src/publish/service';
import { validatePublish, type ValidatorDeps } from '../../src/publish/validator';
import { buildConda, defaults, mopmDefault } from '../validate/builder';
import type { Spec } from '../validate/builder';
import { TestClock } from '../auth-helpers';

export class MutableFlags implements Flags {
  ro = false;
  broken = false;
  async readOnly() {
    if (this.broken) throw new Error('config table unreadable');
    return this.ro;
  }
}

export const sha256 = (b: Uint8Array | string) => createHash('sha256').update(b).digest('hex');

/** The manifest_sha256 a publisher declares for an archive built from `over`: the hash of its embedded <name>.mopm.json. */
export function manifestSha(over: Partial<Spec> = {}): string {
  const s = defaults(over);
  return sha256(typeof s.mopm === 'string' ? s.mopm : JSON.stringify({ ...mopmDefault(s), ...s.mopm }));
}

export interface Pkg {
  name: string;
  version: string;
  subdir: string;
  bytes: Buffer;
  filename: string;
  sha256: string;
  manifest: string;
}
export function pkg(over: Partial<Spec> = {}): Pkg {
  const b = buildConda(over);
  return { name: b.req.name, version: b.req.version, subdir: b.req.subdir, bytes: b.bytes, filename: b.req.filename, sha256: sha256(b.bytes), manifest: manifestSha(over) };
}

export interface Account {
  github_id: number;
  handle: string;
  token: string;
}

/** The whole pipeline on in-memory ports, driven the way the queues and the HTTP API drive it. */
export class Harness {
  clock = new TestClock();
  registry: MemoryStore;
  authStore = new MemoryAuthStore();
  publishes = new MemoryPublishStore();
  objects = new MemoryObjectStore();
  s3 = new FakeS3Upload(this.objects);
  validateQueue = new MemoryQueue();
  indexQueue = new MemoryQueue();
  invalidator = new MemoryInvalidator();
  flags = new MutableFlags();
  config: PublishConfig = { ...DEFAULT_PUBLISH_CONFIG };
  logs: Array<Record<string, unknown>> = [];
  private n = 0;

  service!: PublishService;
  deps!: RouterDeps;
  validatorDeps!: ValidatorDeps;
  indexerDeps!: IndexerDeps;

  constructor(config: Partial<PublishConfig> = {}, registry: MemoryStore = new MemoryStore()) {
    this.registry = registry;
    this.config = { ...DEFAULT_PUBLISH_CONFIG, ...config };
    this.build();
  }

  /** Rebuild the wiring after `config` changed. */
  build() {
    const now = this.clock.now;
    this.service = new PublishService({
      registry: this.registry,
      publishes: this.publishes,
      objects: this.objects,
      presigner: new MemoryPresigner(),
      validateQueue: this.validateQueue,
      indexQueue: this.indexQueue,
      config: this.config,
      now,
      newId: () => (++this.n).toString(16).padStart(32, '0'),
    });
    const api: PublishApi = { auth: new Authenticator({ store: this.authStore, now }), service: this.service, flags: this.flags };
    this.deps = { store: this.registry, stage: 'beta', version: 't', commit: 't', readOnly: false, publish: api };
    this.validatorDeps = {
      registry: this.registry,
      publishes: this.publishes,
      objects: this.objects,
      indexQueue: this.indexQueue,
      config: this.config,
      channelUrl: 'https://conda.example.invalid',
      now,
      log: (l) => this.logs.push(l),
    };
    this.indexerDeps = {
      registry: this.registry,
      publishes: this.publishes,
      objects: this.objects,
      invalidator: this.invalidator,
      now,
      log: (l) => this.logs.push(l),
      ensured: new Set(),
    };
  }

  /** A claimed package with `account` as an owner, and an API token with publish scope for it. */
  async account(github_id: number, handle: string, packages: string[]): Promise<Account> {
    for (const name of packages) {
      if (!(await this.registry.getPackage(name))) await this.registry.createPackage({ name, state: 'claimed', created_at: this.clock.now().toISOString() });
      await this.registry.addOwner({ name, github_id, handle, added_at: this.clock.now().toISOString() });
    }
    return { github_id, handle, token: await this.token(github_id, packages, ['publish']) };
  }

  async token(github_id: number, packages: string[], scopes: Array<'publish' | 'yank'>): Promise<string> {
    const t = this.clock.now();
    const m = await mintToken(this.authStore, {
      kind: 'api',
      github_id,
      name: 'test',
      scopes,
      packages,
      all_current: false,
      created_at: t.toISOString(),
      expires_at: new Date(t.getTime() + 86_400_000).toISOString(),
    });
    return m.secret;
  }

  call(method: string, path: string, token?: string, body?: unknown): Promise<HttpResponse> {
    return route(
      {
        method,
        path,
        query: {},
        headers: token ? { authorization: `Bearer ${token}` } : {},
        body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body),
      },
      this.deps,
      'req-1',
    );
  }

  /** begin-upload for one package file, then the PUT to the (fake) S3, as the CLI does. */
  async upload(token: string, p: Pkg, opts: { bytes?: Buffer; size?: number; sha256?: string } = {}) {
    const res = await this.call('POST', `/api/v1/packages/${p.name}/${p.version}/files`, token, {
      subdir: p.subdir,
      filename: p.filename,
      sha256: opts.sha256 ?? p.sha256,
      size: opts.size ?? p.bytes.length,
    });
    if (res.statusCode !== 200) return { res, upload_id: undefined as string | undefined, put: undefined as string | undefined };
    const body = JSON.parse(res.body);
    const rec = (await this.publishes.getUpload(body.upload_id))!;
    const put = await this.s3.put(
      rec.key,
      { url: body.put_url, headers: body.put_headers },
      opts.bytes ?? p.bytes,
      this.clock.now(),
      new Date(body.expires_at),
    );
    return { res, upload_id: body.upload_id as string, put };
  }

  commit(token: string, name: string, version: string, uploadIds: string[], manifest: string, extra: Record<string, unknown> = {}) {
    return this.call('POST', `/api/v1/packages/${name}/${version}/publish`, token, { upload_ids: uploadIds, manifest_sha256: manifest, ...extra });
  }

  /** begin + PUT + commit of one file (`extra`: more fields of the commit body); returns the publish id. */
  async publish(token: string, p: Pkg, extra: Record<string, unknown> = {}): Promise<string> {
    const u = await this.upload(token, p);
    expect(u.res.statusCode).toBe(200);
    expect(u.put).toBe('ok');
    const c = await this.commit(token, p.name, p.version, [u.upload_id!], p.manifest, extra);
    expect(c.statusCode).toBe(202);
    return JSON.parse(c.body).publish_id as string;
  }

  async status(token: string, publishId: string) {
    const r = await this.call('GET', `/api/v1/publishes/${publishId}`, token);
    return { statusCode: r.statusCode, body: JSON.parse(r.body) };
  }

  /** Run every queued validate message, one after the other. */
  async runValidator() {
    for (let m = this.validateQueue.take(); m; m = this.validateQueue.take()) {
      await validatePublish(this.validatorDeps, JSON.parse(m.body).publish_id);
    }
  }

  /** Run every queued index message, one after the other. */
  async runIndexer() {
    for (let m = this.indexQueue.take(); m; m = this.indexQueue.take()) await indexSubdir(this.indexerDeps, JSON.parse(m.body));
  }

  /** The repodata.json the channel currently serves for a subdir. */
  repodata(subdir: string): { 'packages.conda': Record<string, { name: string; version: string; sha256: string }>; removed: string[] } {
    const o = this.objects.objects.get(`${subdir}/repodata.json`);
    if (!o) throw new Error(`no repodata for ${subdir}`);
    return JSON.parse(o.body.toString('utf8'));
  }
}
