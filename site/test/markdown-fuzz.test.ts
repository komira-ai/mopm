// T9: on arbitrary Markdown-shaped input the renderer never throws, emits only renderer markup with safe link
// targets, and escapes every '<' that is text (a '<' in the output always starts an allowlisted tag).
import fc from 'fast-check';
import { expectSafe, md, MD_TAGS, tagsOf } from './md';

// Pieces that exercise every construct and every escape path, joined at random.
const piece = fc.oneof(
  fc.constantFrom(
    '*', '**', '_', '__', '`', '``', '[', ']', '(', ')', '![', '<', '>', '&', '"', "'", '\\', '|', '#', '-', '+',
    '1.', '\n', '\n\n', '  \n', '    ', '\t', '> ', '- ', '```', '~~~', '---', '|---|', ':', '/', '#x',
    'javascript:', 'JaVaScRiPt:', 'data:', 'vbscript:', 'https://mopm.dev/', 'mailto:a@mopm.dev', '//evil', 'a@mopm.dev',
    '<script>', '</script>', '<img onerror=x>', 'onerror=', 'style=', '&#115;', '%0a', '\u0000', '​', ' ',
  ),
  fc.string({ maxLength: 6 }),
  fc.fullUnicodeString({ maxLength: 3 }),
);
const markdown = fc.array(piece, { maxLength: 60 }).map((xs) => xs.join(''));

test('never throws; output is allowlisted markup with safe links; text "<" is always escaped', () => {
  fc.assert(
    fc.property(markdown, (src) => {
      const html = md(src);
      // tagsOf throws on a '<' that does not start a well-formed tag, so this also proves text '<' was escaped.
      const tags = tagsOf(html);
      for (const t of tags) expect(MD_TAGS).toContain(t.tag);
      expectSafe(html);
    }),
    { numRuns: 2000, seed: 20261014 },
  );
});
