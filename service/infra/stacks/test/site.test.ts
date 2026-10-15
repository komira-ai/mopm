import * as fs from 'fs';
import * as path from 'path';
import { App } from 'aws-cdk-lib';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { STAGES, stageConfig } from '../lib/config';
import {
  ASSETS_CACHE_CONTROL, DEFAULT_SITE_DIR, PAGES_CACHE_CONTROL, PERMISSIONS_POLICY, SPA_ROUTER_SOURCE, SiteStack,
  assertSiteBuild,
} from '../lib/site-stack';
import { DUMMY_ACCOUNT, DUMMY_ZONE_ID, SITE_STUB_DIR, bucketStatements, build } from './util';

type Json = any;

/** The site stack of a stage, its template, and the directory its assembly was written to (the staged assets). */
function synth(stage: (typeof STAGES)[number]) {
  const s = build(stage);
  const asm = (s.site.node.root as App).synth();
  return { t: Template.fromStack(s.site), dir: asm.directory };
}

/** The files under `dir`, relative, sorted. */
function files(dir: string, rel = ''): string[] {
  return fs
    .readdirSync(path.join(dir, rel), { withFileTypes: true })
    .flatMap((e) => (e.isDirectory() ? files(dir, path.join(rel, e.name)) : [path.join(rel, e.name)]))
    .sort();
}

