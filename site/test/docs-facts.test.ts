// docs/configuration.md lists every key the parsers read, and no key they do not: the key lists are read from the Zig
// source of the parsers (src/core/manifest.zig, lock.zig, credentials.zig), not written again here, so a key added to a
// parser without a row on the page, a row for a key the parser refuses, or a key moved from one table to another all
// fail. The page's tables of keys all have the same columns, and each row says its type, default, allowed values and an
// example. Mutants (each planted and shown red when this test was written): a key added to a parser's list without the
// page; a row of the page renamed; a row dropped from the page; a table of the parser with no section on the page.
import { readFileSync } from 'fs';
import { join } from 'path';
import { REPO_ROOT } from './build-fixture';

const read = (p: string) => readFileSync(join(REPO_ROOT, p), 'utf8');
const sorted = (a: Iterable<string>) => [...a].sort();

// ---------------------------------------------------------------- the parsers

interface KeyList {
  /** What the parser calls the table in its messages: `onlyKeys(t, <where>, ...)`, resolved. */
  where: string;
  keys: string[];
}

/** Every `onlyKeys(<table>, <where>, &.{ "a", "b" })` of manifest.zig: the keys one table of mopm.toml may hold. */
export function manifestKeyLists(src: string): KeyList[] {
  const out: KeyList[] = [];
  for (const m of src.matchAll(/onlyKeys\(\s*[^,]+,\s*([^,]+?),\s*&\.\{([^}]*)\}\s*\)/g)) {
    let where = m[1].trim();
    if (!where.startsWith('"')) {
      // A name: the message text its last `const <name> = ...` before the call gives.
      const before = src.slice(0, m.index);
      const decl = [...before.matchAll(new RegExp(`const ${where} = (?:try std\\.fmt\\.allocPrint\\(c\\.arena, )?"([^"]+)"`, 'g'))].pop();
      if (!decl) throw new Error(`manifest.zig: no declaration of ${where} before an onlyKeys call`);
      where = decl[1];
    } else {
      where = where.slice(1, -1);
    }
    out.push({ where, keys: [...m[2].matchAll(/"([^"]+)"/g)].map((k) => k[1]) });
  }
  return out;
}

/** The keys lock.zig's `parse` reads: `<object>.get("k")` and `r.string/array(<object>, "k", ...)`. */
export function lockKeys(src: string): string[] {
  const body = src.slice(src.indexOf('pub fn parse('), src.indexOf('fn str(w: anytype'));
  const keys = new Set<string>();
  for (const m of body.matchAll(/\.get\("([a-z_0-9]+)"\)|r\.(?:string|array)\([^,]+,\s*"([a-z_0-9]+)"/g)) keys.add(m[1] ?? m[2]);
  return sorted(keys);
}

/** The keys of an entry of credentials.json: `e.get("k")` in `load`, from the file's own reader. */
export function credentialKeys(src: string): string[] {
  const body = src.slice(src.indexOf('pub fn load('), src.indexOf('pub fn store('));
  return sorted(new Set([...body.matchAll(/\be\.get\("([a-z_0-9]+)"\)/g)].map((m) => m[1])));
}

// -------------------------------------------------------------------- the page

interface Table {
  /** The nearest h2 above, then the nearest h2 or h3 above. */
  h2: string;
  heading: string;
  header: string[];
  rows: string[][];
}

const cells = (line: string) =>
  line
    .trim()
    .replace(/^\|/, '')
    .replace(/\|$/, '')
    .split(/(?<!\\)\|/)
    .map((c) => c.trim());

/** The tables of a Markdown page (outside code fences), each with the headings above it. */
export function tablesOf(md: string): Table[] {
  const out: Table[] = [];
  const lines = md.split('\n');
  let h2 = '';
  let heading = '';
  let fenced = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith('```')) fenced = !fenced;
    if (fenced) continue;
    const h = /^(#{2,3}) (.+)$/.exec(line);
    if (h) {
      heading = h[2];
      if (h[1] === '##') h2 = h[2];
      continue;
    }
    if (line.startsWith('|') && /^\|[ :|-]+\|$/.test(lines[i + 1] ?? '')) {
      const header = cells(line);
      const rows: string[][] = [];
      let j = i + 2;
      for (; j < lines.length && lines[j].startsWith('|'); j++) rows.push(cells(lines[j]));
      out.push({ h2, heading, header, rows });
      i = j - 1;
    }
  }
  return out;
}

const COLUMNS = ['key', 'type', 'default', 'allowed', 'example'];
const code = (cell: string) => {
  const m = /^`([^`]+)`$/.exec(cell);
  if (!m) throw new Error(`a key cell is a code span, not ${cell}`);
  return m[1];
};

const page = read('docs/configuration.md');
const tables = tablesOf(page);
const keyTables = tables.filter((t) => t.header[0] === 'key' && t.header.length === COLUMNS.length);

test('the page has tables of keys, and each has the same five columns', () => {
  expect(keyTables.length).toBeGreaterThan(10);
  for (const t of keyTables) expect([t.heading, t.header]).toEqual([t.heading, COLUMNS]);
});

test('every row of a table of keys says its type, default, allowed values and an example', () => {
  for (const t of keyTables) {
    for (const r of t.rows) {
      expect([t.heading, r[0], r.length]).toEqual([t.heading, r[0], COLUMNS.length]);
      for (const c of r) expect([t.heading, r[0], c === '']).toEqual([t.heading, r[0], false]);
      code(r[0]);
    }
  }
});

test('a key is a row once in a table', () => {
  for (const t of keyTables) {
    const keys = t.rows.map((r) => code(r[0]));
    expect([t.heading, keys.length]).toEqual([t.heading, new Set(keys).size]);
  }
});

// ------------------------------------------------------------------- mopm.toml

/** The parser's table (as manifest.zig's messages name it) to the section of the page that documents it. */
const TOML_SECTIONS: Record<string, string> = {
  'mopm.toml': 'Top level',
  '[package]': '`[package]`',
  '[toolchain]': '`[toolchain]`',
  "dependency '{s}'": 'Dependencies: `[dependencies]` and `[dev-dependencies]`',
  "native dependency '{s}'": 'Native dependencies: `[native-dependencies]`',
  '[native.{s}]': 'Native libraries: `[native.<id>]`',
  '[targets]': '`[targets]`',
};
/** `[targets]` holds a second table: the keys of `lib` and of each entry of `bins`. */
const TARGET_ENTRIES = ['[targets] lib', 'a [targets] bin'];

const manifest = manifestKeyLists(read('src/core/manifest.zig'));

test('manifest.zig has the tables this test knows, and the page has a section for each', () => {
  const known = [...Object.keys(TOML_SECTIONS), ...TARGET_ENTRIES];
  expect(sorted(manifest.map((l) => l.where))).toEqual(sorted(known));
  for (const heading of Object.values(TOML_SECTIONS)) {
    expect([heading, keyTables.filter((t) => t.h2 === 'mopm.toml' && t.heading === heading).length > 0]).toEqual([heading, true]);
  }
});

function pageKeys(heading: string, which: number): string[] {
  const t = keyTables.filter((x) => x.h2 === 'mopm.toml' && x.heading === heading)[which];
  if (!t) throw new Error(`no table of keys #${which} under ${heading}`);
  return t.rows.map((r) => code(r[0]));
}

