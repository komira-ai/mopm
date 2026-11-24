// The tutorial page's draft and output (src/tutorial/page.ts): the edited files and the last lesson in localStorage
// under mopm.tutorial.1, read back by the next page; a draft that is missing, malformed or of another lesson; a
// storage that throws; the grant never written. And `visible`: the exact marker of each control, bidi and invisible
// character, and nothing else changed.
import fc from 'fast-check';
import { DRAFT_KEY, exitNote, lastLesson, visible } from '../src/tutorial/page';
import { GRANT, GRANT_ANSWER, LESSON, MAIN, OK, SIGNED_IN, fakeRunner, harness, memoryStorage } from './page-fakes';

const EDITED = 'fn main():\n    print("edited")\n';
const filesOf = (h: ReturnType<typeof harness>) => {
  const v = h.page.view();
  return v.state === 'signed_in' || v.state === 'running' ? v.files : null;
};

describe('the draft', () => {
  test('is the key mopm.tutorial.1 (design section 6)', () => {
    expect(DRAFT_KEY).toBe('mopm.tutorial.1');
  });

  test('load() writes the last lesson; each edit writes the files; the next page reads them back', async () => {
    const storage = memoryStorage();
    const h = harness({ getWebSession: [SIGNED_IN] }, { storage });
    await h.page.load();
    h.page.edit('src/main.mojo', EDITED);
    expect(storage.writes).toEqual([
      [DRAFT_KEY, '{"last_lesson":"hello"}'],
      [DRAFT_KEY, JSON.stringify({ last_lesson: 'hello', files: { hello: { 'src/main.mojo': EDITED } } })],
    ]);
    const next = harness({ getWebSession: [SIGNED_IN] }, { storage });
    await next.page.load();
    expect(filesOf(next)).toEqual([{ path: 'src/main.mojo', text: EDITED }]);
    expect(lastLesson(storage)).toBe('hello');
  });

  test("keeps other lessons' files and fields it does not know", async () => {
    const stored = { last_lesson: 'other', files: { other: { 'a.mojo': 'x' } }, later_field: [1, 2] };
    const storage = memoryStorage({ [DRAFT_KEY]: JSON.stringify(stored) });
    const h = harness({ getWebSession: [SIGNED_IN] }, { storage });
    await h.page.load();
    expect(filesOf(h)).toEqual([{ path: 'src/main.mojo', text: MAIN }]);
    h.page.edit('src/main.mojo', EDITED);
    expect(JSON.parse(storage.items.get(DRAFT_KEY) as string)).toEqual({
      last_lesson: 'hello',
      files: { other: { 'a.mojo': 'x' }, hello: { 'src/main.mojo': EDITED } },
      later_field: [1, 2],
    });
  });

  test.each([
    ['not JSON', '{"files":'],
    ['JSON that is not an object', '[1,2]'],
    ['null', 'null'],
    ['files not an object', '{"files":"x"}'],
    ['the lesson not an object', '{"files":{"hello":["x"]}}'],
    ['a file that is not text', '{"files":{"hello":{"src/main.mojo":42}}}'],
    ['only other files', '{"files":{"hello":{"src/other.mojo":"x"}}}'],
  ])("%s: the lesson's own text", async (_, raw) => {
    const storage = memoryStorage({ [DRAFT_KEY]: raw });
    const h = harness({ getWebSession: [SIGNED_IN] }, { storage });
    await h.page.load();
    expect(filesOf(h)).toEqual([{ path: 'src/main.mojo', text: MAIN }]);
    h.page.edit('src/main.mojo', EDITED);
    expect(JSON.parse(storage.items.get(DRAFT_KEY) as string).files.hello).toEqual({ 'src/main.mojo': EDITED });
  });

  test('a path named like an Object member is a plain key: read back, never a prototype', async () => {
    const lesson = { ...LESSON, files: [{ path: '__proto__', text: 'a' }, { path: 'constructor', text: 'b' }, { path: 'toString', text: 'c' }] };
    const storage = memoryStorage();
    const h = harness({ getWebSession: [SIGNED_IN] }, { storage, lesson });
    await h.page.load();
    expect(filesOf(h)).toEqual(lesson.files);
    h.page.edit('__proto__', 'A');
    h.page.edit('constructor', 'B');
    const next = harness({ getWebSession: [SIGNED_IN] }, { storage, lesson });
    await next.page.load();
    expect(filesOf(next)).toEqual([{ path: '__proto__', text: 'A' }, { path: 'constructor', text: 'B' }, { path: 'toString', text: 'c' }]);
    expect(Object.getPrototypeOf(JSON.parse(storage.items.get(DRAFT_KEY) as string).files.hello)).toBe(Object.prototype);
  });

  test('a storage that throws on every call: the page loads, edits and runs without a draft', async () => {
    const storage = memoryStorage({}, true);
    const runner = fakeRunner(OK);
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { storage, runner });
    await h.page.load();
    h.page.edit('src/main.mojo', EDITED);
    await h.page.run('run');
    expect(filesOf(h)).toEqual([{ path: 'src/main.mojo', text: EDITED }]);
    expect(runner.calls.map((c) => c.files)).toEqual([[{ path: 'src/main.mojo', text: EDITED }]]);
    expect(h.page.view().state).toBe('signed_in');
    expect(lastLesson(storage)).toBeNull();
    // It was asked, and refused each time.
    expect(storage.writes.length).toBe(2);
    expect(storage.items.size).toBe(0);
  });

  test('the grant is never written: only the draft key, and no value holds any field of the grant', async () => {
    const storage = memoryStorage();
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { storage });
    await h.page.load();
    h.page.edit('src/main.mojo', EDITED);
    await h.page.run('run');
    h.page.edit('src/main.mojo', MAIN);
    await h.page.run('run');
    expect(storage.writes.length).toBe(3);
    for (const [key, value] of storage.writes) {
      expect(key).toBe(DRAFT_KEY);
      for (const v of [GRANT.sandbox_id, GRANT.access_token, GRANT.expires_at, GRANT.domain, 'access_token', 'sandbox_id']) {
        expect(value).not.toContain(v);
      }
    }
    expect([...storage.items.keys()]).toEqual([DRAFT_KEY]);
  });

  test.each([
    ['no draft', null, null],
    ['a lesson id', '{"last_lesson":"hello"}', 'hello'],
    ['not a lesson id', '{"last_lesson":"../x"}', null],
    ['not text', '{"last_lesson":1}', null],
    ['inherited, not own', '{}', null],
  ])('lastLesson(): %s', (_, raw, want) => {
    expect(lastLesson(memoryStorage(raw === null ? {} : { [DRAFT_KEY]: raw }))).toBe(want);
  });
});

