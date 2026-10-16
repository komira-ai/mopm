//! The tests of `service/api/test/auth-device.test.ts`. GitHub is a scripted server on loopback and the real
//! HTTP client talks to it, so what is held is the login logic, the HTTP adapter and the wire between them.
//! What they prove: each answer of `start` and `poll`, what is stored (and what never is), and the
//! two-factor rule.

use std::sync::Arc;

use mopm_core::error::ErrorCode;
use mopm_ports::auth::AuthStore;
use mopm_ports::env::Clock;
use mopm_ports::types::TokenKind;
use mopm_testing::fake_http::{FakeHttp, Reply};
use mopm_testing::memory_auth::MemoryAuthStore;
use serde_json::{json, Value};

use crate::device_login::*;
use crate::github::{GitHubHosts, HttpGitHub};
use crate::http::HttpClient;
use crate::test_support::{code_of, refusal, rig, start_ms, Rig};
use crate::tokens::{hash_token, iso_at, is_token_shaped, Authenticator};

struct Fixture {
    r: Rig,
    server: FakeHttp,
    login: DeviceLogin<MemoryAuthStore, HttpGitHub>,
    auth: Authenticator<MemoryAuthStore>,
}

fn json_reply(v: Value) -> Reply {
    Reply::new(200).header("content-type", "application/json").body(v.to_string())
}

/// The answer of `POST /login/device/code`.
fn started() -> Reply {
    json_reply(json!({"device_code": "gh-device-code-0123456789", "user_code": "WDJB-MJHT", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5}))
}

fn granted() -> Reply {
    json_reply(json!({"access_token": "gho_faketoken", "token_type": "bearer", "scope": "read:user"}))
}

fn user(id: u64, login: &str, two_factor: Option<bool>) -> Reply {
    let mut v = json!({"id": id, "login": login});
    if let Some(t) = two_factor {
        v["two_factor_authentication"] = json!(t);
    }
    json_reply(v)
}

fn octo() -> Reply {
    user(4242, "octo", Some(true))
}

fn error(name: &str) -> Reply {
    json_reply(json!({"error": name}))
}

async fn setup(replies: Vec<Reply>, config: DeviceLoginConfig) -> Fixture {
    let r = rig().await;
    let server = FakeHttp::start(replies);
    let hosts = GitHubHosts { oauth: server.endpoint(), api: server.endpoint() };
    let github = HttpGitHub::new("Iv1.testclientid", HttpClient::with_plain_http(), hosts).unwrap();
    let clock: Arc<dyn Clock> = r.clock.clone();
    let login = DeviceLogin::new(r.auth.clone(), github, config, clock.clone(), r.rng.clone());
    let auth = Authenticator::new(r.auth.clone(), clock);
    Fixture { r, server, login, auth }
}

impl Fixture {
    /// The requests that reached GitHub's token endpoint.
    fn polls(&self) -> usize {
        self.server.requests().iter().filter(|s| s.path() == "/login/oauth/access_token").count()
    }
}

fn no_2fa() -> DeviceLoginConfig {
    DeviceLoginConfig { require_2fa: false, ..DeviceLoginConfig::default() }
}

// ---- start ----------------------------------------------------------------------------------------

#[tokio::test]
async fn start_returns_our_own_device_code_with_githubs_user_code_and_url_and_githubs_device_code_is_not_handed_out() {
    let f = setup(vec![started()], DeviceLoginConfig::default()).await;
    let s = f.login.start("mopm 0.1.0").await.unwrap();
    assert_eq!((s.user_code.as_str(), s.verification_uri.as_str()), ("WDJB-MJHT", "https://github.com/login/device"));
    assert!(s.device_code.len() >= 16);
    assert_eq!(s.device_code.len(), 4 + 48, "dev_ and 96 bits twice, in hex");
    assert!(s.device_code.starts_with("dev_") && !s.device_code.contains("gh-device-code"));
    assert_eq!((s.expires_in, s.interval), (600, 5), "ten minutes, although GitHub allows fifteen");
    // stored under the hash only
    let row = f.r.auth.get_device_login(&hash_token(&s.device_code)).await.unwrap().unwrap();
    assert_eq!(row.github_device_code, "gh-device-code-0123456789");
    assert_eq!((row.client.as_str(), row.created_at.as_str(), row.expires_at.as_str()), ("mopm 0.1.0", iso_at(start_ms()).as_str(), iso_at(start_ms() + 600_000).as_str()));
    assert!(f.r.auth.get_device_login(&s.device_code).await.unwrap().is_none());
    assert!(!serde_json::to_string(&row).unwrap().contains(&s.device_code));
    // the request to GitHub carried the client id and the scope, and nothing secret
    let seen = &f.server.requests()[0];
    assert_eq!(seen.path(), "/login/device/code");
    assert_eq!(String::from_utf8_lossy(&seen.body), "client_id=Iv1.testclientid&scope=read%3Auser");
}

