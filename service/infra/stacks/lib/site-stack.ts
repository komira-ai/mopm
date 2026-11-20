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
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';
// The site's own route grammar: the edge router below is generated from it, so the router and the app shell accept the
// same namespaces, names, versions and docs slugs (site/src/routes.ts imports nothing).
import { DOC_SLUG, NAME, NAME_SEPARATORS, NAMESPACE, NAMESPACE_MAX, VERSION, VERSION_MAX } from '../../../../site/src/routes';
import { StageConfig, edgeOriginSecretName, siteBucketName } from './config';
import { assertRegion, lookupZone, removalPolicyFor } from './common';

export interface SiteStackProps extends StackProps {
  config: StageConfig;
  /** The built site (`npm run build` in site/ writes `dist/`; Buck2's //site:dist is the same tree). Tests pass a stub. */
  siteDir?: string;
}

/** Where the site build lives in a checkout. It is not committed: CI and deploy.yml build it before synth. */
export const DEFAULT_SITE_DIR = path.resolve(__dirname, '../../../../site/dist');

/** What a site build must hold for the stack to serve it: the three pages the router names, and the assets. */
export const REQUIRED_SITE_ENTRIES = ['index.html', 'app.html', '404.html', 'assets'] as const;

/** Hashed assets (`assets/<content hash>/...`): a changed file gets a new URL, so a cached copy is never stale. */
export const ASSETS_CACHE_CONTROL = 'public, max-age=31536000, immutable';
/** Pages keep their URLs across releases: browsers recheck after a minute, CloudFront after five (and each deploy invalidates). */
export const PAGES_CACHE_CONTROL = 'public, max-age=60, s-maxage=300';
/** The page the router answers anything that is no page, file or asset of the build with, status 404. */
export const NOT_FOUND_PAGE = '/404.html';
/** CloudFront Functions' limit on the size of a function's code, in bytes. */
export const FUNCTION_MAX_BYTES = 10240;

/** HSTS on every response of the site host, pages and API alike: two years, subdomains included. */
const HSTS_MAX_AGE = Duration.days(730);

/** The paths the site host sends to the stage's API (its API Gateway custom domain) instead of the bucket. */
export const API_PATH_PATTERN = '/api/*';
/** The origin header the distribution adds to every `/api/*` request, set to the stage's edge-origin secret. */
export const EDGE_HEADER = 'x-mopm-edge';
/** How long CloudFront waits for the API's response, set explicitly (it is also CloudFront's default). */
export const API_READ_TIMEOUT = Duration.seconds(30);
/** The CSP of the API's responses on the site host: JSON, never a document that runs or embeds anything. */
export const API_CONTENT_SECURITY_POLICY = "default-src 'none'; sandbox; frame-ancestors 'none'";

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

/** Every file of a site build as the URI that names it ('/index.html', '/assets/<id>/main.js'), sorted. */
export function siteFiles(dir: string, rel = ''): string[] {
  return fs
    .readdirSync(path.join(dir, rel), { withFileTypes: true })
    .flatMap((e) => (e.isDirectory() ? siteFiles(dir, `${rel}/${e.name}`) : [`${rel}/${e.name}`]))
    .sort();
}

/**
 * The router (cloudfront-js-2.0) of the site's default behaviour, generated from the site's route grammar and the
 * files of the build it serves (siteFiles); no host or stage in it, so every stage runs the same code for one build.
 * site/test/fixtures/routes.json holds the vectors it must satisfy and the build they assume (test/site-router.test.ts
 * runs it over every one). The same function runs on viewer-request and on viewer-response.
 *
 * Viewer request. A package is `/packages/<namespace>/<name>`, a version `/packages/<namespace>/<name>/<version>`; a
 * name the registry would normalise is redirected (301) to its normalised spelling, the namespace never (nothing
 * normalises it). A one-segment address, `/packages/<name>` of the names before namespaces or `/packages/<namespace>`,
 * and a flat `/packages/<name>/<version>` are redirected (302, not 301: they name no package now, and what a search
 * answers changes as packages are published) to a search: for the name in every namespace, or for the namespace's
 * packages (site/src/routes.ts flatSearchPath, which says which). A name starts with a letter and a version with a
 * digit, so `/packages/<a>/<b>` is never both a package and a flat version. `/docs/` and `/docs/<slug>/` are their
 * `index.html`. Anything else is a file of the build as it is, or an asset of an earlier build (`/assets/<id>/...` with
 * an id this build does not have: the bucket keeps every build's assets, so an open tab of an earlier release still
 * loads them), or else the 404 page: the router rewrites the request to NOT_FOUND_PAGE.
 *
 * Viewer response. A 200 for a request the router answers with the 404 page becomes a 404. CloudFront's request object
 * is the viewer's request, so the router works out its answer again from the URI (and treats NOT_FOUND_PAGE itself as
 * that answer, whichever URI CloudFront hands it). The function never sees the body, and CloudFront runs no viewer
 * function on an origin status of 400 or more, so a response it did not make a 404 page passes untouched.
 *
 * There are no distribution-wide error responses: they would turn the API's JSON errors on `/api/*` into this page.
 */
