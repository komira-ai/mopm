//! Tokens (`auth/tokens.ts`): minting, the API-token routes (create, list, revoke), and the bearer
//! middleware that turns an `Authorization` header into a [`Principal`] and the four security schemes of
//! `spec/api/openapi.yaml` over it.
//!
//! Only the SHA-256 of a secret and its first characters are stored; the secret exists once, in the response
//! that creates it.

use std::future::Future;
use std::sync::Arc;

use jiff::Timestamp;
use mopm_core::error::{invalid_request, Detail, ErrorCode, RegistryError};
use mopm_core::version::versions_equivalent;
use mopm_ports::auth::AuthStore;
use mopm_ports::env::{iso_millis, Clock, Rng};
use mopm_ports::error::PortResult;
use mopm_ports::store::Store;
use mopm_ports::types::{TokenKind, TokenRecord, TokenScope};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

use crate::js;

pub const TOKEN_PREFIX: &str = "mopm_";
/// A session token is "fresh" (good for the actions that need a recent login) this long after the login.
pub const SESSION_FRESH_MS: i64 = 15 * 60_000;
pub const OIDC_TOKEN_TTL_MS: i64 = 15 * 60_000;
const DAY_MS: i64 = 86_400_000;
/// `last_used_at` is written at most this often per token, to keep reads from becoming writes.
const TOUCH_EVERY_MS: i64 = 60_000;
const MAX_TOKENS_PER_USER: usize = 50;
const MAX_NAME_UTF16: usize = 80;

pub(crate) fn error<const N: usize>(code: ErrorCode, message: impl Into<String>, detail: [(&str, &str); N]) -> RegistryError {
    RegistryError::new(code, message, detail.into_iter().map(|(k, v)| (k.to_string(), v.to_string())).collect::<Detail>())
}

pub(crate) fn unavailable() -> RegistryError {
    error(ErrorCode::Unavailable, "The registry is temporarily unavailable.", [])
}

fn scope_missing(scope: &str, name: &str) -> RegistryError {
    error(ErrorCode::ScopeMissing, format!("The token does not have the '{scope}' scope for '{name}'."), [("scope", scope), ("name", name)])
}

/// `^mopm_[a-z2-7]{32,64}$`: the spec's Token pattern.
pub fn is_token_shaped(s: &str) -> bool {
    s.strip_prefix(TOKEN_PREFIX).is_some_and(|rest| (32..=64).contains(&rest.len()) && rest.bytes().all(|b| matches!(b, b'a'..=b'z' | b'2'..=b'7')))
}

/// `^[a-z][a-z0-9_]{1,63}$`.
pub fn is_valid_package_name(s: &str) -> bool {
    let b = s.as_bytes();
    (2..=64).contains(&b.len()) && b[0].is_ascii_lowercase() && b[1..].iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_')
}

/// RFC 4648 base32, lower case, no padding.
pub fn base32(bytes: &[u8]) -> String {
    const B32: &[u8; 32] = b"abcdefghijklmnopqrstuvwxyz234567";
    let (mut bits, mut value, mut out) = (0u32, 0u32, String::new());
    for &b in bytes {
        value = (value << 8) | u32::from(b);
        bits += 8;
        while bits >= 5 {
            out.push(B32[((value >> (bits - 5)) & 31) as usize] as char);
            bits -= 5;
        }
        value &= (1 << bits) - 1;
    }
    if bits > 0 {
        out.push(B32[((value << (5 - bits)) & 31) as usize] as char);
    }
    out
}

/// 200 bits of randomness: `mopm_` and 40 base32 characters.
pub fn generate_token_secret(rng: &dyn Rng) -> String {
    let mut bytes = [0u8; 25];
    rng.fill(&mut bytes);
    format!("{TOKEN_PREFIX}{}", base32(&bytes))
}

pub fn hash_token(secret: &str) -> String {
    hex::encode(Sha256::digest(secret.as_bytes()))
}

/// `<prefix>_` and 96 bits of randomness in hex.
pub fn new_id(rng: &dyn Rng, prefix: &str) -> String {
    let mut bytes = [0u8; 12];
    rng.fill(&mut bytes);
    format!("{prefix}_{}", hex::encode(bytes))
}

pub(crate) fn now_ms(clock: &dyn Clock) -> i64 {
    clock.now().as_millisecond()
}

pub(crate) fn iso_at(ms: i64) -> String {
    iso_millis(Timestamp::from_millisecond(ms).expect("a representable time"))
}