#[tokio::test]
async fn start_takes_the_larger_of_githubs_interval_and_five_and_the_smaller_of_its_expiry_and_ten_minutes() {
    let slow = json_reply(json!({"device_code": "d", "user_code": "u", "verification_uri": "v", "expires_in": 300, "interval": 12}));
    let f = setup(vec![slow], DeviceLoginConfig::default()).await;
    let s = f.login.start("mopm").await.unwrap();
    assert_eq!((s.expires_in, s.interval), (300, 12));
    let quick = json_reply(json!({"device_code": "d", "user_code": "u", "verification_uri": "v", "expires_in": 300, "interval": 1}));
    let f = setup(vec![quick], DeviceLoginConfig::default()).await;
    assert_eq!(f.login.start("mopm").await.unwrap().interval, 5);
}

#[tokio::test]
async fn a_missing_or_oversize_client_is_invalid_request_and_github_is_not_asked() {
    let f = setup(vec![started()], DeviceLoginConfig::default()).await;
    for client in ["".to_string(), "x".repeat(81), "\u{1f600}".repeat(41)] {
        assert_eq!(code_of(f.login.start(&client).await), ErrorCode::InvalidRequest);
    }
    f.login.start(&"x".repeat(80)).await.unwrap();
    f.login.start(&"\u{1f600}".repeat(40)).await.unwrap();
    assert_eq!(f.server.requests().len(), 2, "only the two good ones reached GitHub");
}

#[tokio::test]
async fn github_failing_is_unavailable_503() {
    let f = setup(vec![Reply::new(502)], DeviceLoginConfig::default()).await;
    let e = refusal(f.login.start("mopm").await);
    assert_eq!((e.code, e.status(), e.message.as_str()), (ErrorCode::Unavailable, 503, "The registry is temporarily unavailable."));
    assert!(f.r.auth.get_device_login(&hash_token("anything")).await.unwrap().is_none());
}

// ---- poll -----------------------------------------------------------------------------------------

#[tokio::test]
async fn pending_while_the_person_has_not_decided_and_github_is_not_asked_again_before_the_interval() {
    let f = setup(vec![started(), error("authorization_pending")], DeviceLoginConfig::default()).await;
    let s = f.login.start("mopm").await.unwrap();
    assert_eq!(f.login.poll(&s.device_code).await.unwrap(), DevicePoll::Pending { interval: 5 });
    assert_eq!(f.polls(), 1);
    f.r.clock.advance_millis(1000);
    // too fast: answered locally, the interval grows
    assert_eq!(f.login.poll(&s.device_code).await.unwrap(), DevicePoll::Pending { interval: 10 });
    assert_eq!(f.polls(), 1);
    f.r.clock.advance_millis(10_000);
    f.login.poll(&s.device_code).await.unwrap();
    assert_eq!(f.polls(), 2);
}

#[tokio::test]
async fn the_interval_is_exclusive_polling_exactly_one_interval_later_asks_github() {
    let f = setup(vec![started(), error("authorization_pending")], DeviceLoginConfig::default()).await;
    let s = f.login.start("mopm").await.unwrap();
    f.login.poll(&s.device_code).await.unwrap();
    f.r.clock.advance_millis(5000);
    f.login.poll(&s.device_code).await.unwrap();
    assert_eq!(f.polls(), 2, "exactly the interval after the last poll asks GitHub");
    f.r.clock.advance_millis(4999);
    f.login.poll(&s.device_code).await.unwrap();
    assert_eq!(f.polls(), 2, "one millisecond short does not");
}

