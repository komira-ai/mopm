// Readme marker comments (test/fixtures/marker-comments.json): a comment that starts with a marker word, `mojo-hidden`
// or any `<lang>-hidden`, `include` or `not-tested`, renders nothing and leaves the fence after it whole, on the package
// page as in the renderer; a comment with no marker word renders as any comment does; a marker word inside code stays
// text. The vectors are written from komira's rule (docs/design/documentation_tests.md, "Include, fill and
// freshness") until komira publishes its own file for it.
import { readFileSync } from 'fs';
import { join } from 'path';
import { serialize, StringDoc } from '../src/doc';
import { readmeSection } from '../src/views/package';
import { md } from './md';

interface Vector {
  name: string;
  markdown: string;
  marker: string | null;
  html: string;
}

const VECTORS: Vector[] = JSON.parse(readFileSync(join(__dirname, 'fixtures', 'marker-comments.json'), 'utf8')).vectors;
const MARKED = VECTORS.filter((v) => v.marker !== null);
const UNMARKED = VECTORS.filter((v) => v.marker === null);

// The marker words, as the rule spells them: `<lang>-hidden` for any language word, `include`, `not-tested`, each ending
// at a space, a ':' or the comment's end.
const MARKER_WORD = /^(?:[a-z0-9+#]+(?:-[a-z0-9+#]+)*-hidden|include|not-tested)(?=[ \t\r\n:]|--|$)/;

describe('readme marker comments', () => {
  // The first two tests lint the fixture, not the renderer: they keep the file complete and true to the rule.
  test('the vectors cover every marker word, comments with none, and marker words inside code', () => {
    const words = new Set(MARKED.map((v) => v.marker));
    for (const w of ['mojo-hidden', 'include', 'not-tested']) expect(words).toContain(w);
    // `<lang>-hidden` for a language other than Mojo.
    expect([...words].some((w) => w !== 'mojo-hidden' && w!.endsWith('-hidden'))).toBe(true);
    expect(UNMARKED.some((v) => /^<!--/.test(v.markdown))).toBe(true);
    expect(UNMARKED.some((v) => v.markdown.startsWith('```') || v.markdown.startsWith('~~~'))).toBe(true);
    expect(new Set(VECTORS.map((v) => v.name)).size).toBe(VECTORS.length);
  });

  // A marked vector's comment opens with its word, and the word is a marker word.
  test.each(MARKED.map((v) => [v.name, v] as const))('%s: the comment starts with a marker word', (_name, v) => {
    expect(v.marker).toMatch(MARKER_WORD);
    expect(v.markdown).toMatch(new RegExp(`<!--[ \\t\\r\\n]*${v.marker!.replace(/[+]/g, '\\+')}(?=[ \\t\\r\\n:]|--)`));
  });

  // The renderer: its exact output, so the comment shows nothing and the fence after it renders whole.
  test.each(VECTORS.map((v) => [v.name, v] as const))('%s', (_name, v) => {
    expect(md(v.markdown)).toBe(v.html);
  });

  test('on the package page, a readme of every marked vector shows no marker word and no comment', () => {
    const readme = MARKED.map((v) => v.markdown).join('\n');
    const doc = new StringDoc();
    const section = readmeSection(doc, readme);
    expect(section).not.toBeNull();
    const out = serialize([section!]);
    for (const w of new Set(MARKED.map((v) => v.marker!))) expect(out).not.toContain(w);
    expect(out).not.toContain('&lt;!--');
    expect(out).not.toContain('<!--');
    expect(out.match(/<pre tabindex="0">/g)).toHaveLength(MARKED.length);
  });
});
