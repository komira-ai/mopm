use super::*;

#[tokio::test]
async fn a_secret_reads_back_what_was_set_and_an_absent_id_is_none() {
    let s = MemorySecrets::new();
    assert_eq!(s.read("a").await.unwrap(), None);
    s.set("a", "one");
    s.set("b", "two");
    assert_eq!(s.read("a").await.unwrap().as_deref(), Some("one"));
    assert_eq!(s.read("b").await.unwrap().as_deref(), Some("two"));
    s.set("a", "three");
    assert_eq!(
        s.read("a").await.unwrap().as_deref(),
        Some("three"),
        "setting again replaces"
    );
    assert_eq!(s.read("c").await.unwrap(), None);
}

fn publish_record(marker: &str) -> PublishRecord {
    serde_json::from_value(serde_json::json!({
        "publish_id": "pub_1", "name": "demo", "version": "1.0.0", "canonical": "1", "actor": "u:1", "published_by": "octo",
        "status": "pending", "manifest_sha256": "b", "files": [], "remaining_subdirs": [marker],
        "created_at": "t", "updated_at": "t", "rev": 0
    }))
    .unwrap()
}

#[tokio::test]
async fn one_update_function_that_declines_then_writes_leaves_the_record_then_bumps_its_rev() {
    let s = MemoryPublishStore::new();
    s.create_publish(&publish_record("x")).await.unwrap();
    let mut calls = 0;
    let mut f = |c: &PublishRecord| {
        calls += 1;
        if calls == 1 {
            None
        } else {
            let mut n = c.clone();
            n.remaining_subdirs.push("y".to_string());
            Some(n)
        }
    };
    assert_eq!(
        s.update_publish("pub_1", &mut f)
            .await
            .unwrap()
            .unwrap()
            .rev,
        0
    );
    let done = s.update_publish("pub_1", &mut f).await.unwrap().unwrap();
    assert_eq!(
        (done.rev, done.remaining_subdirs),
        (1, vec!["x".to_string(), "y".to_string()])
    );
    assert_eq!(s.update_publish("absent", &mut f).await.unwrap(), None);
}
