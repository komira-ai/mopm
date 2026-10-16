//! The tests of `service/api/test/auth-oidc.test.ts`, with real RSA signatures (two fixed test keys) and the
//! `jsonwebtoken` verification the verifier uses. What they prove: the exchange mints a one-package one-version
//! publish token only for a token that is genuine, current, for this registry, and from a registered
//! publisher; every refusal has its code, status and message; and the algorithm cannot be chosen by the token
//! (`none`, HMAC keyed with the public key, other RSA widths, and other kinds of key are all refused).

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use jsonwebtoken::{Algorithm, EncodingKey};
use mopm_core::error::ErrorCode;
use mopm_ports::auth::AuthStore;
use mopm_ports::env::Clock;
use mopm_ports::types::{TokenKind, TrustedPublisher};
use mopm_testing::fake_http::{FakeHttp, Reply};
use mopm_testing::memory_auth::MemoryAuthStore;
use serde_json::{json, Map, Value};

use crate::http::HttpClient;
use crate::oidc::*;
use crate::test_keys::*;
use crate::test_support::{refusal, rig, Rig};
use crate::tokens::{iso_at, Authenticator};

const ISSUER: &str = GITHUB_OIDC_ISSUER;

// ---- keys and tokens --------------------------------------------------------------------------------

struct TestKey {
    kid: &'static str,
    enc: EncodingKey,
    jwk: Jwk,
}

fn key(kid: &'static str, der_b64: &str, n: &str) -> TestKey {
    let der = STANDARD.decode(der_b64).unwrap();
    TestKey { kid, enc: EncodingKey::from_rsa_der(&der), jwk: Jwk { kty: "RSA".into(), kid: Some(kid.into()), n: Some(n.into()), e: Some(E.into()), use_: Some("sig".into()), alg: Some("RS256".into()) } }
}

/// The issuer's key.
fn key_a(kid: &'static str) -> TestKey {
    key(kid, A_PRIVATE_DER_B64, A_N)
}

/// Another key: a forger that copies the kid, or a key rotated in.
fn key_b(kid: &'static str) -> TestKey {
    key(kid, B_PRIVATE_DER_B64, B_N)
}

fn b64u(v: &Value) -> String {
    URL_SAFE_NO_PAD.encode(v.to_string())
}

fn sign_with(k: &TestKey, claims: &Value, header: Value) -> String {
    let mut h = json!({"alg": "RS256", "typ": "JWT", "kid": k.kid});
    h.as_object_mut().unwrap().extend(header.as_object().unwrap().clone());
    let signing_input = format!("{}.{}", b64u(&h), b64u(claims));
    let sig = jsonwebtoken::crypto::sign(signing_input.as_bytes(), &k.enc, Algorithm::RS256).unwrap();
    format!("{signing_input}.{sig}")
}

fn sign(k: &TestKey, claims: &Value) -> String {
    sign_with(k, claims, json!({}))
}

/// A token assembled by hand, for the algorithm and tamper cases.
fn raw_jwt(header: &Value, claims: &Value, sig: &str) -> String {
    format!("{}.{}.{sig}", b64u(header), b64u(claims))
}

fn good_claims(now_s: i64) -> Map<String, Value> {
    json!({
        "iss": ISSUER, "aud": "mopm.dev", "sub": "repo:acme/widgets:ref:refs/tags/v1.0.0",
        "iat": now_s - 5, "nbf": now_s - 5, "exp": now_s + 300,
        "repository": "acme/widgets", "repository_id": "111", "repository_owner_id": "222",
        "workflow_ref": "acme/widgets/.github/workflows/release.yml@refs/tags/v1.0.0"
    })
    .as_object()
    .unwrap()
    .clone()
}

/// `good_claims` with some members set; a member named `-x` removes `x` (so a `null` stays a `null`).
fn claims_with(now_s: i64, over: Value) -> Value {
    let mut c = good_claims(now_s);
    for (k, v) in over.as_object().unwrap() {
        match k.strip_prefix('-') {
            Some(removed) => c.remove(removed),
            None => c.insert(k.clone(), v.clone()),
        };
    }
    Value::Object(c)
}

/// `claims_with`'s removal of one member.
fn without(member: &str) -> Value {
    let mut m = Map::new();
    m.insert(format!("-{member}"), json!(true));
    Value::Object(m)
}

// ---- the fixture -------------------------------------------------------------------------------------

/// A key set the test controls, counting how often it is fetched.
struct FakeJwks {
    keys: Mutex<Vec<Jwk>>,
    fetches: AtomicUsize,
    down: AtomicBool,
}

impl JwksSource for Arc<FakeJwks> {
    async fn fetch(&self) -> Result<JwkSet, JwksUnavailable> {
        self.fetches.fetch_add(1, Ordering::SeqCst);
        if self.down.load(Ordering::SeqCst) {
            return Err(JwksUnavailable("down".into()));
        }
        Ok(JwkSet { keys: self.keys.lock().unwrap().clone() })
    }
}

