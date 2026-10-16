//! The tests of `service/api/test/auth-tokens.test.ts`, over the memory stores. What they prove: the token
//! routes and the bearer middleware answer as the TypeScript does for each case below, and what is persisted
//! is the hash and a prefix and never the secret.

use std::sync::Arc;

use mopm_core::error::ErrorCode;
use mopm_ports::store::Store;
use mopm_ports::env::Clock;
use mopm_ports::error::PortResult;
use mopm_ports::types::{TokenKind, TokenRecord, TokenScope};
use mopm_testing::memory_auth::MemoryAuthStore;
use mopm_testing::memory_store::MemoryStore;
use serde_json::json;

use crate::test_support::{code_of, refusal, rig, start_ms, Rig, ALICE, BOB};
use crate::tokens::*;

const DAY: i64 = 86_400_000;

struct Fixture {
    r: Rig,
    tokens: TokenService<MemoryAuthStore, MemoryStore>,
    auth: Authenticator<MemoryAuthStore>,
}

async fn setup() -> Fixture {
    let r = rig().await;
    let clock: Arc<dyn Clock> = r.clock.clone();
    let tokens = TokenService::new(r.auth.clone(), r.store.clone(), clock.clone(), r.rng.clone());
    let auth = Authenticator::new(r.auth.clone(), clock);
    Fixture { r, tokens, auth }
}

fn input(name: &str, scopes: &[&str], packages: &[&str], days: f64) -> CreateTokenInput {
    CreateTokenInput { name: name.into(), scopes: scopes.iter().map(|s| s.to_string()).collect(), packages: PackageSet::Names(packages.iter().map(|s| s.to_string()).collect()), expires_in_days: days }
}

fn bearer(secret: &str) -> String {
    format!("Bearer {secret}")
}

impl Fixture {
    async fn api(&self, id: u64, name: &str, scopes: &[&str], packages: &[&str]) -> CreatedToken {
        self.tokens.create(id, input(name, scopes, packages, 1.0)).await.unwrap()
    }

    async fn principal(&self, secret: &str) -> Principal {
        self.auth.authenticate(Some(&bearer(secret))).await.unwrap()
    }

    /// A session token of `id`, fresh for `fresh_ms`.
    async fn session(&self, id: u64, fresh_ms: i64) -> String {
        let now = self.r.clock.now().as_millisecond();
        let f = TokenFields {
            kind: TokenKind::Session,
            github_id: Some(id),
            name: "login".into(),
            scopes: vec![],
            packages: vec![],
            all_current: false,
            version: None,
            fresh_until: Some(iso_at(now + fresh_ms)),
            created_at: iso_at(now),
            expires_at: iso_at(now + 30 * DAY),
            issued_to: None,
        };
        mint_token(self.r.auth.as_ref(), self.r.rng.as_ref(), f).await.unwrap().secret
    }
}

// ---- API token creation -------------------------------------------------------------------------

#[tokio::test]
async fn the_secret_has_the_recognisable_prefix_and_matches_the_pattern_and_only_the_hash_and_a_prefix_are_stored() {
    let f = setup().await;
    let t = f.api(ALICE, "ci", &["publish"], &["alpha"]).await;
    assert!(t.token.starts_with("mopm_"));
    assert!(is_token_shaped(&t.token));
    assert_eq!(t.token.len(), 45, "mopm_ and 40 base32 characters");
    let rows = f.r.auth.dump_tokens();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].hash, hash_token(&t.token));
    assert!(rows[0].hash.len() == 64 && rows[0].hash.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)));
    assert!(t.token.starts_with(&rows[0].prefix));
    assert_eq!(rows[0].prefix.len(), 11);
    // the secret appears nowhere in anything persisted, nor in what list returns later
    assert!(!serde_json::to_string(&rows).unwrap().contains(&t.token));
    assert!(!serde_json::to_string(&f.tokens.list(ALICE).await.unwrap()).unwrap().contains(&t.token));
}

#[tokio::test]
async fn two_tokens_never_share_a_secret_or_an_id() {
    let f = setup().await;
    let a = f.api(ALICE, "a", &["publish"], &["alpha"]).await;
    let b = f.api(ALICE, "b", &["publish"], &["alpha"]).await;
    assert_ne!(a.token, b.token);
    assert_ne!(a.meta.id, b.meta.id);
    assert!(a.meta.id.starts_with("tok_") && a.meta.id.len() == 4 + 24);
}

