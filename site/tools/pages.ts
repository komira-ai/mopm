// The prerendered pages that are not docs: the home page, the 404 page and the app shell.
//
// The home page says only what README.md says: its opening sentence word for word, the commands that work today, the
// build from source (there is no installer yet, so the page marks it planned), and the planned commands
// (src/cli/main.zig). Its "Recently published" list is an empty slot the page script fills from the registry
// (src/views/recent.ts): no package is baked into the page. There is no featured list: the API has no source for one. test/layout.test.ts holds this copy to those files,
// so when the README or the CLI changes, this page has to change with it.

import { h, type SNode } from '../src/doc';
import { anchorHref, internalHref, REPO_URL, webHref } from '../src/links';
import { searchPath } from '../src/routes';
import { loadingView } from '../src/views/common';
import { doc, type PageSpec } from './layout';

const MOJO_URL = 'https://www.modular.com/mojo';

/** README.md's opening sentence, as it reads on the page (links become text in the comparison). */
export const OPENING_SENTENCE =
  'mopm is "cargo for Mojo": a package manager plus build, test and coverage tooling for Mojo projects, with a package registry at mopm.dev.';

/** README.md's "Status: early." list of commands that work today, in its order. */
export const WORKING_TODAY = ['--version', 'link-plan', 'metadata', 'new', 'init', 'build', 'run', 'repl', 'test'];

/** The `planned` array of src/cli/main.zig, in its order. */
export const PLANNED = ['add', 'remove', 'cov', 'check', 'export', 'launch'];

/** The commands that work in a package `mopm new` has just made (tests/new/lib holds what it makes). */
export const QUICKSTART = [
  'mopm new my_package --lib      # or --bin; `mopm init` makes one in the current directory',
  'cd my_package',
  'mopm metadata                  # check mopm.toml and print it as JSON',
  'mopm test                      # tests/**/test_*.mojo, one process per test',
  'mopm repl                      # mojo repl with the native libraries preloaded',
].join('\n');

/** Build and run take a Mojo file with a main; the scaffold makes none for --lib, so the reader brings one. */
export const BUILD_RUN = [
  'mopm build hello.mojo -o hello # links the native libraries of the environment',
  'mopm run hello.mojo',
].join('\n');

const BUILD = ['git clone https://github.com/komira-ai/mopm', 'cd mopm', 'zig build            # builds zig-out/bin/mopm'].join('\n');

function link(href: string, text: string): SNode {
  return h(doc, 'a', { href: webHref(href) ?? undefined }, text);
}

function code(s: string): SNode {
  return h(doc, 'code', null, s);
}

/** A scrollable, keyboard-reachable code block, named for screen readers (a named <pre> needs a role). */
function block(s: string, label: string): SNode {
  return h(doc, 'pre', { tabindex: '0', role: 'region', 'aria-label': label }, h(doc, 'code', null, s));
}

/** `a`, `b` and `c` with code spans. */
function codeList(items: readonly string[], conj: string): (SNode | string)[] {
  const out: (SNode | string)[] = [];
  items.forEach((it, i) => {
    if (i > 0) out.push(i === items.length - 1 ? ` ${conj} ` : ', ');
    out.push(code(it));
  });
  return out;
}

/** A command block with a Copy button (added by the page script; see src/copy.ts), named for screen readers. */
function copyBlock(s: string, label: string, extra = ''): SNode {
  return h(doc, 'div', { class: `cmd copy-box${extra}` }, h(doc, 'pre', { tabindex: '0', role: 'region', 'aria-label': label }, h(doc, 'code', null, s)));
}

/** A command block with no Copy button: the text holds a placeholder the reader replaces. */
function plainBlock(s: string, label: string): SNode {
  return h(doc, 'div', { class: 'cmd' }, h(doc, 'pre', { tabindex: '0', role: 'region', 'aria-label': label }, h(doc, 'code', null, s)));
}