describe('visible()', () => {
  test.each([
    ['a right-to-left override', 'a‮b', 'a[U+202E]b'],
    ['the bidi isolates', '⁦⁧⁨⁩', '[U+2066][U+2067][U+2068][U+2069]'],
    ['a left-to-right mark and an Arabic letter mark', '‎؜', '[U+200E][U+061C]'],
    ['zero-width space, joiner and non-joiner', '​‌‍', '[U+200B][U+200C][U+200D]'],
    ['a BOM and a word joiner', '﻿⁠', '[U+FEFF][U+2060]'],
    ['a soft hyphen', 'in­visible', 'in[U+00AD]visible'],
    ['NUL, ESC and DEL', '\u0000\u001B[31m\u007F', '[U+0000][U+001B][31m[U+007F]'],
    ['a C1 control', '\u0085\u009B', '[U+0085][U+009B]'],
    ['a carriage return alone', 'progress 10%\rprogress 20%', 'progress 10%[U+000D]progress 20%'],
    ['CR LF', 'a\r\nb\r\n', 'a\nb\n'],
    ['the line and paragraph separators', '  ', '[U+2028][U+2029]'],
    ['a tag character (5 hex digits)', 'a\u{E0041}\u{E007F}', 'a[U+E0041][U+E007F]'],
    ['a lone surrogate', 'x\uD800y\uDFFF', 'x[U+D800]y[U+DFFF]'],
    ['the invisible letters', '͏ᅟᅠ឴឵ㅤﾠ', '[U+034F][U+115F][U+1160][U+17B4][U+17B5][U+3164][U+FFA0]'],
    ['newline and tab stay', 'a\tb\nc', 'a\tb\nc'],
    ['emoji with a variation selector stay', '❤️ \u{1F600}', '❤️ \u{1F600}'],
    ['the empty string', '', ''],
  ])('%s', (_, input, want) => {
    expect(visible(input)).toBe(want);
  });

  const HIDDEN = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Cs}͏ᅟᅠ឴឵ㅤﾠ]/u;

  test('leaves no hidden character but newline and tab, for any text', () => {
    fc.assert(
      fc.property(fc.fullUnicodeString(), fc.string16bits(), (a, b) => {
        for (const s of [a, b]) for (const c of visible(s)) expect(c === '\n' || c === '\t' || !HIDDEN.test(c)).toBe(true);
      }),
    );
  });

  test('changes nothing in text without a hidden character or CR', () => {
    fc.assert(
      fc.property(fc.fullUnicodeString(), (s) => {
        const plain = [...s].filter((c) => c === '\n' || c === '\t' || !HIDDEN.test(c)).join('');
        expect(visible(plain)).toBe(plain);
      }),
    );
  });
});

test.each([
  [0, null],
  [1, 'The program exited with code 1.'],
  [-1, 'The program exited with code -1.'],
])('exitNote(%i)', (code, want) => {
  expect(exitNote(code)).toBe(want);
});
