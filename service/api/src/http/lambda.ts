import {
  Authenticator,
  authTablesFor,
  CI_PUBLISHERS_ENV,
  parseCiPublishers,
  DeviceLogin,
  DynamoAuthStore,
  DynamoMembershipPassStore,
  DynamoNamespaceStore,
  GithubJwtVerifier,
  HttpGitHubApi,
  type NamespaceAccess,
  OrgMembership,
  OidcExchange,
  ownedPackagesFrom,
  TokenService,
} from '../auth';
import { DynamoStore, tablesFor, type DocClient } from '../dynamo-store';
import { documentClient, flagsFor, namespaceAccessFor, publishApiFor, stageOf } from '../publish/wiring';
import { TokenServiceV2 } from '../auth/tokens-v2';
import type { Store } from '../store';
import type { V2Deps } from './v2-routes';
import type { Flags } from '../publish/ports';
import type { AuthServices } from './auth-routes';
import { SecretGitHubAppApi } from './app-secret';
import { OAuthSecretSource, readSecretFromAws, type SecretReader } from './oauth-secret';
import { route, type RouterDeps, type Stage } from './router';

/** The part of an API Gateway HTTP API (payload format 2.0) event the router needs. */
interface GatewayEvent {
  rawPath: string;
  queryStringParameters?: Record<string, string | undefined> | null;
  headers?: Record<string, string | undefined> | null;
  body?: string | null;
  isBase64Encoded?: boolean;
  requestContext: { requestId: string; http: { method: string } };
}

interface Configured {
  deps: RouterDeps;
  flags: Flags;
  envReadOnly: boolean;
}

let configured: Configured | undefined;

/**
 * Accepted `aud` of a CI identity token, per stage. Beta accepts only its own host, so a token minted for another stage
 * is refused there. Gamma and prod keep what they accepted before (the bare domain, and gamma also its own host) until
 * no live client of the exchange is known to depend on it; making them strict is a one-line change to this table.
 */
export const OIDC_AUDIENCES: Record<Stage, readonly string[]> = {
  beta: ['beta.mopm.dev'],
  gamma: ['mopm.dev', 'gamma.mopm.dev'],
  prod: ['mopm.dev'],
};
export const oidcAudiences = (stage: Stage): string[] => [...OIDC_AUDIENCES[stage]];

/**
 * Wires login, tokens and CI exchange. Needs only the table names (from the stage) and the name of the OAuth secret;
 * the secret itself is read when a device login first needs it, so a stage without it still serves everything else.
 */
export function configureAuth(stage: Stage, doc: DocClient, env: NodeJS.ProcessEnv, read: SecretReader = readSecretFromAws): AuthServices | undefined {
  // Parsed before anything else: a CI_PUBLISHERS value on a stage that may not have one stops the function from starting,
  // whether or not auth is otherwise wired (the check is the code's, not only the infrastructure's).
  const ciPublishers = parseCiPublishers(stage, env[CI_PUBLISHERS_ENV]);
  const secretId = env.MOPM_OAUTH_SECRET_NAME;
  if (!secretId) return undefined;
  const tables = authTablesFor(stage);
  const store = new DynamoAuthStore(doc, tables);
  const namespaces = new DynamoNamespaceStore(doc, tables.namespaces);
  const secret = new OAuthSecretSource({ secretId, read });
  const require2fa = env.MOPM_REQUIRE_2FA !== 'false';
  let device: { clientId: string; svc: DeviceLogin } | undefined;
  return {
    authn: new Authenticator({ store }),
    tokens: new TokenService({ store, ownedPackages: ownedPackagesFrom(doc, tablesFor(stage).owners) }),
    oidc: new OidcExchange({
      store,
      verifier: new GithubJwtVerifier({ audiences: oidcAudiences(stage) }),
      namespaces,
      ...(ciPublishers.length > 0 ? { ciPublishers, registry: new DynamoStore(doc, tablesFor(stage)) } : {}),
    }),
    async devices() {
      const clientId = await secret.clientId();
      if (device?.clientId !== clientId) device = { clientId, svc: new DeviceLogin({ store, namespaces, github: new HttpGitHubApi(clientId), require2fa }) };
      return device.svc;
    },
  };
}

