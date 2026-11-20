use super::*;
use mopm_ports::types::{TokenKind, TokenScope};

fn tok(id: &str, hash: &str) -> TokenRecord {
    TokenRecord {
        id: id.to_string(),
        kind: TokenKind::Api,
        github_id: Some(1),
        name: "t".to_string(),
        hash: hash.to_string(),
        prefix: "mopm_abcdef".to_string(),
        scopes: vec![TokenScope::Publish],
        packages: vec![],
        all_current: false,
        version: None,
        fresh_until: None,
        created_at: "2026-10-14T12:00:00.000Z".to_string(),
        expires_at: "2026-11-13T12:00:00.000Z".to_string(),
        revoked_at: None,
        last_used_at: None,
        issued_to: None,
    }
}

fn tp(id: &str, name: &str) -> TrustedPublisher {
    TrustedPublisher {
        id: id.to_string(),
        name: name.to_string(),
        repository_id: "111".to_string(),
        repository_owner_id: "222".to_string(),
        workflow: ".github/workflows/release.yml".to_string(),
        environment: None,
        added_by: 1,
        added_at: "2026-10-14T12:00:00.000Z".to_string(),
    }
}

#[tokio::test]
async fn dump_tokens_lists_every_stored_row_by_id_and_is_empty_before_any() {
    let s = MemoryAuthStore::new();
    assert!(s.dump_tokens().is_empty());
    s.put_token(&tok("b", "hb")).await.unwrap();
    s.put_token(&tok("a", "ha")).await.unwrap();
    let ids: Vec<String> = s.dump_tokens().into_iter().map(|t| t.id).collect();
    assert_eq!(ids, ["a", "b"]);
}

#[tokio::test]
async fn removing_a_trusted_publisher_of_an_unknown_package_changes_nothing() {
    let s = MemoryAuthStore::new();
    s.add_trusted_publisher(&tp("tp1", "alpha")).await.unwrap();
    s.remove_trusted_publisher("nobody", "tp1").await.unwrap();
    let kept: Vec<String> = s
        .list_trusted_publishers("alpha")
        .await
        .unwrap()
        .into_iter()
        .map(|t| t.id)
        .collect();
    assert_eq!(kept, ["tp1"]);
    assert!(s
        .list_trusted_publishers("nobody")
        .await
        .unwrap()
        .is_empty());
}
