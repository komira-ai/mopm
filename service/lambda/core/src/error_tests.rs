//! Tests of the error codes, the template tables and the views. The tables are held against two
//! things the TypeScript registry's own tests hold them against: the `x-mopm-errors` table of
//! spec/api/openapi.yaml (test/http/auth-catalogue.test.ts, test/publish/catalogue.test.ts), and the
//! rendered errors in the contract fixtures (test/http/replay.test.ts).

use std::collections::BTreeMap;

use serde_json::Value;

use crate::error::*;

const SPEC: &str = include_str!("../../../../spec/api/openapi.yaml");
const CONTRACT_ERRORS: &str = include_str!("../../../../tests/contract/api/errors.json");

struct SpecError {
    status: u16,
    message: String,
    hint: String,
}

/// The end (exclusive) of the JSON string literal that starts at `s[0]`.
fn string_end(s: &str) -> Option<usize> {
    let b = s.as_bytes();
    if b.first() != Some(&b'"') {
        return None;
    }
    let mut i = 1;
    while i < b.len() {
        match b[i] {
            b'\\' => i += 2,
            b'"' => return Some(i + 1),
            _ => i += 1,
        }
    }
    None
}

/// One line of the table: `  code: { status: 400, message: "...", hint: "..." }`.
fn spec_line(line: &str) -> Option<(String, SpecError)> {
    let rest = line.strip_prefix("  ")?;
    let colon = rest.find(':')?;
    let code = &rest[..colon];
    if code.is_empty() || !code.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
        return None;
    }
    let rest = rest[colon + 1..].trim_start().strip_prefix("{ status: ")?;
    let comma = rest.find(',')?;
    let status: u16 = rest[..comma].parse().ok()?;
    let rest = rest[comma..].strip_prefix(", message: ")?;
    let end = string_end(rest)?;
    let message: String = serde_json::from_str(&rest[..end]).ok()?;
    let rest = rest[end..].strip_prefix(", hint: ")?;
    let end = string_end(rest)?;
    let hint: String = serde_json::from_str(&rest[..end]).ok()?;
    (rest[end..].trim() == "}").then_some((code.to_string(), SpecError { status, message, hint }))
}

fn spec_errors() -> BTreeMap<String, SpecError> {
    let at = SPEC.find("\nx-mopm-errors:").expect("the spec has the table");
    SPEC[at..].lines().skip(1).filter_map(spec_line).collect()
}

#[test]
fn the_spec_table_is_read() {
    let spec = spec_errors();
    assert!(spec.len() > 30, "{}", spec.len());
    let t = &spec["token_missing"];
    assert_eq!((t.status, t.message.as_str(), t.hint.as_str()), (401, "This request needs a token.", "Run 'mopm login' or pass a token."));
}

#[test]
fn every_template_has_the_spec_text_and_its_code_the_spec_status() {
    let spec = spec_errors();
    for (name, table) in [("read", READ_CATALOGUE), ("auth", AUTH_CATALOGUE), ("publish", PUBLISH_CATALOGUE)] {
        assert!(!table.is_empty());
        for (code, t) in table {
            let want = spec.get(code.as_str()).unwrap_or_else(|| panic!("{name}: the spec lacks {code}"));
            assert_eq!(t.message, want.message, "{name} {code} message");
            assert_eq!(t.hint, want.hint, "{name} {code} hint");
            assert_eq!(code.status(), want.status, "{name} {code} status");
        }
    }
}

#[test]
fn every_code_the_registry_raises_has_the_status_of_the_spec_when_the_spec_lists_it() {
    let spec = spec_errors();
    let mut listed = 0;
    for code in ErrorCode::ALL {
        if let Some(want) = spec.get(code.as_str()) {
            assert_eq!(code.status(), want.status, "{code}");
            listed += 1;
        }
    }
    assert!(listed >= 28, "{listed} of {} codes are in the spec table", ErrorCode::ALL.len());
}

