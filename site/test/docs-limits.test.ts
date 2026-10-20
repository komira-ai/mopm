// The published docs state the registry's size limits; the numbers come from the validator's limits.ts, not from memory.
// limits.ts has two different caps and the docs once called the archive's cap a per-file cap: the number is pinned
// together with its noun (the uploaded package file vs any one unpacked file).
import { readFileSync } from 'fs';
import { join } from 'path';
import { REPO_ROOT } from './build-fixture';

const read = (p: string) => readFileSync(join(REPO_ROOT, p), 'utf8').replace(/\s+/g, ' ');

/** The numeric initialiser of a Limits field in limits.ts, evaluated (digits, `_` and `*` only). */
function limit(field: string): number {
  const m = new RegExp(`${field}:\\s*([0-9_ *]+),`).exec(read('service/api/src/validate/limits.ts'));
  if (!m) throw new Error(`limits.ts has no numeric ${field}`);
  return m[1].split('*').reduce((a, t) => a * Number(t.trim().replace(/_/g, '')), 1);
}

const ARCHIVE_MB = `${limit('maxArchiveBytes') / 1e6} MB`;
const FILE_MIB = `${limit('maxFileBytes') / (1024 * 1024)} MiB`;

test('limits.ts holds the numbers this test derives the docs from', () => {
  expect([ARCHIVE_MB, FILE_MIB]).toEqual(['100 MB', '128 MiB']);
});

const DOCS: [string, string, string][] = [
  ['docs/getting-started.md', `${ARCHIVE_MB} per package file`, `${FILE_MIB} per unpacked file`],
  ['docs/why-and-design.md', `a package file of at most ${ARCHIVE_MB}`, `any one unpacked file of at most ${FILE_MIB}`],
];

// The configuration page states the cap that the CLI itself enforces before a request (publish_cmd.zig max_file_bytes), with
// its noun, and the readme cap that limits.ts and the CLI share.
test('docs/configuration.md states the package-file cap with its noun, and the readme cap', () => {
  const text = read('docs/configuration.md');
  expect(text).toContain(`a package file over ${ARCHIVE_MB}`);
  expect(text).toContain('of at most 64 KiB (65,536 bytes)');
  expect(text).toContain('over 64 KiB');
});

test.each(DOCS)('%s states the archive cap and the per-unpacked-file cap, each with its noun', (doc, archive, file) => {
  const text = read(doc);
  expect(text).toContain(archive);
  expect(text).toContain(file);
});

test.each(['docs/getting-started.md', 'docs/why-and-design.md', 'docs/configuration.md', 'docs/examples.md', 'README.md'])('%s never calls the archive cap a per-file cap', (doc) => {
  expect(read(doc)).not.toMatch(/\b\d+ MB per file\b/);
});
