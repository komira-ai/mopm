// T14 (version page): yanked and tombstoned versions over the contract fixtures; a download link only for a published
// or yanked version and only to the conda channel of the host the page is served on (a tombstoned version never gets
// one, even if a url came with it); a pinned mopm.toml line only for a published version; dependencies link only when
// their name is valid; the address shows the version the registry returned.
import { ADD_CAVEAT_YANKED, versionView } from '../src/views/version';
import { hrefs, html, sdoc, text, uniqueIds, versionFixture } from './view-helpers';

const CTX = { host: 'mopm.dev' };
const CH = 'https://conda.mopm.dev/komira-ai/';
const FILE_URL = `${CH}noarch/mojo-komira-ai.json-1.1.0-mojo1.0.0_0.conda`;
const FN = { namespace: 'komira-ai', name: 'json' };
const installCardOf = (page: string) => page.slice(page.indexOf('<section class="install-card"'), page.indexOf('</section>', page.indexOf('<section class="install-card"')));
const render = (v = versionFixture('version detail'), ctx = CTX, route = FN) => versionView(sdoc, route, v, ctx);
/** Each command row of a page, in order: its label and its command. */
/** Words an install card must not show: another installer, or a conda channel or package to install from. */
const NO_OTHER_TOOL = /pixi|conda|mojo-komira-ai|<details/i;
const cmdRows = (page: string) => [...page.matchAll(/<div class="cmd cmd-lg copy-box">.*?aria-label="([^"]*)"[^>]*><code>([^<]*)<\/code>/g)].map((m) => [m[1], m[2]]);

