// T14 (package page): the package view over the contract fixture and the shapes the fixtures do not cover (a claimed
// name, no latest release, a latest mopm cannot name, an unknown state, a hostile readme or repository URL). Every
// value is shown as text; only checked URLs become links; the state of a version is words, not only a class. The page
// leads with mopm's own install lines (`mopm add <namespace>/<name>`, then the mopm.toml line and "then run mopm
// sync"), with pixi and the conda channel under a closed "Other tools (pixi, conda)", then the readme; the side panel
// lists the newest versions with their state.
import { CHANNELS_NOTE, DEP_CHANNELS_NOTE, INSTALL_NOTE, MOPM_INSTALL_PATH, OTHER_TOOLS, packageView, README_MAX_BYTES, SIDE_VERSIONS } from '../src/views/package';
import { PLANNED, WORKING_TODAY } from '../tools/pages';
import { hrefs, html, packageFixture, sdoc, text, uniqueIds } from './view-helpers';

const CTX = { host: 'mopm.dev' };
const FN = { namespace: 'komira-ai', name: 'json' };
const CH = 'https://conda.mopm.dev/komira-ai/';
const CH_CMD = `pixi workspace channel add ${CH}`;
const render = (info = packageFixture(), ctx = CTX) => html(packageView(sdoc, FN, info, ctx));

const rich = (r: Record<string, unknown>) =>
  Object.assign(r, { description: 'JSON parser', license: 'Apache-2.0', repository: 'https://github.com/komira-ai/json' });
/** The commands of the copy boxes in `card`, in order (the text of each `.cmd-lg` row's <code>). */
const commands = (card: string) => [...card.matchAll(/<div class="cmd cmd-lg copy-box">.*?<code>(.*?)<\/code>/g)].map((m) => text(m[1]));
const installCard = (page: string) => page.slice(page.indexOf('<section class="install-card"'), page.indexOf('</section>', page.indexOf('<section class="install-card"')));
const cmdRow = (cmd: string, label: string, describedBy = 'pixi-note') =>
  `<div class="cmd cmd-lg copy-box"><span class="prompt" aria-hidden="true">$</span><pre tabindex="0" role="region" aria-label="${label}" aria-describedby="${describedBy}"><code>${cmd}</code></pre></div>`;