#[tokio::test]
async fn github_slow_down_raises_the_interval() {
    let f = setup(vec![started(), json_reply(json!({"error": "slow_down", "interval": 15}))], DeviceLoginConfig::default()).await;
    let s = f.login.start("mopm").await.unwrap();
    assert_eq!(f.login.poll(&s.device_code).await.unwrap(), DevicePoll::Pending { interval: 15 });
    let f = setup(vec![started(), error("slow_down")], DeviceLoginConfig::default()).await;
    let s = f.login.start("mopm").await.unwrap();
    assert_eq!(f.login.poll(&s.device_code).await.unwrap(), DevicePoll::Pending { interval: 10 }, "without a figure, five more");
    f.r.clock.advance_millis(9_999);
    assert_eq!(f.login.poll(&s.device_code).await.unwrap(), DevicePoll::Pending { interval: 15 }, "the stored interval is the new one");
    assert_eq!(f.polls(), 1);
}

#[tokio::test]
async fn approved_the_user_upserted_by_numeric_id_a_session_fresh_for_fifteen_minutes_and_the_handle_returned() {
    let f = setup(vec![started(), granted(), octo()], DeviceLoginConfig::default()).await;
    let s = f.login.start("mopm 0.1.0").await.unwrap();
    let DevicePoll::Approved { token, token_kind, expires_at, fresh_until, handle } = f.login.poll(&s.device_code).await.unwrap() else { panic!("not approved") };
    assert_eq!((handle.as_str(), token_kind), ("octo", "session"));
    assert!(is_token_shaped(&token));
    assert_eq!(fresh_until, iso_at(start_ms() + 15 * 60_000));
    assert_eq!(expires_at, iso_at(start_ms() + 30 * 86_400_000));
    let u = f.r.auth.get_user(4242).await.unwrap().unwrap();
    assert_eq!((u.github_id, u.handle.as_str(), u.two_factor), (4242, "octo", Some(true)));
    let p = f.auth.authenticate(Some(&format!("Bearer {token}"))).await.unwrap();
    assert_eq!((p.kind, p.github_id), (TokenKind::Session, Some(4242)));
    assert_eq!(f.auth.fresh_session(&p).unwrap(), 4242);
    let rows = f.r.auth.dump_tokens();
    assert_eq!(rows[0].name, "login (mopm 0.1.0)");
    // GitHub's access token was used for the user lookup once, as a bearer, and is stored nowhere
    let lookup = &f.server.requests()[2];
    assert_eq!((lookup.path(), lookup.header("authorization")), ("/user", Some("Bearer gho_faketoken")));
    let stored = serde_json::to_string(&rows).unwrap();
    assert!(!stored.contains("gho_faketoken") && !stored.contains(&token));
}

#[tokio::test]
async fn the_wire_forms_of_the_answers() {
    assert_eq!(serde_json::to_value(DevicePoll::Pending { interval: 5 }).unwrap(), json!({"status": "pending", "interval": 5}));
    assert_eq!(serde_json::to_value(DevicePoll::Expired).unwrap(), json!({"status": "expired"}));
    assert_eq!(serde_json::to_value(DevicePoll::Denied { reason: DenyReason::GithubDenied }).unwrap(), json!({"status": "denied", "reason": "github_denied"}));
    assert_eq!(serde_json::to_value(DevicePoll::Denied { reason: DenyReason::TwoFactorRequired }).unwrap(), json!({"status": "denied", "reason": "two_factor_required"}));
    let approved = DevicePoll::Approved { token: "t".into(), token_kind: "session", expires_at: "e".into(), fresh_until: "f".into(), handle: "h".into() };
    assert_eq!(serde_json::to_value(approved).unwrap(), json!({"status": "approved", "token": "t", "token_kind": "session", "expires_at": "e", "fresh_until": "f", "handle": "h"}));
    let start = DeviceStart { device_code: "d".into(), user_code: "u".into(), verification_uri: "v".into(), expires_in: 600, interval: 5 };
    assert_eq!(serde_json::to_value(start).unwrap(), json!({"device_code": "d", "user_code": "u", "verification_uri": "v", "expires_in": 600, "interval": 5}));
}