struct Fixture {
    r: Rig,
    jwks: Arc<FakeJwks>,
    oidc: OidcExchange<MemoryAuthStore, Arc<FakeJwks>>,
    auth: Authenticator<MemoryAuthStore>,
    tp: TrustedPublisher,
}

async fn setup_with(keys: Vec<Jwk>, audiences: &[&str]) -> Fixture {
    let r = rig().await;
    let jwks = Arc::new(FakeJwks { keys: Mutex::new(keys), fetches: AtomicUsize::new(0), down: AtomicBool::new(false) });
    let clock: Arc<dyn Clock> = r.clock.clone();
    let options = JwtVerifierOptions::github(audiences.iter().map(|s| s.to_string()).collect());
    let verifier = JwtVerifier::new(options, jwks.clone(), clock.clone()).unwrap();
    let oidc = OidcExchange::new(r.auth.clone(), verifier, clock.clone(), r.rng.clone());
    let auth = Authenticator::new(r.auth.clone(), clock);
    let tp = TrustedPublisher {
        id: "tp1".into(),
        name: "widgets".into(),
        repository_id: "111".into(),
        repository_owner_id: "222".into(),
        workflow: ".github/workflows/release.yml".into(),
        environment: None,
        added_by: 1,
        added_at: "2026-10-01T00:00:00Z".into(),
    };
    Fixture { r, jwks, oidc, auth, tp }
}

async fn setup() -> Fixture {
    setup_with(vec![key_a("k1").jwk], &["mopm.dev"]).await
}

impl Fixture {
    fn now_s(&self) -> i64 {
        self.r.clock.now().as_second()
    }

    fn fetches(&self) -> usize {
        self.jwks.fetches.load(Ordering::SeqCst)
    }

    async fn trust(&self, tp: TrustedPublisher) {
        self.r.auth.add_trusted_publisher(&tp).await.unwrap();
    }

    /// A token from the issuer's key `k1`, claims as `good_claims` with `over` applied.
    fn token(&self, over: Value) -> String {
        sign(&key_a("k1"), &claims_with(self.now_s(), over))
    }

    async fn exchange(&self, jwt: &str) -> mopm_ports::error::PortResult<OidcToken> {
        self.oidc.exchange(jwt, "widgets", "1.0.0").await
    }
}

/// Exact: code, status and the detail the message template carries.
fn assert_rejected<T: std::fmt::Debug>(r: mopm_ports::error::PortResult<T>, code: ErrorCode, status: u16, detail: Option<&str>) {
    let e = refusal(r);
    assert_eq!((e.code, e.status()), (code, status), "{e}");
    if let Some(d) = detail {
        assert_eq!(e.detail.get("detail").map(String::as_str), Some(d), "{e}");
    }
}

fn assert_invalid<T: std::fmt::Debug>(r: mopm_ports::error::PortResult<T>, detail: &str) {
    assert_rejected(r, ErrorCode::OidcTokenInvalid, 401, Some(detail));
}

// ---- the happy path ----------------------------------------------------------------------------------

#[tokio::test]
async fn a_matching_token_mints_a_fifteen_minute_publish_token_for_exactly_that_package_and_version() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    let r = f.exchange(&f.token(json!({}))).await.unwrap();
    assert_eq!((r.token_kind, r.name.as_str(), r.version.as_str()), ("publish", "widgets", "1.0.0"));
    assert_eq!(r.expires_at, iso_at(f.r.clock.now().as_millisecond() + 15 * 60_000));
    assert!(crate::tokens::is_token_shaped(&r.token));

    let p = f.auth.authenticate(Some(&format!("Bearer {}", r.token))).await.unwrap();
    assert_eq!((p.kind, p.github_id), (TokenKind::Oidc, None));
    f.auth.publish_token(&p, "widgets", "1.0.0").unwrap();
    // the row says whose workflow earned it, and the secret is stored hashed only
    let rows = f.r.auth.dump_tokens();
    assert_eq!((rows[0].issued_to.as_deref(), rows[0].name.as_str()), (Some("acme/widgets"), "ci acme/widgets"));
    assert!(!serde_json::to_string(&rows).unwrap().contains(&r.token));
    assert_eq!(serde_json::to_value(&r).unwrap()["token_kind"], "publish");
}

