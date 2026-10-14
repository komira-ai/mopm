import { README_MAX_BYTES } from '../types';
import { invalidRequest } from './errors';

/**
 * The optional display metadata a commit request carries (spec/api/openapi.yaml CommitPublishRequest; rules in
 * spec/mopm-toml.md, `[package]` display fields). The registry stores it on the version and serves it back
 * (`getVersion`, `getPackage`). Every rule is the one the spec states for the field; a value that breaks it is
 * `invalid_request`, never silently trimmed.
 */
export interface DisplayMeta {
  description?: string;
  license?: string;
  repository?: string;
  homepage?: string;
  keywords?: string[];
  /** Markdown, at most README_MAX_BYTES of UTF-8. */
  readme?: string;
}

export const DISPLAY_FIELDS = ['description', 'license', 'repository', 'homepage', 'keywords', 'readme'] as const;

const KEYWORD = /^[A-Za-z0-9._+-]{1,32}$/;

function url(field: string, v: string, protocols: readonly string[]): string {
  let u: URL | undefined;
  try {
    u = new URL(v);
  } catch {
    u = undefined;
  }
  if (v.length > 2048 || u === undefined || !protocols.includes(u.protocol) || /\s/.test(v)) {
    throw invalidRequest(`'${field}' is a ${protocols.map((p) => p.slice(0, -1)).join(' or ')} URL of at most 2048 characters`);
  }
  return v;
}

/** Validate the display fields of a commit body. Absent stays absent; `null` is not a value. */
export function parseDisplay(body: Record<string, unknown>): DisplayMeta {
  const out: DisplayMeta = {};
  const { description, license, repository, homepage, keywords, readme } = body;
  if (description !== undefined) {
    if (typeof description !== 'string' || description.length < 1 || description.length > 512 || /[\r\n]/.test(description)) {
      throw invalidRequest("'description' is one line of 1 to 512 characters");
    }
    out.description = description;
  }
  if (license !== undefined) {
    if (typeof license !== 'string' || license.length < 1 || license.length > 128) throw invalidRequest("'license' is a string of 1 to 128 characters");
    out.license = license;
  }
  if (repository !== undefined) {
    if (typeof repository !== 'string') throw invalidRequest("'repository' must be a string");
    out.repository = url('repository', repository, ['https:']);
  }
  if (homepage !== undefined) {
    if (typeof homepage !== 'string') throw invalidRequest("'homepage' must be a string");
    out.homepage = url('homepage', homepage, ['http:', 'https:']);
  }
  if (keywords !== undefined) {
    if (!Array.isArray(keywords) || keywords.length > 10) throw invalidRequest("'keywords' is an array of at most 10 strings");
    if (!keywords.every((k) => typeof k === 'string' && KEYWORD.test(k))) {
      throw invalidRequest("each keyword is 1 to 32 letters, digits, '-', '_', '.' or '+'");
    }
    if (new Set(keywords).size !== keywords.length) throw invalidRequest("'keywords' repeats a keyword");
    out.keywords = keywords as string[];
  }
  if (readme !== undefined) {
    // Bytes of UTF-8, not characters: the read API serves at most README_MAX_BYTES, so a larger one could never be shown.
    if (typeof readme !== 'string' || Buffer.byteLength(readme, 'utf8') > README_MAX_BYTES) {
      throw invalidRequest(`'readme' is a string of at most ${README_MAX_BYTES} bytes of UTF-8`);
    }
    out.readme = readme;
  }
  return out;
}
