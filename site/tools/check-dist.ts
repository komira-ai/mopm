// Checks a built dist/ before anything deploys it. Each rule is one the site stack or the CSP relies on:
//  - the pages the edge router and the error responses name exist (index, app, 404, docs);
//  - every /assets/<id>/ reference in a page, and every relative import in a module, names a file that exists
//    (a dangling one is a broken page after deploy, since assets are immutable and pages are not);
//  - every <script> is empty and has a src under /assets/; no style attribute or element, no event-handler attribute,
//    no javascript:, data: or vbscript: URL, read after entity decoding as a browser reads it (the CSP would block them);
//  - only .html, .js and .css files (the bucket serves nothing else);
//  - the JavaScript and CSS stay small: each module at most JS_MAX_BYTES, all of them at most JS_TOTAL_MAX_BYTES (tsc
//    output is not minified; the edge compresses it), the stylesheet at most CSS_MAX_BYTES.

import { readdirSync, readFileSync, statSync } from 'fs';
import { join, posix, relative, sep } from 'path';
import { DOC_PAGES } from '../src/links';

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
export const CSS_MAX_BYTES = 16 * 1024;

export const REQUIRED = ['index.html', 'app.html', '404.html', 'docs/index.html', ...DOC_PAGES.map((d) => `docs/${d.slug}/index.html`)];

export class DistError extends Error {
  constructor(problems: string[]) {
    super(`dist check failed:\n  ${problems.join('\n  ')}`);
    this.name = 'DistError';
  }
}

/**
 * Every start tag in a page with its attributes (lowercased names, raw values). Text and attribute values are escaped
 * by the serializer, so a '<' always starts a tag and a '"' always ends a value.
 */
export function tagsIn(html: string): [string, [string, string][]][] {
  const out: [string, [string, string][]][] = [];
  for (const m of html.matchAll(/<([a-zA-Z][a-zA-Z0-9]*)((?:\s+[^\s=>"'\/]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>"']+))?)*)\s*\/?>/g)) {
    const attrs = [...m[2].matchAll(/([^\s=>"'\/]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+)))?/g)].map(
      (a): [string, string] => [a[1].toLowerCase(), a[2] ?? a[3] ?? a[4] ?? ''],
    );
    out.push([m[1].toLowerCase(), attrs]);
  }
  return out;
}

const NAMED: Readonly<Record<string, string>> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", colon: ':', tab: '\t', newline: '\n' };
const URL_ATTRS = new Set(['href', 'src', 'action', 'formaction']);

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
  let css = 0;
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
      css += Buffer.byteLength(text);
      if (!f.startsWith('assets/')) problems.push(`${f}: a stylesheet outside assets/`);
    }
    if (ext !== '.html') continue;
    // A script's content runs whatever its attributes say; every one must be empty (an unclosed one runs to the end).
    for (const m of text.matchAll(/<script\b[^>]*>([\s\S]*?)(?:<\/script\s*>|$)/gi)) {
      if (m[1] !== '') problems.push(`${f}: an inline <script>`);
    }
    if (/<style\b/i.test(text)) problems.push(`${f}: a <style> element`);
    for (const [tag, attrs] of tagsIn(text)) {
      if (tag === 'script') {
        const src = attrs.filter(([name]) => name === 'src');
        if (src.length !== 1 || !src[0][1].startsWith('/assets/')) problems.push(`${f}: a <script> without one src under /assets/`);
      }
      for (const [name, value] of attrs) {
        if (name === 'style') problems.push(`${f}: a style attribute on <${tag}>`);
        if (name.startsWith('on')) problems.push(`${f}: an event-handler attribute ${name} on <${tag}>`);
        if (URL_ATTRS.has(name) && isScriptUrl(value)) problems.push(`${f}: a script URL (or an unknown character reference) in ${name} on <${tag}>`);
        const asset = (name === 'href' || name === 'src') && /^\/(assets\/[^#?]+)/.exec(value);
        if (asset && !have.has(asset[1])) problems.push(`${f}: references /${asset[1]}, which is not in dist`);
      }
    }
  }
  if (js > JS_TOTAL_MAX_BYTES) problems.push(`JavaScript is ${js} bytes in all; the limit is ${JS_TOTAL_MAX_BYTES}`);
  if (css > CSS_MAX_BYTES) problems.push(`CSS is ${css} bytes; the limit is ${CSS_MAX_BYTES}`);
  if (problems.length > 0) throw new DistError(problems);
}