/// `Date.parse(iso) <= now`, failing closed: a time that does not parse is in the past.
pub(crate) fn is_past(iso: &str, now: i64) -> bool {
    js::parse_ms(iso).is_none_or(|t| t <= now)
}

/// Who a request is, once its bearer token resolved.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Principal {
    pub token_id: String,
    pub kind: TokenKind,
    /// Absent for an `oidc` token.
    pub github_id: Option<u64>,
    pub scopes: Vec<TokenScope>,
    pub packages: Vec<String>,
    pub version: Option<String>,
    pub fresh_until: Option<String>,
}

/// A token row, before it has an id, a hash and a prefix.
#[derive(Clone, Debug)]
pub struct TokenFields {
    pub kind: TokenKind,
    pub github_id: Option<u64>,
    pub name: String,
    pub scopes: Vec<TokenScope>,
    pub packages: Vec<String>,
    pub all_current: bool,
    pub version: Option<String>,
    pub fresh_until: Option<String>,
    pub created_at: String,
    pub expires_at: String,
    pub issued_to: Option<String>,
}

#[derive(Clone, Debug)]
pub struct MintedToken {
    pub id: String,
    pub secret: String,
    pub record: TokenRecord,
}

/// Create a token row (hash and prefix only) and return the secret, which the caller shows once.
pub async fn mint_token<A: AuthStore>(store: &A, rng: &dyn Rng, f: TokenFields) -> PortResult<MintedToken> {
    let secret = generate_token_secret(rng);
    let record = TokenRecord {
        id: new_id(rng, "tok"),
        kind: f.kind,
        github_id: f.github_id,
        name: f.name,
        hash: hash_token(&secret),
        prefix: secret[..TOKEN_PREFIX.len() + 6].to_string(),
        scopes: f.scopes,
        packages: f.packages,
        all_current: f.all_current,
        version: f.version,
        fresh_until: f.fresh_until,
        created_at: f.created_at,
        expires_at: f.expires_at,
        revoked_at: None,
        last_used_at: None,
        issued_to: f.issued_to,
    };
    store.put_token(&record).await?;
    Ok(MintedToken { id: record.id.clone(), secret, record })
}

/// The packages a token covers: a list, or `all_current` (the snapshot of the caller's packages at creation).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PackageSet {
    AllCurrent,
    Names(Vec<String>),
}

impl Serialize for PackageSet {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            PackageSet::AllCurrent => s.serialize_str("all_current"),
            PackageSet::Names(n) => n.serialize(s),
        }
    }
}