#[test]
fn the_status_tables_of_the_typescript_registry() {
    // HTTP_STATUS (errors.ts), AUTH_HTTP_STATUS (auth/errors.ts) and the publish table's statuses.
    let ts: &[(&str, u16)] = &[
        ("invalid_request", 400), ("invalid_name", 400), ("invalid_version", 400), ("version_exists", 409),
        ("version_not_found", 404), ("invalid_transition", 409), ("package_not_found", 404), ("name_taken", 409),
        ("owner_not_found", 404), ("already_owner", 409), ("internal_error", 500), ("unavailable", 503),
        ("route_not_found", 404), ("token_missing", 401), ("token_unknown", 401), ("token_expired", 401),
        ("token_revoked", 401), ("stale_session", 401), ("oidc_token_invalid", 401), ("scope_missing", 403),
        ("not_owner", 403), ("oidc_not_trusted", 403), ("device_code_unknown", 404), ("token_not_found", 404),
        ("upload_invalid", 400), ("publish_not_found", 404), ("upload_used", 409), ("payload_too_large", 413),
        ("limit_exceeded", 403), ("rate_limited", 429), ("read_only_mode", 503),
    ];
    assert_eq!(ts.len(), ErrorCode::ALL.len(), "every code of the registry is in the list, and no other");
    for (text, status) in ts {
        let code = ErrorCode::parse(text).unwrap_or_else(|| panic!("no code {text}"));
        assert_eq!(code.status(), *status, "{text}");
        assert_eq!(code.as_str(), *text);
    }
}

#[test]
fn codes_round_trip_through_their_text_and_unknown_text_is_no_code() {
    for code in ErrorCode::ALL {
        assert_eq!(ErrorCode::parse(code.as_str()), Some(*code));
        assert_eq!(code.to_string(), code.as_str());
    }
    assert_eq!(ErrorCode::parse("gone_fishing"), None);
    assert_eq!(ErrorCode::parse("Invalid_Request"), None);
    assert_eq!(ErrorCode::parse(""), None);
}

// ---- the contract fixtures ---------------------------------------------------------------------

/// Whether `rendered` can be `template` with its placeholders filled: the literal pieces appear in order,
/// the first at the start and the last at the end.
fn fits(template: &str, rendered: &str) -> bool {
    let mut pieces: Vec<&str> = Vec::new();
    let mut rest = template;
    while let Some(open) = rest.find('{') {
        let after = &rest[open + 1..];
        match after.find('}') {
            Some(close) if after[..close].bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') && close > 0 => {
                pieces.push(&rest[..open]);
                rest = &after[close + 1..];
            }
            _ => {
                pieces.push(&rest[..open + 1]);
                rest = after;
            }
        }
    }
    pieces.push(rest);
    let (first, last) = (pieces[0], pieces[pieces.len() - 1]);
    if pieces.len() == 1 {
        return rendered == template;
    }
    if !rendered.starts_with(first) || !rendered.ends_with(last) || rendered.len() < first.len() + last.len() {
        return false;
    }
    let mut at = first.len();
    let end = rendered.len() - last.len();
    for p in &pieces[1..pieces.len() - 1] {
        match rendered[at..end].find(p) {
            Some(i) => at += i + p.len(),
            None => return false,
        }
    }
    true
}

#[test]
fn the_template_matcher_can_fail() {
    assert!(fits("There is no package '{name}'.", "There is no package 'nosuch'."));
    assert!(fits("Cannot {action} '{name}' {version}: it is {state}.", "Cannot yank 'p' 1.0.0: it is pending."));
    assert!(fits("This request needs a token.", "This request needs a token."));
    assert!(!fits("There is no package '{name}'.", "There is no package 'nosuch'"));
    assert!(!fits("There is no package '{name}'.", "There is no such package 'x'."));
    assert!(!fits("This request needs a token.", "This request needs a token!"));
    assert!(!fits("Cannot {action} '{name}' {version}: it is {state}.", "Cannot yank 'p' 1.0.0: it was pending."));
}

