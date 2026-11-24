// The lesson runner: page.ts's `Runner` port over E2B's SDK. Built for one lesson, it writes the lesson's edited files
// into the lesson's directory in the sandbox of a grant and runs the lesson's command there
// (docs/design/tutorial-sign-in.md, section 4, "What E2B lacks", and section 7).
//
// The client is the SDK's `Sandbox` constructor over the grant alone: the sandbox id, its access token, the agent's
// version and the sandbox's domain. It talks only to that sandbox's agent (`https://49983-<sandbox_id>.<domain>` in a
// browser) and sends the token as `X-Access-Token`; no API key is given, read or sent. `Sandbox.create` and
// `Sandbox.connect` would need the team's key, which stays on our service. e2b 2.64.0 exports the constructor and types
// it public, but its comment marks it `@internal`, so `e2b` is pinned exactly (package.json) and `npm run typecheck`
// checks this call against the pinned types: an upgrade that changes it fails the build, not the page.
//
// What a run gives the page:
//  - the command's exit code and output; a non-zero exit is the program's own (the SDK's CommandExitError), not an
//    error of the page;
//  - `{kind: 'SandboxNotRunning'}` (SandboxNotRunningError: killed or timed out) or `{kind: 'SandboxUnreachable'}`
//    (SandboxUnreachableError): the sandbox is gone, so the page asks the gate for a new one and runs again, once;
//  - anything else (a refused token, a write the agent refused, a command past RUN_TIMEOUT_MS) is thrown as the SDK
//    raised it.
// A lesson id outside the lesson grammar (spec/tutorial-lesson.schema.json) is refused with a RangeError when the runner
// is built; a file path or a command outside it, by the run, before any request.
//
// This module and what it imports are bundled with the SDK by esbuild into the one asset the tutorial page loads
// (tools/build.ts, TUTORIAL_BUNDLE); no other page loads it.

import { CommandExitError, Sandbox, SandboxNotRunningError, SandboxUnreachableError } from 'e2b';
import { LESSON, type SandboxGrant } from './gate.js';
import type { LessonFile, Runner, RunnerError, RunResult } from './page.js';

/** Where the template puts each lesson's project (tutorial/README.md): `/home/user/lessons/<id>/`. */
export const LESSONS_DIR = '/home/user/lessons';

/** How long a command may run before the SDK ends it (a TimeoutError, thrown): a lesson's build and run of Mojo. */
export const RUN_TIMEOUT_MS = 120_000;

/** spec/tutorial-lesson.schema.json's ProjectPath: relative, '/'-separated, no empty, '.' or '..' segment. */
const PROJECT_PATH = /^\.?[A-Za-z0-9_-][A-Za-z0-9_.-]*(\/\.?[A-Za-z0-9_-][A-Za-z0-9_.-]*)*$/;
const PROJECT_PATH_MAX = 255;
/** The schema's two actions: nothing in them a shell would read. */
const COMMAND = /^mopm (run( [A-Za-z0-9_./=:-]+)+|test( [A-Za-z0-9_./=:-]+)*)$/;
const COMMAND_MAX = 200;

/** The lesson's directory in the sandbox; throws a RangeError for an id outside the grammar. */
export function lessonDir(lesson: string): string {
  if (lesson.length > 64 || !LESSON.test(lesson)) throw new RangeError(`not a lesson id: ${JSON.stringify(lesson)}`);
  return `${LESSONS_DIR}/${lesson}`;
}

function checkPath(path: string): void {
  if (path.length > PROJECT_PATH_MAX || !PROJECT_PATH.test(path)) throw new RangeError(`not a lesson file path: ${JSON.stringify(path)}`);
}

function checkCommand(command: string): void {
  if (command.length > COMMAND_MAX || !COMMAND.test(command)) throw new RangeError(`not a lesson command: ${JSON.stringify(command)}`);
}

/** The SDK's client of the grant's sandbox, from the grant alone (no API key). */
export function sandboxOf(grant: SandboxGrant): Sandbox {
  return new Sandbox({
    sandboxId: grant.sandbox_id,
    sandboxDomain: grant.domain,
    envdVersion: grant.envd_version,
    envdAccessToken: grant.access_token,
  });
}

async function run(dir: string, grant: SandboxGrant, files: readonly LessonFile[], command: string): Promise<RunResult | RunnerError> {
  files.forEach((f) => checkPath(f.path));
  checkCommand(command);
  const sandbox = sandboxOf(grant);
  try {
    // One upload for every file; an empty list sends nothing.
    await sandbox.files.write(files.map((f) => ({ path: `${dir}/${f.path}`, data: f.text })));
    const r = await sandbox.commands.run(command, { cwd: dir, timeoutMs: RUN_TIMEOUT_MS });
    return { exit_code: r.exitCode, stdout: r.stdout, stderr: r.stderr };
  } catch (e) {
    if (e instanceof CommandExitError) return { exit_code: e.exitCode, stdout: e.stdout, stderr: e.stderr };
    if (e instanceof SandboxNotRunningError) return { kind: 'SandboxNotRunning' };
    if (e instanceof SandboxUnreachableError) return { kind: 'SandboxUnreachable' };
    throw e;
  }
}

/** The runner the tutorial page uses for `lesson`: E2B's SDK, from each run's grant. Throws a RangeError for a bad id. */
export function e2bRunner(lesson: string): Runner {
  const dir = lessonDir(lesson);
  return { run: (grant, files, command) => run(dir, grant, files, command) };
}
