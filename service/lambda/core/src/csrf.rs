//! The CSRF value of a web session (docs/design/tutorial-sign-in.md, section 2): every cookie-authenticated `POST`
//! carries `X-Mopm-CSRF` equal to `base64url(SHA-256("mopm-csrf\0" + session token))`, unpadded. It is derived from
//! the session token, so nothing new is stored for it, and the token cannot be recovered from it.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

use crate::token::TokenSecret;

/// What the hash input starts with, so the value is no other SHA-256 of the token (the row's `hash` is one).
pub const CSRF_DOMAIN: &[u8] = b"mopm-csrf\0";

/// The CSRF value of `session`: 43 characters of `A-Za-z0-9-_`.
pub fn csrf_value(session: &TokenSecret) -> String {
    let mut h = Sha256::new();
    h.update(CSRF_DOMAIN);
    h.update(session.expose().as_bytes());
    URL_SAFE_NO_PAD.encode(h.finalize())
}

/// Whether `presented` (the request's `X-Mopm-CSRF`) is `session`'s CSRF value. The bytes are compared in constant
/// time; a value of another length, the empty one included, is refused.
pub fn csrf_matches(session: &TokenSecret, presented: &str) -> bool {
    bool::from(csrf_value(session).as_bytes().ct_eq(presented.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(fill: u8) -> TokenSecret {
        TokenSecret::mint(&[fill; crate::token::SECRET_BYTES])
    }

    // The value for the all-zero secret, `mopm_` and 40 `a`s: computed independently with Node's crypto by
    // service/api/test/auth/token-vectors.test.ts, which holds tests/fixtures/token_vectors.json to it.
    const ZERO_CSRF: &str = "xWcCkV1r9oST5Nrqj9DOsFbfC_KAZXaHtwzE9xsTu3A";

    #[test]
    fn the_value_of_a_known_secret() {
        assert_eq!(session(0).expose(), format!("mopm_{}", "a".repeat(40)));
        assert_eq!(csrf_value(&session(0)), ZERO_CSRF);
    }

    #[test]
    fn the_value_is_43_url_safe_characters() {
        for fill in [0u8, 1, 0x7f, 0xff] {
            let v = csrf_value(&session(fill));
            assert_eq!(v.len(), 43, "{v}");
            assert!(
                v.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'),
                "{v}"
            );
        }
    }

    #[test]
    fn the_value_is_not_the_rows_hash() {
        let s = session(0);
        let hex_of_csrf = hex::encode(URL_SAFE_NO_PAD.decode(csrf_value(&s)).unwrap());
        assert_ne!(hex_of_csrf, s.hash());
    }

    #[test]
    fn the_sessions_own_value_matches() {
        let s = session(9);
        assert!(csrf_matches(&s, &csrf_value(&s)));
    }

    #[test]
    fn another_sessions_value_is_refused() {
        assert!(!csrf_matches(&session(1), &csrf_value(&session(2))));
    }

    #[test]
    fn an_empty_value_is_refused() {
        assert!(!csrf_matches(&session(1), ""));
    }

    #[test]
    fn a_value_of_another_length_is_refused() {
        let s = session(1);
        let v = csrf_value(&s);
        assert!(!csrf_matches(&s, &v[..42]));
        assert!(!csrf_matches(&s, &format!("{v}A")));
        // The padded spelling of the same digest is not the value either.
        assert!(!csrf_matches(&s, &format!("{v}=")));
    }

    #[test]
    fn a_value_differing_in_one_character_is_refused() {
        let s = session(1);
        let v = csrf_value(&s);
        let last = if v.ends_with('A') { 'B' } else { 'A' };
        let changed = format!("{}{last}", &v[..42]);
        assert!(!csrf_matches(&s, &changed));
    }
}