#[tokio::test]
async fn the_minted_token_cannot_publish_another_version_another_package_yank_or_manage_tokens() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    f.trust(TrustedPublisher { id: "tp2".into(), name: "other".into(), ..f.tp.clone() }).await;
    let r = f.exchange(&f.token(json!({}))).await.unwrap();
    let p = f.auth.authenticate(Some(&format!("Bearer {}", r.token))).await.unwrap();
    for e in [f.auth.publish_token(&p, "widgets", "1.0.1").unwrap_err(), f.auth.publish_token(&p, "other", "1.0.0").unwrap_err(), f.auth.yank_token(&p, "widgets").unwrap_err()] {
        assert_eq!((e.code, e.status()), (ErrorCode::ScopeMissing, 403));
    }
    assert_eq!(f.auth.fresh_session(&p).unwrap_err().code, ErrorCode::ScopeMissing);
    assert_eq!(f.auth.user_token(&p).unwrap_err().code, ErrorCode::ScopeMissing);
}

#[tokio::test]
async fn the_minted_token_expires_after_fifteen_minutes() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    let r = f.oidc.exchange(&f.token(json!({})), "widgets", "2.0.0").await.unwrap();
    f.r.clock.advance_millis(15 * 60_000 - 1000);
    f.auth.authenticate(Some(&format!("Bearer {}", r.token))).await.unwrap();
    f.r.clock.advance_millis(1000);
    assert_rejected(f.auth.authenticate(Some(&format!("Bearer {}", r.token))).await, ErrorCode::TokenExpired, 401, None);
}

#[tokio::test]
async fn an_optional_environment_unset_on_the_record_accepts_any_set_requires_equality() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    f.exchange(&f.token(json!({"environment": "release"}))).await.unwrap();
    f.exchange(&f.token(json!({}))).await.unwrap();

    let f = setup().await;
    f.trust(TrustedPublisher { environment: Some("release".into()), ..f.tp.clone() }).await;
    f.exchange(&f.token(json!({"environment": "release"}))).await.unwrap();
    assert_rejected(f.exchange(&f.token(json!({"environment": "staging"}))).await, ErrorCode::OidcNotTrusted, 403, None);
    assert_rejected(f.exchange(&f.token(json!({}))).await, ErrorCode::OidcNotTrusted, 403, None);
    assert_rejected(f.exchange(&f.token(json!({"environment": 7}))).await, ErrorCode::OidcNotTrusted, 403, None);
}

#[tokio::test]
async fn any_one_of_several_trusted_publishers_is_enough() {
    let f = setup().await;
    f.trust(TrustedPublisher { id: "a".into(), repository_id: "999".into(), ..f.tp.clone() }).await;
    f.trust(TrustedPublisher { id: "b".into(), ..f.tp.clone() }).await;
    f.exchange(&f.token(json!({}))).await.unwrap();
}

#[tokio::test]
async fn the_audience_may_be_the_stage_host_as_well_as_the_main_one_when_configured_and_may_be_a_list() {
    let f = setup_with(vec![key_a("k1").jwk], &["mopm.dev", "gamma.mopm.dev"]).await;
    f.trust(f.tp.clone()).await;
    f.exchange(&f.token(json!({"aud": "gamma.mopm.dev"}))).await.unwrap();
    f.exchange(&f.token(json!({"aud": ["x", "mopm.dev"]}))).await.unwrap();
    assert_invalid(f.exchange(&f.token(json!({"aud": ["x", 5, null]}))).await, "wrong audience");
}

#[tokio::test]
async fn at_least_one_audience_is_required() {
    let r = rig().await;
    let jwks = Arc::new(FakeJwks { keys: Mutex::new(vec![]), fetches: AtomicUsize::new(0), down: AtomicBool::new(false) });
    let clock: Arc<dyn Clock> = r.clock.clone();
    assert_eq!(JwtVerifier::new(JwtVerifierOptions::github(vec![]), jwks, clock).err(), Some(NoAudience));
}

// ---- every refusal, exactly --------------------------------------------------------------------------

#[tokio::test]
async fn wrong_audience_a_missing_audience_and_a_wrong_issuer() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    assert_invalid(f.exchange(&f.token(json!({"aud": "sts.amazonaws.com"}))).await, "wrong audience");
    assert_invalid(f.exchange(&f.token(json!({"-aud": true}))).await, "wrong audience");
    assert_invalid(f.exchange(&f.token(json!({"aud": 5}))).await, "wrong audience");
    assert_invalid(f.exchange(&f.token(json!({"iss": "https://evil.example.invalid"}))).await, "wrong issuer");
    assert_invalid(f.exchange(&f.token(json!({"-iss": true}))).await, "wrong issuer");
    let e = refusal(f.exchange(&f.token(json!({"iss": "x"}))).await);
    assert_eq!(e.message, "The CI identity token was rejected: wrong issuer.");
}