impl<'de> Deserialize<'de> for PackageSet {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Wire {
            Word(String),
            Names(Vec<String>),
        }
        match Wire::deserialize(d)? {
            Wire::Word(w) if w == "all_current" => Ok(PackageSet::AllCurrent),
            Wire::Word(w) => Err(serde::de::Error::custom(format!("packages must be a list or all_current, not '{w}'"))),
            Wire::Names(n) => Ok(PackageSet::Names(n)),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct CreateTokenInput {
    pub name: String,
    /// `publish` or `yank`; anything else is refused by name.
    pub scopes: Vec<String>,
    pub packages: PackageSet,
    /// A whole number of days, 1 to 90 (a fractional number is refused, as the TypeScript does).
    pub expires_in_days: f64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct TokenMeta {
    pub id: String,
    pub name: String,
    pub scopes: Vec<TokenScope>,
    pub packages: PackageSet,
    pub created_at: String,
    pub expires_at: String,
    pub last_used_at: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct CreatedToken {
    #[serde(flatten)]
    pub meta: TokenMeta,
    /// The secret: shown here and nowhere else.
    pub token: String,
}

fn meta(t: &TokenRecord) -> TokenMeta {
    TokenMeta {
        id: t.id.clone(),
        name: t.name.clone(),
        scopes: t.scopes.clone(),
        packages: if t.all_current { PackageSet::AllCurrent } else { PackageSet::Names(t.packages.clone()) },
        created_at: t.created_at.clone(),
        expires_at: t.expires_at.clone(),
        last_used_at: t.last_used_at.clone(),
    }
}

fn is_live_api_token(t: &TokenRecord, now: i64) -> bool {
    t.kind == TokenKind::Api && t.revoked_at.is_none() && !is_past(&t.expires_at, now)
}

/// The routes that manage a caller's API tokens. The caller proves a fresh session first (see
/// [`Authenticator::fresh_session`]); this type does not look at the request.
pub struct TokenService<A, S> {
    auth: Arc<A>,
    store: Arc<S>,
    clock: Arc<dyn Clock>,
    rng: Arc<dyn Rng>,
}

impl<A: AuthStore, S: Store> TokenService<A, S> {
    /// `store` answers which packages an account owns.
    pub fn new(auth: Arc<A>, store: Arc<S>, clock: Arc<dyn Clock>, rng: Arc<dyn Rng>) -> Self {
        TokenService { auth, store, clock, rng }
    }

    /// The secret is returned once.
    pub async fn create(&self, github_id: u64, input: CreateTokenInput) -> PortResult<CreatedToken> {
        let name_len = js::length(&input.name);
        if !(1..=MAX_NAME_UTF16).contains(&name_len) {
            return Err(invalid_request("name must be 1 to 80 characters").into());
        }
        if input.scopes.is_empty() {
            return Err(invalid_request("scopes must not be empty").into());
        }
        let mut scopes = Vec::new();
        for s in &input.scopes {
            match s.as_str() {
                "publish" => scopes.push(TokenScope::Publish),
                "yank" => scopes.push(TokenScope::Yank),
                other => return Err(invalid_request(&format!("unknown scope '{other}'")).into()),
            }
        }
        let days = input.expires_in_days;
        if !(days.fract() == 0.0 && (1.0..=90.0).contains(&days)) {
            return Err(invalid_request("expires_in_days must be an integer from 1 to 90").into());
        }
        let now = now_ms(self.clock.as_ref());
        let live = self.auth.list_tokens(github_id).await?.iter().filter(|t| is_live_api_token(t, now)).count();
        if live >= MAX_TOKENS_PER_USER {
            return Err(invalid_request(&format!("at most {MAX_TOKENS_PER_USER} live tokens per account")).into());
        }

        let owned = self.store.owned_packages(github_id).await?;
        let (packages, all_current) = match &input.packages {
            PackageSet::AllCurrent => {
                let mut p = owned.clone();
                p.sort_by(|a, b| js::cmp_utf16(a, b));
                if p.is_empty() {
                    return Err(invalid_request("you own no packages yet").into());
                }
                (p, true)
            }
            PackageSet::Names(names) => {
                if names.is_empty() {
                    return Err(invalid_request("packages must be a non-empty list or all_current").into());
                }
                let mut p = names.clone();
                p.sort_by(|a, b| js::cmp_utf16(a, b));
                p.dedup();
                for n in &p {
                    if !is_valid_package_name(n) {
                        return Err(error(ErrorCode::InvalidName, format!("'{n}' is not a valid package name."), [("name", n.as_str())]).into());
                    }
                    if !owned.contains(n) {
                        return Err(error(ErrorCode::NotOwner, format!("You are not an owner of '{n}'."), [("name", n.as_str())]).into());
                    }
                }
                (p, false)
            }
        };

        scopes.sort_by_key(|s| matches!(s, TokenScope::Yank));
        scopes.dedup();
        let m = mint_token(
            self.auth.as_ref(),
            self.rng.as_ref(),
            TokenFields {
                kind: TokenKind::Api,
                github_id: Some(github_id),
                name: input.name,
                scopes,
                packages,
                all_current,
                version: None,
                fresh_until: None,
                created_at: iso_at(now),
                expires_at: iso_at(now + days as i64 * DAY_MS),
                issued_to: None,
            },
        )
        .await?;
        Ok(CreatedToken { meta: meta(&m.record), token: m.secret })
    }

    /// The caller's live API tokens: metadata only, oldest first.
    pub async fn list(&self, github_id: u64) -> PortResult<Vec<TokenMeta>> {
        let now = now_ms(self.clock.as_ref());
        let mut live: Vec<TokenRecord> = self.auth.list_tokens(github_id).await?.into_iter().filter(|t| is_live_api_token(t, now)).collect();
        live.sort_by(|a, b| a.created_at.cmp(&b.created_at).then_with(|| a.id.cmp(&b.id)));
        Ok(live.iter().map(meta).collect())
    }

    /// Immediate. Another account's token, or a session or CI token, is `token_not_found`. Repeating is fine.
    pub async fn revoke(&self, github_id: u64, token_id: &str) -> PortResult<()> {
        match self.auth.get_user_token(github_id, token_id).await? {
            Some(t) if t.kind == TokenKind::Api => {
                self.auth.revoke_token(&t.hash, &iso_at(now_ms(self.clock.as_ref()))).await?;
                Ok(())
            }
            _ => Err(error(ErrorCode::TokenNotFound, "There is no such token.", []).into()),
        }
    }
}

/// What the bearer middleware needs of the store: a lookup by hash and the last-used mark. Every
/// [`AuthStore`] is one.
pub trait TokenLookup: Send + Sync {
    fn get_token_by_hash(&self, hash: &str) -> impl Future<Output = PortResult<Option<TokenRecord>>> + Send;
    fn touch_token(&self, hash: &str, at: &str) -> impl Future<Output = PortResult<()>> + Send;
}

impl<T: AuthStore> TokenLookup for T {
    fn get_token_by_hash(&self, hash: &str) -> impl Future<Output = PortResult<Option<TokenRecord>>> + Send {
        AuthStore::get_token_by_hash(self, hash)
    }

    fn touch_token(&self, hash: &str, at: &str) -> impl Future<Output = PortResult<()>> + Send {
        AuthStore::touch_token(self, hash, at)
    }
}

pub struct Authenticator<L> {
    store: Arc<L>,
    clock: Arc<dyn Clock>,
}

impl<L: TokenLookup> Authenticator<L> {
    pub fn new(store: Arc<L>, clock: Arc<dyn Clock>) -> Self {
        Authenticator { store, clock }
    }

    /// Resolve an `Authorization` header value to a [`Principal`], or the contract's error.
    pub async fn authenticate(&self, authorization: Option<&str>) -> PortResult<Principal> {
        let missing = || error(ErrorCode::TokenMissing, "This request needs a token.", []);
        let unknown = || error(ErrorCode::TokenUnknown, "The token is not recognised.", []);
        let secret = authorization.and_then(bearer_secret).ok_or_else(missing)?;
        // A string that cannot be a token never reaches the store.
        if !is_token_shaped(secret) {
            return Err(unknown().into());
        }

        let hash = hash_token(secret);
        let rec = self.store.get_token_by_hash(&hash).await?;
        // Compare again, in constant time, whatever the store matched on: a row whose hash differs is no match.
        let rec = rec.filter(|r| bool::from(r.hash.as_bytes().ct_eq(hash.as_bytes()))).ok_or_else(unknown)?;
        if rec.revoked_at.is_some() {
            return Err(error(ErrorCode::TokenRevoked, "The token was revoked.", []).into());
        }
        let now = now_ms(self.clock.as_ref());
        if is_past(&rec.expires_at, now) {
            return Err(error(ErrorCode::TokenExpired, format!("The token expired at {}.", rec.expires_at), [("expires_at", rec.expires_at.as_str())]).into());
        }
        if rec.last_used_at.as_deref().and_then(js::parse_ms).is_none_or(|t| now - t >= TOUCH_EVERY_MS) {
            self.store.touch_token(&rec.hash, &iso_at(now)).await?;
        }
        Ok(Principal {
            token_id: rec.id,
            kind: rec.kind,
            github_id: rec.github_id,
            scopes: rec.scopes,
            packages: rec.packages,
            version: rec.version,
            fresh_until: rec.fresh_until,
        })
    }

    // The four security schemes of spec/api/openapi.yaml.

    /// `userToken`: any live token of a user, a session or an API token. A CI token is nobody's.
    pub fn user_token(&self, p: &Principal) -> Result<u64, RegistryError> {
        match p.github_id {
            Some(id) if p.kind != TokenKind::Oidc => Ok(id),
            _ => Err(scope_missing("user", "this account")),
        }
    }

    /// `freshSession`: a session token younger than 15 minutes. An older session or an API token is `stale_session`.
    pub fn fresh_session(&self, p: &Principal) -> Result<u64, RegistryError> {
        let id = self.user_token(p)?;
        let fresh = p.kind == TokenKind::Session && p.fresh_until.as_deref().is_some_and(|t| !is_past(t, now_ms(self.clock.as_ref())));
        if fresh {
            Ok(id)
        } else {
            Err(error(ErrorCode::StaleSession, "This action needs a login from the last 15 minutes.", []))
        }
    }

    /// `publishToken`: an API token with `publish` for the package, or a CI token for exactly this package and version.
    pub fn publish_token(&self, p: &Principal, name: &str, version: &str) -> Result<(), RegistryError> {
        let publishes = p.scopes.contains(&TokenScope::Publish);
        let allowed = match p.kind {
            TokenKind::Oidc => publishes && p.packages.len() == 1 && p.packages[0] == name && p.version.as_deref().is_some_and(|v| same_version(v, version)),
            TokenKind::Api => publishes && p.packages.iter().any(|n| n == name),
            TokenKind::Session => false,
        };
        if allowed {
            Ok(())
        } else {
            Err(scope_missing("publish", name))
        }
    }

    /// `yankToken`: an API token with `yank` (or `publish`, which the spec lets yank) for the package.
    pub fn yank_token(&self, p: &Principal, name: &str) -> Result<(), RegistryError> {
        let may = p.scopes.iter().any(|s| matches!(s, TokenScope::Yank | TokenScope::Publish));
        if p.kind == TokenKind::Api && may && p.packages.iter().any(|n| n == name) {
            Ok(())
        } else {
            Err(scope_missing("yank", name))
        }
    }
}

/// `/^Bearer +(\S+)$/i` of the trimmed header value: the secret, if it has that shape.
fn bearer_secret(header: &str) -> Option<&str> {
    let h = js::trim(header);
    let (scheme, rest) = h.split_at_checked(6)?;
    if !scheme.eq_ignore_ascii_case("bearer") {
        return None;
    }
    let secret = rest.strip_prefix(' ')?.trim_start_matches(' ');
    (!secret.is_empty() && !secret.chars().any(js::is_js_space)).then_some(secret)
}

/// The same version. The grammar has one spelling of each (`1.0` is not a version), so this is string equality for
/// valid versions; an invalid one is no match, even with itself.
fn same_version(a: &str, b: &str) -> bool {
    versions_equivalent(a, b).unwrap_or(false)
}

#[cfg(test)]
mod unit {
    use super::*;

    #[test]
    fn base32_is_rfc_4648_lower_case_without_padding() {
        for (input, want) in [("", ""), ("f", "my"), ("fo", "mzxq"), ("foo", "mzxw6"), ("foob", "mzxw6yq"), ("fooba", "mzxw6ytb"), ("foobar", "mzxw6ytboi")] {
            assert_eq!(base32(input.as_bytes()), want, "{input}");
        }
        assert_eq!(base32(&[0xff; 25]), "7".repeat(40));
        assert_eq!(base32(&[0; 25]), "a".repeat(40));
    }

    #[test]
    fn the_token_shape_is_the_specs() {
        let ok = format!("mopm_{}", "a2".repeat(16));
        assert!(is_token_shaped(&ok));
        assert!(is_token_shaped(&format!("mopm_{}", "z".repeat(64))));
        assert!(!is_token_shaped(&format!("mopm_{}", "z".repeat(31))));
        assert!(!is_token_shaped(&format!("mopm_{}", "z".repeat(65))));
        for bad in ["MOPM_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "mopm_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1", "mopm_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] {
            assert!(!is_token_shaped(bad), "{bad}");
        }
        assert!(!is_token_shaped(&format!("{ok}\n")), "a trailing newline is not part of the pattern");
    }

    #[test]
    fn package_names_are_the_specs() {
        for ok in ["ab", "a_1", &format!("a{}", "b".repeat(63))] {
            assert!(is_valid_package_name(ok), "{ok}");
        }
        for bad in ["", "a", "1a", "_a", "Ab", "a-b", "a b", "ab\n", &format!("a{}", "b".repeat(64)), "\u{e9}a"] {
            assert!(!is_valid_package_name(bad), "{bad:?}");
        }
    }

    #[test]
    fn the_bearer_header_is_read_as_the_typescript_did() {
        assert_eq!(bearer_secret("Bearer abc"), Some("abc"));
        assert_eq!(bearer_secret("bearer   abc"), Some("abc"));
        assert_eq!(bearer_secret("BEARER abc"), Some("abc"));
        assert_eq!(bearer_secret("  Bearer abc \n"), Some("abc"));
        for bad in ["", "Bearer", "Bearer ", "Basic abc", "Bearerabc", "Bearer a b", "Bearer\tabc", "Bearer a\u{a0}b", "Token abc", "\u{e9}earer abc"] {
            assert_eq!(bearer_secret(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn an_unparsable_time_counts_as_past() {
        assert!(is_past("garbage", 0));
        assert!(is_past("1970-01-01T00:00:01.000Z", 1000), "expiry is exclusive of the instant");
        assert!(!is_past("1970-01-01T00:00:01.000Z", 999));
    }
}
