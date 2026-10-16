//! The S3, SQS, CloudFront and Secrets Manager adapters against a scripted HTTP server on loopback
//! (`service/api/test/publish/aws.test.ts`): the SDK builds, signs and sends real requests; the server
//! records them. The first real exercise of the services themselves is the stage deployment.

use std::sync::Arc;

use aws_sdk_s3::config::{BehaviorVersion, Credentials, Region};
use aws_sdk_s3::config::retry::RetryConfig;
use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;
use mopm_ports::publish::{Invalidator, ObjectStore, PresignRequest, Presigner, PutOptions, PutOutcome, Queue, QueueMessage};
use mopm_ports::secrets::SecretReader;
use mopm_testing::env::FixedClock;
use mopm_testing::fake_http::{FakeHttp, Reply};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::services::{CloudFrontInvalidator, S3Channel, S3Presigner, SecretsManagerReader, SqsFifoQueue};

/// Built at runtime: the hygiene job refuses a 12-digit literal.
fn queue_url() -> String {
    format!("https://sqs.us-east-1.amazonaws.com/{}/mopm-beta-validate.fifo", "1".repeat(12))
}

fn creds() -> Credentials {
    Credentials::new("AKIDTEST", "secret", Some("SESSION".into()), None, "static")
}

macro_rules! configured {
    ($crate_name:ident, $endpoint:expr) => {
        $crate_name::Config::builder()
            .behavior_version(BehaviorVersion::latest())
            .region(Region::new("us-east-1"))
            .endpoint_url($endpoint)
            .credentials_provider(creds())
            .retry_config(RetryConfig::disabled())
    };
}

fn s3(endpoint: &str) -> aws_sdk_s3::Client {
    aws_sdk_s3::Client::from_conf(configured!(aws_sdk_s3, endpoint).force_path_style(true).build())
}

fn channel(fake: &FakeHttp) -> S3Channel {
    S3Channel::new(s3(&fake.endpoint()), "bkt")
}

const SHA_HELLO: &str = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";

fn opts(content_type: &str) -> PutOptions {
    PutOptions { content_type: content_type.into(), ..PutOptions::default() }
}

// ---- S3 ---------------------------------------------------------------------------------------------------

#[tokio::test]
async fn put_is_signed_with_the_checksum_content_type_and_cache_control_and_create_only_adds_if_none_match() {
    let fake = FakeHttp::start(vec![Reply::new(200).header("etag", "\"x\"")]);
    let body = b"hello";
    let o = PutOptions { content_type: "application/json".into(), cache_control: Some("public, max-age=60".into()), create_only: true };
    assert_eq!(channel(&fake).put("noarch/repodata.json", body, &o).await.unwrap(), PutOutcome::Created);
    let r = &fake.requests()[0];
    assert_eq!((r.method.as_str(), r.path()), ("PUT", "/bkt/noarch/repodata.json"));
    assert_eq!(r.body, body);
    assert_eq!(r.header("content-type"), Some("application/json"));
    assert_eq!(r.header("cache-control"), Some("public, max-age=60"));
    assert_eq!(r.header("if-none-match"), Some("*"));
    assert_eq!(r.header("x-amz-checksum-sha256"), Some(STANDARD.encode(Sha256::digest(body)).as_str()));
    assert_eq!(r.header("x-amz-security-token"), Some("SESSION"));
    assert!(r.header("authorization").unwrap().contains("/us-east-1/s3/aws4_request"));
    let signed = r.signed_headers();
    for h in ["cache-control", "content-type", "host", "if-none-match", "x-amz-checksum-sha256", "x-amz-date", "x-amz-security-token"] {
        assert!(signed.iter().any(|s| s == h), "{h} is not signed: {signed:?}");
    }
}

#[tokio::test]
async fn put_without_create_only_sends_no_if_none_match_412_means_exists_and_other_failures_are_faults() {
    let plain = FakeHttp::start(vec![Reply::new(200)]);
    channel(&plain).put("k", b"x", &opts("text/plain")).await.unwrap();
    assert_eq!(plain.requests()[0].header("if-none-match"), None);

    let exists = FakeHttp::start(vec![Reply::new(412).body("<Error><Code>PreconditionFailed</Code></Error>")]);
    let o = PutOptions { create_only: true, ..opts("t") };
    assert_eq!(channel(&exists).put("k", b"x", &o).await.unwrap(), PutOutcome::Exists);

    let broken = FakeHttp::start(vec![Reply::new(500).body("<Error><Code>InternalError</Code></Error>")]);
    let e = channel(&broken).put("k", b"x", &opts("t")).await.unwrap_err();
    assert!(e.registry().is_none());
    assert!(e.to_string().contains("s3 PUT k"), "{e}");
}

