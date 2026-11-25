// The header's account box (src/account.ts), driven through a StringDoc port with no DOM, over the gate replaying the
// contract's recorded answers (tests/contract/api-v2/web-auth.json): no network. What each test proves is its name; the
// defect it catches is beside it.
import { readFileSync } from 'fs';
import { join } from 'path';
import {
  ACCOUNT_ID, accountLink, type AccountPort, GITHUB_2FA_URL, NOT_SIGNED_OUT, pagePath, returnPathOf, SIGN_IN_ERRORS, SIGN_OUT_ID, showAccount, signedInNodes,
  signInError, signInErrorBanner,
} from '../src/account';
import { h, type SElement, type SNode, serialize, StringDoc } from '../src/doc';
import { CSRF_HEADER, LOGOUT_PATH, type RecordedAnswer, replayGate, type ReplayScript, SESSION_PATH, type TutorialGate } from '../src/tutorial/gate';
import { answer, HTML_504, LOGIN, SIGNED_IN, SIGNED_OUT } from './page-fakes';

const SIGNED_OUT_204 = answer('sign out answers 204 and clears the session cookie');
const LOGOUT_CSRF_FAILED = answer('sign out with a wrong CSRF value is refused as csrf_failed');
const LOGOUT_SESSION_REQUIRED = answer('sign out of a signed-out browser is refused as session_required');
const SESSION_INVALID = answer('the session with an Authorization header is refused as invalid_request');
const CSRF = (SIGNED_IN.body as { csrf: string }).csrf;
/** The same user's session after it changed in another tab: another CSRF value. */
const CSRF_2 = 'B'.repeat(43);
const SIGNED_IN_2: RecordedAnswer = { ...SIGNED_IN, body: { ...(SIGNED_IN.body as object), csrf: CSRF_2 } };

class Port extends StringDoc implements AccountPort<SNode> {
  readonly clicks = new Map<SNode, () => void>();
  readonly focused: SNode[] = [];
  replaceChildren(node: SNode, nodes: SNode[]): void {
    (node as SElement).children = nodes;
  }
  onClick(node: SNode, fn: () => void): void {
    this.clicks.set(node, fn);
  }
  focus(node: SNode): void {
    this.focused.push(node);
  }
  setText(node: SNode, t: string): void {
    (node as SElement).children = t === '' ? [] : [{ text: t }];
  }
  linkHref(box: SNode): string | null {
    const link = (box as SElement).children.find((c) => attr(c, 'class') === 'button sign-in');
    return link === undefined ? null : (attr(link, 'href') ?? null);
  }
}

/** The account box as layout.ts writes it for `path`. */
function box(port: Port, path: string): SElement {
  return h(port, 'div', { class: 'site-account', id: ACCOUNT_ID }, accountLink(port, path)) as SElement;
}

const out = (n: SNode): string => serialize([n]);
const attr = (n: SNode, k: string): string | undefined => ('tag' in n ? n.attrs.find(([a]) => a === k)?.[1] : undefined);
const startLink = (path: string): string =>
  `<a class="button sign-in" href="/api/v2/auth/web/start?return_to=${encodeURIComponent(path)}"><span>Sign in<span class="sign-in-more"> with GitHub</span></span></a>`;
const signedInBox = (failed = false): string =>
  `<div class="site-account" id="site-account"${failed ? ' aria-busy="false"' : ''}><span class="account-login" title="${LOGIN}"><span class="visually-hidden">Signed in as </span>${LOGIN}</span>` +
  `<button type="button" id="site-sign-out" class="button">Sign out</button>` +
  `<span class="account-status" role="status">${failed ? NOT_SIGNED_OUT : ''}</span>` +
  '</div>';

/** Lets the replayed answers settle (no clock involved). */
async function settle(): Promise<void> {
  for (let i = 0; i < 10; i++) await new Promise((r) => setImmediate(r));
}

function signOutButton(slot: SElement): SNode {
  const b = slot.children.find((c) => attr(c, 'id') === SIGN_OUT_ID);
  if (b === undefined) throw new Error('no Sign out button');
  return b;
}

