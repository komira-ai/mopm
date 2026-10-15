// static/site.css: the contrast and focus rules a stylesheet edit could quietly break. Form controls (the search
// fields, the sort select, buttons) have a border at least 3:1 against the page and header backgrounds in light and
// dark (WCAG 1.4.11); body, muted and link text and the primary button's label are at least 4.5:1 (WCAG 1.4.3); every
// colour token is redefined for dark mode, so no light colour leaks into it; and the focus ring does not reshape what
// it outlines.
import { readFileSync } from 'fs';
import { join } from 'path';
import { AREA_STYLESHEETS } from '../tools/layout';

const css = readFileSync(join(__dirname, '..', 'static', 'site.css'), 'utf8');
/** The home page's area stylesheet: the hero's build-command block lives there. */
const homeCss = readFileSync(join(__dirname, '..', 'static', 'home.css'), 'utf8');

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

/** The declarations of the rule whose selector list is exactly `selector` (in site.css unless `sheet` is given). */
function rule(selector: string, sheet = css): string {
  const i = sheet.indexOf(`\n${selector} {`);
  if (i < 0) throw new Error(`no rule '${selector}'`);
  return sheet.slice(i, sheet.indexOf('}', i));
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
  const media = homeCss.slice(homeCss.indexOf('@media (max-width: 40rem)'));
  expect(media.slice(0, media.indexOf('\n}\n'))).toMatch(/\.cmd-xl code \{[^}]*white-space: pre-wrap;[^}]*overflow-wrap: anywhere;/);
});