/** A home band: a full-width section with its own wrap, a kicker and a heading. */
function band(id: string, cls: string, kicker: string, title: string, ...children: (SNode | string | null)[]): SNode {
  return h(
    doc,
    'section',
    { class: `band ${cls}`, 'aria-labelledby': id },
    h(doc, 'div', { class: 'wrap' }, h(doc, 'p', { class: 'kicker' }, kicker), h(doc, 'h2', { id }, title), ...children),
  );
}

/** The terminal card beside the hero: a first session, in commands that work today in a package `mopm new` makes. */
export const SESSION = ['mopm new my_package --lib', 'cd my_package', 'mopm metadata', 'mopm test', 'mopm repl'];

function terminal(): SNode {
  const lines: (SNode | string)[] = [];
  SESSION.forEach((cmd, i) => {
    if (i > 0) lines.push('\n');
    lines.push(h(doc, 'span', { class: 'p', 'aria-hidden': 'true' }, '$ '), cmd);
  });
  return h(
    doc,
    'div',
    { class: 'term' },
    h(doc, 'div', { class: 'term-bar', 'aria-hidden': 'true' }, h(doc, 'span', { class: 'dots' }), h(doc, 'span', null, 'my_package')),
    h(doc, 'pre', { tabindex: '0', role: 'region', 'aria-label': 'A first session' }, h(doc, 'code', null, ...lines)),
  );
}

