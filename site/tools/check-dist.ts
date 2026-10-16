// Checks a built dist/ before anything deploys it. The site stack does not serve this build yet; each rule is one the
// stack will rely on when it is switched to (its edge router, its error responses and a Content-Security-Policy that
// allows 'self' only are requirements for that change, not things it has today):
//  - the pages the edge router and the error responses are to name exist (index, app, 404, docs);
//  - every /assets/<id>/ reference in a page, and every relative import in a module, names a file that exists
//    (a dangling one is a broken page after deploy, since assets are immutable and pages are not);
//  - every '<' in a page starts a tag the scanner reads as the browser does (no comment, no '<' inside a tag, no
//    unclosed tag), so nothing below can be skipped;
//  - every <script> is empty and has a src under /assets/; no style attribute or element, no event-handler attribute,
//    no javascript:, data: or vbscript: URL in any *href, src, action, formaction or data, read after entity decoding
//    as a browser reads it (the required CSP would block them);
//  - only .html, .js and .css files (the bucket is to serve nothing else);
//  - the JavaScript and CSS stay small: each module at most JS_MAX_BYTES, all of them at most JS_TOTAL_MAX_BYTES (tsc
//    output is not minified; the edge is to compress it); the shared stylesheet at most SHARED_CSS_MAX_BYTES, each area
//    stylesheet at most AREA_CSS_MAX_BYTES, and the stylesheets one page links at most PAGE_CSS_MAX_BYTES together.

import { readdirSync, readFileSync, statSync } from 'fs';
import { join, posix, relative, sep } from 'path';
import { DOC_PAGES } from '../src/links';
import { SHARED_STYLESHEET } from './layout';

/** Relative paths ('/'-separated) of the files under dir, sorted. */
export function listFiles(dir: string): string[] {
  const out: string[] = [];
  const walk = (d: string): void => {
    for (const f of readdirSync(d).sort()) {
      const p = join(d, f);
      if (statSync(p).isDirectory()) walk(p);
      else out.push(relative(dir, p).split(sep).join('/'));
    }
  };
  walk(dir);
  return out.sort();
}

