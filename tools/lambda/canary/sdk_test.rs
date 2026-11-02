//! The AWS SDK for Rust, pinned by Cargo.lock, does one DynamoDB GetItem against a
//! fake endpoint on loopback, and every service client the registry will use is built.
//!
//! What it proves: the SDK's request serialization (the JSON 1.0 protocol: target header,
//! body), SigV4 signing with the credentials given (the Authorization header names the key,
//! date, region and service and signs host and x-amz-date) and response and error
//! deserialization all run in this build; and the five service crates link, with the SDK's
//! HTTPS client on rustls over AWS-LC (it constructs a connector even for an http:// endpoint).
//! What it catches: a crate pinned with the wrong features or cfgs (the SDK compiles but
//! misbehaves), and a link that lost AWS-LC.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::thread;

use aws_sdk_dynamodb::config::{BehaviorVersion, Credentials, Region};
use aws_sdk_dynamodb::types::AttributeValue;

/// What the fake saw of the one request.
struct Seen {
    head: String,
    body: String,
}

fn header<'a>(head: &'a str, name: &str) -> Option<&'a str> {
    head.lines().skip(1).find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.eq_ignore_ascii_case(name).then(|| v.trim())
    })
}

/// A DynamoDB that answers one request with `reply` (status line, a newline, the body) and returns what it got.
fn fake_dynamodb(reply: &'static str) -> (String, thread::JoinHandle<Seen>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let handle = thread::spawn(move || {
        let (mut tcp, _) = listener.accept().unwrap();
        let mut buf = Vec::new();
        let mut chunk = [0u8; 4096];
        let (head_end, content_length) = loop {
            let n = tcp.read(&mut chunk).unwrap();
            assert!(n > 0, "client closed before the request was complete");
            buf.extend_from_slice(&chunk[..n]);
            if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                let head = String::from_utf8_lossy(&buf[..i]).to_string();
                break (i + 4, header(&head, "content-length").map_or(0, |v| v.parse::<usize>().unwrap()));
            }
        };
        while buf.len() < head_end + content_length {
            let n = tcp.read(&mut chunk).unwrap();
            buf.extend_from_slice(&chunk[..n]);
        }
        let head = String::from_utf8_lossy(&buf[..head_end - 4]).to_string();
        let body = String::from_utf8_lossy(&buf[head_end..head_end + content_length]).to_string();
        let (status, payload) = reply.split_once('\n').unwrap();
        write!(
            tcp,
            "HTTP/1.1 {status}\r\nContent-Type: application/x-amz-json-1.0\r\nx-amzn-RequestId: req-1\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
            payload.len()
        )
        .unwrap();
        Seen { head, body }
    });
    (url, handle)
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap()
}

fn credentials() -> Credentials {
    Credentials::new("AKIDFAKE", "fakesecret", None, None, "static")
}

/// A DynamoDB client for `endpoint` (a plain `http://host:port` URL) that signs with fixed credentials.
fn dynamodb(endpoint: &str) -> aws_sdk_dynamodb::Client {
    let config = aws_sdk_dynamodb::Config::builder()
        .behavior_version(BehaviorVersion::latest())
        .region(Region::new("us-east-1"))
        .endpoint_url(endpoint)
        .credentials_provider(credentials())
        .build();
    aws_sdk_dynamodb::Client::from_conf(config)
}

/// The `title` attribute of the item whose string key `id` is given, if the item exists.
async fn get_title(client: &aws_sdk_dynamodb::Client, id: &str) -> Result<Option<String>, aws_sdk_dynamodb::Error> {
    let out = client.get_item().table_name("canary").key("id", AttributeValue::S(id.to_string())).send().await?;
    Ok(out.item().and_then(|item| item.get("title")).and_then(|v| v.as_s().ok()).cloned())
}