describe.each(STAGES)('SiteStack %s', (stage) => {
  const { t, dir } = synth(stage);
  const c = stageConfig(stage);
  const host = stage === 'prod' ? 'mopm.dev' : `${stage}.mopm.dev`;
  const deployments = Object.entries<Json>(t.findResources('Custom::CDKBucketDeployment'));
  const byPrefix = (prefix: string | undefined) => deployments.filter(([, r]) => r.Properties.DestinationBucketKeyPrefix === prefix);
  const policy = (Object.values<Json>(t.findResources('AWS::CloudFront::ResponseHeadersPolicy'))[0]).Properties
    .ResponseHeadersPolicyConfig;
  const dist = (Object.values<Json>(t.findResources('AWS::CloudFront::Distribution'))[0]).Properties.DistributionConfig;

  test('bucket is private and encrypted, TLS only', () => {
    t.hasResourceProperties('AWS::S3::Bucket', {
      BucketName: `mopm-${stage}-site-${DUMMY_ACCOUNT}`,
      PublicAccessBlockConfiguration: Match.objectLike({ BlockPublicAcls: true, BlockPublicPolicy: true, IgnorePublicAcls: true, RestrictPublicBuckets: true }),
      BucketEncryption: Match.anyValue(),
    });
    expect(bucketStatements(t).some((x) => x.Condition?.Bool?.['aws:SecureTransport'] === 'false')).toBe(true);
  });

  test('CloudFront with OAC serves the site host over HTTPS with a root object; the certificate is DNS validated', () => {
    t.resourceCountIs('AWS::CloudFront::OriginAccessControl', 1);
    t.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        Aliases: [host],
        DefaultRootObject: 'index.html',
        DefaultCacheBehavior: Match.objectLike({ ViewerProtocolPolicy: 'redirect-to-https' }),
      }),
    });
    t.hasResourceProperties('AWS::CertificateManager::Certificate', { DomainName: host, ValidationMethod: 'DNS' });
  });

  test("the CSP is exactly the site's own origin plus this stage's API for fetch, with no wildcard and no unsafe- source", () => {
    const csp = policy.SecurityHeadersConfig.ContentSecurityPolicy;
    expect(csp).toEqual({
      Override: true,
      ContentSecurityPolicy:
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; " +
        `connect-src https://api.${host}; base-uri 'none'; form-action 'self'; frame-ancestors 'none'; ` +
        "object-src 'none'; require-trusted-types-for 'script'; trusted-types 'none'",
    });
    expect(c.apiDomain).toBe(`api.${host}`);
    expect(csp.ContentSecurityPolicy).not.toContain('*');
    expect(csp.ContentSecurityPolicy).not.toContain('unsafe-');
    // No other stage's API (a prod page must not talk to beta, nor beta to prod).
    for (const other of STAGES.filter((s) => s !== stage)) {
      expect(csp.ContentSecurityPolicy).not.toContain(`https://${stageConfig(other).apiDomain};`);
    }
  });

  test('the security headers stay, and COOP, CORP and a Permissions-Policy are added, all overriding the origin', () => {
    expect(policy.SecurityHeadersConfig).toEqual(
      expect.objectContaining({
        ContentTypeOptions: { Override: true },
        FrameOptions: { FrameOption: 'DENY', Override: true },
        ReferrerPolicy: { ReferrerPolicy: 'no-referrer', Override: true },
        StrictTransportSecurity: { AccessControlMaxAgeSec: 63072000, IncludeSubdomains: true, Override: true },
      }),
    );
    expect(policy.CustomHeadersConfig.Items).toEqual([
      { Header: 'Cross-Origin-Opener-Policy', Value: 'same-origin', Override: true },
      { Header: 'Cross-Origin-Resource-Policy', Value: 'same-origin', Override: true },
      { Header: 'Permissions-Policy', Value: PERMISSIONS_POLICY, Override: true },
    ]);
    expect(PERMISSIONS_POLICY).toMatch(/^([a-z-]+=\(\)(, )?)+$/);
  });

  test('two deployments: hashed assets, immutable and never pruned; pages, short-cached, pruned and invalidated', () => {
    expect(deployments).toHaveLength(2);
    const [[, assets]] = byPrefix('assets/');
    const [[, pages]] = byPrefix(undefined);
    expect(assets.Properties).toEqual(
      expect.objectContaining({ Prune: false, SystemMetadata: { 'cache-control': ASSETS_CACHE_CONTROL } }),
    );
    expect(assets.Properties.DistributionId).toBeUndefined();
    expect(assets.Properties.Exclude).toBeUndefined();
    expect(pages.Properties).toEqual(
      expect.objectContaining({
        Prune: true,
        Exclude: ['assets/*'],
        SystemMetadata: { 'cache-control': PAGES_CACHE_CONTROL },
        DistributionId: expect.anything(),
        DistributionPaths: ['/*'],
      }),
    );
    expect(pages.Properties.DistributionId).toEqual({ Ref: expect.stringMatching(/^Distribution/) });
    expect(ASSETS_CACHE_CONTROL).toBe('public, max-age=31536000, immutable');
    expect(PAGES_CACHE_CONTROL).toMatch(/^public, max-age=60, s-maxage=\d+$/);
  });

  test('the pages deployment depends on the assets deployment, so no page names an asset that is not there yet', () => {
    const [[assetsId]] = byPrefix('assets/');
    const [[, pages]] = byPrefix(undefined);
    expect(pages.DependsOn).toEqual(expect.arrayContaining([assetsId]));
  });

  test('the assets upload holds only the hashed directories, the pages upload everything else and no assets/', () => {
    const staged = (r: Json) => path.join(dir, `asset.${String(r.Properties.SourceObjectKeys[0]).replace(/\.zip$/, '')}`);
    const [[, assets]] = byPrefix('assets/');
    const [[, pages]] = byPrefix(undefined);
    expect(files(staged(assets))).toEqual(files(path.join(SITE_STUB_DIR, 'assets')));
    expect(files(staged(pages))).toEqual(files(SITE_STUB_DIR).filter((f) => !f.startsWith('assets/')));
    expect(files(staged(pages))).toContain('index.html');
  });

  test('a missing key (403 from S3 through OAC) or 404 gets the 404 page with status 404, briefly cached; nothing maps to 200', () => {
    expect(dist.CustomErrorResponses).toEqual([
      { ErrorCode: 403, ResponseCode: 404, ResponsePagePath: '/404.html', ErrorCachingMinTTL: 10 },
      { ErrorCode: 404, ResponseCode: 404, ResponsePagePath: '/404.html', ErrorCachingMinTTL: 10 },
    ]);
    expect(JSON.stringify(dist.CustomErrorResponses)).not.toContain('index.html');
  });

  test('one CloudFront Function (cloudfront-js-2.0) runs the router on viewer-request, the same code in every stage', () => {
    const fns = Object.entries<Json>(t.findResources('AWS::CloudFront::Function'));
    expect(fns).toHaveLength(1);
    const [[fnId, fn]] = fns;
    expect(fn.Properties.FunctionConfig.Runtime).toBe('cloudfront-js-2.0');
    expect(fn.Properties.AutoPublish).toBe(true);
    expect(fn.Properties.FunctionCode).toBe(SPA_ROUTER_SOURCE);
    expect(dist.DefaultCacheBehavior.FunctionAssociations).toEqual([
      { EventType: 'viewer-request', FunctionARN: { 'Fn::GetAtt': [fnId, 'FunctionARN'] } },
    ]);
    expect(dist.CacheBehaviors).toBeUndefined();
  });
});