#[tokio::test]
async fn expiry_is_expires_in_days_from_now() {
    let f = setup().await;
    let t = f.tokens.create(ALICE, input("x", &["yank"], &["beta"], 7.0)).await.unwrap();
    assert_eq!(t.meta.expires_at, iso_at(start_ms() + 7 * DAY));
    assert_eq!(t.meta.created_at, iso_at(start_ms()));
}

#[tokio::test]
async fn expires_in_days_outside_one_to_ninety_or_fractional_is_invalid_request() {
    let f = setup().await;
    for d in [0.0, 91.0, 1.5, -1.0, f64::NAN, f64::INFINITY] {
        assert_eq!(code_of(f.tokens.create(ALICE, input("x", &["publish"], &["alpha"], d)).await), ErrorCode::InvalidRequest, "{d}");
    }
    for d in [1.0, 90.0] {
        f.tokens.create(ALICE, input("x", &["publish"], &["alpha"], d)).await.unwrap();
    }
}

#[tokio::test]
async fn an_unknown_scope_an_empty_scope_list_and_an_odd_name_are_invalid_request_with_the_message() {
    let f = setup().await;
    let e = refusal(f.tokens.create(ALICE, input("x", &["owners"], &["alpha"], 1.0)).await);
    assert_eq!((e.code, e.message.as_str()), (ErrorCode::InvalidRequest, "The request is not valid: unknown scope 'owners'."));
    let e = refusal(f.tokens.create(ALICE, input("x", &[], &["alpha"], 1.0)).await);
    assert_eq!(e.message, "The request is not valid: scopes must not be empty.");
    let e = refusal(f.tokens.create(ALICE, input("", &["publish"], &["alpha"], 1.0)).await);
    assert_eq!(e.message, "The request is not valid: name must be 1 to 80 characters.");
    assert_eq!(e.detail["detail"], "name must be 1 to 80 characters");
    // 80 UTF-16 units are allowed, 81 are not; an astral character counts twice
    f.tokens.create(ALICE, input(&"n".repeat(80), &["publish"], &["alpha"], 1.0)).await.unwrap();
    f.tokens.create(ALICE, input(&"\u{1f600}".repeat(40), &["publish"], &["alpha"], 1.0)).await.unwrap();
    assert_eq!(code_of(f.tokens.create(ALICE, input(&"n".repeat(81), &["publish"], &["alpha"], 1.0)).await), ErrorCode::InvalidRequest);
    assert_eq!(code_of(f.tokens.create(ALICE, input(&"\u{1f600}".repeat(41), &["publish"], &["alpha"], 1.0)).await), ErrorCode::InvalidRequest);
}

#[tokio::test]
async fn a_package_the_caller_does_not_own_is_not_owner_and_a_malformed_name_is_invalid_name() {
    let f = setup().await;
    let e = refusal(f.tokens.create(ALICE, input("x", &["publish"], &["alpha", "gamma"], 1.0)).await);
    assert_eq!((e.code, e.status()), (ErrorCode::NotOwner, 403));
    assert_eq!(e.detail["name"], "gamma");
    assert_eq!(e.message, "You are not an owner of 'gamma'.");
    let e = refusal(f.tokens.create(ALICE, input("x", &["publish"], &["Bad-Name"], 1.0)).await);
    assert_eq!((e.code, e.message.as_str()), (ErrorCode::InvalidName, "'Bad-Name' is not a valid package name."));
    assert_eq!(code_of(f.tokens.create(ALICE, input("x", &["publish"], &[], 1.0)).await), ErrorCode::InvalidRequest);
}

#[tokio::test]
async fn packages_and_scopes_are_stored_sorted_and_without_duplicates() {
    let f = setup().await;
    let t = f.tokens.create(ALICE, input("x", &["yank", "publish", "yank"], &["beta", "alpha", "beta"], 1.0)).await.unwrap();
    assert_eq!(t.meta.packages, PackageSet::Names(vec!["alpha".into(), "beta".into()]));
    assert_eq!(t.meta.scopes, vec![TokenScope::Publish, TokenScope::Yank]);
}

