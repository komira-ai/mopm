import { Authenticator, MemoryAuthStore, mintToken } from '../../src/auth';
import { route, type HttpResponse, type RouterDeps } from '../../src/http/router';
import { Metrics } from '../../src/metrics';
import { DEFAULT_PUBLISH_CONFIG, type PublishConfig } from '../../src/publish/config';
import { GroupService } from '../../src/publish/group-service';
import { validateGroup, type GroupJobOutcome, type GroupValidatorDeps } from '../../src/publish/group-validator';
import { MemoryObjectStore, MemoryPresigner, MemoryPublishStore, MemoryQueue } from '../../src/publish/memory';
import { PublishService } from '../../src/publish/service';
import { TestClock } from '../auth-helpers';
import type { Rig } from '../group-rig';
import { hex } from '../helpers';
import { MutableFlags, sha256 } from './harness';

export interface MemberBody {
  name: string;
  version: string;
  files: Array<{ subdir: string; filename: string; sha256: string; size: number }>;
}

/**
 * The group routes and the single publish on one registry adapter (memory, or DynamoDB over the in-process fake), with the
 * ports around them in memory: what the group tests drive. `mono` is the clock of the creation budget, in milliseconds.
 */
export class GroupEnv {
  clock = new TestClock();
  mono = 0;
  authStore = new MemoryAuthStore();
  publishes = new MemoryPublishStore();
  objects = new MemoryObjectStore();
  flags = new MutableFlags();
  metricLines: Array<Record<string, unknown>> = [];
  /** The group queue (a commit queues the group's validation here) and the single validator's queue, which a group never touches. */
  groupQueue = new MemoryQueue();
  validateQueue = new MemoryQueue();
  indexQueue = new MemoryQueue();
  /** The monotonic clock of a group job's time budget, in milliseconds, and the log lines the job wrote. */
  jobClock = 0;
  jobLogs: Array<Record<string, unknown>> = [];
  readonly config: PublishConfig;
  readonly groups: GroupService;
  readonly single: PublishService;
  readonly deps: RouterDeps;
  private n = 0;

  constructor(
    readonly rig: Rig,
    config: Partial<PublishConfig> = {},
  ) {
    this.config = { ...DEFAULT_PUBLISH_CONFIG, ...config };
    const now = this.clock.now;
    const presigner = new MemoryPresigner();
    this.groups = new GroupService({
      registry: rig.store,
      publishes: this.publishes,
      objects: this.objects,
      presigner,
      config: this.config,
      now,
      clock: () => this.mono,
      groupQueue: this.groupQueue,
      metrics: new Metrics((l) => this.metricLines.push(l)),
    });
    this.single = new PublishService({
      registry: rig.store,
      groups: rig.store,
      publishes: this.publishes,
      objects: this.objects,
      presigner,
      validateQueue: this.validateQueue,
      indexQueue: this.indexQueue,
      config: this.config,
      now,
      newId: () => (++this.n).toString(16).padStart(32, '0'),
    });
    const auth = new Authenticator({ store: this.authStore, now });
    this.deps = { store: rig.store, stage: 'beta', version: 't', commit: 't', readOnly: false, publish: { auth, service: this.single, flags: this.flags, groups: this.groups } };
  }

  /** The deps of a group's validator job on this environment's ports (`over` replaces any of them). */
  validatorDeps(over: Partial<GroupValidatorDeps> = {}): GroupValidatorDeps {
    return {
      registry: this.rig.store,
      publishes: this.publishes,
      objects: this.objects,
      groupQueue: this.groupQueue,
      indexQueue: this.indexQueue,
      config: this.config,
      channelUrl: 'https://conda.example.invalid',
      now: this.clock.now,
      clock: () => this.jobClock,
      log: (l) => this.jobLogs.push(l),
      ...over,
    };
  }

  /** Run the next message of the group queue the way the Lambda does. */
  async runGroupJob(over: Partial<GroupValidatorDeps> = {}): Promise<GroupJobOutcome> {
    const m = this.groupQueue.take();
    if (!m) throw new Error('the group queue is empty');
    const msg = JSON.parse(m.body) as { group_id: string; attempt: number; n: number };
    return validateGroup(this.validatorDeps(over), msg);
  }