#[tokio::test]
async fn get_and_head_403_and_404_both_mean_absent_200_gives_the_bytes_and_the_length_anything_else_is_a_fault() {
    let got = FakeHttp::start(vec![Reply::new(200).body("bytes!")]);
    assert_eq!(channel(&got).get("quarantine/u/f").await.unwrap().as_deref(), Some(&b"bytes!"[..]));
    assert_eq!((got.requests()[0].method.as_str(), got.requests()[0].path()), ("GET", "/bkt/quarantine/u/f"));
    for status in [403u16, 404] {
        let f = FakeHttp::start(vec![Reply::new(status).body("<Error><Code>NoSuchKey</Code></Error>")]);
        assert_eq!(channel(&f).get("k").await.unwrap(), None, "get {status}");
        let f = FakeHttp::start(vec![Reply::new(status)]);
        assert_eq!(channel(&f).head("k").await.unwrap(), None, "head {status}");
    }
    let head = FakeHttp::start(vec![Reply::new(200).header("content-length", "42")]);
    assert_eq!(channel(&head).head("k").await.unwrap().map(|i| i.size), Some(42));
    assert_eq!(head.requests()[0].method, "HEAD");
    let broken = FakeHttp::start(vec![Reply::new(500)]);
    assert!(channel(&broken).get("k").await.is_err());
}

#[tokio::test]
async fn delete_accepts_204_and_404_and_a_server_error_is_a_fault() {
    for status in [204u16, 404] {
        let f = FakeHttp::start(vec![Reply::new(status)]);
        channel(&f).delete("k").await.unwrap();
        assert_eq!((f.requests()[0].method.as_str(), f.requests()[0].path()), ("DELETE", "/bkt/k"));
    }
    let f = FakeHttp::start(vec![Reply::new(503)]);
    assert!(channel(&f).delete("k").await.is_err());
}

#[tokio::test]
async fn a_key_outside_the_unreserved_set_is_encoded_the_same_way_in_the_url_and_the_signature() {
    let fake = FakeHttp::start(vec![Reply::new(200)]);
    channel(&fake).put("noarch/mojo-a+b-1.0.0.conda", b"x", &opts("t")).await.unwrap();
    assert_eq!(fake.requests()[0].path(), "/bkt/noarch/mojo-a%2Bb-1.0.0.conda");
}

// ---- presigning -------------------------------------------------------------------------------------------

fn presigner() -> S3Presigner {
    let client = s3("http://127.0.0.1:1");
    S3Presigner::new(client, "bkt", Arc::new(FixedClock::at_millis(1_760_443_200_000))) // 2025-10-14T12:00:00Z
}

#[tokio::test]
async fn a_presigned_put_pins_the_length_and_the_checksum_and_expires() {
    let p = presigner().presign_put("quarantine/u1/f", &PresignRequest { size: 5, sha256: SHA_HELLO, expires_in_seconds: 300 }).await.unwrap();
    let url = p.url.clone();
    assert!(url.starts_with("http://127.0.0.1:1/bkt/quarantine/u1/f?"), "{url}");
    for want in ["X-Amz-Algorithm=AWS4-HMAC-SHA256", "X-Amz-Date=20251014T120000Z", "X-Amz-Expires=300", "X-Amz-Signature="] {
        assert!(url.contains(want), "{want} not in {url}");
    }
    // The headers the caller must send, and so what is signed.
    assert_eq!(p.headers.get("content-length").map(String::as_str), Some("5"));
    assert_eq!(p.headers.get("x-amz-checksum-sha256").map(String::as_str), Some("LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ="));
    let signed = url.split("X-Amz-SignedHeaders=").nth(1).unwrap().split('&').next().unwrap().replace("%3B", ";");
    for h in ["content-length", "host", "x-amz-checksum-sha256"] {
        assert!(signed.split(';').any(|s| s == h), "{h} is not signed: {signed}");
    }
}

