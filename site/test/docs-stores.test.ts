// docs/what-mopm-stores.md states how long the service keeps each thing and what its log line holds. Each of those
// facts is read here from the source that decides it: the session's lifetime (mopm_core's WEB_SESSION_LIFETIME), the
// cookies' Max-Age (mopm_web's cookie.rs), the sign-in's lifetime (fn_web_login's LOGIN_SECONDS), how often a request
// writes last_used_at (mopm_web's TOUCH_EVERY), the Rust functions' log retention (the stack's RustFunction), the
// sandbox timeout (the stack's stage settings), the sandbox route's log line (fn_tutorial_sandbox's log.rs) and the
// draft's storage key (src/tutorial/page.ts). A changed lifetime, retention or log field fails here until the page says
// so. The page's text is never copied into an expectation: the expected text is built from the value found in the
// source.
import { readFileSync } from 'fs';
import { join } from 'path';
import { DOC_PAGES } from '../src/links';
import { DRAFT_KEY } from '../src/tutorial/page';
import { REPO_ROOT } from './build-fixture';

const read = (p: string) => readFileSync(join(REPO_ROOT, p), 'utf8');
const DOC = 'docs/what-mopm-stores.md';
const page = read(DOC);

/** The first capture group of `re` in `src`, or a failure that names what was looked for. */
function found(src: string, re: RegExp, what: string): string {
  const m = re.exec(src);
  if (!m) throw new Error(`source: no ${what}`);
  return m[1];
}

const int = (s: string) => Number(s.replace(/_/g, ''));