const IMPORT = /(?:\bfrom\s*|\bimport\s*\(?\s*)['"](\.{1,2}\/[^'"]+)['"]/g;

/** The relative imports of a module's source, resolved against its own path. */
export function importsOf(path: string, source: string): string[] {
  return [...source.matchAll(IMPORT)].map((m) => posix.normalize(posix.join(posix.dirname(path), m[1])));
}

export const JS_MAX_BYTES = 64 * 1024;
export const JS_TOTAL_MAX_BYTES = 128 * 1024;
/** The design note's budgets: the shared stylesheet (site.css) and each area stylesheet. */
export const SHARED_CSS_MAX_BYTES = 24 * 1024;
export const AREA_CSS_MAX_BYTES = 16 * 1024;
/**
 * The stylesheets one page links, together: 30 KiB, down from the 32 KiB that held every route's styles in one sheet.
 * The heaviest page is the app shell (the shared sheet plus the package and search areas, see layout.ts).
 */
export const PAGE_CSS_MAX_BYTES = 30 * 1024;

export const REQUIRED = ['index.html', 'app.html', '404.html', 'docs/index.html', ...DOC_PAGES.map((d) => `docs/${d.slug}/index.html`)];

export class DistError extends Error {
  constructor(problems: string[]) {
    super(`dist check failed:\n  ${problems.join('\n  ')}`);
    this.name = 'DistError';
  }
}

export type Tag = [string, [string, string][]];

const WS = new Set(['\t', '\n', '\f', '\r', ' ']);
const isAlpha = (c: string | undefined): boolean => c !== undefined && /^[a-zA-Z]$/.test(c);

/**
 * Reads one start or end tag beginning at html[i] (a '<'), as the HTML tokenizer does: a '/' separates attributes; a
 * name runs to whitespace, '/', '>' or '=' (and may start with '='); a quoted value runs to its quote, an unquoted
 * one to whitespace or '>'. Returns the tag and the index after its '>', or null when the page ends first.
 */
function readTag(html: string, i: number): { tag: Tag; end: number } | null {
  let j = i + 1;
  if (html[j] === '/') j++;
  let name = '';
  while (j < html.length && !WS.has(html[j]) && html[j] !== '/' && html[j] !== '>') name += html[j++];
  const attrs: [string, string][] = [];
  for (;;) {
    while (j < html.length && (WS.has(html[j]) || html[j] === '/')) j++;
    if (j >= html.length) return null;
    if (html[j] === '>') return { tag: [name.toLowerCase(), attrs], end: j + 1 };
    let attr = html[j++];
    while (j < html.length && !WS.has(html[j]) && html[j] !== '/' && html[j] !== '>' && html[j] !== '=') attr += html[j++];
    while (j < html.length && WS.has(html[j])) j++;
    let value = '';
    if (html[j] === '=') {
      j++;
      while (j < html.length && WS.has(html[j])) j++;
      const q = html[j];
      if (q === '"' || q === "'") {
        const close = html.indexOf(q, j + 1);
        if (close < 0) return null;
        value = html.slice(j + 1, close);
        j = close + 1;
      } else {
        while (j < html.length && !WS.has(html[j]) && html[j] !== '>') value += html[j++];
      }
    }
    attrs.push([attr.toLowerCase(), value]);
  }
}

/**
 * Every start tag in a page with its attributes (lowercased names, raw values, duplicates kept), and what the scanner
 * could not read. It fails closed: the serializer escapes every '<' in text and attribute values, so in a page this
 * site builds a '<' starts a start tag, an end tag or the leading doctype. Any other '<' (a comment, a '<' inside a
 * tag), or a tag the page does not close, is a problem, so no markup the browser reads can hide from the checks.
 */
export function readTags(html: string): { tags: Tag[]; problems: string[] } {
  const tags: Tag[] = [];
  const problems: string[] = [];
  const doctype = /^<!doctype html>/i.exec(html);
  let i = doctype ? doctype[0].length : 0;
  for (;;) {
    const lt = html.indexOf('<', i);
    if (lt < 0) break;
    const isTag = isAlpha(html[lt + 1]) || (html[lt + 1] === '/' && isAlpha(html[lt + 2]));
    if (!isTag) {
      problems.push(`a '<' that does not start a tag, at offset ${lt}`);
      i = lt + 1;
      continue;
    }
    const r = readTag(html, lt);
    if (r === null) {
      problems.push(`a tag the page does not close, at offset ${lt}`);
      break;
    }
    if (html.slice(lt + 1, r.end).includes('<')) problems.push(`a '<' inside a tag, at offset ${lt}`);
    if (html[lt + 1] !== '/') tags.push(r.tag);
    i = r.end;
  }
  return { tags, problems };
}

/** The start tags of a page (see readTags); throws when the page holds anything the scanner cannot read. */
export function tagsIn(html: string): Tag[] {
  const { tags, problems } = readTags(html);
  if (problems.length > 0) throw new Error(problems.join('; '));
  return tags;
}

const NAMED: Readonly<Record<string, string>> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", colon: ':', tab: '\t', newline: '\n' };
// Every *href (href, xlink:href) and the other attributes that take a URL a browser may navigate to or load.
const URL_ATTRS = new Set(['src', 'action', 'formaction', 'data']);
const isUrlAttr = (name: string): boolean => name.endsWith('href') || URL_ATTRS.has(name);

/**
 * An attribute value as the browser reads it: character references decoded in one pass, or null when it holds a named
 * reference this list does not know (the page's own serializer writes only &amp;, &lt;, &gt; and &quot;).
 */
export function decodeAttr(raw: string): string | null {
  let unknown = false;
  const out = raw.replace(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);?/g, (_m, ref: string) => {
    if (ref[0] === '#') {
      const cp = ref[1] === 'x' || ref[1] === 'X' ? parseInt(ref.slice(2), 16) : parseInt(ref.slice(1), 10);
      return cp > 0 && cp <= 0x10ffff ? String.fromCodePoint(cp) : '\ufffd';
    }
    const c = NAMED[ref.toLowerCase()];
    if (c === undefined) unknown = true;
    return c ?? '';
  });
  return unknown ? null : out;
}

