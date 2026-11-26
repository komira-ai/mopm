import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { App } from 'aws-cdk-lib';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { STAGES, TutorialConfig, edgeOriginSecretName, stageConfig } from '../lib/config';
import {
  API_CONTENT_SECURITY_POLICY, API_PATH_PATTERN, ASSETS_CACHE_CONTROL, DEFAULT_SITE_DIR, EDGE_HEADER, FUNCTION_MAX_BYTES,
  PAGES_CACHE_CONTROL, PERMISSIONS_POLICY, SiteStack, TUTORIAL_DIR, assertSiteBuild, contentSecurityPolicy, servedFiles,
  servesTutorial, siteFiles, siteRouterSource,
} from '../lib/site-stack';
import { DUMMY_ACCOUNT, DUMMY_ZONE_ID, SITE_STUB_DIR, bucketStatements, build } from './util';
import { apiBehaviour, behaviourFor, edgeHeaderProblems } from './site-edge';
import { securityHeaders } from '../../../../site/tools/headers';

type Json = any;

/** The site distribution's page settings as the stack synthesized them before the API behaviour (fixtures/site-before.json). */
const BEFORE = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/site-before.json'), 'utf8')).stages;

/** CloudFront's managed policies the API behaviour names (their ids are fixed by AWS). */
const CACHING_DISABLED = '4135ea2d-6df8-44a3-9df3-4b5a84be39ad';
const ALL_VIEWER_EXCEPT_HOST_HEADER = 'b689b0a8-53d0-40ab-baf2-68738e2966ac';

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
  const policies = t.findResources('AWS::CloudFront::ResponseHeadersPolicy');
  const policy = policies.HeadersECA0794E.Properties.ResponseHeadersPolicyConfig;
  const dist = (Object.values<Json>(t.findResources('AWS::CloudFront::Distribution'))[0]).Properties.DistributionConfig;
  const before = BEFORE[stage];

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

  test("the CSP's connect-src is exactly the site's own origin and E2B's sandboxes; every other directive is as before", () => {
    const csp = policy.SecurityHeadersConfig.ContentSecurityPolicy;
    expect(csp).toEqual({
      Override: true,
      ContentSecurityPolicy:
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; " +
        "connect-src 'self' https://*.e2b.app; base-uri 'none'; form-action 'self'; frame-ancestors 'none'; " +
        "object-src 'none'; require-trusted-types-for 'script'; trusted-types 'none'",
    });
    expect(contentSecurityPolicy(c)).toBe(csp.ContentSecurityPolicy);
    // The pages read the API under /api/* on their own host: no API host is named, this stage's or another's.
    expect(csp.ContentSecurityPolicy).not.toContain('https://api.');
    expect(csp.ContentSecurityPolicy).not.toContain('unsafe-');
    // The one wildcard is E2B's sandboxes, in connect-src.
    expect(csp.ContentSecurityPolicy.split('*')).toHaveLength(2);
    // Against the policy before: connect-src changed from this stage's API host, and nothing else did.
    const directives = (p: string) => p.split('; ');
    const was = directives(before.headersPolicy.SecurityHeadersConfig.ContentSecurityPolicy.ContentSecurityPolicy);
    const now = directives(csp.ContentSecurityPolicy);
    expect(was.filter((d) => !now.includes(d))).toEqual([`connect-src https://api.${host}`]);
    expect(now.filter((d) => !was.includes(d))).toEqual(["connect-src 'self' https://*.e2b.app"]);
    expect(now.map((d) => d.split(' ')[0])).toEqual(was.map((d) => d.split(' ')[0]));
  });

  test("a stage whose tutorial block names another E2B domain allows that domain's sandboxes, and not e2b.app", () => {
    const s = build(stage, { tutorial: { e2bDomain: 'sandbox.example' } });
    const other = Template.fromStack(s.site).findResources('AWS::CloudFront::ResponseHeadersPolicy').HeadersECA0794E;
    const csp: string = other.Properties.ResponseHeadersPolicyConfig.SecurityHeadersConfig.ContentSecurityPolicy.ContentSecurityPolicy;
    expect(csp).toContain("; connect-src 'self' https://*.sandbox.example; ");
    expect(csp).not.toContain('e2b.app');
    expect(csp).toBe(policy.SecurityHeadersConfig.ContentSecurityPolicy.ContentSecurityPolicy.replace('*.e2b.app', '*.sandbox.example'));
  });

  test('the pages send that policy: the default behaviour names the site policy, the API behaviour its own', () => {
    expect(Object.keys(policies).sort()).toEqual(['ApiHeaders86A8FCD8', 'HeadersECA0794E']);
    expect(dist.DefaultCacheBehavior.ResponseHeadersPolicyId).toEqual({ Ref: 'HeadersECA0794E' });
    expect(dist.CacheBehaviors.map((b: Json) => b.ResponseHeadersPolicyId)).toEqual([{ Ref: 'ApiHeaders86A8FCD8' }]);
  });

  test("the pages' headers policy (but its connect-src), bucket origin, default behaviour and distribution settings are the ones before, byte for byte", () => {
    // Same logical ids: CloudFormation updates the distribution, the policy and the router in place.
    expect([before.distributionId, before.headersPolicyId, before.routerId]).toEqual(['Distribution830FAC52', 'HeadersECA0794E', 'Router16807C72']);
    expect(t.findResources('AWS::CloudFront::Distribution')[before.distributionId]).toBeDefined();
    expect(t.findResources('AWS::CloudFront::Function')[before.routerId]).toBeDefined();
    // The pages' headers policy changes only in its CSP's connect-src (the test above holds that string).
    const beforePolicy = JSON.parse(JSON.stringify(before.headersPolicy));
    beforePolicy.SecurityHeadersConfig.ContentSecurityPolicy.ContentSecurityPolicy = contentSecurityPolicy(c);
    expect(JSON.stringify(policy)).toBe(JSON.stringify(beforePolicy));
    expect(JSON.stringify(dist.Origins[0])).toBe(JSON.stringify(before.bucketOrigin));
    // The changes, and nothing else: the error responses are gone (the router answers the 404 page), the API origin and
    // behaviour are added, and the router also runs on viewer-response (to give that page its 404).
    const { Origins, CacheBehaviors, ...rest } = dist;
    expect([Origins.length, CacheBehaviors.length]).toEqual([2, 1]);
    const { CustomErrorResponses, ...beforeRest } = before.distributionConfig;
    expect(CustomErrorResponses).toHaveLength(2);
    const fn = { 'Fn::GetAtt': [before.routerId, 'FunctionARN'] };
    expect(beforeRest.DefaultCacheBehavior.FunctionAssociations).toEqual([{ EventType: 'viewer-request', FunctionARN: fn }]);
    const defaultBefore = {
      ...beforeRest.DefaultCacheBehavior,
      FunctionAssociations: [...beforeRest.DefaultCacheBehavior.FunctionAssociations, { EventType: 'viewer-response', FunctionARN: fn }],
    };
    expect(JSON.stringify(rest)).toBe(JSON.stringify({ ...beforeRest, DefaultCacheBehavior: defaultBefore }));
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
    expect(PERMISSIONS_POLICY).toBe('camera=(), microphone=(), geolocation=(), payment=(), usb=()');
  });

  // The site's local preview (site/tools/preview.ts) sends securityHeaders() for its own connect-src: with the same
  // builder, a page that breaks under this policy breaks under the preview.
  test("the headers the policy sends, as HTTP headers, are the site's securityHeaders for its own origin and E2B", () => {
    const sec = policy.SecurityHeadersConfig;
    const sent: Record<string, string> = {
      'content-security-policy': sec.ContentSecurityPolicy.ContentSecurityPolicy,
      'strict-transport-security': `max-age=${sec.StrictTransportSecurity.AccessControlMaxAgeSec}${sec.StrictTransportSecurity.IncludeSubdomains ? '; includeSubDomains' : ''}`,
      'x-content-type-options': 'nosniff',
      'x-frame-options': sec.FrameOptions.FrameOption,
      'referrer-policy': sec.ReferrerPolicy.ReferrerPolicy,
    };
    for (const h of policy.CustomHeadersConfig.Items) sent[h.Header.toLowerCase()] = h.Value;
    expect(Object.keys(sec).sort()).toEqual(['ContentSecurityPolicy', 'ContentTypeOptions', 'FrameOptions', 'ReferrerPolicy', 'StrictTransportSecurity']);
    expect(sent).toEqual(securityHeaders("'self' https://*.e2b.app"));
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
    expect(PAGES_CACHE_CONTROL).toBe('public, max-age=60, s-maxage=300');
  });

  test('the pages deployment depends on the assets deployment, so no page names an asset that is not there yet', () => {
    const [[assetsId]] = byPrefix('assets/');
    const [[, pages]] = byPrefix(undefined);
    expect(pages.DependsOn).toEqual(expect.arrayContaining([assetsId]));
  });

  test('both deployments keep their objects when the deployment resource is deleted or replaced', () => {
    // CDK leaves RetainOnDelete out when it is true (the default). Assets: old hashes must outlive a replaced or deleted
    // deployment, as they outlive a deploy (Prune false). Pages: its prefix is the whole bucket, and the handler's delete
    // is `aws s3 rm s3://<bucket>/ --recursive` without the exclude, so retainOnDelete false would also remove assets/.
    const [[, assets]] = byPrefix('assets/');
    const [[, pages]] = byPrefix(undefined);
    expect([assets.Properties.RetainOnDelete, pages.Properties.RetainOnDelete]).toEqual([undefined, undefined]);
  });

  test('the assets upload holds only the hashed directories, the pages upload everything else and no assets/', () => {
    const staged = (r: Json) => path.join(dir, `asset.${String(r.Properties.SourceObjectKeys[0]).replace(/\.zip$/, '')}`);
    const [[, assets]] = byPrefix('assets/');
    const [[, pages]] = byPrefix(undefined);
    expect(files(staged(assets))).toEqual(files(path.join(SITE_STUB_DIR, 'assets')));
    const tutorial = (f: string) => f.startsWith(`${TUTORIAL_DIR}/`);
    expect(files(staged(pages))).toEqual(files(SITE_STUB_DIR).filter((f) => !f.startsWith('assets/') && (servesTutorial(c) || !tutorial(f))));
    expect(files(staged(pages))).toContain('index.html');
    // The stage files decide: beta names its template, gamma and prod do not yet.
    expect([stage, files(staged(pages)).some(tutorial)]).toEqual([stage, stage === 'beta']);
  });

  test('no distribution-wide error responses: they would turn the JSON errors of /api/* into the 404 page', () => {
    expect(dist.CustomErrorResponses).toBeUndefined();
    expect(JSON.stringify(t.toJSON())).not.toContain('ErrorCachingMinTTL');
  });

  test('one CloudFront Function (cloudfront-js-2.0) runs the router of this build on viewer-request and viewer-response', () => {
    const fns = Object.entries<Json>(t.findResources('AWS::CloudFront::Function'));
    expect(fns).toHaveLength(1);
    const [[fnId, fn]] = fns;
    expect(fn.Properties.FunctionConfig.Runtime).toBe('cloudfront-js-2.0');
    expect(fn.Properties.AutoPublish).toBe(true);
    expect(fn.Properties.FunctionCode).toBe(siteRouterSource(servedFiles(c, files(SITE_STUB_DIR).map((f) => `/${f}`))));
    const arn = { 'Fn::GetAtt': [fnId, 'FunctionARN'] };
    expect(dist.DefaultCacheBehavior.FunctionAssociations).toEqual([
      { EventType: 'viewer-request', FunctionARN: arn },
      { EventType: 'viewer-response', FunctionARN: arn },
    ]);
  });

  test('the API behaviour: /api/* to the stage API over HTTPS only, every method, no caching, every header but Host', () => {
    const { behaviour, origin } = apiBehaviour(t.toJSON());
    expect(behaviour).toEqual({
      PathPattern: API_PATH_PATTERN,
      TargetOriginId: origin.Id,
      ViewerProtocolPolicy: 'https-only',
      AllowedMethods: ['GET', 'HEAD', 'OPTIONS', 'PUT', 'PATCH', 'POST', 'DELETE'],
      CachePolicyId: CACHING_DISABLED,
      OriginRequestPolicyId: ALL_VIEWER_EXCEPT_HOST_HEADER,
      ResponseHeadersPolicyId: { Ref: 'ApiHeaders86A8FCD8' },
      Compress: true,
    });
    // No function and no Lambda@Edge (the toEqual above admits no other key): nothing at the edge rewrites an API
    // request or its response.
    expect(API_PATH_PATTERN).toBe('/api/*');
  });

  test('the API origin: the stage API custom domain, HTTPS and TLS 1.2 only, a 30 s read timeout, the edge header', () => {
    const { origin } = apiBehaviour(t.toJSON());
    expect(origin.DomainName).toBe(c.apiDomain);
    expect(origin.DomainName).toBe(`api.${host}`);
    expect(origin.CustomOriginConfig).toEqual({
      OriginProtocolPolicy: 'https-only',
      OriginReadTimeout: 30,
      OriginSSLProtocols: ['TLSv1.2'],
    });
    expect(origin.OriginCustomHeaders.map((h: Json) => h.HeaderName)).toEqual([EDGE_HEADER]);
    expect(EDGE_HEADER).toBe('x-mopm-edge');
  });

  test("the edge header's value is a dynamic reference to the stage's generated edge-origin secret, never a literal", () => {
    expect(edgeHeaderProblems(t.toJSON())).toEqual([]);
    const [[secretId, secret]] = Object.entries<Json>(t.findResources('AWS::SecretsManager::Secret'));
    expect(apiBehaviour(t.toJSON()).origin.OriginCustomHeaders).toEqual([
      {
        HeaderName: 'x-mopm-edge',
        HeaderValue: { 'Fn::Join': ['', ['{{resolve:secretsmanager:', { Ref: secretId }, ':SecretString:::}}']] },
      },
    ]);
    expect(secret.Properties).toEqual({
      Name: `mopm/${stage}/edge-origin`,
      Description: `The x-mopm-edge header the mopm ${stage} site distribution sends to the API on /api/*`,
      GenerateSecretString: { ExcludePunctuation: true, PasswordLength: 64 },
    });
    expect(secret.Properties.Name).toBe(edgeOriginSecretName(stage));
    // Beta and gamma are disposable; prod keeps the secret when the stack or the resource goes.
    const keep = stage === 'prod' ? 'Retain' : 'Delete';
    expect([secret.DeletionPolicy, secret.UpdateReplacePolicy]).toEqual([keep, keep]);
  });

  test("the API's responses get their own headers policy: nosniff, no-referrer, HSTS and a sandboxing CSP, nothing else", () => {
    expect(policies.ApiHeaders86A8FCD8.Properties.ResponseHeadersPolicyConfig).toEqual({
      Name: `mopm-${stage}-api-headers`,
      SecurityHeadersConfig: {
        ContentSecurityPolicy: { ContentSecurityPolicy: "default-src 'none'; sandbox; frame-ancestors 'none'", Override: true },
        ContentTypeOptions: { Override: true },
        ReferrerPolicy: { ReferrerPolicy: 'no-referrer', Override: true },
        StrictTransportSecurity: { AccessControlMaxAgeSec: 63072000, IncludeSubdomains: true, Override: true },
      },
    });
    expect(API_CONTENT_SECURITY_POLICY).toBe("default-src 'none'; sandbox; frame-ancestors 'none'");
  });

  test('a request goes where its path says: /api/... to the API, every other path through the router to the bucket', () => {
    const json = t.toJSON();
    const api = apiBehaviour(json).origin.Id;
    const bucket = dist.Origins[0].Id;
    for (const [uri, want] of [
      ['/api/v2/packages/komira-ai/json', api],
      ['/api/v2/auth/web/session', api],
      ['/api/v1/health', api],
      ['/api/', api],
      ['/api', bucket],
      ['/apis/v2', bucket],
      ['/API/v2/packages', bucket],
      ['/', bucket],
      ['/packages/komira-ai/json', bucket],
      ['/assets/0123456789abcdef/site.css', bucket],
      ['/docs/api/', bucket],
    ]) {
      expect([uri, behaviourFor(json, uri).TargetOriginId]).toEqual([uri, want]);
    }
    expect(behaviourFor(json, '/nope').FunctionAssociations).toHaveLength(2);
  });
});