describe('a published version (fixture: version detail)', () => {
  const view = render();
  const out = html(view);

  test('title and h1 name the version', () => {
    expect(view.title).toBe('komira-ai/json 1.1.0');
    expect(out.match(/<h1>/g)).toHaveLength(1);
    expect(out).toContain('<h1><span class="ns">komira-ai/</span><span>json</span> <span class="ver">1.1.0</span></h1>');
    expect(text(out.slice(out.indexOf('<h1>'), out.indexOf('</h1>')))).toBe('komira-ai/json 1.1.0');
  });

  // The package page's head band: crumb Packages / name / version, the glyph, the state tag, then the facts.
  // Defect caught: the crumb losing the package link; the facts losing the platforms (taken from the files).
  test('the head is the package page\'s: crumb to the package, glyph, state, published, license, Mojo, platforms', () => {
    expect(out).toContain('<header class="page-band pkg-head"><nav class="crumb" aria-label="Breadcrumb"><a href="/search">Packages</a><span class="sep" aria-hidden="true">/</span><a href="/search?q=komira-ai%2F" class="crumb-pkg">komira-ai</a><span class="sep" aria-hidden="true">/</span><a href="/packages/komira-ai/json" class="crumb-pkg">json</a><span class="sep" aria-hidden="true">/</span><span aria-current="page">1.1.0</span></nav>');
    expect(out).toMatch(/<span class="glyph g[012] glyph-lg" aria-hidden="true">js<\/span><h1>/);
    expect(out).toContain('<span class="tag state-published">published</span>');
    const facts = text(out.slice(out.indexOf('<ul class="metarow">'), out.indexOf('</ul>', out.indexOf('<ul class="metarow">'))));
    expect(facts).toMatch(/^Published \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC/);
    expect(facts).toContain('Platform noarch');
  });

  // mopm's own lines, as on the package page, before the files: `mopm add` with the version pinned, then the pinned
  // mopm.toml line, then the link to install mopm, and no other tool. Defect caught: the card moved below the files; a
  // pixi or conda line back in the card; the mopm add command naming no version (it would add the newest, not this
  // one).
  test('the install card is mopm add with the version pinned, the pinned mopm.toml line and the install link: nothing else', () => {
    expect(out.indexOf('class="install-card"')).toBeLessThan(out.indexOf('id="files-heading"'));
    const card = installCardOf(out);
    expect(cmdRows(out)).toEqual([['install command', 'mopm add komira-ai/json@=1.1.0']]);
    expect(card).toContain('aria-label="install command" aria-describedby="install-note"><code>mopm add komira-ai/json@=1.1.0</code>');
    expect(card.indexOf('"komira-ai/json" = "=1.1.0"')).toBeGreaterThan(card.indexOf('mopm add komira-ai/json@=1.1.0'));
    expect(text(card)).toContain('Or write this line into mopm.toml yourself, then run mopm sync.');
    expect(card).toContain('<a href="/#install">Install it</a>');
    expect(card).not.toMatch(NO_OTHER_TOOL);
    expect(card).not.toContain('id="install-caveat"');
    expect(text(out)).not.toMatch(/pixi/i);
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
    expect(out).toContain('<nav class="tabs" aria-label="On this page"><a href="#files-heading">Files <span class="count">1</span></a><a href="#deps-heading">Dependencies <span class="count">0</span></a>');
  });

  test('the mopm.toml line pins the version', () => {
    expect(out).toContain('<code>[dependencies]\n"komira-ai/json" = "=1.1.0"</code>');
  });

  test('the file links to the channel of this host', () => {
    expect(hrefs(out)).toContain(FILE_URL);
    expect(out).toContain('<td class="num" role="cell">4.0 KiB</td>');
  });

  test('a dependency is a full name that links to its page, with its range as text', () => {
    const page = html(render(versionFixture('version detail', (r) => Object.assign(r, { deps: [{ name: 'acme/http_core', range: '>=1.2,<2' }] }))));
    expect(page).toContain('<a href="/packages/acme/http_core">acme/http_core</a><code class="range">&gt;=1.2,&lt;2</code>');
  });

  test('the address is /packages/<namespace>/<name>/<version>', () => {
    expect(view.canonicalPath).toBe('/packages/komira-ai/json/1.1.0');
  });

  // The package page's versions section lists release lines only; every version is on the versions page.
  test('the side panel links to the page of every version of the full name', () => {
    expect(out).toContain('<a href="/packages/komira-ai/json/versions">All versions of komira-ai/json</a>');
  });

  test('the caption of the files table names the full name and the version', () => {
    expect(out).toContain('<caption class="visually-hidden">Files of komira-ai/json 1.1.0</caption>');
  });

  test('provenance and the manifest digest are text', () => {
    const page = html(render(versionFixture('version detail', (r) => Object.assign(r, { provenance: { kind: 'oidc', repository: 'komira-ai/json', workflow_ref: 'komira-ai/json/.github/workflows/release.yml@refs/heads/main' } }))));
    expect(text(page)).toContain('komira-ai/json/.github/workflows/release.yml@refs/heads/main');
    expect(out).toContain('bec06d7f4d2accdf76fca6d972465db912d5467a35cfc63b0efc5fd6b2af3363');
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
    expect(text(out)).toContain('Reason: crashes on empty input');
  });

  test('no pinned mopm.toml line', () => {
    expect(out).not.toContain('[dependencies]');
  });

  test('its files stay downloadable', () => {
    expect(hrefs(out)).toContain(FILE_URL);
  });

  // mopm's resolver refuses a pin on a yanked version (src/core/resolve.zig), so the page must not offer one.
  // Defect caught: 'mopm add komira-ai/json@=<yanked version>', which fails; the caveat missing or not tied to it.
  test('mopm add names no version and says it adds the newest, not this yanked one', () => {
    expect(cmdRows(out)[0]).toEqual(['install command', 'mopm add komira-ai/json']);
    expect(out).not.toContain('mopm add komira-ai/json@');
    expect(out).toContain(`<p class="install-caveat" id="install-caveat">${ADD_CAVEAT_YANKED}</p>`);
    expect(out).toContain('aria-label="install command" aria-describedby="install-note install-caveat"><code>mopm add komira-ai/json</code>');
    expect(text(installCardOf(out))).not.toContain('mopm sync');
    expect(installCardOf(out)).not.toMatch(NO_OTHER_TOOL);
    expect(uniqueIds(out)).toBe(true);
  });

  test('the sidebar state carries the reason', () => {
    expect(out).toContain('<dt>State</dt><dd>yanked: crashes on empty input</dd>');
  });
});