/** A whole number of seconds as the page writes it: in days, else minutes, else seconds; plural unless one. */
function duration(seconds: number): string {
  const unit = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`;
  if (seconds > 0 && seconds % 86_400 === 0) return unit(seconds / 86_400, 'day');
  if (seconds > 0 && seconds % 60 === 0) return unit(seconds / 60, 'minute');
  return unit(seconds, 'second');
}

// CloudWatch Logs' retention, by the CDK's RetentionDays member, as the page writes it. A member not listed here fails
// the test, so a retention the page has no words for cannot pass unread.
const RETENTION: Record<string, string> = {
  ONE_WEEK: 'one week',
  TWO_WEEKS: 'two weeks',
  ONE_MONTH: 'one month',
  TWO_MONTHS: 'two months',
  THREE_MONTHS: 'three months',
  SIX_MONTHS: 'six months',
  ONE_YEAR: 'one year',
};

function retentionText(member: string): string {
  const t = RETENTION[member];
  if (t === undefined) throw new Error(`RetentionDays.${member} has no wording here`);
  return t;
}

/** The cells of the row of a page table whose first cell starts with `first`. */
function row(src: string, first: string): string[] {
  const line = src.split('\n').find((l) => l.startsWith(`| ${first}`));
  if (!line) throw new Error(`no row for ${first}`);
  return line
    .replace(/^\|/, '')
    .replace(/\|$/, '')
    .split('|')
    .map((c) => c.trim());
}

// --------------------------------------------------------------------- the values, from their sources

const token = read('service/lambda/core/src/token.rs');
const cookie = read('service/lambda/web/src/cookie.rs');
const session = read('service/lambda/web/src/session.rs');
const login = read('service/lambda/fn_web_login/src/login.rs');
const rustFunction = read('service/infra/stacks/lib/rust-function.ts');
const stageSettings = read('service/infra/stacks/lib/stage-settings.ts');
const sandboxLog = read('service/lambda/fn_tutorial_sandbox/src/log.rs');

const sessionSeconds = int(found(token, /WEB_SESSION_LIFETIME: SignedDuration = SignedDuration::from_hours\((\d+) \* 24\);/, 'WEB_SESSION_LIFETIME')) * 86_400;
const sessionMaxAge = int(found(cookie, /pub const SESSION_MAX_AGE: u64 = ([\d_]+);/, 'SESSION_MAX_AGE'));
const loginMaxAge = int(found(cookie, /pub const LOGIN_MAX_AGE: u64 = ([\d_]+);/, 'LOGIN_MAX_AGE'));
const loginSeconds = int(found(login, /pub const LOGIN_SECONDS: i64 = ([\d_]+);/, 'LOGIN_SECONDS'));
const touchSeconds = int(found(session, /const TOUCH_EVERY: SignedDuration = SignedDuration::from_secs\(([\d_]+)\);/, 'TOUCH_EVERY'));
const sandboxSeconds = int(found(stageSettings, /export const DEFAULT_SANDBOX_TIMEOUT_S = ([\d_]+);/, 'DEFAULT_SANDBOX_TIMEOUT_S'));
const sessionCookie = found(cookie, /pub const SESSION_COOKIE: &str = "([^"]+)";/, 'SESSION_COOKIE');
const loginCookie = found(cookie, /pub const LOGIN_COOKIE: &str = "([^"]+)";/, 'LOGIN_COOKIE');

describe('the helpers', () => {
  test('duration writes days, minutes or seconds, singular for one', () => {
    expect([604_800, 86_400, 600, 1800, 60, 59, 1, 0].map(duration)).toEqual(['7 days', '1 day', '10 minutes', '30 minutes', '1 minute', '59 seconds', '1 second', '0 seconds']);
  });

  test('retentionText refuses a retention it has no words for', () => {
    expect(retentionText('ONE_MONTH')).toBe('one month');
    expect(() => retentionText('FIVE_DAYS')).toThrow('RetentionDays.FIVE_DAYS has no wording here');
  });

  test('found and row name what they did not find', () => {
    expect(() => found('const X: u64 = 1;', /const Y: u64 = (\d+);/, 'Y')).toThrow('source: no Y');
    expect(() => row('| a | b |', '`c`')).toThrow('no row for `c`');
    expect(row('| `a` table | b | 7 days |', '`a`')).toEqual(['`a` table', 'b', '7 days']);
  });
});

describe('docs/what-mopm-stores.md', () => {
  test('is a published docs page', () => {
    expect(DOC_PAGES).toContainEqual({ slug: 'what-mopm-stores', source: DOC });
  });

  test('the session: the row lives as long as the cookie, and the page says how long in both tables and the summary', () => {
    // Two constants decide it (the row's expiry and the cookie's Max-Age); the page has one number, so they must agree.
    expect(sessionMaxAge).toBe(sessionSeconds);
    const d = duration(sessionSeconds);
    expect(row(page, '`tokens` table')[2]).toBe(d);
    expect(row(page, `\`${sessionCookie}\``)[2]).toBe(`${d}, or until you sign out`);
    expect(page).toContain(`a hash of the session token, which ends ${d} after you sign in`);
    expect(page).toContain(`the row stays, unusable, until its ${d} are over`);
  });

  test('the sign-in in progress: the row lives as long as the login cookie, and the page says how long', () => {
    expect(loginMaxAge).toBe(loginSeconds);
    const d = duration(loginSeconds);
    expect(row(page, '`web_logins` table')[2]).toBe(d);
    expect(row(page, `\`${loginCookie}\``)[2]).toBe(d);
    expect(page).toContain(`**A sign-in in progress**: kept for ${d}.`);
  });

  test('last_used_at: the page says how often a request writes it', () => {
    expect(row(page, '`tokens` table')[1]).toContain(`written at most once every ${touchSeconds} seconds while you use the tutorial`);
  });

  test('the logs: every Rust function log group keeps what the page says', () => {
    const members = [...rustFunction.matchAll(/retention: logs\.RetentionDays\.([A-Z_]+)/g)].map((m) => m[1]);
    expect(members).toHaveLength(1);
    const t = retentionText(members[0]);
    expect(row(page, 'logs')[2]).toBe(t);
    expect(page).toContain(`one line per request to the sign-in and sandbox routes, kept for ${t}.`);
  });

  test('the sandbox: E2B ends it when the stage settings say, and the page says when', () => {
    const d = duration(sandboxSeconds);
    expect(page).toContain(`E2B ends the sandbox ${d} after it was created`);
    expect(page).toContain(`at most ${d} after it was created`);
  });

  test("the sandbox route's log line on the page has exactly the keys, in order, of the line the function writes", () => {
    const fn = sandboxLog.slice(sandboxLog.indexOf('pub fn created('));
    const template = found(fn, /r#"(\{.*\})"#/, 'the created line');
    const keys = (s: string) => [...s.matchAll(/"([a-z_]+)":/g)].map((m) => m[1]);
    const block = found(page, /```json\n(\{"event":"tutorial_sandbox".*\})\n```/, 'the log line block');
    expect(keys(block)).toEqual(keys(template));
    // The constant parts of the line are the function's: the event name and the outcome of a created sandbox.
    expect(JSON.parse(block)).toMatchObject({ event: 'tutorial_sandbox', outcome: 'created' });
    expect(template).toContain('"event":"tutorial_sandbox"');
    expect(template).toContain('"outcome":"created"');
  });

  test("the browser: the draft's key and the cookies' names are the ones the code uses", () => {
    expect(row(page, `\`${DRAFT_KEY}\``)[1]).toBe("the browser's `localStorage` for the site");
    expect(row(page, `\`${sessionCookie}\``)[1]).toContain('`HttpOnly`');
    expect(row(page, `\`${loginCookie}\``)[1]).toContain('a cookie with the same attributes');
  });

  test('names E2B and links its terms and privacy policy', () => {
    expect(page).toContain('[E2B\'s terms](https://e2b.dev/terms)');
    expect(page).toContain("[E2B's privacy policy](https://e2b.dev/privacy)");
    expect(page).toContain('Your code runs on E2B\'s servers, which see your IP address. mopm.dev does not see or store your code.');
  });
});