#[tokio::test]
async fn the_trust_decision_is_on_ids_workflow_and_environment_not_names() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    for over in [
        json!({"repository_id": "112"}),
        json!({"repository_owner_id": "223"}),
        json!({"workflow_ref": "acme/widgets/.github/workflows/other.yml@refs/heads/main"}),
        // a workflow_ref from a different repository than the repository claim
        json!({"workflow_ref": "evil/fork/.github/workflows/release.yml@refs/heads/main"}),
        // the repository NAME matches and the id does not
        json!({"repository": "acme/widgets", "repository_id": "1"}),
    ] {
        let e = refusal(f.exchange(&f.token(over.clone())).await);
        assert_eq!((e.code, e.status()), (ErrorCode::OidcNotTrusted, 403), "{over}");
        assert_eq!(e.message, "No trusted publisher of 'widgets' matches this CI identity.");
        assert_eq!(e.detail["name"], "widgets");
    }
    // any ref of the trusted workflow matches
    f.exchange(&f.token(json!({"workflow_ref": "acme/widgets/.github/workflows/release.yml@refs/heads/main"}))).await.unwrap();
}

#[tokio::test]
async fn a_package_with_no_trusted_publisher_and_trust_per_package() {
    let f = setup().await;
    assert_rejected(f.exchange(&f.token(json!({}))).await, ErrorCode::OidcNotTrusted, 403, None);
    f.trust(f.tp.clone()).await;
    assert_rejected(f.oidc.exchange(&f.token(json!({})), "widgets2", "1.0.0").await, ErrorCode::OidcNotTrusted, 403, None);
}

#[tokio::test]
async fn expiry_is_exact_at_the_leeway_boundary() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    let now = f.now_s();
    // leeway is 60s: exp = now - 59 is still accepted, exp = now - 60 is not
    f.exchange(&f.token(json!({"exp": now - 59}))).await.unwrap();
    assert_invalid(f.exchange(&f.token(json!({"exp": now - 60}))).await, "token expired");
    assert_invalid(f.exchange(&f.token(json!({"exp": now - 3600}))).await, "token expired");
}

#[tokio::test]
async fn a_token_that_expires_while_held_is_expired_when_the_clock_passes_exp() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    let jwt = f.token(json!({"exp": f.now_s() + 10}));
    f.exchange(&jwt).await.unwrap();
    f.r.clock.advance_millis(80_000);
    assert_invalid(f.exchange(&jwt).await, "token expired");
}

#[tokio::test]
async fn not_yet_valid_nbf_and_issued_in_the_future_iat_with_the_same_leeway() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    let now = f.now_s();
    assert_invalid(f.exchange(&f.token(json!({"nbf": now + 3600}))).await, "token not yet valid");
    f.exchange(&f.token(json!({"nbf": now + 60}))).await.unwrap();
    assert_invalid(f.exchange(&f.token(json!({"nbf": now + 61}))).await, "token not yet valid");
    assert_invalid(f.exchange(&f.token(json!({"nbf": "soon"}))).await, "token not yet valid");
    assert_invalid(f.exchange(&f.token(json!({"nbf": Value::Null}))).await, "token not yet valid");
    assert_invalid(f.exchange(&f.token(json!({"iat": now + 3600, "-nbf": true}))).await, "token issued in the future");
    f.exchange(&f.token(json!({"iat": now + 60, "-nbf": true}))).await.unwrap();
    assert_invalid(f.exchange(&f.token(json!({"iat": now + 61, "-nbf": true}))).await, "token issued in the future");
}

#[tokio::test]
async fn missing_exp_missing_iat_and_missing_identity_claims_are_refused() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    assert_invalid(f.exchange(&f.token(json!({"-exp": true}))).await, "missing expiry");
    assert_invalid(f.exchange(&f.token(json!({"exp": "tomorrow"}))).await, "missing expiry");
    assert_invalid(f.exchange(&f.token(json!({"-iat": true}))).await, "missing issued-at");
    for c in ["repository", "repository_id", "repository_owner_id", "workflow_ref"] {
        assert_invalid(f.exchange(&f.token(without(c))).await, &format!("missing claim {c}"));
        assert_invalid(f.exchange(&f.token(json!({ c: "" }))).await, &format!("missing claim {c}"));
        assert_invalid(f.exchange(&f.token(json!({ c: 111 }))).await, &format!("missing claim {c}"));
    }
}

#[tokio::test]
async fn the_claim_checks_run_in_the_order_issuer_audience_expiry_not_before_issued_at_identity() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    let now = f.now_s();
    // A token wrong in every way at once; each step repairs the fault that was reported and the next shows.
    let mut c = json!({"iss": "x", "aud": "x", "exp": now - 3600, "nbf": now + 3600, "iat": now + 3600, "-repository": true}).as_object().unwrap().clone();
    let steps = [
        ("wrong issuer", json!({"iss": ISSUER})),
        ("wrong audience", json!({"aud": "mopm.dev"})),
        ("token expired", json!({"exp": now + 300})),
        ("token not yet valid", json!({"nbf": now - 1})),
        ("token issued in the future", json!({"iat": now})),
        ("missing claim repository", json!({"repository": "acme/widgets"})),
    ];
    for (reported, repair) in steps {
        assert_invalid(f.exchange(&f.token(Value::Object(c.clone()))).await, reported);
        c.extend(repair.as_object().unwrap().clone());
        if reported == "missing claim repository" {
            c.remove("-repository");
        }
    }
    f.exchange(&f.token(Value::Object(c))).await.unwrap();
}

