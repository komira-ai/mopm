//! The contract of the registry `Store` port, as scenarios (`service/api/test/store.test.ts`, the part that
//! is about the port and not about DynamoDB rows). Each is run against every adapter by
//! [`store_contract_tests!`](crate::store_contract_tests), so the memory store that every other test uses is
//! held to what the real one does.

use mopm_core::error::ErrorCode;
use mopm_core::state::VersionEvent;
use mopm_core::types::{FileRef, OwnerRecord, PackageRecord, PackageState, VersionState};
use mopm_ports::error::PortResult;
use mopm_ports::store::Store;

use crate::records::{audit, rec, with_state};

/// The domain error code of a failed call; a fault, or a success, fails the scenario.
pub fn code_of<T: std::fmt::Debug>(r: PortResult<T>) -> ErrorCode {
    match r {
        Err(e) => e.registry().unwrap_or_else(|| panic!("a fault, not a domain error: {e}")).code,
        Ok(v) => panic!("expected a domain error, got {v:?}"),
    }
}

fn pkg(name: &str) -> PackageRecord {
    PackageRecord { name: name.to_string(), state: PackageState::Active, created_at: "2026-10-13T12:00:00Z".to_string(), repository: None, license: None, description: None, homepage: None, keywords: None }
}

pub async fn create_then_get_by_version_and_invalid_spellings<S: Store>(s: S) {
    s.create_version(&rec("p", "1.0.0"), &audit("p", "publish", Some("1.0.0"))).await.unwrap();
    let got = s.get_version("p", "1.0.0").await.unwrap().unwrap();
    assert_eq!((got.version.as_str(), got.canonical.as_str()), ("1.0.0", "1.0.0"));
    for v in ["1", "1.0", "1.0.0.0", "1.0.0rc1"] {
        assert_eq!(code_of(s.get_version("p", v).await), ErrorCode::InvalidVersion, "{v}");
    }
    assert_eq!(code_of(s.create_version(&rec("p", "1.0"), &audit("p", "publish", Some("1.0"))).await), ErrorCode::InvalidVersion);
    assert!(s.get_version("p", "1.0.1").await.unwrap().is_none());
    assert!(s.get_version("q", "1.0.0").await.unwrap().is_none());
}

pub async fn the_same_version_is_refused_naming_the_sha256<S: Store>(s: S) {
    s.create_version(&rec("p", "1.0.0"), &audit("p", "publish", None)).await.unwrap();
    let err = s.create_version(&rec("p", "1.0.0"), &audit("p", "publish", None)).await.unwrap_err();
    let e = err.registry().expect("a domain error");
    assert_eq!((e.code, e.status()), (ErrorCode::VersionExists, 409));
    assert_eq!(e.detail["name"], "p");
    assert_eq!(e.detail["version"], "1.0.0");
    assert_eq!(e.detail["sha256"], "a".repeat(64));
    // The failed create left no audit row behind (the write is all or nothing).
    assert_eq!(s.list_audit("p").await.unwrap().len(), 1);
    assert_eq!(s.list_versions("p").await.unwrap().len(), 1);
}

pub async fn the_same_version_of_another_package_is_independent<S: Store>(s: S) {
    s.create_version(&rec("p", "1.0.0"), &audit("p", "publish", None)).await.unwrap();
    s.create_version(&rec("q", "1.0.0"), &audit("q", "publish", None)).await.unwrap();
    assert_eq!(s.list_versions("q").await.unwrap().len(), 1);
}

pub async fn invalid_versions_are_refused_before_anything_is_written<S: Store>(s: S) {
    assert_eq!(code_of(s.create_version(&rec("p", "v1"), &audit("p", "publish", None)).await), ErrorCode::InvalidVersion);
    assert!(s.list_versions("p").await.unwrap().is_empty());
    assert!(s.list_audit("p").await.unwrap().is_empty());
}

pub async fn a_tombstoned_number_is_never_reusable<S: Store>(s: S) {
    s.create_version(&rec("p", "2.0.0"), &audit("p", "publish", None)).await.unwrap();
    let tomb = VersionEvent::Tombstone { reason_code: "malware".to_string(), date: "2026-10-12".to_string(), unpublished: false };
    s.update_version("p", "2.0.0", &tomb, &audit("p", "takedown", None)).await.unwrap();
    let mut other = rec("p", "2.0.0");
    other.files = vec![FileRef { subdir: "linux-64".to_string(), filename: "mojo-p-2.0.0-mojo1.0.0_0.conda".to_string(), sha256: "e".repeat(64), size: 5, url: None }];
    assert_eq!(code_of(s.create_version(&other, &audit("p", "publish", None)).await), ErrorCode::VersionExists);
}

