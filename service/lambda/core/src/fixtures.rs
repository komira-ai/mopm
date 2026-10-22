//! Test records: `rec` is `rec` of service/api/test/helpers.ts and `golden_records` is
//! `GOLDEN_RECORDS` of service/api/test/fixtures/golden-records.ts.

use crate::types::{Dep, FileRef, NativeRef, Tombstone, VersionRecord, VersionState};

pub fn hex(c: char) -> String {
    c.to_string().repeat(64)
}

/// A published record of `name` at `version` with one linux-64 file.
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

/// `r` as a member of group `group` that is not shown: `pending`, stamped at `attempt` when it was staged.
pub fn group_row(r: VersionRecord, group: &str, attempt: Option<u64>) -> VersionRecord {
    VersionRecord { state: VersionState::Pending, group_id: Some(group.to_string()), staged_attempt: attempt, ..r }
}

pub fn file(subdir: &str, name: &str, version: &str, sha: char, size: u64) -> FileRef {
    FileRef { subdir: subdir.to_string(), filename: format!("mojo-{name}-{version}-mojo1.0.0_0.conda"), sha256: hex(sha), size, url: None }
}

pub fn golden_records() -> Vec<VersionRecord> {
    let mut http_core = rec("http_core", "1.2.0");
    http_core.files = vec![file("linux-64", "http_core", "1.2.0", 'a', 1000), file("osx-arm64", "http_core", "1.2.0", '9', 1001)];

    let mut http_client = rec("http_client", "0.4.0");
    http_client.deps = vec![Dep { name: "http_core".to_string(), range: Some(">=1.2,<2".to_string()) }];
    http_client.native = vec![NativeRef { id: "openssl".to_string(), soname: "libssl.so.3".to_string() }];
    http_client.files = vec![file("linux-64", "http_client", "0.4.0", 'b', 2048)];

    let mut yanked = rec("http_client", "0.3.0");
    yanked.state = VersionState::Yanked;
    yanked.yank_reason = Some("broken".to_string());
    yanked.files = vec![file("linux-64", "http_client", "0.3.0", 'c', 1500)];

    let mut tls = rec("tls", "1.0.0");
    tls.state = VersionState::Tombstoned;
    tls.tombstone = Some(Tombstone { reason_code: "malware".to_string(), date: "2026-10-12".to_string() });
    tls.files = vec![file("linux-64", "tls", "1.0.0", 'd', 700)];

    let mut fresh = rec("fresh", "2.0.0");
    fresh.state = VersionState::Pending;
    fresh.files = vec![file("linux-64", "fresh", "2.0.0", 'e', 10)];

    vec![http_core, http_client, yanked, tls, fresh]
}