#[tokio::test]
async fn bad_signature_a_payload_altered_after_signing_and_a_forger_that_copies_the_kid() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    let signed = sign(&key_a("k1"), &claims_with(f.now_s(), json!({"repository_id": "999"})));
    let parts: Vec<&str> = signed.split('.').collect();
    let forged_payload = b64u(&Value::Object(good_claims(f.now_s())));
    assert_invalid(f.exchange(&format!("{}.{forged_payload}.{}", parts[0], parts[2])).await, "bad signature");
    // signed by a different key that claims the trusted kid
    assert_invalid(f.exchange(&sign(&key_b("k1"), &Value::Object(good_claims(f.now_s())))).await, "bad signature");
    // a flipped bit of the signature, and a signature of the wrong length
    let mut sig = URL_SAFE_NO_PAD.decode(parts[2]).unwrap();
    sig[10] ^= 1;
    assert_invalid(f.exchange(&format!("{}.{}.{}", parts[0], parts[1], URL_SAFE_NO_PAD.encode(&sig))).await, "bad signature");
    assert_invalid(f.exchange(&format!("{}.{}.{}", parts[0], parts[1], URL_SAFE_NO_PAD.encode(&sig[..100]))).await, "bad signature");
    assert_invalid(f.exchange(&format!("{}.{}.", parts[0], parts[1])).await, "bad signature");
}

#[tokio::test]
async fn a_signature_that_cannot_be_decoded_and_a_key_that_cannot_verify_are_a_bad_signature_not_a_pass() {
    let mut weak = key_a("weak");
    weak.jwk.n = Some("AQAB".into()); // a modulus of 65537: a key no real signature verifies under
    let f = setup_with(vec![key_a("k1").jwk, weak.jwk.clone()], &["mopm.dev"]).await;
    f.trust(f.tp.clone()).await;
    let good = f.token(json!({}));
    let parts: Vec<&str> = good.split('.').collect();
    // One base64 character cannot be a whole number of bytes; nor can five.
    for sig in ["A", "AAAAA", "-_-_-"] {
        assert_invalid(f.exchange(&format!("{}.{}.{sig}", parts[0], parts[1])).await, "bad signature");
    }
    assert_invalid(f.exchange(&sign(&weak, &claims_with(f.now_s(), json!({})))).await, "bad signature");
}

#[tokio::test]
async fn an_unknown_kid_is_refused_as_an_unknown_signing_key() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    assert_invalid(f.exchange(&sign(&key_b("rotated-away"), &Value::Object(good_claims(f.now_s())))).await, "unknown signing key");
}

// ---- the algorithm is ours ---------------------------------------------------------------------------

#[tokio::test]
async fn algorithm_none_is_refused_before_any_key_is_used() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    let claims = Value::Object(good_claims(f.now_s()));
    for alg in ["none", "None", "NONE", "nOnE"] {
        assert_invalid(f.exchange(&raw_jwt(&json!({"alg": alg, "kid": "k1"}), &claims, "")).await, "unsupported algorithm");
    }
    // the same, with a signature part some libraries would read as "no signature needed"
    assert_invalid(f.exchange(&raw_jwt(&json!({"alg": "none", "kid": "k1"}), &claims, "AAAA")).await, "unsupported algorithm");
    // and no algorithm at all, or one that is not a string
    assert_invalid(f.exchange(&raw_jwt(&json!({"kid": "k1"}), &claims, "AAAA")).await, "unsupported algorithm");
    assert_invalid(f.exchange(&raw_jwt(&json!({"alg": null, "kid": "k1"}), &claims, "AAAA")).await, "unsupported algorithm");
    assert_invalid(f.exchange(&raw_jwt(&json!({"alg": ["RS256"], "kid": "k1"}), &claims, "AAAA")).await, "unsupported algorithm");
    assert_eq!(f.fetches(), 0, "no key set was even fetched");
    assert!(f.r.auth.dump_tokens().is_empty());
}

