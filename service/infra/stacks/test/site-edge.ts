// Readers of the site stack's synthesized template for test/site.test.ts: the /api/* behaviour and its origin, which
// behaviour CloudFront picks for a path, and the check that the API origin's x-mopm-edge header comes from the stage's
// generated edge-origin secret.

type Json = any;

const SECRET_NAME = /^mopm\/(beta|gamma|prod)\/edge-origin$/;

function distributionConfig(template: Json): Json {
  const dists = Object.values<Json>(template.Resources).filter((r) => r.Type === 'AWS::CloudFront::Distribution');
  if (dists.length !== 1) throw new Error(`expected one distribution, found ${dists.length}`);
  return dists[0].Properties.DistributionConfig;
}

/** The /api/* behaviour and the origin it targets. */
export function apiBehaviour(template: Json): { behaviour: Json; origin: Json } {
  const d = distributionConfig(template);
  const behaviour = (d.CacheBehaviors ?? []).find((b: Json) => b.PathPattern === '/api/*');
  if (!behaviour) throw new Error('the distribution has no /api/* behaviour');
  const origin = d.Origins.find((o: Json) => o.Id === behaviour.TargetOriginId);
  if (!origin) throw new Error(`the /api/* behaviour targets ${behaviour.TargetOriginId}, which is no origin`);
  return { behaviour, origin };
}

/** CloudFront's path pattern match: case-sensitive, `*` any run of characters, `?` one character. */
function patternMatches(pattern: string, uri: string): boolean {
  const re = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.');
  return new RegExp(`^${re}$`).test(uri);
}

/** The behaviour CloudFront applies to a request for `uri`: the first cache behaviour whose pattern matches, else the default. */
export function behaviourFor(template: Json, uri: string): Json {
  const d = distributionConfig(template);
  return (d.CacheBehaviors ?? []).find((b: Json) => patternMatches(b.PathPattern, uri)) ?? d.DefaultCacheBehavior;
}

/**
 * What is wrong with the API origin's x-mopm-edge header, or nothing: its value must be a dynamic reference to a
 * mopm/<stage>/edge-origin secret of this template that is generated at creation (never a literal, another secret, or a
 * secret whose value the template writes).
 */
export function edgeHeaderProblems(template: Json): string[] {
  const problems: string[] = [];
  const secrets = Object.entries<Json>(template.Resources)
    .filter(([, r]) => r.Type === 'AWS::SecretsManager::Secret' && SECRET_NAME.test(r.Properties?.Name ?? ''))
    .filter(([, r]) => r.Properties.GenerateSecretString !== undefined && r.Properties.SecretString === undefined)
    .map(([id]) => id);
  if (secrets.length === 0) problems.push('no generated edge-origin secret');
  const header = (apiBehaviour(template).origin.OriginCustomHeaders ?? []).find((h: Json) => h.HeaderName === 'x-mopm-edge');
  if (!header) return [...problems, 'the API origin sends no x-mopm-edge header'];
  const reference = (id: string) =>
    JSON.stringify({ 'Fn::Join': ['', ['{{resolve:secretsmanager:', { Ref: id }, ':SecretString:::}}']] });
  if (!secrets.some((id) => JSON.stringify(header.HeaderValue) === reference(id))) {
    problems.push('the x-mopm-edge header is not a dynamic reference to the edge-origin secret');
  }
  return problems;
}