  /** Run the group queue until it is empty (a job that runs out of time queues its continuation). Returns each job's outcome. */
  async runGroupJobs(over: Partial<GroupValidatorDeps> = {}, limit = 50): Promise<GroupJobOutcome[]> {
    const out: GroupJobOutcome[] = [];
    while (this.groupQueue.sent.length > 0) {
      if (out.length >= limit) throw new Error(`the group queue did not drain in ${limit} jobs`);
      out.push(await this.runGroupJob(over));
    }
    return out;
  }


  /** Let the group routes admit these accounts (by GitHub id). */
  allow(...githubIds: number[]) {
    for (const id of githubIds) this.flags.groupActors.add(`u:${id}`);
  }

  /** Claim the packages, if they are not, and make the account an owner of each. */
  async own(githubId: number, handle: string, names: string[]) {
    for (const name of names) {
      if (!(await this.rig.store.getPackage(name))) await this.rig.store.createPackage({ name, state: 'claimed', created_at: this.clock.now().toISOString() });
      await this.rig.store.addOwner({ name, github_id: githubId, handle, added_at: this.clock.now().toISOString() });
    }
  }

  /** An API token of the account with `publish` for `packages`. */
  async token(githubId: number, packages: string[]): Promise<string> {
    const t = this.clock.now();
    const m = await mintToken(this.authStore, {
      kind: 'api',
      github_id: githubId,
      name: 'test',
      scopes: ['publish'],
      packages,
      all_current: false,
      created_at: t.toISOString(),
      expires_at: new Date(t.getTime() + 7 * 86_400_000).toISOString(),
    });
    return m.secret;
  }

  /** A CI identity token: good for one version of one package. */
  async ciToken(name: string, version: string): Promise<string> {
    const t = this.clock.now();
    const m = await mintToken(this.authStore, {
      kind: 'oidc',
      name: 'ci',
      scopes: ['publish'],
      packages: [name],
      all_current: false,
      version,
      created_at: t.toISOString(),
      expires_at: new Date(t.getTime() + 3_600_000).toISOString(),
    });
    return m.secret;
  }

  /** The account owns the packages and holds an API token for them; groups are allowed for it. */
  async account(githubId: number, handle: string, names: string[]): Promise<string> {
    await this.own(githubId, handle, names);
    this.allow(githubId);
    return this.token(githubId, names);
  }

  /** One member of a create request: a single file in linux-64 named by the rule. */
  member(name: string, version = '1.0.0', extra: Partial<MemberBody> = {}): MemberBody {
    return {
      name,
      version,
      files: [{ subdir: 'linux-64', filename: `mojo-${name}-${version}-mojo1.0.0_0.conda`, sha256: sha256(`${name}-${version}`), size: 1000 }],
      ...extra,
    };
  }

  call(method: string, path: string, token?: string, body?: unknown): Promise<HttpResponse> {
    return route(
      { method, path, query: {}, headers: token ? { authorization: `Bearer ${token}` } : {}, body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body) },
      this.deps,
      'req-1',
    );
  }

  create(token: string | undefined, members: MemberBody[]) {
    return this.call('POST', '/api/v1/groups', token, { members });
  }
  get(token: string, id: string) {
    return this.call('GET', `/api/v1/groups/${id}`, token);
  }
  abort(token: string, id: string) {
    return this.call('DELETE', `/api/v1/groups/${id}`, token);
  }

  /** begin-upload of one file of a single publish. */
  begin(token: string, name: string, version = '1.0.0') {
    return this.call('POST', `/api/v1/packages/${name}/${version}/files`, token, {
      subdir: 'linux-64',
      filename: `mojo-${name}-${version}-mojo1.0.0_0.conda`,
      sha256: hex('c'),
      size: 500,
    });
  }
}

export const json = (r: HttpResponse) => JSON.parse(r.body) as any; // eslint-disable-line @typescript-eslint/no-explicit-any
export const errorCode = (r: HttpResponse): string => json(r).error.code;
