//! The contract of the `PublishStore` port (`service/api/test/publish/dynamo.test.ts`, the part that is
//! about the port), run against every adapter by [`publish_contract_tests!`](crate::publish_contract_tests).

use mopm_core::rejection::RejectionCode;
use mopm_ports::publish::PublishStore;
use mopm_ports::types::{PublishRecord, PublishStatus, UploadRecord};

fn upload(id: &str) -> UploadRecord {
    UploadRecord {
        upload_id: id.to_string(),
        name: "demo".to_string(),
        version: "1.0.0".to_string(),
        canonical: "1".to_string(),
        subdir: "noarch".to_string(),
        filename: "mojo-demo-1.0.0-mojo1.0.0_0.conda".to_string(),
        sha256: "a".repeat(64),
        size: 10,
        key: format!("quarantine/{id}/f"),
        actor: "u:1".to_string(),
        created_at: "2026-10-14T12:00:00Z".to_string(),
        url_expires_at: "2026-10-14T12:05:00Z".to_string(),
        expires_at: 1_792_000_000,
        used_by: None,
    }
}

fn publish(id: &str) -> PublishRecord {
    PublishRecord {
        publish_id: id.to_string(),
        name: "demo".to_string(),
        version: "1.0.0".to_string(),
        canonical: "1".to_string(),
        actor: "u:1".to_string(),
        published_by: "octo".to_string(),
        status: PublishStatus::Pending,
        rejection_code: None,
        message: None,
        manifest_sha256: "b".repeat(64),
        display: None,
        files: vec![],
        remaining_subdirs: vec![],
        created_at: "2026-10-14T12:00:00Z".to_string(),
        updated_at: "2026-10-14T12:00:00Z".to_string(),
        rev: 0,
    }
}

pub async fn uploads_are_stored_read_back_and_taken_once_by_one_publish<S: PublishStore>(s: S) {
    s.put_upload(&upload("u1")).await.unwrap();
    assert_eq!(s.get_upload("u1").await.unwrap(), Some(upload("u1")));
    assert_eq!(s.get_upload("nope").await.unwrap(), None);
    assert!(s.use_upload("u1", "pub_a").await.unwrap());
    assert!(s.use_upload("u1", "pub_a").await.unwrap(), "the same publish again (a resume)");
    assert!(!s.use_upload("u1", "pub_b").await.unwrap());
    assert_eq!(s.get_upload("u1").await.unwrap().unwrap().used_by.as_deref(), Some("pub_a"));
    assert!(!s.use_upload("nope", "pub_a").await.unwrap());
}

pub async fn many_publishes_racing_for_one_upload_exactly_one_gets_it<S: PublishStore>(s: S) {
    s.put_upload(&upload("u1")).await.unwrap();
    let (r0, r1, r2, r3, r4, r5, r6, r7) = tokio::join!(
        s.use_upload("u1", "pub_0"),
        s.use_upload("u1", "pub_1"),
        s.use_upload("u1", "pub_2"),
        s.use_upload("u1", "pub_3"),
        s.use_upload("u1", "pub_4"),
        s.use_upload("u1", "pub_5"),
        s.use_upload("u1", "pub_6"),
        s.use_upload("u1", "pub_7"),
    );
    let won = [r0, r1, r2, r3, r4, r5, r6, r7].into_iter().filter(|r| *r.as_ref().unwrap()).count();
    assert_eq!(won, 1);
}

pub async fn the_version_lock_first_claim_wins_and_others_learn_who_holds_it<S: PublishStore>(s: S) {
    assert_eq!(s.version_holder("demo", "1").await.unwrap(), None);
    let (a, b, c, d) = tokio::join!(
        s.claim_version("demo", "1", "pub_0"),
        s.claim_version("demo", "1", "pub_1"),
        s.claim_version("demo", "1", "pub_2"),
        s.claim_version("demo", "1", "pub_3"),
    );
    let winners: std::collections::BTreeSet<String> = [a, b, c, d].into_iter().map(Result::unwrap).collect();
    assert_eq!(winners.len(), 1);
    let winner = winners.into_iter().next().unwrap();
    assert_eq!(s.version_holder("demo", "1").await.unwrap(), Some(winner.clone()));
    assert_eq!(s.claim_version("demo", "1", "pub_late").await.unwrap(), winner);
    // another version of the same package, and the same version of another package, are other locks
    assert_eq!(s.claim_version("demo", "2", "pub_x").await.unwrap(), "pub_x");
    assert_eq!(s.claim_version("other", "1", "pub_y").await.unwrap(), "pub_y");
}

