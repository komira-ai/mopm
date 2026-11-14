import type { AuthServices } from './auth-routes';
import type { V2Deps } from './v2-routes';

/** `POST /api/v2/namespaces` (createNamespace): 201 created, 200 rebound or held, with `NamespaceInfo`. */
export async function createNamespaceV2(_auth: AuthServices, _v2: V2Deps, _authorization: string | undefined, _body: string | undefined): Promise<{ status: number; body: unknown }> {
  throw new Error('createNamespaceV2: not implemented');
}