/** Whether a URL attribute value runs script or embeds a document, as a browser's URL parser reads it. */
export function isScriptUrl(raw: string): boolean {
  const v = decodeAttr(raw);
  if (v === null) return true;
  // The URL parser drops leading C0 controls and spaces, and every tab and newline anywhere.
  const s = v.replace(/[\t\n\r]/g, '').replace(/^[\x00-\x20]+/, '');
  return /^(?:javascript|data|vbscript):/i.test(s);
}

/** Throws a DistError listing every problem found. */
export function checkDist(dir: string): void {
  const files = listFiles(dir);
  const have = new Set(files);
  const problems: string[] = [];

  for (const r of REQUIRED) if (!have.has(r)) problems.push(`missing ${r}`);

  let js = 0;
  const cssSize = new Map<string, number>();
  for (const f of files) {
    if (posix.extname(f) === '.css') cssSize.set(f, statSync(join(dir, f)).size);
  }
  for (const f of files) {
    const ext = posix.extname(f);
    if (!['.html', '.js', '.css'].includes(ext)) {
      problems.push(`${f}: only .html, .js and .css files are published`);
      continue;
    }
    const text = readFileSync(join(dir, f), 'utf8');
    if (ext === '.js') {
      const n = Buffer.byteLength(text);
      js += n;
      if (n > JS_MAX_BYTES) problems.push(`${f} is ${n} bytes; the limit for one module is ${JS_MAX_BYTES}`);
      if (!f.startsWith('assets/')) problems.push(`${f}: a script outside assets/`);
      for (const dep of importsOf(f, text)) if (!have.has(dep)) problems.push(`${f}: imports ${dep}, which is not in dist`);
    }
    if (ext === '.css') {
      const n = Buffer.byteLength(text);
      const shared = posix.basename(f) === SHARED_STYLESHEET;
      const max = shared ? SHARED_CSS_MAX_BYTES : AREA_CSS_MAX_BYTES;
      if (n > max) problems.push(`${f} is ${n} bytes; the limit for ${shared ? 'the shared' : 'an area'} stylesheet is ${max}`);
      if (!f.startsWith('assets/')) problems.push(`${f}: a stylesheet outside assets/`);
    }
    if (ext !== '.html') continue;
    // A script's content runs whatever its attributes say; every one must be empty (an unclosed one runs to the end).
    for (const m of text.matchAll(/<script\b[^>]*>([\s\S]*?)(?:<\/script\s*>|$)/gi)) {
      if (m[1] !== '') problems.push(`${f}: an inline <script>`);
    }
    if (/<style\b/i.test(text)) problems.push(`${f}: a <style> element`);
    const { tags, problems: unread } = readTags(text);
    for (const p of unread) problems.push(`${f}: ${p}`);
    let pageCss = 0;
    for (const [tag, attrs] of tags) {
      if (tag === 'link' && attrs.some(([k, v]) => k === 'rel' && v === 'stylesheet')) {
        const href = attrs.find(([k]) => k === 'href')?.[1] ?? '';
        pageCss += cssSize.get(href.replace(/^\//, '')) ?? 0;
      }
      if (tag === 'script') {
        const src = attrs.filter(([name]) => name === 'src');
        if (src.length !== 1 || !src[0][1].startsWith('/assets/')) problems.push(`${f}: a <script> without one src under /assets/`);
      }
      for (const [name, value] of attrs) {
        if (name === 'style') problems.push(`${f}: a style attribute on <${tag}>`);
        if (name.startsWith('on')) problems.push(`${f}: an event-handler attribute ${name} on <${tag}>`);
        if (isUrlAttr(name) && isScriptUrl(value)) problems.push(`${f}: a script URL (or an unknown character reference) in ${name} on <${tag}>`);
        const asset = (name === 'href' || name === 'src') && /^\/(assets\/[^#?]+)/.exec(value);
        if (asset && !have.has(asset[1])) problems.push(`${f}: references /${asset[1]}, which is not in dist`);
      }
    }
    if (pageCss > PAGE_CSS_MAX_BYTES) problems.push(`${f} links ${pageCss} bytes of CSS; the limit for one page is ${PAGE_CSS_MAX_BYTES}`);
  }
  if (js > JS_TOTAL_MAX_BYTES) problems.push(`JavaScript is ${js} bytes in all; the limit is ${JS_TOTAL_MAX_BYTES}`);
  if (problems.length > 0) throw new DistError(problems);
}
