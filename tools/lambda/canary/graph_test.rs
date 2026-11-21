//! The unit table `buildrules sync` wrote (`buildrules.lock.bzl`, what the farm builds) uses AWS-LC for TLS and has no
//! `ring`: no unit is the `ring` crate or depends on one, every rustls and webpki unit is built with its aws-lc-rs
//! feature and without its ring feature, and the AWS-LC crates are there. So every TLS connection of the functions
//! (the SDK's, and `mopm_aws::http`'s) is on the pinned AWS-LC. Each rule is also shown failing on a small table.

/// The committed table, as the farm reads it.
const TABLE: &str = include_str!("../../../buildrules.lock.bzl");

/// One entry of `UNITS`: its key, its crate, its features, and the keys of its dependencies.
#[derive(Debug, Default)]
struct Unit {
    key: String,
    krate: String,
    features: Vec<String>,
    deps: Vec<String>,
}

/// The quoted strings of `text`, in order.
fn quoted(text: &str) -> Vec<String> {
    text.split('"')
        .skip(1)
        .step_by(2)
        .map(str::to_string)
        .collect()
}

/// The entries of the table's `UNITS` dict: one `    "<key>": {` line, then one field per line, then `    },`.
fn units(table: &str) -> Vec<Unit> {
    let mut out = Vec::new();
    let mut lines = table.lines().skip_while(|l| *l != "UNITS = {").skip(1);
    let mut cur: Option<Unit> = None;
    for line in lines.by_ref() {
        if line == "}" {
            break;
        }
        if let Some(key) = line
            .strip_prefix("    \"")
            .and_then(|l| l.strip_suffix("\": {"))
        {
            cur = Some(Unit {
                key: key.to_string(),
                ..Unit::default()
            });
        } else if line == "    }," {
            out.extend(cur.take());
        } else if let Some(u) = cur.as_mut() {
            if let Some(v) = line.strip_prefix("        \"crate\": ") {
                u.krate = quoted(v).into_iter().next().unwrap_or_default();
            } else if let Some(v) = line.strip_prefix("        \"features\": ") {
                u.features = quoted(v);
            } else if let Some(v) = line.strip_prefix("        \"deps\": ") {
                // [["name", "key"], ...]: every second string is a unit key.
                u.deps = quoted(v).into_iter().skip(1).step_by(2).collect();
            }
        }
    }
    out
}

/// What is wrong with the table's TLS stack; empty when it is AWS-LC only.
fn findings(table: &str) -> Vec<String> {
    let units = units(table);
    let mut out = Vec::new();
    if units.is_empty() {
        out.push("no units read: the table's format is not the one this check reads".to_string());
        return out;
    }
    for u in &units {
        if u.krate == "ring" {
            out.push(format!("{} is the ring crate", u.key));
        }
        if let Some(d) = u.deps.iter().find(|d| d.starts_with("ring-")) {
            out.push(format!("{} depends on {d}", u.key));
        }
        if matches!(u.krate.as_str(), "rustls" | "rustls-webpki") {
            if !u.features.iter().any(|f| f == "aws_lc_rs") {
                out.push(format!("{} is built without its aws_lc_rs feature", u.key));
            }
            if u.features.iter().any(|f| f == "ring") {
                out.push(format!("{} is built with its ring feature", u.key));
            }
        }
    }
    for needed in ["aws-lc-rs", "aws-lc-sys", "rustls"] {
        if !units.iter().any(|u| u.krate == needed) {
            out.push(format!("no {needed} unit"));
        }
    }
    out
}

#[test]
fn the_committed_table_builds_tls_on_aws_lc_and_has_no_ring() {
    assert_eq!(findings(TABLE), Vec::<String>::new());
    // The units this check is about are really read from it.
    let units = units(TABLE);
    assert!(units.iter().any(|u| u.krate == "hyper-rustls"));
    assert!(
        units.iter().filter(|u| u.krate == "rustls").count() >= 2,
        "a unit per profile, at least"
    );
}

