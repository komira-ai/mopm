// The lessons of the interactive tutorial, as the site build reads them: tutorial/lessons/<id>/lesson.md (the text) and
// lesson.json, checked against spec/tutorial-lesson.schema.json and the rules of it JSON Schema cannot say. A bad lesson
// fails the build with every problem found, each `<lesson directory>: <what is wrong>`, naming the field.
//
// The schema is read from the file, not copied: `schemaErrors` interprets the keywords the schema uses (type, required,
// properties, additionalProperties: false, $ref into $defs, minLength, maxLength, pattern, minimum, minItems,
// uniqueItems, items) and refuses a schema holding any other keyword, so a schema change this check does not implement
// fails the build instead of passing lessons unchecked. The site has no JSON Schema library and takes none (README.md,
// rule 1, and the build's own dependencies are dev dependencies only).
//
// The rules beyond the schema are those of tests/drivers/tutorial_lessons.zig (//:tutorial_lessons), which checks the
// same tree on every pull request; the site build checks the half it reads, so it never renders a lesson the contract
// refuses:
//  - the id (the directory's name) is the schema's $defs/LessonId;
//  - lesson.md is a file that is not empty, and lesson.json a file holding JSON that passes the schema;
//  - each editable path names a file under project/ (the schema has already refused '..', absolute paths and
//    backslashes; a symbolic link is followed, as the template's copy does);
//  - (this check's own) each editable file is UTF-8 text with no carriage return and no NUL, since the lesson's page
//    carries it as HTML text, which a browser reads back with a CR as a newline and a NUL replaced;
//  - no two lessons share an order;
//  - a file directly under tutorial/lessons is refused, and so is a tree with no lesson.
// One rule of the driver is left to it: an order written as 1.0 or 1e30 (the schema's integer takes both). JSON.parse
// reads either as a number, so this check cannot see the spelling.

import { readdirSync, readFileSync, statSync } from 'fs';
import { join } from 'path';

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type JsonObject = { [key: string]: Json };

/** The repository paths the build reads the lessons and their schema from. */
export const LESSONS_DIR = 'tutorial/lessons';
export const LESSON_SCHEMA = 'spec/tutorial-lesson.schema.json';

export interface Lesson {
  /** The directory's name: the <lesson> of /tutorial/<lesson>. */
  id: string;
  /** The repository path of lesson.md, which relative links in it resolve against. */
  source: string;
  title: string;
  summary: string;
  order: number;
  editable: readonly string[];
  /** Each editable file's path and its text under project/, in `editable`'s order. */
  files: readonly { path: string; text: string }[];
  actions: { run: string; test?: string };
  /** lesson.md as it is. */
  markdown: string;
}

export class LessonError extends Error {
  constructor(readonly problems: readonly string[]) {
    super(`tutorial lessons check failed:\n  ${problems.join('\n  ')}`);
    this.name = 'LessonError';
  }
}

// Annotations carry no rule; every other keyword below is one schemaErrors implements.
const ANNOTATIONS = new Set(['$schema', '$id', '$comment', 'title', 'description']);
const KEYWORDS = new Set([
  ...ANNOTATIONS,
  '$defs', '$ref', 'type', 'required', 'properties', 'additionalProperties', 'minLength', 'maxLength', 'pattern', 'minimum',
  'minItems', 'uniqueItems', 'items',
]);
const TYPES = new Set(['string', 'integer', 'object', 'array']);

const isObject = (v: Json | undefined): v is JsonObject => typeof v === 'object' && v !== null && !Array.isArray(v);

/**
 * Throws unless every subschema of `schema` uses only the keywords schemaErrors implements, with the values it
 * implements (a `type` of string, integer, object or array; `additionalProperties` false; a local `$ref` to a $defs entry).
 */
