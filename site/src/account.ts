// The site header's account box (#site-account), on every page.
//
// Every prerendered page carries, in the box, the link "Sign in with GitHub" to the start route with the page's own path
// as `return_to` (tools/layout.ts builds it with `accountLink`). That link is the whole box without a script, and stays
// the whole box while signed out: the cached HTML never says who is signed in. Once a page is on screen, the page script
// (main.ts) calls `showAccount`, which rewrites the link when it is not the one for `pagePath` (the app shell is one page
// for many addresses; the 404 page sends a sign-in home), asks the session route (session.ts: `GET /api/v2/auth/web/session`, same-origin, `cache:
// 'no-store'`), and, when it answers a signed-in session, puts the GitHub login and a Sign out button in the box. Sign
// out is `POST /api/v2/auth/web/logout` with the session's CSRF value; any answer that is not a session (an error, a
// 5xx, a stage without the route) leaves the link as it is.
//
// The session route gives no avatar, and the page CSP allows images from the site's own origin only, so the box shows
// the login as text.
//
// A refused sign-in is sent to `/tutorial?error=<code>` (fn_web_login, "callback"); `signInError` reads that address and
// `signInErrorBanner` says what happened, which main.ts shows under the header.
//
// Written against a small DOM port (AccountPort), as enhance.ts is, so test/account.test.ts drives it with StringDoc.

import { type Doc, h } from './doc.js';
import { webHref } from './links.js';
import { isReturnPath, signInHref, type WebSession } from './session.js';

/** The header's account box: tools/layout.ts writes it, main.ts finds it by this id. */
export const ACCOUNT_ID = 'site-account';
/** The Sign out button's id. */
export const SIGN_OUT_ID = 'site-sign-out';

/** What the box asks of the session client (session.ts webSession; the tutorial's gate has the same two). */
export type AccountSession = Pick<WebSession, 'session' | 'signOut'>;

/** The DOM reads and writes beyond Doc that the box needs. */
export interface AccountPort<N> extends Doc<N> {
  replaceChildren(node: N, nodes: N[]): void;
  onClick(node: N, fn: () => void): void;
  focus(node: N): void;
  setText(node: N, text: string): void;
  /** The href of the box's sign-in link (`a.sign-in`), or null when it holds none. */
  linkHref(box: N): string | null;
}

/**
 * Where a sign-in from the page at `pathname` comes back to: the path itself when the start route keeps it as its
 * `return_to` (`isReturnPath`), else the home page. The start route would send any other value to `/tutorial`, which
 * a stage without the tutorial does not serve; a page with no such path is the 404 page or a docs address the router
 * redirects.
 */
export function returnPathOf(pathname: string): string {
  return isReturnPath(pathname) ? pathname : '/';
}

/**
 * The path the box's link returns to on a page whose body has `data-page` `page` (tools/layout.ts) at `pathname`: the
 * address the browser is at, except on the 404 page, which answers any address the site has no page for (`/tutorial`
 * among them on a stage that does not serve the tutorial), so a sign-in from it comes back to the home page.
 */
export function pagePath(pathname: string, page: string | null): string {
  return page === 'error' ? '/' : pathname;
}

/**
 * The link "Sign in with GitHub" back to `pathname` (through `returnPathOf`). Below a narrow width the stylesheet hides
 * " with GitHub" visually, never from the link's accessible name.
 */
export function accountLink<N>(doc: Doc<N>, pathname: string): N {
  return h(doc, 'a', { class: 'button sign-in', href: signInHref(returnPathOf(pathname)) }, h(doc, 'span', null, 'Sign in', h(doc, 'span', { class: 'sign-in-more' }, ' with GitHub')));
}

/** What the status says after a sign-out that did not finish. */
export const NOT_SIGNED_OUT = 'Not signed out. Try again.';

/**
 * The box while `login` is signed in: who, Sign out, and an empty status. The status is on the page, empty, before a
 * sign-out can fail, so that a screen reader announces the text when it is written into it.
 */
export function signedInNodes<N>(doc: Doc<N>, login: string): [N, N, N] {
  return [
    h(doc, 'span', { class: 'account-login', title: login }, h(doc, 'span', { class: 'visually-hidden' }, 'Signed in as '), login),
    h(doc, 'button', { type: 'button', id: SIGN_OUT_ID, class: 'button' }, 'Sign out'),
    h(doc, 'span', { class: 'account-status', role: 'status' }),
  ];
}

