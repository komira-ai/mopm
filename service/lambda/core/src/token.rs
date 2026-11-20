//! Tokens, ported from `service/api/src/auth/tokens.ts`: the secret's grammar, minting it from random bytes the
//! caller supplies, its SHA-256 (the key of the `tokens` table), the prefix a list shows, and the fields of the
//! session a web login creates.
//!
//! The same random bytes give the same secret, hash and prefix as `generateTokenSecret`, `hashToken` and
//! `mintToken` (`tests/fixtures/token_vectors.json`, which the TypeScript side checks too).

use std::fmt;

use jiff::{SignedDuration, Timestamp};
use sha2::{Digest, Sha256};
use thiserror::Error;

/// `TOKEN_PREFIX`: what every secret starts with.
pub const TOKEN_PREFIX: &str = "mopm_";
/// How many random bytes a minted secret encodes: 200 bits, 40 base32 characters.
pub const SECRET_BYTES: usize = 25;
/// How many characters of a secret a token row keeps as its `prefix` (`TOKEN_PREFIX.length + 6`).
pub const DISPLAY_PREFIX_LEN: usize = TOKEN_PREFIX.len() + 6;
/// The fewest and most base32 characters after the prefix that `TOKEN_PATTERN` accepts.
pub const BODY_MIN: usize = 32;
pub const BODY_MAX: usize = 64;

/// The `name` of the row a web login creates.
pub const WEB_SESSION_NAME: &str = "web login";
/// How long a web session lasts, absolute, from its creation.
pub const WEB_SESSION_LIFETIME: SignedDuration = SignedDuration::from_hours(7 * 24);

const B32: &[u8; 32] = b"abcdefghijklmnopqrstuvwxyz234567";

/// A token secret in `TOKEN_PATTERN`'s grammar: `mopm_` and 32 to 64 of `a-z2-7`. Its `Debug` hides the value, so
/// a secret in a logged structure does not leak.
#[derive(Clone, PartialEq, Eq)]
pub struct TokenSecret(String);

impl TokenSecret {
    /// `generateTokenSecret` with the caller's random bytes: `mopm_` and their base32 (lowercase, no padding).
    pub fn mint(random: &[u8; SECRET_BYTES]) -> TokenSecret {
        TokenSecret(format!("{TOKEN_PREFIX}{}", base32(random)))
    }

    /// The secret `s`, when it is in the grammar (`TOKEN_PATTERN.test(s)`).
    pub fn parse(s: &str) -> Option<TokenSecret> {
        is_token(s).then(|| TokenSecret(s.to_owned()))
    }

    /// The secret itself: for the one response or cookie that carries it, never for a log.
    pub fn expose(&self) -> &str {
        &self.0
    }

    /// `hashToken`: SHA-256 of the whole secret, lowercase hex.
    pub fn hash(&self) -> String {
        hash_token(&self.0)
    }

    /// The row's `prefix`: the first [`DISPLAY_PREFIX_LEN`] characters (`mopm_` and six more).
    pub fn display_prefix(&self) -> &str {
        // Every secret is ASCII and longer than the prefix (the grammar), so this is a character boundary.
        &self.0[..DISPLAY_PREFIX_LEN]
    }
}

impl fmt::Debug for TokenSecret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "TokenSecret({}...)", self.display_prefix())
    }
}

/// `TOKEN_PATTERN.test(s)`: `^mopm_[a-z2-7]{32,64}$`.
pub fn is_token(s: &str) -> bool {
    s.strip_prefix(TOKEN_PREFIX).is_some_and(|body| {
        (BODY_MIN..=BODY_MAX).contains(&body.len())
            && body
                .bytes()
                .all(|b| b.is_ascii_lowercase() || (b'2'..=b'7').contains(&b))
    })
}

/// `hashToken`: SHA-256 of `secret`'s UTF-8 bytes, lowercase hex. Any string, as in TypeScript; a caller looking a
/// presented value up checks [`is_token`] first.
pub fn hash_token(secret: &str) -> String {
    hex::encode(Sha256::digest(secret.as_bytes()))
}

/// `base32` of `tokens.ts`: RFC 4648's alphabet in lower case, most significant bit first, the last group padded with
/// zero bits, no `=`.
fn base32(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(5) * 8);
    let mut value: u32 = 0;
    let mut bits = 0u32;
    for &b in bytes {
        value = (value << 8) | u32::from(b);
        bits += 8;
        while bits >= 5 {
            out.push(char::from(B32[((value >> (bits - 5)) & 31) as usize]));
            bits -= 5;
        }
        value &= (1 << bits) - 1;
    }
    if bits > 0 {
        out.push(char::from(B32[((value << (5 - bits)) & 31) as usize]));
    }
    out
}

/// The fields of the `tokens` row a web login writes for its session, other than the row's id and account (the
/// caller's). The rest of the row is fixed: `kind: session`, no scopes, no packages, `all_current: false`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WebSessionFields {
    /// [`WEB_SESSION_NAME`].
    pub name: &'static str,
    /// SHA-256 of the secret, lowercase hex.
    pub hash: String,
    /// [`TokenSecret::display_prefix`].
    pub prefix: String,
    /// `now`, as `toISOString` writes it.
    pub created_at: String,
    /// Equal to `created_at`: a web session is never fresh, so it cannot create an API token on the TypeScript routes.
    pub fresh_until: String,
    /// `now` plus [`WEB_SESSION_LIFETIME`].
    pub expires_at: String,
}

/// `now` is so late that `now` plus the session's lifetime is past the last time a timestamp can hold.
#[derive(Debug, Error, PartialEq, Eq)]
#[error("a session created at {created_at} would expire after the last representable time")]
pub struct ExpiryOutOfRange {
    pub created_at: String,
}

/// The row fields of a web session for `secret`, created at `now`.
pub fn web_session_fields(
    secret: &TokenSecret,
    now: Timestamp,
) -> Result<WebSessionFields, ExpiryOutOfRange> {
    let created_at = iso_millis(now);
    let expires = now
        .checked_add(WEB_SESSION_LIFETIME)
        .map_err(|_| ExpiryOutOfRange {
            created_at: created_at.clone(),
        })?;
    Ok(WebSessionFields {
        name: WEB_SESSION_NAME,
        hash: secret.hash(),
        prefix: secret.display_prefix().to_owned(),
        fresh_until: created_at.clone(),
        created_at,
        expires_at: iso_millis(expires),
    })
}

/// `Date.prototype.toISOString`: `YYYY-MM-DDTHH:MM:SS.mmmZ`, as the TypeScript rows hold their times.
fn iso_millis(ts: Timestamp) -> String {
    ts.strftime("%Y-%m-%dT%H:%M:%S%.3fZ").to_string()
}

#[cfg(test)]
#[path = "token_tests.rs"]
mod tests;
