// The full version list (/packages/<namespace>/<name>/versions, src/views/versions.ts): every version the API gives, in
// its order, with its state in words and its publish time, under the package's head band whose crumb ends at
// "Versions"; and the claimed-name and no-version shapes.
import { versionsView } from '../src/views/versions';
import { hrefs, html, packageFixture, sdoc, text, uniqueIds } from './view-helpers';

const FN = { namespace: 'komira-ai', name: 'json' };
const AT = '2026-10-13T12:00:00Z';
const render = (info = packageFixture()) => html(versionsView(sdoc, FN, info));

describe('the fixture package', () => {
  const view = versionsView(sdoc, FN, packageFixture());
  const out = html(view);

  test('the title names the list and the package; one h1, the full name', () => {
    expect(view.title).toBe('Versions of komira-ai/json');
    expect(out.match(/<h1>/g)).toHaveLength(1);
    expect(out).toContain('<h1><span class="ns">komira-ai/</span><span>json</span></h1>');
  });

  test('the crumb links Packages, the namespace and the package, and ends at Versions', () => {
    expect(out).toContain(
      '<nav class="crumb" aria-label="Breadcrumb"><a href="/search">Packages</a><span class="sep" aria-hidden="true">/</span><a href="/search?q=komira-ai%2F" class="crumb-pkg">komira-ai</a><span class="sep" aria-hidden="true">/</span><a href="/packages/komira-ai/json" class="crumb-pkg">json</a><span class="sep" aria-hidden="true">/</span><span aria-current="page">Versions</span></nav>',
    );
  });

  test('every version is a row, the yanked one too, with its state as words and a link to its page', () => {
    expect(out).toContain('<caption>Versions of komira-ai/json, newest first</caption>');
    expect(out.match(/<tr class="state-/g)).toHaveLength(2);
    expect(out).toContain('<td>yanked: wrong license text</td>');
    expect(out).toContain('<td>published</td>');
    expect(hrefs(out)).toEqual(expect.arrayContaining(['/packages/komira-ai/json/1.1.0', '/packages/komira-ai/json/1.0.0']));
  });

  test('the count of versions is a fact in the head band; a link leads back to the package page', () => {
    expect(text(out.slice(0, out.indexOf('</header>')))).toContain('2 versions');
    expect(out).toContain('<a href="/packages/komira-ai/json">The package page of komira-ai/json</a>');
  });

  test('no install lines, no side panel, no in-page tabs; ids are unique', () => {
    expect(out).not.toContain('install-card');
    expect(out).not.toContain('<aside');
    expect(out).not.toContain('class="tabs"');
    expect(uniqueIds(out)).toBe(true);
  });
});

// The table is the package page's old one: every version, in the API's order, not grouped and not re-sorted.
test('versions keep the order the API gives, every state in words, a version outside the grammar as text', () => {
  const out = render(
    packageFixture((r) =>
      Object.assign(r, {
        versions: [
          { version: '0.6.0', state: 'tombstoned', published_at: AT },
          { version: '0.5.1', state: 'yanked', yank_reason: null, published_at: AT },
          { version: '0.5.0', state: 'published', published_at: AT },
          { version: '0.5.0-rc.1', state: 'published', published_at: AT },
          { version: '0.4.0', state: 'quarantined', published_at: AT },
        ],
      }),
    ),
  );
  const rows = [...out.matchAll(/<tr class="[^"]+"><th scope="row">(.*?)<\/th><td>(.*?)<\/td><td>(.*?)<\/td><\/tr>/g)].map((m) => [text(m[1]), m[2], m[3]]);
  expect(rows).toEqual([
    ['0.6.0', 'tombstoned (files removed by an administrator)', '<time datetime="2026-10-13T12:00:00Z">2026-10-13 12:00 UTC</time>'],
    ['0.5.1', 'yanked', '<time datetime="2026-10-13T12:00:00Z">2026-10-13 12:00 UTC</time>'],
    ['0.5.0', 'published', '<time datetime="2026-10-13T12:00:00Z">2026-10-13 12:00 UTC</time>'],
    ['0.5.0-rc.1', 'published', '<time datetime="2026-10-13T12:00:00Z">2026-10-13 12:00 UTC</time>'],
    ['0.4.0', 'unknown (quarantined)', '<time datetime="2026-10-13T12:00:00Z">2026-10-13 12:00 UTC</time>'],
  ]);
  expect(out).toContain('<th scope="row"><span>0.5.0-rc.1</span></th>');
  expect(text(out.slice(0, out.indexOf('</header>')))).toContain('5 versions');
});

test('one version: the fact says "1 version"', () => {
  const out = render(packageFixture((r) => Object.assign(r, { versions: [{ version: '1.0.0', state: 'published', published_at: AT }] })));
  expect(text(out.slice(0, out.indexOf('</header>')))).toContain('1 version');
  expect(text(out)).not.toContain('1 versions');
});

test('an active package with no versions says none is published', () => {
  const out = render(packageFixture((r) => Object.assign(r, { latest: null, versions: [] })));
  expect(out).toContain('<p class="muted">No versions are published.</p>');
  expect(out).not.toContain('<table>');
});

test('a claimed name: says it is claimed, no table and no count', () => {
  const out = render(packageFixture((r) => Object.assign(r, { state: 'claimed', latest: null, versions: [] })));
  expect(text(out)).toContain('This name is claimed. Nothing has been published under it yet.');
  expect(out).not.toContain('<table>');
  expect(text(out)).not.toMatch(/\d versions?/);
  expect(out).toContain('<a href="/packages/komira-ai/json">The package page of komira-ai/json</a>');
});

test('the description is text, a hostile one included', () => {
  const out = render(packageFixture((r) => Object.assign(r, { description: '<script>alert(1)</script>' })));
  expect(out).toContain('<p class="lede">&lt;script&gt;alert(1)&lt;/script&gt;</p>');
});
