// The header's Tutorial entry (tools/layout.ts) and its removal (tools/tutorial-link.ts), which the site stack applies
// to every page of a stage that does not serve the tutorial. Every kind of page has the entry, between Docs and GitHub,
// exactly as TUTORIAL_NAV_ITEM says, so the removal finds it; the removal leaves the rest of the page as it was, and
// refuses a page it cannot make free of links to the tutorial.
import { type PageKind, type PageSpec, renderPage } from '../tools/layout';
import { TUTORIAL_NAV_ID, TUTORIAL_NAV_ITEM, withoutTutorialLink } from '../tools/tutorial-link';

const ASSETS = { base: '/assets/0123456789abcdef/', entry: 'main.js', preload: [] };
const KINDS: readonly PageKind[] = ['home', 'docs', 'app', 'error', 'tutorial'];
const page = (kind: PageKind, more: Partial<PageSpec> = {}): string =>
  renderPage({ title: 'T', description: 'd', kind, path: '/', main: [], ...more }, ASSETS);

/** The site nav's entries, each as its link's text and the attributes of its <a> after href. */
function navOf(html: string): string[] {
  const nav = html.slice(html.indexOf('<nav class="site-nav"'), html.indexOf('</nav>'));
  return [...nav.matchAll(/<li(?: id="([^"]+)")?><a href="[^"]*"([^>]*)>([^<]*)<\/a><\/li>/g)].map((m) => `${m[3]}${m[1] ? `#${m[1]}` : ''}${m[2]}`);
}

describe.each(KINDS)('a %s page', (kind) => {
  const html = page(kind);

  test('has the Tutorial entry after Docs and before GitHub, exactly TUTORIAL_NAV_ITEM, once', () => {
    expect(navOf(html)).toEqual(['Packages', 'Docs', `Tutorial#${TUTORIAL_NAV_ID}`, 'GitHub']);
    expect(html.split(TUTORIAL_NAV_ITEM)).toHaveLength(2);
  });

  test('without it is the same page less the entry: Packages, Docs and GitHub, and no link to /tutorial', () => {
    const out = withoutTutorialLink('p.html', html);
    expect(out).toBe(html.replace(TUTORIAL_NAV_ITEM, ''));
    expect(navOf(out)).toEqual(['Packages', 'Docs', 'GitHub']);
    expect(out).not.toMatch(/href="\/tutorial/);
  });
});

// A tutorial page marks the entry as the docs pages mark Docs: the current page on /tutorial, its parent on a lesson.
// The stack never strips one (a stage without the tutorial uploads no tutorial page), and the removal refuses it.
test('the Tutorial entry is current on the tutorial pages, and only there', () => {
  expect(navOf(page('tutorial', { current: 'tutorial', currentIsTarget: true }))).toEqual(['Packages', 'Docs', `Tutorial#${TUTORIAL_NAV_ID} aria-current="page"`, 'GitHub']);
  expect(navOf(page('tutorial', { current: 'tutorial' }))).toEqual(['Packages', 'Docs', `Tutorial#${TUTORIAL_NAV_ID} aria-current="true"`, 'GitHub']);
  expect(navOf(page('docs', { current: 'docs' }))).toEqual(['Packages', 'Docs aria-current="true"', `Tutorial#${TUTORIAL_NAV_ID}`, 'GitHub']);
  expect(() => withoutTutorialLink('tutorial/index.html', page('tutorial', { current: 'tutorial', currentIsTarget: true }))).toThrow(
    "tutorial/index.html: expected the header's Tutorial entry exactly once, found it 0 times",
  );
});

describe('withoutTutorialLink refuses', () => {
  const html = page('docs');

  test('a page without the entry, or with it twice, naming the page and the count', () => {
    expect(() => withoutTutorialLink('a.html', html.replace(TUTORIAL_NAV_ITEM, ''))).toThrow("a.html: expected the header's Tutorial entry exactly once, found it 0 times");
    expect(() => withoutTutorialLink('b.html', html.replace(TUTORIAL_NAV_ITEM, TUTORIAL_NAV_ITEM.repeat(2)))).toThrow(
      "b.html: expected the header's Tutorial entry exactly once, found it 2 times",
    );
  });

  // A link to the tutorial elsewhere on the page would lead to the 404 page just the same.
  test.each(['/tutorial', '/tutorial/hello', '/tutorial?x=1', '/tutorial#top'])('a page that links to %s elsewhere', (href) => {
    const linked = html.replace('</main>', `<a href="${href}">go</a></main>`);
    expect(() => withoutTutorialLink('c.html', linked)).toThrow('c.html: links to /tutorial outside the header\'s Tutorial entry');
  });

  // Boundary: what only looks like a tutorial link is not one.
  test.each(['/tutorials', '/docs/tutorial/', '/api/v2/auth/web/start?return_to=%2Ftutorial'])('nothing for a link to %s', (href) => {
    const linked = html.replace('</main>', `<a href="${href}">go</a></main>`);
    expect(withoutTutorialLink('d.html', linked)).toBe(linked.replace(TUTORIAL_NAV_ITEM, ''));
  });
});
