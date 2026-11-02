import { createHash } from 'node:crypto';
import { quarantineKeyFor, readmeUploadIdFor } from '../../src/publish/group-keys';
import { json } from './group-env';
import { pkg } from './harness';
import { Scenario } from './group-scenario';

export const sha = (b: Uint8Array | string) => createHash('sha256').update(b).digest('hex');
export const refOf = (b: Buffer) => ({ sha256: sha(b), size: b.length });

/**
 * A Scenario whose members have readmes: `declare` says whether the create request names them as objects, and the commit is
 * written in either form (`objectsBody`, `inlineBody`).
 */
export class ReadmeScenario extends Scenario {
  constructor(
    env: Scenario['env'],
    specs: Scenario['specs'],
    /** The readme of each member, by name. */
    readonly readmes: Record<string, Buffer>,
    readonly declare = true,
  ) {
    super(env, specs);
  }

  async create(): Promise<this> {
    this.pkgs = this.specs.map((sp) => pkg({ subdir: 'noarch', ...sp }));
    this.token = await this.env.account(this.githubId, 'octocat', [...new Set(this.names)]);
    const r = await this.env.create(this.token, this.members());
    expect([200, 201]).toContain(r.statusCode);
    this.created = json(r);
    this.gid = this.created!.group_id;
    return this;
  }

  members() {
    return this.pkgs.map((p) => ({
      name: p.name,
      version: p.version,
      files: [{ subdir: p.subdir, filename: p.filename, sha256: p.sha256, size: p.bytes.length }],
      ...(this.declare && this.readmes[p.name] ? { readme: refOf(this.readmes[p.name]!) } : {}),
    }));
  }

  /** The answer of the create for a member. */
  answerOf(name: string) {
    return (this.created as unknown as { members: Array<Record<string, any>> }).members.find((m) => m.name === name)!; // eslint-disable-line @typescript-eslint/no-explicit-any
  }

  /** Where the member's readme object goes in quarantine. */
  readmeKey(name: string): string {
    const p = this.pkgs.find((x) => x.name === name)!;
    return quarantineKeyFor(readmeUploadIdFor(this.gid, { name, canonical: p.version }, sha(this.readmes[name]!)), 'README.md');
  }

  async uploadReadmes(only?: readonly string[]): Promise<this> {
    for (const name of Object.keys(this.readmes)) {
      if (only && !only.includes(name)) continue;
      await this.env.objects.put(this.readmeKey(name), this.readmes[name]!, { contentType: 'application/octet-stream' });
    }
    return this;
  }

  objectsBody(over: Record<string, unknown> = {}) {
    return { members: this.pkgs.map((p) => ({ name: p.name, manifest_sha256: p.manifest, ...(this.readmes[p.name] ? { readme: refOf(this.readmes[p.name]!) } : {}), ...over })) };
  }

  inlineBody() {
    return { members: this.pkgs.map((p) => ({ name: p.name, manifest_sha256: p.manifest, ...(this.readmes[p.name] ? { readme: this.readmes[p.name]!.toString('utf8') } : {}) })) };
  }

  /** create, upload the files and the readmes. */
  async ready(): Promise<this> {
    await this.create();
    await this.upload();
    await this.uploadReadmes();
    return this;
  }
}
