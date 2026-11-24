// Builds dist/: the prerendered pages and the hashed assets, then checks the result (check-dist.ts).
//
//   dist/index.html, app.html, 404.html, docs/index.html, docs/<slug>/index.html
//   dist/install.sh    static/install.sh as it is: the installer, served at https://mopm.dev/install.sh
//   dist/assets/<id>/  the browser modules (build/browser, from tsc) and the stylesheets of static/ (layout.ts says
//                      which page loads which), and tutorial.js (TUTORIAL_BUNDLE): the tutorial's runner bundled with
//                      the e2b SDK, the one asset not loaded as tsc wrote it
//
// tutorial.js is esbuild's bundle of tsc's tutorial/runner.js and what it imports, e2b included: one minified ES module,
// no source map, no path of this machine in it. e2b 2.64.0 imports six node:* modules at the top of its ES module, used
// only by its template builder, so the bundle gives each the empty tutorial/node-stub.js (NODE_STUBS); a new one, or any
// esbuild warning, fails the build. No page of this build loads it: only the tutorial page will (check-dist.ts refuses
// any other page that does), and the tsc modules the other pages load are as they were.
//
// <id> is the first 16 hex digits of a sha256 over the assets' sorted (path, bytes): the same inputs give the same id
// and the same bytes everywhere, with no clock or commit in them, so every stage deploys one artifact and an asset URL
// never serves two contents (the site stack is to cache assets as immutable once it serves this build).

import { createHash } from 'crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { dirname, join, resolve } from 'path';
import { buildSync } from 'esbuild';
import { checkDist, importsOf, INSTALLER, listFiles, TUTORIAL_BUNDLE } from './check-dist';
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
/** The module of tsc's browser output that TUTORIAL_BUNDLE is built from. */
export const TUTORIAL_ENTRY = 'tutorial/runner.js';
/** The empty module (src/tutorial/node-stub.ts) the bundle gives each of NODE_STUBS. */
export const NODE_STUB = 'tutorial/node-stub.js';
/** The node:* modules e2b 2.64.0 imports at the top of its ES module; esbuild for the browser cannot resolve them. */
export const NODE_STUBS = ['node:crypto', 'node:fs', 'node:os', 'node:path', 'node:stream', 'node:url'];
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

/**
 * TUTORIAL_BUNDLE's bytes: TUTORIAL_ENTRY and what it imports, the e2b SDK included, as one minified ES module for the
 * browser, with no source map. Throws on any esbuild error or warning.
 */
export function bundleTutorial(browserDir: string): Buffer {
  for (const m of [TUTORIAL_ENTRY, NODE_STUB]) {
    if (!existsSync(join(browserDir, m))) throw new Error(`build: ${join(browserDir, m)} is missing; run tsc -p tsconfig.browser.json first`);
  }
  const stub = join(browserDir, NODE_STUB);
  const r = buildSync({
    entryPoints: [join(browserDir, TUTORIAL_ENTRY)],
    absWorkingDir: browserDir,
    alias: Object.fromEntries(NODE_STUBS.map((m) => [m, stub])),
    bundle: true,
    format: 'esm',
    platform: 'browser',
    target: 'es2022',
    minify: true,
    sourcemap: false,
    write: false,
    logLevel: 'silent',
  });
  if (r.warnings.length > 0) throw new Error(`build: esbuild warned on ${TUTORIAL_ENTRY}: ${r.warnings.map((w) => w.text).join('; ')}`);
  if (r.outputFiles.length !== 1) throw new Error(`build: esbuild wrote ${r.outputFiles.length} files for ${TUTORIAL_ENTRY}, not one`);
  return Buffer.from(r.outputFiles[0].contents);
}

function write(path: string, data: string | Buffer): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
}

export function buildSite(opts: BuildOptions): { id: string; files: string[]; tutorialBytes: number } {
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
  assets.set(TUTORIAL_BUNDLE, bundleTutorial(opts.browserDir));

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
  write(join(opts.outDir, INSTALLER), readFileSync(join(opts.staticDir, INSTALLER)));

  checkDist(opts.outDir);
  return { id, files: listFiles(opts.outDir), tutorialBytes: (assets.get(TUTORIAL_BUNDLE) as Buffer).length };
}

if (require.main === module) {
  // Compiled to site/build/tools/tools/build.js.
  const site = resolve(__dirname, '..', '..', '..');
  const { id, files, tutorialBytes } = buildSite({
    browserDir: join(site, 'build', 'browser'),
    staticDir: join(site, 'static'),
    repoRoot: resolve(site, '..'),
    outDir: join(site, 'dist'),
  });
  process.stdout.write(`dist: ${files.length} files, assets/${id}/, ${TUTORIAL_BUNDLE} ${tutorialBytes} bytes\n`);
}
