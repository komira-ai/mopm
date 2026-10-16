//! The contract of the `AuthStore` port (`service/api/test/auth-store.test.ts` CHECKS), run against
//! every adapter by [`auth_contract_tests!`](crate::auth_contract_tests).

use mopm_ports::auth::AuthStore;
use mopm_ports::types::{DeviceLoginRecord, TokenKind, TokenRecord, TokenScope, TrustedPublisher, UserRecord};

fn tok(id: &str, hash: &str) -> TokenRecord {
    TokenRecord {
        id: id.to_string(),
        kind: TokenKind::Api,
        github_id: Some(1),
        name: "t".to_string(),
        hash: hash.to_string(),
        prefix: "mopm_abcdef".to_string(),
        scopes: vec![TokenScope::Publish],
        packages: vec!["alpha".to_string()],
        all_current: false,
        version: None,
        fresh_until: None,
        created_at: "2026-10-14T12:00:00.000Z".to_string(),
        expires_at: "2026-11-13T12:00:00.123Z".to_string(),
        revoked_at: None,
        last_used_at: None,
        issued_to: None,
    }
}

fn h(n: u32) -> String {
    format!("{n:064}")
}

fn login() -> DeviceLoginRecord {
    DeviceLoginRecord {
        id: h(9),
        github_device_code: "gh-device-code-0123456789".to_string(),
        client: "mopm 0.1.0".to_string(),
        created_at: "2026-10-14T12:00:00.000Z".to_string(),
        expires_at: "2026-10-14T12:10:00.000Z".to_string(),
        interval: 5,
        last_polled_at: None,
    }
}

fn tp(id: &str, name: &str, environment: Option<&str>) -> TrustedPublisher {
    TrustedPublisher {
        id: id.to_string(),
        name: name.to_string(),
        repository_id: "111".to_string(),
        repository_owner_id: "222".to_string(),
        workflow: ".github/workflows/release.yml".to_string(),
        environment: environment.map(str::to_string),
        added_by: 1,
        added_at: "2026-10-14T12:00:00.000Z".to_string(),
    }
}

pub async fn a_user_keeps_created_at_takes_the_new_handle_and_two_factor_follows_the_last_login<S: AuthStore>(s: S) {
    let first = s.upsert_user(7, "old", "2026-10-01T00:00:00.000Z", Some(true)).await.unwrap();
    assert_eq!(
        first,
        UserRecord { github_id: 7, handle: "old".into(), created_at: "2026-10-01T00:00:00.000Z".into(), last_login_at: "2026-10-01T00:00:00.000Z".into(), two_factor: Some(true) }
    );
    let again = s.upsert_user(7, "new", "2026-10-05T00:00:00.000Z", None).await.unwrap();
    assert_eq!(
        again,
        UserRecord { github_id: 7, handle: "new".into(), created_at: "2026-10-01T00:00:00.000Z".into(), last_login_at: "2026-10-05T00:00:00.000Z".into(), two_factor: None }
    );
    assert_eq!(s.get_user(7).await.unwrap(), Some(again));
    assert_eq!(s.get_user(8).await.unwrap(), None);
}

pub async fn a_token_round_trips_exactly_by_hash<S: AuthStore>(s: S) {
    let mut t = tok("tok_a", &h(1));
    t.last_used_at = Some("2026-10-14T12:30:00.000Z".to_string());
    s.put_token(&t).await.unwrap();
    assert_eq!(s.get_token_by_hash(&h(1)).await.unwrap(), Some(t));
    assert_eq!(s.get_token_by_hash(&h(2)).await.unwrap(), None);
}

pub async fn a_ci_token_has_no_account_and_keeps_its_single_version<S: AuthStore>(s: S) {
    let mut t = tok("tok_ci", &h(3));
    t.kind = TokenKind::Oidc;
    t.github_id = None;
    t.version = Some("1.0.0".to_string());
    t.issued_to = Some("acme/widgets".to_string());
    s.put_token(&t).await.unwrap();
    assert_eq!(s.get_token_by_hash(&h(3)).await.unwrap(), Some(t));
    assert!(s.list_tokens(1).await.unwrap().is_empty());
}

pub async fn list_tokens_returns_every_token_of_the_account_and_nobody_elses<S: AuthStore>(s: S) {
    for i in 1..=5u32 {
        let mut t = tok(&format!("tok_{i}"), &h(i));
        if i == 5 {
            t.kind = TokenKind::Session;
        }
        s.put_token(&t).await.unwrap();
    }
    let mut other = tok("tok_other", &h(10));
    other.github_id = Some(2);
    s.put_token(&other).await.unwrap();
    s.revoke_token(&h(2), "2026-10-14T13:00:00.000Z").await.unwrap();
    let mut ids: Vec<String> = s.list_tokens(1).await.unwrap().into_iter().map(|t| t.id).collect();
    ids.sort();
    assert_eq!(ids, ["tok_1", "tok_2", "tok_3", "tok_4", "tok_5"]);
    let theirs: Vec<String> = s.list_tokens(2).await.unwrap().into_iter().map(|t| t.id).collect();
    assert_eq!(theirs, ["tok_other"]);
    assert!(s.list_tokens(3).await.unwrap().is_empty());
}