/** Clicks Sign out in the box and lets the answers settle. */
async function clickSignOut(port: Port, slot: SElement): Promise<void> {
  (port.clicks.get(signOutButton(slot)) as () => void)();
  await settle();
}

/** A box on `path` whose session the gate answered from `script`, with what the gate was asked. */
async function shown(script: ReplayScript, path = '/docs/mopm-test/'): Promise<{ port: Port; slot: SElement; gate: ReturnType<typeof replayGate> }> {
  const port = new Port();
  const slot = box(port, '/search');
  const gate = replayGate(script);
  await showAccount(port, slot, gate, path);
  return { port, slot, gate };
}

const calls = (gate: ReturnType<typeof replayGate>): string[] => gate.requests.map((r) => `${r.method} ${r.url} ${(r.init.headers as Record<string, string> | undefined)?.[CSRF_HEADER] ?? '-'}`);

describe('returnPathOf: where a sign-in from a page comes back to', () => {
  // Defect caught: a page the start route keeps sent home instead; the 404 page's address (or any path the route
  // would replace with the unserved /tutorial) passed through.
  test.each([
    ['/', '/'],
    ['/search', '/search'],
    ['/docs', '/docs'],
    ['/docs/', '/docs/'],
    ['/docs/mopm-test/', '/docs/mopm-test/'],
    ['/packages/komira-ai/http_client', '/packages/komira-ai/http_client'],
    ['/packages/komira-ai/http_client/1.0.0', '/packages/komira-ai/http_client/1.0.0'],
    ['/tutorial/hello', '/tutorial/hello'],
    ['/nowhere', '/'],
    ['/search/', '/'],
    ['/packages/komira-ai/Http_Client', '/'],
    ['/tutorial/', '/'],
    ['/docs/../x', '/'],
    ['', '/'],
    [`/docs/${'a'.repeat(300)}/`, '/'],
  ])('%j comes back to %j', (path, want) => {
    expect(returnPathOf(path)).toBe(want);
  });
});

describe('pagePath: the path the page script hands the box', () => {
  // Defect caught: the 404 page served at /tutorial?error=<code> (where a refused sign-in lands) linking a new sign-in
  // back to /tutorial, which is that same 404 page; any other page losing its own address.
  test.each([
    ['/tutorial', 'error', '/'],
    ['/packages/komira-ai/http_client', 'error', '/'],
    ['/packages/komira-ai/http_client', 'app', '/packages/komira-ai/http_client'],
    ['/docs/mopm-test/', 'docs', '/docs/mopm-test/'],
    ['/', 'home', '/'],
    ['/tutorial/hello', 'tutorial', '/tutorial/hello'],
    ['/search', null, '/search'],
  ])('%s on a %s page is %s', (path, page, want) => {
    expect(pagePath(path, page)).toBe(want);
  });
});