describe('tombstoned (fixture)', () => {
  test('a banner says the files were removed, with the reason code and date', () => {
    const out = html(render(versionFixture('tombstoned version has no url')));
    expect(text(out)).toContain('An administrator removed the files of this version.');
    expect(text(out)).toContain('Reason: malware, on 2026-11-12.');
    expect(out).not.toContain('[dependencies]');
    expect(out).not.toMatch(/pixi/i);
    expect(out).not.toContain('mopm add');
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
    expect(out).toContain('<span class="file">mojo-komira-ai.json-1.1.0-mojo1.0.0_0.conda</span>');
  });
});

describe('download links', () => {
  test('an unknown state: no download link, no install lines, the raw state as text', () => {
    const out = html(render(versionFixture('version detail', (r) => Object.assign(r, { state: 'quarantined' }))));
    expect(hrefs(out).filter((h) => h.includes('conda'))).toEqual([]);
    expect(out).not.toContain('[dependencies]');
    expect(out).not.toMatch(/pixi/i);
    expect(out).not.toContain('mopm add');
    expect(out).not.toContain('conda channel');
    expect(text(out)).toContain('Treat this version as not installable.');
    expect(out).toContain('<dt>State</dt><dd>unknown (quarantined)</dd>');
  });

  test.each([
    ['another stage\'s channel', 'https://conda.beta.mopm.dev/komira-ai/noarch/x.conda'],
    ['plain http', 'http://conda.mopm.dev/komira-ai/noarch/x.conda'],
    ['the site host, not the channel', 'https://mopm.dev/komira-ai/noarch/x.conda'],
    ['another host', 'https://evil-mopm.invalid/komira-ai/noarch/x.conda'],
    ['a host ending in the channel host', 'https://evilconda.mopm.dev/komira-ai/noarch/x.conda'],
    ['a look-alike host', 'https://conda.mopm.dev.evil-mopm.invalid/x.conda'],
    ['a host with a port', 'https://conda.mopm.dev:8443/x.conda'],
    ['credentials in the URL', 'https://user:pw@conda.mopm.dev/x.conda'],
    ['a script URL', 'javascript:alert(1)'],
    ['another namespace\'s channel', 'https://conda.mopm.dev/acme/noarch/x.conda'],
    ['the channel root', 'https://conda.mopm.dev/noarch/x.conda'],
    ['a namespace that only starts with this one', 'https://conda.mopm.dev/komira-ai-labs/noarch/x.conda'],
    ['the channel root of the right host with a dot-dot back out', 'https://conda.mopm.dev/komira-ai/../acme/x.conda'],
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
    const url = 'https://conda.beta.mopm.dev/komira-ai/noarch/x.conda';
    const out = html(render(versionFixture('version detail', (r) => {
      (r.files as Record<string, unknown>[])[0].url = url;
    }), { host: 'beta.mopm.dev' }));
    expect(hrefs(out)).toContain(url);
  });
});

describe('native libraries', () => {
  test('are listed with their id and soname when the version has some, and absent otherwise', () => {
    const page = html(render(versionFixture('version detail', (r) => Object.assign(r, { native: [{ id: 'openssl', soname: 'libssl.so.3' }] }))));
    expect(page).toContain('<h2 id="native-heading">Native libraries</h2>');
    expect(page).toContain('<li><span>openssl</span><code>libssl.so.3</code></li>');
    expect(html(render())).not.toContain('native-heading');
  });
});