#[tokio::test]
async fn hmac_keyed_with_the_public_key_is_refused_the_key_confusion_attack() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    let claims = Value::Object(good_claims(f.now_s()));
    // The attacker signs with HS256, using the issuer's public key material as the HMAC secret: every form of it.
    let der_public = STANDARD.decode(A_PRIVATE_DER_B64).unwrap();
    for secret in [A_N.as_bytes().to_vec(), URL_SAFE_NO_PAD.decode(A_N).unwrap(), der_public] {
        for alg in ["HS256", "HS384", "HS512", "hs256"] {
            let a = match alg.to_ascii_uppercase().as_str() {
                "HS384" => Algorithm::HS384,
                "HS512" => Algorithm::HS512,
                _ => Algorithm::HS256,
            };
            let signing_input = format!("{}.{}", b64u(&json!({"alg": alg, "typ": "JWT", "kid": "k1"})), b64u(&claims));
            let sig = jsonwebtoken::crypto::sign(signing_input.as_bytes(), &EncodingKey::from_secret(&secret), a).unwrap();
            assert_invalid(f.exchange(&format!("{signing_input}.{sig}")).await, "unsupported algorithm");
        }
    }
    assert_eq!(f.fetches(), 0, "refused before any key was looked up");
    // The header says RS256 and the signature is an HMAC: the fixed algorithm is applied to it, and it fails.
    let signing_input = format!("{}.{}", b64u(&json!({"alg": "RS256", "typ": "JWT", "kid": "k1"})), b64u(&claims));
    let hmac = jsonwebtoken::crypto::sign(signing_input.as_bytes(), &EncodingKey::from_secret(A_N.as_bytes()), Algorithm::HS256).unwrap();
    assert_invalid(f.exchange(&format!("{signing_input}.{hmac}")).await, "bad signature");
}

#[tokio::test]
async fn other_algorithms_are_unsupported_even_when_the_signature_is_a_good_one() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    let claims = claims_with(f.now_s(), json!({}));
    for alg in ["RS384", "RS512", "PS256", "PS384", "ES256", "ES384", "EdDSA", "rs256", "Rs256", "RS256 ", ""] {
        let jwt = sign_with(&key_a("k1"), &claims, json!({"alg": alg}));
        // sign_with signs the bytes with RS256 whatever the header says: the signature is right, the header is the lie
        assert_invalid(f.exchange(&jwt).await, "unsupported algorithm");
    }
    assert_eq!(f.fetches(), 0);
}

#[tokio::test]
async fn keys_carried_by_the_token_are_never_used() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    let claims = claims_with(f.now_s(), json!({}));
    let forger = key_b("k1");
    let embedded = json!({"jwk": serde_json::to_value(&forger.jwk).unwrap(), "jku": "https://evil.example.invalid/jwks", "x5u": "https://evil.example.invalid/c.pem", "x5c": ["AAAA"]});
    // signed by the forger with its own key in the header, under the trusted kid
    assert_invalid(f.exchange(&sign_with(&forger, &claims, embedded.clone())).await, "bad signature");
    // and under a kid the issuer does not publish: unknown, not "the embedded one"
    let unknown = TestKey { kid: "attacker", enc: forger.enc.clone(), jwk: forger.jwk.clone() };
    assert_invalid(f.exchange(&sign_with(&unknown, &claims, embedded)).await, "unknown signing key");
}

#[tokio::test]
async fn keys_that_are_not_rsa_signing_keys_are_ignored() {
    let ec = Jwk { kty: "EC".into(), kid: Some("k1".into()), ..Jwk::default() };
    let enc = Jwk { kid: Some("enc".into()), use_: Some("enc".into()), ..key_a("enc").jwk };
    let nokid = Jwk { kid: None, ..key_a("x").jwk };
    // not RSA by its kty, though it carries the RSA components of a key that does sign
    let mislabelled = Jwk { kty: "EC".into(), ..key_a("ec").jwk };
    let f = setup_with(vec![ec, enc, nokid, mislabelled, key_a("k1").jwk], &["mopm.dev"]).await;
    f.trust(f.tp.clone()).await;
    f.exchange(&f.token(json!({}))).await.unwrap();
    // a token naming the encryption-only key's kid finds nothing
    assert_invalid(f.exchange(&sign(&key_a("enc"), &Value::Object(good_claims(f.now_s())))).await, "unknown signing key");
    assert_invalid(f.exchange(&sign(&key_a("ec"), &Value::Object(good_claims(f.now_s())))).await, "unknown signing key");
    // a key with garbage components is skipped, not fatal
    let broken = Jwk { n: Some("!!!".into()), kid: Some("broken".into()), ..key_a("x").jwk };
    let f = setup_with(vec![broken, key_a("k1").jwk], &["mopm.dev"]).await;
    f.trust(f.tp.clone()).await;
    f.exchange(&f.token(json!({}))).await.unwrap();
}

// ---- malformed input ---------------------------------------------------------------------------------