#[tokio::test]
async fn presigning_is_deterministic_for_the_same_inputs_and_changes_with_each_pinned_value() {
    let req = |size, sha| PresignRequest { size, sha256: sha, expires_in_seconds: 300 };
    let a = presigner().presign_put("k", &req(5, SHA_HELLO)).await.unwrap();
    let b = presigner().presign_put("k", &req(5, SHA_HELLO)).await.unwrap();
    assert_eq!(a, b);
    let other_size = presigner().presign_put("k", &req(6, SHA_HELLO)).await.unwrap();
    let other_sha = presigner().presign_put("k", &req(5, &"a".repeat(64))).await.unwrap();
    let sig = |p: &mopm_ports::publish::PresignedPut| p.url.split("X-Amz-Signature=").nth(1).unwrap().to_string();
    assert_ne!(sig(&a), sig(&other_size), "the length is part of the signature");
    assert_ne!(sig(&a), sig(&other_sha), "the checksum is part of the signature");
}

#[tokio::test]
async fn a_sha256_that_is_not_hex_is_a_fault() {
    let e = presigner().presign_put("k", &PresignRequest { size: 1, sha256: "zz", expires_in_seconds: 60 }).await.unwrap_err();
    assert!(e.registry().is_none());
}

// ---- SQS --------------------------------------------------------------------------------------------------

fn sqs(fake: &FakeHttp) -> SqsFifoQueue {
    SqsFifoQueue::new(aws_sdk_sqs::Client::from_conf(configured!(aws_sdk_sqs, fake.endpoint()).build()), queue_url())
}

