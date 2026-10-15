// static/site.css: the contrast and focus rules a stylesheet edit could quietly break. Form controls (the search
// fields, the sort select, buttons) have a border at least 3:1 against the page and header backgrounds in light and
// dark (WCAG 1.4.11), and the focus ring does not reshape what it outlines.
import { readFileSync } from 'fs';
import { join } from 'path';

const css = readFileSync(join(__dirname, '..', 'static', 'site.css'), 'utf8');

/** The custom properties of the first ':root {' block at or after `from`. */
function tokens(from: number): Record<string, string> {
  const start = css.indexOf(':root {', from);
  const body = css.slice(start, css.indexOf('}', start));
  return Object.fromEntries([...body.matchAll(/(--[a-z-]+):\s*(#[0-9a-f]{6});/g)].map((m) => [m[1], m[2]]));
}

function luminance(hex: string): number {
  const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((x) => (x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4));
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

function contrast(a: string, b: string): number {
  const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
}

/** The declarations of the rule whose selector list is exactly `selector`. */
function rule(selector: string): string {
  const i = css.indexOf(`\n${selector} {`);
  if (i < 0) throw new Error(`no rule '${selector}'`);
  return css.slice(i, css.indexOf('}', i));
}

const light = tokens(0);
const dark = { ...light, ...tokens(css.indexOf('@media (prefers-color-scheme: dark)')) };

test.each([
  ['light', light],
  ['dark', dark],
])('%s: the control border is at least 3:1 on the page and the header background', (_scheme, t) => {
  expect(contrast(t['--control-border'], t['--bg'])).toBeGreaterThanOrEqual(3);
  expect(contrast(t['--control-border'], t['--bg-soft'])).toBeGreaterThanOrEqual(3);
});

test('search fields, selects and buttons use the control border', () => {
  expect(rule('input[type="search"],\nselect')).toContain('border: 1px solid var(--control-border);');
  expect(rule('.button')).toContain('border: 1px solid var(--control-border);');
});

test('the focus ring sets no border-radius (it would override a code block\'s rounded corners)', () => {
  expect(rule(':focus-visible')).toContain('outline: 3px solid var(--focus);');
  expect(rule(':focus-visible')).not.toContain('border-radius');
});

test('a .home-wide section spans every column of the home grid', () => {
  expect(rule('.home-wide')).toContain('grid-column: 1 / -1;');
});