/// A table in the committed format with the given units: (key, crate, features, dependency keys).
fn table(units: &[(&str, &str, &[&str], &[&str])]) -> String {
    let mut out = String::from("SCHEMA = 2\n\nUNITS = {\n");
    for (key, krate, features, deps) in units {
        let features: Vec<String> = features.iter().map(|f| format!("\"{f}\"")).collect();
        let deps: Vec<String> = deps.iter().map(|d| format!("[\"x\", \"{d}\"]")).collect();
        out.push_str(&format!(
            "    \"{key}\": {{\n        \"crate\": \"{krate}\",\n        \"version\": \"1\",\n"
        ));
        out.push_str(&format!(
            "        \"features\": [{}],\n        \"deps\": [{}],\n    }},\n",
            features.join(", "),
            deps.join(", ")
        ));
    }
    out.push_str("}\n\nOTHER = {\n    \"ring-0:1\": {\n        \"crate\": \"ring\",\n    },\n}\n");
    out
}

const AWS_LC_RS: (&str, &str, &[&str], &[&str]) = (
    "aws-lc-rs-1:a",
    "aws-lc-rs",
    &["aws-lc-sys"],
    &["aws-lc-sys-0:b"],
);
const AWS_LC_SYS: (&str, &str, &[&str], &[&str]) = ("aws-lc-sys-0:b", "aws-lc-sys", &[], &[]);
const RUSTLS: (&str, &str, &[&str], &[&str]) = (
    "rustls-0:c",
    "rustls",
    &["aws_lc_rs", "std"],
    &["aws-lc-rs-1:a", "rustls-webpki-0:d"],
);
const WEBPKI: (&str, &str, &[&str], &[&str]) = (
    "rustls-webpki-0:d",
    "rustls-webpki",
    &["aws_lc_rs", "std"],
    &["aws-lc-rs-1:a"],
);

#[test]
fn a_small_table_on_aws_lc_only_passes_and_what_follows_its_dict_is_not_read() {
    let small = table(&[AWS_LC_RS, AWS_LC_SYS, RUSTLS, WEBPKI]);
    assert_eq!(findings(&small), Vec::<String>::new());
    // A line between two units (a comment, say) belongs to neither and changes nothing.
    let with_comment = small.replacen(
        "    },\n",
        "    },\n    # between units\n        \"crate\": \"ring\",\n",
        1,
    );
    assert_eq!(units(&with_comment).len(), 4);
    assert_eq!(findings(&with_comment), Vec::<String>::new());
}

#[test]
fn a_ring_unit_and_a_unit_that_depends_on_it_are_found() {
    let ring = ("ring-0.17:e", "ring", &[][..], &[][..]);
    let webpki = (
        "rustls-webpki-0:d",
        "rustls-webpki",
        &["aws_lc_rs", "std"][..],
        &["aws-lc-rs-1:a", "ring-0.17:e"][..],
    );
    assert_eq!(
        findings(&table(&[AWS_LC_RS, AWS_LC_SYS, RUSTLS, webpki, ring])),
        [
            "rustls-webpki-0:d depends on ring-0.17:e",
            "ring-0.17:e is the ring crate"
        ]
    );
}

#[test]
fn rustls_or_webpki_on_ring_or_without_aws_lc_is_found() {
    let rustls = (
        "rustls-0:c",
        "rustls",
        &["ring", "std"][..],
        &["rustls-webpki-0:d"][..],
    );
    let webpki = (
        "rustls-webpki-0:d",
        "rustls-webpki",
        &["aws_lc_rs", "ring"][..],
        &[][..],
    );
    assert_eq!(
        findings(&table(&[AWS_LC_RS, AWS_LC_SYS, rustls, webpki])),
        [
            "rustls-0:c is built without its aws_lc_rs feature",
            "rustls-0:c is built with its ring feature",
            "rustls-webpki-0:d is built with its ring feature"
        ]
    );
}

#[test]
fn a_table_without_the_aws_lc_crates_or_rustls_is_found() {
    let other = ("serde-1:f", "serde", &["std"][..], &[][..]);
    assert_eq!(
        findings(&table(&[other])),
        ["no aws-lc-rs unit", "no aws-lc-sys unit", "no rustls unit"]
    );
}

#[test]
fn a_table_this_check_cannot_read_is_a_finding_not_a_pass() {
    let want = ["no units read: the table's format is not the one this check reads"];
    assert_eq!(findings("SCHEMA = 2\n"), want);
    assert_eq!(findings(&table(&[]).replace("UNITS = {", "UNITS={")), want);
    // A unit whose closing line is missing is not read either.
    assert_eq!(
        findings(&table(&[AWS_LC_SYS]).replacen("    },\n", "", 1)),
        want
    );
}
