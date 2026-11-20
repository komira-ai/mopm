//! What a test relies on from the scripted server: replies in order, requests recorded in full, the three answers,
//! and the progress event.

use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;

use super::client::{exchange, exchange_raw, parse, request};
use super::*;

#[tokio::test]
async fn replies_answer_in_order_and_the_last_repeats() {
    let fake = FakeHttp::start(vec![
        Reply::new(201).body("one"),
        Reply::new(500).header("X-Kind", "outage").body("two"),
    ]);
    let get = request("GET", "/", &[], b"");
    let first = exchange(&fake.endpoint(), &get).await.expect("an answer");
    assert_eq!((first.status, first.text()), (201, "one".to_string()));
    for _ in 0..2 {
        let next = exchange(&fake.endpoint(), &get).await.expect("an answer");
        assert_eq!(
            (next.status, next.header("x-kind"), next.text()),
            (500, Some("outage"), "two".to_string())
        );
    }
    assert_eq!(fake.requests().len(), 3);
}

#[tokio::test]
async fn no_replies_is_an_empty_200() {
    let fake = FakeHttp::start(vec![]);
    let got = exchange(&fake.endpoint(), &request("GET", "/", &[], b""))
        .await
        .expect("an answer");
    assert_eq!(
        (got.status, got.header("content-length"), got.body.len()),
        (200, Some("0"), 0)
    );
}

#[tokio::test]
async fn a_reply_is_sent_exactly_with_its_own_length_or_a_computed_one() {
    let fake = FakeHttp::start(vec![
        Reply::json(409, &serde_json::json!({"a": 1})),
        Reply::new(200).header("Content-Length", "3").body("abc"),
    ]);
    let raw = exchange_raw(&fake.endpoint(), &request("GET", "/", &[], b"")).await;
    assert_eq!(
        String::from_utf8(raw).expect("UTF-8"),
        "HTTP/1.1 409 Error\r\nContent-Type: application/json\r\nContent-Length: 7\r\nConnection: close\r\n\r\n{\"a\":1}"
    );
    let raw = exchange_raw(&fake.endpoint(), &request("GET", "/", &[], b"")).await;
    assert_eq!(
        String::from_utf8(raw).expect("UTF-8"),
        "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc"
    );
}

#[tokio::test]
async fn a_head_request_gets_the_headers_and_no_body() {
    let fake = FakeHttp::start(vec![Reply::new(200).body("body")]);
    let raw = exchange_raw(&fake.endpoint(), &request("HEAD", "/o", &[], b"")).await;
    assert_eq!(
        String::from_utf8(raw).expect("UTF-8"),
        "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n"
    );
}

#[tokio::test]
async fn a_request_is_recorded_in_full() {
    let fake = FakeHttp::start(vec![]);
    let auth = "AWS4-HMAC-SHA256 Credential=a/b, SignedHeaders=host;x-amz-date, Signature=00";
    exchange(
        &fake.endpoint(),
        &request(
            "PUT",
            "/a%20b/c?x=1&y=2",
            &[("X-Mixed-Case", " v "), ("Authorization", auth)],
            b"{\"k\":true}",
        ),
    )
    .await
    .expect("an answer");
    let seen = fake.requests();
    assert_eq!(seen.len(), 1);
    let r = &seen[0];
    assert_eq!(
        (r.method.as_str(), r.target.as_str(), r.path(), r.query()),
        ("PUT", "/a%20b/c?x=1&y=2", "/a%20b/c", "x=1&y=2")
    );
    assert_eq!(
        r.headers,
        vec![
            ("host".to_string(), "fake".to_string()),
            ("x-mixed-case".to_string(), "v".to_string()),
            ("authorization".to_string(), auth.to_string()),
            ("content-length".to_string(), "10".to_string()),
        ]
    );
    assert_eq!(r.body, b"{\"k\":true}");
    assert_eq!(r.json(), Some(serde_json::json!({"k": true})));
    assert_eq!(
        r.signed_headers(),
        vec!["host".to_string(), "x-amz-date".to_string()]
    );
    assert_eq!(r.header("x-absent"), None);
}

