import { quarantineKeyFor } from '../../src/publish/group-keys';
import type { GroupJobOutcome, GroupValidatorDeps } from '../../src/publish/group-validator';
import type { Spec } from '../validate/builder';
import { GroupEnv, json } from './group-env';
import { pkg, type Pkg } from './harness';

/**
 * One group of real packages, through the steps a publisher takes: create the group, PUT each file into (fake) quarantine,
 * commit it, and then run the validator's job the way the group queue does. Every package is a real archive the real
 * validator opens.
 */
export class Scenario {
  token = '';
  gid = '';
  pkgs: Pkg[] = [];
  created: { group_id: string; members: Array<{ name: string; files: Array<{ subdir: string; filename: string; upload_id: string }> }> } | undefined;

  /** `specs`: one archive each (a package name and version, and any archive field the builder takes). They are `noarch` unless a spec says otherwise. */
  constructor(
    readonly env: GroupEnv,
    readonly specs: Array<Partial<Spec>>,
    readonly githubId = 1,
  ) {}

  get names(): string[] {
    return this.pkgs.map((p) => p.name);
  }

  /** The archives, the account and its token, and POST /groups. */
  async create(): Promise<this> {
    this.pkgs = this.specs.map((s) => pkg({ subdir: 'noarch', ...s }));
    this.token = await this.env.account(this.githubId, 'octocat', [...new Set(this.names)]);
    const members = this.pkgs.map((p) => ({ name: p.name, version: p.version, files: [{ subdir: p.subdir, filename: p.filename, sha256: p.sha256, size: p.bytes.length }] }));
    const r = await this.env.create(this.token, members);
    expect([200, 201]).toContain(r.statusCode);
    this.created = json(r);
    this.gid = this.created!.group_id;
    return this;
  }

  /** POST /groups again with the same request (a group that ended opens again with the next attempt). */
  async recreate() {
    const members = this.pkgs.map((p) => ({ name: p.name, version: p.version, files: [{ subdir: p.subdir, filename: p.filename, sha256: p.sha256, size: p.bytes.length }] }));
    const r = await this.env.create(this.token, members);
    if (r.statusCode === 200 || r.statusCode === 201) this.created = json(r);
    return r;
  }

  /** The key of a member's file in quarantine. */
  keyOf(name: string): string {
    const m = this.created!.members.find((x) => x.name === name)!;
    return quarantineKeyFor(m.files[0]!.upload_id, m.files[0]!.filename);
  }

  /** PUT the bytes of every member (or of those named) where the group's upload URLs point. */
  async upload(only?: readonly string[]): Promise<this> {
    for (const p of this.pkgs) {
      if (only && !only.includes(p.name)) continue;
      await this.env.objects.put(this.keyOf(p.name), p.bytes, { contentType: 'application/octet-stream' });
    }
    return this;
  }

  /** The body of the commit request. */
  commitBody(): { members: Array<{ name: string; manifest_sha256: string }> } {
    return { members: this.pkgs.map((p) => ({ name: p.name, manifest_sha256: p.manifest })) };
  }

  commit(body: unknown = this.commitBody(), token = this.token) {
    return this.env.call('POST', `/api/v1/groups/${this.gid}/commit`, token, body);
  }

  /** create, upload, commit: the group is validating and its job is on the queue. */
  async start(): Promise<this> {
    await this.create();
    await this.upload();
    const r = await this.commit();
    expect(r.statusCode).toBe(202);
    return this;
  }

  run(over: Partial<GroupValidatorDeps> = {}): Promise<GroupJobOutcome> {
    return this.env.runGroupJob(over);
  }
  runAll(over: Partial<GroupValidatorDeps> = {}): Promise<GroupJobOutcome[]> {
    return this.env.runGroupJobs(over);
  }

  header() {
    return this.env.rig.store.getGroup(this.gid);
  }
  /** A member's row as stored. */
  row(name: string) {
    return this.env.rig.store.raw.rawGet(name, this.pkgs.find((p) => p.name === name)!.version);
  }
  /** What the API shows of a member. */
  shown(name: string) {
    return this.env.rig.store.getVersion(name, this.pkgs.find((p) => p.name === name)!.version);
  }
  /** The channel's files (not quarantine). */
  channelFiles(): string[] {
    return this.env.objects.keys().filter((k) => !k.startsWith('quarantine/'));
  }
}