export function homePage(): PageSpec {
  const hero = h(
    doc,
    'section',
    { class: 'hero', 'aria-labelledby': 'hero-title' },
    h(
      doc,
      'div',
      { class: 'wrap hero-grid' },
      h(
        doc,
        'div',
        { class: 'hero-text' },
        h(
          doc,
          'p',
          { class: 'eyebrow' },
          h(doc, 'a', { class: 'pill', href: anchorHref('status') }, 'Status: early'),
          h(doc, 'a', { href: internalHref('/docs/') }, 'Read the docs →'),
        ),
        h(doc, 'h1', { class: 'display', id: 'hero-title' }, 'Cargo for ', h(doc, 'em', null, 'Mojo.')),
        h(
          doc,
          'p',
          { class: 'lede', id: 'opening' },
          'mopm is "cargo for Mojo": a package manager plus build, test and coverage tooling for ',
          link(MOJO_URL, 'Mojo'),
          ' projects, with a package registry at mopm.dev.',
        ),
        // The home page has no header search (layout.ts), so this field takes its id: '/' focuses it.
        h(
          doc,
          'form',
          { class: 'hero-search', role: 'search', action: internalHref('/search'), method: 'get', 'aria-label': 'Search the registry' },
          h(doc, 'label', { for: 'q', class: 'visually-hidden' }, 'Find a package by name'),
          h(
            doc,
            'div',
            { class: 'big-search' },
            h(doc, 'span', { class: 'search-icon', 'aria-hidden': 'true' }),
            h(doc, 'input', { id: 'q', name: 'q', type: 'search', placeholder: 'Find a package by name', maxlength: '64', autocomplete: 'off', spellcheck: 'false', enterkeyhint: 'search' }),
            h(doc, 'kbd', { 'aria-hidden': 'true' }, '/'),
            h(doc, 'button', { type: 'submit', class: 'button button-primary' }, 'Search'),
          ),
          // Name order, not sort=updated: the API refuses sort=updated once more than 1000 packages match, and with no q
          // every package matches.
          h(doc, 'p', { class: 'muted small' }, 'Search matches the start of a name, or ', h(doc, 'a', { href: internalHref(searchPath()) }, 'browse all packages'), '.'),
        ),
        h(
          doc,
          'div',
          { class: 'install-hero', id: 'install' },
          h(doc, 'p', { class: 'install-label' }, h(doc, 'strong', null, 'Install the mopm CLI')),
          h(
            doc,
            'p',
            { class: 'seg', 'aria-hidden': 'true' },
            h(doc, 'span', { class: 'seg-on' }, 'From source'),
            h(doc, 'span', { class: 'seg-off' }, 'One-line installer ', h(doc, 'span', { class: 'tag tag-planned' }, 'planned')),
          ),
          copyBlock(BUILD, 'build from source commands', ' cmd-xl'),
          h(
            doc,
            'p',
            { class: 'note', id: 'build' },
            'There are no release binaries yet, and no one-line installer: build from source with Zig 0.12.0 (',
            code('tools/install_zig.sh <dir>'),
            ' installs it, checked against a pinned sha256). CI builds and tests it on Linux x86_64, Linux aarch64 and macOS arm64.',
          ),
        ),
      ),
      h(doc, 'div', { class: 'hero-side' }, terminal()),
    ),
  );

  const steps = h(
    doc,
    'ol',
    { class: 'stepper' },
    h(
      doc,
      'li',
      null,
      h(doc, 'span', { class: 'num', 'aria-hidden': 'true' }, '1'),
      h(doc, 'h3', null, 'Build mopm'),
      h(doc, 'p', null, 'In a clone of ', link(REPO_URL, 'the repository'), ', with Zig 0.12.0. The one-line installer is planned.'),
      copyBlock('zig build', 'build command'),
    ),
    h(
      doc,
      'li',
      null,
      h(doc, 'span', { class: 'num', 'aria-hidden': 'true' }, '2'),
      h(doc, 'h3', null, 'Start a package'),
      h(doc, 'p', null, code('mopm init'), ' makes one in the current directory instead. ', code('mopm test'), ' runs its tests in a ', h(doc, 'a', { href: anchorHref('mojo-env') }, 'Mojo environment'), '.'),
      copyBlock('mopm new my_package --lib', 'new package command'),
    ),
    h(
      doc,
      'li',
      null,
      h(doc, 'span', { class: 'num', 'aria-hidden': 'true' }, '3'),
      h(doc, 'h3', null, 'Add a package'),
      h(doc, 'p', null, 'In a pixi project that lists the mopm.dev channel. mopm’s own ', code('mopm add'), ' is planned.'),
      plainBlock('pixi add mojo-<name>', 'pixi command'),
    ),
  );
  const quickstart = band('quickstart', 'band-steps', 'Quickstart', 'Three steps to your first package', steps);

  const registry = h(
    doc,
    'section',
    { class: 'band strip', 'aria-label': 'The registry' },
    h(
      doc,
      'div',
      { class: 'wrap strip-grid' },
      h(
        doc,
        'div',
        { class: 'strip-recent' },
        h(doc, 'p', { class: 'kicker' }, 'Recently published'),
        h(doc, 'h2', { id: 'recent' }, 'Fresh on the registry'),
        // Filled by the page script from the registry (src/views/recent.ts); nothing is baked in at build time.
        h(
          doc,
          'div',
          { class: 'recent-slot', id: 'recent-list', 'aria-live': 'polite', 'aria-busy': 'true' },
          h(doc, 'p', { class: 'recent-note js-only' }, 'Loading recently published packages…'),
          h(doc, 'p', { class: 'recent-note no-js' }, 'The list of recent packages needs JavaScript. ', h(doc, 'a', { href: internalHref(searchPath()) }, 'Browse all packages'), ' instead.'),
        ),
      ),
      h(
        doc,
        'div',
        { class: 'strip-registry' },
        h(doc, 'p', { class: 'kicker' }, 'Install from the registry'),
        h(doc, 'h2', { id: 'registry' }, 'Every package is a conda package'),
        h(
          doc,
          'p',
          null,
          'Every published package is served as a conda channel at ',
          h(doc, 'code', { id: 'conda-channel' }, 'https://conda.mopm.dev/'),
          ', so pixi and other conda clients install it today. The conda package of ',
          code('<name>'),
          ' is ',
          code('mojo-<name>'),
          '; in a pixi project that lists the channel, ',
          code('pixi add mojo-<name>'),
          ' installs it (',
          link(`${REPO_URL}/blob/main/spec/channel.md`, 'the channel spec'),
          ').',
        ),
        h(doc, 'p', null, 'mopm’s own ', code('mopm add'), ' is planned.'),
      ),
    ),
  );

  const today = band(
    'today',
    'home-wide',
    'Working today',
    'What mopm does now',
    h(
      doc,
      'p',
      { class: 'status', id: 'status' },
      h(doc, 'strong', null, 'Status: early.'),
      ' ',
      ...codeList(WORKING_TODAY.map((c) => `mopm ${c}`), 'and'),
      ' work today. Everything else is a plan, and the design may change.',
    ),
    h(
      doc,
      'p',
      { id: 'mojo-env' },
      'mopm runs the ',
      code('mojo'),
      ' of a Mojo environment: ',
      code('--prefix <dir>'),
      ', else ',
      code('CONDA_PREFIX'),
      ', else ',
      code('MODULAR_HOME'),
      ' without its ',
      code('/share/max'),
      '. ',
      code('test'),
      ', ',
      code('repl'),
      ', ',
      code('build'),
      ' and ',
      code('run'),
      ' need one.',
    ),
    h(doc, 'p', null, 'These commands work today, in a new package:'),
    block(QUICKSTART, 'Quickstart commands'),
    h(doc, 'p', { id: 'build-run' }, 'Build and run take a Mojo file with a ', code('main'), ' (', code('hello.mojo'), ' here is your own file):'),
    block(BUILD_RUN, 'Build and run commands'),
    h(
      doc,
      'p',
      { id: 'mojo-exec' },
      code('build'),
      ', ',
      code('run'),
      ' and ',
      code('repl'),
      ' each run ',
      code('<env>/bin/mojo'),
      ' in place of mopm, so stdin, signals and the exit status are mojo’s; ',
      code('--print-cmd'),
      ' prints the command instead. ',
      code('test'),
      ' starts one mojo process per test. ',
      h(doc, 'a', { href: internalHref('/docs/mopm-test/') }, 'How mopm test works'),
      '.',
    ),
  );

  const planned = band(
    'planned',
    'band-planned',
    'Being built',
    'Planned',
    h(doc, 'p', null, 'Not implemented yet: ', ...codeList(PLANNED, 'and'), '. The design may change.'),
    h(
      doc,
      'ul',
      { class: 'goals' },
      h(doc, 'li', null, h(doc, 'h3', null, 'Coverage for any Mojo package'), h(doc, 'p', null, code('mopm cov'), ' builds and tests a package and reports line coverage, without the package adopting a particular build system.')),
      h(doc, 'li', null, h(doc, 'h3', null, 'Automatic native linking for downstream consumers'), h(doc, 'p', null, 'The build, run and REPL part works today; dependency resolution is planned.')),
    ),
  );

  return {
    title: 'mopm',
    description: 'mopm is a package manager plus build, test and coverage tooling for Mojo projects, with a package registry at mopm.dev.',
    kind: 'home',
    main: [hero, quickstart, registry, today, planned],
  };
}