export function assertSupported(schema: Json): void {
  const schemaRoot = schema;
  const refuse = (at: string, what: string): never => {
    throw new Error(`${LESSON_SCHEMA}: ${at || '/'}: ${what}, which the site's lesson check does not implement`);
  };
  const walk = (s: Json, at: string): void => {
    if (!isObject(s)) refuse(at, 'a schema that is not an object');
    const o = s as JsonObject;
    for (const [k, v] of Object.entries(o)) {
      if (!KEYWORDS.has(k)) refuse(at, `the keyword ${k}`);
      if (k === 'type' && !(typeof v === 'string' && TYPES.has(v))) refuse(at, `the type ${JSON.stringify(v)}`);
      if (k === 'additionalProperties' && v !== false) refuse(at, `additionalProperties ${JSON.stringify(v)}`);
      if (k === '$ref' && !(typeof v === 'string' && /^#\/\$defs\/[^/~]+$/.test(v) && isObject(defs(schemaRoot)[v.slice(8)]))) refuse(at, `the $ref ${JSON.stringify(v)}`);
      if (k === 'uniqueItems' && v !== true) refuse(at, `uniqueItems ${JSON.stringify(v)}`);
      if (k === 'required' && !(Array.isArray(v) && v.every((x) => typeof x === 'string'))) refuse(at, 'a required that is not a list of names');
      if ((k === 'minLength' || k === 'maxLength' || k === 'minItems') && !(typeof v === 'number' && Number.isInteger(v) && v >= 0)) refuse(at, `${k} ${JSON.stringify(v)}`);
      if (k === 'minimum' && typeof v !== 'number') refuse(at, `minimum ${JSON.stringify(v)}`);
      if (k === 'pattern' && typeof v !== 'string') refuse(at, `pattern ${JSON.stringify(v)}`);
    }
    if (o.properties !== undefined) {
      if (!isObject(o.properties)) refuse(at, 'properties that are not an object');
      for (const [k, v] of Object.entries(o.properties as JsonObject)) walk(v, `${at}/properties/${k}`);
    }
    if (o.$defs !== undefined) {
      if (!isObject(o.$defs)) refuse(at, '$defs that are not an object');
      for (const [k, v] of Object.entries(o.$defs as JsonObject)) walk(v, `${at}/$defs/${k}`);
    }
    if (o.items !== undefined) walk(o.items, `${at}/items`);
  };
  walk(schema, '');
}

function defs(root: Json): JsonObject {
  return isObject(root) && isObject(root.$defs) ? root.$defs : {};
}

/** JSON values compared as JSON Schema compares them: by value, an object's keys in any order. */
function canonical(v: Json): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  if (isObject(v)) return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(',')}}`;
  return JSON.stringify(v);
}

function typeOk(type: string, v: Json): boolean {
  if (type === 'string') return typeof v === 'string';
  if (type === 'integer') return typeof v === 'number' && Number.isInteger(v);
  if (type === 'object') return isObject(v);
  return Array.isArray(v);
}

/**
 * Where `value` breaks `schema` (a subschema of `root`, which $ref resolves in), each `<JSON pointer>: <what>`; empty
 * when it passes. `schema` must have passed assertSupported. Lengths count code points, as JSON Schema does.
 */
export function schemaErrors(root: Json, schema: Json, value: Json, at = ''): string[] {
  const s = schema as JsonObject;
  const where = at || '/';
  if (typeof s.$ref === 'string') return schemaErrors(root, defs(root)[s.$ref.slice('#/$defs/'.length)], value, at);
  if (typeof s.type === 'string' && !typeOk(s.type, value)) return [`${where}: must be ${/^[aeiou]/.test(s.type) ? 'an' : 'a'} ${s.type}`];
  const out: string[] = [];
  if (typeof value === 'string') {
    const n = [...value].length;
    if (typeof s.minLength === 'number' && n < s.minLength) out.push(`${where}: must be at least ${s.minLength} characters`);
    if (typeof s.maxLength === 'number' && n > s.maxLength) out.push(`${where}: must be at most ${s.maxLength} characters`);
    if (typeof s.pattern === 'string' && !new RegExp(s.pattern, 'u').test(value)) out.push(`${where}: ${JSON.stringify(value)} does not match ${s.pattern}`);
  }
  if (typeof value === 'number' && typeof s.minimum === 'number' && value < s.minimum) out.push(`${where}: must be at least ${s.minimum}`);
  if (Array.isArray(value)) {
    if (typeof s.minItems === 'number' && value.length < s.minItems) out.push(`${where}: must hold at least ${s.minItems} item${s.minItems === 1 ? '' : 's'}`);
    if (s.uniqueItems === true) {
      const seen = new Map<string, number>();
      value.forEach((x, i) => {
        const k = canonical(x);
        const first = seen.get(k);
        if (first === undefined) seen.set(k, i);
        else out.push(`${at}/${i}: repeats ${at}/${first}`);
      });
    }
    if (s.items !== undefined) value.forEach((x, i) => out.push(...schemaErrors(root, s.items as Json, x, `${at}/${i}`)));
  }
  if (isObject(value)) {
    const props = isObject(s.properties) ? s.properties : {};
    for (const k of Array.isArray(s.required) ? (s.required as string[]) : []) {
      if (!Object.prototype.hasOwnProperty.call(value, k)) out.push(`${at}/${k}: is required and missing`);
    }
    for (const k of Object.keys(value).sort()) {
      if (Object.prototype.hasOwnProperty.call(props, k)) out.push(...schemaErrors(root, props[k], value[k], `${at}/${k}`));
      else if (s.additionalProperties === false) out.push(`${at}/${k}: is not a field the schema allows`);
    }
  }
  return out;
}

/** The schema at `path`, after assertSupported. */
export function readLessonSchema(path: string): Json {
  const schema = JSON.parse(readFileSync(path, 'utf8')) as Json;
  assertSupported(schema);
  return schema;
}

/** Whether `path` is a file, or a directory (`dir`), a symbolic link followed; false when nothing is there. */
function isA(path: string, dir: boolean): boolean {
  try {
    const st = statSync(path);
    return dir ? st.isDirectory() : st.isFile();
  } catch {
    return false;
  }
}

/** A file's text, or null when there is no file there. */
function readFile(path: string): string | null {
  return isA(path, false) ? readFileSync(path, 'utf8') : null;
}

/**
 * An editable file's text, null when there is no file there, or a problem when the lesson page cannot carry it as it is:
 * the page holds it as HTML text (src/tutorial/view.ts lessonSource), which a browser reads back with every CR turned
 * into a newline and every NUL replaced, and as UTF-8.
 */
function editableText(path: string): string | { problem: string } | null {
  if (!isA(path, false)) return null;
  let text: string;
  try {
    text = new TextDecoder('utf-8', { fatal: true }).decode(readFileSync(path));
  } catch {
    return { problem: 'is not UTF-8 text' };
  }
  if (text.includes('\r')) return { problem: 'holds a carriage return (the page would read it as a newline); use LF line ends' };
  if (text.includes('\0')) return { problem: 'holds a NUL character, which the page cannot carry' };
  return text;
}

/**
 * Every lesson under `dir` (the repository's tutorial/lessons), in order; throws a LessonError listing every problem.
 * `label` is how messages name `dir` (its repository path).
 */
export function loadLessons(dir: string, schema: Json, label = LESSONS_DIR): Lesson[] {
  const problems: string[] = [];
  let names: string[] = [];
  try {
    names = readdirSync(dir).sort();
  } catch {
    throw new LessonError([`${label}: there is no such directory`]);
  }
  const idSchema = defs(schema).LessonId;
  const lessons: Lesson[] = [];
  const byOrder = new Map<number, string>();
  for (const id of names) {
    const where = `${label}/${id}`;
    const lessonDir = join(dir, id);
    if (!isA(lessonDir, true)) {
      problems.push(`${where}: not a directory; a lesson is a directory with lesson.md, lesson.json and project/`);
      continue;
    }
    if (schemaErrors(schema, idSchema, id).length > 0) {
      problems.push(`${where}: the lesson id "${id}" is not a LessonId (lower-case letters and digits, words joined by single hyphens, at most 64)`);
    }
    const markdown = readFile(join(lessonDir, 'lesson.md'));
    if (markdown === null) problems.push(`${where}: lesson.md is not a file`);
    else if (markdown === '') problems.push(`${where}: lesson.md is empty`);
    const text = readFile(join(lessonDir, 'lesson.json'));
    if (text === null) {
      problems.push(`${where}: lesson.json is not a file`);
      continue;
    }
    let doc: Json;
    try {
      doc = JSON.parse(text) as Json;
    } catch {
      problems.push(`${where}: lesson.json is not JSON`);
      continue;
    }
    const errs = schemaErrors(schema, schema, doc);
    for (const e of errs) problems.push(`${where}: lesson.json: ${e}`);
    if (errs.length > 0) continue;
    const l = doc as unknown as Omit<Lesson, 'id' | 'source' | 'markdown' | 'files'>;
    const files: { path: string; text: string }[] = [];
    for (const p of l.editable) {
      const text = editableText(join(lessonDir, 'project', p));
      if (text === null) problems.push(`${where}: lesson.json: /editable: ${p} is not a file under project/`);
      else if (typeof text !== 'string') problems.push(`${where}: project/${p}: ${text.problem}`);
      else files.push({ path: p, text });
    }
    const other = byOrder.get(l.order);
    if (other !== undefined) problems.push(`${where}: lesson.json: /order: ${l.order} is also the order of the lesson ${other}`);
    else byOrder.set(l.order, id);
    if (markdown) {
      lessons.push({
        id,
        source: `${where}/lesson.md`,
        title: l.title,
        summary: l.summary,
        order: l.order,
        editable: l.editable,
        files,
        actions: { ...l.actions },
        markdown,
      });
    }
  }
  if (names.length === 0) problems.push(`${label}: no lesson; the tutorial needs at least one`);
  if (problems.length > 0) throw new LessonError(problems);
  return lessons.sort((a, b) => a.order - b.order);
}
