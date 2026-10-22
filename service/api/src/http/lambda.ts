import {
  Authenticator,
  authTablesFor,
  DeviceLogin,
  DynamoAuthStore,
  GithubJwtVerifier,
  HttpGitHubApi,
  OidcExchange,
  ownedPackagesFrom,
  TokenService,
} from '../auth';
import { DynamoStore, tablesFor, type DocClient } from '../dynamo-store';
import { documentClient, flagsFor, publishApiFor, stageOf } from '../publish/wiring';
import type { Flags } from '../publish/ports';
import type { AuthServices } from './auth-routes';
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

/** Accepted `aud` of a CI identity token: the bare domain and the stage's own host. */
export const oidcAudiences = (stage: Stage) => (stage === 'prod' ? ['mopm.dev'] : ['mopm.dev', `${stage}.mopm.dev`]);

/**
 * Wires login, tokens and CI exchange. Needs only the table names (from the stage) and the name of the OAuth secret;
 * the secret itself is read when a device login first needs it, so a stage without it still serves everything else.
 */
export function configureAuth(stage: Stage, doc: DocClient, env: NodeJS.ProcessEnv, read: SecretReader = readSecretFromAws): AuthServices | undefined {
  const secretId = env.MOPM_OAUTH_SECRET_NAME;
  if (!secretId) return undefined;
  const store = new DynamoAuthStore(doc, authTablesFor(stage));
  const secret = new OAuthSecretSource({ secretId, read });
  const require2fa = env.MOPM_REQUIRE_2FA !== 'false';
  let device: { clientId: string; svc: DeviceLogin } | undefined;
  return {
    authn: new Authenticator({ store }),
    tokens: new TokenService({ store, ownedPackages: ownedPackagesFrom(doc, tablesFor(stage).owners) }),
    oidc: new OidcExchange({ store, verifier: new GithubJwtVerifier({ audiences: oidcAudiences(stage) }) }),
    async devices() {
      const clientId = await secret.clientId();
      if (device?.clientId !== clientId) device = { clientId, svc: new DeviceLogin({ store, github: new HttpGitHubApi(clientId), require2fa }) };
      return device.svc;
    },
  };
}

function configure(): Configured {
  const stage = stageOf(process.env) as Stage;
  const doc = documentClient();
  const flags = flagsFor(process.env, doc, stage);
  const envReadOnly = process.env.MOPM_READ_ONLY === 'true';
  return {
    deps: {
      store: new DynamoStore(doc, tablesFor(stage)),
      stage,
      version: process.env.MOPM_VERSION ?? 'dev',
      commit: process.env.MOPM_COMMIT ?? 'dev',
      readOnly: envReadOnly,
      publish: publishApiFor(process.env, doc, stage, flags),
      auth: configureAuth(stage, doc, process.env),
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
