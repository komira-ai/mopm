// docs/examples.md quotes the files of examples/, and only those, and every one of them: a block of the page is its file
// byte for byte, a file that is not on the page is an example nobody can read, and a block that quotes no file is text
// that nothing keeps true. The examples are run by the built mopm in the CI (tests/drivers/examples_test.zig, the Buck2
// target //:examples), so the page, the files and the program cannot drift apart. It fails on: a character of a file
// changed; a file added under examples/; a block deleted from the page; a block that quotes a path that is no file; a
// section dropped.
import { readdirSync, readFileSync, statSync } from 'fs';
import { join } from 'path';
import { REPO_ROOT } from './build-fixture';

const page = readFileSync(join(REPO_ROOT, 'docs/examples.md'), 'utf8');

/** The files under `dir` (relative to the repository root, '/'-separated), sorted. */
function filesUnder(rel: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(join(REPO_ROOT, rel)).sort()) {
    const p = `${rel}/${name}`;
    if (statSync(join(REPO_ROOT, p)).isDirectory()) out.push(...filesUnder(p));
    else out.push(p);
  }
  return out;
}

/** A block of the page: a bold code-span path, a blank line, a fenced block. */
const BLOCK = /^\*\*`(examples\/[^`]+)`\*\*\n\n```([A-Za-z]*)\n([\s\S]*?)\n```$/gm;
const blocks = [...page.matchAll(BLOCK)].map((m) => ({ path: m[1], lang: m[2], text: m[3] }));
const files = filesUnder('examples');
const sorted = (a: string[]) => [...a].sort();

test('the page quotes the examples, and the examples are there', () => {
  expect(files.length).toBeGreaterThan(30);
  expect(blocks.length).toBeGreaterThan(30);
});

test.each(blocks.map((b) => [b.path, b] as const))('the block for %s is that file, byte for byte', (path, b) => {
  const want = readFileSync(join(REPO_ROOT, path), 'utf8');
  expect(want.endsWith('\n') && !want.endsWith('\n\n')).toBe(true);
  expect(`${b.text}\n`).toBe(want);
});

test('every file under examples/ is quoted on the page, once', () => {
  expect(sorted(blocks.map((b) => b.path))).toEqual(sorted(files));
});

test('a bold path of the page is always the head of a block', () => {
  // A path in bold that the block pattern did not take up is a block whose fence is missing or misplaced.
  const bold = [...page.matchAll(/^\*\*`(examples\/[^`]+)`\*\*$/gm)].map((m) => m[1]);
  expect(sorted(bold)).toEqual(sorted(blocks.map((b) => b.path)));
});

test('each block names a language its file name implies', () => {
  const lang: Record<string, string> = { toml: 'toml', mojo: 'mojo', json: 'json', lock: 'json', txt: 'text', md: 'markdown' };
  for (const b of blocks) expect([b.path, b.lang]).toEqual([b.path, lang[b.path.slice(b.path.lastIndexOf('.') + 1)]]);
});

// Six examples, one section each, in the order the page counts them; each directory of examples/ is one of them, and the
// section tells the reader to `cd` into it.
test('the page has a numbered section for each example directory, and says to cd into it', () => {
  const dirs = readdirSync(join(REPO_ROOT, 'examples')).sort();
  expect(dirs).toEqual(['app', 'greeter', 'publish', 'testing', 'toolchain', 'workspace']);
  const sections = [...page.matchAll(/^## (\d+)\. .+$/gm)].map((m) => Number(m[1]));
  expect(sections).toEqual([1, 2, 3, 4, 5, 6]);
  for (const d of dirs) expect([d, page.includes(`cd examples/${d}\n`)]).toEqual([d, true]);
});

// The commands the page shows are the ones the CI runs: each `mopm ...` line of a shell block is a command of the
// driver, by its verb. A verb the page shows and the driver never runs is an example nobody ran.
test('every mopm command of the page is one the driver runs', () => {
  const driver = readFileSync(join(REPO_ROOT, 'tests/drivers/examples_test.zig'), 'utf8');
  const shell = [...page.matchAll(/```sh\n([\s\S]*?)```/g)].flatMap((m) => m[1].split('\n'));
  const commands = shell.filter((l) => l.startsWith('mopm '));
  expect(commands.length).toBeGreaterThan(10);
  for (const c of commands) {
    const words = c.split(' ').slice(1).filter((w) => !w.startsWith('-') && !w.includes('/') && !w.includes('='));
    const verb = words[0];
    expect([c, driver.includes(`"${verb}"`)]).toEqual([c, true]);
  }
});
