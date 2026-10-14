// T17: the site's source has no HTML or code sink. Markup is built through the Doc port only (src/doc.ts); a string
// of HTML never reaches the DOM, and no string is ever run as code. CSP Trusted Types enforces the same in browsers.
import { readdirSync, readFileSync, statSync } from 'fs';
import { join } from 'path';

const SRC = join(__dirname, '..', 'src');

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    return statSync(p).isDirectory() ? files(p) : [p];
  });
}

const SINKS: [string, RegExp][] = [
  ['innerHTML', /innerHTML/],
  ['outerHTML', /outerHTML/],
  ['insertAdjacentHTML', /insertAdjacentHTML/],
  ['document.write', /document\s*\.\s*write/],
  ['eval', /\beval\s*\(/],
  ['new Function', /\bnew\s+Function\b/],
  ['createContextualFragment', /createContextualFragment/],
  ['DOMParser', /DOMParser|parseFromString/],
  ['srcdoc', /srcdoc/],
  ['string timer', /set(?:Timeout|Interval)\s*\(\s*['"`]/],
];

const sources = files(SRC).filter((f) => f.endsWith('.ts'));

test('there are sources to scan', () => {
  expect(sources.length).toBeGreaterThanOrEqual(10);
});

test.each(SINKS)('no %s anywhere in src', (_name, re) => {
  const hits = sources.filter((f) => re.test(readFileSync(f, 'utf8')));
  expect(hits).toEqual([]);
});
