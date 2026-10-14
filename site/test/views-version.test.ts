// T14 (version page): yanked and tombstoned versions over the contract fixtures; a download link only for a published
// or yanked version and only to the conda channel of the host the page is served on (a tombstoned version never gets
// one, even if a url came with it); a pinned mopm.toml line only for a published version; dependencies link only when
// their name is valid; the address shows the version the registry returned.
import { versionView } from '../src/views/version';
import { hrefs, html, sdoc, text, uniqueIds, versionFixture } from './view-helpers';

const CTX = { host: 'mopm.dev' };
const FILE_URL = 'https://conda.mopm.dev/linux-64/mojo-http_client-0.4.0-mojo1.0.0_0.conda';
const render = (v = versionFixture('version detail'), ctx = CTX, route = 'http_client') => versionView(sdoc, route, v, ctx);

describe('a published version (fixture: version detail)', () => {
  const view = render();
  const out = html(view);

  test('title and h1 name the version', () => {
    expect(view.title).toBe('http_client 0.4.0');
    expect(out.match(/<h1>/g)).toHaveLength(1);
    expect(out).toContain('<h1>http_client 0.4.0</h1>');
  });

  test('the mopm.toml line pins the version', () => {
    expect(out).toContain('<code>[dependencies]\nhttp_client = "=0.4.0"</code>');
  });

  test('the file links to the channel of this host', () => {
    expect(hrefs(out)).toContain(FILE_URL);
    expect(out).toContain('<td class="num">120.6 KiB</td>');
  });

  test('a dependency with a valid name links to its page, with its range as text', () => {
    expect(out).toContain('<a href="/packages/http_core">http_core</a><code class="range">&gt;=1.2,&lt;2</code>');
  });

  test('provenance and the manifest digest are text', () => {
    expect(text(out)).toContain('example/http_client/.github/workflows/release.yml@refs/tags/v0.4.0');
    expect(out).toContain('2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae');
  });

  test('the pixi line says it installs the newest version, which may not be this one', () => {
    expect(out).toContain('<code>pixi add mojo-http_client</code>');
    expect(text(out)).toContain('pixi, in a project that lists the channel (installs the newest version, not necessarily this one)');
  });

  test('the sidebar shows the state and the publish time in UTC', () => {
    expect(out).toContain('<dt>State</dt><dd>published</dd>');
    expect(out).toMatch(/<dt>Published<\/dt><dd><time datetime="[^"]+">\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC<\/time>/);
  });

  test('no banner for a published version', () => {
    expect(out).not.toContain('role="note"');
  });

  test('every id on the page is unique, with a readme whose headings repeat the page\'s', () => {
    const v = versionFixture('version detail', (r) => Object.assign(r, { readme: '# Heading\n\n## Files\n\n## Install' }));
    const page = html(render(v));
    expect(page).toContain('<h3 id="readme-heading">Heading</h3>');
    expect(uniqueIds(page)).toBe(true);
    expect(uniqueIds(out)).toBe(true);
  });

  test('readme_html from the server is never shown', () => {
    expect(out).not.toContain('An HTTP client.');
  });
});

describe('yanked (fixture)', () => {
  const out = html(render(versionFixture('yanked version keeps its files and says why')));

  test('a banner gives the reason', () => {
    expect(text(out)).toContain('Yanked.');
    expect(text(out)).toContain('Reason: crashes on empty body');
  });

  test('no pinned mopm.toml line', () => {
    expect(out).not.toContain('[dependencies]');
  });

  test('its files stay downloadable', () => {
    expect(hrefs(out)).toContain(FILE_URL);
  });

  test('the pixi line says it does not install this yanked version', () => {
    expect(text(out)).toContain('(installs the newest version, not this yanked one)');
  });

  test('the sidebar state carries the reason', () => {
    expect(out).toContain('<dt>State</dt><dd>yanked: crashes on empty body</dd>');
  });
});

describe('tombstoned (fixture)', () => {
  test('a banner says the files were removed, with the reason code and date', () => {
    const out = html(render(versionFixture('tombstoned version has no url')));
    expect(text(out)).toContain('An administrator removed the files of this version.');
    expect(text(out)).toContain('Reason: malware, on 2026-10-14.');
    expect(out).not.toContain('[dependencies]');
    expect(out).not.toContain('pixi add');
    expect(out).not.toContain('conda channel');
    expect(out).toContain('<dt>State</dt><dd>tombstoned (files removed by an administrator)</dd>');
  });

  test('no download link, even when a url is injected into the answer', () => {
    const v = versionFixture('tombstoned version has no url', (r) => {
      (r.files as Record<string, unknown>[])[0].url = FILE_URL;
    });
    expect(v.files[0].url).toBe(FILE_URL);
    const out = html(render(v));
    expect(hrefs(out).filter((h) => h.includes('conda'))).toEqual([]);
    expect(out).toContain('<span class="file">mojo-http_client-0.4.0-mojo1.0.0_0.conda</span>');
  });
});

