import * as fs from 'fs';
import * as path from 'path';
import { App } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { createStageStacks } from '../lib/app';
import { STAGES, stageConfig } from '../lib/config';
import { CHANNEL_SUBDIRS, assertEmptyRepodata, emptyRepodata, zstdRawFrame } from '../lib/empty-channel';
import { DUMMY_ACCOUNT, DUMMY_ZONE_ID } from './util';

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

  test('one non-pruning, retained deployment into the channel bucket', () => {
    t.resourceCountIs('Custom::CDKBucketDeployment', 1);
    t.hasResourceProperties('Custom::CDKBucketDeployment', { Prune: false, RetainOnDelete: true });
  });

  test('the staged asset holds the four empty repodata files and their zst', () => {
    const dep = Object.values(t.findResources('Custom::CDKBucketDeployment'))[0] as any;
    const hash = (JSON.stringify(dep.Properties.SourceObjectKeys) as string).match(/([0-9a-f]{64})\.zip/)![1];
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

  test('repodata cache stays at 60 seconds', () => {
    t.hasResourceProperties('AWS::CloudFront::CachePolicy', {
      CachePolicyConfig: { Name: `mopm-${stage}-repodata`, DefaultTTL: 60, MaxTTL: 60, MinTTL: 0 },
    });
  });
});
