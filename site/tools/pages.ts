// The prerendered pages that are not docs: the home page, the 404 page and the app shell.
//
// The home page says only what README.md says: its opening sentence word for word, the commands that work today, the
// build from source, and the planned commands (src/cli/main.zig). test/layout.test.ts holds this copy to those files,
// so when the README or the CLI changes, this page has to change with it.

import { h, type SNode } from '../src/doc';
import { internalHref, REPO_URL, webHref } from '../src/links';
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
export const PLANNED = ['add', 'remove', 'lock', 'sync', 'cov', 'tree', 'check', 'publish', 'export', 'launch'];

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

function section(id: string, title: string, ...children: (SNode | string | null)[]): SNode {
  return h(doc, 'section', { class: 'home-section', 'aria-labelledby': id }, h(doc, 'h2', { id }, title), ...children);
}

export function homePage(): PageSpec {
  const hero = h(
    doc,
    'section',
    { class: 'hero' },
    h(doc, 'h1', null, 'mopm'),
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
      h(doc, 'label', { for: 'q' }, 'Find a package by name'),
      h(
        doc,
        'div',
        { class: 'hero-search-row' },
        h(doc, 'input', { id: 'q', name: 'q', type: 'search', placeholder: 'http_client', maxlength: '64', autocomplete: 'off', spellcheck: 'false', enterkeyhint: 'search' }),
        h(doc, 'button', { type: 'submit', class: 'button button-primary' }, 'Search'),
      ),
      // Name order, not sort=updated: the API refuses sort=updated once more than 1000 packages match, and with no q
      // every package matches.
      h(doc, 'p', { class: 'muted small' }, 'or ', h(doc, 'a', { href: internalHref(searchPath()) }, 'browse all packages')),
    ),
    h(
      doc,
      'p',
      { class: 'status notice', id: 'status' },
      h(doc, 'strong', null, 'Status: early.'),
      ' ',
      ...codeList(WORKING_TODAY.map((c) => `mopm ${c}`), 'and'),
      ' work today. Everything else is a plan, and the design may change.',
    ),
  );

  const registry = section(
    'registry',
    'Install from the registry',
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
    h(doc, 'p', null, 'mopm’s own ', code('mopm add'), ' and ', code('mopm sync'), ' are planned.'),
  );

  const install = section(
    'build',
    'Build mopm',
    h(
      doc,
      'p',
      null,
      'There are no release binaries yet. Build from source with Zig 0.12.0 (',
      code('tools/install_zig.sh <dir>'),
      ' installs it, checked against a pinned sha256):',
    ),
    block(BUILD, 'Build from source'),
    h(doc, 'p', { class: 'muted small' }, 'CI builds and tests it on Linux x86_64, Linux aarch64 and macOS arm64.'),
  );

  const quickstart = section(
    'quickstart',
    'Quickstart',
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

  const planned = section(
    'planned',
    'Planned',
    h(doc, 'p', null, 'Not implemented yet: ', ...codeList(PLANNED, 'and'), '. The design may change.'),
    h(
      doc,
      'ul',
      { class: 'goals' },
      h(doc, 'li', null, h(doc, 'strong', null, 'Coverage for any Mojo package.'), ' ', code('mopm cov'), ' builds and tests a package and reports line coverage, without the package adopting a particular build system.'),
      h(doc, 'li', null, h(doc, 'strong', null, 'Automatic native linking for downstream consumers.'), ' The build, run and REPL part works today; dependency resolution is planned.'),
    ),
  );

  return {
    title: 'mopm',
    description: 'mopm is a package manager plus build, test and coverage tooling for Mojo projects, with a package registry at mopm.dev.',
    kind: 'home',
    main: [hero, h(doc, 'div', { class: 'home-grid' }, registry, install, quickstart, planned)],
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