pub async fn lifecycle_has_one_audit_row_per_change<S: Store>(s: S) {
    s.create_version(&with_state(rec("p", "1.0.0"), VersionState::Pending), &audit("p", "upload", None)).await.unwrap();
    let published = s.update_version("p", "1.0.0", &VersionEvent::Publish(None), &audit("p", "publish", None)).await.unwrap();
    assert_eq!(published.state, VersionState::Published);
    let y = s.update_version("p", "1.0.0", &VersionEvent::Yank { reason: "broken".to_string() }, &audit("p", "yank", None)).await.unwrap();
    assert_eq!((y.state, y.yank_reason.as_deref(), y.rev), (VersionState::Yanked, Some("broken"), 2));
    // Idempotent: no change, so no audit row.
    s.update_version("p", "1.0.0", &VersionEvent::Yank { reason: "other".to_string() }, &audit("p", "yank-again", None)).await.unwrap();
    let u = s.update_version("p", "1.0.0", &VersionEvent::Unyank, &audit("p", "unyank", None)).await.unwrap();
    assert_eq!((u.state, u.yank_reason), (VersionState::Published, None));
    let actions: Vec<String> = s.list_audit("p").await.unwrap().into_iter().map(|a| a.action).collect();
    // The ids of one scenario increase, and the time is the same, so the order is the order written.
    assert_eq!(actions, ["upload", "publish", "yank", "unyank"]);
}

pub async fn a_missing_version_and_a_refused_transition_change_nothing<S: Store>(s: S) {
    assert_eq!(code_of(s.update_version("p", "1.0.0", &VersionEvent::Publish(None), &audit("p", "x", None)).await), ErrorCode::VersionNotFound);
    s.create_version(&with_state(rec("p", "1.0.0"), VersionState::Pending), &audit("p", "upload", None)).await.unwrap();
    let err = s.update_version("p", "1.0.0", &VersionEvent::Yank { reason: "r".to_string() }, &audit("p", "yank", None)).await.unwrap_err();
    let e = err.registry().expect("a domain error");
    assert_eq!((e.code, e.status()), (ErrorCode::InvalidTransition, 409));
    assert_eq!(s.get_version("p", "1.0.0").await.unwrap().unwrap().state, VersionState::Pending);
    assert_eq!(s.list_audit("p").await.unwrap().len(), 1);
}

pub async fn list_versions_is_in_version_order_not_text_order<S: Store>(s: S) {
    for v in ["1.10.0", "1.9.0", "1.0.1", "1.0.0", "1.2.0"] {
        s.create_version(&rec("p", v), &audit("p", "publish", Some(v))).await.unwrap();
    }
    let got: Vec<String> = s.list_versions("p").await.unwrap().into_iter().map(|r| r.version).collect();
    assert_eq!(got, ["1.0.0", "1.0.1", "1.2.0", "1.9.0", "1.10.0"]);
}

pub async fn packages_are_create_once_and_listed<S: Store>(s: S) {
    for n in ["c", "a", "b", "e", "d"] {
        s.create_package(&pkg(n)).await.unwrap();
    }
    assert_eq!(code_of(s.create_package(&pkg("a")).await), ErrorCode::NameTaken);
    assert_eq!(s.list_package_names().await.unwrap(), ["a", "b", "c", "d", "e"]);
    assert_eq!(s.get_package("a").await.unwrap().unwrap().name, "a");
    assert!(s.get_package("zz").await.unwrap().is_none());
}

