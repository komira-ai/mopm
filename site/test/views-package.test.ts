// T14 (package page): the package view over the contract fixture and the shapes the fixtures do not cover (a claimed
// name, no latest release, a latest mopm cannot name, an unknown state, a hostile readme or repository URL). Every
// value is shown as text; only checked URLs become links; the state of a version is words, not only a class.
import { packageView, README_MAX_BYTES } from '../src/views/package';
import { hrefs, html, packageFixture, sdoc, text } from './view-helpers';

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

  test('the page says registry installs through mopm are planned', () => {
    expect(text(out)).toContain('fetching registry packages (mopm add, mopm sync) is planned');
  });

  test('the versions table has a caption, column headers and the state as text', () => {
    expect(out).toContain('<caption>Versions of http_client, newest first</caption>');
    expect(out).toContain('<th scope="col">State</th>');
    expect(out).toContain('<td>yanked: crashes on empty body</td>');
    expect(out).toContain('<td>published</td>');
    expect(hrefs(out)).toEqual(expect.arrayContaining(['/packages/http_client/0.4.0', '/packages/http_client/0.3.0']));
  });

  test('owners are text, the repository is a nofollow link', () => {
    expect(out).toContain('<li>octocat</li>');
    expect(out).toContain('<a href="https://github.com/example/http_client" rel="nofollow noopener noreferrer ugc">');
  });

  test('a page served from another stage shows that stage\'s channel', () => {
    expect(render(packageFixture(), { host: 'beta.mopm.dev' })).toContain('<code>https://conda.beta.mopm.dev/</code>');
  });

  test('a page on an unknown host shows no channel', () => {
    expect(render(packageFixture(), { host: 'localhost' })).not.toContain('conda.');
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

  test('active with no latest release: no mopm.toml line, a reason, the channel still shown', () => {
    const out = render(packageFixture((r) => Object.assign(r, { latest: null })));
    expect(out).not.toContain('[dependencies]');
    expect(text(out)).toContain('There is no latest release');
    expect(out).toContain('<code>pixi add mojo-http_client</code>');
  });

  test.each(['1.2.3.4', '1.0rc1'])('latest %s: no mopm.toml line, a reason, pixi still shown', (v) => {
    const out = render(packageFixture((r) => Object.assign(r, { latest: v })));
    expect(out).not.toContain('[dependencies]');
    expect(text(out)).toContain('cannot be written as a mopm.toml requirement');
    expect(out).toContain('<code>pixi add mojo-http_client</code>');
  });

  test('an unknown package state: no mopm.toml line', () => {
    const out = render(packageFixture((r) => Object.assign(r, { state: 'frozen' })));
    expect(out).not.toContain('[dependencies]');
    expect(text(out)).toContain('package state this page does not know');
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
    expect(hrefs(out).filter((h) => !h.startsWith('/') && !h.startsWith('https://github.com/example/'))).toEqual([]);
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
  test('renders with readme- ids, headings one level down, raw HTML as text', () => {
    const out = render(packageFixture((r) => Object.assign(r, { readme: '# Usage\n\n<script>alert(1)</script>\n\n[x](javascript:alert(1))' })));
    expect(out).toContain('<h2 id="readme-usage">Usage</h2>');
    expect(out).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
    expect(out).not.toContain('<script');
    expect(hrefs(out).some((h) => h.toLowerCase().startsWith('javascript'))).toBe(false);
    expect(out.match(/<h1>/g)).toHaveLength(1);
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
