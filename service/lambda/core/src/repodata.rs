//! The channel index (`repodata.json` and its `.zst`), byte for byte what the TypeScript registry's
//! `buildRepodata` writes (spec/channel.md). A pure function of the records: nothing time-dependent
//! is written and the order of the input does not matter.

use std::collections::BTreeSet;

use serde_json::{json, Map, Value};
use thiserror::Error;

use crate::canonical_json::{canonical_json, cmp_utf16, CanonicalJsonError};
use crate::types::{VersionRecord, VersionState};
use crate::zstd::zstd_frame;

/// The conda package that pins the compiler. The spec says "the exact compiler requirement" but not
/// the conda name; one constant to change.
pub const COMPILER_PACKAGE: &str = "mojo-compiler";

#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum RepodataError {
    /// The same file name in two records: a bug in the caller (the store holds one record per version).
    #[error("repodata: file {0} appears twice")]
    DuplicateFile(String),
    #[error(transparent)]
    Json(#[from] CanonicalJsonError),
}

/// `repodata.json` and `repodata.json.zst`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RepodataFiles {
    pub json: Vec<u8>,
    /// The same bytes in a zstd frame.
    pub zst: Vec<u8>,
}

/// The conda dependencies of a record: the compiler pin, the package dependencies as `mojo-<name> <range>`
/// (or `mojo-<name>`), and the native libraries by their allow-list id (the conda package that
/// provides them); no duplicates, sorted as JavaScript sorts strings.
fn depends_of(r: &VersionRecord) -> Vec<String> {
    let mut specs: BTreeSet<String> = BTreeSet::new();
    specs.insert(format!("{COMPILER_PACKAGE} {}", r.requires_mojo));
    for d in &r.deps {
        match d.range.as_deref().filter(|s| !s.is_empty()) {
            Some(range) => specs.insert(format!("mojo-{} {range}", d.name)),
            None => specs.insert(format!("mojo-{}", d.name)),
        };
    }
    for n in &r.native {
        specs.insert(n.id.clone());
    }
    let mut out: Vec<String> = specs.into_iter().collect();
    out.sort_by(|a, b| cmp_utf16(a, b));
    out
}

/// `repodata.json` text for one subdir. `published` records of the subdir are listed under
/// `packages.conda`; `yanked` ones leave it and are listed under `removed` (the files stay
/// downloadable), and so do `tombstoned` ones (their bytes are gone; the name tells a client the
/// file was withdrawn); `pending` records appear nowhere.
pub fn build_repodata_json(subdir: &str, records: &[VersionRecord]) -> Result<String, RepodataError> {
    let mut conda = Map::new();
    let mut removed: Vec<String> = Vec::new();
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    for r in records {
        if r.state == VersionState::Pending {
            continue;
        }
        for f in &r.files {
            if f.subdir != subdir {
                continue;
            }
            if !seen.insert(f.filename.as_str()) {
                return Err(RepodataError::DuplicateFile(f.filename.clone()));
            }
            if matches!(r.state, VersionState::Yanked | VersionState::Tombstoned) {
                removed.push(f.filename.clone());
                continue;
            }
            conda.insert(
                f.filename.clone(),
                json!({
                    "build": r.build,
                    "build_number": 0,
                    "depends": depends_of(r),
                    "name": format!("mojo-{}", r.name),
                    "sha256": f.sha256,
                    "size": f.size,
                    "subdir": f.subdir,
                    "version": r.version,
                }),
            );
        }
    }
    removed.sort_by(|a, b| cmp_utf16(a, b));
    let doc = json!({
        "info": { "subdir": subdir },
        "packages": {},
        "packages.conda": Value::Object(conda),
        "removed": removed,
    });
    Ok(canonical_json(&doc)?)
}

