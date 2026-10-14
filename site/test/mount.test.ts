// T14 (putting a view on the page, mount.ts): with a fake <main>, document and history, each thing main.ts relies on
// mount for is checked: the title and nodes, focus kept on <main>, the noindex meta, the canonical address (with the
// hash), the header search text, and the Retry button calling back. And the home page's conda channel follows the host.
import { type SNode, serialize } from '../src/doc';
import { networkError } from '../src/errors';
import { type MainElement, mount, type MountTarget, showChannel } from '../src/mount';
import { errorView, loadingView, type View } from '../src/views/common';
import { sdoc } from './view-helpers';

type Listener = { type: string; listener: () => void; once: boolean };

/** A page whose members record what mount does to them. */
function page(at: { pathname: string; search?: string; hash?: string }, opts: { focusInside?: boolean; robots?: boolean; headerQ?: boolean } = {}) {
  const rec = {
    children: [] as SNode[],
    focused: [] as { preventScroll: boolean }[],
    titles: [] as string[],
    noindexAdded: 0,
    replaced: [] as string[],
    listeners: [] as Listener[],
  };
  // Focus as a browser keeps it: the active element is <body>, <main> or a node inside <main>. A focused node that
  // replaceChildren removes is no longer active, and focus falls back to <body>.
  const body = { tag: 'body' };
  const focusedChild = sdoc.el('button') as SNode; // the old view's Retry button
  if (opts.focusInside) rec.children = [focusedChild];
  let active: unknown = opts.focusInside ? focusedChild : body;
  const main: MainElement<SNode> = {
    contains: (n) => n === main || rec.children.includes(n as SNode),
    replaceChildren: (...nodes) => {
      rec.children = nodes;
      if (active !== main && !nodes.includes(active as SNode)) active = body;
    },
    focus: (o) => {
      rec.focused.push(o);
      active = main;
    },
    // The view's Retry button, when the nodes hold one.
    querySelector: () =>
      serialize(rec.children).includes('<button type="button" class="button retry">')
        ? { addEventListener: (type, listener, o) => void rec.listeners.push({ type, listener, once: o.once }) }
        : null,
  };
  const headerQ = opts.headerQ === false ? null : { value: 'old' };
  const t: MountTarget<SNode> = {
    main,
    headerQ,
    activeElement: () => active,
    setTitle: (s) => void rec.titles.push(s),
    hasRobotsMeta: () => opts.robots === true,
    addNoindex: () => void rec.noindexAdded++,
    location: { pathname: at.pathname, search: at.search ?? '', hash: at.hash ?? '' },
    replaceState: (u) => void rec.replaced.push(u),
  };
  return { t, rec, headerQ };
}

const view = (extra: Partial<View<SNode>> = {}): View<SNode> => ({ title: 'http_client', nodes: [sdoc.text('x')], ...extra });

describe('mount', () => {
  test('sets the title with the site suffix and replaces <main>\'s children with the view\'s nodes', () => {
    const { t, rec } = page({ pathname: '/packages/http_client' });
    const v = view();
    mount(t, v, () => undefined);
    expect(rec.titles).toEqual(['http_client · mopm']);
    expect(rec.children).toEqual(v.nodes);
  });

  test('focus inside <main> stays on <main>; focus elsewhere is left alone', () => {
    const inside = page({ pathname: '/x' }, { focusInside: true });
    expect(inside.t.main.contains(inside.t.activeElement())).toBe(true);
    mount(inside.t, view(), () => undefined);
    expect(inside.rec.focused).toEqual([{ preventScroll: true }]);
    // The focused Retry button is gone with the old view; focus is on <main>, not fallen back to <body>.
    expect(inside.t.activeElement()).toBe(inside.t.main);
    const outside = page({ pathname: '/x' });
    mount(outside.t, view(), () => undefined);
    expect(outside.rec.focused).toEqual([]);
  });

  test('a noindex view adds the robots meta once, only when the page has none', () => {
    const none = page({ pathname: '/x' });
    mount(none.t, view({ noindex: true }), () => undefined);
    expect(none.rec.noindexAdded).toBe(1);
    const has = page({ pathname: '/x' }, { robots: true });
    mount(has.t, view({ noindex: true }), () => undefined);
    expect(has.rec.noindexAdded).toBe(0);
    const indexed = page({ pathname: '/x' });
    mount(indexed.t, view(), () => undefined);
    expect(indexed.rec.noindexAdded).toBe(0);
  });

  test('a canonical path that differs replaces the address, keeping the hash; the same path does not', () => {
    const differs = page({ pathname: '/search', search: '?q=http&sort=relevance', hash: '#r' });
    mount(differs.t, view({ canonicalPath: '/search?q=http' }), () => undefined);
    expect(differs.rec.replaced).toEqual(['/search?q=http#r']);
    const same = page({ pathname: '/search', search: '?q=http' });
    mount(same.t, view({ canonicalPath: '/search?q=http' }), () => undefined);
    expect(same.rec.replaced).toEqual([]);
  });

  test('a search view sets the header search text; another view leaves it', () => {
    const s = page({ pathname: '/search' });
    mount(s.t, view({ searchQ: 'json' }), () => undefined);
    expect(s.headerQ?.value).toBe('json');
    const p = page({ pathname: '/packages/x' });
    mount(p.t, view(), () => undefined);
    expect(p.headerQ?.value).toBe('old');
    expect(() => mount(page({ pathname: '/search' }, { headerQ: false }).t, view({ searchQ: 'json' }), () => undefined)).not.toThrow();
  });

  test('the error view\'s Retry button calls back once on a click; a view without one wires nothing', () => {
    const { t, rec } = page({ pathname: '/packages/x' });
    let retries = 0;
    mount(t, errorView(sdoc, networkError()), () => void retries++);
    expect(rec.listeners.map((l) => [l.type, l.once])).toEqual([['click', true]]);
    rec.listeners[0].listener();
    expect(retries).toBe(1);
    const loading = page({ pathname: '/packages/x' });
    mount(loading.t, loadingView(sdoc), () => undefined);
    expect(loading.rec.listeners).toEqual([]);
  });
});

describe('showChannel', () => {
  test.each([
    ['mopm.dev', 'https://conda.mopm.dev/'],
    ['beta.mopm.dev', 'https://conda.beta.mopm.dev/'],
  ])('on %s the home page shows %s', (host, want) => {
    const el = { textContent: 'https://conda.mopm.dev/' as string | null };
    showChannel(el, host);
    expect(el.textContent).toBe(want);
  });

  test('a host outside the table keeps the prerendered channel; a page without the element is left alone', () => {
    const el = { textContent: 'https://conda.mopm.dev/' as string | null };
    showChannel(el, 'localhost');
    expect(el.textContent).toBe('https://conda.mopm.dev/');
    expect(() => showChannel(null, 'beta.mopm.dev')).not.toThrow();
  });
});