export function siteRouterSource(files: readonly string[]): string {
  const builds = [...new Set(files.filter((f) => f.startsWith('/assets/')).map((f) => f.split('/')[2]))].sort();
  const set = (xs: readonly string[]) => JSON.stringify(Object.fromEntries(xs.map((x) => [x, 1])));
  const source = `var NAME = /${NAME.source}/;
var NAMESPACE = /${NAMESPACE.source}/;
var NAMESPACE_MAX = ${NAMESPACE_MAX};
var VERSION = /${VERSION.source}/;
var VERSION_MAX = ${VERSION_MAX};
var SEPARATORS = /${NAME_SEPARATORS.source}/g;
var DOC_SLUG = /${DOC_SLUG.source}/;
var NOT_FOUND = '${NOT_FOUND_PAGE}';
var FILES = ${set(files)};
var BUILDS = ${set(builds)};

function has(o, k) {
  return Object.prototype.hasOwnProperty.call(o, k);
}

function file(u) {
  return has(FILES, u) ? u : NOT_FOUND;
}

function normalise(n) {
  return n.toLowerCase().replace(SEPARATORS, '_');
}

function canonical(n) {
  return NAME.test(n) && normalise(n) === n;
}

function namespace(s) {
  return s.length <= NAMESPACE_MAX && NAMESPACE.test(s);
}

function version(v) {
  return v.length <= VERSION_MAX && VERSION.test(v);
}

function redirect(code, location) {
  return { statusCode: code, statusDescription: code === 301 ? 'Moved Permanently' : 'Found',
    headers: { location: { value: location } } };
}

function query(qs) {
  var out = [];
  for (var k in qs) {
    var vs = qs[k].multiValue || [qs[k]];
    for (var i = 0; i < vs.length; i++) out.push(vs[i].value === '' ? k : k + '=' + vs[i].value);
  }
  return out.length ? '?' + out.join('&') : '';
}

// What a viewer request for uri gets: a redirect, or the key to read from the bucket.
function target(uri, qs) {
  if (uri === '/') return '/index.html';
  if (uri === '/search') return '/app.html';
  var p = uri.split('/');
  if (p[1] === 'packages') {
    if (p.length === 3) {
      if (canonical(p[2])) return redirect(302, '/search?q=' + p[2]);
      if (namespace(p[2])) return redirect(302, '/search?q=' + p[2] + '%2F');
      var flat = normalise(p[2]);
      if (NAME.test(flat)) return redirect(302, '/search?q=' + flat);
    }
    if (p.length === 4 && canonical(p[2]) && version(p[3])) return redirect(302, '/search?q=' + p[2]);
    if (p.length === 4 && namespace(p[2])) {
      if (canonical(p[3])) return '/app.html';
      var n = normalise(p[3]);
      if (n !== p[3] && NAME.test(n)) return redirect(301, '/packages/' + p[2] + '/' + n + query(qs));
    }
    if (p.length === 5 && namespace(p[2]) && canonical(p[3]) && version(p[4])) return '/app.html';
    return file(uri);
  }
  if (p[1] === 'assets' && p.length > 3 && p[2] !== '' && p[p.length - 1] !== '' && !has(BUILDS, p[2])) return uri;
  if (p[1] === 'docs') {
    if (p.length === 2 || (p.length === 3 && p[2] === '')) return file('/docs/index.html');
    if ((p.length === 3 || (p.length === 4 && p[3] === '')) && DOC_SLUG.test(p[2])) {
      return file('/docs/' + p[2] + '/index.html');
    }
  }
  return file(uri);
}

function handler(event) {
  var r = event.request;
  if (event.context && event.context.eventType === 'viewer-response') {
    var res = event.response;
    if (res.statusCode === 200 && (r.uri === NOT_FOUND || target(r.uri, r.querystring) === NOT_FOUND)) {
      res.statusCode = 404;
      res.statusDescription = 'Not Found';
    }
    return res;
  }
  var t = target(r.uri, r.querystring);
  if (typeof t !== 'string') return t;
  r.uri = t;
  return r;
}
`;
  const bytes = Buffer.byteLength(source);
  if (bytes > FUNCTION_MAX_BYTES) {
    throw new Error(
      `the edge router for this site build is ${bytes} bytes; CloudFront Functions take at most ${FUNCTION_MAX_BYTES} ` +
        `(the build has ${files.length} files)`,
    );
  }
  return source;
}

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

