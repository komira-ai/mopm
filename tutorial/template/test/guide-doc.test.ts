// docs/tutorial-author-guide.md shows the files of guide/ as its code: each file appears once in a ```ts block whose
// first line names it, word for word, so the code a reader copies is the code `npm run typecheck` checks against the
// pinned e2b and the guide-*.test.ts files run. The guide's code is for a browser: it imports only e2b and its own
// files.
import { readdirSync, readFileSync } from 'fs';
import { join } from 'path';
import { REPO_ROOT } from './fixture';

const GUIDE_DIR = join(__dirname, '..', 'guide');
const DOC = join(REPO_ROOT, 'docs', 'tutorial-author-guide.md');
const NAME_LINE = /^\/\/ (tutorial\/template\/guide\/[a-z-]+\.ts)$/;

/** The ```ts blocks of a Markdown text, each without its fences. */
export function tsBlocks(markdown: string): string[] {
  const blocks: string[] = [];
  let open: string[] | null = null;
  for (const line of markdown.split('\n')) {
    if (open === null) {
      if (line === '```ts') open = [];
    } else if (line === '```') {
      blocks.push(open.join('\n') + '\n');
      open = null;
    } else {
      open.push(line);
    }
  }
  return blocks;
}

/** What differs between the doc's named blocks and the files (path -> text); empty when they agree. */
export function snippetProblems(markdown: string, files: ReadonlyMap<string, string>): string[] {
  const problems: string[] = [];
  const seen = new Map<string, number>();
  for (const block of tsBlocks(markdown)) {
    const m = NAME_LINE.exec(block.split('\n')[0]);
    if (m === null) continue;
    const path = m[1];
    seen.set(path, (seen.get(path) ?? 0) + 1);
    const file = files.get(path);
    if (file === undefined) problems.push(`${path}: shown in the doc, but there is no such file`);
    else if (file !== block) problems.push(`${path}: the doc's block differs from the file`);
  }
  for (const path of files.keys()) {
    const n = seen.get(path) ?? 0;
    if (n !== 1) problems.push(`${path}: shown ${n} times in the doc, not once`);
  }
  return problems;
}

function guideFiles(): Map<string, string> {
  const files = new Map<string, string>();
  for (const name of readdirSync(GUIDE_DIR).sort()) {
    files.set(`tutorial/template/guide/${name}`, readFileSync(join(GUIDE_DIR, name), 'utf8'));
  }
  return files;
}

describe('the guide and its files', () => {
  test('every file of guide/ is shown once in the guide, word for word', () => {
    const files = guideFiles();
    expect([...files.keys()]).toEqual([
      'tutorial/template/guide/editor.ts',
      'tutorial/template/guide/sandbox.ts',
      'tutorial/template/guide/terminal.ts',
    ]);
    expect(snippetProblems(readFileSync(DOC, 'utf8'), files)).toEqual([]);
  });

  test('each file starts with the line that names it', () => {
    for (const [path, text] of guideFiles()) expect(text.split('\n')[0]).toBe(`// ${path}`);
  });

  test("the guide's code imports only e2b and its own files", () => {
    for (const [path, text] of guideFiles()) {
      const from = [...text.matchAll(/ from '([^']+)'/g)].map((m) => m[1]);
      expect({ path, from: from.filter((f) => f !== 'e2b' && !/^\.\/[a-z-]+$/.test(f)) }).toEqual({ path, from: [] });
    }
  });
});

describe('snippetProblems', () => {
  const A = 'tutorial/template/guide/a.ts';
  const B = 'tutorial/template/guide/b.ts';
  const fileA = `// ${A}\nexport const a = 1;\n`;
  const fileB = `// ${B}\nexport const b = 2;\n`;
  const fence = (body: string) => '```ts\n' + body + '```\n';
  const files = new Map([
    [A, fileA],
    [B, fileB],
  ]);

  test('agrees when each file is shown once as it is, whatever else the doc holds', () => {
    const doc = `# Guide\n\n${fence(fileA)}\ntext\n\n${fence('const unnamed = 0;\n')}\n\`\`\`sh\nnpm test\n\`\`\`\n${fence(fileB)}`;
    expect(snippetProblems(doc, files)).toEqual([]);
  });

  test('a block that differs from its file is reported', () => {
    const doc = fence(fileA.replace('= 1', '= 3')) + fence(fileB);
    expect(snippetProblems(doc, files)).toEqual([`${A}: the doc's block differs from the file`]);
  });

  test('a file the doc does not show is reported', () => {
    expect(snippetProblems(fence(fileA), files)).toEqual([`${B}: shown 0 times in the doc, not once`]);
  });

  test('a file shown twice is reported', () => {
    expect(snippetProblems(fence(fileA) + fence(fileA) + fence(fileB), files)).toEqual([`${A}: shown 2 times in the doc, not once`]);
  });

  test('a named block with no file is reported', () => {
    const C = 'tutorial/template/guide/c.ts';
    expect(snippetProblems(fence(fileA) + fence(fileB) + fence(`// ${C}\n`), files)).toEqual([
      `${C}: shown in the doc, but there is no such file`,
    ]);
  });

  test('an unclosed block is not a block', () => {
    expect(tsBlocks('```ts\nconst x = 1;\n')).toEqual([]);
  });
});