#[tokio::test]
async fn malformed_input_is_refused_as_malformed() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    let b = |s: &str| URL_SAFE_NO_PAD.encode(s);
    for jwt in [
        String::new(),
        "a.b".to_string(),
        "a.b.c.d".to_string(),
        "!!!.@@@.###".to_string(),
        format!("{}.{}.AAAA", b("nope"), b("{}")),
        format!("{}.{}.AAAA", b("null"), b("{}")),
        format!("{}.{}.AAAA", b("{}"), b("null")),
        format!("{}.{}.AAAA", b("5"), b("{}")),
        format!("{}.{}.AAAA", b("\"s\""), b("{}")),
        format!("{}.{}.AAAA", b("{}"), b("[1")),
        "x".repeat(9000),
        format!("{}.{}.{}", "a".repeat(3000), "b".repeat(3000), "c".repeat(3000)),
    ] {
        assert_invalid(f.exchange(&jwt).await, "malformed token");
    }
    let claims = Value::Object(good_claims(f.now_s()));
    assert_invalid(f.exchange(&raw_jwt(&json!({"alg": "RS256"}), &claims, "AAAA")).await, "missing key id");
    assert_invalid(f.exchange(&raw_jwt(&json!({"alg": "RS256", "kid": ""}), &claims, "AAAA")).await, "missing key id");
    assert_invalid(f.exchange(&raw_jwt(&json!({"alg": "RS256", "kid": 5}), &claims, "AAAA")).await, "missing key id");
    // a signature part that is not base64url is malformed, but only once the key is found (as the TypeScript does)
    assert_invalid(f.exchange(&raw_jwt(&json!({"alg": "RS256", "kid": "k1"}), &claims, "@@@")).await, "malformed token");
    assert_invalid(f.exchange(&raw_jwt(&json!({"alg": "RS256", "kid": "nope"}), &claims, "@@@")).await, "unknown signing key");
    // arrays are objects without members
    assert_invalid(f.exchange(&format!("{}.{}.AAAA", b("[]"), b("{}"))).await, "unsupported algorithm");
}

#[tokio::test]
async fn a_bad_package_name_or_version_is_refused_before_the_token_is_looked_at() {
    let f = setup().await;
    let e = refusal(f.oidc.exchange("junk", "Not Valid", "1.0.0").await);
    assert_eq!((e.code, e.status(), e.message.as_str()), (ErrorCode::InvalidName, 400, "'Not Valid' is not a valid package name."));
    let e = refusal(f.oidc.exchange("junk", "widgets", "one").await);
    assert_eq!((e.code, e.status(), e.message.as_str()), (ErrorCode::InvalidVersion, 400, "'one' is not a valid version."));
    assert_eq!(f.fetches(), 0);
}

#[tokio::test]
async fn a_refused_exchange_mints_nothing() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    for over in [json!({"aud": "nope"}), json!({"repository_id": "1"}), json!({"exp": 1})] {
        assert!(f.exchange(&f.token(over)).await.is_err());
    }
    assert!(f.r.auth.dump_tokens().is_empty());
}

// ---- the key set -------------------------------------------------------------------------------------

#[tokio::test]
async fn keys_are_fetched_once_and_cached_across_exchanges() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    for _ in 0..3 {
        f.exchange(&f.token(json!({}))).await.unwrap();
    }
    assert_eq!(f.fetches(), 1);
}

#[tokio::test]
async fn the_cache_expires_after_its_ttl() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    f.exchange(&f.token(json!({}))).await.unwrap();
    f.r.clock.advance_millis(10 * 60_000 - 1);
    f.exchange(&f.token(json!({}))).await.unwrap();
    assert_eq!(f.fetches(), 1);
    f.r.clock.advance_millis(1);
    f.exchange(&f.token(json!({}))).await.unwrap();
    assert_eq!(f.fetches(), 2);
}

#[tokio::test]
async fn a_rotated_key_is_picked_up_by_one_refetch_and_unknown_kids_cannot_force_a_fetch_per_request() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    f.exchange(&f.token(json!({}))).await.unwrap();
    let rotated = key_b("k2");
    *f.jwks.keys.lock().unwrap() = vec![key_a("k1").jwk, rotated.jwk.clone()];
    let claims = |f: &Fixture| Value::Object(good_claims(f.now_s()));
    // within the refetch floor an unknown kid is refused without a fetch
    assert_invalid(f.exchange(&sign(&rotated, &claims(&f))).await, "unknown signing key");
    assert_eq!(f.fetches(), 1);
    // after the floor, one refetch finds it
    f.r.clock.advance_millis(61_000);
    f.exchange(&sign(&rotated, &claims(&f))).await.unwrap();
    assert_eq!(f.fetches(), 2);
    for _ in 0..5 {
        assert_invalid(f.exchange(&sign(&key_b("zzz"), &claims(&f))).await, "unknown signing key");
    }
    assert_eq!(f.fetches(), 2, "five forged kids right after a fetch cost no fetches");
}

