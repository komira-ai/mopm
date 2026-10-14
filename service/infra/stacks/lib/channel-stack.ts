import { Duration, Stack, StackProps } from 'aws-cdk-lib';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as targets from 'aws-cdk-lib/aws-route53-targets';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';
import { StageConfig, channelBucketName } from './config';
import { anyone, assertRegion, deleteAllowedRoleArns, lookupZone, notNamedRoles, removalPolicyFor } from './common';

export interface ChannelStackProps extends StackProps {
  config: StageConfig;
}

/** Private S3 bucket + CloudFront (OAC) serving the conda channel at conda.<stage>. */
export class ChannelStack extends Stack {
  readonly bucket: s3.Bucket;
  readonly distribution: cloudfront.Distribution;

  constructor(scope: Construct, id: string, props: ChannelStackProps) {
    super(scope, id, props);
    assertRegion(this);
    const c = props.config;

    this.bucket = new s3.Bucket(this, 'Bucket', {
      bucketName: channelBucketName(c.stage, this.account),
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      versioned: true,
      enforceSSL: true,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
      removalPolicy: removalPolicyFor(c),
      lifecycleRules: [
        {
          id: 'quarantine-expiry',
          prefix: 'quarantine/',
          expiration: Duration.days(1),
          noncurrentVersionExpiration: Duration.days(1),
          abortIncompleteMultipartUploadAfter: Duration.days(1),
        },
        { id: 'abort-multipart', abortIncompleteMultipartUploadAfter: Duration.days(1) },
      ],
    });

    // Nobody deletes objects except the takedown role (prod) or takedown + cleanup roles (disposable stages).
    // quarantine/ is the one exception for plain DeleteObject: the validator removes an upload once it is judged (a
    // delete marker; the lifecycle rule expires the old versions). Deleting a *version* stays denied everywhere, and
    // only the validator's role is allowed any S3 delete in quarantine/ (nothing else in the account is).
    const exempt = notNamedRoles(deleteAllowedRoleArns(this, c));
    this.bucket.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: 'DenyDeleteExceptNamedRoles',
        effect: iam.Effect.DENY,
        principals: [anyone()],
        actions: ['s3:DeleteObject', 's3:DeleteObjectVersion'],
        notResources: [this.bucket.arnForObjects('quarantine/*')],
        conditions: exempt,
      }),
    );
    this.bucket.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: 'DenyDeleteQuarantineVersions',
        effect: iam.Effect.DENY,
        principals: [anyone()],
        actions: ['s3:DeleteObjectVersion'],
        resources: [this.bucket.arnForObjects('quarantine/*')],
        conditions: exempt,
      }),
    );

    // Uploads wait in quarantine/ until validated. The OAC allow covers the whole bucket, so deny CloudFront
    // explicitly there: an explicit deny wins, and quarantined bytes are never served from the channel host.
    this.bucket.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: 'DenyCloudFrontQuarantine',
        effect: iam.Effect.DENY,
        principals: [new iam.ServicePrincipal('cloudfront.amazonaws.com')],
        actions: ['s3:GetObject'],
        resources: [this.bucket.arnForObjects('quarantine/*')],
      }),
    );

    const zone = lookupZone(this, c);
    const cert = new acm.Certificate(this, 'Cert', {
      domainName: c.condaDomain,
      validation: acm.CertificateValidation.fromDns(zone),
    });

    // repodata is the only mutable object: short TTL. Packages and content-addressed shards are immutable.
    const repodataPolicy = new cloudfront.CachePolicy(this, 'RepodataCache', {
      cachePolicyName: `mopm-${c.stage}-repodata`,
      minTtl: Duration.seconds(0),
      defaultTtl: Duration.seconds(60),
      maxTtl: Duration.seconds(60),
      enableAcceptEncodingGzip: true,
      enableAcceptEncodingBrotli: true,
    });
    const immutablePolicy = new cloudfront.CachePolicy(this, 'ImmutableCache', {
      cachePolicyName: `mopm-${c.stage}-immutable`,
      minTtl: Duration.days(365),
      defaultTtl: Duration.days(365),
      maxTtl: Duration.days(365),
      enableAcceptEncodingGzip: false,
      enableAcceptEncodingBrotli: false,
    });
    const headers = new cloudfront.ResponseHeadersPolicy(this, 'Headers', {
      responseHeadersPolicyName: `mopm-${c.stage}-channel-headers`,
      securityHeadersBehavior: {
        contentTypeOptions: { override: true },
        strictTransportSecurity: {
          accessControlMaxAge: Duration.days(730),
          includeSubdomains: true,
          override: true,
        },
        frameOptions: { frameOption: cloudfront.HeadersFrameOption.DENY, override: true },
        referrerPolicy: { referrerPolicy: cloudfront.HeadersReferrerPolicy.NO_REFERRER, override: true },
      },
    });

    const origin = origins.S3BucketOrigin.withOriginAccessControl(this.bucket);
    const common = {
      origin,
      viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
      allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD,
      responseHeadersPolicy: headers,
    };
    this.distribution = new cloudfront.Distribution(this, 'Distribution', {
      comment: `mopm ${c.stage} conda channel`,
      domainNames: [c.condaDomain],
      certificate: cert,
      minimumProtocolVersion: cloudfront.SecurityPolicyProtocol.TLS_V1_2_2021,
      httpVersion: cloudfront.HttpVersion.HTTP2_AND_3,
      defaultBehavior: { ...common, cachePolicy: immutablePolicy, compress: false },
      additionalBehaviors: {
        '*/repodata*': { ...common, cachePolicy: repodataPolicy, compress: true },
        '*/current_repodata*': { ...common, cachePolicy: repodataPolicy, compress: true },
      },
    });

    // No repodata seed. The index writer (service/api/src/publish/indexer.ts) owns every repodata file and creates the
    // empty index of a subdir lazily, create-only, the first time it runs. Stages deployed before this change keep the
    // files the earlier BucketDeployment wrote: its custom resource was retainOnDelete, so removing it deletes nothing.

    const target = route53.RecordTarget.fromAlias(new targets.CloudFrontTarget(this.distribution));
    new route53.ARecord(this, 'ARecord', { zone, recordName: c.condaDomain, target });
    new route53.AaaaRecord(this, 'AaaaRecord', { zone, recordName: c.condaDomain, target });
  }
}
