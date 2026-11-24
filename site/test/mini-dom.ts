// A small DOM for test/tutorial-main.test.ts, which runs the tutorial page's real script (src/tutorial/main.ts) under
// Node: just the members main.ts and browserDoc (src/doc.ts) use, with the browser's behaviour for each of them.
//  - createElement gives an HTMLTextAreaElement for 'textarea' and an HTMLButtonElement for 'button'; a text node is a
//    Node, not an Element;
//  - a <textarea>'s value is its text content until the reader types (setting `value` makes it dirty), as a browser's;
//  - a button's `disabled` is its disabled attribute;
//  - events bubble from the target through its ancestors to every listener of their type;
//  - `document.activeElement` is the focused element while it is in the document, and the body once it is not (a
//    browser moves focus to the body when the focused element is removed).
// Nothing here parses markup: there is no innerHTML, as the site's CSP allows none.

export class MiniNode {
  parentNode: MiniElement | null = null;
  constructor(readonly ownerDocument: MiniDocument) {}
  get textContent(): string | null {
    return '';
  }
}

export class MiniText extends MiniNode {
  constructor(doc: MiniDocument, readonly data: string) {
    super(doc);
  }
  override get textContent(): string {
    return this.data;
  }
}

export interface MiniEvent {
  type: string;
  target: MiniNode;
}

export class MiniElement extends MiniNode {
  readonly childNodes: MiniNode[] = [];
  private readonly attributes = new Map<string, string>();
  private readonly listeners = new Map<string, ((e: MiniEvent) => void)[]>();
  constructor(doc: MiniDocument, readonly tagName: string) {
    super(doc);
  }
  get id(): string {
    return this.getAttribute('id') ?? '';
  }
  override get textContent(): string {
    return this.childNodes.map((c) => c.textContent).join('');
  }
  setAttribute(name: string, value: string): void {
    this.attributes.set(name, value);
  }
  getAttribute(name: string): string | null {
    return this.attributes.get(name) ?? null;
  }
  hasAttribute(name: string): boolean {
    return this.attributes.has(name);
  }
  appendChild(child: MiniNode): MiniNode {
    if (child.parentNode !== null) child.parentNode.childNodes.splice(child.parentNode.childNodes.indexOf(child), 1);
    child.parentNode = this;
    this.childNodes.push(child);
    return child;
  }
  replaceChildren(...nodes: MiniNode[]): void {
    for (const c of this.childNodes) c.parentNode = null;
    this.childNodes.length = 0;
    for (const n of nodes) this.appendChild(n);
  }
  contains(n: unknown): boolean {
    for (let x = n as MiniNode | null; x !== null; x = x.parentNode) if (x === this) return true;
    return false;
  }
  /** `closest(tag)` for a bare tag name, the only selector main.ts uses. */
  closest(tag: string): MiniElement | null {
    for (let x: MiniElement | null = this; x !== null; x = x.parentNode) if (x.tagName === tag.toUpperCase()) return x;
    return null;
  }
  /** Descendants (not this element) whose class list holds `className`, in document order. */
  getElementsByClassName(className: string): MiniElement[] {
    const out: MiniElement[] = [];
    const walk = (e: MiniElement): void => {
      for (const c of e.childNodes) {
        if (!(c instanceof MiniElement)) continue;
        if ((c.getAttribute('class') ?? '').split(/\s+/).includes(className)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
  focus(): void {
    this.ownerDocument.focused = this;
  }
  addEventListener(type: string, fn: (e: MiniEvent) => void): void {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), fn]);
  }
  /** Delivers an event from `target` (this element's own, or a descendant's) to this element's listeners. */
  deliver(e: MiniEvent): void {
    for (const fn of this.listeners.get(e.type) ?? []) fn(e);
  }
}

export class MiniHTMLElement extends MiniElement {}

export class MiniButton extends MiniHTMLElement {
  get disabled(): boolean {
    return this.hasAttribute('disabled');
  }
}

export class MiniTextArea extends MiniHTMLElement {
  private typed: string | null = null;
  get value(): string {
    return this.typed ?? this.textContent;
  }
  set value(v: string) {
    this.typed = v;
  }
}

/** Sends an event of `type` from `target` up through its ancestors, as a bubbling DOM event. */
export function dispatch(type: string, target: MiniNode): void {
  const e = { type, target };
  for (let x = target instanceof MiniElement ? target : target.parentNode; x !== null; x = x.parentNode) x.deliver(e);
}

export class MiniDocument {
  focused: MiniElement | null = null;
  readonly body: MiniHTMLElement;
  constructor() {
    this.body = new MiniHTMLElement(this, 'BODY');
  }
  createElement(tag: string): MiniElement {
    if (tag === 'textarea') return new MiniTextArea(this, 'TEXTAREA');
    if (tag === 'button') return new MiniButton(this, 'BUTTON');
    return new MiniHTMLElement(this, tag.toUpperCase());
  }
  createTextNode(s: string): MiniText {
    return new MiniText(this, s);
  }
  get activeElement(): MiniElement {
    return this.focused !== null && this.body.contains(this.focused) ? this.focused : this.body;
  }
  getElementById(id: string): MiniElement | null {
    const find = (e: MiniElement): MiniElement | null => {
      if (e.id === id) return e;
      for (const c of e.childNodes) {
        const f = c instanceof MiniElement ? find(c) : null;
        if (f !== null) return f;
      }
      return null;
    };
    return find(this.body);
  }
}

/** The globals main.ts and browserDoc read, for this document. */
export function miniGlobals(doc: MiniDocument): Record<string, unknown> {
  return { document: doc, Node: MiniNode, Element: MiniElement, HTMLElement: MiniHTMLElement, HTMLTextAreaElement: MiniTextArea };
}
