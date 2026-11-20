//! The website's two cookies (docs/design/tutorial-sign-in.md, sections 1 and 2): the session,
//! `__Host-mopm_session` (seven days), and the login transaction, `__Host-mopm_login` (ten minutes). Both are
//! `Secure; HttpOnly; Path=/; SameSite=Lax` and carry no `Domain`, which the `__Host-` prefix requires: the browser
//! keeps them for the site's own host only. `Lax`, because the sign-in's callback is a top-level navigation from
//! github.com, which a `Strict` cookie would miss.
//!
//! A cookie is read by its exact name only, and a request with two cookies of that name is refused: a second
//! one can only come from somewhere other than this host's `Set-Cookie`.

use std::fmt;

use mopm_core::token::TokenSecret;
use thiserror::Error;

use crate::request::WebRequest;

pub const SESSION_COOKIE: &str = "__Host-mopm_session";
pub const LOGIN_COOKIE: &str = "__Host-mopm_login";
/// Seven days, the session's absolute lifetime.
pub const SESSION_MAX_AGE: u64 = 604_800;
/// Ten minutes, the login transaction's lifetime.
pub const LOGIN_MAX_AGE: u64 = 600;

const ATTRIBUTES: &str = "Secure; HttpOnly; Path=/; SameSite=Lax";

/// A `Set-Cookie` header value. Only this module makes one, so every value carries the attributes above.
#[derive(Clone, PartialEq, Eq)]
pub struct SetCookie(String);

impl SetCookie {
    /// The header value: for the response, never for a log (a session's carries the session token).
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for SetCookie {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // The name and the attributes, never the value.
        let (name, rest) = self.0.split_once('=').unwrap_or((&self.0, ""));
        let attrs = rest.split_once(';').map_or("", |(_, a)| a);
        write!(f, "SetCookie({name}=...;{attrs})")
    }
}

fn set_cookie(name: &str, value: &str, max_age: u64) -> SetCookie {
    SetCookie(format!("{name}={value}; {ATTRIBUTES}; Max-Age={max_age}"))
}

/// The session cookie for `session`.
pub fn session_cookie(session: &TokenSecret) -> SetCookie {
    set_cookie(SESSION_COOKIE, session.expose(), SESSION_MAX_AGE)
}

/// The value given for the login cookie is not a cookie value (RFC 6265 `cookie-octet`s, at least one).
#[derive(Debug, Error, PartialEq, Eq)]
#[error("the login cookie's value is empty or has a character a cookie value cannot hold")]
pub struct InvalidCookieValue;

/// The login transaction's cookie for `txn`: refused when `txn` is empty or holds anything but RFC 6265's
/// `cookie-octet` (no space, `"`, `,`, `;`, `\` or control character), so it cannot end the cookie early.
pub fn login_cookie(txn: &str) -> Result<SetCookie, InvalidCookieValue> {
    let octet = |b: u8| matches!(b, 0x21 | 0x23..=0x2b | 0x2d..=0x3a | 0x3c..=0x5b | 0x5d..=0x7e);
    if txn.is_empty() || !txn.bytes().all(octet) {
        return Err(InvalidCookieValue);
    }
    Ok(set_cookie(LOGIN_COOKIE, txn, LOGIN_MAX_AGE))
}

/// Clears the session cookie (sign-out).
pub fn clear_session_cookie() -> SetCookie {
    set_cookie(SESSION_COOKIE, "", 0)
}

/// Clears the login cookie (every answer of the callback).
pub fn clear_login_cookie() -> SetCookie {
    set_cookie(LOGIN_COOKIE, "", 0)
}

/// The request carries two or more cookies of one name.
#[derive(Debug, Error, PartialEq, Eq)]
#[error("the request carries more than one cookie named {name}")]
pub struct DuplicateCookie {
    pub name: &'static str,
}

