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
    expect(out).toContain('<h1>http_client <span class="ver">0.4.0</span></h1>');
    expect(text(out.slice(out.indexOf('<h1>'), out.indexOf('</h1>')))).toBe('http_client 0.4.0');
  });

  // The package page's head band: crumb Packages / name / version, the glyph, the state tag, then the facts.
  // Defect caught: the crumb losing the package link; the facts losing the platforms (taken from the files).
  test('the head is the package page\'s: crumb to the package, glyph, state, published, license, Mojo, platforms', () => {
    expect(out).toContain('<header class="page-band pkg-head"><nav class="crumb" aria-label="Breadcrumb"><a href="/search">Packages</a><span class="sep" aria-hidden="true">/</span><a href="/packages/http_client" class="crumb-pkg">http_client</a><span class="sep" aria-hidden="true">/</span><span aria-current="page">0.4.0</span></nav>');
    expect(out).toMatch(/<span class="glyph g[012] glyph-lg" aria-hidden="true">hc<\/span><h1>/);
    expect(out).toContain('<span class="tag state-published">published</span>');
    const facts = text(out.slice(out.indexOf('<ul class="metarow">'), out.indexOf('</ul>', out.indexOf('<ul class="metarow">'))));
    expect(facts).toMatch(/^Published \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC/);
    expect(facts).toContain('Platform linux-64');
  });

  // One install command first, as on the package page, before the files; the mopm.toml pin and the channel under
  // "Other ways". Defect caught: the card moved below the files; a second command shown outside the details.
  test('one install command leads the page, before the files, with the pin under Other ways', () => {
    expect(out.indexOf('class="install-card"')).toBeLessThan(out.indexOf('id="files-heading"'));
    expect(out.match(/<div class="cmd cmd-lg copy-box">/g)).toHaveLength(1);
    const details = out.slice(out.indexOf('<details class="other-ways">'));
    expect(details).toContain('http_client = "=0.4.0"');
    expect(out.indexOf('http_client = "=0.4.0"')).toBeGreaterThan(out.indexOf('<details class="other-ways">'));
  });

  // Each digest is a copy box the page script gives a Copy button, named for its file through a hidden label. The
  // digest wraps, so its <pre> is no tab stop and no region. Defect caught: the digest back to plain text (no box); a box with
  // an unnamed <pre> (its button would read "Copy command"); tabindex or role=region back on the <pre>.
  test('each file\'s SHA-256 sits in its own named copy box, with no extra tab stop', () => {
    const v = versionFixture('version detail');
    v.files.forEach((f, i) => {
      expect(out).toContain(`<td class="sha" role="cell"><span id="sha-label-${i}" hidden="">SHA-256 of ${f.filename}</span><div class="hash-box copy-box"><pre aria-labelledby="sha-label-${i}"><code class="hash">${f.sha256}</code></pre></div></td>`);
    });
    expect(out.split('class="hash-box copy-box"').length - 1).toBe(v.files.length);
    expect(out).not.toMatch(/<pre[^>]*(tabindex|role)="[^"]*"[^>]*><code class="hash">/);
  });

  test('jump links to the files and dependencies, with their counts', () => {
    expect(out).toContain('<nav class="tabs" aria-label="On this page"><a href="#files-heading">Files <span class="count">1</span></a><a href="#deps-heading">Dependencies <span class="count">1</span></a>');
  });

  test('the mopm.toml line pins the version', () => {
    expect(out).toContain('<code>[dependencies]\nhttp_client = "=0.4.0"</code>');
  });

  test('the file links to the channel of this host', () => {
    expect(hrefs(out)).toContain(FILE_URL);
    expect(out).toContain('<td class="num" role="cell">120.6 KiB</td>');
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
    expect(text(out)).toContain('This installs the newest version, not necessarily this one.');
    expect(out).toContain('aria-describedby="install-note install-caveat"');
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
    expect(text(out)).toContain('This installs the newest version, not this yanked one.');
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
    ['another host', 'https://evil-mopm.invalid/linux-64/x.conda'],
    ['a host ending in the channel host', 'https://evilconda.mopm.dev/linux-64/x.conda'],
    ['a look-alike host', 'https://conda.mopm.dev.evil-mopm.invalid/x.conda'],
    ['a host with a port', 'https://conda.mopm.dev:8443/x.conda'],
    ['credentials in the URL', 'https://user:pw@conda.mopm.dev/x.conda'],
    ['a script URL', 'javascript:alert(1)'],
  ])('a url on %s is not a link', (_what, url) => {
    const out = html(render(versionFixture('version detail', (r) => {
      (r.files as Record<string, unknown>[])[0].url = url;
    })));
    // In-page jump links ('#files-heading') and same-site paths are the page's own.
    expect(hrefs(out).filter((h) => !h.startsWith('/') && !h.startsWith('#') && !h.startsWith('https://github.com/example/'))).toEqual([]);
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
    expect(hrefs(out).filter((h) => h.startsWith('/packages/') && h.split('#')[0] !== '/packages/http_client')).toEqual([]);
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

// Every fixture version has one file, so a table showing only the first, or a head that repeats or miscounts the
// platforms, would pass the tests above. Three files on two platforms, one platform twice. Defect caught: v.files.slice(0, 1)
// in the table; the platforms not deduped (linux-64 listed twice); 'Platform' for more than one; the Files tab counting
// platforms or rows of one platform.
describe('a version with several files', () => {
  const extra = (subdir: string, n: string) => ({
    filename: `mojo-http_client-0.4.0-mojo1.0.0_${n}.conda`,
    subdir,
    size: 1024,
    sha256: n.repeat(64).slice(0, 64),
    url: `https://conda.mopm.dev/${subdir}/mojo-http_client-0.4.0-mojo1.0.0_${n}.conda`,
  });
  const v = versionFixture('version detail', (r) => {
    (r.files as Record<string, unknown>[]).push(extra('osx-arm64', '1'), extra('linux-64', '2'));
  });
  const out = html(render(v));

  test('one row, one named copy box and one Copy label per file', () => {
    expect(v.files).toHaveLength(3);
    const tbody = out.slice(out.indexOf('<tbody role="rowgroup">'), out.indexOf('</tbody>'));
    expect(tbody.match(/<tr role="row">/g)).toHaveLength(3);
    v.files.forEach((f, i) => {
      expect(tbody).toContain(`<span id="sha-label-${i}" hidden="">SHA-256 of ${f.filename}</span><div class="hash-box copy-box"><pre aria-labelledby="sha-label-${i}"><code class="hash">${f.sha256}</code></pre></div>`);
      expect(hrefs(tbody)).toContain(f.url);
    });
    expect(uniqueIds(out)).toBe(true);
  });

  test('the head lists each platform once, as Platforms, and the Files tab counts every file', () => {
    const facts = text(out.slice(out.indexOf('<ul class="metarow">'), out.indexOf('</ul>', out.indexOf('<ul class="metarow">'))));
    expect(facts).toContain('Platforms linux-64 · osx-arm64');
    expect(facts.match(/linux-64/g)).toHaveLength(1);
    expect(out).toContain('<a href="#files-heading">Files <span class="count">3</span></a>');
  });
});

// The spec says files has minItems 1, but the decoder accepts files: [] (the registry is not trusted to keep its own
// schema), so the empty branch is reachable. Defect caught: the guard `v.files.length === 0` changed so it never fires -> an
// empty Files table (a region with a header row and no rows) where the 'No files.' line should be.
describe('a version with no files', () => {
  const v = versionFixture('version detail', (r) => {
    r.files = [];
  });
  const out = html(render(v));

  test('says No files. and renders no Files table or region', () => {
    expect(v.files).toHaveLength(0);
    expect(out).toContain('<p class="muted">No files.</p>');
    expect(out).not.toContain('role="table"');
    expect(out).not.toContain('aria-label="Files"');
    expect(out).not.toContain('<table');
  });
});
