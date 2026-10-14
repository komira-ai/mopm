import { Match } from 'aws-cdk-lib/assertions';
import { STAGES } from '../lib/config';
import { bucketStatements, exemptRoles, tpl } from './util';

describe.each(STAGES)('ChannelStack %s', (stage) => {
  const { channel: t } = tpl(stage);

  test('bucket is private, encrypted, versioned, owner-enforced', () => {
    t.hasResourceProperties('AWS::S3::Bucket', {
      BucketName: `mopm-${stage}-channel-111111111111`,
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true,
      },
      BucketEncryption: { ServerSideEncryptionConfiguration: [Match.objectLike({ ServerSideEncryptionByDefault: { SSEAlgorithm: 'AES256' } })] },
      VersioningConfiguration: { Status: 'Enabled' },
      OwnershipControls: { Rules: [{ ObjectOwnership: 'BucketOwnerEnforced' }] },
    });
  });

  test('TLS-only policy denies insecure transport', () => {
    const s = bucketStatements(t).find((x) => x.Condition?.Bool?.['aws:SecureTransport'] === 'false');
    expect(s).toBeDefined();
    expect(s.Effect).toBe('Deny');
  });

  test('delete is denied to everyone except the named roles', () => {
    const s = bucketStatements(t).find((x) => x.Sid === 'DenyDeleteExceptNamedRoles');
    expect(s.Effect).toBe('Deny');
    expect(s.Principal).toEqual({ AWS: '*' });
    expect(s.Action).toEqual(['s3:DeleteObject', 's3:DeleteObjectVersion']);
    expect(exemptRoles(s)).toEqual(stage === 'prod' ? ['takedown'] : ['cleanup', 'takedown']);
  });

  test('quarantine prefix expires after one day', () => {
    t.hasResourceProperties('AWS::S3::Bucket', {
      LifecycleConfiguration: { Rules: Match.arrayWith([Match.objectLike({ Prefix: 'quarantine/', ExpirationInDays: 1, Status: 'Enabled' })]) },
    });
  });

  test('CloudFront uses origin access control, not a legacy identity, and redirects to HTTPS', () => {
    t.resourceCountIs('AWS::CloudFront::OriginAccessControl', 1);
    t.resourceCountIs('AWS::CloudFront::CloudFrontOriginAccessIdentity', 0);
    t.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        Aliases: [stage === 'prod' ? 'conda.mopm.dev' : `conda.${stage}.mopm.dev`],
        DefaultCacheBehavior: Match.objectLike({ ViewerProtocolPolicy: 'redirect-to-https', AllowedMethods: ['GET', 'HEAD'] }),
        ViewerCertificate: Match.objectLike({ MinimumProtocolVersion: 'TLSv1.2_2021' }),
      }),
    });
  });

  test('bucket policy lets only CloudFront (this distribution) read objects', () => {
    const s = bucketStatements(t).find((x) => x.Principal?.Service === 'cloudfront.amazonaws.com');
    expect(s.Action).toBe('s3:GetObject');
    expect(s.Condition.StringEquals['AWS:SourceArn']).toBeDefined();
  });

  test('repodata has a 60s cache policy and packages are immutable for a year', () => {
    t.hasResourceProperties('AWS::CloudFront::CachePolicy', {
      CachePolicyConfig: Match.objectLike({ Name: `mopm-${stage}-repodata`, DefaultTTL: 60, MaxTTL: 60, MinTTL: 0 }),
    });
    t.hasResourceProperties('AWS::CloudFront::CachePolicy', {
      CachePolicyConfig: Match.objectLike({ Name: `mopm-${stage}-immutable`, DefaultTTL: 31536000, MaxTTL: 31536000, MinTTL: 31536000 }),
    });
    t.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        CacheBehaviors: Match.arrayWith([Match.objectLike({ PathPattern: '*/repodata*' })]),
      }),
    });
  });

  test('certificate is DNS validated for the conda host', () => {
    t.hasResourceProperties('AWS::CertificateManager::Certificate', {
      DomainName: stage === 'prod' ? 'conda.mopm.dev' : `conda.${stage}.mopm.dev`,
      ValidationMethod: 'DNS',
    });
  });

  test('bucket retention', () => {
    t.hasResource('AWS::S3::Bucket', { DeletionPolicy: stage === 'prod' ? 'Retain' : 'Delete' });
  });
});
