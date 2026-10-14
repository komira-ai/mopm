// T10: the parser does work linear in its input on the inputs that make naive Markdown parsers quadratic. The
// measure is the parser's own step counter (deterministic), not a timer.
import { MAX_DEPTH, parse } from '../src/markdown/parse';

const N = 64 * 1024;
const fill = (unit: string): string => unit.repeat(Math.ceil(N / unit.length)).slice(0, N);

// The bound, in steps per input character, calibrated on these inputs: flat input stays under 5, so 8 leaves room.
// Nested containers are the exception by design: each nesting level sees each of its lines once (a lazy line
// under a 16-deep quote is seen 16 times, about 18 steps per character measured), so those inputs are held to
// MAX_DEPTH + 4. A quadratic step, such as rescanning for a closing backtick run from each opening one, costs
// thousands of steps per character on 64 KiB and fails either bound.
const FLAT = 8;
const NESTED = MAX_DEPTH + 4;

const inputs: [string, string, number?][] = [
  ['open brackets', fill('[')],
  ['open bracket-paren pairs', fill('[](')],
  ['link openers with titles', fill('[a](b "')],
  ['angle destinations', fill('[a](<')],
  ['stars', fill('*')],
  ['alternating stars and letters', fill('*a')],
  ['underscores between punctuation', fill('_!')],
  ['nested emphasis', `${'*a '.repeat(N / 6)}x${' a*'.repeat(N / 6)}`],
  ['backtick runs of growing length', Array.from({ length: 360 }, (_, k) => '`'.repeat(k + 1)).join(' ').slice(0, N)],
  // Openers that never close (every length is unique) with text between them: a parser that looks for each closer
  // by scanning forward walks the rest of the input once per opener.
  ['unclosed backtick runs between text', Array.from({ length: 180 }, (_, k) => '`'.repeat(k + 1) + 'a'.repeat(200)).join('')],
  ['single backticks', fill('`a')],
  ['mixed backtick runs', fill('`` ` ``` `')],
  ['10k nested quotes', '>'.repeat(10_000) + ' x', NESTED],
  ['10k nested quotes, spaced', '> '.repeat(10_000) + 'x', NESTED],
  ['quote lines', fill('>\n')],
  ['deep quote then lazy lines', '>'.repeat(20) + ' a\n' + fill('b\n'), NESTED],
  ['nested list items', Array.from({ length: 2000 }, (_, k) => ' '.repeat(2 * (k % 40)) + '- x').join('\n').slice(0, N), NESTED],
  ['pipes', fill('|')],
  ['table rows of pipes', '|a|b|\n|-|-|\n' + fill('|||\n')],
  ['wide table', '|'.repeat(8000) + '\n' + '-|'.repeat(8000) + '\n' + fill('|x\n')],
  ['raw tag openers', fill('<a')],
  ['autolink openers', fill('<http:')],
  ['backslashes and quotes', fill('\\"')],
  ['parens in destinations', '[a](' + fill('(')],
  ['close parens after bracket pairs', fill('[a](b)')],
  ['hash lines', fill('#\n')],
  ['fence openers', fill('```\n')],
  ['setext-looking lines', fill('a\n=\n')],
];

test.each(inputs)('%s', (_name, src, bound = FLAT) => {
  const { steps } = parse(src);
  expect(steps).toBeLessThanOrEqual(bound * src.length);
});

test('the inputs are full size', () => {
  for (const [name, src] of inputs) expect([name, src.length >= 10_000]).toEqual([name, true]);
});
