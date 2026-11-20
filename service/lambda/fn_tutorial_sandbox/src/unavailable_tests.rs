//! Every way the function cannot give a sandbox: each is 503 `tutorial_unavailable` with `Retry-After: 30`, the exact
//! body, and one log line with its reason class. When the cause is ours (the key, the template) E2B is not called.

use mopm_ports::http::{HttpFailure, HttpResponse};
use mopm_testing::fake_e2b::{CreateAnswer, Sandbox};
use serde_json::json;

use crate::test_support::*;

/// The 503 answer and its log line, for `reason`.
async fn assert_unavailable(rig: &Rig, reason: &str) {
    let got = rig.send(&Req::signed_in()).await;
    assert_eq!(got.status, 503, "{reason}: {got:?}");
    assert_eq!(got.body, UNAVAILABLE_BODY, "{reason}");
    assert_eq!(
        got.headers,
        vec![
            ("cache-control".to_string(), "no-store".to_string()),
            ("content-type".to_string(), "application/json".to_string()),
            ("retry-after".to_string(), "30".to_string()),
            ("x-mopm-request-id".to_string(), REQUEST_ID.to_string()),
        ],
        "{reason}"
    );
    assert_eq!(rig.last_line(), unavailable_line(reason));
}

#[tokio::test]
async fn a_key_that_is_not_there_or_not_usable_is_unavailable_and_e2b_is_not_called() {
    let cases = [
        (Stored::NotFound, "secret_missing"),
        (Stored::NoString, "secret_missing"),
        (Stored::Value(String::new()), "secret_empty"),
        (
            Stored::Value(r#"{"api_key":""}"#.to_string()),
            "secret_empty",
        ),
        (
            Stored::Value("not json at all".to_string()),
            "secret_malformed",
        ),
        (
            Stored::Value(r#"{"api_key":7}"#.to_string()),
            "secret_malformed",
        ),
        (
            Stored::Value(r#"{"key":"x"}"#.to_string()),
            "secret_malformed",
        ),
        (
            Stored::Value(r#"["e2b_test_key_0123456789"]"#.to_string()),
            "secret_malformed",
        ),
        (Stored::Fail(500), "secret_read_failed"),
    ];
    for (stored, reason) in cases {
        let rig = rig(Spec {
            e2b_secret: stored.clone(),
            ..Spec::default()
        })
        .await;
        assert_unavailable(&rig, reason).await;
        assert_eq!(rig.e2b.requests().len(), 0, "{stored:?}: E2B was asked");
    }
}

#[tokio::test]
async fn a_stage_without_a_template_is_unavailable_and_neither_the_key_nor_e2b_is_asked() {
    let config = item_with(|item| {
        item.as_object_mut()
            .expect("an item")
            .remove("e2b_template_id");
    });
    let rig = rig(Spec {
        config: Some(config),
        ..Spec::default()
    })
    .await;
    assert_unavailable(&rig, "template_missing").await;
    assert_eq!(rig.e2b.requests().len(), 0);
    assert_eq!(
        rig.secrets.reads("mopm/beta/e2b"),
        1,
        "the key is read at the cold start only"
    );
}

#[tokio::test]
async fn e2b_refusing_is_unavailable_with_the_status_as_the_reason() {
    for (status, reason) in [
        (429, "e2b_status_429"),
        (500, "e2b_status_500"),
        (401, "e2b_status_401"),
    ] {
        let rig = rig(Spec {
            script: vec![CreateAnswer::Refused {
                status,
                message: "no".to_string(),
            }],
            ..Spec::default()
        })
        .await;
        assert_unavailable(&rig, reason).await;
        assert_eq!(rig.e2b.create_requests().len(), 1, "{reason}");
    }
    let rig = rig(Spec {
        script: vec![CreateAnswer::concurrency_limit()],
        ..Spec::default()
    })
    .await;
    assert_unavailable(&rig, "e2b_status_429").await;
}

#[tokio::test]
async fn a_sandbox_without_an_access_token_is_unavailable() {
    let rig = rig(Spec {
        script: vec![CreateAnswer::Created(
            Sandbox::example().without_access_token(),
        )],
        ..Spec::default()
    })
    .await;
    assert_unavailable(&rig, "e2b_no_access_token").await;
}

#[tokio::test]
async fn no_answer_from_e2b_is_unavailable_by_how_it_failed() {
    for (failure, reason) in [
        (HttpFailure::Timeout, "e2b_timeout"),
        (HttpFailure::Connect, "e2b_no_connection"),
        (HttpFailure::Tls, "e2b_tls"),
    ] {
        let (http, script) = TestHttp::failing(failure);
        let rig = rig(Spec {
            http: Some(http),
            ..Spec::default()
        })
        .await;
        assert_unavailable(&rig, reason).await;
        assert_eq!(
            script.requests().len(),
            1,
            "{reason}: the create was tried once"
        );
    }
}

#[tokio::test]
async fn an_answer_that_is_not_a_sandbox_is_unavailable() {
    let rig = rig(Spec {
        http: Some(TestHttp::answering(201, "<html>not json</html>")),
        ..Spec::default()
    })
    .await;
    assert_unavailable(&rig, "e2b_malformed").await;
    let no_id = json!({"envdVersion": "0.2.4", "envdAccessToken": "envd-token-0123456789abcdef"})
        .to_string();
    let rig = rig_with_answer(&no_id).await;
    assert_unavailable(&rig, "e2b_missing_field").await;
}

async fn rig_with_answer(body: &str) -> Rig {
    let answer = HttpResponse {
        status: 201,
        headers: vec![],
        body: body.as_bytes().to_vec(),
    };
    rig(Spec {
        http: Some(TestHttp::scripted(vec![Ok(answer)])),
        ..Spec::default()
    })
    .await
}

#[tokio::test]
async fn a_client_that_fails_without_a_failure_class_is_unavailable() {
    let rig = rig(Spec {
        http: Some(TestHttp::scripted(vec![])),
        ..Spec::default()
    })
    .await;
    assert_unavailable(&rig, "e2b_client").await;
}

#[tokio::test]
async fn an_end_past_the_last_representable_time_is_unavailable() {
    let last = "9999-12-30T21:50:00Z"
        .parse::<jiff::Timestamp>()
        .expect("a time")
        .as_millisecond();
    let spec = Spec {
        clock_ms: last,
        session_expires: Some("9999-12-30T21:55:00.000Z".to_string()),
        ..Spec::default()
    };
    let rig = rig(spec).await;
    assert_unavailable(&rig, "clock_out_of_range").await;
    assert_eq!(
        rig.e2b.requests().len(),
        0,
        "the request is not sent when its end cannot be told"
    );
}

// ---- the key is read again until it is there --------------------------------------------------------------------

#[tokio::test]
async fn a_key_written_after_the_cold_start_is_picked_up_by_the_next_request() {
    let rig = rig(Spec {
        e2b_secret: Stored::NotFound,
        ..Spec::default()
    })
    .await;
    assert_unavailable(&rig, "secret_missing").await;
    assert_eq!(
        rig.secrets.reads("mopm/beta/e2b"),
        2,
        "the cold start, then the request"
    );
    rig.secrets.set_e2b(Stored::key(E2B_KEY));
    assert_eq!(rig.send(&Req::signed_in()).await.status, 201);
    assert_eq!(rig.secrets.reads("mopm/beta/e2b"), 3);
    // Present now, so kept: the secret is not read again, even if it changes or goes.
    rig.secrets.set_e2b(Stored::NotFound);
    assert_eq!(rig.send(&Req::signed_in()).await.status, 201);
    assert_eq!(rig.secrets.reads("mopm/beta/e2b"), 3);
    assert_eq!(rig.e2b.create_requests().len(), 2);
}

#[tokio::test]
async fn a_key_present_at_the_cold_start_is_read_once() {
    let rig = rig(Spec::default()).await;
    for _ in 0..3 {
        assert_eq!(rig.send(&Req::signed_in()).await.status, 201);
    }
    assert_eq!(rig.secrets.reads("mopm/beta/e2b"), 1);
    assert_eq!(rig.secrets.reads("mopm/beta/edge-origin"), 1);
}

#[tokio::test]
async fn a_malformed_key_is_read_again_by_the_next_request_and_not_kept() {
    let rig = rig(Spec {
        e2b_secret: Stored::Value("{".to_string()),
        ..Spec::default()
    })
    .await;
    assert_unavailable(&rig, "secret_malformed").await;
    rig.secrets.set_e2b(Stored::Fail(500));
    assert_unavailable(&rig, "secret_read_failed").await;
    assert_eq!(rig.secrets.reads("mopm/beta/e2b"), 3);
}
