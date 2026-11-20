//! The website's session (docs/design/tutorial-sign-in.md, section 2): the `tokens` row a valid
//! `__Host-mopm_session` cookie names. [`SessionAuth`] runs, in order, and answers the first refusal:
//!
//! 1. the edge-header check ([`EdgeCheck`]): `session_required`;
//! 2. no `Authorization` header: the website's routes never combine a bearer token with the cookie
//!    (`invalid_request`);
//! 3. exactly one session cookie, in the token grammar: `session_required` otherwise;
//! 4. for a `POST`, the CSRF checks ([`CsrfCheck`]): `csrf_failed`;
//! 5. the row by the token's SHA-256 ([`AuthStore::get_token_by_hash`]): present, its hash equal (compared again
//!    in constant time), `kind: session`, not revoked, `expires_at` after now (the injected [`Clock`]); then the
//!    account ([`AuthStore::get_user`]). Each miss is `session_required`.
//! 6. the row's `last_used_at` is set to now ([`AuthStore::touch_token`]) when it is absent or a minute old, the
//!    TypeScript `Authenticator`'s rule, so both languages write the row alike.
//!
//! Steps 1 to 4 read no store: a request that fails them, a forged cross-site `POST` included, never reads or
//! touches a session row. A store that fails is `internal_error`.

use jiff::{SignedDuration, Timestamp};
use mopm_core::error::RegistryError;
use mopm_core::token::TokenSecret;
use mopm_ports::auth::AuthStore;
use mopm_ports::env::{iso_millis, Clock};
use mopm_ports::types::{TokenKind, TokenRecord, UserRecord};
use subtle::ConstantTimeEq;

use crate::cookie::{single, SESSION_COOKIE};
use crate::csrf::CsrfCheck;
use crate::edge::EdgeCheck;
use crate::envelope::{authorization_refused, internal, session_required};
use crate::request::WebRequest;

/// How old `last_used_at` may be before a request writes it again (`TOUCH_EVERY_MS` of `tokens.ts`).
const TOUCH_EVERY: SignedDuration = SignedDuration::from_secs(60);

/// A signed-in browser: its session token (for the CSRF value, never for a log), the session's row and the
/// account.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WebSession {
    pub secret: TokenSecret,
    pub token: TokenRecord,
    pub user: UserRecord,
}

/// The session authenticator of the website's routes, over the stage's `AuthStore` and clock.
pub struct SessionAuth<S, C> {
    edge: EdgeCheck,
    csrf: CsrfCheck,
    store: S,
    clock: C,
}

/// `Date.parse` of a stored time; a value it cannot read is `None`.
fn parse_time(s: &str) -> Option<Timestamp> {
    s.parse().ok()
}

impl<S: AuthStore, C: Clock> SessionAuth<S, C> {
    pub fn new(edge: EdgeCheck, csrf: CsrfCheck, store: S, clock: C) -> Self {
        SessionAuth { edge, csrf, store, clock }
    }

    /// The session of a `GET` (`GET /api/v2/auth/web/session`): steps 1 to 3, 5 and 6.
    pub async fn session(&self, req: &WebRequest) -> Result<WebSession, RegistryError> {
        let secret = self.cookie_token(req)?;
        self.lookup(secret).await
    }

    /// The session of a `POST` (`/auth/web/logout`, `/tutorial/sandbox`): every step, the CSRF checks
    /// included.
    pub async fn session_for_post(&self, req: &WebRequest) -> Result<WebSession, RegistryError> {
        let secret = self.cookie_token(req)?;
        self.csrf.check(req, &secret)?;
        self.lookup(secret).await
    }

    /// Steps 1 to 3: the request came through the site, carries no bearer token, and names one token.
    fn cookie_token(&self, req: &WebRequest) -> Result<TokenSecret, RegistryError> {
        self.edge.check(req)?;
        if req.headers.contains("authorization") {
            return Err(authorization_refused());
        }
        let value = single(req, SESSION_COOKIE).map_err(|_| session_required("two session cookies"))?.ok_or_else(|| session_required("no session cookie"))?;
        TokenSecret::parse(value).ok_or_else(|| session_required("the session cookie is not a token"))
    }

    /// Steps 5 and 6.
    async fn lookup(&self, secret: TokenSecret) -> Result<WebSession, RegistryError> {
        let hash = secret.hash();
        let token = self.store.get_token_by_hash(&hash).await.map_err(|e| internal(&e))?;
        let token = token.filter(|t| bool::from(t.hash.as_bytes().ct_eq(hash.as_bytes()))).ok_or_else(|| session_required("no such session"))?;
        if token.kind != TokenKind::Session {
            return Err(session_required("the token is not a session"));
        }
        if token.revoked_at.is_some() {
            return Err(session_required("the session was revoked"));
        }
        let now = self.clock.now();
        // A time that cannot be read is no time at all: the session counts as expired.
        if parse_time(&token.expires_at).is_none_or(|expires| expires <= now) {
            return Err(session_required("the session expired"));
        }
        let github_id = token.github_id.ok_or_else(|| session_required("the session names no account"))?;
        let user = self.store.get_user(github_id).await.map_err(|e| internal(&e))?.ok_or_else(|| session_required("the session's account does not exist"))?;
        let stale = token.last_used_at.as_deref().and_then(parse_time).is_none_or(|used| now.duration_since(used) >= TOUCH_EVERY);
        if stale {
            self.store.touch_token(&hash, &iso_millis(now)).await.map_err(|e| internal(&e))?;
        }
        Ok(WebSession { secret, token, user })
    }
}

#[cfg(test)]
#[path = "session_tests.rs"]
mod tests;
