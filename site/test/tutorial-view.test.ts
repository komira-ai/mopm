// The tutorial page's nodes (src/tutorial/view.ts) through StringDoc, with no DOM: the lesson's source as the build
// prerenders it and the page script reads it back (every malformed source refused), each PageView state's markup, and
// the small helpers. What each test proves is its name; the defect it catches is beside it.
import { h, type SElement, type SNode, serialize, StringDoc, TAGS } from '../src/doc';
import { internalHref } from '../src/links';
import { type Lesson, MESSAGES, type PageView } from '../src/tutorial/page';
import {
  CONTROL, editorId, editorIndex, lessonSource, readLesson, rowsFor, RUNNER_ID, SOURCE_CLASS, tutorialView,
} from '../src/tutorial/view';
import { LESSON, LESSON_WITH_TEST, MAIN } from './page-fakes';
import { FakeDom } from './tutorial-dom';
import { html as viewHtml, text } from './view-helpers';

const dom = new FakeDom(() => ({ text: '' }));
const sdoc = new StringDoc();

const mountOf = (lesson: Lesson, id: string | null = lesson.id): SElement =>
  h(sdoc, 'section', { id: RUNNER_ID, 'data-lesson': id ?? undefined }, ...lessonSource(sdoc, lesson)) as SElement;

const render = (v: PageView, lesson: Lesson = LESSON): string => viewHtml({ title: '', nodes: tutorialView(sdoc, v, lesson) });

describe('the lesson source and readLesson', () => {
  // Defect caught: the page script running a lesson other than the one the build wrote (a file, its text, a command or
  // the id lost or changed on the way).
  test.each([LESSON, LESSON_WITH_TEST])('reads back the lesson lessonSource wrote ($id)', (lesson) => {
    expect(readLesson(dom, mountOf(lesson))).toEqual(lesson);
  });

  test('text a browser would read differently is kept: markup, entities, a leading newline, tabs and unicode', () => {
    const lesson: Lesson = { ...LESSON, files: [{ path: 'src/main.mojo', text: '\n\tprint("<b>&amp; é ‮")\n' }] };
    const s = serialize(mountOf(lesson));
    // The text sits in <code> inside <pre>: the newline a browser drops after <pre> is not the text's first.
    expect(s).toContain('<pre class="lesson-text"><code>\n\tprint("&lt;b&gt;&amp;amp; é ‮")\n</code></pre>');
    expect(readLesson(dom, mountOf(lesson))).toEqual(lesson);
  });

  test.each<[string, (m: SElement) => void]>([
    ['no data-lesson', (m) => (m.attrs = m.attrs.filter(([k]) => k !== 'data-lesson'))],
    ['an id outside the grammar', (m) => (m.attrs = m.attrs.map(([k, v]) => [k, k === 'data-lesson' ? 'Hello' : v]))],
    ['no file', (m) => ((m.children[0] as SElement).children = [])],
    ['a file without its path', (m) => (((m.children[0] as SElement).children[0] as SElement).children.shift())],
    ['a file without its text', (m) => (((m.children[0] as SElement).children[0] as SElement).children.pop())],
    ['an empty path', (m) => ((((m.children[0] as SElement).children[0] as SElement).children[0] as SElement).children = [])],
    ['a path given twice', (m) => (m.children[0] as SElement).children.push((m.children[0] as SElement).children[0])],
    ['no run command', (m) => (m.children = m.children.slice(0, 1))],
    ['an empty run command', (m) => (((m.children[1] as SElement).children[1] as SElement).children = [])],
  ])('%s: no lesson', (_name, spoil) => {
    const m = mountOf(LESSON_WITH_TEST);
    spoil(m);
    expect(readLesson(dom, m)).toBeNull();
  });

  test('a mount point with no test command reads as a lesson with no test action', () => {
    const l = readLesson(dom, mountOf(LESSON));
    expect(l?.actions).toEqual({ run: 'mopm run src/main.mojo' });
    expect(Object.hasOwn(l?.actions ?? {}, 'test')).toBe(false);
  });

  test('the source uses only the Doc allowlist, and the classes readLesson reads', () => {
    const s = serialize(lessonSource(sdoc, LESSON_WITH_TEST));
    for (const c of Object.values(SOURCE_CLASS)) expect(s).toContain(`class="${c}"`);
    expect(viewHtml({ title: '', nodes: lessonSource(sdoc, LESSON_WITH_TEST) })).toBe(s);
  });
});

