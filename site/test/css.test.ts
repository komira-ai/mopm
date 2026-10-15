// static/site.css: the contrast and focus rules a stylesheet edit could quietly break. Form controls (the search
// fields, the sort select, buttons) have a border at least 3:1 against the page and header backgrounds in light and
// dark (WCAG 1.4.11); body, muted and link text and the primary button's label are at least 4.5:1 (WCAG 1.4.3); every
// colour token is redefined for dark mode, so no light colour leaks into it; and the focus ring does not reshape what
// it outlines.
import { readFileSync } from 'fs';
import { join } from 'path';

const css = readFileSync(join(__dirname, '..', 'static', 'site.css'), 'utf8');

/** The custom properties of the first ':root {' block at or after `from`. */
function tokens(from: number): Record<string, string> {
  const start = css.indexOf(':root {', from);
  const body = css.slice(start, css.indexOf('}', start));
  return Object.fromEntries([...body.matchAll(/(--[a-z0-9-]+):\s*(#[0-9a-f]{6});/g)].map((m) => [m[1], m[2]]));
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

// The Copy button is a control: a --border-strong edge is 1.4:1 on the code background (WCAG 1.4.11 asks 3:1).
test('the Copy button uses the control border', () => {
  expect(rule('.copy')).toContain('border: 1px solid var(--control-border);');
});

// The current section in the header nav needs a cue that is not only colour: the pill is about 1:1 on the header and
// the text colour change about 1.5:1, so without a bar or underline the current item looks like the others.
test('the current header nav item is marked by an underline or a bar, not by colour alone', () => {
  expect(rule('.site-nav a[aria-current]')).toMatch(/(box-shadow: inset 0 -2px 0 var\(--accent\)|text-decoration: underline)/);
});

// The label goes from "Copy" to "Copied" and back; a button sized by its text would grow and re-wrap the command
// beside it, moving everything below. A fixed minimum wide enough for "Copied" keeps the layout still.
test('the Copy button has a minimum width, so the Copied label does not reflow the command', () => {
  expect(rule('.copy')).toMatch(/min-width: \d/);
  expect(rule('.copy')).toContain('text-align: center;');
});

// The hero search input drops its own outline, so the box around it must carry a ring as strong as :focus-visible's,
// not only a 1px border colour change.
test('the hero search box shows a focus ring when its field is focused', () => {
  expect(rule('.big-search:focus-within')).toMatch(/box-shadow: 0 0 0 3px /);
});

// The build commands are the first a reader runs; on a phone a hidden horizontal scroll would cut them off.
test('on narrow screens the hero build commands wrap instead of scrolling out of sight', () => {
  const media = css.slice(css.indexOf('@media (max-width: 40rem)'));
  expect(media.slice(0, media.indexOf('\n}\n'))).toMatch(/\.cmd-xl code \{[^}]*white-space: pre-wrap;[^}]*overflow-wrap: anywhere;/);
});

// The package head's links jump within the page; nothing styles one as the selected tab.
test('no tab-selection style is left for the jump links, and no fake tab shape for the planned installer', () => {
  expect(css).not.toContain('.tabs a.on');
  expect(css).not.toMatch(/\.seg\b/);
  expect(rule('.cmd-xl')).not.toContain('border-radius: 0 ');
});

test('the focus ring sets no border-radius (it would override a code block\'s rounded corners)', () => {
  expect(rule(':focus-visible')).toContain('outline: 3px solid var(--focus);');
  expect(rule(':focus-visible')).not.toContain('border-radius');
});

test.each([
  ['light', light],
  ['dark', dark],
])('%s: text is at least 4.5:1 where it sits', (_scheme, t) => {
  for (const bg of ['--bg', '--bg-soft', '--surface', '--surface-2', '--bg-code']) {
    expect(contrast(t['--fg'], t[bg])).toBeGreaterThanOrEqual(7);
    expect(contrast(t['--fg-muted'], t[bg])).toBeGreaterThanOrEqual(4.5);
    expect(contrast(t['--link'], t[bg])).toBeGreaterThanOrEqual(4.5);
  }
  // The primary button's label sits on a gradient between these two.
  expect(contrast(t['--accent-fg'], t['--btn-top'])).toBeGreaterThanOrEqual(4.5);
  expect(contrast(t['--accent-fg'], t['--btn-bottom'])).toBeGreaterThanOrEqual(4.5);
  expect(contrast(t['--accent-strong'], t['--accent-soft'])).toBeGreaterThanOrEqual(4.5);
});

test('every colour token of the light theme is redefined for dark', () => {
  const darkOnly = tokens(css.indexOf('@media (prefers-color-scheme: dark)'));
  expect(Object.keys(light).length).toBeGreaterThan(20);
  expect(Object.keys(light).filter((k) => !(k in darkOnly))).toEqual([]);
});

// The home page's recent list prerenders a line for readers without scripts; it must stay hidden when scripts run.
test('the no-script line is hidden unless scripting is off, and the loading line is hidden when it is', () => {
  expect(rule('.no-js')).toContain('display: none;');
  const media = css.slice(css.indexOf('@media (scripting: none)'));
  expect(media.slice(0, media.indexOf('}\n}'))).toMatch(/\.no-js \{ display: block; \}[\s\S]*\.js-only, \.loading \{ display: none;/);
});
