use super::*;
use crate::records::{audit, rec};
use mopm_core::error::ErrorCode;

#[tokio::test]
async fn updating_a_version_spelled_wrongly_is_refused_and_writes_no_audit_row() {
    let s = MemoryStore::new();
    s.create_version(&rec("p", "1.0.0"), &audit("p", "publish", Some("1.0.0")))
        .await
        .unwrap();
    let e = s
        .update_version(
            "p",
            "1.0",
            &VersionEvent::Unyank,
            &audit("p", "unyank", Some("1.0")),
        )
        .await
        .unwrap_err();
    assert_eq!(e.registry().unwrap().code, ErrorCode::InvalidVersion);
    assert_eq!(s.list_audit("p").await.unwrap().len(), 1);
}
