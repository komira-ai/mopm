// The copy button (src/copy.ts), driven through a StringDoc port with a fake clipboard and a fake timer, so no DOM and
// no real clipboard are involved. What each test proves, and the defect it catches:
//  - the click writes exactly the <pre>'s text (a button copying the label, or the "$" prompt, fails it);
//  - after the write resolves the button reads "Copied" and the live region announces it (a button that changes only
//    its look, with no aria-live status, fails it);
//  - the reset after RESET_MS puts "Copy" back and empties the status (a missing reset fails it), and an earlier
//    click's timer does not cut a later "Copied" short (a reset without the round check fails it);
//  - a refused write says so in the status and never shows "Copied" (a handler that ignores the rejection fails it);
//  - with no clipboard nothing is added, so the command stays plain text (a dead button fails it).
import { addCopyButton, type Clipboard, COPIED, COPY, copyLabel, type CopyPort, FAILED, RESET_MS } from '../src/copy';
import { h, type SNode, serialize, StringDoc } from '../src/doc';

class Port extends StringDoc implements CopyPort<SNode> {
  clicks = new Map<SNode, () => void>();
  onClick(node: SNode, fn: () => void): void {
    this.clicks.set(node, fn);
  }
  setText(node: SNode, text: string): void {
    if (!('tag' in node)) throw new Error('not an element');
    node.children = text === '' ? [] : [{ text }];
  }
  textOf(node: SNode): string {
    return 'tag' in node ? node.children.map((c) => this.textOf(c)).join('') : node.text;
  }
}

function setup(clipboard: Clipboard | null) {
  const port = new Port();
  const pre = h(port, 'pre', { tabindex: '0', role: 'region', 'aria-label': 'install command' }, h(port, 'code', null, 'pixi add mojo-http_client'));
  const box = h(port, 'div', { class: 'cmd copy-box' }, h(port, 'span', { class: 'prompt', 'aria-hidden': 'true' }, '$'), pre);
  const timers: (() => void)[] = [];
  const delays: number[] = [];
  const button = addCopyButton(port, box, pre, 'install command', clipboard, (fn, ms) => {
    timers.push(fn);
    delays.push(ms);
  });
  const status = () => (box as { children: SNode[] }).children.find((c) => 'tag' in c && c.attrs.some(([k, v]) => k === 'role' && v === 'status')) as SNode;
  const click = async () => {
    port.clicks.get(button as SNode)?.();
    await new Promise((r) => setImmediate(r)); // let the clipboard promise settle
  };
  return { port, box, button, status, click, timers, delays };
}

function fakeClipboard(fail = false): Clipboard & { written: string[] } {
  const written: string[] = [];
  return {
    written,
    writeText: (t: string) => {
      written.push(t);
      return fail ? Promise.reject(new Error('denied')) : Promise.resolve();
    },
  };
}

test('the button is a real button, named for what it copies, followed by a polite live status', () => {
  const { box } = setup(fakeClipboard());
  const out = serialize(box);
  expect(out).toContain('<button type="button" class="copy" aria-label="Copy install command">Copy</button>');
  expect(out).toMatch(/<\/button><span class="visually-hidden" role="status" aria-live="polite"><\/span><\/div>$/);
});

test('a click writes exactly the command text, then says Copied on the button and in the live status', async () => {
  const clip = fakeClipboard();
  const { port, button, status, click } = setup(clip);
  await click();
  expect(clip.written).toEqual(['pixi add mojo-http_client']);
  expect(port.textOf(button as SNode)).toBe(COPIED);
  expect(port.textOf(status())).toBe(`${COPIED}: install command`);
  expect(serialize(button as SNode)).toContain('class="copy done"');
});

test('after RESET_MS the button reads Copy again and the status is empty', async () => {
  const { port, button, status, click, timers, delays } = setup(fakeClipboard());
  await click();
  expect(delays).toEqual([RESET_MS]);
  timers[0]();
  expect(port.textOf(button as SNode)).toBe(COPY);
  expect(port.textOf(status())).toBe('');
  expect(serialize(button as SNode)).toContain('class="copy"');
});

test("an earlier click's reset does not cut a later Copied short", async () => {
  const { port, button, click, timers } = setup(fakeClipboard());
  await click();
  await click();
  timers[0](); // the first round's timer fires during the second round
  expect(port.textOf(button as SNode)).toBe(COPIED);
  timers[1]();
  expect(port.textOf(button as SNode)).toBe(COPY);
});

test('a refused write says so in the status and never shows Copied', async () => {
  const { port, button, status, click, timers } = setup(fakeClipboard(true));
  await click();
  expect(port.textOf(button as SNode)).toBe(COPY);
  expect(port.textOf(status())).toBe(FAILED);
  expect(timers).toEqual([]);
});

test('a clipboard that throws instead of rejecting is handled the same way', async () => {
  const { port, status, click } = setup({
    writeText: () => {
      throw new Error('no');
    },
  });
  await click();
  expect(port.textOf(status())).toBe(FAILED);
});

test('with no clipboard nothing is added: the command stays plain, selectable text', () => {
  const { box, button } = setup(null);
  expect(button).toBeNull();
  expect(serialize(box)).toBe('<div class="cmd copy-box"><span class="prompt" aria-hidden="true">$</span><pre tabindex="0" role="region" aria-label="install command"><code>pixi add mojo-http_client</code></pre></div>');
});

test('copyLabel: the aria-label, else the labelling text, else "command"', () => {
  expect(copyLabel('install command', 'ignored')).toBe('install command');
  expect(copyLabel(null, ' conda channel ')).toBe('conda channel');
  expect(copyLabel(null, null)).toBe('command');
  expect(copyLabel('  ', null)).toBe('command');
});