#[tokio::test]
async fn the_device_code_works_once_a_replay_after_approval_is_device_code_unknown() {
    let f = setup(vec![started(), granted(), octo()], DeviceLoginConfig::default()).await;
    let s = f.login.start("mopm").await.unwrap();
    assert!(matches!(f.login.poll(&s.device_code).await.unwrap(), DevicePoll::Approved { .. }));
    let e = refusal(f.login.poll(&s.device_code).await);
    assert_eq!((e.code, e.status(), e.message.as_str()), (ErrorCode::DeviceCodeUnknown, 404, "The device code is not recognised."));
}

#[tokio::test]
async fn logging_in_again_as_the_same_account_keeps_one_user_keeps_created_at_and_follows_a_renamed_handle() {
    let again = vec![started(), granted(), octo(), started(), granted(), user(4242, "octo-renamed", Some(true))];
    let f = setup(again, DeviceLoginConfig::default()).await;
    let s = f.login.start("mopm").await.unwrap();
    f.login.poll(&s.device_code).await.unwrap();
    let first = f.r.auth.get_user(4242).await.unwrap().unwrap();
    f.r.clock.advance_millis(86_400_000);
    let s = f.login.start("mopm").await.unwrap();
    let DevicePoll::Approved { handle, .. } = f.login.poll(&s.device_code).await.unwrap() else { panic!("not approved") };
    assert_eq!(handle, "octo-renamed");
    let second = f.r.auth.get_user(4242).await.unwrap().unwrap();
    assert_eq!(second.created_at, first.created_at);
    assert_eq!(second.handle, "octo-renamed");
    assert_eq!(second.last_login_at, iso_at(start_ms() + 86_400_000));
}

#[tokio::test]
async fn a_different_account_with_the_same_login_text_is_a_different_user() {
    let f = setup(vec![started(), granted(), octo(), started(), granted(), user(9999, "octo", Some(true))], DeviceLoginConfig::default()).await;
    for _ in 0..2 {
        let s = f.login.start("mopm").await.unwrap();
        f.login.poll(&s.device_code).await.unwrap();
    }
    assert_eq!(f.r.auth.get_user(4242).await.unwrap().unwrap().github_id, 4242);
    assert_eq!(f.r.auth.get_user(9999).await.unwrap().unwrap().github_id, 9999);
}

#[tokio::test]
async fn the_person_denies_on_github_denied_no_user_no_token_and_the_code_is_spent() {
    let f = setup(vec![started(), error("access_denied")], DeviceLoginConfig::default()).await;
    let s = f.login.start("mopm").await.unwrap();
    assert_eq!(f.login.poll(&s.device_code).await.unwrap(), DevicePoll::Denied { reason: DenyReason::GithubDenied });
    assert!(f.r.auth.get_user(4242).await.unwrap().is_none());
    assert!(f.r.auth.dump_tokens().is_empty());
    assert_eq!(code_of(f.login.poll(&s.device_code).await), ErrorCode::DeviceCodeUnknown);
}

#[tokio::test]
async fn github_says_the_code_expired_expired() {
    let f = setup(vec![started(), error("expired_token")], DeviceLoginConfig::default()).await;
    let s = f.login.start("mopm").await.unwrap();
    assert_eq!(f.login.poll(&s.device_code).await.unwrap(), DevicePoll::Expired);
    assert_eq!(code_of(f.login.poll(&s.device_code).await), ErrorCode::DeviceCodeUnknown, "and it is spent");
}

#[tokio::test]
async fn our_ten_minutes_pass_expired_without_asking_github() {
    let f = setup(vec![started(), error("authorization_pending")], DeviceLoginConfig::default()).await;
    let s = f.login.start("mopm").await.unwrap();
    f.r.clock.advance_millis(599_999);
    assert_eq!(f.login.poll(&s.device_code).await.unwrap(), DevicePoll::Pending { interval: 5 }, "one millisecond short of it");
    f.r.clock.advance_millis(1);
    assert_eq!(f.login.poll(&s.device_code).await.unwrap(), DevicePoll::Expired);
    assert_eq!(f.polls(), 1, "the second poll did not reach GitHub");
    assert_eq!(code_of(f.login.poll(&s.device_code).await), ErrorCode::DeviceCodeUnknown);
}

