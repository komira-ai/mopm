// Checks a built dist/ before anything deploys it. Each rule is one the site stack or the CSP relies on:
//  - the pages the edge router and the error responses name exist (index, app, 404, docs);
//  - every /assets/<id>/ reference in a page, and every relative import in a module, names a file that exists
//    (a dangling one is a broken page after deploy, since assets are immutable and pages are not);
//  - no inline script, no style attribute or element, no event-handler attribute (the CSP would block them);
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
    for (const m of text.matchAll(/<script\b([^>]*)>/gi)) {
      if (!/\bsrc="/.test(m[1])) problems.push(`${f}: an inline <script>`);
    }
    if (/<style\b/i.test(text)) problems.push(`${f}: a <style> element`);
    for (const [tag, attrs] of tagsIn(text)) {
      for (const [name, value] of attrs) {
        if (name === 'style') problems.push(`${f}: a style attribute on <${tag}>`);
        if (name.startsWith('on')) problems.push(`${f}: an event-handler attribute ${name} on <${tag}>`);
        if ((name === 'href' || name === 'src' || name === 'action') && /^\s*(?:javascript|data|vbscript):/i.test(value)) {
          problems.push(`${f}: a script URL on <${tag}>`);
        }
        const asset = (name === 'href' || name === 'src') && /^\/(assets\/[^#?]+)/.exec(value);
        if (asset && !have.has(asset[1])) problems.push(`${f}: references /${asset[1]}, which is not in dist`);
      }
    }
  }
  if (js > JS_TOTAL_MAX_BYTES) problems.push(`JavaScript is ${js} bytes in all; the limit is ${JS_TOTAL_MAX_BYTES}`);
  if (css > CSS_MAX_BYTES) problems.push(`CSS is ${css} bytes; the limit is ${CSS_MAX_BYTES}`);
  if (problems.length > 0) throw new DistError(problems);
}
