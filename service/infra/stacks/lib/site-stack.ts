import * as fs from 'fs';
import * as path from 'path';
import { Duration, Stack, StackProps } from 'aws-cdk-lib';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as targets from 'aws-cdk-lib/aws-route53-targets';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as deploy from 'aws-cdk-lib/aws-s3-deployment';
import { Construct } from 'constructs';
// The site's own route grammar: the edge router below is generated from it, so the router and the app shell accept the
// same names, versions and docs slugs (site/src/routes.ts imports nothing).
import { DOC_SLUG, NAME, NAME_SEPARATORS, VERSION, VERSION_MAX } from '../../../../site/src/routes';
import { StageConfig, siteBucketName } from './config';
import { assertRegion, lookupZone, removalPolicyFor } from './common';

export interface SiteStackProps extends StackProps {
  config: StageConfig;
  /** The built site (`npm run build` in site/ writes `dist/`; Buck2's //site:dist is the same tree). Tests pass a stub. */
  siteDir?: string;
}

/** Where the site build lives in a checkout. It is not committed: CI and deploy.yml build it before synth. */
export const DEFAULT_SITE_DIR = path.resolve(__dirname, '../../../../site/dist');

/** What a site build must hold for the stack to serve it: the three pages the router and error responses name, and the assets. */
export const REQUIRED_SITE_ENTRIES = ['index.html', 'app.html', '404.html', 'assets'] as const;

/** Hashed assets (`assets/<content hash>/...`): a changed file gets a new URL, so a cached copy is never stale. */
export const ASSETS_CACHE_CONTROL = 'public, max-age=31536000, immutable';
/** Pages keep their URLs across releases: browsers recheck after a minute, CloudFront after five (and each deploy invalidates). */
export const PAGES_CACHE_CONTROL = 'public, max-age=60, s-maxage=300';
/** How long CloudFront caches the 404 page it answers a missing key with. */
export const ERROR_TTL = Duration.seconds(10);

/** The Content-Security-Policy of a stage: nothing but the site itself, and the stage's own API for fetch. */
export function contentSecurityPolicy(c: StageConfig): string {
  return [
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self'",
    `connect-src https://${c.apiDomain}`,
    "base-uri 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "object-src 'none'",
    // The site writes the DOM only through createElement/setAttribute/text nodes (site/src/doc.ts; no HTML sink, which
    // site/test/no-sinks.test.ts holds), so it needs no Trusted Types policy and may create none.
    "require-trusted-types-for 'script'",
    "trusted-types 'none'",
  ].join('; ');
}

export const PERMISSIONS_POLICY = 'camera=(), microphone=(), geolocation=(), payment=(), usb=()';

/**
 * The viewer-request router (cloudfront-js-2.0), generated from the site's route grammar; no host or stage in it, so
 * every stage runs the same code. site/test/fixtures/routes.json holds the vectors it must satisfy
 * (test/site-router.test.ts runs it over every one).
 *
 * Order matters: the package routes come before the file check, because a version route ends in what looks like an
 * extension (`/packages/x/1.0.0`).
 */
export const SPA_ROUTER_SOURCE = `var NAME = /${NAME.source}/;
var VERSION = /${VERSION.source}/;
var VERSION_MAX = ${VERSION_MAX};
var SEPARATORS = /${NAME_SEPARATORS.source}/g;
var DOC_SLUG = /${DOC_SLUG.source}/;

function canonical(n) {
  return NAME.test(n) && n.toLowerCase().replace(SEPARATORS, '_') === n;
}

function query(qs) {
  var out = [];
  for (var k in qs) {
    var vs = qs[k].multiValue || [qs[k]];
    for (var i = 0; i < vs.length; i++) out.push(vs[i].value === '' ? k : k + '=' + vs[i].value);
  }
  return out.length ? '?' + out.join('&') : '';
}

function handler(event) {
  var r = event.request;
  var uri = r.uri;
  if (uri === '/') { r.uri = '/index.html'; return r; }
  if (uri === '/search') { r.uri = '/app.html'; return r; }
  var p = uri.split('/');
  if (p[1] === 'packages') {
    if (p.length === 3) {
      if (canonical(p[2])) { r.uri = '/app.html'; return r; }
      var n = p[2].toLowerCase().replace(SEPARATORS, '_');
      if (n !== p[2] && NAME.test(n)) {
        return { statusCode: 301, statusDescription: 'Moved Permanently',
          headers: { location: { value: '/packages/' + n + query(r.querystring) } } };
      }
    }
    if (p.length === 4 && canonical(p[2]) && p[3].length <= VERSION_MAX && VERSION.test(p[3])) {
      r.uri = '/app.html';
      return r;
    }
    return r;
  }
  // A file (a page, an asset, robots.txt): straight to the bucket.
  if (p[p.length - 1].indexOf('.') !== -1) return r;
  if (p[1] === 'docs') {
    if (p.length === 2 || (p.length === 3 && p[2] === '')) { r.uri = '/docs/index.html'; return r; }
    if ((p.length === 3 || (p.length === 4 && p[3] === '')) && DOC_SLUG.test(p[2])) {
      r.uri = '/docs/' + p[2] + '/index.html';
      return r;
    }
  }
  return r;
}
`;

