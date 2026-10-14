// URL checking: the only producer of SafeHref.
//
// A link from markdown (a package readme, or a repo doc rendered at build time) becomes a SafeHref or nothing; the
// renderer shows a refused link as its text. The decision is made on the string as a browser's URL parser sees it:
// control characters, whitespace and invisible format characters are removed first, the URL is resolved with the
// WHATWG parser, and only the normalised result is emitted, so what was checked is exactly what the browser follows.

import type { SafeHref } from './doc.js';

export const REPO_URL = 'https://github.com/komira-ai/mopm';
const REPO_BLOB = `${REPO_URL}/blob/main/`;
const REPO_BLOB_PATH = new URL(REPO_BLOB).pathname;

/** Repo docs the site publishes, by source path: a relative link to one of them stays on the site. */
export const DOC_PAGES: readonly { slug: string; source: string }[] = [
  { slug: 'mopm-toml', source: 'spec/mopm-toml.md' },
  { slug: 'mopm-test', source: 'docs/mopm-test.md' },
];

const ALLOWED_SCHEMES: ReadonlySet<string> = new Set(['https:', 'http:', 'mailto:']);
// C0 controls, space, DEL, C1 controls, and invisible format characters (zero-width, bidi controls, BOM).
const STRIP = /[\u0000-\u0020\u007f-\u009f\u00ad\u200b-\u200f\u2028-\u202e\u2060-\u2064\ufeff]/g;
const HAS_SCHEME = /^[a-z][a-z0-9+.-]*:/i;

export type LinkContext =
  /** A package readme: absolute links and in-page fragments only; a relative link becomes text. */
  | { mode: 'readme'; idPrefix: string }
  /** A repo doc at `source` (a repo path): relative links resolve in the repo, as GitHub resolves them. */
  | { mode: 'docs'; idPrefix: string; source: string };

function fragment(frag: string, idPrefix: string): SafeHref | null {
  if (frag === '') return null;
  let decoded = frag;
  try {
    decoded = decodeURIComponent(frag);
  } catch {
    // keep the raw text; it is encoded below either way
  }
  return `#${idPrefix}${encodeURIComponent(decoded)}` as SafeHref;
}

function sitePathFor(repoPath: string): string | null {
  for (const d of DOC_PAGES) if (d.source === repoPath) return `/docs/${d.slug}/`;
  return null;
}

function repoLink(s: string, source: string): SafeHref | null {
  // A path starting with '/' is relative to the repo root, as on GitHub; anything else to the doc's directory.
  const dir = source.includes('/') ? source.slice(0, source.lastIndexOf('/') + 1) : '';
  const base = s.startsWith('/') ? REPO_BLOB : REPO_BLOB + dir;
  let u: URL;
  try {
    u = new URL(s.startsWith('/') ? s.slice(1) : s, base);
  } catch {
    return null;
  }
  // '//host/x', '..' past the repo root and a scheme the regex missed all land outside the blob prefix.
  if (!u.href.startsWith(REPO_BLOB)) return null;
  const site = sitePathFor(decodeURIComponentSafe(u.pathname.slice(REPO_BLOB_PATH.length)));
  return (site ? site + u.hash : u.href) as SafeHref;
}

function decodeURIComponentSafe(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}

/** The checked href for a markdown link destination, or null when it must be shown as text. */
export function safeHref(raw: string, ctx: LinkContext): SafeHref | null {
  const s = raw.replace(STRIP, '');
  if (s === '') return null;
  if (s.startsWith('#')) return fragment(s.slice(1), ctx.idPrefix);
  if (HAS_SCHEME.test(s)) {
    let u: URL;
    try {
      u = new URL(s);
    } catch {
      return null;
    }
    return ALLOWED_SCHEMES.has(u.protocol) ? (u.href as SafeHref) : null;
  }
  if (s.startsWith('//') || s.startsWith('\\') || s.startsWith('/\\')) return null;
  return ctx.mode === 'docs' ? repoLink(s, ctx.source) : null;
}

/** A same-site path built by routes.ts (always '/...', never protocol-relative). Throws on anything else. */
export function internalHref(path: string): SafeHref {
  // A tab or newline would be dropped by the browser's URL parser ('/\t/x' is '//x'), so any such character refuses.
  if (path.replace(STRIP, '') !== path || !path.startsWith('/') || path.startsWith('//') || path.startsWith('/\\')) {
    throw new Error(`internalHref: '${path}' is not a same-site path`);
  }
  return path as SafeHref;
}