function sameKeys(label: string, parser: string[], documented: string[]) {
  const missing = parser.filter((k) => !documented.includes(k));
  const extra = documented.filter((k) => !parser.includes(k));
  expect([label, 'on the page, not in the parser', extra]).toEqual([label, 'on the page, not in the parser', []]);
  expect([label, 'in the parser, not on the page', missing]).toEqual([label, 'in the parser, not on the page', []]);
}

test.each(Object.entries(TOML_SECTIONS))('mopm.toml %s: the page has every key the parser reads, and no other', (where, heading) => {
  const lists = manifest.filter((l) => l.where === where);
  expect(lists).toHaveLength(1);
  sameKeys(where, lists[0].keys, pageKeys(heading, 0));
});

test('mopm.toml [targets]: the keys of lib and of a bin entry are the second table of the section', () => {
  const entries = manifest.filter((l) => TARGET_ENTRIES.includes(l.where));
  expect(entries).toHaveLength(2);
  sameKeys('[targets] lib and bins', [...new Set(entries.flatMap((l) => l.keys))], pageKeys('`[targets]`', 1));
});

// The table of what reads each key names every key of [package] as package.<key>, and each other table by name.
test('the table of what reads each key has a row for every key of [package] and every table of mopm.toml', () => {
  const reads = tables.find((t) => t.header[0] === 'key' && t.header[1] === 'what reads it');
  if (!reads) throw new Error('no table "what reads it"');
  const names = reads.rows.map((r) => r[0]);
  const has = (needle: string) => names.some((n) => n.split(/,\s*/).some((x) => x === `\`${needle}\``));
  const pkg = manifest.find((l) => l.where === '[package]');
  const top = manifest.find((l) => l.where === 'mopm.toml');
  if (!pkg || !top) throw new Error('manifest.zig lists no [package] or top level');
  for (const k of pkg.keys) if (k !== 'name' && k !== 'version') expect([`package.${k}`, has(`package.${k}`)]).toEqual([`package.${k}`, true]);
  expect(has('package.name')).toBe(true);
  expect(has('package.version')).toBe(true);
  for (const t of top.keys.filter((k) => k !== 'package')) {
    const covered = names.some((n) => n.includes(`\`${t}\``) || n.includes(`\`${t}.`));
    expect([t, covered]).toEqual([t, true]);
  }
});