#[tokio::test]
async fn all_current_is_a_snapshot_a_package_claimed_later_is_not_covered() {
    let f = setup().await;
    let mut i = input("all", &["publish"], &[], 1.0);
    i.packages = PackageSet::AllCurrent;
    let t = f.tokens.create(ALICE, i).await.unwrap();
    assert_eq!(t.meta.packages, PackageSet::AllCurrent);
    assert_eq!(serde_json::to_value(&t.meta).unwrap()["packages"], json!("all_current"));
    f.r.store.add_owner(&mopm_core::types::OwnerRecord { name: "delta".into(), github_id: ALICE, handle: "u".into(), added_at: "t".into() }).await.unwrap();
    let p = f.principal(&t.token).await;
    f.auth.publish_token(&p, "alpha", "1.0.0").unwrap();
    f.auth.publish_token(&p, "beta", "1.0.0").unwrap();
    assert_eq!(f.auth.publish_token(&p, "delta", "1.0.0").unwrap_err().code, ErrorCode::ScopeMissing);
}

#[tokio::test]
async fn all_current_with_no_packages_is_refused() {
    let f = setup().await;
    let mut i = input("x", &["publish"], &[], 1.0);
    i.packages = PackageSet::AllCurrent;
    let e = refusal(f.tokens.create(7777, i).await);
    assert_eq!((e.code, e.message.as_str()), (ErrorCode::InvalidRequest, "The request is not valid: you own no packages yet."));
}

#[tokio::test]
async fn fifty_live_tokens_is_the_limit_and_expired_or_revoked_ones_do_not_count() {
    let f = setup().await;
    let mut ids = Vec::new();
    for n in 0..50 {
        ids.push(f.api(ALICE, &format!("t{n}"), &["publish"], &["alpha"]).await.meta.id);
    }
    let e = refusal(f.tokens.create(ALICE, input("one more", &["publish"], &["alpha"], 1.0)).await);
    assert_eq!(e.message, "The request is not valid: at most 50 live tokens per account.");
    f.tokens.create(BOB, input("bob", &["publish"], &["gamma"], 1.0)).await.unwrap();
    f.tokens.revoke(ALICE, &ids[0]).await.unwrap();
    f.api(ALICE, "fits now", &["publish"], &["alpha"]).await;
    assert_eq!(code_of(f.tokens.create(ALICE, input("full again", &["publish"], &["alpha"], 1.0)).await), ErrorCode::InvalidRequest);
    f.r.clock.advance_millis(DAY + 1);
    f.api(ALICE, "all expired", &["publish"], &["alpha"]).await;
}

#[test]
fn the_wire_forms_of_the_inputs_and_outputs() {
    let i: CreateTokenInput = serde_json::from_value(json!({"name": "ci", "scopes": ["publish"], "packages": ["a"], "expires_in_days": 30})).unwrap();
    assert_eq!(i.packages, PackageSet::Names(vec!["a".into()]));
    let i: CreateTokenInput = serde_json::from_value(json!({"name": "ci", "scopes": ["publish"], "packages": "all_current", "expires_in_days": 30})).unwrap();
    assert_eq!(i.packages, PackageSet::AllCurrent);
    assert!(serde_json::from_value::<CreateTokenInput>(json!({"name": "ci", "scopes": ["publish"], "packages": "everything", "expires_in_days": 30})).is_err());
    assert!(serde_json::from_value::<CreateTokenInput>(json!({"name": "ci", "scopes": ["publish"], "packages": 5, "expires_in_days": 30})).is_err());
    let created = CreatedToken {
        meta: TokenMeta { id: "tok_1".into(), name: "n".into(), scopes: vec![TokenScope::Publish], packages: PackageSet::Names(vec!["a".into()]), created_at: "c".into(), expires_at: "e".into(), last_used_at: None },
        token: "mopm_x".into(),
    };
    assert_eq!(
        serde_json::to_value(created).unwrap(),
        json!({"id": "tok_1", "name": "n", "scopes": ["publish"], "packages": ["a"], "created_at": "c", "expires_at": "e", "last_used_at": null, "token": "mopm_x"})
    );
}

// ---- list and revoke ----------------------------------------------------------------------------

#[tokio::test]
async fn list_shows_the_callers_live_api_tokens_only() {
    let f = setup().await;
    f.session(ALICE, 900_000).await;
    let a = f.api(ALICE, "a", &["publish"], &["alpha"]).await;
    f.api(BOB, "b", &["publish"], &["gamma"]).await;
    let l = f.tokens.list(ALICE).await.unwrap();
    assert_eq!(l.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), [a.meta.id.as_str()]);
    assert!(serde_json::to_value(&l[0]).unwrap().get("token").is_none());
    assert_eq!(l[0].last_used_at, None);
}

