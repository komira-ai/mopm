import type { HttpRequest, RouterDeps } from './router';
import type { V2Deps } from './v2-routes';

/** The read operations of `/api/v2`: search, package, versions, version, namespace. */
export async function searchPackagesV2(_deps: RouterDeps, _query: HttpRequest['query']): Promise<unknown> {
  throw new Error('searchPackagesV2: not implemented');
}
export async function getPackageV2(_deps: RouterDeps, _v2: V2Deps, _namespace: string, _name: string): Promise<unknown> {
  throw new Error('getPackageV2: not implemented');
}
export async function listVersionsV2(_deps: RouterDeps, _namespace: string, _name: string, _query: HttpRequest['query']): Promise<unknown> {
  throw new Error('listVersionsV2: not implemented');
}
export async function getVersionV2(_deps: RouterDeps, _namespace: string, _name: string, _version: string): Promise<unknown> {
  throw new Error('getVersionV2: not implemented');
}
export async function getNamespaceV2(_v2: V2Deps, _namespace: string): Promise<unknown> {
  throw new Error('getNamespaceV2: not implemented');
}
