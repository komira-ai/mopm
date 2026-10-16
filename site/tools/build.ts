// Builds dist/: the prerendered pages and the hashed assets, then checks the result (check-dist.ts).
//
//   dist/index.html, app.html, 404.html, docs/index.html, docs/<slug>/index.html
//   dist/assets/<id>/  the browser modules (build/browser, from tsc) and the stylesheets of static/ (layout.ts says
//                      which page loads which)
//
// <id> is the first 16 hex digits of a sha256 over the assets' sorted (path, bytes): the same inputs give the same id
// and the same bytes everywhere, with no clock or commit in them, so every stage deploys one artifact and an asset URL
// never serves two contents (the site stack is to cache assets as immutable once it serves this build).

import { createHash } from 'crypto';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { dirname, join, resolve } from 'path';
import { checkDist, importsOf, listFiles } from './check-dist';
import { buildDocPages, docsIndexPage } from './docs';
import { AREA_STYLESHEETS, type Assets, renderPage, SHARED_STYLESHEET } from './layout';
import { appShell, homePage, notFoundPage } from './pages';

export interface BuildOptions {
  /** tsc's browser output (build/browser): main.js and the modules it imports. */
  browserDir: string;
  /** site/static: the stylesheets. */
  staticDir: string;
  /** The repository root: the docs are read from it. */
  repoRoot: string;
  /** Emptied and rewritten. */
  outDir: string;
}

export const ENTRY = 'main.js';
/** Every stylesheet in static/ that ships: the shared one and each area's, sorted. */
export const STYLESHEETS = [...new Set([SHARED_STYLESHEET, ...Object.values(AREA_STYLESHEETS).flat()])].sort();

/** The asset id: sha256 over each (path, bytes) pair in path order, length-prefixed so no two sets collide. */
export function assetId(files: ReadonlyMap<string, Buffer>): string {
  const hash = createHash('sha256');
  for (const path of [...files.keys()].sort()) {
    const bytes = files.get(path) as Buffer;
    hash.update(`${Buffer.byteLength(path)}:${path}:${bytes.length}:`);
    hash.update(bytes);
  }
  return hash.digest('hex').slice(0, 16);
}

/** Modules reachable from the entry, without the entry, in a stable order: the modulepreload list. */
export function moduleGraph(js: ReadonlyMap<string, Buffer>, entry: string): string[] {
  const seen = new Set<string>([entry]);
  const queue = [entry];
  while (queue.length > 0) {
    const m = queue.shift() as string;
    const src = js.get(m);
    if (src === undefined) throw new Error(`build: ${m} is imported but was not compiled`);
    for (const dep of importsOf(m, src.toString('utf8'))) {
      if (!seen.has(dep)) {
        seen.add(dep);
        queue.push(dep);
      }
    }
  }
  seen.delete(entry);
  return [...seen].sort();
}

function write(path: string, data: string | Buffer): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
}

export function buildSite(opts: BuildOptions): { id: string; files: string[] } {
  const compiled = new Map<string, Buffer>();
  for (const f of listFiles(opts.browserDir)) {
    if (f.endsWith('.js')) compiled.set(f, readFileSync(join(opts.browserDir, f)));
  }
  if (!compiled.has(ENTRY)) throw new Error(`build: ${join(opts.browserDir, ENTRY)} is missing; run tsc -p tsconfig.browser.json first`);
  // Only the entry and what it imports ship (types.js, a module of types only, is never loaded).
  const preload = moduleGraph(compiled, ENTRY);
  const assets = new Map<string, Buffer>();
  for (const m of [ENTRY, ...preload]) assets.set(m, compiled.get(m) as Buffer);
  for (const css of STYLESHEETS) assets.set(css, readFileSync(join(opts.staticDir, css)));

  const id = assetId(assets);
  const refs: Assets = { base: `/assets/${id}/`, entry: ENTRY, preload };

  rmSync(opts.outDir, { recursive: true, force: true });
  for (const [path, bytes] of assets) write(join(opts.outDir, 'assets', id, path), bytes);

  const docs = buildDocPages(opts.repoRoot);
  const pages: [string, string][] = [
    ['index.html', renderPage(homePage(), refs)],
    ['app.html', renderPage(appShell(), refs)],
    ['404.html', renderPage(notFoundPage(), refs)],
    ['docs/index.html', renderPage(docsIndexPage(docs, opts.repoRoot), refs)],
    ...docs.map((d): [string, string] => [`docs/${d.slug}/index.html`, renderPage(d.spec, refs)]),
  ];
  for (const [path, html] of pages) write(join(opts.outDir, path), html);

  checkDist(opts.outDir);
  return { id, files: listFiles(opts.outDir) };
}

if (require.main === module) {
  // Compiled to site/build/tools/tools/build.js.
  const site = resolve(__dirname, '..', '..', '..');
  const { id, files } = buildSite({
    browserDir: join(site, 'build', 'browser'),
    staticDir: join(site, 'static'),
    repoRoot: resolve(site, '..'),
    outDir: join(site, 'dist'),
  });
  process.stdout.write(`dist: ${files.length} files, assets/${id}/\n`);
}
