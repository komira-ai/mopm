import * as fs from 'fs';
import * as path from 'path';
import { validatePackage, type Limits, type PublishExpectation, type Verdict } from '../../src/validate';

/**
 * The validator corpus: the TypeScript validator against files, with the verdict of every file recorded.
 *
 * `tests/validator_corpus/` holds archives (written byte by byte by tests/drivers/validator_corpus.zig, no
 * library in between), `cases.json` (for each case: the archive, what the publisher declared, the limits in force,
 * and the rule the case was written to hit) and `verdicts.json` (what this validator answered, recorded). A
 * second implementation of the validator, in Rust, is held to the same file: same verdict, same rule, and so the
 * same order of rejection when an input is wrong in two ways.
 *
 * What this test proves:
 *  - the recorded verdict of every case is what the validator answers now (a changed rule, code, message or
 *    fact is a changed behaviour: review it as one);
 *  - the rule each case was written to hit is the rule the validator reports, so a case that stopped reaching its
 *    fault (an archive that is wrong in some other way) is found, and a validator that reads its rules in another
 *    order is found by the cases that are wrong in two ways;
 *  - nothing in the corpus is unaccounted for.
 * What it does not prove: that the recorded behaviour is the right one. The cases say what each was meant to show;
 * the verdict says what happened.
 *
 * A failing run prints the verdicts it got in base64 (CI logs mask text that looks like a credential); that is how
 * `verdicts.json` is made.
 */

const DIR = path.resolve(__dirname, '../../../../tests/validator_corpus');

interface CaseSpec {
  id: string;
  archive: string;
  intent: string;
  what: string;
  expect: { name: string; version: string; subdir: string; filename: string; sha256?: string; manifest_sha256?: string };
  limits: Record<string, number>;
  allow_native: string[];
  note: string;
}

const LIMIT_KEYS: Record<string, keyof Limits> = {
  max_archive_bytes: 'maxArchiveBytes',
  max_file_bytes: 'maxFileBytes',
  max_unpacked_bytes: 'maxUnpackedBytes',
  max_files: 'maxFiles',
  max_ratio: 'maxRatio',
  ratio_floor_bytes: 'ratioFloorBytes',
  max_metadata_bytes: 'maxMetadataBytes',
};

const cases: CaseSpec[] = JSON.parse(fs.readFileSync(path.join(DIR, 'cases.json'), 'utf8')).cases;

/** The verdict as JSON: what a second implementation must reproduce. A crash of the validator itself is recorded by its error name. */
function verdictOf(c: CaseSpec): unknown {
  const bytes = fs.readFileSync(path.join(DIR, 'archives', c.archive));
  const expected: PublishExpectation = {
    name: c.expect.name,
    version: c.expect.version,
    subdir: c.expect.subdir,
    filename: c.expect.filename,
    ...(c.expect.sha256 !== undefined ? { sha256: c.expect.sha256 } : {}),
    ...(c.expect.manifest_sha256 !== undefined ? { manifestSha256: c.expect.manifest_sha256 } : {}),
  };
  const limits: Partial<Limits> = {};
  for (const [k, v] of Object.entries(c.limits)) limits[LIMIT_KEYS[k]!] = v;
  let v: Verdict;
  try {
    v = validatePackage(bytes, expected, { limits, allowedNativeDeps: new Set(c.allow_native) });
  } catch (err) {
    return { crash: (err as Error).name };
  }
  return JSON.parse(JSON.stringify(v));
}

const outcomeOf = (v: unknown): string => {
  const o = v as { ok?: boolean; rule?: string; crash?: string };
  return o.crash !== undefined ? `crash ${o.crash}` : o.ok ? 'ok' : String(o.rule);
};

const VERDICTS = path.join(DIR, 'verdicts.json');
const recorded: { format: number; verdicts: Array<{ id: string; verdict: unknown }> } = fs.existsSync(VERDICTS)
  ? JSON.parse(fs.readFileSync(VERDICTS, 'utf8'))
  : { format: 1, verdicts: [] };

describe('the validator corpus', () => {
  test('cases, archives and verdicts account for each other', () => {
    expect(cases.length).toBeGreaterThan(100);
    expect(new Set(cases.map((c) => c.id)).size).toBe(cases.length);
    const files = fs.readdirSync(path.join(DIR, 'archives')).sort();
    expect(files).toEqual([...new Set(cases.map((c) => c.archive))].sort());
    expect(recorded.verdicts.map((v) => v.id)).toEqual(cases.map((c) => c.id));
  });

  test('verdicts.json is what the validator answers (all cases, in order)', () => {
    const doc = { format: 1, recorded_with: 'service/api/src/validate (TypeScript)', verdicts: cases.map((c) => ({ id: c.id, verdict: verdictOf(c) })) };
    const text = JSON.stringify(doc, null, 2) + '\n';
    const have = fs.existsSync(VERDICTS) ? fs.readFileSync(VERDICTS, 'utf8') : '';
    if (text !== have) {
      const b64 = (Buffer.from(text, 'utf8').toString('base64').match(/.{1,100}/g) ?? []).join('\n');
      throw new Error(`verdicts.json differs from what the validator answers\n\nBASE64 verdicts.json:\n${b64}\nEND BASE64 verdicts.json`);
    }
  });

  test.each(cases.map((c) => [c.id, c] as const))('%s', (_id, c) => {
    const entry = recorded.verdicts.find((v) => v.id === c.id);
    if (!entry) throw new Error(`verdicts.json has no verdict for ${c.id}`);
    const want = entry.verdict;
    const got = verdictOf(c);
    expect(got).toEqual(want);
    // The case was written to hit this rule, and it does.
    expect(outcomeOf(got)).toBe(c.intent);
  });

  // The rule codes the corpus reaches, so a rule the corpus never reaches is a visible gap, not a silent one.
  test('every rule code of the validator is reached by at least one case', () => {
    const reached = new Set(recorded.verdicts.map((v) => outcomeOf(v.verdict)));
    const codes = fs.readFileSync(path.resolve(__dirname, '../../src/validate/codes.ts'), 'utf8');
    const rules = [...codes.matchAll(/^ {2}([a-z_0-9]+): '[a-z_]+',?$/gm)].map((m) => m[1]!);
    expect(rules.length).toBeGreaterThan(30);
    expect(rules.filter((r) => !reached.has(r)).sort()).toEqual([]);
  });
});