describe('the box as the page script fills it', () => {
  // Defect caught: a call made on a host with no API, or a box missing from the page throwing.
  test('with no box, or no API on this host, nothing changes and nothing is called', async () => {
    const port = new Port();
    const gate = replayGate({ getWebSession: [SIGNED_IN] });
    await showAccount(port, null, gate, '/');
    expect(gate.requests).toEqual([]);
    const slot = box(port, '/search');
    const before = out(slot);
    await showAccount(port, slot, null, '/packages/komira-ai/http_client');
    expect(out(slot)).toBe(before);
  });

  // Defect caught: the session asked without the cookie (credentials), from the cache, cross-origin, or with a CSRF
  // header on a GET; the app shell's prerendered '/search' left as the return path of a package page.
  test('signed out, the box is the sign-in link back to the address the browser is at, after one same-origin session call', async () => {
    const { slot, gate } = await shown({ getWebSession: [SIGNED_OUT] }, '/packages/komira-ai/http_client/1.0.0');
    expect(out(slot)).toBe(`<div class="site-account" id="site-account">${startLink('/packages/komira-ai/http_client/1.0.0')}</div>`);
    expect(gate.requests).toHaveLength(1);
    const [r] = gate.requests;
    expect(r.url).toBe(SESSION_PATH);
    expect(r.init).toMatchObject({ method: 'GET', mode: 'same-origin', credentials: 'same-origin', cache: 'no-store' });
    expect(r.init.headers).toBeUndefined();
  });

  // Defect caught: the prerendered link replaced although it is already right (a keyboard user who reached it before the
  // script ran loses focus), or a wrong one (the app shell's '/search' on a package page) left in place.
  test('a prerendered link that is already right stays the same node; a wrong one is replaced at once', async () => {
    const port = new Port();
    const right = box(port, '/docs/mopm-test/');
    const link = right.children[0];
    const replay = replayGate({ getWebSession: [SIGNED_OUT] });
    let open = (): void => undefined;
    const held = new Promise<void>((r) => (open = r));
    const gate: TutorialGate = { ...replay, session: async () => (await held, replay.session()) };
    const shownRight = showAccount(port, right, gate, '/docs/mopm-test/');
    const wrong = box(port, '/search');
    const shownWrong = showAccount(port, wrong, gate, '/packages/komira-ai/http_client');
    expect(right.children[0]).toBe(link);
    expect(out(wrong)).toBe(`<div class="site-account" id="site-account">${startLink('/packages/komira-ai/http_client')}</div>`);
    open();
    await Promise.all([shownRight, shownWrong]);
    expect(right.children[0]).toBe(link);
  });

  // Defect caught: an error read as signed in (a login of undefined), or the link removed when the session route fails,
  // leaving no way to sign in.
  test.each([
    ['a CDN 5xx page', [HTML_504]],
    ['invalid_request', [SESSION_INVALID]],
    ['a 200 that is no session', [{ ...SIGNED_IN, body: { login: LOGIN } }]],
    ['no route on this stage', []],
  ])('when the session route answers %s, the box keeps the link', async (_what, answers) => {
    const { slot } = await shown({ getWebSession: answers as RecordedAnswer[] });
    expect(out(slot)).toBe(`<div class="site-account" id="site-account">${startLink('/docs/mopm-test/')}</div>`);
  });

  // Defect caught: the login missing, the link left beside Sign out, or a Sign out with no click handler.
  test('signed in, the box is the login, as text, and Sign out, and no link', async () => {
    const { port, slot } = await shown({ getWebSession: [SIGNED_IN] });
    expect(out(slot)).toBe(signedInBox());
    expect(port.clicks.has(signOutButton(slot))).toBe(true);
    expect(port.focused).toEqual([]);
  });

  // Defect caught: a login put on the page as markup. GitHub logins are [A-Za-z0-9-], but the page decodes any non-empty
  // string, so it has to stay text.
  test('a login that looks like markup is shown as text', async () => {
    const login = '<img src=x>&"';
    const { slot } = await shown({ getWebSession: [{ ...SIGNED_IN, body: { ...(SIGNED_IN.body as object), login } }] });
    expect(out(slot)).toContain('title="&lt;img src=x&gt;&amp;&quot;"><span class="visually-hidden">Signed in as </span>&lt;img src=x&gt;&amp;"</span>');
  });
});