#[tokio::test]
async fn a_key_set_that_cannot_be_fetched_is_unavailable_503_not_a_verdict_on_the_token() {
    let f = setup().await;
    f.trust(f.tp.clone()).await;
    f.jwks.down.store(true, Ordering::SeqCst);
    assert_rejected(f.exchange(&f.token(json!({}))).await, ErrorCode::Unavailable, 503, None);
    assert!(f.r.auth.dump_tokens().is_empty());
    f.jwks.down.store(false, Ordering::SeqCst);
    f.exchange(&f.token(json!({}))).await.unwrap();
}

#[tokio::test]
async fn the_key_set_over_http_is_read_from_the_issuers_url() {
    let body = serde_json::to_string(&JwkSet { keys: vec![key_a("k1").jwk] }).unwrap();
    let server = FakeHttp::start(vec![Reply::new(200).header("content-type", "application/json").body(body)]);
    let r = rig().await;
    let clock: Arc<dyn Clock> = r.clock.clone();
    let source = HttpJwks::new(HttpClient::with_plain_http(), format!("{}/.well-known/jwks", server.endpoint()));
    let verifier = JwtVerifier::new(JwtVerifierOptions::github(vec!["mopm.dev".into()]), source, clock.clone()).unwrap();
    let claims = verifier.verify(&sign(&key_a("k1"), &Value::Object(good_claims(r.clock.now().as_second())))).await.unwrap();
    assert_eq!(claims, GithubActionsClaims { repository: "acme/widgets".into(), repository_id: "111".into(), repository_owner_id: "222".into(), workflow_ref: "acme/widgets/.github/workflows/release.yml@refs/tags/v1.0.0".into(), environment: None });
    let seen = &server.requests()[0];
    assert_eq!((seen.method.as_str(), seen.path(), seen.header("accept")), ("GET", "/.well-known/jwks", Some("application/json")));
    assert_eq!(HttpJwks::github(HttpClient::with_plain_http()).url(), GITHUB_JWKS_URL);
}

#[tokio::test]
async fn a_key_set_that_answers_badly_over_http_is_unavailable() {
    for reply in [Reply::new(503), Reply::new(200).body("<html>"), Reply::new(404).body("{\"keys\": []}")] {
        let server = FakeHttp::start(vec![reply]);
        let source = HttpJwks::new(HttpClient::with_plain_http(), format!("{}/jwks", server.endpoint()));
        assert!(source.fetch().await.is_err());
    }
    for body in ["{}", "{\"keys\": []}", "[]"] {
        let server = FakeHttp::start(vec![Reply::new(200).body(body)]);
        let source = HttpJwks::new(HttpClient::with_plain_http(), format!("{}/jwks", server.endpoint()));
        assert_eq!(source.fetch().await.unwrap(), JwkSet { keys: vec![] }, "{body}: an answer with no keys is a set with no keys");
    }
}

// ---- matching ----------------------------------------------------------------------------------------

fn claims_of(over: impl FnOnce(&mut GithubActionsClaims)) -> GithubActionsClaims {
    let mut c = GithubActionsClaims {
        repository: "acme/widgets".into(),
        repository_id: "111".into(),
        repository_owner_id: "222".into(),
        workflow_ref: "acme/widgets/.github/workflows/release.yml@refs/tags/v1".into(),
        environment: None,
    };
    over(&mut c);
    c
}

#[tokio::test]
async fn workflow_path_takes_the_path_out_of_workflow_ref_only_for_the_claimed_repository() {
    assert_eq!(workflow_path("acme/widgets/.github/workflows/release.yml@refs/tags/v1", "acme/widgets"), Some(".github/workflows/release.yml"));
    assert_eq!(workflow_path("acme/widgets/.github/workflows/release.yml", "acme/widgets"), Some(".github/workflows/release.yml"));
    assert_eq!(workflow_path("acme/widgets-evil/.github/workflows/release.yml@x", "acme/widgets"), None);
    assert_eq!(workflow_path("acme/widgets", "acme/widgets"), None);
    assert_eq!(workflow_path("a/b/c@x@y", "a/b"), Some("c@x"), "the last @ ends the path");
}

#[tokio::test]
async fn a_prefix_of_the_workflow_path_or_a_longer_path_does_not_match() {
    let f = setup().await;
    let tp = f.tp;
    assert!(matches_trusted_publisher(&tp, &claims_of(|_| {})));
    for wf in [".github/workflows/rel", ".github/workflows/release.yml.bak", "github/workflows/release.yml", ".github/workflows/RELEASE.yml"] {
        assert!(!matches_trusted_publisher(&TrustedPublisher { workflow: wf.into(), ..tp.clone() }, &claims_of(|_| {})), "{wf}");
    }
}