// The package head's links jump within the page; nothing styles one as the selected tab.
test('no tab-selection style is left for the jump links, and no fake tab shape for the planned installer', () => {
  expect(css).not.toContain('.tabs a.on');
  expect(css).not.toMatch(/\.seg\b/);
  expect(rule('.cmd-xl', homeCss)).not.toContain('border-radius: 0 ');
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

// The area stylesheets (tools/layout.ts AREA_STYLESHEETS) build on site.css's tokens and never define their own, so
// light and dark stay in one place and every area follows a token change.
describe('the area stylesheets', () => {
  const areas = ['home.css', 'package.css', 'search.css', 'docs.css'].map((f) => [f, readFileSync(join(__dirname, '..', 'static', f), 'utf8')] as const);
  const defined = new Set([...css.matchAll(/(--[a-z0-9-]+):/g)].map((m) => m[1]));

  // Mutant: a misspelt token in an area sheet (var(--fg-mutd)) silently falls back to the inherited colour.
  test.each(areas)('%s uses only custom properties site.css defines', (_f, text) => {
    const used = [...text.matchAll(/var\((--[a-z0-9-]+)/g)].map((m) => m[1]);
    expect(used.length).toBeGreaterThan(0);
    expect(used.filter((v) => !defined.has(v))).toEqual([]);
  });

  // Mutant: an area sheet with its own :root or dark block, which the dark-token test above would never see.
  test.each(areas)('%s defines no tokens and no colour scheme of its own', (_f, text) => {
    expect(text).not.toMatch(/:root|prefers-color-scheme|--[a-z0-9-]+\s*:/);
  });

  test('site.css also uses only the custom properties it defines', () => {
    const used = [...css.matchAll(/var\((--[a-z0-9-]+)/g)].map((m) => m[1]);
    expect(used.filter((v) => !defined.has(v))).toEqual([]);
  });
});

// The app shell paints the header (with its search) before it knows the view; a sheet it links that hides the header
// search or nav once a view mounts moves the whole page up after the network answer, and drops a reader's focus or typing
// in the header box. Mutant: `body:has(.search-band) .site-search { display: none; }` back in search.css.
test('the app shell links the package and search sheets', () => {
  expect([...AREA_STYLESHEETS.app].sort()).toEqual(['package.css', 'search.css']);
});
test.each([...AREA_STYLESHEETS.app])('%s (linked by the app shell) never hides the header search or nav', (f) => {
  const sheet = readFileSync(join(__dirname, '..', 'static', f), 'utf8');
  expect(sheet).not.toMatch(/\.site-(search|nav)\b[^{]*\{[^}]*(display:\s*none|visibility:\s*hidden)/);
});

// Every docs page has an on-this-page list, at every width: below 76rem it is a block above the article, not hidden.
// Mutant: `.toc { display: none; }` back, shown only in the wide media query.
test('the docs on-this-page list is shown at every width', () => {
  const docsCss = readFileSync(join(__dirname, '..', 'static', 'docs.css'), 'utf8');
  expect(rule('.toc', docsCss)).not.toMatch(/display:\s*none/);
  expect(docsCss).not.toMatch(/\.toc\b[^{,]*\{[^}]*display:\s*none/);
});

// The shared crumb rule serves the docs pages too, whose current item is a page title in prose type; monospace belongs
// to package and version names only. Mutant: font-family: var(--mono) back on the shared .crumb [aria-current].
test('only the package head sets its crumb\'s current item in monospace', () => {
  const pkgCss = readFileSync(join(__dirname, '..', 'static', 'package.css'), 'utf8');
  expect(rule('.crumb [aria-current]')).not.toContain('font-family');
  expect(rule('.pkg-head .crumb [aria-current]', pkgCss)).toContain('font-family: var(--mono);');
});

// The header is sticky, so an in-page link (the docs on-this-page list and heading anchors, the version page's Files and
// Dependencies tabs to #files-heading and #deps-heading, the package page's #section-readme and #versions-heading)
// scrolls its target to the viewport top, under the header, unless the target has a scroll margin at least the header's
// height. Every one of those targets is an element with an id, so one shared [id] rule covers them all, on every page
// (the 404 page loads site.css alone). The header measured in headless Chrome: 104px tall from 320px to below 48rem (two
// rows: brand and nav, then the search; 106px from 25rem), 65px from 48rem. Mutants: the [id] rule removed (a heading
// lands at top 0, hidden); the token below the narrow header (a docs heading's top 18px hidden at 88px); an area sheet
// with its own fixed scroll-margin-top that beats [id] on specificity (docs.css's old `.doc h2 { scroll-margin-top: 88px }`).
describe('anchor targets clear the sticky header', () => {
  const sheets = [['site.css', css] as const, ...['home.css', 'package.css', 'search.css', 'docs.css'].map((f) => [f, readFileSync(join(__dirname, '..', 'static', f), 'utf8')] as const)];
  const px = (v: string | undefined): number => Number(/^(\d+)px$/.exec(v ?? '')?.[1] ?? NaN);
  const narrow = px(/--header-h:\s*([^;]+);/.exec(rule(':root'))?.[1]);
  const wideBlock = css.slice(css.indexOf('@media (min-width: 48rem) { :root {'));
  const wide = px(/--header-h:\s*([^;]+);/.exec(wideBlock.slice(0, wideBlock.indexOf('}')))?.[1]);

  test('every element with an id has a scroll margin of the header height plus a gap', () => {
    expect(rule('[id]')).toContain('scroll-margin-top: calc(var(--header-h) + 16px);');
  });

  test('the header-height token is at least the measured header, narrow and wide', () => {
    expect(narrow).toBeGreaterThanOrEqual(106);
    expect(wide).toBeGreaterThanOrEqual(65);
    expect(wide).toBeLessThan(narrow);
  });

  // The 106px holds only while brand and nav share the first row. Untightened they need 353px of content, so they wrap
  // (a third row, 151px, measured at 360 and 375) below a 385px viewport; the max-width rule tightens them to 286px,
  // which fits the 288px content box of a 320px viewport. Mutants: the tightening rule removed, or its breakpoint set
  // under 385px (24rem = 384px wraps at 384), or above the wide breakpoint; the nav padding or gap put back.
  test('below the width where brand and nav would wrap, a rule tightens them onto one row', () => {
    const m = /@media \(max-width: ([\d.]+)rem\) \{\n  \.bar \{ column-gap: 8px; \}([\s\S]*?)\n\}/.exec(css);
    expect(m).not.toBeNull();
    const px = Number(m?.[1]) * 16;
    expect(px).toBeGreaterThanOrEqual(385);
    expect(px).toBeLessThan(48 * 16);
    expect(m?.[2]).toContain('.site-nav ul { gap: 0; }');
    expect(m?.[2]).toContain('.site-nav a { padding: 6px; font-size: 0.875rem; }');
    expect(m?.[2]).toContain('.brand { font-size: 1.2rem; gap: 8px; }');
    expect(rule(':root')).toContain('holds from a 320px viewport up');
  });

  test.each(sheets)('%s sets no scroll margin but the shared one, and offsets sticky columns by the token', (f, text) => {
    const margins = [...text.matchAll(/scroll-margin-top:\s*([^;]+);/g)].map((m) => m[1]);
    expect(margins).toEqual(f === 'site.css' ? ['calc(var(--header-h) + 16px)'] : []);
    const stickyTops = [...text.matchAll(/position: sticky; top: ([^;]+);/g)].map((m) => m[1]);
    expect(stickyTops.filter((t) => t !== '0' && !t.includes('var(--header-h)'))).toEqual([]);
  });
});