describe('names, spellings and unknown values', () => {
  // The version page's own links to its package (the crumb, the package page, its version list) are not dependencies.
  const OWN_PAGES = new Set(['/packages/komira-ai/json', '/packages/komira-ai/json/versions']);

  test.each([
    ['a flat name', 'http_core'],
    ['an uppercase name', 'acme/Http'],
    ['an uppercase namespace', 'Acme/http'],
    ['a name that would be normalised', 'acme/http-core'],
    ['three parts', 'acme/http/core'],
    ['an empty name', 'acme/'],
    ['an empty namespace', '/http'],
  ])('a dependency that is %s is text, not a link', (_what, name) => {
    const out = html(render(versionFixture('version detail', (r) => Object.assign(r, { deps: [{ name }] }))));
    expect(out).toContain(`<li><span>${name}</span></li>`);
    expect(hrefs(out).filter((h) => h.startsWith('/packages/') && !OWN_PAGES.has(h.split('#')[0]))).toEqual([]);
  });

  test('a dependency name that is not a package name is text', () => {
    const out = html(render(versionFixture('version detail', (r) => Object.assign(r, { deps: [{ name: 'Bad-Name' }, { name: 'javascript:x' }] }))));
    expect(out).toContain('<span>Bad-Name</span>');
    expect(out).toContain('<span>javascript:x</span>');
    expect(hrefs(out).filter((h) => h.startsWith('/packages/') && !OWN_PAGES.has(h.split('#')[0]))).toEqual([]);
  });

  test('the address is the version the registry returned', () => {
    const view = render(versionFixture('version detail', (r) => Object.assign(r, { version: '1.0.0' })));
    expect(view.canonicalPath).toBe('/packages/komira-ai/json/1.0.0');
  });

  test('a returned version outside the grammar is not put in the address', () => {
    const view = render(versionFixture('version detail', (r) => Object.assign(r, { version: '../../x' })));
    expect(view.canonicalPath).toBeUndefined();
    expect(html(view)).not.toContain('[dependencies]');
  });

  test.each(['1.0', '1.0rc1', '1.2.3.4'])('a published %s (outside the grammar) gets no pinned line and no install section', (v) => {
    const view = render(versionFixture('version detail', (r) => Object.assign(r, { version: v })));
    expect(html(view)).not.toContain('[dependencies]');
    expect(html(view)).not.toMatch(/pixi/i);
    expect(html(view)).not.toContain('mopm add');
    expect(view.canonicalPath).toBeUndefined();
  });

  test('a published version with a part over 2^64-1 gets no pinned line, and says why', () => {
    const out = html(render(versionFixture('version detail', (r) => Object.assign(r, { version: '1.18446744073709551616.0' }))));
    expect(out).not.toContain('[dependencies]');
    expect(text(out)).toContain('Version 1.18446744073709551616.0 has a part larger than a mopm.toml requirement allows (2^64-1).');
    // mopm cannot pin it either, and an unpinned `mopm add` would add another version: no mopm command at all.
    expect(out).not.toContain('mopm add');
    expect(cmdRows(out)).toEqual([]);
    expect(installCardOf(out)).not.toMatch(NO_OTHER_TOOL);
  });

  test('a published version is pinned as written', () => {
    const out = html(render(versionFixture('version detail', (r) => Object.assign(r, { version: '1.2.0' }))));
    expect(out).toContain('<code>[dependencies]\n"komira-ai/json" = "=1.2.0"</code>');
    expect(cmdRows(out)[0]).toEqual(['install command', 'mopm add komira-ai/json@=1.2.0']);
  });

  // Catches a version page on beta or gamma whose mopm commands omit --registry: mopm would read prod's registry.
  test.each([
    ['beta.mopm.dev', 'mopm add komira-ai/json@=1.1.0 --registry beta', 'mopm sync --registry beta'],
    ['gamma.mopm.dev', 'mopm add komira-ai/json@=1.1.0 --registry gamma', 'mopm sync --registry gamma'],
  ])('on %s the pinned mopm commands name that stage\'s registry', (host, add, sync) => {
    const out = html(render(versionFixture('version detail'), { host }));
    expect(cmdRows(out)[0]).toEqual(['install command', add]);
    expect(text(installCardOf(out))).toContain(`then run ${sync}.`);
  });
});

