// The page script's additions (src/enhance.ts), driven through a StringDoc port with no DOM. What each test proves,
// and the defect it catches:
//  - every .copy-box with a <pre> gets exactly one Copy button, a box that already has one gets no second, and a box
//    with no <pre> gets none (a loop that skips boxes, or doubles them when a view is shown again, fails it);
//  - the button is named from the <pre>'s aria-label, else the text its aria-labelledby names (a label read from the
//    wrong place, or dropped, fails it);
//  - with no clipboard (an insecure context) no button is added (a dead button fails it);
//  - the recent slot is filled and marked aria-busy="false" on an answer, on a rejected call, and on a host with no
//    API (a missing aria-busy reset, a missing .catch, or a call on an unknown host fails it).
import type { Client } from '../src/api';
import type { Clipboard } from '../src/copy';
import { h, type SElement, type SNode, serialize, StringDoc } from '../src/doc';
import { addCopyButtons, type EnhancePort, searchFieldId, showRecent } from '../src/enhance';
import type { PackageList } from '../src/types';
import { text } from './view-helpers';

class Port extends StringDoc implements EnhancePort<SNode> {
  constructor(private readonly rootNode: () => SNode) {
    super();
  }
  onClick(): void {}
  setText(node: SNode, t: string): void {
    (node as SElement).children = t === '' ? [] : [{ text: t }];
  }
  textOf(node: SNode): string {
    return 'tag' in node ? node.children.map((c) => this.textOf(c)).join('') : node.text;
  }
  private all(n: SNode): SElement[] {
    return 'tag' in n ? [n, ...n.children.flatMap((c) => this.all(c))] : [];
  }
  getAttr(node: SNode, name: string): string | null {
    return 'tag' in node ? (node.attrs.find(([k]) => k === name)?.[1] ?? null) : null;
  }
  copyBoxes(root: SNode): SNode[] {
    return this.all(root).filter((e) => (this.getAttr(e, 'class') ?? '').split(' ').includes('copy-box'));
  }
  firstPre(box: SNode): SNode | null {
    return this.all(box).find((e) => e.tag === 'pre') ?? null;
  }
  hasCopyButton(box: SNode): boolean {
    return this.all(box).some((e) => e.tag === 'button' && this.getAttr(e, 'class')?.split(' ').includes('copy'));
  }
  textById(id: string): string | null {
    const e = this.all(this.rootNode()).find((x) => this.getAttr(x, 'id') === id);
    return e ? this.textOf(e) : null;
  }
  replaceChildren(node: SNode, nodes: SNode[]): void {
    (node as SElement).children = nodes;
  }
}

const clip: Clipboard = { writeText: async () => undefined };
const later = () => undefined;

function page() {
  let root: SNode | null = null;
  const port = new Port(() => root as SNode);
  root = h(
    port,
    'main',
    null,
    h(port, 'p', { id: 'lbl' }, ' conda channel '),
    h(port, 'div', { class: 'cmd copy-box' }, h(port, 'pre', { 'aria-labelledby': 'lbl' }, h(port, 'code', null, 'https://conda.mopm.dev/'))),
    h(port, 'div', { class: 'cmd cmd-lg copy-box' }, h(port, 'pre', { 'aria-label': 'install command' }, h(port, 'code', null, 'pixi add mojo-x'))),
    h(port, 'div', { class: 'copy-box' }, h(port, 'p', null, 'no pre here')),
    h(port, 'div', { class: 'cmd' }, h(port, 'pre', null, 'not a copy box')),
  );
  return { port, root };
}

test('one Copy button per copy box with a <pre>, named from aria-labelledby or aria-label; none twice', () => {
  const { port, root } = page();
  expect(addCopyButtons(port, root, clip, later)).toBe(2);
  const out = serialize(root);
  expect(out.match(/<button /g)).toHaveLength(2);
  expect(out).toContain('aria-label="Copy conda channel"');
  expect(out).toContain('aria-label="Copy install command"');
  expect(out).toContain('<div class="cmd"><pre>not a copy box</pre></div>');
  expect(addCopyButtons(port, root, clip, later)).toBe(0);
  expect(serialize(root).match(/<button /g)).toHaveLength(2);
});

test('with no clipboard no button is added', () => {
  const { port, root } = page();
  expect(addCopyButtons(port, root, null, later)).toBe(0);
  expect(serialize(root)).not.toContain('<button');
});

function slot() {
  const port = new Port(() => s);
  const s: SNode = h(port, 'div', { id: 'recent-list', 'aria-busy': 'true' }, h(port, 'p', null, 'Loading…'));
  return { port, s };
}

const list: PackageList = { next_cursor: null, packages: [{ name: 'json', latest: '1.0.0', description: null, updated_at: '2026-10-14T00:00:00Z' }] };

test('an answer fills the slot and clears aria-busy', async () => {
  const { port, s } = slot();
  await showRecent(port, s, { searchPackages: async () => ({ kind: 'ok', value: list, requestId: null }) });
  expect(serialize(s)).toMatch(/^<div id="recent-list" aria-busy="false"><ol class="recent">/);
  expect(text(serialize(s))).not.toContain('Loading');
});

test('a rejected call is shown as a failure and clears aria-busy', async () => {
  const { port, s } = slot();
  const api: Pick<Client, 'searchPackages'> = { searchPackages: () => Promise.reject(new Error('offline')) };
  await showRecent(port, s, api);
  expect(serialize(s)).toContain('aria-busy="false"');
  expect(text(serialize(s))).toBe('Recently updated packages could not be loaded. Browse all packages.');
});

test('a host with no API makes no call, says why, and clears aria-busy', async () => {
  const { port, s } = slot();
  await showRecent(port, s, null);
  expect(serialize(s)).toContain('aria-busy="false"');
  expect(text(serialize(s))).toContain('not served from mopm.dev');
});

test('a page with no slot is left alone', async () => {
  const { port } = slot();
  let called = 0;
  await showRecent(port, null, {
    searchPackages: async () => {
      called++;
      return { kind: 'ok', value: list, requestId: null };
    },
  });
  expect(called).toBe(0);
});

// '/' on the search page goes to the page's own box (it holds the query), elsewhere to the header's; the header box
// stays on every app-shell view, so both exist on /search. Mutants: the header's #q preferred (the '/' shortcut lands in
// the small box on /search); no fallback to #q (no shortcut on the package and docs pages).
test('searchFieldId: the search page\'s box when there is one, else the header\'s, else none', () => {
  expect(searchFieldId((id) => id === 'search-q' || id === 'q')).toBe('search-q');
  expect(searchFieldId((id) => id === 'search-q')).toBe('search-q');
  expect(searchFieldId((id) => id === 'q')).toBe('q');
  expect(searchFieldId(() => false)).toBeNull();
});
