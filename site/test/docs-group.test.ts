// docs/publishing-a-workspace.md, the "Groups" section of service/docs/runbook.md and CHANGELOG.md state commands, flags, values,
// outcomes and names. Each of those is read here from the source that decides it (the CLI's Zig, the service's TypeScript, the
// stacks' names, the workflows), so a renamed flag, a changed default, a new outcome or a changed value of the groups switch fails
// until the text says so. The text of a page is never copied into an expectation where a source holds the fact.
import { readFileSync } from 'fs';
import { join } from 'path';
import { DOC_PAGES } from '../src/links';
import { REPO_ROOT } from './build-fixture';

const read = (p: string) => readFileSync(join(REPO_ROOT, p), 'utf8');
const squash = (s: string) => s.replace(/\s+/g, ' ').trim();
const sorted = (a: Iterable<string>) => [...new Set(a)].sort();

const DOC = 'docs/publishing-a-workspace.md';
const doc = read(DOC);
const runbook = read('service/docs/runbook.md');
const changelog = read('CHANGELOG.md');
const stageZig = read('src/cli/stage_cmd.zig');
const publishZig = read('src/cli/group_publish.zig');
const yankZig = read('src/cli/yank_cmd.zig');
const flagsTs = read('service/api/src/publish/flags.ts');
const opsTs = read('service/api/src/ops/group-ops.ts');
const opsMainTs = read('service/api/src/ops/group-ops-main.ts');
const validatorTs = read('service/api/src/publish/group-validator.ts');
const stacksConfigTs = read('service/infra/stacks/lib/config.ts');
const publishStackTs = read('service/infra/stacks/lib/publish-stack.ts');
const e2eYml = read('.github/workflows/e2e.yml');
const spec = read('spec/staged-set.md');

