import * as crypto from 'crypto';
import * as fs from 'fs';
import * as path from 'path';
import { App } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { createStageStacks } from '../lib/app';
import { STAGES, stageConfig } from '../lib/config';
import { CHANNEL_SUBDIRS, assertEmptyRepodata, emptyRepodata, zstdRawFrame } from '../lib/empty-channel';
import { DUMMY_ACCOUNT, DUMMY_ZONE_ID } from './util';

const SEED_WARNING =
  'changing the channel seed re-runs the BucketDeployment and overwrites live repodata on every stage, including prod; ' +
  'the index writer must own repodata before any change here';

/** sha256 of every seeded file. Update only after the index writer owns repodata (see the runbook). */
const SEED_SHA256: Record<string, { json: string; zst: string }> = {
  noarch: { json: '1d8e3c3e7a8f2f9846d703b004c741528b5608e9176af2e7961819909cd4cc66', zst: 'caedad1de142232180858126b860902471c538acce8929e25c9b0fe09681f427' },
  'linux-64': { json: '6808b921f357a22d3754437d5eef5d1cbc335293a833f9a23efc408cdb9bcdcd', zst: 'e4b95ebf442129806f9a6f9f654e7bfb2ababc60757c9721b4d5bc404ef0b17f' },
  'linux-aarch64': { json: 'bc4be9caca4baec5a91c75e38a6f868d4244be60a5cbf86d142d599dce2d5de1', zst: '50f6dcf2c8a732c3c7365100fc8df85cc6daa8a618490f53f3cca0837bb500bb' },
  'osx-arm64': { json: '4276b2e3a8c18e59bb46be52f9ca92a9577b7211b80f4bf8faa996750a3bf7af', zst: '6c1f6c6319aa2fdcdf69de15e82d0b0fb7313a7f87f2df5f62fe83255bcc01ba' },
};
const sha256 = (b: Buffer) => crypto.createHash('sha256').update(b).digest('hex');

/** Parses a raw-block zstd frame as written by zstdRawFrame; throws on anything else. */
function unzstdRaw(b: Buffer): string {
  expect([...b.subarray(0, 5)]).toEqual([0x28, 0xb5, 0x2f, 0xfd, 0x20]);
  const size = b[5];
  const bh = b[6] | (b[7] << 8) | (b[8] << 16);
  expect(bh).toBe((size << 3) | 1); // last block, raw
  expect(b.length).toBe(9 + size);
  return b.subarray(9).toString();
}

describe('empty repodata shape', () => {
  test('conda empty repodata: info.subdir set, packages and packages.conda empty objects', () => {
    const r = JSON.parse(emptyRepodata('linux-64'));
    expect(r.info).toEqual({ subdir: 'linux-64' });
    expect(r.packages).toEqual({});
    expect(r['packages.conda']).toEqual({});
  });

  test('a fixture with the wrong subdir fails', () => {
    expect(() => assertEmptyRepodata('linux-64', emptyRepodata('noarch'))).toThrow(/info.subdir "noarch"/);
  });

  test('a fixture with packages fails', () => {
    const bad = JSON.stringify({ info: { subdir: 'noarch' }, packages: {}, 'packages.conda': { 'x.conda': {} } });
    expect(() => assertEmptyRepodata('noarch', bad)).toThrow(/packages.conda/);
    const bad2 = JSON.stringify({ info: { subdir: 'noarch' }, packages: [], 'packages.conda': {} });
    expect(() => assertEmptyRepodata('noarch', bad2)).toThrow(/packages must be/);
  });

  test('zst file is a valid zstd frame of the same bytes', () => {
    const j = emptyRepodata('osx-arm64');
    expect(unzstdRaw(zstdRawFrame(Buffer.from(j)))).toBe(j);
  });
});

describe.each(STAGES)('ChannelStack %s seeds empty repodata', (stage) => {
  const app = new App();
  const stacks = createStageStacks(app, stageConfig(stage, DUMMY_ZONE_ID), { account: DUMMY_ACCOUNT, region: 'us-east-1' }, '1.2.3', 'c0ffee');
  const t = Template.fromStack(stacks.channel);
  const assembly = app.synth();
  const seedHash = () => {
    const dep = Object.values(t.findResources('Custom::CDKBucketDeployment'))[0] as any;
    return (JSON.stringify(dep.Properties.SourceObjectKeys) as string).match(/([0-9a-f]{64})\.zip/)![1];
  };

  test('one non-pruning, retained deployment into the channel bucket', () => {
    t.resourceCountIs('Custom::CDKBucketDeployment', 1);
    t.hasResourceProperties('Custom::CDKBucketDeployment', { Prune: false, RetainOnDelete: true });
  });

  test('the staged asset holds the four empty repodata files and their zst', () => {
    const hash = seedHash();
    // The asset is zipped by the deployment, but its directory is staged next to the template.
    const dir = path.join(assembly.directory, `asset.${hash}`);
    expect(fs.existsSync(dir)).toBe(true);
    expect(fs.readdirSync(dir).sort()).toEqual([...CHANNEL_SUBDIRS].sort());
    for (const s of CHANNEL_SUBDIRS) {
      const json = fs.readFileSync(path.join(dir, s, 'repodata.json'), 'utf8');
      assertEmptyRepodata(s, json);
      expect(unzstdRaw(fs.readFileSync(path.join(dir, s, 'repodata.json.zst')))).toBe(json);
    }
  });

  test('seed files are pinned by sha256', () => {
    const dir = path.join(assembly.directory, `asset.${seedHash()}`);
    for (const s of CHANNEL_SUBDIRS) {
      const got = {
        json: sha256(fs.readFileSync(path.join(dir, s, 'repodata.json'))),
        zst: sha256(fs.readFileSync(path.join(dir, s, 'repodata.json.zst'))),
      };
      if (got.json !== SEED_SHA256[s].json || got.zst !== SEED_SHA256[s].zst) {
        throw new Error(`${s} seed changed: ${SEED_WARNING}. got ${JSON.stringify(got)}`);
      }
    }
  });

  test('repodata cache stays at 60 seconds', () => {
    t.hasResourceProperties('AWS::CloudFront::CachePolicy', {
      CachePolicyConfig: { Name: `mopm-${stage}-repodata`, DefaultTTL: 60, MaxTTL: 60, MinTTL: 0 },
    });
  });
});
