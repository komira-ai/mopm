// The lesson check of the site build (tools/lessons.ts): spec/tutorial-lesson.schema.json read from the file and
// interpreted, and the rules beyond it. Each refusal names the lesson's directory and the field, and a build of a tree
// holding a bad lesson fails with that message before it writes anything.
import { existsSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
import { assertSupported, type Json, LESSON_SCHEMA, LessonError, loadLessons, readLessonSchema, schemaErrors } from '../tools/lessons';
import { cleanup, type Fixture, fixture, goodLesson, LESSONS_DIR, lessonJson, lessonTree, REPO_ROOT, scratch } from './build-fixture';

const SCHEMA = readLessonSchema(join(REPO_ROOT, LESSON_SCHEMA));
const trees: string[] = [];
const dirs: string[] = [];
const made: Fixture[] = [];
afterAll(() => {
  for (const d of [...trees.map((t) => dirname(t)), ...dirs]) rmSync(d, { recursive: true, force: true });
  made.forEach(cleanup);
});

function tree(lessons: Parameters<typeof lessonTree>[0]): string {
  const t = lessonTree(lessons);
  trees.push(t);
  return t;
}

/** The problems loadLessons reports for the tree, exactly. */
function problems(dir: string): readonly string[] {
  try {
    loadLessons(dir, SCHEMA);
  } catch (e) {
    expect(e).toBeInstanceOf(LessonError);
    expect((e as Error).message).toBe(`tutorial lessons check failed:\n  ${(e as LessonError).problems.join('\n  ')}`);
    return (e as LessonError).problems;
  }
  throw new Error('loadLessons passed');
}

const errs = (doc: unknown): string[] => schemaErrors(SCHEMA, SCHEMA, doc as Json);
const defErrs = (def: string, v: unknown): string[] => schemaErrors(SCHEMA, (SCHEMA as { $defs: Record<string, Json> }).$defs[def], v as Json);

describe('the lessons in the repository', () => {
  test('every one passes, in order, with its text and fields', () => {
    const lessons = loadLessons(LESSONS_DIR, SCHEMA);
    expect(lessons.length).toBeGreaterThanOrEqual(1);
    expect(lessons.map((l) => l.order)).toEqual([...lessons.map((l) => l.order)].sort((a, b) => a - b));
    const hello = lessons.find((l) => l.id === 'hello');
    expect(hello).toMatchObject({
      source: 'tutorial/lessons/hello/lesson.md',
      title: 'Hello, world',
      order: 1,
      editable: ['src/main.mojo'],
      actions: { run: 'mopm run src/main.mojo' },
    });
    expect(hello?.markdown).toContain('Press **Run**');
  });
});

describe('the schema check, on the schema itself', () => {
  test('a valid lesson passes, with and without the test action', () => {
    expect(errs(lessonJson(1))).toEqual([]);
    expect(errs(lessonJson(1, { actions: { run: 'mopm run src/main.mojo', test: 'mopm test' } }))).toEqual([]);
    expect(errs(lessonJson(7, { editable: ['src/main.mojo', '.gitignore', 'a/b_c-d.e/f.mojo'] }))).toEqual([]);
  });

  test('each required field, missing', () => {
    for (const k of ['title', 'summary', 'order', 'editable', 'actions']) {
      const doc = lessonJson(1);
      delete doc[k];
      expect(errs(doc)).toEqual([`/${k}: is required and missing`]);
    }
  });

  test('a missing run action, and an unknown action or field', () => {
    expect(errs(lessonJson(1, { actions: {} }))).toEqual(['/actions/run: is required and missing']);
    expect(errs(lessonJson(1, { actions: { test: 'mopm test' } }))).toEqual(['/actions/run: is required and missing']);
    expect(errs(lessonJson(1, { actions: { run: 'mopm run x', build: 'mopm build' } }))).toEqual(['/actions/build: is not a field the schema allows']);
    expect(errs(lessonJson(1, { hint: 'x' }))).toEqual(['/hint: is not a field the schema allows']);
  });

  test('each type, wrong', () => {
    expect(errs([])).toEqual(['/: must be an object']);
    expect(errs(null)).toEqual(['/: must be an object']);
    expect(errs(lessonJson(1, { title: 1 }))).toEqual(['/title: must be a string']);
    expect(errs(lessonJson(1, { order: '1' }))).toEqual(['/order: must be an integer']);
    expect(errs(lessonJson(1, { order: 1.5 }))).toEqual(['/order: must be an integer']);
    expect(errs(lessonJson(1, { editable: 'src/main.mojo' }))).toEqual(['/editable: must be an array']);
    expect(errs(lessonJson(1, { editable: [1] }))).toEqual(['/editable/0: must be a string']);
    expect(errs(lessonJson(1, { actions: 'mopm run x' }))).toEqual(['/actions: must be an object']);
  });

  test('order from 1', () => {
    expect(errs(lessonJson(0))).toEqual(['/order: must be at least 1']);
    expect(errs(lessonJson(-3))).toEqual(['/order: must be at least 1']);
  });

  // Lengths count code points (JSON Schema's rule), so an astral character is one, not two UTF-16 units.
  test('title and summary lengths at and past their bounds', () => {
    expect(errs(lessonJson(1, { title: '' }))).toEqual(['/title: must be at least 1 characters']);
    expect(errs(lessonJson(1, { title: 'x'.repeat(80) }))).toEqual([]);
    expect(errs(lessonJson(1, { title: '😀'.repeat(80) }))).toEqual([]);
    expect(errs(lessonJson(1, { title: 'x'.repeat(81) }))).toEqual(['/title: must be at most 80 characters']);
    expect(errs(lessonJson(1, { summary: 'x'.repeat(280) }))).toEqual([]);
    expect(errs(lessonJson(1, { summary: 'x'.repeat(281) }))).toEqual(['/summary: must be at most 280 characters']);
    expect(errs(lessonJson(1, { summary: '' }))).toEqual(['/summary: must be at least 1 characters']);
  });

  test('editable: at least one, no repeat, each a ProjectPath', () => {
    expect(errs(lessonJson(1, { editable: [] }))).toEqual(['/editable: must hold at least 1 item']);
    expect(errs(lessonJson(1, { editable: ['a.mojo', 'b.mojo', 'a.mojo'] }))).toEqual(['/editable/2: repeats /editable/0']);
    expect(errs(lessonJson(1, { editable: ['../x'] }))).toEqual(['/editable/0: "../x" does not match ^\\.?[A-Za-z0-9_-][A-Za-z0-9_.-]*(/\\.?[A-Za-z0-9_-][A-Za-z0-9_.-]*)*$']);
  });

  test.each([
    ['src/main.mojo', true],
    ['.gitignore', true],
    ['a/.hidden/b', true],
    ['x'.repeat(255), true],
    ['x'.repeat(256), false],
    ['', false],
    ['/etc/passwd', false],
    ['..', false],
    ['.', false],
    ['a/../b', false],
    ['a/./b', false],
    ['a//b', false],
    ['a/', false],
    ['a\\b', false],
    ['..hidden', false],
    ['src/main mojo', false],
    ['src/é.mojo', false],
  ])('ProjectPath %j passes: %s', (p, ok) => {
    expect(defErrs('ProjectPath', p).length === 0).toBe(ok);
  });

  test.each([
    ['hello', true],
    ['structs-2', true],
    ['2', true],
    ['a'.repeat(64), true],
    ['a'.repeat(65), false],
    ['Hello', false],
    ['hello_world', false],
    ['hello--world', false],
    ['-hello', false],
    ['hello-', false],
    ['', false],
    ['héllo', false],
  ])('LessonId %j passes: %s', (id, ok) => {
    expect(defErrs('LessonId', id).length === 0).toBe(ok);
  });

  test.each([
    ['mopm run src/main.mojo', true],
    ['mopm run a b=c d:e ./f', true],
    ['mopm run', false],
    ['mopm run ', false],
    ['mopm run  x', false],
    ['mopm run x; rm -rf /', false],
    ['mopm run $(id)', false],
    ['mopm build x', false],
    [`mopm run ${'x'.repeat(191)}`, true],
    [`mopm run ${'x'.repeat(192)}`, false],
  ])('the run action %j passes: %s', (run, ok) => {
    expect(errs(lessonJson(1, { actions: { run } })).length === 0).toBe(ok);
  });

  test.each([
    ['mopm test', true],
    ['mopm test --filter=x', true],
    ['mopm test ', false],
    ['mopm tests', false],
    ['mopm test | cat', false],
  ])('the test action %j passes: %s', (t, ok) => {
    expect(errs(lessonJson(1, { actions: { run: 'mopm run x', test: t } })).length === 0).toBe(ok);
  });

  test('every problem is reported, fields in name order', () => {
    expect(errs({ title: '', order: 0, editable: [], actions: {}, extra: 1 })).toEqual([
      '/summary: is required and missing',
      '/actions/run: is required and missing',
      '/editable: must hold at least 1 item',
      '/extra: is not a field the schema allows',
      '/order: must be at least 1',
      '/title: must be at least 1 characters',
    ]);
  });

  test('a schema without properties or required takes any field; minItems above one says items', () => {
    const o = { type: 'object' } as Json;
    expect(schemaErrors(o, o, { a: 1, b: [] })).toEqual([]);
    const a = { type: 'array', minItems: 2 } as Json;
    expect(schemaErrors(a, a, ['x'])).toEqual(['/: must hold at least 2 items']);
    expect(schemaErrors(a, a, ['x', 'y'])).toEqual([]);
  });

  test('a repeat is found by value, an object\'s keys in any order', () => {
    const s = { type: 'array', uniqueItems: true } as Json;
    expect(schemaErrors(s, s, [{ a: 1, b: [2] }, { b: [2], a: 1 }])).toEqual(['/1: repeats /0']);
    expect(schemaErrors(s, s, [{ a: 1 }, { a: 2 }, 'a', 1, null])).toEqual([]);
  });
});

describe('a schema the check does not implement is refused', () => {
  test('the repository schema is implemented', () => {
    expect(() => assertSupported(SCHEMA)).not.toThrow();
  });

  test.each([
    ['an unknown keyword', { type: 'object', oneOf: [] }, '/: the keyword oneOf'],
    ['an unknown keyword in a property', { properties: { a: { enum: [1] } } }, '/properties/a: the keyword enum'],
    ['an unknown keyword in a def', { $defs: { A: { format: 'uri' } } }, '/$defs/A: the keyword format'],
    ['an unknown keyword in items', { items: { maximum: 3 } }, '/items: the keyword maximum'],
    ['a type it does not implement', { type: 'number' }, '/: the type "number"'],
    ['a list of types', { type: ['string', 'null'] }, '/: the type ["string","null"]'],
    ['additionalProperties as a schema', { additionalProperties: {} }, '/: additionalProperties {}'],
    ['additionalProperties true', { additionalProperties: true }, '/: additionalProperties true'],
    ['a remote $ref', { $ref: 'https://example.com/s.json' }, '/: the $ref "https://example.com/s.json"'],
    ['a $ref to a missing def', { $ref: '#/$defs/Gone' }, '/: the $ref "#/$defs/Gone"'],
    ['uniqueItems false', { uniqueItems: false }, '/: uniqueItems false'],
    ['a required that is not a list', { required: 'a' }, '/: a required that is not a list of names'],
    ['a required holding a non-name', { required: [1] }, '/: a required that is not a list of names'],
    ['a negative maxLength', { maxLength: -1 }, '/: maxLength -1'],
    ['a fractional minItems', { minItems: 0.5 }, '/: minItems 0.5'],
    ['a minimum that is not a number', { minimum: '1' }, '/: minimum "1"'],
    ['a pattern that is not a string', { pattern: 1 }, '/: pattern 1'],
    ['a schema that is not an object', true, '/: a schema that is not an object'],
    ['properties that are not an object', { properties: [] }, '/: properties that are not an object'],
    ['$defs that are not an object', { $defs: 1 }, '/: $defs that are not an object'],
  ])('%s', (_what, schema, where) => {
    expect(() => assertSupported(schema as Json)).toThrow(`${LESSON_SCHEMA}: ${where}, which the site's lesson check does not implement`);
  });

  test('a lesson schema file using an unimplemented keyword fails readLessonSchema', () => {
    const d = scratch('s-');
    dirs.push(d);
    writeFileSync(join(d, 'schema.json'), JSON.stringify({ type: 'object', not: {} }));
    expect(() => readLessonSchema(join(d, 'schema.json'))).toThrow(`${LESSON_SCHEMA}: /: the keyword not`);
  });
});

describe('a bad lesson is refused, naming the lesson and the field', () => {
  test('a tree of good lessons passes, sorted by order and not by name', () => {
    const lessons = loadLessons(tree({ a: goodLesson(2), b: goodLesson(1), c: goodLesson(10) }), SCHEMA);
    expect(lessons.map((l) => [l.id, l.order])).toEqual([['b', 1], ['a', 2], ['c', 10]]);
    expect(lessons[0].source).toBe('tutorial/lessons/b/lesson.md');
  });

  test("each editable file's text is read, in editable's order, as the page will carry it", () => {
    const t = tree({ hello: { ...goodLesson(1), json: lessonJson(1, { editable: ['src/main.mojo', 'b.mojo'] }), project: ['src/main.mojo', 'b.mojo'] } });
    writeFileSync(join(t, 'hello', 'project', 'b.mojo'), '\n\tfn b(): pass  # é <&>\n');
    expect(loadLessons(t, SCHEMA)[0].files).toEqual([
      { path: 'src/main.mojo', text: '# src/main.mojo\n' },
      { path: 'b.mojo', text: '\n\tfn b(): pass  # é <&>\n' },
    ]);
  });

  // Defect caught: a lesson page whose editor starts from text other than the project's (a browser reads a CR in the
  // page's HTML as a newline and replaces a NUL; bytes that are not UTF-8 would be decoded into replacement characters).
  test.each([
    ['a CRLF line end', Buffer.from('fn main():\r\n    pass\r\n'), 'holds a carriage return (the page would read it as a newline); use LF line ends'],
    ['a lone CR', Buffer.from('a\rb'), 'holds a carriage return (the page would read it as a newline); use LF line ends'],
    ['a NUL', Buffer.from('a\u0000b'), 'holds a NUL character, which the page cannot carry'],
    ['bytes that are not UTF-8', Buffer.from([0x66, 0x6e, 0xff, 0x0a]), 'is not UTF-8 text'],
  ])('an editable file with %s is refused', (_what, bytes, problem) => {
    const t = tree({ hello: goodLesson(1) });
    writeFileSync(join(t, 'hello', 'project', 'src', 'main.mojo'), bytes);
    expect(problems(t)).toEqual([`tutorial/lessons/hello: project/src/main.mojo: ${problem}`]);
  });

  test('an editable path that does not exist under project/', () => {
    const t = tree({ hello: { ...goodLesson(1), json: lessonJson(1, { editable: ['src/main.mojo', 'src/gone.mojo'] }) } });
    expect(problems(t)).toEqual(['tutorial/lessons/hello: lesson.json: /editable: src/gone.mojo is not a file under project/']);
  });

  test('an editable path naming a directory, and one naming lesson.md beside project/', () => {
    const t = tree({ hello: { ...goodLesson(1), json: lessonJson(1, { editable: ['src', 'lesson.md'] }) } });
    expect(problems(t)).toEqual([
      'tutorial/lessons/hello: lesson.json: /editable: src is not a file under project/',
      'tutorial/lessons/hello: lesson.json: /editable: lesson.md is not a file under project/',
    ]);
  });

  test('an editable path through a symbolic link to a file is followed; a dangling one is refused', () => {
    const t = tree({ hello: { ...goodLesson(1), json: lessonJson(1, { editable: ['src/main.mojo', 'link.mojo'] }) } });
    symlinkSync('src/main.mojo', join(t, 'hello', 'project', 'link.mojo'));
    expect(loadLessons(t, SCHEMA)).toHaveLength(1);
    rmSync(join(t, 'hello', 'project', 'src', 'main.mojo'));
    expect(problems(t)).toEqual([
      'tutorial/lessons/hello: lesson.json: /editable: src/main.mojo is not a file under project/',
      'tutorial/lessons/hello: lesson.json: /editable: link.mojo is not a file under project/',
    ]);
  });

  test.each([
    ['Hello'],
    ['hello_world'],
    ['hello--world'],
    ['-x'],
    ['a'.repeat(65)],
  ])('an id out of grammar: %j', (id) => {
    expect(problems(tree({ [id]: goodLesson(1) }))).toEqual([
      `tutorial/lessons/${id}: the lesson id "${id}" is not a LessonId (lower-case letters and digits, words joined by single hyphens, at most 64)`,
    ]);
  });

  test('an id at the length bound passes', () => {
    expect(loadLessons(tree({ ['a'.repeat(64)]: goodLesson(1) }), SCHEMA)).toHaveLength(1);
  });

  test('a duplicate order names both lessons; a third lesson with it is refused too', () => {
    expect(problems(tree({ a: goodLesson(1), b: goodLesson(1), c: goodLesson(2), d: goodLesson(1) }))).toEqual([
      'tutorial/lessons/b: lesson.json: /order: 1 is also the order of the lesson a',
      'tutorial/lessons/d: lesson.json: /order: 1 is also the order of the lesson a',
    ]);
  });

  test('a missing action', () => {
    const t = tree({ hello: { ...goodLesson(1), json: lessonJson(1, { actions: { test: 'mopm test' } }) } });
    expect(problems(t)).toEqual(['tutorial/lessons/hello: lesson.json: /actions/run: is required and missing']);
    const u = tree({ hello: { ...goodLesson(1), json: { ...lessonJson(1), actions: undefined } } });
    expect(problems(u)).toEqual(['tutorial/lessons/hello: lesson.json: /actions: is required and missing']);
  });

  test('a lesson.json that is missing, not JSON, or not a file', () => {
    const t = tree({ a: { ...goodLesson(1), json: undefined }, b: { ...goodLesson(2), json: '{"title":' }, c: { ...goodLesson(3), json: undefined } });
    mkdirSync(join(t, 'c', 'lesson.json'));
    expect(problems(t)).toEqual([
      'tutorial/lessons/a: lesson.json is not a file',
      'tutorial/lessons/b: lesson.json is not JSON',
      'tutorial/lessons/c: lesson.json is not a file',
    ]);
  });

  test('a lesson.md that is missing or empty', () => {
    expect(problems(tree({ a: { ...goodLesson(1), md: undefined }, b: { ...goodLesson(2), md: '' } }))).toEqual([
      'tutorial/lessons/a: lesson.md is not a file',
      'tutorial/lessons/b: lesson.md is empty',
    ]);
  });

  test('a file directly under tutorial/lessons, a dangling link there, no lesson, and no directory', () => {
    const t = tree({ hello: goodLesson(1) });
    writeFileSync(join(t, 'README.md'), 'x\n');
    symlinkSync('gone', join(t, 'zz'));
    expect(problems(t)).toEqual([
      'tutorial/lessons/README.md: not a directory; a lesson is a directory with lesson.md, lesson.json and project/',
      'tutorial/lessons/zz: not a directory; a lesson is a directory with lesson.md, lesson.json and project/',
    ]);
    expect(problems(tree({}))).toEqual(['tutorial/lessons: no lesson; the tutorial needs at least one']);
    const gone = join(dirname(t), 'nothing');
    expect(existsSync(gone)).toBe(false);
    expect(problems(gone)).toEqual(['tutorial/lessons: there is no such directory']);
  });

  test('every problem of every lesson is reported at once', () => {
    const t = tree({
      Bad: goodLesson(1),
      dup: goodLesson(1),
      gone: { ...goodLesson(3), json: lessonJson(3, { editable: ['nope.mojo'] }) },
      noaction: { ...goodLesson(4), json: lessonJson(4, { actions: {} }) },
    });
    expect(problems(t)).toEqual([
      'tutorial/lessons/Bad: the lesson id "Bad" is not a LessonId (lower-case letters and digits, words joined by single hyphens, at most 64)',
      'tutorial/lessons/dup: lesson.json: /order: 1 is also the order of the lesson Bad',
      'tutorial/lessons/gone: lesson.json: /editable: nope.mojo is not a file under project/',
      'tutorial/lessons/noaction: lesson.json: /actions/run: is required and missing',
    ]);
  });

  test('a bad lesson fails the build before it writes anything', () => {
    const t = tree({ hello: { ...goodLesson(1), json: lessonJson(1, { editable: ['src/gone.mojo'] }) } });
    const f = fixture({}, t);
    made.push(f);
    expect(() => f.build()).toThrow(LessonError);
    expect(() => f.build()).toThrow('tutorial/lessons/hello: lesson.json: /editable: src/gone.mojo is not a file under project/');
    expect(existsSync(f.outDir)).toBe(false);
  });
});