// ------------------------------------------------------------------- mopm.lock

test('mopm.lock: the page has every key lock.zig reads, and no other', () => {
  const documented = keyTables.filter((t) => t.h2 === 'mopm.lock').flatMap((t) => t.rows.map((r) => code(r[0])));
  sameKeys('mopm.lock', lockKeys(read('src/core/lock.zig')), sorted(new Set(documented)));
});

// ---------------------------------------------------------- credentials.json

test('credentials.json: the page has the keys of an entry that credentials.zig reads, and no other', () => {
  const t = keyTables.find((x) => x.heading === 'credentials.json');
  if (!t) throw new Error('no table of keys under credentials.json');
  sameKeys('credentials.json', credentialKeys(read('src/core/credentials.zig')), t.rows.map((r) => code(r[0])));
});

// The extractors read the Zig they are given: pinned on small inputs, so that an extractor that finds nothing cannot
// make the checks above pass (every comparison would then be an empty set on one side only, but a parser that stops
// matching the pattern would otherwise read as "no keys").
test('the extractors find what they are written to find', () => {
  const zig = [
    'const where = "[package]";',
    'try c.onlyKeys(t, where, &.{ "name", "version" });',
    'const in = try std.fmt.allocPrint(c.arena, "dependency \'{s}\'", .{e.key});',
    'try c.onlyKeys(sub, in, &.{ "version", "path" });',
    'try c.onlyKeys(root, "mopm.toml", &.{',
    '    "package", "toolchain",',
    '});',
  ].join('\n');
  expect(manifestKeyLists(zig)).toEqual([
    { where: '[package]', keys: ['name', 'version'] },
    { where: "dependency '{s}'", keys: ['version', 'path'] },
    { where: 'mopm.toml', keys: ['package', 'toolchain'] },
  ]);
  expect(manifest.every((l) => l.keys.length > 0)).toBe(true);
  expect(lockKeys('pub fn parse(a) {\n top.get("lock_version"); r.string(o, "name", w); r.array(o, "deps", w, false);\n}\nfn str(w: anytype')).toEqual(['deps', 'lock_version', 'name']);
  expect(credentialKeys('pub fn load() { e.get("token"); e.get("handle"); }\npub fn store(')).toEqual(['handle', 'token']);
});