pub async fn search_packages_prefix_order_after_limit_and_summary_fields<S: Store>(s: S) {
    for n in ["http_d", "httpx", "zlib", "http_a", "http_c", "http_b", "ht"] {
        let mut p = pkg(n);
        p.description = Some(format!("d {n}"));
        p.repository = Some("https://github.com/example/r".to_string());
        p.license = Some("MIT".to_string());
        s.create_package(&p).await.unwrap();
    }
    async fn found<S: Store>(s: &S, prefix: &str, after: Option<&str>, limit: usize) -> Vec<String> {
        s.search_packages(prefix, after, limit).await.unwrap().into_iter().map(|p| p.name).collect()
    }
    assert_eq!(found(&s, "http_", None, 100).await, ["http_a", "http_b", "http_c", "http_d"]);
    assert_eq!(found(&s, "", None, 100).await, ["ht", "http_a", "http_b", "http_c", "http_d", "httpx", "zlib"]);
    assert_eq!(found(&s, "http_", Some("http_b"), 100).await, ["http_c", "http_d"], "strictly after");
    assert!(found(&s, "http_", Some("http_d"), 100).await.is_empty());
    assert_eq!(found(&s, "http_", None, 3).await, ["http_a", "http_b", "http_c"]);
    assert!(found(&s, "nomatch", None, 100).await.is_empty());
    assert!(found(&s, "http", None, 0).await.is_empty());
    // The result carries what a summary shows and nothing else (the index projects no more).
    let one = s.search_packages("zlib", None, 1).await.unwrap().remove(0);
    assert_eq!(serde_json::to_value(&one).unwrap(), serde_json::json!({"name": "zlib", "state": "active", "created_at": "2026-10-13T12:00:00Z", "description": "d zlib"}));
}

pub async fn a_package_without_a_description_has_no_description_key<S: Store>(s: S) {
    let mut p = pkg("bare");
    p.state = PackageState::Claimed;
    s.create_package(&p).await.unwrap();
    let one = s.search_packages("", None, 5).await.unwrap().remove(0);
    assert_eq!(serde_json::to_value(&one).unwrap(), serde_json::json!({"name": "bare", "state": "claimed", "created_at": "2026-10-13T12:00:00Z"}));
}

pub async fn owners_are_unique_removable_and_listed_by_id<S: Store>(s: S) {
    let o = |id: u64| OwnerRecord { name: "p".to_string(), github_id: id, handle: format!("u{id}"), added_at: "2026-10-13T12:00:00Z".to_string() };
    for id in [30, 4, 200, 11] {
        s.add_owner(&o(id)).await.unwrap();
    }
    assert_eq!(code_of(s.add_owner(&o(4)).await), ErrorCode::AlreadyOwner);
    s.remove_owner("p", 200).await.unwrap();
    assert_eq!(code_of(s.remove_owner("p", 200).await), ErrorCode::OwnerNotFound);
    let ids: Vec<u64> = s.list_owners("p").await.unwrap().into_iter().map(|x| x.github_id).collect();
    assert_eq!(ids, [4, 11, 30], "by id, numerically (not 11, 30, 4)");
    assert!(s.list_owners("other").await.unwrap().is_empty());
}

pub async fn audit_lists_oldest_first_by_time_then_id<S: Store>(s: S) {
    let mut late = audit("p", "late", None);
    late.ts = "2026-10-13T12:00:05Z".to_string();
    let mut early = audit("p", "early", None);
    early.ts = "2026-10-13T12:00:01Z".to_string();
    let mut same_a = audit("p", "same-a", None);
    same_a.ts = "2026-10-13T12:00:03Z".to_string();
    let mut same_b = audit("p", "same-b", None);
    same_b.ts = "2026-10-13T12:00:03Z".to_string();
    for e in [&late, &same_b, &early, &same_a] {
        s.append_audit(e).await.unwrap();
    }
    s.append_audit(&audit("other", "elsewhere", None)).await.unwrap();
    let actions: Vec<String> = s.list_audit("p").await.unwrap().into_iter().map(|a| a.action).collect();
    assert_eq!(actions, ["early", "same-a", "same-b", "late"]);
}

// ---- create-once under concurrency ---------------------------------------------------------

pub async fn exactly_one_of_two_concurrent_creates_wins<S: Store>(s: S) {
    let (a, b) = (rec("p", "1.0.0"), rec("p", "1.0.0"));
    let (au1, au2) = (audit("p", "publish", None), audit("p", "publish", None));
    let (x, y) = tokio::join!(s.create_version(&a, &au1), s.create_version(&b, &au2));
    let results = [x, y];
    assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
    let loser = results.into_iter().find_map(Result::err).unwrap();
    assert_eq!(loser.registry().unwrap().code, ErrorCode::VersionExists);
    assert_eq!(s.list_versions("p").await.unwrap().len(), 1);
    assert_eq!(s.list_audit("p").await.unwrap().len(), 1);
}