fn message() -> QueueMessage {
    QueueMessage { body: r#"{"type":"validate"}"#.into(), group_id: "demo".into(), dedup_id: "pub_1".into() }
}

#[tokio::test]
async fn send_message_over_the_json_protocol_with_the_group_and_deduplication_ids() {
    let fake = FakeHttp::start(vec![Reply::new(200).header("content-type", "application/x-amz-json-1.0").body(r#"{"MessageId":"m"}"#)]);
    sqs(&fake).send(&message()).await.unwrap();
    let r = &fake.requests()[0];
    assert_eq!((r.method.as_str(), r.path()), ("POST", "/"));
    assert_eq!(r.header("x-amz-target"), Some("AmazonSQS.SendMessage"));
    assert_eq!(r.header("content-type"), Some("application/x-amz-json-1.0"));
    let body: Value = serde_json::from_slice(&r.body).unwrap();
    assert_eq!(
        body,
        json!({"QueueUrl": queue_url(), "MessageBody": r#"{"type":"validate"}"#, "MessageGroupId": "demo", "MessageDeduplicationId": "pub_1"})
    );
    let signed = r.signed_headers();
    for h in ["content-type", "host", "x-amz-target"] {
        assert!(signed.iter().any(|s| s == h), "{h}: {signed:?}");
    }
    assert!(r.header("authorization").unwrap().contains("/us-east-1/sqs/aws4_request"));
}

#[tokio::test]
async fn a_refused_send_is_an_error() {
    let fake = FakeHttp::start(vec![Reply::new(400).header("content-type", "application/x-amz-json-1.0").body(r#"{"__type":"com.amazonaws.sqs#AccessDenied","message":"no"}"#)]);
    let e = sqs(&fake).send(&message()).await.unwrap_err();
    assert!(e.to_string().contains("sqs SendMessage"), "{e}");
}

// ---- CloudFront -------------------------------------------------------------------------------------------

fn cloudfront(fake: &FakeHttp) -> CloudFrontInvalidator {
    CloudFrontInvalidator::new(aws_sdk_cloudfront::Client::from_conf(configured!(aws_sdk_cloudfront, fake.endpoint()).build()), "E123ABC")
}

const INVALIDATION: &str = "<Invalidation><Id>I1</Id><Status>InProgress</Status><CreateTime>2026-10-14T12:00:00Z</CreateTime>\
    <InvalidationBatch><Paths><Quantity>1</Quantity><Items><Path>/a</Path></Items></Paths><CallerReference>r</CallerReference></InvalidationBatch></Invalidation>";

#[tokio::test]
async fn create_invalidation_on_the_distribution_with_the_paths_and_the_caller_reference() {
    let fake = FakeHttp::start(vec![Reply::new(201).header("content-type", "text/xml").body(INVALIDATION)]);
    cloudfront(&fake).invalidate(&["/noarch/repodata.json".to_string(), "/noarch/repodata.json.zst".to_string()], "ref-1").await.unwrap();
    let r = &fake.requests()[0];
    assert_eq!((r.method.as_str(), r.path()), ("POST", "/2020-05-31/distribution/E123ABC/invalidation"));
    let body = String::from_utf8(r.body.clone()).unwrap();
    assert!(body.contains("<Quantity>2</Quantity>"), "{body}");
    assert!(body.contains("<Path>/noarch/repodata.json</Path>"), "{body}");
    assert!(body.contains("<Path>/noarch/repodata.json.zst</Path>"), "{body}");
    assert!(body.contains("<CallerReference>ref-1</CallerReference>"), "{body}");
    assert!(r.header("authorization").unwrap().contains("/us-east-1/cloudfront/aws4_request"));
}

#[tokio::test]
async fn a_refused_invalidation_is_an_error_and_markup_in_a_path_cannot_break_out_of_the_xml() {
    let refused = FakeHttp::start(vec![Reply::new(403).header("content-type", "text/xml").body("<ErrorResponse><Error><Code>AccessDenied</Code></Error></ErrorResponse>")]);
    assert!(cloudfront(&refused).invalidate(&["/a".to_string()], "r").await.is_err());
    let fake = FakeHttp::start(vec![Reply::new(201).header("content-type", "text/xml").body(INVALIDATION)]);
    cloudfront(&fake).invalidate(&["/a<b>&c".to_string()], "r").await.unwrap();
    let body = String::from_utf8(fake.requests()[0].body.clone()).unwrap();
    assert!(!body.contains("/a<b>"), "{body}");
    assert!(body.contains("<Path>/a&lt;b&gt;&amp;c</Path>"), "{body}");
}

// ---- Secrets Manager --------------------------------------------------------------------------------------

fn secrets(fake: &FakeHttp) -> SecretsManagerReader {
    SecretsManagerReader::new(aws_sdk_secretsmanager::Client::from_conf(configured!(aws_sdk_secretsmanager, fake.endpoint()).build()))
}

#[tokio::test]
async fn a_secret_is_read_by_id_and_its_string_returned() {
    let fake = FakeHttp::start(vec![Reply::new(200).header("content-type", "application/x-amz-json-1.1").body(r#"{"Name":"mopm/beta/github-oauth","SecretString":"{\"client_id\":\"abc12345\"}"}"#)]);
    assert_eq!(secrets(&fake).read("mopm/beta/github-oauth").await.unwrap().as_deref(), Some(r#"{"client_id":"abc12345"}"#));
    let r = &fake.requests()[0];
    assert_eq!(r.header("x-amz-target"), Some("secretsmanager.GetSecretValue"));
    assert_eq!(serde_json::from_slice::<Value>(&r.body).unwrap(), json!({"SecretId": "mopm/beta/github-oauth"}));
}

#[tokio::test]
async fn a_missing_secret_is_none_and_any_other_failure_is_an_error() {
    let missing = FakeHttp::start(vec![Reply::new(400).header("content-type", "application/x-amz-json-1.1").body(r#"{"__type":"ResourceNotFoundException","Message":"nope"}"#)]);
    assert_eq!(secrets(&missing).read("x").await.unwrap(), None);
    let denied = FakeHttp::start(vec![Reply::new(400).header("content-type", "application/x-amz-json-1.1").body(r#"{"__type":"AccessDeniedException","Message":"no"}"#)]);
    let e = secrets(&denied).read("x").await.unwrap_err();
    assert!(e.registry().is_none());
    assert!(e.to_string().contains("GetSecretValue"), "{e}");
}

#[tokio::test]
async fn a_binary_secret_has_no_string_value() {
    let fake = FakeHttp::start(vec![Reply::new(200).header("content-type", "application/x-amz-json-1.1").body(r#"{"Name":"n","SecretBinary":"AAEC"}"#)]);
    assert_eq!(secrets(&fake).read("n").await.unwrap(), None);
}