#[tokio::test]
async fn list_is_oldest_first_and_an_expired_token_drops_out() {
    let f = setup().await;
    let first = f.api(ALICE, "first", &["publish"], &["alpha"]).await;
    f.r.clock.advance_millis(1000);
    let second = f.api(ALICE, "second", &["publish"], &["alpha"]).await;
    let l = f.tokens.list(ALICE).await.unwrap();
    assert_eq!(l.iter().map(|t| t.id.clone()).collect::<Vec<_>>(), [first.meta.id, second.meta.id.clone()]);
    f.r.clock.advance_millis(DAY - 1000 + 1);
    assert_eq!(f.tokens.list(ALICE).await.unwrap().iter().map(|t| t.id.clone()).collect::<Vec<_>>(), [second.meta.id]);
    f.r.clock.advance_millis(1000);
    assert!(f.tokens.list(ALICE).await.unwrap().is_empty());
}

#[tokio::test]
async fn revocation_is_immediate_the_same_secret_is_token_revoked_at_once_and_the_token_leaves_the_list() {
    let f = setup().await;
    let t = f.api(ALICE, "a", &["publish"], &["alpha"]).await;
    f.principal(&t.token).await;
    f.tokens.revoke(ALICE, &t.meta.id).await.unwrap();
    assert_eq!(code_of(f.auth.authenticate(Some(&bearer(&t.token))).await), ErrorCode::TokenRevoked);
    assert!(f.tokens.list(ALICE).await.unwrap().is_empty());
    f.tokens.revoke(ALICE, &t.meta.id).await.unwrap();
    assert_eq!(f.r.auth.dump_tokens()[0].revoked_at.as_deref(), Some(iso_at(start_ms()).as_str()));
}

#[tokio::test]
async fn revoking_another_accounts_token_a_missing_token_or_a_session_token_is_token_not_found_and_changes_nothing() {
    let f = setup().await;
    let t = f.api(ALICE, "a", &["publish"], &["alpha"]).await;
    f.session(ALICE, 900_000).await;
    assert_eq!(code_of(f.tokens.revoke(BOB, &t.meta.id).await), ErrorCode::TokenNotFound);
    assert_eq!(code_of(f.tokens.revoke(ALICE, "tok_nope").await), ErrorCode::TokenNotFound);
    let session_id = f.r.auth.dump_tokens().into_iter().find(|t| t.kind == TokenKind::Session).unwrap().id;
    let e = refusal(f.tokens.revoke(ALICE, &session_id).await);
    assert_eq!((e.code, e.message.as_str(), e.status()), (ErrorCode::TokenNotFound, "There is no such token.", 404));
    assert!(f.r.auth.dump_tokens().iter().all(|t| t.revoked_at.is_none()));
    f.principal(&t.token).await;
}

// ---- authenticate: every refusal, exactly ---------------------------------------------------------

#[tokio::test]
async fn no_header_and_a_header_that_is_not_bearer_are_token_missing() {
    let f = setup().await;
    for h in [None, Some(""), Some("Basic abc"), Some("Bearer"), Some("Bearer "), Some("Bearer two words")] {
        let e = refusal(f.auth.authenticate(h).await);
        assert_eq!((e.code, e.message.as_str(), e.status()), (ErrorCode::TokenMissing, "This request needs a token.", 401), "{h:?}");
    }
}

#[tokio::test]
async fn a_string_that_is_not_shaped_like_a_token_and_a_well_formed_token_nobody_issued_are_token_unknown() {
    let f = setup().await;
    for secret in ["not-a-token".to_string(), format!("mopm_{}", "a".repeat(40)), format!("MOPM_{}", "a".repeat(40)), format!("mopm_{}", "a".repeat(31))] {
        let e = refusal(f.auth.authenticate(Some(&bearer(&secret))).await);
        assert_eq!((e.code, e.message.as_str()), (ErrorCode::TokenUnknown, "The token is not recognised."), "{secret}");
    }
}

