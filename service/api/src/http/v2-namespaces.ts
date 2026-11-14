import { AuthError } from '../auth/errors';
import { RegistryError } from '../errors';
import { jsonBody, type AuthServices } from './auth-routes';
import type { V2Deps } from './v2-routes';

/**
 * `POST /api/v2/namespaces` (createNamespace): a fresh session binds the organization namespace `{"namespace": string}` to
 * the App's installation. 201 created, 200 rebound or held, with `NamespaceInfo`.
 */
export async function createNamespaceV2(auth: AuthServices, v2: V2Deps, authorization: string | undefined, body: string | undefined): Promise<{ status: number; body: unknown }> {
  const account = auth.authn.freshSession(await auth.authn.authenticate(authorization));
  const namespace = jsonBody(body).namespace;
  if (typeof namespace !== 'string') {
    throw new RegistryError('invalid_request', "The request is not valid: 'namespace' must be a string.", { detail: "'namespace' must be a string" });
  }
  if (!v2.membership) throw new AuthError('unavailable', 'GitHub could not be asked: the registry has no GitHub App configured.', { service: 'GitHub' });
  const bound = await v2.membership.bindOrgNamespace(v2.namespaces, namespace, account);
  return { status: bound.status === 'created' ? 201 : 200, body: await v2.access.info(bound.record) };
}