#[test]
fn the_rendered_errors_of_the_contract_fixtures_are_the_templates_with_values_filled() {
    let doc: Value = serde_json::from_str(CONTRACT_ERRORS).unwrap();
    let mut checked = 0;
    let mut by_code = std::collections::BTreeSet::new();
    for case in doc["cases"].as_array().unwrap() {
        // A case that is meant to fail the contract (a wrong status) is no oracle for the right one.
        if case.get("expect").and_then(Value::as_str) == Some("invalid") {
            continue;
        }
        let Some(err) = case["response"]["body"].get("error") else { continue };
        let code = ErrorCode::parse(err["code"].as_str().unwrap());
        let Some(code) = code else { continue }; // a code of work not ported yet (claims, invitations)
        let status = case["response"]["status"].as_u64().unwrap() as u16;
        let (message, hint) = (err["message"].as_str().unwrap(), err["hint"].as_str().unwrap());
        let name = case["name"].as_str().unwrap();
        let t = publish_template(code).or_else(|| read_auth_template(code));
        if let Some(t) = t {
            assert_eq!(code.status(), status, "{name}: status");
            assert!(fits(t.message, message), "{name}: message {message:?} does not fit {:?}", t.message);
            assert!(fits(t.hint, hint), "{name}: hint {hint:?} does not fit {:?}", t.hint);
            checked += 1;
            by_code.insert(code);
        }
    }
    assert!(checked >= 25, "only {checked} fixture errors were checked");
    for code in [ErrorCode::InvalidTransition, ErrorCode::VersionExists, ErrorCode::RateLimited, ErrorCode::LimitExceeded, ErrorCode::TokenExpired] {
        assert!(by_code.contains(&code), "{code} is not covered by a fixture");
    }
}

// ---- render and the views ------------------------------------------------------------------------