pub async fn get_user_token_finds_the_accounts_own_token_and_never_another<S: AuthStore>(s: S) {
    s.put_token(&tok("tok_mine", &h(1))).await.unwrap();
    let mut theirs = tok("tok_theirs", &h(2));
    theirs.github_id = Some(2);
    s.put_token(&theirs).await.unwrap();
    assert_eq!(s.get_user_token(1, "tok_mine").await.unwrap().map(|t| t.hash), Some(h(1)));
    assert_eq!(s.get_user_token(1, "tok_theirs").await.unwrap(), None);
    assert_eq!(s.get_user_token(2, "tok_mine").await.unwrap(), None);
    assert_eq!(s.get_user_token(1, "tok_nope").await.unwrap(), None);
}

pub async fn revoking_is_idempotent_keeps_the_first_time_and_a_missing_token_is_nothing<S: AuthStore>(s: S) {
    s.put_token(&tok("tok_a", &h(1))).await.unwrap();
    s.revoke_token(&h(1), "2026-10-14T13:00:00.000Z").await.unwrap();
    s.revoke_token(&h(1), "2026-10-14T14:00:00.000Z").await.unwrap();
    assert_eq!(s.get_token_by_hash(&h(1)).await.unwrap().unwrap().revoked_at.as_deref(), Some("2026-10-14T13:00:00.000Z"));
    s.revoke_token(&h(99), "2026-10-14T13:00:00.000Z").await.unwrap();
    assert_eq!(s.get_token_by_hash(&h(99)).await.unwrap(), None, "not created by revoking");
}

pub async fn touching_records_last_used_at_and_does_not_create_a_token<S: AuthStore>(s: S) {
    s.put_token(&tok("tok_a", &h(1))).await.unwrap();
    s.touch_token(&h(1), "2026-10-14T15:00:00.000Z").await.unwrap();
    assert_eq!(s.get_token_by_hash(&h(1)).await.unwrap().unwrap().last_used_at.as_deref(), Some("2026-10-14T15:00:00.000Z"));
    s.touch_token(&h(98), "2026-10-14T15:00:00.000Z").await.unwrap();
    assert_eq!(s.get_token_by_hash(&h(98)).await.unwrap(), None);
}

pub async fn a_device_login_round_trips_records_polls_and_once_consumed_is_gone<S: AuthStore>(s: S) {
    let l = login();
    s.put_device_login(&l).await.unwrap();
    assert_eq!(s.get_device_login(&l.id).await.unwrap(), Some(l.clone()));
    s.set_device_polled(&l.id, "2026-10-14T12:00:07.000Z", 10).await.unwrap();
    let polled = DeviceLoginRecord { last_polled_at: Some("2026-10-14T12:00:07.000Z".to_string()), interval: 10, ..l.clone() };
    assert_eq!(s.get_device_login(&l.id).await.unwrap(), Some(polled));
    s.delete_device_login(&l.id).await.unwrap();
    assert_eq!(s.get_device_login(&l.id).await.unwrap(), None);
    s.delete_device_login(&l.id).await.unwrap(); // repeating is fine
    s.set_device_polled(&l.id, "2026-10-14T12:00:09.000Z", 15).await.unwrap(); // a poll after consumption changes nothing
    assert_eq!(s.get_device_login(&l.id).await.unwrap(), None);
    s.set_device_polled(&h(77), "2026-10-14T12:00:09.000Z", 15).await.unwrap(); // unknown id: nothing
    assert_eq!(s.get_device_login(&h(77)).await.unwrap(), None);
}

pub async fn trusted_publishers_are_per_package_listed_and_removable_by_id<S: AuthStore>(s: S) {
    s.add_trusted_publisher(&tp("tp1", "alpha", None)).await.unwrap();
    s.add_trusted_publisher(&tp("tp2", "alpha", Some("release"))).await.unwrap();
    s.add_trusted_publisher(&tp("tp3", "beta_pkg", None)).await.unwrap();
    async fn ids<S: AuthStore>(s: &S, n: &str) -> Vec<String> {
        let mut v: Vec<String> = s.list_trusted_publishers(n).await.unwrap().into_iter().map(|x| x.id).collect();
        v.sort();
        v
    }
    assert_eq!(ids(&s, "alpha").await, ["tp1", "tp2"]);
    assert_eq!(ids(&s, "beta_pkg").await, ["tp3"]);
    let tp2 = s.list_trusted_publishers("alpha").await.unwrap().into_iter().find(|x| x.id == "tp2");
    assert_eq!(tp2, Some(tp("tp2", "alpha", Some("release"))));
    s.remove_trusted_publisher("alpha", "tp1").await.unwrap();
    assert_eq!(ids(&s, "alpha").await, ["tp2"]);
    assert!(ids(&s, "nothing").await.is_empty());
}

#[macro_export]
macro_rules! auth_contract_tests {
    ($make:expr) => {
        $crate::contract_tests!($make, $crate::auth_cases, [
            a_user_keeps_created_at_takes_the_new_handle_and_two_factor_follows_the_last_login,
            a_token_round_trips_exactly_by_hash,
            a_ci_token_has_no_account_and_keeps_its_single_version,
            list_tokens_returns_every_token_of_the_account_and_nobody_elses,
            get_user_token_finds_the_accounts_own_token_and_never_another,
            revoking_is_idempotent_keeps_the_first_time_and_a_missing_token_is_nothing,
            touching_records_last_used_at_and_does_not_create_a_token,
            a_device_login_round_trips_records_polls_and_once_consumed_is_gone,
            trusted_publishers_are_per_package_listed_and_removable_by_id,
        ]);
    };
}
