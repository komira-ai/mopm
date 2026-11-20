//! The token vectors and the web session row that the TypeScript side checks too (tests/fixtures; see each file's
//! `$comment`): the same random bytes give the same secret, hash, prefix and CSRF value in both languages.

use mopm_core::csrf::{csrf_matches, csrf_value};
use mopm_core::token::{is_token, web_session_fields, TokenSecret, SECRET_BYTES};
use serde_json::Value;

const TOKEN_VECTORS: &str = include_str!("fixtures/token_vectors.json");
const WEB_SESSION_RECORD: &str = include_str!("fixtures/web_session_record.json");

fn random(hex_bytes: &str) -> [u8; SECRET_BYTES] {
    let v: Vec<u8> = (0..hex_bytes.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex_bytes[i..i + 2], 16).unwrap())
        .collect();
    v.try_into().unwrap()
}

fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str()
        .unwrap_or_else(|| panic!("{k} is not a string in {v}"))
}

#[test]
fn every_vector_is_what_tokens_ts_makes_of_its_bytes() {
    let doc: Value = serde_json::from_str(TOKEN_VECTORS).unwrap();
    let vectors = doc["vectors"].as_array().unwrap();
    assert_eq!(vectors.len(), 4);
    for v in vectors {
        let secret = TokenSecret::mint(&random(s(v, "random_hex")));
        assert_eq!(secret.expose(), s(v, "token"));
        assert!(is_token(secret.expose()));
        assert_eq!(secret.hash(), s(v, "hash"));
        assert_eq!(secret.display_prefix(), s(v, "prefix"));
        assert_eq!(csrf_value(&secret), s(v, "csrf"));
        assert!(csrf_matches(&secret, s(v, "csrf")));
    }
}

#[test]
fn the_web_session_row_has_the_fields_the_builder_writes() {
    let doc: Value = serde_json::from_str(WEB_SESSION_RECORD).unwrap();
    let secret = TokenSecret::mint(&random(s(&doc, "random_hex")));
    assert_eq!(secret.expose(), s(&doc, "token"));
    let f = web_session_fields(&secret, s(&doc, "now").parse().unwrap()).unwrap();
    let r = &doc["record"];
    assert_eq!(
        [
            f.name,
            f.hash.as_str(),
            f.prefix.as_str(),
            f.created_at.as_str(),
            f.fresh_until.as_str(),
            f.expires_at.as_str()
        ],
        [
            s(r, "name"),
            s(r, "hash"),
            s(r, "prefix"),
            s(r, "created_at"),
            s(r, "fresh_until"),
            s(r, "expires_at")
        ]
    );
}