describe('the views', () => {
  const signIn = internalHref('/api/v2/auth/web/start?return_to=%2Ftutorial%2Fhello');
  const signedIn: PageView = {
    state: 'signed_in',
    lesson: 'hello',
    login: '<octo>',
    files: [{ path: 'src/main.mojo', text: '</textarea><script>x</script>' }],
    actions: ['run'],
    running: null,
    output: null,
    message: null,
  };

  test('loading: a status line and the read-only source', () => {
    expect(render({ state: 'loading', lesson: 'hello' })).toBe(
      `<p class="lesson-status muted" role="status">Checking whether you are signed in…</p>${serialize(lessonSource(sdoc, LESSON))}`,
    );
  });

  test('unavailable: the message as an alert, Try again, and the read-only source', () => {
    const out = render({ state: 'unavailable', lesson: 'hello', message: { code: 'tutorial_unavailable', text: MESSAGES.tutorial_unavailable } });
    expect(out).toBe(
      `<p class="notice notice-error lesson-message" role="alert">${MESSAGES.tutorial_unavailable}</p>` +
        `<p><button type="button" id="${CONTROL.retry}" class="button">Try again</button></p>${serialize(lessonSource(sdoc, LESSON))}`,
    );
  });

  test('signed out, opened so: the sign-in card and the read-only source, no textarea', () => {
    const out = render({ state: 'signed_out', lesson: 'hello', sign_in: signIn, files: null, message: null });
    expect(out).toBe(
      '<div class="notice lesson-sign-in"><p>Sign in with GitHub to edit this lesson and run it in a sandbox.</p>' +
        `<p><a class="button button-primary" href="${signIn}">Sign in with GitHub</a></p></div>${serialize(lessonSource(sdoc, LESSON))}`,
    );
  });

  test('signed out after the session ended: the message in the card, and the kept files in their editors', () => {
    const out = render({ state: 'signed_out', lesson: 'hello', sign_in: signIn, files: [{ path: 'src/main.mojo', text: 'kept' }], message: { code: 'session_required', text: MESSAGES.session_required } });
    expect(out).toContain(`<div class="notice lesson-sign-in"><p class="notice notice-error lesson-message" role="alert">${MESSAGES.session_required}</p>`);
    expect(out).toContain('<textarea id="lesson-file-0" name="src/main.mojo" class="lesson-code" rows="4" spellcheck="false" autocomplete="off">kept</textarea>');
    expect(out).not.toContain('<button');
  });

  // Defect caught: a login or file text that ends the textarea or starts an element.
  test('signed in: login and file text are text, never markup', () => {
    const out = render(signedIn);
    expect(out).toContain('Signed in as <strong>&lt;octo&gt;</strong>. <button type="button" id="lesson-sign-out" class="button">Sign out</button>');
    expect(out).toContain('rows="4" spellcheck="false" autocomplete="off">&lt;/textarea&gt;&lt;script&gt;x&lt;/script&gt;</textarea>');
    expect(out).toContain('<p class="lesson-buttons"><button type="button" id="lesson-run" class="button button-primary">Run</button></p>');
    expect(out).toContain('<p class="lesson-status muted" role="status"></p>');
    expect(out).not.toContain('lesson-output');
  });

  test('running: every button disabled, and what is running in the status line', () => {
    const run = render({ ...signedIn, state: 'running', running: 'run', actions: ['run', 'test'] }, LESSON_WITH_TEST);
    expect(run).toContain('<button type="button" id="lesson-sign-out" class="button" disabled="">Sign out</button>');
    expect(run).toContain(
      '<p class="lesson-buttons"><button type="button" id="lesson-run" class="button button-primary" disabled="">Run</button>' +
        '<button type="button" id="lesson-test" class="button" disabled="">Test</button></p>',
    );
    expect(run).toContain('role="status">Running…</p>');
    expect(render({ ...signedIn, state: 'running', running: 'test', actions: ['run', 'test'] }, LESSON_WITH_TEST)).toContain('role="status">Testing…</p>');
  });

  test('output: the exit line, then stdout and stderr as two text nodes of one <pre>', () => {
    const nodes = tutorialView(sdoc, { ...signedIn, output: { action: 'run', exit_code: 2, stdout: 'out\n', stderr: 'err\n', exit_note: 'The program exited with code 2.' } }, LESSON);
    const section = nodes[nodes.length - 1] as SElement;
    expect(serialize(section)).toBe('<section class="lesson-output" aria-label="Output"><p class="lesson-exit">The program exited with code 2.</p><pre class="lesson-out">out\nerr\n</pre></section>');
    expect((section.children[1] as SElement).children).toEqual([{ text: 'out\n' }, { text: 'err\n' }]);
  });

  test('a message beside the editor: its alert after the status line', () => {
    const out = render({ ...signedIn, message: { code: 'invalid_request', text: MESSAGES.invalid_request } });
    expect(out).toMatch(/role="status"><\/p><p class="notice notice-error lesson-message" role="alert">Something went wrong\. Reload the page\.<\/p>$/);
  });

  test('every view uses only tags of the Doc allowlist (textarea now among them)', () => {
    expect(TAGS).toContain('textarea');
    for (const v of [render(signedIn), render({ state: 'loading', lesson: 'hello' })]) expect(text(v).length).toBeGreaterThan(0);
  });
});

describe('helpers', () => {
  test('rowsFor: lines and one more, from 4 to 30', () => {
    expect([rowsFor(''), rowsFor('a\nb'), rowsFor(MAIN), rowsFor('x\n'.repeat(4)), rowsFor('x\n'.repeat(28)), rowsFor('x\n'.repeat(100))]).toEqual([4, 4, 4, 6, 30, 30]);
  });

  test('editorIndex reads back editorId, and nothing else', () => {
    for (const i of [0, 1, 9, 10, 9999]) expect(editorIndex(editorId(i))).toBe(i);
    for (const id of ['lesson-file-', 'lesson-file-01', 'lesson-file--1', 'lesson-file-10000', 'lesson-file-1x', 'xlesson-file-1', CONTROL.run]) expect(editorIndex(id)).toBeNull();
  });

  test('the controls have distinct ids, none an editor id', () => {
    const ids = Object.values(CONTROL);
    expect(new Set(ids).size).toBe(ids.length);
    for (const id of ids) expect(editorIndex(id)).toBeNull();
  });
});

test('FakeDom.byClass looks below the root only, by whole class names', () => {
  const root: SNode = h(sdoc, 'div', { class: 'lesson-file' }, h(sdoc, 'p', { class: 'lesson-file-x lesson-path' }, 'p'), h(sdoc, 'p', { class: 'lesson-paths' }, 'q'));
  expect(dom.byClass(root, 'lesson-file').length).toBe(0);
  expect(dom.byClass(root, 'lesson-path').map((n) => dom.textOf(n))).toEqual(['p']);
});
