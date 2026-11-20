// Run by definition.test.ts in a child Node process (`node -r ts-node/register/transpile-only`), not by Jest: E2B
// selects and hashes the files of each COPY step through a dynamic ESM import, which Jest's CommonJS runtime cannot
// load. Prints, as JSON, the source and E2B's files hash of each COPY step of the definition of the repository at
// argv[2]. toJSON reads the files from disk and makes no network call.
import { Template } from 'e2b';
import { templateDefinition } from '../src/definition';
import { listLessons } from '../src/inputs';

async function hashes(root: string): Promise<{ src: string; filesHash: string }[]> {
  const t = templateDefinition({ repoRoot: root, lessons: listLessons(root), mopm: { version: '0.0.1', sha256: '0'.repeat(64) } });
  const json = JSON.parse(await Template.toJSON(t, true)) as { steps: { type: string; args: string[]; filesHash: string }[] };
  return json.steps.filter((s) => s.type === 'COPY').map((s) => ({ src: s.args[0], filesHash: s.filesHash }));
}

hashes(process.argv[2]).then(
  (h) => process.stdout.write(`${JSON.stringify(h)}\n`),
  (e: unknown) => {
    process.stderr.write(`${String(e)}\n`);
    process.exitCode = 1;
  },
);