/** Refuses to synthesize without a complete site build, saying how to make one. */
export function assertSiteBuild(dir: string): void {
  const missing = REQUIRED_SITE_ENTRIES.filter((f) => !fs.existsSync(path.join(dir, f)));
  if (missing.length > 0) {
    throw new Error(
      `the site build at ${dir} lacks ${missing.join(', ')}; run 'npm ci && npm run build' in site first ` +
        '(or build //site:dist with Buck2)',
    );
  }
}

/** Private S3 bucket + CloudFront (OAC) serving the site build, with an edge router, a CSP and the 404 page. */
export class SiteStack extends Stack {
  readonly bucket: s3.Bucket;
  readonly distribution: cloudfront.Distribution;

  constructor(scope: Construct, id: string, props: SiteStackProps) {
    super(scope, id, props);
    assertRegion(this);
    const c = props.config;
    const siteDir = props.siteDir ?? DEFAULT_SITE_DIR;
    assertSiteBuild(siteDir);

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
        contentSecurityPolicy: { contentSecurityPolicy: contentSecurityPolicy(c), override: true },
        contentTypeOptions: { override: true },
        strictTransportSecurity: {
          accessControlMaxAge: Duration.days(730),
          includeSubdomains: true,
          override: true,
        },
        frameOptions: { frameOption: cloudfront.HeadersFrameOption.DENY, override: true },
        referrerPolicy: { referrerPolicy: cloudfront.HeadersReferrerPolicy.NO_REFERRER, override: true },
      },
      customHeadersBehavior: {
        customHeaders: [
          { header: 'Cross-Origin-Opener-Policy', value: 'same-origin', override: true },
          { header: 'Cross-Origin-Resource-Policy', value: 'same-origin', override: true },
          { header: 'Permissions-Policy', value: PERMISSIONS_POLICY, override: true },
        ],
      },
    });

    const router = new cloudfront.Function(this, 'Router', {
      functionName: `mopm-${c.stage}-site-router`,
      comment: 'mopm site routes: pages, app shell, docs, package name redirects',
      runtime: cloudfront.FunctionRuntime.JS_2_0,
      code: cloudfront.FunctionCode.fromInline(SPA_ROUTER_SOURCE),
    });

    // A missing key answers 403 from S3 through OAC (no ListBucket), 404 otherwise: both get the 404 page with 404.
    const notFound = (httpStatus: number): cloudfront.ErrorResponse => ({
      httpStatus,
      responseHttpStatus: 404,
      responsePagePath: '/404.html',
      ttl: ERROR_TTL,
    });

    this.distribution = new cloudfront.Distribution(this, 'Distribution', {
      comment: `mopm ${c.stage} site`,
      domainNames: [c.siteDomain],
      certificate: cert,
      defaultRootObject: 'index.html',
      minimumProtocolVersion: cloudfront.SecurityPolicyProtocol.TLS_V1_2_2021,
      httpVersion: cloudfront.HttpVersion.HTTP2_AND_3,
      errorResponses: [notFound(403), notFound(404)],
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(this.bucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD,
        cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
        responseHeadersPolicy: headers,
        functionAssociations: [{ function: router, eventType: cloudfront.FunctionEventType.VIEWER_REQUEST }],
      },
    });

    // Assets first, never pruned: pages of an earlier release (an open tab, a rollback) keep their asset URLs working.
    const assets = new deploy.BucketDeployment(this, 'Assets', {
      destinationBucket: this.bucket,
      destinationKeyPrefix: 'assets/',
      sources: [deploy.Source.asset(path.join(siteDir, 'assets'))],
      prune: false,
      cacheControl: [deploy.CacheControl.fromString(ASSETS_CACHE_CONTROL)],
    });

    // Then the pages (everything but assets/), pruned so a removed page goes, and the cache invalidated. `exclude` keeps
    // assets/ out of the upload and out of the prune.
    const pages = new deploy.BucketDeployment(this, 'Pages', {
      destinationBucket: this.bucket,
      sources: [deploy.Source.asset(siteDir, { exclude: ['assets', 'assets/**'] })],
      exclude: ['assets/*'],
      prune: true,
      cacheControl: [deploy.CacheControl.fromString(PAGES_CACHE_CONTROL)],
      distribution: this.distribution,
      distributionPaths: ['/*'],
    });
    pages.node.addDependency(assets);

    const target = route53.RecordTarget.fromAlias(new targets.CloudFrontTarget(this.distribution));
    new route53.ARecord(this, 'ARecord', { zone, recordName: c.siteDomain, target });
    new route53.AaaaRecord(this, 'AaaaRecord', { zone, recordName: c.siteDomain, target });
  }
}