pub async fn publish_records_are_create_once_and_updates_are_compare_and_swap<S: PublishStore>(s: S) {
    let created = s.create_publish(&publish("pub_1")).await.unwrap();
    assert_eq!(created.status, PublishStatus::Pending);
    let mut other = publish("pub_1");
    other.status = PublishStatus::Rejected;
    assert_eq!(s.create_publish(&other).await.unwrap().status, PublishStatus::Pending, "the existing record, not the argument");
    let got = s.get_publish("pub_1").await.unwrap().unwrap();
    assert_eq!((got.publish_id.as_str(), got.rev), ("pub_1", 0));
    assert_eq!(s.get_publish("nope").await.unwrap(), None);
    assert_eq!(s.update_publish("nope", |c| Some(c.clone())).await.unwrap(), None);

    // f returns None: nothing is written
    assert_eq!(s.update_publish("pub_1", |_| None).await.unwrap().unwrap().rev, 0);
    // five concurrent updates, each adding its own subdir: none is lost, rev counts them
    fn add(x: &'static str) -> impl FnMut(&PublishRecord) -> Option<PublishRecord> + Send {
        move |c| {
            let mut n = c.clone();
            n.remaining_subdirs.push(x.to_string());
            Some(n)
        }
    }
    let (a, b, c, d, e) = tokio::join!(
        s.update_publish("pub_1", add("a")),
        s.update_publish("pub_1", add("b")),
        s.update_publish("pub_1", add("c")),
        s.update_publish("pub_1", add("d")),
        s.update_publish("pub_1", add("e")),
    );
    for r in [a, b, c, d, e] {
        r.unwrap().unwrap();
    }
    let end = s.get_publish("pub_1").await.unwrap().unwrap();
    let mut subdirs = end.remaining_subdirs.clone();
    subdirs.sort();
    assert_eq!(subdirs, ["a", "b", "c", "d", "e"]);
    assert_eq!(end.rev, 5);
}

pub async fn records_with_optional_members_unset_are_accepted<S: PublishStore>(s: S) {
    s.create_publish(&publish("pub_2")).await.unwrap();
    s.put_upload(&upload("u2")).await.unwrap();
    s.update_publish("pub_2", |c| {
        let mut n = c.clone();
        n.status = PublishStatus::Rejected;
        n.rejection_code = Some(RejectionCode::ArchiveInvalid);
        n.message = None;
        Some(n)
    })
    .await
    .unwrap();
    assert_eq!(s.get_publish("pub_2").await.unwrap().unwrap().rejection_code, Some(RejectionCode::ArchiveInvalid));
}

pub async fn counters_hold_the_limit_under_concurrency_and_keys_are_independent<S: PublishStore>(s: S) {
    const KEY: &str = "rl#u#1#2026-10-14";
    let hits = tokio::join!(
        s.hit(KEY, 5, 1_792_000_000), s.hit(KEY, 5, 1_792_000_000), s.hit(KEY, 5, 1_792_000_000), s.hit(KEY, 5, 1_792_000_000),
        s.hit(KEY, 5, 1_792_000_000), s.hit(KEY, 5, 1_792_000_000), s.hit(KEY, 5, 1_792_000_000), s.hit(KEY, 5, 1_792_000_000),
        s.hit(KEY, 5, 1_792_000_000), s.hit(KEY, 5, 1_792_000_000), s.hit(KEY, 5, 1_792_000_000), s.hit(KEY, 5, 1_792_000_000),
    );
    let all: Vec<_> = [hits.0, hits.1, hits.2, hits.3, hits.4, hits.5, hits.6, hits.7, hits.8, hits.9, hits.10, hits.11].into_iter().map(Result::unwrap).collect();
    assert_eq!(all.iter().filter(|h| h.ok).count(), 5);
    assert!(all.iter().filter(|h| !h.ok).all(|h| h.count == 5));
    assert!(s.hit("rl#u#2#2026-10-14", 5, 1_792_000_000).await.unwrap().ok);
    assert!(s.hit("rl#u#1#2026-10-15", 5, 1_792_000_000).await.unwrap().ok);
}

#[macro_export]
macro_rules! publish_contract_tests {
    ($make:expr) => {
        $crate::contract_tests!($make, $crate::publish_cases, [
            uploads_are_stored_read_back_and_taken_once_by_one_publish,
            many_publishes_racing_for_one_upload_exactly_one_gets_it,
            the_version_lock_first_claim_wins_and_others_learn_who_holds_it,
            publish_records_are_create_once_and_updates_are_compare_and_swap,
            records_with_optional_members_unset_are_accepted,
            counters_hold_the_limit_under_concurrency_and_keys_are_independent,
        ]);
    };
}
