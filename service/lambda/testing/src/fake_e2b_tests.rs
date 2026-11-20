//! What the tutorial-sandbox tests rely on from the fake E2B API: the key check, each scripted answer verbatim and in
//! order, unknown routes, the recorded body, and a hang that only the caller ends.

use serde_json::json;

use super::*;
use crate::fake_http::client::{exchange, exchange_raw, request, Answered};

const KEY: &str = "e2b_test_key";

/// The create body of `docs/design/tutorial-sign-in.md` section 4.
fn create_body() -> Vec<u8> {
    json!({
        "templateID": "mopm-tutorial-test",
        "timeout": 1800,
        "allow_internet_access": false,
        "autoPause": false,
        "network": {"allowPublicTraffic": false},
        "metadata": {"mopm_stage": "beta", "mopm_request": "req-1"}
    })
    .to_string()
    .into_bytes()
}

async fn create(fake: &FakeE2b, key: Option<&str>) -> Option<Answered> {
    let mut headers = vec![("Content-Type", "application/json")];
    headers.extend(key.map(|k| ("X-API-Key", k)));
    exchange(
        &fake.endpoint(),
        &request("POST", CREATE_PATH, &headers, &create_body()),
    )
    .await
}

async fn created(fake: &FakeE2b) -> Answered {
    create(fake, Some(KEY)).await.expect("an answer")
}

#[tokio::test]
async fn a_create_answers_201_and_the_sandbox_verbatim() {
    let fake = FakeE2b::start(KEY, vec![CreateAnswer::Created(Sandbox::example())]);
    let got = created(&fake).await;
    assert_eq!(
        (got.status, got.header("content-type")),
        (201, Some("application/json"))
    );
    assert_eq!(
        got.json(),
        json!({
            "templateID": "mopm-tutorial-test",
            "sandboxID": "itest0sandbox0000001",
            "envdVersion": "0.2.4",
            "envdAccessToken": "envd-token-0123456789abcdef",
            "domain": "e2b.app"
        })
    );
}

#[tokio::test]
async fn a_null_domain_is_sent_as_null() {
    let fake = FakeE2b::start(
        KEY,
        vec![CreateAnswer::Created(Sandbox::example().null_domain())],
    );
    let body = created(&fake).await.json();
    assert_eq!(body["domain"], serde_json::Value::Null);
    assert_eq!(
        body.as_object().map(|o| o.contains_key("domain")),
        Some(true),
        "present, and null"
    );
    assert_eq!(body["envdAccessToken"], "envd-token-0123456789abcdef");
}

#[tokio::test]
async fn a_sandbox_without_an_access_token_has_no_such_member() {
    let fake = FakeE2b::start(
        KEY,
        vec![CreateAnswer::Created(
            Sandbox::example().without_access_token(),
        )],
    );
    assert_eq!(
        created(&fake).await.json(),
        json!({"templateID": "mopm-tutorial-test", "sandboxID": "itest0sandbox0000001", "envdVersion": "0.2.4", "domain": "e2b.app"})
    );
}

#[tokio::test]
async fn refusals_answer_their_status_and_e2b_error_body() {
    let fake = FakeE2b::start(
        KEY,
        vec![
            CreateAnswer::concurrency_limit(),
            CreateAnswer::server_error(503),
            CreateAnswer::Refused {
                status: 400,
                message: "bad".into(),
            },
        ],
    );
    let got = created(&fake).await;
    assert_eq!(
        (got.status, got.json()),
        (
            429,
            json!({"code": 429, "message": "You have reached the maximum number of concurrent E2B sandboxes"})
        )
    );
    let got = created(&fake).await;
    assert_eq!(
        (got.status, got.json()),
        (
            503,
            json!({"code": 503, "message": "Internal server error"})
        )
    );
    let got = created(&fake).await;
    assert_eq!(
        (got.status, got.json()),
        (400, json!({"code": 400, "message": "bad"}))
    );
}

#[tokio::test]
async fn the_script_answers_in_order_and_its_last_answer_repeats() {
    let second = Sandbox {
        sandbox_id: "second".into(),
        ..Sandbox::example()
    };
    let fake = FakeE2b::start(
        KEY,
        vec![
            CreateAnswer::concurrency_limit(),
            CreateAnswer::Created(second),
        ],
    );
    assert_eq!(created(&fake).await.status, 429);
    for _ in 0..2 {
        assert_eq!(created(&fake).await.json()["sandboxID"], "second");
    }
}

#[tokio::test]
async fn an_empty_script_answers_the_example_sandbox() {
    let fake = FakeE2b::start(KEY, vec![]);
    assert_eq!(created(&fake).await.json(), Sandbox::example().to_json());
}

