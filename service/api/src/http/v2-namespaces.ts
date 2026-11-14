import { AuthError } from '../auth/errors';
import { jsonBody, type AuthServices } from './auth-routes';
import type { V2Deps } from './v2-routes';

const unavailable = () => new AuthError('unavailable', 'The registry is temporarily unavailable.');
const needMembers = (v2: V2Deps) => v2.members ?? (() => { throw unavailable(); })(); // prettier-ignore

/**
 * `POST /api/v2/namespaces` (createNamespace): a fresh session starts the registration of the organization namespace
 * `{"namespace": string}`: GitHub's device flow with scope `read:org`. 202 with the device code and the user code.
 */
export async function createNamespaceV2(auth: AuthServices, authorization: string | undefined, body: string | undefined): Promise<{ status: number; body: unknown }> {
  const account = auth.authn.freshSession(await auth.authn.authenticate(authorization));
  const namespace = jsonBody(body).namespace;
  const start = await (await auth.registration()).start(account, namespace);
  return { status: 202, body: start };
}

/**
 * `POST /api/v2/namespaces/poll` (pollNamespace): a token of the account that started the registration asks how it went.
 * `created` carries the new organization's `NamespaceInfo`.
 */
export async function pollNamespaceV2(auth: AuthServices, v2: V2Deps, authorization: string | undefined, body: string | undefined): Promise<{ status: number; body: unknown }> {
  const account = auth.authn.userToken(await auth.authn.authenticate(authorization));
  const r = await (await auth.registration()).poll(account, jsonBody(body).device_code);
  if (r.status !== 'created') return { status: 200, body: r };
  return { status: 200, body: { status: 'created', namespace: await v2.access.info(r.record) } };
}

/** `GET /api/v2/namespaces/{namespace}/members` (listMembers). */
export async function listMembersV2(auth: AuthServices, v2: V2Deps, authorization: string | undefined, namespace: string): Promise<{ status: number; body: unknown }> {
  const account = auth.authn.userToken(await auth.authn.authenticate(authorization));
  return { status: 200, body: await needMembers(v2).list(account, namespace) };
}

/** `PUT /api/v2/namespaces/{namespace}/members/{user}` (setMember): 201 when added, 200 when the role changed or was already that. */
export async function setMemberV2(
  auth: AuthServices,
  v2: V2Deps,
  authorization: string | undefined,
  namespace: string,
  user: string,
  body: string | undefined,
): Promise<{ status: number; body: unknown }> {
  const account = auth.authn.freshSession(await auth.authn.authenticate(authorization));
  const role = jsonBody(body).role;
  const r = await needMembers(v2).set(account, namespace, user, role);
  return { status: r.created ? 201 : 200, body: r.member };
}

/** `DELETE /api/v2/namespaces/{namespace}/members/{user}` (removeMember): 204. */
export async function removeMemberV2(auth: AuthServices, v2: V2Deps, authorization: string | undefined, namespace: string, user: string): Promise<{ status: number; body?: unknown }> {
  const account = auth.authn.freshSession(await auth.authn.authenticate(authorization));
  await needMembers(v2).remove(account, namespace, user);
  return { status: 204 };
}
