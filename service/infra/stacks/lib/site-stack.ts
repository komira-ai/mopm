import { Duration, Stack, StackProps } from 'aws-cdk-lib';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as targets from 'aws-cdk-lib/aws-route53-targets';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as deploy from 'aws-cdk-lib/aws-s3-deployment';
import { Construct } from 'constructs';
import { StageConfig, siteBucketName } from './config';
import { assertRegion, lookupZone, removalPolicyFor } from './common';

export interface SiteStackProps extends StackProps {
  config: StageConfig;
}

export const PLACEHOLDER_HTML =
  '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>mopm</title></head>' +
  '<body><h1>mopm</h1><p>The Mojo package registry. Coming soon.</p></body></html>';

/** Private S3 bucket + CloudFront (OAC) for the website, with a placeholder page. */
export class SiteStack extends Stack {
  readonly bucket: s3.Bucket;
  readonly distribution: cloudfront.Distribution;

  constructor(scope: Construct, id: string, props: SiteStackProps) {
    super(scope, id, props);
    assertRegion(this);
    const c = props.config;

    this.bucket = new s3.Bucket(this, 'Bucket', {
      bucketName: siteBucketName(c.stage, this.account),
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      versioned: true,
      enforceSSL: true,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
      removalPolicy: removalPolicyFor(c),
    });

    const zone = lookupZone(this, c);
    const cert = new acm.Certificate(this, 'Cert', {
      domainName: c.siteDomain,
      validation: acm.CertificateValidation.fromDns(zone),
    });

    const headers = new cloudfront.ResponseHeadersPolicy(this, 'Headers', {
      responseHeadersPolicyName: `mopm-${c.stage}-site-headers`,
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

    this.distribution = new cloudfront.Distribution(this, 'Distribution', {
      comment: `mopm ${c.stage} site`,
      domainNames: [c.siteDomain],
      certificate: cert,
      defaultRootObject: 'index.html',
      minimumProtocolVersion: cloudfront.SecurityPolicyProtocol.TLS_V1_2_2021,
      httpVersion: cloudfront.HttpVersion.HTTP2_AND_3,
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(this.bucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD,
        cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
        responseHeadersPolicy: headers,
      },
    });

    new deploy.BucketDeployment(this, 'Placeholder', {
      destinationBucket: this.bucket,
      sources: [deploy.Source.data('index.html', PLACEHOLDER_HTML)],
      distribution: this.distribution,
      distributionPaths: ['/index.html'],
    });

    const target = route53.RecordTarget.fromAlias(new targets.CloudFrontTarget(this.distribution));
    new route53.ARecord(this, 'ARecord', { zone, recordName: c.siteDomain, target });
    new route53.AaaaRecord(this, 'AaaaRecord', { zone, recordName: c.siteDomain, target });
  }
}