#[tokio::test]
async fn a_missing_or_wrong_key_is_401_and_takes_no_answer_from_the_script() {
    let fake = FakeE2b::start(
        KEY,
        vec![
            CreateAnswer::concurrency_limit(),
            CreateAnswer::Created(Sandbox::example()),
        ],
    );
    for key in [None, Some("e2b_other"), Some("")] {
        let got = create(&fake, key).await.expect("an answer");
        assert_eq!(
            (got.status, got.json()),
            (401, json!({"code": 401, "message": "Invalid API key"})),
            "key {key:?}"
        );
    }
    // The key in another header is no key.
    let raw = request(
        "POST",
        CREATE_PATH,
        &[("Authorization", &format!("Bearer {KEY}"))],
        &create_body(),
    );
    assert_eq!(
        exchange(&fake.endpoint(), &raw)
            .await
            .expect("an answer")
            .status,
        401
    );
    // The first create with the key still gets the first answer.
    assert_eq!(created(&fake).await.status, 429);
    assert_eq!(fake.requests().len(), 5);
    assert_eq!(fake.create_requests().len(), 5);
}

#[tokio::test]
async fn an_unknown_route_is_404_and_takes_no_answer_from_the_script() {
    let fake = FakeE2b::start(
        KEY,
        vec![
            CreateAnswer::concurrency_limit(),
            CreateAnswer::Created(Sandbox::example()),
        ],
    );
    for (method, target) in [
        ("GET", CREATE_PATH),
        ("POST", "/sandboxes"),
        ("POST", "/v2/sandboxes/x/connect"),
        ("PUT", "/sandboxes/x/network"),
    ] {
        let got = exchange(
            &fake.endpoint(),
            &request(method, target, &[("X-API-Key", KEY)], b""),
        )
        .await
        .expect("an answer");
        assert_eq!(
            (got.status, got.json()),
            (404, json!({"code": 404, "message": "Not found"})),
            "{method} {target}"
        );
    }
    assert_eq!(created(&fake).await.status, 429);
    assert_eq!(fake.requests().len(), 5);
    assert_eq!(
        fake.create_requests().len(),
        1,
        "only POST /v2/sandboxes is a create"
    );
}

#[tokio::test]
async fn a_query_string_does_not_change_the_route() {
    let fake = FakeE2b::start(KEY, vec![]);
    let got = exchange(
        &fake.endpoint(),
        &request("POST", "/v2/sandboxes?x=1", &[("X-API-Key", KEY)], b"{}"),
    )
    .await
    .expect("an answer");
    assert_eq!(got.status, 201);
}

#[tokio::test]
async fn the_create_request_is_recorded_in_full() {
    let fake = FakeE2b::start(KEY, vec![]);
    created(&fake).await;
    let seen = fake.create_requests();
    assert_eq!(seen.len(), 1);
    assert_eq!(
        (seen[0].method.as_str(), seen[0].target.as_str()),
        ("POST", CREATE_PATH)
    );
    assert_eq!(
        (seen[0].header("x-api-key"), seen[0].header("content-type")),
        (Some(KEY), Some("application/json"))
    );
    assert_eq!(seen[0].body, create_body());
    assert_eq!(
        seen[0].json(),
        Some(json!({
            "templateID": "mopm-tutorial-test",
            "timeout": 1800,
            "allow_internet_access": false,
            "autoPause": false,
            "network": {"allowPublicTraffic": false},
            "metadata": {"mopm_stage": "beta", "mopm_request": "req-1"}
        }))
    );
}

#[tokio::test]
async fn a_hang_answers_nothing_until_the_caller_gives_up_and_the_next_answer_is_served() {
    let fake = FakeE2b::start(
        KEY,
        vec![
            CreateAnswer::Hang,
            CreateAnswer::Created(Sandbox::example()),
        ],
    );
    let endpoint = fake.endpoint();
    let raw = request("POST", CREATE_PATH, &[("X-API-Key", KEY)], &create_body());
    let hanging = tokio::spawn(async move { exchange_raw(&endpoint, &raw).await });
    fake.wait_for_requests(1).await;
    assert_eq!(
        fake.create_requests()[0].body,
        create_body(),
        "a hanging create is recorded in full"
    );
    // The caller's timeout: it gives up on the call; nothing was answered.
    hanging.abort();
    assert!(hanging
        .await
        .expect_err("the call was given up")
        .is_cancelled());
    assert_eq!(created(&fake).await.status, 201);
}

#[tokio::test]
async fn a_hang_ends_with_no_answer_when_the_fake_is_dropped() {
    let fake = FakeE2b::start(KEY, vec![CreateAnswer::Hang]);
    let endpoint = fake.endpoint();
    let raw = request("POST", CREATE_PATH, &[("X-API-Key", KEY)], &create_body());
    let hanging = tokio::spawn(async move { exchange_raw(&endpoint, &raw).await });
    fake.wait_for_requests(1).await;
    drop(fake);
    assert_eq!(hanging.await.expect("the client task"), Vec::<u8>::new());
}