describe('download links', () => {
  test('an unknown state: no download link, no install lines, the raw state as text', () => {
    const out = html(render(versionFixture('version detail', (r) => Object.assign(r, { state: 'quarantined' }))));
    expect(hrefs(out).filter((h) => h.includes('conda'))).toEqual([]);
    expect(out).not.toContain('[dependencies]');
    expect(out).not.toContain('pixi add');
    expect(out).not.toContain('conda channel');
    expect(text(out)).toContain('Treat this version as not installable.');
    expect(out).toContain('<dt>State</dt><dd>unknown (quarantined)</dd>');
  });

  test.each([
    ['another stage\'s channel', 'https://conda.beta.mopm.dev/linux-64/x.conda'],
    ['plain http', 'http://conda.mopm.dev/linux-64/x.conda'],
    ['the site host, not the channel', 'https://mopm.dev/linux-64/x.conda'],
    ['another host', 'https://evilmopm.dev/linux-64/x.conda'],
    ['a look-alike host', 'https://conda.mopm.dev.evilmopm.dev/x.conda'],
    ['a host with a port', 'https://conda.mopm.dev:8443/x.conda'],
    ['credentials in the URL', 'https://user:pw@conda.mopm.dev/x.conda'],
    ['a script URL', 'javascript:alert(1)'],
  ])('a url on %s is not a link', (_what, url) => {
    const out = html(render(versionFixture('version detail', (r) => {
      (r.files as Record<string, unknown>[])[0].url = url;
    })));
    expect(hrefs(out).filter((h) => !h.startsWith('/') && !h.startsWith('https://github.com/example/'))).toEqual([]);
  });

  test('on an unknown host no file links and no channel', () => {
    const out = html(render(versionFixture('version detail'), { host: 'localhost' }));
    expect(hrefs(out).filter((h) => h.includes('conda'))).toEqual([]);
    expect(out).not.toContain('conda channel');
  });

  test('a beta page links beta channel files', () => {
    const url = 'https://conda.beta.mopm.dev/linux-64/x.conda';
    const out = html(render(versionFixture('version detail', (r) => {
      (r.files as Record<string, unknown>[])[0].url = url;
    }), { host: 'beta.mopm.dev' }));
    expect(hrefs(out)).toContain(url);
  });
});

describe('names, spellings and unknown values', () => {
  test('a dependency name that is not a package name is text', () => {
    const out = html(render(versionFixture('version detail', (r) => Object.assign(r, { deps: [{ name: 'Bad-Name' }, { name: 'javascript:x' }] }))));
    expect(out).toContain('<span>Bad-Name</span>');
    expect(out).toContain('<span>javascript:x</span>');
    expect(hrefs(out).filter((h) => h.startsWith('/packages/') && h !== '/packages/http_client')).toEqual([]);
  });

  test('the address is the version the registry returned', () => {
    const view = render(versionFixture('version detail', (r) => Object.assign(r, { version: '1.0.0' })));
    expect(view.canonicalPath).toBe('/packages/http_client/1.0.0');
  });

  test('a returned version outside the grammar is not put in the address', () => {
    const view = render(versionFixture('version detail', (r) => Object.assign(r, { version: '../../x' })));
    expect(view.canonicalPath).toBeUndefined();
    expect(html(view)).not.toContain('[dependencies]');
  });

  test.each(['1.0', '1.0rc1', '1.2.3.4'])('a published %s (outside the grammar) gets no pinned line and no install section', (v) => {
    const view = render(versionFixture('version detail', (r) => Object.assign(r, { version: v })));
    expect(html(view)).not.toContain('[dependencies]');
    expect(html(view)).not.toContain('pixi add');
    expect(view.canonicalPath).toBeUndefined();
  });

  test('a published version with a part over 2^64-1 gets no pinned line, and says why', () => {
    const out = html(render(versionFixture('version detail', (r) => Object.assign(r, { version: '1.18446744073709551616.0' }))));
    expect(out).not.toContain('[dependencies]');
    expect(text(out)).toContain('Version 1.18446744073709551616.0 has a part larger than a mopm.toml requirement allows (2^64-1).');
  });

  test('a published version is pinned as written', () => {
    const out = html(render(versionFixture('version detail', (r) => Object.assign(r, { version: '1.2.0' }))));
    expect(out).toContain('<code>[dependencies]\nhttp_client = "=1.2.0"</code>');
  });
});
