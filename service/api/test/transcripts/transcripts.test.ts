import * as fs from 'fs';
import * as path from 'path';
import { runScenario, type Scenario } from './runner';

/**
 * Transcripts of `route()` (the router with the auth and publish routes), recorded from this implementation.
 *
 * A scenario (fixtures/transcripts/scenarios/NAME.json) is a world (seeds, clock, which routes are wired, the
 * limits) and a list of steps: requests, and the few actions a request cannot do (move the clock, flip the
 * read-only switch, put an object into the bucket). Running it produces a transcript, which is committed as the
 * golden (fixtures/transcripts/golden/NAME.json): the world, and for every request what was sent and what came back:
 * the status, the headers in order with their spelling, and the body bytes. Another implementation replays the
 * golden (the world and the resolved requests) and must produce the same bytes. See README.md in this directory
 * for the formats, the random source and how to record.
 *
 * What this test proves: for each scenario, this implementation still answers byte for byte as recorded; and each
 * request that carries an `expect` still has that status and error code, so a scenario that stopped reaching the
 * branch it was written for is reported instead of silently recording something else.
 * What it does not: that the recorded behaviour is right (the contract fixtures and the other tests say that); it
 * is a record of what the TypeScript implementation does, which the Rust one must reproduce.
 *
 * To record: MOPM_RECORD_TRANSCRIPTS=1 npx jest test/transcripts rewrites the golden files from the scenarios.
 * Otherwise a missing or different golden fails the test and prints the actual transcript (`ACTUAL`).
 */

const SCENARIOS = path.join(__dirname, '..', 'fixtures', 'transcripts', 'scenarios');
const GOLDEN = path.join(__dirname, '..', 'fixtures', 'transcripts', 'golden');
const names = (dir: string) => (fs.existsSync(dir) ? fs.readdirSync(dir) : []).filter((f) => f.endsWith('.json')).map((f) => f.slice(0, -5)).sort();

describe('transcripts', () => {
  test('every scenario has a golden and every golden a scenario', () => {
    expect(names(GOLDEN)).toEqual(names(SCENARIOS));
    expect(names(SCENARIOS).length).toBeGreaterThan(0);
  });

  test.each(names(SCENARIOS))('%s', async (name) => {
    const sc: Scenario = JSON.parse(fs.readFileSync(path.join(SCENARIOS, `${name}.json`), 'utf8'));
    const { transcript, unmet } = await runScenario(sc);
    const actual = JSON.stringify(transcript, null, 2) + '\n';
    if (process.env.MOPM_RECORD_TRANSCRIPTS === '1') {
      fs.writeFileSync(path.join(GOLDEN, `${name}.json`), actual);
      return;
    }
    const file = path.join(GOLDEN, `${name}.json`);
    const golden = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : undefined;
    const problems = unmet.map((u) => `unmet expectation: ${u}`);
    if (golden !== actual) problems.push(`the transcript of ${name} differs from its golden`);
    if (problems.length > 0) {
      // Also in base64: a CI log masks anything that looks like a credential (these transcripts hold made-up tokens),
      // so the plain text above may be cut; the base64 lines are the exact bytes of the golden file.
      const b64 = (Buffer.from(actual, 'utf8').toString('base64').match(/.{1,100}/g) ?? []).join('\n');
      throw new Error(`${problems.join('\n')}\n\nACTUAL ${name}:\n${actual}END ACTUAL ${name}\n\nBASE64 ${name}:\n${b64}\nEND BASE64 ${name}`);
    }
  });
});
