import { Match } from 'aws-cdk-lib/assertions';
import { STAGES } from '../lib/config';
import { DUMMY_ACCOUNT, bucketStatements, exemptRoles, tpl } from './util';

describe.each(STAGES)('ChannelStack %s', (stage) => {
  const { channel: t } = tpl(stage);

  test('bucket is private, encrypted, versioned, owner-enforced', () => {
    t.hasResourceProperties('AWS::S3::Bucket', {
      BucketName: `mopm-${stage}-channel-${DUMMY_ACCOUNT}`,
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

  test('plain DeleteObject is exempt only under quarantine/ (the validator removes judged uploads); deleting a version never is', () => {
    const all = bucketStatements(t).find((x) => x.Sid === 'DenyDeleteExceptNamedRoles');
    expect(all.Effect).toBe('Deny');
    expect(all.Resource).toBeUndefined();
    expect(JSON.stringify(all.NotResource)).toContain('/quarantine/*');
    const versions = bucketStatements(t).find((x) => x.Sid === 'DenyDeleteQuarantineVersions');
    expect(versions.Effect).toBe('Deny');
    expect(versions.Action).toBe('s3:DeleteObjectVersion');
    expect(JSON.stringify(versions.Resource)).toContain('/quarantine/*');
    expect(exemptRoles(versions)).toEqual(exemptRoles(all));
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
    const s = bucketStatements(t).find((x) => x.Effect === 'Allow' && x.Principal?.Service === 'cloudfront.amazonaws.com');
    expect(s.Action).toBe('s3:GetObject');
    expect(s.Condition.StringEquals['AWS:SourceArn']).toBeDefined();
  });

  test('quarantine/ is unreachable through the distribution (explicit deny beats the OAC allow)', () => {
    const s = bucketStatements(t).find((x) => x.Sid === 'DenyCloudFrontQuarantine');
    expect(s).toBeDefined();
    expect(s.Effect).toBe('Deny');
    expect(s.Principal).toEqual({ Service: 'cloudfront.amazonaws.com' });
    expect(s.Action).toBe('s3:GetObject');
    expect(JSON.stringify(s.Resource)).toContain('/quarantine/*');
  });

  test('index/ is unreachable through the distribution (the sparse index is served by the API host, never cached for a year)', () => {
    const s = bucketStatements(t).find((x) => x.Sid === 'DenyCloudFrontIndex');
    expect(s).toBeDefined();
    expect(s.Effect).toBe('Deny');
    expect(s.Principal).toEqual({ Service: 'cloudfront.amazonaws.com' });
    expect(s.Action).toBe('s3:GetObject');
    expect(JSON.stringify(s.Resource)).toContain('/index/*');
    // It denies exactly index/*: the package and repodata paths stay served.
    expect(JSON.stringify(s.Resource)).not.toContain('quarantine');
    expect(bucketStatements(t).filter((x) => x.Effect === 'Deny' && x.Principal?.Service === 'cloudfront.amazonaws.com').map((x) => x.Sid).sort()).toEqual(['DenyCloudFrontIndex', 'DenyCloudFrontNativeMirror', 'DenyCloudFrontQuarantine']);
  });

  test('native-mirror/ is unreachable through the distribution, and its old versions expire after 7 days', () => {
    const s = bucketStatements(t).find((x) => x.Sid === 'DenyCloudFrontNativeMirror');
    expect(s).toBeDefined();
    expect(s.Effect).toBe('Deny');
    expect(s.Action).toBe('s3:GetObject');
    expect(JSON.stringify(s.Resource)).toContain('/native-mirror/*');
    t.hasResourceProperties('AWS::S3::Bucket', {
      LifecycleConfiguration: {
        Rules: Match.arrayWith([Match.objectLike({ Id: 'native-mirror-noncurrent-expiry', Prefix: 'native-mirror/', NoncurrentVersionExpiration: { NoncurrentDays: 7 }, Status: 'Enabled' })]),
      },
    });
  });

  test('old versions of index/ files expire after 30 days; the current file never does', () => {
    t.hasResourceProperties('AWS::S3::Bucket', {
      LifecycleConfiguration: {
        Rules: Match.arrayWith([Match.objectLike({ Id: 'index-noncurrent-expiry', Prefix: 'index/', NoncurrentVersionExpiration: { NoncurrentDays: 30 }, Status: 'Enabled' })]),
      },
    });
    const rules = Object.values(t.findResources('AWS::S3::Bucket'))[0]!.Properties.LifecycleConfiguration.Rules as any[];
    const idx = rules.find((r) => r.Id === 'index-noncurrent-expiry');
    expect(idx.ExpirationInDays).toBeUndefined();
    expect(idx.ExpirationDate).toBeUndefined();
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