/** The text of the section with this heading (any level), up to the next heading of the same or a higher level. */
function section(md: string, heading: string): string {
  const lines = md.split('\n');
  // A line of a fenced block is never a heading (a shell comment starts with '# ').
  const fenced: boolean[] = [];
  let open = false;
  for (const l of lines) {
    if (l.startsWith('```')) open = !open;
    fenced.push(open || l.startsWith('```'));
  }
  const at = lines.findIndex((l, i) => !fenced[i] && /^#{1,6} /.test(l) && l.replace(/^#+ /, '') === heading);
  if (at < 0) throw new Error(`no section ${heading}`);
  const level = /^#+/.exec(lines[at])![0].length;
  let end = lines.length;
  for (let i = at + 1; i < lines.length; i++) {
    const m = fenced[i] ? null : /^(#+) /.exec(lines[i]);
    if (m && m[1].length <= level) {
      end = i;
      break;
    }
  }
  return lines.slice(at, end).join('\n');
}

/** The fenced blocks of a text, each without its fence lines. */
function fences(md: string): string[] {
  return [...md.matchAll(/^```[a-z]*\n([\s\S]*?)^```$/gm)].map((m) => m[1]);
}

/** The lines of the `usage` string of a Zig command up to its first blank line, as the commands it shows (one string each). */
function usageCommands(zig: string): string[] {
  const lines = zig.split('\n');
  const at = lines.findIndex((l) => /\bconst usage =\s*$/.test(l));
  if (at < 0) throw new Error('no usage string');
  const out: string[] = [];
  for (let i = at + 1; i < lines.length; i++) {
    const m = /^\s*\\\\(.*)$/.exec(lines[i]);
    if (!m || m[1].trim() === '') break;
    out.push(m[1]);
  }
  return squash(out.join(' '))
    .replace(/^usage: /, '')
    .split(/\s(?=mopm )/);
}

/** The flags a Zig parser takes: those of its `const takes = ...;`, and the flags that take no value. */
function flagsOf(zig: string, noValue: readonly string[] = []): string[] {
  const m = /const takes = ([^;]+);/.exec(zig);
  if (!m) throw new Error('no takes list');
  for (const flag of noValue) expect(zig).toContain(`eql(u8, a, "${flag}")`);
  return sorted([...[...m[1].matchAll(/"(--[a-z-]+)"/g)].map((x) => x[1]), ...noValue]);
}

const flagTokens = (text: string): string[] => sorted(text.match(/--[a-z]+(?:-[a-z]+)*/g) ?? []);

// ------------------------------------------------------------------------------------------------- the commands

describe.each([
  ['mopm stage', stageZig, undefined],
  ['mopm publish --staged', publishZig, ['--dry-run', '--oidc', '--no-commit', '--abort']],
] as const)('docs: %s', (heading, zig, noValue) => {
  const sec = section(doc, heading);
  const source = flagsOf(zig, noValue);
  const first = fences(sec)[0];

  test('the synopsis is the usage string of the command', () => {
    const commands = usageCommands(zig);
    expect(commands).toHaveLength(1);
    expect(squash(first)).toBe(commands[0]);
  });

  test('the synopsis names every flag the parser takes, and no other', () => {
    expect(flagTokens(first)).toEqual(source);
  });

  test('a row of the table of flags for each flag', () => {
    for (const f of source) expect([f, sec.includes(`| \`${f}`)]).toEqual([f, true]);
    const rows = sec.split('\n').filter((l) => l.startsWith('| `--'));
    expect(sorted(rows.map((l) => /^\| `(--[a-z-]+)/.exec(l)![1]))).toEqual(source);
  });
});

describe('docs: mopm yank --group', () => {
  const sec = section(doc, 'Yanking a group');
  const block = fences(sec)[0];
  const source = flagsOf(yankZig, ['--unyank']);

  test('the synopsis is the two usage lines of the command', () => {
    expect(block.trim().split('\n').map(squash)).toEqual(usageCommands(yankZig));
  });

  test('the synopsis names every flag the parser takes, and no other', () => {
    expect(flagTokens(block)).toEqual(source);
  });

  test('the reason is at most as long as the CLI takes, and a yank needs one', () => {
    const max = /max_reason: usize = (\d+)/.exec(yankZig)![1];
    expect(yankZig).toContain(`--reason is 1 to ${max} characters`);
    expect(sec).toContain(`1 to ${max} characters`);
    expect(yankZig).toContain('--reason is for a yank');
    expect(sec).toContain('is refused with `--unyank`');
  });

  test('a group that is not visible is refused with group_not_settled (409)', () => {
    expect(yankZig).toContain('group_not_settled');
    expect(sec).toContain('409');
    expect(sec).toContain('`group_not_settled`');
    expect(sec).toContain('Only a group that is `visible` can be yanked');
  });

  test('the command waits for the states the registry reports, and says a group yank is not one flip', () => {
    expect(yankZig).toContain('"restored"');
    expect(yankZig).toContain('"yanked"');
    expect(sec).toContain('`yanked`');
    expect(sec).toContain('`restored`');
    expect(sec).toContain('is not one flip');
    expect(runbook).toContain('`yanked_set`');
  });
});

describe('docs: values and outcomes', () => {
  test('--wait defaults to the CLI default: a base plus an allowance for each member', () => {
    const base = Number(/default_wait_secs: i64 = (\d+)/.exec(publishZig)![1]);
    const each = Number(/wait_per_member_secs: i64 = (\d+)/.exec(publishZig)![1]);
    const sec = section(doc, 'mopm publish --staged');
    expect(sec).toContain(`The default grows with the group: ${base} seconds plus ${each} seconds for each member`);
    expect(sec).toContain(`(${base + each * 170} seconds at 170 members, ${base + each * 300} at 300)`);
  });

  test('the outcomes of a run are the Result of the publisher, and are all named', () => {
    const names = /pub const Result = enum \{([^}]*)\}/.exec(publishZig)![1].split(',').map((s) => s.trim()).filter(Boolean);
    expect(names).toEqual(['published', 'staged', 'aborted', 'nothing_to_abort', 'failed', 'rate_limited', 'no_group_publish', 'timed_out']);
    const sec = section(doc, 'report.json');
    expect(sec).toContain(`The outcome of a run is ${names.slice(0, -1).map((n) => `\`${n}\``).join(', ')} or \`${names[names.length - 1]}\``);
  });

  test('the outcomes of a member are the strings the report writes, one row each', () => {
    const outcomes = sorted([...publishZig.matchAll(/outcome = "([a-z_]+)"/g)].map((m) => m[1]));
    expect(outcomes).toEqual(['not_published', 'pending', 'published', 'rejected', 'skipped', 'staged']);
    const rows = section(doc, 'report.json').split('\n').filter((l) => l.startsWith('| `'));
    expect(sorted(rows.map((l) => /^\| `([a-z_]+)`/.exec(l)![1]))).toEqual(outcomes);
  });

  test('the actions of a member are those of the staged-set spec, one row each', () => {
    const m = /`action` is `(\w+)`, `(\w+)` or `(\w+)`/.exec(spec)!;
    const actions = [m[1], m[2], m[3]];
    expect(actions).toEqual(['upload', 'skip', 'refuse']);
    for (const a of actions) expect(stageZig).toContain(`\`${a}\``);
    const rows = section(doc, 'mopm stage').split('\n').filter((l) => /^\| `(upload|skip|refuse)` \|/.test(l));
    expect(rows.map((l) => /^\| `(\w+)`/.exec(l)![1])).toEqual(actions);
  });

  test('state.json and report.json are the names the command and the spec use', () => {
    for (const f of ['state.json', 'report.json']) {
      expect([f, publishZig.includes(f), spec.includes(f), doc.includes(`\`${f}\``)]).toEqual([f, true, true, true]);
    }
  });

  test('--registry has no default on the three commands', () => {
    for (const z of [stageZig, publishZig, yankZig]) expect(z).toContain('there is no default');
    expect(doc.match(/no default/gi)!.length).toBeGreaterThanOrEqual(3);
  });
});

describe('docs: errors and exit status', () => {
  test('404 from the create means no group publish, nothing is uploaded, and the outcome is no_group_publish', () => {
    expect(publishZig).toContain('has no group publish (POST /groups answered HTTP 404); nothing was uploaded');
    expect(publishZig).toContain('"route_not_found"');
    const sec = section(doc, '404: the registry has no group publish');
    expect(sec).toContain('has no group publish');
    expect(sec).toContain('uploads nothing');
    expect(sec).toContain('`no_group_publish`');
  });

  test('429 stops the run, names the wait and is never retried', () => {
    expect(publishZig).toContain('rate limiting this client (HTTP 429); nothing more was sent');
    expect(publishZig).toContain('; retry after {d} seconds');
    const sec = section(doc, '429: slow down');
    expect(sec).toContain('rate limiting this client');
    expect(sec).toContain('never retries into the limit');
    expect(sec).toContain('`rate_limited`');
  });

  test('the token: $MOPM_TOKEN or the login, read after the plan is checked, and not by a dry run', () => {
    expect(publishZig).toContain('`$MOPM_TOKEN`, else the login');
    expect(doc).toContain('`$MOPM_TOKEN`, else the login');
    expect(publishZig.indexOf('if (flags.dry_run) return dryRun')).toBeGreaterThan(0);
    expect(publishZig.indexOf('if (flags.dry_run) return dryRun')).toBeLessThan(publishZig.indexOf('findToken'));
    expect(publishZig).toContain('dry run: nothing was sent');
    expect(section(doc, 'mopm publish --staged')).toContain('It reads no token and writes no file');
  });

  test('the exit statuses of stage are those of its header', () => {
    const m = /Exit status: 0 ([a-z ]+); 1 ([a-z ]+); 2 ([a-z ]+)\./.exec(stageZig)!;
    expect(doc).toContain(`| \`mopm stage\` | ${m[1]} | ${m[2]} | ${m[3]} |`);
  });

  test('publish --staged and yank --group answer a usage error with 2, and the table says so', () => {
    for (const z of [publishZig, yankZig]) expect(z).toMatch(/writeAll\(usage\) catch \{\};\s*return 2;/);
    expect(yankZig).toContain('return if (y.run() == .done) 0 else 1;');
    expect(publishZig).toContain('nothing to publish: every member of the plan is skipped');
    const exit = section(doc, 'Exit status');
    expect(exit).toMatch(/\| `mopm publish --staged` \|[^|]+\|[^|]+\| usage error \|/);
    expect(exit).toMatch(/\| `mopm yank --group` \|[^|]+\|[^|]+\| usage error \|/);
  });
});

describe('docs: where group publish is switched off', () => {
  test('the service creates no group unless the item says so, and the page says the hosted registries are off', () => {
    expect(flagsTs).toContain("export const GROUPS_OFF: GroupsPolicy = { mode: 'off' };");
    expect(flagsTs).toContain('if (!item) return GROUPS_OFF;');
    const sec = section(doc, 'Group publish is off on the hosted registries');
    for (const stage of ['prod', 'gamma', 'beta']) expect(sec).toContain(`\`${stage}\``);
    expect(opsMainTs).toContain("--stage is beta, gamma or prod");
    expect(sec).toContain('switched off');
    expect(sec).toContain('HTTP 404');
  });

  test('the page is a docs page of the site', () => {
    expect(DOC_PAGES).toContainEqual({ slug: 'publish-workspace', source: DOC });
    expect(doc.startsWith('# Publishing a workspace as one group\n')).toBe(true);
  });

  test('a reader sees the group in steps, in the words of the runbook', () => {
    const sec = section(doc, 'What a reader sees');
    expect(sec).toContain('the registry releases those files in steps after the commit');
    expect(sec).toContain('dependencies before the packages that need them');
    expect(squash(runbook)).toContain('this is not atomic');
    expect(squash(runbook)).toContain("the CDN's cache adds up to a minute");
    expect(sec).toContain('up to a minute');
  });
});

// ------------------------------------------------------------------------------------------------- the runbook

describe('runbook: groups', () => {
  const sec = section(runbook, 'Groups: enabling, rolling out and recovering');

  test('the values of groups_enabled are the modes the service reads, with the fields it reads', () => {
    const type = /export type GroupsPolicy =([^\n]+)/.exec(flagsTs)![1];
    const modes = sorted([...type.matchAll(/mode: '([a-z]+)'/g)].map((m) => m[1]));
    expect(modes).toEqual(['all', 'allow', 'off']);
    expect(flagsTs).toContain("Key: { key: 'groups_enabled' }");
    const table = section(sec, 'The `groups_enabled` item');
    const rows = table.split('\n').filter((l) => /^\| `[a-z]+` \|/.test(l) && !l.startsWith('| `mode`'));
    expect(sorted(rows.map((l) => /^\| `([a-z]+)`/.exec(l)![1]))).toEqual(modes);
    for (const field of ['actors', 'deny']) {
      expect(flagsTs).toContain(`item.${field}`);
      expect(table).toContain(`\`${field}\``);
    }
    // The switch is cached for the time the runbook says.
    expect(flagsTs).toContain('cacheMs = 5000');
    expect(table).toContain('five seconds');
  });

  test('each put-item of the runbook is a complete item the service reads', () => {
    const items = [...sec.matchAll(/--table-name mopm-<stage>-config --item '([^']+)'/g)].map((m) => JSON.parse(m[1]) as Record<string, { S?: string; L?: { S: string }[] }>);
    expect(items).toHaveLength(3);
    expect(items.map((i) => i.key.S)).toEqual(['groups_enabled', 'groups_enabled', 'groups_enabled']);
    expect(items.map((i) => i.mode.S)).toEqual(['off', 'allow', 'all']);
    expect(items[1].actors!.L!.every((a) => a.S.startsWith('u:'))).toBe(true);
    expect(items[2].deny!.L!.every((a) => a.S.startsWith('u:'))).toBe(true);
    expect(items[0].actors).toBeUndefined();
    expect(flagsTs).toContain("item.mode === 'allow'");
    expect(flagsTs).toContain("item.mode === 'all'");
  });

  test('the order is beta, gamma, prod canary, prod everybody, and the e2e job is the proof on the first two', () => {
    const order = section(sec, 'The order: beta, gamma, then a canary on prod');
    const at = ['**beta.**', '**gamma.**', '**prod, canary.**', '**prod, everybody.**'].map((s) => order.indexOf(s));
    expect(at.every((i) => i >= 0)).toBe(true);
    expect([...at].sort((a, b) => a - b)).toEqual(at);
    expect(e2eYml).toContain('group-e2e:');
    expect(e2eYml).toContain("inputs.stage != 'prod'");
    expect(order).toContain('`group-e2e`');
    expect(squash(order)).toContain('never on prod');
  });

  test('the group tool: flags, modes, dry run by default, exit statuses and the verdict', () => {
    const block = fences(section(sec, 'The group tool'))[0];
    const known = /new Set\(\[([^\]]*)\]\)/.exec(opsTs)![1];
    const flags = sorted([...known.matchAll(/'([a-z]+)'/g)].map((m) => `--${m[1]}`));
    expect(flagTokens(block)).toEqual(flags);
    expect(opsTs).toContain("export type OpsMode = 'status' | 'fail';");
    expect(block).toContain('--mode=status');
    expect(block).toContain('--mode=fail');
    expect(opsTs).toContain('apply: flags.has(\'apply\')');
    expect(opsTs).toContain('dry_run: !args.apply');
    const rb = squash(sec);
    expect(rb).toContain("It is a dry run unless `--apply` is given");
    expect(opsTs).toContain("Returns the exit status: 0 done (or safe), 2 refused (nothing to do or not allowed), 3 not safe to revert, 4 lost a race.");
    expect(rb).toContain("Exit status 0 when there is no such group and the queues are empty, 3 when not.");
    expect(rb).toContain("Exit status 0 done, 2 refused");
    expect(rb).toContain('4 lost a race');
    expect(opsTs).toContain('return safe ? 0 : 3;');
    for (const kind of ['group', 'queue', 'verdict', 'plan']) {
      expect([kind, opsTs.includes(`kind: '${kind}'`), rb.includes(`kind \`${kind}\``) || rb.includes(`a \`${kind}\` line`)]).toEqual([kind, true, true]);
    }
    expect(opsTs).toContain('safe_to_revert');
    expect(sec).toContain('safe_to_revert');
    expect(opsTs).toContain('dist/ops/group-ops-bin.js');
    expect(block).toContain('dist/ops/group-ops-bin.js');
  });

  test('the tool lists six queues, and the dead-letter queue and alarm are the ones the stacks create', () => {
    const queues = /export const QUEUES = \[([^\]]*)\]/.exec(opsMainTs)![1].match(/'[a-z-]+'/g)!;
    expect(queues).toHaveLength(6);
    expect(squash(sec)).toContain('the six queues');
    const name = (fn: string) => new RegExp(`${fn} = \\(s: Stage\\) => \`([^\`]+)\``).exec(stacksConfigTs)![1].replace('${s}', '<stage>');
    expect(sec).toContain(`\`${name('groupDlqName')}\``);
    expect(sec).toContain(`\`${name('indexDlqName')}\``);
    expect(publishStackTs).toContain("['GroupDlqAlarm', this.groupDlq, 'group']");
    expect(publishStackTs).toContain('alarmName: `mopm-${c.stage}-${label}-dlq-depth`');
    expect(sec).toContain('`mopm-<stage>-group-dlq-depth`');
    const receives = /MAX_RECEIVES = (\d+)/.exec(publishStackTs)![1];
    expect(receives).toBe('3');
    expect(squash(sec)).toContain('fails three times');
  });

  test('public bytes after a failed group: create-only copies with a one-year immutable header, burned numbers, no deletion', () => {
    const pub = section(sec, 'Public bytes after a failed group');
    expect(validatorTs).toContain("cacheControl: 'public, max-age=31536000, immutable', createOnly: true");
    expect(pub).toContain('create-only');
    expect(squash(pub)).toContain('one-year immutable');
    expect(opsTs).toContain("const to = phase >= 2 ? 'failed' : 'rejected';");
    expect(opsTs).toContain("burns_numbers: to === 'failed'");
    expect(validatorTs).toContain("{ type: 'group_burn'");
    expect(pub).toContain('burned');
    expect(pub).toContain('`rejected`');
    expect(squash(pub)).toContain('Nothing deletes the files');
  });

  test('the rollback precheck is the tool: groups not over, empty queues, groups off first', () => {
    const pre = section(sec, 'The rollback precheck');
    expect(opsTs).toContain('open, validating, committed and not yet visible');
    for (const s of ['`open`', '`validating`', '`visible`', '`safe_to_revert: true`', 'every queue and dead-letter queue is empty']) expect(squash(pre)).toContain(s);
    expect(pre).toContain('`groups_enabled` to `off`');
    expect(opsTs).toContain('safe_to_revert: safe, groups_not_over: active.length, queues_not_empty: busy');
  });
});

// ------------------------------------------------------------------------------------------------- the changelog

describe('CHANGELOG.md: group publish', () => {
  const text = squash(changelog);

  test('names the three commands as their usage strings give them', () => {
    expect(text).toContain(usageCommands(stageZig)[0]);
    expect(text).toContain(usageCommands(publishZig)[0]);
    expect(text).toContain(usageCommands(yankZig)[0]);
    expect(text).toContain('`--unyank`');
  });

  test('says it is dark, links the page, and says what the command line sees', () => {
    expect(changelog).toContain('### Group publish (dark)');
    expect(changelog).toContain('(docs/publishing-a-workspace.md)');
    expect(text).toContain('switched off on `beta`, `gamma` and `prod`');
    expect(text).toContain('see some of its members (dependencies first); the API shows all or none');
    expect(text).toContain('a group yank is not one flip');
  });
});
