//! The OAuth app's secret: what is read, and every way it fails to be, by exact message and never with its content.

use mopm_ports::error::PortError;
use mopm_testing::memory_publish::MemorySecrets;
use serde_json::json;

use super::*;
use crate::test_support::stage;

const ID: &str = "mopm/t/github-oauth";

fn secret(value: &str) -> MemorySecrets {
    let secrets = MemorySecrets::new();
    secrets.set(ID, value);
    secrets
}

async fn load(value: &str) -> Result<OAuthApp, OAuthError> {
    OAuthApp::load(&secret(value), &stage()).await
}

#[tokio::test]
async fn the_apps_client_id_and_secret_are_read_from_the_stages_secret() {
    let app =
        load(r#"{"client_id": "Ov23liExampleId", "client_secret": "s3cr3t-value", "extra": 1}"#)
            .await
            .unwrap();
    assert_eq!(app.client_id(), "Ov23liExampleId");
    assert_eq!(app.client_secret(), "s3cr3t-value");
}

#[tokio::test]
async fn another_stages_secret_is_not_read() {
    let secrets = MemorySecrets::new();
    secrets.set(
        "mopm/prod/github-oauth",
        r#"{"client_id": "prod-client", "client_secret": "prod-secret"}"#,
    );
    assert_eq!(
        OAuthApp::load(&secrets, &stage())
            .await
            .unwrap_err()
            .to_string(),
        "the GitHub OAuth secret mopm/t/github-oauth does not exist"
    );
}

#[tokio::test]
async fn debug_shows_the_client_id_and_never_the_client_secret() {
    let app = load(r#"{"client_id": "Ov23liExampleId", "client_secret": "s3cr3t-value"}"#)
        .await
        .unwrap();
    assert_eq!(
        format!("{app:?}"),
        r#"OAuthApp { client_id: "Ov23liExampleId", client_secret: "<redacted>" }"#
    );
    assert_eq!(
        format!("{app:#?}"),
        "OAuthApp {\n    client_id: \"Ov23liExampleId\",\n    client_secret: \"<redacted>\",\n}"
    );
}

#[tokio::test]
async fn a_secret_that_is_not_json_fails_the_start_without_its_content() {
    let err = load("this-is-not-json-s3cr3t").await.unwrap_err();
    assert_eq!(
        err.to_string(),
        "the GitHub OAuth secret mopm/t/github-oauth is not JSON"
    );
    assert_eq!(format!("{err:?}"), r#"NotJson("mopm/t/github-oauth")"#);
}

#[tokio::test]
async fn a_client_id_outside_the_typescript_grammar_fails_the_start() {
    let long = "a".repeat(101);
    let cases = [
        json!({"client_secret": "s"}),
        json!({"client_id": 12345678, "client_secret": "s"}),
        json!({"client_id": null, "client_secret": "s"}),
        json!({"client_id": "abc", "client_secret": "s"}),
        json!({"client_id": "", "client_secret": "s"}),
        json!({"client_id": long, "client_secret": "s"}),
        json!({"client_id": "has space", "client_secret": "s"}),
        json!({"client_id": "slash/id", "client_secret": "s"}),
        json!({"client_id": "idé-ünicode", "client_secret": "s"}),
    ];
    for case in cases {
        let err = load(&case.to_string()).await.unwrap_err();
        assert_eq!(
            err.to_string(),
            "the GitHub OAuth secret mopm/t/github-oauth has no usable client_id",
            "{case}"
        );
    }
    for not_an_object in ["[]", "\"text\"", "17", "null"] {
        let err = load(not_an_object).await.unwrap_err();
        assert_eq!(
            err.to_string(),
            "the GitHub OAuth secret mopm/t/github-oauth has no usable client_id",
            "{not_an_object}"
        );
    }
}

#[tokio::test]
async fn the_shortest_and_longest_client_ids_and_every_allowed_character_are_accepted() {
    for id in ["abcd", &"a".repeat(100), "Az09._-xyz"] {
        let app = load(&json!({"client_id": id, "client_secret": "s"}).to_string())
            .await
            .unwrap();
        assert_eq!(app.client_id(), id);
    }
}

#[tokio::test]
async fn a_missing_or_empty_client_secret_fails_the_start() {
    for case in [
        json!({"client_id": "abcd1234"}),
        json!({"client_id": "abcd1234", "client_secret": ""}),
        json!({"client_id": "abcd1234", "client_secret": 5}),
        json!({"client_id": "abcd1234", "client_secret": null}),
    ] {
        let err = load(&case.to_string()).await.unwrap_err();
        assert_eq!(
            err.to_string(),
            "the GitHub OAuth secret mopm/t/github-oauth has no client_secret",
            "{case}"
        );
    }
}

#[tokio::test]
async fn a_secret_that_does_not_exist_fails_the_start_by_name() {
    let err = OAuthApp::load(&MemorySecrets::new(), &stage())
        .await
        .unwrap_err();
    assert_eq!(
        err.to_string(),
        "the GitHub OAuth secret mopm/t/github-oauth does not exist"
    );
}

struct Failing;

impl SecretReader for Failing {
    async fn read(&self, _: &str) -> PortResult<Option<String>> {
        Err(PortError::fault("access denied"))
    }
}

#[tokio::test]
async fn a_secret_that_cannot_be_read_fails_the_start_naming_it() {
    let err = OAuthApp::load(&Failing, &stage()).await.unwrap_err();
    assert_eq!(
        err.to_string(),
        "reading the GitHub OAuth secret mopm/t/github-oauth: infrastructure fault: access denied"
    );
}
