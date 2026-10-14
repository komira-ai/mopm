import { Match } from 'aws-cdk-lib/assertions';
import { STAGES } from '../lib/config';
import { bucketStatements, tpl } from './util';

describe.each(STAGES)('SiteStack %s', (stage) => {
  const { site: t } = tpl(stage);
  const host = stage === 'prod' ? 'mopm.dev' : `${stage}.mopm.dev`;

  test('bucket is private and encrypted, TLS only', () => {
    t.hasResourceProperties('AWS::S3::Bucket', {
      BucketName: `mopm-${stage}-site-111111111111`,
      PublicAccessBlockConfiguration: Match.objectLike({ BlockPublicAcls: true, BlockPublicPolicy: true, IgnorePublicAcls: true, RestrictPublicBuckets: true }),
      BucketEncryption: Match.anyValue(),
    });
    expect(bucketStatements(t).some((x) => x.Condition?.Bool?.['aws:SecureTransport'] === 'false')).toBe(true);
  });

  test('CloudFront with OAC serves the site host over HTTPS with a root object', () => {
    t.resourceCountIs('AWS::CloudFront::OriginAccessControl', 1);
    t.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        Aliases: [host],
        DefaultRootObject: 'index.html',
        DefaultCacheBehavior: Match.objectLike({ ViewerProtocolPolicy: 'redirect-to-https' }),
      }),
    });
  });

  test('placeholder page is deployed and the certificate is DNS validated', () => {
    t.resourceCountIs('Custom::CDKBucketDeployment', 1);
    t.hasResourceProperties('AWS::CertificateManager::Certificate', { DomainName: host, ValidationMethod: 'DNS' });
  });
});
