// Nothing of the local preview reaches a deployed stage. dist/ ships src/main.ts and the modules it imports
// (tools/build.ts, moduleGraph), and the tutorial bundle of src/tutorial/runner.ts with what it imports and E2B's SDK
// (tools/build.ts, bundleTutorial), all compiled by tsconfig.browser.json from src/ alone: so the preview
// (tools/preview.ts) is never compiled for the browser, and main.js's modules do not include the tutorial gate. The site stack's test
// checks the real build too (service/infra/stacks/test/site.test.ts: no file of dist/ names E2B or its key, and the
// tutorial bundle, E2B's SDK, carries none of the preview's own text).
import { readFileSync } from 'fs';
import { join } from 'path';
import { ENTRY, moduleGraph } from '../tools/build';
import { listFiles } from '../tools/check-dist';

const SITE = join(__dirname, '..');
const SRC = join(SITE, 'src');

/** The browser modules tsc would write for src/, by output name ('x.js'), with their TypeScript source. */
function browserModules(): Map<string, Buffer> {
  const out = new Map<string, Buffer>();
  for (const f of listFiles(SRC)) if (f.endsWith('.ts')) out.set(f.replace(/\.ts$/, '.js'), readFileSync(join(SRC, f)));
  return out;
}

test('only src/ is compiled for the browser, so no module of tools/ can be in dist/', () => {
  const browser = JSON.parse(readFileSync(join(SITE, 'tsconfig.browser.json'), 'utf8')) as { include: string[]; compilerOptions: { rootDir: string } };
  expect(browser.include).toEqual(['src']);
  expect(browser.compilerOptions.rootDir).toBe('src');
  for (const [m, src] of browserModules()) expect([m, /from\s*['"](\.\.\/)+tools\//.test(src.toString('utf8'))]).toEqual([m, false]);
});

test("the modules dist/ ships do not include the tutorial gate, and none names E2B's create call or its key", () => {
  const modules = browserModules();
  const shipped = [ENTRY, ...moduleGraph(modules, ENTRY)];
  expect(shipped).toContain('host.js');
  expect(shipped.filter((m) => m.startsWith('tutorial/'))).toEqual([]);
  for (const m of shipped) {
    const text = (modules.get(m) as Buffer).toString('utf8');
    expect([m, /E2B_API_KEY|api\.e2b\.app|\/v2\/sandboxes/.test(text)]).toEqual([m, false]);
  }
});

test('the check above sees a module that would import the gate', () => {
  const modules = browserModules();
  modules.set(ENTRY, Buffer.from("import { httpGate } from './tutorial/gate.js';\n"));
  expect(moduleGraph(modules, ENTRY)).toContain('tutorial/gate.js');
});
