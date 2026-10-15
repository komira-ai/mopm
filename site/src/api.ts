// The read API client. One call per page: getPackage, getVersion or searchPackages, plus getHealth for the banner.
//
// Every request is a simple CORS GET with no headers and no credentials, so the browser sends no preflight and no
// cookies. fetch is injected: tests replay the contract fixtures through it and never reach the network.

import { decodeHealth, decodePackageInfo, decodePackageList, decodeVersionDetail } from './decode.js';
import { type ApiError, fromResponse, networkError, timeoutError, unreadable } from './errors.js';
import type { SearchSort } from './routes.js';
import type { Health, PackageInfo, PackageList, VersionDetail } from './types.js';

export type FetchFn = (url: string, init: RequestInit) => Promise<Response>;

export type Result<T> = { kind: 'ok'; value: T; requestId: string | null } | ApiError;

export interface SearchQuery {
  q?: string;
  sort?: SearchSort;
  cursor?: string;
  limit?: number;
}

export interface Client {
  getHealth(): Promise<Result<Health>>;
  searchPackages(query: SearchQuery): Promise<Result<PackageList>>;
  getPackage(name: string): Promise<Result<PackageInfo>>;
  getVersion(name: string, version: string): Promise<Result<VersionDetail>>;
}

export const REQUEST_ID_HEADER = 'x-mopm-request-id';
export const TIMEOUT_MS = 10_000;

/** `base` is apiBase(location.hostname), e.g. 'https://api.mopm.dev/api/v1'. */
export function client(fetchFn: FetchFn, base: string, timeoutMs: number = TIMEOUT_MS): Client {
  async function get<T>(path: string, decode: (v: unknown) => T): Promise<Result<T>> {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), timeoutMs);
    try {
      let res: Response;
      try {
        res = await fetchFn(base + path, { method: 'GET', mode: 'cors', credentials: 'omit', signal: ctl.signal });
      } catch {
        return ctl.signal.aborted ? timeoutError() : networkError();
      }
      const requestId = res.headers.get(REQUEST_ID_HEADER);
      let body: string;
      try {
        body = await res.text();
      } catch {
        return ctl.signal.aborted ? timeoutError() : networkError();
      }
      if (res.status < 200 || res.status > 299) return fromResponse(res.status, body, requestId);
      try {
        return { kind: 'ok', value: decode(JSON.parse(body)), requestId };
      } catch {
        return unreadable(res.status, requestId);
      }
    } finally {
      clearTimeout(timer);
    }
  }

  return {
    getHealth: () => get('/health', decodeHealth),
    searchPackages: (query) => {
      const qs = new URLSearchParams();
      if (query.q !== undefined) qs.set('q', query.q);
      if (query.sort !== undefined) qs.set('sort', query.sort);
      if (query.cursor !== undefined) qs.set('cursor', query.cursor);
      if (query.limit !== undefined) qs.set('limit', String(query.limit));
      const s = qs.toString();
      return get(s ? `/packages?${s}` : '/packages', decodePackageList);
    },
    getPackage: (name) => get(`/packages/${encodeURIComponent(name)}`, decodePackageInfo),
    getVersion: (name, version) =>
      get(`/packages/${encodeURIComponent(name)}/${encodeURIComponent(version)}`, decodeVersionDetail),
  };
}