#[tokio::test]
async fn a_token_one_character_off_is_token_unknown_not_a_near_match() {
    let f = setup().await;
    let t = f.api(ALICE, "a", &["publish"], &["alpha"]).await;
    let last = t.token.chars().last().unwrap();
    let off = format!("{}{}", &t.token[..t.token.len() - 1], if last == 'a' { 'b' } else { 'a' });
    assert_eq!(code_of(f.auth.authenticate(Some(&bearer(&off))).await), ErrorCode::TokenUnknown);
}

/// A faulty or hostile store: answers every lookup with one row, whatever hash was asked for.
struct Lying(TokenRecord);

impl TokenLookup for Lying {
    async fn get_token_by_hash(&self, _hash: &str) -> PortResult<Option<TokenRecord>> {
        Ok(Some(self.0.clone()))
    }

    async fn touch_token(&self, _hash: &str, _at: &str) -> PortResult<()> {
        Ok(())
    }
}

#[tokio::test]
async fn a_store_that_hands_back_a_row_whose_hash_is_not_the_presented_token_is_token_unknown() {
    let f = setup().await;
    let t = f.api(ALICE, "a", &["publish"], &["alpha"]).await;
    let real = f.r.auth.dump_tokens().remove(0);
    let clock: Arc<dyn Clock> = f.r.clock.clone();
    let lying = Authenticator::new(Arc::new(Lying(TokenRecord { hash: hash_token(&format!("mopm_{}", "b".repeat(40))), ..real.clone() })), clock.clone());
    assert_eq!(code_of(lying.authenticate(Some(&bearer(&t.token))).await), ErrorCode::TokenUnknown);
    // control: the same row with its real hash is accepted
    let honest = Authenticator::new(Arc::new(Lying(real)), clock);
    assert_eq!(honest.authenticate(Some(&bearer(&t.token))).await.unwrap().github_id, Some(ALICE));
}

#[tokio::test]
async fn expiry_is_exact_valid_up_to_the_instant_expired_from_it_with_the_instant_in_detail() {
    let f = setup().await;
    let t = f.api(ALICE, "a", &["publish"], &["alpha"]).await;
    f.r.clock.advance_millis(DAY - 1);
    f.principal(&t.token).await;
    f.r.clock.advance_millis(1);
    let e = refusal(f.auth.authenticate(Some(&bearer(&t.token))).await);
    assert_eq!((e.code, e.status()), (ErrorCode::TokenExpired, 401));
    assert_eq!(e.detail["expires_at"], t.meta.expires_at);
    assert_eq!(e.message, format!("The token expired at {}.", t.meta.expires_at));
}

#[tokio::test]
async fn a_row_whose_expiry_does_not_parse_is_expired() {
    let f = setup().await;
    let t = f.api(ALICE, "a", &["publish"], &["alpha"]).await;
    let mut row = f.r.auth.dump_tokens().remove(0);
    row.expires_at = "tomorrow".into();
    let clock: Arc<dyn Clock> = f.r.clock.clone();
    assert_eq!(code_of(Authenticator::new(Arc::new(Lying(row)), clock).authenticate(Some(&bearer(&t.token))).await), ErrorCode::TokenExpired);
}

#[tokio::test]
async fn a_token_that_is_both_revoked_and_expired_is_token_revoked() {
    let f = setup().await;
    let t = f.api(ALICE, "a", &["publish"], &["alpha"]).await;
    f.tokens.revoke(ALICE, &t.meta.id).await.unwrap();
    f.r.clock.advance_millis(2 * DAY);
    assert_eq!(code_of(f.auth.authenticate(Some(&bearer(&t.token))).await), ErrorCode::TokenRevoked);
}

#[tokio::test]
async fn the_scheme_is_case_insensitive_and_extra_spaces_are_tolerated() {
    let f = setup().await;
    let t = f.api(ALICE, "a", &["publish"], &["alpha"]).await;
    for h in [format!("bearer   {}", t.token), format!("BEARER {}", t.token), format!("  Bearer {} \n", t.token)] {
        assert_eq!(f.auth.authenticate(Some(&h)).await.unwrap().kind, TokenKind::Api, "{h:?}");
    }
}