/** The full names of a namespace's packages, sorted: a prefix read of the registry's name index. */
export function packagesInFrom(registry: Pick<Store, 'searchPackages'>): (namespace: string) => Promise<string[]> {
  return async (namespace) => {
    const out: string[] = [];
    for (let after: string | undefined; ; ) {
      const page = await registry.searchPackages(`${namespace}/`, after, 100);
      out.push(...page.map((p) => p.name));
      if (page.length < 100) return out;
      after = page[page.length - 1]!.name;
    }
  };
}

/**
 * What `/api/v2` needs (src/http/v2-routes.ts). `getMe` and `createToken` need the auth tables, so they are wired with login
 * (MOPM_OAUTH_SECRET_NAME); `createPackage` with the publish side; `createNamespace` with the organization check
 * (`membership`, built by `membershipFor` when MOPM_APP_SECRET_NAME is set; without it `createNamespace` answers `unavailable`).
 */
export function configureV2(
  stage: Stage,
  doc: DocClient,
  env: NodeJS.ProcessEnv,
  registry: Store,
  access: NamespaceAccess,
  creates: V2Deps['creates'],
  membership?: OrgMembership,
): V2Deps {
  const namespaces = new DynamoNamespaceStore(doc, authTablesFor(stage).namespaces);
  return {
    access,
    namespaces,
    ...(creates ? { creates } : {}),
    ...(membership ? { membership } : {}),
    ...(env.MOPM_OAUTH_SECRET_NAME
      ? { tokens: new TokenServiceV2({ store: new DynamoAuthStore(doc, authTablesFor(stage)), access, packagesIn: packagesInFrom(registry) }) }
      : {}),
  };
}

/**
 * The organization membership check, when the stage names a GitHub App secret (MOPM_APP_SECRET_NAME). The secret is read on
 * the first organization question, not here; while it is absent or malformed that question answers `unavailable`.
 */
export function membershipFor(stage: Stage, doc: DocClient, env: NodeJS.ProcessEnv, read: SecretReader = readSecretFromAws): OrgMembership | undefined {
  const secretId = env.MOPM_APP_SECRET_NAME;
  if (!secretId) return undefined;
  return new OrgMembership({
    app: new SecretGitHubAppApi({ secretId, read }),
    passes: new DynamoMembershipPassStore(doc, authTablesFor(stage).membership_passes),
    now: () => new Date(),
  });
}

function configure(): Configured {
  const stage = stageOf(process.env) as Stage;
  const doc = documentClient();
  const flags = flagsFor(process.env, doc, stage);
  const envReadOnly = process.env.MOPM_READ_ONLY === 'true';
  const store = new DynamoStore(doc, tablesFor(stage));
  const membership = membershipFor(stage, doc, process.env);
  const access = namespaceAccessFor(doc, stage, membership);
  const publish = publishApiFor(process.env, doc, stage, flags, access);
  return {
    deps: {
      store,
      stage,
      version: process.env.MOPM_VERSION ?? 'dev',
      commit: process.env.MOPM_COMMIT ?? 'dev',
      readOnly: envReadOnly,
      publish,
      auth: configureAuth(stage, doc, process.env),
      v2: configureV2(stage, doc, process.env, store, access, publish?.creates, membership),
      ...(process.env.MOPM_API_DOMAIN && process.env.MOPM_CHANNEL_DOMAIN
        ? { indexConfig: { apiDomain: process.env.MOPM_API_DOMAIN, channelDomain: process.env.MOPM_CHANNEL_DOMAIN } }
        : {}),
    },
    flags,
    envReadOnly,
  };
}

export const handler = async (event: GatewayEvent) => {
  configured ??= configure();
  const c = configured;
  // /health reports the switch. If it cannot be read, health still answers, with the deployment's own value.
  let readOnly = c.envReadOnly;
  try {
    readOnly = await c.flags.readOnly();
  } catch (err) {
    console.error(JSON.stringify({ level: 'error', msg: 'read-only switch unreadable', error: String(err) }));
  }
  const body = event.body ? (event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf8') : event.body) : undefined;
  return route(
    {
      method: event.requestContext.http.method,
      path: event.rawPath,
      query: event.queryStringParameters ?? {},
      headers: event.headers ?? {},
      ...(body !== undefined ? { body } : {}),
    },
    { ...c.deps, readOnly },
    event.requestContext.requestId,
  );
};