/**
 * Private S3 bucket + CloudFront (OAC) serving the site build, with an edge router, a CSP and the 404 page; and, under
 * `/api/*`, the stage's API, with the edge-origin secret as an origin header.
 */
export class SiteStack extends Stack {
  readonly bucket: s3.Bucket;
  readonly distribution: cloudfront.Distribution;
  /** mopm/<stage>/edge-origin: the value of the `x-mopm-edge` header the distribution sends to the API. */
  readonly edgeOriginSecret: secretsmanager.Secret;

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
          accessControlMaxAge: HSTS_MAX_AGE,
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
      comment: 'mopm site routes: pages, app shell, docs, package name redirects, the 404 page',
      runtime: cloudfront.FunctionRuntime.JS_2_0,
      code: cloudfront.FunctionCode.fromInline(siteRouterSource(siteFiles(siteDir))),
    });

    // Generated at creation and never committed: the template holds a dynamic reference to it, which CloudFormation
    // resolves when it creates or updates the distribution (generating it needs secretsmanager:GetRandomPassword).
    this.edgeOriginSecret = new secretsmanager.Secret(this, 'EdgeOrigin', {
      secretName: edgeOriginSecretName(c.stage),
      description: `The x-mopm-edge header the mopm ${c.stage} site distribution sends to the API on ${API_PATH_PATTERN}`,
      generateSecretString: { passwordLength: 64, excludePunctuation: true },
      removalPolicy: removalPolicyFor(c),
    });

    const apiHeaders = new cloudfront.ResponseHeadersPolicy(this, 'ApiHeaders', {
      responseHeadersPolicyName: `mopm-${c.stage}-api-headers`,
      securityHeadersBehavior: {
        contentSecurityPolicy: { contentSecurityPolicy: API_CONTENT_SECURITY_POLICY, override: true },
        contentTypeOptions: { override: true },
        strictTransportSecurity: { accessControlMaxAge: HSTS_MAX_AGE, includeSubdomains: true, override: true },
        referrerPolicy: { referrerPolicy: cloudfront.HeadersReferrerPolicy.NO_REFERRER, override: true },
      },
    });

    const api = new origins.HttpOrigin(c.apiDomain, {
      protocolPolicy: cloudfront.OriginProtocolPolicy.HTTPS_ONLY,
      originSslProtocols: [cloudfront.OriginSslPolicy.TLS_V1_2],
      readTimeout: API_READ_TIMEOUT,
      // CloudFront sets a configured origin header itself, replacing one of that name the viewer sent.
      customHeaders: { [EDGE_HEADER]: this.edgeOriginSecret.secretValue.unsafeUnwrap() },
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
        functionAssociations: [
          { function: router, eventType: cloudfront.FunctionEventType.VIEWER_REQUEST },
          { function: router, eventType: cloudfront.FunctionEventType.VIEWER_RESPONSE },
        ],
      },
      additionalBehaviors: {
        [API_PATH_PATTERN]: {
          origin: api,
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.HTTPS_ONLY,
          allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
          cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
          originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
          responseHeadersPolicy: apiHeaders,
        },
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
