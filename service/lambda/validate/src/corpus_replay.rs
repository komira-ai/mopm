//! Phase A's validator corpus (`tests/validator_corpus`, komira-ai/mopm#88): 219 inputs and the verdict the
//! TypeScript validator gave each. The Rust validator must answer the same, for every input: same
//! acceptance, same rule, same rejection code, same message and path, and for an accepted package the same facts.
//! "Same" is compared as JSON values, so only meaning counts, not key order. Inputs that are wrong in two ways fix
//! the order the rules are applied in; the corpus holds them.
//!
//! What this proves: that the port agrees with the recorded behaviour of the TypeScript on these inputs. What it does
//! not: that the behaviour is right (the corpus says what the TypeScript did), or anything about inputs not in it.

use std::collections::BTreeSet;

use mopm_core::limits::Limits;
use serde_json::Value;
use sha2::Digest;

use crate::corpus_table::ARCHIVES;
use crate::{validate_package, PublishExpectation, ValidatorOptions};

const CASES: &str = include_str!("../../../../tests/validator_corpus/cases.json");
const VERDICTS: &str = include_str!("../../../../tests/validator_corpus/verdicts.json");

fn archive(name: &str) -> &'static [u8] {
    ARCHIVES.iter().find(|(n, _)| *n == name).map(|(_, b)| *b).unwrap_or_else(|| panic!("src/corpus_table.rs lacks the line for {name}"))
}

fn expectation(c: &Value) -> PublishExpectation {
    let e = &c["expect"];
    let s = |k: &str| e[k].as_str().unwrap_or_default().to_string();
    PublishExpectation {
        name: s("name"),
        version: s("version"),
        subdir: s("subdir"),
        filename: s("filename"),
        sha256: e.get("sha256").and_then(Value::as_str).map(str::to_string),
        manifest_sha256: e.get("manifest_sha256").and_then(Value::as_str).map(str::to_string),
    }
}

fn limits(c: &Value) -> Limits {
    let mut l = Limits::DEFAULT;
    for (k, v) in c["limits"].as_object().expect("limits is an object") {
        let n = v.as_u64().unwrap_or_else(|| panic!("limit {k} is not a number"));
        match k.as_str() {
            "max_archive_bytes" => l.max_archive_bytes = n,
            "max_file_bytes" => l.max_file_bytes = n,
            "max_unpacked_bytes" => l.max_unpacked_bytes = n,
            "max_files" => l.max_files = n,
            "max_ratio" => l.max_ratio = n,
            "ratio_floor_bytes" => l.ratio_floor_bytes = n,
            "max_metadata_bytes" => l.max_metadata_bytes = n,
            other => panic!("unknown limit {other}"),
        }
    }
    l
}

fn cases() -> Vec<Value> {
    serde_json::from_str::<Value>(CASES).unwrap()["cases"].as_array().unwrap().clone()
}

fn verdicts() -> Vec<Value> {
    serde_json::from_str::<Value>(VERDICTS).unwrap()["verdicts"].as_array().unwrap().clone()
}

fn verdict_of(c: &Value) -> Value {
    let options = ValidatorOptions {
        limits: limits(c),
        allowed_native_deps: c["allow_native"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect(),
    };
    validate_package(archive(c["archive"].as_str().unwrap()), &expectation(c), &options).to_json()
}

fn outcome(v: &Value) -> String {
    if v["ok"] == true { "ok".into() } else { v["rule"].as_str().unwrap_or("?").to_string() }
}

#[test]
fn the_corpus_is_what_the_replay_expects() {
    let cases = cases();
    assert_eq!(cases.len(), 219, "the corpus of komira-ai/mopm#88");
    let verdicts = verdicts();
    assert_eq!(verdicts.len(), cases.len());
    for (c, v) in cases.iter().zip(&verdicts) {
        assert_eq!(c["id"], v["id"], "cases.json and verdicts.json are in the same order");
    }
    // The table lists exactly the archives the cases name.
    let named: BTreeSet<&str> = cases.iter().map(|c| c["archive"].as_str().unwrap()).collect();
    let tabled: BTreeSet<&str> = ARCHIVES.iter().map(|(n, _)| *n).collect();
    assert_eq!(named.difference(&tabled).collect::<Vec<_>>(), Vec::<&&str>::new(), "add these to src/corpus_table.rs");
    assert_eq!(tabled.difference(&named).collect::<Vec<_>>(), Vec::<&&str>::new(), "remove these from src/corpus_table.rs");
    // Ids are unique.
    let ids: BTreeSet<&str> = cases.iter().map(|c| c["id"].as_str().unwrap()).collect();
    assert_eq!(ids.len(), cases.len());
}

#[test]
fn every_case_gets_the_verdict_the_typescript_gave() {
    let cases = cases();
    let verdicts = verdicts();
    let mut differ = Vec::new();
    for (c, v) in cases.iter().zip(&verdicts) {
        let got = verdict_of(c);
        if got != v["verdict"] {
            differ.push(format!("{}: want {} got {}\n  want {}\n  got  {}", c["id"], outcome(&v["verdict"]), outcome(&got), v["verdict"], got));
        }
    }
    assert!(differ.is_empty(), "{} of {} cases differ:\n{}", differ.len(), cases.len(), differ.join("\n"));
}

#[test]
fn every_case_reaches_the_rule_it_was_written_to_hit() {
    // `intent` is the rule the case was written for (or `ok`): a case that stops reaching its fault is a case to repair.
    let mut wrong = Vec::new();
    for c in cases() {
        let got = outcome(&verdict_of(&c));
        if got != c["intent"].as_str().unwrap() {
            wrong.push(format!("{}: intent {} but {}", c["id"], c["intent"], got));
        }
    }
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
}

#[test]
fn the_corpus_covers_every_rule_the_validator_can_apply() {
    let seen: BTreeSet<String> = verdicts().iter().map(|v| outcome(&v["verdict"])).collect();
    let missing: Vec<&str> = crate::RuleCode::ALL.iter().map(|r| r.as_str()).filter(|r| !seen.contains(*r)).collect();
    // The rules the TypeScript corpus does not reach are those that need a format the Lambda never accepts.
    assert_eq!(missing, Vec::<&str>::new(), "rules no corpus case reaches");
}

#[test]
fn declared_hashes_are_compared_case_insensitively_and_a_wrong_one_is_refused() {
    let case = cases().into_iter().find(|c| c["id"] == "ok_minimal").unwrap();
    let facts = verdict_of(&case)["facts"].clone();
    let manifest = facts["manifestSha256"].as_str().unwrap().to_string();
    let archive_sha = hex::encode(sha2::Sha256::digest(archive("ok_minimal.conda")));
    let run = |sha: Option<String>, manifest_sha: Option<String>| {
        let mut e = expectation(&case);
        e.sha256 = sha;
        e.manifest_sha256 = manifest_sha;
        let o = ValidatorOptions { limits: limits(&case), allowed_native_deps: Default::default() };
        validate_package(archive("ok_minimal.conda"), &e, &o).to_json()
    };
    assert_eq!(run(Some(archive_sha.to_uppercase()), Some(manifest.to_uppercase()))["ok"], true);
    assert_eq!(run(Some(archive_sha.clone()), Some(manifest.clone()))["ok"], true);
    assert_eq!(run(Some("0".repeat(64)), None)["rule"], "sha256_mismatch");
    assert_eq!(run(None, Some("0".repeat(64)))["rule"], "manifest_sha256_mismatch");
}