// A stage serves the tutorial's pages exactly when its configuration names the E2B template its sandboxes start from:
// the stage's name plays no part, and the other settings of the tutorial block do not turn it on.
describe('the tutorial on a stage', () => {
  const stack = (stage: (typeof STAGES)[number], tutorial: TutorialConfig) => {
    const s = build(stage, { tutorial });
    const dir = (s.site.node.root as App).synth().directory;
    const t = Template.fromStack(s.site);
    const [, pages] = Object.entries<Json>(t.findResources('Custom::CDKBucketDeployment')).find(([, r]) => r.Properties.DestinationBucketKeyPrefix === undefined) as [string, Json];
    const staged = files(path.join(dir, `asset.${String(pages.Properties.SourceObjectKeys[0]).replace(/\.zip$/, '')}`));
    const [fn] = Object.values<Json>(t.findResources('AWS::CloudFront::Function'));
    const router = new Function(`${fn.Properties.FunctionCode}\nreturn handler;`)() as (e: Json) => Json;
    const edge = (uri: string) => router({ request: { method: 'GET', uri, querystring: {}, headers: {} } }).uri;
    return { pages, staged, edge };
  };
  const STUB_TUTORIAL = ['tutorial/hello/index.html', 'tutorial/index.html'];

  test.each([
    ['prod', { e2bTemplateId: 'tpl-1' }],
    ['gamma', { e2bTemplateId: 'tpl-1', e2bDomain: 'e2b.example' }],
    ['beta', { e2bTemplateId: 'tpl-1', sandboxTimeoutS: 60 }],
  ] as const)('%s with a template (%j): the pages upload has the tutorial and the router serves it', (stage, tutorial) => {
    const { pages, staged, edge } = stack(stage, tutorial);
    expect(staged.filter((f) => f.startsWith(`${TUTORIAL_DIR}/`))).toEqual(STUB_TUTORIAL);
    expect(pages.Properties.Exclude).toEqual(['assets/*']);
    expect([edge('/tutorial'), edge('/tutorial/hello'), edge('/tutorial/hello/index.html')]).toEqual([
      '/tutorial/index.html',
      '/tutorial/hello/index.html',
      '/tutorial/hello/index.html',
    ]);
    expect([edge('/tutorial/'), edge('/tutorial/nope'), edge('/tutorial/hello/')]).toEqual(['/404.html', '/404.html', '/404.html']);
  });

  test.each([
    ['beta', {}],
    ['prod', { e2bDomain: 'e2b.example', sandboxTimeoutS: 60 }],
  ] as const)('%s without a template (%j): no tutorial file is uploaded, the prune still covers tutorial/, and every tutorial path is the 404 page', (stage, tutorial) => {
    const { pages, staged, edge } = stack(stage, tutorial);
    expect(staged.filter((f) => f.startsWith(`${TUTORIAL_DIR}/`))).toEqual([]);
    expect(staged).toEqual(expect.arrayContaining(['index.html', '404.html', 'app.html', 'docs/index.html']));
    // Only assets/ is kept out of the prune, so tutorial pages an earlier deploy left are deleted.
    expect(pages.Properties.Exclude).toEqual(['assets/*']);
    for (const uri of ['/tutorial', '/tutorial/hello', '/tutorial/index.html', '/tutorial/hello/index.html']) {
      expect([uri, edge(uri)]).toEqual([uri, '/404.html']);
    }
    expect(edge('/docs/')).toBe('/docs/index.html');
  });

  test('servedFiles drops only what is under tutorial/, and keeps a file merely named like it', () => {
    const build = ['/index.html', '/tutorial/index.html', '/tutorial/a/index.html', '/tutorial.html', '/tutorials/x.html', '/docs/tutorial/index.html'];
    expect(servedFiles(stageConfig('prod', DUMMY_ZONE_ID, {}), build)).toEqual(['/index.html', '/tutorial.html', '/tutorials/x.html', '/docs/tutorial/index.html']);
    expect(servedFiles(stageConfig('prod', DUMMY_ZONE_ID, { e2bTemplateId: 't' }), build)).toEqual(build);
    // No tutorial block at all (stageConfig would read the stage file's for an undefined argument).
    expect(servesTutorial({ ...stageConfig('prod', DUMMY_ZONE_ID, {}), tutorial: undefined })).toBe(false);
  });
});