describe('an active package (fixture: package info)', () => {
  const out = render(packageFixture(rich));

  test('one h1 holding the namespace and the name; the title is the full name', () => {
    expect(out.match(/<h1>/g)).toHaveLength(1);
    expect(out).toContain('<h1><span class="ns">komira-ai/</span><span>json</span></h1>');
    expect(text(out.slice(out.indexOf('<h1>'), out.indexOf('</h1>')))).toBe('komira-ai/json');
    expect(packageView(sdoc, FN, packageFixture(), CTX).title).toBe('komira-ai/json');
  });

  test('the crumb links Packages, the namespace search and ends at the name', () => {
    expect(out).toContain(
      '<nav class="crumb" aria-label="Breadcrumb"><a href="/search">Packages</a><span class="sep" aria-hidden="true">/</span><a href="/search?q=komira-ai%2F" class="crumb-pkg">komira-ai</a><span class="sep" aria-hidden="true">/</span><span aria-current="page">json</span></nav>',
    );
  });

  test('the mopm.toml line has the full name as a quoted key and names the latest version as published', () => {
    expect(out).toContain('<code>[dependencies]\n"komira-ai/json" = "1.1.0"</code>');
    expect(out).not.toContain('\njson = ');
  });

  test('the conda channel is the namespace channel of this host and the pixi commands name it', () => {
    expect(out).toContain(`<code>${CH}</code>`);
    expect(out).toContain(`<code>${CH_CMD}</code>`);
    expect(out).toContain('<code>pixi add mojo-komira-ai.json</code>');
    expect(out).not.toContain('<code>https://conda.mopm.dev/</code>');
  });

  // Catches the card leading with pixi again (or any command before mopm's), the mopm.toml line or the mopm install
  // link moved under the <details>, the pixi lines left outside it, the <details> open, or a block copy.ts cannot find
  // (it looks for a .copy-box holding one <pre>).
  test('the first install command is mopm add, then the mopm.toml line and a link to install mopm; pixi and conda sit in a closed <details>', () => {
    const card = installCard(out);
    expect(commands(card)[0]).toBe('mopm add komira-ai/json');
    expect(card.indexOf('<pre')).toBe(card.indexOf('<pre tabindex="0" role="region" aria-label="install command" aria-describedby="install-note"><code>mopm add komira-ai/json</code></pre>'));
    const before = card.slice(0, card.indexOf('<details'));
    expect(before.match(/class="cmd[^"]*copy-box"/g)).toHaveLength(2); // the mopm add command and the mopm.toml lines
    expect(before).toContain(`<p class="install-note" id="install-note">${INSTALL_NOTE}</p>`);
    expect(before).toContain('<div class="cmd copy-box"><pre tabindex="0" role="region" aria-labelledby="snippet-manifest"><code>[dependencies]\n"komira-ai/json" = "1.1.0"</code></pre></div>');
    expect(before.indexOf('mopm add komira-ai/json')).toBeLessThan(before.indexOf('[dependencies]'));
    expect(text(before)).toContain('Or write this line into mopm.toml yourself, then run mopm sync.');
    expect(before).toContain(`<a href="${MOPM_INSTALL_PATH}">Install it</a>`);
    expect(text(before)).toContain('New to mopm? Install it with one command.');
    expect(before).not.toContain('pixi');
    expect(before).not.toContain('conda.');
    const others = card.slice(card.indexOf('<details'));
    expect(others.startsWith(`<details class="other-ways"><summary>${OTHER_TOOLS}</summary>`)).toBe(true);
    expect(OTHER_TOOLS).toBe('Other tools (pixi, conda)');
    expect(commands(others)).toEqual([CH_CMD, 'pixi add mojo-komira-ai.json']);
    expect(others).toContain(cmdRow(CH_CMD, 'pixi channel command'));
    expect(others).toContain(cmdRow('pixi add mojo-komira-ai.json', 'pixi install command'));
    expect(others).toContain(`<p class="install-note" id="pixi-note">In a pixi workspace: add the conda channel of the namespace, <code>${CH}</code>, then the package.</p>`);
    expect(others).toContain(`<div class="cmd copy-box"><pre tabindex="0" role="region" aria-labelledby="snippet-channel"><code>${CH}</code></pre></div>`);
    expect(others).not.toContain('[dependencies]');
    expect(card).not.toContain('<details class="other-ways" open');
    expect(card).not.toContain('<button'); // the page script adds the buttons; a view never does
    expect(uniqueIds(out)).toBe(true);
  });

  // The home page's install block carries id="install" (layout.test.ts holds the built page to it).
  test('the link to install mopm is the home page install block', () => {
    expect(MOPM_INSTALL_PATH).toBe('/#install');
    expect(hrefs(installCard(out))).toContain('/#install');
  });

  test('the package page says a dependency in another namespace needs its channel, and adds no channel of its own for it', () => {
    expect(text(installCard(out))).toContain(text(CHANNELS_NOTE));
    expect(installCard(out)).not.toContain('channel command 2');
    expect(text(out)).not.toContain(text(DEP_CHANNELS_NOTE));
  });

  test('the page reads in order: name, install card, readme, versions table', () => {
    const page = render(packageFixture((r) => Object.assign(r, { readme: '# Usage' })));
    const at = (s: string) => page.indexOf(s);
    expect(at('<h1>')).toBeLessThan(at('class="install-card"'));
    expect(at('class="install-card"')).toBeLessThan(at('id="section-readme"'));
    expect(at('id="section-readme"')).toBeLessThan(at('<table>'));
  });

  test('the head: latest version, description, and the published time of the latest version', () => {
    expect(out).toContain('<span class="ver"><span class="visually-hidden">latest version </span>1.1.0</span>');
    expect(out).toContain('<p class="lede">JSON parser</p>');
    expect(text(out)).toContain('Published 2026-11-10 08:30 UTC');
    expect(text(out)).toContain('License Apache-2.0');
    expect(text(out)).toContain('2 versions');
  });

  test('the side panel lists versions with their state in words and links to the full table', () => {
    const side = out.slice(out.indexOf('<aside'));
    expect(side).toContain('<li class="state-published"><a href="/packages/komira-ai/json/1.1.0">1.1.0</a><span>2026-11-10</span></li>');
    expect(side).toContain('<li class="state-yanked"><a href="/packages/komira-ai/json/1.0.0">1.0.0</a><span>yanked</span></li>');
    expect(side).toContain('<a href="#versions-heading">All 2 versions</a>');
  });

  // The note names only commands README.md says work today or src/cli/main.zig still plans (layout.test.ts pins
  // PLANNED to main.zig), so a command the CLI has since implemented is never called planned here.
  test('the install card names mopm add and mopm sync as working, and names no command the CLI does not have', () => {
    expect(text(installCard(out))).toContain('in a project with a mopm.toml: writes the dependency into it and locks it, as cargo add does');
    expect(text(installCard(out))).toContain('then run mopm sync.');
    expect(text(out)).not.toContain('is planned');
    const named = [...text(out).matchAll(/\bmopm ([a-z-]+)/g)].map((m) => m[1]);
    for (const cmd of named) expect([...WORKING_TODAY, ...PLANNED]).toContain(cmd);
  });

  test('the versions table has a caption with the full name, column headers and the state as text', () => {
    expect(out).toContain('<caption>Versions of komira-ai/json, newest first</caption>');
    expect(out).toContain('<th scope="col">State</th>');
    expect(out).toContain('<td>yanked: wrong license text</td>');
    expect(out).toContain('<td>published</td>');
    expect(hrefs(out)).toEqual(expect.arrayContaining(['/packages/komira-ai/json/1.1.0', '/packages/komira-ai/json/1.0.0']));
  });

  test('the repository is a nofollow link', () => {
    expect(out).toContain('<a href="https://github.com/komira-ai/json" rel="nofollow noopener noreferrer ugc">');
  });

  test('a page served from another stage shows that stage\'s channel of the namespace', () => {
    const beta = render(packageFixture(), { host: 'beta.mopm.dev' });
    expect(beta).toContain('<code>https://conda.beta.mopm.dev/komira-ai/</code>');
    expect(beta).toContain('<code>pixi workspace channel add https://conda.beta.mopm.dev/komira-ai/</code>');
  });

  // Catches a mopm command without --registry on beta or gamma: mopm's default is prod, so a reader copying it would add
  // prod's package of that name (or none) to a project meant for that stage. mopm.dev, the prod site, names none.
  test.each([
    ['mopm.dev', 'mopm add komira-ai/json', 'mopm sync'],
    ['beta.mopm.dev', 'mopm add komira-ai/json --registry beta', 'mopm sync --registry beta'],
    ['gamma.mopm.dev', 'mopm add komira-ai/json --registry gamma', 'mopm sync --registry gamma'],
  ])('on %s the mopm commands name that stage\'s registry', (host, add, sync) => {
    const card = installCard(render(packageFixture(), { host }));
    expect(commands(card)[0]).toBe(add);
    expect(text(card)).toContain(`then run ${sync}.`);
  });

  // Catches a fixed note naming prod's channel beside a command run on another stage: a reader following the visible
  // line would install prod's package of that name.
  test("the line beside the commands names this stage's channel of the namespace", () => {
    for (const host of ['beta.mopm.dev', 'gamma.mopm.dev']) {
      const page = render(packageFixture(), { host });
      const note = page.slice(page.indexOf('<p class="install-note" id="pixi-note"'), page.indexOf('</p>', page.indexOf('<p class="install-note" id="pixi-note"')));
      expect(text(note)).toBe(`In a pixi workspace: add the conda channel of the namespace, https://conda.${host}/komira-ai/, then the package.`);
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

  test('a page on an unknown host shows no channel, no pixi command and no <details>; the mopm lines stand alone, with no --registry', () => {
    const out2 = render(packageFixture(), { host: 'localhost' });
    expect(out2).not.toContain('conda.');
    expect(out2).not.toContain('pixi');
    expect(out2).not.toContain('<details');
    expect(out2).not.toContain('--registry');
    expect(commands(installCard(out2))).toEqual(['mopm add komira-ai/json']);
    expect(text(out2)).not.toContain(text(CHANNELS_NOTE));
    expect(out2).toContain('<code>[dependencies]\n"komira-ai/json" = "1.1.0"</code>');
    expect(hrefs(installCard(out2))).toContain('/#install');
  });
});

describe('a full name the site cannot write into a command', () => {
  test.each([
    ['a namespace with a space', { namespace: 'bad ns', name: 'json' }],
    ['a namespace with an uppercase letter', { namespace: 'Komira', name: 'json' }],
    ['a name with a quote', { namespace: 'komira-ai', name: 'js"on' }],
    ['a name the registry would normalise', { namespace: 'komira-ai', name: 'Json' }],
  ])('%s: no mopm or pixi command, no channel and no mopm.toml line, though the page still renders', (_what, f) => {
    const out = html(packageView(sdoc, f, packageFixture(), CTX));
    expect(out).not.toContain('pixi');
    expect(out).not.toContain('mopm add');
    expect(out).not.toContain('[dependencies]');
    expect(out).not.toContain('cmd-lg');
    expect(out).not.toContain('conda.');
    expect(out.match(/<h1>/g)).toHaveLength(1);
  });
});

describe('the namespace section of the side panel', () => {
  const section = (change: (ns: Record<string, unknown>) => void = () => undefined) => {
    const page = render(packageFixture((r) => change(r.namespace as Record<string, unknown>)));
    const side = page.slice(page.indexOf('<aside'));
    const at = side.indexOf('<section aria-labelledby="side-namespace">');
    return side.slice(at, side.indexOf('</section>', at));
  };

  test('shows the namespace as a link to its packages, the kind and the GitHub account (fixture: an org)', () => {
    const sec = section();
    expect(sec).toContain('<h2 id="side-namespace">Namespace</h2>');
    expect(sec).toContain('<dt>Namespace</dt><dd><a href="/search?q=komira-ai%2F" class="crumb-pkg">komira-ai</a></dd>');
    expect(sec).toContain('<dt>Kind</dt><dd>GitHub organization</dd>');
    expect(sec).toContain('<dt>GitHub</dt><dd><a href="https://github.com/komira-ai" rel="nofollow noopener noreferrer ugc">@komira-ai</a></dd>');
  });

  test.each([
    ['user', 'GitHub user'],
    ['org', 'GitHub organization'],
    ['unknown', 'unknown'],
  ])('the kind %s is labelled %s', (kind, label) => {
    expect(section((ns) => Object.assign(ns, { kind }))).toContain(`<dt>Kind</dt><dd>${label}</dd>`);
  });

  test.each([
    ['upper case', 'Komira-AI'],
    ['a double hyphen', 'komira--ai'],
    ['40 characters', 'a'.repeat(40)],
    ['a slash', 'komira-ai/x'],
  ])('a namespace the registry answers with %s is text, not a link to a search', (_what, namespace) => {
    const sec = section((ns) => Object.assign(ns, { namespace, login: namespace }));
    expect(sec).toContain(`<dt>Namespace</dt><dd>${namespace}</dd>`);
    expect(sec).not.toContain('/search?q=');
  });

  test('a kind the registry newly adds is labelled unknown', () => {
    expect(section((ns) => Object.assign(ns, { kind: 'bot' }))).toContain('<dt>Kind</dt><dd>unknown</dd>');
  });

  test.each([
    ['a plain login', 'alice'],
    ['a login with digits and a single hyphen', 'Alice-99'],
    ['39 characters', 'a'.repeat(39)],
    ['an enterprise-managed login with an underscore', 'alice_corp'],
  ])('%s links to its GitHub page', (_what, login) => {
    const sec = section((ns) => Object.assign(ns, { login }));
    expect(sec).toContain(`<a href="https://github.com/${login}" rel="nofollow noopener noreferrer ugc">@${login}</a>`);
  });

  test.each([
    ['a space', 'bad login'],
    ['a slash', 'a/b'],
    ['40 characters', 'a'.repeat(40)],
    ['a leading hyphen', '-alice'],
    ['a double hyphen', 'al--ice'],
    ['a trailing hyphen', 'alice-'],
    ['a query', 'alice?x=1'],
    ['the empty string', ''],
  ])('a login with %s is shown as text, never a link', (_what, login) => {
    const page = render(packageFixture((r) => Object.assign(r.namespace as Record<string, unknown>, { login })));
    expect(hrefs(page).filter((x) => x.includes('github.com/') && !x.includes('/komira-ai/json'))).toEqual([]);
    const sec = section((ns) => Object.assign(ns, { login }));
    expect(sec).toContain(`<dt>GitHub</dt><dd><span>${login}</span></dd>`);
  });

  test('a login that differs from the namespace only in case says nothing about a rename', () => {
    const sec = section((ns) => Object.assign(ns, { namespace: 'komira-ai', login: 'Komira-AI' }));
    expect(sec).not.toContain('now');
    expect(sec).toContain('@Komira-AI');
  });

  test('a login that differs beyond case says the account was renamed and the namespace keeps its name', () => {
    const sec = section((ns) => Object.assign(ns, { login: 'komira-labs' }));
    expect(text(sec)).toContain('The GitHub account is now komira-labs; the namespace keeps the name komira-ai.');
    expect(sec).toContain('href="https://github.com/komira-labs"');
  });

  test('a renamed login that is not a GitHub login is still named, as text', () => {
    const sec = section((ns) => Object.assign(ns, { login: 'new name' }));
    expect(text(sec)).toContain('The GitHub account is now new name; the namespace keeps the name komira-ai.');
    expect(sec).not.toContain('github.com/new');
  });

  test('a namespace row says nothing about publishing rights', () => {
    const sec = section((ns) => Object.assign(ns, { frozen: true }));
    expect(text(sec)).not.toMatch(/Frozen|GitHub App|publish/i);
  });

  test('the old owners list is gone', () => {
    const page = render();
    expect(page).not.toContain('class="avatar"');
    expect(text(page)).not.toContain('Owners');
  });
});

describe('package shapes the fixtures do not cover', () => {
  test('a claimed name: no install lines, no versions table, says it is claimed', () => {
    const out = render(packageFixture((r) => Object.assign(r, { state: 'claimed', latest: null, versions: [] })));
    expect(out).not.toContain('[dependencies]');
    expect(out).not.toContain('pixi add');
    expect(out).not.toContain('mopm add');
    expect(out).not.toContain('<table>');
    expect(text(out)).toContain('This name is claimed.');
  });

  const AT = '2026-10-13T12:00:00Z';
  // The spec makes latest the newest published version, so a null latest beside a published version is a contract
  // break; the page still offers mopm add (mopm picks the newest version that fits), the channel and pixi, none of which depend on latest.
  test('active with a published version but no latest: no mopm.toml line, a reason; mopm add, the channel and pixi shown', () => {
    const out = render(
      packageFixture((r) => Object.assign(r, { latest: null, versions: [{ version: '1.0.0', state: 'published', published_at: AT }] })),
    );
    expect(out).not.toContain('[dependencies]');
    expect(text(out)).toContain('The registry names no latest version this page can show, so there is no mopm.toml line.');
    expect(out).toContain(`<code>${CH}</code>`);
    expect(out).toContain('<code>pixi add mojo-komira-ai.json</code>');
    expect(commands(installCard(out))[0]).toBe('mopm add komira-ai/json');
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
    expect(out).not.toContain('mopm add');
    expect(out).not.toContain('conda.mopm.dev');
    expect(text(out)).toContain('Nothing can be installed: every version is yanked or its files were removed.');
    expect(out).toContain('<table>');
  });

  test('latest with a part over 2^64-1: no mopm.toml line, the reason; mopm add and pixi still shown', () => {
    const v = '1.18446744073709551616.0';
    const out = render(packageFixture((r) => Object.assign(r, { latest: v })));
    expect(out).not.toContain('[dependencies]');
    expect(text(out)).toContain(`The latest version, ${v}, has a part larger than a mopm.toml requirement allows (2^64-1).`);
    expect(out).toContain('<code>pixi add mojo-komira-ai.json</code>');
    expect(commands(installCard(out))[0]).toBe('mopm add komira-ai/json');
  });

  test.each(['1.0', '1.0rc1'])('latest %s (outside the grammar): no mopm.toml line, not shown as the latest; mopm add and pixi still shown', (v) => {
    const out = render(packageFixture((r) => Object.assign(r, { latest: v })));
    expect(out).not.toContain('[dependencies]');
    expect(render()).toContain('latest version </span>1.1.0'); // the marker the next line looks for
    expect(out).not.toContain('latest version </span>');
    expect(text(out)).toContain('The registry names no latest version this page can show');
    expect(out).toContain('<code>pixi add mojo-komira-ai.json</code>');
    expect(commands(installCard(out))[0]).toBe('mopm add komira-ai/json');
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
    expect(out).toContain(`<code>${CH}</code>`);
    expect(out).toContain('<code>pixi add mojo-komira-ai.json</code>');
    expect(commands(installCard(out))[0]).toBe('mopm add komira-ai/json');
    expect(out).toContain(`<code>[dependencies]\n"komira-ai/json" = "${latest}"</code>`);
    expect(text(out)).not.toContain('Nothing can be installed');
  });

  test('active with no versions at all: no install lines, says no version is published', () => {
    const out = render(packageFixture((r) => Object.assign(r, { latest: null, versions: [] })));
    expect(out).not.toContain('pixi add');
    expect(out).not.toContain('mopm add');
    expect(text(out)).toContain('Nothing can be installed: no version is published.');
  });

  test('an unknown package state: no install lines, as the version page treats an unknown version state', () => {
    const out = render(packageFixture((r) => Object.assign(r, { state: 'frozen' })));
    expect(out).not.toContain('[dependencies]');
    expect(out).not.toContain('pixi add');
    expect(out).not.toContain('mopm add');
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
    expect(side).toContain('<li class="state-tombstoned"><a href="/packages/komira-ai/json/0.7.0">0.7.0</a><span>tombstoned</span></li>');
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
    expect(hrefs(out).filter((h) => !h.startsWith('/') && h !== 'https://github.com/komira-ai' && h !== '#versions-heading')).toEqual([]);
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
    expect(hrefs(out)).not.toContain('/packages/komira-ai/json/..%2Fx');
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