fn detail(pairs: &[(&str, &str)]) -> Detail {
    pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

#[test]
fn render_fills_word_placeholders_and_nothing_else() {
    let d = detail(&[("name", "p"), ("version", "1.0.0"), ("a_1", "x")]);
    assert_eq!(render("'{name}' {version}", &d), "'p' 1.0.0");
    assert_eq!(render("{a_1}{a_1}", &d), "xx");
    assert_eq!(render("{missing}.", &d), ".", "a value that is not there is nothing");
    assert_eq!(render("{}", &d), "{}");
    assert_eq!(render("{a b}", &d), "{a b}");
    assert_eq!(render("{name", &d), "{name");
    assert_eq!(render("{{name}}", &d), "{p}");
    assert_eq!(render("}{", &d), "}{");
    assert_eq!(render("no braces", &d), "no braces");
    assert_eq!(render("", &d), "");
}

#[test]
fn a_substituted_value_is_not_scanned_again() {
    let d = detail(&[("detail", "{name}"), ("name", "NO")]);
    assert_eq!(render("The request is not valid: {detail}.", &d), "The request is not valid: {name}.");
}

#[test]
fn render_is_utf8_safe() {
    let d = detail(&[("name", "\u{e9}\u{1f600}")]);
    assert_eq!(render("\u{e9}{name}\u{e9}", &d), "\u{e9}\u{e9}\u{1f600}\u{e9}");
}

#[test]
fn the_publish_view_renders_the_publish_table() {
    let v = publish_error_view(&version_exists("p", "1.0.0", "abc"));
    assert_eq!(v.status, 409);
    assert_eq!(v.body.code, "version_exists");
    assert_eq!(v.body.message, "'p' 1.0.0 already exists (sha256 abc); versions are immutable.");
    assert_eq!(v.body.hint, "Publish a new version.");
    assert_eq!(v.retry_after, None);
}

#[test]
fn the_publish_view_carries_retry_after_and_fills_the_hint_with_it() {
    let mut e = RegistryError::new(ErrorCode::RateLimited, "x", detail(&[("retry_after", "30")]));
    e.retry_after = Some(30);
    let v = publish_error_view(&e);
    assert_eq!(v.status, 429);
    assert_eq!(v.body.message, "Too many requests.");
    assert_eq!(v.body.hint, "Wait 30 seconds; the Retry-After header says how long.");
    assert_eq!(v.retry_after, Some(30));
}

#[test]
fn a_code_the_publish_table_lacks_is_internal_error_there() {
    // stale_session is an auth-route code; the publish routes answer 500 for it.
    let v = publish_error_view(&RegistryError::new(ErrorCode::StaleSession, "x", Detail::new()));
    assert_eq!(v, internal_error_view());
    assert_eq!(v.status, 500);
    assert_eq!(v.body.code, "internal_error");
    assert_eq!(v.body.message, "Something went wrong on our side.");
    assert_eq!(v.body.hint, "Try again; report the request id if it persists.");
}

#[test]
fn the_read_and_auth_view_uses_the_read_table_then_the_auth_one() {
    let e = RegistryError::new(ErrorCode::StaleSession, "x", Detail::new());
    let v = read_auth_error_view(&e);
    assert_eq!((v.status, v.body.code), (401, "stale_session"));
    assert_eq!(v.body.message, "This action needs a login from the last 15 minutes.");
    let e = RegistryError::new(ErrorCode::TokenExpired, "x", detail(&[("expires_at", "2026-10-13T00:00:00Z")]));
    assert_eq!(read_auth_error_view(&e).body.message, "The token expired at 2026-10-13T00:00:00Z.");
    // A code only the publish table knows is internal_error here.
    let e = RegistryError::new(ErrorCode::UploadUsed, "x", detail(&[("upload_id", "u")]));
    let v = read_auth_error_view(&e);
    assert_eq!((v.status, v.body.code), (500, "internal_error"));
    // And one in no table at all.
    let v = read_auth_error_view(&RegistryError::new(ErrorCode::NameTaken, "x", Detail::new()));
    assert_eq!((v.status, v.body.code), (500, "internal_error"));
}

#[test]
fn the_constructors_make_the_typescript_messages_and_details() {
    let e = invalid_request("cursor is not recognised");
    assert_eq!((e.code, e.message.as_str()), (ErrorCode::InvalidRequest, "The request is not valid: cursor is not recognised."));
    assert_eq!(e.detail["detail"], "cursor is not recognised");
    let e = upload_invalid("size differs");
    assert_eq!(e.message, "The upload does not match what was declared: size differs.");
    let e = oidc_invalid("bad aud");
    assert_eq!((e.code, e.message.as_str()), (ErrorCode::OidcTokenInvalid, "The CI identity token was rejected: bad aud."));
    assert_eq!(read_auth_error_view(&e).body.message, "The CI identity token was rejected: bad aud.");
}

#[test]
fn the_error_displays_its_code_and_message() {
    let e = invalid_request("x");
    assert_eq!(e.to_string(), "invalid_request: The request is not valid: x.");
}

#[test]
fn the_store_errors_have_the_typescript_messages_and_details() {
    let e = name_taken("p");
    assert_eq!((e.code, e.message.as_str(), e.status()), (ErrorCode::NameTaken, "'p' is already taken.", 409));
    assert_eq!(e.detail["name"], "p");
    let e = version_not_found("p", "1.0.0");
    assert_eq!((e.code, e.message.as_str(), e.status()), (ErrorCode::VersionNotFound, "'p' has no version '1.0.0'.", 404));
    assert_eq!(read_auth_error_view(&e).body.message, "'p' has no version '1.0.0'.");
    let e = already_owner("octocat", "p");
    assert_eq!((e.code, e.message.as_str()), (ErrorCode::AlreadyOwner, "'octocat' already owns 'p'."));
    let e = owner_not_found("p");
    assert_eq!((e.code, e.message.as_str(), e.status()), (ErrorCode::OwnerNotFound, "That account is not an owner of the package.", 404));
}
