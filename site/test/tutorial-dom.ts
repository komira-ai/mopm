// A fake of the DOM the tutorial page script uses (src/tutorial/start.ts TutorialDom) over StringDoc's node tree, for
// test/tutorial-start.test.ts: a page (<main> holding the lesson's article and the prerendered mount point, as
// tools/tutorial.ts writes it), one focused element, and a reader who clicks buttons and types into editors. A click
// reaches the page script only on an enabled button, as main.ts's listener does; `press` sends it regardless, to show
// the controller itself starts one run at a time.
import { h, type SElement, type SNode, StringDoc } from '../src/doc';
import { internalHref } from '../src/links';
import type { TutorialDom } from '../src/tutorial/start';
import { lessonSource, RUNNER_ID } from '../src/tutorial/view';
import type { Lesson } from '../src/tutorial/page';

const isEl = (n: SNode): n is SElement => 'tag' in n;

export class FakeDom extends StringDoc implements TutorialDom<SNode> {
  /** The element with focus, or null when the body has it. */
  focused: SElement | null = null;
  private clicks: ((id: string) => void)[] = [];
  private inputs: ((id: string, value: string) => void)[] = [];
  /** How many times replaceChildren ran. */
  renders = 0;

  constructor(readonly root: () => SNode) {
    super();
  }

  /** Every element under `n`, `n` included, in document order. */
  all(n: SNode): SElement[] {
    return isEl(n) ? [n, ...n.children.flatMap((c) => this.all(c))] : [];
  }
  contains(root: SNode, n: SNode): boolean {
    return this.all(root).includes(n as SElement);
  }
  byClass(root: SNode, className: string): SNode[] {
    return this.all(root)
      .slice(1)
      .filter((e) => (this.attr(e, 'class') ?? '').split(' ').includes(className));
  }
  textOf(node: SNode): string {
    return isEl(node) ? node.children.map((c) => this.textOf(c)).join('') : node.text;
  }
  attr(node: SNode, name: string): string | null {
    return isEl(node) ? (node.attrs.find(([k]) => k === name)?.[1] ?? null) : null;
  }
  replaceChildren(node: SNode, nodes: SNode[]): void {
    (node as SElement).children = nodes;
    this.renders += 1;
  }
  focusedId(root: SNode): string | null {
    const f = this.focused;
    return f !== null && this.contains(root, f) ? this.attr(f, 'id') : null;
  }
  focusIsLost(): boolean {
    // A browser moves focus to the body when the focused element leaves the document.
    return this.focused === null || !this.contains(this.root(), this.focused);
  }
  focusById(root: SNode, id: string): boolean {
    const e = this.byId(root, id);
    if (e === null || this.attr(e, 'disabled') !== null) return false;
    this.focused = e;
    return true;
  }
  onClick(_root: SNode, fn: (id: string) => void): void {
    this.clicks.push(fn);
  }
  onInput(_root: SNode, fn: (id: string, value: string) => void): void {
    this.inputs.push(fn);
  }

  byId(root: SNode, id: string): SElement | null {
    return this.all(root).find((e) => this.attr(e, 'id') === id) ?? null;
  }
  /** The reader clicks the button `id`: focus moves to it, and the page script hears of it unless it is disabled. */
  click(id: string): void {
    const b = this.byId(this.root(), id);
    if (b === null || b.tag !== 'button') throw new Error(`no button #${id}`);
    if (this.attr(b, 'disabled') !== null) return;
    this.focused = b;
    this.clicks.forEach((fn) => fn(id));
  }
  /** The click event of `id`, sent whether the button is enabled or not. */
  press(id: string): void {
    this.clicks.forEach((fn) => fn(id));
  }
  /** The reader replaces the text of the editor `id` with `value`; the textarea's node keeps its initial text. */
  type(id: string, value: string): void {
    const t = this.byId(this.root(), id);
    if (t === null || t.tag !== 'textarea') throw new Error(`no editor #${id}`);
    this.focused = t;
    this.inputs.forEach((fn) => fn(id, value));
  }
  /** An input event from an element that is not one of the lesson's editors (a test's own id). */
  input(id: string, value: string): void {
    this.inputs.forEach((fn) => fn(id, value));
  }
}

export interface Page {
  dom: FakeDom;
  main: SElement;
  mount: SElement;
  /** The lesson's article, outside the mount point. */
  article: SElement;
  /** A link outside the mount point the reader can focus. */
  outside: SElement;
}

/** A lesson page as the build writes it: the article, then the mount point with the lesson's prerendered source. */
export function lessonPageDom(lesson: Lesson, articleText = 'Press Run: mopm builds the program and runs it.'): Page {
  let main: SElement | null = null;
  const dom = new FakeDom(() => main as SElement);
  const article = h(dom, 'article', { class: 'prose lesson' }, h(dom, 'p', null, articleText)) as SElement;
  const outside = h(dom, 'a', { id: 'outside', href: internalHref('/docs/') }, 'Docs') as SElement;
  const mount = h(dom, 'section', { id: RUNNER_ID, class: 'lesson-runner', 'aria-label': 'Try it', 'data-lesson': lesson.id }, ...lessonSource(dom, lesson)) as SElement;
  main = h(dom, 'main', { id: 'main' }, h(dom, 'h1', null, 'Hello'), article, outside, mount) as SElement;
  return { dom, main, mount, article, outside };
}

/** The elements of `tag` under `n`. */
export function tags(dom: FakeDom, n: SNode, tag: string): SElement[] {
  return dom.all(n).filter((e) => e.tag === tag);
}