#[tokio::test]
async fn unknown_and_short_device_codes_are_device_code_unknown() {
    let f = setup(vec![started()], DeviceLoginConfig::default()).await;
    for code in ["x".repeat(40), "short".to_string(), String::new(), "x".repeat(201), "x".repeat(15)] {
        assert_eq!(code_of(f.login.poll(&code).await), ErrorCode::DeviceCodeUnknown, "{} chars", code.len());
    }
    assert_eq!(f.server.requests().len(), 0);
}

#[tokio::test]
async fn a_github_error_we_do_not_understand_is_unavailable_not_a_login() {
    let f = setup(vec![started(), error("device_flow_disabled")], DeviceLoginConfig::default()).await;
    let s = f.login.start("mopm").await.unwrap();
    assert_eq!(code_of(f.login.poll(&s.device_code).await), ErrorCode::Unavailable);
    assert!(f.r.auth.dump_tokens().is_empty());
}

#[tokio::test]
async fn a_user_lookup_that_fails_or_returns_junk_is_unavailable_and_creates_nothing() {
    for lookup in [Reply::new(500), json_reply(json!({"id": "abc", "login": "x"})), json_reply(json!({"id": 5, "login": ""}))] {
        let f = setup(vec![started(), granted(), lookup], DeviceLoginConfig::default()).await;
        let s = f.login.start("mopm").await.unwrap();
        assert_eq!(code_of(f.login.poll(&s.device_code).await), ErrorCode::Unavailable);
        assert!(f.r.auth.dump_tokens().is_empty());
        assert!(f.r.auth.get_user(5).await.unwrap().is_none());
    }
}

// ---- the two-factor requirement (pending the CEO; defaults ON) -------------------------------------

#[tokio::test]
async fn on_by_default_an_account_github_says_has_2fa_off_is_denied_with_no_user_and_no_token() {
    let f = setup(vec![started(), granted(), user(4242, "octo", Some(false))], DeviceLoginConfig::default()).await;
    let s = f.login.start("mopm").await.unwrap();
    assert_eq!(f.login.poll(&s.device_code).await.unwrap(), DevicePoll::Denied { reason: DenyReason::TwoFactorRequired });
    assert!(f.r.auth.get_user(4242).await.unwrap().is_none());
    assert!(f.r.auth.dump_tokens().is_empty());
    assert_eq!(code_of(f.login.poll(&s.device_code).await), ErrorCode::DeviceCodeUnknown, "the code is spent");
}

#[tokio::test]
async fn it_fails_closed_when_github_does_not_show_the_field_the_login_is_denied() {
    let f = setup(vec![started(), granted(), user(4242, "octo", None)], DeviceLoginConfig::default()).await;
    let s = f.login.start("mopm").await.unwrap();
    assert_eq!(f.login.poll(&s.device_code).await.unwrap(), DevicePoll::Denied { reason: DenyReason::TwoFactorRequired });
    assert!(f.r.auth.dump_tokens().is_empty());
}

#[tokio::test]
async fn switched_off_the_same_accounts_log_in() {
    for who in [user(4242, "octo", Some(false)), user(4242, "octo", None)] {
        let f = setup(vec![started(), granted(), who], no_2fa()).await;
        let s = f.login.start("mopm").await.unwrap();
        assert!(matches!(f.login.poll(&s.device_code).await.unwrap(), DevicePoll::Approved { .. }));
        assert!(f.r.auth.get_user(4242).await.unwrap().is_some());
    }
}

#[tokio::test]
async fn the_configured_scope_and_session_lifetime_are_used() {
    let config = DeviceLoginConfig { github_scope: "read:user user:email".into(), session_ttl_days: 7, ..DeviceLoginConfig::default() };
    let f = setup(vec![started(), granted(), octo()], config).await;
    let s = f.login.start("mopm").await.unwrap();
    assert_eq!(String::from_utf8_lossy(&f.server.requests()[0].body), "client_id=Iv1.testclientid&scope=read%3Auser+user%3Aemail");
    let DevicePoll::Approved { expires_at, .. } = f.login.poll(&s.device_code).await.unwrap() else { panic!("not approved") };
    assert_eq!(expires_at, iso_at(start_ms() + 7 * 86_400_000));
}