// Every fixture version has one file, so a table showing only the first, or a head that repeats or miscounts the
// platforms, would pass the tests above. Three files on two platforms, one platform twice. Defect caught: v.files.slice(0, 1)
// in the table; the platforms not deduped (noarch listed twice); 'Platform' for more than one; the Files tab counting
// platforms or rows of one platform.
describe('a version with several files', () => {
  const extra = (subdir: string, n: string) => ({
    filename: `mojo-komira-ai.json-1.1.0-mojo1.0.0_${n}.conda`,
    subdir,
    size: 1024,
    sha256: n.repeat(64).slice(0, 64),
    url: `https://conda.mopm.dev/komira-ai/${subdir}/mojo-komira-ai.json-1.1.0-mojo1.0.0_${n}.conda`,
  });
  const v = versionFixture('version detail', (r) => {
    (r.files as Record<string, unknown>[]).push(extra('osx-arm64', '1'), extra('noarch', '2'));
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
    expect(facts).toContain('Platforms noarch · osx-arm64');
    expect(facts.match(/noarch/g)).toHaveLength(1);
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

// mopm resolves a version's whole closure from the registry's index, so dependencies in other namespaces add nothing
// to the card. Defect caught: a channel line or note per dependency namespace back in the card.
describe('the dependencies and the install card', () => {
  const withDeps = (names: string[], host = 'mopm.dev') =>
    html(render(versionFixture('version detail', (r) => Object.assign(r, { deps: names.map((name) => ({ name })) })), { host }));

  test.each([
    ['none', []],
    ['in the package\'s own namespace', ['komira-ai/xml', 'komira-ai/yaml']],
    ['in other namespaces', ['zeta/a_pkg', 'acme/http', 'komira-ai/xml', 'acme/json', 'zeta/b_pkg']],
    ['outside the grammar', ['http_core', 'Acme/http', 'acme/Http', 'bad ns/x']],
  ])('dependencies %s: the card is the one mopm add command', (_what, deps) => {
    const page = withDeps(deps);
    expect(cmdRows(page)).toEqual([['install command', 'mopm add komira-ai/json@=1.1.0']]);
    expect(installCardOf(page)).not.toMatch(NO_OTHER_TOOL);
    expect(installCardOf(page)).toBe(installCardOf(withDeps([])));
  });

  test('a yanked version with dependencies in other namespaces: the unpinned mopm add only', () => {
    const page = html(render(versionFixture('yanked version keeps its files and says why', (r) => Object.assign(r, { deps: [{ name: 'acme/http' }] }))));
    expect(cmdRows(page)).toEqual([['install command', 'mopm add komira-ai/json']]);
    expect(installCardOf(page)).not.toMatch(NO_OTHER_TOOL);
  });

  test('a tombstoned version has no commands', () => {
    const page = html(render(versionFixture('tombstoned version has no url', (r) => Object.assign(r, { deps: [{ name: 'acme/http' }] }))));
    expect(cmdRows(page)).toEqual([]);
    expect(page).not.toContain('class="install-card"');
  });

  test('on a host outside the table the mopm command stays, with no --registry', () => {
    const page = withDeps(['acme/http'], 'localhost');
    expect(cmdRows(page)).toEqual([['install command', 'mopm add komira-ai/json@=1.1.0']]);
    expect(page).not.toContain('--registry');
    expect(installCardOf(page)).not.toMatch(NO_OTHER_TOOL);
  });
});

describe('a version with several builds', () => {
  const two = () => versionFixture('version detail with two builds');
  const out = html(render(two()));

  test('the Mojo fact and the Requires Mojo row list every build\'s requirement, in order', () => {
    expect(out).toContain('Mojo <strong>==1.0.0 · ==1.2.0</strong>');
    expect(out).toContain('<code>==1.0.0 · ==1.2.0</code>');
  });

  test('the files table, the count and the platforms show the files of every build', () => {
    const v = two();
    const all = v.builds!.flatMap((b) => b.files);
    expect(all.length).toBeGreaterThan(v.files.length);
    for (const f of all) expect(out).toContain(`>${f.filename}<`);
    expect(out.split('class="hash-box copy-box"').length - 1).toBe(all.length);
    expect(out).toContain(`Files <span class="count">${all.length}</span>`);
  });

  test('a version whose builds are absent or empty renders as one with its top-level fields', () => {
    const plain = versionFixture('version detail', (raw) => delete raw.builds);
    const empty = versionFixture('version detail', (raw) => (raw.builds = []));
    const one = versionFixture('version detail');
    expect(one.builds).toHaveLength(1);
    expect(html(render(empty))).toBe(html(render(plain)));
    expect(html(render(one))).toBe(html(render(plain)));
    expect(html(render(plain))).toContain('Mojo <strong>==1.0.0</strong>');
  });
});