/// The value of the cookie named exactly `name` (case counts): `None` when there is none, an error when there
/// are two or more.
pub fn single<'r>(
    req: &'r WebRequest,
    name: &'static str,
) -> Result<Option<&'r str>, DuplicateCookie> {
    let mut values = req
        .cookies
        .iter()
        .filter(|c| c.name == name)
        .map(|c| c.value.as_str());
    let first = values.next();
    match values.next() {
        Some(_) => Err(DuplicateCookie { name }),
        None => Ok(first),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request::Method;

    fn secret() -> TokenSecret {
        TokenSecret::mint(&[0; mopm_core::token::SECRET_BYTES])
    }

    #[test]
    fn the_session_cookie_has_exactly_the_designs_attributes() {
        assert_eq!(session_cookie(&secret()).as_str(), "__Host-mopm_session=mopm_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=604800");
    }

    #[test]
    fn the_login_cookie_has_exactly_the_designs_attributes() {
        assert_eq!(
            login_cookie("txn-AZaz09_~").unwrap().as_str(),
            "__Host-mopm_login=txn-AZaz09_~; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=600"
        );
    }

    #[test]
    fn the_clearing_forms_are_empty_with_max_age_zero() {
        assert_eq!(
            clear_session_cookie().as_str(),
            "__Host-mopm_session=; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=0"
        );
        assert_eq!(
            clear_login_cookie().as_str(),
            "__Host-mopm_login=; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=0"
        );
    }

    #[test]
    fn no_cookie_names_a_domain() {
        for c in [
            session_cookie(&secret()),
            login_cookie("t").unwrap(),
            clear_session_cookie(),
            clear_login_cookie(),
        ] {
            assert!(
                !c.as_str().to_ascii_lowercase().contains("domain"),
                "{}",
                c.as_str()
            );
        }
    }

    #[test]
    fn a_login_value_that_could_end_the_cookie_is_refused() {
        for bad in [
            "", "a b", "a;b", "a,b", "a\"b", "a\\b", "a\tb", "a\u{7f}b", "a\nb", "é",
        ] {
            assert_eq!(login_cookie(bad), Err(InvalidCookieValue), "{bad:?}");
        }
        assert_eq!(
            InvalidCookieValue.to_string(),
            "the login cookie's value is empty or has a character a cookie value cannot hold"
        );
    }

    #[test]
    fn every_cookie_octet_is_a_login_value() {
        let all: String = (0x21u8..=0x7e)
            .filter(|b| !matches!(b, b'"' | b',' | b';' | b'\\'))
            .map(char::from)
            .collect();
        assert_eq!(all.len(), 90);
        assert!(login_cookie(&all).is_ok());
    }

    #[test]
    fn debug_shows_the_name_and_attributes_but_never_the_value() {
        assert_eq!(format!("{:?}", session_cookie(&secret())), "SetCookie(__Host-mopm_session=...; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=604800)");
        assert_eq!(
            format!("{:?}", clear_login_cookie()),
            "SetCookie(__Host-mopm_login=...; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=0)"
        );
    }

    fn with_cookies(header: &str) -> WebRequest {
        WebRequest::new(Method::Get, "/", "r").with_cookies(header)
    }

    #[test]
    fn exactly_the_named_cookie_is_read() {
        let r = with_cookies(
            "__host-mopm_session=lower; __Host-mopm_session=v; __Host-mopm_sessionx=w; other=1",
        );
        assert_eq!(single(&r, SESSION_COOKIE), Ok(Some("v")));
        assert_eq!(single(&r, LOGIN_COOKIE), Ok(None));
    }

    #[test]
    fn two_cookies_of_the_name_are_refused_even_with_one_value() {
        let r = with_cookies("__Host-mopm_session=v; __Host-mopm_session=v");
        let err = single(&r, SESSION_COOKIE).unwrap_err();
        assert_eq!(
            err,
            DuplicateCookie {
                name: SESSION_COOKIE
            }
        );
        assert_eq!(
            err.to_string(),
            "the request carries more than one cookie named __Host-mopm_session"
        );
    }
}
