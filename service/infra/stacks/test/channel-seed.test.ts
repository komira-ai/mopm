import { STAGES } from '../lib/config';
import { tpl } from './util';

// This file replaces empty-channel.test.ts, which pinned the sha256 of the empty repodata the channel stack seeded
// through a BucketDeployment and warned that "the index writer must own repodata before any change here".
//
// The index writer (service/api/src/publish/indexer.ts) now owns repodata, so this PR deliberately removes the
// seed, as the runbook's "Before the first real publish" required. The pin moved with the content: the bytes of an
// empty index are now produced by the writer, and service/api/test/publish/empty-index.test.ts pins their sha256.
//
// What stays guarded here: nothing in the channel stack may write repodata at deploy time again. A deploy-time
// writer would overwrite the live index with whatever it carries, on every stage including prod.
describe.each(STAGES)('ChannelStack %s has no repodata seed', (stage) => {
  const { channel: t } = tpl(stage);

  test('no BucketDeployment, no custom resource, no Lambda, no layer', () => {
    t.resourceCountIs('Custom::CDKBucketDeployment', 0);
    t.resourceCountIs('AWS::Lambda::Function', 0);
    t.resourceCountIs('AWS::Lambda::LayerVersion', 0);
    const custom = Object.values(t.toJSON().Resources as Record<string, { Type: string }>).filter((r) => r.Type.startsWith('Custom::'));
    expect(custom).toEqual([]);
  });

  test('repodata cache stays at 60 seconds', () => {
    t.hasResourceProperties('AWS::CloudFront::CachePolicy', {
      CachePolicyConfig: { Name: `mopm-${stage}-repodata`, DefaultTTL: 60, MaxTTL: 60, MinTTL: 0 },
    });
  });
});
