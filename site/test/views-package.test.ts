// T14 (package page): the package view over the contract fixture and the shapes the fixtures do not cover (a claimed
// name, no latest release, a latest mopm cannot name, an unknown state, a hostile readme or repository URL). Every
// value is shown as text; only checked URLs become links; the state of a version is words, not only a class. The page
// leads with ONE install command (pixi, which installs a published package today), with the others under "Other ways
// to install", then the readme; the side panel lists the newest versions with their state.
import { packageView, README_MAX_BYTES, SIDE_VERSIONS } from '../src/views/package';
import { PLANNED, WORKING_TODAY } from '../tools/pages';
import { hrefs, html, packageFixture, sdoc, text, uniqueIds } from './view-helpers';

const CTX = { host: 'mopm.dev' };
const render = (info = packageFixture(), ctx = CTX) => html(packageView(sdoc, 'http_client', info, ctx));

describe('an active package (fixture: package info)', () => {
  const out = render();

  test('one h1, the name', () => {
    expect(out.match(/<h1>/g)).toHaveLength(1);
    expect(out).toContain('<h1>http_client</h1>');
  });

  test('the mopm.toml line names the latest version as published', () => {
    expect(out).toContain('<code>[dependencies]\nhttp_client = "0.4.0"</code>');
  });

  test('the conda channel of this host and the pixi command are shown', () => {
    expect(out).toContain('<code>https://conda.mopm.dev/</code>');
    expect(out).toContain('<code>pixi add mojo-http_client</code>');
  });

  // Catches: a second command promoted beside pixi, the channel or manifest moved out of the <details>, or a block a
  // copy button cannot find (copy.ts looks for a .copy-box holding one <pre>).
  test('ONE install command comes first, in a copy box, with the other ways in a closed <details>', () => {
    const card = out.slice(out.indexOf('<section class="install-card"'), out.indexOf('</section>', out.indexOf('<section class="install-card"')));
    const before = card.slice(0, card.indexOf('<details'));
    expect(before.match(/class="cmd[^"]*copy-box"/g)).toHaveLength(1);
    expect(before).toContain(
      '<div class="cmd cmd-lg copy-box"><span class="prompt" aria-hidden="true">$</span><pre tabindex="0" role="region" aria-label="install command" aria-describedby="install-note"><code>pixi add mojo-http_client</code></pre></div>',
    );
    expect(before).toContain('<p class="install-note" id="install-note">in a pixi project that lists the channel <code>https://conda.mopm.dev/</code></p>');
    const others = card.slice(card.indexOf('<details'));
    expect(others.startsWith('<details class="other-ways"><summary>Other ways to install</summary>')).toBe(true);
    expect(others).toContain('<div class="cmd copy-box"><pre tabindex="0" role="region" aria-labelledby="snippet-channel"><code>https://conda.mopm.dev/</code></pre></div>');
    expect(others).toContain('<code>[dependencies]\nhttp_client = "0.4.0"</code>');
    expect(card).not.toContain('<button'); // the page script adds the buttons; a view never does
  });

  test('the page reads in order: name, install card, readme, versions table', () => {
    const page = render(packageFixture((r) => Object.assign(r, { readme: '# Usage' })));
    const at = (s: string) => page.indexOf(s);
    expect(at('<h1>')).toBeLessThan(at('class="install-card"'));
    expect(at('class="install-card"')).toBeLessThan(at('id="section-readme"'));
    expect(at('id="section-readme"')).toBeLessThan(at('<table>'));
  });

  test('the head: latest version, description, and the published time of the latest version', () => {
    expect(out).toContain('<span class="ver"><span class="visually-hidden">latest version </span>0.4.0</span>');
    expect(out).toContain('<p class="lede">HTTP/1.1 client</p>');
    expect(text(out)).toContain('Published 2026-10-13 12:00 UTC');
    expect(text(out)).toContain('License Apache-2.0');
    expect(text(out)).toContain('2 versions');
    expect(out).toContain('<nav class="crumb" aria-label="Breadcrumb"><a href="/search">Packages</a>');
  });

  test('the side panel lists versions with their state in words and links to the full table', () => {
    const side = out.slice(out.indexOf('<aside'));
    expect(side).toContain('<li class="state-published"><a href="/packages/http_client/0.4.0">0.4.0</a><span>2026-10-13</span></li>');
    expect(side).toContain('<li class="state-yanked"><a href="/packages/http_client/0.3.0">0.3.0</a><span>yanked</span></li>');
    expect(side).toContain('<a href="#versions-heading">All 2 versions</a>');
  });

  // The note names only commands README.md says work today or src/cli/main.zig still plans (layout.test.ts pins
  // PLANNED to main.zig), so a command the CLI has since implemented is never called planned here.
  test('the install note says mopm add is planned, and names no other command as planned', () => {
    expect(text(out)).toContain('mopm metadata checks this table today; mopm add is planned.');
    const named = [...text(out).matchAll(/\bmopm ([a-z-]+)/g)].map((m) => m[1]);
    for (const cmd of named) expect([...WORKING_TODAY, ...PLANNED]).toContain(cmd);
  });

  test('the versions table has a caption, column headers and the state as text', () => {
    expect(out).toContain('<caption>Versions of http_client, newest first</caption>');
    expect(out).toContain('<th scope="col">State</th>');
    expect(out).toContain('<td>yanked: crashes on empty body</td>');
    expect(out).toContain('<td>published</td>');
    expect(hrefs(out)).toEqual(expect.arrayContaining(['/packages/http_client/0.4.0', '/packages/http_client/0.3.0']));
  });

  test('owners are text, the repository is a nofollow link', () => {
    expect(out).toContain('<li><span class="avatar" aria-hidden="true">OC</span>octocat</li>');
    expect(out).toContain('<a href="https://github.com/example/http_client" rel="nofollow noopener noreferrer ugc">');
  });

  test('a page served from another stage shows that stage\'s channel', () => {
    expect(render(packageFixture(), { host: 'beta.mopm.dev' })).toContain('<code>https://conda.beta.mopm.dev/</code>');
  });

  // Catches a fixed note naming prod's channel beside a command run on another stage: a reader following the visible
  // line would install prod's package of that name.
  test("the line beside the one install command names this stage's channel", () => {
    for (const host of ['beta.mopm.dev', 'gamma.mopm.dev']) {
      const page = render(packageFixture(), { host });
      const note = page.slice(page.indexOf('<p class="install-note"'), page.indexOf('</p>', page.indexOf('<p class="install-note"')));
      expect(text(note)).toBe(`in a pixi project that lists the channel https://conda.${host}/`);
    }
  });

  // Catches the published time read from the newest row (versions[0]) instead of the latest version's row: the newest
  // row here is yanked and a day later.
  test('Published is the time of the latest version, not of a newer yanked row', () => {
    const page = render(
      packageFixture((r) =>
        Object.assign(r, {
          latest: '0.4.0',
          versions: [
            { version: '0.5.0', state: 'yanked', yank_reason: null, published_at: '2026-10-14T00:00:00Z' },
            { version: '0.4.0', state: 'published', published_at: '2026-10-13T12:00:00Z' },
          ],
        }),
      ),
    );
    const head = text(page.slice(0, page.indexOf('</header>')));
    expect(head).toContain('Published 2026-10-13 12:00 UTC');
    expect(head).not.toContain('2026-10-14');
  });

  test('a page on an unknown host shows no channel and no pixi command; the mopm.toml lines stand alone', () => {
    const out2 = render(packageFixture(), { host: 'localhost' });
    expect(out2).not.toContain('conda.');
    expect(out2).not.toContain('pixi add');
    expect(out2).not.toContain('<details');
    expect(out2).toContain('<code>[dependencies]\nhttp_client = "0.4.0"</code>');
  });
});

describe('package shapes the fixtures do not cover', () => {
  test('a claimed name: no install lines, no versions table, says it is claimed', () => {
    const out = render(packageFixture((r) => Object.assign(r, { state: 'claimed', latest: null, versions: [] })));
    expect(out).not.toContain('[dependencies]');
    expect(out).not.toContain('pixi add');
    expect(out).not.toContain('<table>');
    expect(text(out)).toContain('This name is claimed.');
  });

  const AT = '2026-10-13T12:00:00Z';
  // The spec makes latest the newest published version, so a null latest beside a published version is a contract
  // break; the page still offers the channel and pixi, which do not depend on latest.
  test('active with a published version but no latest: no mopm.toml line, a reason, the channel and pixi shown', () => {
    const out = render(
      packageFixture((r) => Object.assign(r, { latest: null, versions: [{ version: '1.0.0', state: 'published', published_at: AT }] })),
    );
    expect(out).not.toContain('[dependencies]');
    expect(text(out)).toContain('The registry names no latest version this page can show, so there is no mopm.toml line.');
    expect(out).toContain('<code>https://conda.mopm.dev/</code>');
    expect(out).toContain('<code>pixi add mojo-http_client</code>');
  });

  // spec/channel.md: a yanked version leaves packages.conda, a tombstoned one loses its bytes; with no published
  // version, `pixi add` has nothing to install, so the page offers no install line.
  test.each([
    ['every version yanked', [{ version: '0.2.0', state: 'yanked', yank_reason: 'bad', published_at: AT }]],
    ['every version tombstoned', [{ version: '0.2.0', state: 'tombstoned', published_at: AT }]],
    [
      'yanked and tombstoned versions only',
      [
        { version: '0.3.0', state: 'tombstoned', published_at: AT },
        { version: '0.2.0', state: 'yanked', yank_reason: null, published_at: AT },
      ],
    ],
  ])('active, %s: no install lines, says nothing can be installed', (_what, versions) => {
    const out = render(packageFixture((r) => Object.assign(r, { latest: null, versions })));
    expect(out).not.toContain('[dependencies]');
    expect(out).not.toContain('pixi add');
    expect(out).not.toContain('conda.mopm.dev');
    expect(text(out)).toContain('Nothing can be installed: every version is yanked or its files were removed.');
    expect(out).toContain('<table>');
  });

  test('latest with a part over 2^64-1: no mopm.toml line, the reason, pixi still shown', () => {
    const v = '1.18446744073709551616.0';
    const out = render(packageFixture((r) => Object.assign(r, { latest: v })));
    expect(out).not.toContain('[dependencies]');
    expect(text(out)).toContain(`The latest version, ${v}, has a part larger than a mopm.toml requirement allows (2^64-1).`);
    expect(out).toContain('<code>pixi add mojo-http_client</code>');
  });

  test.each(['1.0', '1.0rc1'])('latest %s (outside the grammar): no mopm.toml line, not shown as the latest, pixi still shown', (v) => {
    const out = render(packageFixture((r) => Object.assign(r, { latest: v })));
    expect(out).not.toContain('[dependencies]');
    expect(render()).toContain('latest version </span>0.4.0'); // the marker the next line looks for
    expect(out).not.toContain('latest version </span>');
    expect(text(out)).toContain('The registry names no latest version this page can show');
    expect(out).toContain('<code>pixi add mojo-http_client</code>');
  });

  // Any published version makes the package installable, wherever it sits: newest first, the newest is often the
  // yanked or tombstoned one.
  test.each([
    ['the newest yanked', [{ version: '0.5.0', state: 'yanked', yank_reason: 'bad', published_at: AT }, { version: '0.4.0', state: 'published', published_at: AT }]],
    ['the newest tombstoned', [{ version: '0.5.0', state: 'tombstoned', published_at: AT }, { version: '0.4.0', state: 'published', published_at: AT }]],
    [
      'the newest yanked and the oldest tombstoned',
      [
        { version: '0.6.0', state: 'yanked', yank_reason: null, published_at: AT },
        { version: '0.5.0', state: 'published', published_at: AT },
        { version: '0.4.0', state: 'tombstoned', published_at: AT },
      ],
    ],
  ])('active, %s, with another version published: the channel and pixi line are shown', (_what, versions) => {
    const latest = versions.find((v) => v.state === 'published')?.version ?? null;
    const out = render(packageFixture((r) => Object.assign(r, { latest, versions })));
    expect(out).toContain('<code>https://conda.mopm.dev/</code>');
    expect(out).toContain('<code>pixi add mojo-http_client</code>');
    expect(out).toContain(`<code>[dependencies]\nhttp_client = "${latest}"</code>`);
    expect(text(out)).not.toContain('Nothing can be installed');
  });

  test('active with no versions at all: no install lines, says no version is published', () => {
    const out = render(packageFixture((r) => Object.assign(r, { latest: null, versions: [] })));
    expect(out).not.toContain('pixi add');
    expect(text(out)).toContain('Nothing can be installed: no version is published.');
  });

  test('an unknown package state: no install lines, as the version page treats an unknown version state', () => {
    const out = render(packageFixture((r) => Object.assign(r, { state: 'frozen' })));
    expect(out).not.toContain('[dependencies]');
    expect(out).not.toContain('pixi add');
    expect(out).not.toContain('conda.mopm.dev');
    expect(text(out)).toContain('The registry reports a package state this page does not know. Treat this package as not installable.');
    expect(out).toContain('<table>');
  });

  test('every version state is shown as words in the versions table', () => {
    const at = '2026-10-13T12:00:00Z';
    const out = render(
      packageFixture((r) =>
        Object.assign(r, {
          versions: [
            { version: '0.6.0', state: 'tombstoned', published_at: at },
            { version: '0.5.1', state: 'yanked', yank_reason: null, published_at: at },
            { version: '0.5.0', state: 'published', published_at: at },
          ],
        }),
      ),
    );
    expect(out).toContain('<td>tombstoned (files removed by an administrator)</td>');
    expect(out).toContain('<td>yanked</td>');
    expect(out).toContain('<td>published</td>');
    expect(out).toContain('<td><time datetime="2026-10-13T12:00:00Z">2026-10-13 12:00 UTC</time></td>');
  });

  test(`the side panel shows the newest ${SIDE_VERSIONS} versions, tombstoned in words; the table has them all`, () => {
    const at = '2026-10-13T12:00:00Z';
    const versions = ['0.7.0', '0.6.0', '0.5.0', '0.4.0', '0.3.0', '0.2.0', '0.1.0'].map((version, i) => ({ version, state: i === 0 ? 'tombstoned' : 'published', published_at: at }));
    const out = render(packageFixture((r) => Object.assign(r, { latest: '0.6.0', versions })));
    const side = out.slice(out.indexOf('<aside'));
    expect(side.match(/<li class="state-/g)).toHaveLength(SIDE_VERSIONS);
    expect(side).toContain('<li class="state-tombstoned"><a href="/packages/http_client/0.7.0">0.7.0</a><span>tombstoned</span></li>');
    expect(side).not.toContain('0.2.0');
    expect(side).toContain('All 7 versions');
    expect(out.slice(0, out.indexOf('<aside')).match(/<tr class="state-/g)).toHaveLength(7);
  });

  test('a claimed name has no tabs, no version count and no side versions', () => {
    const out = render(packageFixture((r) => Object.assign(r, { state: 'claimed', latest: null, versions: [] })));
    expect(out).not.toContain('class="tabs"');
    expect(text(out)).not.toMatch(/\d versions?/);
    expect(out).not.toContain('side-versions');
  });

  // They are jump links, so none is marked as selected: a permanent "on" would show a selection that does not exist.
  test('jump links to the readme and the versions table only when there is a readme, none marked selected', () => {
    expect(render()).not.toContain('class="tabs"');
    const out = render(packageFixture((r) => Object.assign(r, { readme: '# x' })));
    expect(out).toContain('<nav class="tabs" aria-label="On this page"><a href="#section-readme">Readme</a><a href="#versions-heading">Versions <span class="count">2</span></a></nav>');
    expect(out).not.toContain('class="on"');
  });

  test('an unknown version state is shown with its raw value', () => {
    const out = render(
      packageFixture((r) => Object.assign(r, { versions: [{ version: '0.5.0', state: 'quarantined', published_at: '2026-10-13T12:00:00Z' }] })),
    );
    expect(out).toContain('<td>unknown (quarantined)</td>');
  });

  test('a repository or homepage that is not http(s) is text, never a link', () => {
    const out = render(packageFixture((r) => Object.assign(r, { repository: 'javascript:alert(1)', homepage: 'data:text/html,x' })));
    expect(out).toContain('<span>javascript:alert(1)</span>');
    expect(out).toContain('<span>data:text/html,x</span>');
    // The page's own in-page links (the side panel's link to the versions table) are the only other hrefs.
    expect(hrefs(out).filter((h) => !h.startsWith('/') && !h.startsWith('https://github.com/example/') && h !== '#versions-heading')).toEqual([]);
  });

  test('a mailto: or fragment repository or homepage is text, though readme links may use them', () => {
    const out = render(packageFixture((r) => Object.assign(r, { repository: 'mailto:a@example.com', homepage: '#readme' })));
    expect(out).toContain('<span>mailto:a@example.com</span>');
    expect(out).toContain('<span>#readme</span>');
    expect(hrefs(out).filter((h) => h.startsWith('mailto:') || (h.startsWith('#') && h !== '#versions-heading'))).toEqual([]);
  });

  test('keywords are text', () => {
    const out = render(packageFixture((r) => Object.assign(r, { keywords: ['http', '<b>x</b>'] })));
    expect(out).toContain('<li>http</li><li>&lt;b&gt;x&lt;/b&gt;</li>');
  });

  test('a version that does not match the grammar is not a link', () => {
    const out = render(packageFixture((r) => Object.assign(r, { versions: [{ version: '../x', state: 'published', published_at: '2026-10-13T12:00:00Z' }] })));
    expect(out).toContain('<span>../x</span>');
    expect(hrefs(out)).not.toContain('/packages/http_client/..%2Fx');
  });
});

describe('the readme', () => {
  test('renders with readme- ids, headings below the Readme h2, raw HTML as text', () => {
    const out = render(packageFixture((r) => Object.assign(r, { readme: '# Usage\n\n<script>alert(1)</script>\n\n[x](javascript:alert(1))' })));
    expect(out).toContain('<h2 id="section-readme">Readme</h2><div class="prose"><h3 id="readme-usage">Usage</h3>');
    expect(out).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
    expect(out).not.toContain('<script');
    expect(hrefs(out).some((h) => h.toLowerCase().startsWith('javascript'))).toBe(false);
    expect(out.match(/<h1>/g)).toHaveLength(1);
  });

  test('a readme heading never takes an id the page uses, and an in-readme link reaches the readme heading', () => {
    const out = render(packageFixture((r) => Object.assign(r, { readme: '# Heading\n\n## Readme\n\n#### Section readme\n\n[x](#heading)' })));
    expect(uniqueIds(out)).toBe(true);
    expect(out).toContain('<h3 id="readme-heading">Heading</h3>');
    expect(out).toContain('<h6 id="readme-section-readme">Section readme</h6>');
    expect(hrefs(out)).toContain('#readme-heading');
  });

  test(`over ${README_MAX_BYTES} UTF-8 bytes it is not rendered, and the page says so`, () => {
    // 'é' is two bytes: 32769 of them is over the limit in bytes though under it in characters.
    const out = render(packageFixture((r) => Object.assign(r, { readme: '# big\n' + 'é'.repeat(32769) })));
    expect(text(out)).toContain('larger than 64 KiB');
    expect(out).not.toContain('readme-big');
  });

  test('absent: no readme section', () => {
    expect(render()).not.toContain('Readme');
  });
});