/// The index of one subdir as the two files the channel serves.
pub fn build_repodata(subdir: &str, records: &[VersionRecord]) -> Result<RepodataFiles, RepodataError> {
    let json = build_repodata_json(subdir, records)?.into_bytes();
    let zst = zstd_frame(&json);
    Ok(RepodataFiles { json, zst })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::{file, golden_records, group_row, hex, rec};
    use crate::state::{apply_event, VersionEvent};
    use crate::types::Dep;
    use ruzstd::decoding::StreamingDecoder;
    use std::io::Read;

    // The bytes the TypeScript registry wrote for the golden records (service/api/test/fixtures).
    const GOLDEN_LINUX_64: &str = include_str!("../../../api/test/fixtures/repodata.linux-64.json");
    const GOLDEN_OSX_ARM64: &str = include_str!("../../../api/test/fixtures/repodata.osx-arm64.json");
    const GOLDEN_NOARCH: &str = include_str!("../../../api/test/fixtures/repodata.noarch.json");

    fn decode(frame: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        StreamingDecoder::new(frame).expect("a frame").read_to_end(&mut out).expect("a frame");
        out
    }

    #[test]
    fn linux_64_matches_the_checked_in_bytes() {
        assert_eq!(build_repodata_json("linux-64", &golden_records()).unwrap(), GOLDEN_LINUX_64);
    }

    #[test]
    fn osx_arm64_matches_the_checked_in_bytes() {
        assert_eq!(build_repodata_json("osx-arm64", &golden_records()).unwrap(), GOLDEN_OSX_ARM64);
    }

    #[test]
    fn noarch_matches_the_checked_in_bytes() {
        assert_eq!(build_repodata_json("noarch", &golden_records()).unwrap(), GOLDEN_NOARCH);
    }

    #[test]
    fn the_zst_file_decodes_to_exactly_the_json_bytes() {
        let files = build_repodata("linux-64", &golden_records()).unwrap();
        assert_eq!(decode(&files.zst), files.json);
        assert_eq!(files.json, GOLDEN_LINUX_64.as_bytes());
    }

    #[test]
    fn yanked_and_tombstoned_entries_are_under_removed_and_pending_ones_appear_nowhere() {
        let text = build_repodata_json("linux-64", &golden_records()).unwrap();
        let doc: Value = serde_json::from_str(&text).unwrap();
        let listed: Vec<&String> = doc["packages.conda"].as_object().unwrap().keys().collect();
        assert_eq!(listed, ["mojo-http_client-0.4.0-mojo1.0.0_0.conda", "mojo-http_core-1.2.0-mojo1.0.0_0.conda"]);
        assert_eq!(doc["removed"], json!(["mojo-http_client-0.3.0-mojo1.0.0_0.conda", "mojo-tls-1.0.0-mojo1.0.0_0.conda"]));
        assert_eq!(text.matches("mojo-tls").count(), 1, "only in removed");
        assert!(!text.contains("mojo-fresh"));
        assert_eq!(doc["packages"], json!({}));
    }

    #[test]
    fn an_empty_subdir_is_a_valid_empty_repodata() {
        let doc: Value = serde_json::from_str(&build_repodata_json("linux-aarch64", &[]).unwrap()).unwrap();
        assert_eq!(doc, json!({"info": {"subdir": "linux-aarch64"}, "packages": {}, "packages.conda": {}, "removed": []}));
        assert_eq!(build_repodata_json("linux-aarch64", &[]).unwrap(), r#"{"info":{"subdir":"linux-aarch64"},"packages":{},"packages.conda":{},"removed":[]}"#);
    }

    #[test]
    fn entries_carry_only_the_promised_keys() {
        let doc: Value = serde_json::from_str(&build_repodata_json("linux-64", &golden_records()).unwrap()).unwrap();
        for e in doc["packages.conda"].as_object().unwrap().values() {
            let keys: Vec<&String> = e.as_object().unwrap().keys().collect();
            assert_eq!(keys, ["build", "build_number", "depends", "name", "sha256", "size", "subdir", "version"]);
            assert_eq!(e["build_number"], 0);
        }
    }

    #[test]
    fn the_same_file_name_twice_is_a_bug_in_the_caller_not_silently_merged() {
        let err = build_repodata_json("linux-64", &[rec("p", "1.0.0"), rec("p", "1.0.0")]).unwrap_err();
        assert_eq!(err, RepodataError::DuplicateFile("mojo-p-1.0.0-mojo1.0.0_0.conda".to_string()));
        assert_eq!(err.to_string(), "repodata: file mojo-p-1.0.0-mojo1.0.0_0.conda appears twice");
    }

    #[test]
    fn a_pending_duplicate_is_not_looked_at() {
        let mut pending = rec("p", "1.0.0");
        pending.state = VersionState::Pending;
        assert!(build_repodata_json("linux-64", &[rec("p", "1.0.0"), pending]).is_ok());
    }

    /// Group members that are not shown, each with a file in every subdir: staged now, reserved and not yet
    /// staged, and stamped at an attempt other than the group's current one.
    fn unshown_group_rows() -> Vec<VersionRecord> {
        let spread = |name: &str| {
            let mut r = rec(name, "1.0.0");
            r.files = ["linux-64", "osx-arm64", "noarch"].iter().map(|s| file(s, name, "1.0.0", 'd', 10)).collect();
            r
        };
        vec![
            group_row(spread("grp_staged"), "g1", Some(2)),
            group_row(spread("grp_reserved"), "g1", None),
            group_row(spread("grp_stale"), "g0", Some(1)),
        ]
    }

    #[test]
    fn rows_a_group_has_not_flipped_leave_no_trace_in_any_subdir_and_the_golden_bytes_stand() {
        let mut records = golden_records();
        records.extend(unshown_group_rows());
        for (subdir, golden) in [("linux-64", GOLDEN_LINUX_64), ("osx-arm64", GOLDEN_OSX_ARM64), ("noarch", GOLDEN_NOARCH)] {
            assert_eq!(build_repodata_json(subdir, &records).unwrap(), golden, "{subdir}");
            assert_eq!(build_repodata(subdir, &records).unwrap(), build_repodata(subdir, &golden_records()).unwrap(), "{subdir}: the zst too");
        }
        assert!(!build_repodata_json("linux-64", &records).unwrap().contains("grp_"));
    }

    #[test]
    fn a_row_the_group_flipped_is_listed_exactly_like_one_a_single_publish_wrote() {
        let single = rec("grp_staged", "1.0.0");
        let flipped = VersionRecord { group_id: Some("g1".to_string()), staged_attempt: Some(2), ..single.clone() };
        let with = |r: &VersionRecord| {
            let mut rs = golden_records();
            rs.push(r.clone());
            build_repodata("linux-64", &rs).unwrap()
        };
        assert_eq!(with(&flipped), with(&single));
        assert!(String::from_utf8(with(&flipped).json).unwrap().contains("mojo-grp_staged-1.0.0-mojo1.0.0_0.conda"));
    }

    #[test]
    fn adding_unshown_group_rows_to_any_record_set_changes_no_byte() {
        let mut rng = Rng(0x0bad_cafe_f00d_1234);
        for _ in 0..200 {
            let records = random_records(&mut rng);
            let subdir = ["linux-64", "osx-arm64", "noarch"][rng.below(3) as usize];
            let mut with_group = records.clone();
            with_group.extend(unshown_group_rows());
            assert_eq!(build_repodata(subdir, &with_group).unwrap(), build_repodata(subdir, &records).unwrap());
        }
    }

    #[test]
    fn depends_are_deduplicated_and_sorted_as_javascript_sorts_them() {
        let mut r = rec("p", "1.0.0");
        r.requires_mojo = "==1.0.0".to_string();
        r.deps = vec![
            Dep { name: "zeta".to_string(), range: None },
            Dep { name: "alpha".to_string(), range: Some(">=1".to_string()) },
            Dep { name: "beta".to_string(), range: Some(String::new()) }, // an empty range is no range
            Dep { name: "alpha".to_string(), range: Some(">=1".to_string()) },
        ];
        r.native = vec![
            crate::types::NativeRef { id: "zlib".to_string(), soname: "libz.so.1".to_string() },
            crate::types::NativeRef { id: "\u{1f600}lib".to_string(), soname: "x".to_string() },
            crate::types::NativeRef { id: "\u{ff5e}lib".to_string(), soname: "y".to_string() },
        ];
        assert_eq!(
            depends_of(&r),
            ["mojo-alpha >=1", "mojo-beta", "mojo-compiler ==1.0.0", "mojo-zeta", "zlib", "\u{1f600}lib", "\u{ff5e}lib"],
            "the emoji (a surrogate pair) sorts before U+FF5E in UTF-16 order"
        );
    }

    /// A small deterministic generator (xorshift64*), so the properties below need no dependency.
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 >> 12;
            self.0 ^= self.0 << 25;
            self.0 ^= self.0 >> 27;
            self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
        }
        fn below(&mut self, n: u64) -> u64 {
            self.next() % n
        }
    }

    fn random_records(rng: &mut Rng) -> Vec<VersionRecord> {
        let names = ["alpha", "beta", "gamma", "delta", "http_core", "http_client", "tls"];
        let subdirs = ["linux-64", "osx-arm64", "noarch"];
        let states = [VersionState::Pending, VersionState::Published, VersionState::Published, VersionState::Yanked, VersionState::Tombstoned];
        let mut seen = BTreeSet::new();
        let mut out = Vec::new();
        for _ in 0..rng.below(13) {
            let name = names[rng.below(7) as usize];
            let version = format!("{}.{}.{}", rng.below(10), rng.below(10), rng.below(10));
            if !seen.insert((name, version.clone())) {
                continue;
            }
            let mut r = rec(name, &version);
            r.state = states[rng.below(5) as usize];
            if r.state == VersionState::Yanked {
                r.yank_reason = Some("r".to_string());
            }
            let sha = ['a', 'b', '3', 'f'][rng.below(4) as usize];
            let mut files = Vec::new();
            for s in subdirs {
                if rng.below(2) == 0 {
                    files.push(file(s, name, &version, sha, 1 + rng.below(5_000_000)));
                }
            }
            if files.is_empty() {
                files.push(file("linux-64", name, &version, sha, 7));
            }
            r.files = files;
            for d in 0..rng.below(4) {
                r.deps.push(Dep { name: names[((d + rng.below(7)) % 7) as usize].to_string(), range: [None, Some(">=1".to_string()), Some(">=1.2,<2".to_string())][rng.below(3) as usize].clone() });
            }
            out.push(r);
        }
        out
    }

    #[test]
    fn building_twice_from_the_same_records_gives_identical_bytes() {
        let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
        for _ in 0..200 {
            let records = random_records(&mut rng);
            let subdir = ["linux-64", "osx-arm64", "noarch"][rng.below(3) as usize];
            let a = build_repodata(subdir, &records).unwrap();
            let b = build_repodata(subdir, &records.clone()).unwrap();
            assert_eq!(a, b);
            assert_eq!(decode(&a.zst), a.json, "the zst always decodes to the json");
        }
    }

    #[test]
    fn the_order_of_the_input_records_does_not_change_the_output() {
        let mut rng = Rng(0x1234_5678_9abc_def1);
        for _ in 0..200 {
            let records = random_records(&mut rng);
            let mut shuffled = records.clone();
            for i in (1..shuffled.len()).rev() {
                shuffled.swap(i, rng.below(i as u64 + 1) as usize);
            }
            let subdir = ["linux-64", "osx-arm64", "noarch"][rng.below(3) as usize];
            assert_eq!(build_repodata_json(subdir, &shuffled).unwrap(), build_repodata_json(subdir, &records).unwrap());
        }
    }

    #[test]
    fn only_published_records_are_listed_and_the_rest_are_removed_or_absent() {
        let mut rng = Rng(0xdead_beef_cafe_f00d);
        for _ in 0..200 {
            let records = random_records(&mut rng);
            let subdir = ["linux-64", "osx-arm64", "noarch"][rng.below(3) as usize];
            let doc: Value = serde_json::from_str(&build_repodata_json(subdir, &records).unwrap()).unwrap();
            let mut want = BTreeSet::new();
            let mut gone = BTreeSet::new();
            for r in &records {
                for f in r.files.iter().filter(|f| f.subdir == subdir) {
                    match r.state {
                        VersionState::Published => {
                            want.insert(f.filename.clone());
                        }
                        VersionState::Yanked | VersionState::Tombstoned => {
                            gone.insert(f.filename.clone());
                        }
                        VersionState::Pending => {}
                    }
                }
            }
            let listed: BTreeSet<String> = doc["packages.conda"].as_object().unwrap().keys().cloned().collect();
            let removed: Vec<String> = doc["removed"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect();
            assert_eq!(listed, want);
            assert_eq!(removed, gone.iter().cloned().collect::<Vec<_>>());
            assert!(removed.iter().all(|n| !listed.contains(n)));
        }
    }

    #[test]
    fn yanking_moves_a_file_to_removed_and_unyanking_restores_the_bytes() {
        let base: Vec<VersionRecord> = golden_records().into_iter().filter(|r| r.name != "http_core").collect();
        let mut pending = rec("http_core", "1.2.0");
        pending.state = VersionState::Pending;
        pending.files = vec![file("linux-64", "http_core", "1.2.0", 'a', 1000)];
        let published = apply_event(&pending, &VersionEvent::Publish(None)).unwrap().into_record(&pending);
        let name = "mojo-http_core-1.2.0-mojo1.0.0_0.conda";
        let doc = |extra: &VersionRecord| -> Value {
            let mut rs = base.clone();
            rs.push(extra.clone());
            serde_json::from_str(&build_repodata_json("linux-64", &rs).unwrap()).unwrap()
        };
        let with_it = doc(&published);
        assert!(with_it["packages.conda"].get(name).is_some());
        let yanked = apply_event(&published, &VersionEvent::Yank { reason: "bad".to_string() }).unwrap().into_record(&published);
        let after_yank = doc(&yanked);
        assert!(after_yank["packages.conda"].get(name).is_none());
        assert!(after_yank["removed"].as_array().unwrap().iter().any(|v| v == name));
        let restored = apply_event(&yanked, &VersionEvent::Unyank).unwrap().into_record(&yanked);
        let bytes = |r: &VersionRecord| {
            let mut rs = base.clone();
            rs.push(r.clone());
            build_repodata_json("linux-64", &rs).unwrap()
        };
        assert_eq!(bytes(&restored), bytes(&published));
        assert_eq!(hex('a').len(), 64);
    }
}