describe('the site build', () => {
  const make = (siteDir: string) =>
    new SiteStack(new App(), 'mopm-beta-site', {
      env: { account: DUMMY_ACCOUNT, region: 'us-east-1' },
      config: stageConfig('beta', DUMMY_ZONE_ID),
      siteDir,
    });

  test('the stack refuses to synthesize without one, naming what is missing and how to build it', () => {
    const nowhere = path.join(SITE_STUB_DIR, 'no-such-dir');
    expect(() => make(nowhere)).toThrow(
      `the site build at ${nowhere} lacks index.html, app.html, 404.html, assets; run 'npm ci && npm run build' in site first`,
    );
    // docs/ of the stub holds an index.html and nothing else.
    expect(() => make(path.join(SITE_STUB_DIR, 'docs'))).toThrow(/lacks app\.html, 404\.html, assets;/);
    expect(() => make(SITE_STUB_DIR)).not.toThrow();
  });

  // The real build (site/dist; Buck2 stages //site:dist there, CI and deploy.yml run `npm run build` in site first).
  test('the real build is complete and complies with the CSP: scripts and stylesheets only from /assets/, nothing inline', () => {
    if (!fs.existsSync(DEFAULT_SITE_DIR)) {
      throw new Error(`the site build is not at ${DEFAULT_SITE_DIR}; run 'npm ci && npm run build' in site first (CI does)`);
    }
    assertSiteBuild(DEFAULT_SITE_DIR);
    const pages = files(DEFAULT_SITE_DIR).filter((f) => f.endsWith('.html'));
    expect(pages).toEqual(expect.arrayContaining(['404.html', 'app.html', 'docs/index.html', 'index.html']));
    for (const page of pages) {
      const html = fs.readFileSync(path.join(DEFAULT_SITE_DIR, page), 'utf8');
      const scripts = html.match(/<script\b[^>]*>[\s\S]*?<\/script>/g) ?? [];
      expect([page, scripts.length]).toEqual([page, 1]);
      for (const s of scripts) expect([page, s]).toEqual([page, expect.stringMatching(/^<script type="module" src="\/assets\/[^"]+\.js"><\/script>$/)]);
      for (const [, href] of html.matchAll(/<link\b[^>]*\bhref="([^"]*)"/g)) {
        expect([page, href]).toEqual([page, expect.stringMatching(/^\/assets\/[^"]+\.(css|js)$/)]);
      }
      // Inside tags only (text is escaped, so every '<' starts a real tag): no style element or attribute, no handler.
      const inline = (html.match(/<[^>]*>/g) ?? []).filter((tag) => /^<style\b|\sstyle=|\son[a-z]+=|javascript:/i.test(tag));
      expect([page, inline]).toEqual([page, []]);
      for (const [, ref] of html.matchAll(/"(\/assets\/[^"]+)"/g)) {
        expect([page, ref, fs.existsSync(path.join(DEFAULT_SITE_DIR, ref))]).toEqual([page, ref, true]);
      }
    }
  });
});
