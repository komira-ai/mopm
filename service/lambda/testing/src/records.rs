//! Records for tests: `rec` and `audit` are the helpers of service/api/test/helpers.ts.

use std::sync::atomic::{AtomicU64, Ordering};

use mopm_core::types::{AuditEntry, FileRef, VersionRecord, VersionState};

pub fn hex(c: char) -> String {
    c.to_string().repeat(64)
}

/// A published record of `name` at `version` with one linux-64 file (sha256 `a` x 64, 1000 bytes).
pub fn rec(name: &str, version: &str) -> VersionRecord {
    let build = "mojo1.0.0_0";
    VersionRecord {
        name: name.to_string(),
        version: version.to_string(),
        canonical: version.to_string(),
        build: build.to_string(),
        state: VersionState::Published,
        yank_reason: None,
        tombstone: None,
        published_at: "2026-10-13T12:00:00Z".to_string(),
        published_by: None,
        requires_mojo: "==1.0.0".to_string(),
        deps: vec![],
        native: vec![],
        files: vec![FileRef {
            subdir: "linux-64".to_string(),
            filename: format!("mojo-{name}-{version}-{build}.conda"),
            sha256: hex('a'),
            size: 1000,
            url: Some(format!("https://conda.example.invalid/linux-64/mojo-{name}-{version}-{build}.conda")),
        }],
        manifest_sha256: hex('f'),
        provenance: None,
        description: None,
        license: None,
        repository: None,
        homepage: None,
        keywords: None,
        readme: None,
        group_id: None,
        staged_attempt: None,
        rev: 0,
    }
}

pub fn with_state(mut r: VersionRecord, state: VersionState) -> VersionRecord {
    r.state = state;
    r
}

/// `r` as a member of group `group` that is not shown: `pending`, stamped at `attempt` when it was staged.
pub fn group_row(r: VersionRecord, group: &str, attempt: Option<u64>) -> VersionRecord {
    VersionRecord { state: VersionState::Pending, group_id: Some(group.to_string()), staged_attempt: attempt, ..r }
}

static AUDIT_SEQ: AtomicU64 = AtomicU64::new(0);

/// An audit entry with a fresh id (`id000001`, ...), so two never collide.
pub fn audit(name: &str, action: &str, version: Option<&str>) -> AuditEntry {
    AuditEntry {
        name: name.to_string(),
        ts: "2026-10-13T12:00:00Z".to_string(),
        id: format!("id{:06}", AUDIT_SEQ.fetch_add(1, Ordering::Relaxed) + 1),
        actor: "test".to_string(),
        action: action.to_string(),
        version: version.map(str::to_string),
        detail: None,
    }
}