describe('the edge header check', () => {
  const site = build('beta').site;
  const fresh = () => JSON.parse(JSON.stringify(Template.fromStack(site).toJSON()));
  const PROBLEM = 'the x-mopm-edge header is not a dynamic reference to the edge-origin secret';

  test('fails a template whose header is a literal value, is missing, or reads another secret', () => {
    const literal = fresh();
    apiBehaviour(literal).origin.OriginCustomHeaders[0].HeaderValue = 'not-a-secret';
    expect(edgeHeaderProblems(literal)).toEqual([PROBLEM]);

    const none = fresh();
    delete apiBehaviour(none).origin.OriginCustomHeaders;
    expect(edgeHeaderProblems(none)).toEqual(['the API origin sends no x-mopm-edge header']);

    const other = fresh();
    apiBehaviour(other).origin.OriginCustomHeaders[0].HeaderValue = {
      'Fn::Join': ['', ['{{resolve:secretsmanager:', 'mopm/beta/github-oauth', ':SecretString:::}}']],
    };
    expect(edgeHeaderProblems(other)).toEqual([PROBLEM]);
  });

  test('fails a stack without the secret, or with a secret whose value is written rather than generated', () => {
    const noSecret = fresh();
    for (const [id, r] of Object.entries<Json>(noSecret.Resources)) {
      if (r.Type === 'AWS::SecretsManager::Secret') delete noSecret.Resources[id];
    }
    expect(edgeHeaderProblems(noSecret)).toEqual(['no generated edge-origin secret', PROBLEM]);

    const written = fresh();
    for (const r of Object.values<Json>(written.Resources)) {
      if (r.Type === 'AWS::SecretsManager::Secret') {
        delete r.Properties.GenerateSecretString;
        r.Properties.SecretString = 'committed';
      }
    }
    expect(edgeHeaderProblems(written)).toEqual(['no generated edge-origin secret', PROBLEM]);
  });

  test('refuses a template with no /api/* behaviour, naming it', () => {
    const noApi = fresh();
    for (const r of Object.values<Json>(noApi.Resources)) {
      if (r.Type === 'AWS::CloudFront::Distribution') delete r.Properties.DistributionConfig.CacheBehaviors;
    }
    expect(() => edgeHeaderProblems(noApi)).toThrow('the distribution has no /api/* behaviour');
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

  test('one missing entry is enough to refuse: a build without 404.html, or without assets/', () => {
    const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'site-build-'));
    try {
      for (const entry of ['404.html', 'assets']) {
        const partial = path.join(scratch, `no-${entry}`);
        fs.cpSync(SITE_STUB_DIR, partial, { recursive: true });
        fs.rmSync(path.join(partial, entry), { recursive: true });
        expect(() => make(partial)).toThrow(`the site build at ${partial} lacks ${entry};`);
      }
    } finally {
      fs.rmSync(scratch, { recursive: true, force: true });
    }
  });

  // The real build (site/dist; Buck2 stages //site:dist there, CI and deploy.yml run `npm run build` in site first).
  test('the real build is complete and complies with the CSP: scripts and stylesheets only from /assets/, nothing inline', () => {
    if (!fs.existsSync(DEFAULT_SITE_DIR)) {
      throw new Error(`the site build is not at ${DEFAULT_SITE_DIR}; run 'npm ci && npm run build' in site first (CI does)`);
    }
    assertSiteBuild(DEFAULT_SITE_DIR);
    const pages = files(DEFAULT_SITE_DIR).filter((f) => f.endsWith('.html'));
    expect(pages).toEqual(expect.arrayContaining(['404.html', 'app.html', 'docs/index.html', 'index.html', 'tutorial/index.html']));
    // The router of the real build: within CloudFront Functions' size limit, and it serves every file of the build.
    const real = siteFiles(DEFAULT_SITE_DIR);
    expect(Buffer.byteLength(siteRouterSource(real))).toBeLessThanOrEqual(FUNCTION_MAX_BYTES);
    expect(real).toEqual(files(DEFAULT_SITE_DIR).map((f) => `/${f}`));
    // A stack given no site directory serves this build, and its router is this build's.
    const stack = new SiteStack(new App(), 'mopm-beta-site', {
      env: { account: DUMMY_ACCOUNT, region: 'us-east-1' },
      config: stageConfig('beta', DUMMY_ZONE_ID),
    });
    const [fn] = Object.values<Json>(Template.fromStack(stack).findResources('AWS::CloudFront::Function'));
    expect(fn.Properties.FunctionCode).toBe(siteRouterSource(real));
    for (const page of pages) {
      const html = fs.readFileSync(path.join(DEFAULT_SITE_DIR, page), 'utf8');
      const scripts = html.match(/<script\b[^>]*>[\s\S]*?<\/script>/g) ?? [];
      // main.js, and on a lesson's page the tutorial bundle after it.
      expect([page, scripts.length]).toEqual([page, /^tutorial\/[^/]+\/index\.html$/.test(page) ? 2 : 1]);
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

  // The site's local preview (site/tools/preview.ts) and its E2B call are never deployed: no file of the build names
  // E2B's create call or the key's variable. The one exception is the tutorial bundle, assets/<id>/tutorial.js (site
  // README, rule 1): it is E2B's SDK, which names its own key variable and platform routes (read from `process.env`,
  // which a browser does not have, and called only by Sandbox.create and the like, which the runner never calls). It is
  // held instead to carrying none of the preview's own text: its flags, its create body's metadata, its fixed CSRF
  // value, and the host of its create call.
  test('the real build holds nothing of the local preview', () => {
    const bundle = (f: string) => /^assets\/[^/]+\/tutorial\.js$/.test(f.split(path.sep).join('/'));
    const all = files(DEFAULT_SITE_DIR);
    expect(all.filter(bundle)).toHaveLength(1);
    for (const f of all) {
      const text = fs.readFileSync(path.join(DEFAULT_SITE_DIR, f), 'utf8');
      const preview = bundle(f) ? /mopm_stage|mopm_request|--e2b-template|--scenario|mopm-csrf-example-value|api\.e2b\.app/ : /E2B_API_KEY|api\.e2b\.app|\/v2\/sandboxes/;
      expect([f, preview.test(text)]).toEqual([f, false]);
    }
    expect(all.filter((f) => /preview/.test(f))).toEqual([]);
  });
});