#[test]
fn accessors_of_a_bare_request() {
    let r = Seen {
        method: "GET".into(),
        target: "/p".into(),
        headers: vec![],
        body: b"not json".to_vec(),
    };
    assert_eq!(
        (r.path(), r.query(), r.json(), r.signed_headers()),
        ("/p", "", None, Vec::<String>::new())
    );
}

#[test]
fn a_form_body_is_decoded_in_order() {
    let r = Seen {
        method: "POST".into(),
        target: "/".into(),
        headers: vec![],
        body: b"a=1&b=x+y%21&&flag&c=%E2%9C%93&d=%zz%4&e=50%".to_vec(),
    };
    let pairs = |v: &[(&str, &str)]| {
        v.iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect::<Vec<_>>()
    };
    assert_eq!(
        r.form(),
        pairs(&[
            ("a", "1"),
            ("b", "x y!"),
            ("flag", ""),
            ("c", "\u{2713}"),
            ("d", "%zz%4"),
            ("e", "50%")
        ])
    );
    assert_eq!(form_value(&r.form(), "b"), Some("x y!"));
    assert_eq!(form_value(&r.form(), "z"), None);
}

#[test]
fn encoding_a_form_keeps_unreserved_characters_and_escapes_the_rest() {
    let encoded = encode_form(&[("scope", "read:user"), ("s", "aZ09-._~ /+\u{2713}")]);
    assert_eq!(encoded, "scope=read%3Auser&s=aZ09-._~%20%2F%2B%E2%9C%93");
    assert_eq!(
        decode_form(&encoded),
        vec![
            ("scope".to_string(), "read:user".to_string()),
            ("s".to_string(), "aZ09-._~ /+\u{2713}".to_string())
        ]
    );
}

#[tokio::test]
async fn a_body_is_read_to_its_length_and_bytes_after_it_are_ignored() {
    let fake = FakeHttp::start(vec![]);
    let mut stream = TcpStream::connect(fake.endpoint().trim_start_matches("http://"))
        .await
        .expect("a connection");
    stream
        .write_all(b"POST /late HTTP/1.1\r\nContent-Length: 6\r\n\r\n")
        .await
        .expect("the head");
    stream.write_all(b"abc").await.expect("part of the body");
    stream
        .write_all(b"defEXTRA")
        .await
        .expect("the rest, and more");
    let mut out = Vec::new();
    let _ = tokio::io::AsyncReadExt::read_to_end(&mut stream, &mut out).await;
    assert_eq!(parse(&out).expect("an answer").status, 200);
    assert_eq!(fake.requests()[0].body, b"abcdef");
}

#[test]
fn an_answer_without_a_head_or_a_status_does_not_parse() {
    assert!(parse(b"HTTP/1.1 200 OK\r\n").is_none());
    assert!(parse(b"\r\n\r\n").is_none());
    assert!(parse(b"HTTP/1.1\r\n\r\n").is_none());
    assert!(parse(b"HTTP/1.1 abc\r\n\r\n").is_none());
}

#[tokio::test]
async fn a_connection_closed_before_the_request_is_complete_is_not_recorded() {
    let fake = FakeHttp::start(vec![]);
    // Nothing at all, half a head, and a head whose body is cut short.
    for raw in [
        &b""[..],
        b"GET / HTTP/1.1\r\n",
        b"POST / HTTP/1.1\r\nContent-Length: 9\r\n\r\nabc",
    ] {
        let mut stream = TcpStream::connect(fake.endpoint().trim_start_matches("http://"))
            .await
            .expect("a connection");
        stream.write_all(raw).await.expect("the bytes");
        stream.shutdown().await.expect("the write half closes");
        let mut out = Vec::new();
        let _ = tokio::io::AsyncReadExt::read_to_end(&mut stream, &mut out).await;
        assert!(out.is_empty(), "no answer to {raw:?}");
    }
    // A complete request after them is the first one recorded.
    exchange(&fake.endpoint(), &request("GET", "/after", &[], b""))
        .await
        .expect("an answer");
    assert_eq!(
        fake.requests()
            .iter()
            .map(|r| r.target.clone())
            .collect::<Vec<_>>(),
        vec!["/after".to_string()]
    );
}