pub async fn six_concurrent_creates_of_one_version_have_one_winner<S: Store>(s: S) {
    let recs: Vec<_> = (0..6).map(|_| rec("p", "3.0.0")).collect();
    let audits: Vec<_> = (0..6).map(|_| audit("p", "publish", Some("3.0.0"))).collect();
    let (r0, r1, r2, r3, r4, r5) = tokio::join!(
        s.create_version(&recs[0], &audits[0]),
        s.create_version(&recs[1], &audits[1]),
        s.create_version(&recs[2], &audits[2]),
        s.create_version(&recs[3], &audits[3]),
        s.create_version(&recs[4], &audits[4]),
        s.create_version(&recs[5], &audits[5]),
    );
    let results = [r0, r1, r2, r3, r4, r5];
    assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
    assert_eq!(s.list_versions("p").await.unwrap().len(), 1);
}

pub async fn two_concurrent_yanks_end_yanked_with_one_change_recorded<S: Store>(s: S) {
    s.create_version(&rec("p", "1.0.0"), &audit("p", "publish", None)).await.unwrap();
    let (one, two) = (VersionEvent::Yank { reason: "one".to_string() }, VersionEvent::Yank { reason: "two".to_string() });
    let (a1, a2) = (audit("p", "yank", None), audit("p", "yank", None));
    let (x, y) = tokio::join!(s.update_version("p", "1.0.0", &one, &a1), s.update_version("p", "1.0.0", &two, &a2));
    x.unwrap();
    y.unwrap();
    let v = s.get_version("p", "1.0.0").await.unwrap().unwrap();
    assert_eq!(v.state, VersionState::Yanked);
    assert!(["one", "two"].contains(&v.yank_reason.as_deref().unwrap()));
    assert_eq!(v.rev, 1);
    assert_eq!(s.list_audit("p").await.unwrap().len(), 2, "publish and one yank");
}

pub async fn a_yank_racing_a_takedown_ends_tombstoned<S: Store>(s: S) {
    s.create_version(&rec("p", "1.0.0"), &audit("p", "publish", None)).await.unwrap();
    let yank = VersionEvent::Yank { reason: "x".to_string() };
    let tomb = VersionEvent::Tombstone { reason_code: "abuse".to_string(), date: "2026-10-12".to_string(), unpublished: false };
    let (a1, a2) = (audit("p", "yank", None), audit("p", "takedown", None));
    let (_x, _y) = tokio::join!(s.update_version("p", "1.0.0", &yank, &a1), s.update_version("p", "1.0.0", &tomb, &a2));
    assert_eq!(s.get_version("p", "1.0.0").await.unwrap().unwrap().state, VersionState::Tombstoned);
}

/// Every scenario, by name, for the macro that runs them.
#[macro_export]
macro_rules! store_contract_tests {
    ($make:expr) => {
        $crate::contract_tests!($make, $crate::store_cases, [
            create_then_get_by_version_and_invalid_spellings,
            the_same_version_is_refused_naming_the_sha256,
            the_same_version_of_another_package_is_independent,
            invalid_versions_are_refused_before_anything_is_written,
            a_tombstoned_number_is_never_reusable,
            lifecycle_has_one_audit_row_per_change,
            a_missing_version_and_a_refused_transition_change_nothing,
            list_versions_is_in_version_order_not_text_order,
            packages_are_create_once_and_listed,
            search_packages_prefix_order_after_limit_and_summary_fields,
            a_package_without_a_description_has_no_description_key,
            owners_are_unique_removable_and_listed_by_id,
            audit_lists_oldest_first_by_time_then_id,
            exactly_one_of_two_concurrent_creates_wins,
            six_concurrent_creates_of_one_version_have_one_winner,
            two_concurrent_yanks_end_yanked_with_one_change_recorded,
            a_yank_racing_a_takedown_ends_tombstoned,
        ]);
    };
}

/// One `#[tokio::test]` per scenario of `$suite`, each on a fresh value of `$make`.
#[macro_export]
macro_rules! contract_tests {
    ($make:expr, $suite:path, [$($name:ident),+ $(,)?]) => {
        $(
            #[tokio::test]
            async fn $name() {
                use $suite as suite;
                suite::$name(($make)()).await
            }
        )+
    };
}