/**
 * Fills the box: the link for `pathname` at once (the prerendered one is left in place, and keeps its focus, when it is
 * already that link), then who is signed in once the session route answers. With no box (slot null) or no API on this
 * host (web null) it changes nothing and calls nothing.
 *
 * Sign out keeps its button, and focus on it, while it runs (a second click meanwhile does nothing), and moves focus
 * to the link that replaces it. A `csrf_failed` answer (the session changed in another tab) asks the session again, and
 * then either finds the browser signed out or tries once more with the new CSRF value. Anything else that is not
 * signed out leaves the button where it is and writes NOT_SIGNED_OUT into the status.
 */
export async function showAccount<N>(port: AccountPort<N>, slot: N | null, web: AccountSession | null, pathname: string): Promise<void> {
  if (slot === null || web === null) return;
  const box: N = slot;
  const g: AccountSession = web;
  const signedOut = (): N => {
    const link = accountLink(port, pathname);
    port.replaceChildren(box, [link]);
    return link;
  };
  if (port.linkHref(box) !== signInHref(returnPathOf(pathname))) signedOut();
  const s = await g.session();
  if ('error' in s || !s.signed_in) return;
  const [login, button, status] = signedInNodes(port, s.login);
  let busy = false;

  async function signOut(): Promise<void> {
    if (busy) return;
    busy = true;
    port.setAttr(box, 'aria-busy', 'true');
    port.setText(status, '');
    let r = await g.signOut();
    if ('error' in r && r.error === 'csrf_failed') {
      const again = await g.session();
      if (!('error' in again)) r = again.signed_in ? await g.signOut() : { signed_out: true };
    }
    busy = false;
    port.setAttr(box, 'aria-busy', 'false');
    if ('signed_out' in r) port.focus(signedOut());
    else port.setText(status, NOT_SIGNED_OUT);
  }

  port.replaceChildren(box, [login, button, status]);
  port.onClick(button, () => void signOut());
}

// ---- a refused sign-in ------------------------------------------------------------------------------------------

/** The codes a refused sign-in comes back with (fn_web_login's `outcome.rs`, the callback's failure redirect). */
export const SIGN_IN_ERRORS = ['access_denied', 'two_factor_required', 'login_expired', 'unavailable'] as const;
export type SignInError = (typeof SIGN_IN_ERRORS)[number];

/** Where the callback sends a refused sign-in: `/tutorial?error=<code>`. */
export const SIGN_IN_ERROR_PATH = '/tutorial';

/** GitHub's instructions for turning on two-factor authentication. */
export const GITHUB_2FA_URL = 'https://docs.github.com/en/authentication/securing-your-account-with-two-factor-authentication-2fa/configuring-two-factor-authentication';

/** The code of a refused sign-in at this address: exactly one `error` of the list on SIGN_IN_ERROR_PATH, else null. */
export function signInError(pathname: string, search: string): SignInError | null {
  if (pathname !== SIGN_IN_ERROR_PATH) return null;
  const all = new URLSearchParams(search).getAll('error');
  return all.length === 1 && (SIGN_IN_ERRORS as readonly string[]).includes(all[0]) ? (all[0] as SignInError) : null;
}

const SIGN_IN_ERROR_TEXT: Readonly<Record<SignInError, string>> = {
  access_denied: 'GitHub did not authorize mopm.dev, so you are not signed in.',
  two_factor_required: 'mopm.dev needs two-factor authentication on your GitHub account.',
  login_expired: 'The sign-in took too long or was already used. Sign in again.',
  unavailable: 'Sign-in is not available right now. Try again in a few minutes.',
};

/**
 * The banner that says why the sign-in with `code` did not finish; for two-factor, with a link to GitHub's instructions
 * (left out, never linked unchecked, if links.ts ever refused the address).
 */
export function signInErrorBanner<N>(doc: Doc<N>, code: SignInError): N {
  const href = code === 'two_factor_required' ? webHref(GITHUB_2FA_URL) : null;
  const help = href !== null ? [' ', h(doc, 'a', { href }, 'Turn it on at GitHub'), '.'] : [];
  return h(doc, 'div', { class: 'banner', role: 'status' }, h(doc, 'p', null, h(doc, 'strong', null, 'Not signed in.'), ' ', SIGN_IN_ERROR_TEXT[code], ...help));
}