describe('Sign out', () => {
  // Defect caught: the logout sent without the session's CSRF value; the box left signed in after a 204; focus lost
  // with the removed button.
  test('posts the logout with the CSRF value, then shows the link and moves focus to it', async () => {
    const { port, slot, gate } = await shown({ getWebSession: [SIGNED_IN], webLogout: [SIGNED_OUT_204] });
    await clickSignOut(port, slot);
    expect(calls(gate)).toEqual([`GET ${SESSION_PATH} -`, `POST ${LOGOUT_PATH} ${CSRF}`]);
    expect(gate.requests[1].init).toMatchObject({ method: 'POST', mode: 'same-origin', credentials: 'same-origin' });
    expect(out(slot)).toBe(`<div class="site-account" id="site-account" aria-busy="false">${startLink('/docs/mopm-test/')}</div>`);
    expect(port.focused).toEqual([slot.children[0]]);
  });

  // Defect caught: a browser already signed out in another tab shown "not signed out" forever.
  test('a logout answered session_required counts as signed out', async () => {
    const { port, slot } = await shown({ getWebSession: [SIGNED_IN], webLogout: [LOGOUT_SESSION_REQUIRED] });
    await clickSignOut(port, slot);
    expect(out(slot)).toContain(startLink('/docs/mopm-test/'));
  });

  // Defect caught: two logouts from a double click; the box not marked busy while one runs.
  test('while a sign-out runs, the box is busy and another click does nothing', async () => {
    const port = new Port();
    const slot = box(port, '/');
    const replay = replayGate({ getWebSession: [SIGNED_IN], webLogout: [SIGNED_OUT_204] });
    let open = (): void => undefined;
    const held = new Promise<void>((r) => (open = r));
    const gate: TutorialGate = { ...replay, signOut: async () => (await held, replay.signOut()) };
    await showAccount(port, slot, gate, '/');
    const click = port.clicks.get(signOutButton(slot)) as () => void;
    click();
    click();
    await settle();
    expect(attr(slot, 'aria-busy')).toBe('true');
    expect(out(slot)).toContain('Sign out');
    open();
    await settle();
    expect(replay.requests.filter((r) => r.method === 'POST')).toHaveLength(1);
    expect(attr(slot, 'aria-busy')).toBe('false');
    expect(out(slot)).toContain(startLink('/'));
  });

  // Defect caught: a stale CSRF value (the session changed in another tab) never refreshed, or retried more than once.
  test('csrf_failed asks the session again and retries once with its new CSRF value', async () => {
    const { port, slot, gate } = await shown({ getWebSession: [SIGNED_IN, SIGNED_IN_2], webLogout: [LOGOUT_CSRF_FAILED, SIGNED_OUT_204] });
    await clickSignOut(port, slot);
    expect(calls(gate)).toEqual([`GET ${SESSION_PATH} -`, `POST ${LOGOUT_PATH} ${CSRF}`, `GET ${SESSION_PATH} -`, `POST ${LOGOUT_PATH} ${CSRF_2}`]);
    expect(out(slot)).toContain(startLink('/docs/mopm-test/'));
  });

  // Defect caught: a second logout sent for a browser the session route says is already signed out.
  test('csrf_failed, then a session that is signed out, shows the link with no second logout', async () => {
    const { port, slot, gate } = await shown({ getWebSession: [SIGNED_IN, SIGNED_OUT], webLogout: [LOGOUT_CSRF_FAILED] });
    await clickSignOut(port, slot);
    expect(calls(gate)).toEqual([`GET ${SESSION_PATH} -`, `POST ${LOGOUT_PATH} ${CSRF}`, `GET ${SESSION_PATH} -`]);
    expect(out(slot)).toContain(startLink('/docs/mopm-test/'));
  });

  // Defect caught: a failed sign-out shown as signed out (the session still lives), the button gone so the reader
  // cannot try again, focus lost, or the retry loop not ending.
  test.each([
    ['the logout fails', { getWebSession: [SIGNED_IN], webLogout: [HTML_504] }, 2],
    ['csrf_failed and then the session fails', { getWebSession: [SIGNED_IN, HTML_504], webLogout: [LOGOUT_CSRF_FAILED] }, 3],
    ['csrf_failed twice', { getWebSession: [SIGNED_IN, SIGNED_IN_2], webLogout: [LOGOUT_CSRF_FAILED] }, 4],
  ])('when %s, Sign out stays where it is, with the status filled in, and works again', async (_what, script, n) => {
    const { port, slot, gate } = await shown(script as ReplayScript);
    const button = signOutButton(slot);
    await clickSignOut(port, slot);
    expect(gate.requests).toHaveLength(n);
    expect(out(slot)).toBe(signedInBox(true));
    expect(signOutButton(slot)).toBe(button);
    expect(port.focused).toEqual([]);
    (port.clicks.get(button) as () => void)();
    expect(out(slot)).toContain('<span class="account-status" role="status"></span>');
    await settle();
    expect(gate.requests.length).toBeGreaterThan(n);
  });
});