export function notFoundPage(): PageSpec {
  return {
    title: 'Page not found',
    description: 'There is no page at this address.',
    kind: 'error',
    noindex: true,
    main: [
      h(
        doc,
        'section',
        { class: 'notice' },
        h(doc, 'h1', null, 'Page not found'),
        h(doc, 'p', null, 'There is nothing at this address. Package names are lowercase letters, digits and underscores.'),
        h(
          doc,
          'ul',
          null,
          h(doc, 'li', null, h(doc, 'a', { href: internalHref(searchPath()) }, 'Browse packages')),
          h(doc, 'li', null, h(doc, 'a', { href: internalHref('/docs/') }, 'Read the docs')),
          h(doc, 'li', null, h(doc, 'a', { href: internalHref('/') }, 'Go to the home page')),
        ),
      ),
    ],
  };
}

/** The shell for /search, /packages/<name> and /packages/<name>/<version>: main.ts fills <main>. */
export function appShell(): PageSpec {
  const loading = loadingView(doc).nodes;
  return {
    title: 'mopm',
    description: 'Packages in the mopm registry.',
    kind: 'app',
    main: loading,
    noscript: [
      h(doc, 'p', null, 'This page reads the registry API and needs JavaScript. Packages are also served as a conda channel; see the ', h(doc, 'a', { href: internalHref('/') }, 'home page'), '.'),
    ],
  };
}