#[tokio::test]
async fn last_used_at_is_recorded_and_not_rewritten_on_every_request() {
    let f = setup().await;
    let t = f.api(ALICE, "a", &["publish"], &["alpha"]).await;
    let used = || f.r.auth.dump_tokens()[0].last_used_at.clone();
    f.principal(&t.token).await;
    let first = used();
    assert_eq!(first.as_deref(), Some(iso_at(start_ms()).as_str()));
    f.r.clock.advance_millis(10_000);
    f.principal(&t.token).await;
    assert_eq!(used(), first);
    f.r.clock.advance_millis(60_000 - 10_000 - 1);
    f.principal(&t.token).await;
    assert_eq!(used(), first, "59 999 ms after the mark");
    f.r.clock.advance_millis(1);
    f.principal(&t.token).await;
    assert_eq!(used().as_deref(), Some(iso_at(start_ms() + 60_000).as_str()));
}

#[tokio::test]
async fn the_principal_carries_what_the_row_says() {
    let f = setup().await;
    let t = f.api(ALICE, "a", &["publish", "yank"], &["alpha"]).await;
    let p = f.principal(&t.token).await;
    assert_eq!(
        p,
        Principal { token_id: t.meta.id, kind: TokenKind::Api, github_id: Some(ALICE), scopes: vec![TokenScope::Publish, TokenScope::Yank], packages: vec!["alpha".into()], version: None, fresh_until: None }
    );
}

// ---- the four security schemes --------------------------------------------------------------------

struct Principals {
    f: Fixture,
    api: Principal,
    yank: Principal,
    sess: Principal,
}

async fn principals() -> Principals {
    let f = setup().await;
    let api = f.api(ALICE, "a", &["publish"], &["alpha"]).await;
    let yank = f.api(ALICE, "y", &["yank"], &["alpha"]).await;
    let sess = f.session(ALICE, 15 * 60_000).await;
    let (api, yank, sess) = (f.principal(&api.token).await, f.principal(&yank.token).await, f.principal(&sess).await);
    Principals { f, api, yank, sess }
}

#[tokio::test]
async fn publish_token_needs_the_package_in_the_token_and_the_publish_scope() {
    let p = principals().await;
    let a = &p.f.auth;
    a.publish_token(&p.api, "alpha", "1.0.0").unwrap();
    let e = a.publish_token(&p.api, "beta", "1.0.0").unwrap_err();
    assert_eq!((e.code, e.status()), (ErrorCode::ScopeMissing, 403));
    assert_eq!(e.message, "The token does not have the 'publish' scope for 'beta'.");
    assert_eq!(e.detail, [("name".to_string(), "beta".to_string()), ("scope".to_string(), "publish".to_string())].into_iter().collect());
    assert_eq!(a.publish_token(&p.yank, "alpha", "1.0.0").unwrap_err().code, ErrorCode::ScopeMissing);
    assert_eq!(a.publish_token(&p.sess, "alpha", "1.0.0").unwrap_err().code, ErrorCode::ScopeMissing, "a session proves a person, not a publish grant");
}

fn ci(version: &str, packages: &[&str], scopes: &[TokenScope]) -> Principal {
    Principal { token_id: "tok_ci".into(), kind: TokenKind::Oidc, github_id: None, scopes: scopes.to_vec(), packages: packages.iter().map(|s| s.to_string()).collect(), version: Some(version.into()), fresh_until: None }
}

#[tokio::test]
async fn a_ci_token_publishes_exactly_its_package_and_version() {
    let p = principals().await;
    let a = &p.f.auth;
    let t = ci("1.0.0", &["alpha"], &[TokenScope::Publish]);
    a.publish_token(&t, "alpha", "1.0.0").unwrap();
    for (name, version) in [("alpha", "1.0.1"), ("alpha", "1.1.0"), ("alpha", "2.0.0"), ("beta", "1.0.0"), ("alpha", "not a version"), ("alpha", "1.0"), ("alpha", "")] {
        assert_eq!(a.publish_token(&t, name, version).unwrap_err().code, ErrorCode::ScopeMissing, "{name} {version}");
    }
    assert!(a.publish_token(&ci("1.0.0", &["alpha", "beta"], &[TokenScope::Publish]), "alpha", "1.0.0").is_err(), "one package only");
    assert!(a.publish_token(&ci("1.0.0", &["alpha"], &[]), "alpha", "1.0.0").is_err());
    assert!(a.publish_token(&ci("1.0.0", &["alpha"], &[TokenScope::Yank]), "alpha", "1.0.0").is_err());
    let mut no_version = ci("1.0.0", &["alpha"], &[TokenScope::Publish]);
    no_version.version = None;
    assert!(a.publish_token(&no_version, "alpha", "1.0.0").is_err());
    assert!(a.publish_token(&ci("garbage", &["alpha"], &[TokenScope::Publish]), "alpha", "garbage").is_err(), "an unparsable version is no match, even with itself");
}