describe('signedInNodes', () => {
  // A live region is announced when text is written into one already on the page, not when it arrives with its text.
  // Defect caught: the status left out until a sign-out fails, or built with its text.
  test('the status is on the page from the start, empty', () => {
    expect(signedInNodes(new Port(), 'alice').map(out)[2]).toBe('<span class="account-status" role="status"></span>');
  });
});

describe('a refused sign-in', () => {
  // Defect caught: a code outside the callback's list shown (any text in the address would be a message); the banner on
  // another page; an address with two codes picking one.
  test.each([
    ['/tutorial', '?error=access_denied', 'access_denied'],
    ['/tutorial', '?error=two_factor_required', 'two_factor_required'],
    ['/tutorial', '?error=login_expired', 'login_expired'],
    ['/tutorial', '?error=unavailable', 'unavailable'],
    ['/tutorial', '?x=1&error=unavailable', 'unavailable'],
    ['/tutorial', '', null],
    ['/tutorial', '?error=', null],
    ['/tutorial', '?error=Access_Denied', null],
    ['/tutorial', '?error=you+have+been+hacked', null],
    ['/tutorial', '?error=access_denied&error=unavailable', null],
    ['/tutorial/', '?error=access_denied', null],
    ['/tutorial/hello', '?error=access_denied', null],
    ['/', '?error=access_denied', null],
    ['/search', '?error=access_denied', null],
  ])('%s%s is %s', (path, search, want) => {
    expect(signInError(path, search)).toBe(want);
  });

  // The whole text, by exact equality, for each code: the reader is told what happened and what to do.
  test.each([
    ['access_denied', '<strong>Not signed in.</strong> GitHub did not authorize mopm.dev, so you are not signed in.'],
    ['two_factor_required', `<strong>Not signed in.</strong> mopm.dev needs two-factor authentication on your GitHub account. <a href="${GITHUB_2FA_URL}">Turn it on at GitHub</a>.`],
    ['login_expired', '<strong>Not signed in.</strong> The sign-in took too long or was already used. Sign in again.'],
    ['unavailable', '<strong>Not signed in.</strong> Sign-in is not available right now. Try again in a few minutes.'],
  ] as const)('%s says what happened', (code, text) => {
    expect(out(signInErrorBanner(new StringDoc(), code))).toBe(`<div class="banner" role="status"><p>${text}</p></div>`);
  });

  // Defect caught: an <a> with no href (or an unchecked one) when the URL check refuses GitHub's address.
  test('the two-factor banner leaves the link out if the URL check refused its address', () => {
    jest.isolateModules(() => {
      jest.doMock('../src/links', () => ({ ...jest.requireActual('../src/links'), webHref: () => null }));
      const mocked = jest.requireActual('../src/account') as typeof import('../src/account');
      expect(out(mocked.signInErrorBanner(new StringDoc(), 'two_factor_required'))).toBe(
        '<div class="banner" role="status"><p><strong>Not signed in.</strong> mopm.dev needs two-factor authentication on your GitHub account.</p></div>',
      );
    });
    jest.dontMock('../src/links');
  });

  // Held to the codes fn_web_login's outcome.rs writes into `?error=` (each `FailureCode::X => "code"` arm). Defect
  // caught: a code added to the callback that the page would not explain, or one the page reads that never comes.
  test('the codes are the ones the callback sends', () => {
    const outcome = readFileSync(join(__dirname, '..', '..', 'service', 'lambda', 'fn_web_login', 'src', 'outcome.rs'), 'utf8');
    const sent = [...outcome.matchAll(/FailureCode::\w+ => "([a-z_]+)"/g)].map((m) => m[1]);
    expect(sent).toHaveLength(4);
    expect([...SIGN_IN_ERRORS].sort()).toEqual(sent.sort());
    expect(signInError('/tutorial', `?error=${sent[0]}`)).toBe(sent[0]);
  });
});