#[tokio::test]
async fn a_handler_sees_each_request_and_chooses_the_answer() {
    let fake = FakeHttp::with_handler(|seen| match seen.path() {
        "/drop" => Answer::Drop,
        _ => Answer::Reply(Reply::new(200).body(seen.method.clone())),
    });
    let got = exchange(&fake.endpoint(), &request("DELETE", "/x", &[], b""))
        .await
        .expect("an answer");
    assert_eq!(got.text(), "DELETE");
    assert_eq!(
        exchange_raw(&fake.endpoint(), &request("GET", "/drop", &[], b"")).await,
        Vec::<u8>::new()
    );
    assert_eq!(
        fake.requests()
            .iter()
            .map(|r| r.target.clone())
            .collect::<Vec<_>>(),
        vec!["/x".to_string(), "/drop".to_string()]
    );
}

#[tokio::test]
async fn a_hanging_request_is_recorded_answers_nothing_and_ends_when_the_server_is_dropped() {
    let fake = FakeHttp::with_handler(|seen| {
        if seen.path() == "/hang" {
            Answer::Hang
        } else {
            Answer::Reply(Reply::new(204))
        }
    });
    let endpoint = fake.endpoint();
    let hanging = tokio::spawn(async move {
        exchange_raw(&endpoint, &request("POST", "/hang", &[], b"body")).await
    });
    fake.wait_for_requests(1).await;
    assert_eq!(fake.requests()[0].body, b"body");
    // Other connections are served while it hangs.
    let other = exchange(&fake.endpoint(), &request("GET", "/other", &[], b""))
        .await
        .expect("an answer");
    assert_eq!(other.status, 204);
    assert!(!hanging.is_finished());
    drop(fake);
    assert_eq!(
        hanging.await.expect("the client task"),
        Vec::<u8>::new(),
        "not a byte was sent before the connection ended"
    );
}

#[tokio::test]
async fn waiting_for_requests_returns_once_that_many_are_recorded() {
    let fake = FakeHttp::start(vec![]);
    fake.wait_for_requests(0).await;
    let endpoint = fake.endpoint();
    let sender = tokio::spawn(async move {
        for _ in 0..2 {
            exchange(&endpoint, &request("GET", "/", &[], b""))
                .await
                .expect("an answer");
        }
    });
    fake.wait_for_requests(2).await;
    assert_eq!(fake.requests().len(), 2);
    sender.await.expect("the sender");
}

#[tokio::test]
async fn a_handler_that_panics_closes_that_connection_and_the_server_keeps_serving() {
    let fake = FakeHttp::with_handler(|seen| {
        assert!(seen.path() != "/panic", "a scripted assertion fails");
        Answer::Reply(Reply::new(200).body(seen.path().to_string()))
    });
    assert_eq!(
        exchange_raw(&fake.endpoint(), &request("GET", "/panic", &[], b"")).await,
        Vec::<u8>::new()
    );
    let next = exchange(&fake.endpoint(), &request("GET", "/next", &[], b""))
        .await
        .expect("an answer");
    assert_eq!((next.status, next.text()), (200, "/next".to_string()));
    let paths: Vec<String> = fake.requests().iter().map(|r| r.target.clone()).collect();
    assert_eq!(
        paths,
        vec!["/panic".to_string(), "/next".to_string()],
        "the request that panicked is recorded too"
    );
}