#[tokio::test]
async fn yank_token_is_yank_or_publish_for_the_package_and_nothing_else() {
    let p = principals().await;
    let a = &p.f.auth;
    a.yank_token(&p.yank, "alpha").unwrap();
    a.yank_token(&p.api, "alpha").unwrap();
    assert_eq!(a.yank_token(&p.yank, "beta").unwrap_err().detail["scope"], "yank");
    assert_eq!(a.yank_token(&p.sess, "alpha").unwrap_err().code, ErrorCode::ScopeMissing);
    assert!(a.yank_token(&ci("1.0.0", &["alpha"], &[TokenScope::Publish]), "alpha").is_err(), "a CI token cannot yank");
}

#[tokio::test]
async fn fresh_session_passes_a_young_session_and_refuses_an_old_one_and_every_api_token() {
    let p = principals().await;
    let a = &p.f.auth;
    assert_eq!(a.fresh_session(&p.sess).unwrap(), ALICE);
    let e = a.fresh_session(&p.api).unwrap_err();
    assert_eq!((e.code, e.status(), e.message.as_str()), (ErrorCode::StaleSession, 401, "This action needs a login from the last 15 minutes."));
    let old = p.f.principal(&p.f.session(ALICE, 15 * 60_000).await).await;
    p.f.r.clock.advance_millis(15 * 60_000 - 1);
    assert_eq!(a.fresh_session(&old).unwrap(), ALICE);
    p.f.r.clock.advance_millis(1);
    assert_eq!(a.fresh_session(&old).unwrap_err().code, ErrorCode::StaleSession);
    assert_eq!(a.user_token(&old).unwrap(), ALICE, "an old session still passes userToken");
}

#[tokio::test]
async fn only_a_session_token_is_ever_fresh_even_when_the_row_of_another_kind_says_so() {
    let f = setup().await;
    let t = f.api(ALICE, "a", &["publish"], &["alpha"]).await;
    let mut row = f.r.auth.dump_tokens().remove(0);
    row.fresh_until = Some(iso_at(start_ms() + 600_000));
    let clock: Arc<dyn Clock> = f.r.clock.clone();
    let a = Authenticator::new(Arc::new(Lying(row)), clock);
    let p = a.authenticate(Some(&bearer(&t.token))).await.unwrap();
    assert!(p.fresh_until.is_some());
    assert_eq!(a.fresh_session(&p).unwrap_err().code, ErrorCode::StaleSession);
}

#[tokio::test]
async fn user_token_is_any_users_token_and_never_a_ci_identity() {
    let p = principals().await;
    let a = &p.f.auth;
    assert_eq!(a.user_token(&p.api).unwrap(), ALICE);
    assert_eq!(a.user_token(&p.sess).unwrap(), ALICE);
    let e = a.user_token(&ci("1.0.0", &["alpha"], &[TokenScope::Publish])).unwrap_err();
    assert_eq!((e.code, e.message.as_str()), (ErrorCode::ScopeMissing, "The token does not have the 'user' scope for 'this account'."));
    let mut oidc_with_an_id = ci("1.0.0", &["alpha"], &[TokenScope::Publish]);
    oidc_with_an_id.github_id = Some(ALICE);
    assert!(a.user_token(&oidc_with_an_id).is_err(), "an oidc kind is nobody's even if a row carried an id");
}

#[tokio::test]
async fn token_management_needs_the_fresh_session_the_full_create_then_use_flow() {
    let p = principals().await;
    let id = p.f.auth.fresh_session(&p.sess).unwrap();
    let t = p.f.tokens.create(id, input("n", &["publish"], &["beta"], 2.0)).await.unwrap();
    assert_eq!(t.meta.packages, PackageSet::Names(vec!["beta".into()]));
    assert!(p.f.auth.fresh_session(&p.api).is_err(), "an API token cannot mint tokens");
    let used = p.f.principal(&t.token).await;
    p.f.auth.publish_token(&used, "beta", "2.0.0").unwrap();
}