#[test]
fn get_item_is_serialized_signed_and_deserialized() {
    let (url, server) = fake_dynamodb("200 OK\n{\"Item\":{\"id\":{\"S\":\"k1\"},\"title\":{\"S\":\"hello\"}}}");
    let title = runtime().block_on(async { get_title(&dynamodb(&url), "k1").await });
    let seen = server.join().unwrap();

    // Result: the item's attribute, read from the JSON the fake sent.
    assert_eq!(title.unwrap().as_deref(), Some("hello"));

    // Serialization: operation, protocol, body.
    assert!(seen.head.starts_with("POST / HTTP/1.1"), "{}", seen.head);
    assert_eq!(header(&seen.head, "x-amz-target"), Some("DynamoDB_20120810.GetItem"));
    assert_eq!(header(&seen.head, "content-type"), Some("application/x-amz-json-1.0"));
    let body: serde_json::Value = serde_json::from_str(&seen.body).unwrap();
    assert_eq!(body, serde_json::json!({"TableName": "canary", "Key": {"id": {"S": "k1"}}}));

    // Signing: SigV4 for the key, region and service we configured, over host and x-amz-date.
    let auth = header(&seen.head, "authorization").expect("a signed request");
    assert!(auth.starts_with("AWS4-HMAC-SHA256 Credential=AKIDFAKE/"), "{auth}");
    assert!(auth.contains("/us-east-1/dynamodb/aws4_request"), "{auth}");
    let signed = auth.split("SignedHeaders=").nth(1).unwrap().split(',').next().unwrap();
    assert!(signed.split(';').any(|h| h == "host") && signed.split(';').any(|h| h == "x-amz-date"), "{auth}");
    let signature = auth.split("Signature=").nth(1).unwrap();
    assert_eq!(signature.len(), 64, "{auth}");
    assert!(signature.bytes().all(|b| b.is_ascii_hexdigit()), "{auth}");
    assert!(header(&seen.head, "x-amz-date").is_some_and(|d| d.len() == 16 && d.ends_with('Z')), "{}", seen.head);
    assert!(seen.head.to_lowercase().contains("aws-sdk-rust"), "{}", seen.head);
}

#[test]
fn a_service_error_comes_back_as_an_error() {
    let (url, server) = fake_dynamodb(
        "400 Bad Request\n{\"__type\":\"com.amazonaws.dynamodb.v20120810#ResourceNotFoundException\",\"message\":\"Requested resource not found\"}",
    );
    let result = runtime().block_on(async { get_title(&dynamodb(&url), "k1").await });
    server.join().unwrap();
    let err = result.unwrap_err();
    assert!(
        err.to_string().contains("ResourceNotFoundException") || format!("{err:?}").contains("ResourceNotFoundException"),
        "{err:?}"
    );
}

/// The other service crates the registry's Lambdas use link and build a client (no request is made).
#[test]
fn every_service_client_builds() {
    let region = Region::new("us-east-1");
    let s3 = aws_sdk_s3::Client::from_conf(
        aws_sdk_s3::Config::builder()
            .behavior_version(BehaviorVersion::latest())
            .region(region.clone())
            .credentials_provider(credentials())
            .build(),
    );
    let sqs = aws_sdk_sqs::Client::from_conf(
        aws_sdk_sqs::Config::builder()
            .behavior_version(BehaviorVersion::latest())
            .region(region.clone())
            .credentials_provider(credentials())
            .build(),
    );
    let cloudfront = aws_sdk_cloudfront::Client::from_conf(
        aws_sdk_cloudfront::Config::builder()
            .behavior_version(BehaviorVersion::latest())
            .region(region.clone())
            .credentials_provider(credentials())
            .build(),
    );
    let secrets = aws_sdk_secretsmanager::Client::from_conf(
        aws_sdk_secretsmanager::Config::builder()
            .behavior_version(BehaviorVersion::latest())
            .region(region.clone())
            .credentials_provider(credentials())
            .build(),
    );
    for name in [
        s3.config().region().map(|r| r.as_ref().to_string()),
        sqs.config().region().map(|r| r.as_ref().to_string()),
        cloudfront.config().region().map(|r| r.as_ref().to_string()),
        secrets.config().region().map(|r| r.as_ref().to_string()),
    ] {
        assert_eq!(name.as_deref(), Some("us-east-1"));
    }
}
